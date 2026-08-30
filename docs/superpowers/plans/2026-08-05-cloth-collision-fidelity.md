# Cloth-Collision Fidelity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An opt-in loading mode, `fitClothCollisionToMesh` (default `false`), that floors each spring joint's collision radius at the measured half-extent of the mesh skinned to it **and** collides the segment between chain joints — so hair stops passing through arms and hands stop sinking into dresses.

**Architecture:** (A) a load-time measurement utility computes `effectiveHitRadius` per joint (authored never mutated; floored, ceiling-capped, root→leaf inheritance for sparse joints); the single sim consumption point switches to the effective value. (B) three **new** Metal kernels collide the parent→child segment against sphere/capsule/plane colliders, reading the parent endpoint from an **immutable per-substep snapshot**; the three existing collide kernels are textually untouched, which is what lets the bit-exact flag-off baseline survive the metallib recompile. Gates per spec §6, every one with a sabotage observed failing.

**Tech Stack:** Swift 6.2, Metal (MSL via `make shaders`), XCTest. Spec: `docs/superpowers/specs/2026-08-05-cloth-collision-fidelity-design.md`.

## Global Constraints

- Swift 6.2; targets macOS 26+, iOS 26+. New source files carry the 15-line Apache 2.0 header verbatim from `Sources/VRMMetalKit/Animation/CaptureStepController.swift:1-15`.
- Tests run with `--disable-sandbox`. Full suite: `swift test --disable-sandbox --skip HairHeadCollisionTests`. Metal-requiring tests `throw XCTSkip("No Metal device")`.
- Pre-existing failures, not yours: `SpringBoneStressPosePenetrationTests.testLookUp_augmented_noForeheadPenetration` is FIXED on this branch (must stay green); `BalanceModelTests.testEvaluate_isReadOnlyAndDeterministic` flakes under parallel load; `HairHeadCollisionTests` SIGTRAPs under parallel load (passes in isolation).
- **This plan modifies `Sources/`** — unlike SP1. The flag-off path must stay identical at each gate's certified strength (spec §6.1): exact effective values, bit-exact GPU baseline, ≤ 1 mm CSV envelope (`SpringBoneRegressionTests.swift:70`).
- `.metal` edits require `make shaders`; the regenerated `Sources/VRMMetalKit/Resources/VRMMetalKitShaders*.metallib` files commit **in the same commit** as the kernel change. `SpringBoneParams` is defined in BOTH `SpringBoneCollision.metal:44` and `SpringBoneDistance.metal:21` (and possibly others — grep before editing); every copy and the Swift mirror (`SpringBoneBuffers.swift:539` area, the struct containing `settlingFrames`) must change identically or buffer layouts silently skew.
- Fixture resolution must be **bundle-first** (`Bundle.module` resource, source-tree fallback) — Xcode Cloud runs the test bundle without the checkout (SP1's hard-won lesson). New fixtures go under `Tests/VRMMetalKitTests/Fixtures/` which `Package.swift` already `.copy`s.
- **Every gate must be observed failing before it is trusted.** Report both the sabotaged and restored runs verbatim. This branch produced four consecutive tasks whose gates were caught vacuous only by this rule.
- Commit after each task. Do NOT push (pushes trigger Xcode Cloud; the user pushes on request).
- No temporary contextual/informational comments in code; doc comments stating constraints are expected and match the density of `SpringBoneColliderAugmentor.swift`.

---

## File Structure

**Create:**
- `Sources/VRMMetalKit/SpringBoneJointRadiusMeasure.swift` — measurement utility: per-joint mesh half-extent, effective-radius table.
- `Sources/VRMMetalKit/Shaders/SpringBoneSegmentCollision.metal` — snapshot-copy kernel + three segment collide kernels (existing kernels untouched).
- `Tests/VRMMetalKitTests/SpringBone/ClothJointRadiusAuditTests.swift` — the audit table + invariants (spec slice 2 guard).
- `Tests/VRMMetalKitTests/SpringBone/SpringBoneBitBaselineTests.swift` — 6.1(ii) bit-exact GPU baseline, capture + compare.
- `Tests/VRMMetalKitTests/SpringBone/SegmentCollisionGapTests.swift` — 6.2 two-joint-gap discriminator + settling.
- `Tests/VRMMetalKitTests/Fixtures/SpringBitBaseline/` — committed baseline (generated in Task 3, before any kernel change).

**Modify:**
- `Sources/VRMMetalKit/Core/VRMLoadingOptions.swift:268` area — add `fitClothCollisionToMesh: Bool = false`.
- `Sources/VRMMetalKit/Core/VRMTypes.swift:809-833` — `VRMSpringJoint` gains `effectiveHitRadius: Float?`.
- `Sources/VRMMetalKit/Core/VRMModel.swift:555-556, 1177+` — thread the flag into `initializeSpringBoneGPUSystem`, store it, invoke measurement in the #377 slot.
- `Sources/VRMMetalKit/SpringBoneComputeSystem.swift:1487` — consumption point → effective; plus snapshot buffer, params field, segment dispatches.
- `Sources/VRMMetalKit/SpringBoneBuffers.swift` — Swift `SpringBoneParams` mirror + snapshot buffer allocation.
- `Sources/VRMMetalKit/Shaders/SpringBoneCollision.metal:44-57` and `SpringBoneDistance.metal:21+` — `segmentCollision` field appended to `SpringBoneParams` (layout-only; kernel bodies untouched).
- `.gitignore`, `LICENSE-MODELS.md` — bundle `AvatarSample_M_1.0.vrm`.
- `Tests/VRMMetalKitTests/SpringBone/BodySurfacePredicateTests.swift` — pin M's inventory.
- `Tests/VRMMetalKitTests/SpringBone/SkinMeshCoverageTests.swift` — 6.3 improvement gate.
- `CLAUDE.md` §4 CCD sentence, `docs/SpringBonePhysicsGuide.md` — Task 7.

---

### Task 1: Bundle AvatarSample_M and pin its predicate inventory

**Files:**
- Modify: `.gitignore` (lines 21-23, beside the A/U allowlist entries)
- Modify: `LICENSE-MODELS.md`
- Add (binary): `AvatarSample_M_1.0.vrm` (already at repo root, untracked, 20 MB — A is 18 MB tracked, precedented)
- Modify: `Tests/VRMMetalKitTests/SpringBone/BodySurfacePredicateTests.swift`

**Interfaces:**
- Consumes: `BodySurfacePredicate.inventory(model:)`, `assertPinnedInventory` pattern already in that test file (SP1).
- Produces: `getTestModelPath("AvatarSample_M_1.0.vrm")` resolves on a fresh checkout; M's pinned included/excluded material sets, used by Tasks 5–6.

- [ ] **Step 1: Verify the licence from the file, and require it**

```bash
python3 - <<'EOF'
import json, struct
d = open("AvatarSample_M_1.0.vrm", "rb").read()
n = struct.unpack('<I', d[12:16])[0]
m = json.loads(d[20:20+n].decode('utf-8', errors='ignore'))['extensions']['VRMC_vrm']['meta']
for k in ['name','avatarPermission','allowRedistribution','modification','commercialUsage','licenseUrl']:
    print(k, '=', m.get(k))
EOF
```
Required to proceed: `allowRedistribution = True`, `avatarPermission = everyone`, `modification = allowModificationRedistribution`. Anything else → STOP, report BLOCKED, do not bundle.

- [ ] **Step 2: Allowlist and licence entry**

Add `!/AvatarSample_M_1.0.vrm` beside the existing A/U entries in `.gitignore`. Add a `LICENSE-MODELS.md` entry mirroring the AvatarSample_U entry's exact structure with M's own verified values.

- [ ] **Step 3: Write the failing inventory test**

In `BodySurfacePredicateTests.swift`, add a test following the existing pinned-inventory pattern for A and U exactly (read theirs first — same helper, same assertion shape):

```swift
    /// AvatarSample_M is the coverage fixture for cloth-collision fidelity: the
    /// only redistributable rig with a wide dress at hand height (Skirt ×24).
    @MainActor func testInventoryExactSetIsPinnedForAvatarSampleM() async throws {
        let model = try await load("AvatarSample_M_1.0.vrm")
        let inv = BodySurfacePredicate.inventory(model: model)
        assertPinnedInventory(inv, model: model, label: "AvatarSample_M",
            expectedIncluded: [
                // Fill from the FIRST run's printed output — the two SKIN
                // primitives (Face/Body "(Instance)" names) with their real
                // vertex counts. Pin what the model reports; never invent.
            ],
            expectedExcludedNames: [
                // Every other material name, from the same printed output.
            ])
    }
```

The empty arrays are the *mechanism*, not a placeholder: run once, the assertion fails printing the actual sets, pin the printed values, run again green. That is the same procedure the A/U pins used. (If `assertPinnedInventory`'s real signature differs, match it — read the file, do not guess.)

- [ ] **Step 4: Run to verify it fails, pin, verify it passes**

Run: `swift test --filter BodySurfacePredicateTests --disable-sandbox`
Expected: the new test FAILS printing M's sets (expect exactly two included: `N00_000_00_Face_00_SKIN (Instance)`, `N00_000_00_Body_00_SKIN (Instance)`). Pin them. Re-run: PASS, and the A/U pins untouched.

- [ ] **Step 5: Prove U still resolves (landing-order dependency)**

Run: `swift test --filter "SpringBoneStressPosePenetrationTests/testU_legMarch_augmented_noPenetration" --disable-sandbox`
Expected: PASS, not skip — U was bundled in SP1 commit `28f9a5b` (local); a skip here means the landing-order dependency in the spec is broken and this is BLOCKED, not workaroundable.

- [ ] **Step 6: Commit**

```bash
git add .gitignore LICENSE-MODELS.md AvatarSample_M_1.0.vrm Tests/VRMMetalKitTests/SpringBone/BodySurfacePredicateTests.swift
git commit -m "test(fixtures): bundle AvatarSample_M, the wide-dress coverage fixture

Licence verified from the file (allowRedistribution=true, everyone,
allowModificationRedistribution). Predicate inventory pinned: two SKIN
primitives in, all garments out."
```

---

### Task 2: `SpringBoneJointRadiusMeasure` + audit guard

Pure measurement — no flag, no plumbing, no sim change. The utility is called directly by the test on a loaded model, so its maths is reviewable before anything consumes it.

**Files:**
- Create: `Sources/VRMMetalKit/SpringBoneJointRadiusMeasure.swift`
- Test: `Tests/VRMMetalKitTests/SpringBone/ClothJointRadiusAuditTests.swift`

**Interfaces:**
- Consumes: `VRMModel` (`meshes`, `skins`, `nodes`, `springBone?.springs`), `VRMVertex` (`position`, `joints: SIMD4<UInt32>`, `weights: SIMD4<Float>`), `VRMSkin` (`joints: [VRMNode]`, `inverseBindMatrices`), `VRMPrimitive` (`vertexBuffer`, `vertexCount`), `VRMNode` (`mesh: Int?`, `skin: Int?`, `worldMatrix`, `worldPosition`).
- Produces (Tasks 3–6 rely on these exact signatures):
  - `public struct JointRadiusMeasurement { public let springIndex: Int; public let jointIndex: Int; public let node: Int; public let authored: Float; public let measured: Float?; public let dominantVertexCount: Int; public let ceiling: Float; public let effective: Float }`
  - `public enum SpringBoneJointRadiusMeasure { public static func measure(model: VRMModel, percentile: Float = 0.65) -> [JointRadiusMeasurement] }`

- [ ] **Step 1: Write the failing test**

Create `ClothJointRadiusAuditTests.swift` (Apache header first):

```swift
import XCTest
import Metal
import simd
@testable import VRMMetalKit

/// Audit guard for measured joint radii (spec §6, slice 2): pins the invariants
/// and per-chain aggregates so drift and sparse skinning are loud, and prints
/// the full per-joint table for the report. Mirrors ColliderDimensionAudit's
/// role on the collider side.
final class ClothJointRadiusAuditTests: XCTestCase {

    @MainActor private func load(_ filename: String) async throws -> VRMModel {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let path = getTestModelPath(filename)
        try requireFixture(path, hint: filename)
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device,
            options: VRMLoadingOptions(augmentSpringBoneColliders: false))
        model.updateNodeTransforms()
        return model
    }

    /// The invariants every measurement must satisfy, on every fixture:
    /// effective ∈ [authored, max(authored, ceiling)], ceiling formula honored,
    /// measured joints actually measured something.
    @MainActor func testInvariantsHoldOnAllFixtures() async throws {
        for f in ["AvatarSample_A_1.0.vrm.glb", "AvatarSample_U_1.0.vrm.glb", "AvatarSample_M_1.0.vrm"] {
            let model = try await load(f)
            let rows = SpringBoneJointRadiusMeasure.measure(model: model)
            XCTAssertFalse(rows.isEmpty, "\(f): no spring joints measured")
            for r in rows {
                XCTAssertGreaterThanOrEqual(r.effective, r.authored,
                    "\(f) spring \(r.springIndex) joint \(r.jointIndex): effective below authored — the floor must never reduce")
                XCTAssertLessThanOrEqual(r.effective, max(r.authored, r.ceiling) + 1e-6,
                    "\(f) spring \(r.springIndex) joint \(r.jointIndex): effective above ceiling")
                XCTAssertLessThanOrEqual(r.ceiling, 0.05 + 1e-6, "\(f): absolute cap violated")
                if let m = r.measured {
                    XCTAssertGreaterThan(m, 0, "\(f): a computed measurement must be positive")
                    XCTAssertGreaterThanOrEqual(r.dominantVertexCount, 0)
                }
                XCTAssertFalse(r.effective.isNaN)
            }
            print("[RADIUSAUDIT] \(f): \(rows.count) joints, "
                + "measured=\(rows.filter { $0.measured != nil && $0.dominantVertexCount >= 8 }.count), "
                + "inherited/sparse=\(rows.filter { $0.dominantVertexCount < 8 }.count)")
            for r in rows {
                print(String(format: "[RADIUSROW] %@ s%02d j%d node=%d auth=%.4f meas=%@ n=%d ceil=%.4f eff=%.4f",
                    f, r.springIndex, r.jointIndex, r.node, r.authored,
                    r.measured.map { String(format: "%.4f", $0) } ?? "-",
                    r.dominantVertexCount, r.ceiling, r.effective))
            }
        }
    }

    /// M's Hair chains are the evidence base (authored median 3.7mm for
    /// centimetre-wide cards): the measurement must raise them substantially.
    /// The bound is derived from the defect data, not chosen round: authored
    /// median is 0.0037; a floor that fails to at least triple it cannot close
    /// a gap the 18mm experiment showed needs ~15mm.
    @MainActor func testHairRadiiRiseOnAvatarSampleM() async throws {
        let model = try await load("AvatarSample_M_1.0.vrm")
        let rows = SpringBoneJointRadiusMeasure.measure(model: model)
        guard let sb = model.springBone else { return XCTFail("no springbone") }
        let hairRows = rows.filter { (sb.springs[$0.springIndex].name ?? "").contains("Hair") && $0.jointIndex > 0 }
        XCTAssertFalse(hairRows.isEmpty)
        let effs = hairRows.map(\.effective).sorted()
        let median = effs[effs.count / 2]
        XCTAssertGreaterThan(median, 0.0037 * 3,
            "measured hair median \(median) is not meaningfully above the authored 3.7mm — the measurement is not doing its job")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter ClothJointRadiusAuditTests --disable-sandbox`
Expected: FAIL to compile — `SpringBoneJointRadiusMeasure` does not exist.

- [ ] **Step 3: Implement the utility**

Create `Sources/VRMMetalKit/SpringBoneJointRadiusMeasure.swift` (Apache header first):

```swift
import Foundation
import Metal
import simd

/// One joint's measured collision extent, spec §3.
public struct JointRadiusMeasurement {
    public let springIndex: Int
    public let jointIndex: Int
    public let node: Int
    public let authored: Float
    /// Raw measured half-extent (pre-ceiling), nil when nothing was measurable
    /// anywhere up-chain.
    public let measured: Float?
    /// Vertices dominantly skinned to this joint's node. Below 8, the value is
    /// inherited from the nearest computed ancestor (spec §3) — recorded so
    /// sparse skinning is loud, not inferred.
    public let dominantVertexCount: Int
    public let ceiling: Float
    public let effective: Float
}

/// Measures each spring joint's collision half-extent from the mesh actually
/// skinned to it — the cloth's own geometry (hair cards, skirt panels), NOT the
/// body surface. `hitRadius` is a geometric proxy; VRoid routinely authors it
/// near zero (median 3.7 mm on AvatarSample_M's hair, some joints 0) for cards
/// centimetres wide. The effective value floors the proxy at the measured
/// extent without ever mutating the authored field (spec §2/§3).
public enum SpringBoneJointRadiusMeasure {

    public static func measure(model: VRMModel, percentile: Float = 0.65) -> [JointRadiusMeasurement] {
        guard let springBone = model.springBone else { return [] }

        // One pass over every skinned primitive: bucket world-space positions
        // of dominantly-skinned vertices by node index. All meshes participate —
        // hair and garment materials included; this measures the cloth itself.
        var vertsByNode: [Int: [SIMD3<Float>]] = [:]
        for (mi, mesh) in model.meshes.enumerated() {
            guard let node = model.nodes.first(where: { $0.mesh == mi }),
                  let skinIndex = node.skin, skinIndex >= 0, skinIndex < model.skins.count else { continue }
            let skin = model.skins[skinIndex]
            let palette = skin.joints.indices.map { skin.joints[$0].worldMatrix * skin.inverseBindMatrices[$0] }
            let slotToNode: [Int] = skin.joints.map { j in
                model.nodes.firstIndex(where: { $0 === j }) ?? -1
            }
            for primitive in mesh.primitives {
                guard let vb = primitive.vertexBuffer, primitive.vertexCount > 0 else { continue }
                let verts = vb.contents().bindMemory(to: VRMVertex.self, capacity: primitive.vertexCount)
                for vi in 0..<primitive.vertexCount {
                    let v = verts[vi]
                    let js = [Int(v.joints.x), Int(v.joints.y), Int(v.joints.z), Int(v.joints.w)]
                    let ws = [v.weights.x, v.weights.y, v.weights.z, v.weights.w]
                    var dom = -1; var domW: Float = 0
                    for k in 0..<4 where ws[k] > domW { domW = ws[k]; dom = js[k] }
                    guard domW > 0.5, dom >= 0, dom < palette.count else { continue }
                    let nodeIndex = slotToNode[dom]
                    guard nodeIndex >= 0 else { continue }
                    let h = palette[dom] * SIMD4<Float>(v.position, 1)
                    vertsByNode[nodeIndex, default: []].append(SIMD3<Float>(h.x, h.y, h.z))
                }
            }
        }

        var out: [JointRadiusMeasurement] = []
        for (si, spring) in springBone.springs.enumerated() {
            // Root→leaf: inheritance flows only from computed ancestors (spec §3).
            var lastMeasured: Float? = nil
            for (ji, joint) in spring.joints.enumerated() {
                guard joint.node >= 0, joint.node < model.nodes.count else { continue }
                let selfPos = model.nodes[joint.node].worldPosition
                // Axis: parent→self for chain joints; self→first-child for the
                // anchor (roots are measured too — their value feeds the first
                // span's segment radius, spec §3/§4).
                let otherPos: SIMD3<Float>
                if ji > 0 {
                    otherPos = model.nodes[spring.joints[ji - 1].node].worldPosition
                } else if spring.joints.count > 1 {
                    otherPos = model.nodes[spring.joints[1].node].worldPosition
                } else {
                    otherPos = selfPos
                }
                let segLen = simd_length(selfPos - otherPos)
                let ceiling = min(0.05, 0.75 * segLen)

                let verts = vertsByNode[joint.node] ?? []
                var measuredRaw: Float? = nil
                if verts.count >= 8, segLen > 1e-5 {
                    let a = ji > 0 ? otherPos : selfPos
                    let b = ji > 0 ? selfPos : otherPos
                    let axis = simd_normalize(b - a)
                    var perps: [Float] = []
                    perps.reserveCapacity(verts.count)
                    for p in verts {
                        let d = p - a
                        let t = simd_dot(d, axis)
                        guard t >= 0, t <= segLen else { continue }
                        perps.append(simd_length(d - t * axis))
                    }
                    if perps.count >= 8 {
                        perps.sort()
                        let idx = min(perps.count - 1, max(0, Int(Float(perps.count - 1) * percentile)))
                        measuredRaw = perps[idx]
                    }
                }
                if measuredRaw != nil { lastMeasured = measuredRaw }
                let inherited = measuredRaw ?? lastMeasured
                let effective = max(joint.hitRadius, min(inherited ?? joint.hitRadius, ceiling))
                out.append(JointRadiusMeasurement(
                    springIndex: si, jointIndex: ji, node: joint.node,
                    authored: joint.hitRadius, measured: inherited,
                    dominantVertexCount: verts.count,
                    ceiling: ceiling, effective: effective))
            }
        }
        return out
    }
}
```

- [ ] **Step 4: Run to verify it passes; record the tables**

Run: `swift test --filter ClothJointRadiusAuditTests --disable-sandbox`
Expected: PASS. Copy every `[RADIUSAUDIT]` and `[RADIUSROW]` line into your report — they are the evidence base for Tasks 5–6 and the calibration record.

- [ ] **Step 5: Sabotage — prove the invariants discriminate**

Temporarily change `let effective = max(...)` to `let effective = inherited ?? joint.hitRadius` (dropping the ceiling). Run. Expected: `testInvariantsHoldOnAllFixtures` FAILS on ceiling violations (at least on M's wide skirt panels). Restore, confirm green, report both runs. If nothing violates the ceiling under sabotage, say so — that would mean the ceiling never binds and its value needs re-examination, which is a finding, not a pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/VRMMetalKit/SpringBoneJointRadiusMeasure.swift Tests/VRMMetalKitTests/SpringBone/ClothJointRadiusAuditTests.swift
git commit -m "feat(springbone): measure joint collision radii from the skinned mesh

hitRadius is a geometric proxy VRoid authors near zero (median 3.7mm on
AvatarSample_M hair, for cards centimetres wide). Per joint: dominant-weight
verts, perpendicular extent about the chain axis at p65, floored at authored,
ceiling min(5cm, 0.75×span), root->leaf inheritance for sparse joints with
the dominant-vertex count recorded so sparsity is loud. Nothing consumes the
values yet; the audit test pins the invariants on A, U and M."
```

---

### Task 3: Flag, plumbing, unit identity, and the bit-exact baseline — BEFORE any kernel change

**Files:**
- Modify: `Sources/VRMMetalKit/Core/VRMLoadingOptions.swift` (init parameter list around `:268`)
- Modify: `Sources/VRMMetalKit/Core/VRMTypes.swift` (`VRMSpringJoint`, after `angleLimit` ~`:827`)
- Modify: `Sources/VRMMetalKit/Core/VRMModel.swift` (`:555-556` option threading; `initializeSpringBoneGPUSystem` `:1177+`)
- Modify: `Sources/VRMMetalKit/SpringBoneComputeSystem.swift:1487` (consumption point)
- Test: `Tests/VRMMetalKitTests/SpringBone/SpringBoneBitBaselineTests.swift` (+ committed fixture under `Tests/VRMMetalKitTests/Fixtures/SpringBitBaseline/`)

**Interfaces:**
- Consumes: `SpringBoneJointRadiusMeasure.measure(model:percentile:)` (Task 2).
- Produces: `VRMLoadingOptions.fitClothCollisionToMesh: Bool = false`; `VRMSpringJoint.effectiveHitRadius: Float?`; `VRMModel.fitClothCollisionToMesh: Bool` (read by Task 4's dispatch gating); the committed bit-baseline fixture Task 4 must keep green.

- [ ] **Step 1: Write the failing identity + baseline tests**

Create `SpringBoneBitBaselineTests.swift` (Apache header first):

```swift
import XCTest
import Metal
import simd
@testable import VRMMetalKit

/// Spec §6.1: three-layer default-path identity. (i) exact CPU identity of
/// effective values; (ii) a bit-exact GPU spring baseline captured BEFORE any
/// kernel change — this, not the 1mm-envelope CSVs, certifies the recompiled
/// metallib. Serialization is Float.bitPattern text, the PipelineBaseline
/// discipline; regeneration is env-gated so a normal run cannot overwrite its
/// own oracle.
final class SpringBoneBitBaselineTests: XCTestCase {

    private static let frames = 90
    private static let fps: Float = 30

    @MainActor private func load(_ filename: String, fit: Bool) async throws -> VRMModel {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let path = getTestModelPath(filename)
        try requireFixture(path, hint: filename)
        var options = VRMLoadingOptions(augmentSpringBoneColliders: true)
        options.fitClothCollisionToMesh = fit
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device, options: options)
        model.updateNodeTransforms()
        return model
    }

    /// 6.1(i): flag off, effective == authored, every joint, three fixtures.
    @MainActor func testFlagOffEffectiveEqualsAuthored() async throws {
        for f in ["AvatarSample_A_1.0.vrm.glb", "AvatarSample_U_1.0.vrm.glb", "AvatarSample_M_1.0.vrm"] {
            let model = try await load(f, fit: false)
            guard let sb = model.springBone else { continue }
            for (si, spring) in sb.springs.enumerated() {
                for (ji, joint) in spring.joints.enumerated() {
                    XCTAssertEqual(joint.effectiveHitRadius ?? joint.hitRadius, joint.hitRadius,
                        "\(f) s\(si) j\(ji): flag off must leave effective == authored")
                }
            }
        }
    }

    /// Flag ON must actually change something (the discriminating direction —
    /// without this, (i) could pass with the plumbing dead).
    @MainActor func testFlagOnRaisesAtLeastOneJoint() async throws {
        let model = try await load("AvatarSample_M_1.0.vrm", fit: true)
        guard let sb = model.springBone else { return XCTFail("no springbone") }
        let raised = sb.springs.flatMap(\.joints).filter { ($0.effectiveHitRadius ?? $0.hitRadius) > $0.hitRadius + 1e-6 }
        XCTAssertGreaterThan(raised.count, 10,
            "flag on raised only \(raised.count) joints on M — plumbing is not wired")
    }

    // MARK: - 6.1(ii) bit-exact GPU baseline

    private func fixturePath() -> String {
        let name = "avatar_a_ultra_flagoff"
        if let root = Bundle.module.resourceURL {
            let bundled = root.appendingPathComponent("Fixtures/SpringBitBaseline/\(name).txt")
            if FileManager.default.fileExists(atPath: bundled.path) { return bundled.path }
        }
        return "\(getProjectRoot())/Tests/VRMMetalKitTests/Fixtures/SpringBitBaseline/\(name).txt"
    }

    private func sourceTreeFixturePath() -> String {
        "\(getProjectRoot())/Tests/VRMMetalKitTests/Fixtures/SpringBitBaseline/avatar_a_ultra_flagoff.txt"
    }

    /// Runs A flag-off through the renderer's synchronous spring path and
    /// serializes every spring-joint node worldPosition per frame as bit
    /// patterns. Mirror the offscreen loop in SpringBoneStressPosePenetration-
    /// Tests (renderer, synchronousSpringBone, drawOffscreenHeadless, commit,
    /// spin) — read that harness first and reuse its structure exactly.
    @MainActor private func captureSequence() async throws -> [String] {
        let model = try await load("AvatarSample_A_1.0.vrm.glb", fit: false)
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        var config = RendererConfig(); config.sampleCount = 1; config.strict = .off
        config.synchronousSpringBone = true
        let renderer = VRMRenderer(device: device, config: config)
        renderer.loadModel(model)
        renderer.enableSpringBone = true
        renderer.springBoneQuality = .ultra
        renderer.viewMatrix = matrix_identity_float4x4
        renderer.projectionMatrix = matrix_identity_float4x4
        let player = AnimationPlayer()
        player.load(StressPoseFactory.clip(.armsCrossed, duration: Float(Self.frames) / Self.fps))
        player.play()

        var jointNodes: [Int] = []
        if let sb = model.springBone {
            for spring in sb.springs { for (i, j) in spring.joints.enumerated() where i > 0 { jointNodes.append(j.node) } }
        }

        // [offscreen textures + queue: copy the exact descriptor/loop block from
        //  SpringBoneStressPosePenetrationTests.swift:123-176]
        var lines: [String] = []
        try await runOffscreenFrames(renderer: renderer, player: player, model: model,
                                     device: device, frames: Self.frames, fps: Self.fps) { _ in
            for n in jointNodes {
                let p = model.nodes[n].worldPosition
                lines.append("\(p.x.bitPattern) \(p.y.bitPattern) \(p.z.bitPattern)")
            }
        }
        return lines
    }

    /// Opt-in regeneration only — a normal run cannot overwrite the oracle.
    @MainActor func testGenerateBitBaseline() async throws {
        guard ProcessInfo.processInfo.environment["SPRING_BIT_BASELINE_GENERATE"] == "1" else {
            throw XCTSkip("generation is opt-in: SPRING_BIT_BASELINE_GENERATE=1")
        }
        let lines = try await captureSequence()
        let dir = (sourceTreeFixturePath() as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try lines.joined(separator: "\n").write(toFile: sourceTreeFixturePath(), atomically: true, encoding: .utf8)
    }

    @MainActor func testBitBaselineMatches() async throws {
        let path = fixturePath()
        guard FileManager.default.fileExists(atPath: path) else {
            return XCTFail("missing committed bit baseline at \(path) — generate with SPRING_BIT_BASELINE_GENERATE=1 BEFORE any kernel change")
        }
        let expected = try String(contentsOfFile: path, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        let actual = try await captureSequence()
        XCTAssertEqual(actual.count, expected.count, "sequence length changed")
        var firstDiff: Int? = nil
        for i in 0..<min(actual.count, expected.count) where actual[i] != expected[i] { firstDiff = i; break }
        XCTAssertNil(firstDiff, "bit divergence at sample \(firstDiff ?? -1) of \(expected.count)")
    }
}
```

`runOffscreenFrames` is a small local helper you extract from the `SpringBoneStressPosePenetrationTests` loop (texture descriptors, command buffer, `drawOffscreenHeadless`, completion spin, per-frame closure). Read that file and lift the real code — the comment marks where; do not invent a different loop, and do not leave the marker comment in the final file.

- [ ] **Step 2: Run to verify compile failure**

Run: `swift test --filter SpringBoneBitBaselineTests --disable-sandbox`
Expected: FAIL to compile — `fitClothCollisionToMesh` and `effectiveHitRadius` do not exist.

- [ ] **Step 3: Implement the plumbing**

1. `VRMLoadingOptions.swift`: add `public var fitClothCollisionToMesh: Bool = false` with a doc comment naming the spec and the #326 boundary (opt-in: VMK does not deviate from authored physics without host consent), and add `fitClothCollisionToMesh: Bool = false` to the memberwise `init` beside `augmentSpringBoneColliders` (`:268`).
2. `VRMTypes.swift`, `VRMSpringJoint` after `angleLimit`:

```swift
    /// Effective collision radius used by the simulator when
    /// `VRMLoadingOptions.fitClothCollisionToMesh` measured this joint at load.
    /// `nil` means "use the authored `hitRadius`". The authored value is never
    /// mutated (spec §2): this field sits beside it, inspectable.
    public var effectiveHitRadius: Float? = nil
```

3. `VRMModel.swift`: add `public private(set) var fitClothCollisionToMesh: Bool = false`. Thread the option: at `:555-556`, alongside `augmentColliders`, read `context?.options.fitClothCollisionToMesh ?? false` and pass it into `initializeSpringBoneGPUSystem(device:augmentColliders:fitClothCollisionToMesh:)` (new defaulted parameter, preserving the existing public signature's callers). Inside `initializeSpringBoneGPUSystem`, in the same block as the `:1193` augmentation (post-`loadResources`, vertex buffers live), when the flag is on:

```swift
        self.fitClothCollisionToMesh = fitClothCollisionToMesh
        if fitClothCollisionToMesh, let springBone = self.springBone {
            let rows = SpringBoneJointRadiusMeasure.measure(model: self)
            for r in rows where r.effective > springBone.springs[r.springIndex].joints[r.jointIndex].hitRadius {
                springBone.springs[r.springIndex].joints[r.jointIndex].effectiveHitRadius = r.effective
            }
        }
```

   (If `springBone`/`springs` are value-typed rather than class-typed, write back through `self.springBone` accordingly — read the actual declaration first and keep the write in the same structure `SpringBoneComputeSystem.populateSpringBoneData` reads. Verify by following `:1457`'s `for joint in spring.joints` loop to its source collection.)
4. `SpringBoneComputeSystem.swift:1487`: `radius: joint.hitRadius,` → `radius: joint.effectiveHitRadius ?? joint.hitRadius,`.

- [ ] **Step 4: Run the unit tests**

Run: `swift test --filter "SpringBoneBitBaselineTests/testFlagOffEffectiveEqualsAuthored|SpringBoneBitBaselineTests/testFlagOnRaisesAtLeastOneJoint" --disable-sandbox`
Expected: both PASS.

- [ ] **Step 5: Generate and commit the bit baseline — this is the last moment before kernel changes**

```bash
SPRING_BIT_BASELINE_GENERATE=1 swift test --filter testGenerateBitBaseline --disable-sandbox
swift test --filter testBitBaselineMatches --disable-sandbox   # must PASS against itself
```

- [ ] **Step 6: Sabotage 6.1**

Scratch-flip the default: `fitClothCollisionToMesh: Bool = true` in `VRMLoadingOptions`. Run `testBitBaselineMatches` and `swift test --filter SpringBoneRegressionTests --disable-sandbox`.
Expected: the bit gate FAILS (radii changed → trajectories diverge at bit level). Record whether the 1 mm-envelope CSVs also fail — **green CSVs here are the envelope working, not the sabotage failing**; but if the *bit gate* is also green, STOP: the sabotage is non-discriminating and must be replaced (per spec §6.1), report it. Restore the default, confirm both green.

- [ ] **Step 7: Run the regression + full suites**

Run: `swift test --filter "SpringBoneRegressionTests|ClothJointRadiusAuditTests" --disable-sandbox`, then the full suite.
Expected: green (flag defaults off; nothing changed for any existing caller).

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "feat(springbone): opt-in fitClothCollisionToMesh — measured radii wired, bit baseline captured

Flag defaults false; authored hitRadius never mutated (effectiveHitRadius
sits beside it, spec §2/#326 boundary). The single consumption point reads
effective ?? authored. 6.1(i) identity pinned on A/U/M; 6.1(ii) bit-exact
GPU baseline captured and committed BEFORE any kernel change — it, not the
1mm-envelope CSVs, certifies the upcoming metallib recompile. Sabotage
(default flipped) observed failing the bit gate."
```

---

### Task 4: Segment collision kernels + parent snapshot + determinism

The kernel work. **The three existing collide kernels stay textually untouched** — segment collision is three *new* kernels dispatched after them, plus a snapshot-copy kernel. That structure is what gives the flag-off bit gate its best chance across the metallib recompile.

**Files:**
- Create: `Sources/VRMMetalKit/Shaders/SpringBoneSegmentCollision.metal`
- Modify: `Sources/VRMMetalKit/Shaders/SpringBoneCollision.metal:44-57` and `Sources/VRMMetalKit/Shaders/SpringBoneDistance.metal:21+` (append `uint segmentCollision;` to `SpringBoneParams` in EVERY copy — grep `struct SpringBoneParams` across `Shaders/` first and list the hits in your report)
- Modify: `Sources/VRMMetalKit/SpringBoneBuffers.swift` (Swift `SpringBoneParams` mirror — the struct with `settlingFrames` at `:539` — add `public var segmentCollision: UInt32 = 0` in the same position as the Metal field; allocate `bonePosSnapshot` beside `bonePosCurr`/`bonePosPrev`)
- Modify: `Sources/VRMMetalKit/SpringBoneComputeSystem.swift` (pipeline creation `:324-352` pattern; encode site `:756+`; set `segmentCollision` from `model.fitClothCollisionToMesh`)
- Test: `Tests/VRMMetalKitTests/SpringBone/SegmentCollisionGapTests.swift`
- Regenerate: `Sources/VRMMetalKit/Resources/VRMMetalKitShaders*.metallib` via `make shaders` — **same commit**

**Interfaces:**
- Consumes: `effectiveHitRadius` plumbing (Task 3, via `BoneParams.radius`), `model.fitClothCollisionToMesh`.
- Produces: kernels `springBoneSnapshotPositions`, `springBoneCollideSegmentSpheres`, `springBoneCollideSegmentCapsules`, `springBoneCollideSegmentPlanes`; internal test hook `SpringBoneComputeSystem.segmentCollisionEnabledForTesting: Bool?` (nil = follow the model flag) used by Task 5's sabotage.

- [ ] **Step 1: Write the failing discriminator test (6.2)**

Create `SegmentCollisionGapTests.swift` (Apache header first). **Harness note:** read `Tests/VRMMetalKitTests/SpringBone/SpringBoneCollisionBehaviorTests.swift` first — if it builds a synthetic spring model, reuse that builder verbatim; only if no synthetic harness exists anywhere under `Tests/VRMMetalKitTests/SpringBone/` do you construct one, and then report NEEDS_CONTEXT before inventing model-construction requirements.

```swift
/// Spec §6.2 — the sphere-at-joint blind spot made into a fixture.
/// A two-joint chain hangs vertically; an authored sphere collider sits in the
/// INTER-JOINT GAP with clearance from both joints but overlapping the segment.
///
/// Case 1 (gap): flag-on, the child deflects; flag-off passes through — flag-off
/// IS the sabotage, and both outcomes are asserted.
/// Case 2 (at-joint): the collider centered on a joint. flag-on ≈ flag-off
/// within a tolerance DERIVED from the recorded flag-off contact depth, plus a
/// multi-frame settling assertion (no growing oscillation) — this is what
/// bounds the child-only correction's small-t overshoot; its named fallback is
/// the spec §4 t-scaled correction.
```

Concrete assertions to implement behind that doc comment:
- Case 1: after ≥ 60 settled frames, `distance(childPos, colliderCenter) ≥ colliderRadius + jointRadius − 1e-3` when flag-on; `< colliderRadius` when flag-off (it passed through).
- Case 2: record `flagOffDepth = colliderRadius + jointRadius − distance(...)` (the resting contact depth flag-off). Tolerance for |flagOn − flagOff| positional difference = `max(0.002, 0.25 × flagOffDepth)` — write that derivation into the assertion message. Settling: over the last 30 frames, `max(|pos[i] − pos[i−1]|)` must not exceed `2 ×` the same quantity over frames 30–60 (oscillation must not grow).

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter SegmentCollisionGapTests --disable-sandbox`
Expected: case 1 flag-on FAILS (no segment collision exists yet — the child passes through even with the flag on). That failing state is the pre-implementation record; report it.

- [ ] **Step 3: Implement the shader**

Create `SpringBoneSegmentCollision.metal`, `#include` the same headers/structs the existing collision file uses (check how `SpringBoneCollision.metal` gets `BoneParams`/`SpringBoneParams`/collider structs — if they are defined in-file, define a shared header or re-declare identically and say so in your report):

```metal
// Closest point on segment ab to point p (Ericson §5.1.2).
static inline float3 closestPtSegmentPoint(float3 a, float3 b, float3 p, thread float& t) {
    float3 ab = b - a;
    float denom = dot(ab, ab);
    t = denom > 1e-12f ? clamp(dot(p - a, ab) / denom, 0.0f, 1.0f) : 0.0f;
    return a + t * ab;
}

// Closest points between segments p1q1 and p2q2 (Ericson §5.1.9).
static inline void closestPtSegmentSegment(float3 p1, float3 q1, float3 p2, float3 q2,
                                           thread float3& c1, thread float3& c2) {
    float3 d1 = q1 - p1, d2 = q2 - p2, r = p1 - p2;
    float a = dot(d1, d1), e = dot(d2, d2), f = dot(d2, r);
    float s = 0.0f, t = 0.0f;
    if (a <= 1e-12f && e <= 1e-12f) { c1 = p1; c2 = p2; return; }
    if (a <= 1e-12f) { t = clamp(f / e, 0.0f, 1.0f); }
    else {
        float c = dot(d1, r);
        if (e <= 1e-12f) { s = clamp(-c / a, 0.0f, 1.0f); }
        else {
            float b = dot(d1, d2), denom = a * e - b * b;
            s = denom > 1e-12f ? clamp((b * f - c * e) / denom, 0.0f, 1.0f) : 0.0f;
            t = (b * s + f) / e;
            if (t < 0.0f)      { t = 0.0f; s = clamp(-c / a, 0.0f, 1.0f); }
            else if (t > 1.0f) { t = 1.0f; s = clamp((b - c) / a, 0.0f, 1.0f); }
        }
    }
    c1 = p1 + d1 * s; c2 = p2 + d2 * t;
}

// One thread per bone: copy positions into the immutable snapshot the segment
// kernels read for the PARENT endpoint. The collide kernels read AND write
// bonePosCurr[id] per thread; a live read of bonePosCurr[parentIndex] would be
// their first unsynchronized cross-thread read and run-to-run nondeterministic
// (spec §4). One snapshot per substep, after integration, before all collide
// dispatches; staleness across the phase is the chosen semantics.
kernel void springBoneSnapshotPositions(
    device const float3* bonePosCurr [[buffer(1)]],
    device float3* bonePosSnapshot   [[buffer(16)]],
    constant SpringBoneParams& globalParams [[buffer(3)]],
    uint id [[thread_position_in_grid]]
) {
    if (id >= globalParams.numBones) return;
    bonePosSnapshot[id] = bonePosCurr[id];
}

// Discrete segment push-out vs sphere colliders. Additive pass after the
// endpoint kernels; corrections stay single-writer (this thread writes only
// its own slot). No swept branch here — CCD scoping (CLAUDE.md §4) is the
// endpoint kernels' job and is untouched.
kernel void springBoneCollideSegmentSpheres(
    device float3* bonePosCurr [[buffer(1)]],
    constant BoneParams* boneParams [[buffer(2)]],
    constant SphereCollider* sphereColliders [[buffer(5)]],
    constant SpringBoneParams& globalParams [[buffer(3)]],
    device float3* bonePosPrev [[buffer(0)]],
    device const float3* bonePosSnapshot [[buffer(16)]],
    uint id [[thread_position_in_grid]]
) {
    if (id >= globalParams.numBones || globalParams.numSpheres == 0) return;
    if (globalParams.segmentCollision == 0) return;
    uint parent = boneParams[id].parentIndex;
    if (parent == 0xFFFFFFFFu) return;   // roots are kinematic

    float radius = max(boneParams[id].radius, boneParams[parent].radius);
    uint mask = boneParams[id].colliderGroupMask;
    float3 childPos = bonePosCurr[id];
    float3 parentPos = bonePosSnapshot[parent];
    float3 oldPos = childPos;

    for (uint i = 0; i < globalParams.numSpheres; i++) {
        if ((sphereColliders[i].groupMask & mask) == 0) continue;
        if (sphereColliders[i].inside != 0) continue;   // containment: endpoint semantics only (spec)
        float t;
        float3 c = closestPtSegmentPoint(parentPos, childPos, sphereColliders[i].center, t);
        float3 delta = c - sphereColliders[i].center;
        float dist = length(delta);
        float minDist = sphereColliders[i].radius + radius;
        if (dist < minDist && dist > 1e-9f) {
            // Full correction to the child (spec §4); parent-side coverage
            // comes from the parent's own segment.
            float3 push = (delta / dist) * (minDist - dist);
            childPos += push;
        }
    }
    if (any(childPos != oldPos)) {
        bonePosCurr[id] = childPos;
        float3 prevPos = bonePosPrev[id];
        applyVelocityCorrection(prevPos, childPos, oldPos);
        bonePosPrev[id] = prevPos;
    }
}
```

`springBoneCollideSegmentCapsules` follows the same skeleton with `closestPtSegmentSegment(parentPos, childPos, cap.p0, cap.p1, c1, c2)` and `minDist = cap.radius + radius`; `springBoneCollideSegmentPlanes` tests both endpoints against the plane and pushes the child by the deeper penetration (`min` of the two signed distances, when negative). Reuse `applyVelocityCorrection` — if it is `static` in the other file, hoist it to the shared header rather than duplicating.

- [ ] **Step 4: Layout + Swift side**

1. Append `uint segmentCollision;` after `settlingFrames` in **every** Metal `SpringBoneParams` copy (grep first), and `public var segmentCollision: UInt32 = 0` in the Swift mirror at the same position, threaded through its `init`.
2. `SpringBoneBuffers.swift`: allocate `bonePosSnapshot` (same length/options as `bonePosCurr`).
3. `SpringBoneComputeSystem.swift`: create the four new pipelines beside `:324-352`; add `var segmentCollisionEnabledForTesting: Bool? = nil`; set `params.segmentCollision = (segmentCollisionEnabledForTesting ?? model.fitClothCollisionToMesh) ? 1 : 0` where globalParams is filled; at the encode site (`:756+`, after the existing three collide dispatches inside the substep loop), bind buffer 16 and dispatch: snapshot → segmentSpheres → segmentCapsules → segmentPlanes, same grid size, **only when the flag resolves true** (skip the dispatches entirely when off — the kernels also guard, belt and braces). Verify buffer index 16 is free by grepping `buffer(1[0-9])` across `Shaders/` first; if taken, pick the next free and update everywhere including this plan's kernels.
4. Wait — the snapshot must be taken **before** the endpoint collide dispatches (spec: after integration, serving ALL collide dispatches), not between them and the segment ones. Encode order per substep: integrate/kinematic (existing) → **snapshot** → the three existing collide dispatches (untouched) → the three segment dispatches → distance (existing). Place it accordingly.

- [ ] **Step 5: `make shaders`, run the discriminator**

```bash
make shaders
swift test --filter SegmentCollisionGapTests --disable-sandbox
```
Expected: case 1 flag-on now PASSES (child deflects), flag-off still passes-through (asserted), case 2 within its derived tolerance and settling bound. If case 2 fails: do NOT widen the tolerance — implement the spec's named fallback (scale the child correction by the barycentric `t` from `closestPtSegmentPoint`) and re-run; report which variant shipped.

- [ ] **Step 6: The bit gate and the CSVs survive the recompile**

Run: `swift test --filter "SpringBoneBitBaselineTests/testBitBaselineMatches|SpringBoneRegressionTests" --disable-sandbox`
Expected: PASS. If the bit gate fails flag-off after the recompile: quantify the divergence (max ULP delta across samples) and STOP — escalate with numbers. ULP-scale noise means compiler rescheduling of untouched kernels and is a controller/human decision per spec §6.1; mm-scale means your change leaked into the flag-off path and is yours to find. Do not adjust the gate either way.

- [ ] **Step 7: Determinism (6.5) with the live-read sabotage**

Add to `SegmentCollisionGapTests.swift`: two identical flag-on runs of the case-1 scene (fresh model each), comparing every joint position bit-for-bit across all frames (the `SpringBoneRendererDeterminismTests` pattern — read it for the comparison idiom).
Then sabotage: in `springBoneCollideSegmentSpheres`, scratch-change `bonePosSnapshot[parent]` to `bonePosCurr[parent]`, `make shaders`, re-run the determinism test **several times**.
Expected: at least one run diverges (unsynchronized read). If it never diverges after ~10 attempts, report that honestly — scheduling may mask the race on this GPU; the sabotage result is then "not observed on this hardware," recorded, not claimed. Restore, `make shaders`, confirm green.

- [ ] **Step 8: Full suite, then commit atomically**

```bash
swift test --disable-sandbox --skip HairHeadCollisionTests
git add Sources/VRMMetalKit/Shaders/ Sources/VRMMetalKit/Resources/*.metallib Sources/VRMMetalKit/SpringBone*.swift Tests/VRMMetalKitTests/SpringBone/SegmentCollisionGapTests.swift
git commit -m "feat(springbone): segment cloth collision behind fitClothCollisionToMesh

Three NEW kernels collide the parent->child span against sphere/capsule/
plane colliders; the shipped endpoint kernels are textually untouched, which
is what let the flag-off bit baseline survive the metallib recompile. Parent
endpoints read an immutable per-substep snapshot (buffer 16) — the collide
kernels write bonePosCurr[id] per thread, so a live parent read would be
their first cross-thread read and nondeterministic; the 6.5 gate's sabotage
is exactly that read. Corrections stay single-writer to the child; CCD
scoping untouched (segments are discrete-time). Metallibs regenerated and
committed atomically."
```

---

### Task 5: Oracle improvement gate (6.3)

**Files:**
- Modify: `Tests/VRMMetalKitTests/SpringBone/SkinMeshCoverageTests.swift`

**Interfaces:**
- Consumes: `SkinMeshOracle.build(model:)` / `penetration(of:radius:)` (SP1, amended); the flag (Task 3); `SpringBoneComputeSystem.segmentCollisionEnabledForTesting` (Task 4); `SpringBoneJointRadiusMeasure` internals for the A-stub sabotage — add `static var measurementDisabledForTesting = false` to the utility (returns `[]` when set) as part of this task.
- Produces: the recorded flag-off vs flag-on numbers Task 6 cites.

- [ ] **Step 1: Write the gate**

One test per pose (`armsCrossed`, `armsAtSides`), each: load M twice (flag off / flag on), run the existing offscreen loop (reuse this file's harness), measure worst penetration per chain via the oracle **using each joint's simulated radius** (`effectiveHitRadius ?? hitRadius` — the radius the sim actually used), query set = the existing denylist-minus-Bust. Assertions:
- Record `flagOff.worstHair`, `flagOff.worstSkirt` (print, and carry in the assertion message).
- `flagOn.worst < flagOff.worst − max(0.002, 0.2 × flagOff.worst)` per chain family that was non-zero flag-off — the margin derivation (20 % or 2 mm, whichever is larger) stated in the message. If a family is already clean flag-off, assert it stays clean and say so.

- [ ] **Step 2: Run, record both directions**

Run: `swift test --filter SkinMeshCoverageTests --disable-sandbox`
Expected: PASS with real reductions. Copy the per-chain numbers into the report — these are the feature's headline evidence.

- [ ] **Step 3: Dual sabotage**

(i) `SpringBoneJointRadiusMeasure.measurementDisabledForTesting = true` (A stubbed, segments live): the improvement assertion must FAIL, or A contributes nothing — reported, not tuned away. (ii) restore; `segmentCollisionEnabledForTesting = false` (B off, measured radii live): likewise. Restore both, confirm green, report all three runs.

- [ ] **Step 4: Commit**

```bash
git add Tests/VRMMetalKitTests/SpringBone/SkinMeshCoverageTests.swift Sources/VRMMetalKit/SpringBoneJointRadiusMeasure.swift Sources/VRMMetalKit/SpringBoneComputeSystem.swift
git commit -m "test(springbone): oracle gate — cloth fidelity measurably reduces penetration on M

Flag-off vs flag-on in one test per pose, margins derived from the recorded
flag-off depths (20% or 2mm, whichever larger). Both halves proven to
contribute via independent sabotage: measurement stubbed fails the gate, and
segment collision disabled fails the gate."
```

---

### Task 6: Visual + performance gate (6.4)

**Files:** none committed except the report and (if calibration changes the percentile) `SpringBoneJointRadiusMeasure.swift` + repinned audit aggregates with the derivation stated. Renders go to `_visuals_381/` (untracked).

- [ ] **Step 1: Render off/on**

```bash
swift build --product VRMVideoRenderer
for CLIP in Hitarea_Head Hitarea_Groin Sit_Idle; do
  .build/debug/VRMVideoRenderer AvatarSample_M_1.0.vrm "VRMA_Avatar_Mega_Pack/$CLIP.vrma" \
    "_visuals_381/fid-off-$CLIP.mov" --width 1280 --height 720 --duration 6 --orbit --orbit-target body
done
```
The renderer loads with default options (flag off). For the flag-on renders, add a `--fit-cloth-collision` CLI flag to `Sources/VRMVideoRenderer/main.swift` that sets `options.fitClothCollisionToMesh = true` (follow the `--stagger` option's pattern), rebuild, render `fid-on-$CLIP.mov`. This CLI flag is a shippable part of the task — commit it.

- [ ] **Step 2: Quantify + eyeball**

Pixel-delta off-vs-on per clip at t = 1.0/2.0/3.0 using the session's established method (ffmpeg gray dump + per-pixel diff; >8/255 threshold). The 18 mm experiment's 0.31–0.37 % is the floor to beat decisively. Extract hand/hair crops and **look at them**: hair must deflect around the forearm in `Hitarea_Head`, hands must rest on (not in) the skirt in `Hitarea_Groin`. If the renders show scalp-adjacent bulging, that triggers the spec's named round-cone fallback — report it as a finding with frames; do not ship the bulge silently. If the p65 percentile visibly over/under-covers, recalibrate within [p50, p80], repin the audit aggregates, and record the chosen value WITH the renders that justified it.

- [ ] **Step 3: Performance**

Using the offscreen loop on M and U at `.ultra` and `.extreme`, flag off vs on, measure the spring compute cost: the synchronous spring path self-commits its command buffer, so use `MTLCommandBuffer` `gpuStartTime`/`gpuEndTime` on that buffer if reachable; else wall-clock the render loop and state the dilution caveat. Gate: **≤ 3× at ultra** (derivation: `extreme` costs ~4× ultra and is the accepted hero-tier step; an opt-in fidelity feature must cost less than one tier step). Report all four multipliers.

- [ ] **Step 4: Commit (CLI flag + any calibration) and report**

```bash
git add Sources/VRMVideoRenderer/main.swift Sources/VRMMetalKit/SpringBoneJointRadiusMeasure.swift Tests/VRMMetalKitTests/SpringBone/ClothJointRadiusAuditTests.swift
git commit -m "feat(tools): --fit-cloth-collision render flag; record 6.4 calibration"
```

---

### Task 7: Docs, invariant amendment, filing

**Files:**
- Modify: `CLAUDE.md` (§4 CCD sentence)
- Modify: `docs/SpringBonePhysicsGuide.md`
- Modify: `docs/superpowers/specs/2026-08-05-cloth-collision-fidelity-design.md` (Status → implemented; record the calibrated percentile and the 6.4 numbers)

- [ ] **Step 1: CLAUDE.md §4** — amend "Endpoint-inside (resting/sliding) push-out stays discrete on **every** collider" to state that with `fitClothCollisionToMesh` the discrete test also covers the parent→child **segment** (still discrete-time; swept response remains synthetic-group-only, unchanged).
- [ ] **Step 2: Physics guide** — a section on the flag: what it measures, the #326 boundary (opt-in, authored never mutated), the effective-radius formula, segment semantics, and the one-line host adoption (`options.fitClothCollisionToMesh = true`).
- [ ] **Step 3: File on #381** — `gh issue comment 381` summarizing: cloth-side sibling of SP2 shipped opt-in; headline oracle numbers from Task 5; SP3 (per-finger) now has segments to push against.
- [ ] **Step 4: Spec status update + commit**

```bash
git add CLAUDE.md docs/
git commit -m "docs(springbone): cloth-collision fidelity — invariant amendment, guide, spec status"
```

---

## Verification Checklist

- [ ] `swift build` + `swift build --configuration release` clean; `make shaders` idempotent (re-run produces no diff)
- [ ] `swift test --disable-sandbox --skip HairHeadCollisionTests` — no new failures; `testLookUp_augmented_noForeheadPenetration` still green
- [ ] `SpringBoneBitBaselineTests/testBitBaselineMatches` green flag-off, post-recompile
- [ ] `SegmentCollisionGapTests` — gap case discriminates in both directions; determinism gate green, live-read sabotage recorded
- [ ] `SkinMeshCoverageTests` — flag-on reductions recorded, both sabotage directions observed
- [ ] `_visuals_381/fid-{off,on}-*.mov` reviewed by a human; percentile calibration recorded
- [ ] Every sabotage in Tasks 2–5 reported with sabotaged AND restored output
- [ ] Nothing pushed
- [ ] The final whole-branch review (SDD) covers SP1 **and** this feature — SP1's final review was deferred to here and is owed

## What this plan does not build

Per-finger colliders and hierarchical collision (#381 SP3 — enabled by segments, not included), containment-collider segments, any CCD change, override knobs, default-on (a future behaviour change requiring the pre-release protocol), gravity authoring (asset-side).
