//
//  EditRenderer.swift
//  Alter
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
//  Applies a PhotoEdits recipe to pixels via Core Image. Used for grid/preview
//  thumbnails and baked into exports/galleries. Designed to be extracted into
//  a shared package with the Twilightscapes apps later.
//

import CoreImage
import Foundation

enum EditRenderer {
    private static let context = CIContext()

    static func apply(_ recipe: PhotoEdits, to cgImage: CGImage) -> CGImage {
        let edits = recipe.effective
        guard !edits.isNeutral else { return cgImage }
        var image = CIImage(cgImage: cgImage)
        let sourceExtent = image.extent

        // Geometry first: rotate → straighten → crop. Everything after —
        // retouch spots, the histogram, the viewer's tap coordinates — then
        // lives in the same space the user is actually looking at.
        image = applyGeometry(edits, to: image)
        image = applyRetouches(edits.retouchSpots, to: image)
        image = applyRedEye(edits.redEyeSpots, to: image)
        image = applyTonal(edits, to: image)
        image = applyBrushes(edits.brushLayers, to: image, sourceExtent: sourceExtent, geometry: edits)

        guard let output = withRenderStack({ context.createCGImage(image, from: image.extent) }) else {
            return cgImage
        }
        return output
    }

    /// Core Image builds its program graph recursively, one frame set per
    /// node — a long recipe (eighteen retouch spots, brushes, every brick)
    /// runs that recursion past the 512 KB stack Swift's cooperative
    /// threads get, and the app dies with a bus error in CoreImage. Any
    /// render that would start on a small stack hops to a thread with room.
    static func withRenderStack<T>(_ body: @escaping () -> T) -> T {
        let have = pthread_get_stacksize_np(pthread_self())
        if have >= 4 << 20 { return body() }
        var result: T?
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            result = body()
            done.signal()
        }
        thread.stackSize = 16 << 20
        thread.start()
        done.wait()
        return result!
    }

    /// Quarter-turn rotation, cover-scaled straighten, and crop. Extent comes
    /// back translated to a zero origin so downstream normalized math is
    /// simple. Straighten keeps the extent size constant (it scales the
    /// rotated image up to cover), so crop coordinates stay stable while the
    /// angle changes.
    static func applyGeometry(_ edits: PhotoEdits, to input: CIImage) -> CIImage {
        guard edits.hasGeometry else { return input }
        var image = input

        switch edits.rotationQuarters {
        case 1: image = image.oriented(.right)  // 90° clockwise
        case 2: image = image.oriented(.down)
        case 3: image = image.oriented(.left)
        default: break
        }
        image = image.transformed(by: CGAffineTransform(
            translationX: -image.extent.minX, y: -image.extent.minY))

        if edits.flipHorizontal == true || edits.flipVertical == true {
            let w = image.extent.width, h = image.extent.height
            var t = CGAffineTransform.identity
            if edits.flipHorizontal == true { t = t.translatedBy(x: w, y: 0).scaledBy(x: -1, y: 1) }
            if edits.flipVertical == true { t = t.translatedBy(x: 0, y: h).scaledBy(x: 1, y: -1) }
            image = image.transformed(by: t)
            image = image.transformed(by: CGAffineTransform(
                translationX: -image.extent.minX, y: -image.extent.minY))
        }

        let degrees = edits.straightenDegrees
        if degrees != 0 {
            let radians = degrees * .pi / 180
            let extent = image.extent
            let w = extent.width, h = extent.height
            let cosA = abs(cos(radians)), sinA = abs(sin(radians))
            // Scale so the rotated frame still covers the original extent —
            // straightening never exposes blank corners.
            let scale = max((w * cosA + h * sinA) / w,
                            (w * sinA + h * cosA) / h)
            var transform = CGAffineTransform.identity
                .translatedBy(x: w / 2, y: h / 2)
                .scaledBy(x: scale, y: scale)
                // Positive slider = clockwise on screen; CI angles run CCW.
                .rotated(by: -radians)
                .translatedBy(x: -w / 2, y: -h / 2)
            image = image.transformed(by: transform).cropped(to: extent)
        }

        if let crop = edits.crop, crop != .full {
            let c = crop.clamped()
            let extent = image.extent
            // Normalized coords are top-left based; CI's origin is bottom-left.
            let rect = CGRect(x: extent.minX + c.x * extent.width,
                              y: extent.minY + (1 - c.y - c.h) * extent.height,
                              width: c.w * extent.width,
                              height: c.h * extent.height)
            image = image.cropped(to: rect)
            image = image.transformed(by: CGAffineTransform(
                translationX: -image.extent.minX, y: -image.extent.minY))
        }
        return image
    }

    /// The tonal chain only, CIImage → CIImage: the video compositor's
    /// grading path (retouch spots are photo-space and don't apply to
    /// moving footage).
    static func applyTonal(_ recipe: PhotoEdits, to input: CIImage) -> CIImage {
        let edits = recipe.effective
        var image = input
        if edits.exposure != 0 {
            image = image.applyingFilter("CIExposureAdjust", parameters: [
                kCIInputEVKey: edits.exposure,
            ])
        }
        if edits.saturation != 1 {
            image = image.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: edits.saturation,
            ])
        }
        // Contrast is NOT CIColorControls: that pivots in linear light,
        // where sRGB 0.25 already sits at 0.05, so 1.2 crushed everything
        // below the quarter-tone to black (measured). It's a gamma-space
        // pivot around middle grey instead, in the lookup table below.
        if edits.vibrance != 0 {
            image = image.applyingFilter("CIVibrance", parameters: [
                "inputAmount": edits.vibrance,
            ])
        }
        if edits.temperature != 0 || edits.tint != 0 {
            // Positive slider = warmer. White-balance semantics: claiming the
            // scene's neutral is a HIGHER kelvin (bluer light) makes the
            // correction remove blue — warming the image. The old minus sign
            // had it backwards (measured: +80 warmth turned frames blue).
            // Same reasoning on the tint axis: positive slider = magenta,
            // so claim the scene leans green (positive y) — also measured.
            let neutralKelvin = 6500 + edits.temperature * 25
            image = image.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: neutralKelvin, y: edits.tint),
                "inputTargetNeutral": CIVector(x: 6500, y: 0),
            ])
        }
        // Exposure's Recovery and Highlights & Shadows' Highlights both pull
        // highlights down; they share the filter.
        let highlightPull = min(1, edits.highlightsValue + (edits.recovery ?? 0) / 1.5)
        if highlightPull != 0 || edits.shadowsValue != 0 {
            var params: [String: Any] = [:]
            // Filter neutral is highlight=1 / shadow=0; sliders map onto
            // the useful travel of each.
            if highlightPull != 0 {
                // Full slider travel to the filter's floor (0.3).
                params["inputHighlightAmount"] = max(0.3, 1 - highlightPull)
            }
            if edits.shadowsValue != 0 {
                params["inputShadowAmount"] = edits.shadowsValue
            }
            params["inputRadius"] = 0
            image = image.applyingFilter("CIHighlightShadowAdjust", parameters: params)
        }
        if edits.sharpness > 0 {
            image = image.applyingFilter("CISharpenLuminance", parameters: [
                kCIInputSharpnessKey: edits.sharpness,
            ])
        }
        // Curves, levels, colour bands, vignettes… (EditRendererParity).
        image = applyParity(edits, to: image)
        return image
    }

    // MARK: - White balance solve

    /// The temperature/tint that neutralize a sampled color — the
    /// eyedropper's math. Solves against the real filter (not an
    /// approximation), alternating axes: temperature levels red vs blue,
    /// tint levels green against their mean.
    static func neutralizeWhiteBalance(r: Double, g: Double, b: Double)
        -> (temperature: Double, tint: Double) {
        func rendered(temp: Double, tint: Double) -> (r: Double, g: Double, b: Double) {
            var edits = PhotoEdits()
            edits.temperature = temp
            edits.tint = tint
            let input = CIImage(color: CIColor(red: r, green: g, blue: b))
                .cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
            let out = applyTonal(edits, to: input)
            var px = [Float](repeating: 0, count: 4)
            context.render(out, toBitmap: &px, rowBytes: 16,
                           bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                           format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            return (Double(px[0]), Double(px[1]), Double(px[2]))
        }
        func bisect(_ f: (Double) -> Double) -> Double {
            var lo = -100.0, hi = 100.0
            var flo = f(lo)
            let fhi = f(hi)
            if flo * fhi > 0 { return abs(flo) < abs(fhi) ? -100 : 100 }
            for _ in 0..<16 {
                let mid = (lo + hi) / 2
                let fm = f(mid)
                if flo * fm <= 0 { hi = mid } else { lo = mid; flo = fm }
            }
            return (lo + hi) / 2
        }
        var temp = 0.0, tint = 0.0
        for _ in 0..<2 {
            temp = bisect { candidate in
                let c = rendered(temp: candidate, tint: tint)
                return c.r - c.b
            }
            tint = bisect { candidate in
                let c = rendered(temp: temp, tint: candidate)
                return c.g - (c.r + c.b) / 2
            }
        }
        return (temp, tint)
    }

    // MARK: - Brushed adjustments

    /// Each brush layer: rasterize its strokes into a soft mask, run its
    /// own tonal recipe over the image, and blend the result back through
    /// the mask — the adjustment exists only where it was painted.
    /// A layer carries either strokes or a raster mask file (how an
    /// Aperture brush arrives); the raster path needs the pre-geometry
    /// extent and the geometry to land where the painter put it.
    static func applyBrushes(_ layers: [BrushLayer], to input: CIImage,
                             sourceExtent: CGRect? = nil, geometry: PhotoEdits? = nil) -> CIImage {
        var image = input
        for layer in layers where !layer.edits.isNeutral {
            var mask: CIImage
            if let path = layer.maskPath {
                guard let raster = rasterMask(path: path, sourceExtent: sourceExtent ?? input.extent,
                                              geometry: geometry ?? PhotoEdits())
                else { continue }
                mask = raster.cropped(to: image.extent)
            } else if !layer.strokes.isEmpty {
                mask = brushMask(layer.strokes, extent: image.extent)
            } else if layer.inverted == true {
                // Brushed away with nothing painted yet: applies everywhere.
                mask = CIImage(color: .white).cropped(to: image.extent)
            } else {
                continue
            }
            if layer.inverted == true, !(layer.strokes.isEmpty && layer.maskPath == nil) {
                mask = mask.applyingFilter("CIColorInvert").cropped(to: image.extent)
            }
            let adjusted = applyTonal(layer.edits, to: image).cropped(to: image.extent)
            image = adjusted.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: image,
                kCIInputMaskImageKey: mask,
            ]).cropped(to: input.extent)
        }
        return image
    }

    /// Strokes → grayscale mask, in stroke order so an erase carves out
    /// whatever was painted before it. White applies, black protects;
    /// softness feathers the disc's edge.
    static func brushMask(_ strokes: [BrushStroke], extent: CGRect) -> CIImage {
        var mask = CIImage(color: .black).cropped(to: extent)
        for stroke in strokes {
            let radius = max(stroke.radius, 0.001) * extent.width
            // Normalized top-left origin → CI bottom-left.
            let center = CIVector(x: extent.minX + stroke.x * extent.width,
                                  y: extent.minY + (1 - stroke.y) * extent.height)
            let hard = radius * (1 - min(max(stroke.softness, 0), 1))
            let strength = min(max(stroke.strength ?? 1, 0.05), 1)
            let ink: CIColor = (stroke.erase ?? false)
                ? CIColor(red: 0, green: 0, blue: 0, alpha: strength)
                : CIColor(red: 1, green: 1, blue: 1, alpha: strength)
            let clear = CIColor(red: ink.red, green: ink.green, blue: ink.blue, alpha: 0)
            // CIRadialGradient is a generator — build it directly.
            guard let gradient = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": center,
                "inputRadius0": max(hard, 0.5),
                "inputRadius1": radius,
                "inputColor0": ink,
                "inputColor1": clear,
            ])?.outputImage else { continue }
            mask = gradient.cropped(to: extent).composited(over: mask)
        }
        return mask
    }

    /// Cover each spot with a soft-edged patch cloned from its source offset.
    private static func applyRetouches(_ spots: [RetouchSpot], to input: CIImage) -> CIImage {
        guard !spots.isEmpty else { return input }
        var image = input
        let width = input.extent.width
        let height = input.extent.height

        for spot in spots {
            // CI origin is bottom-left; normalized coords are top-left based.
            let center = CIVector(x: input.extent.minX + spot.x * width,
                                  y: input.extent.minY + (1 - spot.y) * height)
            let radius = max(2, spot.radius * width)

            // The patch: the whole image shifted so the source region lands
            // on the target, then masked to a soft-edged circle.
            let patch = image.transformed(by: CGAffineTransform(
                translationX: -spot.dx * width, y: spot.dy * height))

            let softness = min(max(spot.softness ?? 0.45, 0), 1)
            let opacity = min(max(spot.opacity ?? 1, 0), 1)
            guard let gradient = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": center,
                "inputRadius0": max(0.5, radius * (1 - softness)),
                "inputRadius1": radius,
                "inputColor0": CIColor(red: 1, green: 1, blue: 1, alpha: opacity),
                "inputColor1": CIColor.clear,
            ])?.outputImage?.cropped(to: image.extent) else { continue }

            image = patch.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: image,
                kCIInputMaskImageKey: gradient,
            ]).cropped(to: input.extent)
        }
        return image
    }

    // MARK: - Red Eye

    /// A colour cube that takes the red out of red-dominant pixels (the
    /// pupil keeps its luminance from green and blue), applied through a
    /// soft circle per spot.
    private static let redEyeCube: Data = {
        let n = 16
        var data = [Float](repeating: 0, count: n * n * n * 4)
        var i = 0
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    let rf = Float(r) / Float(n - 1), gf = Float(g) / Float(n - 1), bf = Float(b) / Float(n - 1)
                    let other = (gf + bf) / 2
                    if rf > other * 1.5 + 0.08 {
                        data[i] = other * 0.9; data[i + 1] = gf * 0.9; data[i + 2] = bf * 0.9
                    } else {
                        data[i] = rf; data[i + 1] = gf; data[i + 2] = bf
                    }
                    data[i + 3] = 1
                    i += 4
                }
            }
        }
        return data.withUnsafeBufferPointer { Data(buffer: $0) }
    }()

    private static func applyRedEye(_ spots: [RedEyeSpot], to input: CIImage) -> CIImage {
        guard !spots.isEmpty else { return input }
        let corrected = input.applyingFilter("CIColorCubeWithColorSpace", parameters: [
            "inputCubeDimension": 16,
            "inputCubeData": redEyeCube,
            "inputColorSpace": CGColorSpace(name: CGColorSpace.sRGB)!,
        ])
        var mask = CIImage(color: .black).cropped(to: input.extent)
        for spot in spots {
            let center = CIVector(x: input.extent.minX + spot.x * input.extent.width,
                                  y: input.extent.minY + (1 - spot.y) * input.extent.height)
            let radius = max(2, spot.radius * input.extent.width)
            guard let gradient = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": center,
                "inputRadius0": radius * 0.7,
                "inputRadius1": radius,
                "inputColor0": CIColor.white,
                "inputColor1": CIColor.clear,
            ])?.outputImage?.cropped(to: input.extent) else { continue }
            mask = gradient.composited(over: mask)
        }
        return corrected.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: input,
            kCIInputMaskImageKey: mask,
        ]).cropped(to: input.extent)
    }
}
