//
//  HUDHeader.swift
//  Alter
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
//  The title bar every floating HUD shares: an icon, a name, a close
//  button — and the handle you drag the HUD around by, as Aperture's HUDs
//  moved.
//

import SwiftUI

struct HUDHeader: View {
    let title: String
    let systemImage: String
    @Binding var offset: CGSize
    let onClose: () -> Void

    @State private var dragStart: CGSize?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
            Text(title)
                .font(.caption.weight(.semibold))
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close \(title)")
        }
        .foregroundColor(.white.opacity(0.85))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.08))
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { drag in
                    if dragStart == nil { dragStart = offset }
                    guard let start = dragStart else { return }
                    offset = CGSize(width: start.width + drag.translation.width,
                                    height: start.height + drag.translation.height)
                }
                .onEnded { _ in dragStart = nil }
        )
        .onTapGesture(count: 2) { offset = .zero }
        .help("Drag to move — double-click to put it back")
    }
}

/// The panel look every HUD shares.
struct HUDChrome: ViewModifier {
    let width: CGFloat
    func body(content: Content) -> some View {
        content
            .frame(width: width)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.97))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 16, y: 6)
    }
}

extension View {
    func hudChrome(width: CGFloat) -> some View { modifier(HUDChrome(width: width)) }
}
