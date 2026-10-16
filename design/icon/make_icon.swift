// Renders the Alter "Lens" app icon (concept B) natively with Core Graphics
// and writes the macOS AppIcon PNG set. Coordinates follow the SVG concept
// (1024 canvas, y down).
import AppKit

func hex(_ s: String, _ a: CGFloat = 1) -> CGColor {
    let v = Int(s.dropFirst(), radix: 16)!
    return CGColor(red: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255,
                   blue: CGFloat(v & 255) / 255, alpha: a)
}

func draw(_ ctx: CGContext) {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let c = CGPoint(x: 512, y: 512)

    // Squircle with a vertical aluminium gradient.
    let squircle = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824),
                          cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.addPath(squircle); ctx.clip()
    let bg = CGGradient(colorsSpace: cs, colors: [hex("#f2f4f7"), hex("#b9c0ca")] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
    // A soft top sheen.
    let sheen = CGGradient(colorsSpace: cs, colors: [hex("#ffffff", 0.55), hex("#ffffff", 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 420), options: [])
    ctx.restoreGState()

    // Lens shadow on the aluminium.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 14), blur: 40, color: hex("#000000", 0.35))
    ctx.setFillColor(hex("#0d0f12"))
    ctx.fillEllipse(in: CGRect(x: c.x - 330, y: c.y - 330, width: 660, height: 660))
    ctx.restoreGState()

    // Barrel.
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: c.x - 330, y: c.y - 330, width: 660, height: 660)); ctx.clip()
    let barrel = CGGradient(colorsSpace: cs, colors: [hex("#2e333b"), hex("#0d0f12")] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(barrel, start: CGPoint(x: 512, y: 182), end: CGPoint(x: 512, y: 842), options: [])
    ctx.restoreGState()
    ctx.setStrokeColor(hex("#ffffff", 0.10)); ctx.setLineWidth(3)
    ctx.strokeEllipse(in: CGRect(x: c.x - 328, y: c.y - 328, width: 656, height: 656))

    // Knurled focus ring.
    ctx.setStrokeColor(hex("#4a515b")); ctx.setLineWidth(7); ctx.setLineCap(.round)
    for i in 0..<60 {
        let a = CGFloat(i) * .pi * 2 / 60
        ctx.move(to: CGPoint(x: c.x + 292 * cos(a), y: c.y + 292 * sin(a)))
        ctx.addLine(to: CGPoint(x: c.x + 318 * cos(a), y: c.y + 318 * sin(a)))
    }
    ctx.strokePath()

    // Inner ring (the engraved one).
    ctx.setFillColor(hex("#14171c"))
    ctx.fillEllipse(in: CGRect(x: c.x - 282, y: c.y - 282, width: 564, height: 564))
    ctx.setStrokeColor(hex("#3a4049")); ctx.setLineWidth(3)
    ctx.strokeEllipse(in: CGRect(x: c.x - 282, y: c.y - 282, width: 564, height: 564))

    // Engraving over the top of the ring: glyph by glyph along r = 252.
    let text = "ALTER   LENS   1:1.4   35 mm"
    let font = NSFont.systemFont(ofSize: 25, weight: .semibold)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(cgColor: hex("#c9ced6"))!]
    let kern: CGFloat = 8
    let widths = text.map { (String($0) as NSString).size(withAttributes: attrs).width + kern }
    let total = widths.reduce(0, +) - kern
    let radius: CGFloat = 252
    var arc = -total / 2   // centred on the top
    for (ch, w) in zip(text, widths) {
        let mid = arc + (w - kern) / 2
        let theta = -CGFloat.pi / 2 + mid / radius        // y-down: −π/2 is the top
        let p = CGPoint(x: c.x + radius * cos(theta), y: c.y + radius * sin(theta))
        ctx.saveGState()
        ctx.translateBy(x: p.x, y: p.y)
        ctx.rotate(by: theta + .pi / 2)
        // Text draws y-up; flip locally.
        ctx.scaleBy(x: 1, y: -1)
        let s = String(ch) as NSString
        let size = s.size(withAttributes: attrs)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        s.draw(at: CGPoint(x: -size.width / 2, y: -size.height / 2 + 2), withAttributes: attrs)
        ctx.restoreGState()
        arc += w
    }

    // Glass.
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: c.x - 226, y: c.y - 226, width: 452, height: 452)); ctx.clip()
    let glass = CGGradient(colorsSpace: cs, colors: [hex("#16343b"), hex("#071114"), hex("#010203")] as CFArray,
                           locations: [0, 0.55, 1])!
    ctx.drawRadialGradient(glass, startCenter: CGPoint(x: 476, y: 458), startRadius: 0,
                           endCenter: CGPoint(x: 476, y: 458), endRadius: 316, options: [.drawsAfterEndLocation])
    ctx.restoreGState()
    ctx.setStrokeColor(hex("#000000")); ctx.setLineWidth(10)
    ctx.strokeEllipse(in: CGRect(x: c.x - 226, y: c.y - 226, width: 452, height: 452))
    ctx.setStrokeColor(hex("#ffffff", 0.07)); ctx.setLineWidth(3)
    ctx.strokeEllipse(in: CGRect(x: c.x - 150, y: c.y - 150, width: 300, height: 300))

    // Coating reflections: the amber arc, a pale echo, two specks.
    ctx.setLineCap(.round)
    ctx.setStrokeColor(hex("#f5b544", 0.85)); ctx.setLineWidth(22)
    ctx.move(to: CGPoint(x: 370, y: 420)); ctx.addQuadCurve(to: CGPoint(x: 470, y: 350), control: CGPoint(x: 398, y: 362))
    ctx.strokePath()
    ctx.setStrokeColor(hex("#ffe2a3", 0.5)); ctx.setLineWidth(10)
    ctx.move(to: CGPoint(x: 400, y: 452)); ctx.addQuadCurve(to: CGPoint(x: 445, y: 405), control: CGPoint(x: 410, y: 418))
    ctx.strokePath()
    ctx.setFillColor(hex("#ffffff", 0.5)); ctx.fillEllipse(in: CGRect(x: 594, y: 602, width: 32, height: 32))
    ctx.setFillColor(hex("#ffffff", 0.35)); ctx.fillEllipse(in: CGRect(x: 633, y: 583, width: 14, height: 14))
}

func render(_ px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let gc = NSGraphicsContext(bitmapImageRep: rep)!
    let ctx = gc.cgContext
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    // y-down, 1024 units → px.
    ctx.translateBy(x: 0, y: CGFloat(px))
    ctx.scaleBy(x: CGFloat(px) / 1024, y: -CGFloat(px) / 1024)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = gc
    draw(ctx)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
for px in [16, 32, 64, 128, 256, 512, 1024] {
    let data = render(px).representation(using: .png, properties: [:])!
    try! data.write(to: out.appendingPathComponent("icon_\(px).png"))
}
print("wrote icons to \(out.path)")
