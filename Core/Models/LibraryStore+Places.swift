//
//  LibraryStore+Places.swift
//  Alter
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
//  Places: the map over the browser. Pins are every placed photo in the
//  current source; the grid under the map shows what's in view (or what
//  isn't placed yet, ready to drag on).
//

import AppKit
import CoreLocation
import UniformTypeIdentifiers

/// A placed photo, for the map.
struct MapPoint: Identifiable, Equatable {
    let id: Int64
    let latitude: Double
    let longitude: Double
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}

/// What the grid under the map shows.
enum MapScope: String, CaseIterable, Identifiable {
    case inView, notPlaced, all
    var id: String { rawValue }
    var label: String {
        switch self {
        case .inView: return "In View"
        case .notPlaced: return "Not Placed"
        case .all: return "All"
        }
    }
}

/// A track waiting in the Import GPS Track sheet.
struct PendingTrack: Identifiable {
    let id = UUID()
    let track: GPXTrack
}

extension LibraryStore {
    /// File ▸ Import ▸ GPS Track…: pick a GPX file, then the sheet.
    func presentImportGPSTrackPanel() {
        let panel = NSOpenPanel()
        panel.title = "Import GPS Track"
        panel.message = "Choose a GPX file from a phone or GPS logger. Photos taken while it was recording get its locations."
        panel.allowedContentTypes = [UTType(filenameExtension: "gpx") ?? .xml]
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do {
                self.pendingTrack = PendingTrack(track: try GPXTrack.read(url))
            } catch {
                self.alertMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    /// The map is showing (the Places source, or Map turned on for another).
    var showsMap: Bool { source == .places || mapMode }

    /// Pins from the filtered items; the grid narrowed to the map's scope.
    func applyMap() {
        guard showsMap else {
            if !mapPoints.isEmpty { mapPoints = [] }
            return
        }
        let points = items.compactMap { item -> MapPoint? in
            guard let lat = item.latitude, let lon = item.longitude else { return nil }
            return MapPoint(id: item.id, latitude: lat, longitude: lon)
        }
        if points != mapPoints { mapPoints = points }
        switch mapScope {
        case .inView:
            if let visible = mapRegionIDs {
                items = items.filter { visible.contains($0.id) }
            } else {
                items = items.filter(\.hasLocation)
            }
        case .notPlaced:
            items = items.filter { !$0.hasLocation }
        case .all:
            break
        }
    }

    /// Map on/off for the current source (Places is always a map).
    func toggleMap() {
        if source == .places {
            source = .all
            mapMode = false
        } else {
            if !mapMode { mapScope = .all }
            mapMode.toggle()
        }
    }

    /// Keep the loaded item in step with a location change.
    func noteLocation(_ latitude: Double?, _ longitude: Double?, for id: Int64) {
        let master = item(id)?.versionOf ?? id
        for index in items.indices where items[index].id == master || items[index].versionOf == master {
            items[index].latitude = latitude
            items[index].longitude = longitude
            items[index].gpsRead = true
        }
    }

    /// Fill the catalog's locations: Aperture's (once), then each file's
    /// own GPS. Header reads only; files not on this Mac are left for later.
    func backfillLocationsIfNeeded() {
        guard let catalog, !locationBackfillRunning else { return }
        locationBackfillRunning = true
        let fromAperture = (try? catalog.backfillApertureLocations()) ?? false
        Task { [weak self] in
            defer { self?.locationBackfillRunning = false }
            var changed = fromAperture
            while true {
                guard let pending = try? catalog.photosNeedingGPS(limit: 200), !pending.isEmpty else { break }
                let read: [(Int64, CLLocationCoordinate2D?, Bool)] = await Task.detached(priority: .utility) {
                    pending.map { entry in
                        if !FileManager.default.fileExists(atPath: entry.url.path) || FileLocality.needsDownload(entry.url) {
                            // Looked at, nothing learned; the file can still be
                            // placed by hand (or by a track).
                            return (entry.id, nil, false)
                        }
                        return (entry.id, ExifReader.location(url: entry.url), true)
                    }
                }.value
                guard let self, self.catalog === catalog else { return }
                for (id, coordinate, _) in read {
                    try? catalog.noteFileGPS(photoID: id, latitude: coordinate?.latitude, longitude: coordinate?.longitude)
                    if coordinate != nil { changed = true }
                }
                if pending.count < 200 { break }
            }
            if changed { self?.reloadItems() }
            self?.lookUpPlaceNamesIfNeeded()
        }
    }

    // MARK: Place names

    /// Settings ▸ Places: look up names for where photos were taken.
    static let placeNamesKey = "places.lookUpNames"
    var looksUpPlaceNames: Bool {
        UserDefaults.standard.object(forKey: Self.placeNamesKey) as? Bool ?? true
    }

    /// Name every placed ~1 km cell that hasn't been named, through Apple's
    /// geocoder — slowly (it allows about one request a second), most-used
    /// cells first. Offline or throttled: stop, and pick up next time.
    func lookUpPlaceNamesIfNeeded() {
        guard looksUpPlaceNames, placeNameTask == nil, let catalog else { return }
        placeNameTask = Task { [weak self] in
            let geocoder = CLGeocoder()
            var failures = 0
            outer: while !Task.isCancelled {
                guard let cells = try? catalog.placeCellsNeedingNames(limit: 20), !cells.isEmpty else { break }
                var named = 0
                for cell in cells {
                    guard !Task.isCancelled, let self, self.catalog === catalog else { break outer }
                    do {
                        let marks = try await geocoder.reverseGeocodeLocation(
                            CLLocation(latitude: cell.latitude, longitude: cell.longitude))
                        try? catalog.savePlaceName(Self.placeName(marks.first), forCell: cell.key)
                        named += 1
                        failures = 0
                    } catch let error as CLError where error.code == .geocodeFoundNoResult {
                        // Nothing there to name (open sea); don't ask again.
                        try? catalog.savePlaceName("", forCell: cell.key)
                    } catch {
                        failures += 1
                        if failures >= 3 { break outer }
                        try? await Task.sleep(nanoseconds: 30_000_000_000)
                        continue
                    }
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                }
                if named > 0 { self?.reloadItems() }
            }
            self?.placeNameTask = nil
        }
    }

    /// Settings ▸ Places ▸ Look Up Again.
    func relookUpPlaceNames() {
        placeNameTask?.cancel()
        placeNameTask = nil
        try? catalog?.clearPlaceNames()
        reloadItems()
        lookUpPlaceNamesIfNeeded()
    }

    /// "Fort Worth, TX, United States" — city, state or region, country;
    /// a sea or lake when there's no land.
    nonisolated static func placeName(_ mark: CLPlacemark?) -> String {
        guard let mark else { return "" }
        var parts: [String] = []
        if let city = mark.locality ?? mark.subAdministrativeArea { parts.append(city) }
        if let region = mark.administrativeArea, !parts.contains(region) { parts.append(region) }
        if let country = mark.country { parts.append(country) }
        if parts.isEmpty, let water = mark.ocean ?? mark.inlandWater ?? mark.name { parts.append(water) }
        return parts.joined(separator: ", ")
    }
}
