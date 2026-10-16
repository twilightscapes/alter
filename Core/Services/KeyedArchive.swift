//
//  KeyedArchive.swift
//  Alter
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
//  A small, dependency-free reader for the binary plists Aperture stores
//  its adjustments in (NSKeyedArchiver output). Foundation's unarchiver
//  refuses unknown classes (DGControlPoint, RKRetouchBrushStroke…), and its
//  plist parser hides UID objects behind private types — so this walks the
//  bplist00 object table directly and resolves the keyed-archive graph into
//  plain Swift values: [String: Any], [Any], String, Double, Int, Bool,
//  Data. Class entries resolve to nil; custom objects become dictionaries
//  carrying their fields plus "__class__".
//

import Foundation

enum BinaryPlist {
    indirect enum Value {
        case null
        case bool(Bool)
        case int(Int64)
        case real(Double)
        case date(Date)
        case data(Data)
        case string(String)
        case uid(Int)
        case array([Value])
        case dict([(Value, Value)])
    }

    enum ParseError: Error { case notBinaryPlist, malformed }

    static func parse(_ data: Data) throws -> Value {
        guard data.count > 40, data.prefix(8) == Data("bplist00".utf8) else {
            throw ParseError.notBinaryPlist
        }
        let bytes = [UInt8](data)
        // Trailer: 6 unused, offsetIntSize, objectRefSize, numObjects,
        // topObject, offsetTableOffset (all big-endian).
        let t = bytes.count - 32
        let offsetIntSize = Int(bytes[t + 6])
        let objectRefSize = Int(bytes[t + 7])
        let numObjects = Int(readUInt(bytes, at: t + 8, size: 8))
        let topObject = Int(readUInt(bytes, at: t + 16, size: 8))
        let offsetTableOffset = Int(readUInt(bytes, at: t + 24, size: 8))
        guard offsetTableOffset + numObjects * offsetIntSize <= bytes.count else {
            throw ParseError.malformed
        }
        var offsets: [Int] = []
        offsets.reserveCapacity(numObjects)
        for i in 0..<numObjects {
            offsets.append(Int(readUInt(bytes, at: offsetTableOffset + i * offsetIntSize, size: offsetIntSize)))
        }
        let reader = Reader(bytes: bytes, offsets: offsets, refSize: objectRefSize)
        return try reader.object(topObject)
    }

    private static func readUInt(_ b: [UInt8], at: Int, size: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<size { v = (v << 8) | UInt64(b[at + i]) }
        return v
    }

    private final class Reader {
        let bytes: [UInt8]
        let offsets: [Int]
        let refSize: Int
        var cache: [Int: Value] = [:]

        init(bytes: [UInt8], offsets: [Int], refSize: Int) {
            self.bytes = bytes; self.offsets = offsets; self.refSize = refSize
        }

        func object(_ index: Int) throws -> Value {
            if let cached = cache[index] { return cached }
            guard offsets.indices.contains(index) else { throw ParseError.malformed }
            var pos = offsets[index]
            guard pos < bytes.count else { throw ParseError.malformed }
            let marker = bytes[pos]
            let type = marker >> 4
            var count = Int(marker & 0x0F)
            pos += 1

            func readCount() throws {
                // 0xF means the count follows as an int object inline.
                if count == 0x0F {
                    let m = bytes[pos]
                    guard m >> 4 == 0x1 else { throw ParseError.malformed }
                    let n = 1 << Int(m & 0x0F)
                    pos += 1
                    count = Int(readUInt(bytes, at: pos, size: n))
                    pos += n
                }
            }

            let value: Value
            switch type {
            case 0x0:
                switch marker {
                case 0x00: value = .null
                case 0x08: value = .bool(false)
                case 0x09: value = .bool(true)
                default: value = .null
                }
            case 0x1:
                let n = 1 << count
                let raw = readUInt(bytes, at: pos, size: n)
                value = .int(n == 8 ? Int64(bitPattern: raw) : Int64(raw))
            case 0x2:
                let n = 1 << count
                let raw = readUInt(bytes, at: pos, size: n)
                value = .real(n == 4 ? Double(Float(bitPattern: UInt32(raw))) : Double(bitPattern: raw))
            case 0x3:
                let raw = readUInt(bytes, at: pos, size: 8)
                value = .date(Date(timeIntervalSinceReferenceDate: Double(bitPattern: raw)))
            case 0x4:
                try readCount()
                value = .data(Data(bytes[pos..<pos + count]))
            case 0x5:
                try readCount()
                value = .string(String(decoding: bytes[pos..<pos + count], as: UTF8.self))
            case 0x6:
                try readCount()
                var units: [UInt16] = []
                units.reserveCapacity(count)
                for i in 0..<count {
                    units.append(UInt16(bytes[pos + i * 2]) << 8 | UInt16(bytes[pos + i * 2 + 1]))
                }
                value = .string(String(decoding: units, as: UTF16.self))
            case 0x8:
                let n = count + 1
                value = .uid(Int(readUInt(bytes, at: pos, size: n)))
            case 0xA, 0xC:
                try readCount()
                var items: [Value] = []
                items.reserveCapacity(count)
                for i in 0..<count {
                    items.append(try object(Int(readUInt(bytes, at: pos + i * refSize, size: refSize))))
                }
                value = .array(items)
            case 0xD:
                try readCount()
                var pairs: [(Value, Value)] = []
                pairs.reserveCapacity(count)
                for i in 0..<count {
                    let k = try object(Int(readUInt(bytes, at: pos + i * refSize, size: refSize)))
                    let v = try object(Int(readUInt(bytes, at: pos + (count + i) * refSize, size: refSize)))
                    pairs.append((k, v))
                }
                value = .dict(pairs)
            default:
                throw ParseError.malformed
            }
            cache[index] = value
            return value
        }
    }
}

/// NSKeyedArchiver graph → plain values.
enum KeyedArchive {
    static func unwrap(_ data: Data) throws -> Any? {
        let root = try BinaryPlist.parse(data)
        guard case .dict(let top) = root else { return nil }
        var objects: [BinaryPlist.Value] = []
        var topRef: Int?
        for (k, v) in top {
            guard case .string(let key) = k else { continue }
            if key == "$objects", case .array(let items) = v { objects = items }
            if key == "$top", case .dict(let pairs) = v {
                for (tk, tv) in pairs where { if case .string("root") = tk { return true } else { return false } }() {
                    if case .uid(let u) = tv { topRef = u }
                }
            }
        }
        guard let topRef else { return nil }
        return resolve(.uid(topRef), objects: objects, depth: 0)
    }

    private static func resolve(_ v: BinaryPlist.Value, objects: [BinaryPlist.Value], depth: Int) -> Any? {
        guard depth < 64 else { return nil }
        switch v {
        case .null: return nil
        case .bool(let b): return b
        case .int(let i): return Int(i)
        case .real(let d): return d
        case .date(let d): return d
        case .data(let d): return d
        case .string(let s): return s == "$null" ? nil : s
        case .uid(let u):
            guard objects.indices.contains(u) else { return nil }
            return resolve(objects[u], objects: objects, depth: depth + 1)
        case .array(let items):
            return items.map { resolve($0, objects: objects, depth: depth + 1) as Any }
        case .dict(let pairs):
            var fields: [String: BinaryPlist.Value] = [:]
            for (k, val) in pairs {
                if case .string(let key) = k { fields[key] = val }
            }
            if fields["$classname"] != nil { return nil }           // a class table entry
            if let keys = fields["NS.keys"], let vals = fields["NS.objects"],
               case .array(let ks) = keys, case .array(let vs) = vals {
                var out: [String: Any] = [:]
                for (k, val) in zip(ks, vs) {
                    let key = resolve(k, objects: objects, depth: depth + 1)
                    out[key.map { "\($0)" } ?? "null"] = resolve(val, objects: objects, depth: depth + 1)
                }
                return out
            }
            if let vals = fields["NS.objects"], case .array(let vs) = vals {
                return vs.map { resolve($0, objects: objects, depth: depth + 1) as Any }
            }
            if let s = fields["NS.string"] { return resolve(s, objects: objects, depth: depth + 1) }
            if let d = fields["NS.data"] { return resolve(d, objects: objects, depth: depth + 1) }
            var out: [String: Any] = [:]
            for (key, val) in fields where key != "$class" {
                out[key] = resolve(val, objects: objects, depth: depth + 1)
            }
            if let cls = fields["$class"], case .uid(let u) = cls, objects.indices.contains(u),
               case .dict(let cpairs) = objects[u] {
                for (ck, cv) in cpairs {
                    if case .string("$classname") = ck, case .string(let name) = cv { out["__class__"] = name }
                }
            }
            return out
        }
    }
}
