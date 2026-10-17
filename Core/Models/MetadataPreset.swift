//
//  MetadataPreset.swift
//  Alter
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
//  Aperture's metadata presets: a saved set of fields — creator, copyright,
//  keywords, a stock caption — applied in one go to a selection, in Batch
//  Change, or as photos come in through Import. A blank field in a preset
//  leaves a photo's own alone. (Snippets are the one-field cousin.)
//

import Foundation

struct MetadataPreset: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var title = ""
    var caption = ""
    var altText = ""
    var keywords = ""
    var creator = ""
    var copyright = ""

    /// Fill = only fields a photo has empty, keywords added. Replace = the
    /// preset's fields win, its keywords become the photo's.
    enum Mode: String, CaseIterable, Identifiable {
        case fill, replace
        var id: String { rawValue }
        var label: String { self == .fill ? "Fill Empty Fields" : "Replace" }
    }

    var isEmpty: Bool {
        [title, caption, altText, keywords, creator, copyright].allSatisfy {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// What it would do to one photo's metadata.
    func apply(to meta: inout PhotoMetadata, mode: Mode) {
        func set(_ field: WritableKeyPath<PhotoMetadata, String>, _ value: String) {
            let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return }
            if mode == .replace || meta[keyPath: field].isEmpty { meta[keyPath: field] = value }
        }
        set(\.title, title)
        set(\.caption, caption)
        set(\.altText, altText)
        set(\.creator, creator)
        set(\.copyright, copyright)
        let words = PhotoMetadata.splitKeywords(keywords)
        guard !words.isEmpty else { return }
        if mode == .replace {
            meta.keywords = words
        } else {
            for word in words where !meta.keywords.contains(where: { $0.caseInsensitiveCompare(word) == .orderedSame }) {
                meta.keywords.append(word)
            }
        }
    }

    /// A preset from what a photo already carries.
    init(name: String, from meta: PhotoMetadata) {
        self.name = name
        title = meta.title
        caption = meta.caption
        altText = meta.altText
        keywords = meta.keywords.joined(separator: ", ")
        creator = meta.creator
        copyright = meta.copyright
    }

    init(name: String) {
        self.name = name
    }
}

/// The presets, app-wide (like snippets), kept in preferences.
@MainActor
final class MetadataPresets: ObservableObject {
    static let shared = MetadataPresets()
    private static let key = "alter.metadataPresets"

    @Published var presets: [MetadataPreset] {
        didSet {
            if let data = try? JSONEncoder().encode(presets) { UserDefaults.standard.set(data, forKey: Self.key) }
        }
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([MetadataPreset].self, from: data) {
            presets = saved
        } else {
            presets = []
        }
    }
}

extension LibraryStore {
    /// Metadata ▸ Apply Metadata Preset.
    func applyMetadataPreset(_ preset: MetadataPreset, mode: MetadataPreset.Mode, to ids: [Int64]) {
        guard !ids.isEmpty else { return }
        for id in ids {
            editMetadata(id) { preset.apply(to: &$0, mode: mode) }
        }
        reloadKeywordVocabulary()
        statusMessage = "Applied “\(preset.name)” to \(ids.count) photo\(ids.count == 1 ? "" : "s")."
    }
}
