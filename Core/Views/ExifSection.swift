//
//  ExifSection.swift
//  Alter
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
//  EXIF readout + a small GPS map for the Info tab. Reads are instant
//  (ImageIO); editing happens in the popout map editor (LocationSheet).
//

import CoreLocation
import MapKit
import SwiftUI

struct ExifSection: View {
    @EnvironmentObject var store: LibraryStore
    let id: Int64
    let item: PhotoItem

    @State private var info: PhotoExifInfo?
    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 39.5, longitude: -98.35),
        span: MKCoordinateSpan(latitudeDelta: 40, longitudeDelta: 40))
    @State private var isEditorPresented = false
    @State private var refreshToken = 0

    private struct MapPin: Identifiable {
        let id = UUID()
        let coordinate: CLLocationCoordinate2D
    }

    private var pins: [MapPin] {
        guard let coordinate = info?.coordinate else { return [] }
        return [MapPin(coordinate: coordinate)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("EXIF")
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)

            if let info {
                if info.hasAny {
                    exifGrid(info)
                } else {
                    Text("No camera EXIF in this file.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                locationBlock(info)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: "\(item.url.path)#\(refreshToken)#\(item.latitude ?? 0),\(item.longitude ?? 0)") {
            let url = item.url
            var loaded = await Task.detached(priority: .userInitiated) {
                ExifReader.read(url: url)
            }.value
            // The file may carry no EXIF (a TIFF or PSD Aperture managed,
            // a JPEG stripped on the way in) while the catalog knows the
            // camera — from Aperture's database or an earlier read.
            if loaded.camera == nil, !item.camera.isEmpty { loaded.camera = item.camera }
            if loaded.lens == nil, !item.lens.isEmpty { loaded.lens = item.lens }
            if loaded.iso == nil, let iso = item.iso { loaded.iso = "ISO \(iso)" }
            if loaded.focalLength == nil, let focal = item.focalLength { loaded.focalLength = String(format: "%.0f mm", focal) }
            if loaded.aperture == nil, let f = item.aperture { loaded.aperture = String(format: "ƒ/%.1f", f) }
            if loaded.exposure == nil, let t = item.shutter, t > 0 {
                loaded.exposure = t >= 1 ? String(format: "%.1f s", t) : "1/\(Int((1 / t).rounded())) s"
            }
            // Where it was taken is the catalog's call once it has read the
            // file (an Aperture original placed or cleared here keeps its
            // file's GPS untouched).
            if item.gpsRead || item.hasLocation {
                loaded.coordinate = item.latitude.flatMap { lat in
                    item.longitude.map { CLLocationCoordinate2D(latitude: lat, longitude: $0) }
                }
            }
            info = loaded
            if let coordinate = loaded.coordinate {
                region = MKCoordinateRegion(
                    center: coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05))
            }
        }
        .sheet(isPresented: $isEditorPresented) {
            LocationSheet(photoID: id, initialCoordinate: info?.coordinate) {
                refreshToken += 1
            }
        }
    }

    // MARK: - EXIF rows

    @ViewBuilder
    private func exifGrid(_ info: PhotoExifInfo) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            exifRow("Camera", info.camera)
            exifRow("Lens", info.lens)
            exifRow("Exposure", [info.exposure, info.aperture, info.iso, info.focalLength]
                .compactMap { $0 }.joined(separator: " · ").nilIfEmpty)
            // The catalog's date wins: it's the file's EXIF date, or
            // Aperture's, or what Adjust Date & Time set.
            exifRow("Captured", item.captureDate.map {
                Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .shortened)
            } ?? info.captureDate)
            exifRow("Size", info.pixelSize)
        }
        .font(.caption)
    }

    @ViewBuilder
    private func exifRow(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            HStack(alignment: .top, spacing: 6) {
                Text(label)
                    .foregroundColor(.secondary)
                    .frame(width: 60, alignment: .leading)
                Text(value)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: - Location display

    @ViewBuilder
    private func locationBlock(_ info: PhotoExifInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if info.coordinate != nil {
                ZStack {
                    Map(coordinateRegion: $region, annotationItems: pins) { pin in
                        MapMarker(coordinate: pin.coordinate, tint: .red)
                    }
                    .allowsHitTesting(false)   // display only — click opens the editor
                    Color.black.opacity(0.001)
                        .onTapGesture { isEditorPresented = true }
                        .help("Open the map editor")
                }
                .frame(height: 130)
                .cornerRadius(8)
            }

            if info.coordinate != nil, !item.place.isEmpty {
                Label(item.place, systemImage: "mappin.and.ellipse")
                    .font(.callout)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            HStack(spacing: 8) {
                Button(info.coordinate == nil ? "Add Location…" : "Edit Location…") {
                    isEditorPresented = true
                }
                .controlSize(.small)
                if info.coordinate != nil {
                    Button("Remove") {
                        Task {
                            await store.removeGPS(for: id)
                            refreshToken += 1
                        }
                    }
                    .controlSize(.small)
                }
                if let coordinate = info.coordinate {
                    Text(String(format: "%.4f, %.4f", coordinate.latitude, coordinate.longitude))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
