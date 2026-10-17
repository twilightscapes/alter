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

    /// macOS keeps a View menu of its own right after Edit (holding only
    /// its Enter Full Screen); Alter's View menu sits after Metadata,
    /// Aperture's place, with Full Screen (F) in it. So the system's — and
    /// only a View menu with nothing else in it — is taken out, now and
    /// whenever the menu bar is rebuilt.
    nonisolated func applicationWillFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.set(false, forKey: "NSFullScreenMenuItemEverywhere")
    }

    nonisolated func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            Self.dropSystemViewMenu()
            NotificationCenter.default.addObserver(forName: NSMenu.didAddItemNotification, object: nil,
                                                   queue: .main) { note in
                guard (note.object as? NSMenu) === NSApp.mainMenu else { return }
                Task { @MainActor in Self.dropSystemViewMenu() }
            }
        }
    }

    private static func dropSystemViewMenu() {
        guard let bar = NSApp.mainMenu else { return }
        let views = bar.items.filter { $0.title == "View" }
        guard views.count > 1 else { return }
        for item in views {
            let real = item.submenu?.items.filter { !$0.isSeparatorItem } ?? []
            let onlyFullScreen = real.allSatisfy { $0.action == #selector(NSWindow.toggleFullScreen(_:)) }
            if onlyFullScreen { bar.removeItem(item) }
        }
    }

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
        // Aperture's menu bar — see AlterMenus.swift.
        .commands { AlterMenus(store: store) }

        Settings {
            SettingsView()
                .environmentObject(store)
                .alterExtensionRoot(store)
        }
    }
}
