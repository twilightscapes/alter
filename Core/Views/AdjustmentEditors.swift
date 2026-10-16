//
//  AdjustmentEditors.swift
//  Alter
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
//  The bricks that aren't just sliders: Levels (handles under a histogram),
//  Curves (a draggable curve over the histogram, per channel) and Color
//  (six hue buttons, then Hue / Saturation / Luminance / Range for the one
//  picked) — each as Aperture laid them out.
//

import SwiftUI

// MARK: - Shared

enum ToneChannel: String, CaseIterable, Identifiable {
    case rgb = "RGB", red = "Red", green = "Green", blue = "Blue"
    var id: String { rawValue }

    var tint: Color {
        switch self {
        case .rgb: return .white
        case .red: return Color(red: 0.95, green: 0.3, blue: 0.3)
        case .green: return Color(red: 0.3, green: 0.85, blue: 0.4)
        case .blue: return Color(red: 0.4, green: 0.55, blue: 1)
        }
    }

    func bins(_ histogram: HistogramData?) -> [Double] {
        guard let histogram else { return [] }
        switch self {
        case .rgb: return histogram.luminance
        case .red: return histogram.red
        case .green: return histogram.green
        case .blue: return histogram.blue
        }
    }
}

/// Histogram bars filling a rect, the way Aperture draws them behind
/// Levels and Curves.
private func drawHistogram(_ bins: [Double], in rect: CGRect, context: inout GraphicsContext,
                           color: Color) {
    guard bins.count > 1 else { return }
    var path = Path()
    path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
    for (i, v) in bins.enumerated() {
        let x = rect.minX + rect.width * CGFloat(i) / CGFloat(bins.count - 1)
        path.addLine(to: CGPoint(x: x, y: rect.maxY - rect.height * CGFloat(min(1, v))))
    }
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
    path.closeSubpath()
    context.fill(path, with: .color(color))
}

private func channelPicker(_ channel: Binding<ToneChannel>) -> some View {
    Picker("Channel", selection: channel) {
        ForEach(ToneChannel.allCases) { Text($0.rawValue).tag($0) }
    }
    .pickerStyle(.segmented)
    .controlSize(.small)
    .labelsHidden()
    .accessibilityLabel("Channel")
}

// MARK: - Levels

/// Black · gray · white input handles under the histogram, output black
/// and white above it. The quarter-tone points follow the three handles.
struct LevelsEditor: View {
    @Binding var levels: Levels
    let histogram: HistogramData?

    @State private var channel: ToneChannel = .rgb
    @State private var dragging: Handle?

    private enum Handle { case black, mid, white, outBlack, outWhite }

    private let plotHeight: CGFloat = 70
    private let handleBand: CGFloat = 12

    private var current: Binding<LevelsChannel> {
        Binding(
            get: {
                switch channel {
                case .rgb: return levels.rgb
                case .red: return levels.red ?? LevelsChannel()
                case .green: return levels.green ?? LevelsChannel()
                case .blue: return levels.blue ?? LevelsChannel()
                }
            },
            set: { value in
                switch channel {
                case .rgb: levels.rgb = value
                case .red: levels.red = value.isIdentity ? nil : value
                case .green: levels.green = value.isIdentity ? nil : value
                case .blue: levels.blue = value.isIdentity ? nil : value
                }
            })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            channelPicker($channel)
            GeometryReader { geo in
                let width = geo.size.width
                Canvas { context, size in
                    let plot = CGRect(x: 0, y: handleBand, width: size.width, height: plotHeight)
                    context.fill(Path(roundedRect: plot, cornerRadius: 4), with: .color(.black.opacity(0.85)))
                    drawHistogram(channel.bins(histogram), in: plot.insetBy(dx: 0, dy: 2),
                                  context: &context, color: channel.tint.opacity(0.55))
                    let c = current.wrappedValue
                    // Output range above the plot.
                    drawSquare(&context, x: plot.minX + plot.width * CGFloat(c.blackDst), y: handleBand / 2, fill: .black)
                    drawSquare(&context, x: plot.minX + plot.width * CGFloat(c.whiteDst), y: handleBand / 2, fill: .white)
                    // Input handles below.
                    let hy = plot.maxY + handleBand / 2
                    drawTriangle(&context, x: plot.minX + plot.width * CGFloat(c.blackSrc), y: hy, fill: .black)
                    drawTriangle(&context, x: plot.minX + plot.width * CGFloat(c.midSrc), y: hy, fill: Color(white: 0.5))
                    drawTriangle(&context, x: plot.minX + plot.width * CGFloat(c.whiteSrc), y: hy, fill: .white)
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            let x = min(max(drag.location.x / width, 0), 1)
                            if dragging == nil {
                                dragging = nearestHandle(at: drag.startLocation, width: width)
                            }
                            guard let dragging else { return }
                            move(dragging, to: Double(x))
                        }
                        .onEnded { _ in dragging = nil }
                )
            }
            .frame(height: plotHeight + handleBand * 2)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Levels")
            .accessibilityValue(String(format: "black %.2f, gray %.2f, white %.2f",
                                       current.wrappedValue.blackSrc, current.wrappedValue.midSrc,
                                       current.wrappedValue.whiteSrc))

            HStack {
                Text("Drag the handles: black · gray · white below, output range above")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
                Button("Reset") { current.wrappedValue = LevelsChannel() }
                    .controlSize(.small)
                    .disabled(current.wrappedValue.isIdentity)
            }
        }
    }

    private func nearestHandle(at point: CGPoint, width: CGFloat) -> Handle? {
        let c = current.wrappedValue
        let top = point.y < handleBand + plotHeight / 2
        let candidates: [(Handle, Double)] = top
            ? [(.outBlack, c.blackDst), (.outWhite, c.whiteDst)]
            : [(.black, c.blackSrc), (.mid, c.midSrc), (.white, c.whiteSrc)]
        let x = Double(point.x / width)
        return candidates.min { abs($0.1 - x) < abs($1.1 - x) }?.0
    }

    /// Moves one handle, keeps the order, and lets the gray handle ride
    /// between black and white the way Aperture's does.
    private func move(_ handle: Handle, to x: Double) {
        var c = current.wrappedValue
        let gap = 0.02
        let midFraction = (c.midSrc - c.blackSrc) / max(gap, c.whiteSrc - c.blackSrc)
        switch handle {
        case .black:
            c.blackSrc = min(x, c.whiteSrc - gap)
            c.midSrc = c.blackSrc + (c.whiteSrc - c.blackSrc) * midFraction
        case .white:
            c.whiteSrc = max(x, c.blackSrc + gap)
            c.midSrc = c.blackSrc + (c.whiteSrc - c.blackSrc) * midFraction
        case .mid:
            c.midSrc = min(max(x, c.blackSrc + gap / 2), c.whiteSrc - gap / 2)
        case .outBlack:
            c.blackDst = min(x, c.whiteDst - gap)
        case .outWhite:
            c.whiteDst = max(x, c.blackDst + gap)
        }
        // Quarter tones follow the three handles.
        c.shadowSrc = (c.blackSrc + c.midSrc) / 2
        c.highlightSrc = (c.midSrc + c.whiteSrc) / 2
        c.midDst = (c.blackDst + c.whiteDst) / 2
        c.shadowDst = (c.blackDst + c.midDst) / 2
        c.highlightDst = (c.midDst + c.whiteDst) / 2
        current.wrappedValue = c
    }

    private func drawTriangle(_ context: inout GraphicsContext, x: CGFloat, y: CGFloat, fill: Color) {
        var path = Path()
        path.move(to: CGPoint(x: x, y: y - 5))
        path.addLine(to: CGPoint(x: x + 5, y: y + 4))
        path.addLine(to: CGPoint(x: x - 5, y: y + 4))
        path.closeSubpath()
        context.fill(path, with: .color(fill))
        context.stroke(path, with: .color(.secondary), lineWidth: 0.8)
    }

    private func drawSquare(_ context: inout GraphicsContext, x: CGFloat, y: CGFloat, fill: Color) {
        let rect = CGRect(x: x - 4, y: y - 4, width: 8, height: 8)
        context.fill(Path(rect), with: .color(fill))
        context.stroke(Path(rect), with: .color(.secondary), lineWidth: 0.8)
    }
}

// MARK: - Curves

/// A square plot over the histogram. Drag a point to move it, click empty
/// curve to add one, drag a point off the plot to remove it, double-click
/// to reset the channel.
struct CurvesEditor: View {
    @Binding var curves: ToneCurves
    let histogram: HistogramData?

    @State private var channel: ToneChannel = .rgb
    @State private var dragging: Int?
    @State private var removing = false

    private var points: Binding<[CurvePoint]> {
        Binding(
            get: {
                switch channel {
                case .rgb: return curves.rgb
                case .red: return curves.red
                case .green: return curves.green
                case .blue: return curves.blue
                }
            },
            set: { value in
                switch channel {
                case .rgb: curves.rgb = value
                case .red: curves.red = value
                case .green: curves.green = value
                case .blue: curves.blue = value
                }
            })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            channelPicker($channel)
            GeometryReader { geo in
                let side = geo.size.width
                Canvas { context, size in
                    let plot = CGRect(origin: .zero, size: size)
                    context.fill(Path(roundedRect: plot, cornerRadius: 4), with: .color(.black.opacity(0.85)))
                    drawHistogram(channel.bins(histogram), in: plot.insetBy(dx: 1, dy: 1),
                                  context: &context, color: channel.tint.opacity(0.3))
                    // Quarter grid and the identity diagonal.
                    var grid = Path()
                    for i in 1..<4 {
                        let t = size.width * CGFloat(i) / 4
                        grid.move(to: CGPoint(x: t, y: 0)); grid.addLine(to: CGPoint(x: t, y: size.height))
                        grid.move(to: CGPoint(x: 0, y: t)); grid.addLine(to: CGPoint(x: size.width, y: t))
                    }
                    context.stroke(grid, with: .color(.white.opacity(0.1)), lineWidth: 1)
                    var diagonal = Path()
                    diagonal.move(to: CGPoint(x: 0, y: size.height))
                    diagonal.addLine(to: CGPoint(x: size.width, y: 0))
                    context.stroke(diagonal, with: .color(.white.opacity(0.18)), lineWidth: 1)

                    // The curve itself, same interpolation the renderer uses.
                    let f = EditRenderer.monotoneCurve(points.wrappedValue)
                    var curve = Path()
                    for i in 0...64 {
                        let x = Double(i) / 64
                        let p = CGPoint(x: size.width * CGFloat(x), y: size.height * CGFloat(1 - f(x)))
                        if i == 0 { curve.move(to: p) } else { curve.addLine(to: p) }
                    }
                    context.stroke(curve, with: .color(channel.tint), lineWidth: 1.5)

                    for (i, point) in points.wrappedValue.enumerated() {
                        let center = CGPoint(x: size.width * CGFloat(point.x),
                                             y: size.height * CGFloat(1 - point.y))
                        let dot = Path(ellipseIn: CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8))
                        context.fill(dot, with: .color(i == dragging && removing ? .red : channel.tint))
                        context.stroke(dot, with: .color(.black.opacity(0.6)), lineWidth: 1)
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            if dragging == nil {
                                beginDrag(at: drag.startLocation, side: side)
                            }
                            guard let index = dragging, points.wrappedValue.indices.contains(index) else { return }
                            // Off the plot by a margin = remove on release.
                            removing = drag.location.y < -24 || drag.location.y > side + 24
                                || drag.location.x < -24 || drag.location.x > side + 24
                            var pts = points.wrappedValue
                            // An end point (imported from Aperture: a lifted
                            // black or moved white) slides up and down only;
                            // moving it inward would turn it into a mid point.
                            let isEnd = pts[index].x <= 0.0001 || pts[index].x >= 0.9999
                            if !isEnd {
                                let lo = index > 0 ? pts[index - 1].x + 0.01 : 0.005
                                let hi = index < pts.count - 1 ? pts[index + 1].x - 0.01 : 0.995
                                pts[index].x = min(max(Double(drag.location.x / side), lo), hi)
                            }
                            pts[index].y = min(max(1 - Double(drag.location.y / side), 0), 1)
                            points.wrappedValue = pts
                        }
                        .onEnded { _ in
                            if removing, let index = dragging, points.wrappedValue.indices.contains(index) {
                                var pts = points.wrappedValue
                                pts.remove(at: index)
                                points.wrappedValue = pts
                            }
                            dragging = nil
                            removing = false
                        }
                )
                .onTapGesture(count: 2) { points.wrappedValue = [] }
            }
            .aspectRatio(1, contentMode: .fit)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(channel.rawValue) curve")
            .accessibilityValue(points.wrappedValue.isEmpty ? "straight"
                                : "\(points.wrappedValue.count) control point\(points.wrappedValue.count == 1 ? "" : "s")")

            HStack {
                Text("Click the curve to add a point, drag to shape, drag off to remove")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
                Button("Reset") { points.wrappedValue = [] }
                    .controlSize(.small)
                    .disabled(points.wrappedValue.isEmpty)
            }
        }
    }

    /// Grab the point under the pointer, or add one where the pointer is.
    private func beginDrag(at location: CGPoint, side: CGFloat) {
        var pts = points.wrappedValue
        let x = Double(location.x / side), y = 1 - Double(location.y / side)
        if let nearest = pts.indices.min(by: { distance(pts[$0], x, y, side) < distance(pts[$1], x, y, side) }),
           distance(pts[nearest], x, y, side) < 10 {
            dragging = nearest
            return
        }
        let clampedX = min(max(x, 0.005), 0.995)
        let point = CurvePoint(x: clampedX, y: min(max(y, 0), 1))
        pts.append(point)
        pts.sort { $0.x < $1.x }
        points.wrappedValue = pts
        dragging = pts.firstIndex(of: point)
    }

    private func distance(_ p: CurvePoint, _ x: Double, _ y: Double, _ side: CGFloat) -> CGFloat {
        hypot(CGFloat(p.x - x) * side, CGFloat(p.y - y) * side)
    }
}

// MARK: - Color

/// Six hue buttons, then Hue / Saturation / Luminance / Range for the band
/// that's picked.
struct ColorBrick: View {
    @Binding var bands: [ColorBand]
    @State private var selected = 0

    private static let names = ["Reds", "Yellows", "Greens", "Cyans", "Blues", "Magentas"]

    private var band: Binding<ColorBand> {
        Binding(
            get: { bands.indices.contains(selected) ? bands[selected] : ColorBand(hueBase: 0) },
            set: { if bands.indices.contains(selected) { bands[selected] = $0 } })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ForEach(Array(bands.prefix(6).enumerated()), id: \.offset) { index, b in
                    Button {
                        selected = index
                    } label: {
                        Circle()
                            .fill(Color(hue: b.hueBase / 360, saturation: 0.85, brightness: 0.95))
                            .frame(width: 16, height: 16)
                            .overlay(Circle().strokeBorder(
                                selected == index ? Color.primary : Color.black.opacity(0.3),
                                lineWidth: selected == index ? 2 : 1))
                            .overlay(alignment: .bottomTrailing) {
                                if !b.isNeutral {
                                    Circle().fill(Color.accentColor).frame(width: 5, height: 5)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .help(Self.names[min(index, 5)])
                    .accessibilityLabel(Self.names[min(index, 5)])
                    .accessibilityAddTraits(selected == index ? .isSelected : [])
                }
                Spacer()
                Text(Self.names[min(selected, 5)])
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
            }
            ApertureSlider("Hue", value: band.hueShift, in: -180...180,
                           format: { signedReadout($0, decimals: 0, suffix: "°") })
            ApertureSlider("Saturation", value: band.saturation, in: -100...100,
                           format: { signedReadout($0, decimals: 0) })
            ApertureSlider("Luminance", value: band.luminance, in: -100...100,
                           format: { signedReadout($0, decimals: 0) })
            ApertureSlider("Range", value: band.spread, in: 0.2...3, default: 1,
                           format: { String(format: "%.2f", $0) })
        }
    }
}
