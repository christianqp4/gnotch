import SwiftUI

/// A notch-like shape: concave ears at the top corners, rounded bottom corners.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let tr = topRadius
        let br = min(bottomRadius, (rect.height - tr) / 2, (rect.width - 2 * tr) / 2)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + tr, y: rect.minY + tr),
                       control: CGPoint(x: rect.minX + tr, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + tr, y: rect.maxY - br))
        p.addQuadCurve(to: CGPoint(x: rect.minX + tr + br, y: rect.maxY),
                       control: CGPoint(x: rect.minX + tr, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - tr - br, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - tr, y: rect.maxY - br),
                       control: CGPoint(x: rect.maxX - tr, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY + tr))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                       control: CGPoint(x: rect.maxX - tr, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

/// Wraps children onto multiple lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > maxW {
                x = 0
                y += rowH + spacing
                rowH = 0
            }
            x += s.width + spacing
            rowH = max(rowH, s.height)
            widest = max(widest, x - spacing)
        }
        let w = proposal.width.map { $0.isFinite ? $0 : widest } ?? widest
        return CGSize(width: w, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > bounds.width {
                x = 0
                y += rowH + spacing
                rowH = 0
            }
            v.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y), proposal: .unspecified)
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }
}

struct IntensityPicker: View {
    @Binding var value: Int
    var size: CGFloat = 17

    var body: some View {
        HStack(spacing: 6) {
            ForEach(1...5, id: \.self) { i in
                Button {
                    value = i
                } label: {
                    Image(systemName: i <= value ? "flame.fill" : "flame")
                        .font(.system(size: size))
                        .foregroundStyle(i <= value ? Intensity.color(value) : Color.secondary.opacity(0.6))
                        .frame(width: size + 6, height: size + 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(i) · \(Intensity.label(i))")
            }
            Text("\(value) · \(Intensity.label(value))")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Intensity.color(value))
                .padding(.leading, 4)
        }
    }
}

struct IntensityBadge: View {
    let value: Int

    var body: some View {
        HStack(spacing: 1) {
            ForEach(1...5, id: \.self) { i in
                Image(systemName: "flame.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(i <= value ? Intensity.color(value) : Color.primary.opacity(0.12))
            }
        }
        .help("Intensity \(value) · \(Intensity.label(value))")
    }
}

struct TagPicker: View {
    @Binding var selection: [String]

    var body: some View {
        let options = SensationTags.all + selection.filter { !SensationTags.all.contains($0) }
        FlowLayout(spacing: 6) {
            ForEach(options, id: \.self) { tag in
                let on = selection.contains(tag)
                Button {
                    if on { selection.removeAll { $0 == tag } } else { selection.append(tag) }
                } label: {
                    Text(tag)
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(on ? Heat.base : Color.primary.opacity(0.09)))
                        .foregroundStyle(on ? Color.black : Color.primary)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct TagChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.primary.opacity(0.08)))
    }
}

/// A multi-line text box with a placeholder.
struct NotesEditor: View {
    @Binding var text: String
    var placeholder = "Notes & sensations: what helped, what pulled you out, how your body felt…"

    var body: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .font(.system(size: 12.5))
                .scrollContentBackground(.hidden)
                .padding(6)
            if text.isEmpty {
                Text(placeholder)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .allowsHitTesting(false)
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.07)))
    }
}

struct ProgressRing: View {
    let progress: Double?
    let tint: Color
    var lineWidth: CGFloat = 3

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.15), lineWidth: lineWidth)
            if let progress {
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
    }
}

struct CircleButton: View {
    let icon: String
    let tint: Color
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(Circle().fill(tint.opacity(0.18)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
