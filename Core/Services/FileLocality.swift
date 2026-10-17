//
//  FileLocality.swift
//  Alter
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
//  Photos on iCloud Drive (or an iCloud-synced Desktop/Documents) can be
//  "dataless" placeholders — evicted from disk until requested. Reading one
//  fails outright, which shows up as grey thumbnails and failed renders.
//  Before touching an original, ask iCloud to materialize it and wait.
//

import Foundation

enum FileLocalityError: LocalizedError {
    case stillDownloading(String)

    var errorDescription: String? {
        switch self {
        case .stillDownloading(let name):
            return "\(name) is still downloading from iCloud — try again in a moment."
        }
    }
}

enum FileLocality {

    /// True if the file is an iCloud item that isn't fully local yet.
    /// Blocking — and on an iCloud Desktop the File Provider behind it can
    /// stop answering — so app code asks through `needsDownload(_:within:)`.
    static func needsDownload(_ url: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
        guard let values = try? URL(fileURLWithPath: url.path).resourceValues(forKeys: keys),
              values.isUbiquitousItem == true else { return false }
        return values.ubiquitousItemDownloadingStatus != .current
    }

    /// Where those questions are asked: never Swift's shared threads. A
    /// hung File Provider once held all of them (a grid of thumbnails, each
    /// asking), and the whole app stopped.
    private static let queue = DispatchQueue(label: "app.altermedia.file-locality", qos: .utility,
                                             attributes: .concurrent)

    /// The same question, off the shared threads and with a time limit: no
    /// answer in `limit` seconds counts as "local" (reading it then either
    /// works or shows the file as unreadable — it never freezes the app).
    static func needsDownload(_ url: URL, within limit: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            let answered = Answered()
            queue.async {
                let result = needsDownload(url)
                if answered.claim() { continuation.resume(returning: result) }
            }
            queue.asyncAfter(deadline: .now() + limit) {
                if answered.claim() { continuation.resume(returning: false) }
            }
        }
    }

    /// Ensure the file's bytes are on disk, triggering an iCloud download and
    /// polling until it lands (or the timeout passes).
    static func ensureLocal(_ url: URL, timeout: TimeInterval = 20) async throws {
        guard await needsDownload(url, within: 2) else { return }
        queue.async { try? FileManager.default.startDownloadingUbiquitousItem(at: url) }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 300_000_000)
            // Fresh URL each poll — resource values are cached per-instance.
            if await !needsDownload(URL(fileURLWithPath: url.path), within: 2) { return }
        }
        throw FileLocalityError.stillDownloading(url.lastPathComponent)
    }

    /// First caller wins: the answer or the timeout, never both.
    private final class Answered: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }
}
