import SwiftUI

struct NotchRootView: View {
    @ObservedObject var engine: TimerEngine
    @ObservedObject var store: SessionStore
    @ObservedObject var state: NotchState
    let openLog: () -> Void

    private let spring = Animation.spring(response: 0.36, dampingFraction: 0.82)

    var body: some View {
        let expanded = state.isExpanded(phase: engine.phase)
        let size = NotchLayout.size(phase: engine.phase, expanded: expanded, notch: state.notchSize)
        let shape = NotchShape(topRadius: NotchLayout.ear, bottomRadius: expanded ? 24 : 10)
        // Without a physical notch, an idle collapsed bar would just be a black blob.
        let hidden = !expanded && engine.phase == .idle && !state.hasNotch

        ZStack(alignment: .top) {
            shape
                .fill(Color.black)
                .shadow(color: .black.opacity(expanded ? 0.45 : 0), radius: 14, y: 6)
            content(expanded: expanded, size: size)
                .clipShape(shape)
        }
        .frame(width: size.width, height: size.height)
        .opacity(hidden ? 0 : 1)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(spring, value: expanded)
        .animation(spring, value: engine.phase)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private func content(expanded: Bool, size: CGSize) -> some View {
        if expanded {
            VStack(spacing: 0) {
                topBand(width: size.width)
                Group {
                    switch engine.phase {
                    case .idle: IdleView(engine: engine, store: store, openLog: openLog)
                    case .running, .paused: RunningView(engine: engine)
                    case .finishing: FinishView(engine: engine)
                    }
                }
                .padding(.horizontal, NotchLayout.ear + 18)
                .padding(.top, 8)
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .transition(.opacity.animation(.easeOut(duration: 0.18)))
        } else if engine.phase != .idle {
            CollapsedActivity(engine: engine, notch: state.notchSize)
                .transition(.opacity)
        }
    }

    /// The strip beside the physical notch when expanded.
    private func topBand(width: CGFloat) -> some View {
        let side = max(0, (width - 2 * NotchLayout.ear - state.notchSize.width) / 2)
        let today = store.total(onDay: Date()) + (engine.isActive || engine.phase == .finishing ? engine.elapsed : 0)
        return HStack(spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: "brain.head.profile")
                Text("DeepWork")
            }
            .frame(width: side)
            Color.clear.frame(width: state.notchSize.width)
            Text("Today \(Fmt.hm(today))")
                .monospacedDigit()
                .frame(width: side)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, NotchLayout.ear)
        .frame(height: state.notchSize.height)
    }
}

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
                } else if engine.goal == nil {
                    Image(systemName: "flame.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Heat.base)
                } else {
                    ProgressRing(progress: engine.progress, tint: engine.isOvertime ? Heat.base : .white, lineWidth: 2.5)
                        .frame(width: 14, height: 14)
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
    let openLog: () -> Void

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

            HStack {
                let streak = store.streak()
                Text(streak > 0 ? "\(streak)-day streak" : "No streak yet. Today's a good day.")
                Spacer()
                Button(action: openLog) {
                    Label("Log & heatmap", systemImage: "square.grid.3x3.fill")
                }
                .buttonStyle(.plain)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
        }
    }
}

struct RunningView: View {
    @ObservedObject var engine: TimerEngine
    @State private var confirmDiscard = false

    var body: some View {
        let paused = engine.phase == .paused
        HStack(spacing: 14) {
            ZStack {
                ProgressRing(progress: engine.goal == nil ? nil : engine.progress,
                             tint: engine.isOvertime ? Heat.base : .white, lineWidth: 4)
                Image(systemName: paused ? "pause.fill" : "flame.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(paused ? .orange : Heat.base)
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

            HStack(spacing: 8) {
                CircleButton(icon: paused ? "play.fill" : "pause.fill", tint: .orange,
                             help: paused ? "Resume" : "Pause") { engine.togglePause() }
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
    }

    private var subtitle: String {
        if engine.phase == .paused { return "Paused · \(Fmt.clock(engine.elapsed)) in" }
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
                    engine.save(task: task, intensity: intensity, tags: tags, notes: notes)
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
