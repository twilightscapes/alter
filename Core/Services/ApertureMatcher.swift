//
//  ApertureMatcher.swift
//  Alter
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
//  Closes the gap between Alter's render of a translated recipe and the
//  JPEG Aperture itself rendered for that version. Two RAW engines and two
//  sets of filter maths never agree exactly, and slider translation alone
//  left edited photos far from Aperture (measured: ΔE 11 against 3.9 for
//  unedited ones). So, for versions whose tone or colour was edited, a
//  per-channel tone curve is fitted that maps Alter's finished render onto
//  Aperture's preview by matching their R, G and B distributions, and
//  stored as the recipe's Aperture match (applied last; switchable off).
//  Measured on a 379-photo library: ΔE 11.2 → 5.1 (with the strength fixes in EditRenderer).
//
//  It replaces an exposure + white-balance nudge that compensated for the
//  translation's errors with colour casts (tint hit its +60 cap on 28
//  photos and reddened the library on average).
//

import CoreImage
import Foundation
import ImageIO

enum ApertureMatcher {
    private static let context = CIContext()

    /// True when the recipe touches tone or colour (not just geometry/retouch).
    static func touchesToneOrColor(_ e: PhotoEdits) -> Bool {
        e.exposure != 0 || e.contrast != 1 || e.saturation != 1 || e.vibrance != 0
            || e.temperature != 0 || e.tint != 0 || e.highlights != nil || e.shadows != nil
            || e.hasParityBricks || !e.brushLayers.isEmpty
    }

    /// Where the fitted curve samples the two distributions.
    private static let quantiles = [0.0, 0.02, 0.1, 0.25, 0.5, 0.75, 0.9, 0.98, 1.0]

    /// The recipe with its Aperture match fitted, or nil when either image
    /// couldn't be read.
    static func match(_ edits: PhotoEdits, masterURL: URL, previewURL: URL) -> PhotoEdits? {
        guard let master = decode(masterURL, maxPixel: 480),
              let preview = decode(previewURL, maxPixel: 480) else { return nil }
        var base = edits
        base.apertureMatch = nil
        let rendered = EditRenderer.apply(base, to: master)
        // Same small grid for both; quantiles don't need more.
        let w = 160, h = max(1, Int((160 * Double(preview.height) / Double(preview.width)).rounded()))
        guard let ours = channels(rendered, w: w, h: h), let theirs = channels(preview, w: w, h: h) else { return nil }
        var curve = ToneCurves()
        for c in 0..<3 {
            let pts = quantileCurve(ours[c].sorted(), theirs[c].sorted())
            switch c {
            case 0: curve.red = pts
            case 1: curve.green = pts
            default: curve.blue = pts
            }
        }
        var out = edits
        out.apertureMatch = curve.isIdentity ? nil : curve
        return out
    }

    /// Points (our value at quantile q → theirs at q), monotone, with the
    /// ends pinned to x = 0 and x = 1 so a lifted or lowered black/white end
    /// carries over.
    private static func quantileCurve(_ ours: [Double], _ theirs: [Double]) -> [CurvePoint] {
        var pts: [CurvePoint] = []
        let n = ours.count
        for q in quantiles {
            let i = min(n - 1, Int((q * Double(n - 1)).rounded()))
            let x = q == 0 ? 0 : (q == 1 ? 1 : ours[i])
            let y = max(pts.last?.y ?? 0, theirs[i])
            if let last = pts.last, x <= last.x + 0.01 { continue }
            pts.append(CurvePoint(x: x, y: min(1, max(0, y))))
        }
        return pts
    }

    /// sRGB-encoded R, G, B samples on a w×h grid.
    private static func channels(_ cg: CGImage, w: Int, h: Int) -> [[Double]]? {
        let ci = CIImage(cgImage: cg)
        guard ci.extent.width > 0, ci.extent.height > 0 else { return nil }
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: CGFloat(w) / ci.extent.width,
                                                          y: CGFloat(h) / ci.extent.height))
        let px: [Float] = EditRenderer.withRenderStack {
            var out = [Float](repeating: 0, count: w * h * 4)
            context.render(scaled, toBitmap: &out, rowBytes: w * 16,
                           bounds: CGRect(x: 0, y: 0, width: w, height: h),
                           format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            return out
        }
        return (0..<3).map { c in (0..<(w * h)).map { Double(min(1, max(0, px[$0 * 4 + c]))) } }
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
