//
//  PlayerLayerView.swift
//  Alter
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//

import AVFoundation
import AppKit
import SwiftUI

// MARK: - Player layer host

/// AVPlayerLayer without AVKit chrome — the timeline's transport drives it,
/// and layer overlays sit cleanly on top.
struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    final class HostView: NSView {
        let playerLayer = AVPlayerLayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            playerLayer.videoGravity = .resizeAspect
            layer?.addSublayer(playerLayer)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.frame = bounds
            CATransaction.commit()
        }
    }

    func makeNSView(context: Context) -> HostView {
        let view = HostView(frame: .zero)
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ view: HostView, context: Context) {
        if view.playerLayer.player !== player {
            view.playerLayer.player = player
        }
    }
}
