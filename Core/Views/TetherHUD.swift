//
//  TetherHUD.swift
//  Alter
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//

import SwiftUI

/// Aperture's tether HUD: floating over the library while a tethered
/// session runs — the last shot, the count, Capture, Stop.
struct TetherHUD: View {
    @ObservedObject private var hub = CameraHub.shared

    var body: some View {
        if let session = hub.tether {
            TetherHUDContent(session: session, camera: session.camera)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

private struct TetherHUDContent: View {
    @ObservedObject var session: TetherSession
    @ObservedObject var camera: Camera

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let shot = session.lastShot {
                    Image(nsImage: shot).resizable().scaledToFit()
                } else {
                    Image(systemName: "camera.aperture")
                        .font(.system(size: 24))
                        .foregroundColor(.secondary)
                }
            }
            .frame(width: 72, height: 54)
            .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Circle().fill(Color.red).frame(width: 7, height: 7)
                    Text("Tethered").font(.caption.weight(.semibold))
                }
                Text(camera.name)
                    .font(.callout)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text("\(session.shots) shot\(session.shots == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                    if session.busy { ProgressView().controlSize(.mini) }
                }
            }
            .frame(minWidth: 150, alignment: .leading)

            if camera.canTakePicture {
                Button {
                    session.capture()
                } label: {
                    Label("Capture", systemImage: "camera.shutter.button")
                }
                .controlSize(.large)
                .help("Fire the camera — the shot comes straight in")
            }
            Button("Stop") { CameraHub.shared.stopTether() }
                .help("End the tethered session")
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tethered to \(camera.name), \(session.shots) shots")
    }
}
