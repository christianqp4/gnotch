import AppKit

MainActor.assumeIsolated {
    if let dir = ProcessInfo.processInfo.environment["GNOTCH_SNAPSHOT"] {
        Snapshots.run(into: URL(fileURLWithPath: dir))
        exit(0)
    }
    let env = ProcessInfo.processInfo.environment
    if let text = env["GNOTCH_EXPORT_CHECK"], let folder = env["GNOTCH_EXPORT_FOLDER"] {
        let passed = Snapshots.exportCheck(textFile: URL(fileURLWithPath: text),
                                           folder: URL(fileURLWithPath: folder, isDirectory: true),
                                           title: env["GNOTCH_EXPORT_TITLE"] ?? "prueba")
        exit(passed ? 0 : 1)
    }
    if let file = env["GNOTCH_ACTIVITY_CHECK"] { exit(ActivityScanner.check(file: URL(fileURLWithPath: file)) ? 0 : 1) }
    if env["GNOTCH_KEEPAWAKE_CHECK"] != nil { exit(Snapshots.keepAwakeCheck() ? 0 : 1) }
    Migration.run()
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
