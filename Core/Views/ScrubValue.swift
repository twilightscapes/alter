//
//  ScrubValue.swift
//  Alter
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
//  Aperture-style scrubbable value: the number IS a control. Drag it
//  horizontally to change the value, double-click to snap back to the
//  default. Pairs with a slider or stands alone.
//

import AppKit
import SwiftUI

/// A round rotation knob, like every graphics editor: the pointer shows the
/// angle, dragging around the dial turns it — and keeps turning past ±180,
/// accumulating whole revolutions (720° is two laps, not a clamp). Double-
/// click resets to 0.
struct RotationDial: View {
    /// Degrees, clockwise, unbounded.
    let value: Double
    var onBegan: (() -> Void)? = nil
    var onChange: (Double) -> Void

    /// Pointer angle at the previous drag tick — deltas accumulate, so a
    /// wrap past the top never jumps 359° the wrong way.
    @State private var lastAngle: Double?

    private let size: CGFloat = 26

    var body: some View {
        ZStack {
            Circle()
                .fill(Color(nsColor: .controlBackgroundColor))
            Circle()
                .strokeBorder(Color.secondary.opacity(0.45), lineWidth: 1)
            // Tick at 12 o'clock = 0°; SwiftUI's clockwise degrees match the
            // canvas's rotation direction directly.
            Capsule()
                .fill(Color.accentColor)
                .frame(width: 2, height: 9)
                .offset(y: -size / 2 + 6.5)
                .rotationEffect(.degrees(value))
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .onHover { inside in
            if inside { NSCursor.crosshair.push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { drag in
                    let angle = atan2(drag.location.y - size / 2,
                                      drag.location.x - size / 2) * 180 / .pi
                    if lastAngle == nil {
                        onBegan?()
                        lastAngle = angle
                        return
                    }
                    guard let previous = lastAngle else { return }
                    var delta = angle - previous
                    // Shortest way around — crossing the seam is ±small,
                    // never ∓359.
                    if delta > 180 { delta -= 360 } else if delta < -180 { delta += 360 }
                    lastAngle = angle
                    onChange(value + delta)
                }
                .onEnded { _ in lastAngle = nil }
        )
        .onTapGesture(count: 2) {
            onBegan?()
            onChange(0)
        }
        .help("Drag around the dial to rotate — keep going for extra turns; double-click to reset")
    }
}

struct ScrubValue: View {
    let value: Double
    var range: ClosedRange<Double>
    /// Value change per point of horizontal drag.
    var perPoint: Double
    var format: (Double) -> String
    var defaultValue: Double? = nil
    var onBegan: (() -> Void)? = nil
    var onChange: (Double) -> Void

    @State private var startValue: Double?

    var body: some View {
        Text(format(value))
            .font(.caption.monospacedDigit())
            .foregroundColor(.secondary)
            .frame(width: 44, alignment: .trailing)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .highPriorityGesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { drag in
                        if startValue == nil {
                            onBegan?()
                            startValue = value
                        }
                        guard let startValue else { return }
                        let raw = startValue + Double(drag.translation.width) * perPoint
                        onChange(min(max(raw, range.lowerBound), range.upperBound))
                    }
                    .onEnded { _ in startValue = nil }
            )
            .onTapGesture(count: 2) {
                if let defaultValue {
                    onBegan?()
                    onChange(defaultValue)
                }
            }
            .help("Drag to change\(defaultValue != nil ? " — double-click to reset" : "")")
            // Every ScrubValue sits beside a Slider bound to the same value;
            // the slider carries the VoiceOver label, this stays pointer-only.
            .accessibilityHidden(true)
    }
}
