//
//  ExifToolService.swift
//  Alter
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
//  All file metadata reads/writes go through exiftool — the only tool with
//  credible coverage of every field across JPEG/PNG/WebP/TIFF/HEIC. Bundled in
//  Resources for release; falls back to a system install during development.
//

import Foundation

enum ExifToolError: LocalizedError {
    case notFound
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "exiftool not found. Install it (brew install exiftool) or bundle it in the app."
        case .failed(let message):
            return message.isEmpty ? "exiftool failed." : message
        }
    }
}

struct ExifToolService {

    /// Bundled copy first (ships in Resources/exiftool with its Perl lib —
    /// no install needed), then common install locations (dev).
    static func executablePath() -> String? {
        if let bundled = Bundle.main.path(forResource: "exiftool", ofType: nil) {
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: bundled, isDirectory: &isDirectory)
            let script = isDirectory.boolValue ? bundled + "/exiftool" : bundled
            if FileManager.default.isExecutableFile(atPath: script) { return script }
        }
        for path in ["/opt/homebrew/bin/exiftool", "/usr/local/bin/exiftool", "/usr/bin/exiftool"] {
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    static var isAvailable: Bool { executablePath() != nil }

    // MARK: - Read

    /// Batch-read metadata for many files in one exiftool invocation.
    static func readBatch(urls: [URL]) async throws -> [URL: PhotoMetadata] {
        guard !urls.isEmpty else { return [:] }
        let args = [
            "-j", "-q", "-m", "-G1",
            "-XMP-iptcCore:AltTextAccessibility",
            "-XMP-dc:Title", "-IPTC:ObjectName",
            "-XMP-dc:Description", "-IPTC:Caption-Abstract",
            "-XMP-dc:Subject", "-IPTC:Keywords",
            "-XMP-dc:Creator", "-IPTC:By-line", "-IFD0:Artist",
            "-XMP-dc:Rights", "-IPTC:CopyrightNotice", "-IFD0:Copyright",
        ] + urls.map { $0.path }

        let output = try await run(arguments: args)
        guard let data = output.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return [:]
        }

        var result: [URL: PhotoMetadata] = [:]
        for entry in array {
            guard let sourceFile = entry["SourceFile"] as? String else { continue }
            let url = URL(fileURLWithPath: sourceFile)

            func str(_ keys: [String]) -> String {
                for key in keys {
                    if let value = entry[key] as? String, !value.isEmpty { return value }
                    if let value = entry[key] as? [String], let first = value.first { return first }
                }
                return ""
            }
            func list(_ keys: [String]) -> [String] {
                for key in keys {
                    if let value = entry[key] as? [String], !value.isEmpty { return value }
                    if let value = entry[key] as? String, !value.isEmpty {
                        return value.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    }
                }
                return []
            }

            var meta = PhotoMetadata()
            meta.altText = str(["XMP-iptcCore:AltTextAccessibility"])
            meta.title = str(["XMP-dc:Title", "IPTC:ObjectName"])
            meta.caption = str(["XMP-dc:Description", "IPTC:Caption-Abstract"])
            meta.keywords = list(["XMP-dc:Subject", "IPTC:Keywords"])
            meta.creator = str(["XMP-dc:Creator", "IPTC:By-line", "IFD0:Artist"])
            meta.copyright = str(["XMP-dc:Rights", "IPTC:CopyrightNotice", "IFD0:Copyright"])
            result[url] = meta
        }
        return result
    }

    // MARK: - Write

    /// Write the edited fields into the file, stamping all relevant groups so
    /// every consumer (CMSes, Lightroom, Finder, screen-reader pipelines) sees
    /// the same values. Formats without IPTC/EXIF (PNG, WebP) still get XMP
    /// thanks to -m (ignore minor errors).
    static func write(metadata: PhotoMetadata, to url: URL) async throws {
        let keywordList = metadata.keywords.joined(separator: ", ")
        let args = [
            "-overwrite_original", "-q", "-m",
            "-codedcharacterset=utf8", "-charset", "iptc=utf8",
            "-sep", ", ",
            "-XMP-iptcCore:AltTextAccessibility=\(metadata.altText)",
            "-XMP-dc:Title=\(metadata.title)",
            "-IPTC:ObjectName=\(metadata.title)",
            "-XMP-dc:Description=\(metadata.caption)",
            "-IPTC:Caption-Abstract=\(metadata.caption)",
            "-XMP-dc:Subject=\(keywordList)",
            "-IPTC:Keywords=\(keywordList)",
            "-XMP-dc:Creator=\(metadata.creator)",
            "-IPTC:By-line=\(metadata.creator)",
            "-IFD0:Artist=\(metadata.creator)",
            "-XMP-dc:Rights=\(metadata.copyright)",
            "-IPTC:CopyrightNotice=\(metadata.copyright)",
            "-IFD0:Copyright=\(metadata.copyright)",
            url.path,
        ]
        _ = try await run(arguments: args)
    }

    /// Write (or overwrite) a photo's GPS location.
    static func writeGPS(latitude: Double, longitude: Double, to url: URL) async throws {
        _ = try await run(arguments: [
            "-overwrite_original", "-q", "-m",
            "-GPSLatitude=\(abs(latitude))",
            "-GPSLatitudeRef=\(latitude >= 0 ? "N" : "S")",
            "-GPSLongitude=\(abs(longitude))",
            "-GPSLongitudeRef=\(longitude >= 0 ? "E" : "W")",
            url.path,
        ])
    }

    /// Move every date in a file (taken, digitised, modified) by `seconds` —
    /// exiftool's date shift: "-AllDates+=0:0:D h:m:s".
    static func shiftDates(by seconds: Double, in url: URL) async throws {
        var rest = Int(abs(seconds).rounded())
        let days = rest / 86_400; rest %= 86_400
        let shift = "0:0:\(days) \(rest / 3600):\(rest % 3600 / 60):\(rest % 60)"
        _ = try await run(arguments: ["-overwrite_original", "-q", "-m",
                                      "-AllDates\(seconds < 0 ? "-" : "+")=\(shift)", url.path])
    }

    /// Strip all GPS data from a photo.
    static func removeGPS(from url: URL) async throws {
        _ = try await run(arguments: ["-overwrite_original", "-q", "-m", "-GPS:all=", url.path])
    }

    /// Copy the camera EXIF block from the original into an export (rendered
    /// files start with none). Optionally drop GPS while doing so.
    static func copyCameraEXIF(from source: URL, to destination: URL, stripGPS: Bool) async throws {
        var args = [
            "-overwrite_original", "-q", "-m",
            "-TagsFromFile", source.path, "-EXIF:all",
        ]
        if stripGPS {
            args.append("-GPS:all=")
        }
        args.append(destination.path)
        _ = try await run(arguments: args)
    }

    // MARK: - Process plumbing

    private static func run(arguments: [String]) async throws -> String {
        guard let tool = executablePath() else { throw ExifToolError.notFound }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: tool)
                process.arguments = arguments

                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: ExifToolError.failed(error.localizedDescription))
                    return
                }

                let outData = stdout.fileHandleForReading.readDataToEndOfFile()
                let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()

                if process.terminationStatus != 0 {
                    let message = String(data: errData, encoding: .utf8) ?? ""
                    continuation.resume(throwing: ExifToolError.failed(message.trimmingCharacters(in: .whitespacesAndNewlines)))
                    return
                }
                continuation.resume(returning: String(data: outData, encoding: .utf8) ?? "")
            }
        }
    }
}
