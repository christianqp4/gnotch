import Foundation
import SwiftUI

/// One finished deep work block. This is the unit stored in `sessions.json`.
struct DeepWorkSession: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var start: Date
    var end: Date
    /// Active seconds, excluding pauses.
    var duration: TimeInterval
    /// Planned block length in minutes, nil for open-ended blocks.
    var plannedMinutes: Int?
    var task: String
    /// 1 (shallow) ... 5 (flow).
    var intensity: Int
    var tags: [String]
    var notes: String
    /// Added by hand after the fact rather than timed.
    var manual: Bool? = nil
    /// Pauses during the block. Each manual pause is a drift: attention slipped, you stopped to reset.
    /// nil for blocks logged before drift tracking or added by hand.
    var pauses: [PauseSpan]? = nil

    var drifts: Int { pauses?.filter { $0.auto != true }.count ?? 0 }
    var pausedTime: TimeInterval { pauses?.reduce(0) { $0 + $1.duration } ?? 0 }

    var minutes: Double { duration / 60 }
    var displayTask: String { task.isEmpty ? "Deep work" : task }
}

/// A pause inside a block.
struct PauseSpan: Codable, Hashable {
    var start: Date
    var end: Date
    /// true when the Mac paused it (going to sleep), not you. Not counted as a drift.
    var auto: Bool?

    var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }
}

enum Intensity {
    static let labels = ["Shallow", "Light", "Focused", "Deep", "Flow"]
    static let colors: [Color] = [
        Color(red: 0.95, green: 0.80, blue: 0.30),
        Color(red: 0.98, green: 0.68, blue: 0.24),
        Color(red: 1.00, green: 0.55, blue: 0.20),
        Color(red: 1.00, green: 0.42, blue: 0.18),
        Color(red: 0.98, green: 0.28, blue: 0.20),
    ]

    static func clamp(_ v: Int) -> Int { max(1, min(5, v)) }
    static func label(_ v: Int) -> String { labels[clamp(v) - 1] }
    static func color(_ v: Int) -> Color { colors[clamp(v) - 1] }
}

enum SensationTags {
    static let all = ["Flow", "Energized", "Calm", "Clear-headed", "Distracted", "Tired", "Restless", "Breakthrough"]
}

/// Aggregated stats for one calendar day.
struct DayStat {
    var minutes: Double = 0
    /// Minutes weighted by intensity (minutes × intensity / 5).
    var weighted: Double = 0
    /// Sum of intensity × minutes, used for a duration-weighted average.
    var intensityMinutes: Double = 0
    var count = 0

    var avgIntensity: Double { minutes > 0 ? intensityMinutes / minutes : 0 }
}

enum HeatMetric: String, CaseIterable, Identifiable {
    case score = "Deep score"
    case hours = "Hours"
    case intensity = "Intensity"

    var id: String { rawValue }

    var explanation: String {
        switch self {
        case .score: return "Minutes weighted by intensity: 1h at Flow (5) counts 60, 1h at Light (2) counts 24."
        case .hours: return "Total deep work time per day."
        case .intensity: return "Average intensity per day, weighted by block length."
        }
    }

    /// Bucket a day into 0 (nothing) ... 4 (max).
    func level(_ s: DayStat?) -> Int {
        guard let s, s.count > 0 else { return 0 }
        switch self {
        case .hours:
            return s.minutes < 45 ? 1 : s.minutes < 120 ? 2 : s.minutes < 240 ? 3 : 4
        case .score:
            return s.weighted < 30 ? 1 : s.weighted < 90 ? 2 : s.weighted < 180 ? 3 : 4
        case .intensity:
            return max(1, min(4, Int(s.avgIntensity.rounded()) - 1))
        }
    }
}

enum Heat {
    static let base = Color(red: 0.16, green: 0.76, blue: 0.43)
    static func color(_ level: Int) -> Color {
        guard level > 0 else { return Color.primary.opacity(0.08) }
        return base.opacity([0.30, 0.52, 0.76, 1.0][min(level, 4) - 1])
    }
}

enum Fmt {
    /// 05:12 or 1:05:12
    static func clock(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        let h = s / 3600, m = s % 3600 / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
    }

    /// 45m, 2h, 2h 10m
    static func hm(_ t: TimeInterval) -> String {
        let m = Int((t / 60).rounded())
        if m < 60 { return "\(m)m" }
        return m % 60 == 0 ? "\(m / 60)h" : "\(m / 60)h \(m % 60)m"
    }

    static let time: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    static let day: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEEdMMMMyyyy")
        return f
    }()

    static let shortDay: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEdMMM")
        return f
    }()
}
