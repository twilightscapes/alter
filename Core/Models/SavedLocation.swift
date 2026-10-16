//
//  SavedLocation.swift
//  Alter
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
//  Named, reusable GPS locations ("Studio", "Gulf Shores pier") — pick one in
//  the map editor and stamp it onto a photo or a whole selection.
//

import CoreLocation
import Foundation

struct SavedLocation: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var latitude: Double
    var longitude: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

enum SavedLocations {
    private static let defaultsKey = "alter_saved_locations"

    static func load() -> [SavedLocation] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let locations = try? JSONDecoder().decode([SavedLocation].self, from: data) else {
            return []
        }
        return locations
    }

    static func save(_ locations: [SavedLocation]) {
        guard let data = try? JSONEncoder().encode(locations) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}
