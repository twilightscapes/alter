//
//  Watermark.swift
//  Alter
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
//  App-wide watermark (Aperture-style): configure the logo image, size,
//  opacity, and position once in Settings; apply at will per export or
//  gallery. Composited into rendered output only — originals untouched.
//

import CoreGraphics
import Foundation
import ImageIO

struct WatermarkSettings: Codable, Equatable {
    enum Position: String, Codable, CaseIterable, Identifiable {
        case topLeft, top, topRight
        case left, center, right
        case bottomLeft, bottom, bottomRight

        var id: String { rawValue }

        var label: String {
            switch self {
            case .topLeft: return "Top Left"
            case .top: return "Top"
            case .topRight: return "Top Right"
            case .left: return "Left"
            case .center: return "Center"
            case .right: return "Right"
            case .bottomLeft: return "Bottom Left"
            case .bottom: return "Bottom"
            case .bottomRight: return "Bottom Right"
            }
        }
    }

    var imagePath: String = ""
    /// Watermark width as a fraction of the photo's width (0.05–0.5).
    var scale: Double = 0.15
    var opacity: Double = 0.5
    var position: Position = .bottomRight

    var isConfigured: Bool {
        !imagePath.isEmpty && FileManager.default.fileExists(atPath: imagePath)
    }
}

enum Watermark {
    private static let defaultsKey = "alter_watermark"

    static func load() -> WatermarkSettings {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let settings = try? JSONDecoder().decode(WatermarkSettings.self, from: data) else {
            return WatermarkSettings()
        }
        return settings
    }

    static func save(_ settings: WatermarkSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
        cachedPath = nil // invalidate the mark cache on settings change
    }

    // Cache the decoded watermark image between renders of a batch.
    private static var cachedPath: String?
    private static var cachedMark: CGImage?

    private static func markImage(path: String) -> CGImage? {
        if cachedPath == path, let cachedMark { return cachedMark }
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        cachedPath = path
        cachedMark = image
        return image
    }

    /// Composite the watermark onto a rendered image.
    static func apply(to base: CGImage, settings: WatermarkSettings) -> CGImage {
        guard settings.isConfigured,
              let mark = markImage(path: settings.imagePath) else { return base }

        let baseWidth = Double(base.width)
        let baseHeight = Double(base.height)
        let targetWidth = max(1, baseWidth * min(0.5, max(0.05, settings.scale)))
        let targetHeight = targetWidth * Double(mark.height) / Double(mark.width)
        let margin = baseWidth * 0.02

        // CoreGraphics origin is bottom-left.
        let x: Double
        switch settings.position {
        case .topLeft, .left, .bottomLeft: x = margin
        case .top, .center, .bottom: x = (baseWidth - targetWidth) / 2
        case .topRight, .right, .bottomRight: x = baseWidth - targetWidth - margin
        }
        let y: Double
        switch settings.position {
        case .bottomLeft, .bottom, .bottomRight: y = margin
        case .left, .center, .right: y = (baseHeight - targetHeight) / 2
        case .topLeft, .top, .topRight: y = baseHeight - targetHeight - margin
        }

        guard let context = CGContext(
            data: nil, width: base.width, height: base.height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return base }

        context.draw(base, in: CGRect(x: 0, y: 0, width: baseWidth, height: baseHeight))
        context.setAlpha(CGFloat(min(1, max(0.05, settings.opacity))))
        context.draw(mark, in: CGRect(x: x, y: y, width: targetWidth, height: targetHeight))
        return context.makeImage() ?? base
    }
}
