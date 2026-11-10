import Foundation
import SwiftUI

/// Will this Mac stay awake? Read from `pmset`; `KeepAwakeControl` turns it on and off.
struct KeepAwakeStatus: Equatable {
    enum State: Equatable {
        /// A real `caffeinate` is holding the Mac awake.
        case on
        /// Only Claude is holding it, and only while a chat is working.
        case claudeOnly
        case off
        /// `pmset` couldn't be read: don't claim either way.
        case unknown
    }

    struct Holder: Equatable {
        var pid: Int
        var process: String
        var type: String
        var name: String
        var timeout: Int?
    }

    var state: State = .unknown
    /// When the `caffeinate` runs out. Nil means no limit, or not on.
    var ends: Date?
    /// Holding right now, but they can let go at any moment, so they don't count as on.
    var others: [String] = []
    /// `caffeinate -s` alone is ignored on battery.
    var caffeinateIgnoredOnBattery = false
    /// Every `caffeinate` holding an assertion, counted or not: what "Turn off" stops.
    var caffeinatePIDs: [Int] = []
    /// Nil if unknown.
    var onAC: Bool?
    var battery: String?

    static let unknown = KeepAwakeStatus()

    private static let idleTypes: Set<String> = ["PreventUserIdleSystemSleep", "NoIdleSleepAssertion"]
    private static let systemType = "PreventSystemSleep"
    private static let friendlyNames = ["sharingd": "Handoff", "powerd": "the display being on"]

    /// Parses `pmset -g assertions` and `pmset -g batt`.
    static func parse(assertions: String, power: String, now: Date = Date()) -> KeepAwakeStatus {
        var status = KeepAwakeStatus()
        if power.contains("'AC Power'") { status.onAC = true }
        if power.contains("'Battery Power'") { status.onAC = false }
        if let m = power.firstMatch(of: #/(\d+)%; ([^;]+);/#) { status.battery = "\(m.1)% \(m.2)" }
        guard assertions.contains("Assertion status") else { return status }

        let holders = parseHolders(assertions).filter { idleTypes.contains($0.type) || $0.type == systemType }
        let caffeinate = holders.filter { $0.process == "caffeinate" }
        // Power management only honours PreventSystemSleep on AC.
        let working = caffeinate.filter { idleTypes.contains($0.type) || status.onAC != false }
        let claude = holders.filter { $0.process.hasPrefix("Claude") }

        status.caffeinateIgnoredOnBattery = !caffeinate.isEmpty && working.isEmpty
        status.caffeinatePIDs = Array(Set(caffeinate.map(\.pid))).sorted()
        var seen = Set<String>()
        status.others = holders
            .filter { $0.process != "caffeinate" && !$0.process.hasPrefix("Claude") }
            .map { friendlyNames[$0.process] ?? $0.process }
            .filter { seen.insert($0).inserted }

        if !working.isEmpty {
            status.state = .on
            let timeouts = working.map(\.timeout)
            if !timeouts.contains(where: { $0 == nil }), let longest = timeouts.compactMap({ $0 }).max() {
                status.ends = now.addingTimeInterval(TimeInterval(longest))
            }
        } else {
            status.state = claude.isEmpty ? .off : .claudeOnly
        }
        return status
    }

    private static func parseHolders(_ text: String) -> [Holder] {
        var holders: [Holder] = []
        for line in text.components(separatedBy: .newlines) {
            if let m = line.firstMatch(of: #/^\s*pid (\d+)\((.+?)\): \[[^\]]*\] \S+ (\S+) named: "(.*)"/#) {
                holders.append(Holder(pid: Int(m.1) ?? 0, process: String(m.2), type: String(m.3), name: String(m.4)))
            } else if !holders.isEmpty, let m = line.firstMatch(of: #/Timeout will fire in (\d+) secs/#) {
                holders[holders.count - 1].timeout = Int(m.1)
            }
        }
        return holders
    }

    func timeLeft(_ now: Date = Date()) -> String? {
        ends.map { Fmt.hm(max(0, $0.timeIntervalSince(now))) }
    }
}

/// Turns keep-awake on and off with a real `caffeinate`, the same thing the chats run by hand.
enum KeepAwakeControl {
    static let changed = Notification.Name("GNotchKeepAwakeChanged")
    static let choices: [(short: String, long: String, hours: Int?)] = [
        ("1 h", "For 1 hour", 1), ("2 h", "For 2 hours", 2), ("4 h", "For 4 hours", 4),
        ("12 h", "For 12 hours", 12), ("No limit", "Until I turn it off", nil),
    ]
    /// Kept so Foundation reaps them when they end.
    @MainActor private static var running: [Process] = []

    /// Starts `caffeinate -is` (no idle sleep; no system sleep while on AC), after stopping the ones
    /// in `replacing`. It isn't tied to GNotch: it keeps going if GNotch quits or is reinstalled.
    @MainActor @discardableResult
    static func start(hours: Int?, replacing pids: [Int]) -> Bool {
        stop(pids, notify: false)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        p.arguments = ["-is"] + (hours.map { ["-t", String($0 * 3600)] } ?? [])
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { ended in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { running.removeAll { $0 === ended } }
                NotificationCenter.default.post(name: changed, object: nil)
            }
        }
        guard (try? p.run()) != nil else { return false }
        running.append(p)
        notifySoon()
        return true
    }

    /// Stops these `caffeinate` processes, whoever started them. Anything else is left alone.
    @MainActor
    static func stop(_ pids: [Int], notify: Bool = true) {
        for pid in pids where name(of: pid) == "caffeinate" { kill(pid_t(pid), SIGTERM) }
        if notify { notifySoon() }
    }

    /// pmset shows the change a moment later.
    private static func notifySoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    static func name(of pid: Int) -> String? {
        var buf = [CChar](repeating: 0, count: 256)
        guard proc_name(pid_t(pid), &buf, UInt32(buf.count)) > 0 else { return nil }
        return String(cString: buf)
    }
}

/// Reads the status only while the notch is open, every 30 s. Collapsed, it costs nothing.
@MainActor
final class KeepAwakeMonitor: ObservableObject {
    @Published private(set) var status = SnapshotHints.keepAwake ?? .unknown
    private var timer: Timer?
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(forName: KeepAwakeControl.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, SnapshotHints.keepAwake == nil else { return }
                self.refresh()
            }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func start() {
        guard SnapshotHints.keepAwake == nil, timer == nil else { return }
        refresh()
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        t.tolerance = 5
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let new = Self.readNow()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.status = new }
            }
        }
    }

    nonisolated static func readNow() -> KeepAwakeStatus {
        guard let assertions = pmset("assertions") else { return .unknown }
        return KeepAwakeStatus.parse(assertions: assertions, power: pmset("batt") ?? "")
    }

    nonisolated private static func pmset(_ what: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["-g", what]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

/// The cup in the top band: on, off, and the time left if there's room.
struct KeepAwakeBadge: View {
    @ObservedObject var monitor: KeepAwakeMonitor
    @Binding var hovering: Bool
    @Binding var tapped: Bool

    private var status: KeepAwakeStatus { monitor.status }

    private var tint: Color {
        switch status.state {
        case .on: return Heat.base
        case .claudeOnly: return .orange
        case .off, .unknown: return .secondary
        }
    }

    private var short: String {
        switch status.state {
        case .on: return "On"
        case .claudeOnly: return "Claude"
        case .off: return "Off"
        case .unknown: return "?"
        }
    }

    private var long: String {
        if status.state == .on, let left = status.timeLeft() { return "On \(left)" }
        return short
    }

    private func row(_ label: String?) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "cup.and.saucer.fill").font(.system(size: 10))
            if let label {
                Text(label).font(.system(size: 10.5, weight: .bold)).monospacedDigit().fixedSize()
            }
        }
    }

    var body: some View {
        Button {
            tapped.toggle()
            if tapped { monitor.refresh() }
        } label: {
            ViewThatFits(in: .horizontal) {
                row(long)
                row(short)
                row(nil)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 3)
            .frame(minHeight: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .onAppear { monitor.start() }
        .onDisappear {
            monitor.stop()
            hovering = false
            tapped = false
        }
        .accessibilityLabel("Keep awake: \(long)")
    }
}

/// What the cup means, on hover or tap. Tapped, it also turns keep-awake on and off.
struct KeepAwakeCard: View {
    let status: KeepAwakeStatus
    var interactive = false
    var onStart: (Int?) -> Void = { _ in }
    var onStop: () -> Void = {}

    private var headline: String {
        switch status.state {
        case .on: return "On: caffeinate is keeping the Mac awake"
        case .claudeOnly: return "Only while a chat is working: Claude is holding it"
        case .off: return "Off: nothing is set to keep the Mac awake"
        case .unknown: return "Couldn't read the Mac's state"
        }
    }

    private var timeLine: String? {
        guard status.state == .on else { return nil }
        guard let ends = status.ends, let left = status.timeLeft() else { return "No time limit" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE HH:mm"
        return "\(left) left, ends \(f.string(from: ends))"
    }

    private var charger: String {
        let source: String
        switch status.onAC {
        case true: source = "On AC"
        case false: source = "On battery"
        default: source = "Power source unknown"
        }
        return [source, status.battery].compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(headline).font(.system(size: 12, weight: .bold))
            if let timeLine { Text(timeLine).monospacedDigit() }
            Text(charger).monospacedDigit()
            if status.caffeinateIgnoredOnBattery {
                Text("caffeinate is running with -s only, which macOS ignores on battery.")
                    .foregroundStyle(.orange)
            }
            if !status.others.isEmpty {
                Text("Not counted, they can let go any time: \(status.others.joined(separator: ", "))")
                    .foregroundStyle(.secondary)
            }
            Divider()
            if interactive {
                controls
                Divider()
            } else {
                Text("Click the cup to turn it on or off.").foregroundStyle(.secondary)
            }
            Text("To drive chats from the phone: lid open (a closed lid still sleeps), Claude app open, Wi-Fi connected, charger in.")
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 11))
        .foregroundStyle(.white)
        .fixedSize(horizontal: false, vertical: true)
        .padding(10)
        .frame(width: 300, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.13)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.15)))
        .shadow(color: .black.opacity(0.5), radius: 10, y: 4)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(status.state == .on ? "Change it to:" : "Keep the Mac awake:").foregroundStyle(.secondary)
            HStack(spacing: 5) {
                ForEach(KeepAwakeControl.choices, id: \.short) { c in
                    pill(c.short, fill: Heat.base.opacity(0.22), text: Heat.base) { onStart(c.hours) }
                }
            }
            if !status.caffeinatePIDs.isEmpty {
                pill("Turn off", fill: Color.white.opacity(0.12), text: .white) { onStop() }
            }
        }
    }

    private func pill(_ title: String, fill: Color, text: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(text)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(fill))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
