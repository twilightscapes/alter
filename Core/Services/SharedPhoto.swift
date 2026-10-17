//
//  SharedPhoto.swift
//  Alter
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
//  File ▸ Share (Aperture's Share menu, now the Mac's own: Mail, Messages,
//  AirDrop, Notes…). A photo goes out as a JPEG with its adjustments in
//  it, rendered only when a service asks — choosing Share costs nothing.
//

import CoreTransferable
import Foundation
import UniformTypeIdentifiers

struct SharedPhoto: Transferable {
    let item: PhotoItem

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .jpeg) { photo in
            SentTransferredFile(try await photo.render())
        }
    }

    /// The edited photo as a full-size JPEG in a temporary folder.
    private func render() async throws -> URL {
        let item = self.item
        return try await Task.detached(priority: .userInitiated) {
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("Alter Share/\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let out = folder.appendingPathComponent(item.url.deletingPathExtension().lastPathComponent + ".jpg")
            try ExportService.render(item: item, format: .jpeg, sizing: .original, quality: 0.9, to: out)
            return out
        }.value
    }
}
