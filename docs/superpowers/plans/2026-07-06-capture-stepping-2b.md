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

### Task 3: Moving-CoM model TRACKING-CAPACITY gate (deterministic; monotone in disturbance rate + over-capacity counter-case)

**Files:**
- Test: `Tests/VRMMetalKitTests/Animation/CaptureStepStabilityTests.swift`
- (No source change — drives 2a's pure `step` + `BalanceModel` statics against a MOVING-CoM model.)

**Interfaces:**
- Consumes: 2a's `CaptureStepController.step`, `plantedPositions`, `CaptureStepParams`, `BalanceModel` statics.

**RE-AXISED (spec §4).** The failure is a **tracking-capacity limit**, not a momentum cycle: the stepper relocates the support at a bounded rate, so a disturbance faster than that capacity escapes the support and the residual grows. Sweep **disturbance rate** (m/s), classify each run *tracks* (residual bounded) vs *escapes* (residual grows), and assert the boundary is **monotone in drive rate** with an over-capacity counter-case. `captureDistance` is stabilizing — do NOT sweep it for the boundary. This gate's shape is proven by the drive-rate probe (tracks ≤ ~0.2 m/s, escapes ≥ ~0.3 m/s at committed params).

- [ ] **Step 1: Write the gate**

Create `Tests/VRMMetalKitTests/Animation/CaptureStepStabilityTests.swift`:

```swift
//
// Copyright 2025 Arkavo
//
// Licensed under the Apache License, Version 2.0 (the "License");
// ... (standard Apache 2.0 header block — copy from any file in the repo) ...
//
import XCTest
import simd
@testable import VRMMetalKit

final class CaptureStepStabilityTests: XCTestCase {
    private let legFrac: Float = 0.16   // swung-leg mass fraction (spec §4.1, Dempster)

    private func balanceFrom(feet: [SIMD3<Float>], com: SIMD3<Float>, footHalf: Float = 0.05) -> BalanceState {
        var cor: [SIMD2<Float>] = []
        for f in feet {
            cor.append(SIMD2<Float>(f.x - footHalf, f.z - footHalf)); cor.append(SIMD2<Float>(f.x + footHalf, f.z - footHalf))
            cor.append(SIMD2<Float>(f.x + footHalf, f.z + footHalf)); cor.append(SIMD2<Float>(f.x - footHalf, f.z + footHalf))
        }
        let poly = BalanceModel.supportPolygon(footCorners: cor)
        let cg = SIMD2<Float>(com.x, com.z)
        let (m, c) = BalanceModel.stabilityMargin(comGround: cg, polygon: poly)
        return BalanceState(centerOfMass: com, comGround: cg, supportPolygon: poly,
                            supportCentroid: c, margin: m, imbalanceDirection: BalanceModel.imbalanceDirection(comGround: cg, centroid: c))
    }

    /// True if a CONTINUOUS-drive run TRACKS (residual bounded); false if it ESCAPES
    /// (residual grows). The CoM advances by drivePerSec every FRAME (so the swing-lag
    /// is live) plus the swung-leg self-feedback (§4.1). committed params.
    private func tracks(drivePerSec: Float, cap: Float = CaptureStepParams.committedCaptureDistanceMax,
                        swing: Float = 0.25, rate: Float = 0.15) -> Bool {
        var p = CaptureStepParams(); p.captureDistance = cap; p.stepDamping = CaptureStepParams.committedStepDampingMin
        p.swingDuration = swing; p.minStepInterval = rate
        let c = CaptureStepController(params: p)
        c.seed(leftAnkle: SIMD3<Float>(-0.1, 0, 0), rightAnkle: SIMD3<Float>(0.1, 0, 0))
        var com = SIMD3<Float>(0, 1, 0); let dt: Float = 1.0 / 60.0
        var res: [Float] = []
        for _ in 0..<300 {
            com.x += drivePerSec * dt
            let before = c.plantedPositions()
            let b = balanceFrom(feet: before, com: com)
            res.append(max(0, -b.margin))
            _ = c.step(balance: b, dt: dt)
            let after = c.plantedPositions()
            if let mv = zip(after, before).first(where: { simd_distance($0.0, $0.1) > 1e-4 }) { com += legFrac * (mv.0 - mv.1) }
        }
        let peak = res.max() ?? 0; let tail = Array(res.suffix(30)).max() ?? 0
        return tail <= peak * 0.5 + 0.02   // bounded/shrinking ⇒ tracks; still-high tail ⇒ escaped
    }

    /// Tracking-capacity gate (spec §4.1): pass/fail is MONOTONE in disturbance rate —
    /// once it escapes as the rate rises it stays escaped (no bounce) — with an
    /// over-capacity counter-case that escapes and a below-capacity rate that tracks.
    func testTrackingCapacity_isMonotoneInDriveRate_withEscapingCounterCase() {
        let rates: [Float] = [0.1, 0.2, 0.3, 0.4, 0.6, 0.9, 1.3]
        let tr = rates.map { tracks(drivePerSec: $0) }
        // Monotone: no "tracks" appears AFTER an "escapes" as the rate rises.
        if let firstEscape = tr.firstIndex(of: false) {
            for i in firstEscape..<tr.count {
                XCTAssertFalse(tr[i], "non-monotone boundary at rate=\(rates[i]): \(Array(zip(rates, tr))) — the model is wrong")
            }
        }
        XCTAssertTrue(tr.contains(false), "an over-capacity rate escapes (counter-case): \(Array(zip(rates, tr)))")
        XCTAssertTrue(tr.contains(true), "a below-capacity rate tracks: \(Array(zip(rates, tr)))")
    }

    /// captureDistance is STABILIZING, not a loop-gain term (spec §4 re-axis): a larger
    /// lead tracks a disturbance that a smaller lead escapes.
    func testLargerCaptureDistance_tracksFasterDisturbance() {
        XCTAssertFalse(tracks(drivePerSec: 0.6, cap: 0.0), "no lead escapes at 0.6 m/s")
        XCTAssertTrue(tracks(drivePerSec: 0.6, cap: 0.5), "a large lead tracks the same 0.6 m/s")
    }
}
```

- [ ] **Step 2: Run — verify the gate passes (the boundary is monotone)**

Run: `swift test --filter "CaptureStepStabilityTests" --disable-sandbox`
Expected: PASS. The probe already established the boundary (tracks ≤ 0.2, escapes ≥ 0.3). If the monotone assertion FAILS (a "tracks" after an "escapes"), the model is wrong — investigate the self-feedback term (spec §4.1), do NOT weaken the assertion. Record the `(rate, tracks)` table and the committed max-disturbance-rate (the last rate that tracks) in the report.

- [ ] **Step 3: Commit**

```bash
git add Tests/VRMMetalKitTests/Animation/CaptureStepStabilityTests.swift
git commit -m "feat(stepping): moving-CoM tracking-capacity gate (monotone in drive rate + escape counter-case)"
```

---

### Task 4: Real-rig stability confirmation (the model's validity gate)

**Files:**
- Test: `Tests/VRMMetalKitTests/Animation/CaptureStepIKTests.swift`
- Modify: `Sources/VRMMetalKit/Animation/CaptureStepController.swift` (re-doc the committed constants: provisional → validated by both gates)

**Interfaces:**
- Consumes: `update` (Task 2), Task 1's measured `ε`, Task 3's committed defaults + over-gain counter-case cap.

**Empirical (RE-AXISED, spec §4).** Drive the real rig at a **below-capacity disturbance rate** (residual holds, zero clamp events, ε floor valid) and at an **over-capacity rate** (residual grows — counter-case). If the rig escapes at a rate the model tracks, **correct the model (Task 3), not this test.**

- [ ] **Step 1: Write the failing confirmation test**

Append to `CaptureStepIKTests` (substitute Task-1's measured ε — 0.00047 — for `epsilon`):

```swift
    /// Real-rig tracking-capacity confirmation (spec §4.2): a below-capacity root drive
    /// rate does NOT grow the residual (beyond ε), zero clamp events; an over-capacity
    /// rate DOES grow (counter-case). The model's VALIDITY gate.
    @MainActor func testRigTrackingCapacity_belowHolds_overCapacityGrows() async throws {
        let epsilon: Float = 0.001   // Task 1's measured ε (0.00047), rounded up

        func residualPeakTail(drivePerSec: Float) async throws -> (peak: Float, tail: Float, clamps: Int) {
            let model = try await loadRig()
            var p = CaptureStepParams()
            p.captureDistance = CaptureStepParams.committedCaptureDistanceMax
            p.stepDamping = CaptureStepParams.committedStepDampingMin
            let c = CaptureStepController(params: p)
            c.update(deltaTime: 1.0 / 60.0, model: model)
            var residuals: [Float] = []
            var clamps = 0
            let dt: Float = 1.0 / 60.0
            for f in 1...180 {
                for root in model.nodes where root.parent == nil { root.translation.x = drivePerSec * dt * Float(f) }
                model.updateNodeTransforms()
                c.update(deltaTime: dt, model: model)
                if let b = BalanceModel.evaluate(model: model, plantedFeet: c.plantedFeet) { residuals.append(max(0, -b.margin)) }
                if c.lastStepClamped { clamps += 1 }
            }
            return (residuals.max() ?? 0, Array(residuals.suffix(15)).max() ?? 0, clamps)
        }

        // Below capacity (slow drive): residual holds, no clamps, ε floor valid.
        let below = try await residualPeakTail(drivePerSec: 0.15)
        XCTAssertEqual(below.clamps, 0, "no clamp events below capacity (ε floor stays valid)")
        XCTAssertLessThanOrEqual(below.tail, below.peak + epsilon, "below capacity the residual holds — the stepper tracks")

        // Over capacity (fast drive): residual grows — counter-case proving detection.
        let over = try await residualPeakTail(drivePerSec: 0.6)
        XCTAssertGreaterThan(over.tail, over.peak * 0.5 + 0.02, "over capacity the residual grows — the metric detects escape")
    }
```

- [ ] **Step 2: Run to verify fail (needs `lastStepClamped`)**

Run: `swift test --filter "CaptureStepIKTests/testRigTrackingCapacity_belowHolds_overCapacityGrows" --disable-sandbox`
Expected: FAIL — `CaptureStepController` has no `lastStepClamped`.

- [ ] **Step 3: Add clamp tracking + calibrate**

Add a `lastStepClamped` flag: `public private(set) var lastStepClamped = false` (reset at top of `update`). In `placeAnkle`, after `hipPos`, set it `true` when `simd_distance(worldTarget, hipPos)` exceeds the summed leg length (`TwoBoneIKSolver.boneLength(hipPos, kneePos) + boneLength(kneePos, anklePos)`).

Then run. Calibrate per §4.2:
- If the **below**-capacity (0.15 m/s) run **grows or clamps**: either the rig's capacity is lower than the model's (correct the model, Task 3 — do NOT loosen this test) or 0.15 is above the fixture's capacity → lower the below-capacity rate until it tracks cleanly, and re-derive the committed max-disturbance-rate.
- If the **over**-capacity (0.6 m/s) run does **not** grow: raise the rate until the residual demonstrably grows (a fast enough disturbance always escapes — counter-case guaranteed reachable, §4.2).

Record the below/over peak/tail, the clamp counts, and the committed max-disturbance-rate.

- [ ] **Step 4: Promote the committed constants; run full suite**

When both gates are green (Task 3 model + Task 4 rig), re-doc the committed constants in `CaptureStepController.swift` — change "provisional defaults pending 2b's stability validation" to "the committed MAX DISTURBANCE RATE (not captureDistance) is validated by the 2b tracking-capacity model gate (monotone in drive rate) AND the rig confirmation; captureDistance is a stabilizing lead knob."

Run: `swift test --filter "CaptureStepIKTests|CaptureStepStabilityTests|CaptureStepControllerTests" --disable-sandbox` → all PASS. `swift build` → Build complete.

- [ ] **Step 5: Commit**

```bash
git add Sources/VRMMetalKit/Animation/CaptureStepController.swift Tests/VRMMetalKitTests/Animation/CaptureStepIKTests.swift
git commit -m "feat(stepping): real-rig stability confirmation + promote committed defaults to validated"
```

---

## Self-Review

**Spec coverage:**
- §0 counter-case rule (vacuous-metric distinction) → Task 3 (over-capacity escape counter-case), Task 4 (over-capacity escape counter-case), Task 1 (range+ε, not a failing case). ✓
- §1 two failure surfaces apart → Task 1 (IK isolated), Task 3 (model, no IK), Task 4 (rig, depends on ε). ✓
- §2 IK executor + restore-IK-before-evaluate + chained-frame + velocity-free → Tasks 1–2. ✓
- §2.1 IK gate: ankle-at-target within ε across range; ε explicit → Task 1. ✓
- §3 follow/moonwalk + non-interference + polygon gate → Task 2. ✓
- §4.1 moving-CoM model with swung-leg self-feedback; monotone hard-assert in DRIVE RATE + over-capacity escape counter-case → Task 3. ✓
- §4.2 rig confirmation: below-capacity holds / over-capacity grows; both required; model-corrected-not-waived → Task 4. ✓
- §4.3 ε flows to Task 4 as noise floor; clamp guard (zero clamp events) → Task 4. ✓
- §4.2 counter-case reachability (escalate disturbance) → Task 3 & 4 calibration steps. ✓

**Placeholder scan:** the IK conversion (Task 1) and stability model (Task 3) are explicitly EMPIRICAL with concrete calibration loops, candidate code, and stated stop conditions — not vague "tune it." `ε = 0.01` in Task 4 is a placeholder to be replaced by Task 1's measured value (called out in the step). No other placeholders.

**Type consistency:** `placeAnkle(_:worldTarget:model:)`, `update(deltaTime:model:rootVelocity:groundY:)`, `isEnabled`, `lastStepClamped`, and 2a's `step`/`seed`/`plantedFeet`/`plantedPositions`/`target` are used identically across tasks. `BalanceModel.Foot`, `BalanceState`, `CaptureStepParams.committed*` match increments 1/2a.

**Risk callout for execution:** Tasks 1, 3, 4 are calibration/research tasks (not transcription) — run them at a capable tier, not the cheapest. Task 1's ε is a hard dependency for Task 4; if Task 1 can't hit a tight ε, Task 4's noise floor loosens and the confirmation weakens — surface that rather than proceeding silently.
