//
//  Histogram.swift
//  Alter
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
//  Per-channel histogram of a rendered image — the data behind the
//  Lightroom-style RGB display at the top of the Adjustments panel.
//  Belongs to the extractable edit-engine core (with PhotoEdits,
//  EditRenderer, AutoEnhance) shared with Twilightscapes.
//

import CoreGraphics
import Foundation

struct HistogramData: Equatable {
    static let bins = 64

    var red: [Double]
    var green: [Double]
    var blue: [Double]
    var luminance: [Double]

    static let empty = HistogramData(
        red: Array(repeating: 0, count: bins),
        green: Array(repeating: 0, count: bins),
        blue: Array(repeating: 0, count: bins),
        luminance: Array(repeating: 0, count: bins))

    /// Count pixels into per-channel bins, normalized 0…1 with a square root
    /// so a single spike doesn't flatten everything else out of view.
    static func compute(from image: CGImage) -> HistogramData {
        let maxSide = 200
        let scale = min(1, Double(maxSide) / Double(max(image.width, image.height)))
        let width = max(1, Int(Double(image.width) * scale))
        let height = max(1, Int(Double(image.height) * scale))

        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return .empty }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return .empty }

        var r = [Int](repeating: 0, count: bins)
        var g = [Int](repeating: 0, count: bins)
        var b = [Int](repeating: 0, count: bins)
        var l = [Int](repeating: 0, count: bins)

        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        let divisor = 256 / bins
        for index in stride(from: 0, to: width * height * 4, by: 4) {
            let red = Int(pixels[index])
            let green = Int(pixels[index + 1])
            let blue = Int(pixels[index + 2])
            r[red / divisor] += 1
            g[green / divisor] += 1
            b[blue / divisor] += 1
            let luma = (red * 299 + green * 587 + blue * 114) / 1000
            l[min(bins - 1, luma / divisor)] += 1
        }

        func normalize(_ counts: [Int]) -> [Double] {
            let peak = Double(counts.max() ?? 1)
            guard peak > 0 else { return Array(repeating: 0, count: bins) }
            return counts.map { (Double($0) / peak).squareRoot() }
        }

        return HistogramData(
            red: normalize(r), green: normalize(g), blue: normalize(b), luminance: normalize(l))
    }
}
