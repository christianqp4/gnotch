import AppKit
import ImageIO

/// Ubuntu-style screenshots: every new screenshot goes straight onto the clipboard (⌘V right away)
/// and into the clipboard history. Also lists the screenshots already in the folder.
@MainActor
final class ScreenshotLibrary: ObservableObject {
    struct Shot: Identifiable, Hashable {
        let url: URL
        let date: Date
        /// Width / height.
        let aspect: Double
        var id: URL { url }
    }

    @Published private(set) var shots: [Shot] = []
    @Published private(set) var folder: URL
    @Published var autoCopy = UserDefaults.standard.object(forKey: "screenshotAutoCopy") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoCopy, forKey: "screenshotAutoCopy") }
    }

    /// Called for each new screenshot (already on the clipboard when autoCopy is on).
    var onNewScreenshot: ((URL) -> Void)?

    private var source: DispatchSourceFileSystemObject?
    private var known = Set<URL>()
    private var aspects: [URL: Double] = [:]
    private var folderCheck: Timer?
    private let startedAt = Date()

    nonisolated static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "tif"]

    /// `folder` overrides the system screenshot location (snapshots use a temp folder).
    init(folder: URL? = nil, watch: Bool = true) {
        self.folder = folder ?? Self.screenshotFolder()
        rescan(initial: true)
        guard watch else { return }
        startWatching()
        // Follow changes to the screenshot location (e.g. after running scripts/screenshots.sh).
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = Self.screenshotFolder()
                if now != self.folder {
                    self.folder = now
                    self.known.removeAll()
                    self.rescan(initial: true)
                    self.startWatching()
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        folderCheck = t
    }

    /// Where macOS saves screenshots: the Screenshot app's setting, or the Desktop.
    static func screenshotFolder() -> URL {
        if let raw = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location"), !raw.isEmpty {
            let path = (raw as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    }

    /// macOS tags every screenshot file with this attribute, whatever the language of the file name.
    nonisolated static func isScreenshot(_ url: URL) -> Bool {
        guard imageExtensions.contains(url.pathExtension.lowercased()),
              !url.lastPathComponent.hasPrefix(".") else { return false }
        return getxattr(url.path, "com.apple.metadata:kMDItemIsScreenCapture", nil, 0, 0, 0) >= 0
    }

    func refresh() { rescan(initial: false) }

    /// Puts a screenshot on the clipboard as an image, ready for ⌘V.
    static func copyToPasteboard(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url), let image = NSImage(data: data) else { return false }
        let item = NSPasteboardItem()
        if let png = image.pngData() { item.setData(png, forType: .png) }
        if let tiff = image.tiffRepresentation { item.setData(tiff, forType: .tiff) }
        let pb = NSPasteboard.general
        pb.clearContents()
        return pb.writeObjects([item])
    }

    // MARK: Private

    private func startWatching() {
        source?.cancel()
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename],
                                                           queue: .main)
        src.setEventHandler { [weak self] in
            // The screenshot is written to a hidden temp file and renamed; give it a moment.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                MainActor.assumeIsolated { self?.rescan(initial: false) }
            }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    private func rescan(initial: Bool) {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey],
                                                options: [.skipsHiddenFiles])) ?? []
        var found: [Shot] = []
        for url in urls where Self.isScreenshot(url) {
            let date = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let aspect = aspects[url] ?? {
                let size = Self.pixelSize(url) ?? CGSize(width: 16, height: 10)
                return size.width / max(1, size.height)
            }()
            aspects[url] = aspect
            found.append(Shot(url: url, date: date, aspect: aspect))
            if !initial, !known.contains(url), date > startedAt.addingTimeInterval(-5) {
                known.insert(url)
                onNewScreenshot?(url)
            }
        }
        found.sort { $0.date > $1.date }
        known.formUnion(found.map(\.url))
        shots = Array(found.prefix(400))
    }
}

extension ScreenshotLibrary {
    /// Pixel size without decoding the whole image.
    static func pixelSize(_ url: URL) -> CGSize? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return CGSize(width: w, height: h)
    }
}

/// The Screenshot app's floating thumbnail delays saving by ~5 s. Same switch as `scripts/screenshots.sh`.
enum ScreenshotSettings {
    static var thumbnailEnabled: Bool {
        UserDefaults(suiteName: "com.apple.screencapture")?.object(forKey: "show-thumbnail") as? Bool ?? true
    }

    static func setThumbnail(_ on: Bool) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        p.arguments = ["write", "com.apple.screencapture", "show-thumbnail", "-bool", on ? "true" : "false"]
        try? p.run()
        p.waitUntilExit()
    }
}
