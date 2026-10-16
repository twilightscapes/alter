//
//  MultiViewerView.swift
//  Alter
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
//  Aperture's viewer with several photos selected: all of them (up to
//  twelve) side by side on black, the primary one outlined. Click a photo
//  to make it primary, double-click to view it alone. Primary Only (⌥U)
//  collapses back to the single viewer without touching the selection.
//

import SwiftUI

struct MultiViewerView: View {
    @EnvironmentObject var store: LibraryStore
    @AppStorage("viewer.background") private var viewerBackground = 0.08

    static let maxShown = 12

    private var shown: [PhotoItem] {
        Array(store.items.filter { store.selection.contains($0.id) }.prefix(Self.maxShown))
    }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                let items = shown
                let count = max(1, items.count)
                let cols = max(1, Int(ceil(sqrt(Double(count)))))
                let rows = max(1, Int(ceil(Double(count) / Double(cols))))
                let cellW = geo.size.width / CGFloat(cols)
                let cellH = geo.size.height / CGFloat(rows)
                ZStack(alignment: .topLeading) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        MultiViewerCell(item: item, isPrimary: store.viewerPhotoID == item.id)
                            .frame(width: cellW, height: cellH)
                            .offset(x: CGFloat(index % cols) * cellW, y: CGFloat(index / cols) * cellH)
                            .onTapGesture(count: 2) { store.enterViewer(item.id) }
                            .onTapGesture { store.showInViewer(item.id) }
                    }
                }
                .onAppear { ensurePrimary(items) }
                .onChange(of: store.selection) { _ in ensurePrimary(shown) }
            }
            tray
        }
        .background(Color(white: viewerBackground))
    }

    private func ensurePrimary(_ items: [PhotoItem]) {
        if let id = store.viewerPhotoID, items.contains(where: { $0.id == id }) { return }
        if let first = items.first { store.showInViewer(first.id) }
    }

    private var tray: some View {
        HStack(spacing: 12) {
            Button {
                store.exitViewer()
            } label: {
                Label("Grid", systemImage: "square.grid.2x2")
            }
            .help("Back to the grid (Esc)")
            if store.selection.count > Self.maxShown {
                Text("Showing \(Self.maxShown) of \(store.selection.count) selected")
                    .foregroundColor(.secondary)
            } else {
                Text("\(store.selection.count) selected")
                    .foregroundColor(.secondary)
            }
            if let id = store.viewerPhotoID, let item = store.item(id) {
                Text("Primary: \(item.filename)")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Toggle(isOn: $store.primaryOnly) {
                Label("Primary Only", systemImage: "rectangle.inset.filled")
            }
            .toggleStyle(.button)
            .help("Show only the primary photo (⌥U) — the selection stays")
        }
        .font(.callout)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

private struct MultiViewerCell: View {
    let item: PhotoItem
    let isPrimary: Bool

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(8)
        .overlay(alignment: .bottomLeading) {
            HStack(spacing: 6) {
                Text(item.filename)
                    .font(.caption)
                    .lineLimit(1)
                if item.rating > 0 {
                    Text(String(repeating: "★", count: item.rating))
                        .font(.caption2)
                        .foregroundColor(.yellow)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.black.opacity(0.55)))
            .foregroundColor(.white)
            .padding(12)
        }
        .overlay(
            Rectangle()
                .strokeBorder(isPrimary ? Color.white : Color.clear, lineWidth: 2)
                .padding(3)
        )
        .contentShape(Rectangle())
        .task(id: item.url.path + "#" + item.edits.cacheKey) {
            let url = item.url
            let edits = item.edits
            image = await Task.detached(priority: .userInitiated) {
                ImageLoader.shared.thumbnail(for: url, edits: edits, maxPixel: 1200)
            }.value
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.filename)\(isPrimary ? ", primary" : "")")
        .accessibilityAddTraits(.isButton)
    }
}
