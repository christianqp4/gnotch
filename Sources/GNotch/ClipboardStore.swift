import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

enum AppPaths {
    /// ~/Library/Application Support/GNotch. Data from the "DeepWork Tracker" days is moved here once.
    static let base: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = support.appendingPathComponent("GNotch", isDirectory: true)
        let old = support.appendingPathComponent("DeepWorkTracker", isDirectory: true)
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path), fm.fileExists(atPath: old.path) {
            try? fm.moveItem(at: old, to: url)
        }
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
}

enum Migration {
    /// Bring settings (and a running timer) over from the old bundle id.
    static func run() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "migratedFromDeepWorkTracker") else { return }
        if let old = d.persistentDomain(forName: "com.christianqp4.DeepWorkTracker") {
            for (k, v) in old where d.object(forKey: k) == nil { d.set(v, forKey: k) }
        }
        d.set(true, forKey: "migratedFromDeepWorkTracker")
    }
}

/// Something read from a pasteboard or a drop.
enum ClipContent {
    case text(String)
    case image(NSImage)
    case files([URL])
}

struct ClipItem: Codable, Identifiable, Hashable {
    enum Kind: String, Codable { case text, image, file }

    var id: UUID
    var kind: Kind
    var date: Date
    var text: String?
    var paths: [String]?
    var imageFile: String?
    var imageWidth: Int?
    var imageHeight: Int?
    var sourceApp: String?
    var pinned: Bool
    var signature: String

    var fileURLs: [URL] { (paths ?? []).map { URL(fileURLWithPath: $0) } }

    var preview: String {
        switch kind {
        case .text:
            return (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ⏎ ")
        case .file:
            let names = fileURLs.map(\.lastPathComponent)
            return names.count == 1 ? names[0] : "\(names.count) files: " + names.joined(separator: ", ")
        case .image:
            if let w = imageWidth, let h = imageHeight { return "Image · \(w)×\(h)" }
            return "Image"
        }
    }

    var searchText: String {
        [text, paths?.joined(separator: " "), sourceApp, kind == .image ? "image" : nil]
            .compactMap { $0 }.joined(separator: " ").lowercased()
    }

    var isLink: Bool {
        guard kind == .text, let t = text?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        return !t.contains(" ") && (t.hasPrefix("http://") || t.hasPrefix("https://"))
    }
}

/// Clipboard history: watches the system pasteboard, stores text, images and files.
/// Lives in ~/Library/Application Support/GNotch/Clipboard/.
@MainActor
final class ClipboardStore: ObservableObject {
    @Published private(set) var items: [ClipItem] = []
    @Published var paused = UserDefaults.standard.bool(forKey: "clipboardPaused") {
        didSet { UserDefaults.standard.set(paused, forKey: "clipboardPaused") }
    }

    static let maxItems = 500
    static let maxImages = 80

    let dir: URL
    let imagesDir: URL
    private let fileURL: URL
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var timer: Timer?

    init(dir: URL = AppPaths.base.appendingPathComponent("Clipboard", isDirectory: true), monitor: Bool = true) {
        self.dir = dir
        imagesDir = dir.appendingPathComponent("images", isDirectory: true)
        fileURL = dir.appendingPathComponent("clipboard.json")
        try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        load()
        guard monitor else { return }
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        t.tolerance = 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    var pinnedItems: [ClipItem] { items.filter(\.pinned) }
    var unpinnedItems: [ClipItem] { items.filter { !$0.pinned } }

    func search(_ query: String) -> [ClipItem] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        return items.filter { item in words.allSatisfy { item.searchText.contains($0) } }
    }

    // MARK: Capture

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount
        guard !paused, !PasteboardReader.isSensitive(pb) else { return }
        let app = NSWorkspace.shared.frontmostApplication
        if let id = app?.bundleIdentifier, PasteboardReader.passwordApps.contains(id) { return }
        guard let content = PasteboardReader.read(pb) else { return }
        add(content, source: app?.localizedName)
    }

    /// Drops: several files become one item, everything else one item each.
    func addDropped(_ contents: [ClipContent]) {
        var files: [URL] = []
        for c in contents {
            if case .files(let urls) = c { files += urls } else { add(c, source: "Dropped") }
        }
        if !files.isEmpty { add(.files(files), source: "Dropped") }
    }

    func add(_ content: ClipContent, source: String?) {
        var item = ClipItem(id: UUID(), kind: .text, date: Date(), sourceApp: source, pinned: false, signature: "")
        var imageData: Data?

        switch content {
        case .text(let s):
            item.text = String(s.prefix(200_000))
            item.signature = "t:" + Self.hash(Data(s.utf8))
        case .files(let urls):
            item.kind = .file
            item.paths = urls.map(\.path)
            item.signature = "f:" + Self.hash(Data(item.paths!.joined(separator: "\n").utf8))
        case .image(let img):
            guard let png = img.pngData() else { return }
            item.kind = .image
            item.signature = "i:" + Self.hash(png)
            if let rep = NSBitmapImageRep(data: png) {
                item.imageWidth = rep.pixelsWide
                item.imageHeight = rep.pixelsHigh
            }
            imageData = png
        }

        if let i = items.firstIndex(where: { $0.signature == item.signature }) {
            // Seen before: move it to the top instead of duplicating.
            var existing = items.remove(at: i)
            existing.date = Date()
            items.insert(existing, at: 0)
        } else {
            if let imageData {
                let name = item.id.uuidString + ".png"
                guard (try? imageData.write(to: imagesDir.appendingPathComponent(name))) != nil else { return }
                item.imageFile = name
            }
            items.insert(item, at: 0)
            trim()
        }
        save()
    }

    /// A screenshot file: optionally onto the clipboard, and into history either way.
    func addScreenshot(_ url: URL, copy: Bool) {
        guard let image = NSImage(contentsOf: url) else { return }
        if copy, ScreenshotLibrary.copyToPasteboard(url) {
            lastChangeCount = NSPasteboard.general.changeCount
        }
        add(.image(image), source: "Screenshot")
    }

    // MARK: Actions

    func copy(_ item: ClipItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        switch item.kind {
        case .text:
            pb.setString(item.text ?? "", forType: .string)
        case .image:
            if let url = imageURL(for: item), let img = NSImage(contentsOf: url) { pb.writeObjects([img]) }
        case .file:
            pb.writeObjects(item.fileURLs as [NSURL])
        }
        lastChangeCount = pb.changeCount
        bump(item.id)
    }

    func togglePin(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].pinned.toggle()
        save()
    }

    func delete(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        removeFiles(of: items.remove(at: i))
        save()
    }

    /// Clears history but keeps pinned items.
    func clearHistory() {
        items.filter { !$0.pinned }.forEach(removeFiles)
        items.removeAll { !$0.pinned }
        save()
    }

    func imageURL(for item: ClipItem) -> URL? {
        item.imageFile.map { imagesDir.appendingPathComponent($0) }
    }

    func itemProvider(for item: ClipItem) -> NSItemProvider {
        switch item.kind {
        case .text:
            return NSItemProvider(object: (item.text ?? "") as NSString)
        case .image:
            if let url = imageURL(for: item), let p = NSItemProvider(contentsOf: url) { return p }
            return NSItemProvider()
        case .file:
            if let url = item.fileURLs.first, let p = NSItemProvider(contentsOf: url) { return p }
            return NSItemProvider()
        }
    }

    // MARK: Storage

    private func bump(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items.remove(at: i)
        item.date = Date()
        items.insert(item, at: 0)
        save()
    }

    private func trim() {
        var unpinned = 0, images = 0
        var keep: [ClipItem] = []
        for item in items {
            if item.pinned { keep.append(item); continue }
            unpinned += 1
            if item.kind == .image { images += 1 }
            if unpinned > Self.maxItems || (item.kind == .image && images > Self.maxImages) {
                removeFiles(of: item)
            } else {
                keep.append(item)
            }
        }
        items = keep
    }

    private func removeFiles(of item: ClipItem) {
        if let url = imageURL(for: item) { try? FileManager.default.removeItem(at: url) }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        items = (try? d.decode([ClipItem].self, from: data)) ?? []
    }

    private func save() {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        guard let data = try? e.encode(items) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}

enum PasteboardReader {
    /// Markers password managers and other well-behaved apps put on secrets (nspasteboard.org).
    static let sensitiveTypes: Set<String> = [
        "org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType",
        "com.agilebits.onepassword", "com.1password.1password", "de.petermaurer.TransientPasteboardType",
        "Pasteboard generator type", "net.antelle.keeweb",
    ]
    /// Never record anything copied while these apps are in front.
    static let passwordApps: Set<String> = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.agilebits.onepassword-osx",
        "com.bitwarden.desktop", "org.keepassxc.keepassxc", "com.apple.keychainaccess", "com.apple.Passwords",
        "com.lastpass.LastPass", "com.dashlane.dashlanephonefinal", "com.nordpass.macos.NordPass",
        "in.sinew.Enpass-Desktop", "com.apple.systempreferences",
    ]

    private static let imageTypes: [NSPasteboard.PasteboardType] = [
        .png, .tiff, NSPasteboard.PasteboardType("public.jpeg"), NSPasteboard.PasteboardType("public.heic"),
    ]

    static func isSensitive(_ pb: NSPasteboard) -> Bool {
        (pb.types ?? []).contains { sensitiveTypes.contains($0.rawValue) }
    }

    static func read(_ pb: NSPasteboard) -> ClipContent? {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return .files(urls)
        }
        let text = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let textIsJustALink = !text.contains(" ") && text.hasPrefix("http")
        // Office apps put a picture of copied text on the pasteboard too; prefer the text there.
        if pb.availableType(from: imageTypes) != nil, text.isEmpty || textIsJustALink,
           let image = NSImage(pasteboard: pb) {
            return .image(image)
        }
        if !text.isEmpty, let raw = pb.string(forType: .string) { return .text(raw) }
        return nil
    }

    /// Reads dropped items. Calls back on the main thread, in drop order.
    static func read(providers: [NSItemProvider], completion: @escaping @MainActor ([ClipContent]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var results: [Int: ClipContent] = [:]
        func put(_ i: Int, _ c: ClipContent) {
            lock.lock()
            results[i] = c
            lock.unlock()
        }

        for (i, p) in providers.enumerated() {
            group.enter()
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                        put(i, .files([url]))
                    } else if let url = item as? URL {
                        put(i, .files([url]))
                    }
                    group.leave()
                }
            } else if p.canLoadObject(ofClass: NSImage.self) {
                _ = p.loadObject(ofClass: NSImage.self) { obj, _ in
                    if let img = obj as? NSImage { put(i, .image(img)) }
                    group.leave()
                }
            } else if p.canLoadObject(ofClass: NSString.self) {
                _ = p.loadObject(ofClass: NSString.self) { obj, _ in
                    if let s = obj as? String, !s.isEmpty { put(i, .text(s)) }
                    group.leave()
                }
            } else if p.canLoadObject(ofClass: NSURL.self) {
                _ = p.loadObject(ofClass: NSURL.self) { obj, _ in
                    if let u = obj as? URL { put(i, .text(u.absoluteString)) }
                    group.leave()
                }
            } else {
                group.leave()
            }
        }

        group.notify(queue: .main) {
            let ordered = results.keys.sorted().compactMap { results[$0] }
            MainActor.assumeIsolated { completion(ordered) }
        }
    }
}

extension NSImage {
    func pngData() -> Data? {
        guard let tiff = tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

/// Small, cached, downsampled images for lists and tiles.
@MainActor
enum Thumbnails {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(at url: URL, maxPixels: Int) -> NSImage? {
        let key = "\(url.path)#\(maxPixels)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixels,
              ] as CFDictionary)
        else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        cache.setObject(img, forKey: key)
        return img
    }
}
