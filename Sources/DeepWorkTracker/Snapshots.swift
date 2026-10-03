import AppKit
import SwiftUI

/// Dev tool: renders every notch state and the dashboard to PNGs with sample data.
/// `DEEPWORK_SNAPSHOT=/some/dir ./.build/release/DeepWorkTracker`
/// Uses a temporary data file and never touches the real log or saved timer.
@MainActor
enum Snapshots {
    static func run(into dir: URL) {
        _ = NSApplication.shared
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("deepwork-snapshot-\(UUID()).json")
        let store = SessionStore(fileURL: file)
        seed(store)

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("deepwork-snapshot-\(UUID())")
        let clips = ClipboardStore(dir: tmp.appendingPathComponent("clips"), monitor: false)
        let vision = VisionStore(dir: tmp.appendingPathComponent("vision"))
        seedClipboard(clips)
        seedVision(vision)

        let notch = CGSize(width: 185, height: 32)
        func notchShot(_ name: String, hovering: Bool, wings: Bool = true, page: NotchPage = .timer,
                       large: Bool = false, dragging: DropZone? = nil, setup: (TimerEngine) -> Void) {
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
            setup(engine)
            let view = ZStack(alignment: .top) {
                LinearGradient(colors: [Color(red: 0.35, green: 0.45, blue: 0.6), Color(red: 0.75, green: 0.6, blue: 0.55)],
                               startPoint: .top, endPoint: .bottom)
                Rectangle().fill(Color.white.opacity(0.25)).frame(height: notch.height)
                NotchRootView(engine: engine, store: store, clips: clips, vision: vision, state: state,
                              openLog: {}, collapse: {}, onDrop: { _, _ in })
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
        }
        notchShot("4-paused-collapsed", hovering: false) { e in
            e.start(minutes: 90); e.pause(); e.simulate(elapsed: 41 * 60)
        }
        notchShot("5-overtime-expanded", hovering: true) { e in
            e.task = "Gears HUD watch sync"; e.start(minutes: 25); e.simulate(elapsed: 31 * 60 + 4)
        }
        notchShot("6-finish", hovering: false) { e in
            e.task = "Gears HUD watch sync"; e.start(minutes: 50); e.simulate(elapsed: 52 * 60); e.finish()
        }

        notchShot("7-clipboard", hovering: true, page: .clipboard) { e in
            e.start(minutes: 50); e.simulate(elapsed: 12 * 60)
        }
        notchShot("8-clipboard-large", hovering: true, page: .clipboard, large: true) { _ in }
        notchShot("9-vision", hovering: true, page: .vision) { _ in }
        notchShot("10-vision-large", hovering: true, page: .vision, large: true) { _ in }
        notchShot("11-drop", hovering: true, dragging: .vision) { _ in }

        for dark in [false, true] {
            render(DashboardView(store: store), size: CGSize(width: 940, height: 1100), dark: dark,
                   to: dir.appendingPathComponent("dashboard-\(dark ? "dark" : "light").png"))
        }
        try? FileManager.default.removeItem(at: file)
        try? FileManager.default.removeItem(at: tmp)
        print("Snapshots written to \(dir.path)")
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
        clips.add(.text("https://github.com/christianqp4/deepwork-tracker"), source: "Arc")
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
                    intensity: intensity, tags: tags, notes: notes[Int(rng.next() * Double(notes.count))]))
                t = t.addingTimeInterval(mins * 60 + 30 * 60)
            }
        }
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
