import AppKit

/// The deep work timer. Survives app restarts by snapshotting itself to UserDefaults.
@MainActor
final class TimerEngine: ObservableObject {
    enum Phase: String, Codable { case idle, running, paused, finishing }

    @Published private(set) var phase: Phase = .idle
    @Published var task: String = "" { didSet { persist() } }
    @Published var plannedMinutes: Int? = 50 {
        didSet {
            UserDefaults.standard.set(plannedMinutes ?? 0, forKey: "plannedMinutes")
            persist()
        }
    }
    @Published private(set) var now = Date()

    private(set) var startDate: Date?
    private(set) var endDate: Date?
    private var accumulated: TimeInterval = 0
    private var segmentStart: Date?
    private var goalNotified = false
    private var ticker: Timer?

    let store: SessionStore
    var onGoalReached: (() -> Void)?
    /// False for throwaway engines (snapshots) so they never touch the real saved timer.
    private let persistsState: Bool

    init(store: SessionStore, persistsState: Bool = true) {
        self.store = store
        self.persistsState = persistsState
        guard persistsState else { return }
        if UserDefaults.standard.object(forKey: "plannedMinutes") != nil {
            let v = UserDefaults.standard.integer(forKey: "plannedMinutes")
            plannedMinutes = v > 0 ? v : nil
        }
        restore()
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.pause() }
        }
    }

    // MARK: Derived

    var elapsed: TimeInterval {
        accumulated + (segmentStart.map { max(0, now.timeIntervalSince($0)) } ?? 0)
    }
    var goal: TimeInterval? { plannedMinutes.map { Double($0) * 60 } }
    var progress: Double {
        guard let g = goal, g > 0 else { return 0 }
        return min(1, elapsed / g)
    }
    var isOvertime: Bool { goal.map { elapsed >= $0 } ?? false }
    var isActive: Bool { phase == .running || phase == .paused }

    /// Countdown while under the goal, "+overtime" after it, count-up when open-ended.
    var displayTime: String {
        guard let g = goal else { return Fmt.clock(elapsed) }
        let remaining = g - elapsed
        return remaining > 0 ? Fmt.clock(remaining.rounded(.up)) : "+" + Fmt.clock(-remaining)
    }

    // MARK: Actions

    func start() {
        guard phase == .idle else { return }
        let t = Date()
        startDate = t
        now = t
        accumulated = 0
        segmentStart = t
        goalNotified = false
        phase = .running
        startTicker()
        persist()
        sound(.start)
    }

    func start(minutes: Int?) {
        plannedMinutes = minutes
        start()
    }

    func pause() {
        guard phase == .running else { return }
        now = Date()
        accumulated = elapsed
        segmentStart = nil
        phase = .paused
        stopTicker()
        persist()
        sound(.pause)
    }

    func resume() {
        guard phase == .paused else { return }
        now = Date()
        segmentStart = now
        phase = .running
        startTicker()
        persist()
        sound(.resume)
    }

    func togglePause() { phase == .running ? pause() : resume() }

    /// Stops the clock and asks for intensity + notes.
    func finish() {
        guard isActive else { return }
        now = Date()
        accumulated = elapsed
        segmentStart = nil
        endDate = now
        phase = .finishing
        stopTicker()
        persist()
    }

    func save(task: String, intensity: Int, tags: [String], notes: String) {
        guard phase == .finishing, let start = startDate else { return }
        store.add(DeepWorkSession(
            start: start,
            end: endDate ?? Date(),
            duration: accumulated,
            plannedMinutes: plannedMinutes,
            task: task.trimmingCharacters(in: .whitespacesAndNewlines),
            intensity: Intensity.clamp(intensity),
            tags: tags,
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines)
        ))
        reset()
        sound(.saved)
    }

    func discard() { reset() }

    /// Throwaway engines (snapshots) stay silent.
    private func sound(_ e: Sounds.Event) {
        if persistsState { Sounds.play(e) }
    }

    private func reset() {
        stopTicker()
        startDate = nil
        endDate = nil
        accumulated = 0
        segmentStart = nil
        goalNotified = false
        phase = .idle
        task = ""
        persist()
    }

    /// Pretend the running block started `seconds` ago (snapshots only).
    func simulate(elapsed seconds: TimeInterval) {
        guard isActive else { return }
        now = Date()
        startDate = now.addingTimeInterval(-seconds)
        if phase == .running { segmentStart = startDate; accumulated = 0 } else { accumulated = seconds }
    }

    // MARK: Ticking

    private func startTicker() {
        ticker?.invalidate()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func tick() {
        now = Date()
        if !goalNotified, isOvertime {
            goalNotified = true
            persist()
            sound(.goal)
            onGoalReached?()
        }
    }

    // MARK: Snapshot

    private struct Snapshot: Codable {
        var phase: Phase
        var task: String
        var start: Date?
        var end: Date?
        var accumulated: TimeInterval
        var segmentStart: Date?
        var goalNotified: Bool
    }

    private static let snapshotKey = "activeTimer"

    private func persist() {
        guard persistsState else { return }
        let d = UserDefaults.standard
        guard phase != .idle else {
            d.removeObject(forKey: Self.snapshotKey)
            return
        }
        let snap = Snapshot(phase: phase, task: task, start: startDate, end: endDate,
                            accumulated: accumulated, segmentStart: segmentStart, goalNotified: goalNotified)
        d.set(try? JSONEncoder().encode(snap), forKey: Self.snapshotKey)
    }

    private func restore() {
        guard let data = UserDefaults.standard.data(forKey: Self.snapshotKey),
              let s = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        task = s.task
        startDate = s.start
        endDate = s.end
        accumulated = s.accumulated
        segmentStart = s.segmentStart
        goalNotified = s.goalNotified
        now = Date()
        phase = s.phase
        if phase == .running { startTicker() }
    }
}
