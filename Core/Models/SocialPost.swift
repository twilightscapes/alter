//
//  SocialPost.swift
//  Alter
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
//  One outgoing (or already-published) social post. Scheduled posts carry
//  their media pre-rendered in the Outbox, so posting needs nothing but the
//  clock — not even an open library.
//

import Foundation

struct OutboxImage: Codable, Equatable {
    /// Filename inside the post's Outbox folder.
    var file: String
    var alt: String
    var width: Int
    var height: Int
}

struct SocialPost: Identifiable, Codable, Equatable {
    enum Status: String, Codable {
        case scheduled, posted, failed
    }

    var id = UUID()
    var destination = "Bluesky"
    var text: String
    var createdAt = Date()
    var scheduledFor: Date?
    var status: Status = .scheduled
    var postedAt: Date?
    var postURL: String?
    /// at:// URI — the analytics key.
    var atURI: String?
    var error: String?

    // Media: pre-rendered images in the Outbox, or a referenced video file.
    var images: [OutboxImage] = []
    var videoPath: String?
    var videoAlt: String?

    // Analytics snapshot (refreshed from Bluesky).
    var likes: Int?
    var reposts: Int?
    var replies: Int?

    var mediaSummary: String {
        if videoPath != nil { return "Video" }
        return "\(images.count) photo\(images.count == 1 ? "" : "s")"
    }
}
