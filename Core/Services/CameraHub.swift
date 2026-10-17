//
//  CameraHub.swift
//  Alter
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
//  Cameras over USB, through ImageCaptureCore (what Image Capture uses):
//  their photos for the Import window, and tethered shooting — every shot
//  straight into the library. Started the first time the Import window
//  opens (that's when macOS asks for permission), kept for the session.
//

import AppKit
import ImageCaptureCore

@MainActor
final class CameraHub: NSObject, ObservableObject {
    static let shared = CameraHub()

    @Published private(set) var cameras: [Camera] = []
    /// The tethered session running, if one is.
    @Published private(set) var tether: TetherSession?

    private let browser = ICDeviceBrowser()
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        browser.delegate = self
        let mask = ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: mask) ?? .camera
        // macOS asks the user itself the first time a camera is opened.
        browser.start()
    }

    func startTether(on camera: Camera, plan: TetherPlan, store: LibraryStore) {
        tether?.stop()
        let session = TetherSession(camera: camera, plan: plan, store: store)
        tether = session
        session.begin()
    }

    func stopTether() {
        tether?.stop()
        tether = nil
    }

    fileprivate func camera(for device: ICDevice) -> Camera? {
        cameras.first { $0.device === device }
    }
}

extension CameraHub: ICDeviceBrowserDelegate {
    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        Task { @MainActor in
            guard let device = device as? ICCameraDevice, self.camera(for: device) == nil else { return }
            self.cameras.append(Camera(device: device))
        }
    }

    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        Task { @MainActor in
            if let tether = self.tether, tether.camera.device === device { self.stopTether() }
            self.cameras.removeAll { $0.device === device }
        }
    }
}

// MARK: - One camera

/// A connected camera: its session, its photos, what it can do.
@MainActor
final class Camera: NSObject, ObservableObject, Identifiable {
    let device: ICCameraDevice
    nonisolated var id: ObjectIdentifier { ObjectIdentifier(device) }
    var name: String { device.name ?? "Camera" }

    @Published private(set) var isReady = false
    @Published private(set) var files: [ICCameraFile] = []
    /// Bumped as thumbnails arrive, so the window redraws them.
    @Published private(set) var thumbnailTick = 0
    @Published private(set) var canTakePicture = false

    /// New items while tethered go here (the session's).
    fileprivate var onNewFiles: (([ICCameraFile]) -> Void)?

    init(device: ICCameraDevice) {
        self.device = device
        super.init()
        device.delegate = self
    }

    func open() {
        guard !device.hasOpenSession else { return }
        device.requestOpenSession()
    }

    fileprivate func refresh() {
        files = (device.mediaFiles ?? []).compactMap { $0 as? ICCameraFile }
            .sorted { $0.name?.localizedStandardCompare($1.name ?? "") == .orderedAscending }
        canTakePicture = device.capabilities.contains(ICDeviceCapability.cameraDeviceCanTakePicture.rawValue)
        for file in files where file.thumbnail == nil { file.requestThumbnail() }
    }

    /// Copy one photo off the camera into `folder` as `name` (no extension —
    /// the camera's is kept). Returns where it landed.
    func download(_ file: ICCameraFile, to folder: URL, as name: String?) async -> URL? {
        var options: [ICDownloadOption: Any] = [.downloadsDirectoryURL: folder, .overwrite: false]
        let ext = (file.name as NSString?)?.pathExtension ?? ""
        if let name {
            options[.saveAsFilename] = ext.isEmpty ? name : "\(name).\(ext)"
        }
        return await withCheckedContinuation { continuation in
            _ = file.requestDownload(options: options) { filename, error in
                guard error == nil, let filename else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: folder.appendingPathComponent(filename))
            }
        }
    }
}

extension Camera: ICCameraDeviceDelegate {
    nonisolated func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {}
    nonisolated func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {
        Task { @MainActor in self.isReady = false }
    }
    nonisolated func didRemove(_ device: ICDevice) {}
    nonisolated func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        Task { @MainActor in
            self.isReady = true
            self.refresh()
        }
    }
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {
        Task { @MainActor in
            let new = items.compactMap { $0 as? ICCameraFile }
            self.refresh()
            if self.isReady, !new.isEmpty { self.onNewFiles?(new) }
        }
    }
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {
        Task { @MainActor in self.refresh() }
    }
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?,
                                  for item: ICCameraItem, error: Error?) {
        Task { @MainActor in self.thumbnailTick += 1 }
    }
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?,
                                  for item: ICCameraItem, error: Error?) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    nonisolated func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {
        Task { @MainActor in self.canTakePicture = camera.capabilities.contains(ICDeviceCapability.cameraDeviceCanTakePicture.rawValue) }
    }
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}
    nonisolated func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {
        Task { @MainActor in self.refresh() }
    }
    nonisolated func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {}
}

// MARK: - Tethered shooting

/// Where tethered shots go and how they're named and filed.
struct TetherPlan {
    var folder: URL
    var namingPattern: String?
    var project: ImportPlan.Project
    var creator = ""
    var copyright = ""
    var keywords = ""
}

/// Aperture's tethered session: every shot — from the camera's shutter or
/// the Capture button — copied off, catalogued, filed and shown.
@MainActor
final class TetherSession: ObservableObject {
    let camera: Camera
    let plan: TetherPlan
    private weak var store: LibraryStore?

    @Published private(set) var shots = 0
    @Published private(set) var lastShot: NSImage?
    @Published private(set) var busy = false
    /// The project the session files into (made on the first shot when the
    /// plan asks for a new one).
    private var projectID: Int64?

    init(camera: Camera, plan: TetherPlan, store: LibraryStore) {
        self.camera = camera
        self.plan = plan
        self.store = store
    }

    func begin() {
        camera.open()
        camera.device.requestEnableTethering()
        camera.onNewFiles = { [weak self] files in
            Task { await self?.take(files) }
        }
        store?.statusMessage = "Tethered to \(camera.name)" + (camera.canTakePicture ? " — press Capture or the shutter." : " — shots taken on the camera come straight in.")
    }

    func capture() {
        guard camera.canTakePicture else { return }
        camera.device.requestTakePicture()
    }

    func stop() {
        camera.onNewFiles = nil
        camera.device.requestDisableTethering()
        store?.statusMessage = "Tethered session ended: \(shots) shot\(shots == 1 ? "" : "s")."
    }

    private func take(_ files: [ICCameraFile]) async {
        guard let store, let catalog = store.catalog else { return }
        busy = true
        defer { busy = false }
        try? FileManager.default.createDirectory(at: plan.folder, withIntermediateDirectories: true)
        for file in files {
            shots += 1
            let base = (file.name as NSString?)?.deletingPathExtension ?? "Shot \(shots)"
            let name = plan.namingPattern.map {
                $0.replacingOccurrences(of: "{name}", with: base)
                    .replacingOccurrences(of: "{title}", with: base)
                    .replacingOccurrences(of: "{seq}", with: String(format: "%03d", shots))
                    .replacingOccurrences(of: "{date}", with: Self.day.string(from: Date()))
            }
            guard let url = await camera.download(file, to: plan.folder, as: name) else { continue }
            let ids = await store.importURLs([url])
            guard let id = ids.first else { continue }
            // File it.
            switch plan.project {
            case .current:
                break
            case .new(let projectName):
                if projectID == nil { projectID = try? catalog.createProject(name: projectName) }
                if let projectID { try? catalog.setProject(projectID, photoIDs: [id]) }
            case .byDay:
                let day = Self.day.string(from: Date())
                if projectID == nil { projectID = try? catalog.createProject(name: day) }
                if let projectID { try? catalog.setProject(projectID, photoIDs: [id]) }
            }
            let keywords = PhotoMetadata.splitKeywords(plan.keywords)
            if !plan.creator.isEmpty || !plan.copyright.isEmpty || !keywords.isEmpty {
                store.editMetadata(id) { meta in
                    if !self.plan.creator.isEmpty { meta.creator = self.plan.creator }
                    if !self.plan.copyright.isEmpty { meta.copyright = self.plan.copyright }
                    for k in keywords where !meta.keywords.contains(where: { $0.caseInsensitiveCompare(k) == .orderedSame }) {
                        meta.keywords.append(k)
                    }
                }
            }
            store.reloadSidebar()
            store.reloadItems()
            // Show the shot, as Aperture did.
            store.selection = [id]
            store.enterViewer(id)
            lastShot = ImageLoader.shared.thumbnail(for: url, maxPixel: 320)
        }
    }

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
