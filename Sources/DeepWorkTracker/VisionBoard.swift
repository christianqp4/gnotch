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
}

/// Images and short texts (goals, quotes) shown as a board in the notch.
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
    }

    nonisolated static func isImageFile(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
    }

    /// Returns how many items were added (non-image files are skipped).
    @discardableResult
    func add(_ contents: [ClipContent]) -> Int {
        var added = 0
        for c in contents {
            switch c {
            case .text(let s):
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty else { continue }
                items.insert(VisionItem(id: UUID(), kind: .text, date: Date(), text: String(t.prefix(400))), at: 0)
                added += 1
            case .image(let img):
                guard let png = img.pngData() else { continue }
                let id = UUID()
                let name = id.uuidString + ".png"
                guard (try? png.write(to: dir.appendingPathComponent(name))) != nil else { continue }
                items.insert(VisionItem(id: id, kind: .image, date: Date(), imageFile: name), at: 0)
                added += 1
            case .files(let urls):
                for url in urls where Self.isImageFile(url) {
                    let id = UUID()
                    let name = id.uuidString + "." + url.pathExtension.lowercased()
                    guard (try? FileManager.default.copyItem(at: url, to: dir.appendingPathComponent(name))) != nil
                    else { continue }
                    items.insert(VisionItem(id: id, kind: .image, date: Date(), imageFile: name), at: 0)
                    added += 1
                }
            }
        }
        if added > 0 { save() }
        return added
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
    @FocusState private var noteFocused: Bool

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("Vision Board").font(.system(size: 14, weight: .bold))
                    Text("\(vision.items.count)").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
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
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: state.large ? 150 : 110), spacing: 8)],
                                  spacing: 8) {
                            ForEach(vision.items) { tile($0) }
                        }
                    }
                    .scrollIndicators(.never)
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

    private func tile(_ item: VisionItem) -> some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay { tileContent(item) }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .onTapGesture { focused = item }
            .onDrag {
                if let url = vision.imageURL(for: item), let p = NSItemProvider(contentsOf: url) { return p }
                return NSItemProvider(object: (item.text ?? "") as NSString)
            }
            .contextMenu {
                if let url = vision.imageURL(for: item) {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
                Button("Remove from Board", role: .destructive) { vision.remove(item.id) }
            }
    }

    @ViewBuilder
    private func tileContent(_ item: VisionItem) -> some View {
        switch item.kind {
        case .image:
            if let url = vision.imageURL(for: item), let img = Thumbnails.image(at: url, maxPixels: 400) {
                Image(nsImage: img).resizable().scaledToFill()
            } else {
                Color.white.opacity(0.06)
            }
        case .text:
            ZStack {
                LinearGradient(colors: [Color(red: 0.13, green: 0.22, blue: 0.17), Color(red: 0.06, green: 0.08, blue: 0.10)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Text(item.text ?? "")
                    .font(.system(size: state.large ? 15 : 13, weight: .medium, design: .serif))
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.6)
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
