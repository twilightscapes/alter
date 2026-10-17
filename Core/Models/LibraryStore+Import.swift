//
//  LibraryStore+Import.swift
//  Alter
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
//  What the Import window decided, carried out: copy (and rename) or
//  reference in place, catalogue, file into projects, stamp metadata,
//  eject the card.
//

import AppKit

/// The Import window's choices.
struct ImportPlan {
    enum Project: Hashable {
        /// Whatever project is selected in the sidebar (or none).
        case current
        /// A new project with this name.
        case new(String)
        /// One project per day of shooting, named by the day.
        case byDay
    }

    var files: [URL]
    /// Copy into this folder first; nil = reference the files where they are.
    var copyTo: URL?
    /// Rename while copying (a naming preset's pattern); nil = keep names.
    var namingPattern: String?
    var project: Project = .current
    var creator = ""
    var copyright = ""
    var keywords = ""
    /// Eject this volume when done.
    var eject: URL?
}

extension LibraryStore {
    func runImport(_ plan: ImportPlan) async {
        guard isOpen, !plan.files.isEmpty else { return }
        var urls = plan.files

        // 1. Copy (and rename) into the chosen folder.
        if let folder = plan.copyTo {
            isWorking = true
            statusMessage = "Copying \(urls.count) file\(urls.count == 1 ? "" : "s")…"
            let pattern = plan.namingPattern
            let total = urls.count
            let copied: [URL] = await Task.detached(priority: .userInitiated) {
                let fm = FileManager.default
                try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
                var out: [URL] = []
                for (index, source) in plan.files.enumerated() {
                    let base = pattern.map {
                        Self.expandImportName($0, source: source, sequence: index + 1, total: total)
                    } ?? source.deletingPathExtension().lastPathComponent
                    let dest = Self.uniqueURL(in: folder, base: base, ext: source.pathExtension)
                    guard (try? fm.copyItem(at: source, to: dest)) != nil else { continue }
                    // A sidecar travels with its photo.
                    for sidecarExt in ["xmp", "XMP"] {
                        let sidecar = source.deletingPathExtension().appendingPathExtension(sidecarExt)
                        if fm.fileExists(atPath: sidecar.path) {
                            try? fm.copyItem(at: sidecar,
                                             to: dest.deletingPathExtension().appendingPathExtension(sidecarExt))
                        }
                    }
                    out.append(dest)
                }
                return out
            }.value
            isWorking = false
            urls = copied
        }

        // 2. Into the catalog (into the selected project, as ever).
        let ids = await importURLs(urls)
        guard !ids.isEmpty, let catalog else { return }

        // 3. Projects.
        switch plan.project {
        case .current:
            break
        case .new(let name):
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty, let project = try? catalog.createProject(name: trimmed) {
                try? catalog.setProject(project, photoIDs: ids)
            }
        case .byDay:
            // Paths read here (the catalog stays on this thread); the EXIF
            // dates off it.
            let paths = ids.compactMap { id in (try? catalog.photoPath(id)).map { (id, $0) } }
            let days: [(Int64, String)] = await Task.detached(priority: .userInitiated) {
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd"
                return paths.map { id, path -> (Int64, String) in
                    let url = URL(fileURLWithPath: path)
                    let taken = ExifReader.read(url: url).captureTimestamp
                        ?? ((try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date)?
                            .timeIntervalSince1970 ?? Date().timeIntervalSince1970
                    return (id, formatter.string(from: Date(timeIntervalSince1970: taken)))
                }
            }.value
            var projectForDay: [String: Int64] = [:]
            for (id, day) in days {
                if projectForDay[day] == nil {
                    projectForDay[day] = try? catalog.createProject(name: day)
                }
                if let project = projectForDay[day] { try? catalog.setProject(project, photoIDs: [id]) }
            }
        }

        // 4. Metadata for everything that came in.
        let creator = plan.creator.trimmingCharacters(in: .whitespaces)
        let copyright = plan.copyright.trimmingCharacters(in: .whitespaces)
        let keywords = PhotoMetadata.splitKeywords(plan.keywords)
        if !creator.isEmpty || !copyright.isEmpty || !keywords.isEmpty {
            for id in ids {
                editMetadata(id) { meta in
                    if !creator.isEmpty { meta.creator = creator }
                    if !copyright.isEmpty { meta.copyright = copyright }
                    for k in keywords where !meta.keywords.contains(where: { $0.caseInsensitiveCompare(k) == .orderedSame }) {
                        meta.keywords.append(k)
                    }
                }
            }
            reloadKeywordVocabulary()
        }

        reloadSidebar()
        reloadItems()

        // 5. Eject the card.
        if let volume = plan.eject {
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: volume)
                statusMessage += " \(volume.lastPathComponent) ejected."
            } catch {
                statusMessage += " Couldn't eject \(volume.lastPathComponent): \(error.localizedDescription)"
            }
        }
    }

    /// A naming preset's pattern for a file being imported: {name}, {seq},
    /// {date} (when it was taken), {title} (the name — nothing's titled yet).
    nonisolated static func expandImportName(_ pattern: String, source: URL, sequence: Int, total: Int) -> String {
        let name = source.deletingPathExtension().lastPathComponent
        let seq = String(format: "%0\(max(3, String(total).count))d", sequence)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let taken = ExifReader.read(url: source).captureTimestamp.map { Date(timeIntervalSince1970: $0) }
            ?? ((try? FileManager.default.attributesOfItem(atPath: source.path)[.modificationDate]) as? Date)
            ?? Date()
        let expanded = pattern
            .replacingOccurrences(of: "{name}", with: name)
            .replacingOccurrences(of: "{title}", with: name)
            .replacingOccurrences(of: "{seq}", with: seq)
            .replacingOccurrences(of: "{date}", with: formatter.string(from: taken))
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
        return expanded.isEmpty ? name : expanded
    }

    /// folder/base.ext, or base-2.ext, base-3.ext… — never overwrite.
    nonisolated static func uniqueURL(in folder: URL, base: String, ext: String) -> URL {
        var candidate = folder.appendingPathComponent(base).appendingPathExtension(ext)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base)-\(n)").appendingPathExtension(ext)
            n += 1
        }
        return candidate
    }
}
