//
//  ExportService.swift
//  Alter
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
//  Renders photos out of the library into the export "ecosphere": new files
//  (JPEG/PNG/WebP), resized, with the catalog's edited metadata stamped in.
//  Originals are never touched. Rendered files carry NO camera EXIF/GPS unless
//  explicitly copied — privacy-by-default for web publishing.
//

import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ExportFormat: String, CaseIterable, Identifiable {
    case jpeg = "JPEG"
    case png = "PNG"
    case webp = "WebP"

    var id: String { rawValue }
    var fileExtension: String {
        switch self {
        case .jpeg: return "jpg"
        case .png: return "png"
        case .webp: return "webp"
        }
    }
    var usesQuality: Bool { self != .png }
}

enum ExportSizing: Hashable {
    case original
    case maxEdge(Int)
}

struct ExportOptions {
    var format: ExportFormat = .jpeg
    var quality: Double = 0.85
    var sizing: ExportSizing = .original
    var namingPattern: String = "{name}"
    var includeMetadata = true
    var copyCameraEXIF = false
    var stripGPS = true
    var applyWatermark = false
    /// Destination directory; when `archive` is set, files are staged in a temp
    /// dir and zipped to `archive` with a manifest.csv.
    var destination: URL
    var archive: URL?
}

enum ExportError: LocalizedError {
    case render(String)
    case webpMissing
    case zipFailed(String)

    var errorDescription: String? {
        switch self {
        case .render(let file): return "Couldn't render \(file)."
        case .webpMissing:
            return "WebP export needs cwebp. Install it (brew install webp) or bundle it in the app."
        case .zipFailed(let message): return "Couldn't create archive: \(message)"
        }
    }
}

struct ExportService {

    static func cwebpPath() -> String? {
        if let bundled = Bundle.main.path(forResource: "cwebp", ofType: nil) { return bundled }
        for path in ["/opt/homebrew/bin/cwebp", "/usr/local/bin/cwebp"] {
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    static var webpAvailable: Bool { cwebpPath() != nil }

    // MARK: - Single file

    /// Render one photo to `directory` and return the written URL.
    static func export(item: PhotoItem, options: ExportOptions, directory: URL,
                       sequence: Int, total: Int) async throws -> URL {
        let base = NamingPresets.filename(
            pattern: options.namingPattern, item: item, sequence: sequence, total: total)
        var outURL = directory.appendingPathComponent(base).appendingPathExtension(options.format.fileExtension)

        // Avoid collisions from patterns like {title} repeating.
        var counter = 1
        while FileManager.default.fileExists(atPath: outURL.path) {
            counter += 1
            outURL = directory.appendingPathComponent("\(base)-\(counter)")
                .appendingPathExtension(options.format.fileExtension)
        }

        try await FileLocality.ensureLocal(item.url)
        if item.isVideo {
            // Videos pass through untouched (renamed); renditions come with
            // the timeline editor's own export.
            let videoOut = outURL.deletingPathExtension()
                .appendingPathExtension(item.url.pathExtension)
            try FileManager.default.copyItem(at: item.url, to: videoOut)
            return videoOut
        }
        try render(item: item, format: options.format, sizing: options.sizing,
                   quality: options.quality, watermark: options.applyWatermark, to: outURL)

        if options.includeMetadata {
            try await ExifToolService.write(metadata: item.metadata, to: outURL)
        }
        if options.copyCameraEXIF {
            try await ExifToolService.copyCameraEXIF(
                from: item.url, to: outURL, stripGPS: options.stripGPS)
        }
        return outURL
    }

    /// Render one rendition of a photo to disk (also used by gallery publishing).
    static func render(item: PhotoItem, format: ExportFormat, sizing: ExportSizing,
                       quality: Double, watermark: Bool = false, to outURL: URL) throws {
        guard FileManager.default.fileExists(atPath: item.url.path) else {
            throw ExportError.render("\(item.filename) — original not found at \(item.url.path)")
        }
        guard FileManager.default.isReadableFile(atPath: item.url.path) else {
            throw ExportError.render("\(item.filename) — no permission to read the original")
        }
        guard let source = CGImageSourceCreateWithURL(item.url as CFURL, nil) else {
            throw ExportError.render("\(item.filename) — couldn't open the original image")
        }

        // Determine target pixel size.
        let maxPixel: Int
        switch sizing {
        case .original:
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let width = (props?[kCGImagePropertyPixelWidth] as? Int) ?? 10000
            let height = (props?[kCGImagePropertyPixelHeight] as? Int) ?? 10000
            maxPixel = max(width, height)
        case .maxEdge(let edge):
            maxPixel = edge
        }

        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            // Aperture imports draw raw pixels; their rotation covers it.
            kCGImageSourceCreateThumbnailWithTransform: item.edits.appliesFileOrientation,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard var cg = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else {
            throw ExportError.render("\(item.filename) — couldn't decode the image")
        }
        // Bake the non-destructive adjustment recipe into the rendition.
        cg = EditRenderer.apply(item.edits, to: cg)
        if watermark {
            cg = Watermark.apply(to: cg, settings: Watermark.load())
        }

        switch format {
        case .jpeg, .png:
            let type = (format == .jpeg ? UTType.jpeg : UTType.png).identifier as CFString
            guard let destination = CGImageDestinationCreateWithURL(outURL as CFURL, type, 1, nil) else {
                throw ExportError.render("\(item.filename) — couldn't create \(outURL.lastPathComponent) in the destination")
            }
            var props: [CFString: Any] = [:]
            if format == .jpeg {
                props[kCGImageDestinationLossyCompressionQuality] = quality
            }
            CGImageDestinationAddImage(destination, cg, props as CFDictionary)
            guard CGImageDestinationFinalize(destination) else {
                throw ExportError.render("\(item.filename) — couldn't write \(outURL.lastPathComponent)")
            }
        case .webp:
            guard let cwebp = cwebpPath() else { throw ExportError.webpMissing }
            // Stage as PNG, then encode with cwebp.
            let staging = outURL.deletingPathExtension().appendingPathExtension("staging.png")
            guard let destination = CGImageDestinationCreateWithURL(
                staging as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                throw ExportError.render("\(item.filename) — couldn't stage WebP conversion")
            }
            CGImageDestinationAddImage(destination, cg, nil)
            guard CGImageDestinationFinalize(destination) else {
                throw ExportError.render("\(item.filename) — couldn't stage WebP conversion")
            }
            defer { try? FileManager.default.removeItem(at: staging) }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: cwebp)
            process.arguments = ["-q", String(Int(quality * 100)), staging.path, "-o", outURL.path]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw ExportError.render("\(item.filename) — cwebp encoding failed")
            }
        }
    }

    // MARK: - Manifest + archive

    static func writeManifest(items: [(PhotoItem, URL)], to directory: URL) throws {
        func csvField(_ value: String) -> String {
            "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        var csv = "filename,title,alt_text,caption,keywords,creator,copyright,original\n"
        for (item, outURL) in items {
            let meta = item.metadata
            csv += [
                csvField(outURL.lastPathComponent),
                csvField(meta.title),
                csvField(meta.altText),
                csvField(meta.caption),
                csvField(meta.keywords.joined(separator: "; ")),
                csvField(meta.creator),
                csvField(meta.copyright),
                csvField(item.filename),
            ].joined(separator: ",") + "\n"
        }
        try csv.write(to: directory.appendingPathComponent("manifest.csv"), atomically: true, encoding: .utf8)
    }

    /// Zip `directory`'s contents to `archiveURL` (via ditto, preserving nothing exotic).
    static func zip(directory: URL, to archiveURL: URL) throws {
        try? FileManager.default.removeItem(at: archiveURL)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", directory.path, archiveURL.path]
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw ExportError.zipFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
