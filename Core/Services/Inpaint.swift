import Foundation

/// Content-aware fill: rebuild a hole out of small patches from around it,
/// so whatever runs through the hole — a cloud's edge, a wall's grain —
/// carries on through it. Coarse to fine (PatchMatch for the nearest
/// patches, then each pixel votes from the patches that cover it), after
/// Wexler, Shechtman & Irani and Barnes et al.
enum Inpaint {
    struct Grid {
        var width: Int, height: Int
        var pixels: [SIMD3<Float>]
        var hole: [Bool]
    }

    /// Patch half-size: 7×7 patches.
    static let p = 3

    /// Fill `grid.hole` in place. `seed` picks a variation.
    static func fill(_ grid: inout Grid, seed: UInt64) {
        guard grid.hole.contains(true) else { return }
        // The pyramid: halve until the hole is a few patches across.
        var levels = [grid]
        while let top = levels.last, top.width > 4 * p, top.height > 4 * p,
              holeExtent(top) > 2 * p + 2, levels.count < 7 {
            levels.append(downsample(top))
        }
        var rng = SplitMix(seed: seed &+ 0x5EED)
        var nnf: [Int32] = []
        for level in stride(from: levels.count - 1, through: 0, by: -1) {
            var g = levels[level]
            if level == levels.count - 1 {
                diffuse(&g)
            } else {
                // Start from the coarser result, upsampled.
                // Bilinear, so the guess carries no block edges for the
                // patches to latch onto.
                let coarse = levels[level + 1]
                for y in 0..<g.height {
                    for x in 0..<g.width where g.hole[y * g.width + x] {
                        let fx = max(0, min(Float(coarse.width - 1), (Float(x) + 0.5) / 2 - 0.5))
                        let fy = max(0, min(Float(coarse.height - 1), (Float(y) + 0.5) / 2 - 0.5))
                        let x0 = Int(fx), y0 = Int(fy)
                        let x1 = min(coarse.width - 1, x0 + 1), y1 = min(coarse.height - 1, y0 + 1)
                        let tx = fx - Float(x0), ty = fy - Float(y0)
                        let c = coarse.pixels, cw = coarse.width
                        let top = c[y0 * cw + x0] * (1 - tx) + c[y0 * cw + x1] * tx
                        let bottom = c[y1 * cw + x0] * (1 - tx) + c[y1 * cw + x1] * tx
                        g.pixels[y * g.width + x] = top * (1 - ty) + bottom * ty
                    }
                }
            }
            let sources = validSources(g)
            guard !sources.isEmpty else { diffuse(&g); levels[level] = g; continue }
            let targets = targetCentres(g)
            nnf = upsampleField(nnf, from: level + 1 < levels.count ? levels[level + 1] : nil, to: g,
                                targets: targets, sources: sources, rng: &rng)
            let em = level == 0 ? 4 : (level == levels.count - 1 ? 8 : 5)
            for _ in 0..<em {
                patchMatch(g, targets: targets, sources: sources, nnf: &nnf, rng: &rng, passes: 4)
                vote(&g, targets: targets, nnf: nnf)
            }
            if level == 0 {
                // Averaging overlapping patches softens grain; the last
                // word goes to each pixel's own best patch, so the fill
                // keeps the texture's bite.
                patchMatch(g, targets: targets, sources: sources, nnf: &nnf, rng: &rng, passes: 4)
                sharpen(&g, nnf: nnf)
            }
            levels[level] = g
        }
        grid = levels[0]
    }

    // MARK: Pyramid

    private static func holeExtent(_ g: Grid) -> Int {
        var minX = g.width, maxX = -1, minY = g.height, maxY = -1
        for y in 0..<g.height {
            for x in 0..<g.width where g.hole[y * g.width + x] {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        return maxX < 0 ? 0 : max(maxX - minX, maxY - minY) + 1
    }

    private static func downsample(_ g: Grid) -> Grid {
        let w = (g.width + 1) / 2, h = (g.height + 1) / 2
        var px = [SIMD3<Float>](repeating: .zero, count: w * h)
        var hole = [Bool](repeating: false, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                var acc = SIMD3<Float>.zero
                var n: Float = 0
                var anyHole = false
                for dy in 0..<2 {
                    for dx in 0..<2 {
                        let sx = 2 * x + dx, sy = 2 * y + dy
                        guard sx < g.width, sy < g.height else { continue }
                        let k = sy * g.width + sx
                        if g.hole[k] { anyHole = true } else { acc += g.pixels[k]; n += 1 }
                    }
                }
                // Conservative: any hole pixel makes the coarse pixel hole.
                hole[y * w + x] = anyHole
                px[y * w + x] = n > 0 ? acc / n : .zero
            }
        }
        return Grid(width: w, height: h, pixels: px, hole: hole)
    }

    /// Smooth first guess for the coarsest hole: repeated neighbour averages.
    private static func diffuse(_ g: inout Grid) {
        let w = g.width, h = g.height
        var known = SIMD3<Float>.zero
        var n: Float = 0
        for k in 0..<(w * h) where !g.hole[k] { known += g.pixels[k]; n += 1 }
        let mean = n > 0 ? known / n : .zero
        for k in 0..<(w * h) where g.hole[k] { g.pixels[k] = mean }
        for _ in 0..<max(50, 2 * max(w, h)) {
            for y in 0..<h {
                for x in 0..<w where g.hole[y * w + x] {
                    var acc = SIMD3<Float>.zero
                    var m: Float = 0
                    if x > 0 { acc += g.pixels[y * w + x - 1]; m += 1 }
                    if x < w - 1 { acc += g.pixels[y * w + x + 1]; m += 1 }
                    if y > 0 { acc += g.pixels[(y - 1) * w + x]; m += 1 }
                    if y < h - 1 { acc += g.pixels[(y + 1) * w + x]; m += 1 }
                    g.pixels[y * w + x] = acc / m
                }
            }
        }
    }

    // MARK: Patches

    /// Centres whose whole patch is known pixels.
    private static func validSources(_ g: Grid) -> [Int32] {
        let w = g.width, h = g.height
        guard w > 2 * p, h > 2 * p else { return [] }
        // Integral image of the hole so each patch test is O(1).
        var integral = [Int32](repeating: 0, count: (w + 1) * (h + 1))
        for y in 0..<h {
            var row: Int32 = 0
            for x in 0..<w {
                row += g.hole[y * w + x] ? 1 : 0
                integral[(y + 1) * (w + 1) + x + 1] = integral[y * (w + 1) + x + 1] + row
            }
        }
        var out: [Int32] = []
        for y in p..<(h - p) {
            for x in p..<(w - p) {
                let x0 = x - p, x1 = x + p + 1, y0 = y - p, y1 = y + p + 1
                let count = integral[y1 * (w + 1) + x1] - integral[y0 * (w + 1) + x1]
                    - integral[y1 * (w + 1) + x0] + integral[y0 * (w + 1) + x0]
                if count == 0 { out.append(Int32(y * w + x)) }
            }
        }
        return out
    }

    /// Centres of every patch that touches the hole (clamped inside).
    private static func targetCentres(_ g: Grid) -> [Int32] {
        let w = g.width, h = g.height
        var mark = [Bool](repeating: false, count: w * h)
        for y in 0..<h {
            for x in 0..<w where g.hole[y * w + x] {
                for cy in max(p, y - p)...min(h - 1 - p, y + p) where h - 1 - p >= p {
                    for cx in max(p, x - p)...min(w - 1 - p, x + p) where w - 1 - p >= p {
                        mark[cy * w + cx] = true
                    }
                }
            }
        }
        var out: [Int32] = []
        for k in 0..<(w * h) where mark[k] { out.append(Int32(k)) }
        return out
    }

    @inline(__always)
    private static func distance(_ g: Grid, _ a: Int, _ b: Int, cutoff: Float) -> Float {
        let w = g.width
        var d: Float = 0
        for dy in -p...p {
            let ra = a + dy * w, rb = b + dy * w
            for dx in -p...p {
                let e = g.pixels[ra + dx] - g.pixels[rb + dx]
                d += (e * e).sum()
            }
            if d >= cutoff { return d }
        }
        return d
    }

    private static func upsampleField(_ coarse: [Int32], from: Grid?, to g: Grid,
                                      targets: [Int32], sources: [Int32], rng: inout SplitMix) -> [Int32] {
        let valid = Set(sources)
        var nnf = [Int32](repeating: -1, count: g.width * g.height)
        for t in targets {
            let tx = Int(t) % g.width, ty = Int(t) / g.width
            if let from, !coarse.isEmpty {
                let cx = min(from.width - 1, tx / 2), cy = min(from.height - 1, ty / 2)
                let m = Int(coarse[cy * from.width + cx])
                if m >= 0 {
                    let sx = 2 * (m % from.width) + (tx - 2 * cx)
                    let sy = 2 * (m / from.width) + (ty - 2 * cy)
                    let s = Int32(sy * g.width + sx)
                    if sx >= 0, sy >= 0, sx < g.width, sy < g.height, valid.contains(s) {
                        nnf[Int(t)] = s
                        continue
                    }
                }
            }
            nnf[Int(t)] = sources[Int(rng.next() % UInt64(sources.count))]
        }
        return nnf
    }

    private static func patchMatch(_ g: Grid, targets: [Int32], sources: [Int32], nnf: inout [Int32],
                                   rng: inout SplitMix, passes: Int) {
        let w = g.width, h = g.height
        // Validity lookup for candidate centres.
        var ok = [Bool](repeating: false, count: w * h)
        for s in sources { ok[Int(s)] = true }
        var best = [Float](repeating: .greatestFiniteMagnitude, count: w * h)
        for t in targets { best[Int(t)] = distance(g, Int(t), Int(nnf[Int(t)]), cutoff: .greatestFiniteMagnitude) }
        let maxRadius = max(w, h)

        for pass in 0..<passes {
            let forward = pass % 2 == 0
            let step = forward ? 1 : -1
            let order = forward ? Array(targets) : targets.reversed()
            for t32 in order {
                let t = Int(t32)
                let tx = t % w, ty = t / w
                var bestS = Int(nnf[t]), bestD = best[t]
                @inline(__always) func consider(_ s: Int) {
                    guard s >= 0, s < w * h, ok[s], s != bestS else { return }
                    let d = distance(g, t, s, cutoff: bestD)
                    if d < bestD { bestD = d; bestS = s }
                }
                // Propagation: a neighbour's match, shifted back by one.
                let nx = tx - step, ny = ty - step
                if nx >= 0, nx < w, nnf[ty * w + nx] >= 0 {
                    let s = Int(nnf[ty * w + nx]) + step
                    if (s % w) - step == Int(nnf[ty * w + nx]) % w { consider(s) }
                }
                if ny >= 0, ny < h, nnf[ny * w + tx] >= 0 {
                    consider(Int(nnf[ny * w + tx]) + step * w)
                }
                // Random search around the current best, shrinking.
                var radius = maxRadius
                while radius >= 1 {
                    let bx = bestS % w, by = bestS / w
                    let rx = bx + Int(rng.next() % UInt64(2 * radius + 1)) - radius
                    let ry = by + Int(rng.next() % UInt64(2 * radius + 1)) - radius
                    if rx >= 0, ry >= 0, rx < w, ry < h { consider(ry * w + rx) }
                    radius /= 2
                }
                nnf[t] = Int32(bestS)
                best[t] = bestD
            }
        }
    }

    /// Each hole pixel becomes the weighted average of what the patches
    /// covering it say it should be; closer matches count for more.
    private static func vote(_ g: inout Grid, targets: [Int32], nnf: [Int32]) {
        let w = g.width
        var dists: [Float] = []
        dists.reserveCapacity(targets.count)
        for t in targets { dists.append(distance(g, Int(t), Int(nnf[Int(t)]), cutoff: .greatestFiniteMagnitude)) }
        let sorted = dists.sorted()
        let sigma = max(1e-4, sorted[min(sorted.count - 1, sorted.count * 3 / 4)])
        var acc = [SIMD3<Float>](repeating: .zero, count: w * g.height)
        var wsum = [Float](repeating: 0, count: w * g.height)
        for (i, t32) in targets.enumerated() {
            let t = Int(t32), s = Int(nnf[t])
            let weight = exp(-dists[i] / (2 * sigma))
            for dy in -p...p {
                for dx in -p...p {
                    let q = t + dy * w + dx
                    guard g.hole[q] else { continue }
                    acc[q] += g.pixels[s + dy * w + dx] * weight
                    wsum[q] += weight
                }
            }
        }
        for k in 0..<(w * g.height) where g.hole[k] && wsum[k] > 0 {
            g.pixels[k] = acc[k] / wsum[k]
        }
    }
}

extension Inpaint {
    /// Each hole pixel takes the centre of its own patch's match.
    fileprivate static func sharpen(_ g: inout Grid, nnf: [Int32]) {
        let src = g.pixels
        for k in 0..<(g.width * g.height) where g.hole[k] && nnf[k] >= 0 {
            g.pixels[k] = src[Int(nnf[k])]
        }
    }
}

/// Small, fast, deterministic — the same spot fills the same way every
/// render.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
