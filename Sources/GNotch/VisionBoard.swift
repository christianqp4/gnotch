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
    /// Width / height of the image.
    var aspect: Double?

    // Widget layout: position in the flow and size in grid cells.
    var order: Int?
    var cols: Int?
    var rows: Int?
}

/// Images and short texts (goals, quotes) shown as home-screen-style widgets.
/// Lives in ~/Library/Application Support/GNotch/VisionBoard/.
@MainActor
final class VisionStore: ObservableObject {
    static let columns = 6
    static let maxRows = 4

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
        // Boards from before widgets get default sizes.
        var changed = false
        for i in items.indices where items[i].order == nil || items[i].cols == nil {
            items[i].order = items[i].order ?? i
            Self.defaultSize(&items[i])
            changed = true
        }
        if changed { save() }
    }

    nonisolated static func isImageFile(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
    }

    /// Items in widget order.
    var ordered: [VisionItem] { items.sorted { ($0.order ?? 0) < ($1.order ?? 0) } }

    /// Returns how many items were added (non-image files are skipped). New items go first.
    @discardableResult
    func add(_ contents: [ClipContent]) -> Int {
        var new: [VisionItem] = []
        for c in contents {
            switch c {
            case .text(let s):
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty else { continue }
                new.append(VisionItem(id: UUID(), kind: .text, date: Date(), text: String(t.prefix(400))))
            case .image(let img):
                guard let png = img.pngData() else { continue }
                let id = UUID()
                let name = id.uuidString + ".png"
                guard (try? png.write(to: dir.appendingPathComponent(name))) != nil else { continue }
                new.append(VisionItem(id: id, kind: .image, date: Date(), imageFile: name, aspect: Self.aspect(of: img)))
            case .files(let urls):
                for url in urls where Self.isImageFile(url) {
                    let id = UUID()
                    let name = id.uuidString + "." + url.pathExtension.lowercased()
                    let dest = dir.appendingPathComponent(name)
                    guard (try? FileManager.default.copyItem(at: url, to: dest)) != nil else { continue }
                    new.append(VisionItem(id: id, kind: .image, date: Date(), imageFile: name,
                                          aspect: NSImage(contentsOf: dest).map(Self.aspect) ?? 1))
                }
            }
        }
        guard !new.isEmpty else { return 0 }
        for i in new.indices { Self.defaultSize(&new[i]) }
        setOrder(new + ordered)
        return new.count
    }

    /// Persist a new widget order (after a drag).
    func setOrder(_ list: [VisionItem]) {
        var byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        for item in list where byID[item.id] == nil { byID[item.id] = item }
        items = list.enumerated().compactMap { i, item in
            guard var it = byID[item.id] else { return nil }
            it.order = i
            return it
        }
        save()
    }

    func move(_ id: UUID, toIndex target: Int) {
        var list = ordered
        guard let from = list.firstIndex(where: { $0.id == id }) else { return }
        let item = list.remove(at: from)
        list.insert(item, at: max(0, min(list.count, target)))
        setOrder(list)
    }

    func resize(_ id: UUID, cols: Int, rows: Int) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].cols = max(1, min(Self.columns, cols))
        items[i].rows = max(1, min(Self.maxRows, rows))
        save()
    }

    /// Back to default sizes, newest first.
    func tidy() {
        var list = items.sorted { $0.date > $1.date }
        for i in list.indices { Self.defaultSize(&list[i]) }
        setOrder(list)
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

    private static func defaultSize(_ item: inout VisionItem) {
        switch item.kind {
        case .image:
            let a = item.aspect ?? 1
            (item.cols, item.rows) = a >= 1.25 ? (3, 2) : a <= 0.8 ? (2, 3) : (2, 2)
        case .text:
            let n = item.text?.count ?? 0
            (item.cols, item.rows) = n <= 40 ? (2, 1) : n <= 90 ? (3, 1) : (3, 2)
        }
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

/// Places widgets in order, each in the first free spot (row by row), so nothing ever overlaps.
struct WidgetLayout {
    struct Slot: Equatable {
        var col: Int, row: Int, cols: Int, rows: Int
    }

    let slots: [UUID: Slot]
    let totalRows: Int

    init(_ items: [(id: UUID, cols: Int, rows: Int)], columns: Int) {
        var occupied: [[Bool]] = []
        var slots: [UUID: Slot] = [:]
        func ensure(_ rows: Int) {
            while occupied.count < rows { occupied.append(Array(repeating: false, count: columns)) }
        }
        func fits(_ c: Int, _ r: Int, _ w: Int, _ h: Int) -> Bool {
            ensure(r + h)
            for rr in r..<(r + h) { for cc in c..<(c + w) where occupied[rr][cc] { return false } }
            return true
        }
        for item in items {
            let w = max(1, min(columns, item.cols)), h = max(1, item.rows)
            var r = 0
            search: while true {
                for c in 0...(columns - w) where fits(c, r, w, h) {
                    for rr in r..<(r + h) { for cc in c..<(c + w) { occupied[rr][cc] = true } }
                    slots[item.id] = Slot(col: c, row: r, cols: w, rows: h)
                    break search
                }
                r += 1
            }
        }
        self.slots = slots
        totalRows = slots.values.map { $0.row + $0.rows }.max() ?? 0
    }
}

struct VisionPage: View {
    @ObservedObject var vision: VisionStore
    @ObservedObject var state: NotchState
    @State private var adding = false
    @State private var draft = ""
    @State private var focused: VisionItem?
    @State private var selected: UUID?
    /// Live drag: which widget, where it would land, and how far the pointer moved.
    @State private var drag: (id: UUID, target: Int, translation: CGSize)?
    @State private var resize: (id: UUID, cols: Int, rows: Int)?
    @FocusState private var noteFocused: Bool

    private let gap: CGFloat = 8

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("Vision Board").font(.system(size: 14, weight: .bold))
                    Text("\(vision.items.count)").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    pill("square.grid.2x2", "Tidy") { withAnimation(.spring(response: 0.35)) { vision.tidy() } }
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
                    GeometryReader { geo in
                        ScrollView { board(width: geo.size.width) }
                            .scrollIndicators(.never)
                    }
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

    // MARK: Board

    /// Order and sizes including the drag/resize in progress, so the other widgets make room live.
    private func preview() -> [VisionItem] {
        var list = vision.ordered
        if let r = resize, let i = list.firstIndex(where: { $0.id == r.id }) {
            list[i].cols = r.cols
            list[i].rows = r.rows
        }
        if let d = drag, let from = list.firstIndex(where: { $0.id == d.id }) {
            let item = list.remove(at: from)
            list.insert(item, at: max(0, min(list.count, d.target)))
        }
        return list
    }

    private func board(width: CGFloat) -> some View {
        let columns = VisionStore.columns
        let cell = (width - gap * CGFloat(columns - 1)) / CGFloat(columns)
        let list = preview()
        let layout = WidgetLayout(list.map { ($0.id, $0.cols ?? 2, $0.rows ?? 2) }, columns: columns)
        // While dragging, the dragged widget follows the pointer from where it started.
        let resting = WidgetLayout(vision.ordered.map { ($0.id, $0.cols ?? 2, $0.rows ?? 2) }, columns: columns)

        return ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { selected = nil }
            ForEach(list) { item in
                let dragging = drag?.id == item.id
                let slot = (dragging ? resting.slots[item.id] : layout.slots[item.id])
                    ?? WidgetLayout.Slot(col: 0, row: 0, cols: 1, rows: 1)
                let rect = frame(slot, cell: cell)
                widget(item, size: rect.size, cell: cell, layout: layout, list: list)
                    .offset(x: rect.minX + (dragging ? drag!.translation.width : 0),
                            y: rect.minY + (dragging ? drag!.translation.height : 0))
                    .zIndex(dragging ? 10 : selected == item.id ? 1 : 0)
                    .scaleEffect(dragging ? 1.04 : 1, anchor: .center)
            }
        }
        .frame(width: width, height: max(cell, CGFloat(layout.totalRows) * (cell + gap) + cell), alignment: .topLeading)
        .coordinateSpace(name: "board")
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: list.map(\.id))
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: resize?.cols)
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: resize?.rows)
    }

    private func frame(_ slot: WidgetLayout.Slot, cell: CGFloat) -> CGRect {
        CGRect(x: CGFloat(slot.col) * (cell + gap), y: CGFloat(slot.row) * (cell + gap),
               width: CGFloat(slot.cols) * cell + CGFloat(slot.cols - 1) * gap,
               height: CGFloat(slot.rows) * cell + CGFloat(slot.rows - 1) * gap)
    }

    private func widget(_ item: VisionItem, size: CGSize, cell: CGFloat, layout: WidgetLayout,
                        list: [VisionItem]) -> some View {
        let isSelected = selected == item.id
        return tileContent(item, width: size.width)
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.white.opacity(isSelected ? 0.9 : 0), lineWidth: 1.5)
            )
            .overlay(alignment: .bottomTrailing) {
                if isSelected, drag == nil { resizeHandle(item, cell: cell) }
            }
            .shadow(color: .black.opacity(drag?.id == item.id ? 0.6 : 0.25), radius: drag?.id == item.id ? 12 : 3, y: 2)
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .onTapGesture(count: 2) { focused = item }
            .onTapGesture { selected = item.id }
            .gesture(
                DragGesture(minimumDistance: 3, coordinateSpace: .named("board"))
                    .onChanged { g in
                        selected = item.id
                        let target = targetIndex(for: g.location, dragging: item.id, cell: cell,
                                                 layout: layout, list: list)
                        if drag?.target != target {
                            drag = (item.id, target, g.translation)
                        } else {
                            drag?.translation = g.translation
                        }
                    }
                    .onEnded { _ in
                        if let d = drag {
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                                vision.move(d.id, toIndex: d.target)
                                drag = nil
                            }
                        }
                    }
            )
            .contextMenu {
                Button("View Large") { focused = item }
                Menu("Size") {
                    ForEach(["1×1", "2×1", "2×2", "3×2", "2×3", "4×2", "3×3", "6×3"], id: \.self) { size in
                        let parts = size.split(separator: "×").compactMap { Int($0) }
                        Button(size) {
                            withAnimation(.spring(response: 0.32)) { vision.resize(item.id, cols: parts[0], rows: parts[1]) }
                        }
                    }
                }
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

    /// The widget under the pointer gives up its place in the order; empty space means "go to the end".
    private func targetIndex(for point: CGPoint, dragging id: UUID, cell: CGFloat, layout: WidgetLayout,
                             list: [VisionItem]) -> Int {
        let col = Int(point.x / (cell + gap)), row = Int(point.y / (cell + gap))
        for (i, item) in list.enumerated() where item.id != id {
            guard let s = layout.slots[item.id] else { continue }
            if col >= s.col, col < s.col + s.cols, row >= s.row, row < s.row + s.rows {
                return i
            }
        }
        if let current = list.firstIndex(where: { $0.id == id }), let s = layout.slots[id],
           col >= s.col, col < s.col + s.cols, row >= s.row, row < s.row + s.rows {
            return current
        }
        return list.count - 1
    }

    private func resizeHandle(_ item: VisionItem, cell: CGFloat) -> some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.black)
            .frame(width: 20, height: 20)
            .background(Circle().fill(Color.white))
            .shadow(radius: 2)
            .offset(x: 5, y: 5)
            .help("Drag to resize (snaps to the grid)")
            .highPriorityGesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { g in
                        let startCols = item.cols ?? 2, startRows = item.rows ?? 2
                        let cols = startCols + Int((g.translation.width / (cell + gap)).rounded())
                        let rows = startRows + Int((g.translation.height / (cell + gap)).rounded())
                        let c = max(1, min(VisionStore.columns, cols)), r = max(1, min(VisionStore.maxRows, rows))
                        if resize?.cols != c || resize?.rows != r { resize = (item.id, c, r) }
                    }
                    .onEnded { _ in
                        if let r = resize {
                            withAnimation(.spring(response: 0.32)) {
                                vision.resize(r.id, cols: r.cols, rows: r.rows)
                                resize = nil
                            }
                        }
                    }
            )
    }

    @ViewBuilder
    private func tileContent(_ item: VisionItem, width: CGFloat) -> some View {
        switch item.kind {
        case .image:
            if let url = vision.imageURL(for: item), let img = Thumbnails.image(at: url, maxPixels: 900) {
                Image(nsImage: img).resizable().scaledToFill()
            } else {
                Color.white.opacity(0.06)
            }
        case .text:
            ZStack {
                LinearGradient(colors: [Color(red: 0.13, green: 0.22, blue: 0.17), Color(red: 0.06, green: 0.08, blue: 0.10)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Text(item.text ?? "")
                    .font(.system(size: max(10, min(22, width * 0.075)), weight: .medium, design: .serif))
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.5)
                    .padding(10)
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
