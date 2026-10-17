//
//  FacesOverlay.swift
//  Alter
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
//  The viewer's Name tool, as Aperture had it: a box on every face with a
//  label beneath — the name, a suggestion to confirm, or "click to name".
//  Add Missing Face draws one Alter didn't find. Faces live on the master,
//  so the boxes follow the photo's crop and rotation.
//

import SwiftUI

struct FacesOverlay: View {
    @ObservedObject var faces: FacesController
    let item: PhotoItem
    /// The photo's rect in the viewer (view points).
    let fit: CGRect
    @Binding var addingFace: Bool

    @State private var editing: Int64?
    @State private var nameText = ""
    @State private var drawStart: CGPoint?
    @State private var drawRect: CGRect?

    private var masterID: Int64 { item.versionOf ?? item.id }

    var body: some View {
        let shown = faces.faces(onPhoto: masterID)
        ZStack(alignment: .topLeading) {
            // Clicks on the photo (not on a face) go to drawing, when adding.
            Color.clear
                .contentShape(Rectangle())
                .gesture(drawGesture)
                .allowsHitTesting(addingFace)
            ForEach(shown) { face in
                if let rect = viewRect(face) {
                    faceBox(face, rect: rect)
                }
            }
            if let drawRect {
                Rectangle()
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                    .frame(width: drawRect.width, height: drawRect.height)
                    .position(x: drawRect.midX, y: drawRect.midY)
                    .allowsHitTesting(false)
            }
        }
        .onContinuousHover { phase in
            if addingFace, case .active = phase { NSCursor.crosshair.set() } else { NSCursor.arrow.set() }
        }
        .task(id: masterID) {
            editing = nil
            await faces.ensureScanned(photoID: masterID)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(shown.isEmpty ? "No faces found" : "\(shown.count) face\(shown.count == 1 ? "" : "s")")
    }

    // MARK: A face

    @ViewBuilder
    private func faceBox(_ face: FaceRecord, rect: CGRect) -> some View {
        let suggestion = face.personID == nil ? faces.suggestions[face.id] : nil
        let name = face.personID.flatMap { faces.person($0)?.name }
        RoundedRectangle(cornerRadius: 3)
            .strokeBorder(Color.white.opacity(0.9), lineWidth: 1.5)
            .shadow(color: .black.opacity(0.6), radius: 1.5)
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .contextMenu { faceMenu(face) }
        label(face, name: name, suggestion: suggestion)
            .fixedSize()
            .popover(isPresented: Binding(get: { editing == face.id }, set: { if !$0 { editing = nil } }),
                     arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(name == nil ? "Who is this?" : "Rename this face")
                        .font(.headline)
                    NameField(faces: faces, text: $nameText) { commitName(face) }
                        .frame(width: 240)
                    HStack {
                        if face.personID != nil {
                            Button("Remove Name") { faces.unname([face.id]); editing = nil }
                        }
                        Spacer()
                        Button("Name") { commitName(face) }
                            .keyboardShortcut(.defaultAction)
                            .disabled(nameText.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .padding(14)
            }
            // Positioned after the popover, so it hangs off the label.
            .position(x: rect.midX, y: rect.maxY + 14)
    }

    @ViewBuilder
    private func label(_ face: FaceRecord, name: String?, suggestion: (person: Int64, score: Float)?) -> some View {
        Group {
            if let name {
                Button(name) { beginEditing(face, text: name) }
                    .help("Click to change who this is")
            } else if let suggestion, let who = faces.person(suggestion.person)?.name {
                HStack(spacing: 6) {
                    Text("\(who)?")
                    Button {
                        faces.confirm([face.id], as: suggestion.person)
                    } label: {
                        Image(systemName: "checkmark")
                    }
                    .help("Yes, that's \(who)")
                    .accessibilityLabel("Confirm \(who)")
                    Button {
                        faces.reject([face.id], for: suggestion.person)
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .help("No, it isn't")
                    .accessibilityLabel("Not \(who)")
                }
            } else {
                Button("click to name") { beginEditing(face, text: "") }
                    .foregroundColor(.white.opacity(0.75))
            }
        }
        .buttonStyle(.plain)
        .font(.callout.weight(.medium))
        .foregroundColor(.white)
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(Capsule().fill(.black.opacity(0.62)))
        .contextMenu { faceMenu(face) }
    }

    @ViewBuilder
    private func faceMenu(_ face: FaceRecord) -> some View {
        if let person = face.personID {
            Button("Remove Name") { faces.unname([face.id]) }
            Button("Use as \(faces.person(person)?.name ?? "Their") Snapshot") { faces.setKeyFace(face.id, for: person) }
            Divider()
        }
        Button("Not a Face") { faces.notAFace([face.id]) }
    }

    private func beginEditing(_ face: FaceRecord, text: String) {
        nameText = text
        editing = face.id
    }

    private func commitName(_ face: FaceRecord) {
        let text = nameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        faces.name([face.id], as: text)
        editing = nil
    }

    // MARK: Add Missing Face

    private var drawGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                let start = drawStart ?? value.startLocation
                drawStart = start
                let a = clamp(start), b = clamp(value.location)
                drawRect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
            }
            .onEnded { _ in
                defer { drawStart = nil; drawRect = nil }
                guard let drawn = drawRect, drawn.width > 8, drawn.height > 8,
                      let rect = masterRect(drawn) else { return }
                faces.addFace(photoID: masterID, rect: rect, name: nil)
                addingFace = false
            }
    }

    private func clamp(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, fit.minX), fit.maxX), y: min(max(p.y, fit.minY), fit.maxY))
    }

    // MARK: Geometry

    /// Where a face (on the upright master) sits in the viewer, through the
    /// photo's crop, rotation and straighten.
    private func viewRect(_ face: FaceRecord) -> CGRect? {
        let size = face.imageSize.width > 0 ? face.imageSize : CGSize(width: 1000, height: 1000)
        let (t, out) = EditRenderer.geometry(item.edits, sourceExtent: CGRect(origin: .zero, size: size))
        guard out.width > 0, out.height > 0 else { return nil }
        // Core Image's frame is bottom-left; faces are top-left.
        let ci = CGRect(x: face.rect.minX * size.width, y: (1 - face.rect.maxY) * size.height,
                        width: face.rect.width * size.width, height: face.rect.height * size.height)
        let moved = ci.applying(t)
        let normal = CGRect(x: moved.minX / out.width, y: 1 - moved.maxY / out.height,
                            width: moved.width / out.width, height: moved.height / out.height)
        // Cropped out of the photo: no box.
        guard normal.intersects(CGRect(x: 0, y: 0, width: 1, height: 1)) else { return nil }
        return CGRect(x: fit.minX + normal.minX * fit.width, y: fit.minY + normal.minY * fit.height,
                      width: normal.width * fit.width, height: normal.height * fit.height)
    }

    /// A box drawn in the viewer, carried back onto the upright master.
    private func masterRect(_ drawn: CGRect) -> CGRect? {
        guard let size = FaceScanner.uprightSize(of: item.url) else { return nil }
        let (t, out) = EditRenderer.geometry(item.edits, sourceExtent: CGRect(origin: .zero, size: size))
        let normal = CGRect(x: (drawn.minX - fit.minX) / fit.width, y: (drawn.minY - fit.minY) / fit.height,
                            width: drawn.width / fit.width, height: drawn.height / fit.height)
        let ci = CGRect(x: normal.minX * out.width, y: (1 - normal.maxY) * out.height,
                        width: normal.width * out.width, height: normal.height * out.height)
        let back = ci.applying(t.inverted())
        let rect = CGRect(x: back.minX / size.width, y: 1 - back.maxY / size.height,
                          width: back.width / size.width, height: back.height / size.height)
        return rect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }
}

/// The Name tool's tray: what to do, Add Missing Face, and a way to turn
/// Faces on if it's off (naming by hand works either way).
struct FacesTray: View {
    @ObservedObject var faces: FacesController
    @ObservedObject var models: FaceModelStore
    @Binding var addingFace: Bool
    let done: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.crop.square")
                .foregroundColor(.accentColor)
            Text(addingFace ? "Drag a box around the face" : "Click a label to name someone")
                .font(.callout)
                .foregroundColor(.secondary)
                .frame(width: 220, alignment: .leading)
            Button(addingFace ? "Cancel Adding" : "Add Missing Face") { addingFace.toggle() }
                .help("Draw a box around a face Alter didn't find")
            if !faces.enabled || models.state != .ready {
                if case .downloading(let fraction) = models.state {
                    ProgressView(value: fraction)
                        .frame(width: 80)
                    Text("Getting Faces ready…")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Button("Turn On Faces…") { faces.enable() }
                        .help("Find faces in every photo automatically (downloads \(FaceModelStore.downloadSize) once)")
                }
            }
            Spacer()
            Button("Done", action: done)
                .keyboardShortcut(.defaultAction)
        }
    }
}
