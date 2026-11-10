import AppKit
import EventKit
import SwiftUI
import UserNotifications

// A few quiet reminders a night (close the day, wind down, last call), the next calendar event in the
// notch, and a quiet stretch after the night's last reminder. Nothing else in GNotch notifies.

enum ReminderKind: String, Codable, CaseIterable, Identifiable {
    case closeDay, windDown, lastCall

    var id: String { rawValue }
    var label: String {
        switch self {
        case .closeDay: return "Cerrar el día"
        case .windDown: return "Desconexión"
        case .lastCall: return "Último aviso"
        }
    }
}

struct NightReminder: Codable, Equatable {
    var kind: ReminderKind
    var on: Bool
    /// "HH:mm". Times before 12:00 belong to the same night, after midnight.
    var time: String
    /// The notification's text. Unused for "Cerrar el día", which counts the open questions.
    var text: String

    /// Minutes from the evening's midnight (00:15 → 1455).
    var offset: Int? {
        let p = time.split(separator: ":").compactMap { Int($0) }
        guard p.count == 2, (0..<24).contains(p[0]), (0..<60).contains(p[1]) else { return nil }
        return (p[0] < 12 ? 24 * 60 : 0) + p[0] * 60 + p[1]
    }
}

struct ReminderSettings: Codable, Equatable {
    /// Index 0 = Sunday … 6 = Saturday: the weekday of the evening the night starts.
    var nights: [[NightReminder]]
    /// After the night's last reminder GNotch shows nothing else until this time.
    var quietUntil = "07:00"
    var calendarLine = true
    /// Minutes before an event for the alert; 0 = no alert.
    var calendarLead = 10

    static let sleepKit = "Kit de sueño (tapones, antifaz, spray nasal, suero) y recoger."

    static var standard: ReminderSettings {
        // Mon–Thu: home in the evening. Fri–Sun: work shift, home ~23:30, waiting up for his brother.
        let week = [NightReminder(kind: .closeDay, on: true, time: "21:30", text: ""),
                    NightReminder(kind: .windDown, on: true, time: "23:30", text: sleepKit),
                    NightReminder(kind: .lastCall, on: true, time: "00:00", text: "Apagar todo.")]
        let shift = [NightReminder(kind: .closeDay, on: true, time: "23:30", text: ""),
                     NightReminder(kind: .windDown, on: true, time: "00:15", text: sleepKit),
                     NightReminder(kind: .lastCall, on: true, time: "00:45",
                                   text: "Todo listo para dormir: todo recogido, solo esperar a tu hermano.")]
        return ReminderSettings(nights: [shift, week, week, week, week, shift, shift])
    }

    static let key = "reminderSettings"

    static func load() -> ReminderSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let s = try? JSONDecoder().decode(ReminderSettings.self, from: data), s.nights.count == 7 else { return .standard }
        return s
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    init(nights: [[NightReminder]]) { self.nights = nights }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nights = try c.decode([[NightReminder]].self, forKey: .nights)
        quietUntil = try c.decodeIfPresent(String.self, forKey: .quietUntil) ?? "07:00"
        calendarLine = try c.decodeIfPresent(Bool.self, forKey: .calendarLine) ?? true
        calendarLead = try c.decodeIfPresent(Int.self, forKey: .calendarLead) ?? 10
    }

    /// The enabled reminders of the night that starts on `day`'s evening, with their times.
    func reminders(night day: Date, calendar cal: Calendar = .current) -> [(NightReminder, Date)] {
        let start = cal.startOfDay(for: day)
        let weekday = cal.component(.weekday, from: start) - 1
        return nights[weekday].compactMap { r in
            guard r.on, let off = r.offset, let at = cal.date(byAdding: .minute, value: off, to: start) else { return nil }
            return (r, at)
        }.sorted { $0.1 < $1.1 }
    }

    /// From the night's last reminder until `quietUntil` the next morning.
    func quietSpan(night day: Date, calendar cal: Calendar = .current) -> Range<Date>? {
        guard let last = reminders(night: day, calendar: cal).last?.1 else { return nil }
        let p = quietUntil.split(separator: ":").compactMap { Int($0) }
        guard p.count == 2, let next = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: day)),
              let end = cal.date(bySettingHour: p[0], minute: p[1], second: 0, of: next), end > last else { return nil }
        return last..<end
    }

    func isQuiet(_ now: Date, calendar cal: Calendar = .current) -> Bool {
        [-1, 0].contains { d in
            cal.date(byAdding: .day, value: d, to: now).flatMap { quietSpan(night: $0, calendar: cal) }?.contains(now) ?? false
        }
    }
}

/// Silent notifications. UNUserNotificationCenter crashes in a process without a bundle (a bare build).
@MainActor
enum QuietNotifier {
    static let available = Bundle.main.bundleIdentifier != nil

    static func post(id: String, title: String, body: String, kind: String) {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = nil
            content.userInfo = ["kind": kind]
            center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
    }
}

// MARK: - Calendar

struct CalEvent: Equatable {
    var id: String
    var title: String
    var start: Date
    var end: Date
    var calendar: String
}

/// Today's events from macOS Calendar (Google shows up there once added in Internet Accounts).
/// Read-only. Access is asked once, the first time the notch opens with the calendar on.
@MainActor
final class CalendarFeed {
    enum Access { case notAsked, denied, ready }

    private(set) var events: [CalEvent] = []
    private(set) var googleFound = false
    private(set) var calendarCount = 0
    private var store: EKEventStore?
    var onChange: (() -> Void)?

    var access: Access {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined: return .notAsked
        case .fullAccess, .authorized: return .ready
        default: return .denied
        }
    }

    func askOnce() {
        guard access == .notAsked, !UserDefaults.standard.bool(forKey: "calendarAsked") else { return }
        UserDefaults.standard.set(true, forKey: "calendarAsked")
        requestAccess()
    }

    func requestAccess() {
        let store = self.store ?? EKEventStore()
        self.store = store
        store.requestFullAccessToEvents { _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self.refresh() } }
        }
    }

    /// Re-reads the next 36 hours. A few milliseconds; only when access was given.
    func refresh() {
        guard access == .ready else {
            events = []
            onChange?()
            return
        }
        if store == nil {
            let s = EKEventStore()
            store = s
            NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: s, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        guard let store else { return }
        let now = Date()
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-12 * 3600),
                                                 end: now.addingTimeInterval(36 * 3600), calendars: nil)
        let found = store.events(matching: predicate)
            .filter { e in
                !e.isAllDay && e.status != .canceled
                    && e.attendees?.first(where: \.isCurrentUser)?.participantStatus != .declined
            }
            .map { CalEvent(id: $0.calendarItemIdentifier, title: $0.title ?? "Evento", start: $0.startDate, end: $0.endDate,
                            calendar: $0.calendar?.title ?? "") }
            .sorted { $0.start < $1.start }
        let calendars = store.calendars(for: .event)
        calendarCount = calendars.count
        googleFound = store.sources.contains { s in
            let t = s.title.lowercased()
            return t.contains("google") || t.contains("gmail")
        } || calendars.contains { $0.source?.title.lowercased().contains("gmail") == true }
        if found != events { events = found }
        onChange?()
    }

    /// One line for the notch: the event on now, or the next one within 2 hours today.
    static func line(_ events: [CalEvent], now: Date = Date()) -> String? {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        if let e = events.first(where: { $0.start <= now && $0.end > now }) {
            return "Ahora: \(e.title) · hasta \(f.string(from: e.end))"
        }
        guard let e = events.first(where: { $0.start > now }),
              e.start.timeIntervalSince(now) <= 2 * 3600,
              Calendar.current.isDate(e.start, inSameDayAs: now) || e.start.timeIntervalSince(now) <= 3600 else { return nil }
        let mins = Int((e.start.timeIntervalSince(now) / 60).rounded(.up))
        let when = mins < 60 ? "en \(mins) min" : "en \(mins / 60) h \(mins % 60 > 0 ? "\(mins % 60) min" : "")"
        return "\(f.string(from: e.start)) \(e.title) · \(when.trimmingCharacters(in: .whitespaces))"
    }
}

// MARK: - The scheduler

/// One timer, set to the next thing that can happen (a reminder, an alert, the quiet stretch starting
/// or ending, the calendar line changing), and re-set on wake and when settings or the calendar change.
@MainActor
final class Reminders: NSObject, UNUserNotificationCenterDelegate {
    let calendar = CalendarFeed()
    private(set) var settings = ReminderSettings.load()
    private let questions: QuestionStore
    private let state: NotchState
    private let openQueue: () -> Void
    private var timer: Timer?
    private var lineTimer: Timer?

    init(questions: QuestionStore, state: NotchState, openQueue: @escaping () -> Void) {
        self.questions = questions
        self.state = state
        self.openQueue = openQueue
        super.init()
        if QuietNotifier.available { UNUserNotificationCenter.current().delegate = self }
        state.onExpand = { [weak self] in
            guard let self, self.settings.calendarLine || self.settings.calendarLead > 0 else { return }
            self.calendar.askOnce()
        }
        calendar.onChange = { [weak self] in self?.tick() }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.calendar.refresh() }
        }
        calendar.refresh() // ends in tick()
    }

    func update(_ new: ReminderSettings) {
        settings = new
        new.save()
        tick()
    }

    /// The next reminder, for the menu.
    func next(after now: Date = Date()) -> (NightReminder, Date)? {
        (-1...1).flatMap { d in
            Calendar.current.date(byAdding: .day, value: d, to: now).map { settings.reminders(night: $0) } ?? []
        }.filter { $0.1 > now }.min { $0.1 < $1.1 }
    }

    func test() {
        QuietNotifier.post(id: "gnotch-test", title: "GNotch", body: "Así se verán los recordatorios: sin sonido.", kind: "test")
    }

    private func tick() {
        let now = Date()
        let cal = Calendar.current
        let quiet = settings.isQuiet(now)
        if state.quiet != quiet { state.quiet = quiet }

        // Reminders due in the last 90 minutes that haven't fired (the Mac may have been asleep).
        var fired = Set(UserDefaults.standard.stringArray(forKey: "remindersFired") ?? [])
        let keyDay = DateFormatter()
        keyDay.dateFormat = "yyyy-MM-dd"
        for d in [-1, 0] {
            guard let night = cal.date(byAdding: .day, value: d, to: now) else { continue }
            for (r, at) in settings.reminders(night: night) where at <= now && now.timeIntervalSince(at) < 90 * 60 {
                let key = "\(keyDay.string(from: night))|\(r.kind.rawValue)"
                guard !fired.contains(key) else { continue }
                fired.insert(key)
                fire(r)
            }
        }
        // Calendar alerts, between `lead` minutes before and the start. Not in the quiet stretch.
        if settings.calendarLead > 0, !quiet {
            for e in calendar.events {
                let alert = e.start.addingTimeInterval(TimeInterval(-60 * settings.calendarLead))
                let key = "cal|\(e.id)|\(Int(e.start.timeIntervalSince1970))"
                guard alert <= now, now < e.start, !fired.contains(key) else { continue }
                fired.insert(key)
                let f = DateFormatter()
                f.dateFormat = "HH:mm"
                QuietNotifier.post(id: key, title: "\(f.string(from: e.start)) · \(e.title)",
                                   body: "En \(Int((e.start.timeIntervalSince(now) / 60).rounded(.up))) min · \(e.calendar)", kind: "calendar")
                state.showBadge(icon: "calendar", text: f.string(from: e.start), seconds: 8)
            }
        }
        // Keep the list short: only the last few days matter.
        let recent = fired.filter { k in
            if k.hasPrefix("cal|") { return Double(k.split(separator: "|").last ?? "").map { now.timeIntervalSince1970 - $0 < 86400 * 2 } ?? false }
            return keyDay.date(from: String(k.prefix(10))).map { now.timeIntervalSince($0) < 86400 * 3 } ?? false
        }
        UserDefaults.standard.set(Array(recent), forKey: "remindersFired")

        updateLine(now)
        schedule(now)
    }

    private func fire(_ r: NightReminder) {
        switch r.kind {
        case .closeDay:
            questions.reload()
            let n = questions.openCount
            guard n > 0 else { return }
            QuietNotifier.post(id: "gnotch-closeDay", title: r.kind.label,
                               body: n == 1 ? "1 pregunta de los chats: Y / N, ↩." : "\(n) preguntas de los chats: Y / N, ↩.",
                               kind: r.kind.rawValue)
        case .windDown, .lastCall:
            QuietNotifier.post(id: "gnotch-\(r.kind.rawValue)", title: r.kind.label, body: r.text, kind: r.kind.rawValue)
        }
    }

    private func updateLine(_ now: Date) {
        let line = settings.calendarLine && !settings.isQuiet(now) ? CalendarFeed.line(calendar.events, now: now) : nil
        if state.calendarLine != line { state.calendarLine = line }
        // While an event is near, the "in N min" text changes every minute.
        lineTimer?.invalidate()
        lineTimer = nil
        guard line != nil else { return }
        let t = Timer(timeInterval: 60, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateLine(Date()) }
        }
        t.tolerance = 5
        RunLoop.main.add(t, forMode: .common)
        lineTimer = t
    }

    private func schedule(_ now: Date) {
        timer?.invalidate()
        let cal = Calendar.current
        var points: [Date] = []
        for d in -1...1 {
            guard let night = cal.date(byAdding: .day, value: d, to: now) else { continue }
            points += settings.reminders(night: night).map(\.1)
            if let q = settings.quietSpan(night: night) { points += [q.lowerBound, q.upperBound] }
        }
        for e in calendar.events {
            points += [e.start.addingTimeInterval(TimeInterval(-60 * max(settings.calendarLead, 0))),
                       e.start.addingTimeInterval(-2 * 3600), e.start, e.end]
        }
        // Re-read the calendar at least every 6 hours.
        let next = points.filter { $0 > now.addingTimeInterval(1) }.min() ?? now.addingTimeInterval(6 * 3600)
        let fireAt = min(next, now.addingTimeInterval(6 * 3600))
        let t = Timer(fire: fireAt.addingTimeInterval(1), interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.calendar.refresh() }
        }
        t.tolerance = 20
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let kind = response.notification.request.content.userInfo["kind"] as? String
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if kind == ReminderKind.closeDay.rawValue { self.openQueue() }
                if kind == "calendar" {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Calendar.app"))
                }
            }
            completionHandler()
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}

// MARK: - The notch line

struct CalendarLineView: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "calendar").font(.system(size: 10.5, weight: .semibold))
            Text(text).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(Color(red: 0.55, green: 0.75, blue: 1))
        .frame(height: 18)
        .padding(.horizontal, NotchLayout.ear + 18)
        .padding(.top, 2)
    }
}

// MARK: - Settings window

struct RemindersView: View {
    let reminders: Reminders
    @State private var s: ReminderSettings
    @State private var access: CalendarFeed.Access
    @State private var tested = false

    /// Monday first.
    private let order = [1, 2, 3, 4, 5, 6, 0]
    private let names = ["Domingo", "Lunes", "Martes", "Miércoles", "Jueves", "Viernes", "Sábado"]

    init(reminders: Reminders) {
        self.reminders = reminders
        _s = State(initialValue: reminders.settings)
        _access = State(initialValue: reminders.calendar.access)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Unos pocos avisos por noche, sin sonido. Después del último, GNotch no enseña nada más (ni el contador de preguntas ni avisos del temporizador) hasta la mañana.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                GridRow {
                    Text("Noche de").bold()
                    ForEach(ReminderKind.allCases) { k in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(k.label).bold()
                            Text(k == .closeDay ? "Abre las preguntas; solo si hay" : k == .windDown ? "Kit de sueño" : "Luego, silencio")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(order, id: \.self) { day in
                    GridRow(alignment: .top) {
                        Text(names[day]).frame(width: 82, alignment: .leading).padding(.top, 3)
                        ForEach(0..<3, id: \.self) { i in cell(day: day, index: i) }
                    }
                }
            }

            HStack(spacing: 8) {
                Text("Silencio hasta")
                timePicker($s.quietUntil, nextDay: false).frame(width: 80)
                Text("· las horas antes de las 12:00 cuentan como la misma noche").foregroundStyle(.secondary).font(.caption)
            }

            Divider()
            Text("Calendario").bold()
            Toggle("Enseñar en el notch el evento de ahora o el próximo (en las 2 horas siguientes)", isOn: $s.calendarLine)
            HStack {
                Text("Aviso antes de cada evento")
                Picker("", selection: $s.calendarLead) {
                    Text("Sin aviso").tag(0)
                    ForEach([5, 10, 15, 30], id: \.self) { Text("\($0) min").tag($0) }
                }
                .labelsHidden()
                .frame(width: 120)
            }
            calendarStatus

            Divider()
            HStack {
                Button(tested ? "Enviado" : "Probar un aviso") { reminders.test(); tested = true }
                    .help("Envía uno ahora. La primera vez macOS pregunta si permites notificaciones: Permitir.")
                Button("Horarios por defecto") { s = .standard }
                Spacer()
                if let (r, at) = reminders.next() {
                    Text("Siguiente: \(r.kind.label) · \(Self.hm(at))").foregroundStyle(.secondary)
                }
            }
        }
        .padding(20)
        .frame(width: 900)
        .onChange(of: s) { _, new in reminders.update(new) }
    }

    @ViewBuilder
    private func cell(day: Int, index: Int) -> some View {
        let binding = $s.nights[day][index]
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Toggle("", isOn: binding.on).labelsHidden().toggleStyle(.checkbox)
                timePicker(binding.time, nextDay: true).frame(width: 80).disabled(!binding.wrappedValue.on)
            }
            if binding.wrappedValue.kind != .closeDay {
                TextField("Texto", text: binding.text)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .frame(width: 250)
                    .disabled(!binding.wrappedValue.on)
            }
        }
    }

    private func timePicker(_ text: Binding<String>, nextDay: Bool) -> some View {
        let date = Binding<Date>(
            get: {
                let p = text.wrappedValue.split(separator: ":").compactMap { Int($0) }
                return Calendar.current.date(bySettingHour: p.first ?? 0, minute: p.count > 1 ? p[1] : 0, second: 0, of: Date()) ?? Date()
            },
            set: { text.wrappedValue = Self.hm($0) })
        return DatePicker("", selection: date, displayedComponents: .hourAndMinute)
            .labelsHidden()
            .datePickerStyle(.field)
            .environment(\.locale, Locale(identifier: "es_ES"))
    }

    @ViewBuilder
    private var calendarStatus: some View {
        let feed = reminders.calendar
        HStack(spacing: 8) {
            switch access {
            case .notAsked:
                Text("GNotch aún no puede leer el calendario.").foregroundStyle(.secondary)
                Button("Permitir acceso") {
                    feed.requestAccess()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { access = feed.access }
                }
            case .denied:
                Text("Sin acceso al calendario.").foregroundStyle(.orange)
                Button("Ajustes de privacidad…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                }
            case .ready:
                if feed.googleFound {
                    Text("Google conectado · \(feed.calendarCount) calendarios").foregroundStyle(.secondary)
                } else {
                    Text("No veo una cuenta de Google en Calendario (\(feed.calendarCount) calendarios). Añádela en Ajustes del Sistema → Cuentas de Internet → Google, con Calendarios activado.")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Cuentas de Internet…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension")!)
                    }
                }
            }
        }
        .font(.callout)
    }

    static func hm(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }
}
