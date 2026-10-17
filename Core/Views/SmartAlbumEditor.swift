//
//  SmartAlbumEditor.swift
//  Alter
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
//  The rules sheet for a smart album: a name, all/any, and rule rows of
//  field · operator · value. Fields with fixed choices (rating, label,
//  kind, yes/no) get a picker; free-text fields get a text field.
//

import SwiftUI

struct SmartAlbumEditor: View {
    @EnvironmentObject var store: LibraryStore
    @Environment(\.dismiss) private var dismiss

    /// nil = creating a new smart album.
    let existing: SmartAlbumRow?

    @State private var name = ""
    @State private var rules = SmartAlbumRules(rules: [SmartAlbumRule()])

    /// Live count so you can see a rule bite before saving.
    private var previewCount: Int {
        guard let catalog = store.catalog else { return 0 }
        let all = (try? catalog.photos(in: .all)) ?? []
        return all.filter { rules.matches($0) }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(existing == nil ? "New Smart Album" : "Edit Smart Album")
                .font(.title3.weight(.semibold))

            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)

            SmartRulesEditor(rules: $rules, count: previewCount)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(existing == nil ? "Create" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear {
            if let existing {
                name = existing.name
                rules = existing.rules.rules.isEmpty
                    ? SmartAlbumRules(matchAll: existing.rules.matchAll, rules: [SmartAlbumRule()])
                    : existing.rules
            }
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if let existing {
            store.updateSmartAlbum(existing.id, name: trimmed, rules: rules)
        } else {
            store.createSmartAlbum(named: trimmed, rules: rules)
        }
        dismiss()
    }
}

/// Match all/any and the rule rows (field · operator · value) — shared by
/// the smart album sheet and the Filter HUD.
struct SmartRulesEditor: View {
    @Binding var rules: SmartAlbumRules
    /// How many photos match, shown beside Add Rule.
    let count: Int
    /// The Filter HUD can run with no rules (filter off); a smart album
    /// keeps at least one.
    var allowEmpty = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                Text("Match")
                Picker("", selection: $rules.matchAll) {
                    Text("all").tag(true)
                    Text("any").tag(false)
                }
                .pickerStyle(.segmented)
                .frame(width: 110)
                .labelsHidden()
                Text("of the following rules:")
            }
            .font(.callout)

            VStack(spacing: 8) {
                ForEach($rules.rules) { $rule in
                    HStack(spacing: 8) {
                        Picker("Field", selection: $rule.field) {
                            ForEach(SmartAlbumRule.Field.allCases) { field in
                                Text(field.label).tag(field)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 130)
                        .onChange(of: rule.field) { field in
                            // Keep the operator and value legal for the new field.
                            if !field.operators.contains(rule.op) { rule.op = field.operators[0] }
                            if let choices = field.choices,
                               !choices.contains(where: { $0.value == rule.value }) {
                                rule.value = choices[0].value
                            } else if field.choices == nil, Int(rule.value) != nil {
                                rule.value = ""
                            }
                        }

                        Picker("Operator", selection: $rule.op) {
                            ForEach(rule.field.operators) { op in
                                Text(op.label).tag(op)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 140)

                        if let choices = rule.field.choices {
                            Picker("Value", selection: $rule.value) {
                                ForEach(choices, id: \.value) { choice in
                                    Text(choice.label).tag(choice.value)
                                }
                            }
                            .labelsHidden()
                            .frame(minWidth: 120)
                        } else {
                            TextField(rule.field == .date ? "yyyy-mm-dd"
                                      : rule.field == .iso ? "e.g. 800"
                                      : rule.field == .focalLength ? "e.g. 50"
                                      : rule.field == .person ? "name" : "text", text: $rule.value)
                                .textFieldStyle(.roundedBorder)
                                .frame(minWidth: 120)
                        }

                        Button {
                            rules.rules.removeAll { $0.id == rule.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                        .disabled(!allowEmpty && rules.rules.count == 1)
                        .help("Remove this rule")
                        .accessibilityLabel("Remove rule")
                    }
                }
                HStack {
                    Button {
                        rules.rules.append(SmartAlbumRule())
                    } label: {
                        Label("Add Rule", systemImage: "plus.circle")
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Text("\(count) photo\(count == 1 ? "" : "s") match")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}
