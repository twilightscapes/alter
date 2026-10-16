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

    var body: some View {
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
        .frame(width: 460)
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
            settings.imagePath = url.path
            Watermark.save(settings)
        }
    }
}
