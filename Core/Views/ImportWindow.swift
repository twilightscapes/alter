//
//  ImportWindow.swift
//  Alter
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
//  Aperture's Import window: pick a card, drive or folder, see what's on
//  it (what's already in the library is marked and left out), choose
//  which to bring in, whether to copy and rename, which project, what
//  metadata — then eject.
//

import AppKit
import Combine
import ImageCaptureCore
import SwiftUI

/// Cards and drives as they come and go.
@MainActor
final class VolumeWatcher: ObservableObject {
    struct Volume: Identifiable, Hashable {
        let url: URL
        let name: String
        /// A camera card: it has a DCIM folder.
        let isCard: Bool
        var id: URL { url }
        /// Where to look: DCIM on a card, the whole volume otherwise.
        var scanRoot: URL { isCard ? url.appendingPathComponent("DCIM") : url }
    }

    @Published private(set) var volumes: [Volume] = []
    private var observers: [Any] = []

    init() {
        refresh()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }
    }

    deinit {
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
    }

    func refresh() {
        let keys: [URLResourceKey] = [.volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsInternalKey,
                                      .volumeLocalizedNameKey, .volumeIsRootFileSystemKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                         options: [.skipHiddenVolumes]) ?? []
        volumes = urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.volumeIsRootFileSystem != true,
                  values.volumeIsRemovable == true || values.volumeIsEjectable == true
                    || values.volumeIsInternal == false else { return nil }
            var isDir: ObjCBool = false
            let hasDCIM = FileManager.default.fileExists(atPath: url.appendingPathComponent("DCIM").path,
                                                         isDirectory: &isDir) && isDir.boolValue
            return Volume(url: url, name: values.volumeLocalizedName ?? url.lastPathComponent, isCard: hasDCIM)
        }
        .sorted { ($0.isCard ? 0 : 1, $0.name) < ($1.isCard ? 0 : 1, $1.name) }
    }
}

struct ImportWindow: View {
    @EnvironmentObject var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var watcher = VolumeWatcher()
    @ObservedObject private var hub = CameraHub.shared

    private enum Source: Hashable {
        case volume(VolumeWatcher.Volume)
        case picked([URL])
        case camera(Camera)
    }

    /// A file on a card, drive or folder — or on a camera.
    private struct Candidate: Identifiable, Hashable {
        let url: URL?
        let cameraFile: ICCameraFile?
        let name: String
        let isDuplicate: Bool
        var id: String { url?.path ?? "camera:\(name)" }
    }

    @State private var source: Source?
    @State private var candidates: [Candidate] = []
    @State private var chosen: Set<String> = []
    @State private var scanning = false

    @AppStorage("import.copy") private var copyFiles = true
    @AppStorage("import.copyFolder") private var copyFolderPath = ""
    @AppStorage("import.naming") private var namingPattern = ""
    @AppStorage("import.skipDuplicates") private var skipDuplicates = true
    @AppStorage("import.eject") private var ejectAfter = true
    @AppStorage("import.creator") private var creator = ""
    @AppStorage("import.copyright") private var copyright = ""
    @State private var keywords = ""
    @State private var projectChoice = 0          // 0 selected, 1 new, 2 by day
    @State private var newProjectName = ""

    private var isCard: Bool {
        if case .volume = source { return true }
        return false
    }
    private var camera: Camera? {
        if case .camera(let camera) = source { return camera }
        return nil
    }
    /// A card's or camera's files must be copied (they leave with it); a
    /// folder's may stay where they are.
    private var mustCopy: Bool { isCard || camera != nil }
    private var willCopy: Bool { mustCopy || copyFiles }
    private var copyFolder: URL {
        copyFolderPath.isEmpty
            ? (FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first!
                .appendingPathComponent("Alter Imports"))
            : URL(fileURLWithPath: copyFolderPath)
    }
    private var importCount: Int {
        candidates.filter { chosen.contains($0.id) && !(skipDuplicates && $0.isDuplicate) }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sourceList
                    .frame(width: 190)
                Divider()
                thumbnails
                Divider()
                options
                    .frame(width: 270)
            }
            Divider()
            HStack {
                if scanning {
                    ProgressView().controlSize(.small)
                    Text("Looking for photos…").foregroundColor(.secondary)
                } else if !candidates.isEmpty {
                    let dupes = candidates.filter(\.isDuplicate).count
                    Text("\(candidates.count) item\(candidates.count == 1 ? "" : "s")"
                         + (dupes > 0 ? " · \(dupes) already in the library" : ""))
                        .foregroundColor(.secondary)
                }
                Spacer()
                if let camera {
                    Button("Start Tethered Session") { startTether(camera) }
                        .help(camera.canTakePicture
                              ? "Shoot into Alter: each shot (Capture or the camera's shutter) is copied, filed and shown"
                              : "Shots taken on the camera come straight into Alter (this camera can't be fired from the Mac)")
                }
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(importCount == 0 ? "Import" : "Import \(importCount) Item\(importCount == 1 ? "" : "s")") {
                    startImport()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(importCount == 0)
            }
            .padding(12)
        }
        .frame(width: 1040, height: 660)
        .onAppear { hub.start() }
        .onReceive(camera?.$files.eraseToAnyPublisher() ?? Empty().eraseToAnyPublisher()) { _ in
            if let camera { loadCamera(camera) }
        }
        .onChange(of: hub.cameras) { cameras in
            if let current = camera, !cameras.contains(current) { source = nil; candidates = [] }
        }
        .onAppear {
            if let card = watcher.volumes.first(where: \.isCard) { select(.volume(card)) }
        }
        .onChange(of: watcher.volumes) { volumes in
            // A card arriving while the window is open becomes the source;
            // the one being shown leaving clears it.
            if case .volume(let current) = source, !volumes.contains(current) {
                source = nil; candidates = []
            }
            if source == nil, let card = volumes.first(where: \.isCard) { select(.volume(card)) }
        }
    }

    // MARK: Sources

    private var sourceList: some View {
        List {
            Section("Cards & Drives") {
                if watcher.volumes.isEmpty {
                    Text("Insert a card or connect a drive")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
                ForEach(watcher.volumes) { volume in
                    Button {
                        select(.volume(volume))
                    } label: {
                        Label(volume.name, systemImage: volume.isCard ? "sdcard" : "externaldrive")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 2)
                    .background(source == .volume(volume)
                        ? RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.25)) : nil)
                }
            }
            Section("Cameras") {
                if hub.cameras.isEmpty {
                    Text("Connect a camera by USB and switch it on")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
                ForEach(hub.cameras) { camera in
                    Button {
                        select(.camera(camera))
                    } label: {
                        Label(camera.name, systemImage: "camera")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 2)
                    .background(source == .camera(camera)
                        ? RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.25)) : nil)
                }
            }
            Section("Files & Folders") {
                Button {
                    pickFiles()
                } label: {
                    Label("Choose…", systemImage: "folder")
                }
                .buttonStyle(.plain)
                if case .picked(let urls) = source {
                    Text(urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items")
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func select(_ new: Source) {
        source = new
        candidates = []
        chosen = []
        if case .camera(let camera) = new {
            camera.open()
            scanning = !camera.isReady
            loadCamera(camera)
            return
        }
        scanning = true
        let roots: [URL]
        switch new {
        case .volume(let volume): roots = [volume.scanRoot]
        case .picked(let urls): roots = urls
        case .camera: roots = []
        }
        let known = (try? store.catalog?.knownFileKeys()) ?? []
        Task {
            let found: [Candidate] = await Task.detached(priority: .userInitiated) {
                LibraryStore.collectImageFiles(from: roots).files.map { file, _ in
                    let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64) ?? nil
                    return Candidate(url: file, cameraFile: nil, name: file.lastPathComponent,
                                     isDuplicate: known.contains(Catalog.fileKey(name: file.lastPathComponent, size: size)))
                }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            }.value
            guard source == new else { return }
            candidates = found
            chosen = Set(found.filter { !$0.isDuplicate }.map(\.id))
            scanning = false
        }
    }

    /// A camera's photos, as it reports them (the list fills in as the
    /// camera finishes cataloguing its card).
    private func loadCamera(_ camera: Camera) {
        guard source == .camera(camera) else { return }
        let known = (try? store.catalog?.knownFileKeys()) ?? []
        let previous = Set(candidates.map(\.id))
        candidates = camera.files.map { file in
            let name = file.name ?? "Untitled"
            return Candidate(url: nil, cameraFile: file, name: name,
                             isDuplicate: known.contains(Catalog.fileKey(name: name, size: Int64(file.fileSize))))
        }
        // New arrivals start ticked (unless already in the library).
        for c in candidates where !previous.contains(c.id) && !c.isDuplicate { chosen.insert(c.id) }
        scanning = !camera.isReady
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.title = "Import"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "Choose folders, photos or videos"
        if panel.runModal() == .OK, !panel.urls.isEmpty {
            select(.picked(panel.urls))
        }
    }

    // MARK: Thumbnails

    private var thumbnails: some View {
        VStack(spacing: 0) {
            HStack {
                Text(sourceTitle)
                    .font(.headline)
                Spacer()
                Button("Select All") { chosen = Set(candidates.map(\.id)) }
                    .disabled(candidates.isEmpty)
                Button("Select None") { chosen = [] }
                    .disabled(chosen.isEmpty)
            }
            .padding(10)
            Divider()
            if candidates.isEmpty && !scanning {
                Text(source == nil ? "Choose a card, drive or folder on the left." : "No photos or videos found there.")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 118), spacing: 10)], spacing: 10) {
                        ForEach(candidates) { candidate in
                            ImportThumb(url: candidate.url, cameraFile: candidate.cameraFile, name: candidate.name,
                                        isDuplicate: candidate.isDuplicate,
                                        isChosen: chosen.contains(candidate.id),
                                        tick: camera?.thumbnailTick ?? 0) {
                                if chosen.contains(candidate.id) { chosen.remove(candidate.id) }
                                else { chosen.insert(candidate.id) }
                            }
                        }
                    }
                    .padding(10)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var sourceTitle: String {
        switch source {
        case .volume(let volume): return volume.name
        case .picked(let urls): return urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items"
        case .camera(let camera): return camera.name
        case nil: return "Import"
        }
    }

    // MARK: Options

    private var options: some View {
        Form {
            Section("Files") {
                Toggle("Copy into a folder", isOn: Binding(get: { willCopy }, set: { copyFiles = $0 }))
                    .disabled(mustCopy)
                    .help(mustCopy ? "A card's photos are always copied — the card goes back in the camera"
                          : "Off: the files stay where they are and Alter references them")
                if willCopy {
                    HStack {
                        Text(copyFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundColor(.secondary)
                        Spacer()
                        Button("Choose…", action: chooseFolder)
                    }
                    Picker("Rename", selection: $namingPattern) {
                        Text("Keep Original Names").tag("")
                        ForEach(NamingPresets.load().filter { $0.pattern != "{name}" }) { preset in
                            Text(preset.name).tag(preset.pattern)
                        }
                    }
                }
                Toggle("Don't import duplicates", isOn: $skipDuplicates)
                if isCard {
                    Toggle("Eject after import", isOn: $ejectAfter)
                }
            }
            Section("Project") {
                Picker("Into", selection: $projectChoice) {
                    Text(store.selectedProjectName.map { "Selected: \($0)" } ?? "No project").tag(0)
                    Text("New project").tag(1)
                    Text("One project per day").tag(2)
                }
                .labelsHidden()
                .pickerStyle(.radioGroup)
                if projectChoice == 1 {
                    TextField("Project name", text: $newProjectName)
                }
            }
            Section("Metadata") {
                TextField("Creator", text: $creator)
                TextField("Copyright", text: $copyright)
                TextField("Keywords", text: $keywords, prompt: Text("comma, separated"))
            }
        }
        .formStyle(.grouped)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Copy Here"
        panel.directoryURL = copyFolder.deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url { copyFolderPath = url.path }
    }

    // MARK: Go

    /// The plan the options describe (files filled in by the caller).
    private func makePlan(files: [URL]) -> ImportPlan {
        var plan = ImportPlan(files: files)
        if willCopy {
            plan.copyTo = destination
            plan.namingPattern = namingPattern.isEmpty ? nil : namingPattern
        }
        switch projectChoice {
        case 1: plan.project = .new(newProjectName.isEmpty ? sourceTitle : newProjectName)
        case 2: plan.project = .byDay
        default: plan.project = .current
        }
        plan.creator = creator
        plan.copyright = copyright
        plan.keywords = keywords
        if isCard, ejectAfter, case .volume(let volume) = source { plan.eject = volume.url }
        return plan
    }

    /// A card's or camera's shoot lands in a dated subfolder, as cameras
    /// number files over and over.
    private var destination: URL {
        guard mustCopy else { return copyFolder }
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        return copyFolder.appendingPathComponent(day.string(from: Date()))
    }

    private func startImport() {
        let picked = candidates.filter { chosen.contains($0.id) && !(skipDuplicates && $0.isDuplicate) }
        if let camera {
            // Off the camera first (renamed on the way), then in as files
            // already where they belong.
            var plan = makePlan(files: [])
            let folder = destination
            let pattern = plan.namingPattern
            plan.copyTo = nil
            plan.namingPattern = nil
            dismiss()
            Task {
                store.isWorking = true
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                var urls: [URL] = []
                for (index, candidate) in picked.enumerated() {
                    guard let file = candidate.cameraFile else { continue }
                    store.statusMessage = "Copying from \(camera.name)… \(index + 1) of \(picked.count)"
                    let base = (candidate.name as NSString).deletingPathExtension
                    let name = pattern.map {
                        $0.replacingOccurrences(of: "{name}", with: base)
                            .replacingOccurrences(of: "{title}", with: base)
                            .replacingOccurrences(of: "{seq}", with: String(format: "%0\(max(3, String(picked.count).count))d", index + 1))
                            .replacingOccurrences(of: "{date}", with: String(folder.lastPathComponent))
                    }
                    if let url = await camera.download(file, to: folder, as: name) { urls.append(url) }
                }
                store.isWorking = false
                plan.files = urls
                await store.runImport(plan)
            }
            return
        }
        let plan = makePlan(files: picked.compactMap(\.url))
        dismiss()
        Task { await store.runImport(plan) }
    }

    private func startTether(_ camera: Camera) {
        let plan = makePlan(files: [])
        var project = plan.project
        if case .current = project, store.selectedProjectID == nil {
            // A session wants somewhere to go: its own project.
            let stamp = DateFormatter()
            stamp.dateFormat = "yyyy-MM-dd HH.mm"
            project = .new("Tethered \(stamp.string(from: Date()))")
        }
        let tether = TetherPlan(folder: destination, namingPattern: plan.namingPattern, project: project,
                                creator: creator, copyright: copyright, keywords: keywords)
        dismiss()
        hub.startTether(on: camera, plan: tether, store: store)
    }
}

/// One file in the Import window: thumbnail, name, tick.
private struct ImportThumb: View {
    let url: URL?
    let cameraFile: ICCameraFile?
    let name: String
    let isDuplicate: Bool
    let isChosen: Bool
    /// The camera's thumbnail counter — a new one may have arrived.
    let tick: Int
    let toggle: () -> Void
    @State private var image: NSImage?

    var body: some View {
        Button(action: toggle) {
            VStack(spacing: 4) {
                ZStack(alignment: .topLeading) {
                    Group {
                        if let image {
                            Image(nsImage: image).resizable().scaledToFit()
                        } else if let thumb = cameraFile?.thumbnail {
                            Image(decorative: thumb, scale: 1).resizable().scaledToFit()
                        } else {
                            Rectangle().fill(Color.secondary.opacity(0.15))
                        }
                    }
                    .frame(width: 118, height: 88)
                    .opacity(isChosen ? 1 : 0.45)
                    Image(systemName: isChosen ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(isChosen ? .accentColor : .white)
                        .shadow(radius: 1)
                        .padding(4)
                    if isDuplicate {
                        Text("In Library")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(.regularMaterial, in: Capsule())
                            .padding(4)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    }
                }
                .frame(width: 118, height: 88)
                Text(name)
                    .font(.caption2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundColor(.secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(name)\(isDuplicate ? ", already in the library" : "")")
        .accessibilityValue(isChosen ? "Will import" : "Won't import")
        .id(tick)
        .task(id: url) {
            guard let url else { return }
            image = await ImageLoader.shared.thumbnailAsync(for: url, maxPixel: 240)
        }
    }
}
