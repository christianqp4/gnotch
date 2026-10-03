import Foundation

/// Persists sessions as JSON in ~/Library/Application Support/GNotch/sessions.json.
@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [DeepWorkSession] = []
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
        return out
    }

    func total(onDay day: Date) -> TimeInterval {
        let cal = Calendar.current
        return sessions.filter { cal.isDate($0.start, inSameDayAs: day) }.reduce(0) { $0 + $1.duration }
    }

    func total(since date: Date) -> TimeInterval {
        sessions.filter { $0.start >= date }.reduce(0) { $0 + $1.duration }
    }

    var totalAllTime: TimeInterval { sessions.reduce(0) { $0 + $1.duration } }

    /// Consecutive days with deep work, ending today (or yesterday if today has nothing yet).
    func streak() -> Int {
        let cal = Calendar.current
        let days = Set(sessions.map { cal.startOfDay(for: $0.start) })
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

    func csv() -> String {
        let iso = ISO8601DateFormatter()
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var lines = ["start,end,minutes,planned_minutes,task,intensity,tags,notes"]
        for s in sessions.reversed() {
            lines.append([
                iso.string(from: s.start), iso.string(from: s.end),
                String(format: "%.1f", s.minutes), s.plannedMinutes.map(String.init) ?? "",
                q(s.task), String(s.intensity), q(s.tags.joined(separator: "; ")), q(s.notes),
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
