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
import XCTest
@testable import VRMAuthorKit

final class NativeAnimeRigTests: XCTestCase {
    private func worldPositions(_ avatar: CompiledAvatar) -> [String: SIMD3<Float>] {
        var out: [String: SIMD3<Float>] = [:]
        var byId: [String: CompiledNode] = [:]
        for n in avatar.nodes { byId[n.id] = n }
        func world(_ id: String) -> SIMD3<Float> {
            if let w = out[id] { return w }
            let n = byId[id]!
            let w = (n.parentId.map { world($0) } ?? .zero) + n.translation
            out[id] = w
            return w
        }
        for n in avatar.nodes { _ = world(n.id) }
        return out
    }

    func testEveryHumanoidBoneIsPresentWithParents() throws {
        let (avatar, _) = try NativeAnimeFixture.compiled()
        XCTAssertEqual(Set(avatar.humanoid.keys), Set(VRMHumanBone.allCases))
        XCTAssertEqual(avatar.humanoid.count, 55)
        for bone in VRMHumanBone.required { XCTAssertNotNil(avatar.humanoid[bone], bone.rawValue) }
        let ids = Set(avatar.nodes.map(\.id))
        XCTAssertEqual(ids.count, avatar.nodes.count, "node ids unique")
        for (bone, nodeId) in avatar.humanoid {
            let node = avatar.nodes.first { $0.id == nodeId }
            XCTAssertNotNil(node, bone.rawValue)
            XCTAssertEqual(node?.humanoidBone, bone)
            XCTAssertEqual(node?.rotation, SIMD4<Float>(0, 0, 0, 1), "rest pose carries no rotation")
            XCTAssertEqual(node?.scale, SIMD3<Float>(repeating: 1))
        }
        for n in avatar.nodes {
            if let parent = n.parentId { XCTAssertTrue(ids.contains(parent), "\(n.id) parent \(parent)") }
            else { XCTAssertEqual(n.id, NativeAnimeNodes.root) }
        }
        func parent(_ bone: VRMHumanBone) -> String? { avatar.nodes.first { $0.id == avatar.humanoid[bone] }?.parentId }
        XCTAssertEqual(parent(.spine), avatar.humanoid[.hips])
        XCTAssertEqual(parent(.chest), avatar.humanoid[.spine])
        XCTAssertEqual(parent(.upperChest), avatar.humanoid[.chest])
        XCTAssertEqual(parent(.neck), avatar.humanoid[.upperChest])
        XCTAssertEqual(parent(.head), avatar.humanoid[.neck])
        XCTAssertEqual(parent(.leftEye), avatar.humanoid[.head])
        XCTAssertEqual(parent(.jaw), avatar.humanoid[.head])
        XCTAssertEqual(parent(.leftShoulder), avatar.humanoid[.upperChest])
        XCTAssertEqual(parent(.leftUpperArm), avatar.humanoid[.leftShoulder])
        XCTAssertEqual(parent(.leftLowerArm), avatar.humanoid[.leftUpperArm])
        XCTAssertEqual(parent(.leftHand), avatar.humanoid[.leftLowerArm])
        XCTAssertEqual(parent(.leftThumbMetacarpal), avatar.humanoid[.leftHand])
        XCTAssertEqual(parent(.leftIndexProximal), avatar.humanoid[.leftHand])
        XCTAssertEqual(parent(.leftIndexIntermediate), avatar.humanoid[.leftIndexProximal])
        XCTAssertEqual(parent(.leftIndexDistal), avatar.humanoid[.leftIndexIntermediate])
        XCTAssertEqual(parent(.rightLittleDistal), avatar.humanoid[.rightLittleIntermediate])
        XCTAssertEqual(parent(.leftUpperLeg), avatar.humanoid[.hips])
        XCTAssertEqual(parent(.leftLowerLeg), avatar.humanoid[.leftUpperLeg])
        XCTAssertEqual(parent(.leftFoot), avatar.humanoid[.leftLowerLeg])
        XCTAssertEqual(parent(.leftToes), avatar.humanoid[.leftFoot])
        XCTAssertEqual(parent(.hips), NativeAnimeNodes.root)
    }

    func testRestPoseIsTPoseInMetres() throws {
        let (avatar, attachments) = try NativeAnimeFixture.compiled()
        let world = worldPositions(avatar)
        func w(_ bone: VRMHumanBone) -> SIMD3<Float> { world[avatar.humanoid[bone]!]! }
        XCTAssertGreaterThan(w(.leftUpperArm).x, 0)
        XCTAssertLessThan(w(.rightUpperArm).x, 0)
        XCTAssertGreaterThan(w(.leftUpperLeg).x, 0)
        XCTAssertLessThan(w(.rightUpperLeg).x, 0)
        for bone: VRMHumanBone in [.leftShoulder, .leftUpperArm, .leftLowerArm, .leftHand] { XCTAssertEqual(w(bone).y, w(.leftUpperArm).y, accuracy: 1e-5, bone.rawValue) }
        XCTAssertGreaterThan(w(.leftLowerArm).x, w(.leftUpperArm).x)
        XCTAssertGreaterThan(w(.leftHand).x, w(.leftLowerArm).x)
        XCTAssertGreaterThan(w(.leftIndexDistal).x, w(.leftIndexProximal).x)
        XCTAssertLessThan(w(.rightIndexDistal).x, w(.rightIndexProximal).x)
        XCTAssertGreaterThan(w(.leftThumbDistal).z, w(.leftHand).z)
        XCTAssertLessThan(w(.leftLowerLeg).y, w(.leftUpperLeg).y)
        XCTAssertLessThan(w(.leftFoot).y, w(.leftLowerLeg).y)
        XCTAssertGreaterThan(w(.leftToes).z, w(.leftFoot).z)
        XCTAssertGreaterThan(w(.leftFoot).y, 0.03)
        XCTAssertLessThan(w(.leftFoot).y, 0.15)
        XCTAssertLessThan(w(.hips).y, w(.spine).y)
        XCTAssertLessThan(w(.spine).y, w(.chest).y)
        XCTAssertLessThan(w(.chest).y, w(.upperChest).y)
        XCTAssertLessThan(w(.upperChest).y, w(.neck).y)
        XCTAssertLessThan(w(.neck).y, w(.head).y)
        XCTAssertGreaterThan(w(.hips).y, 0.7)
        XCTAssertLessThan(w(.hips).y, 1.0)
        let hc = NativeAnimeControls.entries.first { $0.key == "body.headCount" }!.defaultValue
        XCTAssertEqual(Double(w(.head).y), 1.65 - 1.65 / hc + 0.15 * 1.65 / hc, accuracy: 1e-4)
        for (bone, p) in attachments.jointWorldPositions {
            let ww = w(bone)
            XCTAssertEqual(ww.x, p.x, accuracy: 1e-5, bone.rawValue)
            XCTAssertEqual(ww.y, p.y, accuracy: 1e-5, bone.rawValue)
            XCTAssertEqual(ww.z, p.z, accuracy: 1e-5, bone.rawValue)
        }
        for eye in attachments.eyes {
            let ww = world[eye.boneNodeId]!
            XCTAssertEqual(ww.x, eye.center.x, accuracy: 1e-5)
            XCTAssertEqual(ww.y, eye.center.y, accuracy: 1e-5)
            XCTAssertEqual(ww.z, eye.center.z, accuracy: 1e-5)
        }
        let mid = (attachments.eyes[0].center + attachments.eyes[1].center) * 0.5 - w(.head)
        XCTAssertEqual(avatar.lookAt.offsetFromHeadBone[0], Double(mid.x), accuracy: 1e-5)
        XCTAssertEqual(avatar.lookAt.offsetFromHeadBone[1], Double(mid.y), accuracy: 1e-5)
        XCTAssertEqual(avatar.lookAt.offsetFromHeadBone[2], Double(mid.z), accuracy: 1e-5)
        XCTAssertGreaterThan(avatar.lookAt.offsetFromHeadBone[1], 0)
        XCTAssertGreaterThan(avatar.lookAt.offsetFromHeadBone[2], 0)
    }

    func testProportionControlsMoveTheRig() throws {
        let (base, ba) = try NativeAnimeFixture.compiled()
        let (wide, wa) = try NativeAnimeFixture.compiled { $0.body["body.proportion.shoulderWidth"] = 1 }
        XCTAssertGreaterThan(wa.jointWorldPositions[.leftUpperArm]!.x, ba.jointWorldPositions[.leftUpperArm]!.x + 0.005)
        XCTAssertEqual(wa.jointWorldPositions[.hips], ba.jointWorldPositions[.hips])
        let (longArms, la) = try NativeAnimeFixture.compiled { $0.body["body.proportion.armLength"] = 1 }
        XCTAssertGreaterThan(la.jointWorldPositions[.leftHand]!.x, ba.jointWorldPositions[.leftHand]!.x + 0.01)
        let (_, lg) = try NativeAnimeFixture.compiled { $0.body["body.proportion.legLength"] = 1 }
        XCTAssertGreaterThan(lg.jointWorldPositions[.hips]!.y, ba.jointWorldPositions[.hips]!.y + 0.01)
        XCTAssertEqual(lg.jointWorldPositions[.head], ba.jointWorldPositions[.head])
        let (_, tl) = try NativeAnimeFixture.compiled { $0.body["body.proportion.torsoLength"] = 1 }
        XCTAssertLessThan(tl.jointWorldPositions[.hips]!.y, ba.jointWorldPositions[.hips]!.y - 0.005)
        let (_, hw) = try NativeAnimeFixture.compiled { $0.body["body.proportion.hipWidth"] = 1 }
        XCTAssertGreaterThan(hw.jointWorldPositions[.leftUpperLeg]!.x, ba.jointWorldPositions[.leftUpperLeg]!.x + 0.005)
        let (_, sp) = try NativeAnimeFixture.compiled { $0.face["face.eye.left.spacing"] = 1 }
        XCTAssertGreaterThan(sp.jointWorldPositions[.leftEye]!.x, ba.jointWorldPositions[.leftEye]!.x + 0.003)
        XCTAssertEqual(sp.jointWorldPositions[.rightEye], ba.jointWorldPositions[.rightEye])
        XCTAssertNotEqual(base.skins[0].inverseBindMatrices, wide.skins[0].inverseBindMatrices)
        XCTAssertNotEqual(base.skins[0].inverseBindMatrices, longArms.skins[0].inverseBindMatrices)
    }

    func testSkinWeightsNormalizedAndInverseBindMatricesMatchRestPose() throws {
        let (avatar, _) = try NativeAnimeFixture.compiled()
        let skin = avatar.skins[0]
        XCTAssertEqual(skin.jointNodeIds.count, 55)
        XCTAssertEqual(skin.inverseBindMatrices.count, 55)
        XCTAssertEqual(Set(skin.jointNodeIds), Set(avatar.humanoid.values))
        let world = worldPositions(avatar)
        for (i, id) in skin.jointNodeIds.enumerated() {
            let m = skin.inverseBindMatrices[i]
            let p = world[id]!
            XCTAssertEqual(m[0], 1)
            XCTAssertEqual(m[5], 1)
            XCTAssertEqual(m[10], 1)
            XCTAssertEqual(m[15], 1)
            XCTAssertEqual(m[12], -p.x, accuracy: 1e-5, id)
            XCTAssertEqual(m[13], -p.y, accuracy: 1e-5, id)
            XCTAssertEqual(m[14], -p.z, accuracy: 1e-5, id)
        }
        let jointIndex = Dictionary(uniqueKeysWithValues: skin.jointNodeIds.enumerated().map { ($1, $0) })
        func index(_ bone: VRMHumanBone) -> UInt16 { UInt16(jointIndex[avatar.humanoid[bone]!]!) }
        for mesh in avatar.meshes {
            for p in mesh.primitives {
                let joints = p.joints0!, weights = p.weights0!
                for i in 0..<p.positions.count {
                    let w = weights[i]
                    let sum = Double(w.x) + Double(w.y) + Double(w.z) + Double(w.w)
                    XCTAssertEqual(sum, 1, accuracy: 1e-4, "\(mesh.id) vertex \(i)")
                    for k in 0..<4 {
                        XCTAssertGreaterThanOrEqual(w[k], 0)
                        XCTAssertLessThan(Int(joints[i][k]), skin.jointNodeIds.count)
                        if w[k] == 0 { XCTAssertEqual(joints[i][k], 0, "unused slots are zeroed") }
                    }
                    XCTAssertGreaterThan(w.x, 0, "primary influence")
                }
            }
        }
        let eyeL = NativeAnimeFixture.primitive(avatar, mesh: "mesh.eyeL")
        for (j, w) in zip(eyeL.joints0!, eyeL.weights0!) {
            XCTAssertEqual(j.x, index(.leftEye))
            XCTAssertEqual(w.x, 1)
        }
        let head = NativeAnimeFixture.primitive(avatar, mesh: "mesh.head")
        for j in head.joints0! { XCTAssertEqual(j.x, index(.head)) }
    }

    func testBodyWeightsFollowRegions() throws {
        let (avatar, attachments) = try NativeAnimeFixture.compiled()
        let skin = avatar.skins[0]
        let jointIndex = Dictionary(uniqueKeysWithValues: skin.jointNodeIds.enumerated().map { ($1, $0) })
        func index(_ bone: VRMHumanBone) -> UInt16 { UInt16(jointIndex[avatar.humanoid[bone]!]!) }
        let body = NativeAnimeFixture.primitive(avatar, mesh: "mesh.body")
        func dominant(_ i: Int) -> UInt16 { body.joints0![i].x }
        let expectations: [(String, Set<VRMHumanBone>)] = [
            ("handL", Set([.leftHand] + NativeAnimeRig.leftFingers + [.leftLowerArm])),
            ("handR", Set([.rightHand] + NativeAnimeRig.rightFingers + [.rightLowerArm])),
            ("forearmL", [.leftLowerArm, .leftUpperArm, .leftHand]),
            ("upperArmR", [.rightUpperArm, .rightShoulder, .rightLowerArm]),
            ("thighL", [.leftUpperLeg, .hips, .leftLowerLeg]),
            ("shinR", [.rightLowerLeg, .rightUpperLeg, .rightFoot]),
            ("footL", [.leftFoot, .leftToes, .leftLowerLeg]),
            ("neck", [.neck, .head, .upperChest]),
            ("hips", [.hips, .spine, .chest, .upperChest, .leftShoulder, .rightShoulder]),
        ]
        for (region, bones) in expectations {
            let allowed = Set(bones.map(index))
            let indices = attachments.indices(of: region, mesh: "mesh.body")
            XCTAssertFalse(indices.isEmpty, region)
            for i in indices { XCTAssertTrue(allowed.contains(dominant(i)), "\(region) vertex \(i) bound to joint \(dominant(i))") }
        }
        let fingertip = attachments.indices(of: "handL", mesh: "mesh.body").max { body.positions[$0].x < body.positions[$1].x }!
        let fingerJoints = Set(NativeAnimeRig.leftFingers.map(index))
        XCTAssertTrue(fingerJoints.contains(dominant(fingertip)), "mitt tip follows a finger bone")
        let knee = attachments.indices(of: "thighL", mesh: "mesh.body").min { body.positions[$0].y < body.positions[$1].y }!
        let kw = body.weights0![knee]
        XCTAssertLessThan(kw.x, 0.999, "joint vertices blend between two bones")
    }
}
