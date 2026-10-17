//
//  AlterMenus.swift
//  Alter
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
//  The menu bar, laid out as Aperture's was: File, Edit, Photos, Stacks,
//  Metadata, View, Window — Aperture's names, order and keys, read from its
//  own help. What Alter adds sits after a divider in the menu it belongs
//  to; what Aperture had and Alter doesn't (Vaults, Books, Light Tables,
//  Print) is left out rather than shown dead. An extension's commands go
//  in through AlterExtensions.menuItems.
//
//  Single-key commands (ratings, /, ⌃digits, O, H, W…) are handled by
//  KeyCommands so typing in a field never triggers them; the menus show
//  their keys after a tab.
//

import SwiftUI

struct AlterMenus: Commands {
    @ObservedObject var store: LibraryStore

    var body: some Commands {
        FileMenu(store: store)
        EditMenu(store: store)
        PhotosMenu(store: store)
        StacksMenu(store: store)
        MetadataMenu(store: store)
        ViewMenu(store: store)
        WindowMenu(store: store)
    }
}

@MainActor
private func slot(_ slot: AlterExtensions.MenuSlot, _ store: LibraryStore) -> AnyView? {
    AlterExtensions.shared.menuItems[slot].map { $0(store) }
}

// MARK: - File

private struct FileMenu: Commands {
    @ObservedObject var store: LibraryStore

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Menu("New") {
                Button("Library…") { store.presentNewLibraryPanel() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Divider()
                Group {
                    Button("Project") { store.newItemRequest = .project }
                    Button("Folder") { store.newItemRequest = .folder }
                    // Aperture's keys: ⌘L album, ⌥⌘L smart album.
                    Button("Album") { store.newItemRequest = .album }
                        .keyboardShortcut("l", modifiers: .command)
                    Button("Smart Album…") { store.newItemRequest = .smartAlbum }
                        .keyboardShortcut("l", modifiers: [.command, .option])
                }
                .disabled(!store.isOpen)
                if let items = slot(.fileNew, store) {
                    Divider()
                    items
                }
            }
            Button("Open Library…") { store.presentOpenLibraryPanel() }
                .keyboardShortcut("o", modifiers: .command)
            Button("Open Aperture Library…") { store.presentOpenApertureLibraryPanel() }
                .keyboardShortcut("o", modifiers: [.command, .option])
            Divider()
            Menu("Import") {
                Button("Files…") { store.presentImportPanel() }
                    .keyboardShortcut("i", modifiers: .command)
                Button("Photos Library…") { store.importFromPhotos() }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                if let items = slot(.fileImport, store) {
                    Divider()
                    items
                }
            }
            .disabled(!store.isOpen)
            Menu("Export") {
                Button("Versions…") { store.isExportSheetPresented = true }
                    .keyboardShortcut("e", modifiers: .command)
                    .disabled(store.items.isEmpty)
                if let items = slot(.fileExport, store) {
                    Divider()
                    items
                }
            }
            .disabled(!store.isOpen)
            if let items = slot(.fileShare, store) {
                Menu("Share") { items }
                    .disabled(!store.isOpen)
            }
            Divider()
            Button("Play Slideshow") {
                store.startSlideshow(window: NSApp.keyWindow ?? NSApp.mainWindow)
            }
            .keyboardShortcut("s", modifiers: [.option, .shift])
            .disabled(!store.isOpen || store.items.isEmpty)
            Divider()
            Button("Show in Finder") { store.showInFinder(store.commandTargets) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(store.commandTargets.isEmpty)
        }
        // Saving metadata lives with the metadata (Metadata ▸ Write to
        // Files, still ⌘S); Aperture's File menu had no Save.
        CommandGroup(replacing: .saveItem) {}
    }
}

// MARK: - Edit

private struct EditMenu: Commands {
    @ObservedObject var store: LibraryStore
    private var ext: AlterExtensions { AlterExtensions.shared }

    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            // An extension may take Undo for its own editor (Animate);
            // everything else falls through to the responder chain, so text
            // fields keep theirs.
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
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Select All Photos") { store.selectAll() }
                .keyboardShortcut("a", modifiers: .command)
                .disabled(!store.isOpen)
            Button("Deselect All") { store.deselectAll() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(store.selection.isEmpty)
            Divider()
            Button("Find") { store.focusSearch() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(!store.isOpen)
        }
    }
}

// MARK: - Photos

private struct PhotosMenu: Commands {
    @ObservedObject var store: LibraryStore

    var body: some Commands {
        CommandMenu("Photos") {
            Button(store.viewerPhotoID == nil ? "Show in Viewer" : "Back to Browser") {
                if store.viewerPhotoID != nil {
                    store.exitViewer()
                } else if let id = store.selection.first {
                    store.enterViewer(id)
                }
            }
            .keyboardShortcut("\r", modifiers: .command)
            .disabled(store.viewerPhotoID == nil && store.selection.count != 1)
            Divider()
            // The viewer's tools, by their keys.
            Group {
                tool("Crop\tC", "crop")
                tool("Straighten\tG", "straighten")
                tool("Retouch\tX", "retouch")
                tool("Red Eye\tE", "redEye")
                ForEach(AlterExtensions.shared.viewerModeTools) { spec in
                    tool(spec.title + (spec.key.map { "\t" + String($0.character).uppercased() } ?? ""), spec.id)
                }
                tool("Brush", "brush")
            }
            Menu("Add Effect") {
                ForEach(QuickBrush.allCases) { quick in
                    Button(quick.name) {
                        if let id = store.commandTargets.first { store.beginQuickBrush(quick, photoID: id) }
                    }
                }
            }
            .disabled(store.commandTargets.count != 1)
            Button("Auto Enhance") {
                Task { await store.autoEnhance(ids: Array(store.selection)) }
            }
            .keyboardShortcut("a", modifiers: [.command, .option])
            .disabled(store.selection.isEmpty)
            Divider()
            // Aperture's keys: ⌥G new version from original, ⌥V duplicate.
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
            Menu("Edit with External Editor") {
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
            if let items = slot(.photos, store) {
                Divider()
                items
            }
        }
    }

    private func tool(_ title: String, _ id: String) -> some View {
        Button(title) { store.requestViewerTool(id) }
            .disabled(!store.canUseViewerTools)
    }
}

// MARK: - Stacks

private struct StacksMenu: Commands {
    @ObservedObject var store: LibraryStore

    private var inStack: Bool { store.selectedStackID != nil }

    var body: some Commands {
        CommandMenu("Stacks") {
            Button("Auto-Stack…") { store.isAutoStackPresented = true }
                .disabled(!store.isOpen || store.items.isEmpty)
            Divider()
            Button("Stack") { store.stackSelection() }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(store.selection.count < 2)
            Button("Unstack") {
                if let stackID = store.selectedStackID { store.unstack(stackID) }
            }
            .keyboardShortcut("k", modifiers: [.command, .shift])
            .disabled(!inStack)
            Divider()
            Button("Open Stack") { store.setStackOpen(true) }
                .disabled(!inStack || store.selectedStackID.flatMap { store.stackInfo[$0]?.collapsed } == false)
            Button("Close Stack") { store.setStackOpen(false) }
                .disabled(!inStack || store.selectedStackID.flatMap { store.stackInfo[$0]?.collapsed } == true)
            Button("Open All Stacks") { store.setAllStacksOpen(true) }
                .disabled(store.stackInfo.isEmpty)
            Button("Close All Stacks") { store.setAllStacksOpen(false) }
                .disabled(store.stackInfo.isEmpty)
            Divider()
            Button("Pick") {
                if let id = store.selection.first { store.setStackPick(id) }
            }
            .keyboardShortcut("\\", modifiers: .command)
            .disabled(store.selection.count != 1 || !inStack)
            Button("Split Stack") { store.splitStack() }
                .disabled(store.selection.count != 1 || !inStack)
            Button("Extract Item") { store.extractFromStack() }
                .keyboardShortcut("k", modifiers: .option)
                .disabled(!store.selection.contains { store.item($0)?.stackID != nil })
        }
    }
}

// MARK: - Metadata

private struct MetadataMenu: Commands {
    @ObservedObject var store: LibraryStore

    private var targets: [Int64] { store.commandTargets }

    var body: some Commands {
        CommandMenu("Metadata") {
            Menu("Rating") {
                ForEach(0...5, id: \.self) { stars in
                    Button(stars == 0 ? "No Rating\t0" : String(repeating: "★", count: stars) + "\t\(stars)") {
                        store.setRating(stars, for: targets)
                    }
                }
                Button("Reject\t9") { store.setRating(-1, for: targets) }
                Divider()
                Button("Increase Rating\t=") { store.adjustRating(by: 1, for: targets) }
                Button("Decrease Rating\t−") { store.adjustRating(by: -1, for: targets) }
            }
            .disabled(targets.isEmpty)
            Button("Flag / Unflag\t/") {
                let anyUnflagged = targets.contains { !(store.item($0)?.flagged ?? true) }
                store.setFlagged(anyUnflagged, for: targets)
            }
            .disabled(targets.isEmpty)
            Menu("Color Label") {
                ForEach(PhotoLabel.allCases) { label in
                    Button("\(label.name)\t⌃\(label.rawValue)") {
                        store.setLabel(label.rawValue, for: targets)
                    }
                }
            }
            .disabled(targets.isEmpty)
            Divider()
            // Aperture's Add Keyword menu is its keyword buttons (⌥1–8).
            Menu("Add Keyword") {
                ForEach(0..<8, id: \.self) { index in
                    let name = store.keywordButtons.indices.contains(index) ? store.keywordButtons[index] : ""
                    Button(name.isEmpty ? "Button \(index + 1) (unassigned)" : name) {
                        store.pressKeywordButton(index)
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .option)
                    .disabled(name.isEmpty)
                }
            }
            .disabled(targets.isEmpty)
            Menu("Remove Keyword") {
                Button("Remove All Keywords") { store.removeAllKeywords(from: targets) }
            }
            .disabled(targets.isEmpty)
            Button("Suggest Keywords") {
                Task { await store.suggestKeywords(ids: Array(store.selection)) }
            }
            .keyboardShortcut("k", modifiers: [.command, .option])
            .disabled(store.selection.isEmpty)
            Divider()
            Button("Batch Change…") { store.isBatchChangePresented = true }
                .keyboardShortcut("b", modifiers: [.command, .shift])
                .disabled(targets.isEmpty)
            // Aperture's Lift & Stamp: ⇧⌘C lifts, ⇧⌘V stamps by the HUD's
            // checkboxes (adjustments and keywords by default).
            Button("Lift Adjustments & Metadata") { store.lift() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(targets.count != 1)
            Button("Stamp Adjustments & Metadata") { store.stamp() }
                .keyboardShortcut("v", modifiers: [.command, .shift])
                .disabled(store.lifted == nil || targets.isEmpty)
            Divider()
            Menu("Snippets") {
                ForEach(store.snippets) { snippet in
                    Button("\(snippet.name) → \(snippet.field.label)") {
                        store.applySnippet(snippet, to: Array(store.selection))
                    }
                    .disabled(store.selection.isEmpty)
                }
                if !store.snippets.isEmpty { Divider() }
                Button("Manage Snippets…") { store.isSnippetsEditorPresented = true }
            }
            if let items = slot(.metadata, store) {
                items
            }
            Divider()
            Button("Write Metadata to Files") { Task { await store.saveDirty() } }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(store.dirtyCount == 0)
            Button("Revert Metadata to As-Found…") {
                store.pendingRevertIDs = Array(store.selection)
            }
            .disabled(store.selection.isEmpty)
        }
    }
}

// MARK: - View

private struct ViewMenu: Commands {
    @ObservedObject var store: LibraryStore

    var body: some Commands {
        // Aperture's View comes after Metadata; macOS fixes its own View
        // menu after Edit, so that one stays empty (and disappears) and
        // this one takes its place.
        CommandGroup(replacing: .sidebar) {}
        CommandGroup(replacing: .toolbar) {}
        CommandMenu("View") {
            Group {
                Button("Browser") { store.viewMode = .browser }
                    .keyboardShortcut("1", modifiers: .command)
                Button("Split View") { store.viewMode = .split }
                    .keyboardShortcut("2", modifiers: .command)
                Button("Viewer") { store.viewMode = .viewer }
                    .keyboardShortcut("3", modifiers: .command)
                Button("Cycle View\tV") { store.cycleViewMode() }
                Divider()
                Button(store.isFullScreenMode ? "Exit Full Screen\tF" : "Full Screen\tF") {
                    store.toggleFullScreenMode(window: NSApp.keyWindow ?? NSApp.mainWindow)
                }
            }
            .disabled(!store.isOpen)
            Divider()
            Group {
                Button("Show Loupe\t`") { store.requestViewerTool("loupe") }
                Button("Show Original Image\tM") { store.requestViewerTool("master") }
                Button("Compare with Original") { store.requestViewerTool("compare") }
                    .keyboardShortcut("m", modifiers: .option)
            }
            .disabled(!store.canUseViewerTools)
            Group {
                Toggle("Highlight Hot & Cold Areas", isOn: $store.showHotCold)
                    .keyboardShortcut("h", modifiers: [.option, .shift])
                Toggle("Primary Only", isOn: $store.primaryOnly)
                    .keyboardShortcut("u", modifiers: .option)
            }
            .disabled(!store.isOpen)
            Divider()
            Button("Show / Hide Sidebar") {
                NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
            Button("Show / Hide Toolbar") {
                NSApp.sendAction(#selector(NSWindow.toggleToolbarShown(_:)), to: nil, from: nil)
            }
            .keyboardShortcut("t", modifiers: [.command, .option])
        }
    }
}

// MARK: - Window

private struct WindowMenu: Commands {
    @ObservedObject var store: LibraryStore

    var body: some Commands {
        CommandGroup(before: .windowList) {
            Group {
                // The inspector's tabs (W cycles them, as in Aperture).
                Button("Info Inspector") { store.inspectorTab = .info }
                Button("Adjustments Inspector") { store.inspectorTab = .adjust }
                ForEach(AlterExtensions.shared.inspectorTabs) { spec in
                    Button("\(spec.title) Inspector") { store.inspectorTab = .ext(spec.id) }
                }
                Button("Next Inspector Tab\tW") { store.cycleInspectorTab() }
                Divider()
                Button("Inspector HUD\tH") { store.isInspectorHUDVisible.toggle() }
                    .disabled(!store.isFullScreenMode)
                Toggle("Keywords HUD\t⇧H", isOn: $store.isKeywordsHUDVisible)
                Toggle("Keyword Controls\t⇧D", isOn: $store.showKeywordControls)
                Toggle("Lift & Stamp HUD\tO", isOn: $store.isLiftStampVisible)
            }
            .disabled(!store.isOpen)
            if let items = slot(.window, store) {
                Divider()
                items
            }
            Divider()
        }
    }
}
