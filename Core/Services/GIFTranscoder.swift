//
//  GIFTranscoder.swift
//  Alter
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
//  AVFoundation can't read an animated GIF as a video track — so the timeline
//  editor never could either. This turns a GIF into a real H.264 .mov (once,
//  cached) so the whole Animate pipeline — scrub, trim, layers, audio, export
//  — works on it like any other clip. Per-frame GIF delays are preserved, so
//  the motion times match the original.
//

import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum GIFTranscoderError: LocalizedError {
    case notAGIF
    case noFrames
    case writerSetupFailed
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .notAGIF: return "That file isn't a readable GIF."
        case .noFrames: return "The GIF has no frames to convert."
        case .writerSetupFailed: return "Couldn't set up the video writer."
        case .writeFailed(let why): return why
        }
    }
}

enum GIFTranscoder {
    /// Deterministic derived-movie location, keyed by the GIF's path ONLY.
    /// NOT by mtime: the .altermeme sidecar (the user's timeline edit) lives
    /// beside this movie, and ⌘S rewrites the GIF's metadata — an mtime key
    /// would orphan the edit on every save. A stale movie after a genuine
    /// pixel re-render is the rarer, recoverable failure. And Application
    /// Support, NOT Caches: purgeable storage would eat the edits too.
    static func derivedURL(for gifURL: URL) -> URL {
        let store = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ALTer/GIFMovies", isDirectory: true)
        try? FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        let key = gifURL.path.data(using: .utf8)!
            .base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .suffix(60)
        return store.appendingPathComponent("\(key).mov")
    }

    /// The GIF as a playable movie. Cached — a second call for the same,
    /// unchanged GIF returns the existing file without re-encoding.
    static func movie(for gifURL: URL) async throws -> URL {
        let dest = derivedURL(for: gifURL)
        // Reuse only a non-empty prior result; a zero-byte file is a failed run.
        if let size = try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int,
           size > 0 {
            return dest
        }
        try? FileManager.default.removeItem(at: dest)
        try await transcode(gifURL, to: dest)
        return dest
    }

    // MARK: - Encoding

    private static func transcode(_ gifURL: URL, to dest: URL) async throws {
        guard let source = CGImageSourceCreateWithURL(gifURL as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else {
            throw GIFTranscoderError.notAGIF
        }
        let count = CGImageSourceGetCount(source)
        guard let first = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw GIFTranscoderError.noFrames
        }
        // H.264 requires even dimensions.
        let width = first.width - (first.width % 2)
        let height = first.height - (first.height % 2)
        guard width >= 2, height >= 2 else { throw GIFTranscoderError.noFrames }

        guard let writer = try? AVAssetWriter(outputURL: dest, fileType: .mov) else {
            throw GIFTranscoderError.writerSetupFailed
        }
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(1_000_000, width * height * 6),
            ],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        guard writer.canAdd(input) else { throw GIFTranscoderError.writerSetupFailed }
        writer.add(input)
        guard writer.startWriting() else {
            throw GIFTranscoderError.writeFailed(
                writer.error?.localizedDescription ?? "The writer wouldn't start.")
        }
        writer.startSession(atSourceTime: .zero)

        let timescale: CMTimeScale = 600
        let queue = DispatchQueue(label: "org.alttext.gif-transcode")

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var index = 0
            var elapsed = 0.0        // seconds, accumulated across frames
            var finished = false

            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData {
                    if index >= count {
                        guard !finished else { return }
                        finished = true
                        input.markAsFinished()
                        // End the session past the last frame so it holds for
                        // its own delay, giving the movie its true length.
                        writer.endSession(atSourceTime: CMTime(seconds: elapsed,
                                                               preferredTimescale: timescale))
                        writer.finishWriting {
                            if writer.status == .completed {
                                cont.resume()
                            } else {
                                cont.resume(throwing: GIFTranscoderError.writeFailed(
                                    writer.error?.localizedDescription ?? "Encoding failed."))
                            }
                        }
                        return
                    }
                    guard let frame = CGImageSourceCreateImageAtIndex(source, index, nil),
                          let buffer = pixelBuffer(from: frame, adaptor: adaptor,
                                                   width: width, height: height) else {
                        index += 1
                        continue
                    }
                    let time = CMTime(seconds: elapsed, preferredTimescale: timescale)
                    adaptor.append(buffer, withPresentationTime: time)
                    elapsed += frameDelay(source, index)
                    index += 1
                }
            }
        }
    }

    /// One GIF frame's on-screen duration. Prefers the unclamped delay; treats
    /// the sub-10ms values browsers reject as the conventional 100ms.
    private static func frameDelay(_ source: CGImageSource, _ index: Int) -> Double {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let gif = props[kCGImagePropertyGIFDictionary] as? [CFString: Any] else {
            return 0.1
        }
        let unclamped = gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double
        let clamped = gif[kCGImagePropertyGIFDelayTime] as? Double
        let delay = unclamped ?? clamped ?? 0.1
        return delay < 0.011 ? 0.1 : delay
    }

    private static func pixelBuffer(from image: CGImage,
                                    adaptor: AVAssetWriterInputPixelBufferAdaptor,
                                    width: Int, height: Int) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let status: CVReturn
        if let pool = adaptor.pixelBufferPool {
            status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
        } else {
            status = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                                         nil, &pixelBuffer)
        }
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width, height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        // A GIF frame can be smaller than canvas (optimized deltas); black-fill
        // then draw so undersized frames don't leave garbage.
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }
}
