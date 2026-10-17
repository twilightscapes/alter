//
//  SmartAlbum.swift
//  Alter
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
//  Rule-based albums, the Aperture way: "rating at least 4 AND keyword
//  contains portrait". Rules are JSON in the catalog; evaluation runs in
//  Swift over the loaded masters — libraries are thousands of rows, not
//  millions, and this keeps every field ALTer knows about available
//  without teaching SQL each one.
//

import Foundation

struct SmartAlbumRow: Identifiable, Hashable {
    let id: Int64
    var name: String
    var rules: SmartAlbumRules
}

struct SmartAlbumRules: Codable, Hashable {
    /// true = every rule must match (AND); false = any rule (OR).
    var matchAll = true
    var rules: [SmartAlbumRule] = []

    func matches(_ item: PhotoItem) -> Bool {
        guard !rules.isEmpty else { return true }
        return matchAll ? rules.allSatisfy { $0.matches(item) }
                        : rules.contains { $0.matches(item) }
    }

    static func decode(_ json: String) -> SmartAlbumRules {
        guard let data = json.data(using: .utf8),
              let rules = try? JSONDecoder().decode(SmartAlbumRules.self, from: data)
        else { return SmartAlbumRules() }
        return rules
    }

    func encoded() -> String {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}

struct SmartAlbumRule: Codable, Hashable, Identifiable {
    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f
    }()

    var id = UUID()
    var field: Field = .rating
    var op: Op = .atLeast
    var value: String = "3"

    enum Field: String, Codable, CaseIterable, Identifiable {
        case rating, flagged, label, keyword, text, kind, hasAlt, adjusted, filename, date, fileType,
             camera, lens, iso, focalLength, person, location
        var id: String { rawValue }

        var label: String {
            switch self {
            case .date: return "Date"
            case .fileType: return "File Type"
            case .camera: return "Camera"
            case .lens: return "Lens"
            case .iso: return "ISO"
            case .focalLength: return "Focal Length (mm)"
            case .person: return "Person"
            case .location: return "Location"
            case .rating: return "Rating"
            case .flagged: return "Flagged"
            case .label: return "Color Label"
            case .keyword: return "Keyword"
            case .text: return "Any Text"
            case .kind: return "Kind"
            case .hasAlt: return "ALT Text"
            case .adjusted: return "Adjustments"
            case .filename: return "File Name"
            }
        }

        /// Which operators make sense for this field.
        var operators: [Op] {
            switch self {
            case .rating: return [.atLeast, .atMost, .is, .isNot]
            case .label: return [.is, .isNot]
            case .keyword, .text, .filename: return [.contains, .notContains]
            case .flagged, .hasAlt, .adjusted: return [.is]
            case .kind, .fileType: return [.is, .isNot]
            case .date, .iso, .focalLength: return [.atLeast, .atMost]
            case .camera, .lens: return [.contains, .notContains]
            case .person: return [.is, .isNot, .contains, .notContains]
            case .location: return [.is, .near, .contains, .notContains]
            }
        }

        /// Fixed choices for the value, when the field has them.
        var choices: [(value: String, label: String)]? {
            switch self {
            case .flagged, .hasAlt, .adjusted:
                return [("yes", "Yes"), ("no", "No")]
            case .location:
                return [("yes", "Set"), ("no", "Not Set")]
            case .kind:
                return [("photo", "Photo"), ("video", "Video"), ("gif", "Animated GIF")]
            case .label:
                return PhotoLabel.allCases.map { (String($0.rawValue), $0.name) }
            case .rating:
                return (0...5).map { (String($0), $0 == 0 ? "None" : String(repeating: "★", count: $0)) }
            case .fileType:
                return ["jpg", "heic", "png", "tif", "cr2", "cr3", "nef", "arw", "dng", "raf", "orf", "psd", "gif", "mov", "mp4"]
                    .map { ($0, $0.uppercased()) }
            case .keyword, .text, .filename, .date, .camera, .lens, .iso, .focalLength, .person:
                return nil
            }
        }
    }

    enum Op: String, Codable, CaseIterable, Identifiable {
        case `is`, isNot, atLeast, atMost, contains, notContains, near
        var id: String { rawValue }
        var label: String {
            switch self {
            case .is: return "is"
            case .isNot: return "is not"
            case .atLeast: return "is at least"
            case .atMost: return "is at most"
            case .contains: return "contains"
            case .notContains: return "does not contain"
            case .near: return "is within"
            }
        }
    }

    func matches(_ item: PhotoItem) -> Bool {
        switch field {
        case .rating:
            let want = Int(value) ?? 0
            switch op {
            case .atLeast: return item.rating >= want
            case .atMost: return item.rating <= want
            case .isNot: return item.rating != want
            default: return item.rating == want
            }
        case .flagged:
            return item.flagged == (value == "yes")
        case .hasAlt:
            return !item.metadata.altText.isEmpty == (value == "yes")
        case .adjusted:
            return !item.edits.isNeutral == (value == "yes")
        case .label:
            let want = Int(value) ?? 0
            return op == .isNot ? item.label != want : item.label == want
        case .kind:
            let kind = item.isVideo ? "video"
                : (item.url.pathExtension.lowercased() == "gif" ? "gif" : "photo")
            return op == .isNot ? kind != value : kind == value
        case .keyword:
            let hit = item.metadata.keywords.contains {
                $0.localizedCaseInsensitiveContains(value)
            }
            return op == .notContains ? !hit : hit
        case .text:
            let hit = item.matchesSearch(value)
            return op == .notContains ? !hit : hit
        case .filename:
            let hit = item.filename.localizedCaseInsensitiveContains(value)
            return op == .notContains ? !hit : hit
        case .fileType:
            let ext = item.url.pathExtension.lowercased()
            let want = value.lowercased()
            let same = ext == want || (want == "jpg" && ext == "jpeg") || (want == "tif" && ext == "tiff")
            return op == .isNot ? !same : same
        case .location:
            if op == .near {
                guard let near = NearPlace(value), let lat = item.latitude, let lon = item.longitude else { return false }
                return near.contains(latitude: lat, longitude: lon)
            }
            if op == .contains || op == .notContains {
                // The place's name: "Texas", "Paris", "Japan"…
                let hit = item.place.localizedCaseInsensitiveContains(value.trimmingCharacters(in: .whitespaces))
                return op == .notContains ? !hit : hit
            }
            return item.hasLocation == (value == "yes")
        case .person:
            // "is" = that person (by name) is in it; "contains" = any name containing it.
            let want = value.trimmingCharacters(in: .whitespaces)
            let hit = op == .is || op == .isNot
                ? item.people.contains { $0.caseInsensitiveCompare(want) == .orderedSame }
                : item.people.contains { $0.localizedCaseInsensitiveContains(want) }
            return op == .isNot || op == .notContains ? !hit : hit
        case .camera:
            let hit = item.camera.localizedCaseInsensitiveContains(value)
            return op == .notContains ? !hit : hit
        case .lens:
            let hit = item.lens.localizedCaseInsensitiveContains(value)
            return op == .notContains ? !hit : hit
        case .iso:
            guard let want = Int(value.trimmingCharacters(in: .whitespaces)), let iso = item.iso else { return false }
            return op == .atMost ? iso <= want : iso >= want
        case .focalLength:
            guard let want = Double(value.trimmingCharacters(in: .whitespaces)), let focal = item.focalLength else { return false }
            return op == .atMost ? focal <= want : focal >= want
        case .date:
            // "2010-08-21": on or after / on or before, by when it was taken
            // (the file's date if that isn't known).
            guard let day = Self.dayFormatter.date(from: value.trimmingCharacters(in: .whitespaces)) else { return true }
            let fileDate = Date(timeIntervalSince1970: item.date)
            switch op {
            case .atMost: return fileDate < day.addingTimeInterval(86_400)
            default: return fileDate >= day
            }
        }
    }
}

/// "is within 25 km of Paris": stored in the rule as "km|lat|lon|name",
/// the place looked up once when it was typed.
struct NearPlace: Equatable {
    var kilometres: Double
    var latitude: Double
    var longitude: Double
    var name: String

    init(kilometres: Double, latitude: Double, longitude: Double, name: String) {
        self.kilometres = kilometres
        self.latitude = latitude
        self.longitude = longitude
        self.name = name
    }

    init?(_ value: String) {
        let parts = value.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4, let km = Double(parts[0]), let lat = Double(parts[1]), let lon = Double(parts[2])
        else { return nil }
        self.init(kilometres: km, latitude: lat, longitude: lon, name: parts[3])
    }

    var encoded: String { "\(kilometres)|\(latitude)|\(longitude)|\(name)" }

    /// Great-circle distance, within the radius.
    func contains(latitude lat: Double, longitude lon: Double) -> Bool {
        let r = 6371.0, rad = Double.pi / 180
        let dLat = (lat - latitude) * rad, dLon = (lon - longitude) * rad
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(latitude * rad) * cos(lat * rad) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * asin(min(1, sqrt(a))) <= kilometres
    }
}
