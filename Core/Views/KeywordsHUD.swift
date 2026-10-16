//
//  KeywordsHUD.swift
//  Alter
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
//  Aperture's Keywords HUD (⇧H): the library's keywords in a floating
//  list — click one to put it on the selected photos (again to take it
//  off), type a new one, assign any of them to the eight keyword buttons
//  — and the keyword controls bar (⇧D): those buttons plus an entry
//  field under the viewer.
//

import SwiftUI

struct KeywordsHUD: View {
    @EnvironmentObject var store: LibraryStore

    @State private var filter = ""
    @State private var newKeyword = ""
    @State private var offset: CGSize = .zero

    private var targets: [Int64] { store.commandTargets }

    private var shown: [(name: String, count: Int)] {
        let all = store.allKeywords
        guard !filter.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HUDHeader(title: "Keywords", systemImage: "tag", offset: $offset) {
                store.isKeywordsHUDVisible = false
            }
            .padding(.horizontal, -12)
            .padding(.top, -12)

            TextField("Search keywords", text: $filter)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)

            Text(targets.isEmpty ? "Select photos to apply keywords"
                 : "Click to apply to \(targets.count) photo\(targets.count == 1 ? "" : "s") — click again to remove")
                .font(.caption2)
                .foregroundColor(.secondary)

            ScrollView {
                if !store.keywordTree.isEmpty, filter.isEmpty {
                  // Aperture's keyword library: a hierarchy (OutlineGroup
                  // needs a stack to lay its rows out in a ScrollView).
                  VStack(alignment: .leading, spacing: 1) {
                    OutlineGroup(store.keywordTree, children: \.children) { node in
                        KeywordRow(keyword: node.name, count: store.keywordCount(node.name),
                                   state: store.keywordState(node.name, in: targets),
                                   buttonIndex: store.keywordButtons.firstIndex(of: node.name),
                                   nodeID: node.id)
                    }
                    .padding(.leading, 2)
                    // Keywords in use that aren't in the library yet.
                    let known = Set(flattened(store.keywordTree).map { $0.lowercased() })
                    let loose = store.allKeywords.filter { !known.contains($0.name.lowercased()) }
                    if !loose.isEmpty {
                        Text("NOT IN LIBRARY").font(.system(size: 9, weight: .bold)).foregroundColor(.secondary).padding(.top, 6)
                        ForEach(loose, id: \.name) { entry in
                            KeywordRow(keyword: entry.name, count: entry.count,
                                       state: store.keywordState(entry.name, in: targets),
                                       buttonIndex: store.keywordButtons.firstIndex(of: entry.name),
                                       nodeID: nil)
                        }
                    }
                  }
                  .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(shown, id: \.name) { entry in
                            KeywordRow(keyword: entry.name, count: entry.count,
                                       state: store.keywordState(entry.name, in: targets),
                                       buttonIndex: store.keywordButtons.firstIndex(of: entry.name),
                                       nodeID: nil)
                        }
                    }
                }
            }
            .frame(height: 260)

            HStack(spacing: 6) {
                TextField("New keyword", text: $newKeyword)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .onSubmit(addNew)
                Button("Add", action: addNew)
                    .controlSize(.small)
                    .disabled(newKeyword.trimmingCharacters(in: .whitespaces).isEmpty)
                    .help(targets.isEmpty ? "Adds the keyword to the list" : "Adds the keyword to the selected photos")
            }
        }
        .padding(12)
        .hudChrome(width: 280)
        .offset(offset)
    }

    private func flattened(_ nodes: [KeywordNode]) -> [String] {
        nodes.flatMap { [$0.name] + flattened($0.children ?? []) }
    }

    private func addNew() {
        let keyword = newKeyword.trimmingCharacters(in: .whitespaces)
        guard !keyword.isEmpty else { return }
        if !store.keywordTree.isEmpty { store.createKeyword(named: keyword) }
        if targets.isEmpty {
            if !store.pendingKeywords.contains(where: { $0.caseInsensitiveCompare(keyword) == .orderedSame }) {
                store.pendingKeywords.append(keyword)
            }
        } else {
            store.applyKeyword(keyword, to: targets)
        }
        newKeyword = ""
    }
}

private struct KeywordRow: View {
    @EnvironmentObject var store: LibraryStore
    let keyword: String
    let count: Int
    /// true = on every target, false = on none, nil = mixed or no targets.
    let state: Bool?
    let buttonIndex: Int?
    /// Its row in the keyword hierarchy, when it has one.
    var nodeID: Int64? = nil

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: state == true ? "checkmark.square.fill" : state == nil && count >= 0 && !store.commandTargets.isEmpty ? "minus.square" : "square")
                .foregroundColor(state == true ? .accentColor : .secondary)
                .font(.caption)
                .opacity(store.commandTargets.isEmpty ? 0.3 : 1)
            Text(keyword)
                .font(.caption)
                .lineLimit(1)
            if let buttonIndex {
                Text("⌥\(buttonIndex + 1)")
                    .font(.system(size: 9, weight: .semibold).monospacedDigit())
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 4)
                    .background(Capsule().fill(Color.secondary.opacity(0.2)))
            }
            Spacer()
            Text("\(count)")
                .font(.caption2.monospacedDigit())
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !store.commandTargets.isEmpty else { return }
            store.toggleKeyword(keyword, on: store.commandTargets)
        }
        .contextMenu {
            Menu("Assign to Keyword Button") {
                ForEach(0..<8, id: \.self) { index in
                    let current = store.keywordButtons.indices.contains(index) ? store.keywordButtons[index] : ""
                    Button(current.isEmpty ? "Button \(index + 1)  (⌥\(index + 1))" : "Button \(index + 1): \(current)") {
                        store.setKeywordButton(index, keyword)
                    }
                }
            }
            if let buttonIndex {
                Button("Remove from Button \(buttonIndex + 1)") { store.setKeywordButton(buttonIndex, nil) }
            }
            if !store.commandTargets.isEmpty {
                Divider()
                Button("Apply to Selected") { store.applyKeyword(keyword, to: store.commandTargets) }
                Button("Remove from Selected") { store.removeKeyword(keyword, from: store.commandTargets) }
            }
            if let nodeID {
                Divider()
                Button("Remove from Keyword Library") { store.deleteKeywordNode(nodeID) }
            } else if !store.keywordTree.isEmpty {
                Divider()
                Button("Add to Keyword Library") { store.createKeyword(named: keyword) }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(keyword)
        .accessibilityValue(state == true ? "applied" : state == false ? "not applied" : "mixed")
        .accessibilityAddTraits(.isButton)
    }
}

/// Aperture's keyword controls: the eight buttons and an entry field.
struct KeywordControlsBar: View {
    @EnvironmentObject var store: LibraryStore
    @State private var entry = ""

    private var targets: [Int64] { store.commandTargets }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "tag")
                .foregroundColor(.secondary)
            ForEach(0..<8, id: \.self) { index in
                let name = store.keywordButtons.indices.contains(index) ? store.keywordButtons[index] : ""
                if name.isEmpty {
                    Menu {
                        ForEach(store.allKeywords, id: \.name) { entry in
                            Button(entry.name) { store.setKeywordButton(index, entry.name) }
                        }
                    } label: {
                        Text("\(index + 1)")
                            .foregroundColor(.secondary)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.bordered)
                    .fixedSize()
                    .help("Assign a keyword to button \(index + 1) (⌥\(index + 1))")
                } else {
                    Toggle(isOn: Binding(
                        get: { store.keywordState(name, in: targets) == true },
                        set: { _ in store.toggleKeyword(name, on: targets) })) {
                        Text(name).lineLimit(1)
                    }
                    .toggleStyle(.button)
                    .disabled(targets.isEmpty)
                    .help("\(name) (⌥\(index + 1)) — click to add or remove on the selection")
                    .contextMenu {
                        Button("Clear Button \(index + 1)") { store.setKeywordButton(index, nil) }
                    }
                }
            }
            TextField("Add keyword…", text: $entry)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 120, maxWidth: 200)
                .onSubmit {
                    store.applyKeyword(entry, to: targets)
                    entry = ""
                }
                .disabled(targets.isEmpty)
            Button {
                store.isKeywordsHUDVisible.toggle()
            } label: {
                Image(systemName: "list.bullet")
            }
            .help("Keywords HUD (⇧H)")
            Spacer()
        }
        .controlSize(.small)
    }
}
