# SpringBone Collider Augmentation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix systemic SpringBone clipping (hair→forehead, hair→arms, arm→skirt, issue #309) by synthesizing tight, bone-derived colliders at model-load time, additive to authored colliders and gated by a config flag — no solver or shader changes.

**Architecture:** A new pure-value type `SpringBoneColliderAugmentor` turns the humanoid skeleton into end-to-end limb capsules plus a forward head/brow capsule. Its output is stored in a new additive list on `VRMSpringBone` that is consumed at **both** buffer-allocation time (`VRMModel.initializeSpringBoneGPUSystem`) and collider-upload time (`SpringBoneComputeSystem.populateSpringBoneData`), so buffer sizes, global-params counts, and uploaded arrays all agree (the count-equality contract). All synthetic colliders join one synthetic collider group whose bit is OR'd into every spring's collider mask. TDD is driven by a hand-fit, test-only **skin-reference oracle** across four stress poses.

**Tech Stack:** Swift 6.2, Metal, XCTest. Build: `swift build`. Test: `swift test --filter <Class> --disable-sandbox`.

**Spec:** `docs/superpowers/specs/2026-05-29-springbone-collider-augmentation-design.md`

**Deviation from spec:** Spec §5 said the flag lives on "the SpringBone/`RendererConfig` config". Verified during planning that collider buffers are allocated inside `VRMModel.load` (`Core/VRMModel.swift:537`), before any `VRMRenderer`/`RendererConfig` exists. The flag therefore lives on **`VRMLoadingOptions`** (`augmentSpringBoneColliders: Bool = true`). Everything else matches the spec.

**Revision 1 (Option 2 — second fixture).** Phase 0 measurement proved AvatarSample_A has no limb-reaching cloth (only short head/neck `Hair`/`Hood` chains; no skirt). Per spec Revision 1, limb capsules are validated on the in-repo **`AvatarSample_U_1.0.vrm.glb`** (6 `Skirt` chains → legs, `Sleeve`/long-hair → arms). Plan changes:
- **Task 4 (done)** — keep only the AvatarSample_A `lookUp` head reproduction; the head-dominated `armsRaised`/`armsCrossed`/`seated` A-tests are removed in Task 4b.
- **Task 4b (NEW)** — generalize the harness to `(modelPath, oracleName)`; author `avatar_u_skin_reference.json` (measured limb/skull oracle for U) + U integrity checksum; add U reproduction tests: `armsRaised` (sleeve/hair→arm) and `seatedDeepFlexion` (skirt→leg), RED with current colliders.
- **Task 7** — augmented green tests target **AvatarSample_U** (arm + skirt/leg).
- **Task 8** — augmented green test targets **AvatarSample_A** (`lookUp`).
- **Task 9** — largely absorbed (U is now the second model); keep only a finite/sane smoke check if a *third* model is configured.
- Sequencing note: Tasks were executed 1,2,3,**5**,4,4b,6,7,8,… (Task 5's flag was pulled ahead of Task 4 so the `augment:false` tests pin coarse colliders permanently).

---

## File Structure

| File | New/Modified | Responsibility |
|---|---|---|
| `Sources/VRMMetalKit/SpringBone/SpringBoneColliderAugmentor.swift` | **New** | Pure value type: humanoid + node world transforms → `[VRMCollider]` synthetic colliders. No Metal. |
| `Sources/VRMMetalKit/Core/VRMTypes.swift` | Modified | Add `var syntheticColliders: [VRMCollider] = []` to `VRMSpringBone`. |
| `Sources/VRMMetalKit/Core/VRMLoadingOptions.swift` | Modified | Add `augmentSpringBoneColliders: Bool` flag (default `true`). |
| `Sources/VRMMetalKit/Core/VRMModel.swift` | Modified | Run augmentor in `initializeSpringBoneGPUSystem`; include synthetic in collider counts; thread flag from `load`. |
| `Sources/VRMMetalKit/SpringBoneComputeSystem.swift` | Modified | Upload authored+synthetic; assign synthetic group index; OR synthetic-group bit into every spring mask. |
| `Tests/VRMMetalKitTests/SpringBone/SpringBoneColliderAugmentorTests.swift` | **New** | Unit tests for synthetic geometry (no GPU). |
| `Tests/VRMMetalKitTests/SpringBone/SkinReferenceOracle.swift` | **New** | Oracle loader + point-vs-shape signed-distance helper + model-integrity checksum. |
| `Tests/VRMMetalKitTests/SpringBone/StressPoseFactory.swift` | **New** | Four static extreme-pose `AnimationClip` builders. |
| `Tests/VRMMetalKitTests/SpringBone/SpringBoneStressPosePenetrationTests.swift` | **New** | The four red→green penetration tests. |
| `Tests/VRMMetalKitTests/TestData/SpringBoneOracle/avatar_a_skin_reference.json` | **New** | Hand-fit, test-only skin-reference colliders + integrity checksum. |

---

## Phase 0 — Oracle + RED tests (no generator code yet)

### Task 1: Skin-reference oracle fixture + loader + distance helper

**Files:**
- Create: `Tests/VRMMetalKitTests/TestData/SpringBoneOracle/avatar_a_skin_reference.json`
- Create: `Tests/VRMMetalKitTests/SpringBone/SkinReferenceOracle.swift`
- Test: covered by Task 1's own unit test below.

- [ ] **Step 1: Write the oracle JSON fixture.**

Node-anchored colliders, expressed in **bone-local** space (offset/tail/radius in metres, relative to the named humanoid bone's node). Authored to trace AvatarSample_A's real skin tighter than the shipped colliders. `integrity` pins the asset so the oracle can't silently drift (Task 2).

```json
{
  "model": "AvatarSample_A_1.0.vrm.glb",
  "authoredDate": "2026-05-29",
  "poseAssumption": "neutral rest pose at load; shapes transform with live node world matrices",
  "note": "GROUND TRUTH for tests only. NEVER shipped as runtime colliders. Do not edit the generator to match these.",
  "integrity": { "vertexCount": 0, "bboxMinY": 0.0, "bboxMaxY": 0.0 },
  "colliders": [
    { "bone": "head",          "kind": "capsule", "offset": [0.0, 0.02, 0.04], "tail": [0.0, -0.07, 0.06], "radius": 0.055 },
    { "bone": "head",          "kind": "sphere",  "offset": [0.0, 0.06, -0.01], "radius": 0.092 },
    { "bone": "leftUpperArm",  "kind": "capsule", "offset": [0.0, 0.0, 0.0], "tailBone": "leftLowerArm", "radius": 0.045 },
    { "bone": "leftLowerArm",  "kind": "capsule", "offset": [0.0, 0.0, 0.0], "tailBone": "leftHand",     "radius": 0.034 },
    { "bone": "rightUpperArm", "kind": "capsule", "offset": [0.0, 0.0, 0.0], "tailBone": "rightLowerArm","radius": 0.045 },
    { "bone": "rightLowerArm", "kind": "capsule", "offset": [0.0, 0.0, 0.0], "tailBone": "rightHand",    "radius": 0.034 },
    { "bone": "leftUpperLeg",  "kind": "capsule", "offset": [0.0, 0.0, 0.0], "tailBone": "leftLowerLeg", "radius": 0.062 },
    { "bone": "leftLowerLeg",  "kind": "capsule", "offset": [0.0, 0.0, 0.0], "tailBone": "leftFoot",     "radius": 0.045 },
    { "bone": "rightUpperLeg", "kind": "capsule", "offset": [0.0, 0.0, 0.0], "tailBone": "rightLowerLeg","radius": 0.062 },
    { "bone": "rightLowerLeg", "kind": "capsule", "offset": [0.0, 0.0, 0.0], "tailBone": "rightFoot",    "radius": 0.045 }
  ]
}
```

`tailBone` (when present) means "tail = that bone's world position, expressed in this bone's local space" — resolved by the loader (Step 3). `integrity` zeros are placeholders filled by Task 2 Step 2 (a one-time measured-value capture), after which they are committed as real numbers — not left zero.

- [ ] **Step 2: Write the oracle model (Codable) and signed-distance helper.**

```swift
// Tests/VRMMetalKitTests/SpringBone/SkinReferenceOracle.swift
import Foundation
import simd
@testable import VRMMetalKit

struct SkinReferenceOracle: Decodable {
    struct Integrity: Decodable { let vertexCount: Int; let bboxMinY: Float; let bboxMaxY: Float }
    struct Shape: Decodable {
        let bone: VRMHumanoidBone
        let kind: String                 // "sphere" | "capsule"
        let offset: SIMD3<Float>
        let tail: SIMD3<Float>?
        let tailBone: VRMHumanoidBone?
        let radius: Float
    }
    let integrity: Integrity
    let colliders: [Shape]

    static func load(named name: String) throws -> SkinReferenceOracle {
        let url = try XCTestResource.url(name, ext: "json", subdir: "TestData/SpringBoneOracle")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(SkinReferenceOracle.self, from: data)
    }
}

// A world-space resolved shape used for distance queries.
enum OracleWorldShape {
    case sphere(center: SIMD3<Float>, radius: Float)
    case capsule(p0: SIMD3<Float>, p1: SIMD3<Float>, radius: Float)

    /// Signed distance from `point` to the shape SURFACE.
    /// Negative => `point` is INSIDE the shape (penetration depth = -value).
    func signedDistance(to point: SIMD3<Float>) -> Float {
        switch self {
        case let .sphere(center, radius):
            return simd_length(point - center) - radius
        case let .capsule(p0, p1, radius):
            let ab = p1 - p0
            let abLenSq = simd_dot(ab, ab)
            let t = abLenSq > 1e-12 ? simd_clamp(simd_dot(point - p0, ab) / abLenSq, 0, 1) : 0
            let closest = p0 + t * ab
            return simd_length(point - closest) - radius
        }
    }
}
```

`SIMD3<Float>` decodes from a 3-element JSON array automatically via `Codable` on `SIMD3` (Swift synthesizes this). `VRMHumanoidBone` is `String`-raw and `Decodable` (it is `CaseIterable, Sendable` with a `String` raw value at `Core/VRMTypes.swift:45`).

- [ ] **Step 3: Add the live-pose resolver (bone-local shapes → world shapes).**

```swift
// Append to SkinReferenceOracle.swift
extension SkinReferenceOracle {
    /// Resolve every bone-local shape into a world-space shape using the
    /// model's CURRENT node world matrices (call after each simulated frame).
    func resolveWorldShapes(model: VRMModel) -> [OracleWorldShape] {
        guard let humanoid = model.humanoid else { return [] }
        func worldPos(_ bone: VRMHumanoidBone) -> SIMD3<Float>? {
            guard let nodeIdx = humanoid.getBoneNode(bone),
                  nodeIdx >= 0, nodeIdx < model.nodes.count else { return nil }
            return model.nodes[nodeIdx].worldPosition
        }
        func worldMatrix(_ bone: VRMHumanoidBone) -> float4x4? {
            guard let nodeIdx = humanoid.getBoneNode(bone),
                  nodeIdx >= 0, nodeIdx < model.nodes.count else { return nil }
            return model.nodes[nodeIdx].worldMatrix
        }
        var out: [OracleWorldShape] = []
        for shape in colliders {
            guard let m = worldMatrix(shape.bone) else { continue }
            let originW = (m * SIMD4<Float>(shape.offset, 1)).xyz
            switch shape.kind {
            case "sphere":
                out.append(.sphere(center: originW, radius: shape.radius))
            case "capsule":
                let tailW: SIMD3<Float>
                if let tb = shape.tailBone, let p = worldPos(tb) {
                    tailW = p
                } else if let tail = shape.tail {
                    tailW = (m * SIMD4<Float>(tail, 1)).xyz
                } else {
                    tailW = originW
                }
                out.append(.capsule(p0: originW, p1: tailW, radius: shape.radius))
            default:
                continue
            }
        }
        return out
    }

    /// Worst penetration depth (>=0) of `point` across all shapes; 0 if outside all.
    static func worstPenetration(of point: SIMD3<Float>, shapes: [OracleWorldShape]) -> Float {
        var worst: Float = 0
        for s in shapes {
            let pen = -s.signedDistance(to: point)
            if pen > worst { worst = pen }
        }
        return worst
    }
}

extension SIMD4 where Scalar == Float { var xyz: SIMD3<Float> { SIMD3(x, y, z) } }
```

- [ ] **Step 4: Add a tiny resource-locator helper used above.**

```swift
// Append to SkinReferenceOracle.swift
import XCTest
enum XCTestResource {
    static func url(_ name: String, ext: String, subdir: String) throws -> URL {
        if let u = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: subdir) {
            return u
        }
        throw XCTSkip("Test resource missing: \(subdir)/\(name).\(ext)")
    }
}
```

- [ ] **Step 5: Register the TestData subdirectory as a bundle resource (if not already).**

Run: `rg -n "TestData" Package.swift`
Expected: a `.copy("Tests/VRMMetalKitTests/TestData")` or `resources:` entry on the test target. If `TestData/SpringBoneRegression` already ships (it does — `avatar_a_baseline.csv` loads via `Bundle.module`), then `TestData/SpringBoneOracle` is covered by the same rule. If the resource rule lists individual subdirectories, add `SpringBoneOracle`. Otherwise no change.

- [ ] **Step 6: Build the test target to confirm the oracle compiles.**

Run: `swift build --build-tests 2>&1 | tail -20`
Expected: builds with no errors referencing `SkinReferenceOracle`.

- [ ] **Step 7: Commit.**

```bash
git add Tests/VRMMetalKitTests/SpringBone/SkinReferenceOracle.swift \
        Tests/VRMMetalKitTests/TestData/SpringBoneOracle/avatar_a_skin_reference.json
git commit -m "test(springbone): skin-reference oracle loader + distance helper (#309)"
```

---

### Task 2: Model-integrity checksum guard

**Files:**
- Modify: `Tests/VRMMetalKitTests/SpringBone/SkinReferenceOracle.swift`
- Modify: `Tests/VRMMetalKitTests/TestData/SpringBoneOracle/avatar_a_skin_reference.json`

- [ ] **Step 1: Write a failing integrity-assert test.**

```swift
// Tests/VRMMetalKitTests/SpringBone/SkinReferenceOracleIntegrityTests.swift
import XCTest
import simd
@testable import VRMMetalKit

final class SkinReferenceOracleIntegrityTests: XCTestCase {
    @MainActor
    func testAvatarSampleAMatchesOracleIntegrity() async throws {
        let path = getTestVRM10ModelPath()
        try requireFixture(path, hint: testVRM10Filename)
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: nil)
        let oracle = try SkinReferenceOracle.load(named: "avatar_a_skin_reference")
        let measured = SkinReferenceOracle.measureIntegrity(model: model)
        XCTAssertEqual(measured.vertexCount, oracle.integrity.vertexCount,
            "AvatarSample_A vertex count changed — the skin-reference oracle is stale. Re-trace it, then update integrity.")
        XCTAssertEqual(measured.bboxMinY, oracle.integrity.bboxMinY, accuracy: 0.001)
        XCTAssertEqual(measured.bboxMaxY, oracle.integrity.bboxMaxY, accuracy: 0.001)
    }
}
```

- [ ] **Step 2: Add `measureIntegrity` and capture the real values.**

```swift
// Append to SkinReferenceOracle.swift
extension SkinReferenceOracle {
    static func measureIntegrity(model: VRMModel) -> Integrity {
        var count = 0
        var minY = Float.greatestFiniteMagnitude
        var maxY = -Float.greatestFiniteMagnitude
        for mesh in model.meshes {
            for prim in mesh.primitives {
                for v in prim.positions {            // SIMD3<Float> rest positions
                    count += 1
                    if v.y < minY { minY = v.y }
                    if v.y > maxY { maxY = v.y }
                }
            }
        }
        if count == 0 { minY = 0; maxY = 0 }
        return Integrity(vertexCount: count, bboxMinY: minY, bboxMaxY: maxY)
    }
}
```

Run: `swift build --build-tests 2>&1 | tail -20`
Then confirm the exact accessors: `rg -n "var meshes|struct .*Mesh|var primitives|var positions" Sources/VRMMetalKit/ | head`. If the rest-position array is named differently (e.g. `vertices` / `positionAccessor`), adjust `prim.positions` to the real property. The point: count vertices and Y-extent from the loaded mesh data.

- [ ] **Step 3: Run the test to capture measured values (it will fail; read them off).**

Run: `swift test --filter SkinReferenceOracleIntegrityTests --disable-sandbox 2>&1 | tail -30`
Expected: FAIL, printing measured vertexCount / bboxMinY / bboxMaxY in the assertion messages.

- [ ] **Step 4: Write the measured values into the JSON `integrity` block.**

Edit `avatar_a_skin_reference.json` `integrity` to the measured `vertexCount`, `bboxMinY`, `bboxMaxY`.

- [ ] **Step 5: Re-run to verify it passes.**

Run: `swift test --filter SkinReferenceOracleIntegrityTests --disable-sandbox 2>&1 | tail -10`
Expected: PASS.

- [ ] **Step 6: Commit.**

```bash
git add Tests/VRMMetalKitTests/SpringBone/SkinReferenceOracle.swift \
        Tests/VRMMetalKitTests/SpringBone/SkinReferenceOracleIntegrityTests.swift \
        Tests/VRMMetalKitTests/TestData/SpringBoneOracle/avatar_a_skin_reference.json
git commit -m "test(springbone): oracle integrity checksum fails loudly on asset drift (#309)"
```

---

### Task 3: Stress-pose factory

**Files:**
- Create: `Tests/VRMMetalKitTests/SpringBone/StressPoseFactory.swift`

- [ ] **Step 1: Write the four static-pose clip builders.**

Each clip holds a fixed extreme rotation for the whole duration (static pose; physics settles into it). Mirrors `makeHeadShakeClip` (`SpringBoneRegressionTests.swift:185`).

```swift
// Tests/VRMMetalKitTests/SpringBone/StressPoseFactory.swift
import Foundation
import simd
@testable import VRMMetalKit

enum StressPose: String, CaseIterable {
    case lookUp, armsRaised, armsCrossed, seatedDeepFlexion
}

enum StressPoseFactory {
    static func clip(_ pose: StressPose, duration: Float = 4.0) -> AnimationClip {
        var clip = AnimationClip(duration: duration)
        func fixed(_ q: simd_quatf) -> ((Float) -> simd_quatf) { { _ in q } }
        func rot(_ deg: Float, _ axis: SIMD3<Float>) -> simd_quatf {
            simd_quatf(angle: deg * .pi / 180, axis: simd_normalize(axis))
        }
        switch pose {
        case .lookUp:
            // Head pitches back ~35° about local X (look up).
            clip.addJointTrack(JointTrack(bone: .head, rotationSampler: fixed(rot(-35, [1, 0, 0]))))
        case .armsRaised:
            // Both upper arms raised ~90° (rotate about Z, mirrored sign per side).
            clip.addJointTrack(JointTrack(bone: .leftUpperArm,  rotationSampler: fixed(rot(-90, [0, 0, 1]))))
            clip.addJointTrack(JointTrack(bone: .rightUpperArm, rotationSampler: fixed(rot(90, [0, 0, 1]))))
        case .armsCrossed:
            // Upper arms rotated inward across the chest (~75° about Y, mirrored).
            clip.addJointTrack(JointTrack(bone: .leftUpperArm,  rotationSampler: fixed(rot(75, [0, 1, 0]))))
            clip.addJointTrack(JointTrack(bone: .rightUpperArm, rotationSampler: fixed(rot(-75, [0, 1, 0]))))
        case .seatedDeepFlexion:
            // Deep hip flexion: upper legs swing forward ~90° about X (thighs toward torso).
            clip.addJointTrack(JointTrack(bone: .leftUpperLeg,  rotationSampler: fixed(rot(90, [1, 0, 0]))))
            clip.addJointTrack(JointTrack(bone: .rightUpperLeg, rotationSampler: fixed(rot(90, [1, 0, 0]))))
        }
        return clip
    }
}
```

- [ ] **Step 2: Build to confirm it compiles.**

Run: `swift build --build-tests 2>&1 | tail -10`
Expected: builds clean.

- [ ] **Step 3: Commit.**

```bash
git add Tests/VRMMetalKitTests/SpringBone/StressPoseFactory.swift
git commit -m "test(springbone): static stress-pose clip factory (#309)"
```

---

### Task 4: RED penetration tests (current colliders fail the oracle)

**Files:**
- Create: `Tests/VRMMetalKitTests/SpringBone/SpringBoneStressPosePenetrationTests.swift`

- [ ] **Step 1: Write the harness + the four pose tests.**

```swift
// Tests/VRMMetalKitTests/SpringBone/SpringBoneStressPosePenetrationTests.swift
import XCTest
import Metal
import simd
@testable import VRMMetalKit

final class SpringBoneStressPosePenetrationTests: XCTestCase {

    private static let minFrameIntervalNanos: UInt64 = 35_000_000  // 35 ms (matches regression harness)
    private static let frameCount = 150
    private static let fps: Float = 30
    private static let penetrationTolerance: Float = 0.005  // 5 mm slack (PBD)
    private static let maxPenetrationRate: Float = 0.01     // < 1% of samples

    /// Node indices of spring joints belonging to hair/skirt chains, excluding each chain's root.
    @MainActor
    private func clothJointNodeIndices(_ model: VRMModel) -> [Int] {
        guard let sb = model.springBone else { return [] }
        var indices: [Int] = []
        for spring in sb.springs {
            let name = (spring.name ?? "").lowercased()
            guard name.contains("hair") || name.contains("skirt") || name.contains("hood") else { continue }
            for (i, joint) in spring.joints.enumerated() where i > 0 {   // skip root
                indices.append(joint.node)
            }
        }
        return indices
    }

    @MainActor
    private func measurePenetrationRate(pose: StressPose, augment: Bool) async throws -> (rate: Float, worst: Float) {
        let path = getTestVRM10ModelPath()
        try requireFixture(path, hint: testVRM10Filename)
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }

        var opts = VRMLoadingOptions()
        opts.augmentSpringBoneColliders = augment
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device, options: opts)

        var config = RendererConfig()
        config.synchronousSpringBone = true                 // deterministic physics (see #283)
        let renderer = VRMRenderer(device: device, config: config)
        try renderer.setModel(model)

        let oracle = try SkinReferenceOracle.load(named: "avatar_a_skin_reference")
        let jointNodes = clothJointNodeIndices(model)
        XCTAssertFalse(jointNodes.isEmpty, "No hair/skirt joints found — chain-name filter is wrong")

        let player = AnimationPlayer()
        player.play(clip: StressPoseFactory.clip(pose))

        let colorTex = try makeColorTexture(device: device, width: 64, height: 64)
        let depthTex = try makeDepthTexture(device: device, width: 64, height: 64)
        guard let queue = device.makeCommandQueue() else { throw XCTSkip("No command queue") }

        var totalSamples = 0, penetrationSamples = 0
        var worst: Float = 0
        let dt = 1.0 / Self.fps

        for frameIndex in 0..<Self.frameCount {
            if frameIndex > 0 { try await Task.sleep(nanoseconds: Self.minFrameIntervalNanos) }
            player.update(deltaTime: dt, model: model)

            guard let cb = queue.makeCommandBuffer() else { XCTFail("no cb"); break }
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

            // Measure only after physics has had time to settle into the held pose.
            guard frameIndex >= Self.frameCount / 2 else { continue }
            let shapes = oracle.resolveWorldShapes(model: model)
            for nodeIdx in jointNodes {
                guard nodeIdx >= 0, nodeIdx < model.nodes.count else { continue }
                let p = model.nodes[nodeIdx].worldPosition
                totalSamples += 1
                let pen = SkinReferenceOracle.worstPenetration(of: p, shapes: shapes)
                if pen > Self.penetrationTolerance {
                    penetrationSamples += 1
                    if pen > worst { worst = pen }
                }
            }
        }
        XCTAssertGreaterThan(totalSamples, 0, "No samples collected")
        return (Float(penetrationSamples) / Float(max(totalSamples, 1)), worst)
    }

    // The four RED tests: current colliders (augment:false) MUST penetrate the oracle.
    @MainActor func testLookUp_currentColliders_penetrate() async throws {
        let (rate, worst) = try await measurePenetrationRate(pose: .lookUp, augment: false)
        XCTAssertGreaterThan(rate, Self.maxPenetrationRate,
            "Expected RED: look-up should penetrate the oracle with coarse colliders (rate \(rate), worst \(worst)m). If green, the oracle is too loose at the brow — tighten it.")
    }
    @MainActor func testArmsRaised_currentColliders_penetrate() async throws {
        let (rate, _) = try await measurePenetrationRate(pose: .armsRaised, augment: false)
        XCTAssertGreaterThan(rate, Self.maxPenetrationRate, "Expected RED: arms-raised should penetrate the oracle with coarse colliders (rate \(rate)).")
    }
    @MainActor func testArmsCrossed_currentColliders_penetrate() async throws {
        let (rate, _) = try await measurePenetrationRate(pose: .armsCrossed, augment: false)
        XCTAssertGreaterThan(rate, Self.maxPenetrationRate, "Expected RED: arms-crossed should penetrate the oracle with coarse colliders (rate \(rate)).")
    }
    @MainActor func testSeatedDeepFlexion_currentColliders_penetrate() async throws {
        let (rate, _) = try await measurePenetrationRate(pose: .seatedDeepFlexion, augment: false)
        XCTAssertGreaterThan(rate, Self.maxPenetrationRate, "Expected RED: seated deep-flexion should penetrate the oracle with coarse colliders (rate \(rate)).")
    }
}
```

- [ ] **Step 2: Resolve helper/API names against the codebase before running.**

Run: `rg -n "func setModel|func play\(clip|class AnimationPlayer|func makeColorTexture|func makeDepthTexture" Sources/VRMMetalKit Tests/VRMMetalKitTests`
- Confirm `renderer.setModel(_:)` (or the actual attach call used by `HairHeadCollisionTests`/`SpringBoneRegressionTests` — copy whatever they use).
- Confirm `AnimationPlayer` construction + `play(clip:)` (copy from regression test, which already drives `player.update`).
- If `makeColorTexture`/`makeDepthTexture` helpers don't exist, copy the inline `MTLTextureDescriptor` setup from `SpringBoneRegressionTests` (`colorTex`/`depthTex` creation around lines 120–140) instead.
Adjust the test to the real names. Do not invent APIs — mirror the two existing tests exactly.

- [ ] **Step 3: Run the four tests; verify they FAIL as RED (penetration present).**

Run: `swift test --filter SpringBoneStressPosePenetrationTests --disable-sandbox 2>&1 | tail -40`
Expected: all four FAIL with `XCTAssertGreaterThan` satisfied? No — these assert penetration EXISTS, so RED here means **they PASS** (penetration confirmed). Read carefully:
- A **passing** test now = "coarse colliders penetrate the oracle" = the bug is reproduced. Good.
- A **failing** test now = oracle too loose for that pose → tighten the relevant oracle shapes (smaller radius / better offset) until it passes, then re-commit the JSON.

This task's exit criterion: **all four tests pass against `augment:false`** (bug reproduced through the oracle).

- [ ] **Step 4: Commit.**

```bash
git add Tests/VRMMetalKitTests/SpringBone/SpringBoneStressPosePenetrationTests.swift \
        Tests/VRMMetalKitTests/TestData/SpringBoneOracle/avatar_a_skin_reference.json
git commit -m "test(springbone): reproduce stress-pose clipping via skin-reference oracle (#309)"
```

---

## Phase 1 — Seam (config + storage + wiring), generator still empty

### Task 5: Add `syntheticColliders` storage and the `VRMLoadingOptions` flag

**Files:**
- Modify: `Sources/VRMMetalKit/Core/VRMTypes.swift:713-725` (`VRMSpringBone`)
- Modify: `Sources/VRMMetalKit/Core/VRMLoadingOptions.swift:220-246`

- [ ] **Step 1: Add the additive storage field to `VRMSpringBone`.**

In `VRMTypes.swift`, inside `public struct VRMSpringBone`, after `public var colliders: [VRMCollider] = []`:

```swift
    /// Procedurally synthesized colliders (issue #309). Additive to `colliders`;
    /// authored `colliders` is never mutated. Populated at load time when
    /// `VRMLoadingOptions.augmentSpringBoneColliders` is true, and consumed by
    /// both buffer allocation and collider upload.
    public var syntheticColliders: [VRMCollider] = []
```

- [ ] **Step 2: Add the flag to `VRMLoadingOptions` (stored property + init param + default).**

In `VRMLoadingOptions.swift`, add the stored property after `optimizations` (line 232):

```swift
    /// When `true`, synthesize tight bone-derived colliders (limb capsules +
    /// head/brow capsule) additive to authored colliders, to reduce SpringBone
    /// clipping (issue #309). Default `true`.
    public let augmentSpringBoneColliders: Bool
```

Add the init parameter (default `true`) to the `public init(...)` at line 241 and assign it:

```swift
    public init(
        progressCallback: (@Sendable (VRMLoadingProgress) -> Void)? = nil,
        progressUpdateInterval: TimeInterval = 0.1,
        enableCancellation: Bool = true,
        optimizations: VRMLoadingOptimization = .default,
        augmentSpringBoneColliders: Bool = true
    ) {
        // ...existing assignments...
        self.augmentSpringBoneColliders = augmentSpringBoneColliders
    }
```

Also confirm the `.default` static factory (if one exists) still compiles — `rg -n "static let .default|static var default" Sources/VRMMetalKit/Core/VRMLoadingOptions.swift`; if it constructs via the memberwise/explicit init with no args, the new default covers it.

- [ ] **Step 3: Build.**

Run: `swift build 2>&1 | tail -10`
Expected: builds clean.

- [ ] **Step 4: Commit.**

```bash
git add Sources/VRMMetalKit/Core/VRMTypes.swift Sources/VRMMetalKit/Core/VRMLoadingOptions.swift
git commit -m "feat(springbone): add syntheticColliders storage + augmentation load flag (#309)"
```

---

### Task 6: Create the empty augmentor + allocation/upload wiring (proves `.off` == today)

**Files:**
- Create: `Sources/VRMMetalKit/SpringBone/SpringBoneColliderAugmentor.swift`
- Modify: `Sources/VRMMetalKit/Core/VRMModel.swift:537` (call site in `load`) and `:1130-1197` (`initializeSpringBoneGPUSystem`)
- Modify: `Sources/VRMMetalKit/SpringBoneComputeSystem.swift` (~700-737 mask loop, ~838-882 upload loop)
- Test: `Tests/VRMMetalKitTests/SpringBone/SpringBoneColliderAugmentorTests.swift`

- [ ] **Step 1: Write a failing test for the empty augmentor + an `.off`/`.on` parity assertion.**

```swift
// Tests/VRMMetalKitTests/SpringBone/SpringBoneColliderAugmentorTests.swift
import XCTest
import simd
@testable import VRMMetalKit

final class SpringBoneColliderAugmentorTests: XCTestCase {
    @MainActor
    func testAugmentorReturnsEmptyWhenNoHumanoid() async throws {
        let model = VRMModel()                       // bare model, no humanoid
        let result = SpringBoneColliderAugmentor.synthesize(model: model)
        XCTAssertTrue(result.isEmpty, "No humanoid => no synthetic colliders")
    }

    @MainActor
    func testAugmentOffMatchesAuthoredColliderCount() async throws {
        let path = getTestVRM10ModelPath()
        try requireFixture(path, hint: testVRM10Filename)
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        var opts = VRMLoadingOptions(); opts.augmentSpringBoneColliders = false
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device, options: opts)
        XCTAssertEqual(model.springBone?.syntheticColliders.count, 0,
            "augment:false must add zero synthetic colliders")
    }
}
```

`VRMModel()` no-arg init: confirm it exists with `rg -n "public init\(\)" Sources/VRMMetalKit/Core/VRMModel.swift`; if not, use the lightest available initializer or build a model with `humanoid = nil`.

- [ ] **Step 2: Create the augmentor returning empty (skeleton).**

```swift
// Sources/VRMMetalKit/SpringBone/SpringBoneColliderAugmentor.swift
import Foundation
import simd

/// Synthesizes tight, bone-derived colliders from the humanoid skeleton to
/// reduce SpringBone clipping (issue #309). Pure value logic — no Metal.
/// Output is ADDITIVE; callers never mutate authored colliders.
public enum SpringBoneColliderAugmentor {

    /// Generator ratios (fractions of a reference scale). Tuned in Phase 3.
    public struct Ratios {
        public var armRadiusFractionOfLength: Float = 0.18
        public var legRadiusFractionOfLength: Float = 0.13
        public var headForwardFraction: Float = 0.60   // × head sphere radius
        public var headDownFraction: Float = 0.50      // × head sphere radius
        public var headRadiusFraction: Float = 0.55    // × head sphere radius
        public init() {}
    }

    public static func synthesize(model: VRMModel, ratios: Ratios = Ratios()) -> [VRMCollider] {
        guard model.humanoid != nil else { return [] }
        return []   // filled in Phase 2 (limbs) and Phase 3 (head)
    }
}
```

- [ ] **Step 3: Wire the augmentor into allocation; thread the flag from `load`.**

In `VRMModel.swift` at the `load` call site (line ~537), pass the flag:

```swift
        if let device = device, model.springBone != nil {
            await context?.updatePhase(.initializingPhysics, progress: 0.5)
            try model.initializeSpringBoneGPUSystem(device: device,
                                                    augmentColliders: options.augmentSpringBoneColliders)
            await context?.updatePhase(.initializingPhysics, progress: 1.0)
        }
```

Change the method signature (line 1130) and compute synthetic colliders before counting:

```swift
    public func initializeSpringBoneGPUSystem(device: MTLDevice,
                                              augmentColliders: Bool = true) throws {
        guard springBone != nil else { return }
        expandVRM0SpringBoneChains()
        guard var expandedSpringBone = self.springBone else { return }

        // Synthesize additive colliders BEFORE counting, so buffer sizes and
        // global-params counts include them (the count-equality contract).
        if augmentColliders {
            expandedSpringBone.syntheticColliders =
                SpringBoneColliderAugmentor.synthesize(model: self)
        } else {
            expandedSpringBone.syntheticColliders = []
        }
        self.springBone = expandedSpringBone     // persist synthetic + expansion
```

Then change the three count computations to span authored + synthetic. Replace each `expandedSpringBone.colliders.filter {...}.count` with a combined count:

```swift
        let allColliders = expandedSpringBone.colliders + expandedSpringBone.syntheticColliders
        let totalSpheres = allColliders.filter {
            switch $0.shape { case .sphere, .insideSphere: return true; default: return false }
        }.count
        let totalCapsules = allColliders.filter {
            switch $0.shape { case .capsule, .insideCapsule: return true; default: return false }
        }.count
        let totalPlanes = allColliders.filter {
            switch $0.shape { case .plane: return true; default: return false }
        }.count
```

(The rest of `initializeSpringBoneGPUSystem` — `allocateBuffers`, `SpringBoneGlobalParams` — already reads these totals, so it now sizes for the augmented set with no further change.)

- [ ] **Step 4: Wire the augmentor into upload + group/mask logic in `populateSpringBoneData`.**

In `SpringBoneComputeSystem.swift`, find where the upload arrays are built from `springBone.colliders` (the `switch shape` loop ~838-882) and where `colliderToGroupIndex` (~700-712) and per-spring `colliderGroupMask` (~721-737) are built.

(a) Define the synthetic group index once (one past authored groups, clamped):

```swift
        let syntheticGroupIndex = UInt32(min(springBone.colliderGroups.count, 31))
        let syntheticGroupBit: UInt32 = 1 << syntheticGroupIndex
```

(b) In the per-spring mask loop, OR the synthetic bit into EVERY spring's mask (so all chains see synthetic colliders), after the existing mask is computed:

```swift
            colliderGroupMask |= syntheticGroupBit
```

(This applies whether or not the spring had explicit groups — including the `0xFFFFFFFF` no-group default, where it is a no-op.)

(c) In the collider-upload loop, iterate authored colliders **then** synthetic colliders. Synthetic colliders use `syntheticGroupIndex` for their `groupIndex` (they are not in `colliderToGroupIndex`). Concretely, after the existing authored loop appends to `sphereColliders`/`capsuleColliders`/`planeColliders`, append a second pass:

```swift
        for collider in springBone.syntheticColliders {
            guard collider.node >= 0, collider.node < model.nodes.count else { continue }
            let colliderNode = model.nodes[collider.node]
            let worldRotation = simd_quatf(colliderNode.worldMatrix)   // same extraction the authored path uses
            switch collider.shape {
            case .sphere(let offset, let radius):
                let center = colliderNode.worldPosition + worldRotation.act(offset)
                sphereColliders.append(SphereCollider(center: center, radius: radius, groupIndex: syntheticGroupIndex))
            case .capsule(let offset, let radius, let tail):
                let p0 = colliderNode.worldPosition + worldRotation.act(offset)
                let p1 = p0 + worldRotation.act(tail)
                capsuleColliders.append(CapsuleCollider(p0: p0, p1: p1, radius: radius, groupIndex: syntheticGroupIndex))
            default:
                continue   // augmentor only emits spheres/capsules
            }
        }
```

Match the **exact** world-rotation extraction and `SphereCollider`/`CapsuleCollider` initializer argument labels used by the authored path immediately above (copy its idiom verbatim — e.g. if it uses `worldRotation * offset` rather than `.act`, use that). The default `groupIndex`/`inside` argument behavior must match the authored `.sphere`/`.capsule` cases.

- [ ] **Step 5: Build, then run the augmentor + parity tests.**

Run: `swift build 2>&1 | tail -15`
Run: `swift test --filter SpringBoneColliderAugmentorTests --disable-sandbox 2>&1 | tail -20`
Expected: both PASS (empty generator → 0 synthetic; `.off` path unchanged).

- [ ] **Step 6: Confirm the four stress tests are still RED with the empty generator (no regression in the reproduction).**

Run: `swift test --filter SpringBoneStressPosePenetrationTests --disable-sandbox 2>&1 | tail -20`
Expected: all four still pass against `augment:false` (bug still reproduced; wiring didn't change authored behavior).

- [ ] **Step 7: Commit.**

```bash
git add Sources/VRMMetalKit/SpringBone/SpringBoneColliderAugmentor.swift \
        Sources/VRMMetalKit/Core/VRMModel.swift \
        Sources/VRMMetalKit/SpringBoneComputeSystem.swift \
        Tests/VRMMetalKitTests/SpringBone/SpringBoneColliderAugmentorTests.swift
git commit -m "feat(springbone): allocation+upload seam for synthetic colliders, empty generator (#309)"
```

---

## Phase 2 — Limb capsules (turns arms/crossed/seated green)

### Task 7: Generate end-to-end limb capsules

**Files:**
- Modify: `Sources/VRMMetalKit/SpringBone/SpringBoneColliderAugmentor.swift`
- Modify: `Tests/VRMMetalKitTests/SpringBone/SpringBoneColliderAugmentorTests.swift`

- [ ] **Step 1: Write a failing unit test for limb-capsule geometry.**

```swift
    @MainActor
    func testLimbCapsulesSpanBoneToChild() async throws {
        let path = getTestVRM10ModelPath()
        try requireFixture(path, hint: testVRM10Filename)
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device)  // augment default true
        let synth = SpringBoneColliderAugmentor.synthesize(model: model)

        // Expect a capsule anchored at leftUpperArm whose world-space far end
        // reaches leftLowerArm.
        guard let humanoid = model.humanoid,
              let uaNode = humanoid.getBoneNode(.leftUpperArm),
              let laNode = humanoid.getBoneNode(.leftLowerArm) else {
            throw XCTSkip("Model lacks arm bones")
        }
        let uaPos = model.nodes[uaNode].worldPosition
        let laPos = model.nodes[laNode].worldPosition

        let armCapsule = synth.first { c in
            c.node == uaNode
            if case .capsule = c.shape { return c.node == uaNode } else { return false }
        }
        XCTAssertNotNil(armCapsule, "Expected a synthetic capsule on leftUpperArm")
        if case let .capsule(offset, radius, tail)? = armCapsule?.shape {
            let worldRot = simd_quatf(model.nodes[uaNode].worldMatrix)
            let p0 = uaPos + worldRot.act(offset)
            let p1 = p0 + worldRot.act(tail)
            XCTAssertLessThan(simd_distance(p1, laPos), 0.01, "Capsule far end should reach the lower arm")
            XCTAssertGreaterThan(radius, 0, "Capsule needs a positive radius")
        }
    }
```

- [ ] **Step 2: Run it to confirm it fails (empty generator).**

Run: `swift test --filter SpringBoneColliderAugmentorTests/testLimbCapsulesSpanBoneToChild --disable-sandbox 2>&1 | tail -20`
Expected: FAIL (`armCapsule` is nil).

- [ ] **Step 3: Implement limb-capsule generation.**

Replace the `return []` in `synthesize` with limb generation:

```swift
    public static func synthesize(model: VRMModel, ratios: Ratios = Ratios()) -> [VRMCollider] {
        guard let humanoid = model.humanoid else { return [] }
        var out: [VRMCollider] = []

        func worldPos(_ bone: VRMHumanoidBone) -> SIMD3<Float>? {
            guard let n = humanoid.getBoneNode(bone), n >= 0, n < model.nodes.count else { return nil }
            return model.nodes[n].worldPosition
        }
        func worldRot(_ node: Int) -> simd_quatf { simd_quatf(model.nodes[node].worldMatrix) }

        // Limb capsule anchored at `from`, far end at `to`'s world position,
        // expressed in `from`'s local space so it rides the bone under animation.
        func limbCapsule(from: VRMHumanoidBone, to: VRMHumanoidBone, radiusFrac: Float) {
            guard let fromNode = humanoid.getBoneNode(from), fromNode >= 0, fromNode < model.nodes.count,
                  let fromPos = worldPos(from), let toPos = worldPos(to) else { return }
            let segWorld = toPos - fromPos
            let length = simd_length(segWorld)
            guard length > 1e-4 else { return }
            let invRot = worldRot(fromNode).inverse
            let tailLocal = invRot.act(segWorld)            // world delta → from-local
            let radius = max(0.01, radiusFrac * length)
            out.append(VRMCollider(node: fromNode,
                                   shape: .capsule(offset: .zero, radius: radius, tail: tailLocal)))
        }

        let a = ratios.armRadiusFractionOfLength
        let l = ratios.legRadiusFractionOfLength
        limbCapsule(from: .leftUpperArm,  to: .leftLowerArm,  radiusFrac: a)
        limbCapsule(from: .leftLowerArm,  to: .leftHand,      radiusFrac: a)
        limbCapsule(from: .rightUpperArm, to: .rightLowerArm, radiusFrac: a)
        limbCapsule(from: .rightLowerArm, to: .rightHand,     radiusFrac: a)
        limbCapsule(from: .leftUpperLeg,  to: .leftLowerLeg,  radiusFrac: l)
        limbCapsule(from: .leftLowerLeg,  to: .leftFoot,      radiusFrac: l)
        limbCapsule(from: .rightUpperLeg, to: .rightLowerLeg, radiusFrac: l)
        limbCapsule(from: .rightLowerLeg, to: .rightFoot,     radiusFrac: l)
        return out
    }
```

- [ ] **Step 4: Run the unit test; verify it passes.**

Run: `swift test --filter SpringBoneColliderAugmentorTests/testLimbCapsulesSpanBoneToChild --disable-sandbox 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Add the green stress assertions for limb-driven poses.**

Append to `SpringBoneStressPosePenetrationTests.swift`:

```swift
    @MainActor func testArmsRaised_augmented_noPenetration() async throws {
        let (rate, worst) = try await measurePenetrationRate(pose: .armsRaised, augment: true)
        XCTAssertLessThan(rate, Self.maxPenetrationRate, "Augmented colliders should keep hair outside the oracle in arms-raised (rate \(rate), worst \(worst)m)")
    }
    @MainActor func testArmsCrossed_augmented_noPenetration() async throws {
        let (rate, worst) = try await measurePenetrationRate(pose: .armsCrossed, augment: true)
        XCTAssertLessThan(rate, Self.maxPenetrationRate, "Augmented colliders should keep hair outside the oracle in arms-crossed (rate \(rate), worst \(worst)m)")
    }
    @MainActor func testSeatedDeepFlexion_augmented_noPenetration() async throws {
        let (rate, worst) = try await measurePenetrationRate(pose: .seatedDeepFlexion, augment: true)
        XCTAssertLessThan(rate, Self.maxPenetrationRate, "Augmented colliders should keep hair outside the oracle in seated deep-flexion (rate \(rate), worst \(worst)m)")
    }
```

- [ ] **Step 6: Run the three augmented limb tests.**

Run: `swift test --filter SpringBoneStressPosePenetrationTests --disable-sandbox 2>&1 | tail -40`
Expected: the three `*_augmented_noPenetration` tests for armsRaised / armsCrossed / seatedDeepFlexion PASS. (`lookUp_augmented` is added in Phase 3.) If one fails, tune `armRadiusFractionOfLength` / `legRadiusFractionOfLength` upward and re-run — do **not** edit the oracle to match the generator.

- [ ] **Step 7: Commit.**

```bash
git add Sources/VRMMetalKit/SpringBone/SpringBoneColliderAugmentor.swift \
        Tests/VRMMetalKitTests/SpringBone/SpringBoneColliderAugmentorTests.swift \
        Tests/VRMMetalKitTests/SpringBone/SpringBoneStressPosePenetrationTests.swift
git commit -m "feat(springbone): end-to-end limb capsules close arm/skirt clipping (#309)"
```

---

## Phase 3 — Head/brow capsule (turns look-up green)

### Task 8: Generate the forward head/brow capsule

**Files:**
- Modify: `Sources/VRMMetalKit/SpringBone/SpringBoneColliderAugmentor.swift`
- Modify: `Tests/VRMMetalKitTests/SpringBone/SpringBoneColliderAugmentorTests.swift`

- [ ] **Step 1: Write a failing unit test for the head capsule (ratios, forward placement).**

```swift
    @MainActor
    func testHeadCapsuleSitsForwardOfHeadCenter() async throws {
        let path = getTestVRM10ModelPath()
        try requireFixture(path, hint: testVRM10Filename)
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device)
        guard let humanoid = model.humanoid, let headNode = humanoid.getBoneNode(.head) else {
            throw XCTSkip("No head bone")
        }
        let synth = SpringBoneColliderAugmentor.synthesize(model: model)
        let headCapsule = synth.first { $0.node == headNode && { if case .capsule = $0.shape { return true } else { return false } }() }
        XCTAssertNotNil(headCapsule, "Expected a synthetic head/brow capsule")

        // Its far end must sit forward of the head origin in head-local +Z.
        if case let .capsule(offset, radius, tail)? = headCapsule?.shape {
            let farEndLocalZ = offset.z + tail.z
            XCTAssertGreaterThan(farEndLocalZ, 0, "Brow capsule must extend forward (+Z) of head center")
            XCTAssertGreaterThan(radius, 0)
        }
    }
```

- [ ] **Step 2: Run it; confirm it fails.**

Run: `swift test --filter SpringBoneColliderAugmentorTests/testHeadCapsuleSitsForwardOfHeadCenter --disable-sandbox 2>&1 | tail -20`
Expected: FAIL (no head capsule yet).

- [ ] **Step 3: Implement the head capsule using head-sphere radius as the ratio base.**

Add, inside `synthesize` before `return out`, a head-capsule emitter that derives its scale from the authored head sphere radius (falling back to a head→neck length proxy):

```swift
        // Head/brow capsule. Scale from the authored head sphere radius (skull
        // scale); ratios — never raw world distances — keep it generalizable.
        if let headNode = humanoid.getBoneNode(.head), headNode >= 0, headNode < model.nodes.count {
            // Reference radius: authored head sphere radius if present, else
            // a fraction of head→neck (or head→top) length.
            var rHead: Float = 0
            if let sb = model.springBone {
                for c in sb.colliders where c.node == headNode {
                    if case let .sphere(_, radius) = c.shape { rHead = max(rHead, radius) }
                    if case let .insideSphere(_, radius) = c.shape { rHead = max(rHead, radius) }
                }
            }
            if rHead <= 0, let neck = worldPos(.neck), let head = worldPos(.head) {
                rHead = 0.9 * simd_length(head - neck)
            }
            if rHead > 0 {
                // Head-local axes: +Z forward (parser normalizes VRM0 -Z facing),
                // -Y down. Capsule sweeps from above-center forward to brow.
                let fwd = ratios.headForwardFraction * rHead
                let down = ratios.headDownFraction * rHead
                let offset = SIMD3<Float>(0,  0.10 * rHead,  0.20 * rHead)  // near upper face
                let tail   = SIMD3<Float>(0, -down,           fwd)          // sweep forward & down
                let radius = ratios.headRadiusFraction * rHead
                out.append(VRMCollider(node: headNode,
                                       shape: .capsule(offset: offset, radius: radius, tail: tail)))
            }
        }
```

- [ ] **Step 4: Run the head unit test; verify it passes.**

Run: `swift test --filter SpringBoneColliderAugmentorTests/testHeadCapsuleSitsForwardOfHeadCenter --disable-sandbox 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Add the look-up green assertion.**

Append to `SpringBoneStressPosePenetrationTests.swift`:

```swift
    @MainActor func testLookUp_augmented_noPenetration() async throws {
        let (rate, worst) = try await measurePenetrationRate(pose: .lookUp, augment: true)
        XCTAssertLessThan(rate, Self.maxPenetrationRate, "Augmented head/brow capsule should keep hair off the forehead in look-up (rate \(rate), worst \(worst)m)")
    }
```

- [ ] **Step 6: Run; tune ratios against AvatarSample_A until look-up is green.**

Run: `swift test --filter SpringBoneStressPosePenetrationTests/testLookUp_augmented_noPenetration --disable-sandbox 2>&1 | tail -20`
Expected: PASS. If it fails, adjust `headForwardFraction` / `headDownFraction` / `headRadiusFraction` (and the `0.10`/`0.20` placement fractions) and re-run. These are ratios of `rHead`, so they generalize. Do **not** edit the oracle to match.

- [ ] **Step 7: Verify the full stress suite is green for augment, red for current.**

Run: `swift test --filter SpringBoneStressPosePenetrationTests --disable-sandbox 2>&1 | tail -40`
Expected: all four `*_currentColliders_penetrate` pass (bug reproduced) AND all four `*_augmented_noPenetration` pass (fix verified).

- [ ] **Step 8: Commit.**

```bash
git add Sources/VRMMetalKit/SpringBone/SpringBoneColliderAugmentor.swift \
        Tests/VRMMetalKitTests/SpringBone/SpringBoneColliderAugmentorTests.swift \
        Tests/VRMMetalKitTests/SpringBone/SpringBoneStressPosePenetrationTests.swift
git commit -m "feat(springbone): forward head/brow capsule closes hair-into-forehead (#309)"
```

---

### Task 9: Tune against a VRoid-family representative (generalization guard)

**Files:**
- Modify: `Sources/VRMMetalKit/SpringBone/SpringBoneColliderAugmentor.swift` (ratios only, if needed)

- [ ] **Step 1: Identify a second VRoid-family test model if available.**

Run: `rg -n "VRM_TEST_VRM1_PATH|getTestModelPath|\.vrm\.glb" Tests/VRMMetalKitTests/TestHelpers.swift; ls *.vrm.glb *.vroid 2>/dev/null`
If a second VRoid model exists (e.g. `model_dd.vroid` in the repo root, or a path via env var), use it; otherwise SKIP this task and record that generalization was validated only against AvatarSample_A (note it in the PR).

- [ ] **Step 2: Add a smoke test that the generator produces sane geometry on the second model.**

```swift
    @MainActor
    func testGeneratorProducesFiniteCapsulesOnSecondModel() async throws {
        guard let p = ProcessInfo.processInfo.environment["VRM_TEST_VROID2_PATH"], !p.isEmpty else {
            throw XCTSkip("No second VRoid model configured (set VRM_TEST_VROID2_PATH)")
        }
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let model = try await VRMModel.load(from: URL(fileURLWithPath: p), device: device)
        let synth = SpringBoneColliderAugmentor.synthesize(model: model)
        XCTAssertFalse(synth.isEmpty, "Generator should emit colliders for a humanoid VRoid model")
        for c in synth {
            if case let .capsule(offset, radius, tail) = c.shape {
                XCTAssert(radius.isFinite && radius > 0)
                XCTAssert(offset.x.isFinite && tail.x.isFinite)
            }
        }
    }
```

- [ ] **Step 3: Run it (skips cleanly if no model).**

Run: `swift test --filter SpringBoneColliderAugmentorTests/testGeneratorProducesFiniteCapsulesOnSecondModel --disable-sandbox 2>&1 | tail -15`
Expected: PASS or SKIP. If geometry is wildly off on the second model (manual render check), nudge ratios so both models stay green; commit ratio changes.

- [ ] **Step 4: Commit (only if changes made).**

```bash
git add Sources/VRMMetalKit/SpringBone/SpringBoneColliderAugmentor.swift \
        Tests/VRMMetalKitTests/SpringBone/SpringBoneColliderAugmentorTests.swift
git commit -m "test(springbone): VRoid-family generalization smoke test for augmentor (#309)"
```

---

## Phase 4 — Validation, baselines, release prep

### Task 10: Re-baseline the neutral SpringBone regression CSV

**Files:**
- Modify: `Tests/VRMMetalKitTests/TestData/SpringBoneRegression/avatar_a_baseline.csv`

- [ ] **Step 1: Confirm the neutral regression test now differs (augmentation changes equilibrium).**

Run: `swift test --filter SpringBoneRegressionTests --disable-sandbox 2>&1 | tail -30`
Expected: the trajectory test FAILS (per-bone means shifted because synthetic colliders alter resting positions) — this is expected and desired.

- [ ] **Step 2: Regenerate the baseline under augmentation (default on).**

Run: `VRM162_REGENERATE_BASELINE=1 swift test --filter SpringBoneRegressionTests --disable-sandbox 2>&1 | tail -20`
Expected: prints "Regenerated baseline at .../avatar_a_baseline.csv".

- [ ] **Step 3: Re-run to confirm the new baseline passes.**

Run: `swift test --filter SpringBoneRegressionTests --disable-sandbox 2>&1 | tail -15`
Expected: PASS.

- [ ] **Step 4: Sanity-check the diff is physically plausible (not NaN / not collapsed).**

Run: `git diff --stat Tests/VRMMetalKitTests/TestData/SpringBoneRegression/avatar_a_baseline.csv`
Inspect a few rows: positions should shift by mm–cm, remain finite, and Y stay within the model's height range.

- [ ] **Step 5: Commit.**

```bash
git add Tests/VRMMetalKitTests/TestData/SpringBoneRegression/avatar_a_baseline.csv
git commit -m "test(springbone): re-baseline neutral regression under collider augmentation (#309)"
```

---

### Task 11: Full suite + AvatarSample_A sanity render

**Files:** none (verification + artifact)

- [ ] **Step 1: Run the full SpringBone-related suite.**

Run: `swift test --filter SpringBone --disable-sandbox --parallel --num-workers 14 -j 16 2>&1 | tail -40`
Expected: all pass. Investigate any failure before proceeding (do NOT loosen the oracle or tolerances to pass).

- [ ] **Step 2: Run the existing hair-head collision guard (must still hold).**

Run: `swift test --filter HairHeadCollisionTests --disable-sandbox 2>&1 | tail -20`
Expected: PASS (augmentation should not worsen the existing <1% guard).

- [ ] **Step 3: Regenerate the AvatarSample_A sanity render (per project convention).**

Run the project's `VRMRender` product to produce `AvatarSample_A.png` (the team regenerates this per PR). Confirm the command:
`rg -n "VRMRender|AvatarSample_A.png" README.md Makefile 2>/dev/null | head`
Then run it and visually confirm hair sits on the forehead/face, not inside it, in a look-up framing if the tool supports posing.

- [ ] **Step 4: Build release config to catch optimization-only breaks.**

Run: `swift build --configuration release 2>&1 | tail -10`
Expected: builds clean.

- [ ] **Step 5: Commit any regenerated artifact.**

```bash
git add AvatarSample_A.png 2>/dev/null || true
git commit -m "test(springbone): regenerate AvatarSample_A sanity render under augmentation (#309)" || echo "no artifact change"
```

---

### Task 12: Docs + release notes (behavior change → pre-release)

**Files:**
- Modify: `Sources/VRMMetalKit/VRMMetalKit.docc/Articles/RenderingAvatars.md` (or the SpringBone article, whichever documents physics config)
- Modify: `CHANGELOG.md` (if present)

- [ ] **Step 1: Document the flag and the behavior change.**

Add a short subsection: `VRMLoadingOptions.augmentSpringBoneColliders` (default `true`) synthesizes additive limb + head/brow colliders to reduce SpringBone clipping (#309); set `false` to restore authored-only colliders. Note it is a **behaviour change** that shifts resting spring positions.

- [ ] **Step 2: Add a CHANGELOG entry under a "Behaviour change" heading.**

Run: `ls CHANGELOG.md 2>/dev/null && rg -n "Behaviour change" CHANGELOG.md | head`
Add an entry referencing #309 and the `augmentSpringBoneColliders` escape hatch. Per project policy, the release carrying this must be cut as a **GitHub pre-release** until Muse validates assets.

- [ ] **Step 3: Build docs (if the project builds DocC in CI) or at least confirm no broken symbol links.**

Run: `swift build 2>&1 | tail -5`
Expected: clean.

- [ ] **Step 4: Commit.**

```bash
git add Sources/VRMMetalKit/VRMMetalKit.docc CHANGELOG.md 2>/dev/null
git commit -m "docs(springbone): document collider augmentation flag + behaviour change (#309)"
```

---

## Self-Review

**Spec coverage:**
- §2 additive seam / count-equality contract → Tasks 5, 6 (synthetic stored on `VRMSpringBone`, counted at allocation, uploaded with matching count). ✓
- §2.2 no shader changes → no `.metal` file is touched in any task. ✓
- §3.1 limb capsules (radius from authored / fallback fraction) → Task 7. ✓ (Radius uses `radiusFrac * length` fallback; authored-sphere-radius primary is folded into the head path and the fraction default for limbs — limbs intentionally use the length fraction as primary since authored limb spheres are sparse/various; acceptable per spec "fallback" wording, and tuned in Task 7 Step 6.)
- §3.2 head capsule via RATIOS of head-sphere radius, +Z forward, #299 caveat → Task 8 (ratios in `Ratios`, `farEndLocalZ > 0` test, fallback to head→neck length). ✓
- §3.3 VRoid tuning → Task 9. ✓
- §4 single synthetic group OR'd into every spring mask; §4.1 fourth seated pose → Task 6 Step 4(b), Tasks 3/4/7. ✓
- §5 flag default-on + pre-release + regenerate CSV → Tasks 5, 10, 12. ✓ (Home moved to `VRMLoadingOptions`; deviation documented in header.)
- §6 oracle (test-only, dated, documented), integrity checksum, four poses, red→green → Tasks 1, 2, 3, 4, 7, 8. ✓
- §7 phasing order (oracle+red → seam → limbs → head → validation) → Phases 0–4. ✓
- §8 risks: drift checksum (Task 2), #299 (Task 8 caveat + lookUp test), over-subscription (seated pose Task 3/4), count-equality (Task 6), default-on rebaseline (Task 10). ✓

**Placeholder scan:** Oracle JSON `integrity` zeros are explicitly filled by a measured capture step (Task 2 Steps 2–4), not left as placeholders. No "TBD"/"handle edge cases"/"similar to" remain. Steps that depend on exact existing idioms (world-rotation extraction, renderer attach call, texture helpers) include an explicit `rg` verification step and "mirror the existing path verbatim" instruction rather than guessing.

**Type consistency:** `synthesize(model:ratios:)`, `Ratios`, `SkinReferenceOracle`, `OracleWorldShape`, `worstPenetration(of:shapes:)`, `resolveWorldShapes(model:)`, `StressPose`, `StressPoseFactory.clip(_:duration:)`, `measureIntegrity(model:)`, `augmentSpringBoneColliders`, `syntheticColliders` are used identically across all tasks. `initializeSpringBoneGPUSystem(device:augmentColliders:)` signature is introduced in Task 6 Step 3 and not re-declared elsewhere. `simd_quatf(model.nodes[node].worldMatrix)` and `.act(_:)` rotation application are flagged in Task 6 Step 4 to be matched to the authored path's exact idiom (the one place the existing code's convention must win over the plan's sample).
