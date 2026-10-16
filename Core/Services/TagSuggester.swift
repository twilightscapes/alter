//
//  TagSuggester.swift
//  Alter
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
//  Keyword suggestions via Apple's on-device Vision classifier — no network,
//  no API cost, fully private. Gemini stays reserved for alt text.
//

import Foundation
import Vision

enum TagSuggester {

    /// Suggest keywords for a photo, most-confident first.
    static func suggest(for url: URL, limit: Int = 10, excluding existing: [String] = []) async -> [String] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNClassifyImageRequest()
                let handler = VNImageRequestHandler(url: url)
                do {
                    try handler.perform([request])
                } catch {
                    continuation.resume(returning: [])
                    return
                }

                let existingLower = Set(existing.map { $0.lowercased() })
                let tags = (request.results ?? [])
                    .filter { $0.hasMinimumRecall(0.01, forPrecision: 0.85) }
                    .sorted { $0.confidence > $1.confidence }
                    .map { humanize($0.identifier) }
                    .filter { !existingLower.contains($0.lowercased()) }

                // De-dupe while preserving confidence order.
                var seen = Set<String>()
                var unique: [String] = []
                for tag in tags where seen.insert(tag.lowercased()).inserted {
                    unique.append(tag)
                    if unique.count == limit { break }
                }
                continuation.resume(returning: unique)
            }
        }
    }

    private static func humanize(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "_", with: " ")
    }
}
