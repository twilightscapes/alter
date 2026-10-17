//
//  ApertureImporter.swift
//  Alter
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
//  Builds an ALTer catalog beside an Aperture library: X.alterlib next to
//  X.aplibrary, referencing the masters where they already sit inside the
//  bundle. The bundle is only ever read. Projects become albums (with their
//  folder path in the name), user albums carry over, smart albums translate
//  where their rules have an ALTer equivalent, stacks and versions map onto
//  ALTer's own, and every version's adjustments become a recipe.
//

import Foundation
import ImageIO

enum ApertureImporter {
    struct Progress {
        var phase: String
        var done: Int
        var total: Int
    }

    struct Summary {
        var masters = 0
        var versions = 0
        var missingFiles = 0
        var albums = 0
        var projects = 0
        var smartAlbums = 0
        var smartAlbumsAsPlain = 0
        var stacks = 0
        var adjustedVersions = 0
        /// Versions whose exposure/white balance were nudged to match
        /// Aperture's own render (decoder differences, unknown as-shot WB).
        var matchedToPreview = 0
        var report = ApertureTranslator.Report()

        var headline: String {
            var parts = ["\(masters) photo\(masters == 1 ? "" : "s")"]
            if versions > 0 { parts.append("\(versions) extra version\(versions == 1 ? "" : "s")") }
            if projects > 0 { parts.append("\(projects) project\(projects == 1 ? "" : "s")") }
            if albums > 0 { parts.append("\(albums) album\(albums == 1 ? "" : "s")") }
            if stacks > 0 { parts.append("\(stacks) stack\(stacks == 1 ? "" : "s")") }
            return parts.joined(separator: ", ")
        }
    }

    enum ImportError: LocalizedError {
        case catalogExists(URL)
        case alreadyImported(String)
        var errorDescription: String? {
            switch self {
            case .catalogExists(let url):
                return "There's already an Alter library at \(url.lastPathComponent)."
            case .alreadyImported(let name):
                return "\(name) is already in this library."
            }
        }
    }

    /// The default home for the catalog: beside the bundle, same name.
    static func defaultCatalogURL(for bundle: URL) -> URL {
        bundle.deletingPathExtension().appendingPathExtension(Catalog.fileExtension)
    }

    /// Reads the bundle and writes the catalog. Call off the main thread;
    /// `progress` is called on the caller's thread.
    ///
    /// `merge`: import into an existing catalog (File ▸ Import ▸ Aperture
    /// Library) instead of building a new one. The library arrives as one
    /// top-level folder named after it, its own folders, projects and
    /// albums inside; the first time, the catalog's own Aperture library is
    /// gathered into a folder of its name the same way.
    static func run(bundle: URL, catalogURL: URL, matchRenders: Bool = true, merge: Bool = false,
                    progress: @escaping (Progress) -> Void) throws -> Summary {
        let fm = FileManager.default
        if !merge, Catalog.isLibrary(catalogURL) { throw ImportError.catalogExists(catalogURL) }
        let bundlePath = bundle.standardizedFileURL.path
        let libraryName = bundle.deletingPathExtension().lastPathComponent
        if merge, let existing = try? Catalog(libraryURL: catalogURL),
           existing.aperturePaths.contains(bundlePath) {
            throw ImportError.alreadyImported(libraryName)
        }

        progress(Progress(phase: "Reading the Aperture library…", done: 0, total: 1))
        let ap = try ApertureLibrary(bundleURL: bundle)
        let masters = try ap.masters()
        let versions = try ap.versions()
        let metadata = try ap.metadataByVersionId()
        let cameraInfo = try ap.cameraInfoByVersionId()
        let stacks = try ap.stacks()
        let albums = try ap.albums()
        let projects = try ap.projects()

        // Versions grouped per master, working version first.
        var byMaster: [String: [ApertureLibrary.Version]] = [:]
        for v in versions { byMaster[v.masterUuid, default: []].append(v) }
        for key in byMaster.keys { byMaster[key]?.sort { $0.versionNumber < $1.versionNumber } }

        // Masters in capture order so the catalog ids read chronologically.
        let orderedMasters = masters.values
            .filter { byMaster[$0.uuid] != nil }
            .sorted { ($0.imageDate ?? 0, $0.fileName) < ($1.imageDate ?? 0, $1.fileName) }

        let catalog = try Catalog(libraryURL: catalogURL)
        var summary = Summary()
        var photoIDByVersionUuid: [String: Int64] = [:]
        var masterIDByVersionUuid: [String: Int64] = [:]
        var masterIDByVersionModelId: [Int64: Int64] = [:]
        var masterIDByProject: [String: [Int64]] = [:]

        try catalog.performBatch {
            // Where this library's projects and albums go: the top of the
            // catalog when it's the catalog's own library, a folder named
            // after it when it's imported into one.
            var root: Int64?
            if merge {
                let known = catalog.aperturePaths
                if catalog.metaValue("source") == "aperture", known.count == 1, let first = known.first {
                    try catalog.groupTopLevel(
                        intoFolderNamed: URL(fileURLWithPath: first).deletingPathExtension().lastPathComponent)
                }
                root = try catalog.createProject(name: libraryName, kind: .folder, parent: nil)
                try catalog.setAperturePaths(known + [bundlePath])
            } else {
                try catalog.setMetaValue("source", "aperture")
                try catalog.setMetaValue("aperture_path", bundlePath)
                try catalog.setMetaValue("aperture_format", ap.formatDescription)
                try catalog.setAperturePaths([bundlePath])
            }

            let folderID = try catalog.addFolder(path: bundle.appendingPathComponent("Masters").path)

            let total = orderedMasters.count
            for (index, master) in orderedMasters.enumerated() {
                if index % 10 == 0 {
                    progress(Progress(phase: matchRenders ? "Reading photos and matching Aperture's renders…"
                                                          : "Reading photos…", done: index, total: total))
                }
                guard let family = byMaster[master.uuid], let working = family.first else { continue }
                let url = ap.fileURL(for: master)
                if master.isMissing || !fm.fileExists(atPath: url.path) { summary.missingFiles += 1 }
                // Aperture's rotation already includes the camera's
                // orientation; the recipe must not apply the file's flag too.
                let fileIsTurned = Self.orientationIsTurned(url)

                // As-shot white balance, if any sibling version still has
                // Aperture's defaults — lets edited WB translate as a shift.
                var asShot: (Double, Double)?
                var familyAdjustments: [String: [ApertureLibrary.Adjustment]] = [:]
                for v in family {
                    let adjs = try ap.adjustments(forVersion: v.uuid)
                    familyAdjustments[v.uuid] = adjs
                    if asShot == nil, let wb = adjs.first(where: { $0.name == "RKWhiteBalanceOperation" }),
                       wb.parameters["inputIsDefaults"] as? Bool == true,
                       let k = wb.parameters["inputTemperature"] as? Double {
                        asShot = (k, wb.parameters["inputTint"] as? Double ?? 0)
                    }
                }

                func recipe(for v: ApertureLibrary.Version) -> PhotoEdits {
                    let context = ApertureTranslator.Context(
                        masterWidth: v.masterWidth, masterHeight: v.masterHeight,
                        rotation: v.rotation, asShotKelvin: asShot?.0, asShotTint: asShot?.1,
                        maskURL: { ap.maskURL(for: $0) })
                    var edits = ApertureTranslator.edits(from: familyAdjustments[v.uuid] ?? [],
                                                         context: context, report: &summary.report)
                    if fileIsTurned { edits.rawOrientation = true }
                    // Tone or colour was edited: nudge the recipe until our
                    // render agrees with Aperture's on brightness and balance.
                    if matchRenders, ApertureMatcher.touchesToneOrColor(edits),
                       let preview = ap.previewURL(for: v, master: master),
                       let matched = ApertureMatcher.match(edits, masterURL: url, previewURL: preview) {
                        edits = matched
                        summary.matchedToPreview += 1
                    }
                    return edits
                }

                // The working version is the master row; its metadata is
                // the file's metadata as far as ALTer is concerned.
                let meta = metadata[working.modelId] ?? ApertureLibrary.Metadata()
                var photoMeta = PhotoMetadata()
                photoMeta.title = meta.title
                photoMeta.caption = meta.caption
                photoMeta.creator = meta.creator
                photoMeta.copyright = meta.copyright
                photoMeta.keywords = meta.keywords
                let masterID = try catalog.insertPhoto(url: url, folderID: folderID, metadata: photoMeta)
                summary.masters += 1
                // Aperture's date for the photo (seconds since 2001) — which
                // includes any Adjust Time made there.
                var camera = cameraInfo[working.modelId] ?? Catalog.CameraInfo()
                camera.captureDate = master.imageDate.map { $0 + Date.timeIntervalBetween1970AndReferenceDate }
                if cameraInfo[working.modelId] != nil || camera.captureDate != nil {
                    try catalog.setCameraInfo(photoID: masterID, camera)
                }
                try apply(working, to: masterID, recipe: recipe(for: working), in: catalog,
                          master: master, ap: ap, summary: &summary)
                photoIDByVersionUuid[working.uuid] = masterID
                masterIDByVersionUuid[working.uuid] = masterID
                masterIDByVersionModelId[working.modelId] = masterID
                if let project = working.projectUuid {
                    masterIDByProject[project, default: []].append(masterID)
                }

                for v in family.dropFirst() {
                    let name = versionName(for: v.name, master: working.name)
                    let id = try catalog.createVersion(of: masterID, edits: recipe(for: v), name: name)
                    summary.versions += 1
                    try apply(v, to: id, recipe: nil, in: catalog, master: master, ap: ap,
                              summary: &summary)
                    photoIDByVersionUuid[v.uuid] = id
                    masterIDByVersionUuid[v.uuid] = masterID
                    masterIDByVersionModelId[v.modelId] = masterID
                }
            }

            // Stacks: Aperture stacks versions; ALTer stacks masters.
            progress(Progress(phase: "Stacks and albums…", done: total, total: total))
            for stack in stacks {
                let ids = unique(stack.versionUuids.compactMap { masterIDByVersionUuid[$0] })
                guard ids.count >= 2 else { continue }
                let pick = stack.pickVersionUuid.flatMap { masterIDByVersionUuid[$0] } ?? ids[0]
                _ = try catalog.createStack(photoIDs: ids, pick: pick)
                summary.stacks += 1
            }

            // Projects → projects, under their folders.
            var folderIDs: [String: Int64] = [:]
            func folder(for path: [String]) throws -> Int64? {
                var parent: Int64? = root
                var key = ""
                for name in path {
                    key += "/" + name
                    if let known = folderIDs[key] { parent = known; continue }
                    let id = try catalog.createProject(name: name, kind: .folder, parent: parent)
                    folderIDs[key] = id
                    parent = id
                }
                return parent
            }
            var projectIDByUuid: [String: Int64] = [:]
            for project in projects {
                guard let ids = masterIDByProject[project.uuid], !ids.isEmpty else { continue }
                let parent = try folder(for: project.folderPath)
                let projectID = try catalog.createProject(name: project.name, kind: .project, parent: parent)
                try catalog.setProject(projectID, photoIDs: unique(ids))
                projectIDByUuid[project.uuid] = projectID
                summary.projects += 1
            }

            // The keyword library, hierarchy and all.
            var keywordIDByAperture: [Int64: Int64] = [:]
            let entries = try ap.keywordLibrary()
            var remaining = entries
            var guardRounds = 0
            while !remaining.isEmpty, guardRounds < 32 {
                guardRounds += 1
                var next: [ApertureLibrary.KeywordEntry] = []
                for entry in remaining {
                    if let parent = entry.parentId {
                        guard let mapped = keywordIDByAperture[parent] else { next.append(entry); continue }
                        keywordIDByAperture[entry.id] = try catalog.createKeyword(name: entry.name, parent: mapped)
                    } else {
                        keywordIDByAperture[entry.id] = try catalog.createKeyword(name: entry.name, parent: nil)
                    }
                }
                remaining = next
            }

            // User albums and smart albums.
            for album in albums {
                if album.subclass == 2 {
                    if let rules = smartRules(from: album.smartQuery) {
                        // Smart albums search the whole catalog; an imported
                        // library's say whose they were.
                        _ = try catalog.createSmartAlbum(name: merge ? "\(album.name) (\(libraryName))" : album.name,
                                                         rules: rules)
                        summary.smartAlbums += 1
                        continue
                    }
                    // Rules we can't express: keep its current members.
                    let ids = unique(album.versionIds.compactMap { masterIDByVersionModelId[$0] })
                    guard !ids.isEmpty else { continue }
                    let albumID = try catalog.createAlbum(name: album.name + " (from Aperture smart album)",
                                                          parent: root)
                    try catalog.addToAlbum(albumID: albumID, photoIDs: ids)
                    summary.smartAlbumsAsPlain += 1
                } else {
                    let ids = unique(album.versionIds.compactMap { masterIDByVersionModelId[$0] })
                    guard !ids.isEmpty else { continue }
                    let container = album.folderUuid.flatMap { projectIDByUuid[$0] } ?? root
                    let albumID = try catalog.createAlbum(name: album.name, parent: container)
                    try catalog.addToAlbum(albumID: albumID, photoIDs: ids)
                    summary.albums += 1
                }
            }
        }
        progress(Progress(phase: "Done", done: 1, total: 1))
        return summary
    }

    /// Per-row state: rating, flag, label, recipe, Aperture's own render.
    private static func apply(_ v: ApertureLibrary.Version, to id: Int64, recipe: PhotoEdits?,
                              in catalog: Catalog, master: ApertureLibrary.Master,
                              ap: ApertureLibrary, summary: inout Summary) throws {
        if v.rating > 0 { try catalog.setRating(photoID: id, rating: v.rating) }
        if v.isFlagged { try catalog.setFlagged(photoID: id, flagged: true) }
        if (1...7).contains(v.colorLabelIndex) {
            try catalog.setLabel(photoID: id, label: v.colorLabelIndex)
        }
        if let recipe, !recipe.isNeutral {
            try catalog.updateEdits(photoID: id, recipe)
        }
        if v.hasEnabledAdjustments { summary.adjustedVersions += 1 }
        if let preview = ap.previewURL(for: v, master: master) {
            try catalog.setReferencePath(photoID: id, preview.path)
        }
    }

    /// "IMG_6163 - Version 2" → "Version 2" when it's Aperture's default
    /// naming; a custom name stays as typed.
    private static func versionName(for name: String, master: String) -> String {
        let prefix = master + " - "
        return name.hasPrefix(prefix) ? String(name.dropFirst(prefix.count)) : name
    }

    private static func unique(_ ids: [Int64]) -> [Int64] {
        var seen = Set<Int64>()
        return ids.filter { seen.insert($0).inserted }
    }

    // MARK: - Smart album rules

    /// Aperture's RKSingleItemQuery predicates → ALTer rules, for the
    /// properties both understand. nil when any enabled rule is foreign.
    static func smartRules(from query: [String: Any]?) -> SmartAlbumRules? {
        guard let query, let subs = query["querySubqueries"] as? [Any] else { return nil }
        var rules: [SmartAlbumRule] = []
        for case let sub as [String: Any] in subs {
            guard sub["queryIsEnabled"] as? Bool ?? true else { continue }
            guard let key = sub["queryPropertyKey"] as? String else { return nil }
            let value = sub["queryFirstValue"]
            let qualifier = sub["queryQualifier"] as? Int ?? 0
            switch key {
            case "basicProperties.MainRating", "MainRating":
                let n = (value as? Int) ?? Int((value as? Double) ?? 0)
                // Aperture rates "N or better" by default.
                rules.append(SmartAlbumRule(field: .rating,
                                            op: qualifier == 3 ? .is : .atLeast,
                                            value: String(max(0, min(5, n)))))
            case "basicProperties.isFlagged", "isFlagged":
                let on = (value as? Bool) ?? ((value as? Int ?? 1) != 0)
                rules.append(SmartAlbumRule(field: .flagged, op: .is, value: on ? "yes" : "no"))
            case "basicProperties.ColorLabel", "colorLabelIndex", "ColorLabel":
                let n = (value as? Int) ?? Int((value as? Double) ?? 0)
                guard (0...7).contains(n) else { return nil }
                rules.append(SmartAlbumRule(field: .label, op: .is, value: String(max(0, n))))
            case "keywords", "Keywords", "basicProperties.Keywords":
                guard let text = value as? String, !text.isEmpty else { return nil }
                rules.append(SmartAlbumRule(field: .keyword, op: .contains, value: text))
            case "fileName", "FileName", "basicProperties.FileName":
                guard let text = value as? String, !text.isEmpty else { return nil }
                rules.append(SmartAlbumRule(field: .filename, op: .contains, value: text))
            case "basicProperties.isAdjusted", "hasEnabledAdjustments":
                let on = (value as? Bool) ?? ((value as? Int ?? 1) != 0)
                rules.append(SmartAlbumRule(field: .adjusted, op: .is, value: on ? "yes" : "no"))
            case "LensModel", "exifProperties.LensModel":
                guard let text = value as? String, !text.isEmpty else { return nil }
                rules.append(SmartAlbumRule(field: .lens, op: .contains, value: text))
            case "Model", "Make", "exifProperties.Model", "exifProperties.Make":
                guard let text = value as? String, !text.isEmpty else { return nil }
                rules.append(SmartAlbumRule(field: .camera, op: .contains, value: text))
            case "ISOSpeedRating", "exifProperties.ISOSpeedRating":
                let n = (value as? Int) ?? Int((value as? Double) ?? 0)
                rules.append(SmartAlbumRule(field: .iso, op: qualifier == 2 ? .atMost : .atLeast, value: String(n)))
            case "FocalLength", "exifProperties.FocalLength":
                let n = (value as? Double) ?? Double((value as? Int) ?? 0)
                rules.append(SmartAlbumRule(field: .focalLength, op: qualifier == 2 ? .atMost : .atLeast, value: String(Int(n))))
            default:
                return nil
            }
        }
        guard !rules.isEmpty else { return nil }
        // queryMatchType: 1 = all of the rules, anything else = any.
        let matchAll = (query["queryMatchType"] as? Int ?? 1) == 1
        return SmartAlbumRules(matchAll: matchAll, rules: rules)
    }
}

extension ApertureImporter {
    /// The file's EXIF orientation flag is anything but "up" (1). Aperture
    /// folds that orientation into its version rotation, so those masters
    /// are drawn from raw pixels (PhotoEdits.rawOrientation).
    static func orientationIsTurned(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let o = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue else { return false }
        return o != 1
    }
}
