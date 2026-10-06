import SwiftUI

/// Live-activity style wings around the notch while a block runs.
struct CollapsedActivity: View {
    @ObservedObject var engine: TimerEngine
    let notch: CGSize

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if engine.phase == .paused {
                    Image(systemName: "pause.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.orange)
                } else {
                    HStack(spacing: 5) {
                        Image(systemName: "flame.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Heat.base)
                        DriftDots(count: engine.drifts)
                    }
                }
            }
            .frame(width: NotchLayout.wing, alignment: .leading)
            .padding(.leading, 14)

            Color.clear.frame(width: notch.width - 14 * 2 + 4)

            Text(engine.displayTime)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(engine.phase == .paused ? .orange : engine.isOvertime ? Heat.base : .white)
                .lineLimit(1)
                .fixedSize()
                .frame(width: NotchLayout.wing, alignment: .trailing)
                .padding(.trailing, 14)
        }
        .padding(.horizontal, NotchLayout.ear - 2)
        .frame(height: notch.height)
    }
}

struct IdleView: View {
    @ObservedObject var engine: TimerEngine
    @ObservedObject var store: SessionStore
    @ObservedObject var ambient: AmbientPlayer
    let openLog: () -> Void
    let addPast: () -> Void

    private let presets: [Int?] = [25, 50, 90, 120, nil]

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            TextField("What will you go deep on?", text: $engine.task)
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: .medium))
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.08)))
                .onSubmit { engine.start() }

            HStack(spacing: 6) {
                ForEach(presets, id: \.self) { m in
                    let on = engine.plannedMinutes == m
                    Button {
                        engine.plannedMinutes = m
                    } label: {
                        Text(m.map { "\($0)m" } ?? "∞")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(minWidth: 38)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(on ? Color.white.opacity(0.22) : Color.white.opacity(0.07)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(m == nil ? "Open-ended: count up until you finish" : "\(m!) minute block")
                }
                Spacer()
                SoundMenu(ambient: ambient, compact: true)
                Button {
                    engine.start()
                } label: {
                    Label("Start", systemImage: "play.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Heat.base))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }

            HStack(alignment: .bottom) {
                Button(action: openLog) {
                    MiniHeatmap(store: store)
                }
                .buttonStyle(.plain)
                .help("Open log & heatmap")
                Spacer()
                VStack(alignment: .trailing, spacing: 5) {
                    let streak = store.streak()
                    let weekStart = Calendar.current.dateInterval(of: .weekOfYear, for: Date())?.start ?? Date()
                    Text(streak > 0 ? "\(streak)-day streak" : "No streak yet")
                        .foregroundStyle(.primary)
                    Text("This week \(Fmt.hm(store.total(since: weekStart)))")
                        .monospacedDigit()
                    Button(action: addPast) {
                        Label("Add past block", systemImage: "plus")
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                    Button(action: openLog) {
                        Label("Log & heatmap", systemImage: "arrow.up.right")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.plain)
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            }
        }
    }
}

struct RunningView: View {
    @ObservedObject var engine: TimerEngine
    @ObservedObject var ambient: AmbientPlayer

    var body: some View {
        let paused = engine.phase == .paused
        VStack(spacing: 10) {
        HStack(spacing: 14) {
            ZStack {
                ProgressRing(progress: engine.goal == nil ? nil : engine.progress,
                             tint: engine.isOvertime ? Heat.base : .white, lineWidth: 4)
                if paused, let since = engine.pauseStart {
                    BreathingGuide(since: since, size: 44, showText: false)
                } else {
                    Image(systemName: "flame.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(Heat.base)
                }
            }
            .frame(width: 54, height: 54)

            VStack(alignment: .leading, spacing: 1) {
                Text(engine.task.isEmpty ? "Deep work" : engine.task)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(engine.displayTime)
                    .font(.system(size: 32, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(paused ? .orange : engine.isOvertime ? Heat.base : .white)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 0)

            SoundMenu(ambient: ambient, compact: true)
            TimerControls(engine: engine)
        }
            DriftRow(engine: engine)
        }
    }

    private var subtitle: String { TimerControls.subtitle(engine) }
}

struct TimerControls: View {
    @ObservedObject var engine: TimerEngine
    @State private var confirmDiscard = false

    var body: some View {
        let paused = engine.phase == .paused
        HStack(spacing: 8) {
            CircleButton(icon: paused ? "play.fill" : "pause.fill", tint: .orange,
                         help: paused ? "Back to focus (⌃⌥P)" : "Drifted? Pause, breathe, refocus (⌃⌥P)") { engine.togglePause() }
            CircleButton(icon: "checkmark", tint: Heat.base, help: "Finish block and log it") { engine.finish() }
            CircleButton(icon: confirmDiscard ? "trash.fill" : "xmark", tint: confirmDiscard ? .red : .gray,
                         help: confirmDiscard ? "Click again to discard" : "Discard block") {
                if confirmDiscard {
                    engine.discard()
                } else {
                    confirmDiscard = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { confirmDiscard = false }
                }
            }
        }
    }

    @MainActor
    static func subtitle(_ engine: TimerEngine) -> String {
        if engine.phase == .paused { return "Paused · \(Fmt.clock(engine.elapsed)) focused so far" }
        if let g = engine.goal {
            return engine.isOvertime ? "Goal of \(Fmt.hm(g)) reached · keep going" : "\(Fmt.clock(engine.elapsed)) of \(Fmt.hm(g))"
        }
        return engine.startDate.map { "Open-ended · since \(Fmt.time.string(from: $0))" } ?? ""
    }
}

struct FinishView: View {
    @ObservedObject var engine: TimerEngine
    @State private var task = ""
    @State private var intensity = 3
    @State private var tags: [String] = []
    @State private var notes = ""
    @State private var place: String? = Places.last

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Block complete")
                    .font(.system(size: 15, weight: .bold))
                Text(Fmt.hm(engine.elapsed))
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(Heat.base)
                Spacer()
                if let s = engine.startDate, let e = engine.endDate {
                    Text("\(Fmt.time.string(from: s)) – \(Fmt.time.string(from: e))")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            if let s = engine.startDate, let e = engine.endDate {
                HStack(spacing: 10) {
                    DriftTimeline(start: s, end: e, pauses: engine.pauses)
                    Text(DriftText.summary(drifts: engine.drifts, paused: engine.pausedTime))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(engine.drifts > 0 ? Color.orange : Heat.base)
                        .fixedSize()
                }
            }

            TextField("What did you work on?", text: $task)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.07)))

            VStack(alignment: .leading, spacing: 5) {
                sectionLabel("Intensity")
                IntensityPicker(value: $intensity)
            }

            VStack(alignment: .leading, spacing: 6) {
                sectionLabel("How did it feel?")
                TagPicker(selection: $tags)
            }

            VStack(alignment: .leading, spacing: 6) {
                sectionLabel("Where?")
                PlacePicker(place: $place)
            }

            NotesEditor(text: $notes)
                .frame(height: 64)

            HStack {
                Button("Discard") { engine.discard() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("⌘↩")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Button {
                    engine.save(task: task, intensity: intensity, tags: tags, notes: notes, location: place)
                } label: {
                    Text("Save to log")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Heat.base))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .onAppear { task = engine.task }
    }

    private func sectionLabel(_ s: String) -> some View {
        Text(s.uppercased())
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.secondary)
    }
}

/// Progress drawn along the notch outline: down the left side, across the bottom, up the right.
struct OutlineProgress: View {
    @ObservedObject var engine: TimerEngine

    var body: some View {
        let paused = engine.phase == .paused
        let overtime = engine.isOvertime
        // Open-ended blocks fill the outline once per hour.
        let progress = engine.goal == nil
            ? engine.elapsed.truncatingRemainder(dividingBy: 3600) / 3600
            : (overtime ? 1 : engine.progress)
        let tint: Color = paused ? .orange : Heat.base
        let pulse = overtime && !paused && Int(engine.elapsed) % 2 == 0

        NotchShape(topRadius: NotchLayout.ear, bottomRadius: 10, closed: false)
            .trim(from: 0, to: max(0.004, progress))
            .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            .shadow(color: tint.opacity(0.7), radius: 3)
            .opacity(pulse ? 0.45 : 1)
            .animation(.linear(duration: 1), value: progress)
            .animation(.easeInOut(duration: 1), value: pulse)
            .allowsHitTesting(false)
    }
}

/// The last 24 weeks, in the same colors and metric as the dashboard heatmap.
struct MiniHeatmap: View {
    @ObservedObject var store: SessionStore
    var weeks = 24
    var cell: CGFloat = 8
    var gap: CGFloat = 2.5
    @AppStorage("heatMetric") private var metricRaw = HeatMetric.score.rawValue

    var body: some View {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let weekStart = cal.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        let first = cal.date(byAdding: .weekOfYear, value: -(weeks - 1), to: weekStart)!
        let stats = store.dayStats()
        let metric = HeatMetric(rawValue: metricRaw) ?? .score

        HStack(spacing: gap) {
            ForEach(0..<weeks, id: \.self) { w in
                VStack(spacing: gap) {
                    ForEach(0..<7, id: \.self) { d in
                        let day = cal.date(byAdding: .day, value: w * 7 + d, to: first)!
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Heat.color(metric.level(stats[day])))
                            .frame(width: cell, height: cell)
                            .overlay(
                                RoundedRectangle(cornerRadius: 2)
                                    .stroke(Color.white.opacity(day == today ? 0.85 : 0), lineWidth: 1)
                            )
                            .opacity(day > today ? 0 : 1)
                    }
                }
            }
        }
        .contentShape(Rectangle())
    }
}

/// While a block runs: the drift timeline and count. While paused: a nudge to breathe.
struct DriftRow: View {
    @ObservedObject var engine: TimerEngine

    var body: some View {
        HStack(spacing: 10) {
            if let start = engine.startDate {
                DriftTimeline(start: start, end: engine.now, pauses: engine.pauses, openPause: engine.pauseStart)
            }
            Group {
                if engine.phase == .paused, let since = engine.pauseStart {
                    Text("\(BreathingGuide.prompt(since: since, now: engine.now)) · paused \(Fmt.clock(engine.now.timeIntervalSince(since)))")
                        .foregroundStyle(.orange)
                } else {
                    Text(DriftText.summary(drifts: engine.drifts, paused: engine.pausedTime))
                        .foregroundStyle(engine.drifts > 0 ? Color.orange : Color.secondary)
                }
            }
            .font(.system(size: 11, weight: .medium))
            .monospacedDigit()
            .fixedSize()
        }
        .help("Drifted? Pause (⌃⌥P), breathe, then resume. Each pause is logged as a drift.")
    }
}
