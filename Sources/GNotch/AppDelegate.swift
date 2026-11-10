import AppKit
import Carbon
import Combine
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store = SessionStore()
    private lazy var engine = TimerEngine(store: store)
    private let clips = ClipboardStore()
    private let vision = VisionStore()
    private let ambient = AmbientPlayer()
    private let shots = ScreenshotLibrary()
    private let router = DashboardRouter()
    private let timeline = TimelineStore()
    private let questions = QuestionStore()
    private var reminders: Reminders?
    private var remindersWindow: NSWindow?
    private var phaseWatch: AnyCancellable?
    private var notch: NotchController!
    private var statusItem: NSStatusItem!
    private var dashboard: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        notch = NotchController(engine: engine, store: store, clips: clips, vision: vision, shots: shots, ambient: ambient, timeline: timeline,
                                questions: questions,
                                openLog: { [weak self] in self?.showDashboard() },
                                addPast: { [weak self] in self?.showDashboard(addBlock: true) })
        // Ubuntu-style: a new screenshot is on the clipboard right away, and in the history.
        shots.onNewScreenshot = { [weak self] url in
            guard let self else { return }
            self.clips.addScreenshot(url, copy: self.shots.autoCopy)
            if self.shots.autoCopy { self.notch.showBadge(icon: "camera.fill", text: "Copied") }
        }
        phaseWatch = engine.$phase.sink { [ambient] phase in ambient.timerRunning(phase == .running) }

        // ⌃⌥D timer · ⌃⌥V clipboard · ⌃⌥B vision board
        HotKeys.register(keyCode: kVK_ANSI_D, modifiers: HotKeys.controlOption) { [weak self] in self?.notch.toggle(page: .timer) }
        HotKeys.register(keyCode: kVK_ANSI_V, modifiers: HotKeys.controlOption) { [weak self] in
            self?.notch.state.textExportOpen = false
            self?.notch.toggle(page: .clipboard)
        }
        HotKeys.register(keyCode: kVK_ANSI_B, modifiers: HotKeys.controlOption) { [weak self] in self?.notch.toggle(page: .vision) }
        // ⌃⌥M: text to .md (title + pasted text → a file on the clipboard).
        HotKeys.register(keyCode: kVK_ANSI_M, modifiers: HotKeys.controlOption) { [weak self] in self?.notch.toggleTextExport() }
        // ⌃⌥P: "I drifted". Pauses and opens the breathing guide; again to get back to focus.
        HotKeys.register(keyCode: kVK_ANSI_P, modifiers: HotKeys.controlOption) { [weak self] in self?.toggleDrift() }
        // ⌃⌥Q: the chats' questions, one card at a time.
        HotKeys.register(keyCode: kVK_ANSI_Q, modifiers: HotKeys.controlOption) { [weak self] in self?.notch.toggleQuestions() }
        // Calendar and notification setup talk to system services: kept off the launch path.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.reminders = Reminders(questions: self.questions, state: self.notch.state) { [weak self] in
                guard let self, !(self.notch.state.pinned && self.notch.state.questionsOpen) else { return }
                self.notch.toggleQuestions()
            }
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "brain.head.profile", accessibilityDescription: "GNotch")
        image?.isTemplate = true
        statusItem.button?.image = image
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    // MARK: Status menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        switch engine.phase {
        case .idle:
            for m in [25, 50, 90] {
                menu.addItem(ClosureMenuItem("Start \(m) min block") { [engine] in engine.start(minutes: m) })
            }
            menu.addItem(ClosureMenuItem("Start open-ended block") { [engine] in engine.start(minutes: nil) })
        case .running, .paused:
            let header = NSMenuItem(title: "\(engine.phase == .paused ? "Paused" : "Running") · \(engine.displayTime)",
                                    action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            let drift = ClosureMenuItem(engine.phase == .paused ? "Back to Focus" : "I Drifted: Pause & Breathe", key: "p") {
                [weak self] in self?.toggleDrift()
            }
            drift.keyEquivalentModifierMask = [.control, .option]
            menu.addItem(drift)
            menu.addItem(ClosureMenuItem("Finish & log…") { [engine] in engine.finish() })
            menu.addItem(ClosureMenuItem("Discard block") { [engine] in engine.discard() })
        case .finishing:
            menu.addItem(ClosureMenuItem("Log the finished block…") { [weak self] in self?.notch.peek(seconds: 1) })
        }
        menu.addItem(.separator())
        for (page, title, key) in [(NotchPage.timer, "Open Timer", "d"), (.clipboard, "Open Clipboard", "v"),
                                   (.vision, "Open Vision Board", "b")] {
            let item = ClosureMenuItem(title, key: key) { [weak self] in self?.notch.toggle(page: page) }
            item.keyEquivalentModifierMask = [.control, .option]
            menu.addItem(item)
        }
        let textExport = ClosureMenuItem("Text to .md…", key: "m") { [weak self] in self?.notch.toggleTextExport() }
        textExport.keyEquivalentModifierMask = [.control, .option]
        menu.addItem(textExport)
        menu.addItem(ClosureMenuItem("Log & Heatmap", key: "l") { [weak self] in self?.showDashboard() })
        questions.reload()
        let open = questions.openCount
        let ask = ClosureMenuItem(open == 0 ? "Questions…" : "Questions (\(open))…", key: "q") { [weak self] in
            guard let self, !(self.notch.state.pinned && self.notch.state.questionsOpen) else { return }
            self.notch.toggleQuestions()
        }
        ask.keyEquivalentModifierMask = [.control, .option]
        ask.toolTip = "Yes/no questions from the chats, from ~/gears_OS/dashboard/questions.json"
        menu.addItem(ask)
        var remindTitle = "Recordatorios…"
        if let (r, at) = reminders?.next() { remindTitle += "  (\(r.kind.label) \(RemindersView.hm(at)))" }
        let remind = ClosureMenuItem(remindTitle) { [weak self] in self?.showReminders() }
        remind.toolTip = "A few silent reminders a night, the calendar in the notch, and quiet after the last one"
        menu.addItem(remind)
        menu.addItem(keepAwakeItem())
        menu.addItem(.separator())

        let sounds = ClosureMenuItem("Timer Sounds") { Sounds.enabled.toggle() }
        sounds.state = Sounds.enabled ? .on : .off
        menu.addItem(sounds)
        if shots.blocked {
            let blocked = ClosureMenuItem("⚠︎ No access to the screenshot folder: allow it…") { ScreenshotLibrary.openPrivacySettings() }
            blocked.toolTip = "System Settings → Privacy & Security → Files & Folders → GNotch → Desktop Folder"
            menu.addItem(blocked)
        }
        let autoCopy = ClosureMenuItem("Screenshots → Clipboard") { [shots] in shots.autoCopy.toggle() }
        autoCopy.state = shots.autoCopy ? .on : .off
        autoCopy.toolTip = "Like Ubuntu: every new screenshot is copied, ready for ⌘V"
        menu.addItem(autoCopy)
        let instant = ClosureMenuItem("Instant Screenshots (no floating thumbnail)") {
            ScreenshotSettings.setThumbnail(!ScreenshotSettings.thumbnailEnabled)
        }
        instant.state = ScreenshotSettings.thumbnailEnabled ? .off : .on
        instant.toolTip = "macOS waits ~5 s for its floating thumbnail before saving. Turn it off to copy instantly."
        menu.addItem(instant)
        menu.addItem(ClosureMenuItem("Screenshot Setup Guide") {
            NSWorkspace.shared.open(URL(string: "https://github.com/christianqp4/gnotch/blob/main/docs/SCREENSHOTS.md")!)
        })
        menu.addItem(.separator())
        let pause = ClosureMenuItem("Pause Clipboard History") { [clips] in clips.paused.toggle() }
        pause.state = clips.paused ? .on : .off
        menu.addItem(pause)
        menu.addItem(ClosureMenuItem("Clear Clipboard History…") { [clips] in
            let alert = NSAlert()
            alert.messageText = "Clear clipboard history?"
            alert.informativeText = "Pinned items are kept."
            alert.addButton(withTitle: "Clear")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn { clips.clearHistory() }
        })
        menu.addItem(.separator())

        let wings = ClosureMenuItem("Show Time Beside Notch") { [weak self] in self?.notch.state.showWings.toggle() }
        wings.state = notch.state.showWings ? .on : .off
        menu.addItem(wings)

        let login = ClosureMenuItem("Launch at Login") { Self.toggleLaunchAtLogin() }
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Quit GNotch", key: "q") { NSApp.terminate(nil) })
    }

    private func toggleDrift() {
        guard engine.isActive else { return }
        engine.togglePause()
        if engine.phase == .paused {
            notch.open(page: .timer)
        } else {
            notch.collapse()
        }
    }

    private static func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change Launch at Login"
            alert.informativeText = "\(error.localizedDescription)\n\nMove the app into /Applications and try again."
            alert.runModal()
        }
    }

    // MARK: Dashboard

    func showDashboard(addBlock: Bool = false) {
        if dashboard == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 780),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "GNotch · Deep Work"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: DashboardView(store: store, router: router))
            w.center()
            w.setFrameAutosaveName("Dashboard")
            dashboard = w
        }
        NSApp.activate(ignoringOtherApps: true)
        dashboard?.makeKeyAndOrderFront(nil)
        if addBlock { router.addRequest += 1 }
    }

    // MARK: Reminders

    private func showReminders() {
        guard let reminders else { return }
        if remindersWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 780),
                             styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "GNotch · Recordatorios"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: RemindersView(reminders: reminders))
            w.center()
            remindersWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        remindersWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: Main menu (needed so ⌘C / ⌘V / ⌘W work in text fields)

    private func setupMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit GNotch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
    }
}

extension AppDelegate {
    /// "Keep Awake" with its state, and a submenu to turn a real `caffeinate` on or off.
    func keepAwakeItem() -> NSMenuItem {
        let status = KeepAwakeMonitor.readNow()
        var title = "Keep Awake"
        switch status.state {
        case .on: title += status.timeLeft().map { ": On, \($0) left" } ?? ": On, no limit"
        case .claudeOnly: title += ": only while a chat works"
        case .off: title += ": Off"
        case .unknown: break
        }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false
        for c in KeepAwakeControl.choices {
            sub.addItem(ClosureMenuItem(c.long) { KeepAwakeControl.start(hours: c.hours, replacing: status.caffeinatePIDs) })
        }
        sub.addItem(.separator())
        let off = ClosureMenuItem("Turn Off") { KeepAwakeControl.stop(status.caffeinatePIDs) }
        off.isEnabled = !status.caffeinatePIDs.isEmpty
        sub.addItem(off)
        item.submenu = sub
        item.toolTip = "Runs caffeinate -is: no idle sleep, and no system sleep on AC. A closed lid still sleeps."
        return item
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, key: String = "", handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func fire() { handler() }
}
