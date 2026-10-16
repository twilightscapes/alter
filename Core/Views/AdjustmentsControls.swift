//
//  AdjustmentsControls.swift
//  Alter
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
//  The Adjustments inspector, Aperture's way: a stack of bricks, each with
//  a checkbox (off keeps the settings, just doesn't apply them), a name, a
//  gear menu (Reset / Remove), and labelled sliders with a numeric field
//  and a reset arrow. Four bricks are always there; the rest arrive through
//  the Add Adjustment popup. Operates on a plain Binding<PhotoEdits> so it
//  extracts straight into the EditKit package shared with Twilightscapes.
//

import SwiftUI

struct AdjustmentsControls: View {
    @Binding var edits: PhotoEdits
    /// The adjusted photo's histogram — the backdrop for Levels and Curves.
    var histogram: HistogramData? = nil
    /// Brushing hooks (the host owns the viewer): brick in/away, edit a
    /// layer's strokes, a Quick Brush. nil = no brushing offered.
    var onBrush: ((AdjustmentBrick, Bool) -> Void)? = nil
    var onEditBrush: ((UUID) -> Void)? = nil
    var onApplyToEntirePhoto: ((UUID) -> Void)? = nil
    var onRemoveBrush: ((UUID) -> Void)? = nil
    var onQuickBrush: ((QuickBrush) -> Void)? = nil
    /// The layer being painted right now, if any (its section is marked).
    var activeBrushLayerID: UUID? = nil
    /// Presets: the user's saved ones; apply / save / delete hooks.
    var presets: [AdjustmentPreset] = []
    var onApplyPreset: ((AdjustmentPreset) -> Void)? = nil
    var onSavePreset: (() -> Void)? = nil
    var onDeletePreset: ((AdjustmentPreset) -> Void)? = nil
    /// Per-brick Auto (Exposure, Enhance, Highlights & Shadows).
    var onAuto: ((AdjustmentBrick) -> Void)? = nil
    /// Eyedroppers (White Balance, Levels, Curves): arm one; the host's
    /// viewer takes the click. `activePick` marks the armed one.
    var onPick: ((ColorPick) -> Void)? = nil
    var activePick: ColorPick? = nil

    @State private var collapsed: Set<String> = []

    private var present: [AdjustmentBrick] {
        AdjustmentBrick.allCases.filter { edits.isPresent($0) }
    }

    /// Layers that aren't a brick: Quick Brushes and anything older.
    private var looseLayers: [BrushLayer] {
        edits.brushLayers.filter { $0.brick == nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Menu {
                    ForEach(AdjustmentBrick.allCases) { brick in
                        Button(brick.name) { edits.add(brick) }
                            .disabled(edits.isPresent(brick))
                    }
                    if let onQuickBrush {
                        Divider()
                        Menu("Quick Brushes") {
                            ForEach(QuickBrush.allCases) { quick in
                                Button(quick.name) { onQuickBrush(quick) }
                            }
                        }
                    }
                } label: {
                    Label("Add Adjustment", systemImage: "plus")
                }
                .menuStyle(.button)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Add an adjustment brick — or a Quick Brush to paint in")
                if let onApplyPreset {
                    Menu {
                        Section("Built-in") {
                            ForEach(AdjustmentPreset.builtIns) { preset in
                                Button(preset.name) { onApplyPreset(preset) }
                            }
                        }
                        if !presets.isEmpty {
                            Section("Mine") {
                                ForEach(presets) { preset in
                                    Button(preset.name) { onApplyPreset(preset) }
                                }
                            }
                        }
                        Divider()
                        if let onSavePreset { Button("Save as Preset…") { onSavePreset() } }
                        if let onDeletePreset, !presets.isEmpty {
                            Menu("Delete Preset") {
                                ForEach(presets) { preset in
                                    Button(preset.name) { onDeletePreset(preset) }
                                }
                            }
                        }
                    } label: {
                        Label("Presets", systemImage: "list.bullet.rectangle")
                    }
                    .menuStyle(.button)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Apply a preset on top of the current adjustments, or save these as one")
                }
                Spacer()
            }

            ForEach(present) { brick in
                BrickSection(
                    brick: brick,
                    edits: $edits,
                    holder: holder(for: brick),
                    brushLayer: edits.brushLayerIndex(for: brick).map { edits.brushLayers[$0] },
                    isActiveBrush: edits.brushLayerIndex(for: brick).map { edits.brushLayers[$0].id } == activeBrushLayerID
                        && activeBrushLayerID != nil,
                    histogram: histogram,
                    isCollapsed: collapsed.contains(brick.rawValue),
                    toggleCollapsed: {
                        if collapsed.contains(brick.rawValue) {
                            collapsed.remove(brick.rawValue)
                        } else {
                            collapsed.insert(brick.rawValue)
                        }
                    },
                    onBrush: onBrush,
                    onEditBrush: onEditBrush,
                    onApplyToEntirePhoto: onApplyToEntirePhoto,
                    onRemoveBrush: onRemoveBrush,
                    onAuto: onAuto,
                    onPick: onPick,
                    activePick: activePick)
            }

            ForEach(looseLayers) { layer in
                QuickBrushSection(
                    layer: layerBinding(layer.id),
                    isActive: layer.id == activeBrushLayerID,
                    onEditBrush: onEditBrush,
                    onRemoveBrush: onRemoveBrush)
            }
        }
    }

    /// The recipe a brick's sliders write to: the brush layer carrying it
    /// when it was brushed, otherwise the whole photo.
    private func holder(for brick: AdjustmentBrick) -> Binding<PhotoEdits> {
        guard edits.brushLayerIndex(for: brick) != nil else { return $edits }
        return Binding(
            get: {
                edits.brushLayerIndex(for: brick).map { edits.brushLayers[$0].edits } ?? PhotoEdits()
            },
            set: { value in
                guard let index = edits.brushLayerIndex(for: brick) else { return }
                var layers = edits.brushLayers
                layers[index].edits = value
                edits.brushes = layers
            })
    }

    private func layerBinding(_ id: UUID) -> Binding<BrushLayer> {
        Binding(
            get: { edits.brushLayers.first { $0.id == id } ?? BrushLayer() },
            set: { value in
                var layers = edits.brushLayers
                guard let index = layers.firstIndex(where: { $0.id == id }) else { return }
                layers[index] = value
                edits.brushes = layers
            })
    }
}

// MARK: - A Quick Brush's section

private struct QuickBrushSection: View {
    @Binding var layer: BrushLayer
    let isActive: Bool
    let onEditBrush: ((UUID) -> Void)?
    let onRemoveBrush: ((UUID) -> Void)?

    private var quick: QuickBrush? { layer.quickBrush.flatMap(QuickBrush.init(rawValue:)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "paintbrush.pointed.fill")
                    .font(.caption2)
                    .foregroundColor(isActive ? .orange : .secondary)
                Text(layer.name ?? quick?.name ?? "Brush")
                    .font(.caption.weight(.semibold))
                Text(layer.inverted == true ? "brushed away" : "brushed in")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
                Menu {
                    if let onEditBrush { Button("Edit Brush Strokes…") { onEditBrush(layer.id) } }
                    if let onRemoveBrush { Button("Remove \(layer.name ?? "Brush")") { onRemoveBrush(layer.id) } }
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 3)
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .fixedSize()
            }
            if let quick {
                let spec = quick.slider
                ApertureSlider(spec.label, value: Binding(
                    get: { layer.edits[keyPath: spec.keyPath] },
                    set: { layer.edits[keyPath: spec.keyPath] = $0 }),
                    in: spec.range, default: spec.neutral)
            } else {
                Text("Strokes only — sliders apply while painting.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isActive ? Color.orange.opacity(0.7) : Color.clear, lineWidth: 1)
        )
    }
}

// MARK: - One brick

private struct BrickSection: View {
    let brick: AdjustmentBrick
    /// The whole photo's recipe (presence, add/remove live here).
    @Binding var edits: PhotoEdits
    /// Where this brick's values live: a brush layer's recipe or `edits`.
    @Binding var holder: PhotoEdits
    let brushLayer: BrushLayer?
    let isActiveBrush: Bool
    let histogram: HistogramData?
    let isCollapsed: Bool
    let toggleCollapsed: () -> Void
    var onBrush: ((AdjustmentBrick, Bool) -> Void)? = nil
    var onEditBrush: ((UUID) -> Void)? = nil
    var onApplyToEntirePhoto: ((UUID) -> Void)? = nil
    var onRemoveBrush: ((UUID) -> Void)? = nil
    var onAuto: ((AdjustmentBrick) -> Void)? = nil
    var onPick: ((ColorPick) -> Void)? = nil
    var activePick: ColorPick? = nil

    init(brick: AdjustmentBrick, edits: Binding<PhotoEdits>, holder: Binding<PhotoEdits>,
         brushLayer: BrushLayer?, isActiveBrush: Bool, histogram: HistogramData?,
         isCollapsed: Bool, toggleCollapsed: @escaping () -> Void,
         onBrush: ((AdjustmentBrick, Bool) -> Void)?, onEditBrush: ((UUID) -> Void)?,
         onApplyToEntirePhoto: ((UUID) -> Void)?, onRemoveBrush: ((UUID) -> Void)?,
         onAuto: ((AdjustmentBrick) -> Void)? = nil,
         onPick: ((ColorPick) -> Void)? = nil, activePick: ColorPick? = nil) {
        self.onAuto = onAuto
        self.onPick = onPick
        self.activePick = activePick
        self.brick = brick
        self._edits = edits
        self._holder = holder
        self.brushLayer = brushLayer
        self.isActiveBrush = isActiveBrush
        self.histogram = histogram
        self.isCollapsed = isCollapsed
        self.toggleCollapsed = toggleCollapsed
        self.onBrush = onBrush
        self.onEditBrush = onEditBrush
        self.onApplyToEntirePhoto = onApplyToEntirePhoto
        self.onRemoveBrush = onRemoveBrush
    }

    private var enabled: Binding<Bool> {
        Binding(get: { holder.isEnabled(brick) }, set: { holder.setEnabled(brick, $0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Button(action: toggleCollapsed) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                        .frame(width: 10)
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .accessibilityLabel(isCollapsed ? "Expand \(brick.name)" : "Collapse \(brick.name)")

                Toggle("", isOn: enabled)
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .help(enabled.wrappedValue ? "Uncheck to see the photo without this adjustment (settings are kept)"
                                               : "Check to apply this adjustment again")
                    .accessibilityLabel("\(brick.name) enabled")

                Text(brick.name)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(enabled.wrappedValue ? .primary : .secondary)
                    .onTapGesture(perform: toggleCollapsed)
                if let brushLayer {
                    Label(brushLayer.inverted == true ? "away" : "in", systemImage: "paintbrush.pointed.fill")
                        .font(.caption2)
                        .foregroundColor(isActiveBrush ? .orange : .secondary)
                        .help(brushLayer.inverted == true
                              ? "Brushed away: applies everywhere except where painted"
                              : "Brushed in: applies only where painted")
                }
                Spacer()
                // Aperture's eyedroppers.
                if let onPick {
                    switch brick {
                    case .whiteBalance:
                        eyedropper(.neutral, "eyedropper.halffull", "Neutral: click something that should be grey", onPick)
                        eyedropper(.skinTone, "face.smiling", "Skin Tone: click skin", onPick)
                    case .levels:
                        eyedropper(.levelsBlack, "eyedropper", "Black point", onPick)
                        eyedropper(.levelsWhite, "eyedropper.full", "White point", onPick)
                    case .curves:
                        eyedropper(.curvesBlack, "eyedropper", "Black point", onPick)
                        eyedropper(.curvesGray, "eyedropper.halffull", "Grey point", onPick)
                        eyedropper(.curvesWhite, "eyedropper.full", "White point", onPick)
                    default:
                        EmptyView()
                    }
                }
                // Aperture's Auto buttons.
                if let onAuto, [.exposure, .enhance, .highlightsShadows].contains(brick) {
                    Button("Auto") { onAuto(brick) }
                        .controlSize(.mini)
                        .help("Set \(brick.name) from an analysis of the photo")
                } else if brick == .levels {
                    Button("Auto") { autoLevels() }
                        .controlSize(.mini)
                        .disabled(histogram == nil)
                        .help("Black and white points from the histogram")
                } else if brick == .curves {
                    Button("Auto") { autoCurves() }
                        .controlSize(.mini)
                        .disabled(histogram == nil)
                        .help("A gentle contrast curve from the histogram's ends")
                }
                Menu {
                    if let brushLayer {
                        if let onEditBrush { Button("Edit Brush Strokes…") { onEditBrush(brushLayer.id) } }
                        if let onApplyToEntirePhoto {
                            Button("Apply \(brick.name) to Entire Photo") { onApplyToEntirePhoto(brushLayer.id) }
                        }
                        Divider()
                        Button("Reset \(brick.name)") { holder.reset(brick) }
                        if let onRemoveBrush { Button("Remove \(brick.name)") { onRemoveBrush(brushLayer.id) } }
                    } else {
                        if let onBrush {
                            Button("Brush \(brick.name) In…") { onBrush(brick, false) }
                            Button("Brush \(brick.name) Away…") { onBrush(brick, true) }
                            Divider()
                        }
                        Button("Reset \(brick.name)") { edits.reset(brick) }
                            .disabled(!edits.hasValues(brick))
                        if !AdjustmentBrick.defaults.contains(brick) {
                            Button("Remove \(brick.name)") { edits.remove(brick) }
                        }
                    }
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 3)
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .fixedSize()
                .accessibilityLabel("\(brick.name) actions")
            }

            if !isCollapsed {
                controls
                    .opacity(enabled.wrappedValue ? 1 : 0.45)
                    .disabled(!enabled.wrappedValue)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isActiveBrush ? Color.orange.opacity(0.7) : Color.clear, lineWidth: 1)
        )
    }

    // MARK: Per-brick controls

    @ViewBuilder
    private var controls: some View {
        switch brick {
        case .whiteBalance:
            // Shown in kelvin like Aperture (a shift from a daylight 5200 K).
            ApertureSlider("Temp", value: $holder.temperature, in: -100...100,
                           format: { "\(Int((5200 + $0 * 25).rounded())) K" })
            ApertureSlider("Tint", value: $holder.tint, in: -100...100,
                           format: { signedReadout($0, decimals: 0) })

        case .exposure:
            ApertureSlider("Exposure", value: $holder.exposure, in: -2...2)
            ApertureSlider("Recovery", value: optional(\.recovery), in: 0...1.5)
            ApertureSlider("Black Point", value: optional(\.blackPoint), in: 0...50,
                           format: { String(format: "%.1f", $0) })
            ApertureSlider("Brightness", value: optional(\.brightness), in: -1...1)

        case .enhance:
            // Aperture reads contrast −1…1 around zero; ALTer stores the
            // multiplier, so the slider shows the offset.
            ApertureSlider("Contrast", value: Binding(
                get: { holder.contrast - 1 }, set: { holder.contrast = 1 + $0 }), in: -1...1)
            ApertureSlider("Definition", value: optional(\.definition), in: 0...1)
            ApertureSlider("Saturation", value: $holder.saturation, in: 0...2, default: 1)
            ApertureSlider("Vibrancy", value: $holder.vibrance, in: -1...1)

        case .highlightsShadows:
            ApertureSlider("Highlights", value: optional(\.highlights), in: 0...1)
            ApertureSlider("Shadows", value: optional(\.shadows), in: -1...1)
            ApertureSlider("Mid Contrast", value: optional(\.midContrast), in: -1...1)

        case .levels:
            LevelsEditor(levels: Binding(
                get: { holder.levels ?? Levels() }, set: { holder.levels = $0 }),
                histogram: histogram)

        case .curves:
            CurvesEditor(curves: Binding(
                get: { holder.curves ?? ToneCurves() }, set: { holder.curves = $0 }),
                histogram: histogram)

        case .color:
            ColorBrick(bands: Binding(
                get: { holder.colorBands ?? AdjustmentBrick.neutralBands },
                set: { holder.colorBands = $0 }))

        case .blackAndWhite:
            ApertureSlider("Red", value: field(\.bwMix, \.red, default: 30), in: -100...200, default: 30,
                           format: { String(format: "%.0f%%", $0) })
            ApertureSlider("Green", value: field(\.bwMix, \.green, default: 59), in: -100...200, default: 59,
                           format: { String(format: "%.0f%%", $0) })
            ApertureSlider("Blue", value: field(\.bwMix, \.blue, default: 11), in: -100...200, default: 11,
                           format: { String(format: "%.0f%%", $0) })

        case .colorMonochrome:
            HStack(spacing: 6) {
                Text("Color")
                    .font(.caption)
                    .frame(width: 78, alignment: .leading)
                ColorPicker("", selection: monochromeColor, supportsOpacity: false)
                    .labelsHidden()
                    .accessibilityLabel("Monochrome color")
                Spacer()
            }
            ApertureSlider("Intensity", value: field(\.monochrome, \.intensity, default: 1), in: 0...1, default: 1)

        case .sepia:
            ApertureSlider("Intensity", value: optional(\.sepia, default: 1), in: 0...1, default: 1)

        case .vignette:
            ApertureSlider("Intensity", value: field(\.vignette, \.intensity, default: 0.7), in: 0...1, default: 0.7)
            ApertureSlider("Radius", value: field(\.vignette, \.radius, default: 1), in: 0...2, default: 1)

        case .devignette:
            ApertureSlider("Intensity", value: field(\.devignette, \.intensity, default: 0.7), in: 0...1, default: 0.7)
            ApertureSlider("Radius", value: field(\.devignette, \.radius, default: 1), in: 0...2, default: 1)

        case .noiseReduction:
            ApertureSlider("Radius", value: field(\.noiseReduction, \.radius, default: 1), in: 0...4, default: 1)
            ApertureSlider("Edge Detail", value: field(\.noiseReduction, \.edgeDetail, default: 1), in: 0...2, default: 1)

        case .sharpen:
            ApertureSlider("Intensity", value: $holder.sharpness, in: 0...1, default: 0.5)

        case .edgeSharpen:
            ApertureSlider("Intensity", value: optional(\.edgeSharpen, default: 0.5), in: 0...1, default: 0.5)

        case .polarize:
            ApertureSlider("Intensity", value: optional(\.polarize, default: 0.5), in: 0...1, default: 0.5)

        case .intensifyContrast:
            ApertureSlider("Intensity", value: optional(\.intensifyContrast, default: 0.5), in: 0...1, default: 0.5)

        case .chromaticAberration:
            ApertureSlider("Red / Cyan", value: field(\.chromaticAberration, \.redCyan, default: 0), in: -1...1)
            ApertureSlider("Blue / Yellow", value: field(\.chromaticAberration, \.blueYellow, default: 0), in: -1...1)
        }
    }

    private func eyedropper(_ kind: ColorPick, _ symbol: String, _ help: String,
                            _ onPick: @escaping (ColorPick) -> Void) -> some View {
        Button {
            onPick(kind)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .padding(3)
                .background(RoundedRectangle(cornerRadius: 4)
                    .fill(activePick == kind ? Color.accentColor.opacity(0.35) : Color.clear))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    // MARK: Auto from the histogram

    /// Where the tones actually start and end (first/last bins with any
    /// real population), as Aperture's Auto Levels found them.
    private func histogramEnds() -> (black: Double, white: Double)? {
        guard let bins = histogram?.luminance, bins.count > 2 else { return nil }
        let threshold = 0.04
        guard let first = bins.firstIndex(where: { $0 > threshold }),
              let last = bins.lastIndex(where: { $0 > threshold }), last > first else { return nil }
        return (Double(first) / Double(bins.count - 1), Double(last + 1) / Double(bins.count - 1))
    }

    private func autoLevels() {
        guard let ends = histogramEnds() else { return }
        var levels = holder.levels ?? Levels()
        levels.rgb.blackSrc = min(ends.black, 0.4)
        levels.rgb.whiteSrc = max(ends.white, 0.6)
        levels.rgb.shadowSrc = (levels.rgb.blackSrc + levels.rgb.midSrc) / 2
        levels.rgb.highlightSrc = (levels.rgb.midSrc + levels.rgb.whiteSrc) / 2
        holder.levels = levels
    }

    private func autoCurves() {
        guard let ends = histogramEnds() else { return }
        var curves = holder.curves ?? ToneCurves()
        let black = min(ends.black, 0.4), white = max(ends.white, 0.6)
        curves.rgb = [
            CurvePoint(x: black + 0.02, y: 0.02),
            CurvePoint(x: white - 0.02, y: 0.98),
        ]
        holder.curves = curves
    }

    // MARK: Binding helpers

    /// An optional Double field shown as a plain slider. Writing never
    /// clears the field — the brick stays on the panel until removed.
    private func optional(_ keyPath: WritableKeyPath<PhotoEdits, Double?>,
                          default fallback: Double = 0) -> Binding<Double> {
        Binding(
            get: { holder[keyPath: keyPath] ?? fallback },
            set: { holder[keyPath: keyPath] = $0 })
    }

    /// A Double inside an optional struct field (vignette.intensity…).
    private func field<S>(_ outer: WritableKeyPath<PhotoEdits, S?>,
                          _ inner: WritableKeyPath<S, Double>,
                          default fallback: Double) -> Binding<Double> {
        Binding(
            get: { holder[keyPath: outer]?[keyPath: inner] ?? fallback },
            set: { holder[keyPath: outer]?[keyPath: inner] = $0 })
    }

    private var monochromeColor: Binding<Color> {
        Binding(
            get: {
                let m = holder.monochrome ?? Monochrome(red: 0.6, green: 0.45, blue: 0.3, intensity: 1)
                return Color(red: m.red, green: m.green, blue: m.blue)
            },
            set: { color in
                guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
                holder.monochrome?.red = Double(rgb.redComponent)
                holder.monochrome?.green = Double(rgb.greenComponent)
                holder.monochrome?.blue = Double(rgb.blueComponent)
            })
    }
}

// MARK: - The slider row

/// A signed slider readout: "+0.25", "-12°". Anything that rounds to zero
/// reads "0" with no sign — never "-0" or "+0".
func signedReadout(_ value: Double, decimals: Int, suffix: String = "") -> String {
    let text = String(format: "%.\(decimals)f", value)
    if Double(text) == 0 { return String(format: "%.\(decimals)f", 0.0) + suffix }
    return (value > 0 ? "+" : "") + text + suffix
}

/// Label · slider · scrubbable number · reset arrow — Aperture's row.
struct ApertureSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var defaultValue: Double = 0
    var format: (Double) -> String = { signedReadout($0, decimals: 2) }

    init(_ label: String, value: Binding<Double>, in range: ClosedRange<Double>,
         default defaultValue: Double = 0, format: ((Double) -> String)? = nil) {
        self.label = label
        self._value = value
        self.range = range
        self.defaultValue = defaultValue
        self.format = format ?? { signedReadout($0, decimals: 2) }
    }

    private var isDefault: Bool { abs(value - defaultValue) < 0.0005 }

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption)
                .frame(width: 78, alignment: .leading)
                .lineLimit(1)
            Slider(value: $value, in: range)
                .controlSize(.small)
                .accessibilityLabel(label)
                .accessibilityValue(format(value))
            ScrubValue(value: value, range: range,
                       perPoint: (range.upperBound - range.lowerBound) / 300,
                       format: format, defaultValue: defaultValue,
                       onChange: { value = $0 })
            Button {
                value = defaultValue
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .opacity(isDefault ? 0.2 : 1)
            .disabled(isDefault)
            .help("Reset \(label)")
            .accessibilityLabel("Reset \(label)")
        }
    }
}
