//
//  PhotosImporter.swift
//  Alter
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
//  Import from the Apple Photos library via the system picker (PhotosUI).
//  The picker runs out-of-process — no library permission prompt. Photos
//  can't hand out its internal originals to reference in place, so picked
//  photos are copied to a folder the user chooses; ALTer references the
//  copies as ordinary files from then on.
//

import AppKit
import Foundation
import PhotosUI
import UniformTypeIdentifiers

final class PhotosImporter: NSObject, PHPickerViewControllerDelegate {
    static let shared = PhotosImporter()

    private static let lastFolderKey = "alter_photos_import_dir"
    private var completion: (([URL]) -> Void)?
    private weak var hostWindow: NSWindow?
    private var sheetWindow: NSWindow?

    /// Present the Photos picker; calls back on the main queue with the URLs
    /// of the copies (empty if the user cancels anywhere along the way).
    func present(completion: @escaping ([URL]) -> Void) {
        guard let host = NSApp.keyWindow ?? NSApp.mainWindow else {
            completion([])
            return
        }
        self.completion = completion
        self.hostWindow = host

        var config = PHPickerConfiguration()
        config.filter = .any(of: [.images, .videos])
        config.selectionLimit = 0 // unlimited
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self

        // The picker ignores preferredContentSize as a VC sheet — give it
        // its own window sized relative to the host and sheet that instead.
        let sheet = NSWindow(contentViewController: picker)
        let size = NSSize(width: min(980, host.frame.width - 120),
                          height: min(680, host.frame.height - 100))
        sheet.setContentSize(size)
        sheetWindow = sheet
        host.beginSheet(sheet)
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        if let sheetWindow {
            hostWindow?.endSheet(sheetWindow)
            sheetWindow.orderOut(nil)
        }
        sheetWindow = nil
        let completion = self.completion
        self.completion = nil
        guard !results.isEmpty else {
            completion?([])
            return
        }
        chooseDestination(count: results.count) { directory in
            guard let directory else {
                completion?([])
                return
            }
            Self.copy(results, to: directory) { urls in
                completion?(urls)
            }
        }
    }

    // MARK: - Destination

    private func chooseDestination(count: Int, then: @escaping (URL?) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "Keep Copies In"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Import Here"
        panel.message = "The \(count) photo\(count == 1 ? "" : "s") will be copied here and referenced by Alter."
        if let saved = UserDefaults.standard.string(forKey: Self.lastFolderKey) {
            panel.directoryURL = URL(fileURLWithPath: saved)
        }
        panel.begin { response in
            guard response == .OK, let url = panel.url else {
                then(nil)
                return
            }
            UserDefaults.standard.set(url.path, forKey: Self.lastFolderKey)
            then(url)
        }
    }

    // MARK: - Copy out of the picker's temp space

    private static func copy(_ results: [PHPickerResult], to directory: URL,
                             completion: @escaping ([URL]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var copied: [URL] = []

        for result in results {
            let provider = result.itemProvider
            // Stills come through as images, videos as movies.
            let type: UTType
            if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
                type = .movie
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                type = .image
            } else {
                continue
            }
            group.enter()
            provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { tempURL, _ in
                defer { group.leave() }
                guard let tempURL else { return }
                // The temp file is deleted when this handler returns — copy now.
                let ext = tempURL.pathExtension.isEmpty
                    ? (type == .movie ? "mov" : "jpg") : tempURL.pathExtension
                let base = provider.suggestedName ?? tempURL.deletingPathExtension().lastPathComponent
                var dest = directory.appendingPathComponent(base).appendingPathExtension(ext)
                var counter = 1
                while FileManager.default.fileExists(atPath: dest.path) {
                    counter += 1
                    dest = directory.appendingPathComponent("\(base)-\(counter)").appendingPathExtension(ext)
                }
                if (try? FileManager.default.copyItem(at: tempURL, to: dest)) != nil {
                    lock.lock()
                    copied.append(dest)
                    lock.unlock()
                }
            }
        }

        group.notify(queue: .main) {
            completion(copied.sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            })
        }
    }
}
