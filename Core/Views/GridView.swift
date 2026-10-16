//
//  GridView.swift
//  Alter
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//

import SwiftUI

/// Injected by GridView so cells' context menus can trigger the naming alert.
private struct NewAlbumActionKey: EnvironmentKey {
    static let defaultValue: ([Int64]) -> Void = { _ in }
}

extension EnvironmentValues {
    var newAlbumFromSelection: ([Int64]) -> Void {
        get { self[NewAlbumActionKey.self] }
        set { self[NewAlbumActionKey.self] = newValue }
    }
}

/// Cell frames reported up for marquee hit-testing.
private struct CellFramesKey: PreferenceKey {
    static var defaultValue: [Int64: CGRect] = [:]
    static func reduce(value: inout [Int64: CGRect], nextValue: () -> [Int64: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

struct GridView: View {
    @EnvironmentObject var store: LibraryStore
    @AppStorage("alter_thumb_size") private var thumbSize = 165.0

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: thumbSize, maximum: thumbSize * 1.45), spacing: 12)]
    }

    // Marquee (rubber-band) selection state.
    @State private var cellFrames: [Int64: CGRect] = [:]
    @State private var marqueeRect: CGRect?
    @State private var marqueeBase: Set<Int64> = []

    // Grid-level album creation.
    @State private var isNamingAlbum = false
    @State private var newAlbumName = ""
    @State private var albumSeedIDs: [Int64] = []

    // Browser-bar search (⌘F lands here via store.searchFocusRequest).
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            browserBar
            Divider()
            if store.items.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        ZStack(alignment: .topLeading) {
                            // The marquee catcher sits BEHIND the grid and is
                            // invisible to VoiceOver. It used to be a
                            // contentShape+gesture on the ZStack itself, which
                            // collapsed the whole grid into ONE accessibility
                            // element — every cell was labelled correctly and
                            // none of them could be reached. Keep the drag
                            // surface a sibling, never a wrapper.
                            Color.clear
                                .contentShape(Rectangle())
                                .gesture(marqueeGesture)
                                .accessibilityHidden(true)

                            LazyVGrid(columns: columns, spacing: 12) {
                                ForEach(store.items) { item in
                                    PhotoCell(item: item, isSelected: store.selection.contains(item.id))
                                        .id(item.id)
                                        .background(GeometryReader { geo in
                                            Color.clear.preference(
                                                key: CellFramesKey.self,
                                                value: [item.id: geo.frame(in: .named("grid"))])
                                        }
                                        // Measurement scaffolding, not content —
                                        // it must not sit between VoiceOver and
                                        // the photo it is measuring.
                                        .accessibilityHidden(true))
                                        .draggable(dragPayload(for: item))
                                        .onTapGesture(count: 2) { store.enterViewer(item.id) }
                                        .onTapGesture { store.handleTap(item.id) }
                                        // VO-Space selects; the rotor action
                                        // opens it full size. Reading a photo
                                        // out is only half the job — you have
                                        // to be able to act on it too.
                                        .accessibilityAction { store.handleTap(item.id) }
                                        .accessibilityAction(named: "Open full size") {
                                            store.enterViewer(item.id)
                                        }
                                }
                            }
                            .padding(12)

                            if let rect = marqueeRect {
                                Rectangle()
                                    .fill(Color.accentColor.opacity(0.15))
                                    .overlay(Rectangle().strokeBorder(Color.accentColor.opacity(0.6)))
                                    .frame(width: rect.width, height: rect.height)
                                    .offset(x: rect.minX, y: rect.minY)
                                    .allowsHitTesting(false)
                            }
                        }
                        .coordinateSpace(name: "grid")
                        // Explicitly a container: VoiceOver walks into the
                        // cells rather than treating the grid as one blob.
                        .accessibilityElement(children: .contain)
                        .onPreferenceChange(CellFramesKey.self) { cellFrames = $0 }
                    }
                    .onChange(of: store.revealID) { id in
                        guard let id else { return }
                        withAnimation { proxy.scrollTo(id, anchor: .center) }
                        store.revealID = nil
                    }
                    // The grid is rebuilt each time you come back from the
                    // viewer, which used to drop you at the top of the
                    // library. Land on the photo you were looking at instead
                    // (as Aperture did) — including one you stepped to in the
                    // viewer. A tick later, once the lazy grid has laid out.
                    .onAppear {
                        guard let id = store.viewerPhotoID ?? store.selection.first else { return }
                        DispatchQueue.main.async { proxy.scrollTo(id, anchor: .center) }
                    }
                }
                .background(Color(nsColor: .underPageBackgroundColor))
                .alert("New Album", isPresented: $isNamingAlbum) {
                    TextField("Album name", text: $newAlbumName)
                    Button("Create") {
                        store.createAlbum(
                            named: newAlbumName.trimmingCharacters(in: .whitespaces),
                            with: albumSeedIDs)
                        newAlbumName = ""
                    }
                    Button("Cancel", role: .cancel) { newAlbumName = "" }
                } message: {
                    Text("Creates an album containing the \(albumSeedIDs.count) selected photo\(albumSeedIDs.count == 1 ? "" : "s").")
                }
            }
        }
        .environment(\.newAlbumFromSelection) { ids in
            albumSeedIDs = ids
            newAlbumName = ""
            isNamingAlbum = true
        }
        .alert("Move to Trash?", isPresented: Binding(
            get: { !store.pendingTrashIDs.isEmpty },
            set: { if !$0 { store.pendingTrashIDs = [] } }
        )) {
            Button("Move to Trash", role: .destructive) {
                store.trashFiles(store.pendingTrashIDs)
                store.pendingTrashIDs = []
            }
            Button("Cancel", role: .cancel) { store.pendingTrashIDs = [] }
        } message: {
            Text("Deletes \(store.pendingTrashIDs.count) file\(store.pendingTrashIDs.count == 1 ? "" : "s") from disk — recoverable from the Trash. \"Remove from Library\" keeps the file if you only want it out of Alter.")
        }
    }

    /// Sort + filter + thumbnail size — the Aperture browser bar.
    private var browserBar: some View {
        HStack(spacing: 14) {
            Menu {
                Picker("Sort", selection: $store.sortKey) {
                    ForEach(LibraryStore.SortKey.allCases) { key in
                        Text(key.label).tag(key)
                    }
                }
                .pickerStyle(.inline)
                Divider()
                Picker("Direction", selection: $store.sortAscending) {
                    Text("Ascending").tag(true)
                    Text("Descending").tag(false)
                }
                .pickerStyle(.inline)
            } label: {
                Label("Sort: \(store.sortKey.label) \(store.sortAscending ? "↑" : "↓")",
                      systemImage: "arrow.up.arrow.down")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Menu {
                Picker("Show", selection: $store.gridFilter) {
                    ForEach(LibraryStore.GridFilter.allCases.filter { $0 != .starred }) { filter in
                        Label(filter.label, systemImage: filter.systemImage).tag(filter)
                    }
                }
                .pickerStyle(.inline)
                Menu("Starred") {
                    ForEach(1...5, id: \.self) { stars in
                        Button {
                            store.starThreshold = stars
                            store.gridFilter = .starred
                        } label: {
                            HStack {
                                Text(String(repeating: "★", count: stars) + (stars < 5 ? " +" : ""))
                                if store.gridFilter == .starred && store.starThreshold == stars {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
            } label: {
                Label(filterLabel, systemImage: store.gridFilter.systemImage)
                    .foregroundColor(store.gridFilter == .all ? .primary : .accentColor)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Menu {
                Button {
                    store.labelFilter = nil
                } label: {
                    if store.labelFilter == nil { Label("Any Label", systemImage: "checkmark") }
                    else { Text("Any Label") }
                }
                Divider()
                ForEach(PhotoLabel.colors) { label in
                    Button {
                        store.labelFilter = label.rawValue
                    } label: {
                        if store.labelFilter == label.rawValue {
                            Label(label.name, systemImage: "checkmark")
                        } else {
                            Label(label.name, systemImage: "circle.fill")
                        }
                    }
                    .tint(label.color)
                }
            } label: {
                if let raw = store.labelFilter, let label = PhotoLabel(rawValue: raw) {
                    Label(label.name, systemImage: "circle.fill")
                        .foregroundColor(label.color)
                } else {
                    Label("Label", systemImage: "circle.dashed")
                }
            }
            .fixedSize()
            .help("Show only photos with this colour label")
            if store.gridFilter != .all {
                Button {
                    store.gridFilter = .all
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear filter")
            }

            Spacer()

            // Search: filename, title, caption, keywords, ALT text, creator.
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                TextField("Search", text: $store.searchText)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .frame(width: 150)
                    .accessibilityLabel("Search library")
                    .accessibilityHint("Matches filename, title, caption, keywords, ALT text, and creator")
                if !store.searchText.isEmpty {
                    Button {
                        store.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(searchFocused || !store.searchText.isEmpty ? 0.08 : 0.05))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(searchFocused ? Color.accentColor.opacity(0.6) : .clear, lineWidth: 1)
            )
            .onChange(of: store.searchFocusRequest) { _ in searchFocused = true }
            // Esc in the field: clear first, then surrender focus. Two taps
            // gets you back to grid keyboard navigation.
            .onExitCommand {
                if store.searchText.isEmpty { searchFocused = false } else { store.searchText = "" }
            }

            Image(systemName: "photo")
                .font(.system(size: 9))
                .foregroundColor(.secondary)
            Slider(value: $thumbSize, in: 110...260)
                .frame(width: 110)
                .help("Thumbnail size")
            Image(systemName: "photo")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var filterLabel: String {
        switch store.gridFilter {
        case .all: return "Show: All"
        case .starred: return "Show: ★\(store.starThreshold)\(store.starThreshold < 5 ? "+" : "")"
        default: return "Show: \(store.gridFilter.label)"
        }
    }

    /// Dragging a selected photo drags the whole selection (as "id,id,id").
    private func dragPayload(for item: PhotoItem) -> String {
        if store.selection.contains(item.id) {
            return store.selection.map(String.init).joined(separator: ",")
        }
        return String(item.id)
    }

    /// Rubber-band select: drag on empty grid space. ⌘/⇧ adds to the selection.
    private var marqueeGesture: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named("grid"))
            .onChanged { value in
                if marqueeRect == nil {
                    let flags = NSApp.currentEvent?.modifierFlags ?? []
                    marqueeBase = (flags.contains(.command) || flags.contains(.shift))
                        ? store.selection : []
                }
                let rect = CGRect(
                    x: min(value.startLocation.x, value.location.x),
                    y: min(value.startLocation.y, value.location.y),
                    width: abs(value.location.x - value.startLocation.x),
                    height: abs(value.location.y - value.startLocation.y))
                marqueeRect = rect
                let hits = cellFrames.filter { $0.value.intersects(rect) }.map(\.key)
                store.selection = marqueeBase.union(hits)
            }
            .onEnded { _ in
                marqueeRect = nil
                marqueeBase = []
            }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            if !store.searchText.isEmpty {
                // A search with no hits is its own situation — the fix is
                // clearing the search, not importing more photos.
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 44))
                    .foregroundColor(.secondary)
                Text("No matches for “\(store.searchText)”")
                    .font(.title3.weight(.semibold))
                Text("Searched filename, title, caption, keywords, ALT text, and creator.")
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
                Button("Clear Search") { store.searchText = "" }
                    .padding(.top, 6)
            } else {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 44))
                    .foregroundColor(.secondary)
                Text(store.allCount == 0 ? "Import photos or videos to get started" : "Nothing here yet")
                    .font(.title3.weight(.semibold))
                Text(store.allCount == 0
                     ? "Drop folders anywhere, or press ⌘I.\nPhotos are referenced in place — never moved or copied."
                     : "This view has no photos. Try All Photos, or drop more in.")
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
                if store.allCount == 0 {
                    HStack(spacing: 10) {
                        Button("Import Folder…") { store.presentImportPanel() }
                        Button("Import from Photos…") { store.importFromPhotos() }
                    }
                    .padding(.top, 6)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}

struct PhotoCell: View {
    @EnvironmentObject var store: LibraryStore
    @Environment(\.newAlbumFromSelection) private var newAlbumFromSelection
    @AppStorage("alter_thumb_size") private var thumbSize = 165.0
    let item: PhotoItem
    let isSelected: Bool

    @State private var thumbnail: NSImage?
    @State private var isMissing = false
    /// The decode ran and produced nothing, but the file is there — a format
    /// problem, not a location problem.
    @State private var isUnreadable = false

    private var imageHeight: CGFloat { thumbSize * 0.8 }

    private var accessibilityLabel: String {
        (item.isVideo ? "Video, " : "Photo, ") + item.filename
    }

    private var accessibilityValue: String {
        var parts = [item.metadata.altText.isEmpty ? "No ALT text yet" : "Has ALT text"]
        if item.rating > 0 { parts.append("\(item.rating) star\(item.rating == 1 ? "" : "s")") }
        if item.rating < 0 { parts.append("rejected") }
        if item.flagged { parts.append("Flagged") }
        if item.label > 0 { parts.append("\(item.photoLabel.name) label") }
        if item.isVersion { parts.append("Version: \(item.versionName)") }
        else if let n = store.versionCounts[item.id] { parts.append("\(n) version\(n == 1 ? "" : "s")") }
        if let stackID = item.stackID, let info = store.stackInfo[stackID], info.count > 1 {
            parts.append(info.collapsed ? "Stack of \(info.count), collapsed" : "In a stack of \(info.count)")
        }
        if !item.edits.isNeutral { parts.append("Adjusted") }
        if item.dirty { parts.append("Unsaved edits") }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .quaternaryLabelColor))
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                        .frame(minWidth: 0, maxWidth: .infinity)
                        .frame(height: imageHeight)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else if isMissing {
                    VStack(spacing: 4) {
                        Image(systemName: "questionmark.folder")
                            .font(.system(size: 26))
                        Text("Original missing")
                            .font(.caption2)
                    }
                    .foregroundColor(.secondary)
                    .help("The file isn't at \(item.url.path). If you moved or renamed its folder, right-click it in the sidebar → Locate / Relink Folder…")
                } else if isUnreadable {
                    VStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 26))
                        Text("Couldn't read")
                            .font(.caption2)
                    }
                    .foregroundColor(.secondary)
                    .help("The file exists but didn't decode as an image.")
                } else {
                    // Decode in flight — big originals (RAW) take a beat.
                    ProgressView()
                        .controlSize(.small)
                }
                statusOverlay
            }
            .frame(height: imageHeight)

            HStack(spacing: 4) {
                if item.label > 0 {
                    Circle().fill(item.photoLabel.color).frame(width: 7, height: 7)
                        .help("\(item.photoLabel.name) label")
                }
                if item.dirty {
                    Circle().fill(Color.orange).frame(width: 6, height: 6)
                        .help("Edits pending write to file")
                }
                if item.isVideo {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .help("Video")
                }
                Text(item.filename)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if item.isVersion {
                    Text(item.versionName.isEmpty ? "v" : item.versionName)
                        .font(.system(size: 8, weight: .semibold))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Color.teal.opacity(0.2))
                        .foregroundColor(.teal)
                        .cornerRadius(3)
                        .help("A version — same file, its own recipe")
                } else if let n = store.versionCounts[item.id], n > 0 {
                    Button {
                        store.toggleVersions(of: item.id)
                    } label: {
                        Label("\(n)", systemImage: "square.on.square")
                            .labelStyle(.titleAndIcon)
                            .font(.system(size: 8, weight: .semibold))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Color.teal.opacity(0.2))
                            .foregroundColor(.teal)
                            .cornerRadius(3)
                    }
                    .buttonStyle(.plain)
                    .help(store.expandedVersionMasters.contains(item.id)
                          ? "Hide its \(n) version\(n == 1 ? "" : "s")"
                          : "Show its \(n) version\(n == 1 ? "" : "s")")
                    .accessibilityLabel("Show versions")
                }
                if let stackID = item.stackID, let info = store.stackInfo[stackID], info.count > 1 {
                    Button {
                        store.toggleStack(stackID)
                    } label: {
                        Label("\(info.count)", systemImage: info.collapsed ? "square.stack.3d.up.fill" : "square.stack.3d.up")
                            .labelStyle(.titleAndIcon)
                            .font(.system(size: 8, weight: .semibold))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Color.indigo.opacity(0.2))
                            .foregroundColor(.indigo)
                            .cornerRadius(3)
                    }
                    .buttonStyle(.plain)
                    .help(info.collapsed ? "Stack of \(info.count) — click to open" : "Stack of \(info.count) — click to close")
                    .accessibilityLabel(info.collapsed ? "Open stack" : "Close stack")
                }
                if !item.edits.isNeutral {
                    Image(systemName: "dial.medium.fill")
                        .font(.system(size: 9))
                        .foregroundColor(.accentColor)
                        .help("Has adjustments")
                }
                if !item.memeJSON.isEmpty {
                    Image(systemName: "text.below.photo.fill")
                        .font(.system(size: 9))
                        .foregroundColor(.purple)
                        .help("Has a meme composition — Meme Maker reopens it")
                }
                if !item.metadata.altText.isEmpty {
                    Text("ALT")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.green.opacity(0.2))
                        .foregroundColor(.green)
                        .cornerRadius(3)
                }
            }

            HStack(spacing: 2) {
                if item.rating > 0 {
                    ForEach(0..<item.rating, id: \.self) { _ in
                        Image(systemName: "star.fill")
                            .font(.system(size: 8))
                            .foregroundColor(.yellow)
                    }
                } else if item.rating < 0 {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.red)
                        .help("Rejected")
                }
                Spacer(minLength: 0)
                if item.flagged {
                    Image(systemName: "flag.fill")
                        .font(.system(size: 9))
                        .foregroundColor(.orange)
                }
            }
            .frame(height: 10)
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .contextMenu { PhotoContextMenu(item: item) }
        // One VoiceOver element per photo: name it, then say whether it still
        // needs ALT text so a blind user can navigate straight to untagged
        // shots and generate descriptions voice-only.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
        .accessibilityAddTraits(isSelected ? [.isImage, .isSelected] : .isImage)
        .task(id: item.url.path + "#" + item.edits.cacheKey) {
            let url = item.url
            let edits = item.edits
            if thumbnail == nil {
                // iCloud-evicted originals read as grey squares — pull them down.
                try? await FileLocality.ensureLocal(url)
            }
            thumbnail = await Task.detached(priority: .utility) {
                ImageLoader.shared.thumbnail(for: url, edits: edits)
            }.value
            let exists = FileManager.default.fileExists(atPath: url.path)
            isMissing = thumbnail == nil && !exists
            isUnreadable = thumbnail == nil && exists
        }
    }

    @ViewBuilder
    private var statusOverlay: some View {
        switch item.status {
        case .generating, .saving, .queued:
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.35))
                ProgressView().controlSize(.small)
            }
        case .error:
            VStack {
                HStack {
                    Spacer()
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundColor(.red)
                        .padding(4)
                }
                Spacer()
            }
        default:
            EmptyView()
        }
    }
}

/// The per-photo context menu, shared by the grid and the filmstrip.
struct PhotoContextMenu: View {
    @EnvironmentObject var store: LibraryStore
    @Environment(\.newAlbumFromSelection) private var newAlbumFromSelection
    let item: PhotoItem

    var body: some View {
        let targets = store.contextTargets(item.id)
        let plural = targets.count > 1 ? " (\(targets.count))" : ""

        Button("View Full Size") { store.enterViewer(item.id) }
        Button("Adjust…") { store.openAdjustments(item.id) }
        Button("Auto-Enhance\(plural)") { Task { await store.autoEnhance(ids: targets) } }
        Button("Copy Adjustments") { store.copyEdits(from: item.id) }
            .disabled(item.edits.isNeutral)
        Button("Paste Adjustments\(plural)") { store.pasteEdits(to: targets) }
            .disabled(store.copiedEdits == nil)
        Divider()
        if let items = AlterExtensions.shared.photoContextMenu { items(item, targets, store) }
        Button("Suggest Keywords\(plural)") { Task { await store.suggestKeywords(ids: targets) } }
        Menu("Apply Snippet\(plural)") {
            SnippetMenuItems(targets: targets)
        }
        Button("Save to File\(plural)") { Task { await store.save(ids: targets) } }

        Menu("Rating") {
            ForEach(0...5, id: \.self) { stars in
                Button(stars == 0 ? "None" : String(repeating: "★", count: stars)) {
                    store.setRating(stars, for: targets)
                }
            }
        }
        Button(item.flagged ? "Unflag\(plural)" : "Flag\(plural)") {
            store.setFlagged(!item.flagged, for: targets)
        }
        Menu("Label") {
            ForEach(PhotoLabel.allCases) { label in
                Button {
                    store.setLabel(label.rawValue, for: targets)
                } label: {
                    if item.label == label.rawValue {
                        Label(label.name, systemImage: "checkmark")
                    } else if label == .none {
                        Text(label.name)
                    } else {
                        Label(label.name, systemImage: "circle.fill")
                    }
                }
                .tint(label.color)
            }
        }

        Divider()
        Button("New Version from Original") { store.createVersion(of: item.id, fromOriginal: true) }
            .help("A fresh take on this file, starting from a neutral recipe")
        Button("Duplicate Version") { store.createVersion(of: item.id, fromOriginal: false) }
            .help("A copy of this take, recipe and all, to push in another direction")
        if item.isVersion {
            Button("Delete Version", role: .destructive) { store.deleteVersion(item.id) }
                .help("Removes this take only — the file and the master stay")
        } else if let n = store.versionCounts[item.id], n > 0 {
            Button(store.expandedVersionMasters.contains(item.id) ? "Hide Versions" : "Show Versions (\(n))") {
                store.toggleVersions(of: item.id)
            }
        }

        Divider()
        if targets.count >= 2 {
            Button("Stack \(targets.count) Photos") { store.stackSelection() }
                .help("Group as one stack — the best-rated becomes the pick")
        }
        if let stackID = item.stackID, let info = store.stackInfo[stackID], info.count > 1 {
            if info.pick != item.id {
                Button("Set as Pick") { store.setStackPick(item.id) }
            }
            Button(info.collapsed ? "Open Stack" : "Close Stack") { store.toggleStack(stackID) }
            Button("Unstack") { store.unstack(stackID) }
        }
        Menu("Auto-Stack by Time") {
            ForEach([5, 15, 30, 60], id: \.self) { seconds in
                Button("Within \(seconds) seconds") { store.autoStack(gapSeconds: Double(seconds)) }
            }
        }
        .help("Group bursts and brackets in this view by capture time")

        if !store.projects.isEmpty {
            Menu("Move to Project") {
                ForEach(store.flatProjects, id: \.node.id) { entry in
                    if entry.node.kind == .project {
                        Button(String(repeating: "    ", count: entry.depth) + entry.node.name) {
                            store.moveToProject(entry.node.id, photoIDs: targets)
                        }
                        .disabled(targets.count == 1 && item.projectID == entry.node.id)
                    } else {
                        Text(String(repeating: "    ", count: entry.depth) + entry.node.name)
                    }
                }
                if item.projectID != nil {
                    Divider()
                    Button("Remove from Project") { store.moveToProject(nil, photoIDs: targets) }
                }
            }
        }
        Menu("Add to Album") {
            ForEach(store.albums) { album in
                Button(album.name) { store.addToAlbum(album.id, photoIDs: targets) }
            }
            if !store.albums.isEmpty { Divider() }
            Button("New Album from Selection…") { newAlbumFromSelection(targets) }
        }
        if case .album(let albumID) = store.source ?? .all {
            Button("Remove from Album\(plural)") {
                store.removeFromAlbum(albumID, photoIDs: targets)
            }
        }

        Divider()
        Button("Export…") {
            if !store.selection.contains(item.id) { store.selection = [item.id] }
            store.isExportSheetPresented = true
        }
        if let items = AlterExtensions.shared.photoExportMenu { items(item, targets, store) }
        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([item.url])
        }
        Button("Locate Original…") { store.relinkPhoto(item.id) }
        Divider()
        Button("Remove from Library\(plural)") {
            store.removeFromLibrary(targets)
        }
        .help("Un-indexes only — the file stays on disk")
        Button("Move File to Trash…\(plural)", role: .destructive) {
            store.pendingTrashIDs = targets
        }
        .help("Deletes the actual file (recoverable from the Trash)")
    }
}
