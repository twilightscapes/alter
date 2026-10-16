//
//  NamingPreset.swift
//  Alter
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
//  Aperture-style file-naming presets for export. A preset is a pattern of
//  tokens + literal text; users can create, edit, and delete sets.
//
//  Tokens:  {name}  original filename (no extension)
//           {seq}   sequence number, zero-padded (001, 002, …)
//           {date}  file date, yyyy-MM-dd
//           {title} the photo's Title field (falls back to {name} if empty)
//

import Foundation

struct NamingPreset: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var pattern: String
}

enum NamingPresets {
    private static let defaultsKey = "alter_naming_presets"

    static let builtins: [NamingPreset] = [
        NamingPreset(name: "Original Name", pattern: "{name}"),
        NamingPreset(name: "Web", pattern: "{name}-web"),
        NamingPreset(name: "Sequenced", pattern: "{seq}-{name}"),
        NamingPreset(name: "Date + Name", pattern: "{date} {name}"),
        NamingPreset(name: "Title", pattern: "{title}"),
    ]

    static func load() -> [NamingPreset] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let presets = try? JSONDecoder().decode([NamingPreset].self, from: data),
              !presets.isEmpty else {
            return builtins
        }
        return presets
    }

    static func save(_ presets: [NamingPreset]) {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    /// Expand a pattern for one photo. `sequence` is 1-based.
    static func filename(pattern: String, item: PhotoItem, sequence: Int, total: Int) -> String {
        let baseName = item.url.deletingPathExtension().lastPathComponent

        let padWidth = max(3, String(total).count)
        let seq = String(format: "%0\(padWidth)d", sequence)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let attrs = try? FileManager.default.attributesOfItem(atPath: item.url.path)
        let date = formatter.string(from: (attrs?[.modificationDate] as? Date) ?? Date())

        let title = item.metadata.title.isEmpty ? baseName : item.metadata.title

        var out = pattern
        out = out.replacingOccurrences(of: "{name}", with: baseName)
        out = out.replacingOccurrences(of: "{seq}", with: seq)
        out = out.replacingOccurrences(of: "{date}", with: date)
        out = out.replacingOccurrences(of: "{title}", with: title)

        // Sanitize for the filesystem.
        out = out.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
        return out.isEmpty ? baseName : out
    }
}
