//
//  InspectorView.swift
//  Alter
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
//  Right-hand panel. Single selection gets two tabs — Info (metadata) and
//  Adjust (the edit panel; switching to it opens the full-size viewer).
//  Multi-selection offers batch apply.
//

import SwiftUI

struct InspectorView: View {
    @EnvironmentObject var store: LibraryStore

    var body: some View {
        Group {
            if case .ext(let tabID) = store.inspectorTab,
               let spec = AlterExtensions.shared.inspectorTabs.first(where: { $0.id == tabID }),
               spec.standalone(store) {
                // An extension's tab that works without a selected photo
                // (an editor over its own media) keeps the whole inspector.
                spec.content(store)
            } else if store.selection.count == 1, let id = store.selection.first, let item = store.item(id) {
                SingleInspector(id: id, item: item)
            } else if store.selection.count > 1 {
                BatchInspector()
            } else {
                placeholder
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "sidebar.right")
                .font(.system(size: 30))
                .foregroundColor(.secondary)
            Text("Select a photo to edit its metadata")
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

// MARK: - Tabs

/// Info | Adjust, then any tabs an extension adds.
struct InspectorTabPicker: View {
    @EnvironmentObject var store: LibraryStore

    var body: some View {
        Picker("", selection: $store.inspectorTab) {
            Text("Info").tag(LibraryStore.InspectorTab.info)
            Text("Adjust").tag(LibraryStore.InspectorTab.adjust)
            ForEach(AlterExtensions.shared.inspectorTabs) { spec in
                Text(spec.title).tag(LibraryStore.InspectorTab.ext(spec.id))
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(10)
    }
}

// MARK: - Single photo (tabbed: Info | Adjust | extension tabs)

private struct SingleInspector: View {
    @EnvironmentObject var store: LibraryStore
    let id: Int64
    let item: PhotoItem

    var body: some View {
        VStack(spacing: 0) {
            InspectorTabPicker()

            Divider()

            switch store.inspectorTab {
            case .info:
                InfoPanel(id: id, item: item)
            case .adjust:
                AdjustmentsPanel(id: id, item: item)
            case .ext(let tabID):
                if let spec = AlterExtensions.shared.inspectorTabs.first(where: { $0.id == tabID }) {
                    spec.content(store)
                } else {
                    InfoPanel(id: id, item: item)
                }
            }
        }
    }
}

// MARK: - Info tab (metadata)

private struct InfoPanel: View {
    @EnvironmentObject var store: LibraryStore
    let id: Int64
    let item: PhotoItem

    /// Aperture's metadata views: Basic, IPTC (adds creator/copyright/location), All (adds EXIF).
    enum MetadataView: String, CaseIterable, Identifiable {
        case basic = "Basic", iptc = "IPTC", all = "All"
        var id: String { rawValue }
    }
    @AppStorage("info.metadataView") private var metadataView: MetadataView = .all

    @State private var suggestedTags: [String] = []
    /// ALT text usually mirrors the caption — collapsed until wanted,
    /// and the choice sticks.
    @AppStorage("alter_show_alt_field") private var showAltField = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(item.filename)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 10) {
                    RatingControl(rating: item.rating) { store.setRating($0, for: [id]) }
                    Button {
                        store.setFlagged(!item.flagged, for: [id])
                    } label: {
                        Image(systemName: item.flagged ? "flag.fill" : "flag")
                            .foregroundColor(item.flagged ? .orange : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help(item.flagged ? "Unflag" : "Flag")
                    .accessibilityLabel(item.flagged ? "Unflag photo" : "Flag photo")
                    LabelDots(selected: item.label) { store.setLabel($0, for: [id]) }
                    Spacer()
                    Menu {
                        SnippetMenuItems(targets: [id])
                    } label: {
                        Label("Snippets", systemImage: "text.badge.plus")
                            .labelStyle(.iconOnly)
                    }
                    .menuStyle(.button)
                .buttonStyle(.borderless)
                    .frame(width: 28)
                    .help("Apply a saved snippet to this photo")
                    .accessibilityLabel("Snippets")
                }

                if case .error(let message) = item.status {
                    Text(message)
                        .font(.caption)
                        .foregroundColor(.red)
                }

                Picker("Metadata view", selection: $metadataView) {
                    ForEach(MetadataView.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .help("Which metadata to show: Basic, IPTC, or everything with EXIF")
                field("TITLE") {
                    TextField("Short title…", text: store.metadataBinding(\.title, for: id))
                        .textFieldStyle(.roundedBorder)
                }

                field("CAPTION / DESCRIPTION") {
                    TextEditor(text: store.metadataBinding(\.caption, for: id))
                        .font(.body)
                        .frame(minHeight: 60)
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
                    if let accessory = AlterExtensions.shared.captionAccessory {
                        HStack {
                            Spacer()
                            accessory(id, store)
                        }
                    }
                }

                // The embedded accessibility text — usually mirroring the
                // caption (generation keeps them in sync), so it stays
                // collapsed until needed. The dot flags when it differs.
                DisclosureGroup(isExpanded: $showAltField) {
                    TextEditor(text: store.metadataBinding(\.altText, for: id))
                        .font(.body)
                        .frame(minHeight: 48)
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
                        .padding(.top, 4)
                } label: {
                    HStack(spacing: 6) {
                        Text("ALT TEXT")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.secondary)
                        if !item.metadata.altText.isEmpty,
                           item.metadata.altText != item.metadata.caption {
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: 5, height: 5)
                                .help("ALT text differs from the caption")
                        }
                    }
                }

                field("KEYWORDS") {
                    TextField("comma, separated, keywords", text: store.keywordsBinding(for: id))
                        .textFieldStyle(.roundedBorder)
                    if !suggestedTags.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Suggested (on-device)")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Button("Add All") {
                                    store.addKeywords(suggestedTags, to: id)
                                    suggestedTags = []
                                }
                                .controlSize(.mini)
                            }
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 4)],
                                      alignment: .leading, spacing: 4) {
                                ForEach(suggestedTags, id: \.self) { tag in
                                    Button("+ \(tag)") {
                                        store.addKeywords([tag], to: id)
                                        suggestedTags.removeAll { $0 == tag }
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }
                        }
                    }
                }

                if metadataView != .basic {
                field("CREATOR") {
                    TextField("Photographer / byline", text: store.metadataBinding(\.creator, for: id))
                        .textFieldStyle(.roundedBorder)
                }

                field("COPYRIGHT") {
                    TextField("© 2026 …", text: store.metadataBinding(\.copyright, for: id))
                        .textFieldStyle(.roundedBorder)
                }

                Divider()

                }
                if metadataView == .all {
                    ExifSection(id: id, item: item)
                }

                if item.dirty {
                    Button {
                        Task { await store.save(ids: [id]) }
                    } label: {
                        Label("Save to File", systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .disabled(store.isWorking)
                }
            }
            .padding(14)
        }
        .task(id: item.url.path) {
            suggestedTags = []
            let url = item.url
            let existing = item.metadata.keywords
            suggestedTags = await TagSuggester.suggest(for: url, limit: 8, excluding: existing)
        }
    }

    @ViewBuilder
    private func field(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
            content()
        }
    }
}

// MARK: - Adjust tab (non-destructive edits)

private struct AdjustmentsPanel: View {
    @EnvironmentObject var store: LibraryStore
    @Environment(\.undoManager) private var undoManager
    let id: Int64
    let item: PhotoItem

    @State private var histogram = HistogramData.empty
    @State private var isNamingPreset = false
    @State private var presetName = ""

    private var histogramKey: String { item.url.path + "#hist#" + item.edits.cacheKey }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(item.filename)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    if !item.edits.isNeutral {
                        Image(systemName: "dial.medium.fill")
                            .foregroundColor(.accentColor)
                            .accessibilityLabel("Has adjustments")
                    }
                }

                if store.viewerPhotoID == nil {
                    Button {
                        store.enterViewer(id)
                    } label: {
                        Label("Open Full-Size View", systemImage: "arrow.up.left.and.arrow.down.right")
                            .frame(maxWidth: .infinity)
                    }
                }

                Button {
                    Task { await store.autoEnhance(ids: [id], undoManager: undoManager) }
                } label: {
                    Label("Auto", systemImage: "wand.and.stars")
                        .frame(maxWidth: .infinity)
                }
                .disabled(store.isWorking)
                .help("Analyze the photo and set a baseline exposure, contrast and vibrance (on-device). Nothing else changes.")

                HistogramView(data: histogram)
                    .task(id: histogramKey) {
                        let url = item.url
                        let edits = item.edits
                        let computed = await Task.detached(priority: .utility) { () -> HistogramData in
                            guard let image = ImageLoader.shared.thumbnail(for: url, edits: edits, maxPixel: 320),
                                  let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                                return .empty
                            }
                            return HistogramData.compute(from: cg)
                        }.value
                        withAnimation(.easeOut(duration: 0.15)) { histogram = computed }
                    }

                if let brushID = store.activeBrushLayerID,
                   let item = store.item(id),
                   let layer = item.edits.brushLayers.first(where: { $0.id == brushID }),
                   layer.brick == nil, layer.quickBrush == nil {
                    // An older free-form brush: its whole recipe is the subject.
                    Label("Brushing — sliders shape the brushed area",
                          systemImage: "paintbrush.pointed.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help("These adjustments apply only where the brush painted. Leave Brush mode to edit the whole photo again.")
                    AdjustmentsControls(edits: store.brushEditsBinding(
                        photoID: id, layerID: brushID), histogram: histogram)
                } else {
                    if store.activeBrushLayerID != nil {
                        Label("Brushing — the outlined brick is being painted",
                              systemImage: "paintbrush.pointed.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    AdjustmentsControls(
                        edits: store.editsBinding(for: id), histogram: histogram,
                        onBrush: { brick, away in store.beginBrushing(brick, away: away, photoID: id) },
                        onEditBrush: { store.editBrushStrokes($0, photoID: id) },
                        onApplyToEntirePhoto: { store.applyBrushToEntirePhoto($0, photoID: id) },
                        onRemoveBrush: { store.removeBrushLayer($0, photoID: id) },
                        onQuickBrush: { store.beginQuickBrush($0, photoID: id) },
                        activeBrushLayerID: store.activeBrushLayerID,
                        presets: store.presets,
                        onApplyPreset: { store.applyPreset($0, to: store.commandTargets.isEmpty ? [id] : store.commandTargets) },
                        onSavePreset: { isNamingPreset = true },
                        onDeletePreset: { store.deletePreset($0.id) },
                        onAuto: { brick in Task { await store.autoBrick(brick, photoID: id, undoManager: undoManager) } },
                        onPick: { kind in
                            store.pickRequest = store.pickRequest == kind ? nil : kind
                            if store.pickRequest != nil, store.viewMode == .browser { store.enterViewer(id) }
                        },
                        activePick: store.pickRequest)
                }

                Button("Reset All Adjustments") {
                    store.resetEdits(for: id)
                }
                .disabled(item.edits.isNeutral)
                .frame(maxWidth: .infinity)

                Text("Originals are never changed — adjustments render into exports and galleries.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(14)
        }
        .alert("Save as Preset", isPresented: $isNamingPreset) {
            TextField("Preset name", text: $presetName)
            Button("Save") {
                let name = presetName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { store.savePreset(named: name, from: id) }
                presetName = ""
            }
            Button("Cancel", role: .cancel) { presetName = "" }
        } message: {
            Text("The current adjustments (not crop, retouch or brushes) become a preset in the Presets menu.")
        }
    }

}

// MARK: - Colour labels

/// Aperture's label swatches in a row: click to set, click again to clear.
/// One adjustable VoiceOver control that steps through the colours.
struct LabelDots: View {
    let selected: Int
    let onChange: (Int) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(PhotoLabel.colors) { label in
                Circle()
                    .fill(label.color)
                    .frame(width: 11, height: 11)
                    .overlay(Circle().strokeBorder(
                        selected == label.rawValue ? Color.primary : Color.clear, lineWidth: 1.5))
                    .scaleEffect(selected == label.rawValue ? 1.15 : 1)
                    .onTapGesture {
                        onChange(selected == label.rawValue ? 0 : label.rawValue)
                    }
                    .help(label.name)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Color label")
        .accessibilityValue(PhotoLabel(rawValue: selected)?.name ?? "No Label")
        .accessibilityAdjustableAction { direction in
            let all = PhotoLabel.allCases.map(\.rawValue)
            let index = all.firstIndex(of: selected) ?? 0
            switch direction {
            case .increment: onChange(all[min(all.count - 1, index + 1)])
            case .decrement: onChange(all[max(0, index - 1)])
            @unknown default: break
            }
        }
    }
}

// MARK: - Rating stars

struct RatingControl: View {
    let rating: Int
    let onChange: (Int) -> Void

    var body: some View {
        HStack(spacing: 2) {
            // Aperture's Reject (9) sits left of the stars.
            Image(systemName: rating < 0 ? "xmark.circle.fill" : "xmark.circle")
                .font(.system(size: 13))
                .foregroundColor(rating < 0 ? .red : .secondary)
                .onTapGesture { onChange(rating < 0 ? 0 : -1) }
                .help(rating < 0 ? "Rejected — click to clear" : "Reject (9)")
                .padding(.trailing, 2)
            ForEach(1...5, id: \.self) { star in
                Image(systemName: star <= rating ? "star.fill" : "star")
                    .font(.system(size: 13))
                    .foregroundColor(star <= rating ? .yellow : .secondary)
                    .onTapGesture {
                        // Tapping the current rating clears it.
                        onChange(star == rating ? 0 : star)
                    }
            }
        }
        // One adjustable VoiceOver control ("Rating, 3 of 5 stars") — swipe
        // up/down to change it, rather than five unlabelled star images.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Rating")
        .accessibilityValue(rating < 0 ? "Rejected" : rating == 0 ? "No rating" : "\(rating) of 5 stars")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onChange(min(5, rating + 1))
            case .decrement: onChange(max(-1, rating - 1))
            @unknown default: break
            }
        }
    }
}

// MARK: - Batch

private struct BatchInspector: View {
    @EnvironmentObject var store: LibraryStore

    @State private var creator = ""
    @State private var copyright = ""
    @State private var keywords = ""
    @State private var appendKeywords = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("\(store.selection.count) photos selected")
                    .font(.headline)

                if let actions = AlterExtensions.shared.batchInspectorActions { actions(store) }

                Menu {
                    SnippetMenuItems(targets: Array(store.selection))
                } label: {
                    Label("Apply Snippet to \(store.selection.count)…", systemImage: "text.badge.plus")
                        .frame(maxWidth: .infinity)
                }

                Divider()

                Group {
                    Text("APPLY TO ALL SELECTED")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)

                    TextField("Creator / byline", text: $creator)
                        .textFieldStyle(.roundedBorder)
                    TextField("Copyright", text: $copyright)
                        .textFieldStyle(.roundedBorder)
                    TextField("Keywords (comma separated)", text: $keywords)
                        .textFieldStyle(.roundedBorder)
                    Toggle("Add to existing keywords (instead of replacing)", isOn: $appendKeywords)
                        .font(.caption)

                    Button("Apply to \(store.selection.count) photos") {
                        applyBatch()
                    }
                    .disabled(creator.isEmpty && copyright.isEmpty && keywords.isEmpty)
                }

                Divider()

                Button("Save \(store.selectedItems.filter(\.dirty).count) to Files") {
                    Task { await store.save(ids: Array(store.selection)) }
                }
                .disabled(store.selectedItems.allSatisfy { !$0.dirty } || store.isWorking)
            }
            .padding(14)
        }
    }

    private func applyBatch() {
        let newKeywords = PhotoMetadata.splitKeywords(keywords)
        let creatorValue = creator
        let copyrightValue = copyright
        let append = appendKeywords

        store.applyToSelection { meta in
            if !creatorValue.isEmpty { meta.creator = creatorValue }
            if !copyrightValue.isEmpty { meta.copyright = copyrightValue }
            if !newKeywords.isEmpty {
                if append {
                    for keyword in newKeywords where !meta.keywords.contains(keyword) {
                        meta.keywords.append(keyword)
                    }
                } else {
                    meta.keywords = newKeywords
                }
            }
        }
        creator = ""
        copyright = ""
        keywords = ""
    }
}
