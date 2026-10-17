//
//  GPXTrack.swift
//  Alter
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
//  Aperture's Import GPS Track: a GPX file from a phone or a logger, and
//  every photo taken while it was recording gets the spot it was taken —
//  matched by time, between the two track points either side of the shot.
//

import CoreLocation
import Foundation

struct GPXTrack {
    struct Point: Equatable {
        let time: Date
        let latitude: Double
        let longitude: Double
        var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
    }

    var name: String
    /// Time-stamped points, oldest first (track points, then route and
    /// way points if that's all the file has).
    var points: [Point]

    var start: Date? { points.first?.time }
    var end: Date? { points.last?.time }

    /// A photo this far outside the track (before its first point, after
    /// its last, or across a gap) isn't placed — the logger wasn't there.
    static let tolerance: TimeInterval = 10 * 60

    enum Failure: LocalizedError {
        case unreadable, noTimes
        var errorDescription: String? {
            switch self {
            case .unreadable: return "That file isn't a GPX track Alter can read."
            case .noTimes: return "The track has no times in it, so photos can't be matched to it."
            }
        }
    }

    static func read(_ url: URL) throws -> GPXTrack {
        guard let parser = XMLParser(contentsOf: url) else { throw Failure.unreadable }
        let reader = Reader()
        parser.delegate = reader
        guard parser.parse() else { throw Failure.unreadable }
        let chosen = !reader.track.isEmpty ? reader.track : (!reader.route.isEmpty ? reader.route : reader.waypoints)
        let points = chosen.sorted { $0.time < $1.time }
        guard !points.isEmpty else { throw reader.sawPoints ? Failure.noTimes : Failure.unreadable }
        return GPXTrack(name: reader.name ?? url.deletingPathExtension().lastPathComponent, points: points)
    }

    /// Where the logger was at `time`: interpolated between the points
    /// either side, nil when it wasn't recording then.
    func location(at time: Date) -> CLLocationCoordinate2D? {
        guard let first = points.first, let last = points.last else { return nil }
        if time <= first.time {
            return first.time.timeIntervalSince(time) <= Self.tolerance ? first.coordinate : nil
        }
        if time >= last.time {
            return time.timeIntervalSince(last.time) <= Self.tolerance ? last.coordinate : nil
        }
        // Binary search for the first point after `time`.
        var low = 0, high = points.count - 1
        while low < high {
            let mid = (low + high) / 2
            if points[mid].time <= time { low = mid + 1 } else { high = mid }
        }
        let after = points[low], before = points[low - 1]
        let gap = after.time.timeIntervalSince(before.time)
        if gap > 2 * Self.tolerance {
            // A long gap (logger off, tunnel): only near either end of it.
            let toBefore = time.timeIntervalSince(before.time), toAfter = after.time.timeIntervalSince(time)
            if min(toBefore, toAfter) > Self.tolerance { return nil }
            return toBefore <= toAfter ? before.coordinate : after.coordinate
        }
        let f = gap > 0 ? time.timeIntervalSince(before.time) / gap : 0
        return CLLocationCoordinate2D(latitude: before.latitude + (after.latitude - before.latitude) * f,
                                      longitude: before.longitude + (after.longitude - before.longitude) * f)
    }

    private final class Reader: NSObject, XMLParserDelegate {
        var track: [Point] = [], route: [Point] = [], waypoints: [Point] = []
        var name: String?
        var sawPoints = false
        private var current: (lat: Double, lon: Double, kind: String)?
        private var text = ""
        private var time: Date?

        private static let formats: [ISO8601DateFormatter] = {
            let plain = ISO8601DateFormatter()
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return [plain, fractional]
        }()

        func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            text = ""
            let local = element.split(separator: ":").last.map(String.init) ?? element
            if ["trkpt", "rtept", "wpt"].contains(local),
               let lat = attributes["lat"].flatMap(Double.init), let lon = attributes["lon"].flatMap(Double.init) {
                current = (lat, lon, local)
                time = nil
                sawPoints = true
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
            let local = element.split(separator: ":").last.map(String.init) ?? element
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch local {
            case "time" where current != nil:
                time = Self.formats.lazy.compactMap { $0.date(from: value) }.first
            case "name" where current == nil && name == nil && !value.isEmpty:
                name = value
            case "trkpt", "rtept", "wpt":
                if let point = current, let time {
                    let made = Point(time: time, latitude: point.lat, longitude: point.lon)
                    switch point.kind {
                    case "trkpt": track.append(made)
                    case "rtept": route.append(made)
                    default: waypoints.append(made)
                    }
                }
                current = nil
            default:
                break
            }
            text = ""
        }
    }
}
