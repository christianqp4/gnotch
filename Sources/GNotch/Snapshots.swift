import AppKit
import SwiftUI

/// Dev tool: renders every notch state and the dashboard to PNGs with sample data.
/// `GNOTCH_SNAPSHOT=/some/dir ./.build/release/GNotch`
/// Uses a temporary data file and never touches the real log or saved timer.
@MainActor
enum Snapshots {
    static func run(into dir: URL) {
        _ = NSApplication.shared
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("gnotch-snapshot-\(UUID()).json")
        let store = SessionStore(fileURL: file)
        seed(store)

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("gnotch-snapshot-\(UUID())")
        let clips = ClipboardStore(dir: tmp.appendingPathComponent("clips"), monitor: false)
        let vision = VisionStore(dir: tmp.appendingPathComponent("vision"))
        seedClipboard(clips)
        seedVision(vision)
        let ambient = AmbientPlayer()
        let shotsDir = tmp.appendingPathComponent("shots")
        try? FileManager.default.createDirectory(at: shotsDir, withIntermediateDirectories: true)
        for (i, (colors, label, w, h)) in [([NSColor.systemBlue, .systemTeal], "Figma", 1600, 1000),
                                            ([.systemPink, .systemOrange], "Chat", 900, 900),
                                            ([.systemGreen, .systemMint], "Terminal", 1800, 700),
                                            ([.systemIndigo, .systemPurple], "Slides", 1440, 900),
                                            ([.systemGray, .darkGray], "Error", 700, 1000)].enumerated() {
            let url = shotsDir.appendingPathComponent("Screenshot \(i).png")
            let img = NSImage(size: NSSize(width: w, height: h), flipped: false) { rect in
                NSGradient(colors: colors)!.draw(in: rect, angle: 30)
                NSAttributedString(string: label, attributes: [.font: NSFont.boldSystemFont(ofSize: 120),
                                                               .foregroundColor: NSColor.white]).draw(at: NSPoint(x: 60, y: 60))
                return true
            }
            try? img.pngData()?.write(to: url)
            setxattr(url.path, "com.apple.metadata:kMDItemIsScreenCapture", "1", 1, 0, 0)
        }
        var shots = ScreenshotLibrary(folder: shotsDir, watch: false)

        let day = Calendar.current.startOfDay(for: Date())
        let at = { (h: Double) in day.addingTimeInterval(h * 3600) }
        let timeline = TimelineStore(sample: [
            DayEvent(date: at(1.04), kind: .displayOff), DayEvent(date: at(2.24), kind: .displayOn),
            DayEvent(date: at(4.36), kind: .shutdown), DayEvent(date: at(14.29), kind: .boot),
            DayEvent(date: at(14.31), kind: .login), DayEvent(date: at(14.31), kind: .launch, app: "Claude"),
        ])

        SnapshotHints.keepAwake = KeepAwakeStatus.parse(assertions: KeepAwakeSamples.caffeinate, power: KeepAwakeSamples.ac)
        let notch = CGSize(width: 185, height: 32)
        func notchShot(_ name: String, hovering: Bool, wings: Bool = true, page: NotchPage = .timer,
                       large: Bool = false, dragging: DropZone? = nil, textExport: (String, String)? = nil, setup: (TimerEngine) -> Void) {
            let engine = TimerEngine(store: store, persistsState: false)
            let state = NotchState()
            state.notchSize = notch
            state.hovering = hovering
            state.showWings = wings
            state.page = page
            state.large = large
            state.pinned = page != .timer
            if let dragging {
                state.dragging = true
                state.dropZone = dragging
            }
            if let textExport {
                state.textExportOpen = true
                (state.textExport.title, state.textExport.text) = textExport
            }
            setup(engine)
            let view = ZStack(alignment: .top) {
                LinearGradient(colors: [Color(red: 0.35, green: 0.45, blue: 0.6), Color(red: 0.75, green: 0.6, blue: 0.55)],
                               startPoint: .top, endPoint: .bottom)
                Rectangle().fill(Color.white.opacity(0.25)).frame(height: notch.height)
                NotchRootView(engine: engine, store: store, clips: clips, vision: vision, shots: shots, state: state,
                              ambient: ambient, timeline: timeline, openLog: {}, addPast: {}, collapse: {}, onDrop: { _, _ in })
            }
            render(view, size: CGSize(width: 900, height: notch.height + 600), dark: true,
                   to: dir.appendingPathComponent("notch-\(name).png"))
        }

        notchShot("1-collapsed-running", hovering: false) { e in
            e.task = "Thesis chapter 3"; e.start(minutes: 50); e.simulate(elapsed: 18 * 60 + 25)
        }
        notchShot("1b-collapsed-outline-only", hovering: false, wings: false) { e in
            e.start(minutes: 50); e.simulate(elapsed: 30 * 60)
        }
        notchShot("2-idle-expanded", hovering: true) { _ in }
        notchShot("3-running-expanded", hovering: true) { e in
            e.task = "Thesis chapter 3"; e.start(minutes: 50); e.simulate(elapsed: 18 * 60 + 25)
            e.simulate(drifts: [(6 * 60, 50), (13 * 60, 95)])
        }
        notchShot("4-paused-collapsed", hovering: false) { e in
            e.start(minutes: 90); e.pause(); e.simulate(elapsed: 41 * 60)
        }
        notchShot("5-overtime-expanded", hovering: true) { e in
            e.task = "Gears HUD watch sync"; e.start(minutes: 25); e.simulate(elapsed: 31 * 60 + 4)
        }
        notchShot("6-finish", hovering: false) { e in
            e.task = "Gears HUD watch sync"; e.start(minutes: 50); e.simulate(elapsed: 52 * 60)
            e.simulate(drifts: [(9 * 60, 70), (31 * 60, 150), (44 * 60, 40)]); e.finish()
        }

        notchShot("7-clipboard", hovering: true, page: .clipboard) { e in
            e.start(minutes: 50); e.simulate(elapsed: 12 * 60)
        }
        notchShot("8-clipboard-large", hovering: true, page: .clipboard, large: true) { _ in }
        notchShot("9-vision", hovering: true, page: .vision) { _ in }
        notchShot("10-vision-large", hovering: true, page: .vision, large: true) { _ in }
        notchShot("12-timer-large-idle", hovering: true, large: true) { _ in }
        notchShot("13-timer-large-running", hovering: true, large: true) { e in
            e.task = "Library: thesis reading"; e.start(minutes: 90); e.simulate(elapsed: 47 * 60 + 12)
            e.simulate(drifts: [(11 * 60, 80)])
        }
        notchShot("15-paused-expanded", hovering: true) { e in
            e.task = "Thesis chapter 3"; e.start(minutes: 50); e.pause(); e.simulate(elapsed: 23 * 60)
            e.simulate(drifts: [(8 * 60, 60)])
        }
        notchShot("16-large-paused", hovering: true, large: true) { e in
            e.task = "Library: thesis reading"; e.start(minutes: 90); e.pause(); e.simulate(elapsed: 35 * 60)
            e.simulate(drifts: [(11 * 60, 80)])
        }
        UserDefaults.standard.set("Screenshots", forKey: "clipboardFilter")
        notchShot("14-screenshots", hovering: true, page: .clipboard) { _ in }
        // A folder macOS won't let us read, like the Desktop after "Don't Allow".
        let lockedDir = tmp.appendingPathComponent("locked")
        try? FileManager.default.createDirectory(at: lockedDir, withIntermediateDirectories: true)
        chmod(lockedDir.path, 0)
        let lockedShots = ScreenshotLibrary(folder: lockedDir, watch: false)
        print("screenshot folder blocked detected: \(lockedShots.blocked)")
        let savedShots = shots
        shots = lockedShots
        notchShot("14b-screenshots-blocked", hovering: true, page: .clipboard) { _ in }
        shots = savedShots
        chmod(lockedDir.path, 0o755)
        UserDefaults.standard.removeObject(forKey: "clipboardFilter")
        notchShot("11-drop", hovering: true, dragging: .vision) { _ in }
        SnapshotHints.keepAwakeCard = true
        notchShot("22-keep-awake-on-card", hovering: true, page: .clipboard) { _ in }
        SnapshotHints.keepAwake = KeepAwakeStatus.parse(assertions: KeepAwakeSamples.accidental, power: KeepAwakeSamples.battery)
        notchShot("23-keep-awake-off-card", hovering: true, page: .clipboard) { _ in }
        SnapshotHints.keepAwakeCard = false
        notchShot("24-keep-awake-off-timer", hovering: true) { _ in }
        SnapshotHints.keepAwake = KeepAwakeStatus.parse(assertions: KeepAwakeSamples.caffeinate, power: KeepAwakeSamples.ac)
        notchShot("25-keep-awake-on-running", hovering: true) { e in
            e.task = "Thesis chapter 3"; e.start(minutes: 50); e.simulate(elapsed: 18 * 60 + 25)
        }
        notchShot("20-text-export-empty", hovering: true, page: .clipboard, textExport: ("", "")) { _ in }
        notchShot("21-text-export", hovering: true, page: .clipboard, textExport: (
            "jueves, noviembre 5",
            String(repeating: "Hoy me levanté tarde, pero el café de la mañana sabía a mandarina y pensé en España. ", count: 40)
        )) { _ in }

        // Heatmap styles and the hover card. The user's own style setting is put back afterwards.
        let savedStyle = UserDefaults.standard.string(forKey: "heatStyle")
        let cal = Calendar.current
        let hovered = cal.date(byAdding: .day, value: -2, to: cal.startOfDay(for: Date()))!
        let row = (cal.component(.weekday, from: hovered) - cal.firstWeekday + 7) % 7
        for style in HeatStyle.allCases {
            UserDefaults.standard.set(style.rawValue, forKey: "heatStyle")
            let tag = style == .year ? "year" : "calendar"
            notchShot("17-idle-\(tag)", hovering: true) { _ in }
            notchShot("18-timer-large-\(tag)", hovering: true, large: true) { _ in }
            render(DashboardView(store: store, router: DashboardRouter()), size: CGSize(width: 940, height: 1100), dark: true,
                   to: dir.appendingPathComponent("dashboard-\(tag).png"))
        }
        UserDefaults.standard.set(HeatStyle.year.rawValue, forKey: "heatStyle")
        SnapshotHints.hover = HeatHover(day: hovered, point: CGPoint(x: 26 + 51 * 14 + 5, y: 17 + CGFloat(row) * 14 + 5))
        notchShot("19-idle-hover", hovering: true) { _ in }
        render(DashboardView(store: store, router: DashboardRouter()), size: CGSize(width: 940, height: 1100), dark: true,
               to: dir.appendingPathComponent("dashboard-hover.png"))
        SnapshotHints.hover = nil
        if let savedStyle {
            UserDefaults.standard.set(savedStyle, forKey: "heatStyle")
        } else {
            UserDefaults.standard.removeObject(forKey: "heatStyle")
        }

        render(SessionEditor(draft: SessionEditor.blank(), isNew: true, others: store.sessions,
                             onSave: { _ in }, onDelete: {}, onCancel: {})
                    .background(Color(nsColor: .windowBackgroundColor)),
               size: CGSize(width: 500, height: 640), dark: true, to: dir.appendingPathComponent("editor-add.png"))

        for dark in [false, true] {
            render(DashboardView(store: store, router: DashboardRouter()), size: CGSize(width: 940, height: 1100), dark: dark,
                   to: dir.appendingPathComponent("dashboard-\(dark ? "dark" : "light").png"))
        }
        try? FileManager.default.removeItem(at: file)
        try? FileManager.default.removeItem(at: tmp)
        print("Snapshots written to \(dir.path)")
    }

    /// Dev check of the keep-awake status: `GNOTCH_KEEPAWAKE_CHECK=1 GNotch`. Only reads `pmset`.
    static func keepAwakeCheck() -> Bool {
        var ok = true
        func check(_ name: String, _ pass: Bool) {
            print("\(pass ? "PASS" : "FAIL")  \(name)")
            if !pass { ok = false }
        }
        let now = Date()
        let on = KeepAwakeStatus.parse(assertions: KeepAwakeSamples.caffeinate, power: KeepAwakeSamples.ac, now: now)
        check("caffeinate -is -t counts as on", on.state == .on)
        check("its time left comes from the timeout", on.ends == now.addingTimeInterval(43057) && on.timeLeft(now) == "11h 58m")
        check("AC power and battery are read", on.onAC == true && on.battery == "46% charging")
        check("accidental holders are listed, not counted",
              on.others == ["Handoff", "the display being on", "WhatsApp"])

        let off = KeepAwakeStatus.parse(assertions: KeepAwakeSamples.accidental, power: KeepAwakeSamples.battery)
        check("WhatsApp, Handoff and powerd alone are off", off.state == .off && off.ends == nil)
        check("battery is read", off.onAC == false && off.battery == "42% discharging")

        let claude = KeepAwakeStatus.parse(assertions: KeepAwakeSamples.claude, power: KeepAwakeSamples.ac)
        check("Claude alone is 'while working', not on", claude.state == .claudeOnly)

        let noLimit = KeepAwakeStatus.parse(assertions: KeepAwakeSamples.noLimit, power: KeepAwakeSamples.ac)
        check("caffeinate without -t is on, no time limit", noLimit.state == .on && noLimit.ends == nil)

        let sOnly = KeepAwakeSamples.noLimit.replacingOccurrences(of: "PreventUserIdleSystemSleep", with: "PreventSystemSleep")
        let sAC = KeepAwakeStatus.parse(assertions: sOnly, power: KeepAwakeSamples.ac)
        let sBattery = KeepAwakeStatus.parse(assertions: sOnly, power: KeepAwakeSamples.battery)
        check("caffeinate -s alone is on with AC", sAC.state == .on)
        check("caffeinate -s alone is off on battery", sBattery.state == .off && sBattery.caffeinateIgnoredOnBattery)

        let display = KeepAwakeSamples.noLimit.replacingOccurrences(of: "PreventUserIdleSystemSleep", with: "PreventUserIdleDisplaySleep")
        check("caffeinate -d alone doesn't count",
              KeepAwakeStatus.parse(assertions: display, power: KeepAwakeSamples.ac).state == .off)
        check("unreadable output is unknown, not off",
              KeepAwakeStatus.parse(assertions: "garbage", power: "").state == .unknown)

        let live = KeepAwakeMonitor.readNow()
        print("      live: \(live.state), left \(live.timeLeft() ?? "-"), AC \(live.onAC.map(String.init) ?? "?"), battery \(live.battery ?? "?"), others \(live.others)")
        return ok
    }

    /// Dev check of "Text to .md": `GNOTCH_EXPORT_CHECK=text.txt GNOTCH_EXPORT_FOLDER=/tmp/x GNOTCH_EXPORT_TITLE=… GNotch`.
    /// Writes only into that folder. The pasteboard writes carry the transient marker, so a running
    /// GNotch keeps them out of the history. The file stays on the pasteboard at the end.
    static func exportCheck(textFile: URL, folder: URL, title: String) -> Bool {
        _ = NSApplication.shared
        let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
        let pb = NSPasteboard.general
        var ok = true
        func check(_ name: String, _ pass: Bool) {
            print("\(pass ? "PASS" : "FAIL")  \(name)")
            if !pass { ok = false }
        }
        guard let bytes = try? Data(contentsOf: textFile), let text = String(data: bytes, encoding: .utf8) else {
            print("FAIL  can't read \(textFile.path)")
            return false
        }

        pb.clearContents()
        pb.setString(text, forType: .string)
        pb.setString("", forType: transient)
        let tv = PlainTextEditor.makeTextView()
        let start = Date()
        tv.paste(nil)
        print(String(format: "      pasted %d bytes in %.0f ms", bytes.count, Date().timeIntervalSince(start) * 1000))
        check("the text area keeps the paste unchanged", Data(tv.string.utf8) == bytes)

        let expected = Data("# \(title)\n\n".utf8) + bytes
        do {
            let first = try TextExport.write(title: title, text: tv.string, folder: folder)
            print("      \(first.path)")
            check("file name comes from the title", first.lastPathComponent == "\(TextExport.fileBase(for: title)).md")
            check("file is heading + exact text", (try? Data(contentsOf: first)) == expected)

            let second = try TextExport.write(title: title, text: "otra entrada", folder: folder)
            print("      \(second.lastPathComponent)")
            check("same title doesn't overwrite", second != first && second.lastPathComponent.contains(" (2)"))
            check("the first file is intact", (try? Data(contentsOf: first)) == expected)

            TextExport.putOnPasteboard(first, pb)
            pb.addTypes([transient], owner: nil)
            pb.setString("", forType: transient)
            print("      pasteboard: \((pb.types ?? []).map(\.rawValue).joined(separator: ", "))")
            let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
            check("pasteboard holds the file URL", urls?.first?.standardizedFileURL == first.standardizedFileURL)
        } catch {
            check("write: \(error.localizedDescription)", false)
        }

        // History: the file replaces the text entry that copying the same text left behind.
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("gnotch-export-check-\(UUID())")
        let clips = ClipboardStore(dir: tmp, monitor: false)
        clips.add(.text(text), source: "Test")
        clips.add(.text("otra cosa"), source: "Test")
        clips.togglePin(clips.items[0].id)
        let exported = folder.appendingPathComponent("\(TextExport.fileBase(for: title)).md")
        clips.addExportedFile(exported, sourceText: text)
        pb.addTypes([transient], owner: nil)
        pb.setString("", forType: transient)
        check("history: file on top, no duplicate of the text, pinned item kept",
              clips.items.first?.kind == .file && clips.items.first?.paths == [exported.path]
                  && !clips.items.contains { $0.text == text } && clips.items.contains { $0.pinned })
        print("      history stores \(clips.items.count) items, file source: \(clips.items.first?.sourceApp ?? "-")")
        try? FileManager.default.removeItem(at: tmp)

        for (title, name) in [("a/b: c", "a-b- c"), ("  .oculto  ", "oculto"), ("nota.md", "nota"),
                              ("dos\nlíneas", "dos líneas"), ("mañana, señor Ñandú", "mañana, señor Ñandú")] {
            check("name \"\(title)\" → \"\(name)\"", TextExport.fileBase(for: title) == name)
        }
        check("very long title fits a file name", TextExport.fileBase(for: String(repeating: "ñ", count: 400)).utf8.count <= 240)
        check("empty title uses today's date", TextExport.fileBase(for: "") == TextExport.todayTitle())
        print("      today: \(TextExport.todayTitle())")
        return ok
    }

    private static func render<V: View>(_ view: V, size: CGSize, dark: Bool, to url: URL) {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.backgroundColor = dark ? NSColor(white: 0.12, alpha: 1) : .white
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    private static func swatch(_ colors: [NSColor], _ label: String) -> NSImage {
        NSImage(size: NSSize(width: 600, height: 600), flipped: false) { rect in
            NSGradient(colors: colors)!.draw(in: rect, angle: 60)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 64, weight: .heavy),
                .foregroundColor: NSColor.white.withAlphaComponent(0.85),
            ]
            let s = NSAttributedString(string: label, attributes: attrs)
            s.draw(at: NSPoint(x: 40, y: 50))
            return true
        }
    }

    private static func seedClipboard(_ clips: ClipboardStore) {
        for i in 1...14 { clips.add(.text("Older clip #\(i)"), source: "Notes") }
        clips.add(.files([URL(fileURLWithPath: "/Users/you/Gears_projects/Recorder_Gears/notes.md"),
                          URL(fileURLWithPath: "/Users/you/Desktop/plan.pdf")]), source: "Finder")
        clips.add(.image(swatch([.systemTeal, .systemIndigo], "Screenshot")), source: "Screenshot")
        clips.add(.text("Deep work is the ability to focus without distraction on a cognitively demanding task."), source: "Safari")
        clips.add(.text("https://github.com/christianqp4/gnotch"), source: "Arc")
        clips.add(.text("func toggle(page: NotchPage) {\n    state.page = page\n}"), source: "Xcode")
        clips.add(.text("Meeting moved to 16:30, bring the Gears HUD prototype"), source: "Messages")
        let pinned = clips.items.first { $0.text?.hasPrefix("Deep work") == true }!
        clips.togglePin(pinned.id)
        clips.add(.text("Madrid 4G budget: rent 950, food 380, gym 45"), source: "Numbers")
    }

    private static func seedVision(_ vision: VisionStore) {
        vision.add([
            .image(swatch([.systemOrange, .systemPink], "Lisbon")),
            .text("Ship Gears HUD 1.0 before spring"),
            .image(swatch([.systemGreen, .systemTeal], "Strong")),
            .image(swatch([.systemPurple, .systemBlue], "Studio")),
            .text("4 hours of deep work, every weekday"),
            .image(swatch([.systemYellow, .systemOrange], "Sunrise")),
            .text("Calm is a superpower"),
        ])
    }

    /// Roughly a year of plausible deep work, deterministic.
    private static func seed(_ store: SessionStore) {
        var rng = SplitMix(seed: 42)
        let cal = Calendar.current
        let tasks = ["Thesis chapter 3", "Gears HUD watch sync", "Reading: Deep Work", "Landing page", "Finances model"]
        let notes = [
            "Phone in another room helped. First 15 min were rough, then it clicked.",
            "Slight headache halfway. Coffee at 10 was a mistake.",
            "Lost in it, didn't notice the time. Hands warm, breathing slow.",
            "Kept checking messages. Need the website blocker on.",
            "",
        ]
        let today = cal.startOfDay(for: Date())
        for back in stride(from: 300, through: 0, by: -1) {
            let day = cal.date(byAdding: .day, value: -back, to: today)!
            let activeChance = back < 60 ? 0.85 : 0.55
            guard rng.next() < activeChance else { continue }
            let blocks = 1 + Int(rng.next() * 3)
            var t = cal.date(bySettingHour: 8 + Int(rng.next() * 3), minute: Int(rng.next() * 50), second: 0, of: day)!
            for _ in 0..<blocks {
                let mins = [25.0, 50, 50, 90, 75, 40][Int(rng.next() * 6)]
                let intensity = 1 + Int(rng.next() * 5)
                let tags = SensationTags.all.filter { _ in rng.next() < 0.18 }
                if t.addingTimeInterval(mins * 60) > Date() { break }
                store.add(DeepWorkSession(
                    start: t, end: t.addingTimeInterval(mins * 60), duration: mins * 60,
                    plannedMinutes: Int(mins), task: tasks[Int(rng.next() * Double(tasks.count))],
                    intensity: intensity, tags: tags, notes: notes[Int(rng.next() * Double(notes.count))],
                    pauses: back < 40 ? (0..<Int(rng.next() * 4)).map { k in
                        let at = t.addingTimeInterval(Double(k + 1) * mins * 60 / 5)
                        return PauseSpan(start: at, end: at.addingTimeInterval(30 + rng.next() * 150))
                    } : nil,
                    location: ["Library", "House", "House", "Coworking", "Coffee", "Biblioteca Retiro"][Int(rng.next() * 6)]))
                t = t.addingTimeInterval(mins * 60 + 30 * 60)
            }
        }
        // Auto blocks (chats, commits): evenings over the last 40 days, some on days with nothing timed.
        let names = ["GNotch", "Umami", "Day chat", "Specialty Media", "GearsOS"]
        var auto: [ActivityBlock] = []
        for back in stride(from: 40, through: 0, by: -1) where back == 2 || rng.next() < 0.6 {
            let day = cal.date(byAdding: .day, value: -back, to: today)!
            for (hour, mins) in [(15.0, 50.0 + rng.next() * 60), (19.5, 90 + rng.next() * 150)] {
                let start = day.addingTimeInterval(hour * 3600 + rng.next() * 1800)
                guard start.addingTimeInterval(mins * 60) < Date() else { continue }
                let first = Int(rng.next() * 5)
                let count = 1 + Int(rng.next() * 3)
                var projects: [String: Int] = [:]
                for k in 0..<count { projects[names[(first + k) % names.count]] = 200 - 50 * k }
                let chats: [String] = (0..<count + 1).map { "chat-\(back)-\($0)" }
                let commits = Int(rng.next() * 4)
                auto.append(ActivityBlock(start: start, end: start.addingTimeInterval(mins * 60),
                                          projects: projects, commits: commits, messages: 300, chats: chats))
            }
        }
        store.setAuto(auto)
    }
}

private struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
    }
}

/// Real `pmset` output, for snapshots and the keep-awake check.
enum KeepAwakeSamples {
    static let ac = """
    Now drawing from 'AC Power'
     -InternalBattery-0 (id=22151267)\t46%; charging; 1:13 remaining present: true
    """
    static let battery = """
    Now drawing from 'Battery Power'
     -InternalBattery-0 (id=22151267)\t42%; discharging; 4:02 remaining present: true
    """
    private static let accidentalLines = """
       pid 648(sharingd): [0x00005e8e00018c67] 00:04:58 PreventUserIdleSystemSleep named: "Handoff"
       pid 338(powerd): [0x000038a900018600] 02:46:39 PreventUserIdleSystemSleep named: "Powerd - Prevent sleep while display is on"
       pid 338(powerd): [0x00005ee900098c82] 00:03:27 UserIsActive named: "com.apple.powermanagement.lidopen"
    \tTimeout will fire in 992 secs Action=TimeoutActionRelease
       pid 628(WhatsApp): [0x0000003900018161] 06:47:27 PreventUserIdleSystemSleep named: "cameracaptured-idleSleepPreventionForBWFigCaptureDevice"
    """
    private static let head = """
    2026-11-05 17:46:54 +0100
    Assertion status system-wide:
       PreventSystemSleep             1
       PreventUserIdleSystemSleep     1
    Listed by owning process:
    """
    static let accidental = head + "\n" + accidentalLines
    static let claude = accidental + """

       pid 622(Claude): [0x00005f0e00018d04] 00:02:50 NoIdleSleepAssertion named: "Electron"
    """
    static let caffeinate = claude + """

       pid 12359(caffeinate): [0x00005f2900018d4b] 00:02:23 PreventUserIdleSystemSleep named: "caffeinate command-line tool"
    \tDetails: caffeinate asserting for 43200 secs
    \tLocalized=THE CAFFEINATE TOOL IS PREVENTING SLEEP.
    \tTimeout will fire in 43057 secs Action=TimeoutActionRelease
       pid 12359(caffeinate): [0x00005f2900078d4c] 00:02:23 PreventSystemSleep named: "caffeinate command-line tool"
    \tDetails: caffeinate asserting for 43200 secs
    \tTimeout will fire in 43057 secs Action=TimeoutActionRelease
    """
    static let noLimit = head + """

       pid 77(caffeinate): [0x00005f2900018d4b] 00:02:23 PreventUserIdleSystemSleep named: "caffeinate command-line tool"
    \tLocalized=THE CAFFEINATE TOOL IS PREVENTING SLEEP.
    """
}
