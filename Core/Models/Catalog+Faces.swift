//
//  Catalog+Faces.swift
//  Alter
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
//  Faces in the catalog: what the scanner found on each master, who
//  people have said each face is, and which suggestions they turned down.
//

import CoreGraphics
import Foundation

/// A face on a master, as stored.
struct FaceRecord: Identifiable, Hashable {
    let id: Int64
    let photoID: Int64
    /// Normalised to the upright master, top-left origin.
    var rect: CGRect
    /// The upright master's size when it was scanned (its aspect is what
    /// matters — for mapping through crops and rotations).
    var imageSize: CGSize
    var quality: Double
    /// SFace's 128 numbers (unit length); nil for a face too small to know.
    var print: [Float]?
    var personID: Int64?
    /// Drawn by hand (Add Missing Face).
    var manual: Bool
}

/// Someone named in Faces.
struct PersonRow: Identifiable, Hashable {
    let id: Int64
    var name: String
    var keyFaceID: Int64?
    /// Photos with this person confirmed in them.
    var photoCount: Int
}

extension Catalog {
    /// Bumped when the scanner changes enough to look again.
    static let faceScanVersion = 1

    // MARK: Scanning

    /// Masters the scanner hasn't looked at (or looked at with an older
    /// scanner), oldest first. Videos are left out.
    func photosNeedingFaceScan(limit: Int, skipping: Set<Int64>) throws -> [(id: Int64, path: String)] {
        let rows = try db.query("""
            SELECT id, path FROM photos
            WHERE version_of IS NULL AND faces_scanned < ?
            ORDER BY id LIMIT ?
            """, [Self.faceScanVersion, limit + skipping.count])
        return rows.compactMap { row -> (Int64, String)? in
            guard let id = row["id"] as? Int64, let path = row["path"] as? String, !skipping.contains(id) else { return nil }
            return (id, path)
        }.prefix(limit).map { $0 }
    }

    /// (scanned, total) masters, for progress.
    func faceScanProgress() throws -> (done: Int, total: Int) {
        let total = try db.scalarInt("SELECT COUNT(*) FROM photos WHERE version_of IS NULL")
        let done = try db.scalarInt("SELECT COUNT(*) FROM photos WHERE version_of IS NULL AND faces_scanned >= ?",
                                    [Self.faceScanVersion])
        return (Int(done), Int(total))
    }

    /// What the scanner found on one master. Faces people have named or
    /// drawn are kept; the rest are replaced.
    func saveScannedFaces(photoID: Int64, imageSize: CGSize, faces: [FaceScanner.Found]) throws {
        try db.execute("BEGIN")
        do {
            let kept = try db.query("SELECT x, y, w, h FROM faces WHERE photo_id = ? AND (person_id IS NOT NULL OR manual = 1 OR ignored = 1)",
                                    [photoID]).map(Self.rect(from:))
            try db.run("DELETE FROM faces WHERE photo_id = ? AND person_id IS NULL AND manual = 0 AND ignored = 0", [photoID])
            for face in faces where !kept.contains(where: { Self.overlap($0, face.rect) > 0.5 }) {
                try insertFace(photoID: photoID, rect: face.rect, imageSize: imageSize, quality: face.quality,
                               print: face.print, manual: false)
            }
            try db.run("UPDATE photos SET faces_scanned = ? WHERE id = ?", [Self.faceScanVersion, photoID])
            try db.execute("COMMIT")
        } catch {
            try? db.execute("ROLLBACK")
            throw error
        }
    }

    func isFaceScanned(photoID: Int64) -> Bool {
        ((try? db.scalarInt("SELECT faces_scanned FROM photos WHERE id = ?", [photoID])) ?? 0) >= Self.faceScanVersion
    }

    /// Mark a master looked at without finding anything (a video, an
    /// unreadable file).
    func markFaceScanned(photoID: Int64) throws {
        try db.run("UPDATE photos SET faces_scanned = ? WHERE id = ?", [Self.faceScanVersion, photoID])
    }

    @discardableResult
    func insertFace(photoID: Int64, rect: CGRect, imageSize: CGSize, quality: Double,
                    print: [Float]?, manual: Bool, personID: Int64? = nil) throws -> Int64 {
        try db.run("""
            INSERT INTO faces (photo_id, x, y, w, h, image_w, image_h, quality, print, manual, person_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [photoID, Double(rect.minX), Double(rect.minY), Double(rect.width), Double(rect.height),
                  Int(imageSize.width), Int(imageSize.height), quality,
                  print.map(Self.data(from:)), manual, personID])
        return db.lastInsertRowID
    }

    // MARK: Reading

    func faces(onPhoto photoID: Int64) throws -> [FaceRecord] {
        try db.query("SELECT * FROM faces WHERE photo_id = ? AND ignored = 0 ORDER BY x", [photoID])
            .compactMap(Self.face(from:))
    }

    func face(_ id: Int64) throws -> FaceRecord? {
        try db.query("SELECT * FROM faces WHERE id = ?", [id]).first.flatMap(Self.face(from:))
    }

    /// Every face Faces can work with (not ignored), for suggestions and
    /// groups. Thousands of rows of 512 bytes — fine to hold.
    func allFaces() throws -> [FaceRecord] {
        try db.query("SELECT * FROM faces WHERE ignored = 0").compactMap(Self.face(from:))
    }

    func people() throws -> [PersonRow] {
        try db.query("""
            SELECT pe.id, pe.name, pe.key_face_id,
                   (SELECT COUNT(DISTINCT f.photo_id) FROM faces f WHERE f.person_id = pe.id) AS n
            FROM people pe ORDER BY pe.name COLLATE NOCASE
            """).compactMap { row in
            guard let id = row["id"] as? Int64 else { return nil }
            return PersonRow(id: id, name: row["name"] as? String ?? "", keyFaceID: row["key_face_id"] as? Int64,
                             photoCount: Int(row["n"] as? Int64 ?? 0))
        }
    }

    /// face id → the people it's been turned down for.
    func faceRejections() throws -> [Int64: Set<Int64>] {
        var out: [Int64: Set<Int64>] = [:]
        for row in try db.query("SELECT face_id, person_id FROM face_rejections") {
            if let f = row["face_id"] as? Int64, let p = row["person_id"] as? Int64 { out[f, default: []].insert(p) }
        }
        return out
    }

    // MARK: Naming

    /// The person called `name` (case-insensitively), made if there isn't one.
    func person(named name: String) throws -> Int64 {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = try db.query("SELECT id FROM people WHERE name = ? COLLATE NOCASE", [trimmed]).first?["id"] as? Int64 {
            return id
        }
        try db.run("INSERT INTO people (name) VALUES (?)", [trimmed])
        return db.lastInsertRowID
    }

    /// Say who these faces are (nil = nobody). Returns the photos touched.
    @discardableResult
    func assignFaces(_ faceIDs: [Int64], to personID: Int64?) throws -> [Int64] {
        guard !faceIDs.isEmpty else { return [] }
        let marks = faceIDs.map { _ in "?" }.joined(separator: ",")
        let params = faceIDs.map { $0 as Any? }
        let photos = try db.query("SELECT DISTINCT photo_id FROM faces WHERE id IN (\(marks))", params)
            .compactMap { $0["photo_id"] as? Int64 }
        try db.run("UPDATE faces SET person_id = ?, ignored = 0 WHERE id IN (\(marks))", [personID] + params)
        if let personID {
            try db.run("DELETE FROM face_rejections WHERE person_id = ? AND face_id IN (\(marks))", [personID] + params)
            // The first face a person gets is their snapshot.
            try db.run("UPDATE people SET key_face_id = ? WHERE id = ? AND key_face_id IS NULL", [faceIDs[0], personID])
        }
        try dropEmptyPeople()
        try refreshPeopleColumn(photoIDs: photos)
        return photos
    }

    /// "That isn't them."
    func rejectFaces(_ faceIDs: [Int64], for personID: Int64) throws {
        for id in faceIDs {
            try db.run("INSERT OR IGNORE INTO face_rejections (face_id, person_id) VALUES (?, ?)", [id, personID])
        }
    }

    /// "Not a Face" — hidden from everything, and a rescan won't bring it back.
    @discardableResult
    func ignoreFaces(_ faceIDs: [Int64]) throws -> [Int64] {
        guard !faceIDs.isEmpty else { return [] }
        let marks = faceIDs.map { _ in "?" }.joined(separator: ",")
        let params = faceIDs.map { $0 as Any? }
        let photos = try db.query("SELECT DISTINCT photo_id FROM faces WHERE id IN (\(marks))", params)
            .compactMap { $0["photo_id"] as? Int64 }
        // A hand-drawn face just goes.
        try db.run("DELETE FROM faces WHERE manual = 1 AND id IN (\(marks))", params)
        try db.run("UPDATE faces SET ignored = 1, person_id = NULL WHERE id IN (\(marks))", params)
        try db.run("UPDATE people SET key_face_id = NULL WHERE key_face_id IN (\(marks))", params)
        try dropEmptyPeople()
        try refreshPeopleColumn(photoIDs: photos)
        return photos
    }

    func renamePerson(_ id: Int64, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Renaming onto someone who exists merges the two.
        if let other = try db.query("SELECT id FROM people WHERE name = ? COLLATE NOCASE AND id <> ?", [trimmed, id])
            .first?["id"] as? Int64 {
            try db.run("UPDATE faces SET person_id = ? WHERE person_id = ?", [other, id])
            try db.run("UPDATE OR IGNORE face_rejections SET person_id = ? WHERE person_id = ?", [other, id])
            try db.run("DELETE FROM people WHERE id = ?", [id])
            try refreshPeopleColumn(personID: other)
        } else {
            try db.run("UPDATE people SET name = ? WHERE id = ?", [trimmed, id])
            try refreshPeopleColumn(personID: id)
        }
    }

    func setKeyFace(_ faceID: Int64, for personID: Int64) throws {
        try db.run("UPDATE people SET key_face_id = ? WHERE id = ?", [faceID, personID])
    }

    /// Forget a person: their faces go back to unnamed.
    func deletePerson(_ id: Int64) throws {
        let photos = try db.query("SELECT DISTINCT photo_id FROM faces WHERE person_id = ?", [id])
            .compactMap { $0["photo_id"] as? Int64 }
        try db.run("UPDATE faces SET person_id = NULL WHERE person_id = ?", [id])
        try db.run("DELETE FROM people WHERE id = ?", [id])
        try refreshPeopleColumn(photoIDs: photos)
    }

    /// Everything Faces knows, gone (Settings ▸ Delete Face Data).
    func deleteAllFaceData() throws {
        try db.execute("""
            DELETE FROM face_rejections; DELETE FROM faces; DELETE FROM people;
            UPDATE photos SET faces_scanned = 0, people = '';
            """)
    }

    /// Look at every master again (named faces stay).
    func resetFaceScan() throws {
        try db.run("UPDATE photos SET faces_scanned = 0")
    }

    // MARK: Helpers

    private func dropEmptyPeople() throws {
        try db.run("DELETE FROM people WHERE id NOT IN (SELECT DISTINCT person_id FROM faces WHERE person_id IS NOT NULL)")
        // A snapshot that's no longer theirs.
        try db.run("""
            UPDATE people SET key_face_id = (SELECT id FROM faces WHERE person_id = people.id ORDER BY quality DESC LIMIT 1)
            WHERE key_face_id IS NULL OR key_face_id NOT IN (SELECT id FROM faces WHERE person_id = people.id)
            """)
    }

    private func refreshPeopleColumn(personID: Int64) throws {
        let photos = try db.query("SELECT DISTINCT photo_id FROM faces WHERE person_id = ?", [personID])
            .compactMap { $0["photo_id"] as? Int64 }
        try refreshPeopleColumn(photoIDs: photos)
    }

    /// photos.people = the names on each master, one per line; its
    /// versions read the same.
    private func refreshPeopleColumn(photoIDs: [Int64]) throws {
        for id in photoIDs {
            let names = try db.query("""
                SELECT DISTINCT pe.name FROM faces f JOIN people pe ON pe.id = f.person_id
                WHERE f.photo_id = ? ORDER BY f.x
                """, [id]).compactMap { $0["name"] as? String }
            try db.run("UPDATE photos SET people = ? WHERE id = ? OR version_of = ?",
                       [names.joined(separator: "\n"), id, id])
        }
    }

    private static func face(from row: [String: Any]) -> FaceRecord? {
        guard let id = row["id"] as? Int64, let photo = row["photo_id"] as? Int64 else { return nil }
        return FaceRecord(id: id, photoID: photo, rect: rect(from: row),
                          imageSize: CGSize(width: Double(row["image_w"] as? Int64 ?? 0),
                                            height: Double(row["image_h"] as? Int64 ?? 0)),
                          quality: row["quality"] as? Double ?? 0,
                          print: (row["print"] as? Data).flatMap(floats(from:)),
                          personID: row["person_id"] as? Int64,
                          manual: (row["manual"] as? Int64 ?? 0) == 1)
    }

    private static func rect(from row: [String: Any]) -> CGRect {
        CGRect(x: row["x"] as? Double ?? 0, y: row["y"] as? Double ?? 0,
               width: row["w"] as? Double ?? 0, height: row["h"] as? Double ?? 0)
    }

    /// Intersection over the smaller box.
    static func overlap(_ a: CGRect, _ b: CGRect) -> Double {
        let i = a.intersection(b)
        guard !i.isNull, !i.isEmpty else { return 0 }
        return Double(i.width * i.height) / Double(max(1e-9, min(a.width * a.height, b.width * b.height)))
    }

    static func data(from print: [Float]) -> Data {
        print.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func floats(from data: Data) -> [Float]? {
        guard data.count == FaceEmbedder.dimensions * 4 else { return nil }
        return ProtoReader.packedFloats(data)
    }
}
