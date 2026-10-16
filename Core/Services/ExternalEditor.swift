//
//  ExternalEditor.swift
//  Alter
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
//  Aperture's "Edit with…": render the version at full size to a TIFF
//  the editor can own, add it to the library beside the original, and
//  open it. Edited pixels come back when the file changes on disk.
//

import AppKit
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ExternalEditor {
    /// Apps on this Mac that can open a TIFF, Aperture's "external editor"
    /// candidates, sorted by name with ALTer itself left out.
    static func candidateApps() -> [(name: String, url: URL)] {
        let urls = NSWorkspace.shared.urlsForApplications(toOpen: UTType.tiff)
        let own = Bundle.main.bundleURL.standardizedFileURL
        // Viewers that merely display a TIFF aren't editors.
        let notEditors: Set<String> = ["Safari", "QuickTime Player", "ColorSync Utility", "xScope", "Image Playground", "Finder"]
        var seen = Set<String>()
        return urls
            .filter { $0.standardizedFileURL != own }
            .filter { !notEditors.contains(FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "")) }
            .compactMap { url -> (String, URL)? in
                let name = FileManager.default.displayName(atPath: url.path)
                    .replacingOccurrences(of: ".app", with: "")
                guard seen.insert(name).inserted else { return nil }
                return (name, url)
            }
            .sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
    }

    /// Where edited copies live: inside the library package, never beside
    /// (or inside) an Aperture bundle.
    static func externalsDirectory(for libraryURL: URL) throws -> URL {
        let dir = libraryURL.appendingPathComponent("External", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Full-resolution render of the version (recipe applied) as a 16-bit
    /// TIFF named after the original.
    static func renderTIFF(item: PhotoItem, into directory: URL) throws -> URL {
        guard let source = CGImageSourceCreateWithURL(item.url as CFURL, nil) else {
            throw ExportError.render(item.filename)
        }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let w = props?[kCGImagePropertyPixelWidth] as? Double ?? 0
        let h = props?[kCGImagePropertyPixelHeight] as? Double ?? 0
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: item.edits.appliesFileOrientation,
            kCGImageSourceThumbnailMaxPixelSize: max(w, h, 1),
        ]
        guard let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ExportError.render(item.filename)
        }
        let rendered = EditRenderer.apply(item.edits, to: decoded)

        let base = item.url.deletingPathExtension().lastPathComponent
        var url = directory.appendingPathComponent("\(base) (edited).tiff")
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(base) (edited \(counter)).tiff")
            counter += 1
        }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 1, nil) else {
            throw ExportError.render(item.filename)
        }
        let tiffProps: [CFString: Any] = [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 5] as [CFString: Any],   // LZW
        ]
        CGImageDestinationAddImage(destination, rendered, tiffProps as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ExportError.render(item.filename) }
        return url
    }
}
