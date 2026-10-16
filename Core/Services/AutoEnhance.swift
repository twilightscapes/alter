//
//  AutoEnhance.swift
//  Alter
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
//  On-device "Auto" adjustment: analyze the image's histogram and derive
//  slider values for the existing PhotoEdits recipe. Deliberately NOT a black
//  box — Auto just moves the same sliders the user can then refine.
//

import CoreGraphics
import Foundation
import ImageIO

enum AutoEnhance {

    /// Compute a starting-point recipe for a photo. Returns nil if the image
    /// can't be read.
    static func edits(for url: URL) -> PhotoEdits? {
        guard let sample = samplePixels(url: url) else { return nil }

        var edits = PhotoEdits()

        // Exposure: push mean luminance toward mid-gray.
        let targetLuminance = 0.42
        if sample.meanLuminance > 0.01 {
            var exposure = log2(targetLuminance / sample.meanLuminance)
            exposure = min(1.25, max(-1.25, exposure))
            if abs(exposure) >= 0.1 {
                edits.exposure = round(exposure * 100) / 100
            }
        }

        // Contrast: widen a flat histogram (small p5–p95 spread).
        let spread = sample.p95 - sample.p5
        if spread > 0.05 && spread < 0.65 {
            edits.contrast = min(1.3, 1 + (0.65 - spread) * 0.6)
            edits.contrast = round(edits.contrast * 100) / 100
        }

        // Vibrance: lift muted color — but leave true monochrome images alone
        // (a B&W photo isn't "undersaturated", it's intentional).
        if sample.meanSaturation > 0.03 && sample.meanSaturation < 0.22 {
            edits.vibrance = min(0.35, (0.22 - sample.meanSaturation) * 2)
            edits.vibrance = round(edits.vibrance * 100) / 100
        }

        return edits
    }

    // MARK: - Pixel sampling

    private struct Sample {
        let meanLuminance: Double
        let p5: Double
        let p95: Double
        let meanSaturation: Double
    }

    private static func samplePixels(url: URL) -> Sample? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 64,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        let width = cg.width
        let height = cg.height
        guard width > 0, height > 0 else { return nil }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))

        var luminances: [Double] = []
        luminances.reserveCapacity(width * height)
        var saturationTotal = 0.0

        for index in stride(from: 0, to: pixels.count, by: 4) {
            let red = Double(pixels[index]) / 255
            let green = Double(pixels[index + 1]) / 255
            let blue = Double(pixels[index + 2]) / 255
            luminances.append(0.2126 * red + 0.7152 * green + 0.0722 * blue)
            let maxChannel = max(red, green, blue)
            let minChannel = min(red, green, blue)
            saturationTotal += maxChannel > 0 ? (maxChannel - minChannel) / maxChannel : 0
        }
        guard !luminances.isEmpty else { return nil }

        let sorted = luminances.sorted()
        let count = sorted.count
        return Sample(
            meanLuminance: luminances.reduce(0, +) / Double(count),
            p5: sorted[max(0, Int(Double(count) * 0.05) - 1)],
            p95: sorted[min(count - 1, Int(Double(count) * 0.95))],
            meanSaturation: saturationTotal / Double(count))
    }
}
