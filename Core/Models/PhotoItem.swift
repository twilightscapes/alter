//
//  PhotoItem.swift
//  Alter
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//

import Foundation

/// The metadata fields ALTer edits. Cached in the catalog while dirty, written
/// to the standard XMP/IPTC/EXIF groups via exiftool on save.
struct PhotoMetadata: Equatable, Codable {
    var altText: String = ""       // XMP-iptcCore:AltTextAccessibility
    var title: String = ""         // XMP-dc:Title + IPTC:ObjectName
    var caption: String = ""       // XMP-dc:Description + IPTC:Caption-Abstract
    var keywords: [String] = []    // XMP-dc:Subject + IPTC:Keywords
    var creator: String = ""       // XMP-dc:Creator + IPTC:By-line + EXIF:Artist
    var copyright: String = ""     // XMP-dc:Rights + IPTC:CopyrightNotice + EXIF:Copyright

    static func splitKeywords(_ joined: String) -> [String] {
        joined.components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// JSON for the catalog's as-found backup column. Always non-empty, so an
    /// empty column unambiguously means "never snapshotted".
    func encodedJSON() -> String {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    static func decodeJSON(_ json: String) -> PhotoMetadata? {
        guard !json.isEmpty, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(PhotoMetadata.self, from: data)
    }
}

/// One heal spot: cover `x,y` (normalized 0…1) with texture sampled from a
/// nearby source offset — Aperture-style retouch, stored in the recipe.
struct RetouchSpot: Codable, Equatable, Hashable {
    var x: Double
    var y: Double
    /// Radius as a fraction of image width.
    var radius: Double
    /// Source offset (normalized) the patch is cloned from.
    var dx: Double
    var dy: Double
    /// Aperture's Retouch HUD: edge softness 0…1 (nil = 0.45) and opacity
    /// 0…1 (nil = 1). `clone` marks a spot whose source was chosen by hand.
    var softness: Double? = nil
    var opacity: Double? = nil
    var clone: Bool? = nil
    /// A dragged stroke: the rest of its path after (x, y), normalized.
    var trail: [RetouchPoint]? = nil
    /// Repair by content-aware fill: rebuilt from patches around it, no
    /// single source (dx/dy unused). `variant` picks another fill.
    var fill: Bool? = nil
    var variant: Int? = nil
}

struct RetouchPoint: Codable, Equatable, Hashable {
    var x: Double
    var y: Double
}

/// Aperture's Red Eye: a circle where red pupils lose their red.
struct RedEyeSpot: Codable, Equatable, Hashable {
    var x: Double
    var y: Double
    /// Radius as a fraction of image width.
    var radius: Double
}

/// One dab of a brush: a soft disc of influence, normalized coords like
/// retouch spots. `erase` strokes carve the mask back out.
struct BrushStroke: Codable, Equatable, Hashable {
    var x: Double
    var y: Double
    /// Radius as a fraction of image width.
    var radius: Double
    /// 0 = hard edge … 1 = fully feathered.
    var softness: Double = 0.5
    var erase: Bool? = nil
    /// Aperture's brush Strength: how much of the look one dab applies.
    var strength: Double? = nil
}

/// A brushed adjustment: its own recipe applied only where its strokes
/// painted — Aperture's "brush it in". A photo can carry several (dodge
/// the face, cool the sky), each editable after the fact.
struct BrushLayer: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String? = nil
    /// The brick this layer carries when it was "brushed in/away" from
    /// the Adjust panel (AdjustmentBrick raw value); its sliders live in
    /// `edits` and the panel binds to them here.
    var brick: String? = nil
    /// A Quick Brush (QuickBrush raw value): one look, one slider.
    var quickBrush: String? = nil
    /// Brushed AWAY: the look applies everywhere except where painted.
    var inverted: Bool? = nil
    var strokes: [BrushStroke] = []
    /// A pre-rendered mask image (grayscale, master-sized) instead of
    /// strokes — how an Aperture brush arrives. Read in place, never copied.
    var maskPath: String? = nil
    /// The look painted in — tonal fields only; geometry stays global.
    var edits: PhotoEdits = PhotoEdits()

    var isEmpty: Bool { strokes.isEmpty && maskPath == nil && edits.isNeutral }
}

/// Normalized crop rectangle, unit coordinates with a top-left origin,
/// relative to the quarter-rotated (and straightened) image.
struct CropRect: Codable, Equatable, Hashable {
    var x: Double
    var y: Double
    var w: Double
    var h: Double

    static let full = CropRect(x: 0, y: 0, w: 1, h: 1)

    /// Clamped to the unit square with a floor so a crop can't collapse.
    func clamped(minSize: Double = 0.05) -> CropRect {
        var r = self
        r.w = min(max(r.w, minSize), 1)
        r.h = min(max(r.h, minSize), 1)
        r.x = min(max(r.x, 0), 1 - r.w)
        r.y = min(max(r.y, 0), 1 - r.h)
        return r
    }
}

// MARK: - The Aperture-parity adjustments
//
// Everything below is optional on the recipe (old recipes decode untouched)
// and renders through EditRenderer in a fixed order. Their shapes mirror
// Aperture's bricks closely enough that an Aperture library translates
// into them one-to-one.

struct CurvePoint: Codable, Equatable, Hashable {
    var x: Double
    var y: Double
}

/// Tone curves: an RGB curve plus optional per-channel curves, each a list
/// of control points. Monotone-cubic through the points at render time.
/// The ends are (0,0) and (1,1) unless the list carries its own: a point at
/// x = 0 is a moved black end (Aperture's lifted blacks), and a last point
/// at x ≥ 1 is a moved white end (Aperture's extended range can put it
/// past 1).
struct ToneCurves: Codable, Equatable, Hashable {
    var rgb: [CurvePoint] = []
    var red: [CurvePoint] = []
    var green: [CurvePoint] = []
    var blue: [CurvePoint] = []
    /// The space the curves work in, as Aperture records it: nil (or
    /// ≈0.4545) is the usual gamma-encoded space; 1.0 is linear light.
    var gamma: Double? = nil

    var isLinear: Bool { gamma.map { abs($0 - 1) < 0.01 } ?? false }

    var isIdentity: Bool {
        [rgb, red, green, blue].allSatisfy { pts in
            pts.allSatisfy { abs($0.x - $0.y) < 0.002 }
        }
    }
}

/// Levels, one channel: five source points remapped to five destinations
/// (black, shadow quarter-tone, mid, highlight quarter-tone, white).
struct LevelsChannel: Codable, Equatable, Hashable {
    var blackSrc = 0.0, blackDst = 0.0
    var shadowSrc = 0.25, shadowDst = 0.25
    var midSrc = 0.5, midDst = 0.5
    var highlightSrc = 0.75, highlightDst = 0.75
    var whiteSrc = 1.0, whiteDst = 1.0

    var isIdentity: Bool {
        abs(blackSrc - blackDst) < 0.002 && abs(shadowSrc - shadowDst) < 0.002
            && abs(midSrc - midDst) < 0.002 && abs(highlightSrc - highlightDst) < 0.002
            && abs(whiteSrc - whiteDst) < 0.002
    }
}

struct Levels: Codable, Equatable, Hashable {
    var rgb = LevelsChannel()
    var red: LevelsChannel? = nil
    var green: LevelsChannel? = nil
    var blue: LevelsChannel? = nil
    /// Aperture's Luminance mode: the main levels move brightness only and
    /// leave colour alone, instead of remapping R, G and B separately
    /// (which also pushes saturation and contrast). nil = RGB mode.
    var luminance: Bool? = nil

    var isIdentity: Bool {
        rgb.isIdentity && (red?.isIdentity ?? true) && (green?.isIdentity ?? true)
            && (blue?.isIdentity ?? true)
    }
}

/// One hue band of the Color adjustment (Aperture's six: reds, yellows,
/// greens, cyans, blues, magentas). Shifts are in degrees / percent.
struct ColorBand: Codable, Equatable, Hashable {
    var hueBase: Double          // degrees, the band's center
    var hueShift = 0.0           // degrees
    var saturation = 0.0         // -100…+100
    var luminance = 0.0          // -100…+100
    var spread = 1.0             // band width multiplier

    var isNeutral: Bool { abs(hueShift) < 0.01 && abs(saturation) < 0.01 && abs(luminance) < 0.01 }
}

struct Vignette: Codable, Equatable, Hashable {
    var intensity: Double        // 0…1 (negative = brighten, for devignette)
    var radius: Double           // 0…2, fraction of the half-diagonal
}

/// Black & white via channel mix (percent weights, Aperture-style).
struct BWMix: Codable, Equatable, Hashable {
    var red: Double
    var green: Double
    var blue: Double
}

struct Monochrome: Codable, Equatable, Hashable {
    var red: Double, green: Double, blue: Double
    var intensity: Double
}

/// Aperture's Chromatic Aberration: red/cyan and blue/yellow fringing
/// corrected by scaling those channels a hair about the centre.
struct ChromaticAberration: Codable, Equatable, Hashable {
    var redCyan: Double = 0
    var blueYellow: Double = 0
    var isNeutral: Bool { abs(redCyan) < 0.001 && abs(blueYellow) < 0.001 }
}

struct NoiseReduction: Codable, Equatable, Hashable {
    var radius: Double
    var edgeDetail: Double
}

/// Non-destructive adjustment recipe. Stored in the catalog as JSON, rendered
/// into exports/galleries — the original pixels are never modified.
struct PhotoEdits: Codable, Equatable {
    var exposure: Double = 0      // EV, -2…+2
    var contrast: Double = 1      // 0.5…1.5
    var saturation: Double = 1    // 0…2
    var vibrance: Double = 0      // -1…+1
    var temperature: Double = 0   // -100…+100 (negative cool, positive warm)
    var tint: Double = 0          // -100…+100 (negative green, positive magenta)
    var sharpness: Double = 0     // 0…1
    /// Optional so recipes saved before retouch existed still decode.
    var retouches: [RetouchSpot]? = nil
    // Geometry — all optional so pre-crop recipes still decode.
    /// Quarter turns clockwise, 0…3.
    var rotation: Int? = nil
    /// Straighten in degrees, -15…+15. Renders with a cover-scale so no
    /// blank wedges appear; the extent is unchanged, so crop coords hold.
    var straighten: Double? = nil
    /// Crop in unit coords of the rotated/straightened image.
    var crop: CropRect? = nil
    /// Highlight recovery, 0…1 (0 = off) — pulls blown areas back down.
    var highlights: Double? = nil
    /// Shadow lift, -1…+1 (0 = off) — negative crushes, positive opens.
    var shadows: Double? = nil
    /// Red Eye spots (applied right after retouch).
    var redEyes: [RedEyeSpot]? = nil
    /// Brushed adjustments — optional so old recipes decode.
    var brushes: [BrushLayer]? = nil
    /// Aperture's Flip: mirror after the quarter-turn, before straighten/crop.
    var flipHorizontal: Bool? = nil
    var flipVertical: Bool? = nil

    // Aperture-parity bricks (all optional, all decode-compatible).
    /// Exposure brick: Recovery 0…1.5 pulls highlights back.
    var recovery: Double? = nil
    /// Exposure brick: Black Point 0…50 on Aperture's scale (≈ 8-bit levels).
    var blackPoint: Double? = nil
    /// Exposure brick: Brightness −1…1, a midtone lift or drop.
    var brightness: Double? = nil
    /// Highlights & Shadows brick: Mid Contrast −1…1.
    var midContrast: Double? = nil
    /// Local contrast / clarity, 0…1.
    var definition: Double? = nil
    var vignette: Vignette? = nil
    var devignette: Vignette? = nil
    var curves: ToneCurves? = nil
    /// Further Curves adjustments after the first, applied in order. Aperture
    /// allows several on one version; the Curves brick edits the first.
    var moreCurves: [ToneCurves]? = nil
    /// Aperture match: a per-channel tone curve fitted at import so this
    /// photo's render lines up with the preview Aperture itself made — the
    /// part of its look no slider translation reaches (its RAW engine, its
    /// own filter maths). Applied last in the tonal chain; switchable off
    /// in the Adjust panel ("apertureMatch" in disabledBricks).
    var apertureMatch: ToneCurves? = nil
    /// See appliesFileOrientation.
    var rawOrientation: Bool? = nil
    var levels: Levels? = nil
    var colorBands: [ColorBand]? = nil
    var bwMix: BWMix? = nil
    var monochrome: Monochrome? = nil
    /// Sepia intensity 0…1.
    var sepia: Double? = nil
    /// Multiply-blend the image onto itself (Aperture's Polarize), 0…1.
    var polarize: Double? = nil
    /// Overlay-blend onto itself (Intensify Contrast), 0…1.
    var intensifyContrast: Double? = nil
    var noiseReduction: NoiseReduction? = nil
    /// Edge-aware sharpening, 0…1.
    var edgeSharpen: Double? = nil
    var chromaticAberration: ChromaticAberration? = nil

    /// Bricks unchecked in the Adjust panel: kept with their settings,
    /// not applied — Aperture's checkbox.
    var disabledBricks: [String]? = nil
    /// Bricks added to the panel while still at their neutral values, so
    /// they stay on screen until removed.
    var addedBricks: [String]? = nil

    /// True when any Aperture-parity brick is set — they hash into the
    /// cache key as one block.
    var hasParityBricks: Bool {
        recovery != nil || blackPoint != nil || brightness != nil || midContrast != nil
            || definition != nil || vignette != nil || devignette != nil || curves != nil
            || moreCurves != nil || apertureMatch != nil || levels != nil || colorBands != nil || bwMix != nil || monochrome != nil
            || sepia != nil || polarize != nil || intensifyContrast != nil
            || noiseReduction != nil || edgeSharpen != nil || chromaticAberration != nil
    }

    var brushLayers: [BrushLayer] { brushes ?? [] }
    /// Slider faces for optional detail bricks: nil reads as 0.
    var definitionValue: Double {
        get { definition ?? 0 }
        set { definition = newValue < 0.005 ? nil : newValue }
    }
    var edgeSharpenValue: Double {
        get { edgeSharpen ?? 0 }
        set { edgeSharpen = newValue < 0.005 ? nil : newValue }
    }
    var highlightsValue: Double {
        get { highlights ?? 0 }
        set { highlights = abs(newValue) < 0.005 ? nil : newValue }
    }
    var shadowsValue: Double {
        get { shadows ?? 0 }
        set { shadows = abs(newValue) < 0.005 ? nil : newValue }
    }

    var retouchSpots: [RetouchSpot] { retouches ?? [] }
    var redEyeSpots: [RedEyeSpot] { redEyes ?? [] }
    var rotationQuarters: Int { ((rotation ?? 0) % 4 + 4) % 4 }
    var straightenDegrees: Double { straighten ?? 0 }
    /// True when any geometry op would change pixels.
    var hasGeometry: Bool {
        rotationQuarters != 0 || straightenDegrees != 0
            || (crop.map { $0 != .full } ?? false)
            || flipHorizontal == true || flipVertical == true
    }

    var isNeutral: Bool { self == PhotoEdits() }

    /// Draw the master's pixels as stored, ignoring the file's EXIF
    /// orientation. Aperture's version rotation already includes the
    /// camera's orientation, so honouring the flag as well turned its
    /// vertical shots on their side. Set by the Aperture import, only for
    /// masters whose flag isn't "up".
    var appliesFileOrientation: Bool { rawOrientation != true }

    /// disabledBricks entry that switches the Aperture match off.
    static let apertureMatchKey = "apertureMatch"
    var isApertureMatchOn: Bool { !(disabledBricks ?? []).contains(Self.apertureMatchKey) }
    mutating func setApertureMatch(on: Bool) {
        var list = (disabledBricks ?? []).filter { $0 != Self.apertureMatchKey }
        if !on { list.append(Self.apertureMatchKey) }
        disabledBricks = list.isEmpty ? nil : list
    }

    /// Stable string for thumbnail cache keys — of what actually renders,
    /// so unchecking a brick is a different key and an added-but-neutral
    /// brick is not.
    var cacheKey: String { effective.renderedCacheKey }

    private var renderedCacheKey: String {
        guard !isNeutral else { return "" }
        var key = [exposure, contrast, saturation, vibrance, temperature, tint,
                   sharpness, highlightsValue, shadowsValue]
            .map { String(format: "%.3f", $0) }.joined(separator: ",")
        for spot in retouchSpots {
            key += String(format: "|r%.4f,%.4f,%.4f,%.4f,%.4f,%.2f,%.2f", spot.x, spot.y, spot.radius, spot.dx, spot.dy,
                          spot.softness ?? 0.45, spot.opacity ?? 1)
            if spot.clone == true { key += "c" }
            if spot.fill == true { key += "f\(spot.variant ?? 0)" }
            for p in spot.trail ?? [] { key += String(format: "~%.4f,%.4f", p.x, p.y) }
        }
        for eye in redEyes ?? [] {
            key += String(format: "|e%.4f,%.4f,%.4f", eye.x, eye.y, eye.radius)
        }
        for layer in brushLayers {
            // Session-stable is all a cache key needs; hashing keeps it
            // short when a layer holds hundreds of strokes.
            key += "|B\(layer.strokes.hashValue)~\(layer.maskPath ?? "")~\(layer.edits.cacheKey)"
        }
        if hasParityBricks {
            var hasher = Hasher()
            hasher.combine(recovery); hasher.combine(blackPoint); hasher.combine(brightness)
            hasher.combine(midContrast)
            hasher.combine(definition); hasher.combine(vignette); hasher.combine(devignette)
            hasher.combine(curves); hasher.combine(moreCurves); hasher.combine(apertureMatch); hasher.combine(levels); hasher.combine(colorBands)
            hasher.combine(bwMix); hasher.combine(monochrome); hasher.combine(sepia)
            hasher.combine(polarize); hasher.combine(intensifyContrast)
            hasher.combine(noiseReduction); hasher.combine(edgeSharpen); hasher.combine(chromaticAberration)
            key += "|P\(hasher.finalize())"
        }
        if rawOrientation == true { key += "|raw" }
        if hasGeometry {
            let c = crop ?? .full
            key += String(format: "|g%d,%.2f,%.4f,%.4f,%.4f,%.4f,%d%d",
                          rotationQuarters, straightenDegrees, c.x, c.y, c.w, c.h,
                          flipHorizontal == true ? 1 : 0, flipVertical == true ? 1 : 0)
        }
        return key
    }

    static func decode(_ json: String) -> PhotoEdits {
        guard !json.isEmpty, let data = json.data(using: .utf8),
              let edits = try? JSONDecoder().decode(PhotoEdits.self, from: data) else {
            return PhotoEdits()
        }
        return edits
    }

    func encoded() -> String {
        guard !isNeutral, let data = try? JSONEncoder().encode(self) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

/// One catalog row: a referenced photo plus its edit state.
struct PhotoItem: Identifiable, Equatable {
    enum Status: Equatable {
        case idle
        case queued
        case generating
        case saving
        case done
        case error(String)
    }

    let id: Int64
    let url: URL
    var metadata: PhotoMetadata
    var edits: PhotoEdits = PhotoEdits()
    var rating: Int = 0
    var flagged: Bool = false
    /// Aperture-style colour label (PhotoLabel rawValue; 0 = none).
    var label: Int = 0
    /// Versions: a non-nil value makes this row an alternate take of that
    /// master — same file, its own recipe, rating, flag, and label.
    var versionOf: Int64? = nil
    var versionName: String = ""
    /// Stacks group bursts/brackets; the stack's pick shows when collapsed.
    var stackID: Int64? = nil
    /// A reference render (Aperture's own JPEG) to compare against, if any.
    var referencePath: String = ""
    /// The project this photo lives in (Aperture's container), if any.
    var projectID: Int64? = nil
    // Camera EXIF from the catalog ('' / nil until read).
    var camera: String = ""
    var lens: String = ""
    var iso: Int? = nil
    var focalLength: Double? = nil
    var aperture: Double? = nil
    var shutter: Double? = nil
    /// Metadata cached in the catalog but not yet written into the file.
    var dirty: Bool = false
    var status: Status = .idle
    /// Saved meme composition (JSON) — scape-style, separate from the pixels.
    var memeJSON: String = ""
    /// When the photo entered the library (unix time) — sort key.
    var addedAt: Double = 0
    /// The original file's modification time (unix time) — sort key.
    var fileDate: Double = 0

    var filename: String { url.lastPathComponent }
    var isVersion: Bool { versionOf != nil }
    var photoLabel: PhotoLabel { PhotoLabel(rawValue: label) ?? .none }

    /// Motion media — thumbnails come from the first frame; the viewer plays
    /// it; Meme Maker opens the timeline editor.
    var isVideo: Bool { ImageLoader.isVideoFile(url) }

    /// One search term against everything a person might remember about a
    /// photo: its name, what it's titled, what it shows, how it's tagged.
    func matchesSearch(_ term: String) -> Bool {
        filename.localizedCaseInsensitiveContains(term)
            || metadata.title.localizedCaseInsensitiveContains(term)
            || metadata.caption.localizedCaseInsensitiveContains(term)
            || metadata.altText.localizedCaseInsensitiveContains(term)
            || metadata.creator.localizedCaseInsensitiveContains(term)
            || metadata.keywords.contains { $0.localizedCaseInsensitiveContains(term) }
    }

    init?(row: [String: Any]) {
        guard let id = row["id"] as? Int64, let path = row["path"] as? String else { return nil }
        self.id = id
        self.url = URL(fileURLWithPath: path)
        var meta = PhotoMetadata()
        meta.altText = row["alt_text"] as? String ?? ""
        meta.title = row["title"] as? String ?? ""
        meta.caption = row["caption"] as? String ?? ""
        meta.keywords = PhotoMetadata.splitKeywords(row["keywords"] as? String ?? "")
        meta.creator = row["creator"] as? String ?? ""
        meta.copyright = row["copyright"] as? String ?? ""
        self.metadata = meta
        self.edits = PhotoEdits.decode(row["edits"] as? String ?? "")
        self.rating = Int(row["rating"] as? Int64 ?? 0)
        self.flagged = (row["flagged"] as? Int64 ?? 0) == 1
        self.label = Int(row["label"] as? Int64 ?? 0)
        self.versionOf = row["version_of"] as? Int64
        self.versionName = row["version_name"] as? String ?? ""
        self.stackID = row["stack_id"] as? Int64
        self.referencePath = row["reference_path"] as? String ?? ""
        self.projectID = row["project_id"] as? Int64
        self.camera = row["camera"] as? String ?? ""
        self.lens = row["lens"] as? String ?? ""
        self.iso = (row["iso"] as? Int64).map { Int($0) }
        self.focalLength = row["focal_length"] as? Double
        self.aperture = row["aperture"] as? Double
        self.shutter = row["shutter"] as? Double
        self.dirty = (row["dirty"] as? Int64 ?? 0) == 1
        self.addedAt = row["added_at"] as? Double ?? 0
        self.fileDate = row["mtime"] as? Double ?? 0
        self.memeJSON = row["meme"] as? String ?? ""
    }
}


// MARK: - Bricks (Aperture's adjustment blocks)

/// The adjustment bricks of the Adjust panel, in Aperture's order. Four are
/// always shown; the rest appear when added or when a recipe carries them.
enum AdjustmentBrick: String, CaseIterable, Identifiable {
    case chromaticAberration, devignette, noiseReduction, whiteBalance, exposure, enhance, highlightsShadows,
         levels, color, blackAndWhite, colorMonochrome, sepia, sharpen, edgeSharpen,
         vignette, curves, polarize, intensifyContrast

    var id: String { rawValue }

    var name: String {
        switch self {
        case .chromaticAberration: return "Chromatic Aberration"
        case .devignette: return "Devignette"
        case .noiseReduction: return "Noise Reduction"
        case .whiteBalance: return "White Balance"
        case .exposure: return "Exposure"
        case .enhance: return "Enhance"
        case .highlightsShadows: return "Highlights & Shadows"
        case .levels: return "Levels"
        case .color: return "Color"
        case .blackAndWhite: return "Black & White"
        case .colorMonochrome: return "Color Monochrome"
        case .sepia: return "Sepia Tone"
        case .sharpen: return "Sharpen"
        case .edgeSharpen: return "Edge Sharpen"
        case .vignette: return "Vignette"
        case .curves: return "Curves"
        case .polarize: return "Polarize"
        case .intensifyContrast: return "Intensify Contrast"
        }
    }

    /// Shown on every photo, as in Aperture.
    static let defaults: [AdjustmentBrick] = [.whiteBalance, .exposure, .enhance, .highlightsShadows]

    /// Aperture's Color brick starts with its six bands at their centres.
    static let neutralBands: [ColorBand] = [0, 60, 120, 180, 240, 300].map { ColorBand(hueBase: $0) }
}

extension PhotoEdits {
    /// Does the recipe carry settings for this brick?
    func hasValues(_ brick: AdjustmentBrick) -> Bool {
        switch brick {
        case .chromaticAberration: return chromaticAberration != nil
        case .whiteBalance: return temperature != 0 || tint != 0
        case .exposure: return exposure != 0 || recovery != nil || blackPoint != nil || brightness != nil
        case .enhance: return contrast != 1 || definition != nil || saturation != 1 || vibrance != 0
        case .highlightsShadows: return highlights != nil || shadows != nil || midContrast != nil
        case .levels: return levels != nil
        case .color: return colorBands != nil
        case .blackAndWhite: return bwMix != nil
        case .colorMonochrome: return monochrome != nil
        case .sepia: return sepia != nil
        case .sharpen: return sharpness != 0
        case .edgeSharpen: return edgeSharpen != nil
        case .vignette: return vignette != nil
        case .devignette: return devignette != nil
        case .noiseReduction: return noiseReduction != nil
        case .curves: return curves != nil || moreCurves != nil
        case .polarize: return polarize != nil
        case .intensifyContrast: return intensifyContrast != nil
        }
    }

    func isPresent(_ brick: AdjustmentBrick) -> Bool {
        AdjustmentBrick.defaults.contains(brick) || hasValues(brick)
            || (addedBricks ?? []).contains(brick.rawValue)
            || brushLayerIndex(for: brick) != nil
    }

    func isEnabled(_ brick: AdjustmentBrick) -> Bool {
        !(disabledBricks ?? []).contains(brick.rawValue)
    }

    mutating func setEnabled(_ brick: AdjustmentBrick, _ enabled: Bool) {
        var list = disabledBricks ?? []
        list.removeAll { $0 == brick.rawValue }
        if !enabled { list.append(brick.rawValue) }
        disabledBricks = list.isEmpty ? nil : list
    }

    /// Put a brick on the panel with Aperture's starting values.
    mutating func add(_ brick: AdjustmentBrick) {
        switch brick {
        case .chromaticAberration: if chromaticAberration == nil { chromaticAberration = ChromaticAberration() }
        case .levels: if levels == nil { levels = Levels() }
        case .color: if colorBands == nil { colorBands = AdjustmentBrick.neutralBands }
        case .blackAndWhite: if bwMix == nil { bwMix = BWMix(red: 30, green: 59, blue: 11) }
        case .colorMonochrome:
            if monochrome == nil { monochrome = Monochrome(red: 0.6, green: 0.45, blue: 0.3, intensity: 1) }
        case .sepia: if sepia == nil { sepia = 1 }
        case .sharpen: if sharpness == 0 { sharpness = 0.5 }
        case .edgeSharpen: if edgeSharpen == nil { edgeSharpen = 0.5 }
        case .vignette: if vignette == nil { vignette = Vignette(intensity: 0.7, radius: 1) }
        case .devignette: if devignette == nil { devignette = Vignette(intensity: 0.7, radius: 1) }
        case .noiseReduction: if noiseReduction == nil { noiseReduction = NoiseReduction(radius: 1, edgeDetail: 1) }
        case .curves: if curves == nil { curves = ToneCurves() }
        case .polarize: if polarize == nil { polarize = 0.5 }
        case .intensifyContrast: if intensifyContrast == nil { intensifyContrast = 0.5 }
        case .whiteBalance, .exposure, .enhance, .highlightsShadows: break
        }
        var list = addedBricks ?? []
        if !list.contains(brick.rawValue) { list.append(brick.rawValue) }
        addedBricks = list
    }

    /// Back to neutral, brick stays on the panel.
    mutating func reset(_ brick: AdjustmentBrick) {
        clearValues(brick)
        if !AdjustmentBrick.defaults.contains(brick) {
            var list = addedBricks ?? []
            if !list.contains(brick.rawValue) { list.append(brick.rawValue) }
            addedBricks = list
        }
    }

    /// Off the panel entirely (default bricks reset instead).
    mutating func remove(_ brick: AdjustmentBrick) {
        clearValues(brick)
        setEnabled(brick, true)
        var list = addedBricks ?? []
        list.removeAll { $0 == brick.rawValue }
        addedBricks = list.isEmpty ? nil : list
    }

    /// Which brush layer carries this brick, if it was brushed.
    func brushLayerIndex(for brick: AdjustmentBrick) -> Int? {
        brushLayers.firstIndex { $0.brick == brick.rawValue }
    }

    /// Just this brick's values, on an otherwise empty recipe.
    func extracting(_ brick: AdjustmentBrick) -> PhotoEdits {
        var out = PhotoEdits()
        out.absorb(self, brick: brick)
        return out
    }

    /// Copy one brick's values in from another recipe.
    mutating func absorb(_ other: PhotoEdits, brick: AdjustmentBrick) {
        switch brick {
        case .chromaticAberration: chromaticAberration = other.chromaticAberration
        case .whiteBalance: temperature = other.temperature; tint = other.tint
        case .exposure:
            exposure = other.exposure; recovery = other.recovery
            blackPoint = other.blackPoint; brightness = other.brightness
        case .enhance:
            contrast = other.contrast; definition = other.definition
            saturation = other.saturation; vibrance = other.vibrance
        case .highlightsShadows:
            highlights = other.highlights; shadows = other.shadows; midContrast = other.midContrast
        case .levels: levels = other.levels
        case .color: colorBands = other.colorBands
        case .blackAndWhite: bwMix = other.bwMix
        case .colorMonochrome: monochrome = other.monochrome
        case .sepia: sepia = other.sepia
        case .sharpen: sharpness = other.sharpness
        case .edgeSharpen: edgeSharpen = other.edgeSharpen
        case .vignette: vignette = other.vignette
        case .devignette: devignette = other.devignette
        case .noiseReduction: noiseReduction = other.noiseReduction
        case .curves: curves = other.curves; moreCurves = other.moreCurves
        case .polarize: polarize = other.polarize
        case .intensifyContrast: intensifyContrast = other.intensifyContrast
        }
    }

    mutating func clearValues(_ brick: AdjustmentBrick) {
        switch brick {
        case .chromaticAberration: chromaticAberration = nil
        case .whiteBalance: temperature = 0; tint = 0
        case .exposure: exposure = 0; recovery = nil; blackPoint = nil; brightness = nil
        case .enhance: contrast = 1; definition = nil; saturation = 1; vibrance = 0
        case .highlightsShadows: highlights = nil; shadows = nil; midContrast = nil
        case .levels: levels = nil
        case .color: colorBands = nil
        case .blackAndWhite: bwMix = nil
        case .colorMonochrome: monochrome = nil
        case .sepia: sepia = nil
        case .sharpen: sharpness = 0
        case .edgeSharpen: edgeSharpen = nil
        case .vignette: vignette = nil
        case .devignette: devignette = nil
        case .noiseReduction: noiseReduction = nil
        case .curves: curves = nil; moreCurves = nil
        case .polarize: polarize = nil
        case .intensifyContrast: intensifyContrast = nil
        }
    }

    /// What actually renders: unchecked bricks neutralised, panel
    /// bookkeeping dropped. The renderer and the cache key both use this.
    var effective: PhotoEdits {
        guard disabledBricks != nil || addedBricks != nil else { return self }
        var out = self
        for name in disabledBricks ?? [] {
            if let brick = AdjustmentBrick(rawValue: name) { out.clearValues(brick) }
            if name == PhotoEdits.apertureMatchKey { out.apertureMatch = nil }
        }
        out.disabledBricks = nil
        out.addedBricks = nil
        return out
    }
}


// MARK: - Quick Brushes

/// Aperture's Quick Brushes: one look, painted in, with a single slider.
enum QuickBrush: String, CaseIterable, Identifiable {
    case skinSmoothing, dodge, burn, polarize, intensifyContrast, saturate, desaturate,
         sharpen, blur, noiseReduction, definition, vibrancy, contrast

    var id: String { rawValue }

    var name: String {
        switch self {
        case .skinSmoothing: return "Skin Smoothing"
        case .dodge: return "Dodge (Lighten)"
        case .burn: return "Burn (Darken)"
        case .polarize: return "Polarize (Multiply)"
        case .intensifyContrast: return "Intensify Contrast (Overlay)"
        case .saturate: return "Saturate"
        case .desaturate: return "Desaturate"
        case .sharpen: return "Sharpen"
        case .blur: return "Blur"
        case .noiseReduction: return "Noise Reduction"
        case .definition: return "Definition"
        case .vibrancy: return "Vibrancy"
        case .contrast: return "Contrast"
        }
    }

    /// The look a fresh brush starts with.
    var preset: PhotoEdits {
        var e = PhotoEdits()
        switch self {
        case .skinSmoothing: e.noiseReduction = NoiseReduction(radius: 2.5, edgeDetail: 0.6)
        case .dodge: e.exposure = 0.5
        case .burn: e.exposure = -0.5
        case .polarize: e.polarize = 0.5
        case .intensifyContrast: e.intensifyContrast = 0.5
        case .saturate: e.saturation = 1.5
        case .desaturate: e.saturation = 0.5
        case .sharpen: e.sharpness = 0.6
        case .blur: e.noiseReduction = NoiseReduction(radius: 6, edgeDetail: 0)
        case .noiseReduction: e.noiseReduction = NoiseReduction(radius: 1, edgeDetail: 1)
        case .definition: e.definition = 0.5
        case .vibrancy: e.vibrance = 0.5
        case .contrast: e.contrast = 1.3
        }
        return e
    }

    /// The one slider the HUD shows for it.
    struct SliderSpec {
        let label: String
        let keyPath: WritableKeyPath<PhotoEdits, Double>
        let range: ClosedRange<Double>
        let neutral: Double
    }

    var slider: SliderSpec {
        switch self {
        case .skinSmoothing: return SliderSpec(label: "Amount", keyPath: \.noiseRadiusValue, range: 0...6, neutral: 0)
        case .dodge: return SliderSpec(label: "Amount", keyPath: \.exposure, range: 0...2, neutral: 0)
        case .burn: return SliderSpec(label: "Amount", keyPath: \.burnAmount, range: 0...2, neutral: 0)
        case .polarize: return SliderSpec(label: "Intensity", keyPath: \.polarizeValue, range: 0...1, neutral: 0)
        case .intensifyContrast: return SliderSpec(label: "Intensity", keyPath: \.intensifyValue, range: 0...1, neutral: 0)
        case .saturate: return SliderSpec(label: "Amount", keyPath: \.saturation, range: 1...3, neutral: 1)
        case .desaturate: return SliderSpec(label: "Amount", keyPath: \.desaturateAmount, range: 0...1, neutral: 0)
        case .sharpen: return SliderSpec(label: "Intensity", keyPath: \.sharpness, range: 0...1, neutral: 0)
        case .blur: return SliderSpec(label: "Amount", keyPath: \.noiseRadiusValue, range: 0...10, neutral: 0)
        case .noiseReduction: return SliderSpec(label: "Radius", keyPath: \.noiseRadiusValue, range: 0...4, neutral: 0)
        case .definition: return SliderSpec(label: "Amount", keyPath: \.definitionValue, range: 0...1, neutral: 0)
        case .vibrancy: return SliderSpec(label: "Amount", keyPath: \.vibrance, range: 0...1, neutral: 0)
        case .contrast: return SliderSpec(label: "Amount", keyPath: \.contrastOffset, range: 0...1, neutral: 0)
        }
    }
}

extension PhotoEdits {
    // Slider faces for Quick Brushes (nil-safe, single-direction where
    // Aperture's were).
    var noiseRadiusValue: Double {
        get { noiseReduction?.radius ?? 0 }
        set { noiseReduction = NoiseReduction(radius: newValue, edgeDetail: noiseReduction?.edgeDetail ?? 0.5) }
    }
    var burnAmount: Double {
        get { -exposure }
        set { exposure = -newValue }
    }
    var polarizeValue: Double {
        get { polarize ?? 0 }
        set { polarize = newValue }
    }
    var intensifyValue: Double {
        get { intensifyContrast ?? 0 }
        set { intensifyContrast = newValue }
    }
    var desaturateAmount: Double {
        get { 1 - saturation }
        set { saturation = 1 - newValue }
    }
    var contrastOffset: Double {
        get { contrast - 1 }
        set { contrast = 1 + newValue }
    }
}


// MARK: - Adjustment presets (Aperture's Presets popup)

struct AdjustmentPreset: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var edits: PhotoEdits
    /// Built-ins ship with the app and can't be deleted.
    var builtIn: Bool? = nil

    static let builtIns: [AdjustmentPreset] = {
        func make(_ name: String, _ build: (inout PhotoEdits) -> Void) -> AdjustmentPreset {
            var e = PhotoEdits(); build(&e)
            return AdjustmentPreset(name: name, edits: e, builtIn: true)
        }
        return [
            make("Auto Levels") { $0.levels = Levels(rgb: LevelsChannel(blackSrc: 0.03, whiteSrc: 0.97)) },
            make("Brighten") { $0.exposure = 0.4; $0.shadows = 0.2 },
            make("Darken") { $0.exposure = -0.4 },
            make("Punch") { $0.contrast = 1.2; $0.saturation = 1.15; $0.definition = 0.3 },
            make("Soft") { $0.contrast = 0.85; $0.saturation = 0.9; $0.brightness = 0.1 },
            make("Warm") { $0.temperature = 25; $0.tint = 4 },
            make("Cool") { $0.temperature = -25; $0.tint = -3 },
            make("Vivid") { $0.saturation = 1.35; $0.vibrance = 0.4; $0.contrast = 1.1 },
            make("Faded Film") { $0.levels = Levels(rgb: LevelsChannel(blackDst: 0.08, whiteDst: 0.96)); $0.saturation = 0.85 },
            make("Black & White") { $0.bwMix = BWMix(red: 30, green: 59, blue: 11) },
            make("High Contrast B&W") { $0.bwMix = BWMix(red: 50, green: 40, blue: 10); $0.contrast = 1.35 },
            make("Sepia") { $0.sepia = 0.8 },
            make("Vignette") { $0.vignette = Vignette(intensity: 0.6, radius: 1) },
            make("Toy Camera") { $0.vignette = Vignette(intensity: 0.9, radius: 0.8); $0.saturation = 1.3; $0.contrast = 1.25; $0.chromaticAberration = ChromaticAberration(redCyan: 0.4, blueYellow: -0.3) },
        ]
    }()
}

extension PhotoEdits {
    /// Aperture applies a preset on top: every brick the preset carries
    /// replaces that brick here; geometry, retouch and brushes stay.
    func applying(_ preset: AdjustmentPreset) -> PhotoEdits {
        var out = self
        for brick in AdjustmentBrick.allCases where preset.edits.hasValues(brick) {
            out.absorb(preset.edits, brick: brick)
            out.setEnabled(brick, true)
        }
        return out
    }

    /// Just the adjustment bricks — what a preset or a lift carries.
    var adjustmentsOnly: PhotoEdits {
        var out = PhotoEdits()
        for brick in AdjustmentBrick.allCases where hasValues(brick) {
            out.absorb(self, brick: brick)
        }
        out.disabledBricks = disabledBricks
        return out
    }
}


// MARK: - Eyedroppers

/// What a click on the photo should set, when an eyedropper is armed.
enum ColorPick: String {
    case neutral        // White Balance: make this grey
    case skinTone       // White Balance: make this a healthy skin tone
    case levelsBlack, levelsWhite
    case curvesBlack, curvesGray, curvesWhite

    var hint: String {
        switch self {
        case .neutral: return "Click something that should be neutral grey"
        case .skinTone: return "Click skin"
        case .levelsBlack: return "Click the tone that should be black"
        case .levelsWhite: return "Click the tone that should be white"
        case .curvesBlack: return "Click the tone that should be black"
        case .curvesGray: return "Click the tone that should be mid-grey"
        case .curvesWhite: return "Click the tone that should be white"
        }
    }
}
