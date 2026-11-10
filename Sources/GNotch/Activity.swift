import Foundation

/// A span of real activity GNotch found on its own: Claude Code chat messages and git commits,
/// joined while the gaps between them stay under 20 minutes, parallel chats merged into wall time.
/// Kept in `activity.json`, never in `sessions.json`: manual blocks and their notes are never touched.
struct ActivityBlock: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var start: Date
    var end: Date
    var manual = false
    var source = "auto"
    /// Messages per project ("GNotch", "Umami", "Day chat"…).
    var projects: [String: Int] = [:]
    /// Commits in the span, across the repos in projects.json.
    var commits = 0
    /// Chat messages in the span (user and Claude turns, tool calls included).
    var messages = 0
    /// Transcript ids of the chats active in the span.
    var chats: [String] = []

    var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }
    /// Projects, busiest first.
    var projectNames: [String] { projects.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key) }
    var label: String {
        let names = projectNames
        guard !names.isEmpty else { return commits > 0 ? "Commits" : "Activity" }
        return names.prefix(3).joined(separator: ", ") + (names.count > 3 ? " +\(names.count - 3)" : "")
    }
    var detail: String {
        var parts: [String] = []
        if !chats.isEmpty { parts.append(chats.count == 1 ? "1 chat" : "\(chats.count) chats") }
        if commits > 0 { parts.append(commits == 1 ? "1 commit" : "\(commits) commits") }
        return parts.joined(separator: " · ")
    }

    /// Joins `other` into this block (they touch or overlap). Keeps the earlier id.
    mutating func absorb(_ other: ActivityBlock) {
        if other.start < start { id = other.id }
        start = min(start, other.start)
        end = max(end, other.end)
        for (k, v) in other.projects { projects[k, default: 0] += v }
        commits += other.commits
        messages += other.messages
        chats = Array(Set(chats).union(other.chats)).sorted()
    }
}

/// The scanner. Reads only what was appended since the last scan (transcripts are append-only),
/// so after the first backfill a scan costs a few kilobytes. Runs off the main thread.
enum ActivityScanner {
    /// Gaps shorter than this join two moments into one block.
    static let gap: TimeInterval = 20 * 60

    struct FileFormat: Codable {
        var version = 1
        var blocks: [ActivityBlock] = []
        /// Bytes already read from each transcript, and the project it belongs to.
        var cursors: [String: Cursor] = [:]
        /// Newest commit time already counted.
        var commitsThrough: Date?
    }

    struct Cursor: Codable {
        var offset: UInt64
        var project: String?
    }

    static var defaultFile: URL { AppPaths.base.appendingPathComponent("activity.json") }
    static let home = FileManager.default.homeDirectoryForCurrentUser

    static func load(_ url: URL) -> FileFormat? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try? d.decode(FileFormat.self, from: data)
    }

    static func save(_ file: FileFormat, to url: URL) {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? e.encode(file) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// One scan: new chat lines and new commits are folded into the stored blocks, then saved.
    /// `transcripts` and `projectsFile` are parameters so the dev check can point elsewhere.
    @discardableResult
    static func scan(file url: URL = defaultFile,
                     transcripts: URL = home.appendingPathComponent(".claude/projects"),
                     projectsFile: URL = home.appendingPathComponent("gears_OS/projects.json")) -> [ActivityBlock] {
        var state: FileFormat
        if FileManager.default.fileExists(atPath: url.path) {
            // Never overwrite a file we can't read.
            guard let loaded = load(url) else { return [] }
            state = loaded
        } else {
            state = FileFormat()
        }
        let projects = ProjectMap(file: projectsFile)
        var fresh: [ActivityBlock] = []
        fresh += readTranscripts(in: transcripts, cursors: &state.cursors, projects: projects)
        fresh += readCommits(projects: projects, since: &state.commitsThrough)
        state.blocks = merge(state.blocks + fresh)
        save(state, to: url)
        return state.blocks
    }

    /// Joins blocks whose gap is under `gap`. Order-independent, so incremental scans
    /// give the same blocks as one big scan.
    static func merge(_ blocks: [ActivityBlock]) -> [ActivityBlock] {
        var out: [ActivityBlock] = []
        for b in blocks.sorted(by: { $0.start < $1.start }) {
            if let last = out.indices.last, b.start.timeIntervalSince(out[last].end) < gap {
                out[last].absorb(b)
            } else {
                out.append(b)
            }
        }
        return out
    }

    // MARK: Chats

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain = ISO8601DateFormatter()

    /// Whole seconds, like the dates in `activity.json`, so a block reads back exactly as it was found.
    static func date(_ s: String) -> Date? {
        (iso.date(from: s) ?? isoPlain.date(from: s)).map { Date(timeIntervalSince1970: $0.timeIntervalSince1970.rounded(.down)) }
    }

    private static func readTranscripts(in dir: URL, cursors: inout [String: Cursor], projects: ProjectMap) -> [ActivityBlock] {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        var out: [ActivityBlock] = []
        for folder in folders {
            guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey]) else { continue }
            for f in files where f.pathExtension == "jsonl" {
                let size = UInt64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                var cursor = cursors[f.path] ?? Cursor(offset: 0, project: nil)
                if size < cursor.offset { cursor.offset = 0 }  // replaced, start again
                guard size > cursor.offset, let h = try? FileHandle(forReadingFrom: f) else { continue }
                defer { try? h.close() }
                try? h.seek(toOffset: cursor.offset)
                guard let data = try? h.readToEnd(), let lastNewline = data.lastIndex(of: 0x0A) else { continue }
                let chat = f.deletingPathExtension().lastPathComponent
                var start = data.startIndex
                while start <= lastNewline {
                    let end = data[start...lastNewline].firstIndex(of: 0x0A) ?? lastNewline
                    defer { start = end + 1 }
                    guard end > start,
                          let obj = try? JSONSerialization.jsonObject(with: data[start..<end]) as? [String: Any] else { continue }
                    if cursor.project == nil, let cwd = obj["cwd"] as? String { cursor.project = projects.label(forPath: cwd) }
                    guard let type = obj["type"] as? String, type == "user" || type == "assistant",
                          let ts = obj["timestamp"] as? String, let t = date(ts) else { continue }
                    let project = cursor.project ?? (obj["cwd"] as? String).map(projects.label(forPath:)) ?? "Chat"
                    out.append(ActivityBlock(start: t, end: t, projects: [project: 1], messages: 1, chats: [chat]))
                }
                cursor.offset += UInt64(lastNewline - data.startIndex + 1)
                cursors[f.path] = cursor
            }
        }
        return out
    }

    // MARK: Commits

    private static func readCommits(projects: ProjectMap, since: inout Date?) -> [ActivityBlock] {
        let floor = since ?? Date().addingTimeInterval(-60 * 86400)
        var out: [ActivityBlock] = []
        var newest = since
        for (label, path) in projects.repos {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", path, "log", "--all", "--format=%ct", "--since=@\(Int(floor.timeIntervalSince1970))"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { continue }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { continue }
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                guard let secs = Double(line) else { continue }
                let t = Date(timeIntervalSince1970: secs)
                if let since, t <= since { continue }
                newest = max(newest ?? t, t)
                out.append(ActivityBlock(start: t, end: t, projects: [label: 0], commits: 1))
            }
        }
        since = newest ?? since
        return out
    }
}

/// Maps a folder to a project name from ~/gears_OS/projects.json ("GNotch · Mac notch" → "GNotch").
struct ProjectMap {
    /// (label, absolute path), longest path first.
    var repos: [(String, String)] = []
    let dayChat: String

    init(file: URL) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        dayChat = home + "/Gears_projects"
        guard let data = try? Data(contentsOf: file),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["projects"] as? [[String: Any]] else { return }
        for p in list {
            guard let local = p["local"] as? String else { continue }
            let path = local.hasPrefix("~") ? home + local.dropFirst() : local
            let name = (p["name"] as? String ?? p["id"] as? String ?? (path as NSString).lastPathComponent)
            let label = name.components(separatedBy: " · ").first ?? name
            repos.append((label, path))
        }
        repos.sort { $0.1.count > $1.1.count }
    }

    func label(forPath raw: String) -> String {
        // Worktrees live inside their repo: …/repo/.claude/worktrees/name
        let path = raw.components(separatedBy: "/.claude/worktrees/").first ?? raw
        if path == dayChat { return "Day chat" }
        if let hit = repos.first(where: { path == $0.1 || path.hasPrefix($0.1 + "/") }) { return hit.0 }
        if path.contains("/Claude/scratch-workspaces/") { return "Scratch" }
        let name = (path as NSString).lastPathComponent
        // A project's parent folder (umami-web holds umami-web/Umami_landing_page), when only one project is inside.
        let inside = Set(repos.filter { $0.1.hasPrefix(path + "/") }.map(\.0))
        if inside.count == 1 { return inside.first! }
        // A project that has moved since (~/Documents/coffee/Simulator_Frothing → Steam Lab).
        if let moved = repos.first(where: { ($0.1 as NSString).lastPathComponent == name }) { return moved.0 }
        return name
    }
}

/// Keeps `activity.json` current while GNotch runs: a scan at launch, then every 5 minutes.
@MainActor
final class ActivityTracker {
    private weak var store: SessionStore?
    private let fileURL: URL
    private var timer: Timer?
    private var scanning = false

    init(store: SessionStore, fileURL: URL = ActivityScanner.defaultFile) {
        self.store = store
        self.fileURL = fileURL
        if let saved = ActivityScanner.load(fileURL) { store.setAuto(saved.blocks) }
        scan()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scan() }
        }
    }

    func scan() {
        guard !scanning else { return }
        scanning = true
        let url = fileURL
        Task.detached(priority: .utility) {
            let blocks = ActivityScanner.scan(file: url)
            await MainActor.run { [weak self] in
                self?.scanning = false
                if !blocks.isEmpty { self?.store?.setAuto(blocks) }
            }
        }
    }
}

extension ActivityScanner {
    /// Dev check: `GNOTCH_ACTIVITY_CHECK=/tmp/activity.json .build/release/GNotch`.
    /// Scans the real transcripts and repos into that file (never the real one), scans again to
    /// prove the second pass adds nothing, checks that merging doesn't depend on order, then
    /// prints hours per day.
    static func check(file: URL) -> Bool {
        var ok = true
        func expect(_ name: String, _ pass: Bool) {
            print(pass ? "PASS" : "FAIL", name)
            ok = ok && pass
        }
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        func at(_ m: Double, _ p: String = "A") -> ActivityBlock {
            ActivityBlock(start: t0.addingTimeInterval(m * 60), end: t0.addingTimeInterval(m * 60), projects: [p: 1], messages: 1, chats: [p])
        }
        let points = [at(0), at(10, "B"), at(25), at(50), at(69, "B"), at(100)]
        let a = merge(points), b = merge(points.reversed())
        expect("merge: 0–25 and 50–69 joined, 100 alone", a.map { $0.duration / 60 } == [25, 19, 0])
        expect("merge: order doesn't matter", a.map(\.start) == b.map(\.start) && a.map(\.end) == b.map(\.end))
        expect("merge: parallel chats counted once", a[0].chats == ["A", "B"] && a[0].messages == 3)
        expect("merge: in two halves = all at once",
               merge(merge(Array(points.prefix(3))) + merge(Array(points.suffix(3)))).map(\.end) == a.map(\.end))

        let started = Date()
        let first = scan(file: file)
        print(String(format: "first scan: %d blocks in %.1f s", first.count, Date().timeIntervalSince(started)))
        let again = Date()
        let second = scan(file: file)
        print(String(format: "second scan: %.2f s", Date().timeIntervalSince(again)))
        // Chats still running may grow the newest block; everything older must be identical.
        let settled = { (bs: [ActivityBlock]) in bs.filter { $0.end < started.addingTimeInterval(-gap) } }
        expect("second scan adds nothing to settled blocks",
               settled(second) == settled(first) && settled(first).count > 0)

        let cal = Calendar.current
        let byDay = Dictionary(grouping: first.filter { $0.duration >= 60 }) { cal.startOfDay(for: $0.start) }
        let f = DateFormatter()
        f.dateFormat = "EEE d MMM"
        for day in byDay.keys.sorted() {
            let blocks = byDay[day]!.sorted { $0.start < $1.start }
            let spans = blocks.map { "\(Fmt.time.string(from: $0.start))–\(Fmt.time.string(from: $0.end))" }
            print(f.string(from: day), Fmt.hm(blocks.reduce(0) { $0 + $1.duration }), spans.joined(separator: " "))
        }
        return ok
    }
}
