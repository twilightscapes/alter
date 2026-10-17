//
//  MetadataPresetsEditor.swift
//  Alter
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
//  Metadata ▸ Edit Metadata Presets…: the list on the left, the chosen
//  preset's fields on the right. Blank fields are left alone when applied.
//

import SwiftUI

struct MetadataPresetsEditor: View {
    @EnvironmentObject var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var library = MetadataPresets.shared
    @State private var selectedID: UUID?

    private var index: Int? { library.presets.firstIndex { $0.id == selectedID } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    List(selection: $selectedID) {
                        ForEach(library.presets) { preset in
                            Text(preset.name.isEmpty ? "Untitled" : preset.name).tag(preset.id)
                        }
                    }
                    Divider()
                    HStack(spacing: 4) {
                        Menu {
                            Button("New Preset") { add(MetadataPreset(name: "New Preset")) }
                            Button("New from Selected Photo") {
                                if let id = store.commandTargets.first, let item = store.item(id) {
                                    add(MetadataPreset(name: item.metadata.title.isEmpty ? "From \(item.filename)" : item.metadata.title,
                                                       from: item.metadata))
                                }
                            }
                            .disabled(store.commandTargets.isEmpty)
                        } label: {
                            Image(systemName: "plus")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("New preset — blank, or from the selected photo's metadata")
                        Button {
                            if let index { library.presets.remove(at: index); selectedID = library.presets.first?.id }
                        } label: {
                            Image(systemName: "minus")
                        }
                        .buttonStyle(.borderless)
                        .disabled(index == nil)
                        .help("Delete this preset")
                        Spacer()
                    }
                    .padding(6)
                }
                .frame(width: 190)
                Divider()
                Group {
                    if let index {
                        Form {
                            TextField("Preset name", text: $library.presets[index].name)
                            Section {
                                TextField("Title", text: $library.presets[index].title)
                                TextField("Caption", text: $library.presets[index].caption, axis: .vertical)
                                    .lineLimit(2...4)
                                TextField("ALT text", text: $library.presets[index].altText, axis: .vertical)
                                    .lineLimit(2...4)
                                TextField("Keywords", text: $library.presets[index].keywords, prompt: Text("comma, separated"))
                                TextField("Creator", text: $library.presets[index].creator)
                                TextField("Copyright", text: $library.presets[index].copyright)
                            } footer: {
                                Text("Blank fields leave a photo's own alone.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .formStyle(.grouped)
                    } else {
                        Text(library.presets.isEmpty ? "No presets yet — click + to make one." : "Choose a preset.")
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 640, height: 460)
        .onAppear { selectedID = selectedID ?? library.presets.first?.id }
    }

    private func add(_ preset: MetadataPreset) {
        library.presets.append(preset)
        selectedID = preset.id
    }
}

/// A menu of presets to apply, for Batch Change and Import.
struct MetadataPresetPicker: View {
    @ObservedObject private var library = MetadataPresets.shared
    let choose: (MetadataPreset) -> Void

    var body: some View {
        Menu("Fill from Preset") {
            ForEach(library.presets) { preset in
                Button(preset.name) { choose(preset) }
            }
            if library.presets.isEmpty {
                Text("No metadata presets yet")
            }
        }
        .fixedSize()
        .disabled(library.presets.isEmpty)
    }
}
