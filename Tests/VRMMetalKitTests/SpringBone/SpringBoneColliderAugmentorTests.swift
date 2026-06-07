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

import XCTest
import Metal
import simd
@testable import VRMMetalKit

final class SpringBoneColliderAugmentorTests: XCTestCase {
    private func makeModelWithoutHumanoid() -> VRMModel {
        let json = #"{"asset":{"version":"2.0"}}"#
        let gltf = try! JSONDecoder().decode(GLTFDocument.self, from: Data(json.utf8))
        return VRMModel(specVersion: .v1_0, meta: VRMMeta(licenseUrl: ""), humanoid: nil, gltf: gltf)
    }

    @MainActor func testAugmentorEmptyWithoutHumanoid() {
        let model = makeModelWithoutHumanoid()
        XCTAssertTrue(SpringBoneColliderAugmentor.synthesize(model: model).isEmpty)
    }

    @MainActor func testAugmentOffAddsNoSyntheticColliders() async throws {
        let path = getTestVRM10ModelPath(); try requireFixture(path, hint: testVRM10Filename)
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device,
                                            options: VRMLoadingOptions(augmentSpringBoneColliders: false))
        XCTAssertEqual(model.springBone?.syntheticColliders.count, 0)
    }

    @MainActor func testAugmentOnAddsFourLegCapsules() async throws {
        let path = getTestVRM10ModelPath(); try requireFixture(path, hint: testVRM10Filename)
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device,
                                            options: VRMLoadingOptions(augmentSpringBoneColliders: true))
        // Four end-to-end leg capsules + one forward head/brow capsule + one
        // lateral skull SPHERE, PLUS (since #321, per the ADR-007 amendment) two
        // lower-arm→hand capsules and two palm spheres for the hand-poke-through.
        let synthetic = model.springBone?.syntheticColliders ?? []
        XCTAssertEqual(synthetic.count, 10)
        var capsuleCount = 0
        var sphereCount = 0
        for collider in synthetic {
            switch collider.shape {
            case let .capsule(_, radius, _):
                capsuleCount += 1
                XCTAssertTrue(radius.isFinite && radius > 0, "Capsule radius must be finite and positive")
            case let .sphere(_, radius):
                sphereCount += 1
                XCTAssertTrue(radius.isFinite && radius > 0, "Sphere radius must be finite and positive")
            default:
                return XCTFail("Synthetic colliders must be capsules or spheres")
            }
        }
        XCTAssertEqual(capsuleCount, 7, "Expect 4 leg + 1 brow + 2 lower-arm→hand capsules")
        XCTAssertEqual(sphereCount, 3, "Expect 1 lateral skull + 2 palm spheres")
    }

    /// A bone with a singular (zero-scale) world matrix must be SKIPPED, not emit
    /// a NaN capsule tail — `simd_inverse` of a singular rotation yields NaN/Inf
    /// which would propagate into the GPU spring sim. Regression for the
    /// degenerate-node edge case (PR #311 review).
    @MainActor func testDegenerateBoneIsSkippedWithoutNaN() async throws {
        let path = getTestVRM10ModelPath(); try requireFixture(path, hint: testVRM10Filename)
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device,
                                            options: VRMLoadingOptions(augmentSpringBoneColliders: true))
        let baseline = SpringBoneColliderAugmentor.synthesize(model: model).count
        guard let legNode = model.humanoid?.getBoneNode(.leftUpperLeg),
              legNode >= 0, legNode < model.nodes.count else { throw XCTSkip("No leftUpperLeg bone") }

        // Force a singular world matrix on the bone: zero the rotation/scale
        // block, keep the translation column so worldPosition (and the segment to
        // its child) stays valid. `simd_inverse` of this block would be NaN.
        var m = model.nodes[legNode].worldMatrix
        m.columns.0 = SIMD4<Float>(0, 0, 0, 0)
        m.columns.1 = SIMD4<Float>(0, 0, 0, 0)
        m.columns.2 = SIMD4<Float>(0, 0, 0, 0)
        model.nodes[legNode].worldMatrix = m

        let synthetic = SpringBoneColliderAugmentor.synthesize(model: model)
        XCTAssertEqual(synthetic.count, baseline - 1,
            "The degenerate leftUpperLeg segment must be skipped (one fewer capsule)")
        for c in synthetic {
            if case let .capsule(offset, radius, tail) = c.shape {
                XCTAssertTrue(offset.x.isFinite && offset.y.isFinite && offset.z.isFinite, "offset must be finite")
                XCTAssertTrue(tail.x.isFinite && tail.y.isFinite && tail.z.isFinite, "tail must be finite")
                XCTAssertTrue(radius.isFinite, "radius must be finite")
            }
        }
    }

    /// AvatarSample_A: `synthesize` appends a forward head/brow capsule AFTER the
    /// four leg capsules (slot 4 — buffer-order-sensitive). Its far end
    /// (offset.z + tail.z, head-local) is forward (> 0) of the head center and its
    /// radius is finite/plausible. Verifies the #309 manifestation-1 capsule.
    @MainActor func testAugmentA_appendsForwardHeadCapsule() async throws {
        let path = getTestVRM10ModelPath(); try requireFixture(path, hint: testVRM10Filename)
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device,
                                            options: VRMLoadingOptions(augmentSpringBoneColliders: true))
        guard let humanoid = model.humanoid else { return XCTFail("A must have a humanoid") }
        guard let headNode = humanoid.getBoneNode(.head) else { return XCTFail("A must rig a head") }

        let synthetic = SpringBoneColliderAugmentor.synthesize(model: model)
        XCTAssertEqual(synthetic.count, 10,
            "A: 4 leg + 1 brow + 2 lower-arm→hand capsules; 1 skull + 2 palm spheres")

        // The brow capsule (the head-node CAPSULE) is appended AFTER the legs.
        // The skull sphere follows it but is a SPHERE in a separate buffer, so the
        // brow capsule is the last *capsule* among the synthetic colliders.
        guard let headCapsule = synthetic.last(where: {
            if case .capsule = $0.shape { return $0.node == headNode } else { return false }
        }) else {
            return XCTFail("Must emit a head/brow capsule on the head node")
        }
        guard case let .capsule(offset, radius, tail) = headCapsule.shape else {
            return XCTFail("Head collider must be a capsule")
        }
        print("[#309 head capsule A] offset=\(offset) tail=\(tail) radius=\(radius)")

        XCTAssertTrue(radius.isFinite && radius > 0, "Head capsule radius must be finite and positive")
        XCTAssertLessThan(radius, 0.12, "Head capsule radius must stay physically plausible")
        // Head-local +Z is forward: the capsule's far end must sweep forward of
        // the head center toward the brow.
        XCTAssertGreaterThan(offset.z + tail.z, 0,
            "Head capsule far end must reach forward (head-local +Z) toward the brow")
        // And it must sweep downward (head-local -Y) toward the brow/upper-face.
        XCTAssertLessThan(tail.y, 0, "Head capsule must sweep down toward the brow")

        // The lateral skull SPHERE: appended after the brow capsule, on the head
        // node, sized/placed oracle-blind as fractions of rHead. Catches lateral
        // temple strands the midline brow capsule cannot reach (#309). It is the
        // sphere on the HEAD node (the palm spheres that follow it sit on the
        // hand nodes), so identify it by node + shape rather than position.
        guard let skull = synthetic.first(where: {
                  if case .sphere = $0.shape { return $0.node == headNode } else { return false }
              }), case let .sphere(sOffset, sRadius) = skull.shape else {
            return XCTFail("Must emit a head skull sphere on the head node")
        }
        // Recover rHead from the brow capsule radius (= 0.50 * rHead) to validate
        // the sphere's ratios independent of the oracle.
        let rHead = radius / 0.50
        print("[#309 skull sphere A] rHead=\(rHead) center.offset=\(sOffset) radius=\(sRadius) (radius/rHead=\(sRadius/rHead), up/rHead=\(sOffset.y/rHead))")
        XCTAssertTrue(sRadius.isFinite && sRadius > 0, "Skull sphere radius must be finite and positive")
        // Oracle-blind plausibility: the sphere must not balloon past ~1.05×rHead
        // (the authored skull estimate) — a much larger sphere would float other
        // hair (back-out criterion on #309).
        XCTAssertLessThanOrEqual(sRadius, 1.05 * rHead,
            "Skull sphere must not balloon past the authored skull (≤1.05×rHead)")
        // The sphere center sits at head-node + (head-local +Y) × up×rHead, lifted
        // toward the cranium (offset.x == offset.z == 0, offset.y > 0).
        XCTAssertEqual(sOffset.x, 0, accuracy: 1e-6, "Skull sphere is midline in X")
        XCTAssertEqual(sOffset.z, 0, accuracy: 1e-6, "Skull sphere is midline in Z")
        XCTAssertGreaterThan(sOffset.y, 0, "Skull sphere center must lift toward the cranium")
    }

    /// AvatarSample_U: `synthesize` returns 4 leg capsules; the `leftUpperLeg`
    /// capsule's far end (after applying the from-bone world transform to
    /// offset+tail) lands within 1 cm of `leftLowerLeg`'s world position; and the
    /// thigh radius comfortably exceeds the physical skin floor the oracle
    /// measured (thigh > 0.062) — a sanity FLOOR, not an oracle read. Arm capsules
    /// were dropped pending CCD/substep work (see SpringBoneColliderAugmentor).
    @MainActor func testAugmentU_legCapsuleGeometryAndRadii() async throws {
        let path = getTestModelPath("AvatarSample_U_1.0.vrm.glb")
        try requireFixture(path, hint: "AvatarSample_U_1.0.vrm.glb")
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device,
                                            options: VRMLoadingOptions(augmentSpringBoneColliders: true))
        guard let humanoid = model.humanoid else { return XCTFail("U must have a humanoid") }

        let synthetic = SpringBoneColliderAugmentor.synthesize(model: model)
        // Capsule-buffer order: legs (0–3), head/brow (4), lower-arm→hand (5–6).
        // The leg slots (0–3) and head slot (4) must stay put — the arm capsules
        // are appended after them (#321) and never disturb the validated order.
        let legBoneNodes = Set([
            humanoid.getBoneNode(.leftUpperLeg), humanoid.getBoneNode(.leftLowerLeg),
            humanoid.getBoneNode(.rightUpperLeg), humanoid.getBoneNode(.rightLowerLeg),
        ].compactMap { $0 })
        let legCapsules = synthetic.filter { legBoneNodes.contains($0.node) }
        XCTAssertEqual(legCapsules.count, 4, "U should yield 4 leg capsules")
        let capsules = synthetic.filter { if case .capsule = $0.shape { return true } else { return false } }
        if let headNode = humanoid.getBoneNode(.head), capsules.count > 4 {
            XCTAssertEqual(capsules[4].node, headNode,
                "Head/brow capsule must occupy capsule slot 4 (after the 4 leg capsules)")
        }

        // Resolve the leftUpperLeg capsule and verify its far end lands on leftLowerLeg.
        guard let upperLegNode = humanoid.getBoneNode(.leftUpperLeg),
              let lowerLegNode = humanoid.getBoneNode(.leftLowerLeg) else {
            return XCTFail("U must rig left upper/lower leg")
        }
        guard let upperLegCapsule = synthetic.first(where: { $0.node == upperLegNode }) else {
            return XCTFail("Missing leftUpperLeg capsule")
        }
        guard case let .capsule(offset, radius, tail) = upperLegCapsule.shape else {
            return XCTFail("leftUpperLeg collider must be a capsule")
        }

        let wm = model.nodes[upperLegNode].worldMatrix
        let rot = simd_float3x3(
            SIMD3<Float>(wm[0][0], wm[0][1], wm[0][2]),
            SIMD3<Float>(wm[1][0], wm[1][1], wm[1][2]),
            SIMD3<Float>(wm[2][0], wm[2][1], wm[2][2])
        )
        let p0 = model.nodes[upperLegNode].worldPosition + rot * offset
        let farEnd = p0 + rot * tail
        let lowerLegPos = model.nodes[lowerLegNode].worldPosition
        XCTAssertLessThan(simd_length(farEnd - lowerLegPos), 0.01,
            "leftUpperLeg capsule far end must land within 1cm of leftLowerLeg")

        // Thigh radius must enclose the thigh skin (oracle measured ~0.062), and
        // stay physically plausible (a real thigh radius is well under ~0.12 m).
        XCTAssertTrue(radius.isFinite)
        XCTAssertGreaterThan(radius, 0.062, "Thigh capsule must enclose the thigh skin")
        XCTAssertLessThan(radius, 0.12, "Thigh capsule radius must stay physically plausible")
    }


    /// Group-mask fail-safe boundary: the 32-bit collider-group mask reserves one
    /// bit for the synthetic group, so up to 31 authored groups are supported and
    /// 32+ disables augmentation. Mutates a real model's `colliderGroups` so the
    /// guard is exercised on a model whose leg/head bones otherwise emit capsules.
    @MainActor func testAugmentSupportedAt31GroupsSkippedAt32() async throws {
        let path = getTestVRM10ModelPath(); try requireFixture(path, hint: testVRM10Filename)
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device,
                                            options: VRMLoadingOptions(augmentSpringBoneColliders: false))
        func synthesizedCount(authoredGroups: Int) -> Int {
            var sb = model.springBone!
            sb.colliderGroups = (0..<authoredGroups).map { VRMColliderGroup(name: "G\($0)", colliders: []) }
            model.springBone = sb
            return SpringBoneColliderAugmentor.synthesize(model: model).count
        }
        XCTAssertGreaterThan(synthesizedCount(authoredGroups: 31), 0,
            "31 authored groups must still be augmented — bit 31 is free for the synthetic group")
        XCTAssertEqual(synthesizedCount(authoredGroups: 32), 0,
            "32 authored groups must disable augmentation — no free mask bit")
    }
}
