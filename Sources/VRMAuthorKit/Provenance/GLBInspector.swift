//
// Copyright 2026 Arkavo
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

import Foundation

/// Foundation-only reader for a glTF asset: a glb container (JSON chunk +
/// optional BIN chunk) or a stand-alone JSON glTF document. Read-only; the
/// imported bytes are never rewritten.
public struct GLTFDocument: Sendable {
    public var json: JSONValue
    public var bin: Data?
    public var isBinary: Bool

    public static let magic = Data("glTF".utf8)
    static let jsonChunk: UInt32 = 0x4E4F534A
    static let binChunk: UInt32 = 0x004E4942

    public static func isGLB(_ data: Data) -> Bool {
        data.count >= 12 && data.prefix(4) == magic
    }

    public init(data: Data, path: String) throws {
        if GLTFDocument.isGLB(data) {
            let (json, bin) = try GLTFDocument.parseGLB(data, path: path)
            self.json = json
            self.bin = bin
            self.isBinary = true
            return
        }
        guard let first = data.first(where: { $0 != 0x20 && $0 != 0x09 && $0 != 0x0A && $0 != 0x0D }), first == UInt8(ascii: "{") else {
            throw AuthorError(code: .invalidRequest, path: path, message: "File is neither a glb container (missing 'glTF' magic) nor a JSON glTF document.",
                              suggestedCommands: ["asset import --kind png"])
        }
        self.json = try GLTFDocument.parseJSONChunk(data, path: path)
        self.bin = nil
        self.isBinary = false
    }

    private static func parseGLB(_ data: Data, path: String) throws -> (JSONValue, Data?) {
        func u32(_ offset: Int) -> UInt32 {
            data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }.littleEndian
        }
        let version = u32(4)
        guard version == 2 else {
            throw AuthorError(code: .invalidRequest, path: path, observed: .number(Double(version)), required: 2, message: "Unsupported glb container version.")
        }
        var offset = 12
        var json: JSONValue?
        var bin: Data?
        while offset + 8 <= data.count {
            let length = Int(u32(offset))
            let type = u32(offset + 4)
            guard offset + 8 + length <= data.count else {
                throw AuthorError(code: .invalidRequest, path: path, message: "Truncated glb chunk at byte \(offset).")
            }
            let chunk = data.subdata(in: (offset + 8)..<(offset + 8 + length))
            if type == jsonChunk, json == nil {
                json = try parseJSONChunk(chunk, path: path)
            } else if type == binChunk, bin == nil {
                bin = chunk
            }
            offset += 8 + length
        }
        guard let json else { throw AuthorError(code: .invalidRequest, path: path, message: "glb container has no JSON chunk.") }
        return (json, bin)
    }

    private static func parseJSONChunk(_ chunk: Data, path: String) throws -> JSONValue {
        do {
            return try JSONValue.parse(chunk)
        } catch {
            guard let object = try? JSONSerialization.jsonObject(with: chunk), let converted = JSONValue(foundation: object) else {
                throw AuthorError(code: .invalidRequest, path: path, message: "glTF JSON chunk is not valid JSON: \(error)")
            }
            return converted
        }
    }

    // MARK: Accessors

    public var extensionsUsed: [String] { (json["extensionsUsed"]?.array ?? []).compactMap(\.string) }
    public var extensionsRequired: [String] { (json["extensionsRequired"]?.array ?? []).compactMap(\.string) }
    public var rootExtensions: [String] { (json["extensions"]?.object ?? [:]).keys.sorted() }

    /// Reads the integer elements of a scalar accessor (index buffers) from the BIN chunk.
    public func scalarIndices(accessor index: Int) -> [UInt32]? {
        guard let bin, let accessor = json["accessors"]?[index], let viewIndex = accessor["bufferView"]?.int,
              let view = json["bufferViews"]?[viewIndex], let count = accessor["count"]?.int, let componentType = accessor["componentType"]?.int,
              accessor["type"]?.string == "SCALAR", view["buffer"]?.int == 0 else { return nil }
        let size: Int
        switch componentType {
        case 5121: size = 1
        case 5123: size = 2
        case 5125: size = 4
        default: return nil
        }
        let stride = view["byteStride"]?.int ?? size
        let start = (view["byteOffset"]?.int ?? 0) + (accessor["byteOffset"]?.int ?? 0)
        guard start >= 0, count >= 0, start + (count - 1) * stride + size <= bin.count else { return nil }
        var out: [UInt32] = []
        out.reserveCapacity(count)
        bin.withUnsafeBytes { raw in
            for i in 0..<count {
                let at = start + i * stride
                switch size {
                case 1: out.append(UInt32(raw.load(fromByteOffset: at, as: UInt8.self)))
                case 2: out.append(UInt32(raw.loadUnaligned(fromByteOffset: at, as: UInt16.self).littleEndian))
                default: out.append(raw.loadUnaligned(fromByteOffset: at, as: UInt32.self).littleEndian)
                }
            }
        }
        return out
    }
}

extension JSONValue {
    /// Lossy bridge from JSONSerialization output for documents the strict parser rejects.
    init?(foundation: Any) {
        switch foundation {
        case is NSNull: self = .null
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { self = .bool(n.boolValue) } else {
                let d = n.doubleValue
                guard d.isFinite else { return nil }
                self = .number(d)
            }
        case let s as String: self = .string(s)
        case let a as [Any]:
            var out: [JSONValue] = []
            for e in a { guard let v = JSONValue(foundation: e) else { return nil }; out.append(v) }
            self = .array(out)
        case let o as [String: Any]:
            var out: [String: JSONValue] = [:]
            for (k, e) in o { guard let v = JSONValue(foundation: e) else { return nil }; out[k] = v }
            self = .object(out)
        default: return nil
        }
    }
}

/// What the tool observed in an imported glTF/VRM and what it can round-trip.
public struct PreservationReport: Codable, Hashable, Sendable {
    public static let roundTripExtensions = ["VRMC_vrm", "VRMC_materials_mtoon", "VRMC_springBone"]

    public var isBinary: Bool
    public var generator: String?
    public var assetVersion: String?
    public var nodes: Int
    public var meshes: Int
    public var primitives: Int
    public var triangles: Int
    public var degenerateTriangles: Int
    public var unindexedPrimitives: Int
    public var materials: Int
    public var images: [String]
    public var textures: Int
    public var skins: Int
    public var extensionsUsed: [String]
    public var extensionsRequired: [String]
    public var rootExtensions: [String]
    public var roundTripExtensions: [String]
    public var preservedOpaqueExtensions: [String]
    public var vrmSpecVersion: String?
    public var humanoidPresent: Bool
    public var humanBones: Int
    public var expressions: Int
    public var springs: Int
    public var colliders: Int
    public var colliderGroups: Int
    public var metaName: String?
    public var metaAuthors: [String]

    public init(document: GLTFDocument) {
        let json = document.json
        isBinary = document.isBinary
        generator = json["asset"]?["generator"]?.string
        assetVersion = json["asset"]?["version"]?.string
        nodes = json["nodes"]?.array?.count ?? 0
        let meshList = json["meshes"]?.array ?? []
        meshes = meshList.count
        var primitiveCount = 0
        var triangleCount = 0
        var degenerate = 0
        var unindexed = 0
        for mesh in meshList {
            for primitive in mesh["primitives"]?.array ?? [] {
                primitiveCount += 1
                let mode = primitive["mode"]?.int ?? 4
                guard let indicesAccessor = primitive["indices"]?.int else {
                    unindexed += 1
                    if mode == 4, let position = primitive["attributes"]?["POSITION"]?.int, let count = json["accessors"]?[position]?["count"]?.int { triangleCount += count / 3 }
                    continue
                }
                guard mode == 4 else { continue }
                if let indices = document.scalarIndices(accessor: indicesAccessor) {
                    var i = 0
                    while i + 2 < indices.count {
                        triangleCount += 1
                        if indices[i] == indices[i + 1] || indices[i + 1] == indices[i + 2] || indices[i] == indices[i + 2] { degenerate += 1 }
                        i += 3
                    }
                } else if let count = json["accessors"]?[indicesAccessor]?["count"]?.int {
                    triangleCount += count / 3
                }
            }
        }
        primitives = primitiveCount
        triangles = triangleCount
        degenerateTriangles = degenerate
        unindexedPrimitives = unindexed
        materials = json["materials"]?.array?.count ?? 0
        images = (json["images"]?.array ?? []).enumerated().map { index, image in image["name"]?.string ?? image["uri"]?.string ?? "image[\(index)]" }
        textures = json["textures"]?.array?.count ?? 0
        skins = json["skins"]?.array?.count ?? 0
        extensionsUsed = document.extensionsUsed
        extensionsRequired = document.extensionsRequired
        rootExtensions = document.rootExtensions
        let present = Set(document.extensionsUsed).union(document.rootExtensions)
        roundTripExtensions = PreservationReport.roundTripExtensions.filter { present.contains($0) }
        preservedOpaqueExtensions = present.subtracting(PreservationReport.roundTripExtensions).sorted()
        let vrm = json["extensions"]?["VRMC_vrm"]
        vrmSpecVersion = vrm?["specVersion"]?.string
        let bones = vrm?["humanoid"]?["humanBones"]?.object ?? [:]
        humanoidPresent = vrm?["humanoid"] != nil
        humanBones = bones.count
        let presets = vrm?["expressions"]?["preset"]?.object?.count ?? 0
        let customs = vrm?["expressions"]?["custom"]?.object?.count ?? 0
        expressions = presets + customs
        let spring = json["extensions"]?["VRMC_springBone"]
        springs = spring?["springs"]?.array?.count ?? 0
        colliders = spring?["colliders"]?.array?.count ?? 0
        colliderGroups = spring?["colliderGroups"]?.array?.count ?? 0
        metaName = vrm?["meta"]?["name"]?.string
        metaAuthors = (vrm?["meta"]?["authors"]?.array ?? []).compactMap(\.string)
    }

    /// The `lossReport` shape from the import result schema: nothing is lost or
    /// converted by an import because the original bytes are stored verbatim.
    public var lossReport: JSONValue {
        var preserved = roundTripExtensions.map { "extension:\($0)" } + preservedOpaqueExtensions.map { "extension:\($0) (opaque)" }
        preserved += ["nodes:\(nodes)", "meshes:\(meshes)", "primitives:\(primitives)", "materials:\(materials)", "images:\(images.count)", "skins:\(skins)"]
        if humanoidPresent { preserved.append("humanoid:\(humanBones)") }
        if expressions > 0 { preserved.append("expressions:\(expressions)") }
        if springs > 0 { preserved.append("springs:\(springs)") }
        return ["preserved": JSONValue(preserved), "lost": [], "converted": []]
    }
}

/// Cheap facts about an imported raster image: format sniffed from magic bytes
/// and the dimensions from the header.
public struct ImageFacts: Codable, Hashable, Sendable {
    public var format: String
    public var width: Int?
    public var height: Int?

    public static func sniff(_ data: Data) -> ImageFacts? {
        if data.count >= 24, data.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            let w = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 16, as: UInt32.self).bigEndian }
            let h = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 20, as: UInt32.self).bigEndian }
            return ImageFacts(format: "png", width: Int(w), height: Int(h))
        }
        if data.count >= 4, data[0] == 0xFF, data[1] == 0xD8, data[2] == 0xFF {
            var facts = ImageFacts(format: "jpeg", width: nil, height: nil)
            var offset = 2
            while offset + 9 < data.count, data[offset] == 0xFF {
                let marker = data[offset + 1]
                if marker == 0xD8 || (0xD0...0xD7).contains(marker) || marker == 0x01 { offset += 2; continue }
                let length = Int(data[offset + 2]) << 8 | Int(data[offset + 3])
                if [0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF].contains(marker) {
                    facts.height = Int(data[offset + 5]) << 8 | Int(data[offset + 6])
                    facts.width = Int(data[offset + 7]) << 8 | Int(data[offset + 8])
                    break
                }
                offset += 2 + length
            }
            return facts
        }
        return nil
    }
}
