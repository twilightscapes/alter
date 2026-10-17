//
//  AdjustDateSheet.swift
//  Alter
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//

import SwiftUI

/// Aperture's Adjust Date & Time: say when one of the photos was really
/// taken (a camera clock left on the wrong time zone, never set) and every
/// selected photo moves by the same amount, so a shoot keeps its order.
struct AdjustDateSheet: View {
    @EnvironmentObject var store: LibraryStore
    @Environment(\.dismiss) private var dismiss

    @State private var corrected = Date()
    @State private var writeToFiles = false
    @State private var original: Date?

    private var targets: [Int64] { store.commandTargets }
    /// The photo the new time is given for: the first selected, by date.
    private var reference: PhotoItem? {
        targets.compactMap { store.item($0) }.min { $0.date < $1.date }
    }
    private var offset: Double { original.map { corrected.timeIntervalSince($0) } ?? 0 }
    private var writable: Int {
        targets.compactMap { store.item($0) }.filter { !store.isApertureOriginal($0) && !$0.isVersion }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Adjust Date & Time")
                .font(.title3.weight(.semibold))
            if let reference, let original {
                Text("\(targets.count) photo\(targets.count == 1 ? "" : "s") selected. Set when \(reference.filename) was really taken; the others move by the same amount.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow {
                        Text("Recorded").foregroundColor(.secondary)
                        Text(original.formatted(date: .abbreviated, time: .standard))
                    }
                    GridRow {
                        Text("Actually taken").foregroundColor(.secondary)
                        DatePicker("Actually taken", selection: $corrected,
                                   displayedComponents: [.date, .hourAndMinute])
                            .labelsHidden()
                            .datePickerStyle(.field)
                    }
                    GridRow {
                        Text("Change").foregroundColor(.secondary)
                        Text(Self.describe(offset))
                            .monospacedDigit()
                    }
                }
                Toggle("Also change the dates in the original files", isOn: $writeToFiles)
                    .disabled(writable == 0)
                    .help(writable == 0
                          ? "These are in an Aperture library — its originals are never written to"
                          : "Shifts the files' EXIF dates too (\(writable) file\(writable == 1 ? "" : "s")); Aperture originals are left alone")
            } else {
                Text("Select the photos to adjust first.")
                    .foregroundColor(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Adjust") {
                    let ids = targets, seconds = offset, write = writeToFiles
                    dismiss()
                    Task { await store.adjustCaptureDates(ids, by: seconds, writeToFiles: write) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(reference == nil || abs(offset) < 1)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear {
            guard let reference else { return }
            let date = Date(timeIntervalSince1970: reference.date)
            original = date
            corrected = date
        }
    }

    /// "+1 day 2 h 5 min", "−8 h", "no change".
    static func describe(_ seconds: Double) -> String {
        guard abs(seconds) >= 1 else { return "No change" }
        var rest = Int(abs(seconds).rounded())
        let days = rest / 86_400; rest %= 86_400
        let hours = rest / 3600; rest %= 3600
        let minutes = rest / 60; let secs = rest % 60
        var parts: [String] = []
        if days > 0 { parts.append("\(days) day\(days == 1 ? "" : "s")") }
        if hours > 0 { parts.append("\(hours) h") }
        if minutes > 0 { parts.append("\(minutes) min") }
        if secs > 0, days == 0 { parts.append("\(secs) s") }
        return (seconds < 0 ? "−" : "+") + parts.joined(separator: " ") + (seconds < 0 ? " (earlier)" : " (later)")
    }
}
