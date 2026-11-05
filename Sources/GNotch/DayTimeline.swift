import AppKit
import Darwin
import SwiftUI

/// One moment in the Mac's day: it was switched on, woke, slept, its display went on or off,
/// or a watched app was launched.
struct DayEvent: Codable, Hashable, Identifiable {
    enum Kind: String, Codable {
        case boot, login, wake, sleep, displayOn, displayOff, shutdown, launch, quit

        /// The Mac (or its screen) came on.
        var isOn: Bool { [.boot, .login, .wake, .displayOn].contains(self) }
        var isOff: Bool { [.sleep, .displayOff, .shutdown].contains(self) }
    }

    var date: Date
    var kind: Kind
    /// App name, for launch and quit.
    var app: String?

    var id: String { "\(kind.rawValue)-\(app ?? "")-\(Int(date.timeIntervalSince1970))" }

    var label: String {
        switch kind {
        case .boot: return "Switched on"
        case .login: return "Logged in"
        case .wake: return "Woke"
        case .sleep: return "Slept"
        case .displayOn: return "Screen on"
        case .displayOff: return "Screen off"
        case .shutdown: return "Shut down"
        case .launch: return "\(app ?? "App") opened"
        case .quit: return "\(app ?? "App") quit"
        }
    }
}

/// Today's timeline. macOS Screen Time doesn't show when the Mac or an app was first opened,
/// so GNotch logs it itself (`timeline.jsonl`, one event per line) and fills in the hours
/// before it started from the system: boot, shutdown and console logins from wtmp, display
/// and sleep/wake from `pmset -g log`, and the launch date of watched apps still running.
@MainActor
final class TimelineStore: ObservableObject {
    @Published private(set) var events: [DayEvent] = []

    /// Bundle ids whose launches are shown. Claude first; more via `defaults write … timelineApps`.
    static let defaultApps = ["com.anthropic.claudefordesktop"]
    var watched: [String] { UserDefaults.standard.stringArray(forKey: "timelineApps") ?? Self.defaultApps }

    private let fileURL: URL?
    private var logged: [DayEvent] = []
    private var system: [DayEvent] = []
    private var pmset: [DayEvent] = []
    private var pmsetDay: Date?
    private var pmsetReadAt = Date.distantPast
    private var observers: [Any] = []

    init(fileURL: URL? = AppPaths.base.appendingPathComponent("timeline.jsonl")) {
        self.fileURL = fileURL
        logged = Self.load(fileURL)
        observe()
        refresh()
    }

    /// Snapshots: fixed events, no files, no notifications.
    init(sample: [DayEvent]) {
        fileURL = nil
        events = sample.sorted { $0.date < $1.date }
    }

    // MARK: Summary

    /// The first time the Mac came on today (boot, login, wake or screen on).
    var firstOpen: Date? { events.first { $0.kind.isOn }?.date }

    /// Still on from yesterday: today's first event switched something off.
    var onAtMidnight: Bool { events.first.map { $0.kind.isOff } ?? false }

    /// The first launch today of each watched app that has one.
    var firstLaunches: [DayEvent] {
        var seen = Set<String>()
        return events.filter { $0.kind == .launch && seen.insert($0.app ?? "").inserted }
    }

    // MARK: Reading

    func refresh() {
        guard fileURL != nil else { return }
        let day = Calendar.current.startOfDay(for: Date())
        system = Self.wtmpEvents(since: day) + runningApps(since: day)
        merge()
        // pmset's log is a few MB; read it at most every 10 minutes, off the main thread.
        if pmsetDay != day || Date().timeIntervalSince(pmsetReadAt) > 600 {
            pmsetReadAt = Date()
            Task.detached(priority: .utility) {
                let found = Self.pmsetEvents(since: day)
                await MainActor.run {
                    self.pmset = found
                    self.pmsetDay = day
                    self.merge()
                }
            }
        }
    }

    private func merge() {
        let day = Calendar.current.startOfDay(for: Date())
        let all = (logged + system + pmset).filter { $0.date >= day && $0.date <= Date().addingTimeInterval(60) }
            .sorted { $0.date < $1.date }
        // The same moment often comes from two sources (GNotch's log and pmset, or a launch
        // seen live and by launchDate). Keep the first within two minutes.
        var kept: [DayEvent] = []
        for e in all where !kept.contains(where: { $0.kind == e.kind && $0.app == e.app
                                                   && abs($0.date.timeIntervalSince(e.date)) < 120 }) {
            kept.append(e)
        }
        events = kept
    }

    // MARK: Logging

    private func observe() {
        let center = NSWorkspace.shared.notificationCenter
        let simple: [(Notification.Name, DayEvent.Kind)] = [
            (NSWorkspace.didWakeNotification, .wake), (NSWorkspace.willSleepNotification, .sleep),
            (NSWorkspace.screensDidWakeNotification, .displayOn), (NSWorkspace.screensDidSleepNotification, .displayOff),
            (NSWorkspace.willPowerOffNotification, .shutdown),
        ]
        for (name, kind) in simple {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.record(DayEvent(date: Date(), kind: kind)) }
            })
        }
        for (name, kind) in [(NSWorkspace.didLaunchApplicationNotification, DayEvent.Kind.launch),
                             (NSWorkspace.didTerminateApplicationNotification, .quit)] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                let id = app?.bundleIdentifier, name = app?.localizedName
                MainActor.assumeIsolated {
                    guard let self, let id, self.watched.contains(id) else { return }
                    self.record(DayEvent(date: Date(), kind: kind, app: name))
                }
            })
        }
    }

    private func record(_ e: DayEvent) {
        logged.append(e)
        if let fileURL, let line = try? Self.encoder.encode(e) {
            if let h = try? FileHandle(forWritingTo: fileURL) {
                h.seekToEndOfFile()
                h.write(line + Data([0x0A]))
                try? h.close()
            } else {
                try? (line + Data([0x0A])).write(to: fileURL)
            }
        }
        // A wake starts a new stretch: re-read the system sources too.
        if e.kind == .wake { pmsetReadAt = .distantPast }
        refresh()
    }

    // Seconds only, like sessions.json.
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static func load(_ url: URL?) -> [DayEvent] {
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        let since = Calendar.current.date(byAdding: .day, value: -1, to: Calendar.current.startOfDay(for: Date()))!
        return text.split(separator: "\n").compactMap { try? d.decode(DayEvent.self, from: Data($0.utf8)) }
            .filter { $0.date >= since }
    }

    // MARK: System sources

    private func runningApps(since day: Date) -> [DayEvent] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard let id = app.bundleIdentifier, watched.contains(id),
                  let at = app.launchDate, at >= day else { return nil }
            return DayEvent(date: at, kind: .launch, app: app.localizedName)
        }
    }

    /// Boots, shutdowns and console logins, the records `last` prints.
    nonisolated static func wtmpEvents(since day: Date) -> [DayEvent] {
        var out: [DayEvent] = []
        setutxent_wtmp(1)
        defer { endutxent_wtmp() }
        while let p = getutxent_wtmp() {
            var u = p.pointee
            let date = Date(timeIntervalSince1970: TimeInterval(u.ut_tv.tv_sec))
            guard date >= day else { continue }
            let line = withUnsafeBytes(of: &u.ut_line) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            switch Int32(u.ut_type) {
            case BOOT_TIME: out.append(DayEvent(date: date, kind: .boot))
            case SHUTDOWN_TIME: out.append(DayEvent(date: date, kind: .shutdown))
            case USER_PROCESS where line == "console": out.append(DayEvent(date: date, kind: .login))
            default: break
            }
        }
        return out
    }

    /// "Display is turned on/off" notifications and Sleep / Wake entries (not DarkWake).
    nonisolated static func pmsetEvents(since day: Date) -> [DayEvent] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["-g", "log"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()

        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        let prefix = String(f.string(from: day).prefix(10))
        var out: [DayEvent] = []
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") where line.hasPrefix(prefix) {
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4, let date = f.date(from: parts[0...2].joined(separator: " ")) else { continue }
            let rest = parts[3]
            let kind: DayEvent.Kind?
            if rest.hasPrefix("Notification"), rest.contains("Display is turned on") { kind = .displayOn }
            else if rest.hasPrefix("Notification"), rest.contains("Display is turned off") { kind = .displayOff }
            else if rest.hasPrefix("Sleep ") { kind = .sleep }
            else if rest.hasPrefix("Wake ") { kind = .wake }
            else { kind = nil }
            if let kind, date >= day { out.append(DayEvent(date: date, kind: kind)) }
        }
        return out
    }
}

// MARK: Views

/// One line under the heatmap: when the Mac and the watched apps were first opened today,
/// and a 24-hour strip of when it was on. Hover it for the full list.
struct TodayLine: View {
    @ObservedObject var timeline: TimelineStore
    @Binding var hovering: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock")
            Text(summary).monospacedDigit().lineLimit(1)
            Spacer(minLength: 8)
            DayStrip(events: timeline.events)
                .frame(width: 120)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onAppear { timeline.refresh() }
    }

    private var summary: String {
        var parts: [String] = []
        if timeline.onAtMidnight { parts.append("On past midnight") }
        if let t = timeline.firstOpen { parts.append("\(parts.isEmpty ? "Opened" : "opened") \(Fmt.time.string(from: t))") }
        if parts.isEmpty { parts.append("Nothing logged yet today") }
        parts += timeline.firstLaunches.map { "\($0.app ?? "App") \(Fmt.time.string(from: $0.date))" }
        return parts.joined(separator: " · ")
    }
}

/// Midnight to midnight: green where the Mac was on, white ticks where a watched app opened.
struct DayStrip: View {
    let events: [DayEvent]
    var height: CGFloat = 6

    var body: some View {
        let day = Calendar.current.startOfDay(for: Date())
        let now = Date()
        GeometryReader { g in
            let x = { (d: Date) in g.size.width * min(1, max(0, d.timeIntervalSince(day) / 86_400)) }
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.white.opacity(0.08))
                ForEach([6, 12, 18], id: \.self) { h in
                    Rectangle().fill(Color.white.opacity(0.18)).frame(width: 1)
                        .offset(x: g.size.width * CGFloat(h) / 24)
                }
                ForEach(Self.onSpans(events, now: now).indices, id: \.self) { i in
                    let s = Self.onSpans(events, now: now)[i]
                    Rectangle().fill(Heat.base.opacity(0.85))
                        .frame(width: max(2, x(s.end) - x(s.start)))
                        .offset(x: x(s.start))
                }
                ForEach(events.filter { $0.kind == .launch }) { e in
                    Rectangle().fill(Color.white).frame(width: 2)
                        .offset(x: x(e.date) - 1)
                }
                Rectangle().fill(Color.white.opacity(0.5)).frame(width: 1, height: height + 4)
                    .offset(x: x(now))
            }
        }
        .frame(height: height)
        .clipShape(Capsule())
        .help("Today, midnight to midnight: green while the Mac was on, white where an app opened")
    }

    /// Stretches between something coming on and something going off.
    static func onSpans(_ events: [DayEvent], now: Date) -> [(start: Date, end: Date)] {
        let day = Calendar.current.startOfDay(for: now)
        var spans: [(start: Date, end: Date)] = []
        var since: Date? = events.first.map { $0.kind.isOff } == true ? day : nil
        for e in events {
            if e.kind.isOn, since == nil { since = e.date }
            if e.kind.isOff, let s = since { spans.append((s, e.date)); since = nil }
        }
        if let s = since { spans.append((s, now)) }
        return spans
    }
}

/// The hovered timeline, in the right-hand column where the week stats usually are.
struct TimelineBrief: View {
    let events: [DayEvent]

    var body: some View {
        let shown = Self.condensed(events)
        VStack(alignment: .trailing, spacing: 3) {
            Text("Today's timeline").foregroundStyle(.primary)
            if shown.isEmpty { Text("Nothing logged yet") }
            ForEach(shown.indices, id: \.self) { i in
                if let e = shown[i] {
                    HStack(spacing: 6) {
                        Text(e.label).foregroundStyle(e.kind == .launch ? Color.primary : Color.secondary)
                        Text(Fmt.time.string(from: e.date)).monospacedDigit()
                            .foregroundStyle(e.kind.isOn ? Heat.base : Color.secondary)
                    }
                } else {
                    Text("⋯").foregroundStyle(.tertiary)
                }
            }
        }
    }

    /// At most six lines: the earliest event, a gap, then the latest ones. A screen coming on
    /// right after a boot or login says nothing new, so it is left out.
    static func condensed(_ events: [DayEvent]) -> [DayEvent?] {
        var list: [DayEvent] = []
        for e in events {
            if e.kind == .displayOn, let last = list.last, [.boot, .login].contains(last.kind),
               e.date.timeIntervalSince(last.date) < 180 { continue }
            list.append(e)
        }
        guard list.count > 6 else { return list }
        return [list[0], nil] + list.suffix(4)
    }
}
