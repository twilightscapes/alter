//
//  ImageLoader.swift
//  Alter
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
//  Thumbnails for the grid + downscaled JPEG base64 for the engine (ALT text
//  needs no more than ~1024px, and it slashes payload/token cost).
//

import AppKit
import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ImageLoaderError: LocalizedError {
    case unreadable

    var errorDescription: String? { "Couldn't read this image." }
}

final class ImageLoader {
    static let shared = ImageLoader()
    private let cache = NSCache<NSURL, NSImage>()

    private init() {
        cache.countLimit = 600
        // ~sixteen 1600px renders' worth of pixels + plenty of grid thumbs.
        cache.totalCostLimit = 64_000_000
    }

    static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "webp", "tif", "tiff", "heic", "heif", "gif", "bmp",
    ]

    /// Camera RAW. macOS ships the codecs — these decode through the same
    /// CGImageSource path as every other still, just slower, so thumbnails
    /// and viewer renders stay async with visible loading states.
    static let rawExtensions: Set<String> = [
        "cr2", "cr3", "crw",           // Canon
        "nef", "nrw",                  // Nikon
        "arw", "srf", "sr2",           // Sony
        "raf",                         // Fujifilm
        "orf",                         // OM / Olympus
        "rw2",                         // Panasonic
        "pef",                         // Pentax
        "srw",                         // Samsung
        "erf",                         // Epson
        "dng",                         // Adobe / universal
        "3fr", "fff",                  // Hasselblad
        "iiq",                         // Phase One
        "mos",                         // Leaf
        "mrw",                         // Minolta
        "dcr", "kdc",                  // Kodak
        "x3f",                         // Sigma
    ]

    static func isRawFile(_ url: URL) -> Bool {
        rawExtensions.contains(url.pathExtension.lowercased())
    }

    static func isImageFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return imageExtensions.contains(ext) || rawExtensions.contains(ext)
    }

    static func isGIF(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "gif"
    }

    /// True only for a GIF that actually moves. A single-frame GIF is just a
    /// still, so the viewer keeps treating it as one (no animated view, edits
    /// apply). Reads the container's frame count — cheap, no decode.
    func isAnimatedGIF(_ url: URL) -> Bool {
        guard Self.isGIF(url),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        return CGImageSourceGetCount(source) > 1
    }

    static let videoExtensions: Set<String> = ["mov", "mp4", "m4v", "avi", "mpg", "mpeg"]

    static func isVideoFile(_ url: URL) -> Bool {
        videoExtensions.contains(url.pathExtension.lowercased())
    }

    /// Audio ALTer can read — but as timeline tracks, not library items
    /// (a soundtrack has no thumbnail, ALT text, or rating to browse by).
    /// Matches what the Add Audio Track picker accepts.
    static let audioExtensions: Set<String> = [
        "mp3", "wav", "m4a", "aac", "aiff", "aif", "caf",
    ]

    static func isAudioFile(_ url: URL) -> Bool {
        audioExtensions.contains(url.pathExtension.lowercased())
    }

    /// Anything the library catalogs — stills or motion.
    static func isMediaFile(_ url: URL) -> Bool {
        isImageFile(url) || isVideoFile(url)
    }

    private func cgThumbnail(url: URL, maxPixel: Int, applyOrientation: Bool = true) -> CGImage? {
        if Self.isVideoFile(url) {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
            return try? generator.copyCGImage(
                at: CMTime(seconds: 0.1, preferredTimescale: 600), actualTime: nil)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: applyOrientation,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// The full-size master, upright per the recipe: EXIF orientation
    /// applied unless the recipe draws raw pixels (Aperture imports).
    /// CGImageSourceCreateImageAtIndex never applies orientation at all, so
    /// renders built on it showed ordinary vertical photos sideways.
    static func decodeFull(_ url: URL, edits: PhotoEdits) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        if !edits.appliesFileOrientation {
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let w = (props?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let h = (props?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(w, h, 1),
        ] as CFDictionary)
    }

    /// Rendered image (cached). The key includes the pixel size — the grid's
    /// 320px render and the viewer's 1600px render must never collide, or the
    /// viewer serves an upscaled (blurry) grid thumbnail.
    /// Drop every cached render — a file changed on disk (external edit).
    func invalidateAll() {
        cache.removeAllObjects()
    }

    func thumbnail(for url: URL, edits: PhotoEdits = PhotoEdits(), maxPixel: Int = 320) -> NSImage? {
        let key = NSURL(fileURLWithPath: url.path + "#\(maxPixel)#" + edits.cacheKey)
        if let cached = cache.object(forKey: key) { return cached }
        guard var cg = cgThumbnail(url: url, maxPixel: maxPixel,
                                   applyOrientation: edits.appliesFileOrientation) else { return nil }
        cg = EditRenderer.apply(edits, to: cg)
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        cache.setObject(image, forKey: key, cost: cg.width * cg.height)
        return image
    }

    /// Downscaled JPEG as raw base64 for the ALTtext engine.
    /// Frames sampled evenly across a video, as upload-sized JPEG base64 —
    /// the contact sheet the engine describes as one clip.
    func videoFramesBase64(for url: URL, count explicitCount: Int? = nil,
                           maxPixel: CGFloat = 768,
                           quality: Double = 0.8) async -> [String] {
        let asset = AVURLAsset(url: url)
        guard let total = try? await asset.load(.duration) else { return [] }
        let seconds = CMTimeGetSeconds(total)
        guard seconds > 0 else { return [] }
        // Longer clips get more frames so the sheet doesn't go sparse.
        let count = explicitCount ?? (seconds > 15 ? 8 : 6)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        var frames: [String] = []
        for index in 0..<count {
            let t = (Double(index) + 0.5) / Double(count) * seconds
            guard let cg = try? await generator.image(
                at: CMTime(seconds: t, preferredTimescale: 600)).image else { continue }
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil
            ) else { continue }
            CGImageDestinationAddImage(destination, cg, [
                kCGImageDestinationLossyCompressionQuality: quality,
            ] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { continue }
            frames.append((data as Data).base64EncodedString())
        }
        return frames
    }

    func jpegBase64(for url: URL, maxPixel: Int = 1024, quality: Double = 0.85) throws -> String {
        guard let cg = cgThumbnail(url: url, maxPixel: maxPixel) else { throw ImageLoaderError.unreadable }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil
        ) else { throw ImageLoaderError.unreadable }
        CGImageDestinationAddImage(destination, cg, [
            kCGImageDestinationLossyCompressionQuality: quality,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ImageLoaderError.unreadable }
        return (data as Data).base64EncodedString()
    }
}
