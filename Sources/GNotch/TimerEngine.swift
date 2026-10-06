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
    /// Finished pauses in the current block, and the one in progress.
    @Published private(set) var pauses: [PauseSpan] = []
    @Published private(set) var pauseStart: Date?
    private var pauseIsAuto = false
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
            MainActor.assumeIsolated { self?.pause(auto: true) }
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

    /// Pausing is how you flag a drift. `auto` is the Mac going to sleep, which isn't one.
    func pause(auto: Bool = false) {
        guard phase == .running else { return }
        now = Date()
        accumulated = elapsed
        segmentStart = nil
        pauseStart = now
        pauseIsAuto = auto
        phase = .paused
        persist()
        if !auto { sound(.pause) }
    }

    func resume() {
        guard phase == .paused else { return }
        now = Date()
        closePause()
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
        closePause()
        endDate = now
        phase = .finishing
        stopTicker()
        persist()
    }

    func save(task: String, intensity: Int, tags: [String], notes: String, location: String?) {
        guard phase == .finishing, let start = startDate else { return }
        store.add(DeepWorkSession(
            start: start,
            end: endDate ?? Date(),
            duration: accumulated,
            plannedMinutes: plannedMinutes,
            task: task.trimmingCharacters(in: .whitespacesAndNewlines),
            intensity: Intensity.clamp(intensity),
            tags: tags,
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
            pauses: pauses,
            location: location
        ))
        Places.remember(location)
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
        pauses = []
        pauseStart = nil
        pauseIsAuto = false
        phase = .idle
        task = ""
        persist()
    }

    /// Drifts so far, including a pause in progress.
    var drifts: Int {
        pauses.filter { $0.auto != true }.count + (pauseStart != nil && !pauseIsAuto ? 1 : 0)
    }

    /// Time spent paused so far, including a pause in progress.
    var pausedTime: TimeInterval {
        pauses.reduce(0) { $0 + $1.duration } + (pauseStart.map { max(0, now.timeIntervalSince($0)) } ?? 0)
    }

    private func closePause() {
        guard let ps = pauseStart else { return }
        pauses.append(PauseSpan(start: ps, end: now, auto: pauseIsAuto ? true : nil))
        pauseStart = nil
        pauseIsAuto = false
    }

    /// Fake earlier drifts (snapshots only). Offsets are seconds after the block started.
    func simulate(drifts: [(at: TimeInterval, length: TimeInterval)]) {
        guard let start = startDate else { return }
        pauses = drifts.map { PauseSpan(start: start.addingTimeInterval($0.at),
                                        end: start.addingTimeInterval($0.at + $0.length)) }
    }

    /// Pretend the running block started `seconds` ago (snapshots only).
    func simulate(elapsed seconds: TimeInterval) {
        guard isActive else { return }
        now = Date()
        startDate = now.addingTimeInterval(-seconds)
        if phase == .running { segmentStart = startDate; accumulated = 0 } else { accumulated = seconds }
        if phase == .paused { pauseStart = now.addingTimeInterval(-42) }
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
        // Optional so a timer saved by an older version still restores.
        var pauses: [PauseSpan]?
        var pauseStart: Date?
        var pauseIsAuto: Bool?
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
                            accumulated: accumulated, segmentStart: segmentStart, goalNotified: goalNotified,
                            pauses: pauses, pauseStart: pauseStart, pauseIsAuto: pauseIsAuto)
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
        pauses = s.pauses ?? []
        pauseStart = s.pauseStart ?? (s.phase == .paused ? Date() : nil)
        pauseIsAuto = s.pauseIsAuto ?? false
        now = Date()
        phase = s.phase
        if isActive { startTicker() }
    }
}
