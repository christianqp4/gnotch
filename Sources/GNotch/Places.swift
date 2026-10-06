import SwiftUI

/// Where a block happened: a few built-in places plus the ones you type, remembered for next time.
enum Places {
    static let builtIn: [(name: String, icon: String)] = [
        ("Library", "books.vertical.fill"),
        ("House", "house.fill"),
        ("Coworking", "building.2.fill"),
        ("Coffee", "cup.and.saucer.fill"),
    ]

    static func icon(_ name: String) -> String {
        builtIn.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.icon ?? "mappin.and.ellipse"
    }

    /// Places you've typed yourself, most recent first.
    static var custom: [String] {
        UserDefaults.standard.stringArray(forKey: "customPlaces") ?? []
    }

    static var all: [String] { builtIn.map(\.name) + custom }

    /// The place of the last saved block: the default for the next one.
    static var last: String? { UserDefaults.standard.string(forKey: "lastPlace") }

    static func remember(_ place: String?) {
        let d = UserDefaults.standard
        guard let place = place?.trimmingCharacters(in: .whitespacesAndNewlines), !place.isEmpty else { return }
        d.set(place, forKey: "lastPlace")
        guard !builtIn.contains(where: { $0.name.caseInsensitiveCompare(place) == .orderedSame }) else { return }
        var list = custom.filter { $0.caseInsensitiveCompare(place) != .orderedSame }
        list.insert(place, at: 0)
        d.set(Array(list.prefix(8)), forKey: "customPlaces")
    }
}

/// Place chips plus "Other…" to type a new one. Tap the selected chip again to clear it.
struct PlacePicker: View {
    @Binding var place: String?
    @State private var typing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        let names = Places.all + (place.map { p in Places.all.contains(p) ? [] : [p] } ?? [])
        FlowLayout(spacing: 6) {
            ForEach(names, id: \.self) { name in
                let on = place == name
                Button {
                    place = on ? nil : name
                } label: {
                    Label(name, systemImage: Places.icon(name))
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(on ? Heat.base : Color.primary.opacity(0.09)))
                        .foregroundStyle(on ? Color.black : Color.primary)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            if typing {
                TextField("Place", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 110)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Capsule().strokeBorder(Heat.base, lineWidth: 1))
                    .focused($focused)
                    .onSubmit(commit)
                    .onExitCommand { typing = false }
            } else {
                Button {
                    typing = true
                    draft = ""
                    focused = true
                } label: {
                    Label("Other…", systemImage: "plus")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Capsule().strokeBorder(Color.primary.opacity(0.2), lineWidth: 1))
                        .foregroundStyle(.secondary)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func commit() {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { place = t }
        typing = false
    }
}

struct PlaceChip: View {
    let place: String

    var body: some View {
        Label(place, systemImage: Places.icon(place))
            .font(.system(size: 10.5, weight: .medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(Heat.base.opacity(0.18)))
            .foregroundStyle(Heat.base)
    }
}

/// Dashboard card: where you focus best over the last 30 days.
struct PlacesCard: View {
    @ObservedObject var store: SessionStore

    private struct Row: Identifiable {
        let place: String
        let hours: Double
        let intensity: Double
        let driftsPerHour: Double?
        var id: String { place }
    }

    var body: some View {
        let since = Calendar.current.date(byAdding: .day, value: -30, to: Date())!
        let groups = Dictionary(grouping: store.sessions.filter { $0.start >= since && $0.location != nil }) { $0.location! }
        let rows = groups.map { place, list -> Row in
            let mins = list.reduce(0) { $0 + $1.minutes }
            let tracked = list.filter { $0.pauses != nil }
            let trackedHours = tracked.reduce(0) { $0 + $1.duration } / 3600
            return Row(place: place, hours: mins / 60,
                       intensity: mins > 0 ? list.reduce(0) { $0 + $1.minutes * Double($1.intensity) } / mins : 0,
                       driftsPerHour: trackedHours > 0.25 ? Double(tracked.reduce(0) { $0 + $1.drifts }) / trackedHours : nil)
        }
        .sorted { $0.hours > $1.hours }
        let maxHours = rows.first?.hours ?? 1

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Where you focus · 30 days").font(.headline)
                Spacer()
                Text("hours · avg intensity · drifts/h").font(.caption).foregroundStyle(.secondary)
            }
            if rows.isEmpty {
                Text("Tag a place when you finish a block (Library, House, Coworking, Coffee…) to see where you focus best.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(rows) { r in
                HStack(spacing: 12) {
                    Label(r.place, systemImage: Places.icon(r.place))
                        .frame(width: 130, alignment: .leading)
                        .lineLimit(1)
                    GeometryReader { g in
                        Capsule().fill(Heat.base.opacity(0.8))
                            .frame(width: max(4, g.size.width * r.hours / max(0.01, maxHours)))
                    }
                    .frame(height: 8)
                    Text(Fmt.hm(r.hours * 3600)).monospacedDigit().frame(width: 64, alignment: .trailing)
                    Text(String(format: "%.1f", r.intensity))
                        .monospacedDigit()
                        .foregroundStyle(Intensity.color(Int(r.intensity.rounded())))
                        .frame(width: 34, alignment: .trailing)
                    Text(r.driftsPerHour.map { String(format: "%.1f", $0) } ?? "–")
                        .monospacedDigit()
                        .foregroundStyle(.orange)
                        .frame(width: 34, alignment: .trailing)
                }
                .font(.system(size: 12.5, weight: .medium))
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
    }
}
