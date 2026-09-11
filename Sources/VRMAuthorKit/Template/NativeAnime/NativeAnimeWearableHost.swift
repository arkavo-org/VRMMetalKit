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

/// Adapts a compiled native-anime-v1 body/face to `WearableHost`.
///
/// The body arrays are the body mesh's primitive 0 followed by the head skin
/// primitive, both skinned to the template's single body skin, so every
/// `WearableRegion` the presets probe resolves into one index space: body
/// regions (chest, torso, waist, hips, limbs) index the body part and the
/// head-mounted regions the hair preset needs (scalp, forehead, earL, earR)
/// index the head part at `headVertexOffset`. Garment presets only shell body
/// regions, so head vertices never enter a garment mesh; head triangles do take
/// part in the clearance and bang-clearance probes.
struct NativeAnimeWearableHost: WearableHost {
    let headNodeId: String
    let neckNodeId: String
    let chestNodeId: String
    let hipsNodeId: String
    let leftEarNodeId: String
    let rightEarNodeId: String

    let scalpSamples: [ScalpSample]
    let bodyPositions: [SIMD3<Float>]
    let bodyNormals: [SIMD3<Float>]
    let bodyUV0: [SIMD2<Float>]
    let bodyJoints: [SIMD4<UInt16>]
    let bodyWeights: [SIMD4<Float>]
    let bodyTriangles: [UInt32]
    let bodySkin: CompiledSkin

    let headCentre: SIMD3<Float>
    let headRadius: Float
    let leftEyeCentre: SIMD3<Float>
    let rightEyeCentre: SIMD3<Float>

    /// Index of the first head-skin vertex inside the body arrays.
    let headVertexOffset: Int
    /// Head-mounted regions served from the head skin primitive.
    static let headRegions = [WearableRegion.scalp, WearableRegion.forehead, WearableRegion.earL, WearableRegion.earR]

    private let regions: [String: [Int]]
    private let worlds: [String: SIMD16<Float>]

    init(avatar: CompiledAvatar, attachments: TemplateAttachments) throws {
        func missing(_ what: String) -> AuthorError {
            AuthorError(code: .internalError, path: "/template", message: "native-anime-v1 compiled without \(what); wearables cannot attach.", suggestedCommands: ["doctor"])
        }
        guard let body = avatar.meshes.first(where: { $0.id == attachments.bodyMeshId })?.primitives.first else { throw missing("a body primitive") }
        guard let headMesh = avatar.meshes.first(where: { $0.id == attachments.headMeshId }), headMesh.primitives.count > HeadPrimitive.skin.rawValue else {
            throw missing("a head skin primitive")
        }
        let head = headMesh.primitives[HeadPrimitive.skin.rawValue]
        guard let skin = avatar.skins.first(where: { $0.id == attachments.skinId }) else { throw missing("the body skin") }
        guard let bodyJoints = body.joints0, let bodyWeights = body.weights0, let headJoints = head.joints0, let headWeights = head.weights0 else {
            throw missing("skinned body and head primitives")
        }
        func node(_ key: String) throws -> String {
            guard let id = attachments.attachmentNodes[key] else { throw missing("attachment node '\(key)'") }
            return id
        }
        headNodeId = try node("head")
        neckNodeId = try node("neck")
        chestNodeId = try node("chest")
        hipsNodeId = try node("hips")
        leftEarNodeId = try node("earLeft")
        rightEarNodeId = try node("earRight")

        let offset = body.positions.count
        headVertexOffset = offset
        bodyPositions = body.positions + head.positions
        bodyNormals = body.normals + head.normals
        bodyUV0 = body.uv0 + head.uv0
        self.bodyJoints = bodyJoints + headJoints
        self.bodyWeights = bodyWeights + headWeights
        bodyTriangles = body.indices + head.indices.map { $0 + UInt32(offset) }
        bodySkin = skin

        var regions: [String: [Int]] = [:]
        for name in WearableRegion.all {
            if Self.headRegions.contains(name) {
                regions[name] = attachments.indices(of: name, mesh: attachments.headMeshId, primitive: HeadPrimitive.skin.rawValue).map { $0 + offset }
            } else {
                regions[name] = attachments.indices(of: name, mesh: attachments.bodyMeshId, primitive: 0)
            }
        }
        self.regions = regions

        scalpSamples = attachments.scalpSamples.map { ScalpSample(position: $0.position, normal: $0.normal) }
        headCentre = attachments.headCenter
        headRadius = 0.5 * (attachments.headRadii.x + attachments.headRadii.z)
        guard let left = attachments.eyes.first(where: { $0.side == "left" }), let right = attachments.eyes.first(where: { $0.side == "right" }) else {
            throw missing("both eye geometries")
        }
        leftEyeCentre = left.center
        rightEyeCentre = right.center
        worlds = Self.worldMatrices(nodes: avatar.nodes)
    }

    /// Rest-pose world matrices (column-major) of every node from its TRS chain.
    static func worldMatrices(nodes: [CompiledNode]) -> [String: SIMD16<Float>] {
        var byId: [String: CompiledNode] = [:]
        for node in nodes { byId[node.id] = node }
        var worlds: [String: Mat4] = [:]
        func world(_ id: String, depth: Int = 0) -> Mat4? {
            if let cached = worlds[id] { return cached }
            guard let node = byId[id], depth <= nodes.count else { return nil }
            let local = Mat4(translation: node.translation, rotation: node.rotation, scale: node.scale)
            let result: Mat4
            if let parent = node.parentId, let parentWorld = world(parent, depth: depth + 1) {
                result = parentWorld * local
            } else {
                result = local
            }
            worlds[id] = result
            return result
        }
        var out: [String: SIMD16<Float>] = [:]
        for node in nodes { out[node.id] = world(node.id)?.m }
        return out
    }

    func region(_ name: String) -> [Int] { regions[name] ?? [] }

    func worldMatrix(ofNode id: String) -> SIMD16<Float>? { worlds[id] }
}
