//
//  FaceModelStore.swift
//  Alter
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
//  SFace isn't in the download: it's 39 MB, and only people who turn Faces
//  on need it. The first time they do, it comes from OpenCV's own release
//  (pinned to one revision, checked against its SHA-256) and is kept in
//  Application Support. Alter runs that file as published — nothing is
//  converted or re-hosted. After that, Faces works offline.
//

import CryptoKit
import Foundation

@MainActor
final class FaceModelStore: ObservableObject {
    static let shared = FaceModelStore()

    enum State: Equatable {
        case missing
        case downloading(Double)
        case ready
        case failed(String)
    }

    @Published private(set) var state: State = .missing

    /// OpenCV's SFace (Apache 2.0), at a fixed revision of their release.
    private nonisolated static let url = URL(string: "https://huggingface.co/opencv/face_recognition_sface/resolve/3d7082438a6e4551e840c9b2bb60b71e8da4b524/face_recognition_sface_2021dec.onnx")!
    private nonisolated static let size: Int64 = 38_696_353
    private nonisolated static let sha256 = "0ba9fbfa01b5270c96627c4ef784da859931e02f04419c829e83484087c34e79"
    static let source = "SFace by OpenCV (Apache License 2.0)"

    static var downloadSize: String { ByteCountFormatter.string(fromByteCount: size, countStyle: .file) }

    /// ~/Library/Application Support/<app>/Models/sface-2021dec-3d70824/
    nonisolated static var modelURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let app = Bundle.main.bundleIdentifier ?? "app.altermedia.alter"
        return support.appendingPathComponent(app, isDirectory: true)
            .appendingPathComponent("Models/sface-2021dec-3d70824/face_recognition_sface_2021dec.onnx")
    }

    private var task: Task<Void, Never>?
    private var loaded: FaceEmbedder?

    private init() {
        state = FileManager.default.fileExists(atPath: Self.modelURL.path) ? .ready : .missing
    }

    /// The network, loaded once (it takes a tenth of a second).
    func embedder() throws -> FaceEmbedder {
        if let loaded { return loaded }
        let made = try FaceEmbedder(modelAt: Self.modelURL)
        loaded = made
        return made
    }

    func download() {
        guard task == nil, state != .ready else { return }
        state = .downloading(0)
        task = Task { [weak self] in
            do {
                try await Self.fetch { fraction in
                    Task { @MainActor in
                        if case .downloading = self?.state { self?.state = .downloading(fraction) }
                    }
                }
                self?.state = .ready
            } catch is CancellationError {
                self?.state = .missing
            } catch let error as URLError where error.code == .cancelled {
                self?.state = .missing
            } catch {
                self?.state = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
            self?.task = nil
        }
    }

    func cancel() {
        task?.cancel()
    }

    /// Settings ▸ Delete Face Data takes the model too.
    func remove() {
        task?.cancel()
        loaded = nil
        try? FileManager.default.removeItem(at: Self.modelURL.deletingLastPathComponent())
        state = .missing
    }

    enum Failure: LocalizedError {
        case http(Int), checksum
        var errorDescription: String? {
            switch self {
            case .http(let code): return "The download failed (HTTP \(code)). Check the connection and try again."
            case .checksum: return "The face recognition model didn't match its fingerprint — nothing was installed."
            }
        }
    }

    private nonisolated static func fetch(progress: @escaping @Sendable (Double) -> Void) async throws {
        let box = TaskBox()
        let downloaded: URL = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                let task = URLSession.shared.downloadTask(with: url) { location, response, error in
                    if let error { continuation.resume(throwing: error); return }
                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        continuation.resume(throwing: Failure.http(http.statusCode)); return
                    }
                    guard let location else { continuation.resume(throwing: Failure.http(0)); return }
                    // The temp file vanishes when this handler returns.
                    let keep = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                    do {
                        try FileManager.default.moveItem(at: location, to: keep)
                        continuation.resume(returning: keep)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                box.observation = task.progress.observe(\.completedUnitCount) { p, _ in
                    progress(Double(p.completedUnitCount) / Double(size))
                }
                box.task = task
                task.resume()
            }
        } onCancel: {
            box.task?.cancel()
        }
        let fm = FileManager.default
        defer { try? fm.removeItem(at: downloaded) }
        var hasher = SHA256()
        let handle = try FileHandle(forReadingFrom: downloaded)
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        try handle.close()
        guard hasher.finalize().map({ String(format: "%02x", $0) }).joined() == sha256 else { throw Failure.checksum }
        try fm.createDirectory(at: modelURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: modelURL)
        try fm.moveItem(at: downloaded, to: modelURL)
    }

    private final class TaskBox: @unchecked Sendable {
        var task: URLSessionDownloadTask?
        var observation: NSKeyValueObservation?
    }
}
