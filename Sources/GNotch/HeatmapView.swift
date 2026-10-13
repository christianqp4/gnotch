import SwiftUI

/// How heatmaps are drawn: the GitHub-style year (zoomed out, to see the trend) or month
/// calendars read left to right (zoomed in, to recognise weeks and plan).
enum HeatStyle: String, CaseIterable, Identifiable {
    case year = "Year"
    case calendar = "Calendar"

    var id: String { rawValue }
    var icon: String { self == .year ? "square.grid.3x3.fill" : "calendar" }
}

/// ISO week numbers (Monday first; week 1 holds the year's first Thursday), as in "week 42 of 53".
enum WeekNumber {
    static let iso: Calendar = {
        var c = Calendar(identifier: .iso8601)
        c.timeZone = .current
        return c
    }()

    static func of(_ d: Date) -> Int { iso.component(.weekOfYear, from: d) }
    static func count(_ d: Date) -> Int { iso.range(of: .weekOfYear, in: .yearForWeekOfYear, for: d)?.count ?? 52 }
    static func label(_ d: Date = Date()) -> String { "Week \(of(d))/\(count(d))" }
    /// The year view labels week 1, every tenth week, and this week.
    static func isLandmark(_ w: Int, current: Int) -> Bool { w == 1 || w % 10 == 0 || w == current }
}

/// Dev only: lets the snapshot tool render a heatmap with a day already hovered.
enum SnapshotHints {
    nonisolated(unsafe) static var hover: HeatHover?
}

/// The day under the pointer and where the pointer is, in the "heat" coordinate space.
struct HeatHover: Equatable {
    var day: Date
    var point: CGPoint
}

/// One day. No number inside: colour only, the labels around the grid do the orienting.
struct HeatCell: View {
    let day: Date
    let level: Int
    let size: CGFloat
    var selected = false
    /// Calendar view outlines the days ahead (to plan); the year view hides them.
    var showFuture = false
    @Binding var hover: HeatHover?
    var onTap: (() -> Void)?

    var body: some View {
        let today = Calendar.current.startOfDay(for: Date())
        let future = day > today
        let r = size * 0.23
        RoundedRectangle(cornerRadius: r)
            .fill(future ? Color.clear : Heat.color(level))
            .overlay(
                RoundedRectangle(cornerRadius: r)
                    .strokeBorder(selected ? Color.primary : day == today ? Color.white.opacity(0.85) : Color.primary.opacity(future ? 0.14 : 0),
                                  lineWidth: selected ? 1.5 : 1)
            )
            .frame(width: size, height: size)
            .opacity(future && !showFuture ? 0 : 1)
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .named("heat")) { phase in
                switch phase {
                case .active(let p): hover = HeatHover(day: day, point: p)
                case .ended: if hover?.day == day { hover = nil }
                }
            }
            .onTapGesture { if !future { onTap?() } }
    }
}

// MARK: Year (GitHub) view

/// Weeks as columns, days top to bottom. Months on top, landmark week numbers underneath.
struct YearGrid: View {
    let weeks: Int
    let stats: [Date: DayStat]
    let metric: HeatMetric
    var cell: CGFloat = 11
    var gap: CGFloat = 3
    var weekdayLabels = true
    @Binding var selected: Date?
    @Binding var hover: HeatHover?
    var tappable = true

    private var cal: Calendar { Calendar.current }
    private var labelSize: CGFloat { max(8, cell * 0.8) }

    private var columns: [[Date]] {
        let today = cal.startOfDay(for: Date())
        let weekStart = cal.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        let first = cal.date(byAdding: .weekOfYear, value: -(weeks - 1), to: weekStart)!
        return (0..<weeks).map { w in
            (0..<7).map { d in cal.date(byAdding: .day, value: w * 7 + d, to: first)! }
        }
    }

    var body: some View {
        let cols = columns
        HStack(alignment: .top, spacing: 6) {
            if weekdayLabels {
                VStack(alignment: .trailing, spacing: gap) {
                    Color.clear.frame(height: labelSize + 3)
                    ForEach(0..<7, id: \.self) { i in
                        Text(i % 2 == 0 ? cal.shortWeekdaySymbols[(cal.firstWeekday - 1 + i) % 7] : "")
                            .font(.system(size: labelSize))
                            .foregroundStyle(.secondary)
                            .frame(height: cell)
                    }
                }
            }
            VStack(alignment: .leading, spacing: gap) {
                monthLabels(cols)
                HStack(spacing: gap) {
                    ForEach(cols.indices, id: \.self) { w in
                        VStack(spacing: gap) {
                            ForEach(0..<7, id: \.self) { d in
                                let day = cols[w][d]
                                HeatCell(day: day, level: metric.level(stats[day]), size: cell,
                                         selected: selected == day, hover: $hover,
                                         onTap: tappable ? { selected = selected == day ? nil : day } : nil)
                            }
                        }
                    }
                }
                weekLabels(cols)
            }
        }
    }

    private func label(_ text: String, at w: Int, strong: Bool = false) -> some View {
        Text(text)
            .font(.system(size: labelSize, weight: strong ? .bold : .regular))
            .monospacedDigit()
            .foregroundStyle(strong ? Color.primary : Color.secondary)
            .fixedSize()
            .offset(x: CGFloat(w) * (cell + gap))
    }

    private func monthLabels(_ cols: [[Date]]) -> some View {
        let fmt = DateFormatter()
        fmt.setLocalizedDateFormatFromTemplate("MMM")
        return ZStack(alignment: .topLeading) {
            ForEach(cols.indices, id: \.self) { w in
                if w > 0, w < cols.count - 1,
                   cal.component(.month, from: cols[w][6]) != cal.component(.month, from: cols[w - 1][6]) {
                    label(fmt.string(from: cols[w][6]), at: w)
                }
            }
        }
        .frame(width: CGFloat(cols.count) * (cell + gap), height: labelSize + 3, alignment: .topLeading)
    }

    private func weekLabels(_ cols: [[Date]]) -> some View {
        let current = WeekNumber.of(Date())
        // The week number of a column is the ISO week of its middle day.
        let numbers = cols.map { WeekNumber.of($0[3]) }
        return ZStack(alignment: .topLeading) {
            ForEach(cols.indices, id: \.self) { w in
                let n = numbers[w]
                // One label per week; a landmark right next to this week would crowd it, so it is skipped.
                // This week is the last column; the same number a year earlier (first column) isn't labelled.
                let now = w == cols.count - 1
                if now || (n != current && (w == 0 || numbers[w - 1] != n)
                           && WeekNumber.isLandmark(n, current: current) && abs(current - n) > 1) {
                    label(now ? "W\(n)" : "\(n)", at: w, strong: now)
                }
            }
        }
        .frame(width: CGFloat(cols.count) * (cell + gap), height: labelSize + 3, alignment: .topLeading)
    }
}

// MARK: Calendar view

/// The last `months` months as small calendars, `perRow` side by side. Days run left to right,
/// each row starts with its week number.
struct CalendarGrid: View {
    let months: Int
    var perRow: Int = 6
    let stats: [Date: DayStat]
    let metric: HeatMetric
    var cell: CGFloat = 11
    var gap: CGFloat = 3
    @Binding var selected: Date?
    @Binding var hover: HeatHover?
    var tappable = true

    private var cal: Calendar { Calendar.current }

    var body: some View {
        let thisMonth = cal.dateInterval(of: .month, for: Date())!.start
        let starts = (0..<months).reversed().map { cal.date(byAdding: .month, value: -$0, to: thisMonth)! }
        let rows = stride(from: 0, to: starts.count, by: perRow).map { Array(starts[$0..<min($0 + perRow, starts.count)]) }
        VStack(alignment: .leading, spacing: cell) {
            ForEach(rows.indices, id: \.self) { r in
                HStack(alignment: .top, spacing: cell * 1.3) {
                    ForEach(rows[r], id: \.self) { start in
                        month(start, first: start == starts.first)
                    }
                }
            }
        }
    }

    private func month(_ start: Date, first: Bool) -> some View {
        let fmt = DateFormatter()
        let january = cal.component(.month, from: start) == 1
        fmt.setLocalizedDateFormatFromTemplate(first || january ? "MMMyyyy" : "MMM")
        let isCurrent = cal.isDate(start, equalTo: Date(), toGranularity: .month)
        let end = cal.date(byAdding: .month, value: 1, to: start)!
        var weekStarts: [Date] = []
        var w = cal.dateInterval(of: .weekOfYear, for: start)!.start
        while w < end {
            weekStarts.append(w)
            w = cal.date(byAdding: .day, value: 7, to: w)!
        }
        let numW = cell * 1.5
        let small = max(7.5, cell * 0.7)
        let currentWeek = WeekNumber.of(Date())

        return VStack(alignment: .leading, spacing: gap) {
            Text(fmt.string(from: start))
                .font(.system(size: max(9, cell * 0.85), weight: .semibold))
                .foregroundStyle(isCurrent ? Color.primary : Color.secondary)
                .padding(.leading, numW + gap)
            HStack(spacing: gap) {
                Color.clear.frame(width: numW, height: small)
                ForEach(0..<7, id: \.self) { i in
                    Text(cal.veryShortWeekdaySymbols[(cal.firstWeekday - 1 + i) % 7])
                        .font(.system(size: small))
                        .foregroundStyle(.tertiary)
                        .frame(width: cell)
                }
            }
            ForEach(weekStarts, id: \.self) { ws in
                let n = WeekNumber.of(cal.date(byAdding: .day, value: 3, to: ws)!)
                let thisWeek = n == currentWeek && cal.isDate(ws, equalTo: Date(), toGranularity: .weekOfYear)
                HStack(spacing: gap) {
                    Text("\(n)")
                        .font(.system(size: small, weight: thisWeek ? .bold : .regular))
                        .monospacedDigit()
                        .foregroundStyle(thisWeek ? Color.primary : Color.secondary.opacity(0.7))
                        .frame(width: numW, height: cell, alignment: .trailing)
                    ForEach(0..<7, id: \.self) { d in
                        let day = cal.date(byAdding: .day, value: d, to: ws)!
                        if cal.isDate(day, equalTo: start, toGranularity: .month) {
                            HeatCell(day: day, level: metric.level(stats[day]), size: cell,
                                     selected: selected == day, showFuture: true, hover: $hover,
                                     onTap: tappable ? { selected = selected == day ? nil : day } : nil)
                        } else {
                            Color.clear.frame(width: cell, height: cell)
                        }
                    }
                }
            }
        }
    }
}

// MARK: Hover card

/// The quick look for one day: total, then each block's time and intensity.
struct DayCard: View {
    let day: Date
    let blocks: [DeepWorkSession]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(Fmt.day.string(from: day)).font(.system(size: 11, weight: .bold))
                Spacer()
                Text("W\(WeekNumber.of(day))").foregroundStyle(.secondary).monospacedDigit()
            }
            if blocks.isEmpty {
                Text(day > Date() ? "Ahead: nothing logged yet" : "No deep work").foregroundStyle(.secondary)
            } else {
                let total = blocks.reduce(0) { $0 + $1.duration }
                let avg = blocks.reduce(0) { $0 + $1.minutes * Double($1.intensity) } / max(1, total / 60)
                Text("\(Fmt.hm(total)) · \(blocks.count == 1 ? "1 block" : "\(blocks.count) blocks") · \(Intensity.label(Int(avg.rounded())))")
                    .foregroundStyle(.secondary)
                ForEach(blocks.prefix(5)) { b in
                    HStack(spacing: 6) {
                        Circle().fill(Intensity.color(b.intensity)).frame(width: 6, height: 6)
                        Text("\(Fmt.time.string(from: b.start))–\(Fmt.time.string(from: b.end))").monospacedDigit()
                        Text(Intensity.label(b.intensity)).foregroundStyle(Intensity.color(b.intensity))
                        Text(b.displayTask).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                if blocks.count > 5 {
                    Text("+\(blocks.count - 5) more").foregroundStyle(.secondary)
                }
            }
        }
        .font(.system(size: 10.5))
        .padding(10)
        .frame(width: 250, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(white: 0.12))
                .shadow(color: .black.opacity(0.4), radius: 8, y: 3)
        )
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.1)))
        .environment(\.colorScheme, .dark)
        .allowsHitTesting(false)
    }
}

extension View {
    /// Shows the day card just above the pointer, kept inside the view's width.
    func heatHoverCard(_ hover: HeatHover?, store: SessionStore) -> some View {
        overlay(alignment: .topLeading) {
            GeometryReader { geo in
                if let h = hover {
                    let x = min(max(0, h.point.x - 125), max(0, geo.size.width - 250))
                    let card = DayCard(day: h.day, blocks: store.blocks(on: h.day))
                    // Always above the pointer: what's above was drawn earlier, so the card covers it
                    // (below, the next section would draw over the card).
                    card.frame(height: max(0, h.point.y - 10), alignment: .bottom).offset(x: x)
                }
            }
        }
        .coordinateSpace(name: "heat")
    }
}

// MARK: Full heatmap (dashboard, big timer page)

/// The last 12 months, as a year grid or as month calendars.
struct HeatmapView: View {
    @ObservedObject var store: SessionStore
    let metric: HeatMetric
    @Binding var selected: Date?

    var cell: CGFloat = 11
    var gap: CGFloat = 3
    var showExplanation = true
    var tappable = true
    @AppStorage("heatStyle") private var styleRaw = HeatStyle.year.rawValue
    @State private var hover: HeatHover? = SnapshotHints.hover

    var body: some View {
        let stats = store.dayStats()
        VStack(alignment: .leading, spacing: 10) {
            Group {
                if HeatStyle(rawValue: styleRaw) == .calendar {
                    CalendarGrid(months: 12, perRow: 6, stats: stats, metric: metric, cell: cell, gap: gap,
                                 selected: $selected, hover: $hover, tappable: tappable)
                } else {
                    YearGrid(weeks: 53, stats: stats, metric: metric, cell: cell, gap: gap,
                             selected: $selected, hover: $hover, tappable: tappable)
                }
            }
            .heatHoverCard(hover, store: store)
            .zIndex(1)

            HStack(spacing: 4) {
                if showExplanation { Text(metric.explanation) }
                Spacer()
                Text("Less")
                ForEach(0..<5, id: \.self) { l in
                    RoundedRectangle(cornerRadius: 2.5).fill(Heat.color(l)).frame(width: cell, height: cell)
                }
                Text("More")
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
        }
    }
}

/// Segmented Year | Calendar switch, shared by the dashboard and the big timer page.
struct HeatStylePicker: View {
    @AppStorage("heatStyle") private var styleRaw = HeatStyle.year.rawValue
    var compact = false

    var body: some View {
        Picker("", selection: $styleRaw) {
            ForEach(HeatStyle.allCases) { s in
                if compact {
                    Image(systemName: s.icon).tag(s.rawValue).help(s == .year ? "Year view" : "Calendar view")
                } else {
                    Label(s.rawValue, systemImage: s.icon).tag(s.rawValue)
                }
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}

// MARK: Mini heatmap (notch)

/// The small heatmap in the notch: 24 weeks, or the last three months as calendars.
/// Hovering a day reports it through `hovered`, so the notch can show its details beside the grid.
struct MiniHeatmap: View {
    @ObservedObject var store: SessionStore
    @Binding var hovered: Date?
    var cell: CGFloat = 8
    var gap: CGFloat = 2.5
    @AppStorage("heatMetric") private var metricRaw = HeatMetric.score.rawValue
    @AppStorage("heatStyle") private var styleRaw = HeatStyle.year.rawValue
    @State private var hover: HeatHover?

    var body: some View {
        let stats = store.dayStats()
        let metric = HeatMetric(rawValue: metricRaw) ?? .score
        Group {
            if HeatStyle(rawValue: styleRaw) == .calendar {
                CalendarGrid(months: 3, perRow: 3, stats: stats, metric: metric, cell: cell, gap: gap,
                             selected: .constant(nil), hover: $hover, tappable: false)
                    .fixedSize()
            } else {
                YearGrid(weeks: 24, stats: stats, metric: metric, cell: cell, gap: gap, weekdayLabels: false,
                         selected: .constant(nil), hover: $hover, tappable: false)
                    .fixedSize()
            }
        }
        .coordinateSpace(name: "heat")
        .contentShape(Rectangle())
        .onChange(of: hover) { _, h in hovered = h?.day }
    }
}

/// Two or three lines about a hovered day, for tight spots like the notch.
struct DayBrief: View {
    let day: Date
    let blocks: [DeepWorkSession]

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text("\(Fmt.shortDay.string(from: day)) · W\(WeekNumber.of(day))").foregroundStyle(.primary)
            if blocks.isEmpty {
                Text(day > Date() ? "Ahead" : "No deep work")
            } else {
                Text("\(Fmt.hm(blocks.reduce(0) { $0 + $1.duration })) · \(blocks.count == 1 ? "1 block" : "\(blocks.count) blocks")")
                    .monospacedDigit()
                ForEach(blocks.prefix(3)) { b in
                    HStack(spacing: 4) {
                        Text("\(Fmt.time.string(from: b.start))–\(Fmt.time.string(from: b.end))").monospacedDigit()
                        Text(Intensity.label(b.intensity)).foregroundStyle(Intensity.color(b.intensity))
                    }
                }
            }
        }
    }
}
