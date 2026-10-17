//
//  FileAccess.swift
//  Alter
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
//  What Alter has been allowed to read. A sandboxed Mac app (the App Store
//  edition) may only open what the person handed it — through an Open
//  panel, a drop — and forgets that at quit unless it kept a
//  security-scoped bookmark. This keeps one for every library, folder,
//  file and destination that came in that way, and opens them all again
//  at launch. Outside the sandbox it's the same code and simply never
//  matters.
//

import AppKit
import Foundation

@MainActor
final class FileAccess: ObservableObject {
    static let shared = FileAccess()

    /// The person's real home folder — inside the sandbox the usual APIs
    /// answer with the app's container instead.
    nonisolated static var realHome: URL {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// `~/…` for showing a path.
    nonisolated static func displayPath(_ path: String) -> String {
        let home = realHome.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// Running in the App Sandbox (the App Store build).
    nonisolated static var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    /// Granted locations by path (folders and files), bookmark data.
    @Published private(set) var grants: [String: Data] = [:]
    /// Locations whose access is open right now.
    private var open: [String: URL] = [:]
    private static let key = "alter.fileAccess"

    private init() {
        if let saved = UserDefaults.standard.dictionary(forKey: Self.key) as? [String: Data] {
            grants = saved
        }
        restoreAll()
    }

    // MARK: Granting

    /// Keep access to a location the person chose (panel, drop). Call it
    /// with every URL that came from outside — it's cheap, and a URL
    /// already covered by a granted folder is left alone.
    func remember(_ url: URL) {
        let url = url.standardizedFileURL
        let path = url.path
        guard grants[path] == nil, !isCovered(path) else { return }
        guard let data = Self.bookmark(for: url) else { return }
        grants[path] = data
        // A folder makes grants inside it redundant.
        if url.hasDirectoryPath || (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            for inner in grants.keys where inner != path && inner.hasPrefix(path + "/") {
                grants[inner] = nil
                if let opened = open.removeValue(forKey: inner) { opened.stopAccessingSecurityScopedResource() }
            }
        }
        start(url, path: path)
        save()
    }

    func remember(_ urls: [URL]) {
        for url in urls { remember(url) }
    }

    /// Stop keeping access (Settings ▸ Folder Access ▸ Remove).
    func forget(_ path: String) {
        grants[path] = nil
        if let opened = open.removeValue(forKey: path) { opened.stopAccessingSecurityScopedResource() }
        save()
    }

    // MARK: Checking

    /// Inside something already granted.
    func isCovered(_ path: String) -> Bool {
        grants.keys.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// Can actually be read now (the sandbox answers this, not our list).
    nonisolated static func canRead(_ path: String) -> Bool {
        FileManager.default.isReadableFile(atPath: path)
    }

    // MARK: Launch

    /// Open every kept location again; refresh bookmarks that went stale
    /// (a folder renamed or moved), drop ones that no longer resolve.
    func restoreAll() {
        var changed = false
        for (path, data) in grants {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: Self.resolveOptions,
                                     relativeTo: nil, bookmarkDataIsStale: &stale) else {
                // Gone (a drive that isn't plugged in keeps resolving later,
                // so only forget it when the bookmark itself is unreadable).
                continue
            }
            let current = url.standardizedFileURL.path
            if stale || current != path {
                if let fresh = Self.bookmark(for: url) {
                    grants[path] = nil
                    grants[current] = fresh
                    changed = true
                }
            }
            start(url, path: current)
        }
        if changed { save() }
    }

    private func start(_ url: URL, path: String) {
        guard open[path] == nil else { return }
        _ = url.startAccessingSecurityScopedResource()
        open[path] = url
    }

    private func save() {
        UserDefaults.standard.set(grants, forKey: Self.key)
    }

    // MARK: Bookmarks

    private static var resolveOptions: URL.BookmarkResolutionOptions {
        isSandboxed ? [.withSecurityScope, .withoutUI] : [.withoutUI]
    }

    private static func bookmark(for url: URL) -> Data? {
        if isSandboxed {
            return try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        }
        return try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    // MARK: Asking

    /// The folders a set of unreadable photos live in, gathered into as few
    /// places as make sense: per top location (a folder in the home folder,
    /// a drive), the deepest folder they all share.
    nonisolated static func foldersToAsk(for paths: [String]) -> [URL] {
        let home = realHome.standardizedFileURL.path
        var groups: [String: [[String]]] = [:]
        for path in paths {
            let dir = (path as NSString).deletingLastPathComponent
            let parts = dir.split(separator: "/").map(String.init)
            let root: String
            if dir.hasPrefix(home + "/") {
                let rest = dir.dropFirst(home.count + 1).split(separator: "/")
                root = home + "/" + (rest.first.map(String.init) ?? "")
            } else if parts.first == "Volumes", parts.count >= 2 {
                root = "/Volumes/" + parts[1]
            } else {
                root = parts.isEmpty ? "/" : "/" + parts[0]
            }
            groups[root, default: []].append(parts)
        }
        return groups.values.map { dirs -> URL in
            var common = dirs[0]
            for dir in dirs.dropFirst() {
                var n = 0
                while n < common.count, n < dir.count, common[n] == dir[n] { n += 1 }
                common = Array(common.prefix(n))
            }
            return URL(fileURLWithPath: "/" + common.joined(separator: "/"), isDirectory: true)
        }.sorted { $0.path < $1.path }
    }

    /// An Open panel pointed at `folder`, asking for it. Returns whether
    /// access was given (to it or to something that contains it).
    func ask(for folder: URL, reason: String) async -> Bool {
        let panel = NSOpenPanel()
        panel.title = "Allow Access"
        panel.message = reason
        panel.prompt = "Allow Access"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = folder
        let response = await withCheckedContinuation { continuation in
            panel.begin { continuation.resume(returning: $0) }
        }
        guard response == .OK, let chosen = panel.url else { return false }
        remember(chosen)
        return folder.standardizedFileURL.path.hasPrefix(chosen.standardizedFileURL.path)
    }
}
