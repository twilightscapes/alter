//
//  AlterApp.swift
//  Alter — the photo library and editor for life after Aperture.
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
//  The window, menus and settings every Alter build shares. Each app
//  target's @main owns the store and hands it here; extensions add their
//  items through AlterExtensions.
//

import SwiftUI

/// Routes Finder into the app: double-clicking an .alterlib (or dropping
/// one on the Dock icon) opens that library. Arrivals can beat the UI —
/// a launch-by-double-click delivers the URL before any view exists — so
/// the URL parks until the store checks in.
@MainActor
final class ALTerAppDelegate: NSObject, NSApplicationDelegate {
    static weak var store: LibraryStore? {
        didSet { openPendingIfReady() }
    }
    private static var pending: URL?
    /// True while a Finder-opened library is waiting for the store — the
    /// "last library isn't where it was" alert must not get in its way.
    static var hasPendingOpen: Bool { pending != nil }

    nonisolated func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            guard let url = urls.first(where: {
                Catalog.isLibrary($0) || ApertureLibrary.isApertureLibrary($0)
            }) else { return }
            Self.pending = url
            Self.openPendingIfReady()
        }
    }

    private static func openPendingIfReady() {
        guard let url = pending, let store else { return }
        pending = nil
        if ApertureLibrary.isApertureLibrary(url) {
            store.adoptApertureLibrary(url)
        } else {
            store.adoptLibrary(url)
        }
    }
}

struct AlterScenes: Scene {
    @ObservedObject var store: LibraryStore
    private var ext: AlterExtensions { AlterExtensions.shared }

    var body: some Scene {
        // A single, identified Window (not WindowGroup) so macOS remembers its
        // size and position across launches.
        Window("Alter", id: "main") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 980, minHeight: 600)
                .onAppear { ALTerAppDelegate.store = store }
                .alterExtensionRoot(store)
        }
        .defaultSize(width: 1240, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Library…") { store.presentNewLibraryPanel() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Open Library…") { store.presentOpenLibraryPanel() }
                    .keyboardShortcut("o", modifiers: .command)
                Button("Open Aperture Library…") { store.presentOpenApertureLibraryPanel() }
                    .keyboardShortcut("o", modifiers: [.command, .option])
                Divider()
                Button("Import Media…") { store.presentImportPanel() }
                    .keyboardShortcut("i", modifiers: .command)
                    .disabled(!store.isOpen)
                Button("Import from Photos Library…") { store.importFromPhotos() }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                    .disabled(!store.isOpen)
                if let items = ext.fileMenuItems { items(store) }
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save Metadata to Files") { Task { await store.saveDirty() } }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(store.dirtyCount == 0)
                Button("Revert Metadata to As-Found…") {
                    store.pendingRevertIDs = Array(store.selection)
                }
                .disabled(store.selection.isEmpty)
                Button("Export…") { store.isExportSheetPresented = true }
                    .keyboardShortcut("e", modifiers: .command)
                    .disabled(store.items.isEmpty)
                if let items = ext.exportMenuItems { items(store) }
            }
            CommandGroup(replacing: .undoRedo) {
                // An extension may take Undo for its own editor; everything
                // else falls through to the responder chain (text fields keep
                // theirs).
                Button("Undo") {
                    if ext.undo?(store) != true {
                        NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
                    }
                }
                .keyboardShortcut("z", modifiers: .command)
                Button("Redo") {
                    if ext.redo?(store) != true {
                        NSApp.sendAction(Selector(("redo:")), to: nil, from: nil)
                    }
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandGroup(before: .sidebar) {
                Button("Cycle View\tV") { store.cycleViewMode() }
                    .disabled(!store.isOpen)
                Button(store.isFullScreenMode ? "Exit Full Screen\tF" : "Full Screen\tF") {
                    store.toggleFullScreenMode(window: NSApp.keyWindow ?? NSApp.mainWindow)
                }
                .disabled(!store.isOpen)
                Button("Inspector HUD\tH") { store.isInspectorHUDVisible.toggle() }
                    .disabled(!store.isFullScreenMode)
                Divider()
                Toggle("Primary Only", isOn: $store.primaryOnly)
                    .keyboardShortcut("u", modifiers: .option)
                    .disabled(!store.isOpen)
                Toggle("Highlight Hot & Cold Areas", isOn: $store.showHotCold)
                    .keyboardShortcut("h", modifiers: [.option, .shift])
                    .disabled(!store.isOpen)
                Button("Browser") { store.viewMode = .browser }
                    .keyboardShortcut("1", modifiers: .command)
                    .disabled(!store.isOpen)
                Button("Split View") { store.viewMode = .split }
                    .keyboardShortcut("2", modifiers: .command)
                    .disabled(!store.isOpen)
                Button("Viewer") { store.viewMode = .viewer }
                    .keyboardShortcut("3", modifiers: .command)
                    .disabled(!store.isOpen)
                Divider()
            }
            CommandGroup(after: .saveItem) {
                if let items = ext.createMenuItems {
                    Divider()
                    items(store)
                }
            }
            CommandGroup(after: .pasteboard) {
                Button("Select All Photos") { store.selectAll() }
                    .keyboardShortcut("a", modifiers: .command)
                    .disabled(!store.isOpen)
                Button("Find") { store.focusSearch() }
                    .keyboardShortcut("f", modifiers: .command)
                    .disabled(!store.isOpen)
            }
            CommandMenu("Media") {
                if let items = ext.mediaMenuTopItems { items(store) }
                Button(store.viewerPhotoID == nil ? "View Full Size" : "Back to Grid") {
                    if store.viewerPhotoID != nil {
                        store.exitViewer()
                    } else if let id = store.selection.first {
                        store.enterViewer(id)
                    }
                }
                .keyboardShortcut("\r", modifiers: .command)
                .disabled(store.viewerPhotoID == nil && store.selection.count != 1)
                Divider()
                // Aperture's keys — plain digits, = and −, 9 to reject, / to
                // flag, ⌃digit for labels — are handled by KeyCommands (so
                // typing in a field never rates a photo); the menu shows them.
                ForEach(0...5, id: \.self) { stars in
                    Button(stars == 0 ? "No Rating\t0" : String(repeating: "★", count: stars) + "\t\(stars)") {
                        store.setRating(stars, for: store.commandTargets)
                    }
                    .disabled(store.commandTargets.isEmpty)
                }
                Button("Reject\t9") { store.setRating(-1, for: store.commandTargets) }
                    .disabled(store.commandTargets.isEmpty)
                Button("Increase Rating\t=") { store.adjustRating(by: 1, for: store.commandTargets) }
                    .disabled(store.commandTargets.isEmpty)
                Button("Decrease Rating\t−") { store.adjustRating(by: -1, for: store.commandTargets) }
                    .disabled(store.commandTargets.isEmpty)
                Divider()
                Button("Flag / Unflag\t/") {
                    let ids = store.commandTargets
                    let anyUnflagged = ids.contains { !(store.item($0)?.flagged ?? true) }
                    store.setFlagged(anyUnflagged, for: ids)
                }
                .disabled(store.commandTargets.isEmpty)
                Menu("Label") {
                    ForEach(PhotoLabel.allCases) { label in
                        Button("\(label.name)\t⌃\(label.rawValue)") {
                            store.setLabel(label.rawValue, for: store.commandTargets)
                        }
                    }
                }
                .disabled(store.commandTargets.isEmpty)
                Divider()
                Button("Rotate Counterclockwise") { store.rotate(-1, for: store.commandTargets) }
                    .keyboardShortcut("[", modifiers: .command)
                    .disabled(store.commandTargets.isEmpty)
                Button("Rotate Clockwise") { store.rotate(1, for: store.commandTargets) }
                    .keyboardShortcut("]", modifiers: .command)
                    .disabled(store.commandTargets.isEmpty)
                Button("Flip Horizontal") { store.flip(horizontal: true, for: store.commandTargets) }
                    .disabled(store.commandTargets.isEmpty)
                Button("Flip Vertical") { store.flip(horizontal: false, for: store.commandTargets) }
                    .disabled(store.commandTargets.isEmpty)
                Divider()
                // Aperture's own keys: ⌥G new version, ⌥V duplicate, ⌘K stack.
                Button("New Version from Original") {
                    if let id = store.selection.first { store.createVersion(of: id, fromOriginal: true) }
                }
                .keyboardShortcut("g", modifiers: .option)
                .disabled(store.selection.count != 1)
                Button("Duplicate Version") {
                    if let id = store.selection.first { store.createVersion(of: id, fromOriginal: false) }
                }
                .keyboardShortcut("v", modifiers: .option)
                .disabled(store.selection.count != 1)
                Button("Stack") { store.stackSelection() }
                    .keyboardShortcut("k", modifiers: .command)
                    .disabled(store.selection.count < 2)
                Button("Unstack") {
                    if let id = store.selection.first, let stackID = store.item(id)?.stackID {
                        store.unstack(stackID)
                    }
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(store.selection.first.flatMap { store.item($0)?.stackID } == nil)
                Button("Set as Pick") {
                    if let id = store.selection.first { store.setStackPick(id) }
                }
                .keyboardShortcut("\\", modifiers: .command)
                .disabled(store.selection.count != 1
                          || store.selection.first.flatMap { store.item($0)?.stackID } == nil)
                Button("Auto-Stack…") { store.isAutoStackPresented = true }
                    .disabled(!store.isOpen || store.items.isEmpty)
                Menu("Edit With") {
                    let apps = ExternalEditor.candidateApps()
                    if apps.isEmpty {
                        Text("No TIFF editors found")
                    }
                    ForEach(apps, id: \.url) { app in
                        Button(app.name) {
                            if let id = store.commandTargets.first { store.editWith(appURL: app.url, photoID: id) }
                        }
                    }
                }
                .disabled(store.commandTargets.count != 1 || store.isWorking)
                Divider()
                Menu("Quick Brushes") {
                    ForEach(QuickBrush.allCases) { quick in
                        Button(quick.name) {
                            if let id = store.commandTargets.first { store.beginQuickBrush(quick, photoID: id) }
                        }
                    }
                }
                .disabled(store.commandTargets.count != 1)
                Button("Auto-Enhance") {
                    Task { await store.autoEnhance(ids: Array(store.selection)) }
                }
                .keyboardShortcut("a", modifiers: [.command, .option])
                .disabled(store.selection.isEmpty)
                Button("Suggest Keywords") {
                    Task { await store.suggestKeywords(ids: Array(store.selection)) }
                }
                .keyboardShortcut("k", modifiers: [.command, .option])
                .disabled(store.selection.isEmpty)
                // Aperture's Lift & Stamp: ⇧⌘C lifts, ⇧⌘V stamps by the HUD's
                // checkboxes (adjustments and keywords by default), O shows it.
                Button("Lift Adjustments & Metadata") { store.lift() }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .disabled(store.commandTargets.count != 1)
                Button("Stamp onto Selection") { store.stamp() }
                    .keyboardShortcut("v", modifiers: [.command, .shift])
                    .disabled(store.lifted == nil || store.commandTargets.isEmpty)
                Toggle("Lift & Stamp HUD\tO", isOn: $store.isLiftStampVisible)
                    .disabled(!store.isOpen)
                Button("Play Slideshow") {
                    store.startSlideshow(window: NSApp.keyWindow ?? NSApp.mainWindow)
                }
                .keyboardShortcut("s", modifiers: [.option, .shift])
                .disabled(!store.isOpen || store.items.isEmpty)
                Button("Batch Change…") { store.isBatchChangePresented = true }
                    .keyboardShortcut("b", modifiers: [.command, .shift])
                    .disabled(store.commandTargets.isEmpty)
                Divider()
                Toggle("Keywords HUD\t⇧H", isOn: $store.isKeywordsHUDVisible)
                    .disabled(!store.isOpen)
                Toggle("Show Keyword Controls\t⇧D", isOn: $store.showKeywordControls)
                    .disabled(!store.isOpen)
                Menu("Keyword Buttons") {
                    ForEach(0..<8, id: \.self) { index in
                        let name = store.keywordButtons.indices.contains(index) ? store.keywordButtons[index] : ""
                        Button(name.isEmpty ? "Button \(index + 1) (unassigned)" : name) {
                            store.pressKeywordButton(index)
                        }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .option)
                        .disabled(name.isEmpty || store.commandTargets.isEmpty)
                    }
                }
                Divider()
                Menu("Apply Snippet") {
                    ForEach(store.snippets) { snippet in
                        Button("\(snippet.name) → \(snippet.field.label)") {
                            store.applySnippet(snippet, to: Array(store.selection))
                        }
                    }
                }
                .disabled(store.selection.isEmpty || store.snippets.isEmpty)
                Button("Manage Snippets…") { store.isSnippetsEditorPresented = true }
            }
        }

        Settings {
            SettingsView()
                .environmentObject(store)
                .alterExtensionRoot(store)
        }
    }
}
