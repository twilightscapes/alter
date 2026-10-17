//
//  FacesController.swift
//  Alter
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
//  Faces, the Aperture way: a scan in the background finds every face,
//  people name a few, and Alter suggests the rest for them to confirm.
//  Nothing is anyone until someone says so. All of it on this Mac.
//
//  Its own object (the store holds it) so scan progress redraws Faces,
//  not the whole window.
//

import AppKit
import Combine

@MainActor
final class FacesController: ObservableObject {
    private weak var store: LibraryStore?

    /// Faces is off until someone turns it on (it downloads a model).
    @Published private(set) var enabled = UserDefaults.standard.bool(forKey: "faces.enabled")
    @Published private(set) var people: [PersonRow] = []
    /// Every face that isn't "Not a Face", by id.
    @Published private(set) var faces: [Int64: FaceRecord] = [:]
    /// Unnamed face → who it probably is.
    @Published private(set) var suggestions: [Int64: (person: Int64, score: Float)] = [:]
    /// Unnamed faces that go together (two or more), biggest first.
    @Published private(set) var groups: [[FaceRecord]] = []
    /// Unnamed faces seen just once (or too small to know).
    @Published private(set) var loneFaces = 0
    @Published private(set) var isScanning = false
    @Published private(set) var progress: (done: Int, total: Int) = (0, 0)

    private var scanTask: Task<Void, Never>?
    private var reloadTask: Task<Void, Never>?
    private var lastReload = Date.distantPast
    private var modelWatch: AnyCancellable?

    init(store: LibraryStore) {
        self.store = store
        // When the model lands, start looking.
        modelWatch = FaceModelStore.shared.$state.sink { [weak self] state in
            guard state == .ready else { return }
            Task { @MainActor in self?.startScan() }
        }
    }

    private var catalog: Catalog? { store?.catalog }

    // MARK: On / off

    /// Turn Faces on: fetch the model if it isn't here, then scan.
    func enable() {
        enabled = true
        UserDefaults.standard.set(true, forKey: "faces.enabled")
        if FaceModelStore.shared.state == .ready { startScan() } else { FaceModelStore.shared.download() }
        reload()
    }

    /// Stop looking; what's been found and named stays.
    func disable() {
        enabled = false
        UserDefaults.standard.set(false, forKey: "faces.enabled")
        stopScan()
    }

    /// Everything Faces knows, and the model, gone.
    func deleteAllData() {
        stopScan()
        try? catalog?.deleteAllFaceData()
        FaceModelStore.shared.remove()
        enabled = false
        UserDefaults.standard.set(false, forKey: "faces.enabled")
        reload()
        store?.reloadItems()
        if case .person = store?.source { store?.source = .faces }
    }

    /// Look at every photo again (names stay).
    func rescan() {
        stopScan()
        try? catalog?.resetFaceScan()
        startScan()
    }

    /// The store opened or closed a library.
    func libraryChanged() {
        stopScan()
        reload()
        startScan()
    }

    // MARK: Scanning

    func startScan() {
        guard enabled, scanTask == nil, catalog != nil, FaceModelStore.shared.state == .ready,
              let embedder = try? FaceModelStore.shared.embedder() else { return }
        scanTask = Task { [weak self] in
            await self?.scan(with: embedder)
            self?.scanTask = nil
        }
    }

    func stopScan() {
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
    }

    private func scan(with embedder: FaceEmbedder) async {
        guard let catalog else { return }
        // Files that aren't on this Mac (iCloud, an unplugged drive) are
        // passed over this session — never downloaded just to look.
        var skipping = Set<Int64>()
        progress = (try? catalog.faceScanProgress()) ?? (0, 0)
        while !Task.isCancelled {
            let batch = (try? catalog.photosNeedingFaceScan(limit: 12, skipping: skipping)) ?? []
            if batch.isEmpty { break }
            isScanning = true
            let results = await Task.detached(priority: .utility) {
                batch.map { photo -> (id: Int64, result: FaceScanner.Result?, skip: Bool) in
                    let url = URL(fileURLWithPath: photo.path)
                    if ImageLoader.isVideoFile(url) { return (photo.id, nil, false) }
                    if !FileManager.default.fileExists(atPath: url.path) || FileLocality.needsDownload(url) {
                        return (photo.id, nil, true)
                    }
                    return (photo.id, FaceScanner.scan(url, embedder: embedder), false)
                }
            }.value
            // The library changed underneath — stop; the new one starts its own.
            guard !Task.isCancelled, catalog === self.catalog else { break }
            for item in results {
                if item.skip {
                    skipping.insert(item.id)
                } else if let result = item.result {
                    try? catalog.saveScannedFaces(photoID: item.id, imageSize: result.imageSize, faces: result.faces)
                } else {
                    try? catalog.markFaceScanned(photoID: item.id)
                }
            }
            progress = (try? catalog.faceScanProgress()) ?? progress
            // Fresh groups now and then while it works.
            if Date().timeIntervalSince(lastReload) > 8 { reload() }
        }
        isScanning = false
        if !Task.isCancelled { reload() }
    }

    /// The viewer opened a photo the scan hasn't reached: look at it now.
    func ensureScanned(photoID: Int64) async {
        guard enabled, FaceModelStore.shared.state == .ready, let catalog,
              !catalog.isFaceScanned(photoID: photoID),
              let path = try? catalog.photoPath(photoID),
              let embedder = try? FaceModelStore.shared.embedder() else { return }
        let url = URL(fileURLWithPath: path)
        guard !ImageLoader.isVideoFile(url) else { return }
        let result = await Task.detached(priority: .userInitiated) {
            FaceScanner.scan(url, embedder: embedder)
        }.value
        guard let result, catalog === self.catalog, !catalog.isFaceScanned(photoID: photoID) else { return }
        try? catalog.saveScannedFaces(photoID: photoID, imageSize: result.imageSize, faces: result.faces)
        reload()
    }

    // MARK: Reading

    /// People, faces, suggestions and groups, from the catalog (the sums
    /// off the main thread).
    func reload() {
        lastReload = Date()
        guard let catalog else {
            people = []; faces = [:]; suggestions = [:]; groups = []; loneFaces = 0; progress = (0, 0)
            return
        }
        people = (try? catalog.people()) ?? []
        let all = (try? catalog.allFaces()) ?? []
        let rejections = (try? catalog.faceRejections()) ?? [:]
        faces = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        if !isScanning { progress = (try? catalog.faceScanProgress()) ?? progress }
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            let (suggested, grouped) = await Task.detached(priority: .userInitiated) {
                (FaceMath.suggestions(faces: all, rejections: rejections), FaceMath.groups(all))
            }.value
            guard !Task.isCancelled, let self else { return }
            // A face already suggested for someone shows there, not in a group.
            let open = grouped.map { $0.filter { suggested[$0.id] == nil } }
            self.suggestions = suggested
            self.groups = open.filter { $0.count > 1 }
            self.loneFaces = open.filter { $0.count == 1 }.count
        }
    }

    func person(_ id: Int64) -> PersonRow? { people.first { $0.id == id } }

    func faces(onPhoto photoID: Int64) -> [FaceRecord] {
        faces.values.filter { $0.photoID == photoID }.sorted { $0.rect.minX < $1.rect.minX }
    }

    /// Faces that may be this person, best first.
    func suggestedFaces(for personID: Int64) -> [FaceRecord] {
        suggestions.filter { $0.value.person == personID }
            .sorted { $0.value.score > $1.value.score }
            .compactMap { faces[$0.key] }
    }

    /// Names that start with (or contain) what's typed, for completion.
    func names(matching text: String) -> [String] {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return [] }
        let starts = people.filter { $0.name.lowercased().hasPrefix(t.lowercased()) }
        let contains = people.filter { !$0.name.lowercased().hasPrefix(t.lowercased()) && $0.name.localizedCaseInsensitiveContains(t) }
        return (starts + contains).map(\.name).filter { $0.caseInsensitiveCompare(t) != .orderedSame }.prefix(5).map { $0 }
    }

    // MARK: Naming

    /// "These are <name>." Makes the person if they're new.
    func name(_ faceIDs: [Int64], as name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let catalog, let person = try? catalog.person(named: trimmed) else { return }
        changed(try? catalog.assignFaces(faceIDs, to: person))
    }

    func confirm(_ faceIDs: [Int64], as personID: Int64) {
        changed(try? catalog?.assignFaces(faceIDs, to: personID))
    }

    /// Take the name off (the face stays, unnamed).
    func unname(_ faceIDs: [Int64]) {
        changed(try? catalog?.assignFaces(faceIDs, to: nil))
    }

    /// "That isn't them."
    func reject(_ faceIDs: [Int64], for personID: Int64) {
        try? catalog?.rejectFaces(faceIDs, for: personID)
        changed([])
    }

    func notAFace(_ faceIDs: [Int64]) {
        changed(try? catalog?.ignoreFaces(faceIDs))
    }

    func rename(_ personID: Int64, to name: String) {
        try? catalog?.renamePerson(personID, to: name)
        changed([])
        store?.reloadItems()
    }

    func setKeyFace(_ faceID: Int64, for personID: Int64) {
        try? catalog?.setKeyFace(faceID, for: personID)
        reload()
    }

    func deletePerson(_ personID: Int64) {
        try? catalog?.deletePerson(personID)
        if store?.source == .person(personID) { store?.source = .faces }
        changed([])
        store?.reloadItems()
    }

    /// Add Missing Face: a box drawn on a master. It's fingerprinted like
    /// a found face, so it joins suggestions too.
    func addFace(photoID: Int64, rect: CGRect, name: String?) {
        guard let catalog, let path = try? catalog.photoPath(photoID) else { return }
        let embedder = FaceModelStore.shared.state == .ready ? try? FaceModelStore.shared.embedder() : nil
        Task {
            let (size, print) = await Task.detached(priority: .userInitiated) { () -> (CGSize, [Float]?) in
                guard let embedder,
                      let made = FaceScanner.fingerprint(URL(fileURLWithPath: path), rect: rect, embedder: embedder)
                else {
                    let image = FaceScanner.image(at: URL(fileURLWithPath: path), maxPixel: 256)
                    return (CGSize(width: image?.width ?? 0, height: image?.height ?? 0), nil)
                }
                return made
            }.value
            guard catalog === self.catalog,
                  let id = try? catalog.insertFace(photoID: photoID, rect: rect, imageSize: size, quality: 1,
                                                   print: print, manual: true) else { return }
            if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty {
                self.name([id], as: name)
            } else {
                self.reload()
            }
        }
    }

    /// After a change: Faces reloads, and the grid/Info/smart albums see
    /// the new names.
    private func changed(_ photos: [Int64]?) {
        reload()
        if let photos, !photos.isEmpty { store?.reloadItems() }
    }
}

// MARK: - Face pictures

/// Square crops of faces for Faces and the suggestions strip, cached.
@MainActor
final class FaceThumbnails {
    static let shared = FaceThumbnails()
    private let cache = NSCache<NSNumber, NSImage>()
    private static let queue = DispatchQueue(label: "app.altermedia.faces.thumbnails", qos: .userInitiated,
                                             attributes: .concurrent)

    func cached(_ face: FaceRecord) -> NSImage? { cache.object(forKey: NSNumber(value: face.id)) }

    func image(for face: FaceRecord, path: String, side: CGFloat = 240) async -> NSImage? {
        if let hit = cached(face) { return hit }
        let made: NSImage? = await withCheckedContinuation { continuation in
            Self.queue.async {
                continuation.resume(returning: Self.crop(face, url: URL(fileURLWithPath: path), side: side))
            }
        }
        if let made { cache.setObject(made, forKey: NSNumber(value: face.id)) }
        return made
    }

    func forget(_ faceID: Int64) { cache.removeObject(forKey: NSNumber(value: faceID)) }

    private nonisolated static func crop(_ face: FaceRecord, url: URL, side: CGFloat) -> NSImage? {
        // Just enough pixels for the crop to be `side` across.
        let aspect = face.imageSize.width > 0 && face.imageSize.height > 0
            ? face.imageSize.height / face.imageSize.width : 1
        let span = max(face.rect.width, face.rect.height / max(aspect, 0.01)) * 1.7
        let wantWidth = side / max(span, 0.01)
        let longSide = aspect > 1 ? wantWidth * aspect : wantWidth
        let maxPixel = Int(min(4096, max(256, longSide)))
        guard let image = FaceScanner.image(at: url, maxPixel: maxPixel) else { return nil }
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let size = min(max(face.rect.width * w, face.rect.height * h) * 1.7, min(w, h))
        var box = CGRect(x: face.rect.midX * w - size / 2, y: face.rect.midY * h - size / 2, width: size, height: size)
        box.origin.x = min(max(0, box.minX), w - size)
        box.origin.y = min(max(0, box.minY), h - size)
        guard let cropped = image.cropping(to: box.integral) else { return nil }
        return NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height))
    }
}
