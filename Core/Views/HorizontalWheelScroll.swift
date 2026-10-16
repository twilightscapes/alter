//
//  HorizontalWheelScroll.swift
//  Alter
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
//  A plain mouse wheel over a horizontal ScrollView scrolls it sideways —
//  no shift key needed. Trackpad gestures (which have phases and do
//  horizontal natively) pass through untouched; only phaseless vertical
//  wheel ticks are rewritten onto the horizontal axis, and only while the
//  pointer is over the view.
//

import AppKit
import SwiftUI

private struct HorizontalWheelScroll: ViewModifier {
    @State private var isHovering = false
    @State private var wheelMonitor: Any?

    func body(content: Content) -> some View {
        content
            .onHover { isHovering = $0 }
            .onAppear { installWheelMonitor() }
            .onDisappear {
                if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) }
                wheelMonitor = nil
            }
    }

    private func installWheelMonitor() {
        guard wheelMonitor == nil else { return }
        wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard isHovering,
                  event.phase == [], event.momentumPhase == [],
                  event.modifierFlags.intersection([.option, .command, .shift, .control]).isEmpty,
                  abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX),
                  let cg = event.cgEvent?.copy() else { return event }
            cg.setDoubleValueField(.scrollWheelEventDeltaAxis2,
                                   value: cg.getDoubleValueField(.scrollWheelEventDeltaAxis1))
            cg.setDoubleValueField(.scrollWheelEventDeltaAxis1, value: 0)
            cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis2,
                                   value: cg.getDoubleValueField(.scrollWheelEventPointDeltaAxis1))
            cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: 0)
            return NSEvent(cgEvent: cg) ?? event
        }
    }
}

extension View {
    /// A plain mouse wheel scrolls this horizontal scroller sideways.
    func wheelScrollsHorizontally() -> some View {
        modifier(HorizontalWheelScroll())
    }
}
