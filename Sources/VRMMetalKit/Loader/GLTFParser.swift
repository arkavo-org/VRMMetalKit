//
// Copyright 2025 Arkavo
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
import simd

// MARK: - GLTF Document Structure

/// Root of a parsed glTF 2.0 document.
///
/// ## Discussion
/// Mirrors the top-level object defined by the
/// [glTF 2.0 spec](https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html#reference-gltf).
/// Each array is optional and indexed by the integer references that appear
/// throughout the rest of the document (for example, a primitive's
/// `material` index refers into ``materials``).
///
/// VRMMetalKit produces `GLTFDocument` values from
/// ``GLTFParser/parse(data:filePath:)`` and consumes them via
/// ``BufferLoader``, ``TextureLoader``, and ``VRMExtensionParser``. Application
/// code rarely interacts with this type directly; ``VRMModel/gltf`` exposes
/// it for advanced inspection.
public struct GLTFDocument: Codable {
    /// glTF version metadata. Mandatory per the spec.
    public let asset: GLTFAsset
    /// Index of the default scene in ``scenes``, or `nil` to leave the choice to the consumer.
    public let scene: Int?
    /// All scenes in the document.
    public let scenes: [GLTFScene]?
    /// All nodes; reference each other by index via `GLTFNode.children`.
    public let nodes: [GLTFNode]?
    /// All meshes, each a bag of one or more ``GLTFPrimitive``.
    public let meshes: [GLTFMesh]?
    /// All materials.
    public let materials: [GLTFMaterial]?
    /// Texture entries pairing a sampler with an image source.
    public let textures: [GLTFTexture]?
    /// Images, either embedded in a buffer view or referenced by URI.
    public let images: [GLTFImage]?
    /// Sampler configurations referenced by ``textures``.
    public let samplers: [GLTFSampler]?
    /// Top-level buffers (GLB chunks, external `.bin` files, or `data:` URIs).
    public let buffers: [GLTFBuffer]?
    /// Sub-ranges of buffers used by accessors and images.
    public let bufferViews: [GLTFBufferView]?
    /// Accessors describing typed views of buffer views.
    public let accessors: [GLTFAccessor]?
    /// Skins for skeletal animation, each holding joint indices and an optional inverse-bind-matrix accessor.
    public let skins: [GLTFSkin]?
    /// Channel-and-sampler animation tracks.
    public let animations: [GLTFAnimation]?
    /// Raw extension dictionary (used for `VRMC_*` and other glTF extensions). Values are heterogeneous JSON.
    public let extensions: [String: Any]?
    /// Names of extensions referenced anywhere in the document.
    public let extensionsUsed: [String]?
    /// Names of extensions a consumer must support to load this document.
    public let extensionsRequired: [String]?

    /// In-memory binary chunk (GLB only). Populated for GLB-sourced documents; ignored by JSON encoding.
    public var binaryBufferData: Data?

    enum CodingKeys: String, CodingKey {
        case asset, scene, scenes, nodes, meshes, materials
        case textures, images, samplers, buffers, bufferViews
        case accessors, skins, animations, extensions
        case extensionsUsed, extensionsRequired
    }

    /// Decodes a glTF document from JSON, treating `extensions` as a heterogeneous dictionary.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        asset = try container.decode(GLTFAsset.self, forKey: .asset)
        scene = try container.decodeIfPresent(Int.self, forKey: .scene)
        scenes = try container.decodeIfPresent([GLTFScene].self, forKey: .scenes)
        nodes = try container.decodeIfPresent([GLTFNode].self, forKey: .nodes)
        meshes = try container.decodeIfPresent([GLTFMesh].self, forKey: .meshes)
        materials = try container.decodeIfPresent([GLTFMaterial].self, forKey: .materials)
        textures = try container.decodeIfPresent([GLTFTexture].self, forKey: .textures)
        images = try container.decodeIfPresent([GLTFImage].self, forKey: .images)
        samplers = try container.decodeIfPresent([GLTFSampler].self, forKey: .samplers)
        buffers = try container.decodeIfPresent([GLTFBuffer].self, forKey: .buffers)
        bufferViews = try container.decodeIfPresent([GLTFBufferView].self, forKey: .bufferViews)
        accessors = try container.decodeIfPresent([GLTFAccessor].self, forKey: .accessors)
        skins = try container.decodeIfPresent([GLTFSkin].self, forKey: .skins)
        animations = try container.decodeIfPresent([GLTFAnimation].self, forKey: .animations)
        extensionsUsed = try container.decodeIfPresent([String].self, forKey: .extensionsUsed)
        extensionsRequired = try container.decodeIfPresent([String].self, forKey: .extensionsRequired)

        // Decode extensions as generic dictionary
        if container.contains(.extensions) {
            // Use AnyCodable to handle arbitrary extension data
            let extensionsDict = try container.decodeIfPresent([String: AnyCodable].self, forKey: .extensions)
            extensions = extensionsDict?.mapValues { $0.value }
        } else {
            extensions = nil
        }
    }

    /// Encodes the document to JSON. The `extensions` dictionary is currently elided on encode.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(asset, forKey: .asset)
        try container.encodeIfPresent(scene, forKey: .scene)
        try container.encodeIfPresent(scenes, forKey: .scenes)
        try container.encodeIfPresent(nodes, forKey: .nodes)
        try container.encodeIfPresent(meshes, forKey: .meshes)
        try container.encodeIfPresent(materials, forKey: .materials)
        try container.encodeIfPresent(textures, forKey: .textures)
        try container.encodeIfPresent(images, forKey: .images)
        try container.encodeIfPresent(samplers, forKey: .samplers)
        try container.encodeIfPresent(buffers, forKey: .buffers)
        try container.encodeIfPresent(bufferViews, forKey: .bufferViews)
        try container.encodeIfPresent(accessors, forKey: .accessors)
        try container.encodeIfPresent(skins, forKey: .skins)
        try container.encodeIfPresent(animations, forKey: .animations)
        try container.encodeIfPresent(extensionsUsed, forKey: .extensionsUsed)
        try container.encodeIfPresent(extensionsRequired, forKey: .extensionsRequired)
    }
}

// MARK: - GLTF Components

/// A glTF 2.0 [asset](https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html#asset) header.
public struct GLTFAsset: Codable {
    /// glTF version string (must be `"2.0"` for files this package loads).
    public let version: String
    /// Free-form exporter identifier (e.g. `"VRoid Studio v1.x"`).
    public let generator: String?
    /// Copyright notice supplied by the exporter.
    public let copyright: String?
    /// Minimum glTF version a consumer must support to load this file.
    public let minVersion: String?
}

/// A glTF 2.0 [scene](https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html#scenes): an ordered list of root node indices.
public struct GLTFScene: Codable {
    /// Optional scene name.
    public let name: String?
    /// Root nodes for this scene (indices into ``GLTFDocument/nodes``).
    public let nodes: [Int]?
}

/// A glTF 2.0 [node](https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html#nodes): a transform plus optional mesh, skin, and children.
///
/// Transform is given as either a single 16-float `matrix`, or a TRS triple
/// (`translation`, `rotation`, `scale`). VRM models always use TRS so that
/// animation can mutate components independently.
public struct GLTFNode: Codable {
    /// Optional node name. VRM relies on these for humanoid bone matching when no `VRMC_vrm.humanoid` entry maps the bone explicitly.
    public let name: String?
    /// Indices of child nodes.
    public let children: [Int]?
    /// 4x4 transform in column-major order, mutually exclusive with TRS.
    public let matrix: [Float]?
    /// TRS translation `[x, y, z]`.
    public let translation: [Float]?
    /// TRS rotation quaternion `[x, y, z, w]`.
    public let rotation: [Float]?
    /// TRS scale `[x, y, z]`.
    public let scale: [Float]?
    /// Mesh index attached to this node, if any.
    public let mesh: Int?
    /// Skin index attached to this node, if any.
    public let skin: Int?
    /// Per-node morph-target weight overrides.
    public let weights: [Float]?
    /// Raw node-level extensions (used by `VRMC_node_constraint`).
    public let extensions: [String: AnyCodable]?
}

/// A glTF 2.0 [mesh](https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html#meshes): a bag of one or more renderable primitives.
public struct GLTFMesh: Codable {
    /// Optional mesh name.
    public let name: String?
    /// Renderable primitives; each becomes one VRMMetalKit ``VRMPrimitive``.
    public let primitives: [GLTFPrimitive]
    /// Default morph-target weights for this mesh.
    public let weights: [Float]?
    /// Vendor-specific extras, used here to surface morph-target names.
    public let extras: GLTFMeshExtras?
}

/// Mesh `extras` block carrying morph-target names exported by VRoid and similar tools.
public struct GLTFMeshExtras: Codable {
    /// Display names for each morph target, in target-array order.
    public let targetNames: [String]?
}

/// A glTF 2.0 [mesh primitive](https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html#meshes-overview). See the spec for attribute and index semantics.
public struct GLTFPrimitive: Codable {
    /// Vertex attribute accessors keyed by semantic (`"POSITION"`, `"NORMAL"`, `"TEXCOORD_0"`, `"JOINTS_0"`, `"WEIGHTS_0"`, …).
    public let attributes: [String: Int]
    /// Optional index accessor. When `nil`, vertices are drawn in attribute order.
    public let indices: Int?
    /// Material index applied to this primitive.
    public let material: Int?
    /// Drawing mode (glTF constant; `4` = triangles).
    public let mode: Int?
    /// Morph target deltas, parallel to the parent mesh's target weights.
    public let targets: [GLTFMorphTarget]?
}

/// A glTF 2.0 [morph target](https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html#morph-targets) referencing delta accessors.
public struct GLTFMorphTarget: Codable {
    /// Accessor of `POSITION` deltas.
    public let position: Int?
    /// Accessor of `NORMAL` deltas.
    public let normal: Int?
    /// Accessor of `TANGENT` deltas.
    public let tangent: Int?
    /// Per-target extras (e.g. names attached by some exporters).
    public let extra: [String: AnyCodable]?

    enum CodingKeys: String, CodingKey {
        case position = "POSITION"
        case normal = "NORMAL"
        case tangent = "TANGENT"
        case extra
    }
}

/// Type-erased wrapper that decodes arbitrary JSON values from `Codable` containers.
///
/// Used to preserve unknown extension payloads (`VRMC_*`, `KHR_*`) on
/// ``GLTFDocument/extensions``, ``GLTFNode/extensions``, and similar fields.
/// Decoding checks for `null` first, then tries `Bool`, `Int`, `Double`,
/// `Float`, `String`, dictionary, and array; JSON `null` and unrecognised
/// types both decode as `NSNull`.
public struct AnyCodable: Codable {
    /// Decoded JSON value. Concrete types are `Bool`, `Int`, `Double`, `Float`, `String`, `[String: Any]`, `[Any]`, or `NSNull`.
    public let value: Any

    /// Wraps an existing value without decoding.
    public init(_ value: Any) {
        self.value = value
    }

    /// Decodes any JSON scalar, array, or object into the underlying ``value``.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        // Try decoding in order of most common types
        if container.decodeNil() {
            value = NSNull()
        } else if let boolValue = try? container.decode(Bool.self) {
            value = boolValue
        } else if let intValue = try? container.decode(Int.self) {
            value = intValue
        } else if let doubleValue = try? container.decode(Double.self) {
            value = doubleValue
        } else if let floatValue = try? container.decode(Float.self) {
            value = floatValue
        } else if let stringValue = try? container.decode(String.self) {
            value = stringValue
        } else if let dictValue = try? container.decode([String: AnyCodable].self) {
            value = dictValue.mapValues { $0.value }
        } else if let arrayValue = try? container.decode([AnyCodable].self) {
            value = arrayValue.map { $0.value }
        } else {
            // If all else fails, store as NSNull
            value = NSNull()
        }
    }

    /// Re-encodes the underlying value into a `Codable` container, mirroring the decode-time type detection.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch value {
        case is NSNull:
            try container.encodeNil()
        case let boolValue as Bool:
            try container.encode(boolValue)
        case let intValue as Int:
            try container.encode(intValue)
        case let doubleValue as Double:
            try container.encode(doubleValue)
        case let floatValue as Float:
            try container.encode(floatValue)
        case let stringValue as String:
            try container.encode(stringValue)
        case let dictValue as [String: Any]:
            let encodableDict = dictValue.mapValues { AnyCodable($0) }
            try container.encode(encodableDict)
        case let arrayValue as [Any]:
            let encodableArray = arrayValue.map { AnyCodable($0) }
            try container.encode(encodableArray)
        default:
            // For unknown types, encode as nil
            try container.encodeNil()
        }
    }
}

/// A glTF 2.0 [material](https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html#materials), parsed with VRM extension support.
///
/// `extensions` preserves `VRMC_materials_mtoon` and `KHR_materials_unlit`
/// payloads so ``VRMMToonMaterial`` and ``VRMMaterial`` can interpret them.
public struct GLTFMaterial: Codable {
    /// Material name (matched against VRM 0.x material property entries).
    public let name: String?
    /// PBR base-color and metallic-roughness inputs.
    public let pbrMetallicRoughness: GLTFPBRMetallicRoughness?
    /// Normal map texture and scale.
    public let normalTexture: GLTFNormalTextureInfo?
    /// Occlusion texture and strength.
    public let occlusionTexture: GLTFOcclusionTextureInfo?
    /// Emissive map.
    public let emissiveTexture: GLTFTextureInfo?
    /// Emissive RGB multiplier `[r, g, b]`.
    public let emissiveFactor: [Float]?
    /// One of `"OPAQUE"`, `"MASK"`, `"BLEND"`.
    public let alphaMode: String?
    /// Alpha threshold for `"MASK"` mode (defaults to 0.5 per spec).
    public let alphaCutoff: Float?
    /// Whether to render back-faces.
    public let doubleSided: Bool?
    /// Material-level extensions (used for VRM MToon).
    public let extensions: [String: Any]?

    enum CodingKeys: String, CodingKey {
        case name, pbrMetallicRoughness, normalTexture
        case occlusionTexture, emissiveTexture, emissiveFactor
        case alphaMode, alphaCutoff, doubleSided, extensions
    }

    /// Decodes the material, preserving the raw `extensions` dictionary for VRM MToon parsing.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        pbrMetallicRoughness = try container.decodeIfPresent(GLTFPBRMetallicRoughness.self, forKey: .pbrMetallicRoughness)
        normalTexture = try container.decodeIfPresent(GLTFNormalTextureInfo.self, forKey: .normalTexture)
        occlusionTexture = try container.decodeIfPresent(GLTFOcclusionTextureInfo.self, forKey: .occlusionTexture)
        emissiveTexture = try container.decodeIfPresent(GLTFTextureInfo.self, forKey: .emissiveTexture)
        emissiveFactor = try container.decodeIfPresent([Float].self, forKey: .emissiveFactor)
        alphaMode = try container.decodeIfPresent(String.self, forKey: .alphaMode)
        alphaCutoff = try container.decodeIfPresent(Float.self, forKey: .alphaCutoff)
        doubleSided = try container.decodeIfPresent(Bool.self, forKey: .doubleSided)
        // Decode extensions as [String: Any] using AnyCodable wrapper
        // This enables VRM 1.0 per-material VRMC_materials_mtoon extension parsing
        if container.contains(.extensions) {
            if let extWrapper = try? container.decode([String: AnyCodable].self, forKey: .extensions) {
                extensions = extWrapper.mapValues { $0.value }
            } else {
                extensions = nil
            }
        } else {
            extensions = nil
        }
    }

    /// Encodes the material's standard fields. Extensions are not re-emitted.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(pbrMetallicRoughness, forKey: .pbrMetallicRoughness)
        try container.encodeIfPresent(normalTexture, forKey: .normalTexture)
        try container.encodeIfPresent(occlusionTexture, forKey: .occlusionTexture)
        try container.encodeIfPresent(emissiveTexture, forKey: .emissiveTexture)
        try container.encodeIfPresent(emissiveFactor, forKey: .emissiveFactor)
        try container.encodeIfPresent(alphaMode, forKey: .alphaMode)
        try container.encodeIfPresent(alphaCutoff, forKey: .alphaCutoff)
        try container.encodeIfPresent(doubleSided, forKey: .doubleSided)
    }
}

/// PBR metallic-roughness material inputs per the glTF 2.0 [Materials](https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html#reference-pbrmetallicroughness) reference.
public struct GLTFPBRMetallicRoughness: Codable {
    /// Linear RGBA base-color multiplier.
    public let baseColorFactor: [Float]?
    /// Base color (albedo) texture.
    public let baseColorTexture: GLTFTextureInfo?
    /// Scalar multiplier for the metallic channel.
    public let metallicFactor: Float?
    /// Scalar multiplier for the roughness channel.
    public let roughnessFactor: Float?
    /// Combined metallic (B) + roughness (G) texture.
    public let metallicRoughnessTexture: GLTFTextureInfo?
}

/// Parsed [`KHR_texture_transform`](https://github.com/KhronosGroup/glTF/blob/main/extensions/2.0/Khronos/KHR_texture_transform/README.md) payload: UV offset, rotation, and scale.
public struct GLTFKHRTextureTransform {
    /// UV offset in texture space.
    public var offset: SIMD2<Float>
    /// UV rotation in radians, counter-clockwise around the origin.
    public var rotation: Float
    /// UV scale.
    public var scale: SIMD2<Float>

    /// Creates a transform with identity defaults for any omitted fields.
    public init(offset: SIMD2<Float> = .zero, rotation: Float = 0.0, scale: SIMD2<Float> = [1, 1]) {
        self.offset = offset
        self.rotation = rotation
        self.scale = scale
    }

    static func parse(from dict: [String: Any]) -> GLTFKHRTextureTransform {
        var transform = GLTFKHRTextureTransform()
        if let off = dict["offset"] as? [Any], off.count >= 2 {
            transform.offset = SIMD2<Float>(toFloat(off[0]), toFloat(off[1]))
        }
        if let rot = dict["rotation"] {
            transform.rotation = toFloat(rot)
        }
        if let sc = dict["scale"] as? [Any], sc.count >= 2 {
            transform.scale = SIMD2<Float>(toFloat(sc[0], default: 1.0), toFloat(sc[1], default: 1.0))
        }
        return transform
    }

    private static func toFloat(_ value: Any, default defaultValue: Float = 0.0) -> Float {
        if let d = value as? Double { return Float(d) }
        if let i = value as? Int { return Float(i) }
        if let f = value as? Float { return f }
        return defaultValue
    }
}

/// A texture reference on a material slot. See the [glTF 2.0 textureInfo schema](https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html#reference-textureinfo).
public struct GLTFTextureInfo: Codable {
    /// Index into ``GLTFDocument/textures``.
    public let index: Int
    /// UV channel index (`TEXCOORD_<n>`). Defaults to 0.
    public let texCoord: Int?
    /// Parsed `KHR_texture_transform` payload, if present on this slot.
    public let khrTextureTransform: GLTFKHRTextureTransform?

    enum CodingKeys: String, CodingKey {
        case index, texCoord, extensions
    }

    /// Decodes the texture reference and, if present, the `KHR_texture_transform` extension.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        index = try container.decode(Int.self, forKey: .index)
        texCoord = try container.decodeIfPresent(Int.self, forKey: .texCoord)
        if container.contains(.extensions),
           let extWrapper = try? container.decode([String: AnyCodable].self, forKey: .extensions),
           let khrDict = extWrapper["KHR_texture_transform"]?.value as? [String: Any] {
            khrTextureTransform = GLTFKHRTextureTransform.parse(from: khrDict)
        } else {
            khrTextureTransform = nil
        }
    }

    /// Encodes the texture reference. The `KHR_texture_transform` payload is not re-emitted.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(index, forKey: .index)
        try container.encodeIfPresent(texCoord, forKey: .texCoord)
    }
}

/// Normal map texture reference with the per-spec `scale` parameter.
public struct GLTFNormalTextureInfo: Codable {
    /// Index into ``GLTFDocument/textures``.
    public let index: Int
    /// UV channel index. Defaults to 0.
    public let texCoord: Int?
    /// Tangent-space normal scale; sampled XY are multiplied by this factor.
    public let scale: Float?
}

/// Occlusion (AO) texture reference with the per-spec `strength` parameter.
public struct GLTFOcclusionTextureInfo: Codable {
    /// Index into ``GLTFDocument/textures``.
    public let index: Int
    /// UV channel index. Defaults to 0.
    public let texCoord: Int?
    /// Linearly interpolates between full occlusion (0) and no occlusion (1).
    public let strength: Float?
}

/// A glTF 2.0 [texture](https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html#textures): a pairing of a sampler with an image source.
public struct GLTFTexture: Codable {
    /// Index into ``GLTFDocument/samplers``, or `nil` for default sampling.
    public let sampler: Int?
    /// Index into ``GLTFDocument/images``.
    public let source: Int?
    /// Optional texture name.
    public let name: String?
}

/// A glTF 2.0 [image](https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html#images), either embedded in a buffer view or referenced by URI.
public struct GLTFImage: Codable {
    /// External file path or `data:` URI. Mutually exclusive with ``bufferView``.
    public let uri: String?
    /// MIME type (`"image/png"`, `"image/jpeg"`, …) when referencing a buffer view.
    public let mimeType: String?
    /// BufferView index containing the encoded image bytes. Mutually exclusive with ``uri``.
    public let bufferView: Int?
    /// Optional image name.
    public let name: String?
}

/// A glTF 2.0 [sampler](https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html#samplers): filter and wrap modes encoded as OpenGL constants.
public struct GLTFSampler: Codable {
    /// Magnification filter (`9728` NEAREST, `9729` LINEAR).
    public let magFilter: Int?
    /// Minification filter (NEAREST/LINEAR plus mipmap variants).
    public let minFilter: Int?
    /// S-axis wrap mode (`33071` CLAMP_TO_EDGE, `33648` MIRRORED_REPEAT, `10497` REPEAT).
    public let wrapS: Int?
    /// T-axis wrap mode (same constants as ``wrapS``).
    public let wrapT: Int?
}

/// A glTF 2.0 [buffer](https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html#buffers): a contiguous binary blob.
public struct GLTFBuffer: Codable {
    /// Total length in bytes.
    public let byteLength: Int
    /// External `.bin` path or `data:` URI. `nil` for the GLB binary chunk (buffer 0).
    public let uri: String?
    /// Optional buffer name.
    public let name: String?
}

/// A glTF 2.0 [bufferView](https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html#buffer-views): a sub-range of a buffer.
public struct GLTFBufferView: Codable {
    /// Index into ``GLTFDocument/buffers``.
    public let buffer: Int
    /// Offset into the parent buffer in bytes.
    public let byteOffset: Int?
    /// Length of this view in bytes.
    public let byteLength: Int
    /// Stride between consecutive elements; non-`nil` indicates an interleaved vertex buffer.
    public let byteStride: Int?
    /// Optional buffer target hint (`34962` ARRAY_BUFFER, `34963` ELEMENT_ARRAY_BUFFER).
    public let target: Int?
    /// Optional bufferView name.
    public let name: String?
}

/// A glTF 2.0 [accessor](https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html#accessors): a typed view into a buffer view.
public struct GLTFAccessor: Codable {
    /// Index into ``GLTFDocument/bufferViews``, or `nil` for sparse-only accessors.
    public let bufferView: Int?
    /// Offset into the bufferView in bytes.
    public let byteOffset: Int?
    /// glTF component type constant (`5120` BYTE … `5126` FLOAT).
    public let componentType: Int
    /// Number of elements.
    public let count: Int
    /// Element shape (`"SCALAR"`, `"VEC2"`, `"VEC3"`, `"VEC4"`, `"MAT2"`, `"MAT3"`, `"MAT4"`).
    public let type: String
    /// Per-component maxima (for `POSITION`, used by viewers to skip a CPU scan).
    public let max: [Float]?
    /// Per-component minima (mirrors ``max``).
    public let min: [Float]?
    /// Whether integer components should be normalised on read.
    public let normalized: Bool?
    /// Sparse-override descriptor, if any.
    public let sparse: GLTFSparse?
    /// Optional accessor name.
    public let name: String?
}

/// Sparse-accessor descriptor. See [glTF 2.0 §5.1.7](https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html#sparse-accessors).
public struct GLTFSparse: Codable {
    /// Number of overridden elements.
    public let count: Int
    /// Override indices descriptor.
    public let indices: GLTFSparseIndices
    /// Override values descriptor.
    public let values: GLTFSparseValues
}

/// Indices half of a sparse accessor: where each override goes.
public struct GLTFSparseIndices: Codable {
    /// BufferView holding the index array.
    public let bufferView: Int
    /// Offset into the bufferView in bytes.
    public let byteOffset: Int?
    /// Component type (must be one of `UNSIGNED_BYTE`/`UNSIGNED_SHORT`/`UNSIGNED_INT`).
    public let componentType: Int
}

/// Values half of a sparse accessor: replacement element data, matching the parent accessor's `componentType`.
public struct GLTFSparseValues: Codable {
    /// BufferView holding the replacement values.
    public let bufferView: Int
    /// Offset into the bufferView in bytes.
    public let byteOffset: Int?
}

/// A glTF 2.0 [skin](https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html#skins): the joint hierarchy used for skinning.
public struct GLTFSkin: Codable {
    /// Accessor index for the joint inverse-bind matrices (`MAT4` × `joints.count`). Identity is assumed when omitted.
    public let inverseBindMatrices: Int?
    /// Optional skeleton root node.
    public let skeleton: Int?
    /// Joint node indices, in the order matching the `JOINTS_0` vertex attribute.
    public let joints: [Int]
    /// Optional skin name.
    public let name: String?
}

/// A glTF 2.0 [animation](https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html#animations) container.
public struct GLTFAnimation: Codable {
    /// Channels binding samplers to node targets.
    public let channels: [GLTFAnimationChannel]
    /// Samplers providing input (time) and output (value) curves.
    public let samplers: [GLTFAnimationSampler]
    /// Optional animation name.
    public let name: String?
}

/// Binding of an animation sampler to a target property on a node.
public struct GLTFAnimationChannel: Codable {
    /// Index into the parent animation's samplers array.
    public let sampler: Int
    /// Target node and path.
    public let target: GLTFAnimationTarget
}

/// Animation channel target: which property on which node.
public struct GLTFAnimationTarget: Codable {
    /// Target node index.
    public let node: Int?
    /// Animated property (`"translation"`, `"rotation"`, `"scale"`, or `"weights"` for morphs).
    public let path: String
}

/// Animation sampler: input keyframe times and output values with an interpolation mode.
public struct GLTFAnimationSampler: Codable {
    /// Accessor of keyframe times (`SCALAR` `FLOAT`, monotonically increasing).
    public let input: Int
    /// Interpolation mode (`"LINEAR"`, `"STEP"`, `"CUBICSPLINE"`). Defaults to `"LINEAR"`.
    public let interpolation: String?
    /// Accessor of keyframe values; shape depends on the channel target path.
    public let output: Int
}

// MARK: - GLB Parser

/// Parses glTF 2.0 GLB (binary) containers into a ``GLTFDocument`` and the optional `BIN` chunk.
///
/// ## Discussion
/// `GLTFParser` is the entry point for every VRM load. It accepts the raw
/// GLB bytes, validates the
/// [GLB header](https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html#binary-gltf-layout)
/// (`glTF` magic, version 2), and walks every chunk, decoding the JSON
/// chunk via Swift's standard `JSONDecoder` and retaining the BIN chunk in
/// ``binaryChunk``. If duplicate JSON or BIN chunks appear (non-conformant
/// but observed in the wild), the last occurrence wins.
///
/// The parser is tolerant of trailing chunks beyond the data length (they
/// are logged and skipped). It is strict about the magic number and
/// version, raising ``VRMError/invalidGLBFormat(reason:filePath:)`` or
/// ``VRMError/unsupportedVersion(version:supported:filePath:)`` on
/// mismatch.
///
/// Plain `.gltf` JSON files are not parsed by this type directly; consumers
/// that need pure-JSON loading should `JSONDecoder.decode(GLTFDocument.self, from:)`
/// against ``GLTFDocument``.
public class GLTFParser {
    /// The `BIN` chunk extracted from the most recent ``parse(data:filePath:)`` call, or `nil` if absent.
    public private(set) var binaryChunk: Data?

    /// Creates an empty parser.
    ///
    /// Reuse with care: ``binaryChunk`` is not reset between calls, so always
    /// use the binary data returned from the current call rather than reading
    /// the property afterward.
    public init() {}

    /// Parses a GLB byte stream and returns the decoded document plus the optional binary chunk.
    ///
    /// - Parameters:
    ///   - data: Raw GLB bytes.
    ///   - filePath: Optional source file path used to enrich error messages.
    /// - Returns: A tuple of the decoded ``GLTFDocument`` and the optional `BIN` chunk bytes.
    /// - Throws:
    ///   - ``VRMError/invalidGLBFormat(reason:filePath:)`` if the magic number is wrong or the file is shorter than a GLB header.
    ///   - ``VRMError/unsupportedVersion(version:supported:filePath:)`` if the GLB container version is not `2`.
    ///   - ``VRMError/invalidJSON(context:underlyingError:filePath:)`` if the JSON chunk is missing or fails to decode against ``GLTFDocument``.
    public func parse(data: Data, filePath: String? = nil) throws -> (document: GLTFDocument, binaryData: Data?) {
        // GLB Header - ensure we have at least 12 bytes for header
        guard data.count >= 12 else {
            throw VRMError.invalidGLBFormat(
                reason: "File is too small (\(data.count) bytes). GLB files require at least 12 bytes for the header.",
                filePath: filePath
            )
        }

        let magic = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }
        guard magic == 0x46546C67 else { // "glTF" in little-endian
            throw VRMError.invalidGLBFormat(
                reason: "Invalid magic number 0x\(String(format: "%08X", magic)). Expected 0x46546C67 ('glTF').",
                filePath: filePath
            )
        }

        let version = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) }
        guard version == 2 else {
            throw VRMError.unsupportedVersion(
                version: "GLB \(version)",
                supported: ["GLB 2"],
                filePath: filePath
            )
        }

        // let length = data.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt32.self) }

        // Parse chunks
        var offset = 12
        var jsonChunk: Data?

        while offset < data.count {
            // Ensure we have at least 8 bytes for chunk header
            guard offset + 8 <= data.count else {
                break
            }

            let chunkLength = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
            let chunkType = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self) }

            // Validate chunk data range
            let chunkStart = offset + 8
            let chunkEnd = chunkStart + Int(chunkLength)
            guard chunkEnd <= data.count else {
                vrmLog("[GLTFParser] Warning: Chunk extends beyond data bounds (start: \(chunkStart), end: \(chunkEnd), data size: \(data.count))")
                break
            }

            let chunkData = data.subdata(in: chunkStart..<chunkEnd)

            if chunkType == 0x4E4F534A { // "JSON"
                jsonChunk = chunkData
            } else if chunkType == 0x004E4942 { // "BIN\0"
                binaryChunk = chunkData
            }

            offset += 8 + Int(chunkLength)
        }

        guard let jsonData = jsonChunk else {
            throw VRMError.invalidJSON(
                context: "Missing JSON chunk in GLB file",
                underlyingError: nil,
                filePath: filePath
            )
        }

        // Parse JSON
        let decoder = JSONDecoder()
        do {
            let document = try decoder.decode(GLTFDocument.self, from: jsonData)
            return (document, self.binaryChunk)
        } catch {
            throw VRMError.invalidJSON(
                context: "Failed to decode glTF JSON structure",
                underlyingError: error.localizedDescription,
                filePath: filePath
            )
        }
    }
}

// MARK: - JSON+Any Extension

extension JSONDecoder {
    func decode(_ type: [String: Any].Type, from data: Data, filePath: String? = nil) throws -> [String: Any] {
        let json = try JSONSerialization.jsonObject(with: data, options: [])
        guard let dict = json as? [String: Any] else {
            let jsonTypeName = String(describing: Swift.type(of: json))
            throw VRMError.invalidJSON(
                context: "JSON root is not a dictionary object",
                underlyingError: "Expected dictionary, got \(jsonTypeName)",
                filePath: filePath
            )
        }
        return dict
    }
}