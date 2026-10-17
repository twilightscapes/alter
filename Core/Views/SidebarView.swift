//
//  SidebarView.swift
//  Alter
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
//  Library sources: built-in smart views, referenced folders, and albums.
//

import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var store: LibraryStore
    @State private var newAlbumName = ""
    @State private var isNamingAlbum = false
    // Projects & folders (Aperture's containers).
    @State private var newProjectName = ""
    @State private var newProjectKind: ProjectNode.Kind = .project
    @State private var newProjectParent: Int64?
    @State private var isNamingProject = false
    @State private var renamingProject: ProjectNode?
    @State private var renameText = ""
    /// One sheet host for new + edit (two chained sheets on one node fight).
    @State private var smartAlbumSheet: SmartAlbumSheet?

    var body: some View {
        List(selection: $store.source) {
            SidebarSection("Library", id: "library") {
                Label("All Media", systemImage: "photo.on.rectangle")
                    .badge(Int(store.allCount))
                    .tag(LibrarySource.all)
                Label("No ALT Text", systemImage: "text.badge.xmark")
                    .badge(Int(store.noAltCount))
                    .tag(LibrarySource.noAltText)
                Label("Flagged", systemImage: "flag")
                    .tag(LibrarySource.flagged)
                Label("Videos", systemImage: "play.rectangle")
                    .tag(LibrarySource.videos)
                Label("Recently Added", systemImage: "clock")
                    .tag(LibrarySource.recentlyAdded)
                if let items = AlterExtensions.shared.librarySidebarItems { items(store) }
            }

            if let sections = AlterExtensions.shared.sidebarSections { sections(store) }

            SidebarSection("Projects", id: "projects") {
                OutlineGroup(store.projects, children: \.children) { node in
                    if node.kind == .album {
                        // An album inside a project (its id is negated in the tree).
                        if let album = store.albums.first(where: { $0.id == -node.id }) {
                            AlbumRowView(album: album)
                                .tag(LibrarySource.album(album.id))
                        }
                    } else {
                        ProjectRowView(node: node,
                                       onNewProject: { parent, kind in
                                           newProjectParent = parent; newProjectKind = kind
                                           newProjectName = ""; isNamingProject = true
                                       },
                                       onRename: { renamingProject = $0; renameText = $0.name })
                            .tag(LibrarySource.project(node.id))
                    }
                }
                if store.unfiledCount > 0, !store.projects.isEmpty {
                    Label("Not in a Project", systemImage: "tray")
                        .badge(Int(store.unfiledCount))
                        .foregroundColor(.secondary)
                        .help("Photos imported by folder, not filed in a project yet — drag them onto one")
                }
            } accessory: {
                Menu {
                    Button("New Project") {
                        newProjectParent = nil; newProjectKind = .project
                        newProjectName = ""; isNamingProject = true
                    }
                    Button("New Folder") {
                        newProjectParent = nil; newProjectKind = .folder
                        newProjectName = ""; isNamingProject = true
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("New Project or Folder — projects hold photos, folders hold projects")
            }

            if !store.folders.isEmpty {
                SidebarSection("Folders", id: "folders") {
                    ForEach(store.folders) { folder in
                        Label(folder.name, systemImage: "folder")
                            .tag(LibrarySource.folder(folder.id))
                            .help(folder.path)
                            .contextMenu {
                                Button("Show in Finder") {
                                    NSWorkspace.shared.activateFileViewerSelecting(
                                        [URL(fileURLWithPath: folder.path)])
                                }
                                Button("Locate / Relink Folder…") {
                                    store.relinkFolder(folder.id)
                                }
                                Button("Remove from Library", role: .destructive) {
                                    store.removeFolder(folder.id)
                                }
                            }
                    }
                }
            }

            SidebarSection("Smart Albums", id: "smartAlbums") {
                ForEach(store.smartAlbums) { album in
                    Label(album.name, systemImage: "gearshape.2")
                        .tag(LibrarySource.smartAlbum(album.id))
                        .help(album.rules.rules.isEmpty ? "Matches everything"
                              : "\(album.rules.rules.count) rule\(album.rules.rules.count == 1 ? "" : "s"), \(album.rules.matchAll ? "all" : "any") must match")
                        .contextMenu {
                            Button("Edit Rules…") { smartAlbumSheet = SmartAlbumSheet(album: album) }
                            Button("Delete Smart Album", role: .destructive) {
                                store.deleteSmartAlbum(album.id)
                            }
                        }
                }
            } accessory: {
                Button {
                    smartAlbumSheet = SmartAlbumSheet(album: nil)
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
                .help("New Smart Album — photos that match rules you set")
            }

            SidebarSection("Albums", id: "albums") {
                ForEach(store.albums.filter { $0.parentID == nil }) { album in
                    AlbumRowView(album: album)
                        .tag(LibrarySource.album(album.id))
                }
            } accessory: {
                Button {
                    isNamingAlbum = true
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
                .help("New Album")
            }
        }
        .listStyle(.sidebar)
        .background(
            Color.clear.sheet(item: $smartAlbumSheet) { sheet in
                SmartAlbumEditor(existing: sheet.album)
                    .environmentObject(store)
            }
        )
        // File ▸ New ▸ Project / Folder / Album / Smart Album land here.
        .onChange(of: store.newItemRequest) { request in
            guard let request else { return }
            store.newItemRequest = nil
            switch request {
            case .project, .folder:
                newProjectKind = request == .folder ? .folder : .project
                newProjectParent = nil
                isNamingProject = true
            case .album:
                isNamingAlbum = true
            case .smartAlbum:
                smartAlbumSheet = SmartAlbumSheet(album: nil)
            }
        }
        .alert(newProjectKind == .folder ? "New Folder" : "New Project", isPresented: $isNamingProject) {
            TextField(newProjectKind == .folder ? "Folder name" : "Project name", text: $newProjectName)
            Button("Create") {
                store.createProject(named: newProjectName.trimmingCharacters(in: .whitespaces),
                                    kind: newProjectKind, parent: newProjectParent)
                newProjectName = ""
            }
            Button("Cancel", role: .cancel) { newProjectName = "" }
        }
        .alert("Rename", isPresented: Binding(get: { renamingProject != nil },
                                                set: { if !$0 { renamingProject = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let node = renamingProject {
                    store.renameProject(node.id, to: renameText.trimmingCharacters(in: .whitespaces))
                }
                renamingProject = nil
            }
            Button("Cancel", role: .cancel) { renamingProject = nil }
        }
        .alert("New Album", isPresented: $isNamingAlbum) {
            TextField("Album name", text: $newAlbumName)
            Button("Create") {
                store.createAlbum(named: newAlbumName.trimmingCharacters(in: .whitespaces))
                newAlbumName = ""
            }
            Button("Cancel", role: .cancel) { newAlbumName = "" }
        }
    }
}

private struct SmartAlbumSheet: Identifiable {
    let id = UUID()
    let album: SmartAlbumRow?
}

/// One album row — a drop target for photos dragged from the grid.
private struct AlbumRowView: View {
    @EnvironmentObject var store: LibraryStore
    let album: AlbumRow

    @State private var isDropTargeted = false

    var body: some View {
        Label(album.name, systemImage: "rectangle.stack")
            .padding(2)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isDropTargeted ? Color.accentColor.opacity(0.25) : Color.clear)
            )
            .contextMenu {
                if !store.projects.isEmpty {
                    Menu("Move Album Into") {
                        ForEach(store.flatProjects, id: \.node.id) { entry in
                            if entry.node.kind != .album {
                                Button(String(repeating: "    ", count: entry.depth) + entry.node.name) {
                                    store.moveAlbum(album.id, toParent: entry.node.id)
                                }
                            }
                        }
                        if album.parentID != nil {
                            Divider()
                            Button("Top Level") { store.moveAlbum(album.id, toParent: nil) }
                        }
                    }
                }
                Button("Delete Album", role: .destructive) {
                    store.deleteAlbum(album.id)
                }
            }
            .dropDestination(for: String.self) { payloads, _ in
                let ids = payloads.flatMap { payload in
                    payload.split(separator: ",").compactMap { Int64($0) }
                }
                guard !ids.isEmpty else { return false }
                store.addToAlbum(album.id, photoIDs: ids)
                return true
            } isTargeted: { targeted in
                isDropTargeted = targeted
            }
    }
}


/// A project or folder in the sidebar: a drop target for photos (projects
/// only), with Aperture's New / Rename / Delete in its context menu.
private struct ProjectRowView: View {
    @EnvironmentObject var store: LibraryStore
    let node: ProjectNode
    let onNewProject: (Int64?, ProjectNode.Kind) -> Void
    let onRename: (ProjectNode) -> Void

    @State private var isDropTargeted = false

    var body: some View {
        Label(node.name, systemImage: node.kind == .folder ? "folder" : node.kind == .album ? "rectangle.stack" : "shippingbox")
            .badge(node.count)
            .padding(2)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isDropTargeted ? Color.accentColor.opacity(0.25) : Color.clear)
            )
            .contextMenu {
                if node.kind == .folder {
                    Button("New Project in “\(node.name)”") { onNewProject(node.id, .project) }
                    Button("New Folder in “\(node.name)”") { onNewProject(node.id, .folder) }
                    Divider()
                }
                Button("Rename…") { onRename(node) }
                Button(node.kind == .folder ? "Delete Folder and Contents" : "Delete Project", role: .destructive) {
                    store.deleteProject(node.id)
                }
            }
            .dropDestination(for: String.self) { payloads, _ in
                guard node.kind == .project else { return false }
                let ids = payloads.flatMap { payload in
                    payload.split(separator: ",").compactMap { Int64($0) }
                }
                guard !ids.isEmpty else { return false }
                store.moveToProject(node.id, photoIDs: ids)
                return true
            } isTargeted: { targeted in
                isDropTargeted = targeted && node.kind == .project
            }
            .help(node.kind == .folder
                  ? "\(node.count) photo\(node.count == 1 ? "" : "s") in the projects below"
                  : "\(node.count) photo\(node.count == 1 ? "" : "s") — drag photos here to move them in")
    }
}
