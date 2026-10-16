//
//  LiftStampHUD.swift
//  Alter
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
//  Aperture's Lift & Stamp HUD (O): lift adjustments and metadata from
//  one photo, tick what should travel, stamp it onto the selection.
//

import SwiftUI

struct LiftStampHUD: View {
    @EnvironmentObject var store: LibraryStore
    @State private var offset: CGSize = .zero

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HUDHeader(title: "Lift & Stamp", systemImage: "arrow.up.doc.on.clipboard", offset: $offset) {
                store.isLiftStampVisible = false
            }
            .padding(.horizontal, -12)
            .padding(.top, -12)

            if let lifted = store.lifted {
                Text("Lifted from \(lifted.filename)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text("Nothing lifted yet — select a photo and click Lift.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider()

            Group {
                Toggle("Adjustments", isOn: $store.stampOptions.adjustments)
                Toggle("Crop, straighten, rotation, flip", isOn: $store.stampOptions.geometry)
                Toggle("Retouch, red eye, brushes", isOn: $store.stampOptions.retouchAndBrushes)
                HStack {
                    Toggle("Keywords", isOn: $store.stampOptions.keywords)
                    Spacer()
                    Picker("", selection: $store.stampOptions.replaceKeywords) {
                        Text("Add").tag(false)
                        Text("Replace").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 120)
                    .labelsHidden()
                    .disabled(!store.stampOptions.keywords)
                }
                Toggle("Rating", isOn: $store.stampOptions.rating)
                Toggle("Colour label", isOn: $store.stampOptions.label)
                Toggle("Flag", isOn: $store.stampOptions.flag)
                Toggle("Title, caption, creator, copyright", isOn: $store.stampOptions.info)
            }
            .toggleStyle(.checkbox)
            .font(.caption)

            Divider()

            HStack {
                Button("Lift") { store.lift() }
                    .disabled(store.commandTargets.count != 1)
                    .help("Lift from the selected photo (⇧⌘C)")
                Spacer()
                Button("Stamp Selected") { store.stamp() }
                    .disabled(store.lifted == nil || store.commandTargets.isEmpty)
                    .keyboardShortcut(.defaultAction)
                    .help("Stamp onto the selection (⇧⌘V)")
            }
            .controlSize(.small)
        }
        .padding(12)
        .hudChrome(width: 300)
        .offset(offset)
    }
}
