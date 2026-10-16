//
//  ContentView.swift
//  Alter
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var store: LibraryStore
    @State private var isDropTargeted = false
    @State private var stripHeight: CGFloat = {
        let saved = UserDefaults.standard.double(forKey: "alter_filmstrip_height")
        return saved > 0 ? CGFloat(saved) : 150
    }()
    @State private var stripHeightAtDragStart: CGFloat?
    /// Aperture's single-key commands (ratings, flag, labels, V, W, F).
    @State private var keyCommands: KeyCommands?

    var body: some View {
        Group {
            if store.isOpen {
                // The split view (which owns the window toolbar) stays mounted
                // under Full Screen and the slideshow — swapping it out left
                // the toolbar gone when the window came back.
                ZStack {
                    librarySplit
                        .toolbar(store.isFullScreenMode || store.slideshowIDs != nil ? .hidden : .visible,
                                 for: .windowToolbar)
                    if let ids = store.slideshowIDs {
                        SlideshowView(ids: ids)
                            .ignoresSafeArea()
                    } else if store.isFullScreenMode {
                        FullScreenView()
                            .ignoresSafeArea()
                    }
                }
            } else {
                WelcomeView()
            }
        }
        .navigationTitle(store.isOpen ? "Media" : "Alter")
        .onAppear {
            store.openLastLibraryIfAvailable()
            if keyCommands == nil {
                let commands = KeyCommands(store: store)
                commands.install()
                keyCommands = commands
            }
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { store.alertMessage != nil },
            set: { if !$0 { store.alertMessage = nil } }
        )) {
            Button("OK", role: .cancel) { store.alertMessage = nil }
        } message: {
            Text(store.alertMessage ?? "")
        }
        .alert("Revert metadata?", isPresented: Binding(
            get: { !store.pendingRevertIDs.isEmpty },
            set: { if !$0 { store.pendingRevertIDs = [] } }
        )) {
            Button("Revert", role: .destructive) {
                let ids = store.pendingRevertIDs
                store.pendingRevertIDs = []
                Task { await store.revertMetadata(ids) }
            }
            Button("Cancel", role: .cancel) { store.pendingRevertIDs = [] }
        } message: {
            Text("Restores ALT text, title, caption, keywords, creator, and copyright on \(store.pendingRevertIDs.count) photo\(store.pendingRevertIDs.count == 1 ? "" : "s") to what the file held when Alter found it. Unsaved edits are discarded too. Adjustments are not affected.")
        }
    }

    private var librarySplit: some View {
        librarySplitCore
            .background(Group {
                if let sheets = AlterExtensions.shared.sheets { sheets(store) }
            })
    }

    /// Saved column widths (SwiftUI won't persist these itself).
    private var savedSidebarWidth: CGFloat {
        let width = UserDefaults.standard.double(forKey: "alter_col_sidebar")
        return width > 0 ? CGFloat(width) : 210
    }

    /// The inspector never grows on its own: it starts at minimum, only a
    /// deliberate divider drag widens it, and that choice is remembered.
    /// (A fresh defaults key — the old auto-saved widths were polluted by
    /// the split view's flexible-detail growth.)
    @AppStorage("alter_inspector_width") private var inspectorWidth: Double = 280
    @State private var dividerDragStart: Double?

    private var clampedInspectorWidth: CGFloat {
        CGFloat(min(max(inspectorWidth, 280), 560))
    }

    /// The drag handle between content and inspector: drag to resize
    /// (window growth never touches the inspector), double-click to snap
    /// back to minimum.
    private var inspectorDivider: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .overlay(
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                if dividerDragStart == nil { dividerDragStart = inspectorWidth }
                                inspectorWidth = min(560, max(280,
                                    (dividerDragStart ?? inspectorWidth) - Double(value.translation.width)))
                            }
                            .onEnded { _ in dividerDragStart = nil }
                    )
                    .onTapGesture(count: 2) { inspectorWidth = 280 }
            )
            .help("Drag to resize the inspector — double-click for minimum width")
    }

    /// Several selected and not Primary Only: Aperture shows them all.
    @ViewBuilder
    private var viewerPane: some View {
        if store.selection.count > 1, !store.primaryOnly {
            MultiViewerView()
        } else {
            ViewerView()
        }
    }

    private var librarySplitCore: some View {
        NavigationSplitView {
            SidebarView()
                .background(ColumnWidthSaver(key: "alter_col_sidebar"))
                .navigationSplitViewColumnWidth(min: 180, ideal: savedSidebarWidth, max: 340)
        } detail: {
            HStack(spacing: 0) {
                Group {
                    if let pane = AlterExtensions.shared.centerPane?(store) {
                        // An extension's editor or queue owns the centre pane.
                        pane
                    } else {
                        switch store.viewMode {
                        case .browser:
                            GridView()
                        case .viewer:
                            viewerPane
                        case .split:
                            VStack(spacing: 0) {
                                viewerPane
                                stripDivider
                                FilmstripView()
                                    .frame(height: stripHeight)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .bottomLeading) {
                    HStack(alignment: .bottom, spacing: 12) {
                        if store.isLiftStampVisible {
                            LiftStampHUD().transition(.opacity)
                        }
                        if store.isKeywordsHUDVisible {
                            KeywordsHUD().transition(.opacity)
                        }
                    }
                    // Clear of the viewer's two-row tray.
                    .padding(.leading, 16)
                    .padding(.bottom, store.viewMode == .browser ? 16 : 80)
                }
                inspectorDivider
                InspectorView()
                    .frame(width: clampedInspectorWidth)
            }
            // These insets MUST live on the detail content, not on the
            // NavigationSplitView: on macOS the split view does not propagate
            // an outer safeAreaInset into its columns, so the whole detail
            // pane laid out one status-bar too tall — the viewer's control
            // tray (and the filmstrip's bottom edge) rendered below the
            // window's visible bottom.
            .safeAreaInset(edge: .top, spacing: 0) {
                if store.exiftoolMissing {
                    exiftoolBanner
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                statusBar
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Picker("View", selection: $store.viewMode) {
                    Image(systemName: "square.grid.2x2").tag(LibraryStore.ViewMode.browser)
                        .help("Browser — the grid (⌘1)")
                    Image(systemName: "squares.below.rectangle").tag(LibraryStore.ViewMode.split)
                        .help("Split View — viewer with filmstrip (⌘2)")
                    Image(systemName: "rectangle").tag(LibraryStore.ViewMode.viewer)
                        .help("Viewer — full size (⌘3)")
                }
                .pickerStyle(.segmented)

                Button {
                    store.presentImportPanel()
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down.on.square")
                }
                .help("Import folders or images — referenced in place (⌘I)")

                Button {
                    Task { await store.saveDirty() }
                } label: {
                    Label("Save to Files", systemImage: "square.and.arrow.down")
                }
                .disabled(store.dirtyCount == 0 || store.isWorking)
                .help("Write all pending edits into the files (⌘S)")

                Button {
                    store.isExportSheetPresented = true
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(store.items.isEmpty || store.isWorking)
                .help(store.selection.isEmpty
                      ? "Export all photos shown (⌘E)"
                      : "Export the \(store.selection.count) selected (⌘E)")

                if let items = AlterExtensions.shared.toolbarItems { items(store) }
            }
        }
        // Sheets are attached one per view node (see `sheetHosts`) — chaining
        // them all here left `dismiss()` bound to the wrong presentation and
        // Cancel/Esc became no-ops, trapping the app in the first sheet.
        // Same lesson as the chained alerts above.
        .background(sheetHosts)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
    }

    /// Each sheet gets its own zero-size host view, so every presentation has
    /// an independent node and `@Environment(\.dismiss)` inside a sheet
    /// resolves to *that* sheet. Nested (rather than chained) so they compose
    /// without stacking modifiers on a single node.
    private var sheetHosts: some View {
        Color.clear
            .sheet(isPresented: $store.isExportSheetPresented) { ExportSheet() }
            .background(
                Color.clear
                    .sheet(isPresented: $store.isSnippetsEditorPresented) { SnippetsEditor() }
                    .background(
                        Color.clear
                            .sheet(isPresented: $store.isBatchChangePresented) {
                                BatchChangeSheet().environmentObject(store)
                            }
                            .background(
                                Color.clear
                                    .sheet(isPresented: $store.isAutoStackPresented) {
                                        AutoStackSheet().environmentObject(store)
                                    }
                            )
                    )
            )
    }

    /// Drag bar between viewer and filmstrip — resizes the strip (Aperture-style).
    private var stripDivider: some View {
        ZStack {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: 1)
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(nsColor: .tertiaryLabelColor))
                .frame(width: 36, height: 4)
        }
        .frame(height: 9)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    if stripHeightAtDragStart == nil { stripHeightAtDragStart = stripHeight }
                    let proposed = (stripHeightAtDragStart ?? stripHeight) - value.translation.height
                    stripHeight = min(320, max(90, proposed))
                }
                .onEnded { _ in
                    stripHeightAtDragStart = nil
                    UserDefaults.standard.set(Double(stripHeight), forKey: "alter_filmstrip_height")
                }
        )
    }

    private var exiftoolBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.yellow)
            Text("exiftool is required to read & write metadata. Install with:  brew install exiftool")
                .font(.callout)
            Spacer()
            Button("Check Again") {
                store.exiftoolMissing = !ExifToolService.isAvailable
            }
        }
        .padding(10)
        .background(.thinMaterial)
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            Text("\(store.items.count) shown")
            if !store.selection.isEmpty {
                Text("\(store.selection.count) selected")
            }
            if store.dirtyCount > 0 {
                Text("\(store.dirtyCount) pending write")
                    .foregroundColor(.orange)
            }
            if store.isWorking {
                ProgressView().controlSize(.small)
            }
            if let progress = store.apertureProgress {
                ProgressView(value: Double(progress.done), total: Double(max(1, progress.total)))
                    .controlSize(.small)
                    .frame(width: 120)
                Text(progress.phase)
                    .foregroundColor(.secondary)
            }
            if store.originalsAreReadOnly {
                Label("Aperture library — originals untouched", systemImage: "lock")
                    .labelStyle(.titleAndIcon)
                    .foregroundColor(.secondary)
                    .help("This library reads an Aperture library in place. Metadata and adjustments live in Alter's catalog; the Aperture bundle is never modified.")
            }
            Spacer()
            Text(store.statusMessage)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundColor(.secondary)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    /// Records a split column's live width so the next launch restores it.
    private struct ColumnWidthSaver: View {
        let key: String
        var body: some View {
            GeometryReader { geo in
                Color.clear
                    .onChange(of: geo.size.width) { width in
                        if width > 0 { UserDefaults.standard.set(Double(width), forKey: key) }
                    }
            }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard store.isOpen else { return false }
        var urls: [URL] = []
        let group = DispatchGroup()
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { urls.append(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            guard !urls.isEmpty else { return }
            Task { await store.importURLs(urls) }
        }
        return true
    }
}


// MARK: - Full Screen mode

/// Aperture's full screen: the photo on black, nothing else — until the
/// pointer goes to the bottom (filmstrip slides up) or the top (a small
/// bar: exit, view mode, HUD). H floats the Inspector HUD, draggable.
private struct FullScreenView: View {
    @EnvironmentObject var store: LibraryStore

    @State private var pointerY: CGFloat?
    @State private var stripHovered = false
    @State private var topHovered = false
    /// Aperture's "Always Show Filmstrip".
    @AppStorage("fullscreen.pinFilmstrip") private var pinFilmstrip = false
    /// HUD centre; nil = default spot top-right.
    @State private var hudPosition: CGPoint?
    @State private var hudDragStart: CGPoint?
    private let hudSize = CGSize(width: 380, height: 660)

    private let stripHeight: CGFloat = 150

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                Color.black.ignoresSafeArea()

                Group {
                    if let pane = AlterExtensions.shared.centerPane?(store) {
                        pane
                    } else if store.viewMode == .browser {
                        GridView()
                    } else if store.selection.count > 1, !store.primaryOnly {
                        MultiViewerView()
                    } else {
                        ViewerView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Filmstrip, from the bottom.
                VStack {
                    Spacer()
                    if showStrip(in: geo.size) {
                        FilmstripView()
                            .frame(height: stripHeight)
                            .background(Color.black.opacity(0.92))
                            .overlay(alignment: .top) {
                                Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1)
                            }
                            .onHover { stripHovered = $0 }
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.easeOut(duration: 0.18), value: showStrip(in: geo.size))

                // Top bar, from the top.
                if showTop {
                    topBar
                        .onHover { topHovered = $0 }
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                if store.isLiftStampVisible || store.isKeywordsHUDVisible {
                    HStack(alignment: .bottom, spacing: 12) {
                        if store.isLiftStampVisible { LiftStampHUD() }
                        if store.isKeywordsHUDVisible { KeywordsHUD() }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .transition(.opacity)
                }

                // Inspector HUD.
                if store.isInspectorHUDVisible {
                    let home = CGPoint(x: geo.size.width - hudSize.width / 2 - 24,
                                       y: hudSize.height / 2 + 60)
                    let p = hudPosition ?? home
                    inspectorHUD
                        .position(x: min(max(p.x, hudSize.width / 2), geo.size.width - hudSize.width / 2),
                                  y: min(max(p.y, hudSize.height / 2), geo.size.height - hudSize.height / 2))
                        .transition(.opacity)
                }
            }
            .coordinateSpace(name: "fullscreen")
            .animation(.easeOut(duration: 0.18), value: showTop)
            .animation(.easeOut(duration: 0.15), value: store.isInspectorHUDVisible)
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let point): pointerY = point.y
                case .ended: pointerY = nil
                }
            }
        }
        .background(Color.black)
    }

    /// The strip rides up only from the very bottom edge (so the viewer's
    /// tray above it stays reachable), stays while hovered, or is pinned.
    private func showStrip(in size: CGSize) -> Bool {
        guard store.viewMode != .browser else { return false }
        if pinFilmstrip || stripHovered { return true }
        guard let y = pointerY else { return false }
        return y > size.height - 6
    }

    private var showTop: Bool {
        if topHovered { return true }
        guard let y = pointerY else { return false }
        return y < 50
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            Button {
                store.exitFullScreenMode(window: NSApp.keyWindow ?? NSApp.mainWindow)
            } label: {
                Label("Exit Full Screen", systemImage: "arrow.down.right.and.arrow.up.left")
            }
            .help("Back to the window (F or Esc)")
            Picker("View", selection: $store.viewMode) {
                Image(systemName: "square.grid.2x2").tag(LibraryStore.ViewMode.browser)
                Image(systemName: "rectangle").tag(LibraryStore.ViewMode.viewer)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 90)
            .help("Browser or Viewer (V)")
            Spacer()
            if let id = store.viewerPhotoID, let item = store.item(id) {
                Text(item.filename)
                    .foregroundColor(.white.opacity(0.8))
                    .lineLimit(1)
                Spacer()
            }
            Toggle(isOn: $pinFilmstrip) {
                Label("Filmstrip", systemImage: "rectangle.bottomthird.inset.filled")
            }
            .toggleStyle(.button)
            .help("Always show the filmstrip (otherwise it slides up from the bottom edge)")
            Toggle(isOn: $store.isInspectorHUDVisible) {
                Label("Inspector", systemImage: "slider.horizontal.3")
            }
            .toggleStyle(.button)
            .help("Inspector HUD (H)")
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.85))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1)
        }
    }

    private var inspectorHUD: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "slider.horizontal.3")
                Text("Inspector")
                    .font(.caption.weight(.semibold))
                Spacer()
                Button {
                    store.isInspectorHUDVisible = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close Inspector HUD")
            }
            .foregroundColor(.white.opacity(0.85))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.08))
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
            }
            .help("Drag to move")
            .gesture(
                DragGesture(coordinateSpace: .named("fullscreen"))
                    .onChanged { drag in
                        if hudDragStart == nil {
                            hudDragStart = hudPosition ?? CGPoint(
                                x: drag.startLocation.x, y: drag.startLocation.y + hudSize.height / 2 - 14)
                        }
                        guard let start = hudDragStart else { return }
                        hudPosition = CGPoint(x: start.x + drag.translation.width,
                                              y: start.y + drag.translation.height)
                    }
                    .onEnded { _ in hudDragStart = nil }
            )
            InspectorView()
                .frame(width: hudSize.width)
                .clipped()
        }
        .frame(width: hudSize.width, height: hudSize.height)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.96))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
        .shadow(color: .black.opacity(0.6), radius: 20, y: 8)
    }
}
