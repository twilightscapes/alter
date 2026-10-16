//
//  AutoStackSheet.swift
//  Alter
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
//  Aperture's Auto-Stack HUD: drag the seconds slider and watch how many
//  stacks it would make of the photos shown, then apply.
//

import SwiftUI

struct AutoStackSheet: View {
    @EnvironmentObject var store: LibraryStore
    @Environment(\.dismiss) private var dismiss

    @AppStorage("autoStack.seconds") private var seconds = 15.0

    private var preview: (stacks: Int, photos: Int) { store.autoStackPreview(gapSeconds: seconds) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Auto-Stack")
                .font(.title3.weight(.semibold))
            Text("Photos shot within the interval of each other become a stack; the highest-rated one is the pick.")
                .font(.callout)
                .foregroundColor(.secondary)
            HStack(spacing: 10) {
                Text("0 s").font(.caption).foregroundColor(.secondary)
                Slider(value: $seconds, in: 0...60, step: 1)
                    .accessibilityLabel("Interval in seconds")
                Text("60 s").font(.caption).foregroundColor(.secondary)
            }
            HStack {
                Text("Within \(Int(seconds)) second\(Int(seconds) == 1 ? "" : "s")")
                    .font(.callout.monospacedDigit())
                Spacer()
                let p = preview
                Text(p.stacks == 0 ? "No stacks" : "\(p.stacks) stack\(p.stacks == 1 ? "" : "s") from \(p.photos) photos")
                    .font(.callout.monospacedDigit())
                    .foregroundColor(p.stacks == 0 ? .secondary : .accentColor)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Stack") { store.autoStack(gapSeconds: seconds); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(preview.stacks == 0)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
