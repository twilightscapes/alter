//
//  ApertureMatcher.swift
//  Alter
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
//  Closes the gap between ALTer's render of a translated recipe and the
//  JPEG Aperture itself rendered for that version. Two decoders never agree
//  on a RAW file's base brightness and white balance, and Aperture's
//  absolute kelvin can't be turned into a shift without knowing the
//  as-shot value — so, for versions whose tone or colour was edited, the
//  recipe's exposure and white balance are nudged (within bounds) until
//  the small renders match in mean luminance and colour balance. Geometry-
//  only versions are left exactly as translated.
//

import CoreImage
import Foundation
import ImageIO

enum ApertureMatcher {
    private static let context = CIContext()

    /// Max correction we'll attribute to decoder differences.
    static let maxExposureEV = 1.5
    static let maxWhiteBalance = 60.0

    /// True when the recipe touches tone or colour (not just geometry/retouch).
    static func touchesToneOrColor(_ e: PhotoEdits) -> Bool {
        e.exposure != 0 || e.contrast != 1 || e.saturation != 1 || e.vibrance != 0
            || e.temperature != 0 || e.tint != 0 || e.highlights != nil || e.shadows != nil
            || e.hasParityBricks || !e.brushLayers.isEmpty
    }

    /// Returns the adjusted recipe, or nil when nothing could be measured.
    static func match(_ edits: PhotoEdits, masterURL: URL, previewURL: URL) -> PhotoEdits? {
        guard let master = decode(masterURL, maxPixel: 320),
              let preview = decode(previewURL, maxPixel: 320) else { return nil }
        guard let target = meanRGB(CIImage(cgImage: preview)) else { return nil }
        var out = edits

        // Exposure: match mean luminance in linear light.
        let rendered = EditRenderer.apply(out, to: master)
        guard let ours = meanRGB(CIImage(cgImage: rendered)) else { return nil }
        let lumT = luminance(target), lumO = luminance(ours)
        if lumT > 0.002, lumO > 0.002 {
            let ev = log2(lumT / lumO)
            out.exposure += min(maxExposureEV, max(-maxExposureEV, ev))
        }

        // White balance: the cast ours has relative to Aperture's, solved
        // with the same math as the eyedropper.
        let rendered2 = EditRenderer.apply(out, to: master)
        if let ours2 = meanRGB(CIImage(cgImage: rendered2)), ours2.g > 0.002, target.g > 0.002 {
            // Normalise both to green so exposure doesn't leak in.
            let r = (ours2.r / ours2.g) / (target.r / target.g)
            let b = (ours2.b / ours2.g) / (target.b / target.g)
            if abs(r - 1) > 0.01 || abs(b - 1) > 0.01 {
                let solved = EditRenderer.neutralizeWhiteBalance(r: r, g: 1, b: b)
                out.temperature = clamp(out.temperature + solved.temperature, maxWhiteBalance)
                out.tint = clamp(out.tint + solved.tint, maxWhiteBalance)
            }
        }
        return out
    }

    private static func clamp(_ v: Double, _ limit: Double) -> Double {
        min(limit, max(-limit, v))
    }

    private static func luminance(_ c: (r: Double, g: Double, b: Double)) -> Double {
        0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
    }

    static func decode(_ url: URL, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            // Aperture's rotation is its own, separate from EXIF orientation.
            kCGImageSourceCreateThumbnailWithTransform: false,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Mean linear RGB over the whole image.
    static func meanRGB(_ image: CIImage) -> (r: Double, g: Double, b: Double)? {
        guard image.extent.width > 0, image.extent.height > 0 else { return nil }
        let averaged = image.applyingFilter("CIAreaAverage", parameters: [
            kCIInputExtentKey: CIVector(cgRect: image.extent),
        ])
        let px: [Float] = EditRenderer.withRenderStack {
            var out = [Float](repeating: 0, count: 4)
            context.render(averaged, toBitmap: &out, rowBytes: 16,
                           bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                           format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.linearSRGB))
            return out
        }
        return (Double(px[0]), Double(px[1]), Double(px[2]))
    }
}
