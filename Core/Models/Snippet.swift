//
//  Snippet.swift
//  Alter
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
//  Aperture-style text snippets: reusable, field-aware pieces of metadata you
//  apply to a photo or a whole selection — copyright lines, credits, boilerplate
//  captions. Tokens expand per photo:
//
//      {name}   original filename (no extension)
//      {date}   file date, yyyy-MM-dd
//      {title}  the photo's current Title field
//
//  Stored app-wide as JSON (shareable / backupable via defaults export).
//

import Foundation

struct Snippet: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var field: SnippetField
    var text: String
}

enum SnippetField: String, Codable, CaseIterable, Identifiable {
    case title
    case caption
    case altText
    case keywords
    case creator
    case copyright

    var id: String { rawValue }

    var label: String {
        switch self {
        case .title: return "Title"
        case .caption: return "Caption"
        case .altText: return "ALT Text"
        case .keywords: return "Keywords"
        case .creator: return "Creator"
        case .copyright: return "Copyright"
        }
    }
}

enum Snippets {
    private static let defaultsKey = "alter_snippets"

    static let starters: [Snippet] = [
        Snippet(name: "Copyright line", field: .copyright, text: "© {date} Your Name"),
        Snippet(name: "Credit", field: .creator, text: "Your Name"),
    ]

    static func load() -> [Snippet] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let snippets = try? JSONDecoder().decode([Snippet].self, from: data) else {
            return starters
        }
        return snippets
    }

    static func save(_ snippets: [Snippet]) {
        guard let data = try? JSONEncoder().encode(snippets) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    /// Expand tokens for one photo.
    static func expand(_ text: String, item: PhotoItem) -> String {
        let base = item.url.deletingPathExtension().lastPathComponent
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let attrs = try? FileManager.default.attributesOfItem(atPath: item.url.path)
        let date = formatter.string(from: (attrs?[.modificationDate] as? Date) ?? Date())

        return text
            .replacingOccurrences(of: "{name}", with: base)
            .replacingOccurrences(of: "{date}", with: date)
            .replacingOccurrences(of: "{title}", with: item.metadata.title)
    }
}
