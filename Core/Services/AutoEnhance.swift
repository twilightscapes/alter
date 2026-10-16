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
//  box — Auto just moves the same sliders the user can then refine, and only
//  the ones it analysed.
//

import CoreGraphics
import Foundation
import ImageIO

enum AutoEnhance {

    /// The sliders Auto can move. Auto writes only these; every other
    /// field of the recipe (crop, retouch, brushes, other bricks) is left
    /// exactly as it was.
    struct Fields: OptionSet {
        let rawValue: Int
        static let exposure = Fields(rawValue: 1 << 0)
        static let contrast = Fields(rawValue: 1 << 1)
        static let vibrance = Fields(rawValue: 1 << 2)
        static let highlights = Fields(rawValue: 1 << 3)
        static let shadows = Fields(rawValue: 1 << 4)

        /// What Auto-Enhance sets: a baseline exposure, contrast and vibrance.
        static let autoEnhance: Fields = [.exposure, .contrast, .vibrance]

        /// What one brick's Auto button sets, or nil if the brick has no
        /// analysis of its own here (Levels and Curves auto from the
        /// panel's histogram instead).
        init?(brick: AdjustmentBrick) {
            switch brick {
            case .exposure: self = .exposure
            case .enhance: self = [.contrast, .vibrance]
            case .highlightsShadows: self = [.highlights, .shadows]
            default: return nil
            }
        }

        init(rawValue: Int) { self.rawValue = rawValue }
    }

    /// The analysed slider values, neutral where the image needs nothing.
    struct Values {
        var exposure = 0.0
        var contrast = 1.0
        var vibrance = 0.0
        var highlights = 0.0
        var shadows = 0.0
    }

    /// Analyse a photo. Returns nil if the image can't be read.
    static func values(for url: URL) -> Values? {
        guard let sample = samplePixels(url: url) else { return nil }

        var values = Values()

        // Exposure: push mean luminance toward mid-gray.
        let targetLuminance = 0.42
        if sample.meanLuminance > 0.01 {
            var exposure = log2(targetLuminance / sample.meanLuminance)
            exposure = min(1.25, max(-1.25, exposure))
            if abs(exposure) >= 0.1 {
                values.exposure = round(exposure * 100) / 100
            }
        }

        // Contrast: widen a flat histogram (small p5–p95 spread).
        let spread = sample.p95 - sample.p5
        if spread > 0.05 && spread < 0.65 {
            values.contrast = min(1.3, 1 + (0.65 - spread) * 0.6)
            values.contrast = round(values.contrast * 100) / 100
        }

        // Vibrance: lift muted color — but leave true monochrome images alone
        // (a B&W photo isn't "undersaturated", it's intentional).
        if sample.meanSaturation > 0.03 && sample.meanSaturation < 0.22 {
            values.vibrance = min(0.35, (0.22 - sample.meanSaturation) * 2)
            values.vibrance = round(values.vibrance * 100) / 100
        }

        // Highlights & Shadows: from the histogram's clipped ends. A real
        // share of pixels piled up near white pulls highlights down; a
        // real share crushed near black lifts shadows. A few specular
        // glints or a black border don't count.
        if sample.nearWhite > 0.02 {
            let pull = min(0.6, (sample.nearWhite - 0.02) * 3 + 0.1)
            values.highlights = round(pull * 100) / 100
        }
        if sample.nearBlack > 0.04 {
            let lift = min(0.5, (sample.nearBlack - 0.04) * 2.5 + 0.1)
            values.shadows = round(lift * 100) / 100
        }

        return values
    }

    // MARK: - Pixel sampling

    private struct Sample {
        let meanLuminance: Double
        let p5: Double
        let p95: Double
        let meanSaturation: Double
        /// Share of pixels at or near clipping on each end.
        let nearBlack: Double
        let nearWhite: Double
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
            meanSaturation: saturationTotal / Double(count),
            nearBlack: Double(sorted.prefix { $0 < 0.04 }.count) / Double(count),
            nearWhite: Double(sorted.reversed().prefix { $0 > 0.96 }.count) / Double(count))
    }
}

extension PhotoEdits {
    /// The current values of the sliders Auto can move.
    var autoValues: AutoEnhance.Values {
        AutoEnhance.Values(exposure: exposure, contrast: contrast, vibrance: vibrance,
                           highlights: highlightsValue, shadows: shadowsValue)
    }

    /// Set just these sliders; nothing else in the recipe changes.
    mutating func apply(_ values: AutoEnhance.Values, fields: AutoEnhance.Fields) {
        if fields.contains(.exposure) { exposure = values.exposure }
        if fields.contains(.contrast) { contrast = values.contrast }
        if fields.contains(.vibrance) { vibrance = values.vibrance }
        if fields.contains(.highlights) { highlightsValue = values.highlights }
        if fields.contains(.shadows) { shadowsValue = values.shadows }
    }
}
