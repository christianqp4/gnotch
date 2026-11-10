import AppKit
import Combine
import SwiftUI
import UserNotifications

/// One question a chat asked Chris, from `~/gears_OS/dashboard/questions.json`.
/// GNotch only shows questions and writes answers back; what an answer means for a task is the chats' job.
struct Question: Identifiable, Equatable {
    enum Kind: String { case yesno, choice, text }

    var id: String
    var text: String
    var kind: Kind
    var options: [String]
    var task: String?
    var from: String?
    var created: String?
    var answer: String?
    var comment: String?

    var isOpen: Bool { (answer ?? "").isEmpty }

    /// The buttons, in order (number keys pick them). Yes/no answers are stored as "yes" / "no".
    var choices: [(label: String, value: String)] {
        switch kind {
        case .yesno: return [("Sí", "yes"), ("No", "no")]
        case .choice: return options.map { ($0, $0) }
        case .text: return []
        }
    }

    init?(_ dict: [String: Any]) {
        guard let id = Self.string(dict["id"]), let text = Self.string(dict["text"]) else { return nil }
        self.id = id
        self.text = text
        options = (dict["options"] as? [Any])?.compactMap(Self.string) ?? []
        // An unknown kind still shows: with options as a choice, otherwise as yes/no.
        kind = Kind(rawValue: Self.string(dict["kind"]) ?? "") ?? (options.isEmpty ? .yesno : .choice)
        if kind == .choice, options.isEmpty { kind = .yesno }
        task = Self.string(dict["task"])
        from = Self.string(dict["from"])
        created = Self.string(dict["created"])
        answer = Self.string(dict["answer"])
        comment = Self.string(dict["comment"])
    }

    /// Chats may write ids and tasks as numbers.
    private static func string(_ value: Any?) -> String? {
        switch value {
        case let s as String: return s
        case let n as NSNumber where CFGetTypeID(n) != CFBooleanGetTypeID(): return n.stringValue
        default: return nil
        }
    }
}

/// Reads the questions file when it changes (a stat every 15 s, nothing else) and writes answers back
/// without losing anything a chat appended meanwhile.
@MainActor
final class QuestionStore: ObservableObject {
    static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("gears_OS/dashboard/questions.json")

    let fileURL: URL
    @Published private(set) var questions: [Question] = []
    /// Set when the file exists but can't be read as JSON (a chat may be halfway through writing it).
    @Published private(set) var readError: String?
    private var stamp: (Date, Int)?
    private var timer: Timer?

    var open: [Question] { questions.filter(\.isOpen) }
    var openCount: Int { questions.reduce(0) { $0 + ($1.isOpen ? 1 : 0) } }

    init(fileURL: URL? = nil, watch: Bool = true) {
        let env = ProcessInfo.processInfo.environment["GNOTCH_QUESTIONS_FILE"]
        self.fileURL = fileURL ?? env.map { URL(fileURLWithPath: $0) } ?? Self.defaultURL
        reload(force: true)
        guard watch else { return }
        let t = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        t.tolerance = 5
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Re-reads the file if its date or size changed since the last read.
    func reload(force: Bool = false) {
        let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let newStamp = attrs.map { (($0[.modificationDate] as? Date) ?? .distantPast, ($0[.size] as? Int) ?? 0) }
        if !force, let a = stamp, let b = newStamp, a == b { return }
        if !force, stamp == nil, newStamp == nil { return }
        stamp = newStamp
        guard newStamp != nil else {
            if !questions.isEmpty { questions = [] }
            readError = nil
            return
        }
        switch Self.readRoot(fileURL) {
        case .success(let root):
            let parsed = (root["questions"] as? [Any] ?? []).compactMap { ($0 as? [String: Any]).flatMap(Question.init) }
            if parsed != questions { questions = parsed }
            readError = nil
        case .failure(let error):
            // Keep showing what we had; the next change of the file is read again.
            readError = error.localizedDescription
        }
    }

    /// Writes the answer into the file as it is on disk right now, then reads it back.
    /// Everything else in the file (questions appended by a chat a second ago, unknown fields, the
    /// `about` note) is kept. Empty comments are left out. Returns nil on success, or the reason.
    @discardableResult
    func answer(_ id: String, answer: String, comment: String, at date: Date = Date()) -> String? {
        let error = Self.writeAnswer(to: fileURL, id: id, answer: answer, comment: comment, at: date)
        reload(force: true)
        return error
    }

    nonisolated static func writeAnswer(to url: URL, id: String, answer: String, comment: String, at date: Date) -> String? {
        var root: [String: Any]
        switch readRoot(url) {
        case .success(let r): root = r
        case .failure(let e): return "questions.json can't be read right now (\(e.localizedDescription)). Nothing was written."
        }
        guard var list = root["questions"] as? [Any],
              let index = list.firstIndex(where: { (($0 as? [String: Any]).flatMap(Question.init))?.id == id }),
              var entry = list[index] as? [String: Any] else {
            return "That question is no longer in questions.json."
        }
        entry["answer"] = answer
        let note = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        if note.isEmpty { entry.removeValue(forKey: "comment") } else { entry["comment"] = note }
        entry["answeredAt"] = Self.timestamp(date)
        list[index] = entry
        root["questions"] = list
        let text = OrderedJSON.encode(root) + "\n"
        do {
            // Written beside the file, then swapped in: a reader never sees half a file.
            try Data(text.utf8).write(to: url, options: .atomic)
            return nil
        } catch {
            return "Couldn't save the answer: \(error.localizedDescription)"
        }
    }

    nonisolated static func readRoot(_ url: URL) -> Result<[String: Any], Error> {
        do {
            let data = try Data(contentsOf: url)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .failure(CocoaError(.fileReadCorruptFile))
            }
            return .success(root)
        } catch {
            return .failure(error)
        }
    }

    /// ISO 8601 with the local offset and no fractional seconds (other GNotch readers reject them).
    nonisolated static func timestamp(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f.string(from: date)
    }
}

/// JSON text with keys in a stable, readable order (the schema's order, then anything else
/// alphabetically), so the file stays easy for chats to read and diff.
enum OrderedJSON {
    static let order = ["schema", "rev", "about", "questions", "id", "text", "kind", "options", "task", "from",
                        "created", "answer", "comment", "answeredAt"]

    static func encode(_ value: Any, indent: Int = 0) -> String {
        let pad = String(repeating: "  ", count: indent + 1)
        let end = String(repeating: "  ", count: indent)
        switch value {
        case let dict as [String: Any]:
            if dict.isEmpty { return "{}" }
            let keys = dict.keys.sorted { a, b in
                let ia = order.firstIndex(of: a) ?? Int.max, ib = order.firstIndex(of: b) ?? Int.max
                return ia != ib ? ia < ib : a < b
            }
            let body = keys.map { "\(pad)\(scalar($0)): \(encode(dict[$0]!, indent: indent + 1))" }
            return "{\n" + body.joined(separator: ",\n") + "\n\(end)}"
        case let array as [Any]:
            if array.isEmpty { return "[]" }
            if array.allSatisfy({ !($0 is [Any]) && !($0 is [String: Any]) }) {
                return "[" + array.map(scalar).joined(separator: ", ") + "]"
            }
            return "[\n" + array.map { pad + encode($0, indent: indent + 1) }.joined(separator: ",\n") + "\n\(end)]"
        default:
            return scalar(value)
        }
    }

    private static func scalar(_ value: Any) -> String {
        if value is NSNull { return "null" }
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes]),
              let s = String(data: data, encoding: .utf8) else { return "null" }
        return s
    }
}

// MARK: - The queue in the notch

/// Which card is showing, what's picked, and the cards answered since the queue opened (for Back).
@MainActor
final class QuestionQueueModel: ObservableObject {
    let store: QuestionStore
    @Published var currentID: String?
    @Published var selected: String?
    @Published var comment = ""
    @Published var textAnswer = ""
    @Published var error: String?
    @Published var commentFocusToken = 0
    private(set) var answered: [String] = []
    private var skipped: [String] = []
    private var cancellable: AnyCancellable?

    init(store: QuestionStore) {
        self.store = store
        currentID = nextOpenID()
        loadCurrent()
        // A chat appended questions while the empty state shows: show the first new one.
        cancellable = store.$questions.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            guard let self else { return }
            if self.current == nil { self.currentID = self.nextOpenID(); self.loadCurrent() }
        }
    }

    var current: Question? { currentID.flatMap { id in store.questions.first { $0.id == id } } }
    var answeredCount: Int { answered.count }
    var canGoBack: Bool { !answered.isEmpty }
    var canCommit: Bool {
        guard let q = current else { return false }
        return q.kind == .text ? !textAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty : selected != nil
    }

    /// Number keys and Y / N.
    func pick(index: Int) {
        guard let q = current, q.kind != .text, q.choices.indices.contains(index) else { return }
        selected = q.choices[index].value
    }

    func pick(value: String) { selected = value }

    /// Saves the picked answer with the comment, then shows the next open question.
    func commit() {
        guard let q = current, canCommit else { return }
        let value = q.kind == .text ? textAnswer.trimmingCharacters(in: .whitespacesAndNewlines) : selected!
        if let message = store.answer(q.id, answer: value, comment: comment) {
            error = message
            return
        }
        error = nil
        answered.removeAll { $0 == q.id }
        answered.append(q.id)
        skipped.removeAll { $0 == q.id }
        currentID = nextOpenID(after: q.id)
        loadCurrent()
    }

    /// Not now: the card goes to the back of the queue until the notch closes.
    func skip() {
        guard let q = current else { return }
        if !skipped.contains(q.id) { skipped.append(q.id) }
        currentID = nextOpenID(after: q.id)
        loadCurrent()
    }

    /// The card answered last, with its answer picked, to change it.
    func back() {
        guard let id = answered.popLast() else { return }
        currentID = id
        loadCurrent()
    }

    private func loadCurrent() {
        let q = current
        error = nil
        selected = q?.kind == .text ? nil : q?.answer
        textAnswer = q?.kind == .text ? (q?.answer ?? "") : ""
        comment = q?.comment ?? ""
    }

    /// Open questions in file order, skipped ones last.
    private func nextOpenID(after id: String? = nil) -> String? {
        let open = store.open.map(\.id)
        let fresh = open.filter { !skipped.contains($0) && $0 != id }
        let later = skipped.filter { open.contains($0) && $0 != id }
        return fresh.first ?? later.first ?? (open.contains(id ?? "") ? id : nil)
    }
}

/// The count of open questions in the top band. Hidden when there are none (unless the queue is open).
struct QuestionBadge: View {
    @ObservedObject var store: QuestionStore
    @ObservedObject var state: NotchState

    var body: some View {
        let count = store.openCount
        if (count > 0 && !state.quiet) || state.questionsOpen {
            Button {
                state.questionsOpen.toggle()
                if state.questionsOpen { state.pinned = true }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "questionmark.bubble.fill").font(.system(size: 10))
                    if count > 0 {
                        Text("\(count)").font(.system(size: 10.5, weight: .bold)).monospacedDigit()
                    }
                }
                .foregroundStyle(state.questionsOpen ? Color.white : Color(red: 0.55, green: 0.75, blue: 1))
                .padding(.horizontal, 6)
                .frame(minHeight: 22)
                .background(Capsule().fill(Color.white.opacity(state.questionsOpen ? 0.16 : 0)))
                .contentShape(Capsule())
                .fixedSize()
            }
            .buttonStyle(.plain)
            .help(count == 1 ? "1 question from the chats (⌃⌥Q)" : "\(count) questions from the chats (⌃⌥Q)")
        }
    }
}

/// One question at a time: big answer buttons, an optional comment, next.
/// Keys: Y / N or 1–9 pick, ↩ saves and goes on, → skips, ← goes back, C writes a comment.
struct QuestionQueueView: View {
    @ObservedObject var store: QuestionStore
    @ObservedObject var state: NotchState
    @StateObject private var model: QuestionQueueModel
    @FocusState private var commentFocused: Bool
    @FocusState private var textFocused: Bool
    @State private var keyMonitor: Any?

    init(store: QuestionStore, state: NotchState, preset: ((QuestionQueueModel) -> Void)? = nil) {
        self.store = store
        self.state = state
        // Built once, when the queue appears (StateObject evaluates this lazily).
        _model = StateObject(wrappedValue: {
            let model = QuestionQueueModel(store: store)
            preset?(model)
            return model
        }())
    }

    var body: some View {
        Group {
            if let q = model.current {
                card(q)
            } else {
                empty
            }
        }
        .onAppear(perform: installKeys)
        .onDisappear(perform: removeKeys)
        .onChange(of: model.commentFocusToken) { _, _ in commentFocused = true }
        .onChange(of: model.currentID) { _, _ in
            commentFocused = false
            textFocused = model.current?.kind == .text
        }
    }

    /// The question with its web links clickable (they open in the browser), in a light blue.
    static func linked(_ text: String) -> AttributedString {
        var out = AttributedString(text)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return out }
        let ns = text as NSString
        for match in detector.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let url = match.url, let r = Range(match.range, in: text),
                  let lower = AttributedString.Index(r.lowerBound, within: out),
                  let upper = AttributedString.Index(r.upperBound, within: out) else { continue }
            out[lower..<upper].link = url
            out[lower..<upper].foregroundColor = Color(red: 0.55, green: 0.75, blue: 1)
            out[lower..<upper].underlineStyle = .single
        }
        return out
    }

    private func card(_ q: Question) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(progress)
                    .foregroundStyle(.white.opacity(0.85))
                if let task = q.task { tag(task) }
                if let from = q.from { Text(from).lineLimit(1) }
                Spacer(minLength: 0)
                smallButton("chevron.left", help: "Back to the last answer (←)", enabled: model.canGoBack, action: model.back)
                smallButton("forward.end", help: "Not now: later in the queue (→)", enabled: store.openCount > 1 || !q.isOpen, action: model.skip)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)

            Text(Self.linked(q.text))
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                // The whole question shows: the notch grows with its height.
                .background(GeometryReader { g in
                    Color.clear
                        .onAppear { state.questionTextHeight = g.size.height }
                        .onChange(of: g.size.height) { _, h in state.questionTextHeight = h }
                })
                .frame(minHeight: 44, alignment: .topLeading)

            if q.kind == .text {
                TextField("Your answer", text: $model.textAnswer)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .medium))
                    .focused($textFocused)
                    .onSubmit(model.commit)
                    .padding(.horizontal, 12)
                    .frame(height: 42)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.1)))
                    .onAppear { state.questionButtonsHeight = 0 }
            } else {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(Array(q.choices.enumerated()), id: \.offset) { i, choice in
                        answerButton(choice.label, value: choice.value, key: keyHint(q, i))
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                // Long option labels wrap: the notch grows by what the buttons add over 46 pt.
                .background(GeometryReader { g in
                    Color.clear
                        .onAppear { state.questionButtonsHeight = g.size.height }
                        .onChange(of: g.size.height) { _, h in state.questionButtonsHeight = h }
                })
            }

            HStack(spacing: 8) {
                TextField("Comment, just in case (C)", text: $model.comment)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($commentFocused)
                    .onSubmit(model.commit)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.07)))
                Button(action: model.commit) {
                    Text(store.openCount > 1 || !q.isOpen ? "Next  ↩" : "Done  ↩")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(model.canCommit ? Color.black : Color.secondary)
                        .padding(.horizontal, 14)
                        .frame(height: 28)
                        .background(Capsule().fill(model.canCommit ? Heat.base : Color.white.opacity(0.1)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!model.canCommit)
            }

            if let error = model.error {
                Text(error).font(.system(size: 11)).foregroundStyle(.orange).lineLimit(2)
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 28))
                .foregroundStyle(Heat.base)
            Text(model.answeredCount > 0 ? "All answered" : "No questions")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
            Text(store.readError.map { "questions.json can't be read right now: \($0)" }
                 ?? (model.answeredCount > 0
                     ? "\(model.answeredCount) saved. The day chat takes it from here."
                     : "When a chat asks something, a count shows up here."))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if model.canGoBack {
                Button("Change the last answer (←)", action: model.back)
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Heat.base)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var progress: String {
        let left = store.openCount
        guard let q = model.current, q.isOpen else { return "Changing an answer" }
        let done = model.answeredCount
        return "\(done + 1) of \(done + left)"
            + (q.created.flatMap(Self.age).map { " · \($0)" } ?? "")
    }

    private static func age(_ created: String) -> String? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: String(created.prefix(10))) else { return nil }
        let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: d),
                                                   to: Calendar.current.startOfDay(for: Date())).day ?? 0
        return days <= 0 ? nil : (days == 1 ? "1 day old" : "\(days) days old")
    }

    private func keyHint(_ q: Question, _ i: Int) -> String {
        if q.kind == .yesno { return i == 0 ? "Y" : "N" }
        return "\(i + 1)"
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.white.opacity(0.1)))
    }

    private func answerButton(_ label: String, value: String, key: String) -> some View {
        let on = model.selected == value
        return Button { model.pick(value: value) } label: {
            HStack(spacing: 8) {
                Text(label).font(.system(size: 15, weight: .bold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text(key)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(on ? Color.black.opacity(0.55) : Color.secondary)
            }
            .foregroundStyle(on ? Color.black : Color.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 46, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 11).fill(on ? Heat.base : Color.white.opacity(0.1)))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Color.white.opacity(on ? 0 : 0.08)))
            .contentShape(RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain)
    }

    private func smallButton(_ icon: String, help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.white.opacity(0.08)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .help(help)
    }

    // The keys work while no text field has the keyboard; in a field, ↩ saves and Esc closes as usual.
    private func installKeys() {
        guard keyMonitor == nil else { return }
        let model = self.model
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.window is NotchPanel,
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return event }
            let keyCode = event.keyCode
            let ch = event.charactersIgnoringModifiers?.lowercased() ?? ""
            let handled = MainActor.assumeIsolated { () -> Bool in
                // In a text field, ↩ saves through the field itself and the arrows move the cursor.
                if NSApp.keyWindow?.firstResponder is NSText { return false }
                switch keyCode {
                case 36, 76: model.commit() // return, enter
                case 124: model.skip() // →
                case 123: model.back() // ←
                default:
                    guard model.current != nil else { return false }
                    switch ch {
                    case "y", "s": model.pick(index: 0)
                    case "n": model.pick(index: 1)
                    case "c": model.commentFocusToken += 1
                    case "1", "2", "3", "4", "5", "6", "7", "8", "9": model.pick(index: Int(ch)! - 1)
                    default: return false
                    }
                }
                return true
            }
            return handled ? nil : event
        }
    }

    private func removeKeys() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}

// MARK: - Dev check

/// The six questions from the 6 Nov task cleanup, for snapshots and the write check.
enum QuestionSamples {
    static let seed = """
    {
      "schema": 1,
      "about": "Sample for snapshots.",
      "questions": [
        {"id": "q1", "text": "Alquiler: ¿ya firmaste el contrato?", "kind": "yesno", "task": "t3, t20", "from": "HQ 6 Nov", "created": "2026-11-06"},
        {"id": "q2", "text": "Competición de Barcelona (mycoffee.awards, hoy 6 nov): ¿vas o la cierro?", "kind": "choice", "options": ["Voy", "La cierro"], "task": "t35", "from": "HQ 6 Nov", "created": "2026-11-06"},
        {"id": "q3", "text": "Garantía Insta360: ¿entró la reclamación?", "kind": "yesno", "task": "t11", "from": "HQ 6 Nov", "created": "2026-11-06"},
        {"id": "q4", "text": "Arreglos de casa y dormitorio: ¿están hechos?", "kind": "choice", "options": ["Hechos", "A medias", "No"], "task": "t36, t21", "from": "HQ 6 Nov", "created": "2026-11-06"},
        {"id": "q5", "text": "Crédito de Netlify de Umami: la web está en vivo, ¿lo doy por resuelto?", "kind": "yesno", "task": "t23", "from": "HQ 6 Nov", "created": "2026-11-06"},
        {"id": "q6", "text": "Entrevista de historia con David (Origen): ¿sigue en pie?", "kind": "yesno", "task": "t25", "from": "HQ 6 Nov", "created": "2026-11-06"}
      ]
    }
    """

    /// Two long questions in the 10 Nov plain style, for the snapshot of a growing card.
    static let long = """
    {
      "schema": 1,
      "about": "Sample for snapshots.",
      "questions": [
        {"id": "q18", "text": "Cada chat nuevo empieza con una nota automática (tu movimiento del día, los recordatorios). ¿Añado ahí tus respuestas de GNotch? Con sí, ningún chat te vuelve a preguntar algo que ya contestaste, como pasó con el alquiler (https://www.youtube.com/watch?v=5dxg61SYjOs&t=463s ). Con no, depende de que el chat se acuerde de mirar.", "kind": "yesno", "from": "HQ 9 Nov", "created": "2026-11-10"},
        {"id": "q33", "text": "En GNotch, si escribes un comentario y no eliges respuesta, el comentario se pierde sin avisar. ¿Qué cambio? Opción 1: se guarda siempre y además puedes enviar solo el comentario. Opción 2: solo se guarda si saltas la pregunta. Opción 3: lo dejo como está.", "kind": "choice", "options": ["Guardar siempre y poder enviar solo el comentario", "Solo guardarlo al saltar", "Dejarlo así"], "from": "Secretaría 10 Nov", "created": "2026-11-10"}
      ]
    }
    """

    /// `GNOTCH_QUESTIONS_CHECK=1 GNotch`: answers questions in a temporary copy, never the real file.
    @MainActor
    static func check() -> Bool {
        var ok = true
        func check(_ name: String, _ pass: Bool) {
            print("\(pass ? "PASS" : "FAIL")  \(name)")
            if !pass { ok = false }
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gnotch-questions-\(UUID())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("questions.json")
        try? Data(seed.utf8).write(to: url)

        let store = QuestionStore(fileURL: url, watch: false)
        check("reads the six questions, all open", store.questions.count == 6 && store.openCount == 6)
        check("kinds and options", store.questions[1].kind == .choice && store.questions[1].options == ["Voy", "La cierro"]
              && store.questions[0].choices.map(\.value) == ["yes", "no"])

        // A chat appends q7 (with a field GNotch doesn't know) after GNotch read the file.
        var root = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as! [String: Any]
        var list = root["questions"] as! [Any]
        list.append(["id": "q7", "text": "¿Nueva?", "kind": "text", "from": "otro chat", "priority": 2])
        root["questions"] = list
        try? JSONSerialization.data(withJSONObject: root).write(to: url)

        let model = QuestionQueueModel(store: store)
        model.pick(value: "yes")
        model.comment = "  firmado el martes  "
        model.commit()
        let raw = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let after = QuestionStore(fileURL: url, watch: false)
        let q1 = after.questions.first { $0.id == "q1" }
        check("answer and trimmed comment written", q1?.answer == "yes" && q1?.comment == "firmado el martes")
        check("question a chat appended meanwhile is kept, with its unknown field",
              after.questions.contains { $0.id == "q7" } && raw.contains("\"priority\": 2"))
        check("the about note is kept, before the questions", raw.range(of: "\"about\"")!.lowerBound < raw.range(of: "\"questions\"")!.lowerBound)
        let stamp = raw.components(separatedBy: "\"answeredAt\": \"").dropFirst().first?.prefix(25) ?? ""
        check("answeredAt is ISO 8601 without milliseconds (\(stamp))",
              stamp.count == 25 && !stamp.contains(".") && ISO8601DateFormatter().date(from: String(stamp)) != nil)
        check("next card is q2", model.currentID == "q2")

        model.pick(index: 1)
        model.commit()
        check("choice stores the label", after.questions.isEmpty == false
              && QuestionStore(fileURL: url, watch: false).questions.first { $0.id == "q2" }?.answer == "La cierro")
        check("empty comment is left out", !raw.isEmpty && !(try! String(contentsOf: url, encoding: .utf8))
              .components(separatedBy: "\"id\": \"q2\"")[1].components(separatedBy: "}")[0].contains("comment"))

        model.back()
        check("back shows q2 with its answer picked", model.currentID == "q2" && model.selected == "La cierro")
        model.pick(index: 0)
        model.commit()
        check("changing an answer overwrites it", QuestionStore(fileURL: url, watch: false).questions.first { $0.id == "q2" }?.answer == "Voy")

        model.skip()
        check("skip moves on without writing", model.currentID == "q4" && QuestionStore(fileURL: url, watch: false).questions.first { $0.id == "q3" }?.isOpen == true)

        let good = try! Data(contentsOf: url)
        try? Data("{ \"questions\": [ {\"id\": \"q1\"".utf8).write(to: url)
        let refused = store.answer("q4", answer: "Hechos", comment: "")
        check("a half-written file is left alone", refused != nil && (try? Data(contentsOf: url)) == Data("{ \"questions\": [ {\"id\": \"q1\"".utf8))
        check("and the last good list stays on screen", store.questions.count == 7 && store.readError != nil)
        try? good.write(to: url)
        store.reload(force: true)
        check("text question shows", store.questions.last?.kind == .text && store.openCount == 5)
        let removed = store.answer("q99", answer: "yes", comment: "")
        check("unknown id is refused", removed != nil)

        // The nightly schedule (Mon–Thu evenings, Fri–Sun shift nights) and the quiet stretch.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Madrid")!
        func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
            cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
        }
        let plan = ReminderSettings.standard
        let monday = plan.reminders(night: at(2026, 11, 9, 12, 0), calendar: cal)
        check("Monday night: 21:30, 23:30, then 00:00 on Tuesday",
              monday.map(\.1) == [at(2026, 11, 9, 21, 30), at(2026, 11, 9, 23, 30), at(2026, 11, 10, 0, 0)])
        let friday = plan.reminders(night: at(2026, 11, 6, 12, 0), calendar: cal)
        check("Friday shift night: 23:30, then 00:15 and 00:45 on Saturday",
              friday.map(\.1) == [at(2026, 11, 6, 23, 30), at(2026, 11, 7, 0, 15), at(2026, 11, 7, 0, 45)])
        check("Sunday is a shift night too", plan.reminders(night: at(2026, 11, 8, 12, 0), calendar: cal).last?.1 == at(2026, 11, 9, 0, 45))
        check("quiet from the last reminder until 07:00",
              plan.isQuiet(at(2026, 11, 7, 1, 0), calendar: cal) && plan.isQuiet(at(2026, 11, 10, 0, 30), calendar: cal)
              && !plan.isQuiet(at(2026, 11, 7, 7, 30), calendar: cal) && !plan.isQuiet(at(2026, 11, 9, 23, 50), calendar: cal)
              && !plan.isQuiet(at(2026, 11, 6, 23, 0), calendar: cal))
        var off = plan
        for i in 0..<3 { off.nights[2][i].on = false }
        check("a night with everything off has no quiet stretch", off.quietSpan(night: at(2026, 11, 10, 12, 0), calendar: cal) == nil)
        let round = try? JSONDecoder().decode(ReminderSettings.self, from: JSONEncoder().encode(plan))
        check("settings survive saving", round == plan)
        let now = Date()
        let events = [CalEvent(id: "a", title: "Entrevista con David", start: now.addingTimeInterval(45 * 60 + 5),
                               end: now.addingTimeInterval(105 * 60), calendar: "Google")]
        check("next event line (\(CalendarFeed.line(events, now: now) ?? "nil"))",
              CalendarFeed.line(events, now: now)?.hasSuffix("Entrevista con David · en 46 min") == true)
        check("no line when the next event is over 2 h away",
              CalendarFeed.line(events, now: now.addingTimeInterval(-3 * 3600)) == nil)
        print(raw.prefix(600))
        return ok
    }
}
