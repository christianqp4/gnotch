import AppKit
import Combine
import SwiftUI

@MainActor
final class NotchState: ObservableObject {
    @Published var hovering = false
    /// Temporary expansion, e.g. when the goal is reached.
    @Published var peek = false
    @Published var notchSize = CGSize(width: 185, height: 32)
    @Published var hasNotch = true

    func isExpanded(phase: TimerEngine.Phase) -> Bool {
        phase == .finishing || hovering || peek
    }
}

/// Sizes of the black shape for every state. Shared by the SwiftUI view and the hit-testing.
enum NotchLayout {
    /// Width of the concave "ears" that blend the shape into the menu bar.
    static let ear: CGFloat = 8
    /// Width of each wing beside the notch while a block runs collapsed.
    static let wing: CGFloat = 78

    static func size(phase: TimerEngine.Phase, expanded: Bool, notch: CGSize) -> CGSize {
        if phase == .finishing {
            return CGSize(width: 480, height: notch.height + 318)
        }
        if expanded {
            return CGSize(width: 460, height: notch.height + (phase == .idle ? 138 : 104))
        }
        if phase == .idle {
            return CGSize(width: notch.width + 2 * ear, height: notch.height)
        }
        return CGSize(width: notch.width + 2 * ear + 2 * wing, height: notch.height)
    }
}

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    // Allow sitting on top of the menu bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Buttons should react on the first click even though the app is never active.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class NotchController {
    let panel: NotchPanel
    let state = NotchState()
    private let engine: TimerEngine
    private var screen: NSScreen?
    private var monitors: [Any] = []
    private var fallbackTimer: Timer?
    private var collapseWork: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()

    init(engine: TimerEngine, store: SessionStore, openLog: @escaping () -> Void) {
        self.engine = engine
        panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        panel.ignoresMouseEvents = true

        let host = FirstMouseHostingView(rootView: NotchRootView(
            engine: engine, store: store, state: state, openLog: openLog))
        host.sizingOptions = []
        panel.contentView = host

        reposition()
        panel.orderFrontRegardless()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reposition() }
        }

        let handler: (NSEvent) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.handleMouse() }
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: handler) {
            monitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { e in
            handler(e)
            return e
        }) {
            monitors.append(m)
        }
        // Safety net for cases where no move event arrives (fast exits, space switches).
        let t = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleMouse() }
        }
        RunLoop.main.add(t, forMode: .common)
        fallbackTimer = t

        engine.onGoalReached = { [weak self] in self?.peek(seconds: 5) }
        engine.$phase
            .receive(on: DispatchQueue.main)
            .sink { [weak self] phase in self?.phaseChanged(phase) }
            .store(in: &cancellables)
    }

    func peek(seconds: Double) {
        state.peek = true
        updateMouseIgnoring()
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            self?.state.peek = false
            self?.updateMouseIgnoring()
        }
    }

    // MARK: Geometry

    private static func pickScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func reposition() {
        screen = Self.pickScreen()
        guard let screen else { return }

        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            state.hasNotch = true
            state.notchSize = CGSize(width: screen.frame.width - left.width - right.width,
                                     height: screen.safeAreaInsets.top)
        } else {
            state.hasNotch = false
            let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
            state.notchSize = CGSize(width: 200, height: menuBar > 10 ? menuBar : 28)
        }

        let w: CGFloat = 620
        let h = state.notchSize.height + 380
        panel.setFrame(NSRect(x: screen.frame.midX - w / 2, y: screen.frame.maxY - h, width: w, height: h),
                       display: true)
    }

    private func visibleRect(expanded: Bool) -> NSRect {
        guard let screen else { return .zero }
        let size = NotchLayout.size(phase: engine.phase, expanded: expanded, notch: state.notchSize)
        return NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height,
                      width: size.width, height: size.height)
    }

    // MARK: Hover

    private func handleMouse() {
        let p = NSEvent.mouseLocation
        let expanded = state.isExpanded(phase: engine.phase)
        let rect = visibleRect(expanded: expanded)
        let hit = expanded ? rect.insetBy(dx: -14, dy: -14) : rect.insetBy(dx: -8, dy: -6)

        if hit.contains(p) {
            collapseWork?.cancel()
            collapseWork = nil
            if !state.hovering { state.hovering = true }
        } else if state.hovering, collapseWork == nil {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.collapseWork = nil
                self.state.hovering = false
                self.updateMouseIgnoring()
                self.dropKeyIfNeeded()
            }
            collapseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
        updateMouseIgnoring()
    }

    /// Clicks outside the visible black shape fall through to whatever is underneath.
    private func updateMouseIgnoring() {
        let rect = visibleRect(expanded: state.isExpanded(phase: engine.phase))
        let ignore = !rect.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation)
        if panel.ignoresMouseEvents != ignore { panel.ignoresMouseEvents = ignore }
    }

    /// Hand the keyboard back to the previous app when we collapse.
    private func dropKeyIfNeeded() {
        guard panel.isKeyWindow, engine.phase != .finishing, !state.isExpanded(phase: engine.phase) else { return }
        panel.orderOut(nil)
        panel.orderFrontRegardless()
    }

    private func phaseChanged(_ phase: TimerEngine.Phase) {
        if phase == .finishing {
            panel.makeKey()
        } else {
            dropKeyIfNeeded()
        }
        updateMouseIgnoring()
    }
}
