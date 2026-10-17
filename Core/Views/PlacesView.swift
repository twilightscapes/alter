//
//  PlacesView.swift
//  Alter
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
//  Aperture's Places: photos on a map, gathered into pins that split as
//  you zoom; the browser underneath shows what's in view. Drag photos from
//  the browser onto the map to place them; search for somewhere; lay a
//  GPS track over a shoot.
//

import CoreLocation
import MapKit
import SwiftUI

struct PlacesView: View {
    @EnvironmentObject var store: LibraryStore
    @AppStorage("places.mapType") private var mapTypeRaw = 0
    @State private var searchText = ""
    @State private var searching = false
    @State private var searchFailed = false
    @State private var centerTarget: CLLocationCoordinate2D?
    @State private var centerToken = 0

    private var mapType: MKMapType {
        switch mapTypeRaw {
        case 1: return .hybrid
        case 2: return .satellite
        default: return .standard
        }
    }

    var body: some View {
        VSplitView {
            ZStack(alignment: .top) {
                PhotoMapView(points: store.mapPoints,
                             track: store.mapTrack,
                             mapType: mapType,
                             fitKey: fitKey,
                             centerTarget: centerTarget,
                             centerToken: centerToken,
                             thumbnail: { id in await thumbnail(id) },
                             onRegion: { ids in if store.mapRegionIDs != ids { store.mapRegionIDs = ids } },
                             onPick: { ids in store.selection = Set(ids) },
                             onDrop: { ids, coordinate in place(ids, at: coordinate) })
                controls
                if store.mapPoints.isEmpty {
                    emptyHint
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(minHeight: 220, idealHeight: 460)
            GridView()
                .frame(minHeight: 150)
        }
    }

    /// Fit the map again when the source changes.
    private var fitKey: String { String(describing: store.source) }

    private var controls: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Find a place", text: $searchText)
                    .textFieldStyle(.plain)
                    .frame(width: 170)
                    .onSubmit(search)
                if searching { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor).opacity(0.9)))
            .help(searchFailed ? "Couldn't find that place" : "Type a place and press Return")
            Picker("Map", selection: $mapTypeRaw) {
                Text("Map").tag(0)
                Text("Hybrid").tag(1)
                Text("Satellite").tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer()
            Picker("Show", selection: $store.mapScope) {
                ForEach(MapScope.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("The browser shows photos in view on the map, ones not placed yet (drag them onto the map), or all")
            if store.mapTrack != nil {
                Button("Hide Track") { store.mapTrack = nil }
            }
            Button("Import GPS Track…") { store.presentImportGPSTrackPanel() }
            if store.source != .places {
                Button("Done") { store.toggleMap() }
                    .help("Back to the browser")
            }
        }
        .controlSize(.small)
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .padding(10)
    }

    private var emptyHint: some View {
        VStack(spacing: 6) {
            Text("No photos here have a location yet")
                .font(.headline)
            Text("Choose Not Placed below and drag photos onto the map, or Import GPS Track… to place a whole shoot.")
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(14)
        .frame(maxWidth: 360)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .allowsHitTesting(false)
    }

    private func thumbnail(_ id: Int64) async -> NSImage? {
        guard let url = (store.item(id)?.url) ?? (try? store.catalog?.photoPath(id)).map(URL.init(fileURLWithPath:))
        else { return nil }
        return await ImageLoader.shared.thumbnailAsync(for: url, edits: store.item(id)?.edits ?? PhotoEdits(), maxPixel: 120)
    }

    private func place(_ ids: [Int64], at coordinate: CLLocationCoordinate2D) {
        Task { await store.setGPS(latitude: coordinate.latitude, longitude: coordinate.longitude, for: ids) }
    }

    private func search() {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        searching = true
        searchFailed = false
        CLGeocoder().geocodeAddressString(query) { placemarks, _ in
            DispatchQueue.main.async {
                searching = false
                guard let coordinate = placemarks?.first?.location?.coordinate else {
                    searchFailed = true
                    NSSound.beep()
                    return
                }
                centerTarget = coordinate
                centerToken += 1
            }
        }
    }
}

// MARK: - The map

struct PhotoMapView: NSViewRepresentable {
    let points: [MapPoint]
    let track: [GPXTrack.Point]?
    let mapType: MKMapType
    let fitKey: String
    let centerTarget: CLLocationCoordinate2D?
    let centerToken: Int
    let thumbnail: (Int64) async -> NSImage?
    let onRegion: (Set<Int64>) -> Void
    let onPick: ([Int64]) -> Void
    let onDrop: ([Int64], CLLocationCoordinate2D) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> DropMapView {
        let map = DropMapView()
        map.delegate = context.coordinator
        map.showsZoomControls = true
        map.showsCompass = true
        map.showsScale = true
        map.register(PhotoPinView.self, forAnnotationViewWithReuseIdentifier: PhotoPinView.photoID)
        map.register(PhotoPinView.self, forAnnotationViewWithReuseIdentifier: PhotoPinView.clusterID)
        map.onDrop = { [weak coordinator = context.coordinator] ids, coordinate in
            coordinator?.parent.onDrop(ids, coordinate)
        }
        return map
    }

    func updateNSView(_ map: DropMapView, context: Context) {
        let c = context.coordinator
        c.parent = self
        if map.mapType != mapType { map.mapType = mapType }

        // Pins: add, move, remove — never rebuild (that would flicker).
        let wanted = Dictionary(uniqueKeysWithValues: points.map { ($0.id, $0) })
        var removed: [PhotoAnnotation] = []
        for (id, annotation) in c.annotations where wanted[id] == nil {
            removed.append(annotation)
            c.annotations[id] = nil
        }
        if !removed.isEmpty { map.removeAnnotations(removed) }
        var added: [PhotoAnnotation] = []
        for point in points {
            if let existing = c.annotations[point.id] {
                if existing.coordinate.latitude != point.latitude || existing.coordinate.longitude != point.longitude {
                    // Moving a clustered pin means re-adding it.
                    map.removeAnnotation(existing)
                    existing.coordinate = point.coordinate
                    map.addAnnotation(existing)
                }
            } else {
                let annotation = PhotoAnnotation(photoID: point.id, coordinate: point.coordinate)
                c.annotations[point.id] = annotation
                added.append(annotation)
            }
        }
        if !added.isEmpty { map.addAnnotations(added) }

        // Fit everything when the source changes (or the first pins land).
        if c.fittedKey != fitKey || (c.fittedEmpty && !points.isEmpty) {
            c.fittedKey = fitKey
            c.fittedEmpty = points.isEmpty
            if !points.isEmpty {
                c.fit(map, Array(c.annotations.values))
            }
            // The new area's photos, once the map settles.
            DispatchQueue.main.async { c.reportRegion(map) }
        }

        // The track.
        let trackKey = track.map { "\($0.count)-\($0.first?.time.timeIntervalSince1970 ?? 0)" }
        if c.trackKey != trackKey {
            c.trackKey = trackKey
            map.removeOverlays(map.overlays)
            if let track, !track.isEmpty {
                var coordinates = track.map(\.coordinate)
                let line = MKPolyline(coordinates: &coordinates, count: coordinates.count)
                map.addOverlay(line)
                map.setVisibleMapRect(line.boundingMapRect,
                                      edgePadding: NSEdgeInsets(top: 70, left: 40, bottom: 40, right: 40), animated: true)
            }
        }

        // A place found by search.
        if c.centerToken != centerToken, let target = centerTarget {
            c.centerToken = centerToken
            map.setRegion(MKCoordinateRegion(center: target, latitudinalMeters: 4000, longitudinalMeters: 4000),
                          animated: true)
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: PhotoMapView
        var annotations: [Int64: PhotoAnnotation] = [:]
        var fittedKey: String?
        var fittedEmpty = true
        var trackKey: String?
        var centerToken = 0
        private var images: [Int64: NSImage] = [:]
        private var regionWork: DispatchWorkItem?

        init(_ parent: PhotoMapView) { self.parent = parent }

        func fit(_ map: MKMapView, _ pins: [MKAnnotation]) {
            var rect = MKMapRect.null
            for pin in pins {
                let p = MKMapPoint(pin.coordinate)
                rect = rect.union(MKMapRect(x: p.x, y: p.y, width: 0, height: 0))
            }
            // A single place (or one spot) gets a sensible neighbourhood.
            let minimum = 8000.0 * MKMapPointsPerMeterAtLatitude(pins.first?.coordinate.latitude ?? 0)
            if rect.size.width < minimum { rect = rect.insetBy(dx: -(minimum - rect.size.width) / 2, dy: 0) }
            if rect.size.height < minimum { rect = rect.insetBy(dx: 0, dy: -(minimum - rect.size.height) / 2) }
            map.setVisibleMapRect(rect, edgePadding: NSEdgeInsets(top: 80, left: 50, bottom: 50, right: 50), animated: false)
        }

        func reportRegion(_ map: MKMapView) {
            let visible = map.visibleMapRect
            let ids = Set(annotations.values.filter { visible.contains(MKMapPoint($0.coordinate)) }.map(\.photoID))
            parent.onRegion(ids)
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            regionWork?.cancel()
            let work = DispatchWorkItem { [weak self, weak mapView] in
                guard let self, let mapView else { return }
                self.reportRegion(mapView)
            }
            regionWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            let photoID: Int64?
            let count: Int
            let view: PhotoPinView?
            if let cluster = annotation as? MKClusterAnnotation {
                view = mapView.dequeueReusableAnnotationView(withIdentifier: PhotoPinView.clusterID, for: cluster) as? PhotoPinView
                let members = cluster.memberAnnotations.compactMap { $0 as? PhotoAnnotation }
                photoID = members.first?.photoID
                count = members.count
            } else if let pin = annotation as? PhotoAnnotation {
                view = mapView.dequeueReusableAnnotationView(withIdentifier: PhotoPinView.photoID, for: pin) as? PhotoPinView
                view?.clusteringIdentifier = "photos"
                photoID = pin.photoID
                count = 1
            } else {
                return nil
            }
            guard let view else { return nil }
            view.count = count
            view.shownPhoto = photoID
            if let photoID, let image = images[photoID] {
                view.image = image
            } else if let photoID {
                view.image = nil
                Task { @MainActor [weak self, weak view] in
                    guard let self, let image = await self.parent.thumbnail(photoID) else { return }
                    self.images[photoID] = image
                    if let view, view.shownPhoto == photoID { view.image = image }
                }
            }
            return view
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            defer { if let annotation = view.annotation { mapView.deselectAnnotation(annotation, animated: false) } }
            if let cluster = view.annotation as? MKClusterAnnotation {
                let members = cluster.memberAnnotations.compactMap { $0 as? PhotoAnnotation }
                parent.onPick(members.map(\.photoID))
                // Aperture zoomed into a pin's photos.
                fit(mapView, members)
            } else if let pin = view.annotation as? PhotoAnnotation {
                parent.onPick([pin.photoID])
            }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let line = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
            let renderer = MKPolylineRenderer(polyline: line)
            renderer.strokeColor = .systemOrange
            renderer.lineWidth = 3
            return renderer
        }
    }
}

final class PhotoAnnotation: NSObject, MKAnnotation {
    let photoID: Int64
    @objc dynamic var coordinate: CLLocationCoordinate2D

    init(photoID: Int64, coordinate: CLLocationCoordinate2D) {
        self.photoID = photoID
        self.coordinate = coordinate
    }
}

/// A pin: the photo itself, small, with how many when it's a group.
final class PhotoPinView: MKAnnotationView {
    static let photoID = "photo", clusterID = "cluster"
    private static let side: CGFloat = 46

    var shownPhoto: Int64?
    var count = 1 { didSet { badge.string = count > 1 ? "\(count)" : ""; layoutBadge() } }
    override var image: NSImage? {
        get { picture.contents as? NSImage }
        set { picture.contents = newValue }
    }

    private let picture = CALayer()
    private let badge = CATextLayer()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: Self.side, height: Self.side)
        wantsLayer = true
        collisionMode = .rectangle
        displayPriority = .defaultHigh
        picture.frame = bounds
        picture.cornerRadius = 7
        picture.masksToBounds = true
        picture.contentsGravity = .resizeAspectFill
        picture.backgroundColor = NSColor.darkGray.cgColor
        picture.borderColor = NSColor.white.cgColor
        picture.borderWidth = 2
        layer?.addSublayer(picture)
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.45
        layer?.shadowRadius = 3
        layer?.shadowOffset = CGSize(width: 0, height: -1)
        badge.fontSize = 11
        badge.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        badge.alignmentMode = .center
        badge.foregroundColor = NSColor.white.cgColor
        badge.backgroundColor = NSColor.systemRed.cgColor
        badge.cornerRadius = 8
        badge.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        layer?.addSublayer(badge)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func prepareForReuse() {
        super.prepareForReuse()
        image = nil
        shownPhoto = nil
    }

    private func layoutBadge() {
        guard count > 1 else { badge.isHidden = true; return }
        badge.isHidden = false
        let width = max(16, CGFloat(String(count).count) * 7 + 8)
        badge.frame = CGRect(x: Self.side - width + 6, y: Self.side - 10, width: width, height: 16)
    }
}

/// The map takes photos dropped from the browser: the drop point is
/// where they were taken.
final class DropMapView: MKMapView {
    var onDrop: (([Int64], CLLocationCoordinate2D) -> Void)?

    /// The browser drags photo ids as text ("12,13,14"); SwiftUI may offer
    /// it as UTF-8 or plain text.
    private static let types: [NSPasteboard.PasteboardType] = [.string, NSPasteboard.PasteboardType("public.plain-text")]

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes(Self.types)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes(Self.types)
    }

    private func ids(_ info: NSDraggingInfo) -> [Int64] {
        guard let text = (info.draggingPasteboard.readObjects(forClasses: [NSString.self]) as? [String])?.first
        else { return [] }
        let parts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let ids = parts.compactMap { Int64($0) }
        return ids.count == parts.count ? ids : []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        ids(sender).isEmpty ? [] : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        ids(sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let dropped = ids(sender)
        guard !dropped.isEmpty else { return false }
        let point = convert(sender.draggingLocation, from: nil)
        onDrop?(dropped, convert(point, toCoordinateFrom: self))
        return true
    }
}

// MARK: - Import GPS Track

struct GPSTrackSheet: View {
    @EnvironmentObject var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let track: GPXTrack
    @State private var hours = 0
    @State private var minutes = 0
    @State private var replace = false
    @State private var candidates: [PhotoItem] = []

    private var shift: TimeInterval { TimeInterval(hours * 3600 + minutes * 60) }

    /// Photos the track has a place for, at the chosen shift.
    private var matches: [(id: Int64, latitude: Double, longitude: Double)] {
        candidates.compactMap { item in
            guard let taken = item.captureDate, replace || !item.hasLocation,
                  let spot = track.location(at: Date(timeIntervalSince1970: taken + shift)) else { return nil }
            return (item.id, spot.latitude, spot.longitude)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import GPS Track")
                .font(.headline)
            VStack(alignment: .leading, spacing: 3) {
                Text(track.name).font(.body.weight(.medium))
                if let start = track.start, let end = track.end {
                    Text("\(start.formatted(date: .abbreviated, time: .shortened)) – \(end.formatted(date: .omitted, time: .shortened)), \(track.points.count) points")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
            }
            Text(store.selection.isEmpty
                 ? "Photos in \(sourceName) taken while the track was recording get its location."
                 : "The \(store.selection.count) selected photo\(store.selection.count == 1 ? "" : "s") taken while the track was recording get its location.")
                .font(.callout)
            HStack(spacing: 8) {
                Text("Shift photo times by")
                Stepper("\(hours) h", value: $hours, in: -14...14)
                    .fixedSize()
                Stepper("\(minutes) min", value: $minutes, in: -59...59)
                    .fixedSize()
            }
            Text("If the camera's clock was set to another time zone, or was off, shift by the difference until the right photos match.")
                .font(.caption)
                .foregroundColor(.secondary)
            Toggle("Replace locations photos already have", isOn: $replace)
            HStack {
                Text(matches.isEmpty ? "No photos match the track's times." : "\(matches.count) photo\(matches.count == 1 ? "" : "s") will be placed.")
                    .foregroundColor(matches.isEmpty ? .secondary : .primary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Place Photos") {
                    let chosen = matches
                    store.mapTrack = track.points
                    dismiss()
                    Task { await store.setLocations(chosen) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(matches.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear(perform: load)
    }

    private var sourceName: String {
        switch store.source {
        case .places, .all, nil: return "the library"
        default: return "this view"
        }
    }

    private func load() {
        guard let catalog = store.catalog else { return }
        if !store.selection.isEmpty {
            candidates = store.selection.compactMap { store.item($0) }
        } else {
            candidates = (try? catalog.photos(in: store.source ?? .all)) ?? []
            if case .smartAlbum(let id) = store.source,
               let rules = store.smartAlbums.first(where: { $0.id == id })?.rules {
                candidates = candidates.filter { rules.matches($0) }
            }
        }
    }
}
