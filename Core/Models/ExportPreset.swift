//
//  ExportPreset.swift
//  Alter
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
//  Named, saved export configurations ("Web JPEG 1600", "Client archive", …).
//  Stored app-wide as JSON.
//

import Foundation

struct ExportPreset: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var format: String            // ExportFormat.rawValue
    var quality: Double
    var maxEdge: Int?             // nil = original size
    var namingPattern: String
    var includeMetadata: Bool
    var copyCameraEXIF: Bool
    var stripGPS: Bool
    var asArchive: Bool
    var applyWatermark: Bool?
}

enum ExportPresets {
    private static let defaultsKey = "alter_export_presets"

    static func load() -> [ExportPreset] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let presets = try? JSONDecoder().decode([ExportPreset].self, from: data) else {
            return []
        }
        return presets
    }

    static func save(_ presets: [ExportPreset]) {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}
