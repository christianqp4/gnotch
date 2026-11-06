import AppKit
import Combine
import CoreAudio
import SwiftUI

/// Which apps are playing sound right now, and a mute for each one, like Windows' volume mixer.
///
/// macOS lists every process that uses Core Audio (`kAudioHardwarePropertyProcessObjectList`), so
/// reading the list needs no permission. Muting one app is a Core Audio process tap with
/// `muteBehavior = .muted` (macOS 14.2+): that app's sound stops reaching the speakers while every
/// other app keeps playing. No driver, nothing installed. Mutes live only while GNotch runs: they
/// are not saved, and quitting GNotch gives the sound back.
///
/// macOS sees processes, not tabs: muting Claude mutes every tab of its browser pane together.
struct SoundApp: Identifiable, Equatable {
    /// The owning app's bundle id, or its name: stays the same when the app's audio helper restarts.
    var id: String
    var name: String
    var pid: pid_t?
    var playing: Bool
    var muted: Bool
    /// Core Audio process objects that belong to this app (an app and its helpers).
    var clients: [AudioObjectID]
}

@MainActor
final class SoundMixer: ObservableObject {
    static let shared = SoundMixer()

    /// Apps playing now, plus any muted app (so it can be unmuted even while quiet).
    @Published private(set) var apps: [SoundApp] = SnapshotHints.sound ?? []
    /// Ids of the muted apps, in the order they were muted.
    @Published private(set) var mutedIDs: [String] = SnapshotHints.sound?.filter(\.muted).map(\.id) ?? []
    @Published private(set) var lastError: String?

    var mutedNames: [String] { mutedIDs.map { id in apps.first { $0.id == id }?.name ?? names[id] ?? id } }
    var playingCount: Int { apps.filter(\.playing).count }

    static var canMute: Bool {
        if #available(macOS 14.2, *) { return true }
        return false
    }

    private var taps: [String: (tap: AudioObjectID, clients: Set<AudioObjectID>)] = [:]
    private var names: [String: String] = [:]
    private var watchers = 0
    private var timer: Timer?
    private var listening = false

    private init() {}

    /// Snapshots only: show a fixed list instead of the live one.
    func showSample(_ list: [SoundApp]) {
        SnapshotHints.sound = list
        apps = list
        mutedIDs = list.filter(\.muted).map(\.id)
    }

    // MARK: Watching

    /// The list refreshes every second while something shows it. Collapsed, it costs nothing.
    func startWatching() {
        guard SnapshotHints.sound == nil else { return }
        watchers += 1
        refresh()
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        t.tolerance = 0.3
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stopWatching() {
        watchers = max(0, watchers - 1)
        guard watchers == 0 else { return }
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        guard SnapshotHints.sound == nil else { return }
        let clients = Self.readClients()
        var groups: [String: SoundApp] = [:]
        for c in clients where c.pid != getpid() {
            let owner = Self.owner(of: c)
            names[owner.id] = owner.name
            var app = groups[owner.id] ?? SoundApp(id: owner.id, name: owner.name, pid: owner.pid,
                                                    playing: false, muted: false, clients: [])
            app.clients.append(c.object)
            app.playing = app.playing || c.running
            groups[owner.id] = app
        }
        // A muted app's helper may have restarted with a new process: tap the new one too.
        for id in mutedIDs {
            let now = Set(groups[id]?.clients ?? [])
            if !now.isEmpty, now != taps[id]?.clients { applyTap(id: id, clients: now) }
        }
        let muted = Set(mutedIDs)
        var list = groups.values.filter { $0.playing || muted.contains($0.id) }
        for i in list.indices { list[i].muted = muted.contains(list[i].id) }
        // A muted app that has quit stays listed until it's unmuted.
        for id in mutedIDs where groups[id] == nil {
            list.append(SoundApp(id: id, name: names[id] ?? id, pid: nil, playing: false, muted: true, clients: []))
        }
        list.sort { ($0.muted ? 0 : 1, $0.name.lowercased()) < ($1.muted ? 0 : 1, $1.name.lowercased()) }
        if list != apps { apps = list }
    }

    // MARK: Muting

    func toggle(_ app: SoundApp) {
        mutedIDs.contains(app.id) ? unmute(app.id) : mute(app)
    }

    func mute(_ app: SoundApp) {
        guard !mutedIDs.contains(app.id), !app.clients.isEmpty else { return }
        names[app.id] = app.name
        guard applyTap(id: app.id, clients: Set(app.clients)) else { return }
        mutedIDs.append(app.id)
        listenForNewProcesses()
        refresh()
    }

    func unmute(_ id: String) {
        removeTap(id)
        mutedIDs.removeAll { $0 == id }
        refresh()
    }

    func unmuteAll() {
        for id in mutedIDs { removeTap(id) }
        mutedIDs = []
        refresh()
    }

    @discardableResult
    private func applyTap(id: String, clients: Set<AudioObjectID>) -> Bool {
        guard #available(macOS 14.2, *) else {
            lastError = "Muting one app needs macOS 14.2 or later."
            return false
        }
        removeTap(id)
        let desc = CATapDescription(stereoMixdownOfProcesses: clients.sorted())
        desc.name = "GNotch mute: \(names[id] ?? id)"
        desc.isPrivate = true
        desc.muteBehavior = .muted
        var tap = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(desc, &tap)
        guard status == noErr, tap != kAudioObjectUnknown else {
            lastError = "Couldn't mute \(names[id] ?? id) (Core Audio error \(status))."
            return false
        }
        lastError = nil
        taps[id] = (tap, clients)
        return true
    }

    private func removeTap(_ id: String) {
        guard let entry = taps.removeValue(forKey: id) else { return }
        if #available(macOS 14.2, *) { AudioHardwareDestroyProcessTap(entry.tap) }
    }

    /// While something is muted, a new audio process (a restarted helper) re-taps at once,
    /// even with the notch closed.
    private func listenForNewProcesses() {
        guard !listening else { return }
        listening = true
        var address = Self.address(kAudioHardwarePropertyProcessObjectList)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, !self.mutedIDs.isEmpty else { return }
                self.refresh()
            }
        }
    }

    // MARK: Reading Core Audio

    struct Client {
        var object: AudioObjectID
        var pid: pid_t
        var bundleID: String
        var running: Bool
    }

    nonisolated static func readClients() -> [Client] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard let pid: pid_t = read(id, kAudioProcessPropertyPID) else { return nil }
            let running: UInt32 = read(id, kAudioProcessPropertyIsRunningOutput) ?? 0
            return Client(object: id, pid: pid, bundleID: readString(id, kAudioProcessPropertyBundleID) ?? "",
                          running: running != 0)
        }
    }

    nonisolated private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    nonisolated private static func read<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> T? {
        var address = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        let value = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { value.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, value) == noErr else { return nil }
        return value.pointee
    }

    nonisolated private static func readString(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    // MARK: Which app a process belongs to

    /// Helpers play the sound, not the app: Claude's audio comes from "Claude Helper", Safari's from
    /// "Safari Graphics and Media", Brave's from "Brave Browser Helper". Walk up to the real app.
    static func owner(of c: Client) -> (id: String, name: String, pid: pid_t?) {
        // 1. A parent process that is a real app (Electron and Chromium helpers).
        var pid = c.pid
        for _ in 0..<6 {
            if let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy != .prohibited,
               app.bundleURL?.pathExtension == "app", !(app.bundleURL?.path.contains(".app/Contents/") ?? false) {
                return (app.bundleIdentifier ?? app.localizedName ?? "\(pid)", cleanName(app.localizedName ?? "pid \(pid)"), app.processIdentifier)
            }
            guard let parent = parentPID(pid), parent > 1 else { break }
            pid = parent
        }
        // 2. A running app whose bundle id prefixes the helper's (com.brave.Browser.helper → com.brave.Browser).
        if !c.bundleID.isEmpty {
            let match = NSWorkspace.shared.runningApplications
                .filter { app in app.bundleIdentifier.map { c.bundleID.hasPrefix($0 + ".") } ?? false }
                .max { ($0.bundleIdentifier?.count ?? 0) < ($1.bundleIdentifier?.count ?? 0) }
            if let app = match, let bid = app.bundleIdentifier {
                return (bid, cleanName(app.localizedName ?? bid), app.processIdentifier)
            }
        }
        // 3. Its own name, without the helper part ("Safari Graphics and Media" → Safari).
        let raw = NSRunningApplication(processIdentifier: c.pid)?.localizedName ?? processName(c.pid) ?? c.bundleID
        let name = cleanName(raw)
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name && $0.activationPolicy == .regular }),
           let bid = app.bundleIdentifier {
            return (bid, name, app.processIdentifier)
        }
        let id = name.isEmpty ? "pid \(c.pid)" : name
        return (id, name.isEmpty ? "pid \(c.pid)" : name, c.pid)
    }

    static func cleanName(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\u{200E}\u{200F}").union(.whitespaces))
        for suffix in [" Graphics and Media", " Helper (Renderer)", " Helper (GPU)", " Helper (Plugin)", " Helper",
                       " Web Content", " Networking"] where name.hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
        }
        return name
    }

    nonisolated private static func parentPID(_ pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    nonisolated private static func processName(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 1024)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }
}

// MARK: - Views

/// The speaker in the top band: how many apps are playing, red with a slash while any is muted.
struct SoundBadge: View {
    @ObservedObject var mixer: SoundMixer
    @Binding var open: Bool

    var body: some View {
        let muted = mixer.mutedIDs.count
        Button {
            open.toggle()
            mixer.refresh()
        } label: {
            HStack(spacing: 2) {
                Image(systemName: muted > 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 10))
                if muted > 0 {
                    Text("\(muted)").font(.system(size: 10.5, weight: .bold)).monospacedDigit()
                } else if mixer.playingCount > 0 {
                    Text("\(mixer.playingCount)").font(.system(size: 10.5, weight: .bold)).monospacedDigit()
                }
            }
            .foregroundStyle(muted > 0 ? Color.red : open ? Color.white : Color.secondary)
            .padding(.horizontal, 3)
            .frame(minHeight: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(muted > 0 ? "Muted: \(mixer.mutedNames.joined(separator: ", "))" : "Sound: who's playing")
        .onAppear { mixer.startWatching() }
        .onDisappear {
            mixer.stopWatching()
            open = false
        }
        .accessibilityLabel(muted > 0 ? "\(muted) app muted" : "\(mixer.playingCount) apps playing sound")
    }
}

/// The list: each app playing sound now, with its own mute.
struct SoundCard: View {
    @ObservedObject var mixer: SoundMixer

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Playing sound now").font(.system(size: 12, weight: .bold))
                Spacer()
                if mixer.mutedIDs.count > 1 {
                    Button("Unmute all") { mixer.unmuteAll() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Heat.base)
                }
            }
            if mixer.apps.isEmpty {
                Text("Nothing is playing.").foregroundStyle(.secondary)
            }
            ForEach(mixer.apps) { app in row(app) }
            if let error = mixer.lastError {
                Text(error).foregroundStyle(.orange)
            }
            if !SoundMixer.canMute {
                Text("Muting one app needs macOS 14.2 or later.").foregroundStyle(.orange)
            }
            Divider()
            Text("A mute lasts until you unmute or quit GNotch. macOS sees apps, not tabs: muting Claude mutes all of its browser pane.")
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 11))
        .foregroundStyle(.white)
        .fixedSize(horizontal: false, vertical: true)
        .padding(10)
        .frame(width: 300, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.13)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.15)))
        .shadow(color: .black.opacity(0.5), radius: 10, y: 4)
    }

    private func row(_ app: SoundApp) -> some View {
        HStack(spacing: 8) {
            icon(app).frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(app.muted ? (app.pid == nil ? "Muted · not running" : app.playing ? "Muted · still playing" : "Muted · quiet")
                               : "Playing")
                    .font(.system(size: 10))
                    .foregroundStyle(app.muted ? Color.red : Color.secondary)
            }
            Spacer(minLength: 4)
            Button {
                mixer.toggle(app)
            } label: {
                Image(systemName: app.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(app.muted ? Color.white : Color.white.opacity(0.85))
                    .frame(width: 34, height: 22)
                    .background(Capsule().fill(app.muted ? Color.red : Color.white.opacity(0.14)))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!SoundMixer.canMute || (!app.muted && app.clients.isEmpty))
            .help(app.muted ? "Unmute \(app.name)" : "Mute \(app.name) only")
        }
    }

    @ViewBuilder
    private func icon(_ app: SoundApp) -> some View {
        if let pid = app.pid, let image = NSRunningApplication(processIdentifier: pid)?.icon {
            Image(nsImage: image).resizable()
        } else {
            Image(systemName: "app.dashed").foregroundStyle(.secondary)
        }
    }
}
