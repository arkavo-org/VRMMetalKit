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

/// One point on the scalp surface, in rest-pose world space.
public struct ScalpSample: Codable, Hashable, Sendable {
    public var position: SIMD3<Float>
    public var normal: SIMD3<Float>

    public init(position: SIMD3<Float>, normal: SIMD3<Float>) {
        self.position = position
        self.normal = normal
    }
}

/// Named body vertex regions a `WearableHost` is expected to answer for.
/// Presets reference regions by these names; a host returns an empty list
/// for regions it does not model.
public enum WearableRegion {
    public static let scalp = "scalp"
    public static let forehead = "forehead"
    public static let chest = "chest"
    public static let torso = "torso"
    public static let waist = "waist"
    public static let hips = "hips"
    public static let thighL = "thighL"
    public static let thighR = "thighR"
    public static let shinL = "shinL"
    public static let shinR = "shinR"
    public static let footL = "footL"
    public static let footR = "footR"
    public static let upperArmL = "upperArmL"
    public static let upperArmR = "upperArmR"
    public static let forearmL = "forearmL"
    public static let forearmR = "forearmR"
    public static let earL = "earL"
    public static let earR = "earR"

    public static let all = [scalp, forehead, chest, torso, waist, hips, thighL, thighR, shinL, shinR, footL, footR,
                             upperArmL, upperArmR, forearmL, forearmR, earL, earR]
}

/// Everything the wearable compiler needs from a compiled body/face template.
///
/// Coordinate frame is VRM 1.0 rest pose: +Y up, +Z is the direction the face
/// looks, +X is the model's left, arms along ±X (T-pose). All positions,
/// normals and matrices are in world space unless stated otherwise.
///
/// - `scalpSamples`: surface points where hair clumps may root.
/// - `region(_:)`: vertex indices into the body arrays for a `WearableRegion`
///   name; empty when the host does not model that region.
/// - `bodyJoints`/`bodyWeights` index into `bodySkin.jointNodeIds`; garments
///   reuse them verbatim and their mesh instances reference `bodySkin.id`, so the
///   integrator must keep that skin in the avatar.
/// - `bodyUV0`: body texture coordinates, reused by offset-shell garments.
/// - `worldMatrix(ofNode:)`: column-major 4x4 rest-pose world matrix of a rig
///   node (the same layout as `CompiledSkin.inverseBindMatrices`); nil for an
///   unknown node. Every attachment node id must resolve.
public protocol WearableHost {
    var headNodeId: String { get }
    var neckNodeId: String { get }
    var chestNodeId: String { get }
    var hipsNodeId: String { get }
    var leftEarNodeId: String { get }
    var rightEarNodeId: String { get }

    var scalpSamples: [ScalpSample] { get }
    func region(_ name: String) -> [Int]

    var bodyPositions: [SIMD3<Float>] { get }
    var bodyNormals: [SIMD3<Float>] { get }
    var bodyUV0: [SIMD2<Float>] { get }
    var bodyJoints: [SIMD4<UInt16>] { get }
    var bodyWeights: [SIMD4<Float>] { get }
    var bodyTriangles: [UInt32] { get }
    var bodySkin: CompiledSkin { get }

    var headCentre: SIMD3<Float> { get }
    var headRadius: Float { get }
    var leftEyeCentre: SIMD3<Float> { get }
    var rightEyeCentre: SIMD3<Float> { get }

    func worldMatrix(ofNode id: String) -> SIMD16<Float>?
}

extension WearableHost {
    /// Rig nodes an accessory may declare as its attachment, in a fixed order.
    public var attachmentNodeIds: [String] { [headNodeId, neckNodeId, chestNodeId, hipsNodeId, leftEarNodeId, rightEarNodeId] }

    func requireWorld(_ id: String, objectId: String? = nil) throws -> Mat4 {
        guard let m = worldMatrix(ofNode: id) else {
            throw AuthorError(code: .attachmentNotFound, objectId: objectId, path: "/attachment", observed: .string(id),
                              required: .array(attachmentNodeIds.map { .string($0) }),
                              message: "Rig node '\(id)' has no world transform on the host; wearables can only attach to declared rig nodes.",
                              suggestedCommands: ["object list --kind node", "object set"])
        }
        return Mat4(m)
    }
}
