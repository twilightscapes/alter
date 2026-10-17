//
//  FaceEmbedder.swift
//  Alter
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
//  "Who is this?" for Faces: OpenCV's SFace network, run straight from the
//  .onnx file OpenCV publishes (no converted copy of it exists anywhere).
//  A face — found and landmarked by Vision — is aligned to the 112×112
//  pose SFace was trained on, and comes out as 128 numbers; two faces of
//  the same person point the same way. Everything stays on this Mac.
//
//  SFace is a plain MobileFaceNet, so the reader below only knows the
//  handful of ONNX operations it uses, and builds them as an MPSGraph.
//

import CoreGraphics
import Foundation
import Metal
import MetalPerformanceShadersGraph

final class FaceEmbedder: @unchecked Sendable {
    /// The network's input side and output length.
    static let side = 112
    static let dimensions = 128

    private let graph = MPSGraph()
    private let input: MPSGraphTensor
    private let output: MPSGraphTensor
    private let device: MPSGraphDevice
    private let queue: MTLCommandQueue
    /// One run at a time — MPSGraph isn't re-entrant.
    private let lock = NSLock()

    enum Failure: LocalizedError {
        case noGPU, unreadable, unsupported(String)
        var errorDescription: String? {
            switch self {
            case .noGPU: return "Faces needs Metal, which this Mac doesn't offer."
            case .unreadable: return "The face recognition model is damaged. Turn Faces off and on to fetch it again."
            case .unsupported(let op): return "The face recognition model uses \(op), which Alter can't run."
            }
        }
    }

    init(modelAt url: URL) throws {
        guard let metal = MTLCreateSystemDefaultDevice(), let queue = metal.makeCommandQueue() else { throw Failure.noGPU }
        self.device = MPSGraphDevice(mtlDevice: metal)
        self.queue = queue
        let model = try ONNXModel(data: Data(contentsOf: url, options: .mappedIfSafe))
        (input, output) = try Self.build(model, in: graph)
    }

    /// 128-number fingerprints (unit length) for aligned faces — RGB
    /// planes, 0…255, `side`×`side` each — in one batch.
    func embed(_ faces: [[Float]]) -> [[Float]] {
        guard !faces.isEmpty else { return [] }
        let plane = 3 * Self.side * Self.side
        var batch = [Float]()
        batch.reserveCapacity(faces.count * plane)
        for face in faces where face.count == plane { batch += face }
        let count = batch.count / plane
        guard count > 0 else { return [] }
        let data = batch.withUnsafeBufferPointer { Data(buffer: $0) }
        let feed = MPSGraphTensorData(device: device, data: data,
                                      shape: [NSNumber(value: count), 3, NSNumber(value: Self.side), NSNumber(value: Self.side)],
                                      dataType: .float32)
        lock.lock()
        let result = graph.run(with: queue, feeds: [input: feed], targetTensors: [output], targetOperations: nil)
        lock.unlock()
        guard let out = result[output] else { return [] }
        var flat = [Float](repeating: 0, count: count * Self.dimensions)
        flat.withUnsafeMutableBufferPointer { out.mpsndarray().readBytes($0.baseAddress!, strideBytes: nil) }
        return (0..<count).map { i in
            let v = Array(flat[(i * Self.dimensions)..<((i + 1) * Self.dimensions)])
            let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
            return norm > 0 ? v.map { $0 / norm } : v
        }
    }

    // MARK: Graph

    private static func build(_ model: ONNXModel, in graph: MPSGraph) throws -> (MPSGraphTensor, MPSGraphTensor) {
        guard let inputName = model.inputs.first(where: { model.initializers[$0] == nil }),
              let outputName = model.outputs.first else { throw Failure.unreadable }
        let input = graph.placeholder(shape: [-1, 3, NSNumber(value: side), NSNumber(value: side)],
                                      dataType: .float32, name: inputName)
        var tensors: [String: MPSGraphTensor] = [inputName: input]
        var rank: [String: Int] = [inputName: 4]

        func constant(_ values: [Float], _ shape: [Int]) -> MPSGraphTensor {
            graph.constant(values.withUnsafeBufferPointer { Data(buffer: $0) },
                           shape: shape.map { NSNumber(value: $0) }, dataType: .float32)
        }
        /// A per-channel vector shaped to broadcast against a tensor of `r` dims.
        func channels(_ values: [Float], rank r: Int) -> MPSGraphTensor {
            constant(values, r == 4 ? [1, values.count, 1, 1] : [1, values.count])
        }
        func tensor(_ name: String) throws -> MPSGraphTensor {
            if let t = tensors[name] { return t }
            guard let t = model.initializers[name] else { throw Failure.unreadable }
            let made = constant(t.values, t.dims.isEmpty ? [1] : t.dims)
            tensors[name] = made
            return made
        }
        func weights(_ name: String) throws -> ONNXModel.Tensor {
            guard let t = model.initializers[name] else { throw Failure.unreadable }
            return t
        }

        for node in model.nodes {
            guard let first = node.inputs.first, let out = node.outputs.first else { throw Failure.unreadable }
            let r = rank[first] ?? 4
            let x = try tensor(first)
            let y: MPSGraphTensor
            var outRank = r
            switch node.op {
            case "Sub":
                y = graph.subtraction(x, try tensor(node.inputs[1]), name: nil)
            case "Mul":
                y = graph.multiplication(x, try tensor(node.inputs[1]), name: nil)
            case "Add":
                y = graph.addition(x, try tensor(node.inputs[1]), name: nil)
            case "Conv":
                let w = try weights(node.inputs[1])
                guard w.dims.count == 4 else { throw Failure.unsupported("a \(w.dims.count)-D convolution") }
                let strides = node.ints["strides"] ?? [1, 1]
                let pads = node.ints["pads"] ?? [0, 0, 0, 0]       // top, left, bottom, right
                let dilations = node.ints["dilations"] ?? [1, 1]
                guard let d = MPSGraphConvolution2DOpDescriptor(
                    strideInX: strides[1], strideInY: strides[0],
                    dilationRateInX: dilations[1], dilationRateInY: dilations[0],
                    groups: node.int("group") ?? 1,
                    paddingLeft: pads[1], paddingRight: pads[3], paddingTop: pads[0], paddingBottom: pads[2],
                    paddingStyle: .explicit, dataLayout: .NCHW, weightsLayout: .OIHW) else { throw Failure.unreadable }
                var conv = graph.convolution2D(x, weights: constant(w.values, w.dims), descriptor: d, name: nil)
                if node.inputs.count > 2 {
                    conv = graph.addition(conv, channels(try weights(node.inputs[2]).values, rank: 4), name: nil)
                }
                y = conv
            case "BatchNormalization":
                // Folded to one scale and shift per channel.
                let gamma = try weights(node.inputs[1]).values, beta = try weights(node.inputs[2]).values
                let mean = try weights(node.inputs[3]).values, variance = try weights(node.inputs[4]).values
                let eps = node.float("epsilon") ?? 1e-5
                let scale = zip(gamma, variance).map { $0 / sqrt($1 + eps) }
                let shift = (0..<beta.count).map { beta[$0] - mean[$0] * scale[$0] }
                y = graph.addition(graph.multiplication(x, channels(scale, rank: r), name: nil),
                                   channels(shift, rank: r), name: nil)
            case "PRelu":
                let slope = channels(try weights(node.inputs[1]).values, rank: r)
                let zero = graph.constant(0, dataType: .float32)
                y = graph.addition(graph.maximum(x, zero, name: nil),
                                   graph.multiplication(slope, graph.minimum(x, zero, name: nil), name: nil), name: nil)
            case "Relu":
                y = graph.reLU(with: x, name: nil)
            case "Dropout", "Identity":
                y = x
            case "Flatten":
                y = graph.reshape(x, shape: [-1, NSNumber(value: model.flattenedSize(after: first) ?? -1)], name: nil)
                outRank = 2
            case "Gemm":
                guard node.int("transA") ?? 0 == 0 else { throw Failure.unsupported("Gemm with transA") }
                let b = try weights(node.inputs[1])
                guard b.dims.count == 2 else { throw Failure.unreadable }
                // B laid out as (in × out) once, here.
                var w = b.values, shape = b.dims
                if node.int("transB") ?? 0 == 1 {
                    let (rows, cols) = (b.dims[0], b.dims[1])
                    for i in 0..<rows { for j in 0..<cols { w[j * rows + i] = b.values[i * cols + j] } }
                    shape = [cols, rows]
                }
                var gemm = graph.matrixMultiplication(primary: x, secondary: constant(w, shape), name: nil)
                if node.inputs.count > 2 {
                    gemm = graph.addition(gemm, channels(try weights(node.inputs[2]).values, rank: 2), name: nil)
                }
                y = gemm
                outRank = 2
            default:
                throw Failure.unsupported(node.op)
            }
            tensors[out] = y
            rank[out] = outRank
        }
        guard let output = tensors[outputName] else { throw Failure.unreadable }
        return (input, output)
    }
}

// MARK: - Alignment

enum FaceAligner {
    /// Where SFace expects the eyes, nose tip and mouth corners (image-left
    /// first), in its 112×112 frame — the ArcFace template OpenCV aligns to.
    static let template: [CGPoint] = [
        CGPoint(x: 38.2946, y: 51.6963), CGPoint(x: 73.5318, y: 51.5014), CGPoint(x: 56.0252, y: 71.7366),
        CGPoint(x: 41.5493, y: 92.3655), CGPoint(x: 70.7299, y: 92.2041),
    ]

    /// The face, rotated, scaled and moved so its five points land on the
    /// template (a least-squares similarity), as RGB planes ready for
    /// `FaceEmbedder.embed`. Points are in the image's pixels, top-left
    /// origin: left eye, right eye, nose tip, left and right mouth corner.
    static func align(_ image: CGImage, points: [CGPoint]) -> [Float]? {
        guard points.count == 5 else { return nil }
        let side = FaceEmbedder.side
        let height = CGFloat(image.height)
        // Both frames flipped to Core Graphics' bottom-left origin — a
        // similarity between flipped frames is the same similarity.
        let src = points.map { CGPoint(x: $0.x, y: height - $0.y) }
        let dst = template.map { CGPoint(x: $0.x, y: CGFloat(side) - $0.y) }
        let t = similarity(from: src, to: dst)

        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.concatenate(t)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))

        let plane = side * side
        var out = [Float](repeating: 0, count: 3 * plane)
        for i in 0..<plane {
            out[i] = Float(pixels[i * 4])
            out[plane + i] = Float(pixels[i * 4 + 1])
            out[2 * plane + i] = Float(pixels[i * 4 + 2])
        }
        return out
    }

    /// Least-squares rotation + uniform scale + translation taking `a` to `b`.
    static func similarity(from a: [CGPoint], to b: [CGPoint]) -> CGAffineTransform {
        let n = CGFloat(a.count)
        let ma = CGPoint(x: a.reduce(0) { $0 + $1.x } / n, y: a.reduce(0) { $0 + $1.y } / n)
        let mb = CGPoint(x: b.reduce(0) { $0 + $1.x } / n, y: b.reduce(0) { $0 + $1.y } / n)
        var dot: CGFloat = 0, cross: CGFloat = 0, spread: CGFloat = 0
        for (p, q) in zip(a, b) {
            let (px, py) = (p.x - ma.x, p.y - ma.y), (qx, qy) = (q.x - mb.x, q.y - mb.y)
            dot += px * qx + py * qy
            cross += px * qy - py * qx
            spread += px * px + py * py
        }
        guard spread > 0 else { return .identity }
        let c = dot / spread, s = cross / spread
        return CGAffineTransform(a: c, b: s, c: -s, d: c,
                                 tx: mb.x - (c * ma.x - s * ma.y), ty: mb.y - (s * ma.x + c * ma.y))
    }
}

// MARK: - ONNX, just enough

/// Reads an ONNX file's graph: its nodes, attributes and float weights.
/// (ONNX is a protocol buffer; this decodes the few fields Faces needs.)
struct ONNXModel {
    struct Tensor { var dims: [Int]; var values: [Float] }
    struct Node {
        var op = ""
        var inputs: [String] = []
        var outputs: [String] = []
        var ints: [String: [Int]] = [:]
        var floats: [String: [Float]] = [:]
        func int(_ name: String) -> Int? { ints[name]?.first }
        func float(_ name: String) -> Float? { floats[name]?.first }
    }

    var nodes: [Node] = []
    var initializers: [String: Tensor] = [:]
    var inputs: [String] = []
    var outputs: [String] = []

    init(data: Data) throws {
        var model = ProtoReader(data)
        var graphData: Data?
        while let (field, value) = try model.next() {
            if field == 7, case .bytes(let d) = value { graphData = d }
        }
        guard let graphData else { throw FaceEmbedder.Failure.unreadable }
        var graph = ProtoReader(graphData)
        while let (field, value) = try graph.next() {
            guard case .bytes(let d) = value else { continue }
            switch field {
            case 1: nodes.append(try Self.node(d))
            case 5:
                let (name, tensor) = try Self.tensor(d)
                initializers[name] = tensor
            case 11: inputs.append(try Self.valueInfoName(d))
            case 12: outputs.append(try Self.valueInfoName(d))
            default: break
            }
        }
        guard !nodes.isEmpty else { throw FaceEmbedder.Failure.unreadable }
    }

    /// What a Flatten after `name` produces per item: the Gemm that
    /// follows it says, through its weights' width.
    func flattenedSize(after name: String) -> Int? {
        guard let flatten = nodes.first(where: { $0.op == "Flatten" && $0.inputs.first == name }),
              let out = flatten.outputs.first,
              let gemm = nodes.first(where: { $0.op == "Gemm" && $0.inputs.first == out }),
              gemm.inputs.count > 1, let b = initializers[gemm.inputs[1]], b.dims.count == 2 else { return nil }
        return gemm.int("transB") == 1 ? b.dims[1] : b.dims[0]
    }

    private static func node(_ data: Data) throws -> Node {
        var node = Node()
        var r = ProtoReader(data)
        while let (field, value) = try r.next() {
            guard case .bytes(let d) = value else { continue }
            switch field {
            case 1: node.inputs.append(String(decoding: d, as: UTF8.self))
            case 2: node.outputs.append(String(decoding: d, as: UTF8.self))
            case 4: node.op = String(decoding: d, as: UTF8.self)
            case 5:
                var a = ProtoReader(d)
                var name = "", ints: [Int] = [], floats: [Float] = []
                while let (f, v) = try a.next() {
                    switch (f, v) {
                    case (1, .bytes(let s)): name = String(decoding: s, as: UTF8.self)
                    case (2, .fixed32(let bits)): floats.append(Float(bitPattern: bits))
                    case (3, .varint(let i)): ints.append(Int(Int64(bitPattern: i)))
                    case (7, .fixed32(let bits)): floats.append(Float(bitPattern: bits))
                    case (7, .bytes(let packed)): floats += ProtoReader.packedFloats(packed)
                    case (8, .varint(let i)): ints.append(Int(Int64(bitPattern: i)))
                    case (8, .bytes(let packed)): ints += try ProtoReader.packedVarints(packed)
                    default: break
                    }
                }
                if !ints.isEmpty { node.ints[name] = ints }
                if !floats.isEmpty { node.floats[name] = floats }
            default: break
            }
        }
        return node
    }

    private static func tensor(_ data: Data) throws -> (String, Tensor) {
        var r = ProtoReader(data)
        var name = "", dims: [Int] = [], values: [Float] = [], type: UInt64 = 1, raw: Data?
        while let (field, value) = try r.next() {
            switch (field, value) {
            case (1, .varint(let d)): dims.append(Int(d))
            case (1, .bytes(let packed)): dims += try ProtoReader.packedVarints(packed)
            case (2, .varint(let t)): type = t
            case (4, .fixed32(let bits)): values.append(Float(bitPattern: bits))
            case (4, .bytes(let packed)): values += ProtoReader.packedFloats(packed)
            case (8, .bytes(let s)): name = String(decoding: s, as: UTF8.self)
            case (9, .bytes(let d)): raw = d
            default: break
            }
        }
        guard type == 1 else { throw FaceEmbedder.Failure.unsupported("non-float weights") }
        if let raw { values = ProtoReader.packedFloats(raw) }
        guard values.count == max(1, dims.reduce(1, *)) else { throw FaceEmbedder.Failure.unreadable }
        return (name, Tensor(dims: dims, values: values))
    }

    private static func valueInfoName(_ data: Data) throws -> String {
        var r = ProtoReader(data)
        while let (field, value) = try r.next() {
            if field == 1, case .bytes(let s) = value { return String(decoding: s, as: UTF8.self) }
        }
        return ""
    }
}

/// Protocol buffer wire format, read forward.
struct ProtoReader {
    enum Value { case varint(UInt64), fixed64(UInt64), bytes(Data), fixed32(UInt32) }

    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = data
        self.offset = data.startIndex
    }

    mutating func next() throws -> (Int, Value)? {
        guard offset < data.endIndex else { return nil }
        let key = try varint()
        let field = Int(key >> 3)
        switch key & 7 {
        case 0: return (field, .varint(try varint()))
        case 1:
            guard offset + 8 <= data.endIndex else { throw FaceEmbedder.Failure.unreadable }
            var v: UInt64 = 0
            for i in 0..<8 { v |= UInt64(data[offset + i]) << (8 * UInt64(i)) }
            offset += 8
            return (field, .fixed64(v))
        case 2:
            let length = Int(try varint())
            guard length >= 0, offset + length <= data.endIndex else { throw FaceEmbedder.Failure.unreadable }
            let bytes = data[offset..<(offset + length)]
            offset += length
            return (field, .bytes(bytes))
        case 5:
            guard offset + 4 <= data.endIndex else { throw FaceEmbedder.Failure.unreadable }
            var v: UInt32 = 0
            for i in 0..<4 { v |= UInt32(data[offset + i]) << (8 * UInt32(i)) }
            offset += 4
            return (field, .fixed32(v))
        default:
            throw FaceEmbedder.Failure.unreadable
        }
    }

    private mutating func varint() throws -> UInt64 {
        var result: UInt64 = 0, shift: UInt64 = 0
        while offset < data.endIndex {
            let byte = data[offset]
            offset += 1
            result |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
            if shift > 63 { break }
        }
        throw FaceEmbedder.Failure.unreadable
    }

    /// Little-endian floats, as ONNX stores them (packed or raw).
    static func packedFloats(_ data: Data) -> [Float] {
        let count = data.count / 4
        var out = [Float](repeating: 0, count: count)
        out.withUnsafeMutableBytes { dest in
            data.withUnsafeBytes { src in dest.copyMemory(from: UnsafeRawBufferPointer(rebasing: src[0..<(count * 4)])) }
        }
        return out
    }

    static func packedVarints(_ data: Data) throws -> [Int] {
        var r = ProtoReader(data)
        var out: [Int] = []
        while r.offset < data.endIndex { out.append(Int(Int64(bitPattern: try r.varint()))) }
        return out
    }
}
