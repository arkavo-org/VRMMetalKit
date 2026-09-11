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

/// Stable ID → export index map recorded next to every build.
public struct ExportIndexMap: Codable, Hashable, Sendable {
    public var nodes: [String: Int] = [:]
    public var meshes: [String: Int] = [:]
    public var skins: [String: Int] = [:]
    public var images: [String: Int] = [:]
    public var textures: [String: Int] = [:]
    public var materials: [String: Int] = [:]
    public var expressions: [String: String] = [:]
    public var springs: [String: Int] = [:]
    public var colliders: [String: Int] = [:]
    public var colliderGroups: [String: Int] = [:]
    public var morphTargets: [String: [String: Int]] = [:]
    public var meshNodes: [String: [Int]] = [:]

    public init() {}
}

public struct GLBExport: Sendable {
    public var data: Data
    public var json: JSONValue
    public var bin: Data
    public var idMap: ExportIndexMap
    public var buildHash: String
    public var sha256: String { SHA256Hex.hex(data) }
}

/// CompiledAvatar → VRM 1.0 GLB. Every array is emitted in stable-id order;
/// the BIN layout follows the sorted traversal, so identical avatars produce
/// identical bytes. `threads` is accepted for interface parity and ignored.
public enum GLBWriter {
    public static var generator: String { "\(ToolInfo.current.tool) \(ToolInfo.current.version)" }

    public static let vrmExtension = "VRMC_vrm"
    public static let mtoonExtension = "VRMC_materials_mtoon"
    public static let springBoneExtension = "VRMC_springBone"
    public static let textureTransformExtension = "KHR_texture_transform"
    public static let emissiveStrengthExtension = "KHR_materials_emissive_strength"

    public static func write(_ avatar: CompiledAvatar, threads: Int = 1) throws -> GLBExport {
        _ = threads
        var builder = try Builder(avatar: avatar.sorted())
        let json = try builder.build()
        var bin = builder.bin.data
        while bin.count % 4 != 0 { bin.append(0x00) }
        let glb = GLBFile(json: json, bin: bin)
        let data = try glb.serialize()
        return GLBExport(data: data, json: json, bin: glb.bin, idMap: builder.idMap, buildHash: try avatar.buildHash())
    }

    static func fail(_ message: String, path: String? = nil, objectId: String? = nil) -> AuthorError {
        AuthorError(code: .exportFailed, objectId: objectId, path: path, message: message, suggestedCommands: ["recipe apply", "object list"])
    }

    // MARK: BIN

    struct BinBuffer {
        var data = Data()
        var views: [JSONValue] = []

        mutating func addView(_ bytes: Data, target: Int?) -> Int {
            while data.count % 4 != 0 { data.append(0x00) }
            var view: [String: JSONValue] = ["buffer": 0, "byteOffset": .number(Double(data.count)), "byteLength": .number(Double(bytes.count))]
            if let target { view["target"] = .number(Double(target)) }
            data.append(bytes)
            views.append(.object(view))
            return views.count - 1
        }
    }

    static func floatBytes(_ values: [Float]) -> Data {
        var out = Data(capacity: values.count * 4)
        for v in values { withUnsafeBytes(of: v.bitPattern.littleEndian) { out.append(contentsOf: $0) } }
        return out
    }

    static func u16Bytes(_ values: [UInt16]) -> Data {
        var out = Data(capacity: values.count * 2)
        for v in values { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
        return out
    }

    static func u32Bytes(_ values: [UInt32]) -> Data {
        var out = Data(capacity: values.count * 4)
        for v in values { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
        return out
    }

    static func numbers(_ values: [Float]) -> JSONValue { .array(values.map { .number(Double($0)) }) }
    static func numbers(_ values: [Double]) -> JSONValue { .array(values.map { .number($0) }) }

    // MARK: Builder

    struct Builder {
        let avatar: CompiledAvatar
        var bin = BinBuffer()
        var accessors: [JSONValue] = []
        var idMap = ExportIndexMap()
        var extensionsUsed: [String] = []
        var meshInstanceByNode: [String: CompiledMeshInstance] = [:]

        init(avatar: CompiledAvatar) throws {
            self.avatar = avatar
            for (index, node) in avatar.nodes.enumerated() { idMap.nodes[node.id] = index }
            for (index, mesh) in avatar.meshes.enumerated() { idMap.meshes[mesh.id] = index }
            for (index, skin) in avatar.skins.enumerated() { idMap.skins[skin.id] = index }
            for (index, image) in avatar.images.enumerated() {
                idMap.images[image.id] = index
                idMap.textures[image.id] = index
            }
            for (index, material) in avatar.materials.enumerated() { idMap.materials[material.id] = index }
            for (index, spring) in avatar.springs.enumerated() { idMap.springs[spring.id] = index }
            for (index, collider) in avatar.colliders.enumerated() { idMap.colliders[collider.id] = index }
            for (index, group) in avatar.colliderGroups.enumerated() { idMap.colliderGroups[group.id] = index }
            for instance in avatar.meshInstances {
                guard idMap.nodes[instance.nodeId] != nil else { throw fail("Mesh instance references unknown node '\(instance.nodeId)'.", path: "/meshInstances", objectId: instance.nodeId) }
                guard idMap.meshes[instance.meshId] != nil else { throw fail("Mesh instance references unknown mesh '\(instance.meshId)'.", path: "/meshInstances", objectId: instance.meshId) }
                if let skinId = instance.skinId, idMap.skins[skinId] == nil { throw fail("Mesh instance references unknown skin '\(skinId)'.", path: "/meshInstances", objectId: skinId) }
                guard meshInstanceByNode[instance.nodeId] == nil else { throw fail("Node '\(instance.nodeId)' instances more than one mesh.", path: "/meshInstances", objectId: instance.nodeId) }
                meshInstanceByNode[instance.nodeId] = instance
                idMap.meshNodes[instance.meshId, default: []].append(idMap.nodes[instance.nodeId]!)
            }
            for key in idMap.meshNodes.keys { idMap.meshNodes[key]?.sort() }
        }

        mutating func use(_ ext: String) {
            if !extensionsUsed.contains(ext) { extensionsUsed.append(ext) }
        }

        mutating func addAccessor(_ bytes: Data, target: Int?, componentType: GLTFComponentType, type: GLTFAccessorType, count: Int, min: [Float]? = nil, max: [Float]? = nil) -> Int {
            let view = bin.addView(bytes, target: target)
            var accessor: [String: JSONValue] = [
                "bufferView": .number(Double(view)), "componentType": .number(Double(componentType.rawValue)),
                "count": .number(Double(count)), "type": .string(type.rawValue),
            ]
            if let min { accessor["min"] = numbers(min) }
            if let max { accessor["max"] = numbers(max) }
            accessors.append(.object(accessor))
            return accessors.count - 1
        }

        mutating func addVec3(_ values: [SIMD3<Float>], bounds: Bool) -> Int {
            var flat: [Float] = []
            flat.reserveCapacity(values.count * 3)
            var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
            var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
            for v in values {
                flat += [v.x, v.y, v.z]
                lo = pointwiseMin(lo, v)
                hi = pointwiseMax(hi, v)
            }
            if values.isEmpty { lo = .zero; hi = .zero }
            return addAccessor(floatBytes(flat), target: 34962, componentType: .float, type: .vec3, count: values.count,
                               min: bounds ? [lo.x, lo.y, lo.z] : nil, max: bounds ? [hi.x, hi.y, hi.z] : nil)
        }

        mutating func build() throws -> JSONValue {
            var root: [String: JSONValue] = [
                "asset": ["version": "2.0", "generator": .string(GLBWriter.generator)],
            ]
            root["nodes"] = .array(try buildNodes())
            root["meshes"] = .array(try buildMeshes())
            if !avatar.skins.isEmpty { root["skins"] = .array(try buildSkins()) }
            let (images, samplers, textures) = buildImages()
            if !images.isEmpty {
                root["images"] = .array(images)
                root["samplers"] = .array(samplers)
                root["textures"] = .array(textures)
            }
            if !avatar.materials.isEmpty { root["materials"] = .array(try buildMaterials()) }
            let vrm = try buildVRM()
            use(GLBWriter.vrmExtension)
            var extensions: [String: JSONValue] = [GLBWriter.vrmExtension: vrm]
            if !avatar.springs.isEmpty || !avatar.colliders.isEmpty || !avatar.colliderGroups.isEmpty {
                extensions[GLBWriter.springBoneExtension] = try buildSpringBone()
                use(GLBWriter.springBoneExtension)
            }
            root["extensions"] = .object(extensions)
            root["extensionsUsed"] = JSONValue(extensionsUsed)
            let roots = avatar.nodes.enumerated().filter { $0.element.parentId == nil }.map { JSONValue.number(Double($0.offset)) }
            root["scenes"] = [["nodes": .array(roots)]]
            root["scene"] = 0
            root["accessors"] = .array(accessors)
            root["bufferViews"] = .array(bin.views)
            var padded = bin.data.count
            while padded % 4 != 0 { padded += 1 }
            root["buffers"] = [["byteLength": .number(Double(padded))]]
            return .object(root)
        }

        func buildNodes() throws -> [JSONValue] {
            var children: [Int: [Int]] = [:]
            for (index, node) in avatar.nodes.enumerated() {
                guard let parentId = node.parentId else { continue }
                guard let parent = idMap.nodes[parentId] else { throw fail("Node '\(node.id)' references unknown parent '\(parentId)'.", path: "/nodes", objectId: node.id) }
                guard parent != index else { throw fail("Node '\(node.id)' is its own parent.", path: "/nodes", objectId: node.id) }
                children[parent, default: []].append(index)
            }
            for (index, node) in avatar.nodes.enumerated() {
                var seen: Set<Int> = [index]
                var cursor = node.parentId.flatMap { idMap.nodes[$0] }
                while let current = cursor {
                    guard seen.insert(current).inserted else { throw fail("Node hierarchy contains a cycle through '\(node.id)'.", path: "/nodes", objectId: node.id) }
                    cursor = avatar.nodes[current].parentId.flatMap { idMap.nodes[$0] }
                }
            }
            return avatar.nodes.enumerated().map { index, node in
                var out: [String: JSONValue] = ["name": .string(node.name)]
                if node.translation != .zero { out["translation"] = numbers([node.translation.x, node.translation.y, node.translation.z]) }
                if node.rotation != SIMD4(0, 0, 0, 1) { out["rotation"] = numbers([node.rotation.x, node.rotation.y, node.rotation.z, node.rotation.w]) }
                if node.scale != SIMD3(repeating: 1) { out["scale"] = numbers([node.scale.x, node.scale.y, node.scale.z]) }
                if let kids = children[index] { out["children"] = .array(kids.map { .number(Double($0)) }) }
                if let instance = meshInstanceByNode[node.id] {
                    out["mesh"] = .number(Double(idMap.meshes[instance.meshId]!))
                    if let skinId = instance.skinId { out["skin"] = .number(Double(idMap.skins[skinId]!)) }
                }
                return .object(out)
            }
        }

        mutating func buildMeshes() throws -> [JSONValue] {
            var meshes: [JSONValue] = []
            for mesh in avatar.meshes {
                guard !mesh.primitives.isEmpty else { throw fail("Mesh '\(mesh.id)' has no primitives.", path: "/meshes", objectId: mesh.id) }
                let targetNames = mesh.primitives[0].morphTargets.map(\.name)
                var primitives: [JSONValue] = []
                for (primitiveIndex, primitive) in mesh.primitives.enumerated() {
                    let where_ = "/meshes/\(mesh.id)/primitives/\(primitiveIndex)"
                    let n = primitive.positions.count
                    guard n > 0 else { throw fail("Primitive has no vertices.", path: where_, objectId: mesh.id) }
                    guard primitive.normals.count == n, primitive.uv0.count == n else {
                        throw fail("Primitive attribute counts differ (positions \(n), normals \(primitive.normals.count), uv0 \(primitive.uv0.count)).", path: where_, objectId: mesh.id)
                    }
                    guard primitive.indices.count % 3 == 0, !primitive.indices.isEmpty else { throw fail("Primitive indices must be a non-empty multiple of 3.", path: where_, objectId: mesh.id) }
                    if let bad = primitive.indices.first(where: { Int($0) >= n }) { throw fail("Index \(bad) exceeds vertex count \(n).", path: where_, objectId: mesh.id) }
                    guard primitive.morphTargets.map(\.name) == targetNames else {
                        throw fail("Every primitive of a mesh must declare the same morph target names.", path: where_, objectId: mesh.id)
                    }
                    guard let materialIndex = idMap.materials[primitive.materialId] else {
                        throw fail("Primitive references unknown material '\(primitive.materialId)'.", path: where_, objectId: primitive.materialId)
                    }
                    var attributes: [String: JSONValue] = [
                        "POSITION": .number(Double(addVec3(primitive.positions, bounds: true))),
                        "NORMAL": .number(Double(addVec3(primitive.normals, bounds: false))),
                    ]
                    attributes["TEXCOORD_0"] = .number(Double(addAccessor(floatBytes(primitive.uv0.flatMap { [$0.x, $0.y] }), target: 34962, componentType: .float, type: .vec2, count: n)))
                    if let joints = primitive.joints0 {
                        guard let weights = primitive.weights0, joints.count == n, weights.count == n else {
                            throw fail("Skinned primitives need joints0 and weights0 with one entry per vertex.", path: where_, objectId: mesh.id)
                        }
                        attributes["JOINTS_0"] = .number(Double(addAccessor(u16Bytes(joints.flatMap { [$0.x, $0.y, $0.z, $0.w] }), target: 34962, componentType: .unsignedShort, type: .vec4, count: n)))
                        attributes["WEIGHTS_0"] = .number(Double(addAccessor(floatBytes(weights.flatMap { [$0.x, $0.y, $0.z, $0.w] }), target: 34962, componentType: .float, type: .vec4, count: n)))
                    } else if primitive.weights0 != nil {
                        throw fail("weights0 without joints0.", path: where_, objectId: mesh.id)
                    }
                    let indices = addAccessor(u32Bytes(primitive.indices), target: 34963, componentType: .unsignedInt, type: .scalar, count: primitive.indices.count)
                    var out: [String: JSONValue] = [
                        "attributes": .object(attributes), "indices": .number(Double(indices)), "material": .number(Double(materialIndex)), "mode": 4,
                    ]
                    if !primitive.morphTargets.isEmpty {
                        var targets: [JSONValue] = []
                        for morph in primitive.morphTargets {
                            guard morph.positionDeltas.count == n else {
                                throw fail("Morph target '\(morph.name)' has \(morph.positionDeltas.count) deltas for \(n) vertices.", path: where_, objectId: mesh.id)
                            }
                            targets.append(["POSITION": .number(Double(addVec3(morph.positionDeltas, bounds: true)))])
                        }
                        out["targets"] = .array(targets)
                    }
                    primitives.append(.object(out))
                }
                var out: [String: JSONValue] = ["name": .string(mesh.name), "primitives": .array(primitives)]
                if !targetNames.isEmpty {
                    out["extras"] = ["targetNames": JSONValue(targetNames)]
                    var names: [String: Int] = [:]
                    for (index, name) in targetNames.enumerated() { names[name] = index }
                    idMap.morphTargets[mesh.id] = names
                }
                meshes.append(.object(out))
            }
            return meshes
        }

        mutating func buildSkins() throws -> [JSONValue] {
            var skins: [JSONValue] = []
            for skin in avatar.skins {
                guard !skin.jointNodeIds.isEmpty else { throw fail("Skin '\(skin.id)' has no joints.", path: "/skins", objectId: skin.id) }
                guard skin.inverseBindMatrices.count == skin.jointNodeIds.count else {
                    throw fail("Skin '\(skin.id)' has \(skin.inverseBindMatrices.count) inverse bind matrices for \(skin.jointNodeIds.count) joints.", path: "/skins", objectId: skin.id)
                }
                let joints = try skin.jointNodeIds.map { id -> JSONValue in
                    guard let index = idMap.nodes[id] else { throw fail("Skin '\(skin.id)' references unknown joint node '\(id)'.", path: "/skins", objectId: skin.id) }
                    return .number(Double(index))
                }
                var flat: [Float] = []
                for m in skin.inverseBindMatrices { for i in 0..<16 { flat.append(m[i]) } }
                let ibm = addAccessor(floatBytes(flat), target: nil, componentType: .float, type: .mat4, count: skin.inverseBindMatrices.count)
                skins.append(["joints": .array(joints), "inverseBindMatrices": .number(Double(ibm)), "name": .string(skin.id)])
            }
            return skins
        }

        mutating func buildImages() -> ([JSONValue], [JSONValue], [JSONValue]) {
            var images: [JSONValue] = []
            var textures: [JSONValue] = []
            for (index, image) in avatar.images.enumerated() {
                let view = bin.addView(image.pngData, target: nil)
                images.append(["bufferView": .number(Double(view)), "mimeType": "image/png", "name": .string(image.id)])
                textures.append(["sampler": 0, "source": .number(Double(index))])
            }
            let samplers: [JSONValue] = images.isEmpty ? [] : [["magFilter": 9729, "minFilter": 9729, "wrapS": 10497, "wrapT": 10497]]
            return (images, samplers, textures)
        }

        /// Replaces `{"image": <imageId>, ...}` texture references with glTF
        /// `{"index": <textureIndex>, ...}` throughout a material JSON tree and
        /// records any `extensions` keys encountered.
        mutating func resolveTextures(_ value: JSONValue, path: String, materialId: String) throws -> JSONValue {
            switch value {
            case .object(var o):
                if let imageId = o["image"]?.string {
                    guard let texture = idMap.textures[imageId] else {
                        throw fail("Material '\(materialId)' references unknown image '\(imageId)'.", path: path + "/image", objectId: materialId)
                    }
                    o["image"] = nil
                    o["index"] = .number(Double(texture))
                }
                if let exts = o["extensions"]?.object { for key in exts.keys.sorted() { use(key) } }
                for key in o.keys.sorted() { o[key] = try resolveTextures(o[key]!, path: path + "/" + JSONPointer.escape(key), materialId: materialId) }
                return .object(o)
            case .array(let a):
                return .array(try a.enumerated().map { try resolveTextures($0.element, path: path + "/\($0.offset)", materialId: materialId) })
            default:
                return value
            }
        }

        mutating func buildMaterials() throws -> [JSONValue] {
            var materials: [JSONValue] = []
            use(GLBWriter.mtoonExtension)
            for material in avatar.materials {
                guard var gltf = try resolveTextures(material.gltf, path: "/materials/\(material.id)/gltf", materialId: material.id).object else {
                    throw fail("Material '\(material.id)' gltf must be an object.", path: "/materials", objectId: material.id)
                }
                guard var mtoon = try resolveTextures(material.mtoon, path: "/materials/\(material.id)/mtoon", materialId: material.id).object else {
                    throw fail("Material '\(material.id)' mtoon must be an object.", path: "/materials", objectId: material.id)
                }
                if mtoon["specVersion"] == nil { mtoon["specVersion"] = "1.0" }
                var extensions = gltf["extensions"]?.object ?? [:]
                extensions[GLBWriter.mtoonExtension] = .object(mtoon)
                gltf["extensions"] = .object(extensions)
                if gltf["name"] == nil { gltf["name"] = .string(material.id) }
                materials.append(.object(gltf))
            }
            return materials
        }

        func nodesInstancing(mesh meshId: String, what: String, objectId: String) throws -> [Int] {
            guard idMap.meshes[meshId] != nil else { throw fail("\(what) references unknown mesh '\(meshId)'.", objectId: objectId) }
            guard let nodes = idMap.meshNodes[meshId], !nodes.isEmpty else { throw fail("\(what) references mesh '\(meshId)' which no node instances.", objectId: objectId) }
            return nodes
        }

        mutating func buildVRM() throws -> JSONValue {
            var meta = try JSONValue.from(avatar.meta).object ?? [:]
            if let thumbnail = avatar.meta.thumbnailImage {
                guard let index = idMap.images[thumbnail] else { throw fail("meta.thumbnailImage references unknown image '\(thumbnail)'.", path: "/meta/thumbnailImage") }
                meta["thumbnailImage"] = .number(Double(index))
            }
            var humanBones: [String: JSONValue] = [:]
            for (bone, nodeId) in avatar.humanoid {
                guard let index = idMap.nodes[nodeId] else { throw fail("Humanoid bone \(bone.rawValue) references unknown node '\(nodeId)'.", path: "/humanoid/\(bone.rawValue)") }
                humanBones[bone.rawValue] = ["node": .number(Double(index))]
            }
            for bone in VRMHumanBone.required where humanBones[bone.rawValue] == nil {
                throw fail("Required humanoid bone \(bone.rawValue) is not mapped.", path: "/humanoid/\(bone.rawValue)")
            }
            var preset: [String: JSONValue] = [:]
            var custom: [String: JSONValue] = [:]
            for expression in avatar.expressions {
                var out: [String: JSONValue] = [
                    "isBinary": .bool(expression.isBinary),
                    "overrideBlink": .string(expression.overrideBlink.rawValue),
                    "overrideLookAt": .string(expression.overrideLookAt.rawValue),
                    "overrideMouth": .string(expression.overrideMouth.rawValue),
                ]
                var morphBinds: [JSONValue] = []
                for bind in expression.morphTargetBinds {
                    let nodes = try nodesInstancing(mesh: bind.mesh, what: "Expression '\(expression.id)' morph bind", objectId: expression.id)
                    guard let index = idMap.morphTargets[bind.mesh]?[bind.target] else {
                        throw fail("Expression '\(expression.id)' binds missing morph target '\(bind.target)' on mesh '\(bind.mesh)'.", path: "/expressions/\(expression.id)/morphTargetBinds", objectId: expression.id)
                    }
                    for node in nodes {
                        morphBinds.append(["node": .number(Double(node)), "index": .number(Double(index)), "weight": .number(bind.weight)])
                    }
                }
                if !morphBinds.isEmpty { out["morphTargetBinds"] = .array(morphBinds) }
                if !expression.materialColorBinds.isEmpty {
                    out["materialColorBinds"] = .array(try expression.materialColorBinds.map { bind in
                        guard let material = idMap.materials[bind.material] else { throw fail("Expression '\(expression.id)' colour bind references unknown material '\(bind.material)'.", objectId: expression.id) }
                        return ["material": .number(Double(material)), "type": .string(bind.type.rawValue), "targetValue": numbers(bind.targetValue)]
                    })
                }
                if !expression.textureTransformBinds.isEmpty {
                    out["textureTransformBinds"] = .array(try expression.textureTransformBinds.map { bind in
                        guard let material = idMap.materials[bind.material] else { throw fail("Expression '\(expression.id)' transform bind references unknown material '\(bind.material)'.", objectId: expression.id) }
                        return ["material": .number(Double(material)), "scale": numbers(bind.scale), "offset": numbers(bind.offset)]
                    })
                }
                if let p = expression.preset {
                    guard preset[p.rawValue] == nil else { throw fail("Preset expression '\(p.rawValue)' is defined twice.", objectId: expression.id) }
                    preset[p.rawValue] = .object(out)
                    idMap.expressions[expression.id] = "preset/\(p.rawValue)"
                } else if let name = expression.name {
                    guard custom[name] == nil else { throw fail("Custom expression '\(name)' is defined twice.", objectId: expression.id) }
                    custom[name] = .object(out)
                    idMap.expressions[expression.id] = "custom/\(name)"
                } else {
                    throw fail("Expression '\(expression.id)' has neither preset nor name.", objectId: expression.id)
                }
            }
            var expressions: [String: JSONValue] = [:]
            if !preset.isEmpty { expressions["preset"] = .object(preset) }
            if !custom.isEmpty { expressions["custom"] = .object(custom) }
            var annotations: [JSONValue] = []
            for annotation in avatar.firstPerson.meshAnnotations {
                for node in try nodesInstancing(mesh: annotation.mesh, what: "First-person annotation", objectId: annotation.mesh) {
                    annotations.append(["node": .number(Double(node)), "type": .string(annotation.type.rawValue)])
                }
            }
            var vrm: [String: JSONValue] = [
                "specVersion": "1.0",
                "meta": .object(meta),
                "humanoid": ["humanBones": .object(humanBones)],
                "lookAt": try JSONValue.from(avatar.lookAt),
                "firstPerson": ["meshAnnotations": .array(annotations)],
            ]
            if !expressions.isEmpty { vrm["expressions"] = .object(expressions) }
            return .object(vrm)
        }

        func buildSpringBone() throws -> JSONValue {
            let colliders: [JSONValue] = try avatar.colliders.map { collider in
                guard let node = idMap.nodes[collider.node] else { throw fail("Collider '\(collider.id)' references unknown node '\(collider.node)'.", objectId: collider.id) }
                let shape: JSONValue
                if let sphere = collider.shape.sphere {
                    shape = ["sphere": ["offset": numbers(sphere.offset), "radius": .number(sphere.radius)]]
                } else if let capsule = collider.shape.capsule {
                    shape = ["capsule": ["offset": numbers(capsule.offset), "radius": .number(capsule.radius), "tail": numbers(capsule.tail)]]
                } else {
                    throw fail("Collider '\(collider.id)' has no shape.", objectId: collider.id)
                }
                return ["node": .number(Double(node)), "shape": shape]
            }
            let groups: [JSONValue] = try avatar.colliderGroups.map { group in
                let indices = try group.colliders.map { id -> JSONValue in
                    guard let index = idMap.colliders[id] else { throw fail("Collider group '\(group.id)' references unknown collider '\(id)'.", objectId: group.id) }
                    return .number(Double(index))
                }
                return ["name": .string(group.name ?? group.id), "colliders": .array(indices)]
            }
            let springs: [JSONValue] = try avatar.springs.map { spring in
                var out: [String: JSONValue] = ["name": .string(spring.name ?? spring.id)]
                if let center = spring.center {
                    guard let index = idMap.nodes[center] else { throw fail("Spring '\(spring.id)' references unknown center node '\(center)'.", objectId: spring.id) }
                    out["center"] = .number(Double(index))
                }
                out["joints"] = .array(try spring.joints.map { joint in
                    guard let node = idMap.nodes[joint.node] else { throw fail("Spring '\(spring.id)' references unknown joint node '\(joint.node)'.", objectId: spring.id) }
                    return ["node": .number(Double(node)), "hitRadius": .number(joint.hitRadius), "stiffness": .number(joint.stiffness),
                            "gravityPower": .number(joint.gravityPower), "gravityDir": numbers(joint.gravityDir), "dragForce": .number(joint.dragForce)]
                })
                out["colliderGroups"] = .array(try spring.colliderGroups.map { id in
                    guard let index = idMap.colliderGroups[id] else { throw fail("Spring '\(spring.id)' references unknown collider group '\(id)'.", objectId: spring.id) }
                    return .number(Double(index))
                })
                return .object(out)
            }
            return ["specVersion": "1.0", "colliders": .array(colliders), "colliderGroups": .array(groups), "springs": .array(springs)]
        }
    }
}
