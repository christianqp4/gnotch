import AppKit
import SwiftUI

/// "Text to .md": a title and a long pasted text become a Markdown file, saved and on the clipboard.
enum TextExport {
    static let folderKey = "textExportFolder"

    /// Outside any repo on purpose: journal text is user data.
    static var defaultFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("Journaling", isDirectory: true)
    }

    /// The way Chris titles entries: "jueves, noviembre 5". Used when the title is left empty.
    static func todayTitle(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_ES")
        f.dateFormat = "EEEE, MMMM d"
        return f.string(from: date)
    }

    /// One line, no surrounding spaces. Accents and punctuation stay as typed.
    static func cleanTitle(_ title: String) -> String {
        let oneLine = title.components(separatedBy: .newlines).joined(separator: " ")
        let clean = oneLine.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? todayTitle() : clean
    }

    /// A file name without extension. Only what macOS can't hold or would hide is changed.
    static func fileBase(for title: String) -> String {
        var s = cleanTitle(title).precomposedStringWithCanonicalMapping
        s = String(s.map { $0 == "/" || $0 == ":" ? "-" : $0 })
        s = String(s.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(Character.init))
        if s.lowercased().hasSuffix(".md") { s.removeLast(3) }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespacesAndNewlines))
        // macOS allows 255 bytes per name; leave room for " (2).md".
        while s.utf8.count > 240 { s.removeLast() }
        s = s.trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? todayTitle() : s
    }

    /// The title as a heading, then the text byte for byte.
    static func contents(title: String, text: String) -> Data {
        Data("# \(cleanTitle(title))\n\n\(text)".utf8)
    }

    /// Creates the file. Never overwrites: an existing name gets " (2)", " (3)"…
    static func write(title: String, text: String, folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = fileBase(for: title)
        let data = contents(title: title, text: text)
        for n in 1...9999 {
            let name = n == 1 ? "\(base).md" : "\(base) (\(n)).md"
            let url = folder.appendingPathComponent(name, isDirectory: false)
            do {
                // .withoutOverwriting is O_EXCL: it fails rather than replace, even in a race.
                try data.write(to: url, options: .withoutOverwriting)
                return url
            } catch CocoaError.fileWriteFileExists {
                continue
            }
        }
        throw CocoaError(.fileWriteFileExists)
    }

    /// The file itself goes on the pasteboard, the way Finder's Copy does it.
    static func putOnPasteboard(_ url: URL, _ pb: NSPasteboard = .general) {
        pb.clearContents()
        pb.writeObjects([url as NSURL])
    }
}

/// Lives in `NotchState`, so a half-pasted text survives the notch closing or switching page.
/// Only the form observes it: typing doesn't re-render the rest of the notch.
@MainActor
final class TextExportDraft: ObservableObject {
    @Published var title = ""
    @Published var text = ""
    @Published var error: String?
    @Published var folder: URL = {
        if let path = UserDefaults.standard.string(forKey: TextExport.folderKey) {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return TextExport.defaultFolder
    }() {
        didSet { UserDefaults.standard.set(folder.path, forKey: TextExport.folderKey) }
    }

    var isEmpty: Bool { title.isEmpty && text.isEmpty }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = folder
        panel.prompt = "Use This Folder"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url { folder = url }
    }

    func revealFolder() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }
}

/// Title, text, export. Shown in place of the history on the clipboard page.
struct TextExportForm: View {
    @ObservedObject var draft: TextExportDraft
    let clips: ClipboardStore
    @ObservedObject var state: NotchState
    let collapse: () -> Void

    @FocusState private var titleFocused: Bool
    @State private var bodyFocus = 0

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button { state.textExportOpen = false } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 26, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Back to the clipboard (the draft stays)")

                TextField(TextExport.todayTitle(), text: $draft.title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .focused($titleFocused)
                    .onSubmit { bodyFocus += 1 }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.08)))
            }

            ZStack(alignment: .topLeading) {
                PlainTextEditor(text: $draft.text, focusRequest: bodyFocus)
                if draft.text.isEmpty {
                    Text("Paste the text here (⌘V). It's saved exactly as it is.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.08)))
            .clipShape(RoundedRectangle(cornerRadius: 9))

            if let error = draft.error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 10) {
                Button(action: draft.revealFolder) {
                    Label((draft.folder.path as NSString).abbreviatingWithTildeInPath, systemImage: "folder")
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                .buttonStyle(.plain)
                .help("Show this folder in Finder")
                Button("Change…", action: draft.chooseFolder)
                    .buttonStyle(.plain)
                    .foregroundStyle(Heat.base)
                Spacer(minLength: 0)
                Button(action: export) {
                    Text("Export .md  ⌘↩")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(draft.text.isEmpty ? Color.secondary : Color.black)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(draft.text.isEmpty ? Color.white.opacity(0.1) : Heat.base))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(draft.text.isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Saves the file and puts it on the clipboard, ready for ⌘V")
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
        }
        .onAppear { titleFocused = true }
        .onChange(of: state.focusToken) { _, _ in titleFocused = true }
    }

    private func export() {
        do {
            let url = try TextExport.write(title: draft.title, text: draft.text, folder: draft.folder)
            clips.addExportedFile(url, sourceText: draft.text)
            draft.title = ""
            draft.text = ""
            draft.error = nil
            state.textExportOpen = false
            state.showBadge(icon: "doc.text.fill", text: "Copied .md")
            // Gives the keyboard back to the previous app, so ⌘V lands there.
            collapse()
        } catch {
            // The draft stays, so nothing is lost.
            draft.error = "Couldn't save: \(error.localizedDescription)"
        }
    }
}

/// A text area that keeps what's pasted untouched. SwiftUI's TextEditor can't turn off every
/// automatic substitution (smart quotes, dashes, spacing around a paste, links, replacements).
struct PlainTextEditor: NSViewRepresentable {
    @Binding var text: String
    /// Bump to move the keyboard here.
    var focusRequest: Int

    final class FirstClickTextView: NSTextView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    static func makeTextView() -> NSTextView {
        let tv = FirstClickTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.smartInsertDeleteEnabled = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isAutomaticTextCompletionEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.isAutomaticDataDetectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.drawsBackground = false
        tv.font = .systemFont(ofSize: 12.5)
        tv.textColor = .white
        tv.insertionPointColor = .white
        tv.textContainerInset = NSSize(width: 5, height: 8)
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude)
        return tv
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PlainTextEditor
        var lastFocusRequest = 0
        init(_ parent: PlainTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let tv = Self.makeTextView()
        tv.string = text
        tv.delegate = context.coordinator
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = tv
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = scroll.documentView as? NSTextView else { return }
        if tv.string != text { tv.string = text }
        if context.coordinator.lastFocusRequest != focusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            tv.window?.makeFirstResponder(tv)
        }
    }
}
