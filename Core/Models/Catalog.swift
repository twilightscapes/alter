//
//  Catalog.swift
//  Alter
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
//  The .alterlib library format. An .alterlib is a plain directory bundle:
//
//      MyPhotos.alterlib/
//        catalog.sqlite     ← this file (photos, folders, albums, edits)
//        Previews/          ← reserved for the preview cache (later phase)
//
//  Design rule #1 (the anti-Aperture promise): the library NEVER contains or
//  moves originals. Photos are referenced where they live; the catalog only
//  indexes them. Metadata edits are cached here (dirty=1) until written into
//  the files via exiftool.
//

import Foundation

struct FolderRow: Identifiable, Hashable {
    let id: Int64
    let path: String
    /// The folder's name — except an Aperture library's Masters folder,
    /// which goes by the library's name (two libraries would otherwise
    /// both read "Masters").
    var name: String {
        let url = URL(fileURLWithPath: path)
        let parent = url.deletingLastPathComponent()
        if url.lastPathComponent == "Masters", parent.pathExtension == "aplibrary" {
            return parent.deletingPathExtension().lastPathComponent
        }
        return url.lastPathComponent
    }
}

struct AlbumRow: Identifiable, Hashable {
    let id: Int64
    let name: String
    /// The project or folder it sits in (Aperture's albums live inside
    /// projects); nil = top level.
    var parentID: Int64? = nil
}

/// A keyword in the library's hierarchy (Aperture's keyword library).
struct KeywordNode: Identifiable, Hashable {
    let id: Int64
    var name: String
    let parentID: Int64?
    var children: [KeywordNode]?
}

/// Aperture's organisation: folders nest, projects hold the photos.
struct ProjectNode: Identifiable, Hashable {
    enum Kind: String { case folder, project, album }
    let id: Int64
    var name: String
    let kind: Kind
    let parentID: Int64?
    var count: Int
    var children: [ProjectNode]?   // nil for a project (leaf)
}

/// Which set of photos the grid is showing.
enum LibrarySource: Hashable {
    case all
    case noAltText
    case flagged
    case recentlyAdded
    case videos
    /// A source an extension adds to the sidebar; it shows every master and
    /// the extension's sourceFilter narrows it (or its centerPane replaces
    /// the grid entirely).
    case extensionSource(String)
    case folder(Int64)
    case album(Int64)
    case smartAlbum(Int64)
    /// A project (its photos) or an organising folder (every project under it).
    case project(Int64)
    /// Aperture's Faces corkboard (its own pane, no grid).
    case faces
    /// Aperture's Places: the whole library on a map.
    case places
    /// One person's photos.
    case person(Int64)
}

final class Catalog {
    let libraryURL: URL
    /// Internal so the catalog's extensions (Faces) can reach it.
    let db: Database

    static let fileExtension = "alterlib"

    // MARK: - Create / open

    /// Opens an existing library or creates the bundle + schema if missing.
    init(libraryURL: URL) throws {
        self.libraryURL = libraryURL
        let fm = FileManager.default
        try fm.createDirectory(at: libraryURL, withIntermediateDirectories: true)
        try fm.createDirectory(at: libraryURL.appendingPathComponent("Previews"), withIntermediateDirectories: true)
        self.db = try Database(path: libraryURL.appendingPathComponent("catalog.sqlite").path)
        makeDailySnapshot()
        try migrate()
        healAfterLibraryMove()
    }

    /// One catalog snapshot per day, taken at open — the state exactly as
    /// the last session left it, banked before this session touches
    /// anything. Keeps a week. The catalog is tiny (it's an index, not a
    /// vault), so seven days of "restore yesterday" costs megabytes and
    /// turns catalog corruption from a disaster into an inconvenience.
    private func makeDailySnapshot() {
        let fm = FileManager.default
        let dir = libraryURL.appendingPathComponent("Backups", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp: String = {
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd"
            return df.string(from: Date())
        }()
        let dest = dir.appendingPathComponent("catalog-\(stamp).sqlite")
        guard !fm.fileExists(atPath: dest.path) else { return }
        // Fold any WAL into the main file so the copy is self-contained.
        try? db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        try? fm.copyItem(
            at: libraryURL.appendingPathComponent("catalog.sqlite"), to: dest)
        // Prune to the newest seven (names sort chronologically).
        if let entries = try? fm.contentsOfDirectory(atPath: dir.path) {
            let snapshots = entries
                .filter { $0.hasPrefix("catalog-") && $0.hasSuffix(".sqlite") }
                .sorted()
            for stale in snapshots.dropLast(7) {
                try? fm.removeItem(at: dir.appendingPathComponent(stale))
            }
        }
    }

    /// If the library has moved since last open (new Mac, external drive,
    /// reorganized folders), photos that traveled WITH it heal themselves:
    /// any missing original whose old path sat beside the library's old
    /// home gets re-based onto the new home — and kept only if the file is
    /// really there. Photos that didn't move are untouched; the ones that
    /// moved elsewhere still relink by folder as before.
    private func healAfterLibraryMove() {
        try? db.execute(
            "CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        let current = libraryURL.standardizedFileURL.path
        let stored = (try? db.query(
            "SELECT value FROM meta WHERE key = 'library_path'"))?
            .first?["value"] as? String
        defer {
            try? db.run("""
                INSERT INTO meta (key, value) VALUES ('library_path', ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """, [current])
        }
        guard let stored, stored != current else { return }
        let oldParent = URL(fileURLWithPath: stored).deletingLastPathComponent().path
        let newParent = libraryURL.standardizedFileURL.deletingLastPathComponent().path
        guard oldParent != newParent else { return }
        let fm = FileManager.default

        func rebased(_ path: String) -> String? {
            guard !fm.fileExists(atPath: path),
                  path.hasPrefix(oldParent + "/") else { return nil }
            let candidate = newParent + path.dropFirst(oldParent.count)
            return fm.fileExists(atPath: candidate) ? candidate : nil
        }

        if let folders = try? db.query("SELECT id, path FROM folders") {
            for row in folders {
                guard let id = row["id"] as? Int64, let path = row["path"] as? String,
                      let healed = rebased(path) else { continue }
                try? db.run("UPDATE folders SET path = ? WHERE id = ?", [healed, id])
            }
        }
        if let photos = try? db.query("SELECT id, path FROM photos") {
            for row in photos {
                guard let id = row["id"] as? Int64, let path = row["path"] as? String,
                      let healed = rebased(path) else { continue }
                try? db.run("UPDATE photos SET path = ? WHERE id = ?", [healed, id])
            }
        }
    }

    static func isLibrary(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent("catalog.sqlite").path)
    }

    private func migrate() throws {
        try db.execute("""
        CREATE TABLE IF NOT EXISTS schema_info (version INTEGER NOT NULL);

        CREATE TABLE IF NOT EXISTS folders (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            path TEXT NOT NULL UNIQUE,
            added_at REAL NOT NULL
        );

        CREATE TABLE IF NOT EXISTS photos (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            folder_id INTEGER REFERENCES folders(id) ON DELETE CASCADE,
            path TEXT NOT NULL UNIQUE,
            filename TEXT NOT NULL,
            added_at REAL NOT NULL,
            mtime REAL,
            file_size INTEGER,
            rating INTEGER NOT NULL DEFAULT 0,
            flagged INTEGER NOT NULL DEFAULT 0,
            dirty INTEGER NOT NULL DEFAULT 0,
            alt_text TEXT NOT NULL DEFAULT '',
            title TEXT NOT NULL DEFAULT '',
            caption TEXT NOT NULL DEFAULT '',
            keywords TEXT NOT NULL DEFAULT '',
            creator TEXT NOT NULL DEFAULT '',
            copyright TEXT NOT NULL DEFAULT ''
        );
        CREATE INDEX IF NOT EXISTS idx_photos_folder ON photos(folder_id);
        CREATE INDEX IF NOT EXISTS idx_photos_dirty ON photos(dirty);

        CREATE TABLE IF NOT EXISTS albums (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            position INTEGER NOT NULL DEFAULT 0
        );

        CREATE TABLE IF NOT EXISTS album_items (
            album_id INTEGER NOT NULL REFERENCES albums(id) ON DELETE CASCADE,
            photo_id INTEGER NOT NULL REFERENCES photos(id) ON DELETE CASCADE,
            position INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (album_id, photo_id)
        );
        """)
        let hasVersion = try db.scalarInt("SELECT COUNT(*) FROM schema_info")
        if hasVersion == 0 {
            try db.run("INSERT INTO schema_info (version) VALUES (1)")
        }

        // v2: non-destructive adjustment recipes (JSON) per photo.
        let version = try db.scalarInt("SELECT version FROM schema_info")
        if version < 2 {
            try? db.execute("ALTER TABLE photos ADD COLUMN edits TEXT NOT NULL DEFAULT ''")
            try db.run("UPDATE schema_info SET version = 2")
        }

        // v3: meme compositions (JSON) per photo — scape-style, the layers
        // live beside the image and never touch it.
        if version < 3 {
            try? db.execute("ALTER TABLE photos ADD COLUMN meme TEXT NOT NULL DEFAULT ''")
            try db.run("UPDATE schema_info SET version = 3")
        }

        // v4: as-found metadata snapshot (JSON), taken from the file the first
        // time ALTer writes into it — powers Revert Metadata. Empty = never
        // written by ALTer.
        if version < 4 {
            try? db.execute("ALTER TABLE photos ADD COLUMN metadata_backup TEXT NOT NULL DEFAULT ''")
            try db.run("UPDATE schema_info SET version = 4")
        }

        // v5: the Aperture set — versions, stacks, colour labels, smart
        // albums. Versions are extra photo rows that share a master's file,
        // which means `path` can no longer be UNIQUE; SQLite can't drop a
        // column constraint, so the table is rebuilt (ids preserved — the
        // album_items rows keep pointing at the same photos).
        if version < 5 {
            try rebuildPhotosTable(carryApertureColumns: false)
            try db.run("UPDATE schema_info SET version = 5")
        }
        // Repair: an early v5 rebuild named the self-reference after the
        // scratch table, and RENAME doesn't rewrite references while
        // foreign keys are off — leaving a dangling FK that broke every
        // version insert. Rebuild once more if that schema is on disk.
        let photosSQL = (try? db.query(
            "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'photos'"))?
            .first?["sql"] as? String ?? ""
        if photosSQL.contains("photos_v5") {
            try rebuildPhotosTable(carryApertureColumns: true)
            try? db.execute("ALTER TABLE photos ADD COLUMN reference_path TEXT NOT NULL DEFAULT ''")
        }
        // v6: a reference render per photo — for a library opened from
        // Aperture, the JPEG Aperture itself rendered, so Compare can show
        // "what Aperture showed" beside what ALTer shows.
        if version < 6 {
            try? db.execute("ALTER TABLE photos ADD COLUMN reference_path TEXT NOT NULL DEFAULT ''")
            try db.run("UPDATE schema_info SET version = 6")
        }

        // v7: projects — Aperture's containers. Folders nest, projects are
        // leaves that hold masters; a photo belongs to at most one project.
        if version < 7 {
            try db.execute("""
            CREATE TABLE IF NOT EXISTS projects (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL,
                kind TEXT NOT NULL DEFAULT 'project',
                parent_id INTEGER REFERENCES projects(id) ON DELETE CASCADE,
                position INTEGER NOT NULL DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS idx_projects_parent ON projects(parent_id);
            """)
            try? db.execute("ALTER TABLE photos ADD COLUMN project_id INTEGER REFERENCES projects(id) ON DELETE SET NULL")
            try? db.execute("CREATE INDEX IF NOT EXISTS idx_photos_project ON photos(project_id)")
            try db.run("UPDATE schema_info SET version = 7")
        }

        // v8: camera EXIF in the catalog, so smart albums can search it.
        // Filled by the Aperture reader, by import, and lazily by the Info
        // panel; '' / NULL = not read yet.
        if version < 8 {
            for sql in ["ALTER TABLE photos ADD COLUMN camera TEXT NOT NULL DEFAULT ''",
                        "ALTER TABLE photos ADD COLUMN lens TEXT NOT NULL DEFAULT ''",
                        "ALTER TABLE photos ADD COLUMN iso INTEGER",
                        "ALTER TABLE photos ADD COLUMN focal_length REAL",
                        "ALTER TABLE photos ADD COLUMN aperture REAL",
                        "ALTER TABLE photos ADD COLUMN shutter REAL",
                        "ALTER TABLE photos ADD COLUMN exif_read INTEGER NOT NULL DEFAULT 0"] {
                try? db.execute(sql)
            }
            try db.run("UPDATE schema_info SET version = 8")
        }

        // v9: albums can live inside projects/folders; a keyword hierarchy.
        if version < 9 {
            try? db.execute("ALTER TABLE albums ADD COLUMN parent_id INTEGER REFERENCES projects(id) ON DELETE SET NULL")
            try db.execute("""
            CREATE TABLE IF NOT EXISTS keywords (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL,
                parent_id INTEGER REFERENCES keywords(id) ON DELETE CASCADE
            );
            CREATE INDEX IF NOT EXISTS idx_keywords_parent ON keywords(parent_id);
            """)
            try db.run("UPDATE schema_info SET version = 9")
        }

        // v10: when the photo was taken, kept in the catalog (from EXIF, or
        // Aperture's own date) so sorting, smart albums and Auto-Stack go by
        // it, and so Adjust Date & Time can move it. capture_read = the
        // EXIF date was looked for (or set by hand — never overwritten).
        if version < 10 {
            try? db.execute("ALTER TABLE photos ADD COLUMN capture_date REAL")
            try? db.execute("ALTER TABLE photos ADD COLUMN capture_read INTEGER NOT NULL DEFAULT 0")
            try db.run("UPDATE schema_info SET version = 10")
        }

        // v11: Faces. A face is a box on a master (normalised, top-left,
        // in the upright image) with SFace's fingerprint; it belongs to a
        // person only once someone has said so. `people` on photos is the
        // names, kept in step, so smart albums and search can read them.
        if version < 11 {
            try db.execute("""
            CREATE TABLE IF NOT EXISTS people (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL,
                key_face_id INTEGER,
                position INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE IF NOT EXISTS faces (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                photo_id INTEGER NOT NULL REFERENCES photos(id) ON DELETE CASCADE,
                x REAL NOT NULL, y REAL NOT NULL, w REAL NOT NULL, h REAL NOT NULL,
                image_w INTEGER NOT NULL DEFAULT 0,
                image_h INTEGER NOT NULL DEFAULT 0,
                quality REAL NOT NULL DEFAULT 0,
                print BLOB,
                person_id INTEGER REFERENCES people(id) ON DELETE SET NULL,
                manual INTEGER NOT NULL DEFAULT 0,
                ignored INTEGER NOT NULL DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS idx_faces_photo ON faces(photo_id);
            CREATE INDEX IF NOT EXISTS idx_faces_person ON faces(person_id);
            CREATE TABLE IF NOT EXISTS face_rejections (
                face_id INTEGER NOT NULL REFERENCES faces(id) ON DELETE CASCADE,
                person_id INTEGER NOT NULL REFERENCES people(id) ON DELETE CASCADE,
                PRIMARY KEY (face_id, person_id)
            );
            """)
            try? db.execute("ALTER TABLE photos ADD COLUMN faces_scanned INTEGER NOT NULL DEFAULT 0")
            try? db.execute("ALTER TABLE photos ADD COLUMN people TEXT NOT NULL DEFAULT ''")
            try db.run("UPDATE schema_info SET version = 11")
        }

        // v12: where each photo was taken, in the catalog — so Places can
        // map a whole library at once, and so a photo in an Aperture
        // library (whose file Alter never writes) can still be placed.
        // gps_read = the file's own GPS has been looked for.
        if version < 12 {
            try? db.execute("ALTER TABLE photos ADD COLUMN latitude REAL")
            try? db.execute("ALTER TABLE photos ADD COLUMN longitude REAL")
            try? db.execute("ALTER TABLE photos ADD COLUMN gps_read INTEGER NOT NULL DEFAULT 0")
            try db.run("UPDATE schema_info SET version = 12")
        }

        // v13: place names ("Fort Worth, Texas, United States") for where
        // photos were taken. Looked up once per ~1 km cell (the key is the
        // location rounded to 0.01°) and shared by every photo in it.
        if version < 13 {
            try db.execute("""
            CREATE TABLE IF NOT EXISTS place_names (
                key TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                looked_up REAL NOT NULL
            );
            """)
            try? db.execute("ALTER TABLE photos ADD COLUMN place TEXT NOT NULL DEFAULT ''")
            try db.run("UPDATE schema_info SET version = 13")
        }

        // v14: the order inside a stack (Promote/Demote); its first is the pick.
        if version < 14 {
            try? db.execute("ALTER TABLE photos ADD COLUMN stack_position INTEGER NOT NULL DEFAULT 0")
            try db.run("UPDATE schema_info SET version = 14")
        }

        // Repair: an early v5 uniqueness index was (path, version_of),
        // which allowed only ONE version per master. Swap it for the
        // masters-only partial index. Idempotent and cheap on every open.
        try db.execute("""
        DROP INDEX IF EXISTS idx_photos_path_version;
        CREATE UNIQUE INDEX IF NOT EXISTS idx_photos_master_path
            ON photos(path) WHERE version_of IS NULL;
        """)
    }

    /// Recreate `photos` without UNIQUE(path), adding the Aperture-set
    /// columns. The scratch table references `photos` by its FINAL name:
    /// the clause isn't validated at CREATE time, and it must read
    /// correctly after the rename (see the repair note above).
    private func rebuildPhotosTable(carryApertureColumns: Bool) throws {
        let extra = carryApertureColumns
            ? ", label, version_of, version_name, stack_id" : ""
        // (reference_path is re-added by the v6 step if this rebuild runs
        // before it; a repair rebuild on a v6 library re-adds it below.)
        try db.execute("""
        PRAGMA foreign_keys = OFF;
        BEGIN;
        CREATE TABLE IF NOT EXISTS stacks (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            pick_photo_id INTEGER,
            collapsed INTEGER NOT NULL DEFAULT 1
        );
        CREATE TABLE IF NOT EXISTS smart_albums (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            rules TEXT NOT NULL DEFAULT '{}',
            position INTEGER NOT NULL DEFAULT 0
        );
        DROP TABLE IF EXISTS photos_rebuild;
        CREATE TABLE photos_rebuild (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            folder_id INTEGER REFERENCES folders(id) ON DELETE CASCADE,
            path TEXT NOT NULL,
            filename TEXT NOT NULL,
            added_at REAL NOT NULL,
            mtime REAL,
            file_size INTEGER,
            rating INTEGER NOT NULL DEFAULT 0,
            flagged INTEGER NOT NULL DEFAULT 0,
            dirty INTEGER NOT NULL DEFAULT 0,
            alt_text TEXT NOT NULL DEFAULT '',
            title TEXT NOT NULL DEFAULT '',
            caption TEXT NOT NULL DEFAULT '',
            keywords TEXT NOT NULL DEFAULT '',
            creator TEXT NOT NULL DEFAULT '',
            copyright TEXT NOT NULL DEFAULT '',
            edits TEXT NOT NULL DEFAULT '',
            meme TEXT NOT NULL DEFAULT '',
            metadata_backup TEXT NOT NULL DEFAULT '',
            label INTEGER NOT NULL DEFAULT 0,
            version_of INTEGER REFERENCES photos(id) ON DELETE CASCADE,
            version_name TEXT NOT NULL DEFAULT '',
            stack_id INTEGER REFERENCES stacks(id) ON DELETE SET NULL
        );
        INSERT INTO photos_rebuild
            (id, folder_id, path, filename, added_at, mtime, file_size, rating,
             flagged, dirty, alt_text, title, caption, keywords, creator,
             copyright, edits, meme, metadata_backup\(extra))
        SELECT id, folder_id, path, filename, added_at, mtime, file_size, rating,
             flagged, dirty, alt_text, title, caption, keywords, creator,
             copyright, edits, meme, metadata_backup\(extra)
        FROM photos;
        DROP TABLE photos;
        ALTER TABLE photos_rebuild RENAME TO photos;
        CREATE INDEX IF NOT EXISTS idx_photos_folder ON photos(folder_id);
        CREATE INDEX IF NOT EXISTS idx_photos_dirty ON photos(dirty);
        CREATE INDEX IF NOT EXISTS idx_photos_version_of ON photos(version_of);
        CREATE INDEX IF NOT EXISTS idx_photos_stack ON photos(stack_id);
        -- One MASTER per file (partial index); versions are distinct rows
        -- and may share a path freely.
        CREATE UNIQUE INDEX IF NOT EXISTS idx_photos_master_path
            ON photos(path) WHERE version_of IS NULL;
        COMMIT;
        PRAGMA foreign_keys = ON;
        """)
    }

    // MARK: - As-found metadata backups

    /// The as-found snapshot for a photo, or nil if ALTer has never written
    /// into its file.
    func metadataBackup(photoID: Int64) throws -> PhotoMetadata? {
        let rows = try db.query("SELECT metadata_backup FROM photos WHERE id = ?", [photoID])
        guard let json = rows.first?["metadata_backup"] as? String else { return nil }
        return PhotoMetadata.decodeJSON(json)
    }

    /// Of the given photos, the ones with no snapshot yet (i.e. files ALTer is
    /// about to write into for the first time).
    func photoIDsWithoutBackup(among ids: [Int64]) throws -> Set<Int64> {
        var missing: Set<Int64> = []
        for id in ids {
            let rows = try db.query("SELECT metadata_backup FROM photos WHERE id = ?", [id])
            if let json = rows.first?["metadata_backup"] as? String, json.isEmpty {
                missing.insert(id)
            }
        }
        return missing
    }

    /// Store the as-found snapshot — first write wins, so the backup always
    /// holds the pre-ALTer state no matter how many saves follow.
    func setMetadataBackup(photoID: Int64, _ metadata: PhotoMetadata) throws {
        try db.run(
            "UPDATE photos SET metadata_backup = ? WHERE id = ? AND metadata_backup = ''",
            [metadata.encodedJSON(), photoID])
    }

    /// Store a photo's adjustment recipe (catalog-only; never touches the file).
    func updateEdits(photoID: Int64, _ edits: PhotoEdits) throws {
        try db.run("UPDATE photos SET edits = ? WHERE id = ?", [edits.encoded(), photoID])
    }

    /// Store a photo's meme composition (catalog-only; never touches the file).
    func updateMeme(photoID: Int64, json: String) throws {
        try db.run("UPDATE photos SET meme = ? WHERE id = ?", [json, photoID])
    }

    // MARK: - Folders

    @discardableResult
    func addFolder(path: String) throws -> Int64 {
        try db.run(
            "INSERT OR IGNORE INTO folders (path, added_at) VALUES (?, ?)",
            [path, Date().timeIntervalSince1970]
        )
        return try db.scalarInt("SELECT id FROM folders WHERE path = ?", [path])
    }

    func folders() throws -> [FolderRow] {
        try db.query("SELECT id, path FROM folders ORDER BY path").compactMap { row in
            guard let id = row["id"] as? Int64, let path = row["path"] as? String else { return nil }
            return FolderRow(id: id, path: path)
        }
    }

    /// Remove a referenced folder and its indexed photos (files untouched).
    func removeFolder(id: Int64) throws {
        try db.run("DELETE FROM folders WHERE id = ?", [id])
    }

    /// Repoint a single photo whose original moved or was renamed.
    func relocatePhoto(id: Int64, to newPath: String) throws {
        let filename = URL(fileURLWithPath: newPath).lastPathComponent
        try db.run("UPDATE photos SET path = ?, filename = ? WHERE id = ?", [newPath, filename, id])
    }

    /// Repoint a referenced folder after the user moved/renamed it on disk,
    /// rewriting every contained photo's path prefix.
    func relocateFolder(id: Int64, to newPath: String) throws {
        guard let oldPath = try folders().first(where: { $0.id == id })?.path else { return }
        try db.run("UPDATE folders SET path = ? WHERE id = ?", [newPath, id])
        try db.run(
            "UPDATE photos SET path = REPLACE(path, ?, ?) WHERE folder_id = ?",
            [oldPath + "/", newPath + "/", id])
    }

    // MARK: - Photos

    /// Index a file into the catalog. Returns the photo id (existing or new).
    @discardableResult
    func insertPhoto(url: URL, folderID: Int64?, metadata: PhotoMetadata) throws -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970
        let size = attrs?[.size] as? Int64
        try db.run("""
            INSERT OR IGNORE INTO photos
                (folder_id, path, filename, added_at, mtime, file_size,
                 alt_text, title, caption, keywords, creator, copyright)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [
            folderID, url.path, url.lastPathComponent, Date().timeIntervalSince1970,
            mtime, size,
            metadata.altText, metadata.title, metadata.caption,
            metadata.keywords.joined(separator: ", "), metadata.creator, metadata.copyright,
        ])
        return try db.scalarInt(
            "SELECT id FROM photos WHERE path = ? AND version_of IS NULL", [url.path])
    }

    /// Every master's file path (for checking what can be read).
    func masterPaths() throws -> [String] {
        try db.query("SELECT path FROM photos WHERE version_of IS NULL").compactMap { $0["path"] as? String }
    }

    func photos(in source: LibrarySource) throws -> [PhotoItem] {
        // Masters only — versions ride along with their master (the store
        // splices them in when a master is expanded).
        let base = "SELECT p.* FROM photos p WHERE p.version_of IS NULL"
        let order = " ORDER BY p.filename COLLATE NOCASE"
        let rows: [[String: Any]]
        switch source {
        case .all, .smartAlbum:
            rows = try db.query(base + order)
        case .noAltText:
            rows = try db.query(base + " AND p.alt_text = ''" + order)
        case .flagged:
            rows = try db.query(base + " AND p.flagged = 1" + order)
        case .recentlyAdded:
            rows = try db.query(base + " ORDER BY p.added_at DESC LIMIT 200")
        case .videos:
            let matches = ImageLoader.videoExtensions
                .map { "lower(p.filename) LIKE '%.\($0)'" }
                .joined(separator: " OR ")
            rows = try db.query(base + " AND (" + matches + ")" + order)
        case .extensionSource:
            rows = try db.query(base + order)
        case .folder(let id):
            rows = try db.query(base + " AND p.folder_id = ?" + order, [id])
        case .project(let id):
            let ids = try projectAndDescendantIDs(id)
            let marks = ids.map { _ in "?" }.joined(separator: ",")
            rows = try db.query(base + " AND p.project_id IN (\(marks))" + order, ids.map { $0 as Any? })
        case .faces:
            rows = []
        case .places:
            rows = try db.query(base + order)
        case .person(let id):
            rows = try db.query(base + " AND p.id IN (SELECT photo_id FROM faces WHERE person_id = ?)" + order, [id])
        case .album(let id):
            rows = try db.query(
                "SELECT p.* FROM photos p JOIN album_items ai ON ai.photo_id = p.id"
                + " WHERE ai.album_id = ? ORDER BY ai.position, p.filename COLLATE NOCASE", [id])
        }
        return rows.compactMap(PhotoItem.init(row:))
    }

    func dirtyPhotos() throws -> [PhotoItem] {
        try db.query("SELECT * FROM photos WHERE dirty = 1").compactMap(PhotoItem.init(row:))
    }

    func counts() throws -> (all: Int64, noAlt: Int64, dirty: Int64) {
        (
            try db.scalarInt("SELECT COUNT(*) FROM photos"),
            try db.scalarInt("SELECT COUNT(*) FROM photos WHERE alt_text = ''"),
            try db.scalarInt("SELECT COUNT(*) FROM photos WHERE dirty = 1")
        )
    }

    /// Cache edited metadata (marks the photo pending write-back).
    func updateMetadata(photoID: Int64, _ metadata: PhotoMetadata, dirty: Bool = true) throws {
        // One file, one set of metadata: every version of it reads the same
        // title/caption/keywords. Only the master carries `dirty` — it's
        // the row the file-writer walks, so a version never double-writes.
        let master = try db.scalarInt(
            "SELECT COALESCE(version_of, id) FROM photos WHERE id = ?", [photoID])
        let masterPath = (try? db.query("SELECT path FROM photos WHERE id = ?", [master]))?.first?["path"] as? String ?? ""
        let dirty = dirty && !isApertureOriginal(masterPath)
        try db.run("""
            UPDATE photos SET alt_text = ?, title = ?, caption = ?, keywords = ?,
                creator = ?, copyright = ?,
                dirty = CASE WHEN version_of IS NULL THEN ? ELSE 0 END
            WHERE id = ? OR version_of = ?
            """, [
            metadata.altText, metadata.title, metadata.caption,
            metadata.keywords.joined(separator: ", "),
            metadata.creator, metadata.copyright, dirty, master, master,
        ])
    }

    func markSaved(photoID: Int64) throws {
        try db.run("UPDATE photos SET dirty = 0 WHERE id = ?", [photoID])
    }

    func setRating(photoID: Int64, rating: Int) throws {
        // −1 is Aperture's Reject.
        try db.run("UPDATE photos SET rating = ? WHERE id = ?", [max(-1, min(5, rating)), photoID])
    }

    func setFlagged(photoID: Int64, flagged: Bool) throws {
        try db.run("UPDATE photos SET flagged = ? WHERE id = ?", [flagged, photoID])
    }

    /// Drop photos from the catalog (files untouched).
    func removePhotos(ids: [Int64]) throws {
        for id in ids {
            try db.run("DELETE FROM photos WHERE id = ?", [id])
        }
    }

    // MARK: - Library metadata (key/value)

    /// A library that reads an Aperture bundle never writes into the
    /// originals: metadata lives in this catalog only, so nothing is ever
    /// marked dirty for a file write.
    private(set) lazy var originalsAreReadOnly: Bool = metaValue("source") == "aperture"

    /// Every Aperture library this catalog reads (bundle paths): the one it
    /// was built from, plus any imported into it since.
    var aperturePaths: [String] {
        if let json = metaValue("aperture_paths"), let data = json.data(using: .utf8),
           let paths = try? JSONDecoder().decode([String].self, from: data) {
            return paths
        }
        return metaValue("aperture_path").map { [$0] } ?? []
    }

    func setAperturePaths(_ paths: [String]) throws {
        let data = try JSONEncoder().encode(paths)
        try setMetaValue("aperture_paths", String(decoding: data, as: UTF8.self))
        aperturePrefixes = nil
    }

    /// Each library's path as written and with symlinks resolved (a photo's
    /// path may carry either form — /tmp vs /private/tmp), cached.
    private var aperturePrefixesCache: [String]?
    private var aperturePrefixes: [String]? {
        get { aperturePrefixesCache }
        set { aperturePrefixesCache = newValue }
    }

    /// Is this original inside an Aperture library? Those are never written
    /// to — in a catalog built from Aperture, or one an Aperture library was
    /// imported into.
    func isApertureOriginal(_ path: String) -> Bool {
        if originalsAreReadOnly { return true }
        if aperturePrefixesCache == nil {
            aperturePrefixesCache = aperturePaths.flatMap { p -> [String] in
                let resolved = URL(fileURLWithPath: p).resolvingSymlinksInPath().path
                let privateForm = p.hasPrefix("/tmp/") || p.hasPrefix("/var/") ? "/private" + p : p
                return Array(Set([p, resolved, privateForm])).map { $0 + "/" }
            }
        }
        return aperturePrefixesCache!.contains { path.hasPrefix($0) }
    }

    /// The first time a second Aperture library comes in: everything at the
    /// top of Projects and Albums moves into one folder named after the
    /// library it came from, so each library reads as its own collapsible
    /// group. Smart albums stay where they are (they search everything).
    @discardableResult
    func groupTopLevel(intoFolderNamed name: String) throws -> Int64 {
        let folder = try createProject(name: name, kind: .folder, parent: nil)
        try db.run("UPDATE projects SET parent_id = ? WHERE parent_id IS NULL AND id != ?", [folder, folder])
        try db.run("UPDATE albums SET parent_id = ? WHERE parent_id IS NULL", [folder])
        return folder
    }

    /// Many writes, one transaction (imports).
    func performBatch(_ body: () throws -> Void) throws {
        try db.execute("BEGIN")
        do {
            try body()
            try db.execute("COMMIT")
        } catch {
            try? db.execute("ROLLBACK")
            throw error
        }
    }

    func metaValue(_ key: String) -> String? {
        (try? db.query("SELECT value FROM meta WHERE key = ?", [key]))?.first?["value"] as? String
    }

    func setMetaValue(_ key: String, _ value: String) throws {
        try db.run("""
            INSERT INTO meta (key, value) VALUES (?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """, [key, value])
    }

    func setReferencePath(photoID: Int64, _ path: String) throws {
        try db.run("UPDATE photos SET reference_path = ? WHERE id = ?", [path, photoID])
    }

    // MARK: - Versions (one file, many takes)

    /// Every row sharing a file: the master plus its versions. Metadata
    /// writes fan out across the family — there is one file, so there is
    /// one title, one caption, one set of keywords.
    func familyIDs(of photoID: Int64) throws -> [Int64] {
        let master = try db.scalarInt(
            "SELECT COALESCE(version_of, id) FROM photos WHERE id = ?", [photoID])
        return try db.query(
            "SELECT id FROM photos WHERE id = ? OR version_of = ?", [master, master])
            .compactMap { $0["id"] as? Int64 }
    }

    func versions(of masterID: Int64) throws -> [PhotoItem] {
        try db.query("SELECT * FROM photos WHERE version_of = ? ORDER BY id", [masterID])
            .compactMap(PhotoItem.init(row:))
    }

    /// master id → how many versions it has (masters with none are absent).
    func versionCounts() throws -> [Int64: Int] {
        var out: [Int64: Int] = [:]
        for row in try db.query(
            "SELECT version_of AS m, COUNT(*) AS n FROM photos WHERE version_of IS NOT NULL GROUP BY version_of") {
            if let m = row["m"] as? Int64 { out[m] = Int(row["n"] as? Int64 ?? 0) }
        }
        return out
    }

    func versionCount(of masterID: Int64) throws -> Int {
        Int(try db.scalarInt("SELECT COUNT(*) FROM photos WHERE version_of = ?", [masterID]))
    }

    /// A new version of a photo: the same file, with the given recipe
    /// (nil = the master's current recipe, "duplicate"; neutral = "from
    /// original"). Rating/flag/label/metadata copy from the source row.
    @discardableResult
    func createVersion(of photoID: Int64, edits: PhotoEdits?, name: String? = nil) throws -> Int64 {
        let master = try db.scalarInt(
            "SELECT COALESCE(version_of, id) FROM photos WHERE id = ?", [photoID])
        let count = try versionCount(of: master)
        let versionName = name ?? "Version \(count + 2)"
        let recipe = edits.map { $0.encoded() }
        try db.run("""
            INSERT INTO photos
                (folder_id, path, filename, added_at, mtime, file_size, rating, flagged,
                 alt_text, title, caption, keywords, creator, copyright, edits, label,
                 version_of, version_name, stack_id)
            SELECT folder_id, path, filename, ?, mtime, file_size, rating, flagged,
                 alt_text, title, caption, keywords, creator, copyright,
                 COALESCE(?, edits), label, ?, ?, stack_id
            FROM photos WHERE id = ?
            """, [Date().timeIntervalSince1970, recipe, master, versionName, photoID])
        return db.lastInsertRowID
    }

    func renameVersion(id: Int64, name: String) throws {
        try db.run("UPDATE photos SET version_name = ? WHERE id = ?", [name, id])
    }

    // MARK: - Labels

    func setLabel(photoID: Int64, label: Int) throws {
        try db.run("UPDATE photos SET label = ? WHERE id = ?", [label, photoID])
    }

    // MARK: - Stacks (bursts and brackets, a pick on top)

    @discardableResult
    func createStack(photoIDs: [Int64], pick: Int64? = nil) throws -> Int64 {
        guard let first = photoIDs.first else { throw NSError(domain: "Alter", code: 1) }
        try db.run("INSERT INTO stacks (pick_photo_id, collapsed) VALUES (?, 1)", [pick ?? first])
        let stackID = db.lastInsertRowID
        // The pick first, the rest in the order given.
        let ordered = pick.map { p in [p] + photoIDs.filter { $0 != p } } ?? photoIDs
        for (position, id) in ordered.enumerated() {
            try db.run("UPDATE photos SET stack_id = ?, stack_position = ? WHERE id = ? OR version_of = ?",
                       [stackID, position, id, id])
        }
        return stackID
    }

    func unstack(stackID: Int64) throws {
        try db.run("UPDATE photos SET stack_id = NULL WHERE stack_id = ?", [stackID])
        try db.run("DELETE FROM stacks WHERE id = ?", [stackID])
    }

    /// Take one photo (and its versions) out of whatever stack it's in.
    func removeFromStack(photoID: Int64) throws {
        try db.run("UPDATE photos SET stack_id = NULL WHERE id = ? OR version_of = ?", [photoID, photoID])
    }

    func setStackPick(stackID: Int64, photoID: Int64) throws {
        try db.run("UPDATE stacks SET pick_photo_id = ? WHERE id = ?", [photoID, stackID])
    }

    /// Every stacked master's place in its stack.
    func stackPositions() throws -> [Int64: Int] {
        var out: [Int64: Int] = [:]
        for row in try db.query("SELECT id, stack_position FROM photos WHERE stack_id IS NOT NULL AND version_of IS NULL") {
            if let id = row["id"] as? Int64 { out[id] = Int(row["stack_position"] as? Int64 ?? 0) }
        }
        return out
    }

    /// A stack's masters, pick first, then by position.
    func stackMemberIDs(stackID: Int64) throws -> [Int64] {
        try db.query("""
            SELECT p.id FROM photos p JOIN stacks s ON s.id = p.stack_id
            WHERE p.stack_id = ? AND p.version_of IS NULL
            ORDER BY (p.id = s.pick_photo_id) DESC, p.stack_position, p.filename COLLATE NOCASE
            """, [stackID]).compactMap { $0["id"] as? Int64 }
    }

    /// A stack in this order; the first becomes its pick.
    func setStackOrder(stackID: Int64, photoIDs: [Int64]) throws {
        for (position, id) in photoIDs.enumerated() {
            try db.run("UPDATE photos SET stack_position = ? WHERE id = ? OR version_of = ?", [position, id, id])
        }
        if let first = photoIDs.first { try setStackPick(stackID: stackID, photoID: first) }
    }

    func setStackCollapsed(stackID: Int64, collapsed: Bool) throws {
        try db.run("UPDATE stacks SET collapsed = ? WHERE id = ?", [collapsed ? 1 : 0, stackID])
    }

    /// Every stack: id → (pick, collapsed, member count).
    func stacks() throws -> [Int64: (pick: Int64?, collapsed: Bool, count: Int)] {
        var out: [Int64: (pick: Int64?, collapsed: Bool, count: Int)] = [:]
        for row in try db.query("""
            SELECT s.id, s.pick_photo_id, s.collapsed,
                   (SELECT COUNT(*) FROM photos p WHERE p.stack_id = s.id AND p.version_of IS NULL) AS n
            FROM stacks s
            """) {
            guard let id = row["id"] as? Int64 else { continue }
            out[id] = (row["pick_photo_id"] as? Int64,
                       (row["collapsed"] as? Int64 ?? 1) == 1,
                       Int(row["n"] as? Int64 ?? 0))
        }
        return out
    }

    // MARK: - Smart albums

    func smartAlbums() throws -> [SmartAlbumRow] {
        try db.query("SELECT id, name, rules FROM smart_albums ORDER BY position, name COLLATE NOCASE")
            .compactMap { row in
                guard let id = row["id"] as? Int64, let name = row["name"] as? String else { return nil }
                return SmartAlbumRow(id: id, name: name,
                                     rules: SmartAlbumRules.decode(row["rules"] as? String ?? ""))
            }
    }

    @discardableResult
    func createSmartAlbum(name: String, rules: SmartAlbumRules) throws -> Int64 {
        try db.run("INSERT INTO smart_albums (name, rules) VALUES (?, ?)", [name, rules.encoded()])
        return db.lastInsertRowID
    }

    func updateSmartAlbum(id: Int64, name: String, rules: SmartAlbumRules) throws {
        try db.run("UPDATE smart_albums SET name = ?, rules = ? WHERE id = ?",
                   [name, rules.encoded(), id])
    }

    func deleteSmartAlbum(id: Int64) throws {
        try db.run("DELETE FROM smart_albums WHERE id = ?", [id])
    }

    // MARK: - Projects

    @discardableResult
    func createProject(name: String, kind: ProjectNode.Kind = .project, parent: Int64? = nil) throws -> Int64 {
        let position = try db.scalarInt(
            "SELECT COALESCE(MAX(position), 0) + 1 FROM projects WHERE parent_id IS ?", [parent])
        try db.run("INSERT INTO projects (name, kind, parent_id, position) VALUES (?, ?, ?, ?)",
                   [name, kind.rawValue, parent, position])
        return db.lastInsertRowID
    }

    func renameProject(id: Int64, name: String) throws {
        try db.run("UPDATE projects SET name = ? WHERE id = ?", [name, id])
    }

    /// Deleting a project leaves its photos in the library (project_id
    /// clears); deleting a folder takes its subtree with it.
    func deleteProject(id: Int64) throws {
        try db.run("DELETE FROM projects WHERE id = ?", [id])
    }

    func moveProject(id: Int64, toParent parent: Int64?) throws {
        if let parent, try projectAndDescendantIDs(id).contains(parent) { return } // no cycles
        try db.run("UPDATE projects SET parent_id = ? WHERE id = ?", [parent, id])
    }

    func setProject(_ projectID: Int64?, photoIDs: [Int64]) throws {
        for id in photoIDs {
            try db.run("UPDATE photos SET project_id = ? WHERE id = ? OR version_of = ?", [projectID, id, id])
        }
    }

    /// A folder or project with everything under it.
    func projectAndDescendantIDs(_ id: Int64) throws -> [Int64] {
        var out = [id]
        var frontier = [id]
        while !frontier.isEmpty {
            let marks = frontier.map { _ in "?" }.joined(separator: ",")
            let children = try db.query("SELECT id FROM projects WHERE parent_id IN (\(marks))",
                                        frontier.map { $0 as Any? }).compactMap { $0["id"] as? Int64 }
            out += children
            frontier = children
        }
        return out
    }

    /// The whole tree, counts rolled up into folders.
    func projectTree() throws -> [ProjectNode] {
        let rows = try db.query("SELECT id, name, kind, parent_id, position FROM projects ORDER BY position, name COLLATE NOCASE")
        var counts: [Int64: Int] = [:]
        for row in try db.query("SELECT project_id, COUNT(*) AS n FROM photos WHERE version_of IS NULL AND project_id IS NOT NULL GROUP BY project_id") {
            if let pid = row["project_id"] as? Int64 { counts[pid] = Int(row["n"] as? Int64 ?? 0) }
        }
        var byParent: [Int64?: [[String: Any]]] = [:]
        for row in rows { byParent[row["parent_id"] as? Int64, default: []].append(row) }
        // Albums inside projects and folders ride along as children.
        var albumsByParent: [Int64: [ProjectNode]] = [:]
        for row in try db.query("""
            SELECT a.id, a.name, a.parent_id, (SELECT COUNT(*) FROM album_items ai WHERE ai.album_id = a.id) AS n
            FROM albums a WHERE a.parent_id IS NOT NULL ORDER BY a.position, a.name COLLATE NOCASE
            """) {
            guard let id = row["id"] as? Int64, let name = row["name"] as? String,
                  let parent = row["parent_id"] as? Int64 else { continue }
            albumsByParent[parent, default: []].append(
                ProjectNode(id: -id, name: name, kind: .album, parentID: parent,
                            count: Int(row["n"] as? Int64 ?? 0), children: nil))
        }
        func build(_ parent: Int64?) -> [ProjectNode] {
            (byParent[parent] ?? []).compactMap { row in
                guard let id = row["id"] as? Int64, let name = row["name"] as? String else { return nil }
                let kind = ProjectNode.Kind(rawValue: row["kind"] as? String ?? "project") ?? .project
                if kind == .folder {
                    let children = build(id) + (albumsByParent[id] ?? [])
                    let total = children.filter { $0.kind != .album }.reduce(0) { $0 + $1.count }
                    return ProjectNode(id: id, name: name, kind: .folder, parentID: parent, count: total, children: children)
                }
                let albums = albumsByParent[id] ?? []
                return ProjectNode(id: id, name: name, kind: .project, parentID: parent,
                                   count: counts[id] ?? 0, children: albums.isEmpty ? nil : albums)
            }
        }
        return build(nil)
    }

    /// Masters with no project — Aperture put every photo in one; ours
    /// may have arrived by folder.
    func unfiledCount() throws -> Int64 {
        try db.scalarInt("SELECT COUNT(*) FROM photos WHERE version_of IS NULL AND project_id IS NULL")
    }

    /// Re-stamp a photo whose file changed on disk (external editor).
    func touchFile(photoID: Int64, url: URL) throws {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970
        let size = attrs?[.size] as? Int64
        try db.run("UPDATE photos SET mtime = ?, file_size = ? WHERE id = ? OR version_of = ?", [mtime, size, photoID, photoID])
    }

    // MARK: - Camera EXIF columns

    struct CameraInfo {
        var camera = ""
        var lens = ""
        var iso: Int?
        var focalLength: Double?
        var aperture: Double?
        var shutter: Double?
        /// When it was taken (seconds since 1970), if known.
        var captureDate: Double?
    }

    /// Write a photo's camera data (and its versions'), mark it read.
    func setCameraInfo(photoID: Int64, _ info: CameraInfo) throws {
        try db.run("""
            UPDATE photos SET camera = ?, lens = ?, iso = ?, focal_length = ?, aperture = ?, shutter = ?, exif_read = 1,
                capture_date = CASE WHEN capture_read = 1 THEN capture_date ELSE COALESCE(?, capture_date) END,
                capture_read = 1
            WHERE id = ? OR version_of = ?
            """, [info.camera, info.lens, info.iso.map { Int64($0) }, info.focalLength, info.aperture, info.shutter,
                  info.captureDate, photoID, photoID])
    }

    /// Masters whose EXIF hasn't been read into the catalog yet.
    /// "name|size" for every master — how the Import window spots files
    /// already in the library (a card's file copied in before, say).
    func knownFileKeys() throws -> Set<String> {
        var keys = Set<String>()
        for row in try db.query("SELECT filename, file_size FROM photos WHERE version_of IS NULL") {
            guard let name = row["filename"] as? String else { continue }
            keys.insert(Self.fileKey(name: name, size: row["file_size"] as? Int64))
        }
        return keys
    }

    func photoPath(_ id: Int64) throws -> String {
        guard let path = try db.query("SELECT path FROM photos WHERE id = ?", [id]).first?["path"] as? String
        else { throw NSError(domain: "Alter", code: 404) }
        return path
    }

    static func fileKey(name: String, size: Int64?) -> String {
        "\(name.lowercased())|\(size ?? -1)"
    }

    /// Adjust Date & Time: move when these were taken by `seconds` (their
    /// versions with them). A photo with no capture date starts from its
    /// file's date. Marked as set, so the EXIF pass never undoes it.
    func shiftCaptureDates(photoIDs: [Int64], by seconds: Double) throws {
        try performBatch {
            for id in photoIDs {
                try db.run("""
                    UPDATE photos SET capture_date = COALESCE(capture_date, mtime, 0) + ?, capture_read = 1
                    WHERE id = ? OR version_of = ?
                    """, [seconds, id, id])
            }
        }
    }

    func photosNeedingExif(limit: Int = 200) throws -> [(id: Int64, url: URL)] {
        try db.query("SELECT id, path FROM photos WHERE version_of IS NULL AND (exif_read = 0 OR capture_read = 0) LIMIT ?",
                     [Int64(limit)])
            .compactMap { row in
                guard let id = row["id"] as? Int64, let path = row["path"] as? String else { return nil }
                return (id, URL(fileURLWithPath: path))
            }
    }

    // MARK: - Keywords

    /// Every keyword in the library with how many masters carry it.
    func keywordVocabulary() throws -> [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        var display: [String: String] = [:]
        for row in try db.query("SELECT keywords FROM photos WHERE version_of IS NULL AND keywords != ''") {
            guard let joined = row["keywords"] as? String else { continue }
            for keyword in PhotoMetadata.splitKeywords(joined) {
                let key = keyword.lowercased()
                counts[key, default: 0] += 1
                display[key] = display[key] ?? keyword
            }
        }
        return counts.map { (display[$0.key] ?? $0.key, $0.value) }
            .sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
    }

    // MARK: - Albums

    @discardableResult
    func createAlbum(name: String, parent: Int64? = nil) throws -> Int64 {
        let position = try db.scalarInt("SELECT COALESCE(MAX(position), 0) + 1 FROM albums")
        try db.run("INSERT INTO albums (name, position, parent_id) VALUES (?, ?, ?)", [name, position, parent])
        return db.lastInsertRowID
    }

    func moveAlbum(id: Int64, toParent parent: Int64?) throws {
        try db.run("UPDATE albums SET parent_id = ? WHERE id = ?", [parent, id])
    }

    func albums() throws -> [AlbumRow] {
        try db.query("SELECT id, name, parent_id FROM albums ORDER BY position, name").compactMap { row in
            guard let id = row["id"] as? Int64, let name = row["name"] as? String else { return nil }
            return AlbumRow(id: id, name: name, parentID: row["parent_id"] as? Int64)
        }
    }

    // MARK: - Keyword hierarchy

    @discardableResult
    func createKeyword(name: String, parent: Int64? = nil) throws -> Int64 {
        if let existing = try db.query(
            "SELECT id FROM keywords WHERE name = ? COLLATE NOCASE AND parent_id IS ?", [name, parent]
        ).first?["id"] as? Int64 {
            return existing
        }
        try db.run("INSERT INTO keywords (name, parent_id) VALUES (?, ?)", [name, parent])
        return db.lastInsertRowID
    }

    func deleteKeyword(id: Int64) throws {
        try db.run("DELETE FROM keywords WHERE id = ?", [id])
    }

    func keywordTree() throws -> [KeywordNode] {
        let rows = try db.query("SELECT id, name, parent_id FROM keywords ORDER BY name COLLATE NOCASE")
        var byParent: [Int64?: [(Int64, String)]] = [:]
        for row in rows {
            guard let id = row["id"] as? Int64, let name = row["name"] as? String else { continue }
            byParent[row["parent_id"] as? Int64, default: []].append((id, name))
        }
        func build(_ parent: Int64?) -> [KeywordNode] {
            (byParent[parent] ?? []).map { id, name in
                let children = build(id)
                return KeywordNode(id: id, name: name, parentID: parent, children: children.isEmpty ? nil : children)
            }
        }
        return build(nil)
    }

    func renameAlbum(id: Int64, name: String) throws {
        try db.run("UPDATE albums SET name = ? WHERE id = ?", [name, id])
    }

    func deleteAlbum(id: Int64) throws {
        try db.run("DELETE FROM albums WHERE id = ?", [id])
    }

    func addToAlbum(albumID: Int64, photoIDs: [Int64]) throws {
        var position = try db.scalarInt(
            "SELECT COALESCE(MAX(position), 0) FROM album_items WHERE album_id = ?", [albumID])
        for photoID in photoIDs {
            position += 1
            try db.run(
                "INSERT OR IGNORE INTO album_items (album_id, photo_id, position) VALUES (?, ?, ?)",
                [albumID, photoID, position])
        }
    }

    func removeFromAlbum(albumID: Int64, photoIDs: [Int64]) throws {
        for photoID in photoIDs {
            try db.run("DELETE FROM album_items WHERE album_id = ? AND photo_id = ?", [albumID, photoID])
        }
    }
}
