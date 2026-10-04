import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct DashboardView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var router: DashboardRouter
    @State private var adding: DeepWorkSession?
    @AppStorage("heatMetric") private var metricRaw = HeatMetric.score.rawValue
    @State private var selectedDay: Date?
    @State private var editing: DeepWorkSession?

    private var metric: Binding<HeatMetric> {
        Binding(get: { HeatMetric(rawValue: metricRaw) ?? .score }, set: { metricRaw = $0.rawValue })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                    // Separate view from the edit sheet so both sheets work.
                    .sheet(item: $adding) { s in
                        SessionEditor(draft: s, isNew: true, others: store.sessions,
                                      onSave: { store.add($0); adding = nil },
                                      onDelete: {},
                                      onCancel: { adding = nil })
                    }
                statsRow
                heatmapCard
                sessionsSection
            }
            .padding(28)
        }
        .frame(minWidth: 860, minHeight: 600)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $editing) { s in
            SessionEditor(draft: s, isNew: false, others: store.sessions,
                          onSave: { store.update($0); editing = nil },
                          onDelete: { store.delete(s.id); editing = nil },
                          onCancel: { editing = nil })
        }
        .onAppear { if router.addRequest > 0 { adding = SessionEditor.blank() } }
        .onChange(of: router.addRequest) { _, _ in adding = SessionEditor.blank() }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Deep Work").font(.system(size: 26, weight: .bold))
                Text("\(store.sessions.count) blocks logged")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([store.fileURL])
            } label: {
                Label("Data file", systemImage: "folder")
            }
            Button {
                adding = SessionEditor.blank()
            } label: {
                Label("Add past block", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            Button(action: exportCSV) {
                Label("Export CSV", systemImage: "square.and.arrow.up")
            }
        }
    }

    private var statsRow: some View {
        let cal = Calendar.current
        let weekStart = cal.dateInterval(of: .weekOfYear, for: Date())?.start ?? Date()
        let monthStart = cal.dateInterval(of: .month, for: Date())?.start ?? Date()
        let avg = store.avgIntensity(lastDays: 30)
        let streak = store.streak()
        return HStack(spacing: 12) {
            StatCard(title: "Today", value: Fmt.hm(store.total(onDay: Date())))
            StatCard(title: "This week", value: Fmt.hm(store.total(since: weekStart)))
            StatCard(title: "This month", value: Fmt.hm(store.total(since: monthStart)))
            StatCard(title: "Streak", value: streak == 1 ? "1 day" : "\(streak) days")
            StatCard(title: "Avg intensity · 30d",
                     value: avg.map { String(format: "%.1f", $0) } ?? "–",
                     sub: avg.map { Intensity.label(Int($0.rounded())) })
            let rate = store.driftsPerHour(lastDays: 30)
            StatCard(title: "Drifts / hour · 30d", value: rate.map { String(format: "%.1f", $0) } ?? "–",
                     sub: rate == nil ? "pause = drift" : nil)
            StatCard(title: "All time", value: Fmt.hm(store.totalAllTime))
        }
    }

    private var heatmapCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Last 12 months").font(.headline)
                Spacer()
                Picker("", selection: metric) {
                    ForEach(HeatMetric.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 280)
            }
            HeatmapView(stats: store.dayStats(), metric: metric.wrappedValue, selected: $selectedDay)
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
    }

    // MARK: Sessions

    private var sessionsSection: some View {
        let cal = Calendar.current
        let filtered = selectedDay.map { day in store.sessions.filter { cal.isDate($0.start, inSameDayAs: day) } }
            ?? store.sessions
        let groups = Dictionary(grouping: filtered) { cal.startOfDay(for: $0.start) }
            .sorted { $0.key > $1.key }

        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Log").font(.headline)
                if let day = selectedDay {
                    Text("· \(Fmt.day.string(from: day))").foregroundStyle(.secondary)
                    Button("Show all") { selectedDay = nil }
                        .buttonStyle(.link)
                }
                Spacer()
            }

            if filtered.isEmpty {
                Text(selectedDay == nil
                     ? "No blocks yet. Hover the notch and hit Start."
                     : "No deep work this day.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 20)
            }

            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(groups, id: \.key) { day, sessions in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(Fmt.day.string(from: day)).font(.subheadline.weight(.semibold))
                            Spacer()
                            Text(Fmt.hm(sessions.reduce(0) { $0 + $1.duration }))
                                .font(.subheadline.weight(.semibold))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        ForEach(sessions) { s in
                            SessionRow(session: s)
                                .onTapGesture { editing = s }
                                .contextMenu {
                                    Button("Edit…") { editing = s }
                                    Button("Delete", role: .destructive) { store.delete(s.id) }
                                }
                        }
                    }
                }
            }
        }
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "deepwork-sessions.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        if panel.runModal() == .OK, let url = panel.url {
            try? store.csv().write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

struct StatCard: View {
    let title: String
    let value: String
    var sub: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text(value).font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(sub ?? " ").font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
    }
}

struct SessionRow: View {
    let session: DeepWorkSession

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Fmt.hm(session.duration))
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                Text("\(Fmt.time.string(from: session.start))–\(Fmt.time.string(from: session.end))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .frame(width: 100, alignment: .leading)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(session.displayTask).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if let pauses = session.pauses {
                        DriftTimeline(start: session.start, end: session.end, pauses: pauses, height: 4)
                            .frame(width: 90)
                        Text(session.drifts == 0 ? "no drifts" : session.drifts == 1 ? "1 drift" : "\(session.drifts) drifts")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(session.drifts > 0 ? Color.orange : Color.secondary)
                    }
                    if session.manual == true {
                        Image(systemName: "pencil")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .help("Added by hand")
                    }
                    IntensityBadge(value: session.intensity)
                }
                if !session.tags.isEmpty {
                    FlowLayout(spacing: 4) {
                        ForEach(session.tags, id: \.self) { TagChip(text: $0) }
                    }
                }
                if !session.notes.isEmpty {
                    Text(session.notes)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
        .contentShape(Rectangle())
    }
}

/// Edits a logged block, or creates one by hand (e.g. a library session done away from the Mac).
struct SessionEditor: View {
    @State var draft: DeepWorkSession
    let isNew: Bool
    let others: [DeepWorkSession]
    let onSave: (DeepWorkSession) -> Void
    let onDelete: () -> Void
    let onCancel: () -> Void

    @State private var start: Date
    @State private var hours: Int
    @State private var minutes: Int

    init(draft: DeepWorkSession, isNew: Bool, others: [DeepWorkSession],
         onSave: @escaping (DeepWorkSession) -> Void, onDelete: @escaping () -> Void, onCancel: @escaping () -> Void) {
        _draft = State(initialValue: draft)
        self.isNew = isNew
        self.others = others
        self.onSave = onSave
        self.onDelete = onDelete
        self.onCancel = onCancel
        _start = State(initialValue: draft.start)
        let m = Int((draft.duration / 60).rounded())
        _hours = State(initialValue: m / 60)
        _minutes = State(initialValue: m % 60)
    }

    /// A blank block ending now-ish, for manual entry.
    static func blank() -> DeepWorkSession {
        let cal = Calendar.current
        var start = Date().addingTimeInterval(-2 * 3600)
        let m = cal.component(.minute, from: start)
        start = cal.date(byAdding: .minute, value: -(m % 5), to: start)!
        start = cal.date(bySetting: .second, value: 0, of: start) ?? start
        return DeepWorkSession(start: start, end: start.addingTimeInterval(7200), duration: 7200, plannedMinutes: nil,
                               task: "", intensity: 3, tags: [], notes: "", manual: true)
    }

    private var duration: TimeInterval { TimeInterval(hours * 3600 + minutes * 60) }
    private var end: Date { start.addingTimeInterval(duration) }
    private var timesChanged: Bool {
        abs(start.timeIntervalSince(draft.start)) > 30 || abs(duration - draft.duration) > 30
    }
    private var overlap: DeepWorkSession? {
        others.first { $0.id != draft.id && $0.start < end && $0.end > start }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? "Add a past block" : "Edit block").font(.title3.bold())

            TextField("What did you work on? (e.g. Library: thesis reading)", text: $draft.task)
                .textFieldStyle(.roundedBorder)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Started").foregroundStyle(.secondary)
                    DatePicker("", selection: $start, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden()
                        .datePickerStyle(.field)
                }
                GridRow {
                    Text("Duration").foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        Stepper("\(hours) h", value: $hours, in: 0...16)
                        Stepper(String(format: "%02d min", minutes), value: $minutes, in: 0...55, step: 5)
                        Text("ends \(Fmt.time.string(from: end))").foregroundStyle(.secondary)
                    }
                    .monospacedDigit()
                }
                GridRow {
                    Color.clear.frame(width: 1, height: 1)
                    HStack(spacing: 6) {
                        ForEach([25, 50, 90, 120, 180, 240], id: \.self) { m in
                            Button(m < 60 ? "\(m)m" : m % 60 == 0 ? "\(m / 60)h" : "\(m / 60)h\(m % 60)") {
                                hours = m / 60
                                minutes = m % 60
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }

            if let o = overlap {
                Label("Overlaps “\(o.displayTask)” \(Fmt.time.string(from: o.start))–\(Fmt.time.string(from: o.end))",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Intensity").font(.caption.bold()).foregroundStyle(.secondary)
                IntensityPicker(value: $draft.intensity)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("How did it feel?").font(.caption.bold()).foregroundStyle(.secondary)
                TagPicker(selection: $draft.tags)
            }
            NotesEditor(text: $draft.notes)
                .frame(height: 90)

            HStack {
                if !isNew { Button("Delete", role: .destructive, action: onDelete) }
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add to log" : "Save") {
                    var s = draft
                    if isNew || timesChanged {
                        s.start = start
                        s.end = end
                        s.duration = duration
                    }
                    onSave(s)
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(duration < 60)
            }
        }
        .padding(22)
        .frame(width: 500)
    }
}

/// Lets the notch ask the dashboard to open the "add a past block" form.
@MainActor
final class DashboardRouter: ObservableObject {
    @Published var addRequest = 0
}
