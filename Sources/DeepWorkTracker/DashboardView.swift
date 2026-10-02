import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct DashboardView: View {
    @ObservedObject var store: SessionStore
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
                statsRow
                heatmapCard
                sessionsSection
            }
            .padding(28)
        }
        .frame(minWidth: 860, minHeight: 600)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $editing) { s in
            SessionEditor(draft: s,
                          onSave: { store.update($0); editing = nil },
                          onDelete: { store.delete(s.id); editing = nil },
                          onCancel: { editing = nil })
        }
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

struct SessionEditor: View {
    @State var draft: DeepWorkSession
    let onSave: (DeepWorkSession) -> Void
    let onDelete: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit block").font(.title3.bold())
            Text("\(Fmt.day.string(from: draft.start)) · \(Fmt.time.string(from: draft.start))–\(Fmt.time.string(from: draft.end)) · \(Fmt.hm(draft.duration))")
                .foregroundStyle(.secondary)

            TextField("Task", text: $draft.task)
                .textFieldStyle(.roundedBorder)

            VStack(alignment: .leading, spacing: 6) {
                Text("Intensity").font(.caption.bold()).foregroundStyle(.secondary)
                IntensityPicker(value: $draft.intensity)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("How did it feel?").font(.caption.bold()).foregroundStyle(.secondary)
                TagPicker(selection: $draft.tags)
            }
            NotesEditor(text: $draft.notes)
                .frame(height: 110)

            HStack {
                Button("Delete", role: .destructive, action: onDelete)
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save") { onSave(draft) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(width: 460)
    }
}
