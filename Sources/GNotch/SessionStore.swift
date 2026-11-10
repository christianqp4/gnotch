import Foundation

/// Persists sessions as JSON in ~/Library/Application Support/GNotch/sessions.json.
@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [DeepWorkSession] = []
    /// Auto blocks from chats and commits (`activity.json`). Shown and counted next to the manual
    /// blocks in Hours, never saved into `sessions.json`.
    @Published private(set) var autoBlocks: [ActivityBlock] = []
    let fileURL: URL

    private struct FileFormat: Codable {
        var version: Int
        var sessions: [DeepWorkSession]
    }

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            self.fileURL = AppPaths.base.appendingPathComponent("sessions.json")
        }
        load()
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let file = try? decoder.decode(FileFormat.self, from: data) {
            sessions = file.sessions.sorted { $0.start > $1.start }
        } else {
            // Never silently overwrite a file we can't read.
            let backup = fileURL.deletingLastPathComponent()
                .appendingPathComponent("sessions.unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.copyItem(at: fileURL, to: backup)
        }
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(FileFormat(version: 1, sessions: sessions)) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func add(_ s: DeepWorkSession) {
        sessions.insert(s, at: 0)
        sessions.sort { $0.start > $1.start }
        persist()
    }

    func update(_ s: DeepWorkSession) {
        guard let i = sessions.firstIndex(where: { $0.id == s.id }) else { return }
        sessions[i] = s
        persist()
    }

    func delete(_ id: UUID) {
        sessions.removeAll { $0.id == id }
        persist()
    }

    func setAuto(_ blocks: [ActivityBlock]) {
        let shown = blocks.filter { $0.duration >= 60 }
        if shown != autoBlocks { autoBlocks = shown }
    }

    // MARK: Auto time

    /// Auto blocks that started on `day`, earliest first.
    func autoBlocks(on day: Date) -> [ActivityBlock] {
        let cal = Calendar.current
        return autoBlocks.filter { cal.isDate($0.start, inSameDayAs: day) }
    }

    /// Time in auto blocks starting in [from, to) that no manual block (or the live block) covers,
    /// so a block timed during a chat is counted once.
    func autoExtra(from: Date, to: Date = .distantFuture, liveSince: Date? = nil) -> TimeInterval {
        let blocks = autoBlocks.filter { $0.start >= from && $0.start < to }
        guard !blocks.isEmpty else { return 0 }
        var covered = sessions.filter { $0.end > blocks[0].start }.map { ($0.start, $0.end) }
        if let liveSince { covered.append((liveSince, Date())) }
        return blocks.reduce(0) { $0 + Self.uncovered($1.start, $1.end, by: covered) }
    }

    private static func uncovered(_ start: Date, _ end: Date, by spans: [(Date, Date)]) -> TimeInterval {
        var cuts = spans.filter { $0.1 > start && $0.0 < end }
            .map { (max($0.0, start), min($0.1, end)) }
            .sorted { $0.0 < $1.0 }
        var covered: TimeInterval = 0
        var cursor = start
        while !cuts.isEmpty {
            let c = cuts.removeFirst()
            let a = max(c.0, cursor)
            if c.1 > a { covered += c.1.timeIntervalSince(a); cursor = c.1 }
        }
        return max(0, end.timeIntervalSince(start) - covered)
    }

    // MARK: Stats

    func dayStats() -> [Date: DayStat] {
        let cal = Calendar.current
        var out: [Date: DayStat] = [:]
        for s in sessions {
            let key = cal.startOfDay(for: s.start)
            var d = out[key, default: DayStat()]
            d.minutes += s.minutes
            d.weighted += s.minutes * Double(s.intensity) / 5
            d.intensityMinutes += s.minutes * Double(s.intensity)
            d.count += 1
            out[key] = d
        }
        // Auto time beyond the manual blocks counts in Hours only (it has no intensity).
        for key in Set(autoBlocks.map { cal.startOfDay(for: $0.start) }) {
            let extra = autoExtra(from: key, to: cal.date(byAdding: .day, value: 1, to: key)!)
            if extra >= 60 { out[key, default: DayStat()].autoMinutes = extra / 60 }
        }
        return out
    }

    /// Blocks that started on `day`, earliest first.
    func blocks(on day: Date) -> [DeepWorkSession] {
        let cal = Calendar.current
        return sessions.filter { cal.isDate($0.start, inSameDayAs: day) }.sorted { $0.start < $1.start }
    }

    /// Manual blocks plus the auto time they don't cover. `liveSince`: a block being timed now,
    /// so its stretch of auto time isn't counted twice.
    func total(onDay day: Date, liveSince: Date? = nil) -> TimeInterval {
        let cal = Calendar.current
        let start = cal.startOfDay(for: day)
        return sessions.filter { cal.isDate($0.start, inSameDayAs: day) }.reduce(0) { $0 + $1.duration }
            + autoExtra(from: start, to: cal.date(byAdding: .day, value: 1, to: start)!, liveSince: liveSince)
    }

    func total(since date: Date, liveSince: Date? = nil) -> TimeInterval {
        sessions.filter { $0.start >= date }.reduce(0) { $0 + $1.duration } + autoExtra(from: date, liveSince: liveSince)
    }

    var totalAllTime: TimeInterval { sessions.reduce(0) { $0 + $1.duration } + autoExtra(from: .distantPast) }

    /// Consecutive days with deep work (timed or auto), ending today (or yesterday if today has nothing yet).
    func streak() -> Int {
        let cal = Calendar.current
        let days = Set(sessions.map { cal.startOfDay(for: $0.start) } + autoBlocks.map { cal.startOfDay(for: $0.start) })
        var day = cal.startOfDay(for: Date())
        if !days.contains(day) { day = cal.date(byAdding: .day, value: -1, to: day)! }
        var n = 0
        while days.contains(day) {
            n += 1
            day = cal.date(byAdding: .day, value: -1, to: day)!
        }
        return n
    }

    func avgIntensity(lastDays: Int) -> Double? {
        let since = Calendar.current.date(byAdding: .day, value: -lastDays, to: Date())!
        let recent = sessions.filter { $0.start >= since }
        let mins = recent.reduce(0) { $0 + $1.minutes }
        guard mins > 0 else { return nil }
        return recent.reduce(0) { $0 + $1.minutes * Double($1.intensity) } / mins
    }

    /// Drifts per focused hour, over blocks timed with drift tracking.
    func driftsPerHour(lastDays: Int) -> Double? {
        let since = Calendar.current.date(byAdding: .day, value: -lastDays, to: Date())!
        let tracked = sessions.filter { $0.start >= since && $0.pauses != nil }
        let hours = tracked.reduce(0) { $0 + $1.duration } / 3600
        guard hours > 0.25 else { return nil }
        return Double(tracked.reduce(0) { $0 + $1.drifts }) / hours
    }

    func csv() -> String {
        let iso = ISO8601DateFormatter()
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var lines = ["start,end,minutes,planned_minutes,task,intensity,tags,notes,drifts,paused_minutes,location"]
        for s in sessions.reversed() {
            lines.append([
                iso.string(from: s.start), iso.string(from: s.end),
                String(format: "%.1f", s.minutes), s.plannedMinutes.map(String.init) ?? "",
                q(s.task), String(s.intensity), q(s.tags.joined(separator: "; ")), q(s.notes),
                s.pauses == nil ? "" : String(s.drifts), s.pauses == nil ? "" : String(format: "%.1f", s.pausedTime / 60),
                q(s.location ?? ""),
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
