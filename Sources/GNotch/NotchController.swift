import AppKit
import Combine
import SwiftUI

enum NotchPage: String, CaseIterable, Identifiable {
    case timer, clipboard, vision

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .timer: return "flame.fill"
        case .clipboard: return "doc.on.clipboard"
        case .vision: return "sparkles"
        }
    }
    var title: String {
        switch self {
        case .timer: return "Deep work timer (⌃⌥D)"
        case .clipboard: return "Clipboard (⌃⌥V)"
        case .vision: return "Vision board (⌃⌥B)"
        }
    }
}

enum DropZone { case clipboard, vision }

struct NotchBadge: Equatable {
    var icon: String
    var text: String
}

@MainActor
final class NotchState: ObservableObject {
    @Published var hovering = false
    /// Temporary expansion, e.g. when the goal is reached.
    @Published var peek = false
    /// Stays open until Esc, the close button, a click elsewhere, or the shortcut again.
    @Published var pinned = false
    /// Something is being dragged over the notch.
    @Published var dragging = false
    @Published var dropZone: DropZone?
    @Published var notchSize = CGSize(width: 185, height: 32)
    @Published var hasNotch = true
    @Published var toast: String?
    /// Brief message in the collapsed notch's wings, e.g. after a screenshot is copied.
    @Published var badge: NotchBadge?
    /// Bumped to ask the visible page to focus its text field.
    @Published var focusToken = 0

    @Published var page = NotchPage(rawValue: UserDefaults.standard.string(forKey: "notchPage") ?? "") ?? .timer {
        didSet { UserDefaults.standard.set(page.rawValue, forKey: "notchPage") }
    }
    /// Bigger layout for every page.
    @Published var large = UserDefaults.standard.bool(forKey: "notchLarge") {
        didSet { UserDefaults.standard.set(large, forKey: "notchLarge") }
    }
    /// Show the time and icon in wings beside the notch, or only the outline progress.
    @Published var showWings = UserDefaults.standard.object(forKey: "showTimeBesideNotch") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showWings, forKey: "showTimeBesideNotch") }
    }

    func isExpanded(phase: TimerEngine.Phase) -> Bool {
        phase == .finishing || hovering || peek || pinned || dragging
    }

    /// The finish form always wins, whatever page was open.
    func visiblePage(phase: TimerEngine.Phase) -> NotchPage {
        phase == .finishing ? .timer : page
    }

    func flash(_ message: String) {
        toast = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            if self?.toast == message { self?.toast = nil }
        }
    }
}

/// Sizes of the black shape for every state. Shared by the SwiftUI view and the hit-testing.
enum NotchLayout {
    /// Width of the concave "ears" that blend the shape into the menu bar.
    static let ear: CGFloat = 8
    /// Width of each wing beside the notch while a block runs collapsed.
    static let wing: CGFloat = 78
    /// The transparent panel is this big (plus the notch height); the shape never exceeds it.
    static let canvas = CGSize(width: 900, height: 600)

    @MainActor
    static func size(phase: TimerEngine.Phase, expanded: Bool, state: NotchState) -> CGSize {
        let notch = state.notchSize
        guard expanded else {
            if state.badge != nil {
                return CGSize(width: notch.width + 2 * ear + 2 * wing, height: notch.height)
            }
            if phase == .idle || !state.showWings {
                return CGSize(width: notch.width + 2 * ear, height: notch.height)
            }
            return CGSize(width: notch.width + 2 * ear + 2 * wing, height: notch.height)
        }
        if state.dragging {
            return CGSize(width: 560, height: notch.height + 150)
        }
        switch state.visiblePage(phase: phase) {
        case .timer:
            switch phase {
            case .finishing: return CGSize(width: 480, height: notch.height + 392)
            case .idle:
                return state.large ? CGSize(width: 760, height: notch.height + 428)
                                   : CGSize(width: 480, height: notch.height + 178)
            case .running, .paused:
                return state.large ? CGSize(width: 760, height: notch.height + 238)
                                   : CGSize(width: 480, height: notch.height + 126)
            }
        case .clipboard:
            return state.large ? CGSize(width: 760, height: notch.height + 520)
                               : CGSize(width: 560, height: notch.height + 400)
        case .vision:
            return state.large ? CGSize(width: 860, height: notch.height + 560)
                               : CGSize(width: 540, height: notch.height + 350)
        }
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
    private var pollTimer: Timer?
    private var collapseWork: DispatchWorkItem?
    /// After an explicit close, ignore hover until the pointer leaves the notch.
    private var suppressHover = false
    private var cancellables = Set<AnyCancellable>()

    init(engine: TimerEngine, store: SessionStore, clips: ClipboardStore, vision: VisionStore,
         shots: ScreenshotLibrary, ambient: AmbientPlayer,
         openLog: @escaping () -> Void, addPast: @escaping () -> Void) {
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

        let state = self.state
        let root = NotchRootView(
            engine: engine, store: store, clips: clips, vision: vision, shots: shots, state: state, ambient: ambient,
            openLog: openLog, addPast: addPast,
            collapse: { [weak self] in self?.collapse() },
            onDrop: { zone, providers in
                PasteboardReader.read(providers: providers) { contents in
                    guard !contents.isEmpty else { return }
                    switch zone {
                    case .clipboard:
                        clips.addDropped(contents)
                        state.page = .clipboard
                        state.flash("Added to clipboard")
                    case .vision:
                        let n = vision.add(contents)
                        state.page = .vision
                        state.flash(n > 0 ? "Added to vision board" : "Only images & text go on the board")
                    }
                    state.pinned = true
                }
            })
        let host = FirstMouseHostingView(rootView: root)
        host.sizingOptions = []
        panel.contentView = host

        reposition()
        panel.orderFrontRegardless()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reposition() }
        }

        installMonitors()

        // Polling the pointer is cheap and keeps working during drags, when move events stop.
        let t = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleMouse() }
        }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t

        engine.onGoalReached = { [weak self] in self?.peek(seconds: 5) }
        engine.$phase
            .removeDuplicates()
            .scan((TimerEngine.Phase.idle, TimerEngine.Phase.idle)) { ($0.1, $1) }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] old, new in self?.phaseChanged(from: old, to: new) }
            .store(in: &cancellables)
    }

    // MARK: Public

    func peek(seconds: Double) {
        state.peek = true
        updateMouseIgnoring()
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            self?.state.peek = false
            self?.updateMouseIgnoring()
        }
    }

    func showBadge(icon: String, text: String, seconds: Double = 2) {
        let badge = NotchBadge(icon: icon, text: text)
        state.badge = badge
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            if self?.state.badge == badge { self?.state.badge = nil }
        }
    }

    /// Shortcut behaviour: open pinned on `page`, or close if it's already showing.
    func toggle(page: NotchPage) {
        if state.pinned, state.page == page {
            collapse()
            return
        }
        state.page = page
        state.pinned = true
        updateMouseIgnoring()
        panel.makeKey()
        state.focusToken += 1
    }

    /// Open pinned on a page (no toggling).
    func open(page: NotchPage) {
        state.page = page
        state.pinned = true
        updateMouseIgnoring()
    }

    func collapse() {
        guard engine.phase != .finishing else { return }
        state.pinned = false
        state.peek = false
        state.hovering = false
        suppressHover = visibleRect(expanded: false).insetBy(dx: -8, dy: -6).contains(NSEvent.mouseLocation)
            || visibleRect(expanded: true).contains(NSEvent.mouseLocation)
        updateMouseIgnoring()
        dropKeyIfNeeded()
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

        let w = NotchLayout.canvas.width
        let h = state.notchSize.height + NotchLayout.canvas.height
        panel.setFrame(NSRect(x: screen.frame.midX - w / 2, y: screen.frame.maxY - h, width: w, height: h),
                       display: true)
    }

    private func visibleRect(expanded: Bool) -> NSRect {
        guard let screen else { return .zero }
        let size = NotchLayout.size(phase: engine.phase, expanded: expanded, state: state)
        return NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height,
                      width: size.width, height: size.height)
    }

    // MARK: Mouse & keyboard

    private func installMonitors() {
        let move: (NSEvent) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.handleMouse() }
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: move) {
            monitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { e in
            move(e)
            return e
        }) {
            monitors.append(m)
        }

        // Clicking another app closes a pinned notch.
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.state.pinned else { return }
                if !self.visibleRect(expanded: true).contains(NSEvent.mouseLocation) { self.collapse() }
            }
        }) {
            monitors.append(m)
        }

        // Clicking inside the notch keeps it open; clicking our other windows closes it.
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown], handler: { [weak self] e in
            MainActor.assumeIsolated {
                guard let self else { return }
                if e.window === self.panel {
                    if self.state.isExpanded(phase: self.engine.phase) { self.state.pinned = true }
                } else if self.state.pinned {
                    self.collapse()
                }
            }
            return e
        }) {
            monitors.append(m)
        }

        // Esc closes.
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.keyDown], handler: { [weak self] e in
            guard e.keyCode == 53 else { return e }
            let windowNumber = e.windowNumber
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, windowNumber == self.panel.windowNumber else { return false }
                self.collapse()
                return true
            }
            return handled ? nil : e
        }) {
            monitors.append(m)
        }
    }

    private func handleMouse() {
        let p = NSEvent.mouseLocation
        let expanded = state.isExpanded(phase: engine.phase)
        let rect = visibleRect(expanded: expanded)
        let hit = expanded ? rect.insetBy(dx: -14, dy: -14) : rect.insetBy(dx: -8, dy: -6)
        let inside = hit.contains(p)

        if suppressHover {
            if !inside, !visibleRect(expanded: true).contains(p) { suppressHover = false }
        } else if inside {
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

    private func phaseChanged(from old: TimerEngine.Phase, to new: TimerEngine.Phase) {
        switch new {
        case .finishing:
            panel.makeKey()
        case .running where old == .idle:
            // Started a block: compact mode gets out of the way, big mode stays open as a focus screen.
            if !(state.large && state.page == .timer) { state.pinned = false }
            dropKeyIfNeeded()
        case .idle where old == .finishing:
            state.pinned = false
            dropKeyIfNeeded()
        default:
            dropKeyIfNeeded()
        }
        updateMouseIgnoring()
    }
}
