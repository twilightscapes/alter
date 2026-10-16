//
//  ApertureTranslator.swift
//  Alter
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
//  Aperture adjustment bricks → an ALTer PhotoEdits recipe. Each Aperture
//  operation becomes the nearest ALTer field; where the two tools disagree
//  on units the conversion is spelled out beside the mapping. Conventions
//  established by experiment on a real Aperture 3.6 library are marked
//  "verified"; anything else is best-effort and expected to be tuned
//  against Aperture's own previews.
//

import Foundation

enum ApertureTranslator {
    /// Why a version's look won't match exactly — surfaced after an open.
    struct Report {
        var unsupported: [String: Int] = [:]
        var approximated: [String: Int] = [:]
        mutating func note(unsupported op: String) { unsupported[op, default: 0] += 1 }
        mutating func note(approximated op: String) { approximated[op, default: 0] += 1 }
    }

    /// Everything the translator needs to know about the version beyond
    /// its adjustment list.
    struct Context {
        let masterWidth: Int
        let masterHeight: Int
        /// Aperture's rotation (0/90/180/270).
        let rotation: Int
        /// As-shot white balance, when another version of the same master
        /// still carries Aperture's defaults. nil → a daylight guess.
        let asShotKelvin: Double?
        let asShotTint: Double?
        /// Resolves a brushed adjustment's mask uuid to its TIFF.
        let maskURL: (String) -> URL?
    }

    static func edits(from adjustments: [ApertureLibrary.Adjustment], context: Context,
                      report: inout Report) -> PhotoEdits {
        var edits = PhotoEdits()

        // Rotation: Aperture stores degrees; 270 turned out to mean the
        // master rotated a quarter COUNTER-clockwise on screen (verified by
        // preview correlation 0.94 vs 0.01), so 90 is a clockwise quarter —
        // the same sense ALTer's rotationQuarters uses.
        switch context.rotation {
        case 90: edits.rotation = 1
        case 180: edits.rotation = 2
        case 270: edits.rotation = 3
        default: break
        }

        for adj in adjustments {
            let p = adj.parameters
            // Brushed adjustments become a mask layer, not a global edit.
            if let mask = adj.maskUuid, let url = context.maskURL(mask) {
                if let layer = brushLayer(for: adj, maskURL: url, report: &report) {
                    edits.brushes = (edits.brushes ?? []) + [layer]
                } else if !brushableBricks.contains(adj.name) {
                    report.note(unsupported: adj.name)
                }
                // (a known brick whose look came out neutral is just a no-op)
                continue
            }

            switch adj.name {
            case "RKRawDecodeOperation":
                break   // RAW boost/hue boost — ALTer's decoder has its own defaults.

            case "RKExposureOperation":
                // Same four sliders as ALTer's Exposure brick, same scales.
                edits.exposure += p.double("inputEV")
                let recovery = p.double("inputRecoveryEV")
                if recovery > 0 { edits.recovery = min(1.5, recovery) }
                let bias = p.double("inputBias")
                if bias > 0.5 { edits.blackPoint = min(50, bias) }
                let brightness = p.double("inputBrightness")
                if brightness != 0 { edits.brightness = min(1, max(-1, brightness)) }

            case "RKEnhanceOperation":
                edits.contrast *= 1 + p.double("inputContrast")
                edits.saturation *= p.double("inputSaturation", default: 1)
                edits.vibrance += p.double("inputVibrancy")
                let definition = p.double("inputDefinition")
                if definition > 0 { edits.definition = min(1, definition) }

            case "RKWhiteBalanceOperation":
                // "Defaults" means as-shot: nothing to do.
                guard !(p["inputIsDefaults"] as? Bool ?? false) else { break }
                // Aperture is absolute (the light was N kelvin); ALTer's
                // slider is a shift from as-shot. Both run warmer with
                // higher kelvin, so the shift is the difference.
                let kelvin = p.double("inputTemperature")
                let tint = p.double("inputTint")
                let baseK = context.asShotKelvin ?? 5200
                let baseTint = context.asShotTint ?? 0
                edits.temperature = clamp((kelvin - baseK) / 25, -100, 100)
                edits.tint = clamp(tint - baseTint, -100, 100)
                if context.asShotKelvin == nil { report.note(approximated: adj.name) }

            case "RKShadowHighlightOperation":
                // Amounts are 0…100.
                let shadows = p.double("inputShadowAmount") / 100
                let highlights = p.double("inputHighlightAmount") / 100
                if shadows != 0 { edits.shadowsValue = clamp(edits.shadowsValue + shadows, -1, 1) }
                if highlights != 0 { edits.highlightsValue = clamp(edits.highlightsValue + highlights, -1, 1) }
                let mid = p.double("inputMidtoneContrast")
                if mid != 0 { edits.midContrast = min(1, max(-1, mid / 100)) }

            case "RKVignetteOperation":
                edits.vignette = Vignette(intensity: p.double("inputIntensity"),
                                          radius: p.double("inputRadius", default: 1))
            case "RKDevignetteOperation":
                edits.devignette = Vignette(intensity: p.double("inputIntensity"),
                                            radius: p.double("inputRadius", default: 1))

            case "RKCurvesOperation":
                var curves = ToneCurves()
                curves.rgb = curvePoints(p["RGBCurvePoints"])
                curves.red = curvePoints(p["redCurvePoints"])
                curves.green = curvePoints(p["greenCurvePoints"])
                curves.blue = curvePoints(p["blueCurvePoints"])
                if !curves.isIdentity { edits.curves = curves }

            case "RKLevelsOperation":
                var levels = edits.levels ?? Levels()
                levels.rgb = merge(levels.rgb, levelsChannel(p, suffix: "RGB"))
                for (suffix, keyPath) in [("Red", \Levels.red), ("Green", \Levels.green), ("Blue", \Levels.blue)] {
                    let channel = levelsChannel(p, suffix: suffix)
                    if !channel.isIdentity { levels[keyPath: keyPath] = channel }
                }
                if !levels.isIdentity { edits.levels = levels }

            case "RKColorOperation":
                var bands: [ColorBand] = []
                for name in ["Reds", "Yellows", "Greens", "Cyans", "Blues", "Magentas"] {
                    let band = ColorBand(
                        hueBase: p.double("input\(name)HueBase", default: defaultHue(name)),
                        hueShift: p.double("input\(name)HueShift"),
                        saturation: p.double("input\(name)Saturation"),
                        luminance: p.double("input\(name)Luminance"),
                        spread: p.double("input\(name)Spread", default: 1))
                    bands.append(band)
                }
                if bands.contains(where: { !$0.isNeutral }) { edits.colorBands = bands }

            case "RKChannelMixerOperation":
                // Aperture's Black & White brick: percent weights per channel.
                edits.bwMix = BWMix(red: p.double("inputRValue", default: 30),
                                    green: p.double("inputGValue", default: 59),
                                    blue: p.double("inputBValue", default: 11))

            case "CIColorMonochrome":
                let rgb = nsColorRGB(p["inputColor"]) ?? (0.6, 0.45, 0.3)
                edits.monochrome = Monochrome(red: rgb.0, green: rgb.1, blue: rgb.2,
                                              intensity: p.double("inputIntensity", default: 1))
            case "CISepiaTone":
                edits.sepia = p.double("inputIntensity", default: 1)

            case "DGGNGMultiplyOperation":
                edits.polarize = p.double("inputIntensity", default: 0.5)
            case "DGGNGOverlayBlendOperation":
                edits.intensifyContrast = p.double("inputIntensity", default: 0.5)

            case "RKProSharpenOperation":
                edits.edgeSharpen = max(edits.edgeSharpen ?? 0, min(1, p.double("inputSharpness")))
            case "RKSharpenOperation", "DGGNGSharpenOperation":
                let key = adj.name == "RKSharpenOperation" ? "inputIntensity" : "inputSharpness"
                edits.sharpness = min(1, edits.sharpness + p.double(key))
            case "DGGNGDefinitionOperation":
                edits.definition = min(1, (edits.definition ?? 0) + p.double("inputIntensity"))

            case "RKNoiseReductionOperation":
                edits.noiseReduction = NoiseReduction(radius: p.double("inputRadius"),
                                                      edgeDetail: p.double("inputEdgeDetail"))

            case "DGChromaticAberrationOperation":
                edits.chromaticAberration = ChromaticAberration(
                    redCyan: p.double("inputRedCyan"), blueYellow: p.double("inputBlueYellow"))

            case "RKStraightenCropOperation":
                // Degrees, opposite sense to ALTer's slider: Aperture's
                // positive is counter-clockwise (verified against previews,
                // flipped matched 24 of 32 straightened versions, the rest
                // were within noise).
                let degrees = p.double("inputRotation")
                if degrees != 0 { edits.straighten = -degrees }

            case "RKCropOperation":
                edits.crop = cropRect(p, context: context)

            case "RKRetouchOperation":
                let spots = retouchSpots(p, context: context)
                if !spots.isEmpty { edits.retouches = (edits.retouches ?? []) + spots }

            case "DGGNGBurnOperation", "DGGNGDodgeOperation", "DGGNGBlurOperation",
                 "DGGNGSaturateOperation", "DGGNGDesaturateOperation", "DGGNGContrastOperation",
                 "DGGNGHaloReductionOperation", "DGGNGSkinSmoothingOperation",
                 "DGGNGBrushedBlurOperation", "DGGNGNoiseReductionOperation", "DGGNGVibrancyOperation":
                // Brush-only bricks that arrived without a mask: apply the
                // look globally rather than drop it.
                if let layer = brushLayer(for: adj, maskURL: nil, report: &report) {
                    edits = overlay(layer.edits, onto: edits)
                    report.note(approximated: adj.name)
                } else {
                    report.note(unsupported: adj.name)
                }

            default:
                report.note(unsupported: adj.name)
            }
        }
        return edits
    }

    // MARK: - Brushes

    /// Bricks `brushLayer` knows how to express when they arrive masked.
    private static let brushableBricks: Set<String> = [
        "DGGNGDodgeOperation", "DGGNGBurnOperation", "DGGNGSharpenOperation",
        "DGGNGDefinitionOperation", "DGGNGSaturateOperation", "DGGNGDesaturateOperation",
        "DGGNGContrastOperation", "DGGNGVibrancyOperation", "DGGNGMultiplyOperation",
        "DGGNGOverlayBlendOperation", "DGGNGBlurOperation", "DGGNGBrushedBlurOperation",
        "DGGNGSkinSmoothingOperation", "DGGNGNoiseReductionOperation",
        "RKExposureOperation", "RKEnhanceOperation", "RKShadowHighlightOperation",
        "RKWhiteBalanceOperation", "RKCurvesOperation", "RKLevelsOperation",
        "RKColorOperation", "RKVignetteOperation", "RKDevignetteOperation",
        "RKChannelMixerOperation", "CIColorMonochrome", "CISepiaTone",
        "RKProSharpenOperation", "RKSharpenOperation", "RKNoiseReductionOperation",
    ]

    /// A brushed brick: its mask plus the tonal look it painted. Aperture's
    /// quick brushes each carry one parameter; ALTer expresses them as a
    /// recipe applied through the mask.
    private static func brushLayer(for adj: ApertureLibrary.Adjustment, maskURL: URL?,
                                   report: inout Report) -> BrushLayer? {
        let p = adj.parameters
        var look = PhotoEdits()
        var name: String
        switch adj.name {
        case "DGGNGDodgeOperation":
            name = "Dodge"; look.exposure = p.double("inputExposure", default: 0.5)
        case "DGGNGBurnOperation":
            name = "Burn"; look.exposure = -p.double("inputExposure", default: 0.5)
        case "DGGNGSharpenOperation":
            name = "Sharpen"; look.sharpness = min(1, p.double("inputSharpness", default: 1))
        case "DGGNGDefinitionOperation":
            name = "Definition"; look.definition = min(1, p.double("inputIntensity", default: 0.5))
        case "DGGNGSaturateOperation":
            name = "Saturate"; look.saturation = 1 + p.double("inputIntensity", default: 0.5)
        case "DGGNGDesaturateOperation":
            name = "Desaturate"; look.saturation = max(0, 1 - p.double("inputIntensity", default: 0.5))
        case "DGGNGContrastOperation":
            name = "Contrast"; look.contrast = 1 + p.double("inputIntensity", default: 0.3)
        case "DGGNGVibrancyOperation":
            name = "Vibrancy"; look.vibrance = p.double("inputIntensity", default: 0.5)
        case "DGGNGMultiplyOperation":
            name = "Polarize"; look.polarize = p.double("inputIntensity", default: 0.5)
        case "DGGNGOverlayBlendOperation":
            name = "Intensify Contrast"; look.intensifyContrast = p.double("inputIntensity", default: 0.5)
        case "DGGNGBlurOperation", "DGGNGBrushedBlurOperation":
            name = "Blur"; look.noiseReduction = NoiseReduction(
                radius: min(10, p.double("inputIntensity", default: 5) / 2), edgeDetail: 0)
            report.note(approximated: adj.name)
        case "DGGNGSkinSmoothingOperation", "DGGNGNoiseReductionOperation":
            name = adj.name == "DGGNGSkinSmoothingOperation" ? "Skin Smoothing" : "Noise Reduction"
            look.noiseReduction = NoiseReduction(radius: 2, edgeDetail: 0.5)
            report.note(approximated: adj.name)
        case "RKExposureOperation", "RKEnhanceOperation", "RKShadowHighlightOperation",
             "RKWhiteBalanceOperation", "RKCurvesOperation", "RKLevelsOperation",
             "RKColorOperation", "RKVignetteOperation", "RKDevignetteOperation",
             "RKChannelMixerOperation", "CIColorMonochrome", "CISepiaTone",
             "RKProSharpenOperation", "RKSharpenOperation", "RKNoiseReductionOperation":
            // A full brick brushed in: translate it as if global, then mask.
            name = displayName(adj.name)
            var sub = Report()
            let context = Context(masterWidth: 0, masterHeight: 0, rotation: 0,
                                  asShotKelvin: nil, asShotTint: nil, maskURL: { _ in nil })
            let unmasked = ApertureLibrary.Adjustment(name: adj.name, isEnabled: true,
                                                      maskUuid: nil, parameters: p)
            look = edits(from: [unmasked], context: context, report: &sub)
            look.rotation = nil
        default:
            return nil
        }
        guard !look.isNeutral else { return nil }
        let brick: AdjustmentBrick? = {
            switch adj.name {
            case "RKExposureOperation": return .exposure
            case "RKEnhanceOperation": return .enhance
            case "RKShadowHighlightOperation": return .highlightsShadows
            case "RKWhiteBalanceOperation": return .whiteBalance
            case "RKCurvesOperation": return .curves
            case "RKLevelsOperation": return .levels
            case "RKColorOperation": return .color
            case "RKVignetteOperation": return .vignette
            case "RKDevignetteOperation": return .devignette
            case "RKChannelMixerOperation": return .blackAndWhite
            case "CIColorMonochrome": return .colorMonochrome
            case "CISepiaTone": return .sepia
            case "RKProSharpenOperation": return .edgeSharpen
            case "RKSharpenOperation": return .sharpen
            case "RKNoiseReductionOperation": return .noiseReduction
            default: return nil
            }
        }()
        let quick: QuickBrush? = {
            switch adj.name {
            case "DGGNGDodgeOperation": return .dodge
            case "DGGNGBurnOperation": return .burn
            case "DGGNGSharpenOperation": return .sharpen
            case "DGGNGDefinitionOperation": return .definition
            case "DGGNGSaturateOperation": return .saturate
            case "DGGNGDesaturateOperation": return .desaturate
            case "DGGNGContrastOperation": return .contrast
            case "DGGNGVibrancyOperation": return .vibrancy
            case "DGGNGMultiplyOperation": return .polarize
            case "DGGNGOverlayBlendOperation": return .intensifyContrast
            case "DGGNGBlurOperation", "DGGNGBrushedBlurOperation": return .blur
            case "DGGNGSkinSmoothingOperation": return .skinSmoothing
            case "DGGNGNoiseReductionOperation": return .noiseReduction
            default: return nil
            }
        }()
        return BrushLayer(name: name, brick: brick?.rawValue, quickBrush: quick?.rawValue,
                          strokes: [], maskPath: maskURL?.path, edits: look)
    }

    /// Fold a brush look into a global recipe (used when a brush brick
    /// has no mask on disk).
    private static func overlay(_ look: PhotoEdits, onto base: PhotoEdits) -> PhotoEdits {
        var out = base
        out.exposure += look.exposure
        out.contrast *= look.contrast
        out.saturation *= look.saturation
        out.vibrance += look.vibrance
        out.sharpness = min(1, out.sharpness + look.sharpness)
        if let d = look.definition { out.definition = min(1, (out.definition ?? 0) + d) }
        if let v = look.polarize { out.polarize = v }
        if let v = look.intensifyContrast { out.intensifyContrast = v }
        if let v = look.noiseReduction { out.noiseReduction = v }
        return out
    }

    // MARK: - Geometry

    /// Aperture crops are master-pixel rectangles with a BOTTOM-LEFT origin
    /// (verified: correlation 0.98 vs 0.00 for top-left), in the unrotated
    /// master's space even when the version is rotated (verified: crop
    /// widths exceed the rotated height). ALTer wants unit coordinates,
    /// top-left origin, in the rotated image — so flip, then rotate.
    private static func cropRect(_ p: [String: Any], context: Context) -> CropRect? {
        let W = Double(context.masterWidth), H = Double(context.masterHeight)
        guard W > 0, H > 0 else { return nil }
        let x = p.double("inputXOrigin"), y = p.double("inputYOrigin")
        let w = p.double("inputWidth", default: W), h = p.double("inputHeight", default: H)
        guard w > 0, h > 0 else { return nil }
        // Unit, top-left, master orientation.
        var r = CropRect(x: x / W, y: 1 - (y + h) / H, w: w / W, h: h / H)
        switch context.rotation {
        case 90:   // clockwise quarter: (u,v) → (1-v, u)
            r = CropRect(x: 1 - (r.y + r.h), y: r.x, w: r.h, h: r.w)
        case 180:
            r = CropRect(x: 1 - (r.x + r.w), y: 1 - (r.y + r.h), w: r.w, h: r.h)
        case 270:  // counter-clockwise quarter: (u,v) → (v, 1-u)
            r = CropRect(x: r.y, y: 1 - (r.x + r.w), w: r.h, h: r.w)
        default: break
        }
        let clamped = r.clamped()
        return clamped == .full ? nil : clamped
    }

    /// Retouch strokes are polylines in master pixels with a source offset;
    /// ALTer heals with spots, so each stroke becomes spots along its path
    /// spaced about a radius apart. Same bottom-left convention as crop.
    private static func retouchSpots(_ p: [String: Any], context: Context) -> [RetouchSpot] {
        let W = Double(context.masterWidth), H = Double(context.masterHeight)
        guard W > 0, H > 0, let strokes = p["inputStrokes"] as? [Any] else { return [] }
        var spots: [RetouchSpot] = []
        for case let stroke as [String: Any] in strokes {
            guard let brush = stroke["brushStroke"] as? [String: Any],
                  let points = brush["data"] as? [Any] else { continue }
            let radiusPx = brush.double("radius", default: 20)
            let offset = parseOffset(stroke["sourceOffset"] as? String)
            // Decimate: successive points closer than ~0.7 radius merge.
            var last: (Double, Double)?
            for case let point as [String: Any] in points {
                let px = point.double("xLocation"), py = point.double("yLocation")
                if let l = last, hypot(px - l.0, py - l.1) < radiusPx * 0.7 { continue }
                last = (px, py)
                var spot = RetouchSpot(x: px / W, y: 1 - py / H, radius: radiusPx / W,
                                       dx: offset.0 / W, dy: offset.1 / H)
                spot = rotate(spot, context.rotation)
                spots.append(spot)
            }
        }
        return spots
    }

    private static func rotate(_ s: RetouchSpot, _ rotation: Int) -> RetouchSpot {
        var r = s
        switch rotation {
        case 90:  r.x = 1 - s.y; r.y = s.x; r.dx = -s.dy; r.dy = s.dx
        case 180: r.x = 1 - s.x; r.y = 1 - s.y; r.dx = -s.dx; r.dy = -s.dy
        case 270: r.x = s.y; r.y = 1 - s.x; r.dx = s.dy; r.dy = -s.dx
        default: break
        }
        return r
    }

    /// "{4, -59}" → (4, -59). Aperture's offset is in master pixels, y up.
    private static func parseOffset(_ s: String?) -> (Double, Double) {
        guard let s else { return (0, 0) }
        let parts = s.trimmingCharacters(in: CharacterSet(charactersIn: "{} "))
            .components(separatedBy: ",")
            .map { Double($0.trimmingCharacters(in: .whitespaces)) ?? 0 }
        guard parts.count == 2 else { return (0, 0) }
        return (parts[0], -parts[1])
    }

    // MARK: - Curves / levels / colour helpers

    /// Aperture pads curves with sentinels at (0,0) and x = 5; keep the
    /// editable points inside the unit square.
    private static func curvePoints(_ raw: Any?) -> [CurvePoint] {
        guard let list = raw as? [Any] else { return [] }
        var pts: [CurvePoint] = []
        for case let d as [String: Any] in list {
            let x = d.double("x"), y = d.double("y")
            guard x > 0.0001, x < 0.9999 else { continue }
            pts.append(CurvePoint(x: x, y: clamp(y, 0, 1)))
        }
        return pts.sorted { $0.x < $1.x }
    }

    private static func levelsChannel(_ p: [String: Any], suffix: String) -> LevelsChannel {
        var c = LevelsChannel()
        c.blackSrc = p.double("inputBlackSrc\(suffix)", default: 0)
        c.blackDst = p.double("inputBlackDst\(suffix)", default: 0)
        c.shadowSrc = p.double("inputShadowSrc\(suffix)", default: 0.25)
        c.shadowDst = p.double("inputShadowDst\(suffix)", default: 0.25)
        c.midSrc = p.double("inputMidSrc\(suffix)", default: 0.5)
        c.midDst = p.double("inputMidDst\(suffix)", default: 0.5)
        c.highlightSrc = p.double("inputHilightSrc\(suffix)", default: 0.75)
        c.highlightDst = p.double("inputHilightDst\(suffix)", default: 0.75)
        c.whiteSrc = p.double("inputWhiteSrc\(suffix)", default: 1)
        c.whiteDst = p.double("inputWhiteDst\(suffix)", default: 1)
        return c
    }

    /// When Exposure already set a black point, keep the stronger one.
    private static func merge(_ a: LevelsChannel, _ b: LevelsChannel) -> LevelsChannel {
        var out = b
        out.blackSrc = max(a.blackSrc, b.blackSrc)
        return out
    }

    private static func defaultHue(_ band: String) -> Double {
        switch band {
        case "Reds": return 0
        case "Yellows": return 60
        case "Greens": return 120
        case "Cyans": return 180
        case "Blues": return 240
        default: return 300
        }
    }

    /// NSColor keyed-archive form: NSRGB is an ASCII "r g b" (sometimes
    /// with alpha) C string.
    private static func nsColorRGB(_ raw: Any?) -> (Double, Double, Double)? {
        guard let dict = raw as? [String: Any] else { return nil }
        var text: String?
        if let data = dict["NSRGB"] as? Data {
            text = String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
        } else if let s = dict["NSRGB"] as? String {
            text = s
        }
        guard let text else { return nil }
        let parts = text.split(separator: " ").compactMap { Double($0) }
        guard parts.count >= 3 else { return nil }
        return (parts[0], parts[1], parts[2])
    }

    static func displayName(_ op: String) -> String {
        switch op {
        case "RKExposureOperation": return "Exposure"
        case "RKEnhanceOperation": return "Enhance"
        case "RKWhiteBalanceOperation": return "White Balance"
        case "RKShadowHighlightOperation": return "Highlights & Shadows"
        case "RKCurvesOperation": return "Curves"
        case "RKLevelsOperation": return "Levels"
        case "RKColorOperation": return "Color"
        case "RKVignetteOperation": return "Vignette"
        case "RKDevignetteOperation": return "Devignette"
        case "RKChannelMixerOperation": return "Black & White"
        case "CIColorMonochrome": return "Color Monochrome"
        case "CISepiaTone": return "Sepia Tone"
        case "RKProSharpenOperation": return "Edge Sharpen"
        case "RKSharpenOperation": return "Sharpen"
        case "RKNoiseReductionOperation": return "Noise Reduction"
        case "RKCropOperation": return "Crop"
        case "RKStraightenCropOperation": return "Straighten"
        case "RKRetouchOperation": return "Retouch"
        case "DGChromaticAberrationOperation": return "Chromatic Aberration"
        case "DGGNGMultiplyOperation": return "Polarize"
        case "DGGNGOverlayBlendOperation": return "Intensify Contrast"
        case "DGGNGDodgeOperation": return "Dodge"
        case "DGGNGBurnOperation": return "Burn"
        case "DGGNGBlurOperation": return "Blur"
        case "DGGNGSharpenOperation": return "Sharpen (brush)"
        case "DGGNGDefinitionOperation": return "Definition (brush)"
        default:
            return op.replacingOccurrences(of: "RK", with: "")
                .replacingOccurrences(of: "DGGNG", with: "")
                .replacingOccurrences(of: "Operation", with: "")
        }
    }

    private static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        min(max(v, lo), hi)
    }
}

private extension Dictionary where Key == String, Value == Any {
    func double(_ key: String, default fallback: Double = 0) -> Double {
        switch self[key] {
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let b as Bool: return b ? 1 : 0
        default: return fallback
        }
    }
}
