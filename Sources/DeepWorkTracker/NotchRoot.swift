import SwiftUI
import UniformTypeIdentifiers

/// Everything the notch shows, switched by `NotchState.page`.
struct NotchRootView: View {
    @ObservedObject var engine: TimerEngine
    @ObservedObject var store: SessionStore
    @ObservedObject var clips: ClipboardStore
    @ObservedObject var vision: VisionStore
    @ObservedObject var state: NotchState
    @ObservedObject var ambient: AmbientPlayer
    let openLog: () -> Void
    let addPast: () -> Void
    let collapse: () -> Void
    let onDrop: (DropZone, [NSItemProvider]) -> Void

    private let spring = Animation.spring(response: 0.36, dampingFraction: 0.82)

    var body: some View {
        let expanded = state.isExpanded(phase: engine.phase)
        let size = NotchLayout.size(phase: engine.phase, expanded: expanded, state: state)
        let shape = NotchShape(topRadius: NotchLayout.ear, bottomRadius: expanded ? 24 : 10)
        // Without a physical notch, an idle collapsed bar would just be a black blob.
        let hidden = !expanded && engine.phase == .idle && !state.hasNotch

        ZStack(alignment: .top) {
            shape
                .fill(Color.black)
                .shadow(color: .black.opacity(expanded ? 0.45 : 0), radius: 14, y: 6)
            content(expanded: expanded, size: size)
                .clipShape(shape)
            if !expanded, engine.isActive {
                OutlineProgress(engine: engine)
            }
            if let toast = state.toast, expanded {
                Text(toast)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Heat.base))
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 12)
                    .transition(.opacity)
            }
        }
        .frame(width: size.width, height: size.height)
        .onDrop(of: [.fileURL, .image, .url, .plainText, .text],
                delegate: NotchDropDelegate(state: state, width: size.width, onDrop: onDrop))
        .opacity(hidden ? 0 : 1)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(spring, value: expanded)
        .animation(spring, value: engine.phase)
        .animation(spring, value: state.page)
        .animation(spring, value: state.large)
        .animation(spring, value: state.dragging)
        .animation(.easeOut(duration: 0.2), value: state.toast)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private func content(expanded: Bool, size: CGSize) -> some View {
        if expanded {
            VStack(spacing: 0) {
                topBand(width: size.width)
                Group {
                    if state.dragging {
                        DropZonesView(state: state)
                    } else {
                        switch state.visiblePage(phase: engine.phase) {
                        case .timer: timerPage
                        case .clipboard: ClipboardPage(clips: clips, vision: vision, state: state)
                        case .vision: VisionPage(vision: vision, state: state)
                        }
                    }
                }
                .padding(.horizontal, NotchLayout.ear + 18)
                .padding(.top, 8)
                .padding(.bottom, 14)
                .frame(maxHeight: .infinity, alignment: .top)
                .transition(.opacity)
                .id(state.dragging ? "drop" : state.visiblePage(phase: engine.phase).rawValue)
            }
            .transition(.opacity.animation(.easeOut(duration: 0.18)))
        } else if engine.phase != .idle, state.showWings {
            CollapsedActivity(engine: engine, notch: state.notchSize)
                .transition(.opacity)
        }
    }

    @ViewBuilder
    private var timerPage: some View {
        switch (engine.phase, state.large) {
        case (.idle, false):
            IdleView(engine: engine, store: store, ambient: ambient, openLog: openLog, addPast: addPast)
        case (.idle, true):
            LargeIdleView(engine: engine, store: store, ambient: ambient, openLog: openLog, addPast: addPast)
        case (.running, false), (.paused, false):
            RunningView(engine: engine, ambient: ambient)
        case (.running, true), (.paused, true):
            LargeRunningView(engine: engine, store: store, ambient: ambient, addPast: addPast)
        case (.finishing, _):
            FinishView(engine: engine)
        }
    }

    /// The strip beside the physical notch: page tabs on the left, page tools on the right.
    private func topBand(width: CGFloat) -> some View {
        let side = max(0, (width - 2 * NotchLayout.ear - state.notchSize.width) / 2)
        let page = state.visiblePage(phase: engine.phase)
        return HStack(spacing: 0) {
            HStack(spacing: 3) {
                ForEach(NotchPage.allCases) { p in tab(p, selected: p == page) }
            }
            .frame(width: side)

            Color.clear.frame(width: state.notchSize.width)

            HStack(spacing: 4) {
                Spacer(minLength: 0)
                switch page {
                case .timer:
                    let today = store.total(onDay: Date())
                        + (engine.isActive || engine.phase == .finishing ? engine.elapsed : 0)
                    Text("Today \(Fmt.hm(today))").monospacedDigit().lineLimit(1)
                    if engine.phase != .finishing {
                        toolButton(state.large ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                                   help: state.large ? "Smaller" : "Bigger") { state.large.toggle() }
                    }
                case .clipboard, .vision:
                    toolButton(state.large ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                               help: state.large ? "Smaller" : "Bigger") { state.large.toggle() }
                }
                if state.pinned {
                    toolButton("chevron.up", help: "Close (Esc)", action: collapse)
                }
            }
            .padding(.trailing, 10)
            .frame(width: side)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, NotchLayout.ear)
        .frame(height: state.notchSize.height)
    }

    private func tab(_ p: NotchPage, selected: Bool) -> some View {
        Button {
            state.page = p
        } label: {
            Group {
                if p == .timer, engine.isActive {
                    Text(engine.displayTime)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(engine.phase == .paused ? .orange : Heat.base)
                } else {
                    Image(systemName: p.icon).font(.system(size: 11.5, weight: .semibold))
                }
            }
            .padding(.horizontal, 7)
            .frame(minWidth: 26, minHeight: 22)
            .background(Capsule().fill(Color.white.opacity(selected ? 0.16 : 0)))
            .foregroundStyle(selected ? Color.white : Color.secondary)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(engine.phase == .finishing)
        .help(p.title)
    }

    private func toolButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10.5, weight: .bold))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.white.opacity(0.08)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Shown while something is dragged over the notch.
struct DropZonesView: View {
    @ObservedObject var state: NotchState

    var body: some View {
        HStack(spacing: 10) {
            zone(.clipboard, icon: "doc.on.clipboard", title: "Clipboard", sub: "Files, images, text")
            zone(.vision, icon: "sparkles", title: "Vision Board", sub: "Images & quotes")
        }
    }

    private func zone(_ z: DropZone, icon: String, title: String, sub: String) -> some View {
        let on = state.dropZone == z
        return VStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 22, weight: .semibold))
            Text(title).font(.system(size: 13, weight: .bold))
            Text(sub).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .foregroundStyle(on ? Heat.base : Color.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(on ? Heat.base.opacity(0.14) : Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(on ? Heat.base : Color.white.opacity(0.2), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
        )
    }
}

struct NotchDropDelegate: DropDelegate {
    let state: NotchState
    let width: CGFloat
    let onDrop: (DropZone, [NSItemProvider]) -> Void

    static let types: [UTType] = [.fileURL, .image, .url, .plainText, .text]

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: Self.types) }

    func dropEntered(info: DropInfo) {
        state.dragging = true
        update(info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        update(info)
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        state.dragging = false
        state.dropZone = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        let zone = state.dropZone ?? .clipboard
        state.dragging = false
        state.dropZone = nil
        onDrop(zone, info.itemProviders(for: Self.types))
        return true
    }

    private func update(_ info: DropInfo) {
        state.dropZone = info.location.x < width / 2 ? .clipboard : .vision
    }
}
