//
//  ExifReader.swift
//  Alter
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
//  Fast on-device EXIF/GPS reads via ImageIO (no exiftool round-trip needed
//  for display). Writes still go through ExifToolService.
//

import CoreLocation
import Foundation
import ImageIO

struct PhotoExifInfo {
    var camera: String?
    var lens: String?
    var exposure: String?
    var aperture: String?
    var iso: String?
    var focalLength: String?
    var captureDate: String?
    /// The same, as a timestamp (local time when the camera recorded no
    /// offset), for the catalog.
    var captureTimestamp: Double?
    var pixelSize: String?
    var coordinate: CLLocationCoordinate2D?
    // Raw values, for the catalog's EXIF columns (smart albums search these).
    var isoValue: Int?
    var focalValue: Double?
    var apertureValue: Double?
    var shutterSeconds: Double?

    var hasAny: Bool {
        camera != nil || lens != nil || exposure != nil || aperture != nil
            || iso != nil || focalLength != nil || captureDate != nil || pixelSize != nil
    }
}

enum ExifReader {

    /// Header-only check for a GPS block — cheap enough to scan a library.
    static func hasGPS(url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [
            kCGImageSourceShouldCache: false,
        ] as CFDictionary),
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any] else {
            return false
        }
        return gps[kCGImagePropertyGPSLatitude] != nil
    }

    /// Header-only read of where it was taken (nil = no GPS).
    static func location(url: URL) -> CLLocationCoordinate2D? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any],
              let latitude = gps[kCGImagePropertyGPSLatitude] as? Double,
              let longitude = gps[kCGImagePropertyGPSLongitude] as? Double else { return nil }
        let latRef = gps[kCGImagePropertyGPSLatitudeRef] as? String ?? "N"
        let lonRef = gps[kCGImagePropertyGPSLongitudeRef] as? String ?? "E"
        // 0,0 is a camera with no fix writing zeros, not a photo off Ghana.
        guard latitude != 0 || longitude != 0 else { return nil }
        return CLLocationCoordinate2D(latitude: latRef == "S" ? -latitude : latitude,
                                      longitude: lonRef == "W" ? -longitude : longitude)
    }

    static func read(url: URL) -> PhotoExifInfo {
        var info = PhotoExifInfo()
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return info
        }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any]

        if let width = props[kCGImagePropertyPixelWidth] as? Int,
           let height = props[kCGImagePropertyPixelHeight] as? Int {
            info.pixelSize = "\(width) × \(height)"
        }

        let make = (tiff?[kCGImagePropertyTIFFMake] as? String)?.trimmingCharacters(in: .whitespaces)
        let model = (tiff?[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespaces)
        if let model {
            // Some models already embed the make ("Canon EOS R5").
            if let make, !model.localizedCaseInsensitiveContains(make) {
                info.camera = "\(make) \(model)"
            } else {
                info.camera = model
            }
        }

        info.lens = exif?[kCGImagePropertyExifLensModel] as? String

        if let time = exif?[kCGImagePropertyExifExposureTime] as? Double, time > 0 {
            info.shutterSeconds = time
            info.exposure = time >= 1
                ? String(format: "%.1f s", time)
                : "1/\(Int((1 / time).rounded())) s"
        }
        if let fNumber = exif?[kCGImagePropertyExifFNumber] as? Double, fNumber > 0 {
            info.apertureValue = fNumber
            info.aperture = String(format: "ƒ/%.1f", fNumber)
        }
        if let isoValues = exif?[kCGImagePropertyExifISOSpeedRatings] as? [Int], let iso = isoValues.first {
            info.isoValue = iso
            info.iso = "ISO \(iso)"
        }
        if let focal = exif?[kCGImagePropertyExifFocalLength] as? Double, focal > 0 {
            info.focalValue = focal
            info.focalLength = String(format: "%.0f mm", focal)
        }
        if let raw = exif?[kCGImagePropertyExifDateTimeOriginal] as? String {
            info.captureDate = formatCaptureDate(raw)
            info.captureTimestamp = parseCaptureDate(raw, offset: exif?[kCGImagePropertyExifOffsetTimeOriginal] as? String)
        }

        if let latitude = gps?[kCGImagePropertyGPSLatitude] as? Double,
           let longitude = gps?[kCGImagePropertyGPSLongitude] as? Double {
            let latRef = gps?[kCGImagePropertyGPSLatitudeRef] as? String ?? "N"
            let lonRef = gps?[kCGImagePropertyGPSLongitudeRef] as? String ?? "E"
            info.coordinate = CLLocationCoordinate2D(
                latitude: latRef == "S" ? -latitude : latitude,
                longitude: lonRef == "W" ? -longitude : longitude)
        }
        return info
    }

    private static func parseCaptureDate(_ raw: String, offset: String?) -> Double? {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        if let offset, offset.count >= 6 {
            parser.dateFormat = "yyyy:MM:dd HH:mm:ssXXX"
            if let date = parser.date(from: raw + offset) { return date.timeIntervalSince1970 }
        }
        parser.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return parser.date(from: raw)?.timeIntervalSince1970
    }

    private static func formatCaptureDate(_ raw: String) -> String {
        let parser = DateFormatter()
        parser.dateFormat = "yyyy:MM:dd HH:mm:ss"
        guard let date = parser.date(from: raw) else { return raw }
        let out = DateFormatter()
        out.dateStyle = .medium
        out.timeStyle = .short
        return out.string(from: date)
    }
}
