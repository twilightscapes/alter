//
//  AlterExtensions.swift
//  Alter
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
//  Where a separately built extension — the paid Alter — plugs into the
//  open core. The core builds and runs with nothing registered: every hook
//  defaults to "add nothing", and the app is a complete library and editor
//  on its own. An extension sets these once, before the first window.
//

import SwiftUI

/// A tab an extension adds to the inspector (beside Info and Adjust).
struct InspectorTabSpec: Identifiable {
    let id: String
    let title: String
    /// The tab's content (it reads the selection from the store).
    let content: (LibraryStore) -> AnyView
    /// True when the tab should own the whole inspector even without a
    /// single selected photo (an editor working over its own media).
    var standalone: (LibraryStore) -> Bool = { _ in false }
}

@MainActor
final class AlterExtensions {
    static let shared = AlterExtensions()
    private init() {}

    /// The extension's name in Settings ("Alter Pro"); nil = core only.
    var editionName: String?

    // MARK: Environment

    /// Wraps every root view, so an extension can inject its own state
    /// objects into the environment.
    var wrapRoot: ((AnyView, LibraryStore) -> AnyView)?

    // MARK: Menus

    /// File menu, after the import items.
    var fileMenuItems: ((LibraryStore) -> AnyView)?
    /// File menu, after Export.
    var exportMenuItems: ((LibraryStore) -> AnyView)?
    /// File menu, a group of its own after Save.
    var createMenuItems: ((LibraryStore) -> AnyView)?
    /// Top of the Media menu.
    var mediaMenuTopItems: ((LibraryStore) -> AnyView)?
    /// Undo / Redo: return true when the extension handled it.
    var undo: ((LibraryStore) -> Bool)?
    var redo: ((LibraryStore) -> Bool)?

    // MARK: Main window

    /// Toolbar buttons after the core ones.
    var toolbarItems: ((LibraryStore) -> AnyView)?
    /// Sidebar sections after Library.
    var sidebarSections: ((LibraryStore) -> AnyView)?
    /// Replaces the centre pane when it returns a view (a composer, a queue).
    var centerPane: ((LibraryStore) -> AnyView?)?
    /// Sheets the main window hosts.
    var sheets: ((LibraryStore) -> AnyView)?
    /// Inspector tabs after Info and Adjust.
    var inspectorTabs: [InspectorTabSpec] = []
    /// Called when the inspector tab changes (new tab is store.inspectorTab).
    var inspectorTabChanged: ((LibraryStore, LibraryStore.InspectorTab) -> Void)?
    /// Narrows an .extensionSource(key) to the photos it should show.
    var sourceFilter: ((String, PhotoItem) -> Bool)?

    // MARK: Photos

    /// Items at the top of a photo's context menu (grid and filmstrip).
    var photoContextMenu: ((PhotoItem, [Int64], LibraryStore) -> AnyView)?
    /// At the top of the inspector when several photos are selected.
    var batchInspectorActions: ((LibraryStore) -> AnyView)?
    /// After Export… in a photo's context menu (publish, share).
    var photoExportMenu: ((PhotoItem, [Int64], LibraryStore) -> AnyView)?
    /// Beside the caption field in Info (e.g. Generate).
    var captionAccessory: ((Int64, LibraryStore) -> AnyView)?
    /// Extra buttons in the viewer's tool strip.
    var viewerTools: ((PhotoItem, LibraryStore) -> AnyView)?
    /// Extra entries at the bottom of the Library sidebar section.
    var librarySidebarItems: ((LibraryStore) -> AnyView)?

    // MARK: Settings

    /// Settings panes after the core ones.
    var settingsPanes: ((LibraryStore) -> AnyView)?
}

extension View {
    /// Apply the registered extension's root wrapper, if any.
    @MainActor
    func alterExtensionRoot(_ store: LibraryStore) -> AnyView {
        let view = AnyView(self)
        return AlterExtensions.shared.wrapRoot?(view, store) ?? view
    }
}
