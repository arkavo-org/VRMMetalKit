# Capture-Stepping 2b — IK Executor + Stability Validation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn 2a's world-space ankle targets into leg-bone rotations on a real rig, and validate stability with a deterministic moving-CoM model gate plus a real-rig confirmation.

**Architecture:** Extend `CaptureStepController` (2a) with `update(deltaTime:model:rootVelocity:groundY:)` that restores the controller's feet, reads `BalanceModel`, calls 2a's pure `step`, and applies targets via `TwoBoneIKSolver` with a direct parent-frame world→local conversion. Stability is validated on two substrates: a deterministic moving-CoM model (monotone regression-lock) and the real rig (the model's validity gate).

**Tech Stack:** Swift 6.2, `simd`, XCTest, Metal (integration tests load a VRM). Consumes 2a (`CaptureStepController`, `CaptureStepParams`, `step(balance:dt:)`, `plantedPositions`, committed defaults), `BalanceModel`, `TwoBoneIKSolver`.

## Global Constraints

- Swift 6.2; macOS 26+, iOS 26+. Apache 2.0 header on any new file.
- Tests run with `--disable-sandbox`; model-loading tests require a Metal device (`guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip(...) }`).
- **§0 counter-case rule (from the spec):** every gate whose metric can pass *vacuously* (stability/boundedness) ships a paired failing counter-case; direct-measurement metrics (IK position error) get rigor from range coverage + explicit ε instead.
- **Two failure surfaces kept apart:** the IK conversion is verified by itself (Task 1); stability is verified on the model (Task 3, no IK) and the rig (Task 4, reads through IK — depends on Task 1's ε).
- **Restore-IK-before-evaluate (spec §2, Option A):** `update` restores planted feet to their stored world pivots (and the swing foot to its arc) via IK *before* `BalanceModel.evaluate`, so the support polygon AND CoM reflect the controller's feet, not the clip's skating positions. Double-IK per swing frame is accepted (single avatar); single-pass is a deferred optimization.
- **`ε` (Task 1's worst-case ankle placement error across the target range) is an explicit number carried into Task 4 as the residual noise floor.** It is measured, not pre-committed (empirical — same reasoning as 2a's `k`).

---

## File Structure

- **Modify** `Sources/VRMMetalKit/Animation/CaptureStepController.swift` — add `update(deltaTime:model:rootVelocity:groundY:)`, the world→local IK application, and a `restAnkleHeight`/seed-from-rig path. 2a's pure core (`step`, state machine, `CaptureStepMath`) is unchanged.
- **Create** `Tests/VRMMetalKitTests/Animation/CaptureStepIKTests.swift` — the rig-integration tests (Tasks 1, 2, 4).
- **Create** `Tests/VRMMetalKitTests/Animation/CaptureStepStabilityTests.swift` — the deterministic moving-CoM model gate (Task 3, pure).

---

### Task 1: IK executor + world→local conversion (EMPIRICAL — resolved against the known-target gate)

**Files:**
- Modify: `Sources/VRMMetalKit/Animation/CaptureStepController.swift`
- Test: `Tests/VRMMetalKitTests/Animation/CaptureStepIKTests.swift`

**Interfaces:**
- Consumes: `TwoBoneIKSolver.solve(rootPos:midPos:endPos:targetPos:poleVector:) -> SolveResult?` (fields `rootRotation`, `midRotation`, both `simd_quatf`), `VRMModel`, `VRMHumanoidBone`, `BalanceModel.Foot`.
- Produces on `CaptureStepController`:
  - `func placeAnkle(_ foot: BalanceModel.Foot, worldTarget: SIMD3<Float>, model: VRMModel)` — solves + applies the leg IK so the ankle lands at `worldTarget`. **This is the only method that touches bone rotations.**

**This task is empirical.** `TwoBoneIKSolver` returns a **world-space** aim; the exact mapping to hip/knee *local* rotations (whether `rootRotation` is applied as `parentWorldRot⁻¹ · rootRotation`, whether `midRotation` is the knee's local bend directly, whether `initialRotation` rest offsets compose in) is **not** knowable from reading — the compositor path treats them as base-pose deltas. The known-target gate below IS the mechanism to get it right: implement the candidate, run the gate, and iterate the composition until the ankle lands within a tight ε **across the whole target range**.

- [ ] **Step 1: Write the failing gate test (the falsifiable measurement)**

Create `Tests/VRMMetalKitTests/Animation/CaptureStepIKTests.swift`:

```swift
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

final class CaptureStepIKTests: XCTestCase {
    @MainActor private func loadRig() async throws -> VRMModel {
        let path = getTestVRM10ModelPath(); try requireFixture(path, hint: testVRM10Filename)
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device,
                                            options: VRMLoadingOptions(augmentSpringBoneColliders: false))
        model.updateNodeTransforms()
        return model
    }

    @MainActor private func ankleWorld(_ model: VRMModel, _ foot: BalanceModel.Foot) throws -> SIMD3<Float> {
        let bone: VRMHumanoidBone = foot == .left ? .leftFoot : .rightFoot
        let idx = try XCTUnwrap(model.humanoid?.getBoneNode(bone))
        return model.nodes[idx].worldPosition
    }

    /// The IK-correctness gate (spec §2.1): the ankle lands at the world target within
    /// ε ACROSS a range of reachable targets — not right-at-one-point. ε (the measured
    /// worst-case error here) is Task 4's residual noise floor. Rig-only; no stepping.
    @MainActor func testPlaceAnkle_landsAtTargetAcrossRange() async throws {
        let model = try await loadRig()
        let c = CaptureStepController()
        let rest = try ankleWorld(model, .left)
        // A range of reachable targets around the rest ankle: fore/back/lateral, small
        // vertical, within leg reach (offsets ≤ ~0.15 m so the solve doesn't clamp).
        let offsets: [SIMD3<Float>] = [
            SIMD3(0.10, 0, 0), SIMD3(-0.10, 0, 0), SIMD3(0, 0, 0.12), SIMD3(0, 0, -0.12),
            SIMD3(0.08, 0.03, 0.08), SIMD3(-0.08, 0.02, -0.06), SIMD3(0.12, 0, -0.10),
        ]
        var worstError: Float = 0
        for off in offsets {
            let target = rest + off
            c.placeAnkle(.left, worldTarget: target, model: model)
            model.updateNodeTransforms()
            let landed = try ankleWorld(model, .left)
            worstError = max(worstError, simd_distance(landed, target))
        }
        // ε: the ankle must land essentially at the target everywhere in range.
        XCTAssertLessThan(worstError, 0.01, "worst-case placement error (ε) across the target range")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter "CaptureStepIKTests/testPlaceAnkle_landsAtTargetAcrossRange" --disable-sandbox`
Expected: FAIL — `value of type 'CaptureStepController' has no member 'placeAnkle'`.

- [ ] **Step 3: Implement the candidate conversion**

Add to `CaptureStepController` in `CaptureStepController.swift` (imports there are `Foundation`/`simd`; add `import Metal`? No — `VRMModel` is in-module, no Metal import needed for the type). Candidate:

```swift
    /// Solve two-bone leg IK and apply it so `foot`'s ankle lands at `worldTarget`.
    /// The ONLY method that writes bone rotations (2b's IK surface). The exact world→
    /// local composition is calibrated against `testPlaceAnkle_landsAtTargetAcrossRange`.
    public func placeAnkle(_ foot: BalanceModel.Foot, worldTarget: SIMD3<Float>, model: VRMModel) {
        guard let humanoid = model.humanoid else { return }
        let (up, lo, en): (VRMHumanoidBone, VRMHumanoidBone, VRMHumanoidBone) =
            foot == .left ? (.leftUpperLeg, .leftLowerLeg, .leftFoot)
                          : (.rightUpperLeg, .rightLowerLeg, .rightFoot)
        guard let hipIdx = humanoid.getBoneNode(up), let kneeIdx = humanoid.getBoneNode(lo),
              let ankleIdx = humanoid.getBoneNode(en),
              hipIdx < model.nodes.count, kneeIdx < model.nodes.count, ankleIdx < model.nodes.count
        else { return }

        let hipPos = model.nodes[hipIdx].worldPosition
        let kneePos = model.nodes[kneeIdx].worldPosition
        let anklePos = model.nodes[ankleIdx].worldPosition
        guard let r = TwoBoneIKSolver.solve(rootPos: hipPos, midPos: kneePos, endPos: anklePos,
                                            targetPos: worldTarget,
                                            poleVector: SIMD3<Float>(0, 0, 1)) else { return }

        // CANDIDATE conversion — calibrate against the known-target gate:
        // set the hip's WORLD rotation to the solver's aim, then the knee relative to
        // the POST-hip-write upper-leg frame (Redline 2: never the stale pre-IK cache).
        let hipParentWorld = worldRotation(model.nodes[hipIdx].parent?.worldMatrix)
        model.nodes[hipIdx].rotation = simd_normalize(hipParentWorld.inverse * r.rootRotation)
        model.nodes[hipIdx].updateLocalMatrix(); model.nodes[hipIdx].updateWorldTransform()
        let kneeParentWorld = worldRotation(model.nodes[kneeIdx].parent?.worldMatrix)  // now post-hip-write
        model.nodes[kneeIdx].rotation = simd_normalize(kneeParentWorld.inverse * (r.rootRotation * r.midRotation))
        model.nodes[kneeIdx].updateLocalMatrix(); model.nodes[kneeIdx].updateWorldTransform()
    }

    /// Orthonormalized rotation quaternion from a (possibly scaled) world matrix.
    private func worldRotation(_ m: simd_float4x4?) -> simd_quatf {
        guard let m = m else { return simd_quatf(ix: 0, iy: 0, iz: 0, r: 1) }
        let c0 = simd_normalize(SIMD3<Float>(m[0][0], m[0][1], m[0][2]))
        let c1 = simd_normalize(SIMD3<Float>(m[1][0], m[1][1], m[1][2]))
        let c2 = simd_normalize(SIMD3<Float>(m[2][0], m[2][1], m[2][2]))
        return simd_quatf(simd_float3x3(c0, c1, c2))
    }
```

- [ ] **Step 4: CALIBRATE the conversion against the gate**

Run: `swift test --filter "CaptureStepIKTests/testPlaceAnkle_landsAtTargetAcrossRange" --disable-sandbox`

If the worst-case error exceeds ε (0.01), the composition is wrong. Iterate the two write lines in `placeAnkle` — the candidate above is a starting point, not a proven formula. Systematically try: (a) knee local `= kneeParentWorld.inverse * r.rootRotation * r.midRotation` (candidate), (b) knee local `= r.midRotation` directly (if the solver already returns a knee-local bend), (c) composing each bone's `initialRotation` rest offset (`... * model.nodes[idx].initialRotation`), (d) the hip write conjugating a delta rather than setting absolute. After each change, re-run and read the worst-case error. **Stop when the gate passes across the whole range.** Record the final composition and the achieved ε in the report — that ε becomes Task 4's noise floor. If no composition lands within 0.01 across the range, report the best achieved ε and the sequences tried (do not loosen the assertion to force a pass).

- [ ] **Step 5: Run to verify it passes; commit**

Run: `swift test --filter "CaptureStepIKTests" --disable-sandbox` → PASS.

```bash
git add Sources/VRMMetalKit/Animation/CaptureStepController.swift Tests/VRMMetalKitTests/Animation/CaptureStepIKTests.swift
git commit -m "feat(stepping): leg IK executor (placeAnkle) calibrated to ε across target range"
```

---

### Task 2: `update()` + restore-IK + real-rig follow/moonwalk + non-interference + polygon gate

**Files:**
- Modify: `Sources/VRMMetalKit/Animation/CaptureStepController.swift`
- Test: `Tests/VRMMetalKitTests/Animation/CaptureStepIKTests.swift`

**Interfaces:**
- Consumes: `placeAnkle` (Task 1), 2a's `step(balance:dt:)`/`seed`/`plantedFeet`/`plantedPositions`/`target`, `BalanceModel.evaluate`.
- Produces on `CaptureStepController`:
  - `var isEnabled: Bool` (default `true`)
  - `func update(deltaTime: Float, model: VRMModel, rootVelocity: SIMD3<Float> = .zero, groundY: Float = 0)` — the full frame: seed-once, **restore-IK planted feet + swing foot before evaluate**, evaluate, `step`, apply targets via `placeAnkle`. No-op when `!isEnabled`.

- [ ] **Step 1: Write the failing tests**

Append to `CaptureStepIKTests`:

```swift
    /// Restore-IK polygon gate (spec Redline 1): under a driven root the support-polygon
    /// corners at decision time match the controller's plantedPositions — proving the
    /// clip's skating leg positions never reach BalanceModel.evaluate.
    @MainActor func testUpdate_supportPolygonMatchesPlantedPositions_underDrivenRoot() async throws {
        let model = try await loadRig()
        let c = CaptureStepController()
        // First update seeds from the rig.
        c.update(deltaTime: 1.0 / 60.0, model: model)
        // Drive the root laterally (the moonwalk disturbance) and step a few frames.
        for f in 1...20 {
            for root in model.nodes where root.parent == nil {
                root.translation.x = 0.01 * Float(f)      // slow scripted approach
            }
            model.updateNodeTransforms()
            c.update(deltaTime: 1.0 / 60.0, model: model)
        }
        // The polygon BalanceModel would build from the rig's planted feet must equal
        // the controller's stored planted positions (within IK ε), i.e. no skate leaked in.
        let planted = c.plantedPositions()
        for p in planted {
            let bone: VRMHumanoidBone = .leftFoot   // check both feet below
            _ = bone
        }
        // Compare each planted foot's rig world position to the controller's stored one.
        for foot in [BalanceModel.Foot.left, .right] where c.plantedFeet.contains(foot) {
            let boneIdx = try XCTUnwrap(model.humanoid?.getBoneNode(foot == .left ? .leftFoot : .rightFoot))
            let rig = model.nodes[boneIdx].worldPosition
            let stored = c.target(foot)
            XCTAssertLessThan(simd_distance(rig, stored), 0.02,
                              "evaluate-time foot (\(foot)) reflects the controller, not the clip skate")
        }
    }

    @MainActor func testUpdate_disabledIsBitIdenticalNoOp() async throws {
        let model = try await loadRig()
        let hipsIdx = try XCTUnwrap(model.humanoid?.getBoneNode(.leftUpperLeg))
        let before = model.nodes[hipsIdx].rotation
        let c = CaptureStepController()
        c.isEnabled = false
        c.update(deltaTime: 1.0 / 60.0, model: model)
        XCTAssertEqual(model.nodes[hipsIdx].rotation, before, "disabled ⇒ leg bones untouched")
    }
```

- [ ] **Step 2: Run to verify fail**

Run: `swift test --filter "CaptureStepIKTests" --disable-sandbox`
Expected: FAIL — no `update`/`isEnabled`.

- [ ] **Step 3: Implement `update` with restore-IK-before-evaluate**

Add to `CaptureStepController`:

```swift
    /// Whether the override drives the legs this frame.
    public var isEnabled: Bool = true
    private var seeded = false

    /// One frame: seed-once from the rig, RESTORE the controller's feet before reading
    /// balance (spec §2 / Redline 1), evaluate, decide (2a `step`), apply via IK.
    public func update(deltaTime: Float, model: VRMModel, rootVelocity: SIMD3<Float> = .zero, groundY: Float = 0) {
        guard isEnabled, let humanoid = model.humanoid else { return }
        _ = rootVelocity   // velocity-free default; reserved for the predicted-target hook

        if !seeded {
            if let l = humanoid.getBoneNode(.leftFoot), let r = humanoid.getBoneNode(.rightFoot),
               l < model.nodes.count, r < model.nodes.count {
                seed(leftAnkle: model.nodes[l].worldPosition, rightAnkle: model.nodes[r].worldPosition)
                seeded = true
            } else { return }
        }

        // RESTORE before evaluate: place both feet at the controller's current targets so
        // evaluate's support polygon + CoM reflect the controller, not the clip's skate.
        placeAnkle(.left, worldTarget: target(.left), model: model)
        placeAnkle(.right, worldTarget: target(.right), model: model)
        model.updateNodeTransforms()

        guard let balance = BalanceModel.evaluate(model: model, groundY: groundY, plantedFeet: plantedFeet) else { return }
        _ = step(balance: balance, dt: deltaTime)

        // Apply the (possibly updated) targets.
        placeAnkle(.left, worldTarget: target(.left), model: model)
        placeAnkle(.right, worldTarget: target(.right), model: model)
        model.updateNodeTransforms()
    }
```

- [ ] **Step 4: Run + add follow/moonwalk**

Run: `swift test --filter "CaptureStepIKTests" --disable-sandbox` → the two tests PASS. Then append the follow/moonwalk behavior test:

```swift
    @MainActor func testUpdate_plantedFootHoldsThenSteps_underSlowApproach() async throws {
        let model = try await loadRig()
        let c = CaptureStepController()
        c.update(deltaTime: 1.0 / 60.0, model: model)
        let firstPlanted = c.plantedPositions().first
        var sawStep = false
        for f in 1...40 {
            for root in model.nodes where root.parent == nil { root.translation.x = 0.012 * Float(f) }
            model.updateNodeTransforms()
            c.update(deltaTime: 1.0 / 60.0, model: model)
            if c.plantedFeet.count == 1 { sawStep = true }   // a swing occurred
        }
        XCTAssertTrue(sawStep, "a step fired as the root dragged the CoM toward the support edge")
        XCTAssertNotNil(firstPlanted)
    }
```

Run again → PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/VRMMetalKit/Animation/CaptureStepController.swift Tests/VRMMetalKitTests/Animation/CaptureStepIKTests.swift
git commit -m "feat(stepping): update() with restore-IK-before-evaluate; follow/moonwalk + polygon + no-op gates"
```

---

### Task 3: Moving-CoM model stability gate (deterministic; monotone hard-assert + cycling counter-case)

**Files:**
- Test: `Tests/VRMMetalKitTests/Animation/CaptureStepStabilityTests.swift`
- (No source change — this drives 2a's pure `step` + `BalanceModel` statics against a MOVING-CoM model. If a shared model helper is useful it lives in the test file.)

**Interfaces:**
- Consumes: 2a's `CaptureStepController.step`, `plantedPositions`, `CaptureStepParams`, `BalanceModel` statics (`supportPolygon`, `stabilityMargin`, `imbalanceDirection`).

**Empirical (calibration):** the committed defaults must produce a **monotone** pass/fail across `captureDistance`, and a just-over-the-line value must cycle. If the model's boundary isn't monotone, that is a FAILURE surfaced loudly (the `L` model is wrong) — do not paper over it; adjust the model's self-feedback coefficient to match the mechanism, or report the non-monotonicity.

- [ ] **Step 1: Write the failing gate**

Create `Tests/VRMMetalKitTests/Animation/CaptureStepStabilityTests.swift`:

```swift
//
// Copyright 2025 Arkavo
//   (Apache 2.0 header — copy the standard block)
//
import XCTest
import simd
@testable import VRMMetalKit

final class CaptureStepStabilityTests: XCTestCase {
    // Moving-CoM model: the CoM advances by the driver AND shifts with the swung leg's
    // mass toward the plant (spec §4.1 — the FEEDBACK term, without which this is not
    // faithful). legFrac ≈ 0.16 (upper+lower+foot) from the Dempster table.
    private let legFrac: Float = 0.16

    private func balanceFrom(feet: [SIMD3<Float>], com: SIMD3<Float>, footHalf: Float = 0.05) -> BalanceState {
        var corners: [SIMD2<Float>] = []
        for f in feet {
            corners.append(SIMD2<Float>(f.x - footHalf, f.z - footHalf))
            corners.append(SIMD2<Float>(f.x + footHalf, f.z - footHalf))
            corners.append(SIMD2<Float>(f.x + footHalf, f.z + footHalf))
            corners.append(SIMD2<Float>(f.x - footHalf, f.z + footHalf))
        }
        let poly = BalanceModel.supportPolygon(footCorners: corners)
        let cg = SIMD2<Float>(com.x, com.z)
        let (m, c) = BalanceModel.stabilityMargin(comGround: cg, polygon: poly)
        return BalanceState(centerOfMass: com, comGround: cg, supportPolygon: poly,
                            supportCentroid: c, margin: m, imbalanceDirection: BalanceModel.imbalanceDirection(comGround: cg, centroid: c))
    }

    /// Returns true if a sustained-drive run at `cap` stays bounded (converges/holds);
    /// false if the residual grows (limit cycle). CoM moves by driver + swung-leg pull.
    private func stableUnderDrive(cap: Float, damp: Float, drive: Float) -> Bool {
        var p = CaptureStepParams(); p.captureDistance = cap; p.stepDamping = damp
        p.swingDuration = 0.1; p.minStepInterval = 0.2
        let c = CaptureStepController(params: p)
        c.seed(leftAnkle: SIMD3<Float>(-0.1, 0, 0), rightAnkle: SIMD3<Float>(0.1, 0, 0))
        var com = SIMD3<Float>(0, 1, 0)
        let framesPerIter = Int(((p.swingDuration + p.minStepInterval + 0.02) * 60).rounded(.up))
        var residuals: [Float] = []
        for _ in 0..<20 {
            com.x += drive                                   // DRIVER advance (disturbance)
            let feet = c.plantedPositions()
            let b = balanceFrom(feet: feet, com: com)
            residuals.append(max(0, -b.margin))
            let beforeFeet = c.plantedPositions()
            for _ in 0..<framesPerIter { _ = c.step(balance: b, dt: 1.0 / 60.0) }
            // SWUNG-LEG self-feedback: the foot that moved pulls the CoM toward its plant.
            let afterFeet = c.plantedPositions()
            if let moved = zip(afterFeet, beforeFeet).first(where: { simd_distance($0.0, $0.1) > 1e-4 }) {
                com += legFrac * (moved.0 - moved.1)
            }
        }
        // Bounded ⇒ the tail does not exceed the peak (no runaway growth).
        let peak = residuals.max() ?? 0
        let tail = Array(residuals.suffix(5)).max() ?? 0
        return tail <= peak + 1e-3
    }

    /// The stability gate (spec §4.1): pass/fail is MONOTONE in captureDistance (once it
    /// cycles it stays cycling), and a just-over-line value cycles (counter-case, §0).
    func testStability_isMonotoneInCaptureDistance_withCyclingCounterCase() {
        let caps: [Float] = [0.04, 0.08, 0.10, 0.14, 0.20, 0.35, 0.6, 1.0]
        let stable = caps.map { stableUnderDrive(cap: $0, damp: CaptureStepParams.committedStepDampingMin, drive: 0.05) }
        // Monotone: no stable value appears AFTER an unstable one (no bounce).
        if let firstUnstable = stable.firstIndex(of: false) {
            for i in firstUnstable..<stable.count {
                XCTAssertFalse(stable[i], "non-monotone at cap=\(caps[i]): \(Array(zip(caps, stable)))")
            }
        }
        // Counter-case: some over-line cap MUST cycle (else the gate proves nothing).
        XCTAssertTrue(stable.contains(false), "a cycling counter-case exists: \(Array(zip(caps, stable)))")
        // Committed default is on the stable side.
        XCTAssertTrue(stableUnderDrive(cap: CaptureStepParams.committedCaptureDistanceMax,
                                       damp: CaptureStepParams.committedStepDampingMin, drive: 0.05),
                      "committed captureDistance is stable under the moving-CoM model")
    }
}
```

- [ ] **Step 2: Run to verify it fails, then CALIBRATE**

Run: `swift test --filter "CaptureStepStabilityTests" --disable-sandbox`

The test may fail on monotonicity or on the counter-case. Investigate:
- If **no** cap cycles (all stable), the drive is too weak or the self-feedback too small to induce a cycle → raise `drive` (0.08, 0.12) until a large cap cycles (per spec §4.2 minor: counter-case-unreachable is never terminal).
- If the boundary is **non-monotone** (a stable cap after an unstable one), the moving-CoM model is wrong — the self-feedback term does not match the mechanism. This is a loud failure per §4.1; adjust the self-feedback model (e.g. the leg centroid moves ~half the foot displacement, so try `com += legFrac * 0.5 * (moved.0 - moved.1)`, or distribute over the swing) until the boundary is monotone, OR report the non-monotonicity as a model defect.

Record the final `drive`, self-feedback form, and the `(cap, stable)` table in the report.

- [ ] **Step 3: Commit**

```bash
git add Tests/VRMMetalKitTests/Animation/CaptureStepStabilityTests.swift
git commit -m "feat(stepping): moving-CoM model stability gate (monotone + cycling counter-case)"
```

---

### Task 4: Real-rig stability confirmation (the model's validity gate)

**Files:**
- Test: `Tests/VRMMetalKitTests/Animation/CaptureStepIKTests.swift`
- Modify: `Sources/VRMMetalKit/Animation/CaptureStepController.swift` (re-doc the committed constants: provisional → validated by both gates)

**Interfaces:**
- Consumes: `update` (Task 2), Task 1's measured `ε`, Task 3's committed defaults + over-gain counter-case cap.

**Empirical.** Drive a sustained disturbance on the real rig at the committed `captureDistance` and at an over-gain cap; the committed run must hold/contract above the ε floor with **zero clamp events**, the over-gain run must grow. If the rig grows where the model said stable, **correct the model (Task 3), not this test.**

- [ ] **Step 1: Write the failing confirmation test**

Append to `CaptureStepIKTests` (uses the Task-1 measured ε — substitute the number recorded in Task 1's report for `epsilon` below):

```swift
    /// Real-rig stability confirmation (spec §4.2): at the committed captureDistance a
    /// sustained shove does NOT grow the residual (beyond ε), with zero clamp events;
    /// an over-gain cap DOES grow (counter-case). This is the model's VALIDITY gate.
    @MainActor func testRigStability_committedHolds_overGainGrows() async throws {
        let epsilon: Float = 0.01   // Task 1's measured worst-case placement error (ε)

        func residualPeakTail(cap: Float) async throws -> (peak: Float, tail: Float, clamps: Int) {
            let model = try await loadRig()
            var p = CaptureStepParams(); p.captureDistance = cap
            p.stepDamping = CaptureStepParams.committedStepDampingMin
            let c = CaptureStepController(params: p)
            c.update(deltaTime: 1.0 / 60.0, model: model)
            var residuals: [Float] = []
            var clamps = 0
            for f in 1...120 {
                for root in model.nodes where root.parent == nil { root.translation.x = 0.02 * Float(f) }  // sustained shove
                model.updateNodeTransforms()
                c.update(deltaTime: 1.0 / 60.0, model: model)
                if let b = BalanceModel.evaluate(model: model, plantedFeet: c.plantedFeet) {
                    residuals.append(max(0, -b.margin))
                }
                // Clamp guard (spec §4.3): a step target beyond leg reach voids ε.
                if c.lastStepClamped { clamps += 1 }
            }
            let peak = residuals.max() ?? 0
            let tail = Array(residuals.suffix(10)).max() ?? 0
            return (peak, tail, clamps)
        }

        let committed = try await residualPeakTail(cap: CaptureStepParams.committedCaptureDistanceMax)
        XCTAssertEqual(committed.clamps, 0, "no clamp events during the committed run (ε floor stays valid)")
        XCTAssertLessThanOrEqual(committed.tail, committed.peak + epsilon,
                                 "committed captureDistance holds — residual does not grow beyond ε")

        // Over-gain counter-case: some large cap must visibly grow on the rig.
        let overGain = try await residualPeakTail(cap: 0.8)
        XCTAssertGreaterThan(overGain.tail, overGain.peak * 0.5 + epsilon,
                             "over-gain captureDistance grows/oscillates — the metric discriminates")
    }
```

- [ ] **Step 2: Run to verify fail (needs `lastStepClamped`)**

Run: `swift test --filter "CaptureStepIKTests/testRigStability_committedHolds_overGainGrows" --disable-sandbox`
Expected: FAIL — `CaptureStepController` has no `lastStepClamped`.

- [ ] **Step 3: Add clamp tracking + calibrate**

The step target can exceed leg reach; 2a's `step` returns a target regardless, and `placeAnkle`'s solver clamps unreachably-far targets. Add a `lastStepClamped` flag set when a placed target's distance from the hip exceeds the leg length. In `placeAnkle`, after computing `hipPos`, compare `simd_distance(worldTarget, hipPos)` to the summed leg length (`TwoBoneIKSolver.boneLength(hipPos,kneePos)+boneLength(kneePos,anklePos)`); set `lastStepClamped = true` if it exceeds. Expose `public private(set) var lastStepClamped = false` (reset at the top of `update`).

Then run the confirmation. Calibrate per §4.2:
- If the committed run **grows** (rig unstable where the model said stable): the model (Task 3) is wrong — return to Task 3, correct the self-feedback, re-run both. Do NOT loosen this test.
- If the over-gain (0.8) run does **not** grow: raise the over-gain cap and/or the shove magnitude until it demonstrably grows (counter-case reachability, §4.2 minor).

Record the committed peak/tail, the over-gain peak/tail, and the clamp count.

- [ ] **Step 4: Promote the committed constants; run full suite**

When both gates are green (Task 3 model + Task 4 rig), re-doc the committed constants in `CaptureStepController.swift` — change "provisional defaults pending 2b's stability validation" to "validated stable by the 2b model gate (monotone) AND the rig confirmation; changing either constant re-triggers both gates."

Run: `swift test --filter "CaptureStepIKTests|CaptureStepStabilityTests|CaptureStepControllerTests" --disable-sandbox` → all PASS. `swift build` → Build complete.

- [ ] **Step 5: Commit**

```bash
git add Sources/VRMMetalKit/Animation/CaptureStepController.swift Tests/VRMMetalKitTests/Animation/CaptureStepIKTests.swift
git commit -m "feat(stepping): real-rig stability confirmation + promote committed defaults to validated"
```

---

## Self-Review

**Spec coverage:**
- §0 counter-case rule (vacuous-metric distinction) → Task 3 (cycling counter-case), Task 4 (over-gain counter-case), Task 1 (range+ε, not a failing case). ✓
- §1 two failure surfaces apart → Task 1 (IK isolated), Task 3 (model, no IK), Task 4 (rig, depends on ε). ✓
- §2 IK executor + restore-IK-before-evaluate + chained-frame + velocity-free → Tasks 1–2. ✓
- §2.1 IK gate: ankle-at-target within ε across range; ε explicit → Task 1. ✓
- §3 follow/moonwalk + non-interference + polygon gate → Task 2. ✓
- §4.1 moving-CoM model with swung-leg self-feedback; monotone hard-assert + cycling case → Task 3. ✓
- §4.2 rig confirmation: committed holds / over-gain grows; both required; model-corrected-not-waived → Task 4. ✓
- §4.3 ε flows to Task 4 as noise floor; clamp guard (zero clamp events) → Task 4. ✓
- §4.2 counter-case reachability (escalate disturbance) → Task 3 & 4 calibration steps. ✓

**Placeholder scan:** the IK conversion (Task 1) and stability model (Task 3) are explicitly EMPIRICAL with concrete calibration loops, candidate code, and stated stop conditions — not vague "tune it." `ε = 0.01` in Task 4 is a placeholder to be replaced by Task 1's measured value (called out in the step). No other placeholders.

**Type consistency:** `placeAnkle(_:worldTarget:model:)`, `update(deltaTime:model:rootVelocity:groundY:)`, `isEnabled`, `lastStepClamped`, and 2a's `step`/`seed`/`plantedFeet`/`plantedPositions`/`target` are used identically across tasks. `BalanceModel.Foot`, `BalanceState`, `CaptureStepParams.committed*` match increments 1/2a.

**Risk callout for execution:** Tasks 1, 3, 4 are calibration/research tasks (not transcription) — run them at a capable tier, not the cheapest. Task 1's ε is a hard dependency for Task 4; if Task 1 can't hit a tight ε, Task 4's noise floor loosens and the confirmation weakens — surface that rather than proceeding silently.
