//
//  EditRendererParity.swift
//  Alter
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
//  The Aperture-parity bricks' Core Image implementations: curves and
//  levels as a lookup table, Color as a colour cube, B&W / monochrome /
//  sepia, polarize and intensify-contrast as self-blends, vignette and
//  devignette, noise reduction, definition and edge sharpening — plus
//  raster brush masks. Kept beside EditRenderer so the main pipeline
//  stays readable.
//

import CoreImage
import Foundation

extension EditRenderer {
    /// Applies every parity brick that's set, in Aperture's order.
    static func applyParity(_ edits: PhotoEdits, to input: CIImage) -> CIImage {
        guard edits.hasParityBricks || edits.contrast != 1 else { return input }
        var image = input
        let extent = input.extent
        let longSide = max(extent.width, extent.height)

        if let ca = edits.chromaticAberration, !ca.isNeutral {
            image = correctChromaticAberration(image, redCyan: ca.redCyan, blueYellow: ca.blueYellow)
        }

        if let nr = edits.noiseReduction, nr.radius > 0 {
            image = image.applyingFilter("CINoiseReduction", parameters: [
                "inputNoiseLevel": min(0.2, 0.02 + nr.radius * 0.04),
                "inputSharpness": min(2, max(0, nr.edgeDetail * 0.4)),
            ])
        }

        // Black point, brightness, contrast, mid contrast, levels, curves —
        // composed into one table per channel.
        if let levels = edits.levels, levels.luminance == true, !levels.rgb.isIdentity {
            image = applyLuminanceLevels(levels.rgb, to: image)
        }
        if edits.levels != nil || edits.curves != nil || edits.moreCurves != nil || edits.contrast != 1
            || edits.blackPoint != nil || edits.brightness != nil || edits.midContrast != nil {
            image = applyLookup(edits, to: image)
        }

        if let definition = edits.definition, definition > 0 {
            // Local contrast: a wide, gentle unsharp mask. Aperture's
            // Definition is subtle; at 0.6× this read as gritty and pushed
            // photos away from Aperture's renders (fitted: a quarter of
            // that is as close as a wide mask gets).
            image = image.applyingFilter("CIUnsharpMask", parameters: [
                kCIInputRadiusKey: min(120, max(8, longSide * 0.02)),
                kCIInputIntensityKey: definition * 0.15,
            ]).cropped(to: extent)
        }

        if let bands = edits.colorBands, bands.contains(where: { !$0.isNeutral }) {
            image = applyColorCube(bands, to: image)
        }

        if let mix = edits.bwMix {
            let r = CGFloat(mix.red / 100), g = CGFloat(mix.green / 100), b = CGFloat(mix.blue / 100)
            let v = CIVector(x: r, y: g, z: b, w: 0)
            image = image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": v, "inputGVector": v, "inputBVector": v,
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ])
        }
        if let mono = edits.monochrome {
            image = image.applyingFilter("CIColorMonochrome", parameters: [
                kCIInputColorKey: CIColor(red: mono.red, green: mono.green, blue: mono.blue),
                kCIInputIntensityKey: min(1, max(0, mono.intensity)),
            ])
        }
        if let sepia = edits.sepia, sepia > 0 {
            image = image.applyingFilter("CISepiaTone", parameters: [
                kCIInputIntensityKey: min(1, sepia),
            ])
        }

        if let amount = edits.polarize, amount > 0 {
            let blended = image.applyingFilter("CIMultiplyBlendMode", parameters: [
                kCIInputBackgroundImageKey: image,
            ])
            // A full self-multiply darkened far past Aperture's Polarize.
            image = mix(image, blended, amount: amount * 0.35)
        }
        if let amount = edits.intensifyContrast, amount > 0 {
            let blended = image.applyingFilter("CIOverlayBlendMode", parameters: [
                kCIInputBackgroundImageKey: image,
            ])
            image = mix(image, blended, amount: amount)
        }

        if let v = edits.devignette, v.intensity > 0 {
            image = vignette(image, intensity: -v.intensity, radius: v.radius)
        }
        if let v = edits.vignette, v.intensity > 0 {
            image = vignette(image, intensity: v.intensity, radius: v.radius)
        }

        if let edge = edits.edgeSharpen, edge > 0 {
            // 0.6× (was 1.2×): matched to the fine detail in Aperture's renders.
            image = image.applyingFilter("CIUnsharpMask", parameters: [
                kCIInputRadiusKey: 1.6,
                kCIInputIntensityKey: edge * 0.6,
            ]).cropped(to: extent)
        }
        return image.cropped(to: extent)
    }

    // MARK: - Chromatic aberration

    /// Fringing is the red and blue channels landing a touch larger or
    /// smaller than green; scale them back about the centre and recombine.
    private static func correctChromaticAberration(_ image: CIImage, redCyan: Double, blueYellow: Double) -> CIImage {
        let e = image.extent
        // One colour channel, the others zero, fully opaque. (Each channel
        // used to carry alpha 0, so the recombined photo came out black.)
        func channel(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CIImage {
            image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: r, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: g, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: b, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ])
        }
        // Clamped first, so a channel scaled down still reaches the edges.
        func scaled(_ img: CIImage, _ amount: Double) -> CIImage {
            let s = 1 + CGFloat(amount) * 0.004
            let t = CGAffineTransform(translationX: e.midX, y: e.midY)
                .scaledBy(x: s, y: s)
                .translatedBy(x: -e.midX, y: -e.midY)
            return img.clampedToExtent().transformed(by: t).cropped(to: e)
        }
        let green = channel(0, 1, 0)
        let red = scaled(channel(1, 0, 0), redCyan)
        let blue = scaled(channel(0, 0, 1), blueYellow)
        // Each image holds one channel and zeros elsewhere, so a
        // per-component maximum puts the three back together exactly.
        return red.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: green])
            .applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: blue])
            .cropped(to: e)
    }

    // MARK: - Helpers

    private static func mix(_ a: CIImage, _ b: CIImage, amount: Double) -> CIImage {
        let t = min(1, max(0, amount))
        if t >= 0.999 { return b.cropped(to: a.extent) }
        return b.applyingFilter("CIMix", parameters: [
            kCIInputBackgroundImageKey: a,
            "inputAmount": t,
        ]).cropped(to: a.extent)
    }

    /// Aperture's radius slider barely moves where the falloff begins
    /// (measured against its previews: radius 0.19 still left the middle
    /// clean), so it maps onto a narrow band around the half-diagonal.
    /// Negative intensity lightens (devignette).
    private static func vignette(_ image: CIImage, intensity: Double, radius: Double) -> CIImage {
        let e = image.extent
        let halfDiagonal = hypot(e.width, e.height) / 2
        let scale = 0.85 + 0.25 * min(2, max(0, radius))
        return image.applyingFilter("CIVignetteEffect", parameters: [
            kCIInputCenterKey: CIVector(x: e.midX, y: e.midY),
            kCIInputRadiusKey: max(1, halfDiagonal * scale),
            kCIInputIntensityKey: min(1, max(-1, intensity)),
            "inputFalloff": 0.5,
        ]).cropped(to: e)
    }

    // MARK: - Lookup table (levels + curves)

    private static let lutSize = 256

    private static func applyLookup(_ edits: PhotoEdits, to image: CIImage) -> CIImage {
        let levels = edits.levels, curves = edits.curves
        var table = [Float](repeating: 0, count: lutSize * 3)
        // Contrast is a pivot about middle grey in gamma space.
        let c = min(max(edits.contrast, 0), 2)
        // Black point: Aperture's 0…50 scale, roughly 8-bit levels.
        let black = min(0.5, max(0, (edits.blackPoint ?? 0) / 255))
        // Brightness: a gamma lift/drop that leaves black and white put.
        let gamma = pow(2.0, -(edits.brightness ?? 0))
        // Mid contrast: ease toward a smoothstep S (or away from it).
        // A quarter strength: the smoothstep S was far stronger than
        // Aperture's Mid Contrast at the same number (fitted).
        let mid = min(1, max(-1, edits.midContrast ?? 0)) * 0.25
        // In Luminance mode the main levels already ran on brightness alone.
        let rgbLevels = levels?.luminance == true ? nil : levels?.rgb
        let chanLevels = [levels?.red, levels?.green, levels?.blue]
        // Every Curves adjustment, in order: its RGB curve, its channel
        // curves, and whether it works in linear light.
        let stages: [(rgb: (Double) -> Double, chan: [((Double) -> Double)?], linear: Bool)] =
            ([curves].compactMap { $0 } + (edits.moreCurves ?? [])).map { c in
                (monotoneCurve(c.rgb),
                 [c.red, c.green, c.blue].map { $0.isEmpty ? nil : monotoneCurve($0) },
                 c.isLinear)
            }
        for i in 0..<lutSize {
            let x = Double(i) / Double(lutSize - 1)
            for ch in 0..<3 {
                var v = x
                if black > 0 { v = max(0, (v - black) / (1 - black)) }
                if gamma != 1 { v = pow(v, gamma) }
                if c != 1 { v = min(1, max(0, 0.5 + (v - 0.5) * c)) }
                if mid != 0 {
                    let s = v * v * (3 - 2 * v)
                    v = min(1, max(0, v + mid * (s - v)))
                }
                if let l = rgbLevels { v = applyLevels(l, v) }
                if let l = chanLevels[ch] { v = applyLevels(l, v) }
                for stage in stages {
                    if stage.linear { v = srgbToLinear(v) }
                    v = stage.rgb(v)
                    if let f = stage.chan[ch] { v = f(v) }
                    if stage.linear { v = linearToSRGB(v) }
                    v = min(1, max(0, v))
                }
                table[i * 3 + ch] = Float(min(1, max(0, v)))
            }
        }
        let data = table.withUnsafeBufferPointer { Data(buffer: $0) }
        return image.applyingFilter("CIColorCurves", parameters: [
            "inputCurvesData": data,
            "inputCurvesDomain": CIVector(x: 0, y: 1),
            "inputColorSpace": CGColorSpace(name: CGColorSpace.sRGB)!,
        ])
    }

    /// One Curves set on its own (the Aperture match), as a lookup table.
    static func applyCurveStage(_ c: ToneCurves, to image: CIImage) -> CIImage {
        let rgb = monotoneCurve(c.rgb)
        let chan = [c.red, c.green, c.blue].map { $0.isEmpty ? nil : monotoneCurve($0) }
        var table = [Float](repeating: 0, count: lutSize * 3)
        for i in 0..<lutSize {
            let x = Double(i) / Double(lutSize - 1)
            for ch in 0..<3 {
                var v = c.isLinear ? srgbToLinear(x) : x
                v = rgb(v)
                if let f = chan[ch] { v = f(v) }
                if c.isLinear { v = linearToSRGB(v) }
                table[i * 3 + ch] = Float(min(1, max(0, v)))
            }
        }
        let data = table.withUnsafeBufferPointer { Data(buffer: $0) }
        return image.applyingFilter("CIColorCurves", parameters: [
            "inputCurvesData": data,
            "inputCurvesDomain": CIVector(x: 0, y: 1),
            "inputColorSpace": CGColorSpace(name: CGColorSpace.sRGB)!,
        ])
    }

    /// Levels on brightness only (Aperture's Luminance mode): map the
    /// photo's luminance through the levels, then scale each pixel's R, G
    /// and B by new/old luminance, so hue and saturation stay put.
    private static func applyLuminanceLevels(_ l: LevelsChannel, to image: CIImage) -> CIImage {
        let e = image.extent
        let w = CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0)
        let luma = image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": w, "inputGVector": w, "inputBVector": w,
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])
        var table = [Float](repeating: 0, count: lutSize * 3)
        for i in 0..<lutSize {
            let v = Float(min(1, max(0, applyLevels(l, Double(i) / Double(lutSize - 1)))))
            table[i * 3] = v; table[i * 3 + 1] = v; table[i * 3 + 2] = v
        }
        let data = table.withUnsafeBufferPointer { Data(buffer: $0) }
        let mapped = luma.applyingFilter("CIColorCurves", parameters: [
            "inputCurvesData": data,
            "inputCurvesDomain": CIVector(x: 0, y: 1),
            "inputColorSpace": CGColorSpace(name: CGColorSpace.sRGB)!,
        ])
        // ratio = mapped / luma. CIDivideBlendMode computes background ÷
        // source and clamps at 1 (measured), so divide a quarter of the
        // mapped luminance and multiply the result back up by 4 — ratios up
        // to 4× survive. A hair is added to luma so black stays black.
        func scale(_ img: CIImage, _ k: CGFloat) -> CIImage {
            img.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: k, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: k, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: k, w: 0),
            ])
        }
        let safeLuma = luma.applyingFilter("CIColorMatrix", parameters: [
            "inputBiasVector": CIVector(x: 1e-4, y: 1e-4, z: 1e-4, w: 0),
        ])
        let quarterRatio = safeLuma.applyingFilter("CIDivideBlendMode", parameters: [
            kCIInputBackgroundImageKey: scale(mapped, 0.25),
        ])
        let multiplied = image.applyingFilter("CIMultiplyCompositing", parameters: [
            kCIInputBackgroundImageKey: quarterRatio,
        ])
        return scale(multiplied, 4).cropped(to: e)
    }

    /// Five source points → five destinations, piecewise linear.
    private static func applyLevels(_ l: LevelsChannel, _ x: Double) -> Double {
        let src = [l.blackSrc, l.shadowSrc, l.midSrc, l.highlightSrc, l.whiteSrc]
        let dst = [l.blackDst, l.shadowDst, l.midDst, l.highlightDst, l.whiteDst]
        if x <= src[0] { return dst[0] }
        for i in 1..<5 where x <= src[i] {
            let span = src[i] - src[i - 1]
            let t = span > 0 ? (x - src[i - 1]) / span : 1
            return dst[i - 1] + (dst[i] - dst[i - 1]) * t
        }
        return dst[4]
    }

    private static func srgbToLinear(_ v: Double) -> Double {
        v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }
    private static func linearToSRGB(_ v: Double) -> Double {
        let x = max(0, v)
        return x <= 0.0031308 ? x * 12.92 : 1.055 * pow(x, 1 / 2.4) - 0.055
    }

    /// Monotone cubic (Fritsch–Carlson) through the control points — no
    /// overshoot, like Aperture. The ends are (0,0) and (1,1) unless the
    /// points carry their own: one at x = 0 is a moved black end, and a
    /// last one at x ≥ 1 a moved white end.
    static func monotoneCurve(_ points: [CurvePoint]) -> (Double) -> Double {
        let sorted = points.sorted { $0.x < $1.x }
        var pts = sorted
        if (sorted.first?.x ?? 1) > 0.0001 { pts.insert(CurvePoint(x: 0, y: 0), at: 0) }
        if (sorted.last?.x ?? 0) < 0.9999 { pts.append(CurvePoint(x: 1, y: 1)) }
        // Drop duplicates in x.
        pts = pts.enumerated().filter { i, p in i == 0 || p.x > pts[i - 1].x + 1e-6 }.map(\.element)
        let n = pts.count
        guard n >= 2 else { return { $0 } }
        var d = [Double](repeating: 0, count: n - 1)   // secant slopes
        for i in 0..<(n - 1) { d[i] = (pts[i + 1].y - pts[i].y) / (pts[i + 1].x - pts[i].x) }
        var m = [Double](repeating: 0, count: n)       // tangents
        m[0] = d[0]; m[n - 1] = d[n - 2]
        for i in 1..<(n - 1) {
            if d[i - 1] * d[i] <= 0 { m[i] = 0 } else { m[i] = (d[i - 1] + d[i]) / 2 }
        }
        for i in 0..<(n - 1) where d[i] != 0 {
            let a = m[i] / d[i], b = m[i + 1] / d[i]
            if a * a + b * b > 9 {
                let t = 3 / sqrt(a * a + b * b)
                m[i] = t * a * d[i]; m[i + 1] = t * b * d[i]
            }
        }
        return { x in
            if x <= pts[0].x { return pts[0].y }
            if x >= pts[n - 1].x { return pts[n - 1].y }
            var i = 0
            while i < n - 2 && x > pts[i + 1].x { i += 1 }
            let h = pts[i + 1].x - pts[i].x
            let t = (x - pts[i].x) / h
            let h00 = 2 * t * t * t - 3 * t * t + 1
            let h10 = t * t * t - 2 * t * t + t
            let h01 = -2 * t * t * t + 3 * t * t
            let h11 = t * t * t - t * t
            return h00 * pts[i].y + h10 * h * m[i] + h01 * pts[i + 1].y + h11 * h * m[i + 1]
        }
    }

    // MARK: - Color (per-hue bands) as a colour cube

    private static var cubeCache: [Int: Data] = [:]
    private static let cubeLock = NSLock()
    private static let cubeDimension = 32

    private static func applyColorCube(_ bands: [ColorBand], to image: CIImage) -> CIImage {
        let key = bands.hashValue
        cubeLock.lock()
        var data = cubeCache[key]
        cubeLock.unlock()
        if data == nil {
            data = buildColorCube(bands)
            cubeLock.lock()
            if cubeCache.count > 32 { cubeCache.removeAll() }
            cubeCache[key] = data
            cubeLock.unlock()
        }
        return image.applyingFilter("CIColorCubeWithColorSpace", parameters: [
            "inputCubeDimension": cubeDimension,
            "inputCubeData": data!,
            "inputColorSpace": CGColorSpace(name: CGColorSpace.sRGB)!,
        ])
    }

    private static func buildColorCube(_ bands: [ColorBand]) -> Data {
        let n = cubeDimension
        var cube = [Float](repeating: 0, count: n * n * n * 4)
        var offset = 0
        for bi in 0..<n {
            for gi in 0..<n {
                for ri in 0..<n {
                    let r = Double(ri) / Double(n - 1)
                    let g = Double(gi) / Double(n - 1)
                    let b = Double(bi) / Double(n - 1)
                    var (h, s, v) = rgbToHSV(r, g, b)
                    if s > 0.001 {
                        var dh = 0.0, ds = 0.0, dv = 0.0
                        for band in bands where !band.isNeutral {
                            // Soft membership: full within the band's core,
                            // falling to zero over its spread.
                            let width = 30.0 * max(0.2, band.spread)
                            var dist = abs(h - band.hueBase).truncatingRemainder(dividingBy: 360)
                            if dist > 180 { dist = 360 - dist }
                            let w = max(0, 1 - dist / width)
                            guard w > 0 else { continue }
                            dh += band.hueShift * w
                            ds += band.saturation / 100 * w
                            dv += band.luminance / 100 * w
                        }
                        h = (h + dh).truncatingRemainder(dividingBy: 360)
                        if h < 0 { h += 360 }
                        s = min(1, max(0, s * (1 + ds)))
                        v = min(1, max(0, v * (1 + dv * 0.6)))
                    }
                    let (nr, ng, nb) = hsvToRGB(h, s, v)
                    cube[offset] = Float(nr); cube[offset + 1] = Float(ng)
                    cube[offset + 2] = Float(nb); cube[offset + 3] = 1
                    offset += 4
                }
            }
        }
        return cube.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private static func rgbToHSV(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        let mx = max(r, g, b), mn = min(r, g, b)
        let delta = mx - mn
        var h = 0.0
        if delta > 0 {
            if mx == r { h = 60 * ((g - b) / delta).truncatingRemainder(dividingBy: 6) }
            else if mx == g { h = 60 * ((b - r) / delta + 2) }
            else { h = 60 * ((r - g) / delta + 4) }
            if h < 0 { h += 360 }
        }
        return (h, mx > 0 ? delta / mx : 0, mx)
    }

    private static func hsvToRGB(_ h: Double, _ s: Double, _ v: Double) -> (Double, Double, Double) {
        let c = v * s
        let hp = h / 60
        let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
        let (r1, g1, b1): (Double, Double, Double)
        switch Int(hp) {
        case 0: (r1, g1, b1) = (c, x, 0)
        case 1: (r1, g1, b1) = (x, c, 0)
        case 2: (r1, g1, b1) = (0, c, x)
        case 3: (r1, g1, b1) = (0, x, c)
        case 4: (r1, g1, b1) = (x, 0, c)
        default: (r1, g1, b1) = (c, 0, x)
        }
        let m = v - c
        return (r1 + m, g1 + m, b1 + m)
    }

    // MARK: - Raster brush masks

    private static var maskCache: [String: CIImage] = [:]
    private static let maskLock = NSLock()

    /// A pre-rendered mask (Aperture's brush TIFF), master-sized: scale it
    /// to the pre-geometry image, run it through the same geometry, and it
    /// lines up with what's on screen.
    static func rasterMask(path: String, sourceExtent: CGRect, geometry: PhotoEdits) -> CIImage? {
        maskLock.lock()
        var mask = maskCache[path]
        maskLock.unlock()
        if mask == nil {
            guard let loaded = CIImage(contentsOf: URL(fileURLWithPath: path)) else { return nil }
            maskLock.lock()
            if maskCache.count > 64 { maskCache.removeAll() }
            maskCache[path] = loaded
            maskLock.unlock()
            mask = loaded
        }
        guard let mask, mask.extent.width > 0, mask.extent.height > 0 else { return nil }
        let sx = sourceExtent.width / mask.extent.width
        let sy = sourceExtent.height / mask.extent.height
        var scaled = mask.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        scaled = scaled.transformed(by: CGAffineTransform(
            translationX: sourceExtent.minX - scaled.extent.minX,
            y: sourceExtent.minY - scaled.extent.minY))
        return applyGeometry(geometry, to: scaled)
    }
}
