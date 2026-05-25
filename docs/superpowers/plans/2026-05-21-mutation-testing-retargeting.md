# Mutation Testing on VRMA Retargeting Samplers — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extract the three VRMA retargeting samplers into a testable unit, then mutation-test that unit to a ≥80% score — the agreed go/no-go run on whether mutation testing should become a routine.

**Architecture:** Phase 1 is a behavior-preserving refactor — move `makeRotationSampler` / `makeTranslationSampler` / `makeScaleSampler` / `safeDivide` out of the 977-line `VRMAnimationLoader.swift` into a focused `RetargetingSamplers.swift`, promoting shared symbols to `internal`. Phase 2 reuses the DepthBiasCalculator POC's mutation methodology (already-bootstrapped patched muter) on the new file.

**Tech Stack:** Swift 6.2, XCTest, `simd`, muter (already bootstrapped at `.build/tools/bin/muter`), Make.

**Spec:** `docs/superpowers/specs/2026-05-21-mutation-testing-retargeting-design.md`
**Issue:** [#282](https://github.com/arkavo-org/VRMMetalKit/issues/282)
**Branch:** `issue/282-mutation-testing` (continues PR #284 — Option C, expanded scope)

---

## File Map

| File | Action | Responsibility |
|---|---|---|
| `Sources/VRMMetalKit/Animation/RetargetingSamplers.swift` | Create | The three retargeting samplers + `safeDivide`, `internal` |
| `Sources/VRMMetalKit/Animation/VRMAnimationLoader.swift` | Modify | Delete the moved functions; promote `KeyTrack`/`Interpolation`/`sampleQuaternion`/`sampleVector3` to `internal` |
| `Tests/VRMMetalKitTests/RetargetingSamplersTests.swift` | Create | Direct oracle suite for the samplers |
| `.muter/retargeting-samplers.yml` | Create | muter config for the new target |
| `Makefile` | Modify | Split `mutation-test` into per-target + aggregate |
| `docs/mutation-testing/depthbiascalculator-baseline.md` | Modify | Update run-command + report-path references after the rename |
| `docs/mutation-testing/retargeting-samplers-baseline.md` | Create | Score, survivor classification, Verdict |

---

## Task 1: Phase 1 — Extract `RetargetingSamplers.swift`

Behavior-preserving refactor. No logic changes; only moves and visibility promotions.

**Files:**
- Create: `Sources/VRMMetalKit/Animation/RetargetingSamplers.swift`
- Modify: `Sources/VRMMetalKit/Animation/VRMAnimationLoader.swift`

- [ ] **Step 1: Create `RetargetingSamplers.swift` with the moved functions.**

Create `Sources/VRMMetalKit/Animation/RetargetingSamplers.swift` with exactly this content. The three sampler functions and `safeDivide` are copied verbatim from `VRMAnimationLoader.swift` with `private func` changed to `func` (module-`internal` by default):

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

import Foundation
import simd

// VRMA rest-pose retargeting samplers.
//
// Extracted from VRMAnimationLoader.swift so the retargeting math is an
// isolated, directly-testable unit (issue #282). VRMAnimationLoader builds
// `KeyTrack`s from parsed GLB data and calls these to produce per-frame
// closures.
//
// Rest-pose retargeting (VRM 1.0 `how_to_transform_human_pose.md`):
//   delta  = inverse(animationRestRotation) * animationRotation
//   result = modelRestRotation * delta
// with the W-term change-of-basis applied for rigs whose world-rest
// orientations differ. See makeRotationSampler for the full derivation.

func makeRotationSampler(track: KeyTrack,
                         animationRestRotation: simd_quatf,
                         animationRestWorldRotation: simd_quatf,
                         modelRestRotation: simd_quatf?,
                         modelRestWorldRotation: simd_quatf?) -> ((Float) -> simd_quatf)? {
    let L_A = simd_normalize(animationRestRotation)
    let W_A = simd_normalize(animationRestWorldRotation)

    // Non-humanoid tracks pass nil for model rest — there's no model-
    // side bone to normalise against, so the animation rotation flows
    // through unchanged.
    guard let modelRest = modelRestRotation,
          let modelWorld = modelRestWorldRotation else {
        return { t in sampleQuaternion(track, at: t) }
    }
    let L_B = simd_normalize(modelRest)
    let W_B = simd_normalize(modelWorld)

    // VRM 1.0 pose-normalisation (`how_to_transform_human_pose.md`):
    //
    //   Normalized       = W_A · L_A⁻¹ · A.LocalRotation · W_A⁻¹
    //   B.LocalRotation  = L_B · W_B⁻¹ · Normalized · W_B
    //
    // Combined: B = L_B · W_B⁻¹ · W_A · L_A⁻¹ · A · W_A⁻¹ · W_B
    //
    // For two rigs that share the same world-rest orientation
    // (`W_A == W_B`), the W terms cancel and the formula collapses to
    // `B = L_B · L_A⁻¹ · A` — the previous "delta retargeting" formula.
    // For VRMAs authored on a different rest pose (e.g. arms-forward
    // when the model is T-pose) the W terms perform the change-of-
    // basis that aligns the animation's world frame with the model's.
    // VMK#269 was the regression where the W terms were missing.
    let invL_A = simd_inverse(L_A)
    let invW_A = simd_inverse(W_A)
    let invW_B = simd_inverse(W_B)
    return { t in
        let A = sampleQuaternion(track, at: t)
        let normalized = simd_normalize(W_A * invL_A * A * invW_A)
        let result = simd_normalize(L_B * invW_B * normalized * W_B)
        return result
    }
}

// Translation Retargeting with Delta-Based Alignment
//
// ROOT MOTION POLICY:
// -------------------
// Translation deltas (including hips XYZ) are applied in LOCAL humanoid space.
// This means hips translation from the animation moves the character relative to
// its own coordinate frame, not the scene/world.
//
// Current Behavior:
//   • Hips XZ translation = character-relative horizontal movement (walk cycles, shifts)
//   • Hips Y translation = vertical movement (crouch, jump, body bounce)
//   • All deltas preserve animation intent while adapting to different skeleton proportions
//
// For Scene Locomotion (Future):
//   If you need the character to move through the world based on animation:
//   1. Extract hips XZ deltas separately (before applying to bone)
//   2. Accumulate as "root motion" vector
//   3. Apply to character's scene transform (not skeleton)
//   4. Optionally zero out the hips XZ in the skeleton to prevent "double movement"
//
// See also: AnimationPlayer.update() for frame-by-frame sampling
//
func makeTranslationSampler(track: KeyTrack,
                            animationRestTranslation: SIMD3<Float>,
                            modelRestTranslation: SIMD3<Float>?) -> ((Float) -> SIMD3<Float>)? {
    guard let modelRest = modelRestTranslation else {
        return { t in sampleVector3(track, at: t) }
    }

    return { t in
        let animTranslation = sampleVector3(track, at: t)
        let delta = animTranslation - animationRestTranslation
        return modelRest + delta
    }
}

func makeScaleSampler(track: KeyTrack,
                      animationRestScale: SIMD3<Float>,
                      modelRestScale: SIMD3<Float>?) -> ((Float) -> SIMD3<Float>)? {
    guard let modelRest = modelRestScale else {
        return { t in sampleVector3(track, at: t) }
    }

    return { t in
        let animScale = sampleVector3(track, at: t)
        let ratio = safeDivide(animScale, by: animationRestScale)
        return modelRest * ratio
    }
}

func safeDivide(_ numerator: SIMD3<Float>, by denominator: SIMD3<Float>) -> SIMD3<Float> {
    let epsilon: Float = 1e-6
    return SIMD3<Float>(
        numerator.x / (abs(denominator.x) > epsilon ? denominator.x : 1),
        numerator.y / (abs(denominator.y) > epsilon ? denominator.y : 1),
        numerator.z / (abs(denominator.z) > epsilon ? denominator.z : 1)
    )
}
```

- [ ] **Step 2: Delete the moved functions from `VRMAnimationLoader.swift`.**

In `Sources/VRMMetalKit/Animation/VRMAnimationLoader.swift`, delete these four declarations entirely (they now live in `RetargetingSamplers.swift`):

1. `private func makeRotationSampler(track: KeyTrack, ...)` — the whole function.
2. The `// Translation Retargeting with Delta-Based Alignment` … `// See also: AnimationPlayer.update()` comment block **and** the `private func makeTranslationSampler(...)` it documents — delete the comment block too, it moved with the function.
3. `private func makeScaleSampler(track: KeyTrack, ...)` — the whole function.
4. `private func safeDivide(_ numerator: SIMD3<Float>, by denominator: SIMD3<Float>) -> SIMD3<Float>` — the whole function.

Do NOT delete `makeExpressionWeightSampler` — it stays.

- [ ] **Step 3: Promote shared symbols to `internal` in `VRMAnimationLoader.swift`.**

The moved functions and the upcoming test reference four symbols that are currently `private`. Change each (the symbols stay in `VRMAnimationLoader.swift`):

- `private struct KeyTrack {` → `struct KeyTrack {`
- `private enum Interpolation: String {` → `enum Interpolation: String {` (required: `KeyTrack.interpolation` is of this type, so an `internal` `KeyTrack` cannot expose a `private` `Interpolation`)
- `private func sampleQuaternion(_ track: KeyTrack, at time: Float) -> simd_quatf {` → `func sampleQuaternion(_ track: KeyTrack, at time: Float) -> simd_quatf {`
- `private func sampleVector3(_ track: KeyTrack, at time: Float) -> SIMD3<Float> {` → `func sampleVector3(_ track: KeyTrack, at time: Float) -> SIMD3<Float> {`

Leave `private extension Interpolation { ... asGLTFCore ... }` and `makeExpressionWeightSampler` as `private` — neither crosses the file boundary.

- [ ] **Step 4: Build.**

Run:
```bash
swift build 2>&1 | tail -10
```
Expected: `Build complete!`. If you get "X is inaccessible due to 'private' protection level", a symbol in Step 3 was missed — promote it. If you get "invalid redeclaration", a function in Step 2 wasn't fully deleted.

- [ ] **Step 5: Run the full test suite to confirm zero behavior change.**

Run:
```bash
swift test --parallel --num-workers 14 -j 16 --disable-sandbox 2>&1 | tail -25
```
Expected: the same pass/fail set as before this task — in particular every animation/VRMA retargeting test still passes. The known-pre-existing SpringBone failures (4, unrelated to this work) may appear; anything *newly* failing means the extraction changed behavior — STOP and diagnose.

- [ ] **Step 6: Commit.**

```bash
git add Sources/VRMMetalKit/Animation/RetargetingSamplers.swift Sources/VRMMetalKit/Animation/VRMAnimationLoader.swift
git commit -m "refactor(animation): extract RetargetingSamplers from VRMAnimationLoader (#282)

Move makeRotationSampler / makeTranslationSampler / makeScaleSampler and
their safeDivide helper into a focused RetargetingSamplers.swift so the
VRMA retargeting math is an isolated, directly-testable unit. KeyTrack,
Interpolation, sampleQuaternion and sampleVector3 are promoted private to
internal so the new file (and tests) can reach them. No behavior change.

Issue #282

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
"
```

---

## Task 2: Phase 2 — Write the oracle suite

**Files:**
- Create: `Tests/VRMMetalKitTests/RetargetingSamplersTests.swift`

Written before any mutation run. The samplers are `VRMMetalKit` code, so `@testable import VRMMetalKit` reaches the now-`internal` functions and `KeyTrack`.

- [ ] **Step 1: Create the test file.**

Create `Tests/VRMMetalKitTests/RetargetingSamplersTests.swift` with exactly this content:

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
import simd
@testable import VRMMetalKit

/// Direct unit tests for the VRMA retargeting samplers — the mutation-testing
/// oracle suite for issue #282.
///
/// The samplers return closures; each test builds a single-keyframe STEP
/// `KeyTrack`, obtains the closure, invokes it, and asserts the output.
final class RetargetingSamplersTests: XCTestCase {

    // MARK: - Track builders

    /// Single-keyframe STEP quaternion track holding `q`.
    private func quatTrack(_ q: simd_quatf) -> KeyTrack {
        KeyTrack(times: [0],
                 values: [q.imag.x, q.imag.y, q.imag.z, q.real],
                 path: "rotation",
                 interpolation: .step,
                 componentCount: 4)
    }

    /// Single-keyframe STEP vec3 track holding `v`.
    private func vec3Track(_ v: SIMD3<Float>) -> KeyTrack {
        KeyTrack(times: [0],
                 values: [v.x, v.y, v.z],
                 path: "translation",
                 interpolation: .step,
                 componentCount: 3)
    }

    /// Asserts two quaternions are equal component-wise (no ± double-cover
    /// tolerance — the retargeting formula is sign-deterministic for these
    /// inputs, and allowing ± would let a sign-flip mutant survive).
    private func assertQuat(_ a: simd_quatf, _ b: simd_quatf,
                            accuracy: Float = 1e-5,
                            _ message: String = "",
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.imag.x, b.imag.x, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(a.imag.y, b.imag.y, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(a.imag.z, b.imag.z, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(a.real,   b.real,   accuracy: accuracy, message, file: file, line: line)
    }

    private func assertVec3(_ a: SIMD3<Float>, _ b: SIMD3<Float>,
                            accuracy: Float = 1e-5,
                            _ message: String = "",
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(a.z, b.z, accuracy: accuracy, message, file: file, line: line)
    }

    private let identity = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)

    // MARK: - Rotation sampler: nil model rest (passthrough)

    func testRotationNilModelRestPassesAnimationThrough() {
        // nil model rest → closure returns sampleQuaternion(track) unmodified.
        let q = simd_normalize(simd_quatf(angle: .pi / 3, axis: [0, 1, 0]))
        let sampler = makeRotationSampler(track: quatTrack(q),
                                          animationRestRotation: identity,
                                          animationRestWorldRotation: identity,
                                          modelRestRotation: nil,
                                          modelRestWorldRotation: nil)
        XCTAssertNotNil(sampler)
        assertQuat(sampler!(0), q, "nil model rest must pass the animation rotation through")
    }

    // MARK: - Rotation sampler: identity rest poses

    func testRotationIdentityRestPosesReturnNormalizedAnimation() {
        // All rests identity → result = normalize(A). A is already unit, so
        // result == A.
        let q = simd_normalize(simd_quatf(angle: .pi / 2, axis: [1, 0, 0]))
        let sampler = makeRotationSampler(track: quatTrack(q),
                                          animationRestRotation: identity,
                                          animationRestWorldRotation: identity,
                                          modelRestRotation: identity,
                                          modelRestWorldRotation: identity)
        XCTAssertNotNil(sampler)
        assertQuat(sampler!(0), q, "identity rests must reduce to result = animation rotation")
    }

    // MARK: - Rotation sampler: W_A == W_B collapse

    func testRotationWorldRestsEqualCollapseToDeltaFormula() {
        // When W_A == W_B the W terms cancel: result = L_B · L_A⁻¹ · A.
        let L_A = simd_normalize(simd_quatf(angle: .pi / 6, axis: [0, 1, 0]))
        let L_B = simd_normalize(simd_quatf(angle: .pi / 2, axis: [0, 1, 0]))
        let W   = simd_normalize(simd_quatf(angle: .pi / 4, axis: [1, 0, 0]))
        let A   = simd_normalize(simd_quatf(angle: .pi / 3, axis: [0, 0, 1]))

        let sampler = makeRotationSampler(track: quatTrack(A),
                                          animationRestRotation: L_A,
                                          animationRestWorldRotation: W,
                                          modelRestRotation: L_B,
                                          modelRestWorldRotation: W)
        XCTAssertNotNil(sampler)
        let expected = simd_normalize(L_B * simd_inverse(L_A) * A)
        assertQuat(sampler!(0), expected,
                   "W_A == W_B must collapse to result = L_B · L_A⁻¹ · A")
    }

    // MARK: - Rotation sampler: full W-term change-of-basis

    func testRotationDifferingWorldRestsApplyChangeOfBasis() {
        // W_A != W_B: the W terms perform a real change of basis, so the
        // result must differ from the W_A==W_B collapsed value. This pins
        // that the W terms are not dead code (the VMK#269 regression).
        let L_A = simd_normalize(simd_quatf(angle: .pi / 6, axis: [0, 1, 0]))
        let L_B = simd_normalize(simd_quatf(angle: .pi / 2, axis: [0, 1, 0]))
        let W_A = simd_normalize(simd_quatf(angle: .pi / 4, axis: [1, 0, 0]))
        let W_B = simd_normalize(simd_quatf(angle: .pi / 3, axis: [0, 0, 1]))
        let A   = simd_normalize(simd_quatf(angle: .pi / 3, axis: [0, 0, 1]))

        let withChangeOfBasis = makeRotationSampler(track: quatTrack(A),
                                                    animationRestRotation: L_A,
                                                    animationRestWorldRotation: W_A,
                                                    modelRestRotation: L_B,
                                                    modelRestWorldRotation: W_B)
        let collapsed = simd_normalize(L_B * simd_inverse(L_A) * A)
        XCTAssertNotNil(withChangeOfBasis)

        let result = withChangeOfBasis!(0)
        let delta = abs(result.imag.x - collapsed.imag.x)
                  + abs(result.imag.y - collapsed.imag.y)
                  + abs(result.imag.z - collapsed.imag.z)
                  + abs(result.real   - collapsed.real)
        XCTAssertGreaterThan(delta, 1e-3,
            "Differing world rests must apply a change of basis (W terms not dead code)")
    }

    func testRotationFullWTermFormulaMatchesReference() {
        // Exact regression pin: independently recompute the documented
        // two-step formula and assert the sampler matches it.
        let L_A = simd_normalize(simd_quatf(angle: .pi / 6, axis: [0, 1, 0]))
        let L_B = simd_normalize(simd_quatf(angle: .pi / 2, axis: [0, 1, 0]))
        let W_A = simd_normalize(simd_quatf(angle: .pi / 4, axis: [1, 0, 0]))
        let W_B = simd_normalize(simd_quatf(angle: .pi / 3, axis: [0, 0, 1]))
        let A   = simd_normalize(simd_quatf(angle: .pi / 5, axis: [0, 1, 0]))

        let sampler = makeRotationSampler(track: quatTrack(A),
                                          animationRestRotation: L_A,
                                          animationRestWorldRotation: W_A,
                                          modelRestRotation: L_B,
                                          modelRestWorldRotation: W_B)
        XCTAssertNotNil(sampler)

        // Normalized = W_A · L_A⁻¹ · A · W_A⁻¹ ; result = L_B · W_B⁻¹ · Normalized · W_B
        let normalized = simd_normalize(W_A * simd_inverse(L_A) * A * simd_inverse(W_A))
        let expected = simd_normalize(L_B * simd_inverse(W_B) * normalized * W_B)
        assertQuat(sampler!(0), expected,
                   "full W-term formula must match the documented two-step reference")
    }

    // MARK: - Translation sampler

    func testTranslationNilModelRestPassesThrough() {
        let v = SIMD3<Float>(3, -2, 7)
        let sampler = makeTranslationSampler(track: vec3Track(v),
                                             animationRestTranslation: SIMD3<Float>(1, 1, 1),
                                             modelRestTranslation: nil)
        XCTAssertNotNil(sampler)
        assertVec3(sampler!(0), v, "nil model rest must pass translation through")
    }

    func testTranslationAppliesAdditiveDelta() {
        // result = modelRest + (anim - animRest)
        let sampler = makeTranslationSampler(track: vec3Track(SIMD3<Float>(3, 0, 0)),
                                             animationRestTranslation: SIMD3<Float>(1, 0, 0),
                                             modelRestTranslation: SIMD3<Float>(0, 5, 0))
        XCTAssertNotNil(sampler)
        // (0,5,0) + ((3,0,0) - (1,0,0)) = (2,5,0)
        assertVec3(sampler!(0), SIMD3<Float>(2, 5, 0),
                   "translation must apply modelRest + (anim - animRest)")
    }

    func testTranslationZeroDeltaWhenAnimEqualsRest() {
        let sampler = makeTranslationSampler(track: vec3Track(SIMD3<Float>(4, 4, 4)),
                                             animationRestTranslation: SIMD3<Float>(4, 4, 4),
                                             modelRestTranslation: SIMD3<Float>(9, 8, 7))
        XCTAssertNotNil(sampler)
        assertVec3(sampler!(0), SIMD3<Float>(9, 8, 7),
                   "anim == animRest must yield exactly modelRest")
    }

    // MARK: - Scale sampler

    func testScaleNilModelRestPassesThrough() {
        let v = SIMD3<Float>(2, 3, 4)
        let sampler = makeScaleSampler(track: vec3Track(v),
                                       animationRestScale: SIMD3<Float>(1, 1, 1),
                                       modelRestScale: nil)
        XCTAssertNotNil(sampler)
        assertVec3(sampler!(0), v, "nil model rest must pass scale through")
    }

    func testScaleAppliesRatio() {
        // result = modelRest * (animScale / animRest)
        let sampler = makeScaleSampler(track: vec3Track(SIMD3<Float>(4, 4, 4)),
                                       animationRestScale: SIMD3<Float>(2, 2, 2),
                                       modelRestScale: SIMD3<Float>(3, 3, 3))
        XCTAssertNotNil(sampler)
        // (3,3,3) * ((4,4,4)/(2,2,2)) = (3,3,3) * (2,2,2) = (6,6,6)
        assertVec3(sampler!(0), SIMD3<Float>(6, 6, 6),
                   "scale must apply modelRest * (animScale / animRest)")
    }

    func testScaleUnitRatioWhenAnimEqualsRest() {
        let sampler = makeScaleSampler(track: vec3Track(SIMD3<Float>(5, 5, 5)),
                                       animationRestScale: SIMD3<Float>(5, 5, 5),
                                       modelRestScale: SIMD3<Float>(2, 3, 4))
        XCTAssertNotNil(sampler)
        assertVec3(sampler!(0), SIMD3<Float>(2, 3, 4),
                   "animScale == animRest must yield exactly modelRest")
    }

    // MARK: - safeDivide

    func testSafeDivideNormal() {
        assertVec3(safeDivide(SIMD3<Float>(4, 9, 6), by: SIMD3<Float>(2, 3, 2)),
                   SIMD3<Float>(2, 3, 3))
    }

    func testSafeDivideByZeroFallsBackToOne() {
        // |0| is not > epsilon → divide by 1 → numerator unchanged.
        assertVec3(safeDivide(SIMD3<Float>(4, 4, 4), by: SIMD3<Float>(0, 0, 0)),
                   SIMD3<Float>(4, 4, 4),
                   "zero denominator must fall back to dividing by 1")
    }

    func testSafeDivideBelowEpsilonFallsBackToOne() {
        // 1e-7 < 1e-6 epsilon → divide by 1.
        assertVec3(safeDivide(SIMD3<Float>(4, 4, 4), by: SIMD3<Float>(1e-7, 1e-7, 1e-7)),
                   SIMD3<Float>(4, 4, 4),
                   "sub-epsilon denominator must fall back to dividing by 1")
    }

    func testSafeDivideNegativeDenominatorDivides() {
        // |-2| > epsilon → real division, sign preserved.
        assertVec3(safeDivide(SIMD3<Float>(4, 4, 4), by: SIMD3<Float>(-2, -2, -2)),
                   SIMD3<Float>(-2, -2, -2),
                   "negative denominator above epsilon must divide normally")
    }
}
```

- [ ] **Step 2: Build the test target.**

Run:
```bash
swift build 2>&1 | tail -8
```
Expected: build succeeds. A "cannot find 'KeyTrack' / 'makeRotationSampler' in scope" error means a Task 1 Step 3 visibility promotion was missed.

- [ ] **Step 3: Run the suite; all tests must pass on the unmutated source.**

Run:
```bash
swift test --filter RetargetingSamplersTests --disable-sandbox 2>&1 | tail -20
```
Expected: 15 tests pass. If a test fails, the assertion's expected value is wrong (recheck the hand-computation) — fix the test. Do NOT change `RetargetingSamplers.swift`.

- [ ] **Step 4: Commit.**

```bash
git add Tests/VRMMetalKitTests/RetargetingSamplersTests.swift
git commit -m "test(animation): direct oracle suite for RetargetingSamplers (#282)

15 direct unit tests covering all three retargeting samplers and
safeDivide: nil-model-rest passthrough, identity-rest collapse, the
W_A==W_B delta-formula collapse, the full W-term change-of-basis, and
additive/ratio/edge-case behavior. The muter target for issue #282's
second mutation run.

Issue #282

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
"
```

---

## Task 3: muter configuration

**Files:**
- Create: `.muter/retargeting-samplers.yml`

- [ ] **Step 1: Create the config.**

Create `.muter/retargeting-samplers.yml` mirroring the existing `.muter/depth-bias.yml` schema (muter v16: `executable`, `arguments`, `exclude`, `excludeCalls`, `coverageThreshold` — file scoping/format/output are CLI flags, set in the Makefile):

```yaml
executable: /usr/bin/swift
arguments:
- test
- --filter
- RetargetingSamplersTests
- --disable-sandbox
exclude: []
excludeCalls: []
coverageThreshold: 0
```

(`--disable-sandbox` is required: the project's tests need filesystem access for fixtures, and muter needs FS write access for source rewrites.)

- [ ] **Step 2: Commit.**

```bash
git add .muter/retargeting-samplers.yml
git commit -m "build(mutation-testing): muter config for RetargetingSamplers (#282)

Issue #282

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
"
```

---

## Task 4: Restructure the Makefile mutation targets

**Files:**
- Modify: `Makefile`
- Modify: `docs/mutation-testing/depthbiascalculator-baseline.md`

- [ ] **Step 1: Replace the single `mutation-test` target with per-target + aggregate.**

In `Makefile`, find the current target:

```makefile
mutation-test: $(MUTER_BIN)
	@mkdir -p .build/mutation-testing
	@$(MUTER_BIN) run \
		--configuration .muter/depth-bias.yml \
		--files-to-mutate Sources/GLTFCore/Utilities/DepthBiasCalculator.swift \
		--skip-coverage \
		--format json \
		--output .build/mutation-testing/last-run.json
```

Replace it with:

```makefile
mutation-test: mutation-test-depth-bias mutation-test-retargeting
	@echo "✅ All mutation-test targets complete"

mutation-test-depth-bias: $(MUTER_BIN)
	@mkdir -p .build/mutation-testing
	@$(MUTER_BIN) run \
		--configuration .muter/depth-bias.yml \
		--files-to-mutate Sources/GLTFCore/Utilities/DepthBiasCalculator.swift \
		--skip-coverage \
		--format json \
		--output .build/mutation-testing/depth-bias.json

mutation-test-retargeting: $(MUTER_BIN)
	@mkdir -p .build/mutation-testing
	@$(MUTER_BIN) run \
		--configuration .muter/retargeting-samplers.yml \
		--files-to-mutate Sources/VRMMetalKit/Animation/RetargetingSamplers.swift \
		--skip-coverage \
		--format json \
		--output .build/mutation-testing/retargeting-samplers.json
```

- [ ] **Step 2: Update `.PHONY` and `help:`.**

Find the `.PHONY` line and replace `mutation-test` with `mutation-test mutation-test-depth-bias mutation-test-retargeting`:

```makefile
.PHONY: help shaders shaders-macos shaders-ios shaders-iossim gltf-shaders clean test docs docs-static muter-bootstrap mutation-test mutation-test-depth-bias mutation-test-retargeting
```

In the `help:` block, replace the single `make mutation-test` line with:

```makefile
	@echo "  make mutation-test - Run all mutation-test targets"
	@echo "  make mutation-test-depth-bias - Mutation-test DepthBiasCalculator"
	@echo "  make mutation-test-retargeting - Mutation-test RetargetingSamplers"
```

- [ ] **Step 3: Update the DepthBiasCalculator baseline doc references.**

In `docs/mutation-testing/depthbiascalculator-baseline.md`:
- Change the `Run: \`make mutation-test\`` line under the Tooling section to `Run: \`make mutation-test-depth-bias\``.
- Change the report path `.build/mutation-testing/last-run.json` to `.build/mutation-testing/depth-bias.json`.

- [ ] **Step 4: Verify the targets resolve.**

Run:
```bash
make -n mutation-test-retargeting
```
Expected: prints the `muter run ...` command for the retargeting target without executing the build (dry-run). Confirms the Makefile parses and the target exists.

- [ ] **Step 5: Commit.**

```bash
git add Makefile docs/mutation-testing/depthbiascalculator-baseline.md
git commit -m "build(mutation-testing): split mutation-test into per-target + aggregate (#282)

mutation-test becomes an aggregate of mutation-test-depth-bias and
mutation-test-retargeting, each writing its own JSON artifact. Mirrors
the shaders aggregate pattern. DepthBiasCalculator baseline doc updated
for the renamed target and report path.

Issue #282

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
"
```

---

## Task 5: First mutation run + survivor triage

**Files:**
- Modify: `Tests/VRMMetalKitTests/RetargetingSamplersTests.swift` (survivor-driven additions)

- [ ] **Step 1: First muter run.**

Run:
```bash
make mutation-test-retargeting 2>&1 | tee /tmp/muter-retargeting-run.log
```
Expected: muter parses `RetargetingSamplers.swift`, generates mutants, runs `RetargetingSamplersTests` against each, writes `.build/mutation-testing/retargeting-samplers.json`. Capture: total mutants, killed/survived counts, score, wall time.

If muter crashes or produces zero mutants, STOP and report BLOCKED with the error.

- [ ] **Step 2: Triage every survivor.**

Inspect `.build/mutation-testing/retargeting-samplers.json`. For each surviving mutant, classify:
- **`kill-pending`** — real test gap; add a distinguishing assertion to `RetargetingSamplersTests.swift` under a new `// MARK: - Survivor-driven additions` section.
- **`equivalent`** — semantically identical under all reachable inputs. Expected here: mutations inside or around `simd_normalize` of an already-unit quaternion, or `simd_inverse` that coincides with the conjugate for unit quaternions. Record a one-line rationale.
- **`accepted-gap`** — real gap deliberately deferred; record rationale.

- [ ] **Step 3: Add tests to kill `kill-pending` survivors.**

For each `kill-pending` mutant, write a test whose expected value is hand-computed (not formula-duplicated, where possible) so it diverges on the mutated code. Re-use the `quatTrack` / `vec3Track` / `assertQuat` / `assertVec3` helpers already in the file.

- [ ] **Step 4: Verify new tests pass on unmutated source.**

Run:
```bash
swift test --filter RetargetingSamplersTests --disable-sandbox 2>&1 | tail -15
```
All tests must pass before re-running muter.

- [ ] **Step 5: Re-run muter.**

```bash
make mutation-test-retargeting 2>&1 | tail -25
```
Repeat Steps 2-5 until the score is ≥80% **or** every remaining survivor is classified `equivalent` / `accepted-gap`.

**Hard cap:** after 3 full cycles, STOP and report DONE_WITH_CONCERNS with the current score, full survivor list, and classifications. Do not loop indefinitely.

If the score plateaus below 80% with all survivors classified `equivalent` / `accepted-gap`, that is the spec's escape hatch — record it; it is not a failure.

- [ ] **Step 6: Save baseline data for Task 6.**

Write the final figures to `/tmp/retargeting-baseline-data.txt`:
```
SCORE
total_mutants: <N>
killed: <N>
survived_equivalent: <N>
survived_accepted_gap: <N>
final_score_percent: <NN>
wall_time: <mm:ss>

SURVIVORS
<file:line> | <operator> | <before> -> <after> | <classification> | <rationale>
...
```

- [ ] **Step 7: Commit the test additions.**

```bash
git add Tests/VRMMetalKitTests/RetargetingSamplersTests.swift
git commit -m "test(animation): kill survivors from RetargetingSamplers mutation run (#282)

Survivor-driven additions. <one-line summary of what was added>.
Mutation score: <X>% -> <Y>%.

Issue #282

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
"
```
(Customize the body to the actual additions. If Step 1's run already scored ≥80% with no `kill-pending` survivors, skip this commit — there is nothing to add.)

---

## Task 6: Write the baseline doc with Verdict

**Files:**
- Create: `docs/mutation-testing/retargeting-samplers-baseline.md`

- [ ] **Step 1: Write the baseline doc.**

Create `docs/mutation-testing/retargeting-samplers-baseline.md`, filling every `<…>` from `/tmp/retargeting-baseline-data.txt`:

```markdown
# Mutation Testing Baseline — VRMA Retargeting Samplers

**Issue:** [#282](https://github.com/arkavo-org/VRMMetalKit/issues/282)
**Last run:** 2026-05-21
**Target:** `Sources/VRMMetalKit/Animation/RetargetingSamplers.swift`
**Oracle suite:** `Tests/VRMMetalKitTests/RetargetingSamplersTests.swift`

## Tooling

`muter` built from `master` at the SHA pinned in `Makefile`, with the local
`.muter/patches/v16-schemata-content-fallback.patch` applied at bootstrap.

- Bootstrap: `make muter-bootstrap`
- Run: `make mutation-test-retargeting`
- Report: `.build/mutation-testing/retargeting-samplers.json` (gitignored)

## Mutation score

| | Count |
|---|---|
| Total mutants generated | <N> |
| Killed | <N> |
| Survived (equivalent) | <N> |
| Survived (accepted-gap) | <N> |

**Score (killed / (total - equivalent)): <NN>%**

Total wall time: <mm:ss>.

## Survivors

Every surviving mutant, classified. No unclassified survivors.

| # | File:line | Operator | Before → After | Classification | Rationale |
|---|---|---|---|---|---|
| 1 | <…> | <…> | <…> | <…> | <…> |

## Verdict

Did this run surface a test-effectiveness blind spot comparable to the
`DepthBiasCalculator` POC's priority-chain finding?

<One of:>
- **Yes — expand.** <What the blind spot was.> Recommend extending mutation
  testing to further Animation targets; next candidates: `KeyframeSampling.swift`,
  then the IK / constraint solvers.
- **No — validated, not adopted.** The existing suite (or the oracle suite as
  first written) already pinned the retargeting math; mutation testing surfaced
  no meaningful gap. Recommend stopping at two targets — mutation testing is a
  proven technique for this codebase but not worth standing up as a routine.
```

- [ ] **Step 2: Commit.**

```bash
git add docs/mutation-testing/retargeting-samplers-baseline.md
git commit -m "docs(mutation-testing): RetargetingSamplers mutation baseline (#282)

Second mutation target. Score <NN>%, every survivor classified. Verdict
section records the expand/stop recommendation for issue #282.

Issue #282

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
"
```

---

## Task 7: Update PR #284 and push

**Files:** (none)

- [ ] **Step 1: Push the branch.**

Confirm with the user before pushing (project convention — push triggers Xcode Cloud CI). When approved:
```bash
git push origin issue/282-mutation-testing
```

- [ ] **Step 2: Update PR #284's title and body for the expanded scope.**

PR #284 now covers two mutation targets. Update it:
```bash
gh pr edit 284 --repo arkavo-org/VRMMetalKit \
  --title "feat(testing): mutation testing on DepthBiasCalculator + retargeting samplers (#282)"
```
Then append a section to the PR body (via `gh pr edit 284 --body` with the full updated body) summarizing the retargeting work: the `RetargetingSamplers.swift` extraction, the new oracle suite, the second mutation score, and the baseline doc's Verdict.

- [ ] **Step 3: Report the PR URL and the Verdict to the user.**

---

## Self-Review

**Spec coverage:**
- Phase 1 extraction (new file; `private`→`internal` for `KeyTrack`/`Interpolation`/`sampleQuaternion`/`sampleVector3`; `safeDivide` moves; `makeExpressionWeightSampler` stays) → Task 1.
- Phase 1 behavior-contract gate (full suite passes) → Task 1 Step 5.
- Phase 2 oracle suite, all required coverage (identity collapse, `W_A==W_B` collapse, full W-term, nil passthroughs, translation/scale/`safeDivide`) → Task 2.
- muter config → Task 3.
- Makefile aggregate restructure + POC baseline-doc update → Task 4.
- Survivor triage, ≥80% / classify-every-survivor, escape hatch → Task 5.
- Baseline doc with Verdict section → Task 6.
- All 6 acceptance criteria map: AC1→Task1, AC2→Task2, AC3→Task4+Task5, AC4/AC5→Task5+Task6, AC6→Task6.

**Placeholder scan:** No TBDs. The `<…>` markers in Task 6's baseline doc and Task 5's commit-body summary are intentional run-time fill-ins (the engineer has the real numbers only after the run) — every one has an explicit source (`/tmp/retargeting-baseline-data.txt`).

**Type consistency:** `KeyTrack(times:values:path:interpolation:componentCount:)` memberwise init matches the struct definition; `Interpolation.step` is a real case; `makeRotationSampler` / `makeTranslationSampler` / `makeScaleSampler` / `safeDivide` signatures are identical between Task 1 (definitions) and Task 2 (call sites); `quatTrack` / `vec3Track` / `assertQuat` / `assertVec3` helper names are consistent within the test file.
