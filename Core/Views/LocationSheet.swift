//
//  LocationSheet.swift
//  Alter
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
//  The popout map editor: a full MKMapView — click anywhere to drop the pin,
//  switch Standard/Hybrid/Satellite, search for a place, reuse saved
//  locations, and apply to one photo or the whole selection.
//

import CoreLocation
import MapKit
import SwiftUI

// MARK: - MKMapView wrapper (click-to-pin, native zoom controls)

struct MapKitView: NSViewRepresentable {
    @Binding var pin: CLLocationCoordinate2D?
    var mapType: MKMapType
    /// Bump `centerToken` after setting `centerTarget` to recenter the map.
    var centerTarget: CLLocationCoordinate2D?
    var centerToken: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.showsZoomControls = true
        map.showsCompass = true
        let click = NSClickGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.mapClicked(_:)))
        map.addGestureRecognizer(click)
        context.coordinator.mapView = map
        if let start = pin ?? centerTarget {
            map.setRegion(MKCoordinateRegion(
                center: start,
                span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)), animated: false)
        }
        return map
    }

    func updateNSView(_ map: MKMapView, context: Context) {
        context.coordinator.parent = self
        map.mapType = mapType

        // Sync the single pin annotation.
        let existing = map.annotations.compactMap { $0 as? MKPointAnnotation }
        if let pin {
            if let annotation = existing.first {
                if annotation.coordinate.latitude != pin.latitude
                    || annotation.coordinate.longitude != pin.longitude {
                    annotation.coordinate = pin
                }
            } else {
                let annotation = MKPointAnnotation()
                annotation.coordinate = pin
                map.addAnnotation(annotation)
            }
        } else {
            map.removeAnnotations(existing)
        }

        // One-shot recenter requests.
        if context.coordinator.lastCenterToken != centerToken, let target = centerTarget {
            context.coordinator.lastCenterToken = centerToken
            map.setRegion(MKCoordinateRegion(
                center: target,
                span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)), animated: true)
        }
    }

    final class Coordinator: NSObject {
        var parent: MapKitView
        weak var mapView: MKMapView?
        var lastCenterToken = 0

        init(_ parent: MapKitView) {
            self.parent = parent
        }

        @objc func mapClicked(_ gesture: NSClickGestureRecognizer) {
            guard let map = mapView else { return }
            let point = gesture.location(in: map)
            parent.pin = map.convert(point, toCoordinateFrom: map)
        }
    }
}

// MARK: - The sheet

struct LocationSheet: View {
    @EnvironmentObject var store: LibraryStore
    @Environment(\.dismiss) private var dismiss

    let photoID: Int64
    let initialCoordinate: CLLocationCoordinate2D?
    var onSaved: () -> Void

    @State private var pin: CLLocationCoordinate2D?
    @State private var mapType: MKMapType = .standard
    @State private var centerTarget: CLLocationCoordinate2D?
    @State private var centerToken = 0
    @State private var searchText = ""
    @State private var isSearching = false
    @State private var savedLocations: [SavedLocation] = SavedLocations.load()
    @State private var isNamingLocation = false
    @State private var newLocationName = ""
    @State private var isApplying = false

    private var selectionCount: Int { store.selection.count }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                TextField("Search for a place…", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { search() }
                Button("Search") { search() }
                    .disabled(searchText.trimmingCharacters(in: .whitespaces).isEmpty || isSearching)
                if isSearching { ProgressView().controlSize(.small) }

                Picker("", selection: $mapType) {
                    Text("Map").tag(MKMapType.standard)
                    Text("Hybrid").tag(MKMapType.hybrid)
                    Text("Satellite").tag(MKMapType.satellite)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
            }

            MapKitView(pin: $pin, mapType: mapType,
                       centerTarget: centerTarget, centerToken: centerToken)
                .frame(minWidth: 640, minHeight: 420)
                .cornerRadius(8)

            HStack(spacing: 8) {
                Menu {
                    if savedLocations.isEmpty {
                        Text("No saved locations yet")
                    }
                    ForEach(savedLocations) { location in
                        Button(location.name) {
                            pin = location.coordinate
                            recenter(on: location.coordinate)
                        }
                    }
                    Divider()
                    Button("Save Pin as Location…") {
                        newLocationName = ""
                        isNamingLocation = true
                    }
                    .disabled(pin == nil)
                    if !savedLocations.isEmpty {
                        Menu("Delete Saved Location") {
                            ForEach(savedLocations) { location in
                                Button(location.name) {
                                    savedLocations.removeAll { $0.id == location.id }
                                    SavedLocations.save(savedLocations)
                                }
                            }
                        }
                    }
                } label: {
                    Label("Saved Locations", systemImage: "mappin.and.ellipse")
                }
                .fixedSize()

                if let pin {
                    Text(String(format: "%.4f, %.4f", pin.latitude, pin.longitude))
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                } else {
                    Text("Click the map to place the pin")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if selectionCount > 1 {
                    Button("Apply to \(selectionCount) Selected") {
                        apply(to: Array(store.selection))
                    }
                    .disabled(pin == nil || isApplying)
                }
                Button("Apply to This Photo") {
                    apply(to: [photoID])
                }
                .keyboardShortcut(.defaultAction)
                .disabled(pin == nil || isApplying)
            }
        }
        .padding(16)
        .alert("Save Location", isPresented: $isNamingLocation) {
            TextField("Location name", text: $newLocationName)
            Button("Save") {
                guard let pin, !newLocationName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                savedLocations.append(SavedLocation(
                    name: newLocationName.trimmingCharacters(in: .whitespaces),
                    latitude: pin.latitude, longitude: pin.longitude))
                SavedLocations.save(savedLocations)
            }
            Button("Cancel", role: .cancel) {}
        }
        .onAppear {
            pin = initialCoordinate
            if let initialCoordinate {
                recenter(on: initialCoordinate)
            }
        }
    }

    private func recenter(on coordinate: CLLocationCoordinate2D) {
        centerTarget = coordinate
        centerToken += 1
    }

    private func search() {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        isSearching = true
        CLGeocoder().geocodeAddressString(query) { placemarks, _ in
            DispatchQueue.main.async {
                isSearching = false
                guard let coordinate = placemarks?.first?.location?.coordinate else { return }
                pin = coordinate
                recenter(on: coordinate)
            }
        }
    }

    private func apply(to ids: [Int64]) {
        guard let pin else { return }
        isApplying = true
        Task {
            await store.setGPS(latitude: pin.latitude, longitude: pin.longitude, for: ids)
            isApplying = false
            onSaved()
            dismiss()
        }
    }
}
