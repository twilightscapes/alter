//
//  SettingsView.swift
//  Alter
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
//  The Settings window: viewer, metadata, and watermark. An extension adds
//  its own panes after these.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var store: LibraryStore
    @AppStorage("viewer.background") private var viewerBackground = 0.08
    @State private var contentHeight: CGFloat = 600

    var body: some View {
        // As tall as the settings are, up to what fits on screen; past that
        // (a long Folder Access list, Pro's panes) it scrolls.
        ScrollView(.vertical) {
            content
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: SettingsHeightKey.self, value: proxy.size.height)
                })
        }
        .onPreferenceChange(SettingsHeightKey.self) { contentHeight = $0 }
        .frame(width: 460, height: min(contentHeight, Self.maxHeight))
    }

    private static var maxHeight: CGFloat {
        (NSScreen.main?.visibleFrame.height ?? 900) - 80
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Viewer") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Background")
                        Slider(value: $viewerBackground, in: 0...0.6)
                            .accessibilityLabel("Viewer background brightness")
                        Rectangle()
                            .fill(Color(white: viewerBackground))
                            .frame(width: 28, height: 16)
                            .overlay(Rectangle().strokeBorder(Color.secondary.opacity(0.5)))
                    }
                    Text("Black to mid-grey behind the photo, as Aperture offered.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Metadata") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Write metadata into files automatically", isOn: $store.autosaveToFiles)
                    Text(store.autosaveToFiles
                         ? "ALT text, title, caption, keywords, creator, and copyright are written into your files a moment after you stop typing — along with any other photos still waiting to be saved. Revert Metadata (File menu) restores a file's as-found state."
                         : "ALT text, title, caption, keywords, creator, and copyright wait in the library until you Save to Files (⌘S).")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("Adjustments are never written into originals — they render into exports and galleries.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Faces") {
                FacesSettingsPane(faces: store.faces, models: FaceModelStore.shared)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Places") {
                PlacesSettingsPane()
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if FileAccess.isSandboxed {
                GroupBox("Folder Access") {
                    FolderAccessPane(access: FileAccess.shared)
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            GroupBox("Watermark") {
                WatermarkSettingsPane()
                    .padding(6)
            }

            if let panes = AlterExtensions.shared.settingsPanes {
                panes(store)
            }

            Text("\(AlterExtensions.shared.editionName ?? "Alter") \(AppVersion.display)")
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(20)
    }
}

private struct SettingsHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

// MARK: - Faces

struct FacesSettingsPane: View {
    @ObservedObject var faces: FacesController
    @ObservedObject var models: FaceModelStore
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Find faces in my photos", isOn: Binding(get: { faces.enabled },
                                                           set: { $0 ? faces.enable() : faces.disable() }))
            Text(models.state == .ready
                 ? "Uses \(FaceModelStore.source), on this Mac only — no photo or face leaves it. Turning this off stops looking; names stay."
                 : "Downloads \(FaceModelStore.source) once (\(FaceModelStore.downloadSize)). Everything runs on this Mac — no photo or face leaves it.")
                .font(.caption)
                .foregroundColor(.secondary)
            HStack {
                Button("Look Again") { faces.rescan() }
                    .disabled(!faces.enabled || models.state != .ready || faces.isScanning)
                    .help("Scan every photo again (names you've given stay)")
                Button("Delete Face Data…") { confirmDelete = true }
                    .help("Forget every face and name in this library, and remove the model")
            }
            .controlSize(.small)
        }
        .confirmationDialog("Delete all face data?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { faces.deleteAllData() }
        } message: {
            Text("Every face found and every name given in this library is forgotten, and the face recognition model is removed. Photos aren't touched.")
        }
    }
}

// MARK: - Folder access

/// What Alter may open (the App Store build only reads what it's given).
struct FolderAccessPane: View {
    @EnvironmentObject var store: LibraryStore
    @ObservedObject var access: FileAccess

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            let paths = access.grants.keys.sorted()
            if paths.isEmpty {
                Text("Nothing yet — libraries and folders you open are added here.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            // About six rows, then the list scrolls on its own.
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(paths, id: \.self) { path in
                        HStack {
                            Image(systemName: "folder")
                                .foregroundColor(.secondary)
                            Text(FileAccess.displayPath(path))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(path)
                            Spacer()
                            Button("Remove") { access.forget(path) }
                                .controlSize(.small)
                        }
                    }
                }
            }
            .frame(height: paths.isEmpty ? 0 : min(CGFloat(paths.count), 6) * 28)
            HStack {
                Button("Add Folder…") { store.presentAllowAccessPanel() }
                    .controlSize(.small)
                Spacer()
            }
            Text("Alter can only open what you give it. Adding your Pictures folder, or a whole drive, covers every photo in it.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Places

struct PlacesSettingsPane: View {
    @EnvironmentObject var store: LibraryStore
    @AppStorage(LibraryStore.placeNamesKey) private var lookUp = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Look up place names", isOn: $lookUp)
                .onChange(of: lookUp) { on in
                    if on { store.lookUpPlaceNamesIfNeeded() } else { store.placeNameTask?.cancel(); store.placeNameTask = nil }
                }
            Text("Names where photos were taken (\"Fort Worth, TX, United States\") for Info, search and smart albums. Asks Apple Maps about each place once, sending only the location — never a photo.")
                .font(.caption)
                .foregroundColor(.secondary)
            Button("Look Up Again") { store.relookUpPlaceNames() }
                .controlSize(.small)
                .disabled(!lookUp)
                .help("Forget the names found so far and ask again")
        }
    }
}

// MARK: - Watermark

struct WatermarkSettingsPane: View {
    @State private var settings = Watermark.load()

    private var markPreview: NSImage? {
        guard settings.isConfigured else { return nil }
        return NSImage(contentsOfFile: settings.imagePath)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Set up once, apply at will — Export and Publish Gallery each have an \"Apply watermark\" switch. Originals are never touched.")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack(spacing: 10) {
                Group {
                    if let preview = markPreview {
                        Image(nsImage: preview)
                            .resizable()
                            .scaledToFit()
                    } else {
                        Image(systemName: "photo.badge.plus")
                            .font(.title2)
                            .foregroundColor(.secondary)
                    }
                }
                .frame(width: 64, height: 44)
                .background(Color(nsColor: .quaternaryLabelColor).opacity(0.4))
                .cornerRadius(6)

                VStack(alignment: .leading, spacing: 2) {
                    Text(settings.isConfigured
                         ? URL(fileURLWithPath: settings.imagePath).lastPathComponent
                         : "No watermark image")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("PNG with transparency works best.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button("Choose Image…") { chooseImage() }
                if settings.isConfigured {
                    Button("Remove") {
                        settings.imagePath = ""
                        Watermark.save(settings)
                    }
                }
            }

            Picker("Position", selection: $settings.position) {
                ForEach(WatermarkSettings.Position.allCases) { position in
                    Text(position.label).tag(position)
                }
            }
            .frame(width: 220)

            HStack(spacing: 10) {
                Text("Size").frame(width: 50, alignment: .leading)
                Slider(value: $settings.scale, in: 0.05...0.5)
                Text("\(Int(settings.scale * 100))% of width")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundColor(.secondary)
                    .frame(width: 80, alignment: .trailing)
            }
            HStack(spacing: 10) {
                Text("Opacity").frame(width: 50, alignment: .leading)
                Slider(value: $settings.opacity, in: 0.05...1.0)
                Text("\(Int(settings.opacity * 100))%")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundColor(.secondary)
                    .frame(width: 80, alignment: .trailing)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: settings) { updated in
            Watermark.save(updated)
        }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.title = "Choose Watermark Image"
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic, .image]
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            FileAccess.shared.remember(url)
            settings.imagePath = url.path
            Watermark.save(settings)
        }
    }
}
