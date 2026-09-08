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
@testable import VRMMetalKit

/// Builds a normalized (identity-rotation) T-pose humanoid with torso, both
/// arms, and finger chains, without loading a file or touching Metal.
///
/// Arms extend along ±X from the shoulders, thumbs point +Z, palms face -Y.
/// Every node's rest rotation is identity, matching VRM 1.0 normalization.
enum SyntheticHumanoidRig {
    static let upperArmLength: Float = 0.25
    static let forearmLength: Float = 0.25

    static func makeTPose(specVersion: VRMSpecVersion = .v1_0) throws -> VRMModel {
        let json = #"{"asset":{"version":"2.0"}}"#
        let gltf = try JSONDecoder().decode(GLTFDocument.self, from: Data(json.utf8))
        let humanoid = VRMHumanoid()
        let model = VRMModel(specVersion: specVersion, meta: VRMMeta(licenseUrl: ""), humanoid: humanoid, gltf: gltf)

        var nodes: [VRMNode] = []
        func add(_ bone: VRMHumanoidBone, _ translation: SIMD3<Float>, parent: VRMNode?) throws -> VRMNode {
            let node = VRMNode(index: nodes.count, gltfNode: try gltfNode(name: bone.rawValue, translation: translation))
            if let parent {
                node.parent = parent
                parent.children.append(node)
            }
            humanoid.humanBones[bone] = VRMHumanoid.VRMHumanBone(node: node.index)
            nodes.append(node)
            return node
        }

        let hips = try add(.hips, [0, 0.9, 0], parent: nil)
        let spine = try add(.spine, [0, 0.1, 0], parent: hips)
        let chest = try add(.chest, [0, 0.15, 0], parent: spine)
        let neck = try add(.neck, [0, 0.15, 0], parent: chest)
        _ = try add(.head, [0, 0.1, 0], parent: neck)

        for sign: Float in [1, -1] {
            let left = sign > 0
            let shoulder = try add(left ? .leftShoulder : .rightShoulder, [0.05 * sign, 0.1, 0], parent: chest)
            let upper = try add(left ? .leftUpperArm : .rightUpperArm, [0.1 * sign, 0, 0], parent: shoulder)
            let lower = try add(left ? .leftLowerArm : .rightLowerArm, [upperArmLength * sign, 0, 0], parent: upper)
            let hand = try add(left ? .leftHand : .rightHand, [forearmLength * sign, 0, 0], parent: lower)

            let fingers: [(VRMHumanoidBone, VRMHumanoidBone, VRMHumanoidBone, Float)] = left
                ? [(.leftIndexProximal, .leftIndexIntermediate, .leftIndexDistal, 0.02),
                   (.leftMiddleProximal, .leftMiddleIntermediate, .leftMiddleDistal, 0.0),
                   (.leftRingProximal, .leftRingIntermediate, .leftRingDistal, -0.02),
                   (.leftLittleProximal, .leftLittleIntermediate, .leftLittleDistal, -0.04)]
                : [(.rightIndexProximal, .rightIndexIntermediate, .rightIndexDistal, 0.02),
                   (.rightMiddleProximal, .rightMiddleIntermediate, .rightMiddleDistal, 0.0),
                   (.rightRingProximal, .rightRingIntermediate, .rightRingDistal, -0.02),
                   (.rightLittleProximal, .rightLittleIntermediate, .rightLittleDistal, -0.04)]
            for (proximal, intermediate, distal, z) in fingers {
                let p = try add(proximal, [0.08 * sign, 0, z], parent: hand)
                let i = try add(intermediate, [0.03 * sign, 0, 0], parent: p)
                _ = try add(distal, [0.02 * sign, 0, 0], parent: i)
            }
            let meta = try add(left ? .leftThumbMetacarpal : .rightThumbMetacarpal, [0.02 * sign, -0.01, 0.02], parent: hand)
            let prox = try add(left ? .leftThumbProximal : .rightThumbProximal, [0, 0, 0.03], parent: meta)
            _ = try add(left ? .leftThumbDistal : .rightThumbDistal, [0, 0, 0.025], parent: prox)
        }

        model.nodes = nodes
        hips.updateWorldTransform()
        return model
    }

    static func worldPosition(_ bone: VRMHumanoidBone, in model: VRMModel) -> SIMD3<Float> {
        let index = model.humanoid!.getBoneNode(bone)!
        return model.nodes[index].worldPosition
    }

    private static func gltfNode(name: String, translation: SIMD3<Float>) throws -> GLTFNode {
        let json = """
        {"name": "\(name)", "translation": [\(translation.x), \(translation.y), \(translation.z)],
         "rotation": [0.0, 0.0, 0.0, 1.0], "scale": [1.0, 1.0, 1.0]}
        """
        return try JSONDecoder().decode(GLTFNode.self, from: Data(json.utf8))
    }
}
