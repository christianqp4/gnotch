import SwiftUI

/// The block as a bar: green while focused, orange where you paused (drifted), grey where the Mac slept.
struct DriftTimeline: View {
    let start: Date
    let end: Date
    let pauses: [PauseSpan]
    /// A pause still in progress.
    var openPause: Date? = nil
    var height: CGFloat = 5

    var body: some View {
        let spans = pauses + (openPause.map { [PauseSpan(start: $0, end: end)] } ?? [])
        let total = max(1, end.timeIntervalSince(start))
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Rectangle().fill(Heat.base.opacity(0.85))
                ForEach(spans.indices, id: \.self) { i in
                    let s = spans[i]
                    Rectangle()
                        .fill(s.auto == true ? Color.gray : Color.orange)
                        .frame(width: max(2, g.size.width * s.duration / total))
                        .offset(x: g.size.width * max(0, s.start.timeIntervalSince(start)) / total)
                }
            }
        }
        .frame(height: height)
        .clipShape(Capsule())
        .help(summary(spans))
    }

    private func summary(_ spans: [PauseSpan]) -> String {
        let drifts = spans.filter { $0.auto != true }
        guard !drifts.isEmpty else { return "No drifts" }
        return drifts.map { "\(Fmt.time.string(from: $0.start)) · \(Fmt.clock($0.duration))" }.joined(separator: "\n")
    }
}

enum DriftText {
    static func summary(drifts: Int, paused: TimeInterval) -> String {
        switch drifts {
        case 0: return "No drifts"
        case 1: return "1 drift · \(Fmt.hm(max(60, paused))) paused"
        default: return "\(drifts) drifts · \(Fmt.hm(max(60, paused))) paused"
        }
    }
}

/// Small orange dots, one per drift (up to 5), for tight spaces.
struct DriftDots: View {
    let count: Int

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<min(count, 5), id: \.self) { _ in
                Circle().fill(Color.orange).frame(width: 4, height: 4)
            }
        }
        .help(count == 1 ? "1 drift" : "\(count) drifts")
    }
}

/// Paced breathing while paused: 4 s in, 6 s out, starting with an inhale when you pause.
struct BreathingGuide: View {
    let since: Date
    var size: CGFloat
    var showText = true

    static let inhale = 4.0
    static let exhale = 6.0

    var body: some View {
        TimelineView(.animation) { ctx in
            let t = max(0, ctx.date.timeIntervalSince(since))
                .truncatingRemainder(dividingBy: Self.inhale + Self.exhale)
            let inhaling = t < Self.inhale
            let p = inhaling ? t / Self.inhale : 1 - (t - Self.inhale) / Self.exhale
            let eased = 0.5 - 0.5 * cos(Double.pi * p)
            ZStack {
                Circle()
                    .fill(Color.orange.opacity(0.12 + 0.22 * eased))
                    .scaleEffect(0.5 + 0.5 * eased)
                Circle()
                    .stroke(Color.orange.opacity(0.65), lineWidth: 1.5)
                    .scaleEffect(0.5 + 0.5 * eased)
                if showText {
                    Text(size >= 100 ? (inhaling ? "Breathe in" : "Breathe out") : (inhaling ? "in" : "out"))
                        .font(.system(size: max(9, size * 0.16), weight: .semibold, design: .rounded))
                        .foregroundStyle(.orange)
                }
            }
            .frame(width: size, height: size)
        }
    }

    /// "Breathe in" / "Breathe out" for labels outside the circle.
    static func prompt(since: Date, now: Date) -> String {
        let t = max(0, now.timeIntervalSince(since)).truncatingRemainder(dividingBy: inhale + exhale)
        return t < inhale ? "Breathe in" : "Breathe out"
    }
}
