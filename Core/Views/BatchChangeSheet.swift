//
//  BatchChangeSheet.swift
//  Alter
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
//  Aperture's Batch Change (⇧⌘B): one sheet that sets metadata, keywords
//  (add or replace), rating, label and flag across the selection — tick
//  what to change, leave the rest alone.
//

import SwiftUI

struct BatchChangeSheet: View {
    @EnvironmentObject var store: LibraryStore
    @Environment(\.dismiss) private var dismiss

    @State private var setTitle = false
    @State private var title = ""
    @State private var setCaption = false
    @State private var caption = ""
    @State private var setCreator = false
    @State private var creator = ""
    @State private var setCopyright = false
    @State private var copyright = ""
    @State private var setKeywords = false
    @State private var keywords = ""
    @State private var replaceKeywords = false
    @State private var setRating = false
    @State private var rating = 0
    @State private var setLabel = false
    @State private var label = 0
    @State private var setFlag = false
    @State private var flag = true

    private var targets: [Int64] { store.commandTargets }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Batch Change")
                .font(.title3.weight(.semibold))
            Text("\(targets.count) photo\(targets.count == 1 ? "" : "s") selected. Only ticked fields change.")
                .font(.callout)
                .foregroundColor(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                row("Title", on: $setTitle) { TextField("Title", text: $title) }
                row("Caption", on: $setCaption) { TextField("Caption", text: $caption, axis: .vertical).lineLimit(2...4) }
                row("Creator", on: $setCreator) { TextField("Creator / byline", text: $creator) }
                row("Copyright", on: $setCopyright) { TextField("Copyright", text: $copyright) }
                row("Keywords", on: $setKeywords) {
                    HStack {
                        TextField("comma, separated", text: $keywords)
                        Picker("", selection: $replaceKeywords) {
                            Text("Add").tag(false)
                            Text("Replace").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 130)
                        .labelsHidden()
                    }
                }
                row("Rating", on: $setRating) {
                    Picker("", selection: $rating) {
                        Text("Reject").tag(-1)
                        Text("None").tag(0)
                        ForEach(1...5, id: \.self) { Text(String(repeating: "★", count: $0)).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 140)
                }
                row("Label", on: $setLabel) {
                    LabelDots(selected: label) { label = $0 }
                }
                row("Flag", on: $setFlag) {
                    Picker("", selection: $flag) {
                        Text("Flagged").tag(true)
                        Text("Unflagged").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 160)
                    .labelsHidden()
                }
            }
            .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Apply to \(targets.count)") { apply(); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(targets.isEmpty || !(setTitle || setCaption || setCreator || setCopyright
                                                   || setKeywords || setRating || setLabel || setFlag))
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    @ViewBuilder
    private func row(_ name: String, on: Binding<Bool>, @ViewBuilder content: () -> some View) -> some View {
        GridRow {
            Toggle(name, isOn: on)
                .toggleStyle(.checkbox)
                .frame(width: 110, alignment: .leading)
            content()
                .disabled(!on.wrappedValue)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func apply() {
        let ids = targets
        let newKeywords = PhotoMetadata.splitKeywords(keywords)
        for id in ids {
            store.editMetadata(id) { meta in
                if setTitle { meta.title = title }
                if setCaption { meta.caption = caption }
                if setCreator { meta.creator = creator }
                if setCopyright { meta.copyright = copyright }
                if setKeywords {
                    if replaceKeywords {
                        meta.keywords = newKeywords
                    } else {
                        for k in newKeywords where !meta.keywords.contains(where: { $0.caseInsensitiveCompare(k) == .orderedSame }) {
                            meta.keywords.append(k)
                        }
                    }
                }
            }
        }
        if setRating { store.setRating(rating, for: ids) }
        if setLabel { store.setLabel(label, for: ids) }
        if setFlag { store.setFlagged(flag, for: ids) }
        store.reloadKeywordVocabulary()
        store.statusMessage = "Batch changed \(ids.count) photo\(ids.count == 1 ? "" : "s")."
    }
}
