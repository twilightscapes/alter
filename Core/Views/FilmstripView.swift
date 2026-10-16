//
//  FilmstripView.swift
//  Alter
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
//  The Browser strip under the viewer in Split View (Aperture-style): a
//  horizontal, resizable band of thumbnails carrying the same badges as the
//  grid. Click shows a photo in the viewer, ⌘/⇧-click multi-selects,
//  double-click goes full Viewer. Scrolls to keep the current photo in view.
//

import AppKit
import SwiftUI

struct FilmstripView: View {
    @EnvironmentObject var store: LibraryStore

    // Grid-parity album creation from the strip's context menu.
    @State private var isNamingAlbum = false
    @State private var newAlbumName = ""
    @State private var albumSeedIDs: [Int64] = []

    var body: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: true) {
                    LazyHStack(spacing: 8) {
                        ForEach(store.items) { item in
                            FilmstripCell(
                                item: item,
                                isSelected: store.selection.contains(item.id),
                                isCurrent: store.viewerPhotoID == item.id,
                                height: max(60, geo.size.height - 24))
                                .id(item.id)
                                .draggable(dragPayload(for: item))
                                .onTapGesture(count: 2) { store.enterViewer(item.id) }
                                .onTapGesture { tap(item.id) }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
                .onChange(of: store.viewerPhotoID) { id in
                    if let id {
                        withAnimation { proxy.scrollTo(id, anchor: .center) }
                    }
                }
                .onAppear {
                    if let id = store.viewerPhotoID {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .wheelScrollsHorizontally()
        .environment(\.newAlbumFromSelection) { ids in
            albumSeedIDs = ids
            newAlbumName = ""
            isNamingAlbum = true
        }
        .alert("New Album", isPresented: $isNamingAlbum) {
            TextField("Album name", text: $newAlbumName)
            Button("Create") {
                store.createAlbum(
                    named: newAlbumName.trimmingCharacters(in: .whitespaces),
                    with: albumSeedIDs)
                newAlbumName = ""
            }
            Button("Cancel", role: .cancel) { newAlbumName = "" }
        } message: {
            Text("Creates an album containing the \(albumSeedIDs.count) selected photo\(albumSeedIDs.count == 1 ? "" : "s").")
        }
    }

    /// ⌘/⇧ modifiers multi-select like the grid; a plain click also moves the
    /// viewer to that photo.
    private func tap(_ id: Int64) {
        store.handleTap(id)
        if store.selection.contains(id) {
            store.showInViewer(id)
        }
    }

    private func dragPayload(for item: PhotoItem) -> String {
        if store.selection.contains(item.id) {
            return store.selection.map(String.init).joined(separator: ",")
        }
        return String(item.id)
    }

}

struct FilmstripCell: View {
    @EnvironmentObject var store: LibraryStore
    let item: PhotoItem
    let isSelected: Bool
    let isCurrent: Bool
    let height: CGFloat

    @State private var thumbnail: NSImage?
    @State private var isMissing = false

    private var width: CGFloat { height * 4 / 3 }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .quaternaryLabelColor))
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(width: width, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else if isMissing {
                Image(systemName: "questionmark.folder")
                    .font(.system(size: 20))
                    .foregroundColor(.secondary)
                    .help("The file isn't at \(item.url.path).")
            }
            statusOverlay
            badges
        }
        .frame(width: width, height: height)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(
                    isCurrent ? Color.accentColor : (isSelected ? Color.accentColor.opacity(0.55) : Color.clear),
                    lineWidth: isCurrent ? 3 : 2)
        )
        .contextMenu { PhotoContextMenu(item: item) }
        .help(item.filename)
        .task(id: item.url.path + "#" + item.edits.cacheKey) {
            let url = item.url
            let edits = item.edits
            if thumbnail == nil {
                try? await FileLocality.ensureLocal(url)
            }
            thumbnail = await Task.detached(priority: .utility) {
                ImageLoader.shared.thumbnail(for: url, edits: edits)
            }.value
            isMissing = thumbnail == nil && !FileManager.default.fileExists(atPath: url.path)
        }
    }

    /// The grid's badges, compacted onto the thumbnail's corners.
    private var badges: some View {
        VStack {
            HStack {
                if item.dirty {
                    Circle().fill(Color.orange).frame(width: 6, height: 6)
                        .help("Edits pending write to file")
                }
                if item.isVideo {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 9))
                }
                Spacer()
                if item.flagged {
                    Image(systemName: "flag.fill")
                        .font(.system(size: 9))
                        .foregroundColor(.orange)
                }
            }
            Spacer()
            HStack(spacing: 2) {
                if item.rating > 0 {
                    ForEach(0..<item.rating, id: \.self) { _ in
                        Image(systemName: "star.fill")
                            .font(.system(size: 7))
                            .foregroundColor(.yellow)
                    }
                }
                Spacer()
                if !item.edits.isNeutral {
                    Image(systemName: "dial.medium.fill")
                        .font(.system(size: 9))
                        .foregroundColor(.accentColor)
                        .help("Has adjustments")
                }
                if !item.metadata.altText.isEmpty {
                    Text("ALT")
                        .font(.system(size: 8, weight: .bold))
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .background(Color.green.opacity(0.25))
                        .foregroundColor(.green)
                        .cornerRadius(3)
                }
            }
        }
        .padding(4)
        .shadow(color: .black.opacity(0.5), radius: 1)
    }

    @ViewBuilder
    private var statusOverlay: some View {
        switch item.status {
        case .generating, .saving, .queued:
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.35))
                ProgressView().controlSize(.small)
            }
        case .error:
            VStack {
                HStack {
                    Spacer()
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundColor(.red)
                        .padding(3)
                }
                Spacer()
            }
        default:
            EmptyView()
        }
    }
}
