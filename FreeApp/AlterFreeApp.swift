//
//  AlterFreeApp.swift
//  Alter — the open-source build.
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
//  The core on its own: no extensions registered.
//

import SwiftUI

@main
struct AlterFreeApp: App {
    @StateObject private var store = LibraryStore()
    @NSApplicationDelegateAdaptor(ALTerAppDelegate.self) private var appDelegate

    var body: some Scene {
        AlterScenes(store: store)
    }
}
