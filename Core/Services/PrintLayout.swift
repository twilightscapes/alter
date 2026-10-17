//
//  PrintLayout.swift
//  Alter
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
//  Aperture's Print: presets (Standard, Contact Sheet, Review Sheet, print
//  sizes, your own), a layout worked out from the paper, and one drawing
//  routine for both the preview and the printer — so the preview is the
//  print. Sizes are in points (1/72 inch) throughout.
//

import AppKit

// MARK: - Settings

struct PrintSettings: Codable, Equatable {
    enum Layout: String, Codable, CaseIterable, Identifiable {
        /// One photo per page, as big as the margins allow.
        case fitPage
        /// Rows × columns on every page (contact sheets).
        case grid
        /// Prints of a set size (4×6…), as many to a page as fit.
        case fixedSize
        var id: String { rawValue }
        var label: String {
            switch self {
            case .fitPage: return "One per Page"
            case .grid: return "Rows & Columns"
            case .fixedSize: return "Print Size"
            }
        }
    }

    enum Metadata: String, Codable, CaseIterable, Identifiable {
        case none, filename, title, caption, titleAndCaption, filenameAndRating
        var id: String { rawValue }
        var label: String {
            switch self {
            case .none: return "None"
            case .filename: return "File Name"
            case .title: return "Title"
            case .caption: return "Caption"
            case .titleAndCaption: return "Title & Caption"
            case .filenameAndRating: return "File Name & Rating"
            }
        }
    }

    var landscape = false
    var layout: Layout = .fitPage
    var rows = 1
    var columns = 1
    /// Print size for .fixedSize, in points (4×6 in = 288×432).
    var printWidth: Double = 288
    var printHeight: Double = 432
    var margin: Double = 36
    var spacing: Double = 14
    /// Fill each space, trimming the photo, rather than fitting all of it.
    var cropToFill = false
    /// Turn a photo sideways when that fits its space better (print sizes;
    /// a contact sheet keeps every photo upright).
    var rotateToFit = false
    var copies = 1
    var metadata: Metadata = .none
    var captionSize: Double = 9
    /// A thin keyline round each photo, in points (0 = none).
    var border: Double = 0
}

struct PrintPreset: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var settings: PrintSettings
    var builtIn = false

    static let builtIns: [PrintPreset] = {
        var next = 0
        func make(_ name: String, _ edit: (inout PrintSettings) -> Void) -> PrintPreset {
            var s = PrintSettings()
            edit(&s)
            // Fixed ids keep the chosen preset across launches.
            next += 1
            let id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", next))!
            return PrintPreset(id: id, name: name, settings: s, builtIn: true)
        }
        return [
            make("Standard") { _ in },
            make("Contact Sheet") {
                $0.layout = .grid; $0.rows = 6; $0.columns = 5; $0.margin = 30; $0.spacing = 10
                $0.metadata = .filename; $0.captionSize = 7
            },
            make("Review Sheet") {
                $0.layout = .grid; $0.rows = 3; $0.columns = 2; $0.margin = 36; $0.spacing = 18
                $0.metadata = .filenameAndRating; $0.captionSize = 9; $0.border = 0.5
            },
            make("4 × 6 Prints") { $0.layout = .fixedSize; $0.rotateToFit = true; $0.printWidth = 288; $0.printHeight = 432; $0.margin = 18; $0.cropToFill = true },
            make("5 × 7 Prints") { $0.layout = .fixedSize; $0.rotateToFit = true; $0.printWidth = 360; $0.printHeight = 504; $0.margin = 18; $0.cropToFill = true },
            make("8 × 10 Prints") { $0.layout = .fixedSize; $0.rotateToFit = true; $0.printWidth = 576; $0.printHeight = 720; $0.margin = 18; $0.cropToFill = true },
            make("Wallets") {
                $0.layout = .fixedSize; $0.printWidth = 180; $0.printHeight = 252; $0.margin = 18; $0.spacing = 9
                $0.cropToFill = true; $0.rotateToFit = true; $0.copies = 4
            },
        ]
    }()
}

// MARK: - Layout

/// Where everything goes on each page.
struct PrintLayout {
    struct Cell {
        /// Which photo (index into the job's photos).
        let photo: Int
        /// The photo's space, and the caption's under it.
        let image: CGRect
        let caption: CGRect?
    }

    let paper: CGSize
    let printable: CGRect
    let pages: [[Cell]]

    init(settings s: PrintSettings, paper: CGSize, photoCount: Int) {
        self.paper = paper
        let margin = min(s.margin, min(paper.width, paper.height) / 3)
        let printable = CGRect(x: margin, y: margin, width: paper.width - 2 * margin, height: paper.height - 2 * margin)
        self.printable = printable
        let copies = max(1, s.copies)
        let photos = (0..<photoCount).flatMap { Array(repeating: $0, count: copies) }

        let captionHeight = s.metadata == .none ? 0
            : s.captionSize * 1.35 * (s.metadata == .titleAndCaption || s.metadata == .filenameAndRating ? 2 : 1) + 4
        let spacing = max(0, s.spacing)

        // The spaces on one page.
        var slots: [CGRect] = []
        switch s.layout {
        case .fitPage:
            slots = [printable]
        case .grid:
            let columns = max(1, s.columns), rows = max(1, s.rows)
            let w = (printable.width - spacing * Double(columns - 1)) / Double(columns)
            let h = (printable.height - spacing * Double(rows - 1)) / Double(rows)
            for r in 0..<rows {
                for c in 0..<columns {
                    slots.append(CGRect(x: printable.minX + Double(c) * (w + spacing),
                                        y: printable.minY + Double(r) * (h + spacing), width: w, height: h))
                }
            }
        case .fixedSize:
            // As many as fit, either way round; the grid centred.
            func grid(_ w: Double, _ h: Double) -> (Int, Int) {
                (max(0, Int((printable.width + spacing) / (w + spacing))),
                 max(0, Int((printable.height + spacing) / (h + captionHeight + spacing))))
            }
            var w = s.printWidth, h = s.printHeight
            let upright = grid(w, h), turned = grid(h, w)
            if turned.0 * turned.1 > upright.0 * upright.1 { swap(&w, &h) }
            let (columns, rows) = grid(w, h)
            if columns == 0 || rows == 0 {
                // Bigger than the paper: one, shrunk to fit.
                slots = [printable]
            } else {
                let totalW = Double(columns) * w + Double(columns - 1) * spacing
                let totalH = Double(rows) * (h + captionHeight) + Double(rows - 1) * spacing
                let x0 = printable.minX + (printable.width - totalW) / 2
                let y0 = printable.minY + (printable.height - totalH) / 2
                for r in 0..<rows {
                    for c in 0..<columns {
                        slots.append(CGRect(x: x0 + Double(c) * (w + spacing),
                                            y: y0 + Double(r) * (h + captionHeight + spacing),
                                            width: w, height: h + captionHeight))
                    }
                }
            }
        }

        var built: [[Cell]] = []
        var page: [Cell] = []
        for photo in photos {
            let slot = slots[page.count]
            let image = CGRect(x: slot.minX, y: slot.minY, width: slot.width, height: max(1, slot.height - captionHeight))
            let caption = captionHeight > 0
                ? CGRect(x: slot.minX, y: image.maxY + 2, width: slot.width, height: captionHeight - 2) : nil
            page.append(Cell(photo: photo, image: image, caption: caption))
            if page.count == slots.count {
                built.append(page)
                page = []
            }
        }
        if !page.isEmpty || built.isEmpty { built.append(page) }
        self.pages = built
    }
}

// MARK: - Drawing

/// What a print job draws: its photos (as images and words), the
/// settings, the layout. Pages are stacked top to bottom in one tall,
/// flipped view, the way NSPrintOperation wants them.
final class PrintPageView: NSView {
    struct Photo {
        var image: NSImage?
        var filename: String
        var title: String
        var caption: String
        var rating: Int
    }

    var settings = PrintSettings() { didSet { needsDisplay = true } }
    var layout: PrintLayout { didSet { resize(); needsDisplay = true } }
    var photos: [Photo] = [] { didSet { needsDisplay = true } }
    /// The preview shows the margins; the printer doesn't get them.
    var showsGuides = false
    /// Printing sizes the view to all its pages; the preview sizes it itself.
    var autoSizes = true

    init(layout: PrintLayout) {
        self.layout = layout
        super.init(frame: .zero)
        resize()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    private func resize() {
        guard autoSizes else { return }
        setFrameSize(NSSize(width: layout.paper.width, height: layout.paper.height * Double(max(1, layout.pages.count))))
    }

    // Printing: one page per paper.
    override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        range.pointee = NSRange(location: 1, length: max(1, layout.pages.count))
        return true
    }

    override func rectForPage(_ page: Int) -> NSRect {
        NSRect(x: 0, y: layout.paper.height * Double(page - 1), width: layout.paper.width, height: layout.paper.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        for (index, cells) in layout.pages.enumerated() {
            let top = layout.paper.height * Double(index)
            let pageRect = CGRect(x: 0, y: top, width: layout.paper.width, height: layout.paper.height)
            guard pageRect.intersects(dirtyRect) else { continue }
            NSColor.white.setFill()
            pageRect.fill()
            if showsGuides {
                let guide = NSBezierPath(rect: layout.printable.offsetBy(dx: 0, dy: top))
                guide.lineWidth = 0.5
                guide.setLineDash([3, 3], count: 2, phase: 0)
                NSColor.systemBlue.withAlphaComponent(0.5).setStroke()
                guide.stroke()
            }
            for cell in cells {
                draw(cell, offset: top)
            }
        }
    }

    private func draw(_ cell: PrintLayout.Cell, offset: Double) {
        guard photos.indices.contains(cell.photo) else { return }
        let photo = photos[cell.photo]
        let space = cell.image.offsetBy(dx: 0, dy: offset)
        if let image = photo.image, image.size.width > 0, image.size.height > 0 {
            var size = image.size
            // Sideways when that suits the space better.
            let turn = settings.rotateToFit && (size.width > size.height) != (space.width > space.height)
                && abs(size.width - size.height) > 1 && abs(space.width - space.height) > 1
            if turn { size = CGSize(width: size.height, height: size.width) }
            let fit = settings.cropToFill
                ? max(space.width / size.width, space.height / size.height)
                : min(space.width / size.width, space.height / size.height)
            let drawn = CGSize(width: size.width * fit, height: size.height * fit)
            let target = CGRect(x: space.midX - drawn.width / 2, y: space.midY - drawn.height / 2,
                                width: drawn.width, height: drawn.height)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: space).addClip()
            if turn {
                let t = NSAffineTransform()
                t.translateX(by: target.midX, yBy: target.midY)
                t.rotate(byDegrees: 90)
                t.concat()
                image.draw(in: CGRect(x: -target.height / 2, y: -target.width / 2, width: target.height, height: target.width),
                           from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                           hints: [.interpolation: NSImageInterpolation.high.rawValue])
            } else {
                image.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                           hints: [.interpolation: NSImageInterpolation.high.rawValue])
            }
            NSGraphicsContext.restoreGraphicsState()
            if settings.border > 0 {
                let line = NSBezierPath(rect: target.intersection(space).insetBy(dx: settings.border / 2, dy: settings.border / 2))
                line.lineWidth = settings.border
                NSColor.black.setStroke()
                line.stroke()
            }
        } else {
            // Not rendered yet (preview): a placeholder of the space.
            NSColor(white: 0.9, alpha: 1).setFill()
            space.fill()
        }
        if let caption = cell.caption {
            captionText(photo).draw(with: caption.offsetBy(dx: 0, dy: offset),
                                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }

    private func captionText(_ photo: Photo) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: settings.captionSize),
            .foregroundColor: NSColor.black,
            .paragraphStyle: style,
        ]
        let lines: [String]
        switch settings.metadata {
        case .none: lines = []
        case .filename: lines = [photo.filename]
        case .title: lines = [photo.title]
        case .caption: lines = [photo.caption]
        case .titleAndCaption: lines = [photo.title, photo.caption].filter { !$0.isEmpty }
        case .filenameAndRating:
            lines = [photo.filename, photo.rating > 0 ? String(repeating: "★", count: photo.rating) : ""]
        }
        return NSAttributedString(string: lines.joined(separator: "\n"), attributes: attributes)
    }
}
