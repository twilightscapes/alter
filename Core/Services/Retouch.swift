import CoreGraphics
import CoreImage
import Foundation

// Retouch: Repair heals (texture from a source, tone and colour from the
// spot's own surroundings — the seamless blend Aperture and Lightroom use)
// and Clone copies. Spots live in the recipe in normalized, top-left
// coordinates of the geometry-applied image; this file turns them into
// pixels, finds good sources, and does the healing.

extension RetouchSpot {
    /// The spot's footprint as dabs (normalized centres): one for a click,
    /// a dab every third of a radius along a dragged stroke.
    var dabs: [CGPoint] {
        var points = [CGPoint(x: x, y: y)]
        guard let trail, !trail.isEmpty else { return points }
        let spacing = max(radius / 3, 0.0005)
        var last = points[0]
        for next in trail.map({ CGPoint(x: $0.x, y: $0.y) }) {
            let length = hypot(next.x - last.x, next.y - last.y)
            let steps = Int(length / spacing)
            if steps > 0 {
                for i in 1...steps {
                    let t = Double(i) / Double(steps)
                    points.append(CGPoint(x: last.x + (next.x - last.x) * t,
                                          y: last.y + (next.y - last.y) * t))
                }
            }
            last = next
        }
        return points
    }

    /// Moved by a normalized offset — target and stroke together.
    func moved(by dx: Double, _ dy: Double) -> RetouchSpot {
        var spot = self
        spot.x += dx
        spot.y += dy
        spot.trail = trail?.map { RetouchPoint(x: $0.x + dx, y: $0.y + dy) }
        return spot
    }

    var isFill: Bool { (fill == true || maskPath != nil) && clone != true }
    var isHeal: Bool { clone != true && fill != true }
}

enum RetouchRenderer {
    /// Apply every spot in order — each sees the ones before it, so a spot
    /// can heal over an earlier one.
    static func apply(_ spots: [RetouchSpot], to input: CIImage) -> CIImage {
        guard !spots.isEmpty else { return input }
        var image = input
        let extent = input.extent
        for spot in spots {
            if spot.isFill {
                image = fill(spot, image: image, extent: extent)
            } else if spot.isHeal {
                image = heal(spot, image: image, extent: extent)
            } else {
                image = clone(spot, image: image, extent: extent)
            }
        }
        return image
    }

    /// Dabs in CI pixel space: (x, y, r), bottom-left origin.
    static func circles(_ spot: RetouchSpot, extent: CGRect) -> [SIMD3<Double>] {
        let r = max(1.5, spot.radius * extent.width)
        return spot.dabs.map {
            SIMD3(extent.minX + $0.x * extent.width,
                  extent.minY + (1 - $0.y) * extent.height, r)
        }
    }

    private static func bounds(_ circles: [SIMD3<Double>], pad: Double) -> CGRect {
        var rect = CGRect.null
        for c in circles {
            rect = rect.union(CGRect(x: c.x - c.z - pad, y: c.y - c.z - pad,
                                     width: 2 * (c.z + pad), height: 2 * (c.z + pad)))
        }
        return rect.integral
    }

    private static func heal(_ spot: RetouchSpot, image: CIImage, extent: CGRect) -> CIImage {
        let circles = circles(spot, extent: extent)
        let target = bounds(circles, pad: HealKernel.ring + 1).intersection(extent)
        guard !target.isEmpty else { return image }
        let offset = CGPoint(x: (spot.dx * extent.width).rounded(),
                             y: (-spot.dy * extent.height).rounded())
        let args: [String: Any] = [
            "circles": circles.flatMap { [$0.x, $0.y, $0.z] },
            "target": NSValue(rect: target),
            "offset": NSValue(point: offset),
            "softness": min(max(spot.softness ?? 0.45, 0), 1),
            "opacity": min(max(spot.opacity ?? 1, 0), 1),
        ]
        guard let healed = try? HealKernel.apply(
            withExtent: target, inputs: [image.clampedToExtent()], arguments: args)
        else { return image }
        // Core Image samples a processor's output past its extent with the
        // edge pixels repeated (cropping to that extent is a no-op it drops),
        // so the box goes in through an explicit mask, never a plain composite.
        let box = CIImage(color: .white).cropped(to: target)
        return healed.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: image,
            kCIInputMaskImageKey: box,
        ]).cropped(to: extent)
    }

    /// Content-aware fill: rebuilt from patches found around the spot.
    private static func fill(_ spot: RetouchSpot, image: CIImage, extent: CGRect) -> CIImage {
        let circles = spot.maskPath == nil ? circles(spot, extent: extent) : []
        var target = bounds(circles, pad: 1).intersection(extent)
        var maskImage: CIImage?
        if let path = spot.maskPath, let box = spot.maskBox {
            guard let mask = selectionMask(path, extent: extent) else { return image }
            maskImage = mask
            target = CGRect(x: extent.minX + box.x * extent.width,
                            y: extent.minY + (1 - box.y - box.h) * extent.height,
                            width: box.w * extent.width, height: box.h * extent.height)
                .insetBy(dx: -2, dy: -2).integral.intersection(extent)
        }
        guard !target.isEmpty else { return image }
        // Where patches may come from: around the spot, generously, but
        // never past the frame (clamped edges would make fake texture).
        let margin = min(900, max(24, 1.2 * max(target.width, target.height)))
        let pool = target.insetBy(dx: -margin, dy: -margin).intersection(extent).integral
        let args: [String: Any] = [
            "circles": circles.flatMap { [$0.x, $0.y, $0.z] },
            "target": NSValue(rect: target),
            "pool": NSValue(rect: pool),
            "softness": min(max(spot.softness ?? 0.45, 0), 1),
            "opacity": min(max(spot.opacity ?? 1, 0), 1),
            "seed": spot.variant ?? 0,
        ]
        guard let filled = try? FillKernel.apply(withExtent: target, inputs: [image] + (maskImage.map { [$0] } ?? []),
                                                 arguments: args)
        else { return image }
        let box = CIImage(color: .white).cropped(to: target)
        return filled.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: image,
            kCIInputMaskImageKey: box,
        ]).cropped(to: extent)
    }

    /// A selection mask scaled over `extent` (it was saved at the size the
    /// photo was shown at; renders at other sizes stretch it to fit).
    private static func selectionMask(_ path: String, extent: CGRect) -> CIImage? {
        maskLock.lock()
        var mask = maskCache[path]
        maskLock.unlock()
        if mask == nil {
            guard let loaded = CIImage(contentsOf: URL(fileURLWithPath: path)) else { return nil }
            maskLock.lock()
            if maskCache.count > 32 { maskCache.removeAll() }
            maskCache[path] = loaded
            maskLock.unlock()
            mask = loaded
        }
        guard let mask, mask.extent.width > 0 else { return nil }
        return mask.samplingLinear()
            .transformed(by: CGAffineTransform(scaleX: extent.width / mask.extent.width,
                                               y: extent.height / mask.extent.height))
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            .cropped(to: extent)
    }
    private static let maskLock = NSLock()
    nonisolated(unsafe) private static var maskCache: [String: CIImage] = [:]

    /// Clone: a straight copy from the source through a soft-edged mask.
    private static func clone(_ spot: RetouchSpot, image: CIImage, extent: CGRect) -> CIImage {
        let circles = circles(spot, extent: extent)
        let patch = image.clampedToExtent().transformed(by: CGAffineTransform(
            translationX: -spot.dx * extent.width, y: spot.dy * extent.height))
        let softness = min(max(spot.softness ?? 0.45, 0), 1)
        let opacity = min(max(spot.opacity ?? 1, 0), 1)
        var mask: CIImage?
        for c in circles {
            guard let dab = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": CIVector(x: c.x, y: c.y),
                "inputRadius0": max(0.5, c.z * (1 - softness)),
                "inputRadius1": c.z,
                "inputColor0": CIColor(red: opacity, green: opacity, blue: opacity, alpha: opacity),
                "inputColor1": CIColor.clear,
            ])?.outputImage?.cropped(to: CGRect(x: c.x - c.z, y: c.y - c.z, width: 2 * c.z, height: 2 * c.z))
            else { continue }
            mask = mask.map { dab.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: $0]) } ?? dab
        }
        guard let mask else { return image }
        return patch.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: image,
            kCIInputMaskImageKey: mask.composited(over: CIImage(color: .clear).cropped(to: extent)),
        ]).cropped(to: extent)
    }
}

/// The heal itself, on the CPU over the spot's own pixels. Result =
/// source + a membrane: the source/target difference measured on a thin
/// ring just outside the spot, interpolated smoothly (harmonically) inward.
/// The texture comes from the source; the brightness and colour come from
/// the spot's surroundings, so the patch doesn't read as a disc.
final class HealKernel: CIImageProcessorKernel {
    /// Width in pixels of the ring the difference is measured on.
    static let ring: Double = 2

    override class var outputFormat: CIFormat { .RGBAf }
    override class func formatForInput(at input: Int32) -> CIFormat { .RGBAf }

    override class func roi(forInput input: Int32, arguments: [String: Any]?, outputRect: CGRect) -> CGRect {
        guard let target = (arguments?["target"] as? NSValue)?.rectValue,
              let offset = (arguments?["offset"] as? NSValue)?.pointValue else { return outputRect }
        // The whole spot, always — the solve needs all of it whatever tile
        // Core Image is asking for — plus where its source sits.
        return target.union(target.offsetBy(dx: offset.x, dy: offset.y)).union(outputRect)
    }

    override class func process(with inputs: [CIImageProcessorInput]?, arguments: [String: Any]?,
                                output: CIImageProcessorOutput) throws {
        guard let input = inputs?.first, let arguments,
              let flat = arguments["circles"] as? [Double],
              let target = (arguments["target"] as? NSValue)?.rectValue,
              let offset = (arguments["offset"] as? NSValue)?.pointValue else { return }
        let softness = arguments["softness"] as? Double ?? 0.45
        let opacity = arguments["opacity"] as? Double ?? 1

        let src = PixelBuffer(input.baseAddress, bytesPerRow: input.bytesPerRow, region: input.region)
        var dst = PixelBuffer(output.baseAddress, bytesPerRow: output.bytesPerRow, region: output.region)
        let circles = stride(from: 0, to: flat.count - 2, by: 3).map { SIMD3(flat[$0], flat[$0 + 1], flat[$0 + 2]) }

        let healed = Heal.solve(width: Int(target.width), height: Int(target.height),
                                originX: Int(target.minX), originY: Int(target.minY),
                                circles: circles, offsetX: Int(offset.x), offsetY: Int(offset.y),
                                softness: softness, opacity: opacity,
                                sample: { src.read($0, $1) })

        let region = output.region
        for y in Int(region.minY)..<Int(region.maxY) {
            for x in Int(region.minX)..<Int(region.maxX) {
                dst.write(x, y, healed.value(x, y) ?? src.read(x, y))
            }
        }
    }
}

/// Content-aware fill on the CPU: the pool around the spot goes to
/// Inpaint, the hole comes back rebuilt, feathered in at the edge.
final class FillKernel: CIImageProcessorKernel {
    override class var outputFormat: CIFormat { .RGBAf }
    override class func formatForInput(at input: Int32) -> CIFormat { .RGBAf }

    override class func roi(forInput input: Int32, arguments: [String: Any]?, outputRect: CGRect) -> CGRect {
        guard let pool = (arguments?["pool"] as? NSValue)?.rectValue else { return outputRect }
        return pool.union(outputRect)
    }

    override class func process(with inputs: [CIImageProcessorInput]?, arguments: [String: Any]?,
                                output: CIImageProcessorOutput) throws {
        guard let input = inputs?.first, let arguments,
              let flat = arguments["circles"] as? [Double],
              let target = (arguments["target"] as? NSValue)?.rectValue,
              let pool = (arguments["pool"] as? NSValue)?.rectValue else { return }
        let softness = arguments["softness"] as? Double ?? 0.45
        let opacity = arguments["opacity"] as? Double ?? 1
        let seed = arguments["seed"] as? Int ?? 0
        let src = PixelBuffer(input.baseAddress, bytesPerRow: input.bytesPerRow, region: input.region)
        var dst = PixelBuffer(output.baseAddress, bytesPerRow: output.bytesPerRow, region: output.region)
        let circles = stride(from: 0, to: flat.count - 2, by: 3).map { SIMD3(flat[$0], flat[$0 + 1], flat[$0 + 2]) }

        let pw = Int(pool.width), ph = Int(pool.height), px0 = Int(pool.minX), py0 = Int(pool.minY)
        // The hole: the brush's circles, or a selection's mask (second input).
        let maskBuffer = inputs!.count > 1
            ? PixelBuffer(inputs![1].baseAddress, bytesPerRow: inputs![1].bytesPerRow, region: inputs![1].region) : nil
        var edge: [Double]
        if let maskBuffer {
            // Mask value → a pseudo edge distance: ≤ 0 inside (rebuilt),
            // and the feather below reads it back as the mask's own softness.
            edge = [Double](repeating: .greatestFiniteMagnitude, count: pw * ph)
            for j in 0..<ph {
                for i in 0..<pw {
                    let x = px0 + i, y = py0 + j
                    guard target.contains(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)) else { continue }
                    let m = Double(maskBuffer.read(x, y).x)
                    if m > 0.02 { edge[j * pw + i] = -m }
                }
            }
        } else {
            edge = Heal.edgeField(width: pw, height: ph, originX: px0, originY: py0, circles: circles, reach: 1)
        }

        // Same pixels, same spot → same fill: renders repeat (every slider
        // move re-renders the recipe), so the fill is remembered.
        var pixels = [SIMD3<Float>](repeating: .zero, count: pw * ph)
        var hole = [Bool](repeating: false, count: pw * ph)
        var checksum: Double = 0
        for j in 0..<ph {
            for i in 0..<pw {
                let v = src.read(px0 + i, py0 + j)
                pixels[j * pw + i] = SIMD3(v.x, v.y, v.z)
                hole[j * pw + i] = edge[j * pw + i] <= 0
                checksum += Double(v.x + 2 * v.y + 3 * v.z) * Double((j * pw + i) % 9973 + 1)
            }
        }
        let key = "\(flat.hashValue)#\(pool)#\(seed)#\(checksum)#\(maskBuffer != nil)"
        let filled: [SIMD3<Float>]
        if let cached = FillCache.shared.get(key) {
            filled = cached
        } else {
            filled = Self.inpaint(pixels: pixels, hole: hole, width: pw, height: ph, seed: seed)
            FillCache.shared.set(key, filled)
        }

        let radius = circles.first?.z ?? 1
        // A mask carries its own soft edge (edge = -mask value); circles
        // feather over the last stretch of the radius.
        let feather = maskBuffer != nil ? 1 : max(1, softness * radius * 0.35)
        let region = output.region
        for y in Int(region.minY)..<Int(region.maxY) {
            for x in Int(region.minX)..<Int(region.maxX) {
                let original = src.read(x, y)
                let i = x - px0, j = y - py0
                guard target.contains(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)),
                      i >= 0, j >= 0, i < pw, j < ph, hole[j * pw + i] else {
                    dst.write(x, y, original)
                    continue
                }
                let t = min(1, -edge[j * pw + i] / feather)
                let a = Float(opacity * t * t * (3 - 2 * t))
                let f = filled[j * pw + i]
                let rebuilt = SIMD4(f.x, f.y, f.z, original.w)
                dst.write(x, y, original + (rebuilt - original) * a)
            }
        }
    }
}

extension FillKernel {
    /// Inpaint, shrinking a big pool first: a large removal (a whole car)
    /// rebuilds at most ~700 px across and is lifted back up — softer than
    /// full resolution, but seconds instead of minutes.
    static func inpaint(pixels: [SIMD3<Float>], hole: [Bool], width w: Int, height h: Int, seed: Int) -> [SIMD3<Float>] {
        let f = max(1, Int((Double(max(w, h)) / 700).rounded(.up)))
        guard f > 1 else {
            var grid = Inpaint.Grid(width: w, height: h, pixels: pixels, hole: hole)
            Inpaint.fill(&grid, seed: UInt64(truncatingIfNeeded: seed))
            return grid.pixels
        }
        let sw = (w + f - 1) / f, sh = (h + f - 1) / f
        var small = [SIMD3<Float>](repeating: .zero, count: sw * sh)
        var smallHole = [Bool](repeating: false, count: sw * sh)
        var count = [Float](repeating: 0, count: sw * sh)
        for j in 0..<h {
            for i in 0..<w {
                let k = (j / f) * sw + i / f
                if hole[j * w + i] { smallHole[k] = true } else { small[k] += pixels[j * w + i]; count[k] += 1 }
            }
        }
        for k in 0..<(sw * sh) where count[k] > 0 { small[k] /= count[k] }
        var grid = Inpaint.Grid(width: sw, height: sh, pixels: small, hole: smallHole)
        Inpaint.fill(&grid, seed: UInt64(truncatingIfNeeded: seed))
        var out = pixels
        for j in 0..<h {
            for i in 0..<w where hole[j * w + i] {
                let gx = max(0, min(Float(sw - 1), (Float(i) + 0.5) / Float(f) - 0.5))
                let gy = max(0, min(Float(sh - 1), (Float(j) + 0.5) / Float(f) - 0.5))
                let x0 = Int(gx), y0 = Int(gy), x1 = min(sw - 1, x0 + 1), y1 = min(sh - 1, y0 + 1)
                let tx = gx - Float(x0), ty = gy - Float(y0)
                let g = grid.pixels
                let top = g[y0 * sw + x0] * (1 - tx) + g[y0 * sw + x1] * tx
                let bottom = g[y1 * sw + x0] * (1 - tx) + g[y1 * sw + x1] * tx
                out[j * w + i] = top * (1 - ty) + bottom * ty
            }
        }
        return out
    }
}

/// Recent fills, so re-rendering an unchanged spot is free.
final class FillCache: @unchecked Sendable {
    static let shared = FillCache()
    private let lock = NSLock()
    private var entries: [(String, [SIMD3<Float>])] = []

    func get(_ key: String) -> [SIMD3<Float>]? {
        lock.lock(); defer { lock.unlock() }
        return entries.first { $0.0 == key }?.1
    }

    func set(_ key: String, _ value: [SIMD3<Float>]) {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll { $0.0 == key }
        entries.append((key, value))
        if entries.count > 24 { entries.removeFirst() }
    }
}

/// An RGBAf buffer addressed in absolute Core Image pixel coordinates
/// (bottom-left origin); the memory itself runs top row first.
struct PixelBuffer {
    let base: UnsafeMutablePointer<Float>
    let stride: Int
    let minX: Int, maxX: Int, minY: Int, maxY: Int

    init(_ address: UnsafeRawPointer, bytesPerRow: Int, region: CGRect) {
        base = UnsafeMutablePointer(mutating: address.assumingMemoryBound(to: Float.self))
        stride = bytesPerRow / MemoryLayout<Float>.size
        minX = Int(region.minX)
        maxX = Int(region.maxX)
        minY = Int(region.minY)
        maxY = Int(region.maxY)
    }

    init(_ address: UnsafeMutableRawPointer, bytesPerRow: Int, region: CGRect) {
        self.init(UnsafeRawPointer(address), bytesPerRow: bytesPerRow, region: region)
    }

    /// Reads clamp to the region, so a source at the frame's edge smears
    /// the edge pixels rather than reading past the buffer.
    @inline(__always) func read(_ x: Int, _ y: Int) -> SIMD4<Float> {
        let cx = max(minX, min(maxX - 1, x)), cy = max(minY, min(maxY - 1, y))
        let p = base + (maxY - 1 - cy) * stride + (cx - minX) * 4
        return SIMD4(p[0], p[1], p[2], p[3])
    }

    @inline(__always) mutating func write(_ x: Int, _ y: Int, _ v: SIMD4<Float>) {
        let p = base + (maxY - 1 - y) * stride + (x - minX) * 4
        p[0] = v.x; p[1] = v.y; p[2] = v.z; p[3] = v.w
    }
}

/// The healing maths, free of Core Image so it can be tested on its own.
enum Heal {
    struct Result {
        let originX: Int, originY: Int, width: Int, height: Int
        /// nil where the spot doesn't reach (pass the input through).
        let pixels: [SIMD4<Float>?]

        func value(_ x: Int, _ y: Int) -> SIMD4<Float>? {
            let i = x - originX, j = y - originY
            guard i >= 0, j >= 0, i < width, j < height else { return nil }
            return pixels[j * width + i]
        }
    }

    static func solve(width w: Int, height h: Int, originX: Int, originY: Int,
                      circles: [SIMD3<Double>], offsetX: Int, offsetY: Int,
                      softness: Double, opacity: Double,
                      sample: (Int, Int) -> SIMD4<Float>) -> Result {
        let n = w * h
        guard n > 0 else { return Result(originX: originX, originY: originY, width: 0, height: 0, pixels: []) }

        let edge = edgeField(width: w, height: h, originX: originX, originY: originY,
                             circles: circles, reach: HealKernel.ring + 1)

        // 0 = untouched, 1 = boundary (difference known), 2 = to solve.
        var kind = [UInt8](repeating: 0, count: n)
        var diff = [SIMD4<Float>](repeating: .zero, count: n)
        var source = [SIMD4<Float>](repeating: .zero, count: n)
        var anyBoundary = false
        for j in 0..<h {
            for i in 0..<w {
                let k = j * w + i
                let e = edge[k]
                guard e <= HealKernel.ring else { continue }
                let x = originX + i, y = originY + j
                let s = sample(x + offsetX, y + offsetY)
                source[k] = s
                if e <= 0 {
                    kind[k] = 2
                } else {
                    kind[k] = 1
                    diff[k] = sample(x, y) - s
                    anyBoundary = true
                }
            }
        }
        guard anyBoundary else {
            return Result(originX: originX, originY: originY, width: w, height: h,
                          pixels: [SIMD4<Float>?](repeating: nil, count: n))
        }

        var membrane = coarseMembrane(kind: kind, diff: diff, width: w, height: h)
        relax(&membrane, kind: kind, diff: diff, width: w, height: h,
              iterations: max(w, h) <= 96 ? 600 : 60)

        // Composite: healed inside, feathered over the last stretch of the
        // radius. The heal already meets its surroundings, so the feather
        // only needs to be a fraction of what Clone uses.
        let radius = circles.first?.z ?? 1
        let feather = max(1, softness * radius * 0.35)
        var out = [SIMD4<Float>?](repeating: nil, count: n)
        for k in 0..<n where kind[k] == 2 {
            let t = min(1, -edge[k] / feather)
            let a = Float(opacity * t * t * (3 - 2 * t))
            let healed = source[k] + membrane[k]
            let i = k % w, j = k / w
            let original = sample(originX + i, originY + j)
            out[k] = original + (healed - original) * a
        }
        return Result(originX: originX, originY: originY, width: w, height: h, pixels: out)
    }

    /// Signed distance to the spot's edge in pixels (≤ 0 inside), for
    /// every pixel of a w×h box at (originX, originY); far pixels stay huge.
    static func edgeField(width w: Int, height h: Int, originX: Int, originY: Int,
                          circles: [SIMD3<Double>], reach: Double) -> [Double] {
        var edge = [Double](repeating: .greatestFiniteMagnitude, count: w * h)
        for c in circles {
            let x0 = max(0, Int((c.x - c.z - reach).rounded(.down)) - originX)
            let x1 = min(w - 1, Int((c.x + c.z + reach).rounded(.up)) - originX)
            let y0 = max(0, Int((c.y - c.z - reach).rounded(.down)) - originY)
            let y1 = min(h - 1, Int((c.y + c.z + reach).rounded(.up)) - originY)
            guard x0 <= x1, y0 <= y1 else { continue }
            for j in y0...y1 {
                let py = Double(originY + j) + 0.5 - c.y
                for i in x0...x1 {
                    let px = Double(originX + i) + 0.5 - c.x
                    let e = (px * px + py * py).squareRoot() - c.z
                    if e < edge[j * w + i] { edge[j * w + i] = e }
                }
            }
        }
        return edge
    }

    /// Solve the membrane on a grid of at most 64 cells a side, then lift
    /// it to full resolution (bilinear). It's smooth by construction, so
    /// the coarse solve carries nearly all of it.
    private static func coarseMembrane(kind: [UInt8], diff: [SIMD4<Float>], width w: Int, height h: Int) -> [SIMD4<Float>] {
        let f = max(1, Int((Double(max(w, h)) / 64).rounded(.up)))
        let cw = (w + f - 1) / f, ch = (h + f - 1) / f
        var sum = [SIMD4<Float>](repeating: .zero, count: cw * ch)
        var count = [Int](repeating: 0, count: cw * ch)
        var inside = [Bool](repeating: false, count: cw * ch)
        for j in 0..<h {
            for i in 0..<w {
                let k = j * w + i, c = (j / f) * cw + i / f
                if kind[k] == 1 { sum[c] += diff[k]; count[c] += 1 }
                if kind[k] == 2 { inside[c] = true }
            }
        }
        // Cell kinds: known (has boundary), free (to solve), or ignored.
        var grid = [SIMD4<Float>](repeating: .zero, count: cw * ch)
        var free = [Bool](repeating: false, count: cw * ch)
        var known = [Bool](repeating: false, count: cw * ch)
        var mean = SIMD4<Float>.zero
        var knownCount: Float = 0
        for c in 0..<(cw * ch) {
            if count[c] > 0 {
                grid[c] = sum[c] / Float(count[c])
                known[c] = true
                mean += grid[c]; knownCount += 1
            } else if inside[c] {
                free[c] = true
            }
        }
        if knownCount > 0 { mean /= knownCount }
        for c in 0..<(cw * ch) where free[c] { grid[c] = mean }

        let omega: Float = 1.85
        for _ in 0..<max(200, 4 * max(cw, ch)) {
            for cj in 0..<ch {
                for ci in 0..<cw {
                    let c = cj * cw + ci
                    guard free[c] else { continue }
                    var acc = SIMD4<Float>.zero
                    var m: Float = 0
                    if ci > 0, known[c - 1] || free[c - 1] { acc += grid[c - 1]; m += 1 }
                    if ci < cw - 1, known[c + 1] || free[c + 1] { acc += grid[c + 1]; m += 1 }
                    if cj > 0, known[c - cw] || free[c - cw] { acc += grid[c - cw]; m += 1 }
                    if cj < ch - 1, known[c + cw] || free[c + cw] { acc += grid[c + cw]; m += 1 }
                    guard m > 0 else { continue }
                    grid[c] += omega * (acc / m - grid[c])
                }
            }
        }

        var membrane = [SIMD4<Float>](repeating: .zero, count: w * h)
        let usable = zip(known, free).map { $0 || $1 }
        for j in 0..<h {
            for i in 0..<w {
                let k = j * w + i
                if kind[k] == 1 { membrane[k] = diff[k]; continue }
                guard kind[k] == 2 else { continue }
                // Bilinear over cell centres, skipping cells with no value.
                let gx = (Double(i) + 0.5) / Double(f) - 0.5
                let gy = (Double(j) + 0.5) / Double(f) - 0.5
                let x0 = max(0, min(cw - 1, Int(gx.rounded(.down))))
                let y0 = max(0, min(ch - 1, Int(gy.rounded(.down))))
                let x1 = min(cw - 1, x0 + 1), y1 = min(ch - 1, y0 + 1)
                let tx = Float(max(0, min(1, gx - Double(x0))))
                let ty = Float(max(0, min(1, gy - Double(y0))))
                var acc = SIMD4<Float>.zero
                var wsum: Float = 0
                for (cx, cy, wt) in [(x0, y0, (1 - tx) * (1 - ty)), (x1, y0, tx * (1 - ty)),
                                     (x0, y1, (1 - tx) * ty), (x1, y1, tx * ty)] {
                    let c = cy * cw + cx
                    guard usable[c], wt > 0 else { continue }
                    acc += grid[c] * wt
                    wsum += wt
                }
                membrane[k] = wsum > 0 ? acc / wsum : mean
            }
        }
        return membrane
    }

    /// Gauss–Seidel at full resolution: irons out what the coarse lift
    /// left near the edge so the heal meets the ring exactly.
    private static func relax(_ m: inout [SIMD4<Float>], kind: [UInt8], diff: [SIMD4<Float>],
                              width w: Int, height h: Int, iterations: Int) {
        let omega: Float = iterations > 100 ? 1.9 : 1.5
        for _ in 0..<iterations {
            for j in 0..<h {
                for i in 0..<w {
                    let k = j * w + i
                    guard kind[k] == 2 else { continue }
                    var acc = SIMD4<Float>.zero
                    var n: Float = 0
                    if i > 0, kind[k - 1] != 0 { acc += m[k - 1]; n += 1 }
                    if i < w - 1, kind[k + 1] != 0 { acc += m[k + 1]; n += 1 }
                    if j > 0, kind[k - w] != 0 { acc += m[k - w]; n += 1 }
                    if j < h - 1, kind[k + w] != 0 { acc += m[k + w]; n += 1 }
                    guard n > 0 else { continue }
                    m[k] += omega * (acc / n - m[k])
                }
            }
        }
    }
}

/// Picks where a Repair spot borrows its texture: the nearby patch whose
/// surroundings best match the spot's surroundings — texture first, then
/// tone — that doesn't overlap the spot itself.
enum HealSourceFinder {
    /// An 8-bit RGB copy of the image the spots apply to, for searching.
    struct Canvas {
        let width: Int, height: Int
        let pixels: [SIMD3<Float>]

        init?(_ image: CGImage, maxSide: Int = 900) {
            let scale = min(1, Double(maxSide) / Double(max(image.width, image.height)))
            width = max(1, Int(Double(image.width) * scale))
            height = max(1, Int(Double(image.height) * scale))
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            guard let ctx = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            var px = [SIMD3<Float>](repeating: .zero, count: width * height)
            for k in 0..<(width * height) {
                px[k] = SIMD3(Float(bytes[k * 4]), Float(bytes[k * 4 + 1]), Float(bytes[k * 4 + 2])) / 255
            }
            pixels = px
        }

        /// Row 0 is the top — the same way up as normalized coordinates.
        @inline(__always) func at(_ x: Int, _ y: Int) -> SIMD3<Float> {
            pixels[max(0, min(height - 1, y)) * width + max(0, min(width - 1, x))]
        }
    }

    /// The normalized (dx, dy) to borrow from, or nil if nothing fits.
    static func find(for spot: RetouchSpot, in canvas: Canvas) -> (dx: Double, dy: Double)? {
        search(for: spot, in: canvas).map { ($0.dx, $0.dy) }
    }

    /// The best source and how well it matches (lower is better; what the
    /// heal can't explain around the spot, plus penalties).
    static func search(for spot: RetouchSpot, in canvas: Canvas,
                       avoiding: (Double, Double)? = nil) -> (dx: Double, dy: Double, score: Float, tone: Float)? {
        let W = Double(canvas.width), H = Double(canvas.height)
        let r = max(1.5, spot.radius * W)
        let dabs = spot.dabs.map { CGPoint(x: $0.x * W, y: $0.y * H) }
        guard !dabs.isEmpty else { return nil }

        // Where we compare: a ring from the spot's edge out to 1.6 radii.
        // Where we look for detail that would be copied: the spot itself.
        let outer = max(r + 2, r * 1.6)
        var ring: [(Int, Int)] = []
        var core: [(Int, Int)] = []
        let minX = Int(dabs.map(\.x).min()! - outer), maxX = Int(dabs.map(\.x).max()! + outer)
        let minY = Int(dabs.map(\.y).min()! - outer), maxY = Int(dabs.map(\.y).max()! + outer)
        for y in max(0, minY)...min(canvas.height - 1, max(0, maxY)) {
            for x in max(0, minX)...min(canvas.width - 1, max(0, maxX)) {
                var d = Double.greatestFiniteMagnitude
                for p in dabs { d = min(d, hypot(Double(x) + 0.5 - p.x, Double(y) + 0.5 - p.y)) }
                if d <= r { core.append((x, y)) } else if d <= outer { ring.append((x, y)) }
            }
        }
        guard !ring.isEmpty else { return nil }
        ring = thinned(ring, to: 1600)
        core = thinned(core, to: 800)

        let targetRing = ring.map { canvas.at($0.0, $0.1) }
        let targetMean = targetRing.reduce(SIMD3<Float>.zero, +) / Float(targetRing.count)
        let targetSpread = spread(targetRing, mean: targetMean)

        // The heal reproduces any planar difference between source and
        // target exactly (that's the membrane), so what predicts a bad heal
        // is the part of the ring difference a plane can't explain. Least
        // squares on fixed ring positions: precompute the projection once.
        let cx = ring.reduce(0.0) { $0 + Double($1.0) } / Double(ring.count)
        let cy = ring.reduce(0.0) { $0 + Double($1.1) } / Double(ring.count)
        let px = ring.map { Float((Double($0.0) - cx) / r) }
        let py = ring.map { Float((Double($0.1) - cy) / r) }
        var sxx: Float = 0, sxy: Float = 0, syy: Float = 0
        for k in 0..<ring.count { sxx += px[k] * px[k]; sxy += px[k] * py[k]; syy += py[k] * py[k] }
        let det = sxx * syy - sxy * sxy

        // Bounds of the shape (with its ring) — the source must fit inside.
        let shapeMinX = Double(minX), shapeMaxX = Double(maxX)
        let shapeMinY = Double(minY), shapeMaxY = Double(maxY)
        let checkDabs = thinned(dabs, to: 24)
        let avoidPx = avoiding.map { CGPoint(x: $0.0 * W, y: $0.1 * H) }

        func score(_ ox: Int, _ oy: Int) -> Float? {
            let o = CGPoint(x: Double(ox), y: Double(oy))
            guard shapeMinX + o.x >= 0, shapeMaxX + o.x < W, shapeMinY + o.y >= 0, shapeMaxY + o.y < H
            else { return nil }
            // The source must clear the spot (and its ring) entirely.
            for a in checkDabs {
                for b in checkDabs where hypot(a.x - (b.x + o.x), a.y - (b.y + o.y)) < r * 2.1 { return nil }
            }
            // "Try another": stay clear of the source being replaced.
            if let avoid = avoidPx, hypot(o.x - avoid.x, o.y - avoid.y) < r * 1.5 { return nil }
            var diff = [SIMD3<Float>](repeating: .zero, count: ring.count)
            var mean = SIMD3<Float>.zero
            for k in 0..<ring.count {
                diff[k] = targetRing[k] - canvas.at(ring[k].0 + ox, ring[k].1 + oy)
                mean += diff[k]
            }
            mean /= Float(ring.count)
            var bx = SIMD3<Float>.zero, by = SIMD3<Float>.zero
            for k in 0..<ring.count {
                let d = diff[k] - mean
                bx += d * px[k]; by += d * py[k]
            }
            var gx = SIMD3<Float>.zero, gy = SIMD3<Float>.zero
            if abs(det) > 1e-6 {
                gx = (bx * syy - by * sxy) / det
                gy = (by * sxx - bx * sxy) / det
            }
            var residual: Float = 0
            for k in 0..<ring.count {
                let e = diff[k] - mean - gx * px[k] - gy * py[k]
                residual += (e * e).sum()
            }
            residual /= Float(ring.count)
            // A big tone gap still costs a little: the heal shifts the
            // source's texture by it, and clipped highlights don't shift.
            let tone = (mean * mean).sum()
            // What the source would paint in: busier than the spot's
            // surroundings means copying an edge or an object.
            var coreValues = [SIMD3<Float>]()
            coreValues.reserveCapacity(core.count)
            for p in core { coreValues.append(canvas.at(p.0 + ox, p.1 + oy)) }
            let coreMean = coreValues.isEmpty ? targetMean
                : coreValues.reduce(SIMD3<Float>.zero, +) / Float(coreValues.count)
            let busy = max(0, spread(coreValues, mean: coreMean) - targetSpread)
            let distance = Float(hypot(o.x, o.y) / r)
            return residual + 0.35 * tone + 1.5 * busy * busy + 0.00004 * distance * distance
        }

        func toneGap(_ ox: Int, _ oy: Int) -> Float {
            var mean = SIMD3<Float>.zero
            for k in 0..<ring.count { mean += targetRing[k] - canvas.at(ring[k].0 + ox, ring[k].1 + oy) }
            mean /= Float(ring.count)
            return (mean * mean).sum().squareRoot()
        }

        var best: (score: Float, ox: Int, oy: Int)?
        let reachMax = max(r * 4, min(r * 40, hypot(W, H) * 0.3))
        var distance = r * 2.2
        while distance <= reachMax {
            // Dense enough that an edge (a cloud's, a wall's) can line up.
            let steps = max(24, min(120, Int(2 * .pi * distance / max(1.5, r * 0.6))))
            for a in 0..<steps {
                let angle = Double(a) / Double(steps) * 2 * .pi
                let ox = Int((cos(angle) * distance).rounded()), oy = Int((sin(angle) * distance).rounded())
                if let s = score(ox, oy), s < (best?.score ?? .greatestFiniteMagnitude) { best = (s, ox, oy) }
            }
            distance *= 1.15
        }
        guard var found = best else { return nil }
        // Refine around the winner, pixel by pixel.
        let step = max(1, Int(r / 4))
        for _ in 0..<2 {
            let centre = found
            for oy in stride(from: centre.oy - 2 * step, through: centre.oy + 2 * step, by: step) {
                for ox in stride(from: centre.ox - 2 * step, through: centre.ox + 2 * step, by: step) {
                    if let s = score(ox, oy), s < found.score { found = (s, ox, oy) }
                }
            }
        }
        return (Double(found.ox) / W, Double(found.oy) / H, found.score, toneGap(found.ox, found.oy))
    }

    private static func spread(_ values: [SIMD3<Float>], mean: SIMD3<Float>) -> Float {
        guard !values.isEmpty else { return 0 }
        var acc: Float = 0
        for v in values { let d = v - mean; acc += (d * d).sum() }
        return (acc / Float(values.count)).squareRoot()
    }

    private static func thinned<T>(_ items: [T], to limit: Int) -> [T] {
        guard items.count > limit else { return items }
        let stride = Double(items.count) / Double(limit)
        return (0..<limit).map { items[Int(Double($0) * stride)] }
    }
}
