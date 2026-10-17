//
//  Catalog+Places.swift
//  Alter
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
//  Where photos were taken, kept in the catalog: read from each file's GPS
//  once, carried over from Aperture, or set in Alter. One location per
//  file — a master and its versions share it, like its metadata.
//

import Foundation

extension Catalog {
    /// Place photos (nil = remove their location). Versions follow their master.
    func setLocation(photoIDs: [Int64], latitude: Double?, longitude: Double?) throws {
        for id in photoIDs {
            let master = try db.scalarInt("SELECT COALESCE(version_of, id) FROM photos WHERE id = ?", [id])
            try db.run("UPDATE photos SET latitude = ?, longitude = ?, gps_read = 1 WHERE id = ? OR version_of = ?",
                       [latitude, longitude, master, master])
            try refreshPlace(where: "id = ? OR version_of = ?", [master, master])
        }
    }

    /// Masters whose file hasn't been looked at for GPS yet.
    func photosNeedingGPS(limit: Int) throws -> [(id: Int64, url: URL)] {
        try db.query("SELECT id, path FROM photos WHERE version_of IS NULL AND gps_read = 0 LIMIT ?", [limit])
            .compactMap { row in
                guard let id = row["id"] as? Int64, let path = row["path"] as? String else { return nil }
                return (id, URL(fileURLWithPath: path))
            }
    }

    /// What a file's own GPS says. A location already in the catalog (from
    /// Aperture, or set here) wins.
    func noteFileGPS(photoID: Int64, latitude: Double?, longitude: Double?) throws {
        try db.run("""
            UPDATE photos SET
                latitude = CASE WHEN latitude IS NULL THEN ? ELSE latitude END,
                longitude = CASE WHEN latitude IS NULL THEN ? ELSE longitude END,
                gps_read = 1
            WHERE id = ? OR version_of = ?
            """, [latitude, longitude, photoID, photoID])
        try refreshPlace(where: "id = ? OR version_of = ?", [photoID, photoID])
    }

    /// Locations Aperture had for photos imported before Alter kept them
    /// (once per library): matched by the master's file.
    @discardableResult
    func backfillApertureLocations() throws -> Bool {
        guard metaValue("aperture_locations") == nil, !aperturePaths.isEmpty else { return false }
        for path in aperturePaths {
            let bundle = URL(fileURLWithPath: path)
            guard let ap = try? ApertureLibrary(bundleURL: bundle),
                  let masters = try? ap.masters(), let versions = try? ap.versions() else { continue }
            var placed = Set<String>()
            for version in versions.sorted(by: { $0.versionNumber < $1.versionNumber }) {
                guard let lat = version.latitude, let lon = version.longitude, lat != 0 || lon != 0,
                      !placed.contains(version.masterUuid), let master = masters[version.masterUuid] else { continue }
                placed.insert(version.masterUuid)
                try db.run("""
                    UPDATE photos SET latitude = ?, longitude = ?
                    WHERE path = ? AND latitude IS NULL
                    """, [lat, lon, ap.fileURL(for: master).path])
            }
        }
        try setMetaValue("aperture_locations", "1")
        try refreshPlace(where: "latitude IS NOT NULL", [])
        return true
    }

    // MARK: Place names

    /// The ~1 km cell a location falls in — the same rounding in SQL and here.
    private static let cellSQL = "printf('%.2f,%.2f', latitude, longitude)"

    /// Cells with placed photos and no name looked up yet, each with the
    /// middle of its photos (where to ask about).
    func placeCellsNeedingNames(limit: Int) throws -> [(key: String, latitude: Double, longitude: Double)] {
        try db.query("""
            SELECT \(Self.cellSQL) AS cell, AVG(latitude) AS lat, AVG(longitude) AS lon
            FROM photos
            WHERE version_of IS NULL AND latitude IS NOT NULL
              AND \(Self.cellSQL) NOT IN (SELECT key FROM place_names)
            GROUP BY cell ORDER BY COUNT(*) DESC LIMIT ?
            """, [limit]).compactMap { row in
            guard let key = row["cell"] as? String, let lat = row["lat"] as? Double, let lon = row["lon"] as? Double
            else { return nil }
            return (key, lat, lon)
        }
    }

    /// A cell's name ('' = looked up, nothing there — the sea, say).
    func savePlaceName(_ name: String, forCell key: String) throws {
        try db.run("INSERT OR REPLACE INTO place_names (key, name, looked_up) VALUES (?, ?, ?)",
                   [key, name, Date().timeIntervalSince1970])
        try db.run("UPDATE photos SET place = ? WHERE latitude IS NOT NULL AND \(Self.cellSQL) = ?", [name, key])
    }

    /// Forget every looked-up name (Settings ▸ Places ▸ Look Up Again).
    func clearPlaceNames() throws {
        try db.execute("DELETE FROM place_names; UPDATE photos SET place = '';")
    }

    /// photos.place from the cache, for rows whose location changed.
    private func refreshPlace(where condition: String, _ params: [Any?]) throws {
        try db.run("""
            UPDATE photos SET place = CASE WHEN latitude IS NULL THEN ''
                ELSE COALESCE((SELECT name FROM place_names WHERE key = \(Self.cellSQL)), '') END
            WHERE \(condition)
            """, params)
    }
}
