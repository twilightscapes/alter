//
//  LibraryStore.swift
//  Alter
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
//  The open library: catalog access, current source, selection, generation,
//  and save-to-files. Referenced originals only — the catalog indexes and
//  caches edits; exiftool writes them into the files on save.
//

import AppKit
import AVFoundation
import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class LibraryStore: ObservableObject {
    @Published var catalog: Catalog?
    @Published var items: [PhotoItem] = []
    @Published var selection: Set<Int64> = []
    @Published var source: LibrarySource? = .all {
        didSet { reloadItems() }
    }

    @Published var folders: [FolderRow] = []
    @Published var albums: [AlbumRow] = []
    @Published var smartAlbums: [SmartAlbumRow] = []
    /// Aperture's projects and folders, as a tree.
    @Published var projects: [ProjectNode] = []
    @Published var unfiledCount: Int64 = 0
    /// Stack id → pick/collapsed/size, for badges and collapse logic.
    @Published var stackInfo: [Int64: (pick: Int64?, collapsed: Bool, count: Int)] = [:]
    /// Master id → number of versions, for the grid badge.
    @Published var versionCounts: [Int64: Int] = [:]
    /// Masters whose versions are shown inline after them.
    @Published var expandedVersionMasters: Set<Int64> = []
    /// Browser-bar colour-label filter (PhotoLabel rawValue); nil = any.
    @Published var labelFilter: Int? = nil { didSet { reloadItems() } }
    @Published var allCount: Int64 = 0
    @Published var noAltCount: Int64 = 0
    @Published var dirtyCount: Int64 = 0

    @Published var isWorking = false
    @Published var statusMessage = ""
    @Published var exiftoolMissing = !ExifToolService.isAvailable
    /// Errors worth a real dialog (export/publish failures), not just status text.
    @Published var alertMessage: String?
    /// Title for the alertMessage alert; nil = "Something went wrong".
    @Published var alertTitle: String?
    /// The grid scrolls this photo into view (fresh imports), then clears it.
    @Published var revealID: Int64?

    /// Automatically write edits into the files shortly after editing stops.
    /// (Catalog caching is always immediate; this controls the file write-back.)
    @Published var autosaveToFiles: Bool {
        didSet {
            UserDefaults.standard.set(autosaveToFiles, forKey: Self.autosaveKey)
            if autosaveToFiles { scheduleAutosave() } else { autosaveTask?.cancel() }
        }
    }

    private var autosaveTask: Task<Void, Never>?
    private var isSaving = false

    private static let lastLibraryKey = "alter_last_library_path"
    private static let autosaveKey = "alter_autosave_to_files"

    init() {
        // Default ON — fields should just save.
        if UserDefaults.standard.object(forKey: Self.autosaveKey) == nil {
            autosaveToFiles = true
        } else {
            autosaveToFiles = UserDefaults.standard.bool(forKey: Self.autosaveKey)
        }
        // Coming back from an external editor: see whether the file changed.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.pickUpExternalEdits() }
        }
    }

    var isOpen: Bool { catalog != nil }
    /// True for a library that reads an Aperture bundle: metadata and
    /// adjustments live in ALTer's catalog, the originals are never written.
    var originalsAreReadOnly: Bool { catalog?.originalsAreReadOnly ?? false }
    /// Does any of this library read an Aperture library in place?
    var hasApertureLibraries: Bool { !(catalog?.aperturePaths.isEmpty ?? true) }
    /// Originals inside an Aperture library are never written to.
    func isApertureOriginal(_ item: PhotoItem) -> Bool {
        catalog?.isApertureOriginal(item.url.path) ?? false
    }
    /// Non-nil while an Aperture library is being read in.
    @Published var apertureProgress: ApertureImporter.Progress?

    var libraryName: String {
        catalog?.libraryURL.deletingPathExtension().lastPathComponent ?? "Alter"
    }
    var selectedItems: [PhotoItem] { items.filter { selection.contains($0.id) } }

    // MARK: - Library lifecycle

    func openLastLibraryIfAvailable() {
        guard catalog == nil,
              let path = UserDefaults.standard.string(forKey: Self.lastLibraryKey) else { return }
        let url = URL(fileURLWithPath: path)
        if Catalog.isLibrary(url) {
            open(libraryURL: url)
        } else {
            // The library isn't where it was — someone moved or renamed it.
            // Silence here read as "ALTer lost my photos"; a locate dialog
            // reads as what actually happened.
            presentMissingLibraryAlert(lastPath: path)
        }
    }

    private func presentMissingLibraryAlert(lastPath: String) {
        // A Finder-opened library (double-click, `open`) arrives a beat after
        // the window appears; give it that beat, then re-check — the missing
        // last library is moot if something else is opening.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let store = self, store.catalog == nil, !ALTerAppDelegate.hasPendingOpen,
                  store.apertureProgress == nil else { return }
            let alert = NSAlert()
            alert.messageText = "Your library isn't where it was"
            alert.informativeText = """
            Alter last opened “\(URL(fileURLWithPath: lastPath).lastPathComponent)” at:

            \(URL(fileURLWithPath: lastPath).deletingLastPathComponent().path)

            If you moved it, point Alter at its new home — everything inside is intact. Your photos are never stored in the library, so they're unaffected either way.
            """
            alert.addButton(withTitle: "Locate Library…")
            alert.addButton(withTitle: "New Library…")
            alert.addButton(withTitle: "Later")
            switch alert.runModal() {
            case .alertFirstButtonReturn: self?.presentOpenLibraryPanel()
            case .alertSecondButtonReturn: self?.presentNewLibraryPanel()
            default: break
            }
        }
    }

    /// Does this path live somewhere iCloud syncs? A live SQLite catalog in
    /// a synced folder is a corruption recipe (mid-write snapshots,
    /// "conflicted copy" forks) — Photos.app keeps its library out of
    /// iCloud Drive for the same reason. Checks the nearest EXISTING
    /// ancestor so brand-new library paths resolve too, and note that
    /// Desktop & Documents sync makes ~/Desktop ubiquitous.
    static func locationSyncsViaICloud(_ url: URL) -> Bool {
        let fm = FileManager.default
        var probe = url.standardizedFileURL
        while !fm.fileExists(atPath: probe.path) {
            let parent = probe.deletingLastPathComponent()
            if parent.path == probe.path { break }
            probe = parent
        }
        if let values = try? probe.resourceValues(forKeys: [.isUbiquitousItemKey]),
           values.isUbiquitousItem == true {
            return true
        }
        return probe.path.contains("Mobile Documents")
    }

    /// Every way a library is adopted (new, open, Finder double-click)
    /// funnels through here: iCloud-synced locations get a warning first.
    /// Originals in iCloud are fine — ALTer materializes evicted files —
    /// it's the CATALOG that must stay on plain local disk.
    func adoptLibrary(_ url: URL, chooseAgain: (() -> Void)? = nil) {
        guard Self.locationSyncsViaICloud(url) else {
            open(libraryURL: url)
            return
        }
        let alert = NSAlert()
        alert.messageText = "That location syncs through iCloud"
        alert.informativeText = """
        iCloud can copy the library's catalog mid-write or fork it into "conflicted copies," which corrupts it.

        Keep the library in a local folder like Pictures. Your photos can live in iCloud — Alter reads them fine there — it's the library itself that shouldn't.
        """
        if chooseAgain != nil {
            alert.addButton(withTitle: "Choose Another Location…")
        }
        alert.addButton(withTitle: "Use It Anyway")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        if chooseAgain != nil {
            switch response {
            case .alertFirstButtonReturn: chooseAgain?()
            case .alertSecondButtonReturn: open(libraryURL: url)
            default: break
            }
        } else if response == .alertFirstButtonReturn {
            open(libraryURL: url)
        }
    }

    func open(libraryURL: URL) {
        // Already open (launch can ask twice: last library, then the Finder
        // URL) — don't tear the catalog down and rebuild it.
        if let catalog, catalog.libraryURL.standardizedFileURL == libraryURL.standardizedFileURL { return }
        do {
            catalog = try Catalog(libraryURL: libraryURL)
            UserDefaults.standard.set(libraryURL.path, forKey: Self.lastLibraryKey)
            noteRecentLibrary(libraryURL)
            selection = []
            source = .all
            browserRules = nil
            reloadSidebar()
            reloadItems()
            statusMessage = "Opened \(libraryName)."
            // SwiftUI hands the first text field focus once the window is
            // up; take it back so the keys work from the first moment.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.takeKeyboardFromTextFields()
            }
            backfillExifIfNeeded()
        } catch {
            statusMessage = error.localizedDescription
            catalog = nil
        }
    }

    func presentNewLibraryPanel() {
        let panel = NSSavePanel()
        panel.title = "New Library"
        panel.nameFieldStringValue = "Media.\(Catalog.fileExtension)"
        panel.canCreateDirectories = true
        // ~/Pictures is where a Mac photo library belongs (Photos and
        // Aperture both) — the Desktop is just where test libraries happen.
        panel.directoryURL = FileManager.default.urls(
            for: .picturesDirectory, in: .userDomainMask).first
        panel.begin { [weak self] response in
            guard response == .OK, var url = panel.url, let self else { return }
            if url.pathExtension != Catalog.fileExtension {
                url.appendPathExtension(Catalog.fileExtension)
            }
            self.adoptLibrary(url, chooseAgain: { self.presentNewLibraryPanel() })
        }
    }

    func presentOpenLibraryPanel() {
        let panel = NSOpenPanel()
        panel.title = "Open Library"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.message = "Choose a .\(Catalog.fileExtension) library"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            if Catalog.isLibrary(url) {
                self.adoptLibrary(url, chooseAgain: { self.presentOpenLibraryPanel() })
            } else {
                self.statusMessage = "That isn't an Alter library."
            }
        }
    }

    // MARK: - Aperture libraries

    func presentOpenApertureLibraryPanel() {
        let panel = NSOpenPanel()
        panel.title = "Open Aperture Library"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.message = "Choose an .aplibrary — Alter reads it in place and never modifies it"
        panel.directoryURL = FileManager.default.urls(
            for: .picturesDirectory, in: .userDomainMask).first
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            if ApertureLibrary.isApertureLibrary(url) {
                self.adoptApertureLibrary(url)
            } else {
                self.statusMessage = "That isn't an Aperture library."
            }
        }
    }

    /// Opening an Aperture library means: an ALTer catalog beside it
    /// (X.alterlib next to X.aplibrary) that references the masters where
    /// they sit. If that catalog already exists, just open it; otherwise
    /// build it, then open it. The bundle itself is read-only throughout.
    func adoptApertureLibrary(_ bundle: URL, catalogURL: URL? = nil) {
        let target = catalogURL ?? ApertureImporter.defaultCatalogURL(for: bundle)
        if Catalog.isLibrary(target) {
            // A catalog that never finished building (a crash mid-read)
            // has no photos: don't open an empty library, start over.
            let count = (try? Catalog(libraryURL: target).counts().all) ?? 0
            let finished = count > 0
            if finished {
                adoptLibrary(target)
                return
            }
            try? FileManager.default.removeItem(at: target)
        }
        if Self.locationSyncsViaICloud(target) {
            let alert = NSAlert()
            alert.messageText = "That location syncs through iCloud"
            alert.informativeText = """
            Alter keeps its own catalog beside the Aperture library. iCloud can copy a live catalog mid-write or fork it into "conflicted copies," which corrupts it.

            You can put the catalog somewhere local instead — the Aperture library stays where it is either way.
            """
            alert.addButton(withTitle: "Choose a Location for the Catalog…")
            alert.addButton(withTitle: "Use It Anyway")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                let panel = NSSavePanel()
                panel.title = "Alter Catalog for \(bundle.deletingPathExtension().lastPathComponent)"
                panel.nameFieldStringValue = target.lastPathComponent
                panel.canCreateDirectories = true
                panel.directoryURL = FileManager.default.urls(
                    for: .picturesDirectory, in: .userDomainMask).first
                panel.begin { [weak self] response in
                    guard response == .OK, var url = panel.url else { return }
                    if url.pathExtension != Catalog.fileExtension {
                        url.appendPathExtension(Catalog.fileExtension)
                    }
                    self?.readApertureLibrary(bundle, into: url)
                }
                return
            case .alertSecondButtonReturn:
                break
            default:
                return
            }
        }
        readApertureLibrary(bundle, into: target)
    }

    private func readApertureLibrary(_ bundle: URL, into catalogURL: URL) {
        apertureProgress = ApertureImporter.Progress(phase: "Opening…", done: 0, total: 1)
        statusMessage = "Reading \(bundle.lastPathComponent)…"
        // A real thread with a deep stack, not the cooperative pool: the
        // render matching builds long Core Image graphs, and the pool's
        // 512 KB stacks overflow inside CoreImage (seen as a bus error).
        let thread = Thread { [weak self] in
            do {
                let summary = try ApertureImporter.run(bundle: bundle, catalogURL: catalogURL) { progress in
                    DispatchQueue.main.async { self?.apertureProgress = progress }
                }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.apertureProgress = nil
                    self.open(libraryURL: catalogURL)
                    self.statusMessage = "Opened \(bundle.lastPathComponent): \(summary.headline)."
                    self.reportApertureOpen(summary, bundle: bundle)
                }
            } catch {
                DispatchQueue.main.async {
                    self?.apertureProgress = nil
                    self?.statusMessage = ""
                    self?.alertMessage = error.localizedDescription
                    // A half-built catalog shouldn't masquerade as a library.
                    if !Catalog.isLibrary(catalogURL) || (try? Catalog(libraryURL: catalogURL).counts().all) == 0 {
                        try? FileManager.default.removeItem(at: catalogURL)
                    }
                }
            }
        }
        thread.name = "Alter.ApertureImport"
        thread.qualityOfService = .userInitiated
        thread.stackSize = 16 << 20
        thread.start()
    }

    // MARK: - Importing another Aperture library

    /// File ▸ Import ▸ Aperture Library…: another Aperture library into the
    /// open one, as a folder of its own (Aperture's File ▸ Import ▸ Library).
    func presentImportApertureLibraryPanel() {
        guard let catalog else { return }
        let panel = NSOpenPanel()
        panel.title = "Import Aperture Library"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.message = "Choose an .aplibrary to add to this library — Alter reads it in place and never modifies it"
        panel.directoryURL = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            guard ApertureLibrary.isApertureLibrary(url) else {
                self.statusMessage = "That isn't an Aperture library."
                return
            }
            let name = url.deletingPathExtension().lastPathComponent
            if catalog.aperturePaths.contains(url.standardizedFileURL.path) {
                self.alertMessage = "\(name) is already in this library."
                return
            }
            let alert = NSAlert()
            alert.messageText = "Import “\(name)” into this library?"
            var info = "It arrives as a folder named “\(name)” with its projects, folders and albums inside. Search, keywords and smart albums then cover both. The Aperture library itself isn't modified."
            if catalog.metaValue("source") == "aperture", catalog.aperturePaths.count == 1,
               let first = catalog.aperturePaths.first {
                let firstName = URL(fileURLWithPath: first).deletingPathExtension().lastPathComponent
                info += "\n\nThis library's own projects and albums move into a folder named “\(firstName)”, so each library is its own group."
            }
            alert.informativeText = info
            alert.addButton(withTitle: "Import")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            self.importApertureLibrary(url, into: catalog.libraryURL)
        }
    }

    private func importApertureLibrary(_ bundle: URL, into catalogURL: URL) {
        apertureProgress = ApertureImporter.Progress(phase: "Opening…", done: 0, total: 1)
        statusMessage = "Importing \(bundle.lastPathComponent)…"
        // A deep-stacked thread, as for opening one (render matching builds
        // long Core Image graphs).
        let thread = Thread { [weak self] in
            do {
                let summary = try ApertureImporter.run(bundle: bundle, catalogURL: catalogURL, merge: true) { progress in
                    DispatchQueue.main.async { self?.apertureProgress = progress }
                }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.apertureProgress = nil
                    self.reloadSidebar()
                    self.reloadItems()
                    self.reloadKeywordVocabulary()
                    self.statusMessage = "Imported \(bundle.lastPathComponent): \(summary.headline)."
                    self.reportApertureOpen(summary, bundle: bundle)
                }
            } catch {
                DispatchQueue.main.async {
                    self?.apertureProgress = nil
                    self?.statusMessage = ""
                    self?.alertMessage = error.localizedDescription
                }
            }
        }
        thread.name = "Alter.ApertureMerge"
        thread.qualityOfService = .userInitiated
        thread.stackSize = 16 << 20
        thread.start()
    }

    // MARK: - Recent libraries (File ▸ Switch to Library)

    private static let recentLibrariesKey = "alter_recent_libraries"

    /// Libraries opened lately, newest first, that are still there.
    var recentLibraries: [URL] {
        (UserDefaults.standard.stringArray(forKey: Self.recentLibrariesKey) ?? [])
            .map { URL(fileURLWithPath: $0) }
            .filter { Catalog.isLibrary($0) }
    }

    fileprivate func noteRecentLibrary(_ url: URL) {
        var paths = UserDefaults.standard.stringArray(forKey: Self.recentLibrariesKey) ?? []
        paths.removeAll { $0 == url.standardizedFileURL.path }
        paths.insert(url.standardizedFileURL.path, at: 0)
        UserDefaults.standard.set(Array(paths.prefix(10)), forKey: Self.recentLibrariesKey)
        objectWillChange.send()
    }

    func clearRecentLibraries() {
        UserDefaults.standard.removeObject(forKey: Self.recentLibrariesKey)
        if let catalog { noteRecentLibrary(catalog.libraryURL) }
    }

    /// What came across, and what didn't — once, right after the open.
    private func reportApertureOpen(_ summary: ApertureImporter.Summary, bundle: URL) {
        var lines: [String] = []
        lines.append("\(summary.headline). Your Aperture library wasn't modified; Alter's catalog is beside it.")
        if summary.missingFiles > 0 {
            lines.append("\(summary.missingFiles) original\(summary.missingFiles == 1 ? " is" : "s are") missing from the bundle (referenced files or files Aperture had already lost).")
        }
        if summary.smartAlbums > 0 || summary.smartAlbumsAsPlain > 0 {
            var s = "\(summary.smartAlbums) smart album\(summary.smartAlbums == 1 ? "" : "s") carried over with rules"
            if summary.smartAlbumsAsPlain > 0 {
                s += "; \(summary.smartAlbumsAsPlain) had rules Alter doesn't have yet and came over as plain albums"
            }
            lines.append(s + ".")
        }
        let unsupported = summary.report.unsupported
        if !unsupported.isEmpty {
            let list = unsupported.sorted { $0.value > $1.value }
                .map { "\(ApertureTranslator.displayName($0.key)) (\($0.value))" }
                .joined(separator: ", ")
            lines.append("Adjustments Alter can't reproduce yet were skipped: \(list). Compare mode shows Aperture's own render for every photo.")
        }
        guard lines.count > 1 else { return }
        alertTitle = "Aperture library opened"
        alertMessage = lines.joined(separator: "\n\n")
    }

    // MARK: - Reloads

    func reloadSidebar() {
        guard let catalog else { return }
        folders = (try? catalog.folders()) ?? []
        albums = (try? catalog.albums()) ?? []
        smartAlbums = (try? catalog.smartAlbums()) ?? []
        projects = (try? catalog.projectTree()) ?? []
        unfiledCount = (try? catalog.unfiledCount()) ?? 0
        keywordVocabulary = (try? catalog.keywordVocabulary()) ?? []
        keywordTree = (try? catalog.keywordTree()) ?? []
        stackInfo = (try? catalog.stacks()) ?? [:]
        versionCounts = (try? catalog.versionCounts()) ?? [:]
        if let counts = try? catalog.counts() {
            allCount = counts.all
            noAltCount = counts.noAlt
            dirtyCount = counts.dirty
        }
    }

    func reloadItems() {
        guard let catalog, let source else {
            items = []
            return
        }
        let previousStatuses = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.status) })
        items = (try? catalog.photos(in: source)) ?? []
        // Keep transient statuses (generating/saving) across a reload.
        for index in items.indices {
            if let status = previousStatuses[items[index].id] {
                items[index].status = status
            }
        }
        if case .smartAlbum(let id) = source,
           let rules = smartAlbums.first(where: { $0.id == id })?.rules {
            items = items.filter { rules.matches($0) }
        }
        if case .extensionSource(let key) = source,
           let filter = AlterExtensions.shared.sourceFilter {
            items = items.filter { filter(key, $0) }
        }
        // Collapsed stacks show only their pick (or their first member if
        // the pick isn't in this view).
        var seenStacks = Set<Int64>()
        items = items.filter { item in
            guard let stackID = item.stackID, let info = stackInfo[stackID],
                  info.collapsed, info.count > 1 else { return true }
            if info.pick == item.id { return true }
            if items.contains(where: { $0.id == info.pick }) { return false }
            return seenStacks.insert(stackID).inserted
        }
        applyFilterAndSort()
        // Versions ride right behind their master, whatever the sort.
        if !expandedVersionMasters.isEmpty {
            var spliced: [PhotoItem] = []
            spliced.reserveCapacity(items.count)
            for item in items {
                spliced.append(item)
                if expandedVersionMasters.contains(item.id),
                   let versions = try? catalog.versions(of: item.id) {
                    spliced.append(contentsOf: versions)
                }
            }
            items = spliced
        }
        let visible = Set(items.map(\.id))
        selection = selection.intersection(visible)
        if let viewerPhotoID, !visible.contains(viewerPhotoID) {
            // In split/viewer mode, land on the first visible photo instead of
            // bouncing back to an empty viewer.
            self.viewerPhotoID = viewMode == .browser ? nil : items.first?.id
        }
    }

    // MARK: - Sorting & filtering (the browser bar)

    enum SortKey: String, CaseIterable, Identifiable {
        case name, imported, fileDate, rating
        var id: String { rawValue }
        var label: String {
            switch self {
            case .name: return "Name"
            case .imported: return "Date Imported"
            // Raw value kept ("fileDate") so a saved sort survives; it now
            // sorts by when the photo was taken.
            case .fileDate: return "Date Taken"
            case .rating: return "Rating"
            }
        }
    }

    /// The keyword stamped on Image Playground round-trips.
    static let playgroundKeyword = "Playground"

    enum GridFilter: String, CaseIterable, Identifiable {
        case all, starred, flagged, rejected, videos, hasGPS, noGPS, hasAlt, missingAlt, adjusted, playground
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: return "Unrated or Better"
            case .rejected: return "Rejected"
            case .starred: return "Starred"
            case .flagged: return "Flagged"
            case .videos: return "Videos"
            case .hasGPS: return "Has Location"
            case .noGPS: return "No Location"
            case .hasAlt: return "Has ALT Text"
            case .missingAlt: return "Missing ALT Text"
            case .adjusted: return "Adjusted"
            case .playground: return "Playground"
            }
        }
        var systemImage: String {
            switch self {
            case .all: return "square.grid.2x2"
            case .rejected: return "xmark.circle"
            case .starred: return "star.fill"
            case .flagged: return "flag.fill"
            case .videos: return "play.rectangle"
            case .hasGPS: return "mappin.and.ellipse"
            case .noGPS: return "location.slash"
            case .hasAlt: return "checkmark.seal"
            case .missingAlt: return "exclamationmark.bubble"
            case .adjusted: return "dial.medium.fill"
            case .playground: return "sparkles"
            }
        }
    }

    @Published var sortKey: SortKey = SortKey(
        rawValue: UserDefaults.standard.string(forKey: "alter_sort_key") ?? "") ?? .name {
        didSet {
            UserDefaults.standard.set(sortKey.rawValue, forKey: "alter_sort_key")
            reloadItems()
        }
    }
    @Published var sortAscending: Bool = UserDefaults.standard.object(forKey: "alter_sort_asc") == nil
        ? true : UserDefaults.standard.bool(forKey: "alter_sort_asc") {
        didSet {
            UserDefaults.standard.set(sortAscending, forKey: "alter_sort_asc")
            reloadItems()
        }
    }
    @Published var gridFilter: GridFilter = .all {
        didSet { reloadItems() }
    }
    /// Minimum rating for the Starred filter (1-5).
    @Published var starThreshold = 1 {
        didSet { if gridFilter == .starred { reloadItems() } }
    }
    /// Live search over the visible source: filename, title, caption,
    /// keywords, ALT text, and creator. Composes with the grid filter —
    /// "missing ALT" + a search term is exactly the triage view you want.
    @Published var searchText = "" {
        didSet { if searchText != oldValue { reloadItems() } }
    }
    /// Aperture's Filter HUD: rules (the smart-album kind) narrowing whatever
    /// is showing, on top of search and Show. nil or empty = off.
    @Published var browserRules: SmartAlbumRules? {
        didSet { if browserRules != oldValue { reloadItems() } }
    }
    var isBrowserFilterActive: Bool { !(browserRules?.rules.isEmpty ?? true) }

    /// Bumped by the Find menu item (⌘F); the browser bar focuses its field.
    @Published var searchFocusRequest = 0

    func focusSearch() { searchFocusRequest += 1 }

    /// photoID → has GPS, filled lazily by scanGPS() (ImageIO header reads).
    private var gpsCache: [Int64: Bool] = [:]
    private var gpsScanRunning = false

    func gpsKnown(_ id: Int64) -> Bool? { gpsCache[id] }

    func noteGPS(_ has: Bool, for ids: [Int64]) {
        for id in ids { gpsCache[id] = has }
    }

    private func applyFilterAndSort() {
        // Search first, then the grid filter — both narrow, order is free,
        // but search is usually the sharper knife.
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            // Terms are ANDed: "beach 2024" finds items matching both.
            let terms = query.split(separator: " ").map(String.init)
            items = items.filter { item in
                terms.allSatisfy { item.matchesSearch($0) }
            }
        }

        if let labelFilter {
            items = items.filter { $0.label == labelFilter }
        }

        if let browserRules, !browserRules.rules.isEmpty {
            items = items.filter { browserRules.matches($0) }
        }

        switch gridFilter {
        // Aperture's default browser filter: rejects stay out of sight
        // unless you ask for them.
        case .all: items = items.filter { $0.rating >= 0 }
        case .rejected: items = items.filter { $0.rating < 0 }
        case .starred: items = items.filter { $0.rating >= starThreshold }
        case .videos: items = items.filter(\.isVideo)
        case .flagged: items = items.filter(\.flagged)
        case .hasAlt: items = items.filter { !$0.metadata.altText.isEmpty }
        case .missingAlt: items = items.filter { $0.metadata.altText.isEmpty }
        case .adjusted: items = items.filter { !$0.edits.isNeutral }
        case .playground:
            items = items.filter { item in
                item.metadata.keywords.contains { $0.caseInsensitiveCompare(Self.playgroundKeyword) == .orderedSame }
            }
        case .hasGPS, .noGPS:
            let want = gridFilter == .hasGPS
            let unknown = items.filter { gpsCache[$0.id] == nil }
            items = items.filter { gpsCache[$0.id] == want }
            if !unknown.isEmpty { scanGPS(unknown) }
        }

        switch sortKey {
        case .name:
            items.sort {
                $0.filename.localizedStandardCompare($1.filename)
                    == (sortAscending ? .orderedAscending : .orderedDescending)
            }
        case .imported:
            items.sort { sortAscending ? $0.addedAt < $1.addedAt : $0.addedAt > $1.addedAt }
        case .fileDate:
            items.sort { sortAscending ? $0.date < $1.date : $0.date > $1.date }
        case .rating:
            // Rating ties break by name so the order is stable.
            items.sort {
                if $0.rating != $1.rating {
                    return sortAscending ? $0.rating < $1.rating : $0.rating > $1.rating
                }
                return $0.filename.localizedStandardCompare($1.filename) == .orderedAscending
            }
        }
    }

    /// Read just the GPS header of files we haven't classified yet, then
    /// re-filter. Cheap per file; runs once per photo per session.
    private func scanGPS(_ pending: [PhotoItem]) {
        guard !gpsScanRunning else { return }
        gpsScanRunning = true
        statusMessage = "Checking \(pending.count) photo\(pending.count == 1 ? "" : "s") for location data…"
        let targets = pending.map { ($0.id, $0.url) }
        Task {
            let found = await Task.detached(priority: .utility) { () -> [Int64: Bool] in
                var result: [Int64: Bool] = [:]
                for (id, url) in targets {
                    result[id] = ExifReader.hasGPS(url: url)
                }
                return result
            }.value
            gpsCache.merge(found) { _, new in new }
            gpsScanRunning = false
            statusMessage = ""
            reloadItems()
        }
    }

    // MARK: - Item access

    func item(_ id: Int64) -> PhotoItem? {
        items.first { $0.id == id }
    }

    func updateItem(_ id: Int64, _ mutate: (inout PhotoItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        mutate(&items[index])
    }

    /// Edit a metadata field: updates the row cache (dirty) + the UI item.
    func editMetadata(_ id: Int64, _ mutate: (inout PhotoMetadata) -> Void) {
        guard let catalog else { return }
        updateItem(id) { item in
            mutate(&item.metadata)
            item.dirty = true
            try? catalog.updateMetadata(photoID: id, item.metadata, dirty: true)
        }
        if let counts = try? catalog.counts() {
            noAltCount = counts.noAlt
            dirtyCount = counts.dirty
        }
        scheduleAutosave()
    }

    /// Debounced write-back: fires ~2.5s after the last edit.
    func scheduleAutosave() {
        guard autosaveToFiles else { return }
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            await self?.saveDirty()
        }
    }

    func metadataBinding(_ keyPath: WritableKeyPath<PhotoMetadata, String>, for id: Int64) -> Binding<String> {
        Binding(
            get: { [weak self] in self?.item(id)?.metadata[keyPath: keyPath] ?? "" },
            set: { [weak self] value in self?.editMetadata(id) { $0[keyPath: keyPath] = value } }
        )
    }

    /// Adjustment slider bindings: persist to the catalog (never to the file),
    /// so exports/galleries render them and thumbnails refresh live.
    func editsBinding(_ keyPath: WritableKeyPath<PhotoEdits, Double>, for id: Int64) -> Binding<Double> {
        Binding(
            get: { [weak self] in self?.item(id)?.edits[keyPath: keyPath] ?? 0 },
            set: { [weak self] value in
                guard let self, let catalog = self.catalog else { return }
                self.updateItem(id) { item in
                    item.edits[keyPath: keyPath] = value
                    try? catalog.updateEdits(photoID: id, item.edits)
                }
            }
        )
    }

    /// Whole-recipe binding — feeds the shareable AdjustmentsControls.
    func editsBinding(for id: Int64) -> Binding<PhotoEdits> {
        Binding(
            get: { [weak self] in self?.item(id)?.edits ?? PhotoEdits() },
            set: { [weak self] edits in
                guard let self, let catalog = self.catalog else { return }
                self.updateItem(id) { item in
                    item.edits = edits
                    try? catalog.updateEdits(photoID: id, item.edits)
                }
            }
        )
    }

    func resetEdits(for id: Int64) {
        guard let catalog else { return }
        updateItem(id) { item in
            item.edits = PhotoEdits()
            try? catalog.updateEdits(photoID: id, item.edits)
        }
    }

    /// While Brush mode paints, the Adjust panel's sliders write THIS brush
    /// layer's recipe instead of the photo's base recipe — same targeting
    /// idea as the grade HUD. Nil = sliders back to the whole photo.
    @Published var activeBrushLayerID: UUID?

    /// Binding into one brush layer's edits within a photo's recipe.
    // MARK: Brush In / Brush Away / Quick Brushes (Aperture's brushes)

    /// Move a brick off the whole photo and onto a brush layer: "Brush X
    /// In" paints it in; "Brush X Away" applies it everywhere except
    /// where painted. A neutral brick starts from its Add defaults so
    /// there's something to paint. Enters Brush mode in the viewer.
    func beginBrushing(_ brick: AdjustmentBrick, away: Bool, photoID: Int64) {
        guard let catalog else { return }
        var layerID: UUID?
        updateItem(photoID) { item in
            var edits = item.edits
            if let index = edits.brushLayerIndex(for: brick) {
                layerID = edits.brushLayers[index].id
                return
            }
            var look = edits.extracting(brick)
            if look.isNeutral {
                var seeded = PhotoEdits()
                seeded.add(brick)
                look = seeded.extracting(brick)
            }
            look.addedBricks = nil
            edits.remove(brick)
            let layer = BrushLayer(name: brick.name, brick: brick.rawValue,
                                   inverted: away ? true : nil, strokes: [], edits: look)
            edits.brushes = edits.brushLayers + [layer]
            layerID = layer.id
            item.edits = edits
            try? catalog.updateEdits(photoID: photoID, edits)
        }
        openBrush(layerID, photoID: photoID)
    }

    func beginQuickBrush(_ quick: QuickBrush, photoID: Int64) {
        guard let catalog else { return }
        let layer = BrushLayer(name: quick.name, quickBrush: quick.rawValue, strokes: [], edits: quick.preset)
        updateItem(photoID) { item in
            item.edits.brushes = item.edits.brushLayers + [layer]
            try? catalog.updateEdits(photoID: photoID, item.edits)
        }
        openBrush(layer.id, photoID: photoID)
    }

    /// Back to editing an existing layer's strokes.
    func editBrushStrokes(_ layerID: UUID, photoID: Int64) {
        openBrush(layerID, photoID: photoID)
    }

    private func openBrush(_ layerID: UUID?, photoID: Int64) {
        guard let layerID else { return }
        if viewMode == .browser || viewerPhotoID != photoID { enterViewer(photoID) }
        inspectorTab = .adjust
        activeBrushLayerID = layerID
    }

    /// Fold a brushed brick back onto the whole photo and drop the strokes.
    func applyBrushToEntirePhoto(_ layerID: UUID, photoID: Int64) {
        guard let catalog else { return }
        if activeBrushLayerID == layerID { activeBrushLayerID = nil }
        updateItem(photoID) { item in
            var edits = item.edits
            guard let index = edits.brushLayers.firstIndex(where: { $0.id == layerID }) else { return }
            let layer = edits.brushLayers[index]
            if let name = layer.brick, let brick = AdjustmentBrick(rawValue: name) {
                edits.absorb(layer.edits, brick: brick)
            }
            var layers = edits.brushLayers
            layers.remove(at: index)
            edits.brushes = layers.isEmpty ? nil : layers
            item.edits = edits
            try? catalog.updateEdits(photoID: photoID, edits)
        }
    }

    func removeBrushLayer(_ layerID: UUID, photoID: Int64) {
        guard let catalog else { return }
        if activeBrushLayerID == layerID { activeBrushLayerID = nil }
        updateItem(photoID) { item in
            var layers = item.edits.brushLayers
            layers.removeAll { $0.id == layerID }
            item.edits.brushes = layers.isEmpty ? nil : layers
            try? catalog.updateEdits(photoID: photoID, item.edits)
        }
    }

    func brushEditsBinding(photoID: Int64, layerID: UUID) -> Binding<PhotoEdits> {
        Binding(
            get: { [weak self] in
                self?.item(photoID)?.edits.brushLayers
                    .first { $0.id == layerID }?.edits ?? PhotoEdits()
            },
            set: { [weak self] edits in
                guard let self, let catalog = self.catalog else { return }
                self.updateItem(photoID) { item in
                    var layers = item.edits.brushLayers
                    guard let index = layers.firstIndex(where: { $0.id == layerID })
                    else { return }
                    layers[index].edits = edits
                    item.edits.brushes = layers
                    try? catalog.updateEdits(photoID: photoID, item.edits)
                }
            }
        )
    }

    func keywordsBinding(for id: Int64) -> Binding<String> {
        Binding(
            get: { [weak self] in self?.item(id)?.metadata.keywords.joined(separator: ", ") ?? "" },
            set: { [weak self] value in
                self?.editMetadata(id) { $0.keywords = PhotoMetadata.splitKeywords(value) }
            }
        )
    }

    // MARK: - Viewer & inspector mode

    /// Info and Adjust are the core's; an extension's tabs are .ext(id).
    enum InspectorTab: Hashable {
        case info, adjust
        case ext(String)
    }

    /// Aperture's three center-pane layouts: grid, viewer + filmstrip, viewer.
    enum ViewMode: String, CaseIterable {
        case browser, split, viewer
    }

    /// A menu asking the sidebar to start a new project, folder, album or
    /// smart album (the sidebar owns the naming prompts).
    enum NewItemRequest: Equatable { case project, folder, album, smartAlbum }
    @Published var newItemRequest: NewItemRequest?

    /// A menu asking the viewer to pick up one of its tools ("crop",
    /// "straighten", "retouch", "redEye", "brush", "loupe", "master",
    /// "compare", or an extension tool's id). The viewer clears it.
    @Published var viewerToolRequest: String?

    @Published var viewMode: ViewMode = .browser {
        didSet {
            guard viewMode != oldValue else { return }
            takeKeyboardFromTextFields()
            if viewMode == .browser {
                viewerPhotoID = nil
            } else if viewerPhotoID == nil {
                viewerPhotoID = selection.first ?? items.first?.id
                if let viewerPhotoID, selection.isEmpty { selection = [viewerPhotoID] }
            }
        }
    }

    /// Switching to Adjust auto-opens the full-size viewer — editing against a
    /// thumbnail isn't editing. Split view keeps the filmstrip for context.
    /// Animate takes over the center pane with the canvas + timeline.
    @Published var inspectorTab: InspectorTab = .info {
        didSet {
            if inspectorTab == .adjust, viewMode == .browser,
               selection.count == 1, let single = selection.first {
                viewerPhotoID = single
                viewMode = .split
            }
            if inspectorTab != oldValue {
                AlterExtensions.shared.inspectorTabChanged?(self, oldValue)
            }
        }
    }

    /// Non-nil = the viewer pane shows this photo full-size.
    @Published var viewerPhotoID: Int64?

    var viewerItem: PhotoItem? { viewerPhotoID.flatMap { item($0) } }

    func enterViewer(_ id: Int64) {
        selection = [id]
        viewerPhotoID = id
        if viewMode == .browser { viewMode = .viewer }
        takeKeyboardFromTextFields()
    }

    func exitViewer() {
        viewMode = .browser
    }

    /// Show a photo in the viewer pane without collapsing a multi-selection
    /// (filmstrip clicks).
    func showInViewer(_ id: Int64) {
        viewerPhotoID = id
    }

    /// Step to the previous/next photo while in the viewer.
    func viewerStep(_ delta: Int) {
        guard let current = viewerPhotoID,
              let index = items.firstIndex(where: { $0.id == current }) else { return }
        let target = index + delta
        guard items.indices.contains(target) else { return }
        enterViewer(items[target].id)
    }

    /// Jump straight into editing a photo (viewer + Adjust tab).
    func openAdjustments(_ id: Int64) {
        enterViewer(id)
        inspectorTab = .adjust
    }

    // MARK: - Selection

    /// The browser owns the keyboard unless you're typing: the search
    /// field (which SwiftUI focuses at launch) lets go whenever the photos
    /// become the subject — a click, Select All, entering the viewer — so
    /// 1–5, V, F… act on the photo. Aperture never parked the cursor in a
    /// search box.
    func takeKeyboardFromTextFields() {
        for window in NSApp.windows where window.firstResponder is NSTextView {
            window.makeFirstResponder(nil)
        }
    }

    func handleTap(_ id: Int64) {
        takeKeyboardFromTextFields()
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        if flags.contains(.command) {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        } else if flags.contains(.shift), let anchor = selection.first,
                  let anchorIndex = items.firstIndex(where: { $0.id == anchor }),
                  let targetIndex = items.firstIndex(where: { $0.id == id }) {
            let range = min(anchorIndex, targetIndex)...max(anchorIndex, targetIndex)
            selection = Set(items[range].map(\.id))
        } else {
            selection = [id]
        }
    }

    func selectAll() {
        selection = Set(items.map(\.id))
        takeKeyboardFromTextFields()
    }

    // MARK: - Import

    func presentImportPanel() {
        guard isOpen else { return }
        let panel = NSOpenPanel()
        panel.title = "Import Media"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "Choose folders, photos, or videos (referenced in place — never moved or copied)"
        panel.begin { [weak self] response in
            guard response == .OK, let self else { return }
            Task { await self.importURLs(panel.urls) }
        }
    }

    /// Import one file and land on it in the viewer (Playground round-trips).
    /// An optional keyword tags the newcomer — written to the file's XMP like
    /// any other keyword, so "Playground" survives export and reimport.
    func importAndReveal(_ url: URL, keyword: String? = nil) async {
        await importURLs([url])
        // A filtered view or album can hide the newcomer — fall back to All.
        if !items.contains(where: { $0.url.path == url.path }) {
            gridFilter = .all
            source = .all
        }
        guard let imported = items.first(where: { $0.url.path == url.path }) else { return }
        if let keyword {
            addKeywords([keyword], to: imported.id)
        }
        selection = [imported.id]
        if viewMode != .browser { viewerPhotoID = imported.id }
        statusMessage = "Imported \(url.lastPathComponent)."
    }

    func importFromPhotos() {
        guard isOpen else { return }
        PhotosImporter.shared.present { [weak self] urls in
            guard let self, !urls.isEmpty else { return }
            Task { await self.importURLs(urls) }
        }
    }

    nonisolated static func collectImageFiles(from urls: [URL])
        -> (files: [(URL, URL?)], skipped: [String: Int]) {
        // (file, owning folder root) — folder root nil for loose files.
        // Skipped: extension → count, so the import can SAY what it dropped
        // instead of silently eating a file the user deliberately chose.
        var files: [(URL, URL?)] = []
        var skipped: [String: Int] = [:]
        let fm = FileManager.default
        func note(skippedFile url: URL) {
            let ext = url.pathExtension.lowercased()
            skipped[ext.isEmpty ? "no extension" : "." + ext, default: 0] += 1
        }
        for url in urls {
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                if let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                    for case let child as URL in enumerator {
                        var childIsDir: ObjCBool = false
                        if fm.fileExists(atPath: child.path, isDirectory: &childIsDir), childIsDir.boolValue { continue }
                        if ImageLoader.isMediaFile(child) {
                            files.append((child, url))
                            if files.count >= 5000 { break }
                        } else {
                            note(skippedFile: child)
                        }
                    }
                }
            } else if ImageLoader.isMediaFile(url) {
                files.append((url, nil))
            } else {
                note(skippedFile: url)
            }
        }
        files.sort { $0.0.lastPathComponent.localizedStandardCompare($1.0.lastPathComponent) == .orderedAscending }
        return (files, skipped)
    }

    /// "12 files (.xmp, .txt)" — the part of an import that didn't happen.
    private static func skippedSummary(_ skipped: [String: Int]) -> String {
        let total = skipped.values.reduce(0, +)
        let exts = skipped.sorted { $0.value > $1.value }.prefix(3).map(\.key)
        return "\(total) file\(total == 1 ? "" : "s") (\(exts.joined(separator: ", ")))"
    }

    @discardableResult
    func importURLs(_ urls: [URL]) async -> [Int64] {
        guard let catalog else { return [] }
        let (found, skipped) = Self.collectImageFiles(from: urls)
        guard !found.isEmpty else {
            statusMessage = ""
            // Everything was dropped — that deserves an alert, not a status
            // line nobody sees. Audio gets its own message: ALTer reads it
            // perfectly well, just as timeline tracks, and telling someone
            // their soundtrack is "not a format ALTer reads" is a lie that
            // sends them away.
            let audioOnly = !skipped.isEmpty && skipped.keys.allSatisfy {
                ImageLoader.audioExtensions.contains($0.replacingOccurrences(of: ".", with: ""))
            }
            if audioOnly {
                alertMessage = "Audio belongs on the timeline, not in the library.\n\n"
                    + "Open a photo or video in the timeline editor (⌘M), then use Add Audio Track to bring in MP3, WAV, or M4A — with its own volume, trimming, and waveform."
                return []
            }
            let what = skipped.isEmpty ? "Nothing importable was found."
                : "Skipped \(Self.skippedSummary(skipped)) — not a format the library catalogs."
            alertMessage = what + "\n\nAlter imports JPEG, PNG, WebP, TIFF, HEIC, GIF, BMP, camera RAW (CR2, CR3, NEF, ARW, DNG, and more), and MOV, MP4, M4V, AVI, MPG video. Audio (MP3, WAV, M4A) is added inside the timeline editor with Add Audio Track."
            return []
        }

        isWorking = true
        statusMessage = "Reading metadata for \(found.count) image\(found.count == 1 ? "" : "s")…"

        var fileMetadata: [URL: PhotoMetadata] = [:]
        do {
            fileMetadata = try await ExifToolService.readBatch(urls: found.map(\.0))
        } catch {
            statusMessage = error.localizedDescription
            exiftoolMissing = !ExifToolService.isAvailable
        }

        var folderIDs: [String: Int64] = [:]
        var importedIDs: [Int64] = []
        for (file, root) in found {
            var folderID: Int64?
            if let root {
                if let cached = folderIDs[root.path] {
                    folderID = cached
                } else if let id = try? catalog.addFolder(path: root.path) {
                    folderIDs[root.path] = id
                    folderID = id
                }
            }
            let targetProject = selectedProjectID
            if let id = try? catalog.insertPhoto(url: file, folderID: folderID,
                                                 metadata: fileMetadata[file] ?? PhotoMetadata()) {
                importedIDs.append(id)
                // Aperture imports into the selected project.
                if let targetProject { try? catalog.setProject(targetProject, photoIDs: [id]) }
            }
        }

        isWorking = false
        reloadSidebar()
        reloadItems()
        backfillExifIfNeeded()
        statusMessage = "Imported \(importedIDs.count) item\(importedIDs.count == 1 ? "" : "s")."
            + (skipped.isEmpty ? "" : " Skipped \(Self.skippedSummary(skipped)) — not library media.")
        // Show the newcomers — select them and scroll the grid there, so an
        // import never lands invisibly below the fold.
        let visible = Set(items.map(\.id))
        let arrived = importedIDs.filter { visible.contains($0) }
        if !arrived.isEmpty {
            selection = Set(arrived)
            revealID = arrived.first
        }
        return importedIDs
    }

    // MARK: - Rating / flag

    func setRating(_ rating: Int, for ids: [Int64]) {
        guard let catalog else { return }
        for id in ids {
            try? catalog.setRating(photoID: id, rating: rating)
            updateItem(id) { $0.rating = rating }
        }
    }

    /// Aperture's = and − keys.
    func adjustRating(by delta: Int, for ids: [Int64]) {
        for id in ids {
            guard let current = item(id)?.rating else { continue }
            setRating(max(-1, min(5, current + delta)), for: [id])
        }
    }

    /// Quarter turns, ⌘[ / ⌘]: a recipe rotation, never the file.
    func rotate(_ quarterTurns: Int, for ids: [Int64]) {
        guard let catalog else { return }
        for id in ids {
            updateItem(id) { item in
                let turns = ((item.edits.rotationQuarters + quarterTurns) % 4 + 4) % 4
                item.edits.rotation = turns == 0 ? nil : turns
                try? catalog.updateEdits(photoID: id, item.edits)
            }
        }
    }

    /// ⌥U: with several photos selected the viewer shows them all (up to
    /// twelve) unless Primary Only is on.
    @Published var primaryOnly = false
    /// ⌥⇧H: blown highlights red, crushed shadows blue.
    @Published var showHotCold = false

    func flip(horizontal: Bool, for ids: [Int64]) {
        guard let catalog else { return }
        for id in ids {
            updateItem(id) { item in
                if horizontal {
                    item.edits.flipHorizontal = item.edits.flipHorizontal == true ? nil : true
                } else {
                    item.edits.flipVertical = item.edits.flipVertical == true ? nil : true
                }
                try? catalog.updateEdits(photoID: id, item.edits)
            }
        }
    }

    /// The photos a keyboard command acts on: in the viewer, the primary
    /// photo when it's alone or Primary Only is on; otherwise the selection.
    var commandTargets: [Int64] {
        if let id = viewerPhotoID, viewMode != .browser, primaryOnly || selection.count <= 1 {
            return [id]
        }
        if viewMode == .browser, selection.isEmpty, let id = viewerPhotoID { return [id] }
        return Array(selection)
    }

    // MARK: - Full Screen (F) — Aperture's black, chrome-free mode

    /// Our own full-screen presentation (no sidebar, no inspector, no
    /// toolbar; filmstrip and controls slide in on hover) riding on the
    /// window's native full screen.
    @Published var isFullScreenMode = false
    /// H: the floating Inspector HUD while in full screen.
    @Published var isInspectorHUDVisible = false
    private var fullScreenObserver: Any?
    private var fullScreenEnterObserver: Any?

    func toggleFullScreenMode(window: NSWindow?) {
        if isFullScreenMode { exitFullScreenMode(window: window) } else { enterFullScreenMode(window: window) }
    }

    func enterFullScreenMode(window: NSWindow?) {
        guard isOpen else { return }
        isFullScreenMode = true
        if viewMode == .browser, let id = selection.first, selection.count == 1 {
            // One photo selected: full screen means the viewer, as in Aperture.
            viewerPhotoID = id
            viewMode = .viewer
        }
        if let window, !window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }
        installFullScreenObservers()
    }

    /// Native full screen and ours move together, whichever way in: the
    /// green button or ⌃⌘F into full screen gives Aperture's black,
    /// chrome-free Full Screen (it used to give the windowed layout, just
    /// bigger), and leaving native full screen leaves ours. Called once the
    /// main window is up, and again (harmlessly) on entering.
    func installFullScreenObservers() {
        installFullScreenObserver()
        guard fullScreenEnterObserver == nil else { return }
        fullScreenEnterObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didEnterFullScreenNotification, object: nil, queue: .main
        ) { [weak self] note in
            // Not the Settings window, should anyone full-screen it.
            let id = (note.object as? NSWindow)?.identifier?.rawValue ?? ""
            guard !id.localizedCaseInsensitiveContains("settings") else { return }
            Task { @MainActor in
                // The toolbar and menu bar hide together and slide in from
                // the top edge (Alter's Full Screen controls live in it).
                NSApp.presentationOptions = [.fullScreen, .autoHideMenuBar, .autoHideToolbar]
                guard let self, self.isOpen, !self.isFullScreenMode, self.slideshowIDs == nil else { return }
                self.isFullScreenMode = true
                if self.viewMode == .browser, let id = self.selection.first, self.selection.count == 1 {
                    self.viewerPhotoID = id
                    self.viewMode = .viewer
                }
            }
        }
    }

    func exitFullScreenMode(window: NSWindow?) {
        isFullScreenMode = false
        isInspectorHUDVisible = false
        if let window, window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }
    }

    /// An armed eyedropper: the viewer's next click sets it.
    @Published var pickRequest: ColorPick?

    // MARK: - Slideshow

    /// Running when non-nil: the photos in play order.
    @Published var slideshowIDs: [Int64]?

    /// The selection when more than one is picked, else everything shown,
    /// starting from the primary photo.
    func startSlideshow(window: NSWindow?) {
        guard isOpen else { return }
        var ids = selection.count > 1 ? items.filter { selection.contains($0.id) }.map(\.id) : items.map(\.id)
        guard !ids.isEmpty else { return }
        if let primary = viewerPhotoID ?? selection.first, let at = ids.firstIndex(of: primary), at > 0 {
            ids = Array(ids[at...]) + Array(ids[..<at])
        }
        isInspectorHUDVisible = false
        slideshowIDs = ids
        installFullScreenObserver()
        if let window, !window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }
    }

    private func installFullScreenObserver() {
        guard fullScreenObserver == nil else { return }
        fullScreenObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didExitFullScreenNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isFullScreenMode = false
                self?.isInspectorHUDVisible = false
                self?.slideshowIDs = nil
            }
        }
    }

    func stopSlideshow(window: NSWindow?) {
        slideshowIDs = nil
        if !isFullScreenMode, let window, window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }
    }

    /// V: Browser → Split → Viewer → Browser.
    func cycleViewMode() {
        guard isOpen else { return }
        switch viewMode {
        case .browser: viewMode = .split
        case .split: viewMode = .viewer
        case .viewer: viewMode = .browser
        }
    }

    /// W: Info → Adjust → (Animate) → Info.
    /// W, as in Aperture: Info → Adjust → each extension tab (Animate) →
    /// back to Info.
    func cycleInspectorTab() {
        let tabs: [InspectorTab] = [.info, .adjust] + AlterExtensions.shared.inspectorTabs.map { .ext($0.id) }
        let index = tabs.firstIndex(of: inspectorTab) ?? -1
        inspectorTab = tabs[(index + 1) % tabs.count]
    }

    func setFlagged(_ flagged: Bool, for ids: [Int64]) {
        guard let catalog else { return }
        for id in ids {
            try? catalog.setFlagged(photoID: id, flagged: flagged)
            updateItem(id) { $0.flagged = flagged }
        }
    }

    // MARK: - Labels, versions, stacks (the Aperture set)

    func setLabel(_ label: Int, for ids: [Int64]) {
        guard let catalog else { return }
        for id in ids {
            try? catalog.setLabel(photoID: id, label: label)
            updateItem(id) { $0.label = label }
        }
    }

    /// New version of a photo: `fromOriginal` starts from a neutral recipe,
    /// otherwise it duplicates the current one. The master expands so the
    /// new take is visible and selected (and in the viewer, if open).
    func createVersion(of id: Int64, fromOriginal: Bool) {
        guard let catalog, let item = item(id) else { return }
        let master = item.versionOf ?? id
        guard let newID = try? catalog.createVersion(
            of: id, edits: fromOriginal ? PhotoEdits() : nil) else { return }
        expandedVersionMasters.insert(master)
        reloadSidebar()
        reloadItems()
        selection = [newID]
        if viewerPhotoID != nil { viewerPhotoID = newID }
        statusMessage = fromOriginal ? "New version from the original." : "Version duplicated."
    }

    func deleteVersion(_ id: Int64) {
        guard let item = item(id), item.isVersion else { return }
        if viewerPhotoID == id { viewerPhotoID = item.versionOf }
        removeFromLibrary([id])
    }

    func renameVersion(_ id: Int64, to name: String) {
        guard let catalog else { return }
        try? catalog.renameVersion(id: id, name: name)
        updateItem(id) { $0.versionName = name }
    }

    func toggleVersions(of masterID: Int64) {
        if expandedVersionMasters.contains(masterID) {
            expandedVersionMasters.remove(masterID)
        } else {
            expandedVersionMasters.insert(masterID)
        }
        reloadItems()
    }

    /// Stack the selection (two or more masters). The best-rated becomes
    /// the pick — ties go to the first in the current order.
    func stackSelection() {
        guard let catalog else { return }
        let ordered = items.filter { selection.contains($0.id) && !$0.isVersion }
        guard ordered.count >= 2 else { return }
        let pick = ordered.max { a, b in
            a.rating != b.rating ? a.rating < b.rating
                : (items.firstIndex(of: a) ?? 0) > (items.firstIndex(of: b) ?? 0)
        }
        // Members already in other stacks move into this one.
        guard let stackID = try? catalog.createStack(
            photoIDs: ordered.map(\.id), pick: pick?.id) else { return }
        reloadSidebar()
        reloadItems()
        if let pick { selection = [pick.id] }
        statusMessage = "Stacked \(ordered.count) photos."
        _ = stackID
    }

    func unstack(_ stackID: Int64) {
        guard let catalog else { return }
        try? catalog.unstack(stackID: stackID)
        reloadSidebar()
        reloadItems()
    }

    func setStackPick(_ id: Int64) {
        guard let catalog, let item = item(id), let stackID = item.stackID else { return }
        try? catalog.setStackPick(stackID: stackID, photoID: id)
        reloadSidebar()
        reloadItems()
    }

    func toggleStack(_ stackID: Int64) {
        guard let catalog, let info = stackInfo[stackID] else { return }
        try? catalog.setStackCollapsed(stackID: stackID, collapsed: !info.collapsed)
        reloadSidebar()
        reloadItems()
    }

    /// Aperture's Auto-Stack: group unstacked photos in this view whose
    /// capture times fall within `gap` seconds of the previous one.
    func autoStack(gapSeconds gap: Double) {
        guard let catalog else { return }
        let candidates = items
            .filter { !$0.isVersion && $0.stackID == nil && $0.date > 0 }
            .sorted { $0.date < $1.date }
        var groups: [[PhotoItem]] = []
        var current: [PhotoItem] = []
        for item in candidates {
            if let last = current.last, item.date - last.date <= gap {
                current.append(item)
            } else {
                if current.count >= 2 { groups.append(current) }
                current = [item]
            }
        }
        if current.count >= 2 { groups.append(current) }
        for group in groups {
            let pick = group.max { $0.rating < $1.rating } ?? group[0]
            try? catalog.createStack(photoIDs: group.map(\.id), pick: pick.id)
        }
        reloadSidebar()
        reloadItems()
        statusMessage = groups.isEmpty
            ? "No bursts found within \(Int(gap)) seconds."
            : "Made \(groups.count) stack\(groups.count == 1 ? "" : "s")."
    }

    // MARK: - Smart albums

    @discardableResult
    func createSmartAlbum(named name: String, rules: SmartAlbumRules) -> Int64? {
        guard let catalog, !name.isEmpty,
              let id = try? catalog.createSmartAlbum(name: name, rules: rules) else { return nil }
        reloadSidebar()
        source = .smartAlbum(id)
        return id
    }

    func updateSmartAlbum(_ id: Int64, name: String, rules: SmartAlbumRules) {
        guard let catalog else { return }
        try? catalog.updateSmartAlbum(id: id, name: name, rules: rules)
        reloadSidebar()
        reloadItems()
    }

    // MARK: - Edit With… (external editor)

    @Published var isAutoStackPresented = false

    /// Render the version to a TIFF the editor can own, add it beside the
    /// original (same project), open it in the app. Aperture's flow.
    func editWith(appURL: URL, photoID: Int64) {
        guard let catalog, let source = item(photoID) else { return }
        statusMessage = "Rendering \(source.filename) for \(FileManager.default.displayName(atPath: appURL.path))…"
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                let directory = try ExternalEditor.externalsDirectory(for: catalog.libraryURL)
                let url = try await Task.detached(priority: .userInitiated) {
                    try ExternalEditor.renderTIFF(item: source, into: directory)
                }.value
                var meta = source.metadata
                if !meta.keywords.contains("edited externally") { meta.keywords.append("edited externally") }
                let id = try catalog.insertPhoto(url: url, folderID: nil, metadata: meta)
                if let project = source.projectID { try catalog.setProject(project, photoIDs: [id]) }
                try catalog.setRating(photoID: id, rating: source.rating)
                try catalog.setLabel(photoID: id, label: source.label)
                externallyEdited.insert(id)
                reloadSidebar()
                reloadItems()
                selection = [id]
                if viewMode != .browser { viewerPhotoID = id }
                _ = try? await NSWorkspace.shared.open([url], withApplicationAt: appURL,
                                                       configuration: NSWorkspace.OpenConfiguration())
                statusMessage = "Opened \(url.lastPathComponent) in \(FileManager.default.displayName(atPath: appURL.path)) — Alter picks up the saved file when you come back."
            } catch {
                alertMessage = "Couldn't hand the photo to the editor: \(error.localizedDescription)"
            }
        }
    }

    /// Photos we handed to an editor this session; checked for changes
    /// whenever ALTer comes back to the front.
    private var externallyEdited: Set<Int64> = []

    func pickUpExternalEdits() {
        guard let catalog, !externallyEdited.isEmpty else { return }
        var changed = false
        for id in externallyEdited {
            guard let current = item(id) else { continue }
            let attrs = try? FileManager.default.attributesOfItem(atPath: current.url.path)
            let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            if mtime > current.fileDate + 0.5 {
                try? catalog.touchFile(photoID: id, url: current.url)
                updateItem(id) { $0.fileDate = mtime }
                changed = true
            }
        }
        if changed {
            ImageLoader.shared.invalidateAll()
            reloadItems()
            statusMessage = "Picked up the edited file."
        }
    }

    // MARK: - Auto-Stack preview

    /// How many stacks (and photos in them) a gap would make of what's shown.
    func autoStackPreview(gapSeconds gap: Double) -> (stacks: Int, photos: Int) {
        let candidates = items
            .filter { !$0.isVersion && $0.stackID == nil && $0.date > 0 }
            .sorted { $0.date < $1.date }
        var stacks = 0, photos = 0
        var run = 1
        for (index, item) in candidates.enumerated() where index > 0 {
            if item.date - candidates[index - 1].date <= gap {
                run += 1
            } else {
                if run >= 2 { stacks += 1; photos += run }
                run = 1
            }
        }
        if run >= 2 { stacks += 1; photos += run }
        return (stacks, photos)
    }

    // MARK: - Camera EXIF into the catalog

    private var exifBackfillRunning = false

    /// Read camera data for photos that haven't had it read, a batch at a
    /// time in the background — smart albums by camera/lens/ISO need it.
    func backfillExifIfNeeded() {
        guard let catalog, !exifBackfillRunning else { return }
        exifBackfillRunning = true
        Task { [weak self] in
            defer { self?.exifBackfillRunning = false }
            while true {
                let pending: [(id: Int64, url: URL)]
                do { pending = try catalog.photosNeedingExif(limit: 100) } catch { return }
                if pending.isEmpty { return }
                let read: [(Int64, Catalog.CameraInfo)] = await Task.detached(priority: .utility) {
                    pending.map { entry in
                        let info = ExifReader.read(url: entry.url)
                        return (entry.id, Catalog.CameraInfo(
                            camera: info.camera ?? "", lens: info.lens ?? "", iso: info.isoValue,
                            focalLength: info.focalValue, aperture: info.apertureValue, shutter: info.shutterSeconds,
                            captureDate: info.captureTimestamp))
                    }
                }.value
                guard let self else { return }
                guard self.catalog === catalog else {
                    // The library changed under us: start over on the new one.
                    self.exifBackfillRunning = false
                    self.backfillExifIfNeeded()
                    return
                }
                for (id, info) in read {
                    try? catalog.setCameraInfo(photoID: id, info)
                    if let index = self.items.firstIndex(where: { $0.id == id }) {
                        self.items[index].camera = info.camera
                        self.items[index].lens = info.lens
                        self.items[index].iso = info.iso
                        self.items[index].focalLength = info.focalLength
                        self.items[index].aperture = info.aperture
                        self.items[index].shutter = info.shutter
                        if self.items[index].captureDate == nil { self.items[index].captureDate = info.captureDate }
                    }
                }
                if read.count < 100 { break }
            }
        }
    }

    // MARK: - Keywords HUD (⇧H) and keyword controls (⇧D)

    @Published var isKeywordsHUDVisible = false
    @Published var showKeywordControls = UserDefaults.standard.bool(forKey: "alter.keywordControls") {
        didSet { UserDefaults.standard.set(showKeywordControls, forKey: "alter.keywordControls") }
    }
    /// The library's keywords with counts (rebuilt with the sidebar).
    @Published var keywordVocabulary: [(name: String, count: Int)] = []
    /// Aperture's keyword library: a hierarchy, when the library has one.
    @Published var keywordTree: [KeywordNode] = []
    /// Keywords typed into the HUD that no photo carries yet.
    @Published var pendingKeywords: [String] = []
    /// Aperture's keyword buttons: eight slots, ⌥1–⌥8.
    @Published var keywordButtons: [String] = {
        (UserDefaults.standard.array(forKey: "alter.keywordButtons") as? [String]) ?? []
    }() {
        didSet { UserDefaults.standard.set(keywordButtons, forKey: "alter.keywordButtons") }
    }

    /// Every keyword a HUD can offer: in use, or typed and waiting.
    var allKeywords: [(name: String, count: Int)] {
        let known = Set(keywordVocabulary.map { $0.name.lowercased() })
        let extra = pendingKeywords.filter { !known.contains($0.lowercased()) }.map { ($0, 0) }
        return (keywordVocabulary + extra)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func reloadKeywordVocabulary() {
        guard let catalog else { return }
        keywordVocabulary = (try? catalog.keywordVocabulary()) ?? []
        keywordTree = (try? catalog.keywordTree()) ?? []
    }

    /// Add a keyword to the library's hierarchy (under a parent, or at the root).
    func createKeyword(named name: String, parent: Int64? = nil) {
        guard let catalog else { return }
        let clean = name.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return }
        try? catalog.createKeyword(name: clean, parent: parent)
        reloadKeywordVocabulary()
    }

    func deleteKeywordNode(_ id: Int64) {
        guard let catalog else { return }
        try? catalog.deleteKeyword(id: id)
        reloadKeywordVocabulary()
    }

    /// Count of photos carrying a keyword, by name.
    func keywordCount(_ name: String) -> Int {
        keywordVocabulary.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.count ?? 0
    }

    func moveAlbum(_ id: Int64, toParent parent: Int64?) {
        guard let catalog else { return }
        try? catalog.moveAlbum(id: id, toParent: parent)
        reloadSidebar()
    }

    /// Do all these photos carry the keyword?
    func keywordState(_ keyword: String, in ids: [Int64]) -> Bool? {
        let items = ids.compactMap { item($0) }
        guard !items.isEmpty else { return nil }
        let have = items.filter { $0.metadata.keywords.contains { $0.caseInsensitiveCompare(keyword) == .orderedSame } }
        if have.count == items.count { return true }
        if have.isEmpty { return false }
        return nil
    }

    func applyKeyword(_ keyword: String, to ids: [Int64]) {
        let clean = keyword.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return }
        for id in ids { addKeywords([clean], to: id) }
        if !pendingKeywords.contains(where: { $0.caseInsensitiveCompare(clean) == .orderedSame }) {
            pendingKeywords.append(clean)
        }
        reloadKeywordVocabulary()
    }

    func removeKeyword(_ keyword: String, from ids: [Int64]) {
        for id in ids {
            editMetadata(id) { meta in
                meta.keywords.removeAll { $0.caseInsensitiveCompare(keyword) == .orderedSame }
            }
        }
        reloadKeywordVocabulary()
    }

    /// Toggle: on if any target lacks it, off if all have it.
    func toggleKeyword(_ keyword: String, on ids: [Int64]) {
        if keywordState(keyword, in: ids) == true {
            removeKeyword(keyword, from: ids)
        } else {
            applyKeyword(keyword, to: ids)
        }
    }

    func setKeywordButton(_ index: Int, _ keyword: String?) {
        var buttons = keywordButtons
        while buttons.count < 8 { buttons.append("") }
        guard buttons.indices.contains(index) else { return }
        buttons[index] = keyword ?? ""
        keywordButtons = buttons
    }

    /// ⌥1–⌥8.
    func pressKeywordButton(_ index: Int) {
        guard keywordButtons.indices.contains(index) else { return }
        let keyword = keywordButtons[index]
        guard !keyword.isEmpty, !commandTargets.isEmpty else { return }
        toggleKeyword(keyword, on: commandTargets)
    }

    // MARK: - Projects (Aperture's containers)

    @discardableResult
    func createProject(named name: String, kind: ProjectNode.Kind = .project, parent: Int64? = nil) -> Int64? {
        guard let catalog, !name.isEmpty else { return nil }
        let id = try? catalog.createProject(name: name, kind: kind, parent: parent)
        reloadSidebar()
        return id
    }

    func renameProject(_ id: Int64, to name: String) {
        guard let catalog, !name.isEmpty else { return }
        try? catalog.renameProject(id: id, name: name)
        reloadSidebar()
    }

    func deleteProject(_ id: Int64) {
        guard let catalog else { return }
        try? catalog.deleteProject(id: id)
        if source == .project(id) { source = .all }
        reloadSidebar()
        reloadItems()
    }

    /// Move photos into a project (nil = out of any project).
    func moveToProject(_ projectID: Int64?, photoIDs: [Int64]) {
        guard let catalog else { return }
        try? catalog.setProject(projectID, photoIDs: photoIDs)
        for id in photoIDs { updateItem(id) { $0.projectID = projectID } }
        reloadSidebar()
        if case .project = source { reloadItems() }
        let name = projectID.flatMap { findProject($0)?.name } ?? "no project"
        statusMessage = "Moved \(photoIDs.count) photo\(photoIDs.count == 1 ? "" : "s") to \(name)."
    }

    func findProject(_ id: Int64, in nodes: [ProjectNode]? = nil) -> ProjectNode? {
        for node in nodes ?? projects {
            if node.id == id { return node }
            if let children = node.children, let hit = findProject(id, in: children) { return hit }
        }
        return nil
    }

    /// Every project (not folder), depth-first, with its depth — for menus.
    var flatProjects: [(node: ProjectNode, depth: Int)] {
        var out: [(ProjectNode, Int)] = []
        func walk(_ nodes: [ProjectNode], _ depth: Int) {
            for node in nodes {
                out.append((node, depth))
                if let children = node.children { walk(children, depth + 1) }
            }
        }
        walk(projects, 0)
        return out
    }

    /// The project new imports land in: the selected one, as in Aperture.
    var selectedProjectID: Int64? {
        if case .project(let id) = source ?? .all, findProject(id)?.kind == .project { return id }
        return nil
    }

    func deleteSmartAlbum(_ id: Int64) {
        guard let catalog else { return }
        try? catalog.deleteSmartAlbum(id: id)
        if case .smartAlbum(let current) = source, current == id { source = .all }
        reloadSidebar()
    }

    /// Targets for a context-menu action: the clicked item, or the whole
    /// selection when the clicked item is part of it.
    func contextTargets(_ id: Int64) -> [Int64] {
        selection.contains(id) ? Array(selection) : [id]
    }

    // MARK: - Albums

    @discardableResult
    func createAlbum(named name: String) -> Int64? {
        guard let catalog, !name.isEmpty else { return nil }
        let id = try? catalog.createAlbum(name: name)
        reloadSidebar()
        return id
    }

    /// Grid-level "New Album from Selection".
    func createAlbum(named name: String, with ids: [Int64]) {
        guard let albumID = createAlbum(named: name), !ids.isEmpty else { return }
        addToAlbum(albumID, photoIDs: ids)
        statusMessage = "Created “\(name)” with \(ids.count) photo\(ids.count == 1 ? "" : "s")."
    }

    func deleteAlbum(_ id: Int64) {
        guard let catalog else { return }
        try? catalog.deleteAlbum(id: id)
        if source == .album(id) { source = .all }
        reloadSidebar()
    }

    func addToAlbum(_ albumID: Int64, photoIDs: [Int64]) {
        guard let catalog else { return }
        try? catalog.addToAlbum(albumID: albumID, photoIDs: photoIDs)
        statusMessage = "Added \(photoIDs.count) to album."
    }

    func removeFromAlbum(_ albumID: Int64, photoIDs: [Int64]) {
        guard let catalog else { return }
        try? catalog.removeFromAlbum(albumID: albumID, photoIDs: photoIDs)
        reloadItems()
    }

    func removeFolder(_ id: Int64) {
        guard let catalog else { return }
        try? catalog.removeFolder(id: id)
        if source == .folder(id) { source = .all }
        reloadSidebar()
        reloadItems()
    }

    /// Repoint a folder the user moved/renamed on disk (referenced paths are
    /// absolute, so a Finder rename strands them until relinked).
    func relinkFolder(_ id: Int64) {
        guard let catalog,
              let folder = folders.first(where: { $0.id == id }) else { return }
        let panel = NSOpenPanel()
        panel.title = "Locate Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Relink"
        panel.message = "Where is \"\(folder.name)\" now? (was: \(folder.path))"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            try? catalog.relocateFolder(id: id, to: url.path)
            self.reloadSidebar()
            self.reloadItems()
            self.statusMessage = "Relinked \(url.lastPathComponent)."
        }
    }

    func removeFromLibrary(_ ids: [Int64]) {
        guard let catalog else { return }
        try? catalog.removePhotos(ids: ids)
        selection.subtract(ids)
        reloadSidebar()
        reloadItems()
    }

    /// IDs awaiting the "Move to Trash?" confirmation.
    @Published var pendingTrashIDs: [Int64] = []

    /// Really delete: the file (and any .altermeme sidecar) goes to the
    /// Trash — recoverable, but gone from disk — then the catalog row too.
    /// The one deliberate exception to "referenced files are never touched",
    /// only ever behind an explicit confirmation.
    func trashFiles(_ ids: [Int64]) {
        var trashed = 0
        var firstError: String?
        for id in ids {
            guard let target = item(id) else { continue }
            do {
                try FileManager.default.trashItem(at: target.url, resultingItemURL: nil)
                let sidecar = target.url.appendingPathExtension("altermeme")
                if FileManager.default.fileExists(atPath: sidecar.path) {
                    try? FileManager.default.trashItem(at: sidecar, resultingItemURL: nil)
                }
                trashed += 1
            } catch {
                if firstError == nil { firstError = error.localizedDescription }
            }
        }
        removeFromLibrary(ids)
        if let firstError {
            alertMessage = "Some files couldn't be trashed: \(firstError)"
        }
        statusMessage = "Moved \(trashed) file\(trashed == 1 ? "" : "s") to the Trash."
    }

    // MARK: - Revert metadata

    /// Set by the Revert Metadata menu command; ContentView shows the
    /// confirmation alert (same pattern as pendingTrashIDs).
    @Published var pendingRevertIDs: [Int64] = []

    /// Restore each photo's metadata to what was in the file when ALTer found
    /// it. Files ALTer has written into get the as-found snapshot written back;
    /// files never written just re-read, so unsaved catalog edits are discarded
    /// either way. Adjustments are untouched — they never lived in the file.
    func revertMetadata(_ allIDs: [Int64]) async {
        guard let catalog else { return }
        let ids = allIDs.filter { id in item(id).map { !catalog.isApertureOriginal($0.url.path) } ?? false }
        if ids.isEmpty {
            alertMessage = "These are in an Aperture library. Alter never writes into those originals, so there's nothing to revert in the files."
            return
        }
        if isSaving || isWorking {
            alertMessage = "A save or generation is running — try again when it finishes."
            return
        }
        isWorking = true
        defer { isWorking = false }
        autosaveTask?.cancel()

        var reverted = 0
        var failed = 0
        for id in ids {
            guard let current = item(id) else { continue }
            statusMessage = "Reverting \(reverted + failed + 1) of \(ids.count)…"
            do {
                let asFound: PhotoMetadata
                if let backup = try? catalog.metadataBackup(photoID: id) {
                    // ALTer wrote into this file — restore the snapshot.
                    try await ExifToolService.write(metadata: backup, to: current.url)
                    asFound = backup
                } else {
                    // Never written — the file is already as-found; just drop
                    // the catalog's unsaved edits back to what the file holds.
                    let read = try await ExifToolService.readBatch(urls: [current.url])
                    asFound = read[current.url] ?? PhotoMetadata()
                }
                try? catalog.updateMetadata(photoID: id, asFound, dirty: false)
                updateItem(id) {
                    $0.metadata = asFound
                    $0.dirty = false
                    $0.status = .done
                }
                reverted += 1
            } catch {
                updateItem(id) { $0.status = .error(error.localizedDescription) }
                failed += 1
            }
        }
        reloadSidebar()
        if let counts = try? catalog.counts() {
            noAltCount = counts.noAlt
            dirtyCount = counts.dirty
        }
        statusMessage = failed == 0
            ? "Reverted metadata on \(reverted) photo\(reverted == 1 ? "" : "s")."
            : "Reverted \(reverted), failed \(failed) — see marked photos."
    }

    // MARK: - Save (write edits into the files)

    /// Save every dirty photo in the library, not just the visible source.
    func saveDirty() async {
        guard let catalog else { return }
        let targets = (try? catalog.dirtyPhotos()) ?? []
        await save(items: targets)
    }

    func save(ids: [Int64]) async {
        let targets = ids.compactMap { item($0) }.filter(\.dirty)
        await save(items: targets)
    }

    private func save(items allTargets: [PhotoItem]) async {
        guard let catalog, !allTargets.isEmpty else { return }
        // Aperture's originals are never written to; their metadata stays
        // in Alter. Everything else saves as usual.
        let targets = allTargets.filter { !catalog.isApertureOriginal($0.url.path) }
        if targets.isEmpty {
            statusMessage = "These are in an Aperture library — metadata stays in Alter; the originals are never modified."
            return
        }
        // If a save (or generation) is mid-flight, try again shortly.
        if isSaving || isWorking {
            scheduleAutosave()
            return
        }
        isSaving = true
        defer { isSaving = false }
        isWorking = true

        // Before the first-ever write into a file, snapshot its as-found
        // metadata so Revert Metadata can always restore the pre-ALTer state.
        // (-overwrite_original keeps no file-level backup; this is it.)
        if let firstWrites = try? catalog.photoIDsWithoutBackup(among: targets.map(\.id)),
           !firstWrites.isEmpty {
            let urls = targets.filter { firstWrites.contains($0.id) }.map(\.url)
            if let asFound = try? await ExifToolService.readBatch(urls: urls) {
                for target in targets where firstWrites.contains(target.id) {
                    // A file with no metadata at all is a valid (empty) snapshot.
                    try? catalog.setMetadataBackup(
                        photoID: target.id, asFound[target.url] ?? PhotoMetadata())
                }
            }
        }

        var saved = 0
        var failed = 0
        for target in targets {
            updateItem(target.id) { $0.status = .saving }
            statusMessage = "Saving \(saved + failed + 1) of \(targets.count)…"
            do {
                try await ExifToolService.write(metadata: target.metadata, to: target.url)
                try? catalog.markSaved(photoID: target.id)
                updateItem(target.id) {
                    $0.dirty = false
                    $0.status = .done
                }
                saved += 1
            } catch {
                updateItem(target.id) { $0.status = .error(error.localizedDescription) }
                failed += 1
            }
        }
        isWorking = false
        reloadSidebar()
        statusMessage = failed == 0
            ? "Saved metadata into \(saved) file\(saved == 1 ? "" : "s")."
            : "Saved \(saved), failed \(failed) — see marked photos."
        exiftoolMissing = !ExifToolService.isAvailable
    }

    // MARK: - Batch apply

    func applyToSelection(_ mutate: (inout PhotoMetadata) -> Void) {
        for id in selection {
            editMetadata(id, mutate)
        }
    }

    // MARK: - Snippets

    @Published var snippets: [Snippet] = Snippets.load()
    @Published var isSnippetsEditorPresented = false

    func saveSnippets(_ updated: [Snippet]) {
        snippets = updated
        Snippets.save(updated)
    }

    /// Apply a snippet to photos: tokens expand per photo; keywords append.
    func applySnippet(_ snippet: Snippet, to ids: [Int64]) {
        for id in ids {
            guard let current = item(id) else { continue }
            let value = Snippets.expand(snippet.text, item: current)
            editMetadata(id) { meta in
                switch snippet.field {
                case .title: meta.title = value
                case .caption: meta.caption = value
                case .altText: meta.altText = value
                case .creator: meta.creator = value
                case .copyright: meta.copyright = value
                case .keywords:
                    for keyword in PhotoMetadata.splitKeywords(value)
                    where !meta.keywords.contains(keyword) {
                        meta.keywords.append(keyword)
                    }
                }
            }
        }
        statusMessage = "Applied “\(snippet.name)” to \(ids.count) photo\(ids.count == 1 ? "" : "s")."
    }

    // MARK: - On-device intelligence (Auto enhance, suggested tags)

    /// Histogram-derived starting-point adjustments (Core Graphics, on-device).
    /// Sets only exposure, contrast and vibrance; the rest of each recipe
    /// (crop, retouch, brushes, other bricks) stays. One ⌘Z undoes the batch.
    func autoEnhance(ids: [Int64], undoManager: UndoManager? = nil) async {
        let done = await runAuto(.autoEnhance, ids: ids, actionName: "Auto-Enhance",
                                 undoManager: undoManager) { done in
            "Auto-enhancing \(done + 1) of \(ids.count)…"
        }
        statusMessage = "Auto-enhanced \(done) photo\(done == 1 ? "" : "s")."
    }

    /// Analyse each photo and write just `fields`, applying as each one
    /// finishes; registers one undo for the whole run. Returns the count.
    /// `undoManager` is the calling view's; a menu command has none and
    /// takes the front window's, captured before any await.
    private func runAuto(_ fields: AutoEnhance.Fields, ids: [Int64], actionName: String,
                         undoManager: UndoManager?, status: ((Int) -> String)? = nil) async -> Int {
        guard let catalog else { return 0 }
        let undoManager = undoManager ?? (NSApp.keyWindow ?? NSApp.mainWindow)?.undoManager
        if status != nil { isWorking = true }
        defer { if status != nil { isWorking = false } }
        var previous: [Int64: AutoEnhance.Values] = [:]
        var done = 0
        for id in ids {
            guard let current = item(id) else { continue }
            if let status { statusMessage = status(done) }
            let url = current.url
            try? await FileLocality.ensureLocal(url)
            let computed = await Task.detached(priority: .userInitiated) {
                AutoEnhance.values(for: url)
            }.value
            if let computed {
                updateItem(id) { item in
                    previous[id] = item.edits.autoValues
                    item.edits.apply(computed, fields: fields)
                    try? catalog.updateEdits(photoID: id, item.edits)
                }
            }
            done += 1
        }
        registerAutoUndo(previous, fields: fields, actionName: actionName, undoManager: undoManager)
        return done
    }

    /// Put these Auto sliders back and register the swap the other way, so
    /// ⌘Z undoes an Auto and ⌘⇧Z redoes it. Only the Auto fields swap —
    /// a crop or brush made after the Auto survives the undo.
    private func setAutoValues(_ values: [Int64: AutoEnhance.Values], fields: AutoEnhance.Fields,
                               actionName: String, undoManager: UndoManager?) {
        guard let catalog else { return }
        var previous: [Int64: AutoEnhance.Values] = [:]
        for (id, value) in values {
            updateItem(id) { item in
                previous[id] = item.edits.autoValues
                item.edits.apply(value, fields: fields)
                try? catalog.updateEdits(photoID: id, item.edits)
            }
        }
        registerAutoUndo(previous, fields: fields, actionName: actionName, undoManager: undoManager)
    }

    private func registerAutoUndo(_ previous: [Int64: AutoEnhance.Values], fields: AutoEnhance.Fields,
                                  actionName: String, undoManager: UndoManager?) {
        guard !previous.isEmpty, let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { store in
            store.setAutoValues(previous, fields: fields, actionName: actionName, undoManager: undoManager)
        }
        undoManager.setActionName(actionName)
    }

    /// Vision-classifier keyword suggestions, appended to each photo (on-device).
    func suggestKeywords(ids: [Int64], perPhoto: Int = 6) async {
        isWorking = true
        defer { isWorking = false }
        var done = 0
        for id in ids {
            guard let current = item(id) else { continue }
            statusMessage = "Analyzing \(done + 1) of \(ids.count)…"
            try? await FileLocality.ensureLocal(current.url)
            let tags = await TagSuggester.suggest(
                for: current.url, limit: perPhoto, excluding: current.metadata.keywords)
            if !tags.isEmpty {
                addKeywords(tags, to: id)
            }
            done += 1
        }
        statusMessage = "Suggested keywords for \(done) photo\(done == 1 ? "" : "s")."
    }

    func addKeywords(_ keywords: [String], to id: Int64) {
        editMetadata(id) { meta in
            for keyword in keywords where !meta.keywords.contains(keyword) {
                meta.keywords.append(keyword)
            }
        }
    }

    // MARK: - GPS

    func setGPS(latitude: Double, longitude: Double, for allIDs: [Int64]) async {
        let ids = allIDs.filter { id in item(id).map { !isApertureOriginal($0) } ?? false }
        if ids.isEmpty {
            alertMessage = "These are in an Aperture library — Alter never writes into those originals."
            return
        }
        isWorking = true
        defer { isWorking = false }
        var done = 0
        for id in ids {
            guard let current = item(id) else { continue }
            statusMessage = "Writing location \(done + 1) of \(ids.count)…"
            do {
                try await ExifToolService.writeGPS(latitude: latitude, longitude: longitude, to: current.url)
                noteGPS(true, for: [id])
                done += 1
            } catch {
                statusMessage = error.localizedDescription
            }
        }
        statusMessage = "Location saved to \(done) photo\(done == 1 ? "" : "s")."
    }

    func removeGPS(for id: Int64) async {
        guard let current = item(id) else { return }
        do {
            try await ExifToolService.removeGPS(from: current.url)
            noteGPS(false, for: [id])
            statusMessage = "Location removed from \(current.filename)."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    // MARK: - Copy / paste adjustments

    @Published var copiedEdits: PhotoEdits?

    // MARK: - Presets (Aperture's Presets popup)

    private static let presetsKey = "alter.adjustmentPresets"

    @Published var presets: [AdjustmentPreset] = {
        guard let data = UserDefaults.standard.data(forKey: LibraryStore.presetsKey),
              let saved = try? JSONDecoder().decode([AdjustmentPreset].self, from: data) else { return [] }
        return saved
    }() {
        didSet {
            if let data = try? JSONEncoder().encode(presets) {
                UserDefaults.standard.set(data, forKey: Self.presetsKey)
            }
        }
    }

    func savePreset(named name: String, from id: Int64) {
        guard let source = item(id) else { return }
        let preset = AdjustmentPreset(name: name, edits: source.edits.adjustmentsOnly)
        presets.removeAll { $0.name == name }
        presets.append(preset)
        statusMessage = "Saved preset “\(name)”."
    }

    func deletePreset(_ id: UUID) {
        presets.removeAll { $0.id == id }
    }

    func applyPreset(_ preset: AdjustmentPreset, to ids: [Int64]) {
        guard let catalog else { return }
        for id in ids {
            updateItem(id) { item in
                item.edits = item.edits.applying(preset)
                try? catalog.updateEdits(photoID: id, item.edits)
            }
        }
        statusMessage = "Applied “\(preset.name)” to \(ids.count) photo\(ids.count == 1 ? "" : "s")."
    }

    /// Auto for one brick: sets only the sliders that brick's analysis
    /// computes (Exposure → exposure; Enhance → contrast and vibrance;
    /// Highlights & Shadows → highlights and shadows). The brick's other
    /// sliders and the rest of the recipe stay. Undoable.
    func autoBrick(_ brick: AdjustmentBrick, photoID: Int64, undoManager: UndoManager? = nil) async {
        guard let fields = AutoEnhance.Fields(brick: brick) else { return }
        _ = await runAuto(fields, ids: [photoID], actionName: "Auto \(brick.name)",
                          undoManager: undoManager)
    }

    // MARK: - Lift & Stamp (O)

    struct Lifted {
        let filename: String
        let edits: PhotoEdits
        let metadata: PhotoMetadata
        let rating: Int
        let label: Int
        let flagged: Bool
    }

    struct StampOptions {
        var adjustments = true
        var geometry = false
        var retouchAndBrushes = false
        var keywords = true
        var replaceKeywords = false
        var rating = false
        var label = false
        var flag = false
        var info = false   // title, caption, creator, copyright
    }

    @Published var lifted: Lifted?
    @Published var stampOptions = StampOptions()
    @Published var isLiftStampVisible = false

    /// Lift from the primary photo.
    func lift(from id: Int64? = nil) {
        guard let id = id ?? commandTargets.first, let source = item(id) else { return }
        lifted = Lifted(filename: source.filename, edits: source.edits, metadata: source.metadata,
                        rating: source.rating, label: source.label, flagged: source.flagged)
        copiedEdits = source.edits
        statusMessage = "Lifted from \(source.filename)."
    }

    /// Stamp what was lifted onto photos, by the HUD's checkboxes.
    func stamp(to ids: [Int64]? = nil) {
        guard let catalog, let lifted else { return }
        let targets = ids ?? commandTargets
        let o = stampOptions
        for id in targets {
            updateItem(id) { item in
                var edits = item.edits
                if o.adjustments {
                    for brick in AdjustmentBrick.allCases {
                        if lifted.edits.hasValues(brick) || lifted.edits.brushLayerIndex(for: brick) != nil {
                            edits.absorb(lifted.edits, brick: brick)
                            edits.setEnabled(brick, lifted.edits.isEnabled(brick))
                        }
                    }
                }
                if o.geometry {
                    edits.rotation = lifted.edits.rotation
                    edits.straighten = lifted.edits.straighten
                    edits.crop = lifted.edits.crop
                    edits.flipHorizontal = lifted.edits.flipHorizontal
                    edits.flipVertical = lifted.edits.flipVertical
                }
                if o.retouchAndBrushes {
                    edits.retouches = lifted.edits.retouches
                    edits.redEyes = lifted.edits.redEyes
                    edits.brushes = lifted.edits.brushes
                }
                if edits != item.edits {
                    item.edits = edits
                    try? catalog.updateEdits(photoID: id, edits)
                }
                var meta = item.metadata
                var metaChanged = false
                if o.keywords {
                    let incoming = lifted.metadata.keywords
                    let merged = o.replaceKeywords ? incoming
                        : meta.keywords + incoming.filter { k in !meta.keywords.contains { $0.caseInsensitiveCompare(k) == .orderedSame } }
                    if merged != meta.keywords { meta.keywords = merged; metaChanged = true }
                }
                if o.info {
                    meta.title = lifted.metadata.title
                    meta.caption = lifted.metadata.caption
                    meta.creator = lifted.metadata.creator
                    meta.copyright = lifted.metadata.copyright
                    metaChanged = true
                }
                if metaChanged {
                    item.metadata = meta
                    item.dirty = !(catalog.isApertureOriginal(item.url.path))
                    try? catalog.updateMetadata(photoID: id, meta)
                }
            }
            if o.rating { setRating(lifted.rating, for: [id]) }
            if o.label { setLabel(lifted.label, for: [id]) }
            if o.flag { setFlagged(lifted.flagged, for: [id]) }
        }
        reloadSidebar()
        statusMessage = "Stamped \(targets.count) photo\(targets.count == 1 ? "" : "s")."
    }

    func copyEdits(from id: Int64) {
        guard let source = item(id) else { return }
        copiedEdits = source.edits
        statusMessage = "Copied adjustments from \(source.filename)."
    }

    func pasteEdits(to ids: [Int64]) {
        guard let catalog, let edits = copiedEdits else { return }
        for id in ids {
            updateItem(id) { item in
                item.edits = edits
                try? catalog.updateEdits(photoID: id, edits)
            }
        }
        statusMessage = "Pasted adjustments to \(ids.count) photo\(ids.count == 1 ? "" : "s")."
    }

    // MARK: - Per-file relink

    /// Repoint a single photo whose original was moved or renamed.
    func relinkPhoto(_ id: Int64) {
        guard let catalog, let current = item(id) else { return }
        let panel = NSOpenPanel()
        panel.title = "Locate Original"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Relink"
        panel.message = "Where is \"\(current.filename)\" now? (was: \(current.url.path))"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            try? catalog.relocatePhoto(id: id, to: url.path)
            self.reloadItems()
            self.statusMessage = "Relinked \(url.lastPathComponent)."
        }
    }

    // MARK: - Export

    @Published var isBatchChangePresented = false
    @Published var isAdjustDatePresented = false
    /// File ▸ Import ▸ Files…: Aperture's Import window.
    @Published var isImportWindowPresented = false

    /// The sidebar's selected project's name, if one is selected.
    var selectedProjectName: String? {
        selectedProjectID.flatMap { findProject($0)?.name }
    }

    /// Adjust Date & Time: move when these were taken by `seconds` (in the
    /// catalog always; in the files too if asked — never an Aperture
    /// original).
    func adjustCaptureDates(_ ids: [Int64], by seconds: Double, writeToFiles: Bool) async {
        guard let catalog, abs(seconds) >= 1 else { return }
        let masters = Array(Set(ids.compactMap { id in item(id).map { $0.versionOf ?? $0.id } }))
        try? catalog.shiftCaptureDates(photoIDs: masters, by: seconds)
        reloadItems()
        var written = 0
        if writeToFiles {
            isWorking = true
            defer { isWorking = false }
            for id in masters {
                guard let photo = item(id), !isApertureOriginal(photo) else { continue }
                statusMessage = "Changing dates in files… \(written + 1) of \(masters.count)"
                if (try? await ExifToolService.shiftDates(by: seconds, in: photo.url)) != nil {
                    written += 1
                    try? catalog.touchFile(photoID: id, url: photo.url)
                }
            }
            reloadItems()
        }
        let change = AdjustDateSheet.describe(seconds)
        statusMessage = "Adjusted \(masters.count) photo\(masters.count == 1 ? "" : "s") by \(change)"
            + (writeToFiles ? "; \(written) file\(written == 1 ? "" : "s") updated." : ".")
    }
    @Published var isExportSheetPresented = false

    /// Name for prefilled gallery titles: the current album, else the library.
    var currentSourceName: String {
        if case .album(let id) = source ?? .all,
           let album = albums.first(where: { $0.id == id }) {
            return album.name
        }
        if case .smartAlbum(let id) = source ?? .all,
           let album = smartAlbums.first(where: { $0.id == id }) {
            return album.name
        }
        if case .project(let id) = source ?? .all, let project = findProject(id) {
            return project.name
        }
        return libraryName
    }

    /// What Export… will act on: the selection, or everything shown.
    var exportTargets: [PhotoItem] {
        selection.isEmpty ? items : items.filter { selection.contains($0.id) }
    }

    func export(options: ExportOptions) async {
        let targets = exportTargets
        guard !targets.isEmpty else { return }

        isWorking = true
        defer { isWorking = false }

        let fm = FileManager.default
        // Archive exports stage into a temp dir, then zip.
        let stagingDir: URL
        if options.archive != nil {
            stagingDir = fm.temporaryDirectory
                .appendingPathComponent("AlterExport-\(UUID().uuidString)")
        } else {
            stagingDir = options.destination
        }

        do {
            try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)

            var written: [(PhotoItem, URL)] = []
            var failed = 0
            var firstError: String?
            for (index, item) in targets.enumerated() {
                statusMessage = "Exporting \(index + 1) of \(targets.count)…"
                do {
                    let out = try await ExportService.export(
                        item: item, options: options, directory: stagingDir,
                        sequence: index + 1, total: targets.count)
                    written.append((item, out))
                } catch {
                    failed += 1
                    if firstError == nil { firstError = error.localizedDescription }
                    statusMessage = error.localizedDescription
                    if error is ExportError, case ExportError.webpMissing = error {
                        break // every remaining item would fail the same way
                    }
                }
            }
            if let firstError, failed > 0 {
                alertMessage = written.isEmpty
                    ? "Export failed.\n\n\(firstError)"
                    : "Exported \(written.count), but \(failed) failed.\n\nFirst error: \(firstError)"
            }
            if written.isEmpty {
                if options.archive != nil { try? fm.removeItem(at: stagingDir) }
                statusMessage = "Nothing was exported."
                return
            }

            if let archiveURL = options.archive {
                try ExportService.writeManifest(items: written, to: stagingDir)
                statusMessage = "Building archive…"
                try ExportService.zip(directory: stagingDir, to: archiveURL)
                try? fm.removeItem(at: stagingDir)
                statusMessage = "Archived \(written.count) photo\(written.count == 1 ? "" : "s") → \(archiveURL.lastPathComponent)"
                NSWorkspace.shared.activateFileViewerSelecting([archiveURL])
            } else {
                statusMessage = failed == 0
                    ? "Exported \(written.count) photo\(written.count == 1 ? "" : "s")."
                    : "Exported \(written.count), failed \(failed)."
                if let first = written.first?.1 {
                    NSWorkspace.shared.activateFileViewerSelecting([first])
                }
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

}
