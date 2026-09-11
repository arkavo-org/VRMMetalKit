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

extension AuthorErrorCode {
    public static let malformedGLB: AuthorErrorCode = "MALFORMED_GLB"
    public static let exportFailed: AuthorErrorCode = "EXPORT_FAILED"
    public static let outputExists: AuthorErrorCode = "OUTPUT_EXISTS"
    public static let noOpEdit: AuthorErrorCode = "NO_OP_EDIT"
    public static let reportBindingMismatch: AuthorErrorCode = "REPORT_BINDING_MISMATCH"
    public static let inspectionMissing: AuthorErrorCode = "INSPECTION_MISSING"
    public static let inspectionStale: AuthorErrorCode = "INSPECTION_STALE"
    public static let inspectionFailed: AuthorErrorCode = "INSPECTION_FAILED"
    public static let inspectionUncertain: AuthorErrorCode = "INSPECTION_UNCERTAIN"
}

/// Binary glTF 2.0 container with one canonical JSON chunk and an optional BIN
/// chunk. The JSON chunk is space-padded and the BIN chunk zero-padded to 4 bytes.
public struct GLBFile: Hashable, Sendable {
    public var json: JSONValue
    public var bin: Data

    public static let magic: UInt32 = 0x4654_6C67
    public static let jsonChunk: UInt32 = 0x4E4F_534A
    public static let binChunk: UInt32 = 0x004E_4942

    public init(json: JSONValue, bin: Data) {
        self.json = json
        self.bin = bin
    }

    public static func parse(_ input: Data) throws -> GLBFile {
        let data = input.startIndex == 0 ? input : Data(input)
        func fail(_ message: String) -> AuthorError {
            AuthorError(code: .malformedGLB, path: "/", message: message, suggestedCommands: ["build"])
        }
        guard data.count >= 20 else { throw fail("GLB is shorter than the 12-byte header plus one chunk header.") }
        func u32(_ offset: Int) -> UInt32 { data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }.littleEndian }
        guard u32(0) == magic else { throw fail("GLB magic is not 'glTF'.") }
        guard u32(4) == 2 else { throw fail("GLB container version must be 2.") }
        let length = Int(u32(8))
        guard length == data.count else { throw fail("GLB header length \(length) does not match the file size \(data.count).") }
        guard length % 4 == 0 else { throw fail("GLB total length is not 4-byte aligned.") }
        var offset = 12
        var json: JSONValue?
        var bin: Data?
        var index = 0
        while offset < length {
            guard offset + 8 <= length else { throw fail("Truncated chunk header at byte \(offset).") }
            let chunkLength = Int(u32(offset))
            let chunkType = u32(offset + 4)
            guard chunkLength % 4 == 0 else { throw fail("Chunk \(index) length \(chunkLength) is not 4-byte aligned.") }
            guard offset + 8 + chunkLength <= length else { throw fail("Chunk \(index) overruns the file.") }
            let body = data.subdata(in: (offset + 8)..<(offset + 8 + chunkLength))
            switch chunkType {
            case jsonChunk:
                guard index == 0 else { throw fail("The JSON chunk must be the first chunk.") }
                guard json == nil else { throw fail("Duplicate JSON chunk.") }
                let trimmed = body.reversed().drop { $0 == 0x20 }.reversed()
                do { json = try JSONValue.parse(Data(trimmed)) } catch { throw fail("JSON chunk is not valid JSON: \(error)") }
            case binChunk:
                guard index == 1 else { throw fail("The BIN chunk must be the second chunk.") }
                guard bin == nil else { throw fail("Duplicate BIN chunk.") }
                bin = body
            default:
                break
            }
            offset += 8 + chunkLength
            index += 1
        }
        guard let json else { throw fail("Missing JSON chunk.") }
        guard json.object != nil else { throw fail("JSON chunk root is not an object.") }
        return GLBFile(json: json, bin: bin ?? Data())
    }

    public func serialize() throws -> Data {
        var jsonData = try CanonicalJSON.data(json)
        while jsonData.count % 4 != 0 { jsonData.append(0x20) }
        var binData = bin
        while binData.count % 4 != 0 { binData.append(0x00) }
        var out = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
        u32(GLBFile.magic)
        u32(2)
        u32(UInt32(12 + 8 + jsonData.count + (binData.isEmpty ? 0 : 8 + binData.count)))
        u32(UInt32(jsonData.count))
        u32(GLBFile.jsonChunk)
        out.append(jsonData)
        if !binData.isEmpty {
            u32(UInt32(binData.count))
            u32(GLBFile.binChunk)
            out.append(binData)
        }
        return out
    }
}

/// glTF accessor component types used by the writer and validator.
public enum GLTFComponentType: Int, Sendable {
    case unsignedByte = 5121
    case unsignedShort = 5123
    case unsignedInt = 5125
    case float = 5126

    public var byteSize: Int {
        switch self {
        case .unsignedByte: return 1
        case .unsignedShort: return 2
        case .unsignedInt, .float: return 4
        }
    }
}

public enum GLTFAccessorType: String, Sendable {
    case scalar = "SCALAR", vec2 = "VEC2", vec3 = "VEC3", vec4 = "VEC4", mat4 = "MAT4"

    public var componentCount: Int {
        switch self {
        case .scalar: return 1
        case .vec2: return 2
        case .vec3: return 3
        case .vec4: return 4
        case .mat4: return 16
        }
    }
}

/// A parsed VRM: the GLB plus typed accessor reads used by validation.
public struct VRMDocument: Sendable {
    public var glb: GLBFile
    public var sha256: String

    public var json: JSONValue { glb.json }
    public var bin: Data { glb.bin }

    public init(glb: GLBFile, sha256: String) {
        self.glb = glb
        self.sha256 = sha256
    }

    public var nodes: [JSONValue] { json["nodes"]?.array ?? [] }
    public var meshes: [JSONValue] { json["meshes"]?.array ?? [] }
    public var accessors: [JSONValue] { json["accessors"]?.array ?? [] }
    public var bufferViews: [JSONValue] { json["bufferViews"]?.array ?? [] }
    public var materials: [JSONValue] { json["materials"]?.array ?? [] }
    public var vrm: JSONValue? { json["extensions"]?["VRMC_vrm"] }
    public var springBone: JSONValue? { json["extensions"]?["VRMC_springBone"] }
    public var extensionsUsed: [String] { json["extensionsUsed"]?.array?.compactMap { $0.string } ?? [] }

    /// Byte range of an accessor within BIN when it is fully described and in bounds.
    public func accessorRange(_ index: Int) -> (offset: Int, length: Int, stride: Int, count: Int, componentType: GLTFComponentType, type: GLTFAccessorType)? {
        guard index >= 0, index < accessors.count, let accessor = accessors[index].object,
              let count = accessor["count"]?.int, count >= 0,
              let componentRaw = accessor["componentType"]?.int, let componentType = GLTFComponentType(rawValue: componentRaw),
              let typeRaw = accessor["type"]?.string, let type = GLTFAccessorType(rawValue: typeRaw),
              let viewIndex = accessor["bufferView"]?.int, viewIndex >= 0, viewIndex < bufferViews.count,
              let view = bufferViews[viewIndex].object, let viewLength = view["byteLength"]?.int else { return nil }
        let viewOffset = view["byteOffset"]?.int ?? 0
        let accessorOffset = accessor["byteOffset"]?.int ?? 0
        let elementSize = componentType.byteSize * type.componentCount
        let stride = view["byteStride"]?.int ?? elementSize
        guard stride >= elementSize else { return nil }
        let needed = count == 0 ? 0 : (count - 1) * stride + elementSize
        guard accessorOffset + needed <= viewLength, viewOffset + viewLength <= bin.count else { return nil }
        return (viewOffset + accessorOffset, needed, stride, count, componentType, type)
    }

    public func floats(accessor index: Int) -> [Float]? {
        guard let range = accessorRange(index), range.componentType == .float else { return nil }
        var out: [Float] = []
        out.reserveCapacity(range.count * range.type.componentCount)
        bin.withUnsafeBytes { raw in
            for element in 0..<range.count {
                let base = range.offset + element * range.stride
                for component in 0..<range.type.componentCount {
                    out.append(Float(bitPattern: raw.loadUnaligned(fromByteOffset: base + component * 4, as: UInt32.self).littleEndian))
                }
            }
        }
        return out
    }

    public func integers(accessor index: Int) -> [UInt32]? {
        guard let range = accessorRange(index), range.componentType != .float else { return nil }
        var out: [UInt32] = []
        out.reserveCapacity(range.count * range.type.componentCount)
        bin.withUnsafeBytes { raw in
            for element in 0..<range.count {
                let base = range.offset + element * range.stride
                for component in 0..<range.type.componentCount {
                    let at = base + component * range.componentType.byteSize
                    switch range.componentType {
                    case .unsignedByte: out.append(UInt32(raw.load(fromByteOffset: at, as: UInt8.self)))
                    case .unsignedShort: out.append(UInt32(raw.loadUnaligned(fromByteOffset: at, as: UInt16.self).littleEndian))
                    case .unsignedInt: out.append(raw.loadUnaligned(fromByteOffset: at, as: UInt32.self).littleEndian)
                    case .float: break
                    }
                }
            }
        }
        return out
    }

    /// Raw bytes of an accessor, used for byte-identity comparisons.
    public func bytes(accessor index: Int) -> Data? {
        guard let range = accessorRange(index) else { return nil }
        return bin.subdata(in: range.offset..<(range.offset + range.length))
    }
}

/// Parses GLB bytes into a `VRMDocument`.
public enum VRMReader {
    public static func read(_ data: Data) throws -> VRMDocument {
        VRMDocument(glb: try GLBFile.parse(data), sha256: SHA256Hex.hex(data))
    }

    public static func read(fileAt url: URL) throws -> VRMDocument {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AuthorError(code: .missingInput, path: url.path, message: "File not found: \(url.path).", suggestedCommands: ["build"])
        }
        return try read(try Data(contentsOf: url))
    }
}
