import AppKit

MainActor.assumeIsolated {
    if let dir = ProcessInfo.processInfo.environment["GNOTCH_SNAPSHOT"] {
        Snapshots.run(into: URL(fileURLWithPath: dir))
        exit(0)
    }
    Migration.run()
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
