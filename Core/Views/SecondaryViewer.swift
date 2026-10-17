//
//  SecondaryViewer.swift
//  Alter
//
//  Aperture's Secondary Viewer (View ▸ Secondary Viewer): the second
//  display shows the photo — Mirror, the one in the viewer (or the
//  selection's first); Alternate, every selected photo side by side;
//  Blank, black, so a bright desktop doesn't throw off your eye. The
//  window never takes the keyboard; you keep working on the main screen.
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class SecondaryViewer: ObservableObject {
    static let shared = SecondaryViewer()

    enum Mode: String, CaseIterable, Identifiable {
        case off, mirror, alternate, blank
        var id: String { rawValue }
        var label: String {
            switch self {
            case .off: return "Off"
            case .mirror: return "Mirror"
            case .alternate: return "Alternate"
            case .blank: return "Blank"
            }
        }
    }

    @Published var mode: Mode = .off {
        didSet { if mode != oldValue { update() } }
    }
    /// There's a second display to use.
    @Published private(set) var available = NSScreen.screens.count > 1

    private weak var store: LibraryStore?
    private var window: NSWindow?
    private var screenWatch: AnyCancellable?

    private init() {
        screenWatch = NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.available = NSScreen.screens.count > 1
                    self.update()
                }
            }
    }

    func attach(_ store: LibraryStore) {
        self.store = store
    }

    /// The display that isn't the one Alter's main window is on.
    private var targetScreen: NSScreen? {
        let main = (NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible && $0 !== window })?.screen ?? NSScreen.main
        return NSScreen.screens.first { $0 != main }
    }

    private func update() {
        guard mode != .off, let store, let screen = targetScreen else {
            window?.orderOut(nil)
            window = nil
            if mode != .off, targetScreen == nil { mode = .off }
            return
        }
        let made = window ?? makeWindow(store)
        made.setFrame(screen.frame, display: true)
        made.orderFront(nil)
        window = made
    }

    private func makeWindow(_ store: LibraryStore) -> NSWindow {
        let window = SecondaryWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        window.backgroundColor = .black
        window.isOpaque = true
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces, .ignoresCycle]
        window.contentView = NSHostingView(rootView: SecondaryViewerView(viewer: self).environmentObject(store))
        return window
    }
}

/// Borderless and never key: the keyboard stays with the main window.
private final class SecondaryWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct SecondaryViewerView: View {
    @EnvironmentObject var store: LibraryStore
    @ObservedObject var viewer: SecondaryViewer

    /// What to show, in order.
    private var ids: [Int64] {
        switch viewer.mode {
        case .off, .blank:
            return []
        case .mirror:
            if let id = store.viewerPhotoID { return [id] }
            return store.items.first { store.selection.contains($0.id) }.map { [$0.id] } ?? []
        case .alternate:
            return Array(store.items.filter { store.selection.contains($0.id) }.prefix(12).map(\.id))
        }
    }

    var body: some View {
        GeometryReader { geo in
            let shown = ids
            let columns = max(1, Int(ceil(sqrt(Double(shown.count)))))
            let rows = max(1, Int(ceil(Double(shown.count) / Double(columns))))
            ZStack {
                Color(white: UserDefaults.standard.object(forKey: "viewer.background") as? Double ?? 0.08)
                    .opacity(viewer.mode == .blank ? 0 : 1)
                Color.black.opacity(viewer.mode == .blank ? 1 : 0)
                if !shown.isEmpty {
                    VStack(spacing: 8) {
                        ForEach(0..<rows, id: \.self) { r in
                            HStack(spacing: 8) {
                                ForEach(0..<columns, id: \.self) { c in
                                    let i = r * columns + c
                                    if i < shown.count {
                                        SecondaryPhoto(id: shown[i],
                                                       maxPixel: Int(max(geo.size.width / Double(columns),
                                                                         geo.size.height / Double(rows)) * 2))
                                    } else {
                                        Color.clear
                                    }
                                }
                            }
                        }
                    }
                    .padding(shown.count > 1 ? 16 : 0)
                }
            }
        }
        .ignoresSafeArea()
    }
}

private struct SecondaryPhoto: View {
    @EnvironmentObject var store: LibraryStore
    let id: Int64
    let maxPixel: Int
    @State private var image: NSImage?

    private var key: String {
        guard let item = store.item(id) else { return "\(id)" }
        return "\(id)|\(item.edits.encoded().hashValue)|\(maxPixel)"
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: key) {
            guard let item = store.item(id) else { return }
            let url = item.url, edits = item.edits, size = min(maxPixel, 6000)
            let made = await Task.detached(priority: .userInitiated) {
                ImageLoader.shared.thumbnail(for: url, edits: edits, maxPixel: size)
            }.value
            if !Task.isCancelled { image = made }
        }
    }
}
