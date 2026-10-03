import AppKit
import SwiftUI

struct ClipboardPage: View {
    @ObservedObject var clips: ClipboardStore
    @ObservedObject var vision: VisionStore
    @ObservedObject var state: NotchState
    @State private var query = ""
    @State private var showAll = false
    @FocusState private var searchFocused: Bool

    /// How many recent items show at a glance before "Show all".
    private let glance = 10

    var body: some View {
        let searching = !query.trimmingCharacters(in: .whitespaces).isEmpty
        let pinned = searching ? [] : clips.pinnedItems
        let list: [ClipItem] = searching ? clips.search(query)
            : showAll ? clips.unpinnedItems : Array(clips.unpinnedItems.prefix(glance))

        VStack(spacing: 10) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search clipboard", text: $query)
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                        .onSubmit { if let first = (searching ? list : pinned + list).first { copy(first) } }
                    if searching {
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
                    Label("Paused", systemImage: "pause.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.orange)
                        .help("Clipboard history is paused (menu bar → Pause Clipboard History)")
                }
            }

            if clips.items.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "doc.on.clipboard").font(.system(size: 24))
                    Text("Copy anything, or drag files and images onto the notch.")
                    Text("Password managers are skipped automatically.").foregroundStyle(.tertiary)
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        if !pinned.isEmpty {
                            header("Pinned")
                            ForEach(pinned) { row($0) }
                        }
                        header(searching ? "\(list.count) result\(list.count == 1 ? "" : "s")"
                               : showAll ? "History · \(clips.unpinnedItems.count)" : "Recent")
                        ForEach(list) { row($0) }

                        if !searching, clips.unpinnedItems.count > glance {
                            Button(showAll ? "Show only recent" : "Show all \(clips.unpinnedItems.count) items") {
                                showAll.toggle()
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(Heat.base)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
                .scrollIndicators(.never)
            }
        }
        .onAppear { if state.focusToken > 0 { searchFocused = true } }
        .onChange(of: state.focusToken) { _, _ in searchFocused = true }
    }

    private func header(_ s: String) -> some View {
        Text(s.uppercased())
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.secondary)
            .padding(.top, 4)
            .padding(.leading, 2)
    }

    private func row(_ item: ClipItem) -> some View {
        ClipRow(item: item, clips: clips, large: state.large,
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

    private func visionContent(_ item: ClipItem) -> ClipContent? {
        switch item.kind {
        case .text: return item.text.map { .text($0) }
        case .image: return clips.imageURL(for: item).flatMap(NSImage.init(contentsOf:)).map { .image($0) }
        case .file: return .files(item.fileURLs)
        }
    }
}

struct ClipRow: View {
    let item: ClipItem
    @ObservedObject var clips: ClipboardStore
    let large: Bool
    let onCopy: () -> Void
    let onVision: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            thumbnail
                .frame(width: large ? 44 : 34, height: large ? 44 : 34)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 2) {
                Text(item.preview)
                    .font(.system(size: 12.5, design: item.kind == .text && !item.isLink ? .default : .default))
                    .foregroundStyle(item.isLink ? Color(red: 0.5, green: 0.75, blue: 1) : .white)
                    .lineLimit(large ? 3 : 2)
                Text([Self.ago(item.date), item.sourceApp].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)

            iconButton(item.pinned ? "pin.fill" : "pin", tint: item.pinned ? .orange : .secondary,
                       help: item.pinned ? "Unpin" : "Pin") { clips.togglePin(item.id) }
                .opacity(item.pinned || hovering ? 1 : 0.35)
            iconButton("trash", tint: .secondary, help: "Delete") { clips.delete(item.id) }
                .opacity(hovering ? 1 : 0.35)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(hovering ? 0.10 : 0.04)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onCopy)
        .onDrag { clips.itemProvider(for: item) }
        .help("Click to copy · drag to drop it anywhere")
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

    @ViewBuilder
    private var thumbnail: some View {
        switch item.kind {
        case .image:
            if let url = clips.imageURL(for: item), let img = Thumbnails.image(at: url, maxPixels: 120) {
                Image(nsImage: img).resizable().scaledToFill()
            } else {
                symbol("photo")
            }
        case .file:
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.paths?.first ?? "/"))
                .resizable()
                .scaledToFit()
        case .text:
            symbol(item.isLink ? "link" : "text.alignleft")
        }
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.white.opacity(0.07))
    }

    private func iconButton(_ icon: String, tint: Color, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
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
