//
//  ExportSheet.swift
//  Alter
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
//  Export options: format, size, naming preset (editable sets), metadata
//  choices, and folder-or-archive destination.
//

import AppKit
import SwiftUI

struct ExportSheet: View {
    @EnvironmentObject var store: LibraryStore
    @Environment(\.dismiss) private var dismiss

    @State private var format: ExportFormat = .jpeg
    @State private var quality: Double = 0.85
    @State private var sizeChoice: SizeChoice = .original
    @State private var customEdge = "1920"

    @State private var presets: [NamingPreset] = NamingPresets.load()
    @State private var selectedPresetID: UUID?
    @State private var isEditingPresets = false

    @State private var includeMetadata = true
    @State private var copyCameraEXIF = false
    @State private var stripGPS = true
    @State private var asArchive = false
    @State private var applyWatermark = false

    @State private var exportPresets: [ExportPreset] = ExportPresets.load()
    @State private var selectedExportPresetID: UUID?
    @State private var isNamingNewPreset = false
    @State private var newPresetName = ""

    enum SizeChoice: Hashable {
        case original, edge2048, edge1600, edge1200, custom
    }

    private var selectedPreset: NamingPreset? {
        presets.first { $0.id == selectedPresetID } ?? presets.first
    }

    private var exampleFilename: String {
        guard let item = store.exportTargets.first else { return "—" }
        let base = NamingPresets.filename(
            pattern: selectedPreset?.pattern ?? "{name}",
            item: item, sequence: 1, total: max(store.exportTargets.count, 1))
        return base + "." + format.fileExtension
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export \(store.exportTargets.count) photo\(store.exportTargets.count == 1 ? "" : "s")")
                .font(.title3.weight(.bold))

            // Saved export presets
            HStack(spacing: 8) {
                Picker("Preset", selection: $selectedExportPresetID) {
                    Text("Custom").tag(UUID?.none)
                    ForEach(exportPresets) { preset in
                        Text(preset.name).tag(Optional(preset.id))
                    }
                }
                .frame(width: 260)
                .onChange(of: selectedExportPresetID) { id in
                    if let preset = exportPresets.first(where: { $0.id == id }) {
                        apply(preset)
                    }
                }
                Button("Save Preset…") {
                    newPresetName = ""
                    isNamingNewPreset = true
                }
                if let id = selectedExportPresetID {
                    Button("Delete") {
                        exportPresets.removeAll { $0.id == id }
                        ExportPresets.save(exportPresets)
                        selectedExportPresetID = nil
                    }
                }
            }
            .alert("Save Export Preset", isPresented: $isNamingNewPreset) {
                TextField("Preset name", text: $newPresetName)
                Button("Save") { saveCurrentAsPreset() }
                Button("Cancel", role: .cancel) {}
            }

            Divider()

            // Format + quality
            HStack(spacing: 12) {
                Picker("Format", selection: $format) {
                    ForEach(ExportFormat.allCases) { candidate in
                        if candidate != .webp || ExportService.webpAvailable {
                            Text(candidate.rawValue).tag(candidate)
                        }
                    }
                }
                .frame(width: 200)

                if format.usesQuality {
                    Slider(value: $quality, in: 0.4...1.0) {
                        Text("Quality")
                    }
                    Text("\(Int(quality * 100))%")
                        .monospacedDigit()
                        .frame(width: 42, alignment: .trailing)
                }
            }
            if !ExportService.webpAvailable {
                Text("WebP needs cwebp (brew install webp).")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Size
            HStack(spacing: 8) {
                Picker("Size", selection: $sizeChoice) {
                    Text("Original size").tag(SizeChoice.original)
                    Text("2048 px long edge").tag(SizeChoice.edge2048)
                    Text("1600 px long edge").tag(SizeChoice.edge1600)
                    Text("1200 px long edge").tag(SizeChoice.edge1200)
                    Text("Custom…").tag(SizeChoice.custom)
                }
                .frame(width: 260)
                if sizeChoice == .custom {
                    TextField("px", text: $customEdge)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                    Text("px long edge").foregroundColor(.secondary)
                }
            }

            // Naming
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Picker("Name files", selection: $selectedPresetID) {
                        ForEach(presets) { preset in
                            Text(preset.name).tag(Optional(preset.id))
                        }
                    }
                    .frame(width: 280)
                    Button("Edit Presets…") { isEditingPresets = true }
                }
                Text("Example:  \(exampleFilename)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Metadata
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Include edited metadata (ALT text, title, caption, keywords, credit)", isOn: $includeMetadata)
                Toggle("Copy camera EXIF from originals", isOn: $copyCameraEXIF)
                if copyCameraEXIF {
                    Toggle("…but remove GPS locations", isOn: $stripGPS)
                        .padding(.leading, 20)
                }
                if !copyCameraEXIF {
                    Text("Exports carry no camera EXIF or GPS — clean for the web.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Toggle("Apply watermark", isOn: $applyWatermark)
                    .disabled(!Watermark.load().isConfigured)
                if !Watermark.load().isConfigured {
                    Text("Set up a watermark image in Settings → Watermark first.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Toggle("Package as archive (.zip with manifest.csv)", isOn: $asArchive)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(asArchive ? "Export Archive…" : "Export…") { chooseDestinationAndExport() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(store.exportTargets.isEmpty || store.isWorking)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            if selectedPresetID == nil { selectedPresetID = presets.first?.id }
        }
        .sheet(isPresented: $isEditingPresets) {
            NamingPresetEditor(presets: $presets, selectedID: $selectedPresetID)
        }
    }

    /// The current size choice as a pixel value (nil = original).
    private var currentMaxEdge: Int? {
        switch sizeChoice {
        case .original: return nil
        case .edge2048: return 2048
        case .edge1600: return 1600
        case .edge1200: return 1200
        case .custom: return max(16, Int(customEdge) ?? 1920)
        }
    }

    private func apply(_ preset: ExportPreset) {
        format = ExportFormat(rawValue: preset.format) ?? .jpeg
        if format == .webp && !ExportService.webpAvailable { format = .jpeg }
        quality = preset.quality
        includeMetadata = preset.includeMetadata
        copyCameraEXIF = preset.copyCameraEXIF
        stripGPS = preset.stripGPS
        asArchive = preset.asArchive
        applyWatermark = (preset.applyWatermark ?? false) && Watermark.load().isConfigured
        switch preset.maxEdge {
        case nil: sizeChoice = .original
        case 2048: sizeChoice = .edge2048
        case 1600: sizeChoice = .edge1600
        case 1200: sizeChoice = .edge1200
        case .some(let edge):
            sizeChoice = .custom
            customEdge = String(edge)
        }
        // Point the naming picker at a matching pattern, adding a transient
        // entry if the preset's pattern isn't in the saved naming sets.
        if let match = presets.first(where: { $0.pattern == preset.namingPattern }) {
            selectedPresetID = match.id
        } else {
            let transient = NamingPreset(name: "\(preset.name) (naming)", pattern: preset.namingPattern)
            presets.append(transient)
            selectedPresetID = transient.id
        }
    }

    private func saveCurrentAsPreset() {
        let name = newPresetName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let preset = ExportPreset(
            name: name,
            format: format.rawValue,
            quality: quality,
            maxEdge: currentMaxEdge,
            namingPattern: selectedPreset?.pattern ?? "{name}",
            includeMetadata: includeMetadata,
            copyCameraEXIF: copyCameraEXIF,
            stripGPS: stripGPS,
            asArchive: asArchive,
            applyWatermark: applyWatermark)
        exportPresets.append(preset)
        ExportPresets.save(exportPresets)
        selectedExportPresetID = preset.id
    }

    private func chooseDestinationAndExport() {
        let pattern = selectedPreset?.pattern ?? "{name}"
        let sizing: ExportSizing = currentMaxEdge.map { ExportSizing.maxEdge($0) } ?? .original

        if asArchive {
            let panel = NSSavePanel()
            panel.title = "Export Archive"
            panel.nameFieldStringValue = "\(store.libraryName)-export.zip"
            panel.begin { response in
                guard response == .OK, var url = panel.url else { return }
                if url.pathExtension != "zip" { url.appendPathExtension("zip") }
                FileAccess.shared.remember(url.deletingLastPathComponent())
                run(options: ExportOptions(
                    format: format, quality: quality, sizing: sizing,
                    namingPattern: pattern, includeMetadata: includeMetadata,
                    copyCameraEXIF: copyCameraEXIF, stripGPS: stripGPS,
                    applyWatermark: applyWatermark,
                    destination: url.deletingLastPathComponent(), archive: url))
            }
        } else {
            let panel = NSOpenPanel()
            panel.title = "Export To Folder"
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.prompt = "Export Here"
            panel.begin { response in
                guard response == .OK, let url = panel.url else { return }
                FileAccess.shared.remember(url)
                run(options: ExportOptions(
                    format: format, quality: quality, sizing: sizing,
                    namingPattern: pattern, includeMetadata: includeMetadata,
                    copyCameraEXIF: copyCameraEXIF, stripGPS: stripGPS,
                    applyWatermark: applyWatermark,
                    destination: url, archive: nil))
            }
        }
    }

    private func run(options: ExportOptions) {
        dismiss()
        Task { await store.export(options: options) }
    }
}

// MARK: - Preset editor

struct NamingPresetEditor: View {
    @Binding var presets: [NamingPreset]
    @Binding var selectedID: UUID?
    @Environment(\.dismiss) private var dismiss

    @State private var editingID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("File Naming Presets")
                .font(.headline)

            List(selection: $editingID) {
                ForEach($presets) { $preset in
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("Preset name", text: $preset.name)
                            .font(.body.weight(.medium))
                        TextField("Pattern", text: $preset.pattern)
                            .font(.system(.callout, design: .monospaced))
                    }
                    .padding(.vertical, 2)
                    .tag(preset.id)
                }
                .onDelete { offsets in
                    presets.remove(atOffsets: offsets)
                }
            }
            .frame(minHeight: 220)

            HStack(spacing: 8) {
                Button {
                    let preset = NamingPreset(name: "New Preset", pattern: "{name}")
                    presets.append(preset)
                    editingID = preset.id
                } label: {
                    Image(systemName: "plus")
                }
                Button {
                    if let id = editingID, let index = presets.firstIndex(where: { $0.id == id }) {
                        presets.remove(at: index)
                        editingID = nil
                    }
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(editingID == nil || presets.count <= 1)

                Spacer()
                Button("Restore Defaults") {
                    presets = NamingPresets.builtins
                    editingID = nil
                }
            }

            Text("Tokens:  {name} original filename · {seq} sequence number · {date} file date · {title} photo title")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack {
                Spacer()
                Button("Done") {
                    // Drop empty patterns, persist, keep a valid selection.
                    presets = presets.filter { !$0.pattern.trimmingCharacters(in: .whitespaces).isEmpty }
                    if presets.isEmpty { presets = NamingPresets.builtins }
                    NamingPresets.save(presets)
                    if let selectedID, !presets.contains(where: { $0.id == selectedID }) {
                        self.selectedID = presets.first?.id
                    } else if selectedID == nil {
                        selectedID = presets.first?.id
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
