# Cross-Avatar Spring-Bone Collision Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend VRMMetalKit's SpringBone solver so one VRM avatar's spring bones yield to a partner avatar's skeleton-derived body colliders (settling, leaning, hugging), as a fourth foreign-collider source unioned into the solver — no second physics engine.

**Architecture:** A thin `SpringBoneContactGroup` coordinator owns membership + temporal ordering (snapshot-all → inject union-minus-self → integrate-all) and holds no per-model simulation state. Each `SpringBoneComputeSystem` gains a pure `contactColliderSnapshot(model:)` and a reserved-tail foreign-collider injection sink. Foreign colliders are skeleton-derived (torso + upper arms + head), snapped (not interpolated) into a reserved buffer tail so the authored interpolation invariant is structurally unreachable, tagged with a single reserved foreign group bit. v1 uses option (b): one-frame-lagged exchange.

**Tech Stack:** Swift 6.2, Metal compute (XPBD), XCTest, Swift Package Manager.

**Design spec:** `docs/superpowers/specs/2026-07-04-cross-avatar-collision-design.md` (ratified). Section references below (§N) point into it.

## Global Constraints

- **Platform:** macOS 26+, iOS 26+. Swift 6.2.
- **License header:** every new `.swift` file starts with the Apache 2.0 header (copy verbatim from any existing source file, e.g. `Sources/VRMMetalKit/SpringBoneColliderAugmentor.swift:1-15`).
- **No temporary/contextual comments** in code (per CLAUDE.md). Doc comments explaining *why* are fine; "TODO"-style notes are not.
- **Build:** `swift build`
- **Test (single):** `swift test --filter <TestClass> --disable-sandbox`
- **Test (full, fast):** `swift test --parallel --num-workers 14 -j 16 --disable-sandbox`
- **GPU tests skip on CI without a Metal device** — guard every GPU test with `guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }`.
- **Fixtures:** GPU tests that need a model use `getTestVRM10ModelPath()` + `try requireFixture(path, hint: testVRM10Filename)` then `VRMModel.load(from:device:options:)` (see `SpringBoneColliderAugmentorTests.swift`).
- **Shaders unchanged:** this plan touches **no** `.metal` files. The collision kernel already loops `for i in 0..<numSpheres` over `globalParams.numSpheres` and filters by `groupMask & (1u << groupIndex)`; foreign colliders ride that existing path. Do **not** run `make shaders`.
- **Determinism path:** behavior/non-interference tests run on the synchronous path — set `RendererConfig.synchronousSpringBone = true` (or drive `SpringBoneComputeSystem.update(model:deltaTime:commandBuffer:nil)` + `waitForPendingFrame()`), never the async render path, and never rely on the arm-swing guard.
- **Do not push** (each push burns Xcode Cloud CI credits). Commit freely; the human pushes.
- **Branch:** already on `design/cross-avatar-collision`. Continue here.

---

## File Structure

**New source files:**
- `Sources/VRMMetalKit/SpringBoneBoneGeometry.swift` — shared pure bone→capsule / bone→sphere geometry primitives, extracted from the augmentor (Task 1).
- `Sources/VRMMetalKit/SpringBoneContactColliderSet.swift` — skeleton-derived contact-set generator: torso + upper arms + head (Task 2).
- `Sources/VRMMetalKit/SpringBoneContactGroup.swift` — coordinator + `exchange()` (Task 6).

**Modified source files:**
- `Sources/VRMMetalKit/SpringBoneColliderAugmentor.swift` — refactor to call the shared primitives (Task 1).
- `Sources/VRMMetalKit/Core/VRMConstants.swift` — foreign-slot + max-partner constants (Task 4).
- `Sources/VRMMetalKit/SpringBoneBuffers.swift` — reserved-tail capacity separate from active count (Task 4).
- `Sources/VRMMetalKit/Core/VRMModel.swift` — pass foreign-slot headroom into `allocateBuffers` (Task 4).
- `Sources/VRMMetalKit/SpringBoneComputeSystem.swift` — `contactColliderSnapshot` (Task 3); foreign group bit at populate + per-frame `globalParams.numSpheres/numCapsules` (Task 4); injection sink (Task 5).

**New test files:** one per task under `Tests/VRMMetalKitTests/SpringBone/`.

**Task DAG:** Task 1 → Task 2 → Task 3; Task 4 → Task 5; (Task 3 + Task 5) → Task 6.

---

### Task 1: Extract shared bone-geometry primitives (behavior-preserving refactor)

Pull the augmentor's pure geometry math into a shared type both #309 and the contact-set generator call — "one implementation, two callers that can't disagree" (§2.3). This task changes **no behavior**: the existing augmentor tests must stay green.

**Files:**
- Create: `Sources/VRMMetalKit/SpringBoneBoneGeometry.swift`
- Modify: `Sources/VRMMetalKit/SpringBoneColliderAugmentor.swift` (replace private helpers with calls into the new type)
- Test: `Tests/VRMMetalKitTests/SpringBone/SpringBoneBoneGeometryTests.swift`

**Interfaces:**
- Produces:
  - `enum SpringBoneBoneGeometry` with:
    - `static func limbCapsule(fromBone: VRMHumanoidBone, toBone: VRMHumanoidBone, radiusFraction: Float, humanoid: VRMHumanoid, model: VRMModel) -> VRMCollider?`
    - `static func headReferenceRadius(humanoid: VRMHumanoid, model: VRMModel) -> (headNode: Int, rHead: Float)?`
    - `static func headBrowCapsule(humanoid: VRMHumanoid, model: VRMModel, ratios: SpringBoneColliderAugmentor.Ratios) -> VRMCollider?`
    - `static func headSkullSphere(humanoid: VRMHumanoid, model: VRMModel, ratios: SpringBoneColliderAugmentor.Ratios) -> VRMCollider?`
    - `static func upperLeft3x3(_ m: float4x4) -> simd_float3x3`

- [ ] **Step 1: Write the failing test**

Create `Tests/VRMMetalKitTests/SpringBone/SpringBoneBoneGeometryTests.swift` (with the Apache header), verifying the extracted primitive produces a valid capsule for a known limb segment and returns `nil` for an unresolvable bone:

```swift
import XCTest
import Metal
import simd
@testable import VRMMetalKit

final class SpringBoneBoneGeometryTests: XCTestCase {
    @MainActor func testLimbCapsuleNilWhenBoneMissing() async throws {
        let path = getTestVRM10ModelPath(); try requireFixture(path, hint: testVRM10Filename)
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device,
                                            options: VRMLoadingOptions(augmentSpringBoneColliders: false))
        model.updateNodeTransforms()
        let humanoid = try XCTUnwrap(model.humanoid)
        // .leftEye rarely anchors a leg-style segment; expect nil rather than a capsule.
        let collider = SpringBoneBoneGeometry.limbCapsule(
            fromBone: .leftEye, toBone: .rightEye, radiusFraction: 0.2,
            humanoid: humanoid, model: model)
        XCTAssertNil(collider)
    }

    @MainActor func testLimbCapsuleProducesFiniteCapsuleForLeg() async throws {
        let path = getTestVRM10ModelPath(); try requireFixture(path, hint: testVRM10Filename)
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device,
                                            options: VRMLoadingOptions(augmentSpringBoneColliders: false))
        model.updateNodeTransforms()
        let humanoid = try XCTUnwrap(model.humanoid)
        let collider = try XCTUnwrap(SpringBoneBoneGeometry.limbCapsule(
            fromBone: .leftUpperLeg, toBone: .leftLowerLeg, radiusFraction: 0.24,
            humanoid: humanoid, model: model))
        guard case let .capsule(_, radius, tail) = collider.shape else {
            return XCTFail("expected capsule")
        }
        XCTAssertTrue(radius.isFinite && radius > 0)
        XCTAssertTrue(tail.x.isFinite && tail.y.isFinite && tail.z.isFinite)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SpringBoneBoneGeometryTests --disable-sandbox`
Expected: FAIL — `cannot find 'SpringBoneBoneGeometry' in scope`.

- [ ] **Step 3: Create the shared primitive type**

Create `Sources/VRMMetalKit/SpringBoneBoneGeometry.swift` (Apache header first), moving the pure geometry math out of `SpringBoneColliderAugmentor` verbatim (same formulas, so #309 output is unchanged):

```swift
import Foundation
import simd

/// Pure bone-derived collider geometry shared by the #309 collider augmentor
/// and the cross-avatar contact-set generator. Same math, two callers that
/// cannot disagree (design §2.3). No Metal, no side effects, never mutates the
/// model. Callers own *which* bones to feed and *when* to call; this type owns
/// only the geometry.
enum SpringBoneBoneGeometry {

    /// One end-to-end capsule from `fromBone` to `toBone`, anchored in the
    /// `from` bone's local frame so it rides the limb under animation once the
    /// upload path re-applies the node world transform. Returns `nil` when
    /// either bone does not resolve, the segment is degenerate, or the frame is
    /// singular. Radius is the larger of the author's scale hint (largest
    /// authored sphere radius parented to `from`) and `radiusFraction × length`.
    static func limbCapsule(fromBone: VRMHumanoidBone, toBone: VRMHumanoidBone,
                            radiusFraction: Float, humanoid: VRMHumanoid,
                            model: VRMModel) -> VRMCollider? {
        guard let fromNode = humanoid.getBoneNode(fromBone),
              fromNode >= 0, fromNode < model.nodes.count,
              let toNode = humanoid.getBoneNode(toBone),
              toNode >= 0, toNode < model.nodes.count else {
            return nil
        }
        let fromPos = model.nodes[fromNode].worldPosition
        let toPos = model.nodes[toNode].worldPosition
        let segWorld = toPos - fromPos
        let length = simd_length(segWorld)
        guard length > 1e-4 else { return nil }

        let fromRot = upperLeft3x3(model.nodes[fromNode].worldMatrix)
        guard abs(simd_determinant(fromRot)) > 1e-6 else { return nil }
        let tailLocal = simd_inverse(fromRot) * segWorld

        let fractionFloor = length * radiusFraction
        let authoredHint = maxAuthoredSphereRadius(parentedTo: fromNode, model: model)
        let radius = max(authoredHint, fractionFloor)
        return VRMCollider(node: fromNode, shape: .capsule(offset: .zero, radius: radius, tail: tailLocal))
    }

    /// Head reference radius `rHead`, oracle-blind: largest authored head sphere
    /// radius, else `0.9 ×` head→neck length. `nil` if the head bone or a radius
    /// cannot be derived.
    static func headReferenceRadius(humanoid: VRMHumanoid, model: VRMModel) -> (headNode: Int, rHead: Float)? {
        guard let headNode = humanoid.getBoneNode(.head),
              headNode >= 0, headNode < model.nodes.count else { return nil }
        var rHead: Float = 0
        if let colliders = model.springBone?.colliders {
            for collider in colliders where collider.node == headNode {
                switch collider.shape {
                case .sphere(_, let radius), .insideSphere(_, let radius):
                    if radius > rHead { rHead = radius }
                default: continue
                }
            }
        }
        if rHead <= 0,
           let neckNode = humanoid.getBoneNode(.neck), neckNode >= 0, neckNode < model.nodes.count {
            let headPos = model.nodes[headNode].worldPosition
            let neckPos = model.nodes[neckNode].worldPosition
            rHead = 0.9 * simd_length(headPos - neckPos)
        }
        guard rHead > 0 else { return nil }
        return (headNode, rHead)
    }

    /// Forward head/brow capsule (head-local +Z forward, -Y down). `nil` if the
    /// head reference radius does not resolve.
    static func headBrowCapsule(humanoid: VRMHumanoid, model: VRMModel,
                                ratios: SpringBoneColliderAugmentor.Ratios) -> VRMCollider? {
        guard let (headNode, rHead) = headReferenceRadius(humanoid: humanoid, model: model) else { return nil }
        let offset = SIMD3<Float>(0, ratios.headOffsetUpFraction * rHead, ratios.headOffsetFwdFraction * rHead)
        let tail = SIMD3<Float>(0, -ratios.headDownFraction * rHead, ratios.headForwardFraction * rHead)
        let radius = ratios.headRadiusFraction * rHead
        return VRMCollider(node: headNode, shape: .capsule(offset: offset, radius: radius, tail: tail))
    }

    /// Lateral skull sphere for temple/side coverage. `nil` if the head
    /// reference radius does not resolve.
    static func headSkullSphere(humanoid: VRMHumanoid, model: VRMModel,
                                ratios: SpringBoneColliderAugmentor.Ratios) -> VRMCollider? {
        guard let (headNode, rHead) = headReferenceRadius(humanoid: humanoid, model: model) else { return nil }
        let offset = SIMD3<Float>(0, ratios.headSkullUpFraction * rHead, 0)
        let radius = ratios.headSkullRadiusFraction * rHead
        return VRMCollider(node: headNode, shape: .sphere(offset: offset, radius: radius))
    }

    /// Extracts the upper-left 3x3 of a 4x4 world matrix (mirrors the upload path).
    static func upperLeft3x3(_ m: float4x4) -> simd_float3x3 {
        simd_float3x3(
            SIMD3<Float>(m[0][0], m[0][1], m[0][2]),
            SIMD3<Float>(m[1][0], m[1][1], m[1][2]),
            SIMD3<Float>(m[2][0], m[2][1], m[2][2]))
    }

    private static func maxAuthoredSphereRadius(parentedTo node: Int, model: VRMModel) -> Float {
        guard let colliders = model.springBone?.colliders else { return 0 }
        var best: Float = 0
        for collider in colliders where collider.node == node {
            switch collider.shape {
            case .sphere(_, let radius), .insideSphere(_, let radius):
                if radius > best { best = radius }
            default: continue
            }
        }
        return best
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SpringBoneBoneGeometryTests --disable-sandbox`
Expected: PASS (both tests; or SKIP if no Metal device).

- [ ] **Step 5: Refactor the augmentor to call the shared primitives**

In `Sources/VRMMetalKit/SpringBoneColliderAugmentor.swift`, replace the bodies of the private helpers so they delegate to `SpringBoneBoneGeometry` (do **not** change `synthesize`'s ordering or the `Ratios` struct). Replace `appendLimbCapsule`, `appendHeadCapsule`, `appendHeadSkullSphere`, and delete the now-unused private `headReferenceRadius`, `radiusFor`, `maxAuthoredSphereRadius`, `upperLeft3x3`:

```swift
    private static func appendHeadCapsule(
        humanoid: VRMHumanoid, model: VRMModel, ratios: Ratios, into out: inout [VRMCollider]
    ) {
        if let c = SpringBoneBoneGeometry.headBrowCapsule(humanoid: humanoid, model: model, ratios: ratios) {
            out.append(c)
        }
    }

    private static func appendHeadSkullSphere(
        humanoid: VRMHumanoid, model: VRMModel, ratios: Ratios, into out: inout [VRMCollider]
    ) {
        if let c = SpringBoneBoneGeometry.headSkullSphere(humanoid: humanoid, model: model, ratios: ratios) {
            out.append(c)
        }
    }

    private static func appendLimbCapsule(
        _ segment: LimbSegment, humanoid: VRMHumanoid, model: VRMModel,
        radiusFraction: Float, into out: inout [VRMCollider]
    ) {
        if let c = SpringBoneBoneGeometry.limbCapsule(
            fromBone: segment.from, toBone: segment.to, radiusFraction: radiusFraction,
            humanoid: humanoid, model: model) {
            out.append(c)
        }
    }
```

Then delete the now-dead private funcs `headReferenceRadius`, `radiusFor`, `maxAuthoredSphereRadius`, and `upperLeft3x3` from the augmentor (they live in `SpringBoneBoneGeometry` now). Keep `appendHandSpheres` as-is but change its one `upperLeft3x3(...)` call to `SpringBoneBoneGeometry.upperLeft3x3(...)`.

- [ ] **Step 6: Run the augmentor's existing tests to verify no behavior change**

Run: `swift test --filter SpringBoneColliderAugmentorTests --disable-sandbox`
Expected: PASS — `testAugmentOnAddsFourLegCapsules` still asserts `synthetic.count == 10` with unchanged radii. This is the behavior-preserving gate.

- [ ] **Step 7: Build the whole package**

Run: `swift build`
Expected: builds clean, no unused-symbol warnings for the deleted privates.

- [ ] **Step 8: Commit**

```bash
git add Sources/VRMMetalKit/SpringBoneBoneGeometry.swift \
        Sources/VRMMetalKit/SpringBoneColliderAugmentor.swift \
        Tests/VRMMetalKitTests/SpringBone/SpringBoneBoneGeometryTests.swift
git commit -m "refactor(springbone): extract shared bone->capsule geometry (#309 unchanged)"
```

---

### Task 2: Contact-set generator (torso + upper arms + head)

Add the skeleton-derived contact set — the huggable body surface — as a **second caller** of the shared primitives, with a different bone selection than #309 and a **new torso capsule** #309 omits (§5). It fires on demand (not through `augmentSpringBoneColliders`).

**Files:**
- Create: `Sources/VRMMetalKit/SpringBoneContactColliderSet.swift`
- Test: `Tests/VRMMetalKitTests/SpringBone/SpringBoneContactColliderSetTests.swift`

**Interfaces:**
- Consumes: `SpringBoneBoneGeometry` (Task 1), `SpringBoneColliderAugmentor.Ratios`.
- Produces:
  - `enum SpringBoneContactColliderSet` with `static func synthesize(model: VRMModel) -> [VRMCollider]` (local-space, node-anchored colliders; empty when no humanoid).
  - `struct ContactSetRatios` (torso ratio) — or extend usage of `SpringBoneColliderAugmentor.Ratios`. This plan adds `torsoRadiusFractionOfLength` as a standalone constant in the generator.

- [ ] **Step 1: Write the failing test**

Create `Tests/VRMMetalKitTests/SpringBone/SpringBoneContactColliderSetTests.swift` (Apache header):

```swift
import XCTest
import Metal
import simd
@testable import VRMMetalKit

final class SpringBoneContactColliderSetTests: XCTestCase {
    @MainActor func testEmptyWithoutHumanoid() {
        let json = #"{"asset":{"version":"2.0"}}"#
        let gltf = try! JSONDecoder().decode(GLTFDocument.self, from: Data(json.utf8))
        let model = VRMModel(specVersion: .v1_0, meta: VRMMeta(licenseUrl: ""), humanoid: nil, gltf: gltf)
        XCTAssertTrue(SpringBoneContactColliderSet.synthesize(model: model).isEmpty)
    }

    @MainActor func testContactSetHasTorsoArmsAndHead() async throws {
        let path = getTestVRM10ModelPath(); try requireFixture(path, hint: testVRM10Filename)
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device,
                                            options: VRMLoadingOptions(augmentSpringBoneColliders: false))
        model.updateNodeTransforms()
        let set = SpringBoneContactColliderSet.synthesize(model: model)
        // torso (1 capsule) + 2 upper-arm capsules + head brow (1 capsule) = 4 capsules;
        // skull sphere = 1 sphere. Bounded contact-set cardinality (design §6).
        let capsules = set.filter { if case .capsule = $0.shape { return true } else { return false } }
        let spheres = set.filter { if case .sphere = $0.shape { return true } else { return false } }
        XCTAssertEqual(capsules.count, 4, "torso + 2 arms + brow")
        XCTAssertEqual(spheres.count, 1, "skull sphere")
        for c in set {
            switch c.shape {
            case let .capsule(_, radius, _): XCTAssertTrue(radius.isFinite && radius > 0)
            case let .sphere(_, radius): XCTAssertTrue(radius.isFinite && radius > 0)
            default: XCTFail("unexpected shape")
            }
        }
    }

    @MainActor func testHeadGeometryMatchesAugmentor() async throws {
        // Parity: the shared primitive means the contact set's head geometry is
        // identical to the augmentor's for the same bones (design §2.3).
        let path = getTestVRM10ModelPath(); try requireFixture(path, hint: testVRM10Filename)
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device,
                                            options: VRMLoadingOptions(augmentSpringBoneColliders: false))
        model.updateNodeTransforms()
        let humanoid = try XCTUnwrap(model.humanoid)
        let ratios = SpringBoneColliderAugmentor.Ratios()
        let brow = try XCTUnwrap(SpringBoneBoneGeometry.headBrowCapsule(humanoid: humanoid, model: model, ratios: ratios))
        let set = SpringBoneContactColliderSet.synthesize(model: model)
        let setBrow = set.first {
            if case .capsule = $0.shape, $0.node == brow.node { return true } else { return false }
        }
        XCTAssertNotNil(setBrow, "contact set includes the same brow capsule the augmentor emits")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SpringBoneContactColliderSetTests --disable-sandbox`
Expected: FAIL — `cannot find 'SpringBoneContactColliderSet' in scope`.

- [ ] **Step 3: Create the generator**

Create `Sources/VRMMetalKit/SpringBoneContactColliderSet.swift` (Apache header):

```swift
import Foundation
import simd

/// Skeleton-derived body contact set for cross-avatar collision (design §5):
/// the huggable surfaces a partner's spring bones yield to — torso, upper arms,
/// and head. A *second caller* of the shared bone->capsule geometry
/// (`SpringBoneBoneGeometry`), independent of the #309 augmentor's trigger and
/// enable flag: it fires because a contact-group participant needs its contact
/// surface, computed from the humanoid skeleton every VRM 1.0 avatar has.
///
/// Output is local-space, node-anchored `VRMCollider`s (the world transform is
/// re-applied at snapshot time). Empty when the model has no humanoid.
enum SpringBoneContactColliderSet {

    /// Torso capsule radius as a fraction of the spine->chest segment length.
    /// The torso is thick relative to its segment, so this floor is larger than
    /// the limb fractions. NEW geometry with no #309 precedent — this value is
    /// the visual-calibration target for the hug spike (design §5.3), not
    /// inherited from a validated #309 ratio.
    static let torsoRadiusFractionOfLength: Float = 0.5

    /// Upper-arm capsule radius as a fraction of the upperArm->lowerArm length.
    static let upperArmRadiusFractionOfLength: Float = 0.22

    static func synthesize(model: VRMModel) -> [VRMCollider] {
        guard let humanoid = model.humanoid else { return [] }
        let ratios = SpringBoneColliderAugmentor.Ratios()
        var out: [VRMCollider] = []

        // Torso: spine -> (upperChest ?? chest ?? neck). The single vertical
        // trunk capsule — the primary hug surface #309 omits.
        let torsoTo: VRMHumanoidBone = {
            if humanoid.getBoneNode(.upperChest) != nil { return .upperChest }
            if humanoid.getBoneNode(.chest) != nil { return .chest }
            return .neck
        }()
        if let torso = SpringBoneBoneGeometry.limbCapsule(
            fromBone: .spine, toBone: torsoTo, radiusFraction: torsoRadiusFractionOfLength,
            humanoid: humanoid, model: model) {
            out.append(torso)
        }

        // Upper arms: the arm surface a hug wraps.
        for (from, to) in [(VRMHumanoidBone.leftUpperArm, VRMHumanoidBone.leftLowerArm),
                           (VRMHumanoidBone.rightUpperArm, VRMHumanoidBone.rightLowerArm)] {
            if let arm = SpringBoneBoneGeometry.limbCapsule(
                fromBone: from, toBone: to, radiusFraction: upperArmRadiusFractionOfLength,
                humanoid: humanoid, model: model) {
                out.append(arm)
            }
        }

        // Head: brow capsule + skull sphere, identical to #309's head geometry.
        if let brow = SpringBoneBoneGeometry.headBrowCapsule(humanoid: humanoid, model: model, ratios: ratios) {
            out.append(brow)
        }
        if let skull = SpringBoneBoneGeometry.headSkullSphere(humanoid: humanoid, model: model, ratios: ratios) {
            out.append(skull)
        }
        return out
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SpringBoneContactColliderSetTests --disable-sandbox`
Expected: PASS (or SKIP without a Metal device).

- [ ] **Step 5: Commit**

```bash
git add Sources/VRMMetalKit/SpringBoneContactColliderSet.swift \
        Tests/VRMMetalKitTests/SpringBone/SpringBoneContactColliderSetTests.swift
git commit -m "feat(springbone): skeleton-derived contact-set generator (torso + arms + head)"
```

---

### Task 3: Pure `contactColliderSnapshot(model:)` on the compute system

A **pure** world-space snapshot of this avatar's contact set — no mutation of the interpolation mirror (§2.2 correctness requirement). It generates the contact set (Task 2), transforms each collider to world space with the same idiom as `appendSyntheticColliders`, and returns flat GPU-struct arrays.

**Files:**
- Modify: `Sources/VRMMetalKit/SpringBoneComputeSystem.swift` (add the method + the result struct)
- Test: `Tests/VRMMetalKitTests/SpringBone/SpringBoneContactSnapshotTests.swift`

**Interfaces:**
- Consumes: `SpringBoneContactColliderSet.synthesize` (Task 2); existing `SphereCollider`, `CapsuleCollider` GPU structs.
- Produces:
  - `public struct ForeignColliderSnapshot: Sendable { public var spheres: [SphereCollider]; public var capsules: [CapsuleCollider] }`
  - `func contactColliderSnapshot(model: VRMModel) -> ForeignColliderSnapshot` on `SpringBoneComputeSystem`. World-space; `groupIndex` left at `0` (the receiving sink assigns the foreign group index — Task 5).

- [ ] **Step 1: Write the failing test**

Create `Tests/VRMMetalKitTests/SpringBone/SpringBoneContactSnapshotTests.swift` (Apache header):

```swift
import XCTest
import Metal
import simd
@testable import VRMMetalKit

final class SpringBoneContactSnapshotTests: XCTestCase {
    @MainActor func testSnapshotProducesWorldSpaceContactColliders() async throws {
        let path = getTestVRM10ModelPath(); try requireFixture(path, hint: testVRM10Filename)
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device,
                                            options: VRMLoadingOptions(augmentSpringBoneColliders: false))
        model.updateNodeTransforms()
        let system = try SpringBoneComputeSystem(device: device)
        let snap = system.contactColliderSnapshot(model: model)
        // 4 capsules + 1 sphere from the contact set; all finite world-space.
        XCTAssertEqual(snap.capsules.count, 4)
        XCTAssertEqual(snap.spheres.count, 1)
        for s in snap.spheres {
            XCTAssertTrue(s.center.x.isFinite && s.center.y.isFinite && s.center.z.isFinite)
            XCTAssertTrue(s.radius.isFinite && s.radius > 0)
        }
        for c in snap.capsules {
            XCTAssertTrue(c.p0.x.isFinite && c.p1.x.isFinite && c.radius > 0)
            XCTAssertNotEqual(c.p0, c.p1, "world capsule endpoints differ")
        }
    }

    @MainActor func testSnapshotIsPure_doesNotAdvanceOrPerturbSim() async throws {
        let path = getTestVRM10ModelPath(); try requireFixture(path, hint: testVRM10Filename)
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device,
                                            options: VRMLoadingOptions(augmentSpringBoneColliders: true))
        model.updateNodeTransforms()
        let system = try SpringBoneComputeSystem(device: device)
        try system.populateSpringBoneData(model: model)
        // Advance one frame.
        system.update(model: model, deltaTime: 1.0 / 60.0, commandBuffer: nil)
        system.waitForPendingFrame()
        let before = model.springBoneBuffers?.getCurrentPositions() ?? []
        // Calling snapshot repeatedly must not change sim state.
        for _ in 0..<5 { _ = system.contactColliderSnapshot(model: model) }
        let after = model.springBoneBuffers?.getCurrentPositions() ?? []
        XCTAssertEqual(before.count, after.count)
        for i in before.indices {
            XCTAssertEqual(before[i], after[i], "snapshot must not perturb bone positions")
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SpringBoneContactSnapshotTests --disable-sandbox`
Expected: FAIL — `value of type 'SpringBoneComputeSystem' has no member 'contactColliderSnapshot'`.

- [ ] **Step 3: Add the result struct and the pure method**

In `Sources/VRMMetalKit/SpringBoneBuffers.swift`, after the `SphereCollider`/`CapsuleCollider` definitions (near line 331), add:

```swift
/// A world-space snapshot of one avatar's body contact set, handed across the
/// avatar boundary by `SpringBoneContactGroup`. `groupIndex` is unset here (0);
/// the receiving avatar's injection sink assigns its own reserved foreign group
/// index when writing these into its buffer tail (design §2.2, §7).
public struct ForeignColliderSnapshot: Sendable {
    public var spheres: [SphereCollider]
    public var capsules: [CapsuleCollider]
    public init(spheres: [SphereCollider] = [], capsules: [CapsuleCollider] = []) {
        self.spheres = spheres
        self.capsules = capsules
    }
}
```

In `Sources/VRMMetalKit/SpringBoneComputeSystem.swift`, add the method (place it near `appendSyntheticColliders`, ~line 1064). It reuses the world-transform idiom but touches **no** instance state:

```swift
    /// Pure world-space snapshot of this avatar's skeleton-derived body contact
    /// set (torso + upper arms + head). Reuses the world-transform idiom of
    /// `appendSyntheticColliders` but mutates NOTHING — it does not read or write
    /// the interpolation mirror, so the coordinator can call it before this
    /// system's integrate without perturbing the subsequent frame (design §2.2).
    /// `groupIndex` is left 0; the receiving sink assigns the foreign group.
    func contactColliderSnapshot(model: VRMModel) -> ForeignColliderSnapshot {
        let local = SpringBoneContactColliderSet.synthesize(model: model)
        var spheres: [SphereCollider] = []
        var capsules: [CapsuleCollider] = []
        for collider in local {
            guard let node = model.nodes[safe: collider.node] else { continue }
            let wm = node.worldMatrix
            let rot = simd_float3x3(
                SIMD3<Float>(wm[0][0], wm[0][1], wm[0][2]),
                SIMD3<Float>(wm[1][0], wm[1][1], wm[1][2]),
                SIMD3<Float>(wm[2][0], wm[2][1], wm[2][2]))
            switch collider.shape {
            case .sphere(let offset, let radius):
                spheres.append(SphereCollider(center: node.worldPosition + rot * offset,
                                              radius: radius, groupIndex: 0))
            case .capsule(let offset, let radius, let tail):
                let p0 = node.worldPosition + rot * offset
                let p1 = p0 + rot * tail
                capsules.append(CapsuleCollider(p0: p0, p1: p1, radius: radius, groupIndex: 0))
            default:
                continue
            }
        }
        return ForeignColliderSnapshot(spheres: spheres, capsules: capsules)
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SpringBoneContactSnapshotTests --disable-sandbox`
Expected: PASS (or SKIP without a Metal device).

- [ ] **Step 5: Commit**

```bash
git add Sources/VRMMetalKit/SpringBoneComputeSystem.swift \
        Sources/VRMMetalKit/SpringBoneBuffers.swift \
        Tests/VRMMetalKitTests/SpringBone/SpringBoneContactSnapshotTests.swift
git commit -m "feat(springbone): pure contactColliderSnapshot(model:) world-space contact set"
```

---

### Task 4: Reserved-tail capacity + foreign group bit + per-frame active count

Separate the **three quantities that currently coincide** (§4.2): allocation capacity, the count-guard reference `buffers.numSpheres`, and the per-frame kernel active count `globalParams.numSpheres`. Reserve `N` foreign slots, reserve the foreign group bit on every spring bone, and make `globalParams.numSpheres/numCapsules` per-frame (defaulting to zero foreign ⇒ bit-identical to today).

**Files:**
- Modify: `Sources/VRMMetalKit/Core/VRMConstants.swift` (constants)
- Modify: `Sources/VRMMetalKit/SpringBoneBuffers.swift` (`sphereCapacity`/`capsuleCapacity`; `allocateBuffers` headroom)
- Modify: `Sources/VRMMetalKit/Core/VRMModel.swift` (pass headroom into `allocateBuffers`)
- Modify: `Sources/VRMMetalKit/SpringBoneComputeSystem.swift` (foreign group bit at populate; `activeForeignSpheres/Capsules`; per-frame `params.numSpheres/numCapsules`)
- Test: `Tests/VRMMetalKitTests/SpringBone/SpringBoneForeignCapacityTests.swift`

**Interfaces:**
- Produces:
  - `VRMConstants.Physics.maxContactPartners: Int` (= 3), `foreignSphereSlotsPerPartner: Int` (= 1), `foreignCapsuleSlotsPerPartner: Int` (= 4).
  - `SpringBoneBuffers.sphereCapacity: Int`, `SpringBoneBuffers.capsuleCapacity: Int` (allocation counts, ≥ `numSpheres`/`numCapsules`).
  - `SpringBoneBuffers.allocateBuffers(numBones:numSpheres:numCapsules:numPlanes:foreignSphereSlots:foreignCapsuleSlots:)` (new trailing params, default 0).
  - `SpringBoneComputeSystem.foreignColliderGroupIndex: UInt32` (reserved, = `min(colliderGroups.count + 1, 31)`).
  - `SpringBoneComputeSystem.activeForeignSpheres: Int`, `.activeForeignCapsules: Int` (default 0; set by the sink in Task 5).

- [ ] **Step 1: Write the failing test**

Create `Tests/VRMMetalKitTests/SpringBone/SpringBoneForeignCapacityTests.swift` (Apache header). The core gate is **bit-identical non-interference**: reserving the tail with zero active foreign must not change the sim.

```swift
import XCTest
import Metal
import simd
@testable import VRMMetalKit

final class SpringBoneForeignCapacityTests: XCTestCase {
    /// Reserving the foreign tail (with zero foreign injected) must not perturb
    /// the authored simulation by even a bit (design §8.1).
    @MainActor func testReservedTailZeroForeignIsBitIdentical() async throws {
        let path = getTestVRM10ModelPath(); try requireFixture(path, hint: testVRM10Filename)
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }

        func run(reserve: Bool) async throws -> [SIMD3<Float>] {
            let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device,
                options: VRMLoadingOptions(augmentSpringBoneColliders: true))
            model.updateNodeTransforms()
            // The reserve flag routes through initializeSpringBoneGPUSystem's
            // headroom (0 when !reserve, N when reserve).
            model.springBoneForeignReservationEnabledForTesting = reserve
            try model.initializeSpringBoneGPUSystem(device: device)
            let system = try SpringBoneComputeSystem(device: device)
            try system.populateSpringBoneData(model: model)
            for _ in 0..<30 {
                system.update(model: model, deltaTime: 1.0 / 60.0, commandBuffer: nil)
                system.waitForPendingFrame()
            }
            return model.springBoneBuffers?.getCurrentPositions() ?? []
        }

        let baseline = try await run(reserve: false)
        let reserved = try await run(reserve: true)
        XCTAssertEqual(baseline.count, reserved.count)
        XCTAssertFalse(baseline.isEmpty)
        for i in baseline.indices {
            XCTAssertEqual(baseline[i], reserved[i], "reserved tail with zero foreign must be bit-identical at bone \(i)")
        }
    }

    @MainActor func testCapacityExceedsActiveCountWhenReserved() async throws {
        let path = getTestVRM10ModelPath(); try requireFixture(path, hint: testVRM10Filename)
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device,
            options: VRMLoadingOptions(augmentSpringBoneColliders: true))
        model.updateNodeTransforms()
        model.springBoneForeignReservationEnabledForTesting = true
        try model.initializeSpringBoneGPUSystem(device: device)
        let buffers = try XCTUnwrap(model.springBoneBuffers)
        XCTAssertGreaterThan(buffers.capsuleCapacity, buffers.numCapsules)
        XCTAssertGreaterThanOrEqual(buffers.sphereCapacity, buffers.numSpheres)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SpringBoneForeignCapacityTests --disable-sandbox`
Expected: FAIL — `springBoneForeignReservationEnabledForTesting` / `capsuleCapacity` unknown.

- [ ] **Step 3: Add constants**

In `Sources/VRMMetalKit/Core/VRMConstants.swift`, inside `public enum Physics` (near `minScaleForThreshold`, line ~148), add:

```swift
        /// Max simultaneous contact-group partners a single avatar yields to
        /// (design §6). The reserved foreign-collider tail is sized to this.
        public static let maxContactPartners: Int = 3
        /// Foreign sphere slots reserved per partner: the contact set contributes
        /// one skull sphere per partner (design §5).
        public static let foreignSphereSlotsPerPartner: Int = 1
        /// Foreign capsule slots reserved per partner: torso + 2 upper arms +
        /// brow = 4 capsules per partner (design §5).
        public static let foreignCapsuleSlotsPerPartner: Int = 4
```

- [ ] **Step 4: Separate capacity from active count in the buffers**

In `Sources/VRMMetalKit/SpringBoneBuffers.swift`, add stored capacity properties after `numPlanes` (line 60) and rewrite `allocateBuffers` to reserve headroom while keeping `numSpheres`/`numCapsules` as the **active** count:

```swift
    /// Allocated sphere-buffer slot count (>= numSpheres). The tail
    /// [numSpheres, sphereCapacity) is the reserved foreign region (design §4.2).
    var sphereCapacity: Int = 0
    /// Allocated capsule-buffer slot count (>= numCapsules).
    var capsuleCapacity: Int = 0
```

```swift
    func allocateBuffers(numBones: Int, numSpheres: Int, numCapsules: Int, numPlanes: Int = 0,
                         foreignSphereSlots: Int = 0, foreignCapsuleSlots: Int = 0) {
        self.numBones = numBones
        self.numSpheres = numSpheres
        self.numCapsules = numCapsules
        self.numPlanes = numPlanes
        self.sphereCapacity = numSpheres + foreignSphereSlots
        self.capsuleCapacity = numCapsules + foreignCapsuleSlots

        let bonePosSize = MemoryLayout<SIMD3<Float>>.stride * numBones
        let boneParamsSize = MemoryLayout<BoneParams>.stride * numBones
        let restLengthSize = MemoryLayout<Float>.stride * numBones
        let sphereColliderSize = MemoryLayout<SphereCollider>.stride * max(sphereCapacity, 0)
        let capsuleColliderSize = MemoryLayout<CapsuleCollider>.stride * max(capsuleCapacity, 0)
        let planeColliderSize = MemoryLayout<PlaneCollider>.stride * numPlanes

        bonePosPrev = device.makeBuffer(length: bonePosSize, options: [.storageModeShared])
        bonePosPrev?.label = "SpringBone BonePos Prev"
        bonePosCurr = device.makeBuffer(length: bonePosSize, options: [.storageModeShared])
        bonePosCurr?.label = "SpringBone BonePos Curr"
        boneParams = device.makeBuffer(length: boneParamsSize, options: [.storageModeShared])
        boneParams?.label = "SpringBone BoneParams"
        restLengths = device.makeBuffer(length: restLengthSize, options: [.storageModeShared])
        restLengths?.label = "SpringBone RestLengths"
        bindDirections = device.makeBuffer(length: bonePosSize, options: [.storageModeShared])
        bindDirections?.label = "SpringBone BindDirections"

        if sphereCapacity > 0 {
            sphereColliders = device.makeBuffer(length: sphereColliderSize, options: [.storageModeShared])
            sphereColliders?.label = "SpringBone SphereColliders"
        }
        if capsuleCapacity > 0 {
            capsuleColliders = device.makeBuffer(length: capsuleColliderSize, options: [.storageModeShared])
            capsuleColliders?.label = "SpringBone CapsuleColliders"
        }
        if numPlanes > 0 {
            planeColliders = device.makeBuffer(length: planeColliderSize, options: [.storageModeShared])
            planeColliders?.label = "SpringBone PlaneColliders"
        }
    }
```

Note: `updateSphereColliders`/`updateCapsuleColliders` keep their `count == numSpheres`/`count == numCapsules` guards unchanged — they upload the **active** authored+synthetic set into the prefix, never the tail.

- [ ] **Step 5: Pass headroom from the model**

In `Sources/VRMMetalKit/Core/VRMModel.swift`, add the test hook property on `VRMModel` (near other stored properties) and route headroom into `allocateBuffers`. Add near the class's stored vars:

```swift
    /// Test-only toggle: when true, `initializeSpringBoneGPUSystem` reserves the
    /// cross-avatar foreign-collider tail. Production reserves unconditionally
    /// once contact groups are wired; this hook lets the capacity test compare
    /// reserved vs. unreserved without a coordinator (design §8.1).
    public var springBoneForeignReservationEnabledForTesting: Bool = true
```

Then change the `allocateBuffers` call (line 1217) to:

```swift
        let reserve = springBoneForeignReservationEnabledForTesting
        let foreignSphereSlots = reserve
            ? VRMConstants.Physics.maxContactPartners * VRMConstants.Physics.foreignSphereSlotsPerPartner : 0
        let foreignCapsuleSlots = reserve
            ? VRMConstants.Physics.maxContactPartners * VRMConstants.Physics.foreignCapsuleSlotsPerPartner : 0
        springBoneBuffers = SpringBoneBuffers(device: device)
        springBoneBuffers?.allocateBuffers(
            numBones: totalBones,
            numSpheres: totalSpheres,
            numCapsules: totalCapsules,
            numPlanes: totalPlanes,
            foreignSphereSlots: foreignSphereSlots,
            foreignCapsuleSlots: foreignCapsuleSlots
        )
```

- [ ] **Step 6: Reserve the foreign group bit + add per-frame active-foreign counts**

In `Sources/VRMMetalKit/SpringBoneComputeSystem.swift`, add stored properties near `sweptColliderGroupIndex` (line ~82):

```swift
    /// Reserved collider-group index for cross-avatar FOREIGN colliders (design
    /// §7). Distinct from the synthetic group so foreign colliders stay OUT of
    /// the synthetic group's swept-CCD scoping (foreign contact is discrete).
    /// `min(colliderGroups.count + 1, 31)`; set at populate time.
    private var foreignColliderGroupIndex: UInt32 = 0xFFFFFFFF
    /// Active foreign colliders written into the reserved tail THIS frame. Set by
    /// the injection sink; drives the per-frame kernel active count. Zero ⇒ the
    /// authored path is bit-identical (design §4.2, §8.1).
    var activeForeignSpheres: Int = 0
    var activeForeignCapsules: Int = 0
```

In `populateSpringBoneData` (line ~1065), after `syntheticGroupIndex` is computed (line ~1101), reserve the foreign index and OR its bit into **every** spring bone's mask. Find where `syntheticGroupBit` is defined (line ~1103) and add directly after it:

```swift
        // Reserve the foreign group bit (design §7). Distinct from synthetic;
        // OR'd into every spring bone unconditionally — harmless when idle (no
        // foreign colliders ⇒ the bit matches nothing).
        foreignColliderGroupIndex = UInt32(min(springBone.colliderGroups.count + 1, 31))
        let foreignGroupBit: UInt32 = 1 << foreignColliderGroupIndex
```

Then find the loop that builds `BoneParams` and sets `colliderGroupMask` (within the `for spring in springBone.springs` block). Locate the line that ORs `syntheticGroupBit` into the mask and OR the foreign bit in the same place:

```swift
            // existing: mask |= syntheticGroupBit
            // add:
            mask |= foreignGroupBit
```

(If the mask variable has a different name at that site, use the actual name; the change is: every bone that gets `syntheticGroupBit` also gets `foreignGroupBit`.)

In `update(...)`, inside the substep loop where `params` is finalized before upload (after `params.dtSub = ...`, line ~475), set the per-frame active counts:

```swift
            // Per-frame kernel active count = active authored+synthetic + active
            // foreign. Zero foreign ⇒ equals the load-time value ⇒ bit-identical
            // (design §4.2). buffers.numSpheres/numCapsules is the active
            // authored+synthetic count (the reserved tail is beyond it).
            params.numSpheres = UInt32(buffers.numSpheres + activeForeignSpheres)
            params.numCapsules = UInt32(buffers.numCapsules + activeForeignCapsules)
```

- [ ] **Step 7: Run the capacity test**

Run: `swift test --filter SpringBoneForeignCapacityTests --disable-sandbox`
Expected: PASS — bit-identical with zero foreign, capacity > active.

- [ ] **Step 8: Run the full spring-bone suite for regressions**

Run: `swift test --filter SpringBone --disable-sandbox`
Expected: PASS — existing physics/determinism tests unaffected (zero foreign everywhere).

- [ ] **Step 9: Commit**

```bash
git add Sources/VRMMetalKit/Core/VRMConstants.swift \
        Sources/VRMMetalKit/SpringBoneBuffers.swift \
        Sources/VRMMetalKit/Core/VRMModel.swift \
        Sources/VRMMetalKit/SpringBoneComputeSystem.swift \
        Tests/VRMMetalKitTests/SpringBone/SpringBoneForeignCapacityTests.swift
git commit -m "feat(springbone): reserved foreign-collider tail + group bit + per-frame active count"
```

---

### Task 5: Foreign-collider injection sink (write tail once per frame, replace-or-clear)

Write the coordinator's per-frame foreign array into the reserved tail once per frame, tagged with `foreignColliderGroupIndex`, with a **replace-or-clear, total-over-frames** contract (§4.1). The sink sets `activeForeignSpheres/Capsules` (Task 4) so the kernel counts them.

**Files:**
- Modify: `Sources/VRMMetalKit/SpringBoneComputeSystem.swift` (the sink method + call it at the top of `update`'s substep processing)
- Test: `Tests/VRMMetalKitTests/SpringBone/SpringBoneForeignSinkTests.swift`

**Interfaces:**
- Consumes: `ForeignColliderSnapshot` (Task 3); `foreignColliderGroupIndex`, `activeForeignSpheres/Capsules`, `sphereCapacity`/`capsuleCapacity` (Task 4).
- Produces:
  - `func setForeignColliders(_ snapshot: ForeignColliderSnapshot)` on `SpringBoneComputeSystem` — stores the frame's foreign set (replace-or-clear); clamps to reserved capacity and logs drops.
  - Internal `writeForeignTail(buffers:)` called once per frame before the substep loop.

- [ ] **Step 1: Write the failing test**

Create `Tests/VRMMetalKitTests/SpringBone/SpringBoneForeignSinkTests.swift` (Apache header):

```swift
import XCTest
import Metal
import simd
@testable import VRMMetalKit

final class SpringBoneForeignSinkTests: XCTestCase {
    @MainActor private func loadedSystem(_ device: MTLDevice) async throws -> (VRMModel, SpringBoneComputeSystem) {
        let path = getTestVRM10ModelPath(); try requireFixture(path, hint: testVRM10Filename)
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device,
            options: VRMLoadingOptions(augmentSpringBoneColliders: true))
        model.updateNodeTransforms()
        try model.initializeSpringBoneGPUSystem(device: device)
        let system = try SpringBoneComputeSystem(device: device)
        try system.populateSpringBoneData(model: model)
        return (model, system)
    }

    /// A foreign sphere overlapping a hair joint must push it (foreign colliders
    /// actually collide once injected).
    @MainActor func testInjectedForeignSpherePushesBones() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let (model, system) = try await loadedSystem(device)
        // Settle a few frames with no foreign colliders.
        for _ in 0..<10 {
            system.setForeignColliders(ForeignColliderSnapshot())
            system.update(model: model, deltaTime: 1.0 / 60.0, commandBuffer: nil)
            system.waitForPendingFrame()
        }
        let settled = model.springBoneBuffers?.getCurrentPositions() ?? []
        // Inject a large foreign sphere at the avatar's centroid so many joints
        // overlap it; run more frames.
        let centroid = settled.reduce(SIMD3<Float>(0,0,0), +) / Float(max(settled.count, 1))
        let big = SphereCollider(center: centroid, radius: 0.5, groupIndex: 0)
        for _ in 0..<20 {
            system.setForeignColliders(ForeignColliderSnapshot(spheres: [big], capsules: []))
            system.update(model: model, deltaTime: 1.0 / 60.0, commandBuffer: nil)
            system.waitForPendingFrame()
        }
        let pushed = model.springBoneBuffers?.getCurrentPositions() ?? []
        var moved = false
        for i in settled.indices where i < pushed.count {
            if simd_distance(settled[i], pushed[i]) > 1e-3 { moved = true; break }
        }
        XCTAssertTrue(moved, "at least one joint must be pushed by the injected foreign sphere")
    }

    /// Replace-or-clear: after clearing, the tail must hold zero active foreign
    /// (a departed partner leaves no ghost collider). Design §4.1.
    @MainActor func testClearLeavesZeroActiveForeign() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let (model, system) = try await loadedSystem(device)
        let s = SphereCollider(center: .zero, radius: 0.3, groupIndex: 0)
        system.setForeignColliders(ForeignColliderSnapshot(spheres: [s], capsules: []))
        system.update(model: model, deltaTime: 1.0 / 60.0, commandBuffer: nil)
        system.waitForPendingFrame()
        XCTAssertEqual(system.activeForeignSpheres, 1)
        // Clear (empty snapshot) — must zero the active count, not keep the last.
        system.setForeignColliders(ForeignColliderSnapshot())
        system.update(model: model, deltaTime: 1.0 / 60.0, commandBuffer: nil)
        system.waitForPendingFrame()
        XCTAssertEqual(system.activeForeignSpheres, 0)
    }

    /// Over-capacity injection is clamped, not silently dropped without notice.
    @MainActor func testOverCapacityClampsToReservedSlots() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let (model, system) = try await loadedSystem(device)
        let cap = VRMConstants.Physics.maxContactPartners * VRMConstants.Physics.foreignSphereSlotsPerPartner
        let many = (0..<(cap + 5)).map { _ in SphereCollider(center: .zero, radius: 0.1, groupIndex: 0) }
        system.setForeignColliders(ForeignColliderSnapshot(spheres: many, capsules: []))
        system.update(model: model, deltaTime: 1.0 / 60.0, commandBuffer: nil)
        system.waitForPendingFrame()
        XCTAssertEqual(system.activeForeignSpheres, cap, "clamped to reserved sphere slots")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SpringBoneForeignSinkTests --disable-sandbox`
Expected: FAIL — `setForeignColliders` unknown.

- [ ] **Step 3: Add the sink storage + method**

In `Sources/VRMMetalKit/SpringBoneComputeSystem.swift`, add storage near `activeForeignSpheres` (Task 4):

```swift
    /// This frame's foreign colliders, set by the coordinator each frame. The
    /// replace-or-clear contract is total over frames: every frame either
    /// replaces (non-empty) or clears (empty). Never accumulates (design §4.1).
    private var pendingForeignSnapshot: ForeignColliderSnapshot = ForeignColliderSnapshot()
```

Add the public setter and the tail writer:

```swift
    /// Sets this frame's foreign colliders. Replace-or-clear: pass an empty
    /// snapshot to clear (a departed partner leaves no ghost). Clamps to the
    /// reserved tail capacity and logs any drop — never silently truncates
    /// (design §4.1, §6).
    func setForeignColliders(_ snapshot: ForeignColliderSnapshot) {
        pendingForeignSnapshot = snapshot
    }

    /// Writes the pending foreign set into the reserved buffer tail ONCE per
    /// frame, tagged with the reserved foreign group index, and sets the active
    /// counts. Called before the substep loop; `interpolateColliders` only ever
    /// rewrites the [0, active) prefix, so the tail persists across the frame's
    /// substeps (design §4.2).
    private func writeForeignTail(buffers: SpringBoneBuffers) {
        let sphereRoom = max(buffers.sphereCapacity - buffers.numSpheres, 0)
        let capsuleRoom = max(buffers.capsuleCapacity - buffers.numCapsules, 0)

        var spheres = pendingForeignSnapshot.spheres
        var capsules = pendingForeignSnapshot.capsules
        if spheres.count > sphereRoom {
            vrmLogPhysics("⚠️ [SpringBone] Foreign spheres \(spheres.count) exceed reserved tail \(sphereRoom); dropping \(spheres.count - sphereRoom).")
            spheres = Array(spheres.prefix(sphereRoom))
        }
        if capsules.count > capsuleRoom {
            vrmLogPhysics("⚠️ [SpringBone] Foreign capsules \(capsules.count) exceed reserved tail \(capsuleRoom); dropping \(capsules.count - capsuleRoom).")
            capsules = Array(capsules.prefix(capsuleRoom))
        }

        if let buf = buffers.sphereColliders, !spheres.isEmpty {
            let ptr = buf.contents().bindMemory(to: SphereCollider.self, capacity: buffers.sphereCapacity)
            for (i, s) in spheres.enumerated() {
                ptr[buffers.numSpheres + i] = SphereCollider(center: s.center, radius: s.radius,
                                                             groupIndex: foreignColliderGroupIndex,
                                                             inside: s.inside != 0)
            }
        }
        if let buf = buffers.capsuleColliders, !capsules.isEmpty {
            let ptr = buf.contents().bindMemory(to: CapsuleCollider.self, capacity: buffers.capsuleCapacity)
            for (i, c) in capsules.enumerated() {
                ptr[buffers.numCapsules + i] = CapsuleCollider(p0: c.p0, p1: c.p1, radius: c.radius,
                                                              groupIndex: foreignColliderGroupIndex,
                                                              inside: c.inside != 0)
            }
        }
        activeForeignSpheres = spheres.count
        activeForeignCapsules = capsules.count
    }
```

- [ ] **Step 4: Call `writeForeignTail` once per frame**

In `update(...)`, before the substep `while` loop begins (after the sleep-gate block, right before `var stepsThisFrame = 0` at line ~450), add:

```swift
        // Write this frame's foreign colliders into the reserved tail once. The
        // tail persists across substeps (interpolate only rewrites the prefix).
        writeForeignTail(buffers: buffers)
```

- [ ] **Step 5: Run the sink tests**

Run: `swift test --filter SpringBoneForeignSinkTests --disable-sandbox`
Expected: PASS — inject pushes, clear zeroes, over-capacity clamps.

- [ ] **Step 6: Re-run the capacity non-interference test**

Run: `swift test --filter SpringBoneForeignCapacityTests --disable-sandbox`
Expected: PASS — still bit-identical (the sink writes nothing when the snapshot is empty, and `writeForeignTail` sets active counts to 0).

- [ ] **Step 7: Commit**

```bash
git add Sources/VRMMetalKit/SpringBoneComputeSystem.swift \
        Tests/VRMMetalKitTests/SpringBone/SpringBoneForeignSinkTests.swift
git commit -m "feat(springbone): foreign-collider injection sink (once-per-frame, replace-or-clear)"
```

---

### Task 6: `SpringBoneContactGroup` coordinator + `exchange()`

The thin coordinator: owns membership + ordering, holds no per-model sim state. `exchange()` snapshots each participant (Task 3), unions minus self, and injects (Task 5) — the two-pass, one-frame-lagged (b) exchange with the multi-renderer all-commits precondition (§3) and the loud interpolation-off precondition (§4.3).

**Files:**
- Create: `Sources/VRMMetalKit/SpringBoneContactGroup.swift`
- Test: `Tests/VRMMetalKitTests/SpringBone/SpringBoneContactGroupTests.swift`

**Interfaces:**
- Consumes: `SpringBoneComputeSystem.contactColliderSnapshot` (Task 3), `.setForeignColliders` (Task 5); `ForeignColliderSnapshot`.
- Produces:
  - `public final class SpringBoneContactGroup` with:
    - `func add(system: SpringBoneComputeSystem, model: VRMModel)`
    - `func remove(system: SpringBoneComputeSystem)`
    - `func exchange()`

- [ ] **Step 1: Write the failing test**

Create `Tests/VRMMetalKitTests/SpringBone/SpringBoneContactGroupTests.swift` (Apache header):

```swift
import XCTest
import Metal
import simd
@testable import VRMMetalKit

final class SpringBoneContactGroupTests: XCTestCase {
    @MainActor private func participant(_ device: MTLDevice) async throws -> (VRMModel, SpringBoneComputeSystem) {
        let path = getTestVRM10ModelPath(); try requireFixture(path, hint: testVRM10Filename)
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device,
            options: VRMLoadingOptions(augmentSpringBoneColliders: true))
        model.updateNodeTransforms()
        try model.initializeSpringBoneGPUSystem(device: device)
        let system = try SpringBoneComputeSystem(device: device)
        try system.populateSpringBoneData(model: model)
        return (model, system)
    }

    /// §8.1 full form: a participant with an EMPTY partner set (present-but-empty
    /// foreign) is bit-identical to a non-participant (foreign absent).
    @MainActor func testEmptyGroupIsBitIdenticalToNonParticipant() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        func run(inGroup: Bool) async throws -> [SIMD3<Float>] {
            let (model, system) = try await participant(device)
            let group = SpringBoneContactGroup()
            if inGroup { group.add(system: system, model: model) }  // alone => union-minus-self is empty
            for _ in 0..<30 {
                if inGroup { group.exchange() }
                system.update(model: model, deltaTime: 1.0 / 60.0, commandBuffer: nil)
                system.waitForPendingFrame()
            }
            return model.springBoneBuffers?.getCurrentPositions() ?? []
        }
        let solo = try await run(inGroup: false)
        let grouped = try await run(inGroup: true)
        XCTAssertEqual(solo.count, grouped.count)
        for i in solo.indices { XCTAssertEqual(solo[i], grouped[i], "empty group must not perturb bone \(i)") }
    }

    /// Two participants: each yields to the other's body (mutual). Assert at
    /// least one avatar's joints move relative to a solo run.
    @MainActor func testTwoParticipantsYieldToEachOther() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let (modelA, sysA) = try await participant(device)
        let (modelB, sysB) = try await participant(device)
        // Overlap the avatars: translate B onto A so their bodies intersect.
        modelB.rootNode?.localPosition = SIMD3<Float>(0.1, 0, 0)
        modelB.updateNodeTransforms()

        // Solo baseline for A (no partner).
        let (modelASolo, sysASolo) = try await participant(device)
        for _ in 0..<30 {
            sysASolo.update(model: modelASolo, deltaTime: 1.0 / 60.0, commandBuffer: nil)
            sysASolo.waitForPendingFrame()
        }
        let aSolo = modelASolo.springBoneBuffers?.getCurrentPositions() ?? []

        let group = SpringBoneContactGroup()
        group.add(system: sysA, model: modelA)
        group.add(system: sysB, model: modelB)
        for _ in 0..<30 {
            group.exchange()
            sysA.update(model: modelA, deltaTime: 1.0 / 60.0, commandBuffer: nil)
            sysA.waitForPendingFrame()
            sysB.update(model: modelB, deltaTime: 1.0 / 60.0, commandBuffer: nil)
            sysB.waitForPendingFrame()
        }
        let aGrouped = modelA.springBoneBuffers?.getCurrentPositions() ?? []
        var moved = false
        for i in aSolo.indices where i < aGrouped.count {
            if simd_distance(aSolo[i], aGrouped[i]) > 1e-3 { moved = true; break }
        }
        XCTAssertTrue(moved, "A's joints must react to B's body colliders")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SpringBoneContactGroupTests --disable-sandbox`
Expected: FAIL — `cannot find 'SpringBoneContactGroup' in scope`.

- [ ] **Step 3: Create the coordinator**

Create `Sources/VRMMetalKit/SpringBoneContactGroup.swift` (Apache header). It holds only membership (coordination state) — no interpolation mirror, no bone positions (§2.1 review gate):

```swift
import Foundation
import simd

/// Coordinates cross-avatar spring-bone contact across independently-stateful
/// `SpringBoneComputeSystem`s (design §2.1, §3). Owns ONLY membership and the
/// snapshot->inject ordering; holds NO per-model simulation state. Each system
/// remains the sole owner of its own mirror.
///
/// Usage per frame (option (b), one-frame-lagged): after ALL participants'
/// last-frame render commits, call `exchange()` once, then run each
/// participant's `update()`/render as usual.
public final class SpringBoneContactGroup {
    private struct Member {
        let system: SpringBoneComputeSystem
        let model: VRMModel
    }
    private var members: [Member] = []

    public init() {}

    /// Adds a participant. Fails loudly if the participant cannot support
    /// cross-avatar contact (interpolation off), rather than silently yielding
    /// to no one (design §4.3).
    public func add(system: SpringBoneComputeSystem, model: VRMModel) {
        if !VRMConstants.Physics.enableRootInterpolation {
            assertionFailure("SpringBoneContactGroup requires enableRootInterpolation == true; v1 foreign injection hooks only the interpolation path (design §4.3).")
            vrmLogPhysics("❌ [SpringBoneContactGroup] enableRootInterpolation is off; participant will not receive cross-avatar contact.")
        }
        members.append(Member(system: system, model: model))
    }

    public func remove(system: SpringBoneComputeSystem) {
        members.removeAll { $0.system === system }
    }

    /// Phase 1 (snapshot all) + Phase 2 (inject union-minus-self). Precondition
    /// (design §3.2): call after ALL participants' node transforms are in their
    /// last-frame-committed state — the caller sequences this after every
    /// participant's render commit, not merely after "a" commit.
    public func exchange() {
        // Phase 1: pure snapshots, no integrate, no mirror mutation.
        let snapshots = members.map { $0.system.contactColliderSnapshot(model: $0.model) }
        // Phase 2: union-minus-self per participant, then inject (replace-or-clear).
        for (i, member) in members.enumerated() {
            var spheres: [SphereCollider] = []
            var capsules: [CapsuleCollider] = []
            for (j, snap) in snapshots.enumerated() where j != i {
                spheres.append(contentsOf: snap.spheres)
                capsules.append(contentsOf: snap.capsules)
            }
            member.system.setForeignColliders(ForeignColliderSnapshot(spheres: spheres, capsules: capsules))
        }
    }
}
```

- [ ] **Step 4: Run the coordinator tests**

Run: `swift test --filter SpringBoneContactGroupTests --disable-sandbox`
Expected: PASS — empty group bit-identical; two participants react.

(If `modelB.rootNode?.localPosition` or `model.rootNode` is not the correct API for moving a model, adjust to the project's node-translation API — grep `rootNode`/`localPosition` in `Core/VRMModel.swift`; the test's intent is only to overlap the two avatars so their contact sets intersect.)

- [ ] **Step 5: Run the whole spring-bone suite**

Run: `swift test --filter SpringBone --disable-sandbox`
Expected: PASS across all spring-bone tests (no regression; foreign path is opt-in via a contact group).

- [ ] **Step 6: Build release to catch config-specific issues**

Run: `swift build --configuration release`
Expected: builds clean.

- [ ] **Step 7: Commit**

```bash
git add Sources/VRMMetalKit/SpringBoneContactGroup.swift \
        Tests/VRMMetalKitTests/SpringBone/SpringBoneContactGroupTests.swift
git commit -m "feat(springbone): SpringBoneContactGroup coordinator + one-frame-lagged exchange()"
```

---

## Deferred (not in this plan — design §9)

- **Convergence rungs 2 & 3** (option (a) animation-lift, then lockstep): built only if the hug spike shows the one-frame lag or the anti-phase limit cycle. Drag/compliance tuning is tried *before* rung 3.
- **Authored-collider inclusion** in the contact set (Option 3 union): fidelity refinement, gated on variable-count tail sizing and double-surface handling.
- **Per-partner response differentiation**: needs a kernel change (per-collider push strength); out of scope.
- **Torso capsule visual calibration**: `SpringBoneContactColliderSet.torsoRadiusFractionOfLength` is seeded at `0.5` and is the hug spike's tuning target (§5.3) — a visual pass, not a code task.
- **Production reservation wiring**: `VRMModel.springBoneForeignReservationEnabledForTesting` defaults `true`; when contact groups are wired into the app/render loop, replace this test hook with unconditional reservation (or a `VRMLoadingOptions` flag) so production always reserves the tail.

## Self-Review

**Spec coverage:**
- §2.1 coordinator (membership+ordering, no sim-state) → Task 6. ✓
- §2.2 pure snapshot + injection sink → Task 3, Task 5. ✓
- §2.3 shared generator / independent trigger → Task 1 (extract), Task 2 (second caller). ✓
- §3 (b) one-frame-lagged exchange, all-commits precondition → Task 6 (`exchange()` doc + test sequences commits). ✓
- §4.1 replace-or-clear → Task 5 (`testClearLeavesZeroActiveForeign`). ✓
- §4.2 three-quantity separation, once-per-frame tail write → Task 4 (capacity/active count), Task 5 (`writeForeignTail`). ✓
- §4.3 loud interpolation-off precondition → Task 6 (`add()` assert). ✓
- §5 skeleton-derived contact set + torso capsule → Task 2. ✓
- §6 capacity constant N + clamp-and-log → Task 4 (constants), Task 5 (clamp + `vrmLogPhysics`). ✓
- §7 single foreign bit, distinct from synthetic, all bones → Task 4 (populate). ✓
- §8.1 bit-identical non-interference → Task 4 (`testReservedTailZeroForeignIsBitIdentical`), Task 6 (`testEmptyGroupIsBitIdenticalToNonParticipant`). ✓
- §8.2 one-way/mutual, generator parity → Task 6 (`testTwoParticipantsYieldToEachOther`), Task 2 (`testHeadGeometryMatchesAugmentor`). ✓
- §8.3 torso as tuning line item → Deferred section + Task 2 constant doc. ✓
- §8.4 determinism path, not the flaky guard → Global Constraints + all tests use `commandBuffer: nil` + `waitForPendingFrame`. ✓

**Placeholder scan:** no TBD/TODO; every step has complete code or an exact command. The one conditional ("if the mask variable has a different name at that site") is an instruction to match an existing symbol, not a placeholder — the change is fully specified.

**Type consistency:** `ForeignColliderSnapshot` (spheres/capsules) is defined in Task 3 and consumed identically in Tasks 5, 6. `foreignColliderGroupIndex`, `activeForeignSpheres/Capsules`, `sphereCapacity`/`capsuleCapacity` defined in Task 4, consumed in Task 5. `contactColliderSnapshot`/`setForeignColliders`/`exchange` names consistent across tasks. `SpringBoneBoneGeometry` primitives defined in Task 1, consumed in Tasks 2 & 3.
