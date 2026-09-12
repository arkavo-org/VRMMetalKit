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

/// Node IDs the pack emits. Humanoid bones are `node.<bone>`.
public enum NativeAnimeNodes {
    public static let root = "node.root"
    public static let earLeft = "node.earL"
    public static let earRight = "node.earR"
    public static let glasses = "node.glasses"
    public static let bodyMesh = "node.mesh.body"
    public static let headMesh = "node.mesh.head"
    public static let eyeLeftMesh = "node.mesh.eyeL"
    public static let eyeRightMesh = "node.mesh.eyeR"
    public static let skin = "skin.body"

    public static func bone(_ bone: VRMHumanBone) -> String { "node." + bone.rawValue }
}

/// Rest-pose skeleton (translations only, T-pose) plus distance-based skinning.
struct NativeAnimeRig {
    let layout: NativeAnimeLayout
    let handles: HeadHandles

    /// Depth-first bone order; parents precede children.
    static let boneOrder: [(VRMHumanBone, VRMHumanBone?)] = {
        var out: [(VRMHumanBone, VRMHumanBone?)] = [
            (.hips, nil), (.spine, .hips), (.chest, .spine), (.upperChest, .chest), (.neck, .upperChest), (.head, .neck),
            (.leftEye, .head), (.rightEye, .head), (.jaw, .head),
        ]
        for side in ["left", "right"] {
            let l = side == "left"
            out += [
                (l ? .leftShoulder : .rightShoulder, .upperChest),
                (l ? .leftUpperArm : .rightUpperArm, l ? .leftShoulder : .rightShoulder),
                (l ? .leftLowerArm : .rightLowerArm, l ? .leftUpperArm : .rightUpperArm),
                (l ? .leftHand : .rightHand, l ? .leftLowerArm : .rightLowerArm),
            ]
            let hand: VRMHumanBone = l ? .leftHand : .rightHand
            let chains: [[VRMHumanBone]] = l
                ? [[.leftThumbMetacarpal, .leftThumbProximal, .leftThumbDistal], [.leftIndexProximal, .leftIndexIntermediate, .leftIndexDistal],
                   [.leftMiddleProximal, .leftMiddleIntermediate, .leftMiddleDistal], [.leftRingProximal, .leftRingIntermediate, .leftRingDistal],
                   [.leftLittleProximal, .leftLittleIntermediate, .leftLittleDistal]]
                : [[.rightThumbMetacarpal, .rightThumbProximal, .rightThumbDistal], [.rightIndexProximal, .rightIndexIntermediate, .rightIndexDistal],
                   [.rightMiddleProximal, .rightMiddleIntermediate, .rightMiddleDistal], [.rightRingProximal, .rightRingIntermediate, .rightRingDistal],
                   [.rightLittleProximal, .rightLittleIntermediate, .rightLittleDistal]]
            for chain in chains {
                out.append((chain[0], hand))
                out.append((chain[1], chain[0]))
                out.append((chain[2], chain[1]))
            }
        }
        for side in ["left", "right"] {
            let l = side == "left"
            out += [
                (l ? .leftUpperLeg : .rightUpperLeg, .hips),
                (l ? .leftLowerLeg : .rightLowerLeg, l ? .leftUpperLeg : .rightUpperLeg),
                (l ? .leftFoot : .rightFoot, l ? .leftLowerLeg : .rightLowerLeg),
                (l ? .leftToes : .rightToes, l ? .leftFoot : .rightFoot),
            ]
        }
        return out
    }()

    static let bones: [VRMHumanBone] = boneOrder.map(\.0)
    static let parentOf: [VRMHumanBone: VRMHumanBone] = {
        var out: [VRMHumanBone: VRMHumanBone] = [:]
        for (b, p) in boneOrder { if let p { out[b] = p } }
        return out
    }()

    var jointIndex: [VRMHumanBone: Int] {
        var out: [VRMHumanBone: Int] = [:]
        for (i, b) in Self.bones.enumerated() { out[b] = i }
        return out
    }

    func nodes() -> [CompiledNode] {
        var out: [CompiledNode] = [CompiledNode(id: NativeAnimeNodes.root, name: "Root")]
        for (bone, parent) in Self.boneOrder {
            let world = layout.joint(bone)
            let parentWorld = parent.map { layout.joint($0) } ?? .zero
            out.append(CompiledNode(id: NativeAnimeNodes.bone(bone), name: bone.rawValue,
                                    parentId: parent.map { NativeAnimeNodes.bone($0) } ?? NativeAnimeNodes.root,
                                    translation: NAMath.f(world - parentWorld), humanoidBone: bone))
        }
        let head = layout.joint(.head)
        let headId = NativeAnimeNodes.bone(.head)
        out.append(CompiledNode(id: NativeAnimeNodes.earLeft, name: "EarL", parentId: headId, translation: NAMath.f((handles.earRoots["left"] ?? head) - head)))
        out.append(CompiledNode(id: NativeAnimeNodes.earRight, name: "EarR", parentId: headId, translation: NAMath.f((handles.earRoots["right"] ?? head) - head)))
        out.append(CompiledNode(id: NativeAnimeNodes.glasses, name: "Glasses", parentId: headId, translation: NAMath.f(handles.noseBridge - head)))
        for id in [NativeAnimeNodes.bodyMesh, NativeAnimeNodes.headMesh, NativeAnimeNodes.eyeLeftMesh, NativeAnimeNodes.eyeRightMesh] {
            out.append(CompiledNode(id: id, name: String(id.dropFirst("node.mesh.".count)), parentId: NativeAnimeNodes.root))
        }
        return out
    }

    func skin() -> CompiledSkin {
        var ibms: [SIMD16<Float>] = []
        for bone in Self.bones {
            let p = layout.joint(bone)
            var m = SIMD16<Float>(repeating: 0)
            m[0] = 1
            m[5] = 1
            m[10] = 1
            m[15] = 1
            m[12] = Float(-p.x)
            m[13] = Float(-p.y)
            m[14] = Float(-p.z)
            ibms.append(m)
        }
        return CompiledSkin(id: NativeAnimeNodes.skin, jointNodeIds: Self.bones.map { NativeAnimeNodes.bone($0) }, inverseBindMatrices: ibms)
    }

    // MARK: Weights

    private func segmentEnd(_ bone: VRMHumanBone) -> NAVec3 {
        let H = layout.height
        let start = layout.joint(bone)
        switch bone {
        case .hips: return layout.joint(.spine)
        case .spine: return layout.joint(.chest)
        case .chest: return layout.joint(.upperChest)
        case .upperChest: return layout.joint(.neck)
        case .neck: return layout.joint(.head)
        case .head: return start + NAVec3(0, layout.headHeight * 0.5, 0)
        case .leftShoulder: return layout.joint(.leftUpperArm)
        case .rightShoulder: return layout.joint(.rightUpperArm)
        case .leftUpperArm: return layout.joint(.leftLowerArm)
        case .rightUpperArm: return layout.joint(.rightLowerArm)
        case .leftLowerArm: return layout.joint(.leftHand)
        case .rightLowerArm: return layout.joint(.rightHand)
        case .leftHand: return layout.joint(.leftMiddleProximal)
        case .rightHand: return layout.joint(.rightMiddleProximal)
        case .leftUpperLeg: return layout.joint(.leftLowerLeg)
        case .rightUpperLeg: return layout.joint(.rightLowerLeg)
        case .leftLowerLeg: return layout.joint(.leftFoot)
        case .rightLowerLeg: return layout.joint(.rightFoot)
        case .leftFoot: return layout.joint(.leftToes)
        case .rightFoot: return layout.joint(.rightToes)
        case .leftToes, .rightToes: return start + NAVec3(0, 0, 0.03 * H)
        case .leftEye, .rightEye, .jaw: return start
        default:
            let children = Self.boneOrder.filter { $0.1 == bone }.map(\.0)
            if let child = children.first { return layout.joint(child) }
            let parent = Self.parentOf[bone]!
            let dir = NAMath.normalize(start - layout.joint(parent))
            return start + dir * (0.016 * H)
        }
    }

    static let leftFingers: [VRMHumanBone] = [
        .leftThumbMetacarpal, .leftThumbProximal, .leftThumbDistal, .leftIndexProximal, .leftIndexIntermediate, .leftIndexDistal,
        .leftMiddleProximal, .leftMiddleIntermediate, .leftMiddleDistal, .leftRingProximal, .leftRingIntermediate, .leftRingDistal,
        .leftLittleProximal, .leftLittleIntermediate, .leftLittleDistal,
    ]
    static let rightFingers: [VRMHumanBone] = [
        .rightThumbMetacarpal, .rightThumbProximal, .rightThumbDistal, .rightIndexProximal, .rightIndexIntermediate, .rightIndexDistal,
        .rightMiddleProximal, .rightMiddleIntermediate, .rightMiddleDistal, .rightRingProximal, .rightRingIntermediate, .rightRingDistal,
        .rightLittleProximal, .rightLittleIntermediate, .rightLittleDistal,
    ]

    static func bodyRegionBones(_ region: String) -> [VRMHumanBone] {
        switch region {
        case "neck": return [.neck, .head, .upperChest]
        case "torso", "chest", "waist", "hips": return [.hips, .spine, .chest, .upperChest, .leftShoulder, .rightShoulder]
        case "upperArmL": return [.leftShoulder, .leftUpperArm, .leftLowerArm]
        case "upperArmR": return [.rightShoulder, .rightUpperArm, .rightLowerArm]
        case "forearmL": return [.leftUpperArm, .leftLowerArm, .leftHand]
        case "forearmR": return [.rightUpperArm, .rightLowerArm, .rightHand]
        case "handL": return [.leftLowerArm, .leftHand] + leftFingers
        case "handR": return [.rightLowerArm, .rightHand] + rightFingers
        case "thighL": return [.hips, .leftUpperLeg, .leftLowerLeg]
        case "thighR": return [.hips, .rightUpperLeg, .rightLowerLeg]
        case "shinL": return [.leftUpperLeg, .leftLowerLeg, .leftFoot]
        case "shinR": return [.rightUpperLeg, .rightLowerLeg, .rightFoot]
        case "footL": return [.leftLowerLeg, .leftFoot, .leftToes]
        case "footR": return [.rightLowerLeg, .rightFoot, .rightToes]
        default: return []
        }
    }

    struct Skinning {
        var joints: [SIMD4<UInt16>]
        var weights: [SIMD4<Float>]
    }

    /// Distance-to-segment weighting with Gaussian falloff over the bones a
    /// vertex's regions allow; top four influences, normalized in double precision.
    /// Hand-region vertices use a tighter sigma so each finger binds to its own
    /// chain instead of blending across the whole mitt.
    func bodySkinning(_ mesh: BuildMesh) -> Skinning {
        let fingerBones = Set(Self.leftFingers + Self.rightFingers)
        var allowed = [[VRMHumanBone]](repeating: [], count: mesh.vertexCount)
        for region in mesh.regions.keys.sorted() {
            let bones = Self.bodyRegionBones(region)
            guard !bones.isEmpty else { continue }
            for i in mesh.regions[region]! { allowed[i] += bones }
        }
        let index = jointIndex
        var joints: [SIMD4<UInt16>] = []
        var weights: [SIMD4<Float>] = []
        joints.reserveCapacity(mesh.vertexCount)
        weights.reserveCapacity(mesh.vertexCount)
        for (i, v) in mesh.vertices.enumerated() {
            let sigma = allowed[i].contains(where: fingerBones.contains) ? 0.014 * layout.height : 0.045 * layout.height
            var candidates: [(bone: VRMHumanBone, w: Double)] = []
            var seen = Set<VRMHumanBone>()
            for bone in allowed[i] where seen.insert(bone).inserted {
                let d = NAMath.segmentDistance(v.position, layout.joint(bone), segmentEnd(bone))
                candidates.append((bone, exp(-(d / sigma) * (d / sigma))))
            }
            if candidates.isEmpty { candidates = [(.hips, 1)] }
            candidates.sort { a, b in a.w != b.w ? a.w > b.w : index[a.bone]! < index[b.bone]! }
            let top = Array(candidates.prefix(4))
            var sum = top.reduce(0) { $0 + $1.w }
            var picked = top
            if sum <= 0 {
                picked = [top[0]]
                picked[0].w = 1
                sum = 1
            }
            var j = SIMD4<UInt16>(repeating: 0)
            var w = SIMD4<Float>(repeating: 0)
            for (k, c) in picked.enumerated() {
                j[k] = UInt16(index[c.bone]!)
                w[k] = Float(c.w / sum)
            }
            joints.append(j)
            weights.append(w)
        }
        return Skinning(joints: joints, weights: weights)
    }

    func rigidSkinning(_ mesh: BuildMesh, bone: VRMHumanBone) -> Skinning {
        let j = SIMD4<UInt16>(UInt16(jointIndex[bone]!), 0, 0, 0)
        return Skinning(joints: Array(repeating: j, count: mesh.vertexCount), weights: Array(repeating: SIMD4<Float>(1, 0, 0, 0), count: mesh.vertexCount))
    }
}
