//
//  WelcomeView.swift
//  Alter
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
//  Shown when no library is open. Libraries are catalogs BESIDE your photos —
//  ALTer never moves, copies, or absorbs originals.
//

import SwiftUI

struct WelcomeView: View {
    @EnvironmentObject var store: LibraryStore

    var body: some View {
        VStack(spacing: 14) {
            VStack(spacing: 2) {
                Text("Alter")
                    .font(.system(size: 40, weight: .heavy))
                Text("Organize · describe · publish")
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 12) {
                Button {
                    store.presentNewLibraryPanel()
                } label: {
                    Label("New Library…", systemImage: "plus.rectangle.on.folder")
                        .frame(minWidth: 160)
                }
                .controlSize(.large)
                .keyboardShortcut("n", modifiers: .command)

                Button {
                    store.presentOpenLibraryPanel()
                } label: {
                    Label("Open Library…", systemImage: "folder")
                        .frame(minWidth: 160)
                }
                .controlSize(.large)
                .keyboardShortcut("o", modifiers: .command)
            }

            Text("Your photos stay exactly where they are.\nAn Alter library only references them — it never moves, copies, or imports your files.")
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 6)

            Text("Version \(AppVersion.display)")
                .font(.caption2.monospacedDigit())
                .foregroundColor(.secondary.opacity(0.7))
                .padding(.top, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
