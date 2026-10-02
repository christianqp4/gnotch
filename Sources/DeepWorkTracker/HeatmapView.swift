import SwiftUI

/// GitHub-style contribution grid for the last 53 weeks.
struct HeatmapView: View {
    let stats: [Date: DayStat]
    let metric: HeatMetric
    @Binding var selected: Date?

    private let cell: CGFloat = 11
    private let gap: CGFloat = 3
    private var cal: Calendar { Calendar.current }

    private var weeks: [[Date]] {
        let today = cal.startOfDay(for: Date())
        let weekStart = cal.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        let first = cal.date(byAdding: .weekOfYear, value: -52, to: weekStart)!
        return (0..<53).map { w in
            (0..<7).map { d in cal.date(byAdding: .day, value: w * 7 + d, to: first)! }
        }
    }

    var body: some View {
        let weeks = self.weeks
        let today = cal.startOfDay(for: Date())

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .trailing, spacing: gap) {
                    Color.clear.frame(height: 14)
                    ForEach(0..<7, id: \.self) { i in
                        Text(i % 2 == 0 ? weekdaySymbol(i) : "")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .frame(height: cell)
                    }
                }

                VStack(alignment: .leading, spacing: gap) {
                    monthLabels(weeks)
                    HStack(spacing: gap) {
                        ForEach(weeks.indices, id: \.self) { w in
                            VStack(spacing: gap) {
                                ForEach(0..<7, id: \.self) { d in
                                    cellView(weeks[w][d], future: weeks[w][d] > today)
                                }
                            }
                        }
                    }
                }
            }

            HStack(spacing: 4) {
                Text(metric.explanation)
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

    private func cellView(_ day: Date, future: Bool) -> some View {
        let s = stats[day]
        let isSelected = selected == day
        return RoundedRectangle(cornerRadius: 2.5)
            .fill(Heat.color(metric.level(s)))
            .frame(width: cell, height: cell)
            .overlay(
                RoundedRectangle(cornerRadius: 2.5)
                    .stroke(Color.primary, lineWidth: isSelected ? 1.5 : 0)
            )
            .opacity(future ? 0 : 1)
            .help(future ? "" : tooltip(day, s))
            .onTapGesture {
                guard !future else { return }
                selected = isSelected ? nil : day
            }
    }

    private func tooltip(_ day: Date, _ s: DayStat?) -> String {
        let d = Fmt.shortDay.string(from: day)
        guard let s, s.count > 0 else { return "\(d) · no deep work" }
        let blocks = s.count == 1 ? "1 block" : "\(s.count) blocks"
        return String(format: "%@ · %@ · %@ · intensity %.1f", d, Fmt.hm(s.minutes * 60), blocks, s.avgIntensity)
    }

    private func weekdaySymbol(_ row: Int) -> String {
        let idx = (cal.firstWeekday - 1 + row) % 7
        return cal.shortWeekdaySymbols[idx]
    }

    private func monthLabels(_ weeks: [[Date]]) -> some View {
        let fmt = DateFormatter()
        fmt.setLocalizedDateFormatFromTemplate("MMM")
        return ZStack(alignment: .topLeading) {
            ForEach(weeks.indices, id: \.self) { w in
                if w > 0, w < weeks.count - 1,
                   cal.component(.month, from: weeks[w][0]) != cal.component(.month, from: weeks[w - 1][0]) {
                    Text(fmt.string(from: weeks[w][6]))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .offset(x: CGFloat(w) * (cell + gap))
                }
            }
        }
        .frame(width: CGFloat(weeks.count) * (cell + gap), height: 14, alignment: .topLeading)
    }
}
