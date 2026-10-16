//
//  ApertureLibrary.swift
//  Alter
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
//  A read-only view of an Aperture 3 library bundle (.aplibrary). Opens its
//  SQLite databases in immutable mode — no journal, no lock file, nothing
//  written anywhere inside the bundle, ever. Exposes the pieces ALTer
//  translates: masters (the files), versions (the takes, with their
//  ratings/labels/flags), adjustments (decoded parameter dictionaries),
//  metadata, keywords, projects, albums, stacks, previews, and masks.
//
//  Verified against an Aperture 3.6 library; column meanings noted where
//  they were established by experiment rather than documentation.
//

import Foundation

struct ApertureLibrary {
    let bundleURL: URL
    private let library: Database     // Database/apdb/Library.apdb
    private let properties: Database  // Database/apdb/Properties.apdb

    enum OpenError: LocalizedError {
        case notAnApertureLibrary
        var errorDescription: String? {
            "That isn't an Aperture library (no Library.apdb inside the bundle)."
        }
    }

    static func isApertureLibrary(_ url: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: url.appendingPathComponent("Database/apdb/Library.apdb").path)
    }

    init(bundleURL: URL) throws {
        guard Self.isApertureLibrary(bundleURL) else { throw OpenError.notAnApertureLibrary }
        self.bundleURL = bundleURL
        let apdb = bundleURL.appendingPathComponent("Database/apdb")
        library = try Database(readOnlyPath: apdb.appendingPathComponent("Library.apdb").path)
        properties = try Database(readOnlyPath: apdb.appendingPathComponent("Properties.apdb").path)
    }

    /// "Aperture Library 3.6" from the bundle's Info.plist, if present.
    var formatDescription: String {
        let info = NSDictionary(contentsOf: bundleURL.appendingPathComponent("Info.plist"))
        return info?["CFBundleGetInfoString"] as? String ?? "Aperture Library"
    }

    // MARK: - Masters

    struct Master {
        let uuid: String
        let modelId: Int64
        /// Relative to <bundle>/Masters for managed files.
        let imagePath: String
        let fileName: String
        let isReferenced: Bool
        let isMissing: Bool
        /// Seconds since 2001-01-01 (Core Data epoch).
        let imageDate: Double?
    }

    func masters() throws -> [String: Master] {
        var out: [String: Master] = [:]
        for row in try library.query("""
            SELECT uuid, modelId, imagePath, fileName, fileIsReference, isMissing, imageDate
            FROM RKMaster WHERE isInTrash = 0
            """) {
            guard let uuid = row["uuid"] as? String else { continue }
            out[uuid] = Master(
                uuid: uuid,
                modelId: row["modelId"] as? Int64 ?? 0,
                imagePath: row["imagePath"] as? String ?? "",
                fileName: row["fileName"] as? String ?? "",
                isReferenced: (row["fileIsReference"] as? Int64 ?? 0) == 1,
                isMissing: (row["isMissing"] as? Int64 ?? 0) == 1,
                imageDate: row["imageDate"] as? Double)
        }
        return out
    }

    /// Where a master's file actually is. Managed masters live under
    /// Masters/; referenced ones carry a path that may or may not resolve.
    func fileURL(for master: Master) -> URL {
        if master.isReferenced, master.imagePath.hasPrefix("/") {
            return URL(fileURLWithPath: master.imagePath)
        }
        return bundleURL.appendingPathComponent("Masters").appendingPathComponent(master.imagePath)
    }

    // MARK: - Versions

    struct Version {
        let uuid: String
        let modelId: Int64
        let masterUuid: String
        /// 0 = the hidden original Aperture keeps per master (never shown,
        /// never adjusted); 1 = the working version; 2+ = extra versions.
        let versionNumber: Int
        let name: String
        let rating: Int
        let isFlagged: Bool
        /// Aperture's label index: -1 none, 1 red … 7 gray (same order as
        /// PhotoLabel).
        let colorLabelIndex: Int
        /// Degrees CLOCKWISE applied to the master (established by
        /// correlating previews: 270 matched a counter-clockwise quarter).
        let rotation: Int
        let stackUuid: String?
        let projectUuid: String?
        let masterWidth: Int
        let masterHeight: Int
        let hasEnabledAdjustments: Bool
        let latitude: Double?
        let longitude: Double?
    }

    /// Visible, untrashed versions (the hidden originals are excluded).
    func versions() throws -> [Version] {
        try library.query("""
            SELECT uuid, modelId, masterUuid, versionNumber, name, mainRating, isFlagged,
                   colorLabelIndex, rotation, stackUuid, projectUuid, masterWidth, masterHeight,
                   hasEnabledAdjustments, exifLatitude, exifLongitude
            FROM RKVersion
            WHERE isInTrash = 0 AND isOriginal = 0 AND showInLibrary = 1
            ORDER BY masterUuid, versionNumber
            """).compactMap { row in
            guard let uuid = row["uuid"] as? String, let master = row["masterUuid"] as? String
            else { return nil }
            return Version(
                uuid: uuid,
                modelId: row["modelId"] as? Int64 ?? 0,
                masterUuid: master,
                versionNumber: Int(row["versionNumber"] as? Int64 ?? 1),
                name: row["name"] as? String ?? "",
                rating: max(0, Int(row["mainRating"] as? Int64 ?? 0)),
                isFlagged: (row["isFlagged"] as? Int64 ?? 0) == 1,
                colorLabelIndex: Int(row["colorLabelIndex"] as? Int64 ?? -1),
                rotation: Int(row["rotation"] as? Int64 ?? 0),
                stackUuid: row["stackUuid"] as? String,
                projectUuid: row["projectUuid"] as? String,
                masterWidth: Int(row["masterWidth"] as? Int64 ?? 0),
                masterHeight: Int(row["masterHeight"] as? Int64 ?? 0),
                hasEnabledAdjustments: (row["hasEnabledAdjustments"] as? Int64 ?? 0) == 1,
                latitude: row["exifLatitude"] as? Double,
                longitude: row["exifLongitude"] as? Double)
        }
    }

    // MARK: - Adjustments

    struct Adjustment {
        /// Aperture's operation identifier, e.g. "RKExposureOperation".
        let name: String
        let isEnabled: Bool
        /// Set when the adjustment was brushed in — a mask file exists.
        let maskUuid: String?
        /// The decoded `inputKeys` dictionary (plain Swift values).
        let parameters: [String: Any]
    }

    /// Enabled adjustments for one version, in Aperture's application order.
    func adjustments(forVersion uuid: String) throws -> [Adjustment] {
        try library.query("""
            SELECT name, isEnabled, maskUuid, data FROM RKImageAdjustment
            WHERE versionUuid = ? ORDER BY adjIndex, modelId
            """, [uuid]).compactMap { row in
            guard let name = row["name"] as? String, let data = row["data"] as? Data else { return nil }
            let enabled = (row["isEnabled"] as? Int64 ?? 0) == 1
            guard enabled else { return nil }
            let root = (try? KeyedArchive.unwrap(data)) as? [String: Any]
            let params = root?["inputKeys"] as? [String: Any] ?? [:]
            return Adjustment(name: name, isEnabled: enabled,
                              maskUuid: row["maskUuid"] as? String, parameters: params)
        }
    }

    /// The mask TIFF for a brushed adjustment: Masks/<x>/<xx>/<uuid>.tiff,
    /// where x is the uuid's first character lowercased.
    func maskURL(for maskUuid: String) -> URL? {
        let lower = maskUuid.lowercased()
        let a = String(lower.prefix(1)), ab = String(lower.prefix(2))
        let url = bundleURL.appendingPathComponent("Masks/\(a)/\(ab)/\(maskUuid).tiff")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - Metadata (Properties.apdb)

    struct Metadata {
        var title = ""
        var caption = ""
        var creator = ""
        var copyright = ""
        var keywords: [String] = []
    }

    /// IPTC fields per version id (ObjectName → title, Caption/Abstract →
    /// caption, Byline → creator, CopyrightNotice → copyright).
    func metadataByVersionId() throws -> [Int64: Metadata] {
        var out: [Int64: Metadata] = [:]
        let rows = try properties.query("""
            SELECT p.versionId AS v, p.propertyKey AS k, s.stringProperty AS s
            FROM RKIptcProperty p JOIN RKUniqueString s ON s.modelId = p.stringId
            WHERE p.propertyKey IN ('ObjectName', 'Caption/Abstract', 'Byline', 'CopyrightNotice')
            """)
        for row in rows {
            guard let v = row["v"] as? Int64, let k = row["k"] as? String,
                  let s = row["s"] as? String else { continue }
            var m = out[v] ?? Metadata()
            switch k {
            case "ObjectName": m.title = s
            case "Caption/Abstract": m.caption = s
            case "Byline": m.creator = s
            case "CopyrightNotice": m.copyright = s
            default: break
            }
            out[v] = m
        }
        // Keywords come from the keyword tables (hierarchical; leaf names).
        for row in try library.query("""
            SELECT kv.versionId AS v, k.name AS name
            FROM RKKeywordForVersion kv JOIN RKKeyword k ON k.modelId = kv.keywordId
            """) {
            guard let v = row["v"] as? Int64, let name = row["name"] as? String, !name.isEmpty
            else { continue }
            var m = out[v] ?? Metadata()
            if !m.keywords.contains(name) { m.keywords.append(name) }
            out[v] = m
        }
        return out
    }

    /// Camera EXIF per version id (Properties.apdb): make/model, lens,
    /// ISO, focal length, aperture, shutter.
    func cameraInfoByVersionId() throws -> [Int64: Catalog.CameraInfo] {
        var out: [Int64: Catalog.CameraInfo] = [:]
        var makes: [Int64: String] = [:]
        for row in try properties.query("""
            SELECT p.versionId AS v, p.propertyKey AS k, s.stringProperty AS s
            FROM RKExifStringProperty p JOIN RKUniqueString s ON s.modelId = p.stringId
            WHERE p.propertyKey IN ('Make', 'Model', 'LensModel')
            """) {
            guard let v = row["v"] as? Int64, let k = row["k"] as? String, let str = row["s"] as? String else { continue }
            var info = out[v] ?? Catalog.CameraInfo()
            switch k {
            case "Make": makes[v] = str.trimmingCharacters(in: .whitespaces)
            case "Model": info.camera = str.trimmingCharacters(in: .whitespaces)
            case "LensModel": info.lens = str.trimmingCharacters(in: .whitespaces)
            default: break
            }
            out[v] = info
        }
        for (v, make) in makes {
            var info = out[v] ?? Catalog.CameraInfo()
            if !info.camera.isEmpty, !info.camera.localizedCaseInsensitiveContains(make) {
                info.camera = "\(make) \(info.camera)"
            } else if info.camera.isEmpty {
                info.camera = make
            }
            out[v] = info
        }
        for row in try properties.query("""
            SELECT versionId AS v, propertyKey AS k, numberProperty AS n FROM RKExifNumberProperty
            WHERE propertyKey IN ('ISOSpeedRating', 'FocalLength', 'ApertureValue', 'ShutterSpeed')
            """) {
            guard let v = row["v"] as? Int64, let k = row["k"] as? String else { continue }
            let n: Double? = (row["n"] as? Double) ?? (row["n"] as? Int64).map(Double.init)
            guard let n else { continue }
            var info = out[v] ?? Catalog.CameraInfo()
            switch k {
            case "ISOSpeedRating": info.iso = Int(n)
            case "FocalLength": info.focalLength = n
            case "ApertureValue": info.aperture = n
            // Aperture stores the denominator for fractions (15 → 1/15 s)
            // and whole seconds when ≥ 1 is unlikely; treat > 1 as 1/n.
            case "ShutterSpeed": info.shutter = n > 1 ? 1 / n : n
            default: break
            }
            out[v] = info
        }
        return out
    }

    // MARK: - Projects, folders, albums

    struct Project {
        let uuid: String
        let name: String
        /// Enclosing user folders, outermost first (system roots dropped).
        let folderPath: [String]
    }

    func projects() throws -> [Project] {
        var byUuid: [String: (name: String, parent: String?, type: Int)] = [:]
        for row in try library.query(
            "SELECT uuid, name, parentFolderUuid, folderType FROM RKFolder WHERE isInTrash = 0") {
            guard let uuid = row["uuid"] as? String else { continue }
            byUuid[uuid] = (row["name"] as? String ?? "", row["parentFolderUuid"] as? String,
                            Int(row["folderType"] as? Int64 ?? 1))
        }
        let systemNames: Set<String> = ["", "Projects", "PublishedProjects", "TopLevelAlbums"]
        // Aperture's auto-import folders ("01", "03", "20110103-024122")
        // are bookkeeping, not organisation a person made.
        func isAutoFolder(_ name: String) -> Bool {
            let digits = name.filter(\.isNumber).count
            if name.count == 2, digits == 2 { return true }
            return name.count == 15 && digits == 14 && name.dropFirst(8).first == "-"
        }
        return byUuid.compactMap { uuid, f in
            guard f.type == 2 else { return nil }
            var path: [String] = []
            var cursor = f.parent
            var hops = 0
            while let p = cursor, let folder = byUuid[p], hops < 16 {
                if !systemNames.contains(folder.name), !isAutoFolder(folder.name) {
                    path.insert(folder.name, at: 0)
                }
                cursor = folder.parent
                hops += 1
            }
            return Project(uuid: uuid, name: f.name, folderPath: path)
        }
        .sorted { ($0.folderPath + [$0.name]).joined(separator: "/")
            < ($1.folderPath + [$1.name]).joined(separator: "/") }
    }

    struct Album {
        let modelId: Int64
        let name: String
        /// 2 = smart album (rules in `smartRules`), otherwise a plain album.
        let subclass: Int
        let versionIds: [Int64]
        /// Decoded query for smart albums.
        let smartQuery: [String: Any]?
        /// The project or folder it lives in (RKFolder uuid), if any.
        let folderUuid: String?
    }

    /// Aperture's keyword library: name + parent (modelId), hierarchical.
    struct KeywordEntry {
        let id: Int64
        let name: String
        let parentId: Int64?
    }

    func keywordLibrary() throws -> [KeywordEntry] {
        try library.query("SELECT modelId, name, parentId FROM RKKeyword ORDER BY parentId, name").compactMap { row in
            guard let id = row["modelId"] as? Int64, let name = row["name"] as? String, !name.isEmpty else { return nil }
            let parent = row["parentId"] as? Int64
            return KeywordEntry(id: id, name: name, parentId: (parent ?? 0) == 0 ? nil : parent)
        }
    }

    /// User albums (the per-folder implicit albums and Aperture's magic
    /// albums — Trash, Flagged, Last Import — are not albums to a person).
    func albums() throws -> [Album] {
        var out: [Album] = []
        for row in try library.query("""
            SELECT modelId, name, albumSubclass, queryData, folderUuid FROM RKAlbum
            WHERE isMagic = 0 AND isInTrash = 0 AND name IS NOT NULL
              AND name != 'Album.implicitAlbum'
            ORDER BY name COLLATE NOCASE
            """) {
            guard let id = row["modelId"] as? Int64, let name = row["name"] as? String else { continue }
            let members = try library.query(
                "SELECT versionId FROM RKAlbumVersion WHERE albumId = ?", [id])
                .compactMap { $0["versionId"] as? Int64 }
            var query: [String: Any]?
            if let data = row["queryData"] as? Data {
                query = (try? KeyedArchive.unwrap(data)) as? [String: Any]
            }
            out.append(Album(modelId: id, name: name,
                             subclass: Int(row["albumSubclass"] as? Int64 ?? 1),
                             versionIds: members, smartQuery: query,
                             folderUuid: row["folderUuid"] as? String))
        }
        return out
    }

    // MARK: - Stacks

    struct Stack {
        let uuid: String
        /// Version uuids in stack order.
        let versionUuids: [String]
        /// The library-wide pick, if Aperture recorded one.
        let pickVersionUuid: String?
    }

    func stacks() throws -> [Stack] {
        var members: [String: [(Int, String)]] = [:]
        for row in try library.query(
            "SELECT stackUuid, orderNumber, versionUuid FROM RKStackContent") {
            guard let s = row["stackUuid"] as? String, let v = row["versionUuid"] as? String
            else { continue }
            members[s, default: []].append((Int(row["orderNumber"] as? Int64 ?? 0), v))
        }
        var picks: [String: String] = [:]
        for row in try library.query(
            "SELECT stackUuid, albumPick FROM RKStackState WHERE albumUuid = 'allProjectsAlbum'") {
            if let s = row["stackUuid"] as? String, let p = row["albumPick"] as? String { picks[s] = p }
        }
        return members.map { uuid, list in
            Stack(uuid: uuid,
                  versionUuids: list.sorted { $0.0 < $1.0 }.map(\.1),
                  pickVersionUuid: picks[uuid])
        }
    }

    // MARK: - Previews

    /// Aperture's rendered JPEG for a version (adjustments baked in):
    /// Previews/<master's dir>/<versionUuid>/<name>.jpg — thumb_ files
    /// are the small variants.
    func previewURL(for version: Version, master: Master) -> URL? {
        let dir = bundleURL.appendingPathComponent("Previews")
            .appendingPathComponent((master.imagePath as NSString).deletingLastPathComponent)
            .appendingPathComponent(version.uuid)
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            return nil
        }
        let full = files.filter { !$0.hasPrefix("thumb_") && $0.lowercased().hasSuffix(".jpg") }
        guard let name = full.first else { return nil }
        return dir.appendingPathComponent(name)
    }
}
