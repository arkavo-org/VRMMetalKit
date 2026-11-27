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

import XCTest
import Metal
import simd
@testable import VRMMetalKit

/// Regression and correctness suite for issue #478:
/// 1. Adaptive 2/3-capsule mesh-fitted hand paddles (plus bone-position fallback)
///    replacing both the #381 wrist-only hand sphere and the unclamped fraction sphere.
/// 2. Mesh-name-agnostic skinned mesh fitting (covers non-"body" models like `vrm-author`).
/// 3. VRM 1.0 terminal cloth joint `hitRadius` inheritance (synthetic group only).
/// 4. Race-free GPU skirt ring-span chord collision (preserving #452 dispatch determinism
///    and ADR-007 sleeve exclusion).
final class SpringBoneHandSkirtCollisionTests: XCTestCase {

    private var device: MTLDevice!
    private var commandQueue: MTLCommandQueue!

    override func setUpWithError() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        guard let queue = device.makeCommandQueue() else {
            throw XCTSkip("Could not create Metal command queue")
        }
        self.device = device
        self.commandQueue = queue
    }

    // MARK: - 1. Layout & ABI

    func testSpringBoneCollisionAuxStructLayoutMatchesMetal() {
        XCTAssertEqual(MemoryLayout<SpringBoneCollisionAux>.size, 16)
        XCTAssertEqual(MemoryLayout<SpringBoneCollisionAux>.stride, 16)
        XCTAssertEqual(MemoryLayout<SpringBoneCollisionAux>.alignment, 4)
        let def = SpringBoneCollisionAux()
        XCTAssertEqual(def.ringLeft, 0xFFFFFFFF)
        XCTAssertEqual(def.ringRight, 0xFFFFFFFF)
        XCTAssertEqual(def.syntheticRadius, 0.0)
        XCTAssertEqual(def.flags, 0)
    }

    // MARK: - 2. Mesh-fitted hand paddles & mesh-name-agnostic scanning

    @MainActor
    func testHandPaddlesReplaceForcefieldAndCoverFingersOnUnauthoredModel() async throws {
        let path = getTestModelPath("AvatarSample_U_1.0.vrm.glb")
        try requireFixture(path, hint: "AvatarSample_U_1.0.vrm.glb")
        let model = try await VRMModel.load(
            from: URL(fileURLWithPath: path),
            device: device,
            options: VRMLoadingOptions(augmentSpringBoneColliders: true)
        )
        let humanoid = try XCTUnwrap(model.humanoid)
        let leftHand = try XCTUnwrap(humanoid.getBoneNode(.leftHand))
        let rightHand = try XCTUnwrap(humanoid.getBoneNode(.rightHand))

        // Strip authored hand colliders (simulating the 12/33 unauthored models like
        // vrm-author / Elias / Godette) and re-run load-time augmentation.
        var sb = try XCTUnwrap(model.springBone)
        sb.colliders.removeAll { $0.node == leftHand || $0.node == rightHand }
        model.springBone = sb
        try model.initializeSpringBoneGPUSystem(device: device, augmentColliders: true)

        let synthetic = try XCTUnwrap(model.springBone).syntheticColliders
        for (label, node) in [("leftHand", leftHand), ("rightHand", rightHand)] {
            let handSpheres = synthetic.filter {
                if case .sphere = $0.shape { return $0.node == node }
                return false
            }
            XCTAssertTrue(handSpheres.isEmpty,
                          "\(label) must not retain the unclamped 0.40x forearm forcefield sphere")

            let paddles = synthetic.filter {
                if case .capsule = $0.shape { return $0.node == node }
                return false
            }
            XCTAssertTrue((2...3).contains(paddles.count),
                          "\(label) should emit 2 or 3 slim paddle capsules, got \(paddles.count)")
            for p in paddles {
                guard case let .capsule(offset, r, tail) = p.shape else { continue }
                // Flat VRoid hand: slim radius (< 25mm), full wrist->fingertip span (> 100mm)
                XCTAssertLessThan(r, 0.025,
                                  "\(label) paddle radius \(r) must stay slim (not TipSleeve-contaminated)")
                XCTAssertGreaterThan(simd_length(tail - offset) + 2 * r, 0.10,
                                     "\(label) paddle must cover wrist through fingertips")
            }
        }
    }

    @MainActor
    func testMeshFitIgnoresMeshNamesForNonBodyMeshes() async throws {
        let path = getTestVRM10ModelPath()
        try requireFixture(path, hint: testVRM10Filename)
        let model = try await VRMModel.load(
            from: URL(fileURLWithPath: path),
            device: device,
            options: VRMLoadingOptions(augmentSpringBoneColliders: true)
        )

        let baseline = SpringBoneMeshFit.computeAll(model: model)
        XCTAssertFalse(baseline.breasts.isEmpty)
        XCTAssertEqual(baseline.shoulders.count, 2)
        XCTAssertEqual(baseline.torso.count, 1)
        XCTAssertGreaterThanOrEqual(baseline.hands.count, 4)

        // Rebuild meshes with vrm-author-style names ("Garment_outfit.001") where zero
        // meshes contain "body", preserving primitives verbatim.
        model.meshes = model.meshes.enumerated().map { idx, mesh in
            let renamed = VRMMesh(name: idx == 0 ? "Head" : "Garment_outfit.00\(idx)")
            renamed.primitives = mesh.primitives
            return renamed
        }

        let renamedFit = SpringBoneMeshFit.computeAll(model: model)
        XCTAssertEqual(renamedFit.breasts.count, baseline.breasts.count,
                       "Breast collider fit must not depend on mesh name containing 'body'")
        XCTAssertEqual(renamedFit.shoulders.count, baseline.shoulders.count,
                       "Shoulder collider fit must not depend on mesh name containing 'body'")
        XCTAssertEqual(renamedFit.torso.count, baseline.torso.count,
                       "Torso collider fit must not depend on mesh name containing 'body'")
        XCTAssertEqual(renamedFit.hands.count, baseline.hands.count,
                       "Hand paddle fit must not depend on mesh name containing 'body'")

        // Verify fitted collider nodes and shapes match exactly, not just counts.
        func assertSameColliders(_ lhs: [VRMCollider], _ rhs: [VRMCollider], label: String) {
            XCTAssertEqual(lhs.count, rhs.count, "\(label) count mismatch")
            for (a, b) in zip(lhs, rhs) {
                XCTAssertEqual(a.node, b.node, "\(label) node mismatch")
                switch (a.shape, b.shape) {
                case let (.sphere(o1, r1), .sphere(o2, r2)):
                    XCTAssertLessThan(simd_distance(o1, o2), 1e-6, "\(label) sphere offset mismatch")
                    XCTAssertEqual(r1, r2, accuracy: 1e-6, "\(label) sphere radius mismatch")
                case let (.capsule(o1, r1, t1), .capsule(o2, r2, t2)):
                    XCTAssertLessThan(simd_distance(o1, o2), 1e-6, "\(label) capsule offset mismatch")
                    XCTAssertLessThan(simd_distance(t1, t2), 1e-6, "\(label) capsule tail mismatch")
                    XCTAssertEqual(r1, r2, accuracy: 1e-6, "\(label) capsule radius mismatch")
                default:
                    XCTFail("\(label) shape type mismatch")
                }
            }
        }
        assertSameColliders(renamedFit.breasts, baseline.breasts, label: "breasts")
        assertSameColliders(renamedFit.shoulders, baseline.shoulders, label: "shoulders")
        assertSameColliders(renamedFit.torso, baseline.torso, label: "torso")
        assertSameColliders(renamedFit.hands, baseline.hands, label: "hands")
    }

    func testHandPaddleBoneFallbackWithoutSkinnedMeshes() throws {
        let gltfJson = #"{"asset":{"version":"2.0"}}"#
        let gltf = try JSONDecoder().decode(GLTFDocument.self, from: Data(gltfJson.utf8))
        let humanoid = VRMHumanoid()
        let model = VRMModel(specVersion: .v1_0, meta: VRMMeta(licenseUrl: ""), humanoid: humanoid, gltf: gltf)

        func makeNode(_ index: Int, name: String, pos: SIMD3<Float>, parent: VRMNode? = nil) -> VRMNode {
            let n = VRMNode(index: index, gltfNode: GLTFNode(name: name))
            n.translation = pos
            n.parent = parent
            parent?.children.append(n)
            n.updateLocalMatrix()
            n.updateWorldTransform()
            return n
        }

        let lowerArm = makeNode(0, name: "L_LowerArm", pos: SIMD3<Float>(0.30, 1.2, 0))
        let hand = makeNode(1, name: "L_Hand", pos: SIMD3<Float>(0.24, 0, 0), parent: lowerArm)
        let indexP = makeNode(2, name: "L_IndexProximal", pos: SIMD3<Float>(0.07, 0, 0.025), parent: hand)
        let middleD = makeNode(3, name: "L_MiddleDistal", pos: SIMD3<Float>(0.12, 0, 0.0), parent: hand)
        let littleP = makeNode(4, name: "L_LittleProximal", pos: SIMD3<Float>(0.065, 0, -0.028), parent: hand)
        model.nodes = [lowerArm, hand, indexP, middleD, littleP]
        lowerArm.updateWorldTransform()

        humanoid.humanBones[.leftLowerArm] = VRMHumanoid.VRMHumanBone(node: 0)
        humanoid.humanBones[.leftHand] = VRMHumanoid.VRMHumanBone(node: 1)
        humanoid.humanBones[.leftIndexProximal] = VRMHumanoid.VRMHumanBone(node: 2)
        humanoid.humanBones[.leftMiddleDistal] = VRMHumanoid.VRMHumanBone(node: 3)
        humanoid.humanBones[.leftLittleProximal] = VRMHumanoid.VRMHumanBone(node: 4)

        let paddles = SpringBoneMeshFit.computeHandColliders(model: model)
        XCTAssertTrue((2...3).contains(paddles.count),
                      "Bone-position fallback should emit 2–3 slim paddle capsules, got \(paddles.count)")
        for c in paddles {
            XCTAssertEqual(c.node, 1)
            guard case let .capsule(offset, r, tail) = c.shape else {
                return XCTFail("Expected capsule")
            }
            XCTAssertTrue(r.isFinite && r > 0.008 && r < 0.035, "Fallback radius \(r) should be hand-sized")
            XCTAssertGreaterThan(simd_length(tail - offset) + 2 * r, 0.11, "Fallback paddle should reach fingertips")
        }
    }

    func testPropSkinnedToHandOutlierGuardFallsBackToBonePaddle() throws {
        let gltfJson = #"{"asset":{"version":"2.0"}}"#
        let gltf = try JSONDecoder().decode(GLTFDocument.self, from: Data(gltfJson.utf8))
        let humanoid = VRMHumanoid()
        let model = VRMModel(specVersion: .v1_0, meta: VRMMeta(licenseUrl: ""), humanoid: humanoid, gltf: gltf)

        func makeNode(_ index: Int, name: String, pos: SIMD3<Float>, parent: VRMNode? = nil) -> VRMNode {
            let n = VRMNode(index: index, gltfNode: GLTFNode(name: name))
            n.translation = pos
            n.parent = parent
            parent?.children.append(n)
            n.updateLocalMatrix()
            n.updateWorldTransform()
            return n
        }

        let lowerArm = makeNode(0, name: "L_LowerArm", pos: SIMD3<Float>(0.30, 1.2, 0))
        let hand = makeNode(1, name: "L_Hand", pos: SIMD3<Float>(0.24, 0, 0), parent: lowerArm)
        let indexP = makeNode(2, name: "L_IndexProximal", pos: SIMD3<Float>(0.07, 0, 0.025), parent: hand)
        let middleD = makeNode(3, name: "L_MiddleDistal", pos: SIMD3<Float>(0.12, 0, 0.0), parent: hand)
        let littleP = makeNode(4, name: "L_LittleProximal", pos: SIMD3<Float>(0.065, 0, -0.028), parent: hand)
        let meshNode = VRMNode(index: 5, gltfNode: GLTFNode(name: "WeaponMesh", mesh: 0, skin: 0))
        meshNode.updateLocalMatrix()
        meshNode.updateWorldTransform()
        model.nodes = [lowerArm, hand, indexP, middleD, littleP, meshNode]
        lowerArm.updateWorldTransform()

        humanoid.humanBones[.leftLowerArm] = VRMHumanoid.VRMHumanBone(node: 0)
        humanoid.humanBones[.leftHand] = VRMHumanoid.VRMHumanBone(node: 1)
        humanoid.humanBones[.leftIndexProximal] = VRMHumanoid.VRMHumanBone(node: 2)
        humanoid.humanBones[.leftMiddleDistal] = VRMHumanoid.VRMHumanBone(node: 3)
        humanoid.humanBones[.leftLittleProximal] = VRMHumanoid.VRMHumanBone(node: 4)

        // Skin a 0.90m prop (exceeds 1.8x forearmLen = 0.432m) directly onto L_Hand.
        let skin = VRMSkin(name: "HandPropSkin")
        skin.joints = [hand]
        skin.inverseBindMatrices = [simd_inverse(hand.worldMatrix)]
        model.skins = [skin]

        var verts: [VRMVertex] = []
        for i in 0..<24 {
            let x = 0.54 + Float(i) * (0.90 / 23.0)
            let y: Float = 1.20 + (i % 2 == 0 ? 0.02 : -0.02)
            let z: Float = (i % 3 == 0 ? 0.03 : -0.03)
            verts.append(VRMVertex(
                position: SIMD3<Float>(x, y, z),
                normal: SIMD3<Float>(0, 1, 0),
                texCoord: SIMD2<Float>(0, 0),
                color: SIMD4<Float>(1, 1, 1, 1),
                joints: SIMD4<UInt32>(0, 0, 0, 0),
                weights: SIMD4<Float>(1, 0, 0, 0)
            ))
        }
        let prim = VRMPrimitive()
        prim.uploadVertices(verts, device: device)
        let mesh = VRMMesh(name: "Outfit")
        mesh.primitives = [prim]
        model.meshes = [mesh]

        let paddles = SpringBoneMeshFit.computeHandColliders(model: model)
        XCTAssertTrue((2...3).contains(paddles.count),
                      "Outlier prop must reject mesh fit and fall back to bone paddle, got \(paddles.count)")
        for c in paddles {
            guard case let .capsule(offset, r, tail) = c.shape else {
                return XCTFail("Expected capsule")
            }
            let totalReach = simd_length(tail - offset) + 2 * r
            XCTAssertLessThan(totalReach, 0.25,
                              "Outlier guard must prevent 0.90m prop from inflating hand paddle (got \(totalReach)m)")
            XCTAssertLessThan(r, 0.035, "Fallback paddle radius must stay hand-sized (got \(r)m)")
        }
    }

    func testCenterDeltaDedupAndBatchedWarmupPreserveRigidFollow() throws {
        let gltfJson = #"{"asset":{"version":"2.0"}}"#
        let gltf = try JSONDecoder().decode(GLTFDocument.self, from: Data(gltfJson.utf8))
        let model = VRMModel(specVersion: .v1_0, meta: VRMMeta(licenseUrl: ""), humanoid: nil, gltf: gltf)

        let center = VRMNode(index: 0, gltfNode: GLTFNode(name: "CenterRoot"))
        center.translation = SIMD3<Float>(0, 0, 0)
        center.updateLocalMatrix()
        center.updateWorldTransform()

        var nodes: [VRMNode] = [center]
        var springs: [VRMSpring] = []
        // 4 springs all sharing centerNodeIndex == 0 exercises the #222 dedup cache
        // (both static identity fast-path during warmup and moving delta path during update).
        for s in 0..<4 {
            let rIdx = nodes.count
            let rNode = VRMNode(index: rIdx, gltfNode: GLTFNode(name: "S\(s)_Root"))
            rNode.translation = SIMD3<Float>(Float(s) * 0.1, 1.0, 0)
            rNode.parent = center
            rNode.updateLocalMatrix()
            center.children.append(rNode)
            nodes.append(rNode)

            let tIdx = nodes.count
            let tNode = VRMNode(index: tIdx, gltfNode: GLTFNode(name: "S\(s)_Tip"))
            tNode.translation = SIMD3<Float>(0, -0.15, 0)
            tNode.parent = rNode
            tNode.updateLocalMatrix()
            rNode.children.append(tNode)
            nodes.append(tNode)

            var j0 = VRMSpringJoint(node: rIdx); j0.hitRadius = 0.01; j0.stiffness = 1.0; j0.dragForce = 0.5; j0.gravityPower = 0.0
            var j1 = VRMSpringJoint(node: tIdx); j1.hitRadius = 0.01; j1.stiffness = 1.0; j1.dragForce = 0.5; j1.gravityPower = 0.0
            var sp = VRMSpring(name: "SharedCenter_\(s)")
            sp.center = 0
            sp.joints = [j0, j1]
            springs.append(sp)
        }
        model.nodes = nodes
        model.device = device
        center.updateWorldTransform()

        var sb = VRMSpringBone()
        sb.springs = springs
        model.springBone = sb

        let totalBones = 8
        let buffers = SpringBoneBuffers(device: device)
        buffers.allocateBuffers(numBones: totalBones, numSpheres: 0, numCapsules: 0, numPlanes: 0)
        model.springBoneBuffers = buffers
        model.springBoneGlobalParams = SpringBoneTestFixtures.defaultGlobalParams(numBones: totalBones)

        let system = try SpringBoneComputeSystem(device: device)
        try system.populateSpringBoneData(model: model)
        system.warmupPhysics(model: model, steps: 30)

        let afterWarmup = SpringBoneTestFixtures.readBonePositions(model: model)
        for s in 0..<4 {
            let expectedTip = SIMD3<Float>(Float(s) * 0.1, 0.85, 0)
            XCTAssertLessThan(simd_distance(afterWarmup[s * 2 + 1], expectedTip), 1e-4,
                              "Batched warmup must keep zero-gravity shared-center tip at rest")
        }

        // Translate shared center node by +2.0m in X; center-space rigid follow must carry
        // all 4 chains cleanly with zero lag/stretch.
        let shift = SIMD3<Float>(2.0, 0.0, 0.0)
        center.translation = shift
        center.updateLocalMatrix()
        center.updateWorldTransform()
        system.update(model: model, deltaTime: 1.0 / 60.0, commandBuffer: nil)
        system.waitForPendingFrame()

        let afterMove = SpringBoneTestFixtures.readBonePositions(model: model)
        for s in 0..<4 {
            let expectedTip = SIMD3<Float>(Float(s) * 0.1 + shift.x, 0.85, 0)
            XCTAssertLessThan(simd_distance(afterMove[s * 2 + 1], expectedTip), 1e-3,
                              "Shared-center delta dedup must rigidly carry spring \(s) with center translation")
        }
    }

    // MARK: - 3. Ring Detection & Terminal Cloth hitRadius Inheritance

    @MainActor
    func testSkirtRingDetectionAndHemRadiusInheritanceOnAvatarSampleU() async throws {
        let path = getTestModelPath("AvatarSample_U_1.0.vrm.glb")
        try requireFixture(path, hint: "AvatarSample_U_1.0.vrm.glb")
        let model = try await VRMModel.load(
            from: URL(fileURLWithPath: path),
            device: device,
            options: VRMLoadingOptions(augmentSpringBoneColliders: true)
        )
        let sb = try XCTUnwrap(model.springBone)

        let onResult = SpringBoneSkirtRingDetector.buildCollisionAux(model: model, hasSyntheticColliders: true)
        // AvatarSample_U has 3 actually skinned cloth sheets (layers _01 & _02 full 6-chain
        // flared skirt rings + layer _03 open-front back panel); the 20 unskinned VRoid
        // template chains carry zero mesh vertices and are skipped automatically.
        XCTAssertEqual(onResult.ringCount, 3,
                       "AvatarSample_U should detect its 3 skinned cloth sheets via mesh topology")
        XCTAssertTrue(onResult.hasRingNeighbors)
        XCTAssertGreaterThanOrEqual(onResult.inheritedHemRadiusCount, 36,
                                    "All lower-body terminal hem joints should inherit parent hitRadius")

        // Verify Sleeve, Hair, and Bust chains are NEVER linked into rings, Sleeve hems stay 0,
        // and no kinematic root joint (j == 0) ever receives a ring neighbor.
        var boneIdx = 0
        for spring in sb.springs where !spring.joints.isEmpty {
            let name = (spring.name ?? "").lowercased()
            let isSleeve = name.contains("sleeve")
            let isHairOrBust = name.contains("hair") || name.contains("bust")
            for (j, joint) in spring.joints.enumerated() {
                let aux = onResult.aux[boneIdx]
                if j == 0 {
                    XCTAssertEqual(aux.ringLeft, SpringBoneSkirtRingDetector.noNeighbor,
                                   "Kinematic root joint must never receive ringLeft")
                    XCTAssertEqual(aux.ringRight, SpringBoneSkirtRingDetector.noNeighbor,
                                   "Kinematic root joint must never receive ringRight")
                }
                if isSleeve || isHairOrBust {
                    XCTAssertEqual(aux.ringLeft, SpringBoneSkirtRingDetector.noNeighbor,
                                   "Non-cloth-sheet chain '\(name)' must never receive ring neighbors")
                    XCTAssertEqual(aux.ringRight, SpringBoneSkirtRingDetector.noNeighbor,
                                   "Non-cloth-sheet chain '\(name)' must never receive ring neighbors")
                }
                if isSleeve && j == spring.joints.count - 1 {
                    XCTAssertEqual(aux.syntheticRadius, joint.hitRadius, accuracy: 1e-6,
                                   "ADR-007: stiff Sleeve terminal joint must not alter its hitRadius")
                }
                boneIdx += 1
            }
        }

        // Name-agnosticism proof: renaming every spring to an opaque non-English/numbered
        // identifier must produce bit-identical cloth-sheet chords and components.
        let chainSyntheticMask = sb.springs.compactMap { sp -> Bool? in
            guard !sp.joints.isEmpty else { return nil }
            return !(sp.name ?? "").lowercased().contains("bust")
        }
        var renamedSB = sb
        for i in renamedSB.springs.indices {
            renamedSB.springs[i].name = "布チェーン_\(i)"
        }
        model.springBone = renamedSB
        let renamedResult = SpringBoneSkirtRingDetector.buildCollisionAux(
            model: model,
            hasSyntheticColliders: true,
            chainSyntheticEnabled: chainSyntheticMask
        )
        XCTAssertEqual(renamedResult.ringCount, onResult.ringCount)
        XCTAssertEqual(renamedResult.linkedBoneCount, onResult.linkedBoneCount)
        XCTAssertEqual(renamedResult.inheritedHemRadiusCount, onResult.inheritedHemRadiusCount)
        XCTAssertEqual(renamedResult.ringChainComponents, onResult.ringChainComponents)
        for i in onResult.aux.indices {
            XCTAssertEqual(renamedResult.aux[i].ringLeft, onResult.aux[i].ringLeft)
            XCTAssertEqual(renamedResult.aux[i].ringRight, onResult.aux[i].ringRight)
            XCTAssertEqual(renamedResult.aux[i].syntheticRadius, onResult.aux[i].syntheticRadius)
        }

        // With augmentation OFF, ring detection and hem inheritance must be completely inert.
        let offResult = SpringBoneSkirtRingDetector.buildCollisionAux(model: model, hasSyntheticColliders: false)
        XCTAssertFalse(offResult.hasRingNeighbors)
        XCTAssertEqual(offResult.ringCount, 0)
        XCTAssertEqual(offResult.inheritedHemRadiusCount, 0)
    }

    func testMeshTopologyDetectsUpperBodyCapeAndRespectsOpenFrontSlitWithoutNames() throws {
        let gltfJson = #"{"asset":{"version":"2.0"}}"#
        let gltf = try JSONDecoder().decode(GLTFDocument.self, from: Data(gltfJson.utf8))
        let humanoid = VRMHumanoid()
        let model = VRMModel(specVersion: .v1_0, meta: VRMMeta(licenseUrl: ""), humanoid: humanoid, gltf: gltf)

        let upperChest = VRMNode(index: 0, gltfNode: GLTFNode(name: "UpperChest"))
        upperChest.translation = SIMD3<Float>(0, 1.30, 0)
        upperChest.updateLocalMatrix()
        humanoid.humanBones[.upperChest] = VRMHumanoid.VRMHumanBone(node: 0)

        var nodes: [VRMNode] = [upperChest]
        var springs: [VRMSpring] = []
        var skinJoints: [VRMNode] = []
        // 4 cape panels hanging from upperChest with opaque names (no "skirt"/"cape" words!),
        // arranged at -135°, -45°, +45°, +135° (60°-90° front slit between chain 1 and chain 2).
        let anglesDeg: [Float] = [-135, -45, 45, 135]
        for (k, deg) in anglesDeg.enumerated() {
            let rad = deg * .pi / 180.0
            let rIdx = nodes.count
            let rNode = VRMNode(index: rIdx, gltfNode: GLTFNode(name: "Opaque_\(k)_A"))
            rNode.translation = SIMD3<Float>(sin(rad) * 0.16, 0.0, cos(rad) * 0.16)
            rNode.parent = upperChest
            rNode.updateLocalMatrix()
            upperChest.children.append(rNode)
            nodes.append(rNode)

            let tIdx = nodes.count
            let tNode = VRMNode(index: tIdx, gltfNode: GLTFNode(name: "Opaque_\(k)_B"))
            tNode.translation = SIMD3<Float>(0, -0.25, 0)
            tNode.parent = rNode
            tNode.updateLocalMatrix()
            rNode.children.append(tNode)
            nodes.append(tNode)

            skinJoints.append(rNode)
            var j0 = VRMSpringJoint(node: rIdx); j0.hitRadius = 0.018
            var j1 = VRMSpringJoint(node: tIdx); j1.hitRadius = 0.0
            var sp = VRMSpring(name: "Panel_\(k)")
            sp.joints = [j0, j1]
            springs.append(sp)
        }
        let meshNode = VRMNode(index: nodes.count, gltfNode: GLTFNode(name: "GarmentMesh", mesh: 0, skin: 0))
        meshNode.updateLocalMatrix()
        nodes.append(meshNode)
        model.nodes = nodes
        upperChest.updateWorldTransform()

        // Stitch chains (0-1), (0-3), (3-2) with mesh quads — leaving the front slit (1-2) UNSTITCHED.
        let skin = VRMSkin(name: "CapeSkin")
        skin.joints = skinJoints
        skin.inverseBindMatrices = skinJoints.map { simd_inverse($0.worldMatrix) }
        model.skins = [skin]

        var verts: [VRMVertex] = []
        var indices: [UInt16] = []
        for (c0, c1) in [(0, 1), (0, 3), (3, 2)] {
            let base = UInt16(verts.count)
            for row in 0..<2 {
                let y: Float = 1.30 - Float(row) * 0.25
                verts.append(VRMVertex(
                    position: SIMD3<Float>(0, y, 0),
                    normal: SIMD3<Float>(0, 0, 1),
                    texCoord: .zero,
                    color: SIMD4<Float>(1, 1, 1, 1),
                    joints: SIMD4<UInt32>(UInt32(c0), 0, 0, 0),
                    weights: SIMD4<Float>(1, 0, 0, 0)
                ))
                verts.append(VRMVertex(
                    position: SIMD3<Float>(0.1, y, 0),
                    normal: SIMD3<Float>(0, 0, 1),
                    texCoord: .zero,
                    color: SIMD4<Float>(1, 1, 1, 1),
                    joints: SIMD4<UInt32>(UInt32(c1), 0, 0, 0),
                    weights: SIMD4<Float>(1, 0, 0, 0)
                ))
            }
            indices.append(contentsOf: [base, base + 1, base + 2, base + 1, base + 3, base + 2])
        }
        let prim = VRMPrimitive()
        prim.uploadVertices(verts, device: device)
        prim.indexCount = indices.count
        prim.indexType = .uint16
        prim.primitiveType = .triangle
        prim.indexBuffer = indices.withUnsafeBytes { bytes in
            device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: .storageModeShared)
        }
        let mesh = VRMMesh(name: "Cloak")
        mesh.primitives = [prim]
        model.meshes = [mesh]

        var sb = VRMSpringBone()
        sb.springs = springs
        model.springBone = sb

        let result = SpringBoneSkirtRingDetector.buildCollisionAux(model: model, hasSyntheticColliders: true)
        XCTAssertEqual(result.ringCount, 1, "All 4 stitched cape panels should form 1 connected cloth sheet")
        XCTAssertEqual(result.inheritedHemRadiusCount, 4, "All 4 cape terminals should inherit parent hitRadius")
        // Chain 1 (bone 3) and chain 2 (bone 5) flank the unstitched 90° front slit:
        // despite being < 110° apart, they MUST NOT bridge because zero triangles connect them.
        XCTAssertNotEqual(result.aux[3].ringLeft, 5, "Unstitched front slit must not bridge (chain 1 -> chain 2)")
        XCTAssertNotEqual(result.aux[3].ringRight, 5, "Unstitched front slit must not bridge (chain 1 -> chain 2)")
        XCTAssertNotEqual(result.aux[5].ringLeft, 3, "Unstitched front slit must not bridge (chain 2 -> chain 1)")
        XCTAssertNotEqual(result.aux[5].ringRight, 3, "Unstitched front slit must not bridge (chain 2 -> chain 1)")
        // Stitched edge (chain 0 bone 1 <-> chain 1 bone 3) MUST link.
        XCTAssertTrue(result.aux[3].ringLeft == 1 || result.aux[3].ringRight == 1,
                      "Stitched cape seam (chain 0 <-> chain 1) must be linked")
    }

    func testMeshFitHandlesOver128BustSpringsWithoutOverflow() throws {
        let gltfJson = #"{"asset":{"version":"2.0"}}"#
        let gltf = try JSONDecoder().decode(GLTFDocument.self, from: Data(gltfJson.utf8))
        let humanoid = VRMHumanoid()
        let model = VRMModel(specVersion: .v1_0, meta: VRMMeta(licenseUrl: ""), humanoid: humanoid, gltf: gltf)

        let upperChest = VRMNode(index: 0, gltfNode: GLTFNode(name: "UpperChest"))
        upperChest.translation = SIMD3<Float>(0, 1.3, 0)
        upperChest.updateLocalMatrix()
        humanoid.humanBones[.upperChest] = VRMHumanoid.VRMHumanBone(node: 0)

        var nodes: [VRMNode] = [upperChest]
        var springs: [VRMSpring] = []
        // 135 Bust-named springs exceeds Int8.max (127); must not trap during skin slot mapping.
        for i in 0..<135 {
            let nIdx = nodes.count
            let n = VRMNode(index: nIdx, gltfNode: GLTFNode(name: "Bust_\(i)"))
            n.translation = SIMD3<Float>(0.05, -0.05, 0.08)
            n.parent = upperChest
            n.updateLocalMatrix()
            upperChest.children.append(n)
            nodes.append(n)

            var sp = VRMSpring(name: "Bust_\(i)")
            sp.joints = [VRMSpringJoint(node: nIdx)]
            springs.append(sp)
        }
        let meshNode = VRMNode(index: nodes.count, gltfNode: GLTFNode(name: "Body", mesh: 0, skin: 0))
        meshNode.updateLocalMatrix()
        nodes.append(meshNode)
        model.nodes = nodes
        upperChest.updateWorldTransform()

        let skin = VRMSkin(name: "BustSkin")
        let lastBustNode = nodes[135]
        skin.joints = [lastBustNode]
        skin.inverseBindMatrices = [simd_inverse(lastBustNode.worldMatrix)]
        model.skins = [skin]

        var verts: [VRMVertex] = []
        for k in 0..<12 {
            let ang = Float(k) * (2.0 * .pi / 12.0)
            verts.append(VRMVertex(
                position: SIMD3<Float>(0.05 + cos(ang) * 0.04, 1.25 + sin(ang) * 0.04, 0.08),
                normal: SIMD3<Float>(0, 0, 1),
                texCoord: .zero,
                color: SIMD4<Float>(1, 1, 1, 1),
                joints: SIMD4<UInt32>(0, 0, 0, 0),
                weights: SIMD4<Float>(1, 0, 0, 0)
            ))
        }
        let prim = VRMPrimitive()
        prim.uploadVertices(verts, device: device)
        let mesh = VRMMesh(name: "Body")
        mesh.primitives = [prim]
        model.meshes = [mesh]

        var sb = VRMSpringBone()
        sb.springs = springs
        model.springBone = sb

        let fitted = SpringBoneMeshFit.computeAll(model: model)
        XCTAssertEqual(fitted.breasts.count, 1, "135th bust spring must fit cleanly without Int8 overflow")
    }

    func testColliderGroupLimit32DisablesAllSyntheticAugmentation() throws {
        let gltfJson = #"{"asset":{"version":"2.0"}}"#
        let gltf = try JSONDecoder().decode(GLTFDocument.self, from: Data(gltfJson.utf8))
        let humanoid = VRMHumanoid()
        let model = VRMModel(specVersion: .v1_0, meta: VRMMeta(licenseUrl: ""), humanoid: humanoid, gltf: gltf)

        let hips = VRMNode(index: 0, gltfNode: GLTFNode(name: "Hips"))
        hips.translation = SIMD3<Float>(0, 0.9, 0); hips.updateLocalMatrix()
        let lLower = VRMNode(index: 1, gltfNode: GLTFNode(name: "L_LowerArm"))
        lLower.translation = SIMD3<Float>(0.3, 0.4, 0); lLower.parent = hips; lLower.updateLocalMatrix(); hips.children.append(lLower)
        let lHand = VRMNode(index: 2, gltfNode: GLTFNode(name: "L_Hand"))
        lHand.translation = SIMD3<Float>(0.24, 0, 0); lHand.parent = lLower; lHand.updateLocalMatrix(); lLower.children.append(lHand)
        let sRoot = VRMNode(index: 3, gltfNode: GLTFNode(name: "S_Root"))
        sRoot.translation = SIMD3<Float>(0.1, 0, 0.1); sRoot.parent = hips; sRoot.updateLocalMatrix(); hips.children.append(sRoot)
        let sTip = VRMNode(index: 4, gltfNode: GLTFNode(name: "S_Tip"))
        sTip.translation = SIMD3<Float>(0, -0.15, 0); sTip.parent = sRoot; sTip.updateLocalMatrix(); sRoot.children.append(sTip)

        model.nodes = [hips, lLower, lHand, sRoot, sTip]
        model.device = device
        hips.updateWorldTransform()
        humanoid.humanBones[.hips] = VRMHumanoid.VRMHumanBone(node: 0)
        humanoid.humanBones[.leftLowerArm] = VRMHumanoid.VRMHumanBone(node: 1)
        humanoid.humanBones[.leftHand] = VRMHumanoid.VRMHumanBone(node: 2)

        var sb = VRMSpringBone()
        sb.colliders = [VRMCollider(node: 0, shape: .sphere(offset: .zero, radius: 0.08))]
        // 32 authored collider groups claim all 32 mask bits -> no free bit for synthetic group!
        sb.colliderGroups = (0..<32).map { VRMColliderGroup(name: "Grp_\($0)", colliders: [0]) }
        var sp = VRMSpring(name: "Cloth")
        sp.joints = [VRMSpringJoint(node: 3), VRMSpringJoint(node: 4)]
        sp.colliderGroups = [31]
        sb.springs = [sp]
        model.springBone = sb

        try model.initializeSpringBoneGPUSystem(device: device, augmentColliders: true)
        let loadedSB = try XCTUnwrap(model.springBone)
        XCTAssertTrue(loadedSB.syntheticColliders.isEmpty,
                      "With 32 authored collider groups, all synthetic augmentation (including bone-fallback hand paddles) must be disabled so bit 31 never aliases authored group 31 (CLAUDE.md §4)")
    }

    func testUnequalLengthChainsNeverLinkToKinematicRoot() throws {
        let gltfJson = #"{"asset":{"version":"2.0"}}"#
        let gltf = try JSONDecoder().decode(GLTFDocument.self, from: Data(gltfJson.utf8))
        let humanoid = VRMHumanoid()
        let model = VRMModel(specVersion: .v1_0, meta: VRMMeta(licenseUrl: ""), humanoid: humanoid, gltf: gltf)

        let hips = VRMNode(index: 0, gltfNode: GLTFNode(name: "Hips"))
        hips.translation = SIMD3<Float>(0, 0.90, 0)
        hips.updateLocalMatrix()
        humanoid.humanBones[.hips] = VRMHumanoid.VRMHumanBone(node: 0)

        var nodes: [VRMNode] = [hips]
        var springs: [VRMSpring] = []
        // 4 chains around hips: alternating 4-joint chains (root y=0.90, j1 y=0.75, j2 y=0.60, j3 y=0.45)
        // and 3-joint chains (root y=0.75 — exact same Y as j1 of the 4-joint chain! — j1 y=0.60, j2 y=0.45).
        let specs: [(deg: Float, rootY: Float, count: Int)] = [
            (0, 0.75, 3),
            (90, 0.90, 4),
            (180, 0.75, 3),
            (-90, 0.90, 4),
        ]
        var rootBoneIndices: Set<Int> = []
        var runningBone = 0
        for (k, spec) in specs.enumerated() {
            let rad = spec.deg * .pi / 180.0
            rootBoneIndices.insert(runningBone)
            var joints: [VRMSpringJoint] = []
            var parentNode: VRMNode = hips
            for j in 0..<spec.count {
                let idx = nodes.count
                let n = VRMNode(index: idx, gltfNode: GLTFNode(name: "Chain_\(k)_\(j)"))
                if j == 0 {
                    n.translation = SIMD3<Float>(sin(rad) * 0.16, spec.rootY - 0.90, cos(rad) * 0.16)
                } else {
                    n.translation = SIMD3<Float>(0, -0.15, 0)
                }
                n.parent = parentNode
                n.updateLocalMatrix()
                parentNode.children.append(n)
                nodes.append(n)
                parentNode = n

                var sj = VRMSpringJoint(node: idx)
                sj.hitRadius = (j == spec.count - 1) ? 0.0 : 0.015
                joints.append(sj)
                runningBone += 1
            }
            var sp = VRMSpring(name: "Panel_\(k)")
            sp.joints = joints
            springs.append(sp)
        }
        model.nodes = nodes
        hips.updateWorldTransform()
        var sb = VRMSpringBone()
        sb.springs = springs
        model.springBone = sb

        let result = SpringBoneSkirtRingDetector.buildCollisionAux(model: model, hasSyntheticColliders: true)
        XCTAssertEqual(result.ringCount, 1)
        for (boneIdx, aux) in result.aux.enumerated() {
            if rootBoneIndices.contains(boneIdx) {
                XCTAssertEqual(aux.ringLeft, SpringBoneSkirtRingDetector.noNeighbor, "Root bone \(boneIdx) must not have ringLeft")
                XCTAssertEqual(aux.ringRight, SpringBoneSkirtRingDetector.noNeighbor, "Root bone \(boneIdx) must not have ringRight")
            }
            if aux.ringLeft != SpringBoneSkirtRingDetector.noNeighbor {
                XCTAssertFalse(rootBoneIndices.contains(Int(aux.ringLeft)),
                               "Bone \(boneIdx) ringLeft must never reference kinematic root \(aux.ringLeft)")
            }
            if aux.ringRight != SpringBoneSkirtRingDetector.noNeighbor {
                XCTAssertFalse(rootBoneIndices.contains(Int(aux.ringRight)),
                               "Bone \(boneIdx) ringRight must never reference kinematic root \(aux.ringRight)")
            }
        }
    }

    func testOpenFrontCoatSkirtDoesNotBridgeAcrossWideFrontGap() throws {
        let gltfJson = #"{"asset":{"version":"2.0"}}"#
        let gltf = try JSONDecoder().decode(GLTFDocument.self, from: Data(gltfJson.utf8))
        let humanoid = VRMHumanoid()
        let model = VRMModel(specVersion: .v1_0, meta: VRMMeta(licenseUrl: ""), humanoid: humanoid, gltf: gltf)

        let hips = VRMNode(index: 0, gltfNode: GLTFNode(name: "Hips"))
        hips.translation = SIMD3<Float>(0, 0.9, 0)
        hips.updateLocalMatrix()
        hips.updateWorldTransform()
        humanoid.humanBones[.hips] = VRMHumanoid.VRMHumanBone(node: 0)

        var nodes: [VRMNode] = [hips]
        var springs: [VRMSpring] = []
        // 4 chains at -90°, -150°, +150°, +90° (leaving a 180° open front around 0°).
        let anglesDeg: [(String, Float)] = [
            ("R_CoatSide", -90),
            ("R_CoatBack", -150),
            ("L_CoatBack", 150),
            ("L_CoatSide", 90),
        ]
        for (name, deg) in anglesDeg {
            let rad = deg * .pi / 180.0
            let r: Float = 0.16
            let rootIdx = nodes.count
            let rootNode = VRMNode(index: rootIdx, gltfNode: GLTFNode(name: "J_Sec_\(name)_01"))
            rootNode.translation = SIMD3<Float>(sin(rad) * r, -0.02, cos(rad) * r)
            rootNode.parent = hips
            hips.children.append(rootNode)
            nodes.append(rootNode)

            let childIdx = nodes.count
            let childNode = VRMNode(index: childIdx, gltfNode: GLTFNode(name: "J_Sec_\(name)_01_end"))
            childNode.translation = SIMD3<Float>(0, -0.15, 0)
            childNode.parent = rootNode
            rootNode.children.append(childNode)
            nodes.append(childNode)

            var j0 = VRMSpringJoint(node: rootIdx); j0.hitRadius = 0.015
            var j1 = VRMSpringJoint(node: childIdx); j1.hitRadius = 0.0
            var sp = VRMSpring(name: "CoatSkirt")
            sp.joints = [j0, j1]
            springs.append(sp)
        }
        model.nodes = nodes
        hips.updateWorldTransform()
        var sb = VRMSpringBone()
        sb.springs = springs
        model.springBone = sb

        let result = SpringBoneSkirtRingDetector.buildCollisionAux(model: model, hasSyntheticColliders: true)
        XCTAssertEqual(result.ringCount, 1)
        // Bones per chain = 2: child bones are indices 1 (R_Side -90°), 3 (R_Back -150°),
        // 5 (L_Back +150°), 7 (L_Side +90°).
        // Ascending azimuth order: R_Back (-150°), R_Side (-90°), L_Side (+90°), L_Back (+150°).
        // Gap R_Side (-90°) -> L_Side (+90°) is 180° >= 110° -> MUST NOT bridge!
        XCTAssertEqual(result.aux[1].ringRight, SpringBoneSkirtRingDetector.noNeighbor,
                       "R_CoatSide must not bridge across 180° open front to L_CoatSide")
        XCTAssertEqual(result.aux[7].ringLeft, SpringBoneSkirtRingDetector.noNeighbor,
                       "L_CoatSide must not bridge across 180° open front to R_CoatSide")
        // Back and side arcs are 60° < 110° -> MUST bridge!
        XCTAssertEqual(result.aux[3].ringRight, 1, "R_CoatBack (-150°) links to R_CoatSide (-90°)")
        XCTAssertEqual(result.aux[1].ringLeft, 3, "R_CoatSide (-90°) links back to R_CoatBack (-150°)")
        XCTAssertEqual(result.aux[7].ringRight, 5, "L_CoatSide (+90°) links to L_CoatBack (+150°)")
        XCTAssertEqual(result.aux[5].ringLeft, 7, "L_CoatBack (+150°) links to L_CoatSide (+90°)")
        XCTAssertEqual(result.aux[5].ringRight, 3, "L_CoatBack (+150°) wraps to R_CoatBack (-150°, 60°)")
        XCTAssertEqual(result.aux[3].ringLeft, 5, "R_CoatBack (-150°) wraps to L_CoatBack (+150°, 60°)")
        // Terminal hem radius inherited from parent (0.015) on all 4 chains.
        for childBone in [1, 3, 5, 7] {
            XCTAssertEqual(result.aux[childBone].syntheticRadius, 0.015, accuracy: 1e-6)
        }
    }

    func testSingleLayerNumberedSkirtFormsOneRing() throws {
        let gltfJson = #"{"asset":{"version":"2.0"}}"#
        let gltf = try JSONDecoder().decode(GLTFDocument.self, from: Data(gltfJson.utf8))
        let humanoid = VRMHumanoid()
        let model = VRMModel(specVersion: .v1_0, meta: VRMMeta(licenseUrl: ""), humanoid: humanoid, gltf: gltf)

        let hips = VRMNode(index: 0, gltfNode: GLTFNode(name: "Hips"))
        hips.translation = SIMD3<Float>(0, 0.9, 0)
        hips.updateLocalMatrix()
        hips.updateWorldTransform()
        humanoid.humanBones[.hips] = VRMHumanoid.VRMHumanBone(node: 0)

        var nodes: [VRMNode] = [hips]
        var springs: [VRMSpring] = []
        // Blender-style single-layer skirt: Skirt_01..Skirt_06 (each suffix appears once).
        for k in 0..<6 {
            let rad = Float(k) * (2.0 * .pi / 6.0)
            let rootIdx = nodes.count
            let rNode = VRMNode(index: rootIdx, gltfNode: GLTFNode(name: String(format: "Skirt_%02d", k + 1)))
            rNode.translation = SIMD3<Float>(sin(rad) * 0.16, -0.02, cos(rad) * 0.16)
            rNode.parent = hips
            hips.children.append(rNode)
            nodes.append(rNode)

            let childIdx = nodes.count
            let cNode = VRMNode(index: childIdx, gltfNode: GLTFNode(name: String(format: "Skirt_%02d_end", k + 1)))
            cNode.translation = SIMD3<Float>(0, -0.15, 0)
            cNode.parent = rNode
            rNode.children.append(cNode)
            nodes.append(cNode)

            // Unique per-chain non-English / tricky names ("CocktailDress_01", "SkirtRear_02", ...)
            // must all unify purely by geometry on bone-only rigs without English string heuristics.
            let trickyNames = [
                "CocktailDress_01", "SkirtRear_02", "HeartSkirt_03",
                "Outerwear_04", "SwingPanel_05", "骨チェーン_06",
            ]
            var sp = VRMSpring(name: trickyNames[k])
            var j0 = VRMSpringJoint(node: rootIdx); j0.hitRadius = 0.014
            var j1 = VRMSpringJoint(node: childIdx); j1.hitRadius = 0.0
            sp.joints = [j0, j1]
            springs.append(sp)
        }
        model.nodes = nodes
        hips.updateWorldTransform()
        var sb = VRMSpringBone()
        sb.springs = springs
        model.springBone = sb

        let result = SpringBoneSkirtRingDetector.buildCollisionAux(model: model, hasSyntheticColliders: true)
        XCTAssertEqual(result.ringCount, 1, "Unique per-chain and non-English spring names must form 1 unified 6-chain ring")
        XCTAssertEqual(result.linkedBoneCount, 6, "All 6 child bones must have ring neighbors")
    }

    func testAsyncSleepGateKeepsRingNeighborsAwakeInLockstep() throws {
        let gltfJson = #"{"asset":{"version":"2.0"}}"#
        let gltf = try JSONDecoder().decode(GLTFDocument.self, from: Data(gltfJson.utf8))
        let humanoid = VRMHumanoid()
        let model = VRMModel(specVersion: .v1_0, meta: VRMMeta(licenseUrl: ""), humanoid: humanoid, gltf: gltf)

        let hips = VRMNode(index: 0, gltfNode: GLTFNode(name: "Hips"))
        hips.translation = SIMD3<Float>(0, 0.9, 0)
        hips.updateLocalMatrix()
        humanoid.humanBones[.hips] = VRMHumanoid.VRMHumanBone(node: 0)

        var nodes: [VRMNode] = [hips]
        var springs: [VRMSpring] = []
        for k in 0..<6 {
            let rad = Float(k) * (2.0 * .pi / 6.0)
            let rIdx = nodes.count
            let rNode = VRMNode(index: rIdx, gltfNode: GLTFNode(name: "Chain_\(k)"))
            rNode.translation = SIMD3<Float>(sin(rad) * 0.16, -0.02, cos(rad) * 0.16)
            rNode.parent = hips
            rNode.updateLocalMatrix()
            hips.children.append(rNode)
            nodes.append(rNode)

            let cIdx = nodes.count
            let cNode = VRMNode(index: cIdx, gltfNode: GLTFNode(name: "Chain_\(k)_end"))
            cNode.translation = SIMD3<Float>(0, -0.15, 0)
            cNode.parent = rNode
            cNode.updateLocalMatrix()
            rNode.children.append(cNode)
            nodes.append(cNode)

            var j0 = VRMSpringJoint(node: rIdx); j0.hitRadius = 0.015; j0.stiffness = 0.5; j0.dragForce = 0.8; j0.gravityPower = 0.0
            var j1 = VRMSpringJoint(node: cIdx); j1.hitRadius = 0.0; j1.stiffness = 0.5; j1.dragForce = 0.8; j1.gravityPower = 0.0
            var sp = VRMSpring(name: "Ring_\(k)")
            sp.joints = [j0, j1]
            springs.append(sp)
        }
        model.nodes = nodes
        model.device = device
        hips.updateWorldTransform()

        var sb = VRMSpringBone()
        sb.springs = springs
        // Distant synthetic capsule so hasSyntheticColliders is true without touching at rest.
        sb.syntheticColliders = [
            VRMCollider(node: 0, shape: .capsule(offset: SIMD3(5, 0, 0), radius: 0.02, tail: SIMD3(5, -0.1, 0)))
        ]
        model.springBone = sb

        let totalBones = 12
        let buffers = SpringBoneBuffers(device: device)
        buffers.allocateBuffers(numBones: totalBones, numSpheres: 0, numCapsules: 1, numPlanes: 0)
        model.springBoneBuffers = buffers
        model.springBoneGlobalParams = SpringBoneTestFixtures.defaultGlobalParams(numBones: totalBones)

        let system = try SpringBoneComputeSystem(device: device)
        try system.populateSpringBoneData(model: model)

        // Run shared-command-buffer (async sleep-gate enabled) frames until the entire ring sleeps.
        for _ in 0..<80 {
            try SpringBoneTestFixtures.runFrame(system: system, model: model, commandQueue: commandQueue)
        }
        XCTAssertEqual(system.testChainAsleep.count, 6)
        XCTAssertTrue(system.testChainAsleep.allSatisfy { $0 },
                      "Settled ring chains must all transition to sleep together (asleep=\(system.testChainAsleep))")

        // Move ONLY chain 0's root (node 1). Ring connected-component synchronization must wake
        // ALL 6 ring chains in lockstep so mid-span chords never run one-sided against a sleeping neighbor.
        model.nodes[1].translation.x += 0.05
        model.nodes[1].updateLocalMatrix()
        hips.updateWorldTransform()
        try SpringBoneTestFixtures.runFrame(system: system, model: model, commandQueue: commandQueue)
        XCTAssertTrue(system.testChainAsleep.allSatisfy { !$0 },
                      "Waking chain 0 must wake every chain in its ring connected component in lockstep (asleep=\(system.testChainAsleep))")

        // After settling again with no motion, all 6 chains must return to sleep together.
        for _ in 0..<80 {
            try SpringBoneTestFixtures.runFrame(system: system, model: model, commandQueue: commandQueue)
        }
        XCTAssertTrue(system.testChainAsleep.allSatisfy { $0 },
                      "Ring component must return to sleep together once settled (asleep=\(system.testChainAsleep))")
    }

    func testLowerBodyHemInheritanceStopsAtChestAndRequiresDownwardHang() throws {
        let gltfJson = #"{"asset":{"version":"2.0"}}"#
        let gltf = try JSONDecoder().decode(GLTFDocument.self, from: Data(gltfJson.utf8))
        let humanoid = VRMHumanoid()
        let model = VRMModel(specVersion: .v1_0, meta: VRMMeta(licenseUrl: ""), humanoid: humanoid, gltf: gltf)

        // Realistic VRM humanoid hierarchy: hips (0) -> spine (1) -> chest (2) -> upperChest (3)
        let hips = VRMNode(index: 0, gltfNode: GLTFNode(name: "Hips"))
        hips.translation = SIMD3<Float>(0, 0.90, 0)
        hips.updateLocalMatrix()

        let spine = VRMNode(index: 1, gltfNode: GLTFNode(name: "Spine"))
        spine.translation = SIMD3<Float>(0, 0.12, 0)
        spine.parent = hips
        spine.updateLocalMatrix()
        hips.children.append(spine)

        let chest = VRMNode(index: 2, gltfNode: GLTFNode(name: "Chest"))
        chest.translation = SIMD3<Float>(0, 0.14, 0)
        chest.parent = spine
        chest.updateLocalMatrix()
        spine.children.append(chest)

        let upperChest = VRMNode(index: 3, gltfNode: GLTFNode(name: "UpperChest"))
        upperChest.translation = SIMD3<Float>(0, 0.14, 0)
        upperChest.parent = chest
        upperChest.updateLocalMatrix()
        chest.children.append(upperChest)

        humanoid.humanBones[.hips] = VRMHumanoid.VRMHumanBone(node: 0)
        humanoid.humanBones[.spine] = VRMHumanoid.VRMHumanBone(node: 1)
        humanoid.humanBones[.chest] = VRMHumanoid.VRMHumanBone(node: 2)
        humanoid.humanBones[.upperChest] = VRMHumanoid.VRMHumanBone(node: 3)

        var nodes: [VRMNode] = [hips, spine, chest, upperChest]
        func addTwoJointChain(parent: VRMNode, name: String, rootOffset: SIMD3<Float>, tipOffset: SIMD3<Float>) -> VRMSpring {
            let rIdx = nodes.count
            let rNode = VRMNode(index: rIdx, gltfNode: GLTFNode(name: "\(name)_0"))
            rNode.translation = rootOffset
            rNode.parent = parent
            rNode.updateLocalMatrix()
            parent.children.append(rNode)
            nodes.append(rNode)

            let tIdx = nodes.count
            let tNode = VRMNode(index: tIdx, gltfNode: GLTFNode(name: "\(name)_1"))
            tNode.translation = tipOffset
            tNode.parent = rNode
            tNode.updateLocalMatrix()
            rNode.children.append(tNode)
            nodes.append(tNode)

            var j0 = VRMSpringJoint(node: rIdx); j0.hitRadius = 0.02
            var j1 = VRMSpringJoint(node: tIdx); j1.hitRadius = 0.0
            var sp = VRMSpring(name: name)
            sp.joints = [j0, j1]
            return sp
        }

        // 1. Standalone necktie under upperChest (hangs down, NOT part of a cloth sheet) -> must NOT inherit.
        let necktie = addTwoJointChain(parent: upperChest, name: "Necktie",
                                       rootOffset: SIMD3(0, 0, 0.08), tipOffset: SIMD3(0, -0.18, 0))
        // 2. Standalone chest ribbon under chest -> must NOT inherit.
        let chestRibbon = addTwoJointChain(parent: chest, name: "ChestRibbon",
                                           rootOffset: SIMD3(0.05, 0, 0.08), tipOffset: SIMD3(0, -0.14, 0))
        // 3. Upward-pointing waist antenna under hips -> must NOT inherit (does not hang downward).
        let waistUp = addTwoJointChain(parent: hips, name: "WaistWing",
                                       rootOffset: SIMD3(0, 0, -0.10), tipOffset: SIMD3(0, 0.16, -0.04))
        // 4. Downward-hanging waist sash under hips -> MUST inherit parent hitRadius.
        let waistSash = addTwoJointChain(parent: hips, name: "WaistSash",
                                         rootOffset: SIMD3(0.12, -0.02, 0.04), tipOffset: SIMD3(0, -0.22, 0))

        model.nodes = nodes
        hips.updateWorldTransform()

        var sb = VRMSpringBone()
        sb.springs = [necktie, chestRibbon, waistUp, waistSash]
        model.springBone = sb

        let result = SpringBoneSkirtRingDetector.buildCollisionAux(model: model, hasSyntheticColliders: true)
        XCTAssertEqual(result.aux.count, 8)
        XCTAssertEqual(result.aux[1].syntheticRadius, 0.0, accuracy: 1e-6,
                       "Unlinked upperChest necktie must not inherit terminal hitRadius via hips ancestry")
        XCTAssertEqual(result.aux[3].syntheticRadius, 0.0, accuracy: 1e-6,
                       "Unlinked chest ribbon must not inherit terminal hitRadius via hips ancestry")
        XCTAssertEqual(result.aux[5].syntheticRadius, 0.0, accuracy: 1e-6,
                       "Upward-pointing hips accessory must not inherit terminal hitRadius")
        XCTAssertEqual(result.aux[7].syntheticRadius, 0.02, accuracy: 1e-6,
                       "Downward-hanging hips sash must inherit parent hitRadius")
        XCTAssertEqual(result.inheritedHemRadiusCount, 1)
    }

    // MARK: - 4. GPU Kernel: Chord Collision, Hem Radius Scoping & Determinism

    func testGPUSkirtChordBlocksCapsuleInOpenAirGapBetweenChains() throws {
        let library = try VRMShaderLibraryLoader.loadBundledLibrary(device: device)
        let capsuleFn = try XCTUnwrap(library.makeFunction(name: "springBoneCollideCapsules"))
        let pipeline = try device.makeComputePipelineState(function: capsuleFn)

        // 4 bones: chain 0 = [0 (root), 1 (skirt A)], chain 1 = [2 (root), 3 (skirt B)].
        // Skirt A is at (-0.10, 0, 0), Skirt B is at (+0.10, 0, 0) — 20 cm circumferential gap.
        // A hand capsule of radius 0.02 sits at z = -0.015 right in the middle of the gap
        // (10 cm from both A and B, so point-vs-capsule misses completely!).
        let prev: [SIMD3<Float>] = [
            SIMD3(-0.10, 0.2, 0), SIMD3(-0.10, 0.0, 0.005),
            SIMD3( 0.10, 0.2, 0), SIMD3( 0.10, 0.0, 0.005),
        ]
        let curr: [SIMD3<Float>] = [
            SIMD3(-0.10, 0.2, 0), SIMD3(-0.10, 0.0, 0.0),
            SIMD3( 0.10, 0.2, 0), SIMD3( 0.10, 0.0, 0.0),
        ]
        let boneParams: [BoneParams] = [
            BoneParams(stiffness: 0.5, drag: 0.4, radius: 0.0, parentIndex: UInt32.max, gravityPower: 0, colliderGroupMask: 0xFFFFFFFF),
            BoneParams(stiffness: 0.5, drag: 0.4, radius: 0.0, parentIndex: 0, gravityPower: 0, colliderGroupMask: 0xFFFFFFFF),
            BoneParams(stiffness: 0.5, drag: 0.4, radius: 0.0, parentIndex: UInt32.max, gravityPower: 0, colliderGroupMask: 0xFFFFFFFF),
            BoneParams(stiffness: 0.5, drag: 0.4, radius: 0.0, parentIndex: 2, gravityPower: 0, colliderGroupMask: 0xFFFFFFFF),
        ]
        // Capsule runs vertically through the mid-gap at (0, y, -0.015), radius 0.02.
        let capsule = CapsuleCollider(
            p0: SIMD3(0, -0.05, -0.015),
            p1: SIMD3(0,  0.05, -0.015),
            radius: 0.02,
            groupMask: 1 << 4
        )

        func run(aux: [SpringBoneCollisionAux], sweptMask: UInt32) throws -> (curr: [SIMD3<Float>], prev: [SIMD3<Float>]) {
            let n = prev.count
            let prevBuf = device.makeBuffer(bytes: prev, length: MemoryLayout<SIMD3<Float>>.stride * n, options: .storageModeShared)!
            let currBuf = device.makeBuffer(bytes: curr, length: MemoryLayout<SIMD3<Float>>.stride * n, options: .storageModeShared)!
            let snapBuf = device.makeBuffer(bytes: curr, length: MemoryLayout<SIMD3<Float>>.stride * n, options: .storageModeShared)!
            let bpBuf = device.makeBuffer(bytes: boneParams, length: MemoryLayout<BoneParams>.stride * n, options: .storageModeShared)!
            var gp = SpringBoneGlobalParams(
                gravity: .zero, dtSub: 1.0 / 120.0,
                windAmplitude: 0, windFrequency: 0, windPhase: 0,
                windDirection: SIMD3(1, 0, 0), substeps: 1,
                numBones: UInt32(n), numSpheres: 0, numCapsules: 1, numPlanes: 0
            )
            let gpBuf = device.makeBuffer(bytes: &gp, length: MemoryLayout<SpringBoneGlobalParams>.stride, options: .storageModeShared)!
            var caps = [capsule]
            let capBuf = device.makeBuffer(bytes: &caps, length: MemoryLayout<CapsuleCollider>.stride, options: .storageModeShared)!
            var chainIdx: [UInt32] = [0, 0, 1, 1]
            var chainSleep: [UInt32] = [0, 0]
            let ciBuf = device.makeBuffer(bytes: &chainIdx, length: MemoryLayout<UInt32>.stride * n, options: .storageModeShared)!
            let csBuf = device.makeBuffer(bytes: &chainSleep, length: MemoryLayout<UInt32>.stride * 2, options: .storageModeShared)!
            var auxCopy = aux
            let auxBuf = device.makeBuffer(bytes: &auxCopy, length: MemoryLayout<SpringBoneCollisionAux>.stride * n, options: .storageModeShared)!
            var swept = sweptMask

            let cb = commandQueue.makeCommandBuffer()!
            let enc = cb.makeComputeCommandEncoder()!
            enc.setComputePipelineState(pipeline)
            enc.setBuffer(prevBuf, offset: 0, index: 0)
            enc.setBuffer(currBuf, offset: 0, index: 1)
            enc.setBuffer(bpBuf, offset: 0, index: 2)
            enc.setBuffer(gpBuf, offset: 0, index: 3)
            enc.setBuffer(capBuf, offset: 0, index: 6)
            enc.setBytes(&swept, length: MemoryLayout<UInt32>.size, index: 15)
            enc.setBuffer(ciBuf, offset: 0, index: 16)
            enc.setBuffer(csBuf, offset: 0, index: 17)
            enc.setBuffer(snapBuf, offset: 0, index: 19)
            enc.setBuffer(auxBuf, offset: 0, index: 20)
            SpringBoneComputeSystem.dispatchCompute(
                enc,
                threadsPerGrid: MTLSize(width: n, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1),
                supportsNonUniformThreadgroups: device.supportsFamily(.apple4) || device.supportsFamily(.mac2)
            )
            enc.endEncoding()
            cb.commit()
            cb.waitUntilCompleted()

            let cPtr = currBuf.contents().bindMemory(to: SIMD3<Float>.self, capacity: n)
            let pPtr = prevBuf.contents().bindMemory(to: SIMD3<Float>.self, capacity: n)
            return (Array(UnsafeBufferPointer(start: cPtr, count: n)),
                    Array(UnsafeBufferPointer(start: pPtr, count: n)))
        }

        // Control: no ring neighbors -> capsule slips straight through the 20 cm gap.
        let noRingAux = [SpringBoneCollisionAux](repeating: SpringBoneCollisionAux(), count: 4)
        let control = try run(aux: noRingAux, sweptMask: 1 << 4)
        XCTAssertEqual(control.curr[1].z, 0.0, accuracy: 1e-5, "Without ring chord, gap is missed")
        XCTAssertEqual(control.curr[3].z, 0.0, accuracy: 1e-5, "Without ring chord, gap is missed")

        // Ring chord + inherited 15mm synthetic hem radius: R = 0.02 + 0.015 = 0.035;
        // chord sits at z = 0 (dist = 0.015 from capsule axis at z = -0.015 -> penetration = 0.02).
        let ringAux: [SpringBoneCollisionAux] = [
            SpringBoneCollisionAux(),
            SpringBoneCollisionAux(ringLeft: 0xFFFFFFFF, ringRight: 3, syntheticRadius: 0.015, flags: 1),
            SpringBoneCollisionAux(),
            SpringBoneCollisionAux(ringLeft: 1, ringRight: 0xFFFFFFFF, syntheticRadius: 0.015, flags: 1),
        ]
        let fixed = try run(aux: ringAux, sweptMask: 1 << 4)
        // Both skirt joints are pushed outward to z = +0.020 so chord clears R = 0.035!
        XCTAssertEqual(fixed.curr[1].z, 0.020, accuracy: 1e-3,
                       "Skirt A must be pushed out so mid-span chord clears capsule + inherited hem radius")
        XCTAssertEqual(fixed.curr[3].z, 0.020, accuracy: 1e-3,
                       "Skirt B must be pushed symmetrically")
        // Velocity correction (#382/#444): pre-push motion was inward (-0.005); post-push
        // normal velocity must be cancelled (0), not reversed into outward coast-off.
        XCTAssertEqual(fixed.curr[1].z - fixed.prev[1].z, 0.0, accuracy: 1e-4,
                       "Chord push must not manufacture outward velocity")

        // Authored-group scoping: when sweptMask does NOT match capsule group, neither
        // ring-chord collision nor syntheticRadius may fire (authored VRM spec untouched).
        let authoredOnly = try run(aux: ringAux, sweptMask: 1 << 7)
        XCTAssertEqual(authoredOnly.curr[1].z, 0.0, accuracy: 1e-5,
                       "Authored (non-synthetic) capsules must not trigger ring-chord push")
    }

    func testSkirtRingCollisionIsDeterministicUnderSerializedBoneDispatches() throws {
        func simulate(serialized: Bool) throws -> (curr: [SIMD3<Float>], prev: [SIMD3<Float>]) {
            let gltfJson = #"{"asset":{"version":"2.0"}}"#
            let gltf = try JSONDecoder().decode(GLTFDocument.self, from: Data(gltfJson.utf8))
            let humanoid = VRMHumanoid()
            let model = VRMModel(specVersion: .v1_0, meta: VRMMeta(licenseUrl: ""), humanoid: humanoid, gltf: gltf)

            let hips = VRMNode(index: 0, gltfNode: GLTFNode(name: "Hips"))
            hips.translation = SIMD3<Float>(0, 0.9, 0)
            hips.updateLocalMatrix()
            hips.updateWorldTransform()
            humanoid.humanBones[.hips] = VRMHumanoid.VRMHumanBone(node: 0)

            var nodes: [VRMNode] = [hips]
            var springs: [VRMSpring] = []
            for k in 0..<6 {
                let rad = Float(k) * (2.0 * .pi / 6.0)
                let rIdx = nodes.count
                let rNode = VRMNode(index: rIdx, gltfNode: GLTFNode(name: "Skirt_\(k)"))
                rNode.translation = SIMD3<Float>(sin(rad) * 0.16, -0.02, cos(rad) * 0.16)
                rNode.parent = hips
                rNode.updateLocalMatrix()
                hips.children.append(rNode)
                nodes.append(rNode)

                let cIdx = nodes.count
                let cNode = VRMNode(index: cIdx, gltfNode: GLTFNode(name: "Skirt_\(k)_end"))
                cNode.translation = SIMD3<Float>(0, -0.15, 0)
                cNode.parent = rNode
                cNode.updateLocalMatrix()
                rNode.children.append(cNode)
                nodes.append(cNode)

                var j0 = VRMSpringJoint(node: rIdx); j0.hitRadius = 0.015; j0.stiffness = 0.3
                var j1 = VRMSpringJoint(node: cIdx); j1.hitRadius = 0.0; j1.stiffness = 0.3
                var sp = VRMSpring(name: "Skirt")
                sp.joints = [j0, j1]
                springs.append(sp)
            }
            model.nodes = nodes
            model.device = device
            hips.updateWorldTransform()

            var sb = VRMSpringBone()
            sb.springs = springs
            // Synthetic capsule placed squarely inside the chord between Skirt_0 (0°) and Skirt_1 (60°).
            sb.syntheticColliders = [
                VRMCollider(
                    node: 0,
                    shape: .capsule(
                        offset: SIMD3<Float>(0.06, -0.10, 0.11),
                        radius: 0.04,
                        tail: SIMD3<Float>(0.08, -0.22, 0.13)
                    )
                )
            ]
            model.springBone = sb

            let totalBones = 12
            let buffers = SpringBoneBuffers(device: device)
            buffers.allocateBuffers(numBones: totalBones, numSpheres: 0, numCapsules: 1, numPlanes: 0)
            model.springBoneBuffers = buffers
            model.springBoneGlobalParams = SpringBoneTestFixtures.defaultGlobalParams(numBones: totalBones)

            let system = try SpringBoneComputeSystem(device: device)
            try system.populateSpringBoneData(model: model)
            system.testSerializeBoneDispatches = serialized

            for _ in 0..<3 {
                system.update(model: model, deltaTime: 1.0 / 60.0, commandBuffer: nil)
                system.waitForPendingFrame()
            }

            let prevBuf = try XCTUnwrap(buffers.bonePosPrev)
            let prevPtr = prevBuf.contents().bindMemory(to: SIMD3<Float>.self, capacity: totalBones)
            return (SpringBoneTestFixtures.readBonePositions(model: model),
                    Array(UnsafeBufferPointer(start: prevPtr, count: totalBones)))
        }

        let parallel = try simulate(serialized: false)
        let serialized = try simulate(serialized: true)
        XCTAssertEqual(parallel.curr.count, serialized.curr.count)
        // Non-vacuity: verify the synthetic capsule actually deflected the ring chord joints
        // away from their rest radius (0.16m) rather than silently remaining at rest or zero.
        let radial0 = hypot(parallel.curr[1].x, parallel.curr[1].z)
        XCTAssertGreaterThan(abs(radial0 - 0.16), 0.02,
                             "Skirt_0_end must be deflected by the mid-chord synthetic capsule (got r=\(radial0))")
        for i in parallel.curr.indices {
            XCTAssertEqual(parallel.curr[i], serialized.curr[i],
                           "Skirt ring bonePosCurr[\(i)] must be bit-identical regardless of GPU SIMD dispatch order (#452)")
            XCTAssertEqual(parallel.prev[i], serialized.prev[i],
                           "Skirt ring bonePosPrev[\(i)] must be bit-identical regardless of GPU SIMD dispatch order (#452)")
        }
    }

    // MARK: - 5. End-to-End AvatarSample_U Rest-Pose & Hand-Into-Skirt Gates (#478)

    @MainActor
    func testAvatarSampleU_restPoseSkirtDoesNotPuffWithRingChords() async throws {
        let path = getTestModelPath("AvatarSample_U_1.0.vrm.glb")
        try requireFixture(path, hint: "AvatarSample_U_1.0.vrm.glb")

        func settledSkirtPositions(enableChords: Bool) async throws -> [Int: SIMD3<Float>] {
            let model = try await VRMModel.load(
                from: URL(fileURLWithPath: path),
                device: device,
                options: VRMLoadingOptions(augmentSpringBoneColliders: true)
            )
            let sb = try XCTUnwrap(model.springBone)
            let ringInfo = SpringBoneSkirtRingDetector.buildCollisionAux(model: model, hasSyntheticColliders: true)

            var config = RendererConfig()
            config.sampleCount = 1
            config.strict = .off
            config.synchronousSpringBone = true
            let renderer = VRMRenderer(device: device, config: config)
            renderer.loadModel(model)
            renderer.enableSpringBone = true
            renderer.simulationDeltaTime = 1.0 / 60.0
            renderer.viewMatrix = matrix_identity_float4x4
            renderer.projectionMatrix = matrix_identity_float4x4

            if !enableChords, let buffers = model.springBoneBuffers {
                // Clear ring chord links while keeping hand paddles and inherited hem radius active.
                let stripped = ringInfo.aux.map {
                    SpringBoneCollisionAux(
                        ringLeft: SpringBoneSkirtRingDetector.noNeighbor,
                        ringRight: SpringBoneSkirtRingDetector.noNeighbor,
                        syntheticRadius: $0.syntheticRadius,
                        flags: 0
                    )
                }
                buffers.updateCollisionAux(stripped)
            }

            let colorDesc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: 64, height: 64, mipmapped: false)
            colorDesc.usage = [.renderTarget, .shaderRead]; colorDesc.storageMode = .private
            let depthDesc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .depth32Float, width: 64, height: 64, mipmapped: false)
            depthDesc.usage = .renderTarget; depthDesc.storageMode = .private
            let colorTex = try XCTUnwrap(device.makeTexture(descriptor: colorDesc))
            let depthTex = try XCTUnwrap(device.makeTexture(descriptor: depthDesc))

            for _ in 0..<60 {
                let cb = try XCTUnwrap(commandQueue.makeCommandBuffer())
                let rpd = MTLRenderPassDescriptor()
                rpd.colorAttachments[0].texture = colorTex
                rpd.colorAttachments[0].loadAction = .clear
                rpd.colorAttachments[0].storeAction = .store
                rpd.depthAttachment.texture = depthTex
                rpd.depthAttachment.loadAction = .clear
                rpd.depthAttachment.clearDepth = 1.0
                rpd.depthAttachment.storeAction = .dontCare
                renderer.drawOffscreenHeadless(to: colorTex, depth: depthTex, commandBuffer: cb, renderPassDescriptor: rpd)
                cb.commit()
                while cb.status != .completed && cb.status != .error { await Task.yield() }
            }

            var out: [Int: SIMD3<Float>] = [:]
            var bIdx = 0
            for sp in sb.springs where !sp.joints.isEmpty {
                for j in sp.joints {
                    if ringInfo.aux[bIdx].ringLeft != SpringBoneSkirtRingDetector.noNeighbor ||
                       ringInfo.aux[bIdx].ringRight != SpringBoneSkirtRingDetector.noNeighbor {
                        out[j.node] = model.nodes[j.node].worldPosition
                    }
                    bIdx += 1
                }
            }
            return out
        }

        let withoutChords = try await settledSkirtPositions(enableChords: false)
        let withChords = try await settledSkirtPositions(enableChords: true)
        XCTAssertFalse(withChords.isEmpty, "AvatarSample_U must have linked cloth-sheet joints")

        var maxDisp: Float = 0
        for (nodeIdx, pOn) in withChords {
            if let pOff = withoutChords[nodeIdx] {
                let d = simd_distance(pOn, pOff)
                if d > maxDisp { maxDisp = d }
            }
        }
        print(String(format: "[#478 rest-pose U] max skirt displacement (chords ON vs OFF)=%.3fmm over %d joints",
                     maxDisp * 1000, withChords.count))
        XCTAssertLessThan(maxDisp, 0.003,
                          "Skirt ring chords must not puff AvatarSample_U's dress at rest against leg capsules (maxDisp=\(maxDisp)m)")
    }

    @MainActor
    func testAvatarSampleU_handIntoFlaredSkirt_augmentedDeflectsSkirtChords() async throws {
        let path = getTestModelPath("AvatarSample_U_1.0.vrm.glb")
        try requireFixture(path, hint: "AvatarSample_U_1.0.vrm.glb")

        func measureHandSkirtPenetration(augment: Bool, enableChords: Bool) async throws -> (penSamples: Int, totalSamples: Int, worstDepth: Float) {
            let model = try await VRMModel.load(
                from: URL(fileURLWithPath: path),
                device: device,
                options: VRMLoadingOptions(augmentSpringBoneColliders: augment)
            )
            let humanoid = try XCTUnwrap(model.humanoid)
            let sb = try XCTUnwrap(model.springBone)

            // Independent hand-paddle oracle measured from the mesh (same on all runs).
            let handOracle = SpringBoneMeshFit.computeHandColliders(model: model)
            XCTAssertFalse(handOracle.isEmpty, "AvatarSample_U must fit hand paddle capsules")

            // Visible skinned skirt ring chords detected from mesh topology.
            let ringInfo = SpringBoneSkirtRingDetector.buildCollisionAux(model: model, hasSyntheticColliders: true)
            var boneToNode: [Int] = []
            for sp in sb.springs where !sp.joints.isEmpty {
                for j in sp.joints { boneToNode.append(j.node) }
            }
            var chords: [(a: Int, b: Int)] = []
            for bIdx in 0..<ringInfo.aux.count {
                let right = ringInfo.aux[bIdx].ringRight
                if right != SpringBoneSkirtRingDetector.noNeighbor,
                   Int(right) < boneToNode.count {
                    chords.append((boneToNode[bIdx], boneToNode[Int(right)]))
                }
            }
            XCTAssertFalse(chords.isEmpty, "AvatarSample_U must expose skinned skirt ring chords")

            // Pose: lower both arms naturally alongside the hips (~76°) and angle forward slightly
            // so the hands descend from outside the dress into the flared skirt's Front↔Side
            // circumferential gap around (x = ±0.16m, y = 0.78m, z = +0.08m).
            var clip = AnimationClip(duration: 2.0)
            let leftArmRot = simd_quatf(angle: -0.14, axis: SIMD3<Float>(1, 0, 0))
                * simd_quatf(angle: -1.32, axis: SIMD3<Float>(0, 0, 1))
            let rightArmRot = simd_quatf(angle: -0.14, axis: SIMD3<Float>(1, 0, 0))
                * simd_quatf(angle: 1.32, axis: SIMD3<Float>(0, 0, 1))
            let leftForearmRot = simd_quatf(angle: -0.05, axis: SIMD3<Float>(0, 1, 0))
            let rightForearmRot = simd_quatf(angle: 0.05, axis: SIMD3<Float>(0, 1, 0))

            clip.addJointTrack(JointTrack(bone: .leftUpperArm) { t in
                let alpha = min(max(t / 0.6, 0), 1)
                return simd_slerp(simd_quatf(ix: 0, iy: 0, iz: 0, r: 1), leftArmRot, alpha)
            })
            clip.addJointTrack(JointTrack(bone: .rightUpperArm) { t in
                let alpha = min(max(t / 0.6, 0), 1)
                return simd_slerp(simd_quatf(ix: 0, iy: 0, iz: 0, r: 1), rightArmRot, alpha)
            })
            clip.addJointTrack(JointTrack(bone: .leftLowerArm) { t in
                let alpha = min(max(t / 0.6, 0), 1)
                return simd_slerp(simd_quatf(ix: 0, iy: 0, iz: 0, r: 1), leftForearmRot, alpha)
            })
            clip.addJointTrack(JointTrack(bone: .rightLowerArm) { t in
                let alpha = min(max(t / 0.6, 0), 1)
                return simd_slerp(simd_quatf(ix: 0, iy: 0, iz: 0, r: 1), rightForearmRot, alpha)
            })

            let player = AnimationPlayer()
            player.isLooping = false
            player.load(clip)
            player.play()

            var config = RendererConfig()
            config.sampleCount = 1
            config.strict = .off
            config.synchronousSpringBone = true
            let renderer = VRMRenderer(device: device, config: config)
            renderer.loadModel(model)
            renderer.enableSpringBone = true
            renderer.simulationDeltaTime = 1.0 / 60.0
            renderer.viewMatrix = matrix_identity_float4x4
            renderer.projectionMatrix = matrix_identity_float4x4

            if augment && !enableChords, let buffers = model.springBoneBuffers {
                // Ablation: keep hand paddles & inherited hem radius ON, disable ring chords only.
                let stripped = ringInfo.aux.map {
                    SpringBoneCollisionAux(
                        ringLeft: SpringBoneSkirtRingDetector.noNeighbor,
                        ringRight: SpringBoneSkirtRingDetector.noNeighbor,
                        syntheticRadius: $0.syntheticRadius,
                        flags: 0
                    )
                }
                buffers.updateCollisionAux(stripped)
            }

            let colorDesc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: 64, height: 64, mipmapped: false)
            colorDesc.usage = [.renderTarget, .shaderRead]; colorDesc.storageMode = .private
            let depthDesc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .depth32Float, width: 64, height: 64, mipmapped: false)
            depthDesc.usage = .renderTarget; depthDesc.storageMode = .private
            let colorTex = try XCTUnwrap(device.makeTexture(descriptor: colorDesc))
            let depthTex = try XCTUnwrap(device.makeTexture(descriptor: depthDesc))

            var penSamples = 0
            var totalSamples = 0
            var worstDepth: Float = 0
            let margin: Float = 0.005

            for frame in 0..<90 {
                player.update(deltaTime: 1.0 / 60.0, model: model)
                let cb = try XCTUnwrap(commandQueue.makeCommandBuffer())
                let rpd = MTLRenderPassDescriptor()
                rpd.colorAttachments[0].texture = colorTex
                rpd.colorAttachments[0].loadAction = .clear
                rpd.colorAttachments[0].storeAction = .store
                rpd.depthAttachment.texture = depthTex
                rpd.depthAttachment.loadAction = .clear
                rpd.depthAttachment.clearDepth = 1.0
                rpd.depthAttachment.storeAction = .dontCare
                renderer.drawOffscreenHeadless(to: colorTex, depth: depthTex, commandBuffer: cb, renderPassDescriptor: rpd)
                cb.commit()
                while cb.status != .completed && cb.status != .error { await Task.yield() }

                guard frame >= 40 else { continue }
                let worldCaps = handOracle.compactMap { SpringBoneContactColliderSet.worldCapsule($0, model: model) }
                for chord in chords {
                    let pA = model.nodes[chord.a].worldPosition
                    let pB = model.nodes[chord.b].worldPosition
                    totalSamples += 1
                    var maxDepth: Float = 0
                    for cap in worldCaps {
                        let d = Self.segmentSegmentDist(pA, pB, cap.p0, cap.p1)
                        let depth = cap.radius - d
                        if depth > maxDepth { maxDepth = depth }
                    }
                    if maxDepth > margin {
                        penSamples += 1
                        if maxDepth > worstDepth { worstDepth = maxDepth }
                    }
                }
            }
            _ = humanoid
            return (penSamples, totalSamples, worstDepth)
        }

        let off = try await measureHandSkirtPenetration(augment: false, enableChords: false)
        let paddlesOnly = try await measureHandSkirtPenetration(augment: true, enableChords: false)
        let full = try await measureHandSkirtPenetration(augment: true, enableChords: true)
        print(String(
            format: "[#478 hand->skirt U] OFF=%d/%d (%.1fmm)  PADDLES_ONLY=%d/%d (%.1fmm)  FULL=%d/%d (%.1fmm)",
            off.penSamples, off.totalSamples, off.worstDepth * 1000,
            paddlesOnly.penSamples, paddlesOnly.totalSamples, paddlesOnly.worstDepth * 1000,
            full.penSamples, full.totalSamples, full.worstDepth * 1000
        ))

        XCTAssertGreaterThan(off.penSamples, 0,
                             "Non-vacuity: pose must drive AvatarSample_U hands into skirt chords when augment is off")
        XCTAssertGreaterThan(paddlesOnly.penSamples, 0,
                             "Ablation non-vacuity: hand paddles alone without ring chords still allow hands to slip between sparse radial chains")
        XCTAssertEqual(full.penSamples, 0,
                       "Hand paddles + cloth-sheet chord collision must eliminate hand-through-skirt clipping (full=\(full.penSamples) vs paddlesOnly=\(paddlesOnly.penSamples) vs off=\(off.penSamples))")
        XCTAssertLessThan(full.worstDepth, 0.005,
                          "Worst hand-to-skirt chord penetration must stay under 5mm (got \(full.worstDepth)m)")
    }

    private static func segmentSegmentDist(
        _ p1: SIMD3<Float>, _ q1: SIMD3<Float>,
        _ p2: SIMD3<Float>, _ q2: SIMD3<Float>
    ) -> Float {
        let eps: Float = 1e-9
        let d1 = q1 - p1
        let d2 = q2 - p2
        let r = p1 - p2
        let a = simd_dot(d1, d1)
        let e = simd_dot(d2, d2)
        let f = simd_dot(d2, r)
        var s: Float = 0
        var t: Float = 0
        if a <= eps && e <= eps {
            return simd_length(p1 - p2)
        } else if a <= eps {
            t = min(max(f / e, 0), 1)
        } else {
            let c = simd_dot(d1, r)
            if e <= eps {
                s = min(max(-c / a, 0), 1)
            } else {
                let b = simd_dot(d1, d2)
                let denom = a * e - b * b
                s = denom > eps ? min(max((b * f - c * e) / denom, 0), 1) : 0
                t = (b * s + f) / e
                if t < 0 {
                    t = 0
                    s = min(max(-c / a, 0), 1)
                } else if t > 1 {
                    t = 1
                    s = min(max((b - c) / a, 0), 1)
                }
            }
        }
        return simd_length((p1 + d1 * s) - (p2 + d2 * t))
    }
}
