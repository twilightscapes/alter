//
//  FilterHUD.swift
//  Alter
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//

import SwiftUI

/// Aperture's Filter HUD: narrow what's showing by rules — rating, label,
/// keyword, date, camera, text… — without making a smart album. Saving
/// turns the filter into one.
struct FilterHUD: View {
    @EnvironmentObject var store: LibraryStore

    @State private var rules = SmartAlbumRules()
    @State private var albumName = ""
    @State private var isNaming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Filter")
                    .font(.headline)
                Spacer()
                Button("Clear") {
                    rules = SmartAlbumRules()
                }
                .disabled(rules.rules.isEmpty)
            }
            if rules.rules.isEmpty {
                Text("Add a rule to narrow what's showing — it works on top of the search field and Show.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    rules.rules.append(SmartAlbumRule())
                } label: {
                    Label("Add Rule", systemImage: "plus.circle")
                }
                .buttonStyle(.plain)
            } else {
                SmartRulesEditor(rules: $rules, count: store.items.count, allowEmpty: true)
                Divider()
                if isNaming {
                    HStack {
                        TextField("Smart album name", text: $albumName)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(save)
                        Button("Save", action: save)
                            .keyboardShortcut(.defaultAction)
                            .disabled(albumName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } else {
                    Button("Save as Smart Album…") { isNaming = true }
                        .help("Keep this filter as a smart album in the sidebar")
                }
            }
        }
        .padding(16)
        .frame(width: 560)
        .onAppear { rules = store.browserRules ?? SmartAlbumRules() }
        .onChange(of: rules) { store.browserRules = $0 }
    }

    private func save() {
        let name = albumName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let id = store.createSmartAlbum(named: name, rules: rules) else { return }
        rules = SmartAlbumRules()
        albumName = ""
        isNaming = false
        store.source = .smartAlbum(id)
    }
}
