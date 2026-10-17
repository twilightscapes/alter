//
//  FacesView.swift
//  Alter
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
//  Aperture's Faces: a corkboard of the people named so far, the unnamed
//  faces that go together (name a whole group at once), and each person's
//  page with the faces that may be them, to confirm or turn down.
//

import SwiftUI

/// The Faces pane (sidebar ▸ Faces).
struct FacesView: View {
    @EnvironmentObject var store: LibraryStore

    var body: some View {
        FacesBoard(faces: store.faces, models: FaceModelStore.shared)
    }
}

private struct FacesBoard: View {
    @EnvironmentObject var store: LibraryStore
    @ObservedObject var faces: FacesController
    @ObservedObject var models: FaceModelStore
    @State private var namingGroup: NamingGroup?
    @State private var renaming: PersonRow?
    @State private var renameText = ""
    @State private var deleting: PersonRow?

    private struct NamingGroup: Identifiable {
        let id = UUID()
        let faces: [FaceRecord]
    }

    private let columns = [GridItem(.adaptive(minimum: 132, maximum: 170), spacing: 18)]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !faces.enabled || models.state != .ready {
                FacesIntro(faces: faces, models: models)
            } else if faces.people.isEmpty && faces.groups.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "person.crop.rectangle.stack")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text(faces.isScanning ? "Looking for faces…" : "No faces found yet")
                        .font(.title3)
                    Text("Faces found in your photos gather here. You can also name the people in any photo with the Name button in the viewer.")
                        .multilineTextAlignment(.center)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: 380)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if !faces.people.isEmpty {
                            LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                                ForEach(faces.people) { person in
                                    personTile(person)
                                }
                            }
                        }
                        if !faces.groups.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Unnamed")
                                    .font(.headline)
                                Text("Faces that look like the same person. Click a group to name it.")
                                    .font(.callout)
                                    .foregroundColor(.secondary)
                            }
                            LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                                ForEach(faces.groups, id: \.first!.id) { group in
                                    groupTile(group)
                                }
                            }
                        }
                        if faces.loneFaces > 0 {
                            Text("\(faces.loneFaces) more face\(faces.loneFaces == 1 ? "" : "s") seen only once — name them from the viewer (Name button).")
                                .font(.callout)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(20)
                }
            }
        }
        .sheet(item: $namingGroup) { group in
            NameGroupSheet(faces: faces, group: group.faces)
        }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
                .autocorrectionDisabled()
            Button("Rename") {
                if let renaming { faces.rename(renaming.id, to: renameText) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: {
            Text("Renaming to someone already in Faces puts the two together.")
        }
        .confirmationDialog("Remove \(deleting?.name ?? "")?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Remove", role: .destructive) {
                if let deleting { faces.deletePerson(deleting.id) }
                deleting = nil
            }
        } message: {
            Text("Their faces go back to unnamed. No photos are removed.")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Faces")
                .font(.headline)
            if faces.enabled, !faces.people.isEmpty {
                Text("\(faces.people.count) \(faces.people.count == 1 ? "person" : "people")")
                    .foregroundColor(.secondary)
            }
            Spacer()
            if faces.enabled, models.state == .ready, faces.isScanning, faces.progress.total > 0 {
                ProgressView(value: Double(faces.progress.done), total: Double(max(1, faces.progress.total)))
                    .frame(width: 140)
                Text("Finding faces — \(faces.progress.done) of \(faces.progress.total) photos")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
    }

    private func personTile(_ person: PersonRow) -> some View {
        VStack(spacing: 6) {
            FaceThumb(face: person.keyFaceID.flatMap { faces.faces[$0] })
                .frame(width: 128, height: 128)
            Text(person.name)
                .font(.callout.weight(.medium))
                .lineLimit(1)
            Text("\(person.photoCount) photo\(person.photoCount == 1 ? "" : "s")")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { store.source = .person(person.id) }
        .contextMenu {
            Button("Show Photos") { store.source = .person(person.id) }
            Button("Rename…") { renameText = person.name; renaming = person }
            Divider()
            Button("Remove \(person.name)…", role: .destructive) { deleting = person }
        }
        .help("Double-click to see \(person.name)'s photos")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(person.name), \(person.photoCount) photos")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { store.source = .person(person.id) }
    }

    private func groupTile(_ group: [FaceRecord]) -> some View {
        VStack(spacing: 6) {
            FaceThumb(face: group.first)
                .frame(width: 128, height: 128)
                .overlay(alignment: .bottomTrailing) {
                    Text("\(group.count)")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(.black.opacity(0.65)))
                        .foregroundColor(.white)
                        .padding(6)
                }
            Text("Unnamed")
                .font(.callout)
                .foregroundColor(.secondary)
            Text("\(Set(group.map(\.photoID)).count) photo\(Set(group.map(\.photoID)).count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture { namingGroup = NamingGroup(faces: group) }
        .help("Click to name these \(group.count) faces")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Unnamed group of \(group.count) faces")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { namingGroup = NamingGroup(faces: group) }
    }
}

/// Faces is off (or its model isn't here yet): what it does, and the switch.
private struct FacesIntro: View {
    @ObservedObject var faces: FacesController
    @ObservedObject var models: FaceModelStore

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "person.2.crop.square.stack")
                .font(.system(size: 44))
                .foregroundColor(.secondary)
            Text("Faces")
                .font(.title2.weight(.semibold))
            Text("Alter finds the faces in your photos and groups the ones that look alike. Name a few people and it suggests the rest — you confirm each one.")
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Text("Everything happens on this Mac; no photo or face ever leaves it. Turning Faces on downloads the face recognition model (\(FaceModelStore.downloadSize), \(FaceModelStore.source)) once.")
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            switch models.state {
            case .downloading(let fraction):
                VStack(spacing: 6) {
                    ProgressView(value: fraction)
                        .frame(width: 240)
                    HStack {
                        Text("Downloading… \(Int(fraction * 100))%")
                            .font(.callout)
                            .monospacedDigit()
                        Button("Cancel") { models.cancel() }
                    }
                }
            case .failed(let message):
                Text(message)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                Button("Try Again") { faces.enable() }
                    .buttonStyle(.borderedProminent)
            default:
                Button(models.state == .ready ? "Turn On Faces" : "Turn On Faces (\(FaceModelStore.downloadSize))") {
                    faces.enable()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Naming a group

private struct NameGroupSheet: View {
    @ObservedObject var faces: FacesController
    let group: [FaceRecord]
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var left: Set<Int64> = []

    private var chosen: [Int64] { group.map(\.id).filter { !left.contains($0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Who is this?")
                .font(.headline)
            Text("Untick any face that isn't the same person.")
                .font(.callout)
                .foregroundColor(.secondary)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 10)], spacing: 10) {
                    ForEach(group) { face in
                        let on = !left.contains(face.id)
                        FaceThumb(face: face)
                            .frame(width: 92, height: 92)
                            .opacity(on ? 1 : 0.35)
                            .overlay(alignment: .topTrailing) {
                                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 17))
                                    .foregroundStyle(.white, on ? Color.accentColor : .black.opacity(0.4))
                                    .padding(4)
                            }
                            .onTapGesture {
                                if on { left.insert(face.id) } else { left.remove(face.id) }
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(on ? "Face, included" : "Face, left out")
                            .accessibilityAddTraits(.isButton)
                    }
                }
            }
            .frame(minHeight: 120, maxHeight: 320)
            NameField(faces: faces, text: $name, prompt: "Name") { commit() }
            HStack {
                Button("Not Faces") {
                    faces.notAFace(chosen)
                    dismiss()
                }
                .help("These aren't faces (or aren't anyone worth naming) — hide them")
                .disabled(chosen.isEmpty)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Name \(chosen.count) Face\(chosen.count == 1 ? "" : "s")") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosen.isEmpty || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func commit() {
        guard !chosen.isEmpty, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        faces.name(chosen, as: name)
        dismiss()
    }
}

// MARK: - A person's page

/// Above the grid on a person's page: back to Faces, their name, and the
/// faces that may be them (Aperture's Confirm Faces).
struct PersonHeader: View {
    @EnvironmentObject var store: LibraryStore
    @ObservedObject var faces: FacesController
    let personID: Int64
    @State private var confirming = false
    @State private var renaming = false
    @State private var renameText = ""

    var body: some View {
        let person = faces.person(personID)
        let suggested = faces.suggestedFaces(for: personID)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    store.source = .faces
                } label: {
                    Label("Faces", systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
                FaceThumb(face: person?.keyFaceID.flatMap { faces.faces[$0] })
                    .frame(width: 28, height: 28)
                Text(person?.name ?? "")
                    .font(.headline)
                    .onTapGesture(count: 2) { renameText = person?.name ?? ""; renaming = true }
                    .help("Double-click to rename")
                Spacer()
                if !suggested.isEmpty {
                    Text("\(suggested.count) more face\(suggested.count == 1 ? "" : "s") may be \(person?.name ?? "them")")
                        .foregroundColor(.secondary)
                    Button(confirming ? "Done" : "Confirm Faces") { confirming.toggle() }
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            if confirming, !suggested.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Click a face that's \(person?.name ?? "them") to confirm it; Option-click one that isn't.")
                            .font(.callout)
                            .foregroundColor(.secondary)
                        Spacer()
                        Button("Reject All") { faces.reject(suggested.map(\.id), for: personID) }
                        Button("Confirm All") { faces.confirm(suggested.map(\.id), as: personID) }
                    }
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 10) {
                            ForEach(suggested) { face in
                                SuggestionTile(face: face) {
                                    faces.confirm([face.id], as: personID)
                                } reject: {
                                    faces.reject([face.id], for: personID)
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .frame(height: 104)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.accentColor.opacity(0.06))
            }
        }
        .alert("Rename", isPresented: $renaming) {
            TextField("Name", text: $renameText)
                .autocorrectionDisabled()
            Button("Rename") { faces.rename(personID, to: renameText) }
            Button("Cancel", role: .cancel) {}
        }
        .onChange(of: personID) { _ in confirming = false }
    }
}

private struct SuggestionTile: View {
    let face: FaceRecord
    let confirm: () -> Void
    let reject: () -> Void
    @State private var hovering = false

    var body: some View {
        FaceThumb(face: face)
            .frame(width: 96, height: 96)
            .overlay(alignment: .bottom) {
                if hovering {
                    HStack(spacing: 14) {
                        Button(action: reject) {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .help("Not them")
                        Button(action: confirm) {
                            Image(systemName: "checkmark.circle.fill")
                        }
                        .help("That's them")
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 20))
                    .foregroundStyle(.white, .black.opacity(0.55))
                    .padding(5)
                }
            }
            .onHover { hovering = $0 }
            .gesture(TapGesture().modifiers(.option).onEnded(reject))
            .onTapGesture(perform: confirm)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Suggested face")
            .accessibilityAction(named: "Confirm", confirm)
            .accessibilityAction(named: "Reject", reject)
    }
}

// MARK: - Pieces

/// A face, cropped square from its photo.
struct FaceThumb: View {
    @EnvironmentObject var store: LibraryStore
    let face: FaceRecord?
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .quaternaryLabelColor))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: 26))
                    .foregroundColor(.secondary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .task(id: face?.id) {
            guard let face else { image = nil; return }
            image = FaceThumbnails.shared.cached(face)
            guard image == nil, let path = try? store.catalog?.photoPath(face.photoID) else { return }
            image = await FaceThumbnails.shared.image(for: face, path: path)
        }
        .accessibilityHidden(true)
    }
}

/// A name, with the names Faces already knows offered as you type.
struct NameField: View {
    @ObservedObject var faces: FacesController
    @Binding var text: String
    var prompt = "Name"
    var onCommit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(prompt, text: $text)
                .textFieldStyle(.roundedBorder)
                // A name is what's typed — no corrections, no predictions.
                .autocorrectionDisabled()
                .onSubmit(onCommit)
            let matches = faces.names(matching: text)
            if !matches.isEmpty {
                HStack(spacing: 6) {
                    ForEach(matches, id: \.self) { name in
                        Button(name) { text = name }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
            }
        }
    }
}
