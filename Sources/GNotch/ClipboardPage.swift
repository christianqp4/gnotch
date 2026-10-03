import AppKit
import SwiftUI

struct ClipboardPage: View {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", text = "Text", images = "Images", files = "Files", screenshots = "Screenshots"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .all: return "square.grid.2x2"
            case .text: return "text.alignleft"
            case .images: return "photo"
            case .files: return "doc"
            case .screenshots: return "camera.viewfinder"
            }
        }
    }

    @ObservedObject var clips: ClipboardStore
    @ObservedObject var vision: VisionStore
    @ObservedObject var shots: ScreenshotLibrary
    @ObservedObject var state: NotchState
    @AppStorage("clipboardFilter") private var filterRaw = Filter.all.rawValue
    @State private var query = ""
    @State private var showAll = false
    @State private var shotLimit = 30
    @FocusState private var searchFocused: Bool

    /// How many recent items show at a glance before "Show all".
    private let glance = 10

    private var filter: Filter { Filter(rawValue: filterRaw) ?? .all }
    private var columns: Int { state.large ? 4 : 3 }
    private var rowHeight: CGFloat { state.large ? 88 : 72 }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(filter == .screenshots ? "Search screenshots" : "Search clipboard", text: $query)
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                        .onSubmit(copyFirst)
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 13))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.08)))

                if clips.paused {
                    Image(systemName: "pause.circle.fill")
                        .foregroundStyle(.orange)
                        .help("Clipboard history is paused (menu bar → Pause Clipboard History)")
                }
            }

            HStack(spacing: 4) {
                ForEach(Filter.allCases) { f in
                    Button {
                        filterRaw = f.rawValue
                        showAll = false
                        if f == .screenshots { shots.refresh() }
                    } label: {
                        Label(f.rawValue, systemImage: f.icon)
                            .labelStyle(.titleAndIcon)
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color.white.opacity(filter == f ? 0.18 : 0.05)))
                            .foregroundStyle(filter == f ? Color.white : Color.secondary)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }

            GeometryReader { geo in
                ScrollView {
                    if filter == .screenshots {
                        screenshotsGrid(width: geo.size.width)
                    } else {
                        clipsGrid(width: geo.size.width)
                    }
                }
                .scrollIndicators(.never)
            }
        }
        .onAppear { if state.focusToken > 0 { searchFocused = true } }
        .onChange(of: state.focusToken) { _, _ in searchFocused = true }
    }

    // MARK: Clips

    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    private func matches(_ item: ClipItem) -> Bool {
        switch filter {
        case .all, .screenshots: return true
        case .text: return item.kind == .text
        case .images: return item.kind == .image
        case .files: return item.kind == .file
        }
    }

    private var pinned: [ClipItem] { searching ? [] : clips.pinnedItems.filter(matches) }
    private var results: [ClipItem] {
        let base = searching ? clips.search(query) : clips.unpinnedItems
        return base.filter(matches)
    }

    @ViewBuilder
    private func clipsGrid(width: CGFloat) -> some View {
        let all = results
        let list = searching || showAll ? all : Array(all.prefix(glance))
        if clips.items.isEmpty {
            emptyState("doc.on.clipboard", "Copy anything, or drag files and images onto the notch.",
                       "Password managers are skipped automatically.")
        } else {
            LazyVStack(alignment: .leading, spacing: 6) {
                if !pinned.isEmpty {
                    header("Pinned")
                    PackedGrid(items: pinned, columns: columns, width: width, rowHeight: rowHeight,
                               span: span(for:)) { tile($0) }
                }
                header(searching ? "\(all.count) result\(all.count == 1 ? "" : "s")"
                       : showAll ? "History · \(all.count)" : "Recent")
                PackedGrid(items: list, columns: columns, width: width, rowHeight: rowHeight,
                           span: span(for:)) { tile($0) }
                if !searching, all.count > glance {
                    Button(showAll ? "Show only recent" : "Show all \(all.count)") { showAll.toggle() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Heat.base)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    /// Short text takes one column, long text and wide images take more.
    private func span(for item: ClipItem) -> Int {
        switch item.kind {
        case .text:
            let n = item.preview.count
            if state.large { return n <= 34 ? 1 : n <= 110 ? 2 : n <= 200 ? 3 : 4 }
            return n <= 28 ? 1 : n <= 90 ? 2 : 3
        case .image:
            let a = Double(item.imageWidth ?? 1) / Double(max(1, item.imageHeight ?? 1))
            return a > 2.4 ? 3 : a > 1.3 ? 2 : 1
        case .file:
            return (item.paths?.count ?? 0) > 1 || item.preview.count > 22 ? 2 : 1
        }
    }

    private func tile(_ item: ClipItem) -> some View {
        ClipTile(item: item, clips: clips, large: state.large,
                 onCopy: { copy(item) },
                 onVision: {
                     if let c = visionContent(item) {
                         _ = vision.add([c])
                         state.flash("Added to vision board")
                     }
                 })
    }

    private func copy(_ item: ClipItem) {
        clips.copy(item)
        state.flash("Copied")
        state.pinned = false
    }

    private func copyFirst() {
        if filter == .screenshots {
            if let s = filteredShots.first { copyShot(s) }
        } else if let first = (pinned + results).first {
            copy(first)
        }
    }

    private func visionContent(_ item: ClipItem) -> ClipContent? {
        switch item.kind {
        case .text: return item.text.map { .text($0) }
        case .image: return clips.imageURL(for: item).flatMap(NSImage.init(contentsOf:)).map { .image($0) }
        case .file: return .files(item.fileURLs)
        }
    }

    // MARK: Screenshots

    private var filteredShots: [ScreenshotLibrary.Shot] {
        guard searching else { return shots.shots }
        let q = query.lowercased()
        return shots.shots.filter { $0.url.lastPathComponent.lowercased().contains(q) }
    }

    @ViewBuilder
    private func screenshotsGrid(width: CGFloat) -> some View {
        let all = filteredShots
        let list = Array(all.prefix(shotLimit))
        if list.isEmpty {
            emptyState("camera.viewfinder", "No screenshots in \(shots.folder.lastPathComponent) yet.",
                       "Take one with ⇧⌘4: it lands on your clipboard, ready for ⌘V.")
        } else {
            LazyVStack(alignment: .leading, spacing: 6) {
                HStack {
                    header("\(all.count) in \(shots.folder.lastPathComponent)")
                    Spacer()
                    Button("Open folder") { NSWorkspace.shared.open(shots.folder) }
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
                PackedGrid(items: list, columns: columns, width: width, rowHeight: rowHeight * 1.3,
                           span: { s in s.aspect > 2.2 ? 3 : s.aspect > 1.15 ? 2 : 1 }) { s in
                    ShotTile(shot: s, large: state.large,
                             onCopy: { copyShot(s) },
                             onVision: {
                                 vision.add([.files([s.url])])
                                 state.flash("Added to vision board")
                             })
                }
                if all.count > list.count {
                    Button("Show more (\(all.count - list.count) older)") { shotLimit += 30 }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Heat.base)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func copyShot(_ s: ScreenshotLibrary.Shot) {
        clips.addScreenshot(s.url, copy: true)
        state.flash("Copied · ⌘V to paste")
        state.pinned = false
    }

    // MARK: Bits

    private func header(_ s: String) -> some View {
        Text(s.uppercased())
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.secondary)
            .padding(.top, 4)
            .padding(.leading, 2)
    }

    private func emptyState(_ icon: String, _ line1: String, _ line2: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 24))
            Text(line1)
            Text(line2).foregroundStyle(.tertiary)
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.top, 50)
    }
}

/// Packs items into full rows, in order. Each item asks for `span` of `columns` units;
/// when it doesn't fit, it shrinks into what's left of the row, so there are no holes.
struct PackedGrid<Item: Identifiable, Tile: View>: View {
    let items: [Item]
    let columns: Int
    let width: CGFloat
    let rowHeight: CGFloat
    var gap: CGFloat = 6
    let span: (Item) -> Int
    @ViewBuilder let tile: (Item) -> Tile

    private struct Cell: Identifiable {
        let item: Item
        let span: Int
        var id: Item.ID { item.id }
    }

    var body: some View {
        let rows = pack()
        VStack(spacing: gap) {
            ForEach(rows.indices, id: \.self) { r in
                let row = rows[r]
                let units = max(1, row.reduce(0) { $0 + $1.span })
                let unit = (width - gap * CGFloat(row.count - 1)) / CGFloat(units)
                HStack(spacing: gap) {
                    ForEach(row) { cell in
                        tile(cell.item)
                            .frame(width: unit * CGFloat(cell.span), height: rowHeight)
                            .clipped()
                    }
                }
            }
        }
    }

    private func pack() -> [[Cell]] {
        var rows: [[Cell]] = []
        var row: [Cell] = []
        var left = columns
        for item in items {
            let s = max(1, min(columns, span(item)))
            let take = row.isEmpty ? s : min(s, left)
            row.append(Cell(item: item, span: take))
            left -= take
            if left == 0 {
                rows.append(row)
                row = []
                left = columns
            }
        }
        if !row.isEmpty { rows.append(row) }
        return rows
    }
}

struct ClipTile: View {
    let item: ClipItem
    @ObservedObject var clips: ClipboardStore
    let large: Bool
    let onCopy: () -> Void
    let onVision: () -> Void
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            content
            HStack(spacing: 0) {
                tileButton(item.pinned ? "pin.fill" : "pin", tint: item.pinned ? .orange : .white,
                           help: item.pinned ? "Unpin" : "Pin") { clips.togglePin(item.id) }
                    .opacity(item.pinned || hovering ? 1 : 0)
                tileButton("trash", tint: .white, help: "Delete") { clips.delete(item.id) }
                    .opacity(hovering ? 1 : 0)
            }
            .padding(3)
        }
        .background(Color.white.opacity(hovering ? 0.11 : 0.05))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onHover { hovering = $0 }
        .onTapGesture(perform: onCopy)
        .onDrag { clips.itemProvider(for: item) }
        .help("Click to copy · drag to drop it anywhere · right-click for more")
        .contextMenu {
            Button("Copy", action: onCopy)
            Button(item.pinned ? "Unpin" : "Pin") { clips.togglePin(item.id) }
            if item.kind != .file || item.fileURLs.contains(where: VisionStore.isImageFile) {
                Button("Add to Vision Board", action: onVision)
            }
            if item.kind == .file {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(item.fileURLs) }
            }
            if item.isLink, let t = item.text, let url = URL(string: t.trimmingCharacters(in: .whitespacesAndNewlines)) {
                Button("Open Link") { NSWorkspace.shared.open(url) }
            }
            Divider()
            Button("Delete", role: .destructive) { clips.delete(item.id) }
        }
    }

    private var meta: String {
        [ClipTile.ago(item.date), item.sourceApp].compactMap { $0 }.joined(separator: " · ")
    }

    @ViewBuilder
    private var content: some View {
        switch item.kind {
        case .image:
            ZStack(alignment: .bottomLeading) {
                if let url = clips.imageURL(for: item), let img = Thumbnails.image(at: url, maxPixels: 500) {
                    Color.clear.overlay { Image(nsImage: img).resizable().scaledToFill() }.clipped()
                } else {
                    Color.white.opacity(0.06)
                }
                LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
                metaText.padding(8)
            }
        case .file:
            HStack(spacing: 8) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: item.paths?.first ?? "/"))
                    .resizable()
                    .scaledToFit()
                    .frame(width: large ? 38 : 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.preview).font(.system(size: 12, weight: .medium)).lineLimit(2)
                    metaText
                }
                Spacer(minLength: 0)
            }
            .padding(9)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .text:
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .top, spacing: 5) {
                    if item.isLink { Image(systemName: "link").font(.system(size: 10, weight: .bold)) }
                    Text(item.preview)
                        .font(.system(size: 12))
                        .lineLimit(large ? 4 : 3)
                }
                .foregroundStyle(item.isLink ? Color(red: 0.5, green: 0.75, blue: 1) : .white)
                Spacer(minLength: 0)
                metaText
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(9)
        }
    }

    private var metaText: some View {
        Text(meta).font(.system(size: 9.5)).foregroundStyle(.secondary).lineLimit(1)
    }

    private func tileButton(_ icon: String, tint: Color, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.black.opacity(0.55)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    static func ago(_ date: Date) -> String {
        let s = Int(-date.timeIntervalSinceNow)
        if s < 60 { return "now" }
        if s < 3600 { return "\(s / 60)m ago" }
        if s < 86400 { return "\(s / 3600)h ago" }
        return "\(s / 86400)d ago"
    }
}

struct ShotTile: View {
    let shot: ScreenshotLibrary.Shot
    let large: Bool
    let onCopy: () -> Void
    let onVision: () -> Void
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let img = Thumbnails.image(at: shot.url, maxPixels: 600) {
                Color.clear.overlay { Image(nsImage: img).resizable().scaledToFill() }.clipped()
            } else {
                Color.white.opacity(0.06)
            }
            LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom)
            Text(ClipTile.ago(shot.date))
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
                .padding(8)
        }
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(hovering ? 0.5 : 0), lineWidth: 1.5))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onHover { hovering = $0 }
        .onTapGesture(perform: onCopy)
        .onDrag { NSItemProvider(contentsOf: shot.url) ?? NSItemProvider() }
        .help("\(shot.url.lastPathComponent)\nClick to copy · drag to drop it anywhere")
        .contextMenu {
            Button("Copy", action: onCopy)
            Button("Open") { NSWorkspace.shared.open(shot.url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([shot.url]) }
            Button("Add to Vision Board", action: onVision)
        }
    }
}
