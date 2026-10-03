import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct VisionItem: Codable, Identifiable, Hashable {
    enum Kind: String, Codable { case image, text }

    var id: UUID
    var kind: Kind
    var date: Date
    var imageFile: String?
    var text: String?

    // Free layout on the board, in fractions of the board size so it works at both sizes.
    /// Centre.
    var x: Double?
    var y: Double?
    /// Width as a fraction of the board width.
    var w: Double?
    /// Width / height.
    var aspect: Double?
    /// Stacking order; higher is in front.
    var z: Int?
}

/// Images and short texts (goals, quotes) arranged freely on a board in the notch.
/// Lives in ~/Library/Application Support/DeepWorkTracker/VisionBoard/.
@MainActor
final class VisionStore: ObservableObject {
    @Published private(set) var items: [VisionItem] = []
    let dir: URL
    private let fileURL: URL

    init(dir: URL = AppPaths.base.appendingPathComponent("VisionBoard", isDirectory: true)) {
        self.dir = dir
        fileURL = dir.appendingPathComponent("board.json")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: fileURL) {
            let d = JSONDecoder()
            d.dateDecodingStrategy = .iso8601
            items = (try? d.decode([VisionItem].self, from: data)) ?? []
        }
        // Boards saved before free layout existed get a tidy starting grid.
        var changed = false
        for i in items.indices where items[i].x == nil {
            place(&items[i], slot: i)
            changed = true
        }
        if changed { save() }
    }

    nonisolated static func isImageFile(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
    }

    var stacked: [VisionItem] { items.sorted { ($0.z ?? 0) < ($1.z ?? 0) } }
    private var topZ: Int { (items.compactMap(\.z).max() ?? 0) + 1 }

    /// Returns how many items were added (non-image files are skipped).
    @discardableResult
    func add(_ contents: [ClipContent]) -> Int {
        var added = 0
        for c in contents {
            var item: VisionItem?
            switch c {
            case .text(let s):
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty else { continue }
                item = VisionItem(id: UUID(), kind: .text, date: Date(), text: String(t.prefix(400)), aspect: 1)
            case .image(let img):
                guard let png = img.pngData() else { continue }
                let id = UUID()
                let name = id.uuidString + ".png"
                guard (try? png.write(to: dir.appendingPathComponent(name))) != nil else { continue }
                item = VisionItem(id: id, kind: .image, date: Date(), imageFile: name, aspect: Self.aspect(of: img))
            case .files(let urls):
                for url in urls where Self.isImageFile(url) {
                    let id = UUID()
                    let name = id.uuidString + "." + url.pathExtension.lowercased()
                    let dest = dir.appendingPathComponent(name)
                    guard (try? FileManager.default.copyItem(at: url, to: dest)) != nil else { continue }
                    var file = VisionItem(id: id, kind: .image, date: Date(), imageFile: name,
                                          aspect: NSImage(contentsOf: dest).map(Self.aspect) ?? 1)
                    place(&file, slot: items.count)
                    file.z = topZ
                    items.append(file)
                    added += 1
                }
            }
            if var item {
                place(&item, slot: items.count)
                item.z = topZ
                items.append(item)
                added += 1
            }
        }
        if added > 0 { save() }
        return added
    }

    func move(_ id: UUID, x: Double, y: Double) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].x = min(1, max(0, x))
        items[i].y = min(1, max(0, y))
        save()
    }

    func resize(_ id: UUID, w: Double) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].w = min(0.95, max(0.06, w))
        save()
    }

    func bringToFront(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }), items[i].z != topZ - 1 || items.count == 1 else { return }
        items[i].z = topZ
        save()
    }

    /// Lay everything out in a neat grid again.
    func tidy() {
        let ordered = stacked
        for (slot, item) in ordered.enumerated() {
            guard let i = items.firstIndex(where: { $0.id == item.id }) else { continue }
            place(&items[i], slot: slot)
        }
        save()
    }

    func remove(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items.remove(at: i)
        if let url = imageURL(for: item) { try? FileManager.default.removeItem(at: url) }
        save()
    }

    func imageURL(for item: VisionItem) -> URL? {
        item.imageFile.map { dir.appendingPathComponent($0) }
    }

    /// Grid slot: 5 columns, rows going down and wrapping back to the top.
    private func place(_ item: inout VisionItem, slot: Int) {
        let col = slot % 5, row = (slot / 5) % 3
        item.w = 0.17
        item.x = 0.11 + Double(col) * 0.195
        item.y = 0.2 + Double(row) * 0.3 + Double(slot / 15) * 0.04
        item.aspect = item.aspect ?? 1
        item.z = item.z ?? slot
    }

    private static func aspect(of img: NSImage) -> Double {
        let s = img.size
        return s.height > 0 ? max(0.3, min(3.5, Double(s.width / s.height))) : 1
    }

    private func save() {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        guard let data = try? e.encode(items) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

struct VisionPage: View {
    @ObservedObject var vision: VisionStore
    @ObservedObject var state: NotchState
    @State private var adding = false
    @State private var draft = ""
    @State private var focused: VisionItem?
    @State private var selected: UUID?
    /// Live gesture state, committed to the store when the gesture ends.
    @State private var moving: (id: UUID, offset: CGSize)?
    @State private var resizing: (id: UUID, w: Double)?
    @FocusState private var noteFocused: Bool

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("Vision Board").font(.system(size: 14, weight: .bold))
                    Text("\(vision.items.count)").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    pill("square.grid.2x2", "Tidy") { vision.tidy() }
                    pill("text.quote", "Note") {
                        adding.toggle()
                        noteFocused = adding
                    }
                    pill("doc.on.clipboard", "Paste") {
                        if let c = PasteboardReader.read(.general), vision.add([c]) > 0 {
                            state.flash("Added from clipboard")
                        } else {
                            state.flash("Nothing to paste")
                        }
                    }
                }

                if adding {
                    TextField("A goal, a quote, a feeling…", text: $draft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.08)))
                        .focused($noteFocused)
                        .onSubmit {
                            vision.add([.text(draft)])
                            draft = ""
                            adding = false
                        }
                }

                if vision.items.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "sparkles").font(.system(size: 24))
                        Text("Drag images onto the notch, then drop on Vision Board.")
                        Text("Or add a note: a goal, a quote, who you're becoming.").foregroundStyle(.tertiary)
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    board
                }
            }

            if let item = focused {
                focusView(item)
                    .transition(.opacity)
                    .onTapGesture { focused = nil }
            }
        }
        .animation(.easeOut(duration: 0.18), value: focused)
    }

    private var board: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white.opacity(0.03))
                    .contentShape(Rectangle())
                    .onTapGesture { selected = nil }
                ForEach(vision.stacked) { item in
                    tile(item, board: size)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private func tile(_ item: VisionItem, board: CGSize) -> some View {
        let w = (resizing?.id == item.id ? resizing!.w : item.w ?? 0.17) * board.width
        let h = w / (item.aspect ?? 1)
        let offset = moving?.id == item.id ? moving!.offset : .zero
        let center = CGPoint(x: (item.x ?? 0.5) * board.width + offset.width,
                             y: (item.y ?? 0.5) * board.height + offset.height)
        let isSelected = selected == item.id

        return tileContent(item, width: w)
            .frame(width: w, height: h)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.white.opacity(isSelected ? 0.9 : 0), lineWidth: 1.5)
            )
            .overlay(alignment: .bottomTrailing) {
                if isSelected { resizeHandle(item, board: board) }
            }
            .shadow(color: .black.opacity(0.5), radius: isSelected ? 8 : 3, y: 2)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { focused = item }
            .onTapGesture {
                selected = item.id
                vision.bringToFront(item.id)
            }
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { g in
                        if moving == nil {
                            selected = item.id
                            vision.bringToFront(item.id)
                        }
                        moving = (item.id, g.translation)
                    }
                    .onEnded { g in
                        vision.move(item.id,
                                    x: (item.x ?? 0.5) + g.translation.width / board.width,
                                    y: (item.y ?? 0.5) + g.translation.height / board.height)
                        moving = nil
                    }
            )
            .position(center)
            .contextMenu {
                Button("View Large") { focused = item }
                Button("Bring to Front") { vision.bringToFront(item.id) }
                if let url = vision.imageURL(for: item) {
                    Button("Copy Image") {
                        if let img = NSImage(contentsOf: url) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.writeObjects([img])
                        }
                    }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
                Divider()
                Button("Remove from Board", role: .destructive) { vision.remove(item.id) }
            }
    }

    private func resizeHandle(_ item: VisionItem, board: CGSize) -> some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.black)
            .frame(width: 18, height: 18)
            .background(Circle().fill(Color.white))
            .offset(x: 6, y: 6)
            .help("Drag to resize")
            .highPriorityGesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { g in
                        // Dragging the corner by dx grows the width by 2·dx because the tile is centred.
                        let start = item.w ?? 0.17
                        resizing = (item.id, max(0.06, min(0.95, start + 2 * g.translation.width / board.width)))
                    }
                    .onEnded { _ in
                        if let r = resizing { vision.resize(r.id, w: r.w) }
                        resizing = nil
                    }
            )
    }

    @ViewBuilder
    private func tileContent(_ item: VisionItem, width: CGFloat) -> some View {
        switch item.kind {
        case .image:
            if let url = vision.imageURL(for: item), let img = Thumbnails.image(at: url, maxPixels: 800) {
                Image(nsImage: img).resizable().scaledToFill()
            } else {
                Color.white.opacity(0.06)
            }
        case .text:
            ZStack {
                LinearGradient(colors: [Color(red: 0.13, green: 0.22, blue: 0.17), Color(red: 0.06, green: 0.08, blue: 0.10)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Text(item.text ?? "")
                    .font(.system(size: max(8, width * 0.11), weight: .medium, design: .serif))
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.5)
                    .padding(width * 0.08)
            }
        }
    }

    private func focusView(_ item: VisionItem) -> some View {
        ZStack {
            Color.black.opacity(0.94)
            switch item.kind {
            case .image:
                if let url = vision.imageURL(for: item), let img = Thumbnails.image(at: url, maxPixels: 1600) {
                    Image(nsImage: img).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 12))
                }
            case .text:
                Text(item.text ?? "")
                    .font(.system(size: 24, weight: .medium, design: .serif))
                    .multilineTextAlignment(.center)
                    .padding(30)
            }
        }
    }

    private func pill(_ icon: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 11.5, weight: .semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.white.opacity(0.09)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
