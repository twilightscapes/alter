//
//  ClippingOverlay.swift
//  Alter
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
//  Aperture's Highlight Hot & Cold Areas (⌥⇧H): blown highlights painted
//  red, crushed shadows blue, everything else left alone. A colour cube
//  with alpha does it in one pass on the rendered image.
//

import CoreImage
import Foundation

enum ClippingOverlay {
    private static let context = CIContext()
    private static let dimension = 16

    /// Premultiplied RGBA: transparent except at the ends of the range.
    private static let cube: Data = {
        let n = dimension
        var data = [Float](repeating: 0, count: n * n * n * 4)
        var i = 0
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    let hi = max(r, g, b)
                    let lo = min(r, g, b)
                    if hi >= n - 1 {
                        data[i] = 1; data[i + 1] = 0.1; data[i + 2] = 0.1; data[i + 3] = 1
                    } else if lo <= 0 && hi <= 1 {
                        data[i] = 0.1; data[i + 1] = 0.45; data[i + 2] = 1; data[i + 3] = 1
                    }
                    i += 4
                }
            }
        }
        return data.withUnsafeBufferPointer { Data(buffer: $0) }
    }()

    static func make(from image: CGImage) -> CGImage? {
        let input = CIImage(cgImage: image)
        let output = input.applyingFilter("CIColorCubeWithColorSpace", parameters: [
            "inputCubeDimension": dimension,
            "inputCubeData": cube,
            "inputColorSpace": CGColorSpace(name: CGColorSpace.sRGB)!,
        ])
        return EditRenderer.withRenderStack { context.createCGImage(output, from: output.extent) }
    }
}


/// The brush mask as something to look at while painting — Aperture's
/// overlay choices.
enum BrushOverlayRenderer {
    private static let context = CIContext()

    static func render(strokes: [BrushStroke], size: CGSize, mode: ViewerView.BrushOverlay) -> CGImage? {
        guard size.width > 0, size.height > 0 else { return nil }
        let extent = CGRect(origin: .zero, size: size)
        let mask = EditRenderer.brushMask(strokes, extent: extent)
        let output: CIImage
        switch mode {
        case .none:
            return nil
        case .color, .strokes:
            let ink = mode == .color
                ? CIColor(red: 1, green: 0.2, blue: 0.2) : CIColor(red: 1, green: 1, blue: 1)
            output = CIImage(color: ink).cropped(to: extent).applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: extent),
                kCIInputMaskImageKey: mask,
            ])
        case .onBlack:
            output = mask
        case .onWhite:
            output = mask.applyingFilter("CIColorInvert").cropped(to: extent)
        }
        return EditRenderer.withRenderStack { context.createCGImage(output, from: extent) }
    }
}
