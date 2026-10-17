//
//  LibraryStore+Access.swift
//  Alter
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
//  Photos the library knows about but Alter may not read (the sandboxed
//  App Store build: nothing outside what the person has handed it). Find
//  the folders they live in, ask once, and remember the answer.
//

import AppKit
import SwiftUI

extension LibraryStore {
    /// Which folders hold photos that exist but can't be read.
    func checkFileAccess() {
        guard let catalog, let paths = try? catalog.masterPaths(), !paths.isEmpty else {
            foldersNeedingAccess = []
            return
        }
        Task {
            let blocked: [URL] = await Task.detached(priority: .utility) {
                let fm = FileManager.default
                let unreadable = paths.filter { fm.fileExists(atPath: $0) && !FileAccess.canRead($0) }
                return FileAccess.foldersToAsk(for: unreadable)
            }.value
            guard self.catalog === catalog else { return }
            foldersNeedingAccess = blocked
        }
    }

    /// Ask for each folder in turn (an Open panel pointed at it).
    func requestFolderAccess() async {
        let folders = foldersNeedingAccess
        for folder in folders {
            _ = await FileAccess.shared.ask(
                for: folder,
                reason: "Alter needs permission to read the photos in “\(folder.lastPathComponent)”. Click Allow Access — or choose a folder above it to cover more.")
        }
        accessGranted()
    }

    /// File ▸ Allow Access to Folder…: grant any folder ahead of time.
    func presentAllowAccessPanel() {
        Task {
            _ = await FileAccess.shared.ask(
                for: FileAccess.realHome.appendingPathComponent("Pictures", isDirectory: true),
                reason: "Choose a folder or drive Alter may read and write — your Pictures folder, or a drive with your photos on it.")
            accessGranted()
        }
    }

    /// Access changed: retry what failed and look again.
    func accessGranted() {
        accessGeneration += 1
        reloadItems()
        checkFileAccess()
        faces.startScan()
        backfillLocationsIfNeeded()
    }
}

/// The banner over the browser when photos can't be read.
struct FileAccessBanner: View {
    @EnvironmentObject var store: LibraryStore
    @State private var asking = false

    var body: some View {
        let folders = store.foldersNeedingAccess
        if !folders.isEmpty, !store.accessPromptDismissed {
            HStack(spacing: 10) {
                Image(systemName: "lock.fill")
                    .foregroundColor(.orange)
                Text(message(folders))
                    .font(.callout)
                    .lineLimit(2)
                Spacer()
                Button("Not Now") { store.accessPromptDismissed = true }
                    .buttonStyle(.borderless)
                Button("Allow Access…") {
                    asking = true
                    Task {
                        await store.requestFolderAccess()
                        asking = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(asking)
            }
            .controlSize(.small)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.orange.opacity(0.12))
            .overlay(alignment: .bottom) { Divider() }
        }
    }

    private func message(_ folders: [URL]) -> String {
        let home = FileAccess.realHome.path
        func name(_ url: URL) -> String {
            let parent = url.deletingLastPathComponent().path
            let place = parent == home ? "your home folder"
                : parent.hasPrefix("/Volumes/") && url.deletingLastPathComponent().deletingLastPathComponent().path == "/Volumes"
                    ? url.deletingLastPathComponent().lastPathComponent : url.deletingLastPathComponent().lastPathComponent
            return "“\(url.lastPathComponent)” (in \(place))"
        }
        let first = name(folders[0])
        let more = folders.count > 1 ? " and \(folders.count - 1) other place\(folders.count == 2 ? "" : "s")" : ""
        return "Alter needs your permission to read photos in \(first)\(more)."
    }
}
