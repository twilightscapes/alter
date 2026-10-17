//
//  FaceScanner.swift
//  Alter
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
//  Finding faces: Vision finds each one and its eyes, nose and mouth; the
//  face is aligned on those and SFace fingerprints it. Then the sums —
//  who an unnamed face probably is, and which unnamed faces go together.
//

import CoreGraphics
import Foundation
import ImageIO
import Vision

enum FaceScanner {
    struct Found {
        /// Normalised, top-left origin, in the upright image.
        var rect: CGRect
        var quality: Double
        var print: [Float]?
    }

    struct Result {
        var imageSize: CGSize
        var faces: [Found]
    }

    /// The longest side faces are looked for at.
    static let scanSide = 2048
    /// Smaller than this (pixels across, at scanSide) and there's too
    /// little face to know anyone by.
    static let minimumFace: CGFloat = 34

    /// The upright image Faces works on, at most `maxPixel` across.
    static func image(at url: URL, maxPixel: Int = scanSide) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ] as CFDictionary)
    }

    /// The upright image's size, from the file's header (no decoding).
    static func uprightSize(of url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        return orientation >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }

    /// Every face in the file worth keeping.
    static func scan(_ url: URL, embedder: FaceEmbedder) -> Result? {
        guard let image = image(at: url) else { return nil }
        let request = VNDetectFaceLandmarksRequest()
        do {
            try VNImageRequestHandler(cgImage: image).perform([request])
        } catch {
            return nil
        }
        let size = CGSize(width: image.width, height: image.height)
        var found: [Found] = []
        var aligned: [[Float]] = []
        var alignedIndex: [Int] = []
        for observation in request.results ?? [] {
            guard observation.boundingBox.width * size.width >= minimumFace else { continue }
            let face = upright(observation, in: image)
            let rect = topLeft(face.boundingBox)
            found.append(Found(rect: rect, quality: Double(face.confidence), print: nil))
            if let points = points(face, size: size), let planes = FaceAligner.align(image, points: points) {
                aligned.append(planes)
                alignedIndex.append(found.count - 1)
            }
        }
        for (i, print) in embedder.embed(aligned).enumerated() where i < alignedIndex.count {
            found[alignedIndex[i]].print = print
        }
        return Result(imageSize: size, faces: found)
    }

    /// A face someone drew by hand: Vision fits its landmarks inside the
    /// box, and it's fingerprinted like the rest.
    static func fingerprint(_ url: URL, rect: CGRect, embedder: FaceEmbedder) -> (CGSize, [Float]?)? {
        guard let image = image(at: url) else { return nil }
        let size = CGSize(width: image.width, height: image.height)
        let box = CGRect(x: rect.minX, y: 1 - rect.maxY, width: rect.width, height: rect.height)
        let seed = VNFaceObservation(requestRevision: VNDetectFaceLandmarksRequestRevision3, boundingBox: box,
                                     roll: 0, yaw: 0, pitch: 0)
        let request = VNDetectFaceLandmarksRequest()
        request.inputFaceObservations = [seed]
        try? VNImageRequestHandler(cgImage: image).perform([request])
        guard let face = request.results?.first, let points = points(face, size: size),
              let planes = FaceAligner.align(image, points: points) else { return (size, nil) }
        return (size, embedder.embed([planes]).first)
    }

    /// Vision sometimes reads a face as upside down and lays its landmarks
    /// out that way, which wrecks the alignment. Photos are shown upright,
    /// so an upside-down face is far likelier to be that mistake: fit the
    /// landmarks again as if upright.
    private static func upright(_ face: VNFaceObservation, in image: CGImage) -> VNFaceObservation {
        guard abs(face.roll?.doubleValue ?? 0) > 2.5 else { return face }
        let seed = VNFaceObservation(requestRevision: VNDetectFaceLandmarksRequestRevision3,
                                     boundingBox: face.boundingBox, roll: 0, yaw: face.yaw, pitch: face.pitch)
        let again = VNDetectFaceLandmarksRequest()
        again.inputFaceObservations = [seed]
        try? VNImageRequestHandler(cgImage: image).perform([again])
        if let refit = again.results?.first, refit.landmarks != nil { return refit }
        return face
    }

    /// Eyes (image-left first), nose tip, mouth corners — in pixels,
    /// top-left origin, the order FaceAligner's template uses.
    private static func points(_ face: VNFaceObservation, size: CGSize) -> [CGPoint]? {
        guard let landmarks = face.landmarks else { return nil }
        func region(_ r: VNFaceLandmarkRegion2D?) -> [CGPoint] {
            (r?.pointsInImage(imageSize: size) ?? []).map { CGPoint(x: $0.x, y: size.height - $0.y) }
        }
        func centroid(_ p: [CGPoint]) -> CGPoint {
            CGPoint(x: p.reduce(0) { $0 + $1.x } / CGFloat(p.count), y: p.reduce(0) { $0 + $1.y } / CGFloat(p.count))
        }
        let left = region(landmarks.leftEye), right = region(landmarks.rightEye)
        let lips = region(landmarks.outerLips), crest = region(landmarks.noseCrest)
        guard !left.isEmpty, !right.isEmpty, !lips.isEmpty, !crest.isEmpty else { return nil }
        // Vision's left eye is the one on the image's left of an upright face.
        let eyes = [centroid(left), centroid(right)]
        let axis = CGPoint(x: eyes[1].x - eyes[0].x, y: eyes[1].y - eyes[0].y)
        let down = CGPoint(x: -axis.y, y: axis.x)
        func along(_ p: CGPoint, _ d: CGPoint) -> CGFloat { p.x * d.x + p.y * d.y }
        guard let mouthLeft = lips.min(by: { along($0, axis) < along($1, axis) }),
              let mouthRight = lips.max(by: { along($0, axis) < along($1, axis) }),
              let nose = crest.max(by: { along($0, down) < along($1, down) }) else { return nil }
        return [eyes[0], eyes[1], nose, mouthLeft, mouthRight]
    }

    private static func topLeft(_ box: CGRect) -> CGRect {
        CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
    }
}

// MARK: - Who's who

enum FaceMath {
    /// SFace's published cut-off: two fingerprints closer than this (as a
    /// cosine) are the same person.
    static let samePerson: Float = 0.363
    /// Stricter for unnamed groups: naming a group names every face in it,
    /// so a stranger slipping in costs more than a face left out (it turns
    /// up as a suggestion once the person has a name). Measured on a real
    /// set: 0.363 let 2 strangers into the biggest group, 0.43 none.
    static let groupCutoff: Float = 0.43

    static func similarity(_ a: [Float], _ b: [Float]) -> Float {
        var sum: Float = 0
        for i in 0..<min(a.count, b.count) { sum += a[i] * b[i] }
        return sum
    }

    /// Who each unnamed face probably is: its closest named person, by the
    /// mean of its best three matches among their faces, when that clears
    /// the cut-off and they haven't been turned down for it.
    static func suggestions(faces: [FaceRecord], rejections: [Int64: Set<Int64>]) -> [Int64: (person: Int64, score: Float)] {
        var named: [Int64: [[Float]]] = [:]
        for face in faces {
            if let person = face.personID, let print = face.print { named[person, default: []].append(print) }
        }
        guard !named.isEmpty else { return [:] }
        var out: [Int64: (Int64, Float)] = [:]
        for face in faces where face.personID == nil {
            guard let print = face.print else { continue }
            let refused = rejections[face.id] ?? []
            var best: (Int64, Float)?
            for (person, prints) in named where !refused.contains(person) {
                let top = prints.map { similarity(print, $0) }.sorted(by: >).prefix(3)
                let score = top.reduce(0, +) / Float(top.count)
                if score >= samePerson, score > (best?.1 ?? -1) { best = (person, score) }
            }
            if let best { out[face.id] = best }
        }
        return out
    }

    /// Unnamed faces that go together — average linkage at the cut-off
    /// (the mean similarity between two groups is the dot product of their
    /// sums over the sizes, so groups are carried as sums). One pass to
    /// seed, then merge passes until nothing joins.
    static func groups(_ faces: [FaceRecord], cutoff: Float = groupCutoff) -> [[FaceRecord]] {
        let usable = faces.filter { $0.personID == nil && $0.print != nil }
            .sorted { $0.quality > $1.quality }
        var sums: [[Float]] = []
        var members: [[Int]] = []
        for (index, face) in usable.enumerated() {
            let print = face.print!
            var best = -1, bestScore = cutoff
            for g in sums.indices {
                let score = similarity(print, sums[g]) / Float(members[g].count)
                if score >= bestScore { best = g; bestScore = score }
            }
            if best >= 0 {
                for i in 0..<print.count { sums[best][i] += print[i] }
                members[best].append(index)
            } else {
                sums.append(print)
                members.append([index])
            }
        }
        // Merge whole groups that belong together.
        var merged = true
        while merged {
            merged = false
            var g = 0
            while g < sums.count {
                var best = -1, bestScore = cutoff
                for h in (g + 1)..<max(g + 1, sums.count) {
                    let score = similarity(sums[g], sums[h]) / Float(members[g].count * members[h].count)
                    if score >= bestScore { best = h; bestScore = score }
                }
                if best >= 0 {
                    for i in 0..<sums[g].count { sums[g][i] += sums[best][i] }
                    members[g] += members[best]
                    sums.remove(at: best)
                    members.remove(at: best)
                    merged = true
                } else {
                    g += 1
                }
            }
        }
        return members.map { $0.map { usable[$0] } }.sorted { $0.count > $1.count }
    }
}
