import SwiftUI

/// The big timer page (⤢): everything for the day without opening the dashboard.
struct LargeIdleView: View {
    @ObservedObject var engine: TimerEngine
    @ObservedObject var store: SessionStore
    @ObservedObject var ambient: AmbientPlayer
    let openLog: () -> Void
    let addPast: () -> Void
    @AppStorage("heatMetric") private var metricRaw = HeatMetric.score.rawValue

    private let presets: [Int?] = [25, 50, 90, 120, nil]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 22) {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("What will you go deep on?", text: $engine.task)
                        .textFieldStyle(.plain)
                        .font(.system(size: 17, weight: .medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.08)))
                        .onSubmit { engine.start() }

                    HStack(spacing: 6) {
                        ForEach(presets, id: \.self) { m in
                            let on = engine.plannedMinutes == m
                            Button { engine.plannedMinutes = m } label: {
                                Text(m.map { "\($0)m" } ?? "∞")
                                    .font(.system(size: 12, weight: .semibold))
                                    .frame(minWidth: 40)
                                    .padding(.vertical, 5)
                                    .background(Capsule().fill(Color.white.opacity(on ? 0.22 : 0.07)))
                                    .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    HStack {
                        SoundMenu(ambient: ambient, compact: false)
                        Spacer()
                        Button { engine.start() } label: {
                            Label("Start", systemImage: "play.fill")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.black)
                                .padding(.horizontal, 22)
                                .padding(.vertical, 8)
                                .background(Capsule().fill(Heat.base))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }

                    StatsGrid(store: store, live: 0)
                }
                .frame(width: 330)

                TodayBlocks(store: store, addPast: addPast)
            }

            HStack(alignment: .bottom) {
                Text("LAST 12 MONTHS").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                Spacer()
                Button(action: openLog) { Label("Full log", systemImage: "arrow.up.right") }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, -8)
            HeatmapView(stats: store.dayStats(), metric: HeatMetric(rawValue: metricRaw) ?? .score,
                        selected: .constant(nil), cell: 9, gap: 3, showExplanation: false)
        }
    }
}

struct LargeRunningView: View {
    @ObservedObject var engine: TimerEngine
    @ObservedObject var store: SessionStore
    @ObservedObject var ambient: AmbientPlayer
    let addPast: () -> Void

    var body: some View {
        let paused = engine.phase == .paused
        HStack(alignment: .top, spacing: 26) {
            ZStack {
                ProgressRing(progress: engine.goal == nil ? nil : engine.progress,
                             tint: paused ? .orange : engine.isOvertime ? Heat.base : .white, lineWidth: 9)
                if paused, let since = engine.pauseStart {
                    BreathingGuide(since: since, size: 150)
                }
                VStack(spacing: 4) {
                    Image(systemName: paused ? "pause.fill" : "flame.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(paused ? .orange : Heat.base)
                        .opacity(paused ? 0 : 1)
                    Text(engine.displayTime)
                        .font(.system(size: 40, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(paused ? .orange : engine.isOvertime ? Heat.base : .white)
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                    Text(engine.goal.map { "of \(Fmt.hm($0))" } ?? "open-ended")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(18)
                .opacity(paused ? 0 : 1)
            }
            .frame(width: 190, height: 190)

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(engine.task.isEmpty ? "Deep work" : engine.task)
                        .font(.system(size: 17, weight: .semibold))
                        .lineLimit(1)
                    Text(TimerControls.subtitle(engine))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 14) {
                    TimerControls(engine: engine)
                    SoundMenu(ambient: ambient, compact: false)
                }
                DriftRow(engine: engine)
                TodayBlocks(store: store, addPast: addPast, live: engine.elapsed)
            }
        }
    }
}

/// Today's logged blocks, newest first.
struct TodayBlocks: View {
    @ObservedObject var store: SessionStore
    let addPast: () -> Void
    var live: TimeInterval = 0

    var body: some View {
        let today = store.sessions.filter { Calendar.current.isDateInToday($0.start) }
        let total = today.reduce(0) { $0 + $1.duration } + live
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("TODAY · \(Fmt.hm(total))")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: addPast) { Label("Add past block", systemImage: "plus") }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Heat.base)
            }
            if today.isEmpty {
                Text(live > 0 ? "First block of the day is running." : "No blocks yet today.")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 6)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(today) { s in
                            HStack(spacing: 10) {
                                Text(Fmt.hm(s.duration))
                                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                                    .frame(width: 58, alignment: .leading)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(s.displayTask).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                    Text("\(Fmt.time.string(from: s.start))–\(Fmt.time.string(from: s.end))")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.tertiary)
                                }
                                Spacer(minLength: 4)
                                DriftDots(count: s.drifts)
                                IntensityBadge(value: s.intensity)
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
                        }
                    }
                }
                .scrollIndicators(.never)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

struct StatsGrid: View {
    @ObservedObject var store: SessionStore
    var live: TimeInterval

    var body: some View {
        let weekStart = Calendar.current.dateInterval(of: .weekOfYear, for: Date())?.start ?? Date()
        let streak = store.streak()
        let avg = store.avgIntensity(lastDays: 30)
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                cell("Today", Fmt.hm(store.total(onDay: Date()) + live))
                cell("This week", Fmt.hm(store.total(since: weekStart) + live))
            }
            GridRow {
                cell("Streak", streak == 1 ? "1 day" : "\(streak) days")
                cell("Intensity · 30d", avg.map { String(format: "%.1f %@", $0, Intensity.label(Int($0.rounded()))) } ?? "–")
            }
        }
    }

    private func cell(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 16, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.05)))
    }
}

/// Picks the focus sound that plays while a block runs.
struct SoundMenu: View {
    @ObservedObject var ambient: AmbientPlayer
    let compact: Bool

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(AmbientPlayer.Kind.allCases) { k in
                    Button {
                        ambient.kind = k
                    } label: {
                        if ambient.kind == k { Label(k.title, systemImage: "checkmark") } else { Text(k.title) }
                    }
                }
            } label: {
                if compact {
                    Image(systemName: ambient.kind.icon)
                } else {
                    Label(ambient.kind == .off ? "Focus sound" : ambient.kind.title, systemImage: ambient.kind.icon)
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(compact ? .hidden : .visible)
            .fixedSize()
            .help("Focus sound while a block runs")

            if !compact, ambient.kind != .off {
                Slider(value: $ambient.volume, in: 0...1)
                    .controlSize(.mini)
                    .frame(width: 90)
                    .help("Volume")
            }
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(ambient.kind == .off ? Color.secondary : Heat.base)
        .tint(Heat.base)
    }
}
