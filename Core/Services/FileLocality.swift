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
    static func needsDownload(_ url: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
        guard let values = try? URL(fileURLWithPath: url.path).resourceValues(forKeys: keys),
              values.isUbiquitousItem == true else { return false }
        return values.ubiquitousItemDownloadingStatus != .current
    }

    /// Ensure the file's bytes are on disk, triggering an iCloud download and
    /// polling until it lands (or the timeout passes).
    static func ensureLocal(_ url: URL, timeout: TimeInterval = 20) async throws {
        guard needsDownload(url) else { return }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 300_000_000)
            // Fresh URL each poll — resource values are cached per-instance.
            if !needsDownload(URL(fileURLWithPath: url.path)) { return }
        }
        throw FileLocalityError.stillDownloading(url.lastPathComponent)
    }
}
