//
//  SnippetsEditor.swift
//  Alter
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
//  Manage the snippet library: name, target field, and text (with tokens).
//

import SwiftUI

struct SnippetsEditor: View {
    @EnvironmentObject var store: LibraryStore
    @Environment(\.dismiss) private var dismiss

    @State private var snippets: [Snippet] = []
    @State private var selectedID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Snippets")
                .font(.headline)
            Text("Reusable text you apply to photos — from the inspector, right-click menu, or Photo menu.")
                .font(.caption)
                .foregroundColor(.secondary)

            List(selection: $selectedID) {
                ForEach($snippets) { $snippet in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            TextField("Snippet name", text: $snippet.name)
                                .font(.body.weight(.medium))
                            Picker("", selection: $snippet.field) {
                                ForEach(SnippetField.allCases) { field in
                                    Text(field.label).tag(field)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 110)
                        }
                        TextField("Text… (tokens: {name} {date} {title})", text: $snippet.text)
                            .font(.system(.callout, design: .monospaced))
                    }
                    .padding(.vertical, 2)
                    .tag(snippet.id)
                }
                .onDelete { offsets in
                    snippets.remove(atOffsets: offsets)
                }
            }
            .frame(minHeight: 240)

            HStack(spacing: 8) {
                Button {
                    let snippet = Snippet(name: "New Snippet", field: .caption, text: "")
                    snippets.append(snippet)
                    selectedID = snippet.id
                } label: {
                    Image(systemName: "plus")
                }
                Button {
                    if let id = selectedID, let index = snippets.firstIndex(where: { $0.id == id }) {
                        snippets.remove(at: index)
                        selectedID = nil
                    }
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(selectedID == nil)

                Spacer()
                Text("Tokens:  {name} filename · {date} file date · {title} photo title")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack {
                Spacer()
                Button("Done") {
                    let cleaned = snippets.filter {
                        !$0.text.trimmingCharacters(in: .whitespaces).isEmpty
                            || !$0.name.trimmingCharacters(in: .whitespaces).isEmpty
                    }
                    store.saveSnippets(cleaned)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { snippets = store.snippets }
    }
}

/// Menu items for applying snippets — reused by the inspector, the grid's
/// context menu, and the Photo menu.
struct SnippetMenuItems: View {
    @EnvironmentObject var store: LibraryStore
    let targets: [Int64]

    var body: some View {
        if store.snippets.isEmpty {
            Text("No snippets yet")
        }
        ForEach(store.snippets) { snippet in
            Button("\(snippet.name) → \(snippet.field.label)") {
                store.applySnippet(snippet, to: targets)
            }
        }
        Divider()
        Button("Manage Snippets…") {
            store.isSnippetsEditorPresented = true
        }
    }
}
