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
                        // In Full Screen the toolbar stays — macOS slides it
                        // down with the menu bar (auto-hide, set on entering)
                        // and it carries the Full Screen controls.
                        .toolbar(store.slideshowIDs != nil ? .hidden : .visible,
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
            store.installFullScreenObservers()
            if keyCommands == nil {
                let commands = KeyCommands(store: store)
                commands.install()
                keyCommands = commands
            }
        }
        .alert(store.alertTitle ?? "Something went wrong", isPresented: Binding(
            get: { store.alertMessage != nil },
            set: { if !$0 { store.alertMessage = nil; store.alertTitle = nil } }
        )) {
            Button("OK", role: .cancel) { store.alertMessage = nil; store.alertTitle = nil }
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
                    } else if store.source == .faces {
                        FacesView()
                    } else {
                        switch store.viewMode {
                        case .browser:
                            if case .person(let id) = store.source {
                                VStack(spacing: 0) {
                                    PersonHeader(faces: store.faces, personID: id)
                                    Divider()
                                    GridView()
                                }
                            } else {
                                GridView()
                            }
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
                .overlay(alignment: .bottomTrailing) {
                    // A tethered session's HUD floats while it runs.
                    TetherHUD()
                        .padding(.trailing, 16)
                        .padding(.bottom, store.viewMode == .browser ? 16 : 80)
                        .animation(.easeOut(duration: 0.2), value: CameraHub.shared.tether != nil)
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
            if store.isFullScreenMode {
                FullScreenToolbarItems()
            } else {
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
                    store.isImportWindowPresented = true
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down.on.square")
                }
                .help("Import from a card, drive or folder (⌘I)")

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
                                    .background(
                                        Color.clear
                                            .sheet(isPresented: $store.isAdjustDatePresented) {
                                                AdjustDateSheet().environmentObject(store)
                                            }
                                            .background(
                                                Color.clear
                                                    .sheet(isPresented: $store.isImportWindowPresented) {
                                                        ImportWindow().environmentObject(store)
                                                    }
                                            )
                                    )
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
            if store.hasApertureLibraries {
                Label(store.originalsAreReadOnly ? "Aperture library — originals untouched"
                                                 : "Aperture originals untouched", systemImage: "lock")
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
    /// Aperture's "Always Show Filmstrip".
    @AppStorage("fullscreen.pinFilmstrip") private var pinFilmstrip = false
    /// HUD centre; nil = default spot top-right.
    @State private var hudPosition: CGPoint?
    @State private var hudDragStart: CGPoint?
    /// The full-screen area, for keeping the HUD reachable while dragging.
    @State private var screenSize: CGSize = .zero
    private let hudSize = CGSize(width: 380, height: 660)

    private let stripHeight: CGFloat = 150

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                Color.black.ignoresSafeArea()

                Group {
                    if let pane = AlterExtensions.shared.centerPane?(store) {
                        pane
                    } else if store.source == .faces {
                        FacesView()
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
                                       y: hudSize.height / 2 + menuBarClearance + 16)
                    let p = clampedHUD(hudPosition ?? home, in: geo.size)
                    inspectorHUD
                        .position(x: p.x, y: p.y)
                        .transition(.opacity)
                }
            }
            .coordinateSpace(name: "fullscreen")
            .onAppear { screenSize = geo.size }
            .onChange(of: geo.size) { screenSize = $0 }
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

    /// The band at the top that macOS claims in full screen: its menu bar
    /// and, under it, the window's title strip and toolbar, which slide down
    /// together and take every click there. The Inspector HUD's title row is
    /// kept below it.
    private var menuBarClearance: CGFloat {
        let menuBar = max(NSApp.mainMenu?.menuBarHeight ?? 0, NSScreen.main?.safeAreaInsets.top ?? 0, 24)
        // Measured: a 52-point window (title strip plus toolbar) sits under
        // the menu bar while it shows.
        let titleStrip: CGFloat = 52
        return menuBar + titleStrip + 6
    }

    /// The HUD's centre, kept on screen and with its title row (close
    /// button, drag handle) below the top bar. Dragged into the band macOS
    /// claims under the menu bar, the title row stopped taking clicks and the
    /// HUD could be neither moved nor closed.
    private func clampedHUD(_ p: CGPoint, in size: CGSize) -> CGPoint {
        guard size.width > 0, size.height > 0 else { return p }
        let topLimit = menuBarClearance + hudSize.height / 2
        let bottomLimit = max(topLimit, size.height - hudSize.height / 2)
        return CGPoint(x: min(max(p.x, hudSize.width / 2), max(hudSize.width / 2, size.width - hudSize.width / 2)),
                       y: min(max(p.y, topLimit), bottomLimit))
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
                        // Clamped as it moves, so overshooting an edge and
                        // coming back doesn't leave a dead stretch.
                        hudPosition = clampedHUD(CGPoint(x: start.x + drag.translation.width,
                                                         y: start.y + drag.translation.height),
                                                 in: screenSize)
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

/// Alter's Full Screen controls, in the window toolbar. macOS slides the
/// toolbar down with the menu bar when the pointer reaches the top edge and
/// hides both when it leaves — flush with the top of the screen and fully
/// clickable. (A bar of Alter's own up there fought the menu bar: it floated
/// below it, flickered, or sat under macOS's click-catching title strip.)
private struct FullScreenToolbarItems: ToolbarContent {
    @EnvironmentObject var store: LibraryStore
    @AppStorage("fullscreen.pinFilmstrip") private var pinFilmstrip = false

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button {
                store.exitFullScreenMode(window: NSApp.keyWindow ?? NSApp.mainWindow)
            } label: {
                Label("Exit Full Screen", systemImage: "arrow.down.right.and.arrow.up.left")
            }
            .help("Back to the window (F or Esc)")
        }
        ToolbarItemGroup {
            Picker("View", selection: $store.viewMode) {
                Image(systemName: "square.grid.2x2").tag(LibraryStore.ViewMode.browser)
                    .help("Browser")
                Image(systemName: "rectangle").tag(LibraryStore.ViewMode.viewer)
                    .help("Viewer")
            }
            .pickerStyle(.segmented)
            .help("Browser or Viewer (V)")
            Toggle(isOn: $pinFilmstrip) {
                Label("Filmstrip", systemImage: "rectangle.bottomthird.inset.filled")
            }
            .help("Always show the filmstrip (otherwise it slides up from the bottom edge)")
            Toggle(isOn: $store.isInspectorHUDVisible) {
                Label("Inspector", systemImage: "slider.horizontal.3")
            }
            .help("Inspector HUD (H)")
        }
    }
}

