# Capture-Stepping 2a — Pure Controller Core + Convergence Gate — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the pure, rig-free core of the capture-step controller — state machine, follow/arrest placement, swing arc — and gate it on the pure convergence corner test that would catch a limit cycle.

**Architecture:** A `CaptureStepController` (Metal-free, `VRMModel`-free) that consumes a `BalanceState` and `dt` and emits **world-space ankle targets** via `step(balance:dt:)`. It owns the per-foot state machine (planted/swinging) and the §2 step decision (trigger → trailing foot → damped capture placement). It touches **no bone rotation, no IK solver, no rig** — that is the seam invariant (2b owns all of it).

**Tech Stack:** Swift 6.2, `simd`, XCTest. Consumes `BalanceModel` (increment 1: `BalanceState`, `BalanceModel.Foot`, `supportPolygon`, `stabilityMargin`, `imbalanceDirection`) — all pure.

## Global Constraints

- Swift 6.2; targets macOS 26+, iOS 26+.
- New source files MUST carry the Apache 2.0 header (copy from any file in `Sources/VRMMetalKit/`).
- **Seam invariant (structural, load-bearing):** 2a's `CaptureStepController` imports only `Foundation`/`simd`, references only `BalanceState`/`BalanceModel.Foot`, **never** imports `Metal`/`VRMModel`, **never** calls `TwoBoneIKSolver`, **never** writes a bone rotation, **never** reads the rig. All of that is 2b. This is what makes 2a's convergence gate provably IK-free.
- Tests run with `--disable-sandbox`. This whole plan is pure — no Metal device needed, no `XCTSkip`.
- Sign convention (from increment 1): `BalanceState.margin > 0` ⇒ CoM inside support (stable); `< 0` ⇒ outside (falling).
- Damping/loop-gain convention (spec §6): `stepDamping ∈ [0,1)`, higher = smaller step = safer; loop gain `L = (1−stepDamping)·k(captureDistance)`, convergence needs `L < 1`. **Follow uses `captureDistance = 0, stepDamping = 0`** (plants exactly at `comGround`).
- **Convergence guarantee is conditional on 2a's CoM-response model** (CoM fixed under the shove; foot lands exactly at target). 2b's real-rig test validates that model against reality. State this in the gate test's doc comment.

---

## File Structure

- **Create** `Sources/VRMMetalKit/Animation/CaptureStepController.swift` — `CaptureStepParams`, `FootPhase`, `CaptureStepController` (state machine + pure statics). Built across Tasks 1–4. Extended in 2b with the `update(model:)` IK executor.
- **Create** `Tests/VRMMetalKitTests/Animation/CaptureStepControllerTests.swift` — all tests, pure.

---

### Task 1: `CaptureStepParams`, `FootPhase`, and the swing arc

**Files:**
- Create: `Sources/VRMMetalKit/Animation/CaptureStepController.swift`
- Test: `Tests/VRMMetalKitTests/Animation/CaptureStepControllerTests.swift`

**Interfaces:**
- Produces:
  - `struct CaptureStepParams: Sendable` — `triggerMargin, captureDistance, stepDamping, swingDuration, stepHeight, minStepInterval: Float`, memberwise `init` with defaults.
  - `enum FootPhase: Sendable` — `.planted(SIMD3<Float>)`, `.swinging(from: SIMD3<Float>, to: SIMD3<Float>, elapsed: Float)`.
  - `enum CaptureStepController` namespace holding `static func swingArc(from:to:t:stepHeight:) -> SIMD3<Float>` (the class comes in Task 3; put the static on a `CaptureStepController` enum for now and fold it into the class in Task 3).

To avoid a type-kind change mid-plan, define the static as a free-standing helper in the file's namespace via an enum `CaptureStepMath`, and Task 3's class calls it. Final shape: `CaptureStepMath.swingArc(...)`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/VRMMetalKitTests/Animation/CaptureStepControllerTests.swift`:

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

final class CaptureStepControllerTests: XCTestCase {

    // MARK: - Task 1: params defaults + swing arc

    func testParamsDefaults_followRegime() {
        let p = CaptureStepParams()
        XCTAssertEqual(p.captureDistance, 0, "default is the follow regime")
        XCTAssertEqual(p.stepDamping, 0, "follow uses zero damping (plants exactly at CoM)")
        XCTAssertGreaterThan(p.swingDuration, 0)
        XCTAssertGreaterThan(p.minStepInterval, 0)
    }

    func testSwingArc_endpointsAndLift() {
        let from = SIMD3<Float>(0, 0, 0)
        let to = SIMD3<Float>(1, 0, 0)
        let h: Float = 0.1
        // Endpoints: no lift, exact from/to.
        XCTAssertEqual(CaptureStepMath.swingArc(from: from, to: to, t: 0, stepHeight: h), from)
        XCTAssertEqual(CaptureStepMath.swingArc(from: from, to: to, t: 1, stepHeight: h), to)
        // Midpoint: halfway across (smoothstep(0.5)=0.5) and lifted to the peak.
        let mid = CaptureStepMath.swingArc(from: from, to: to, t: 0.5, stepHeight: h)
        XCTAssertEqual(mid.x, 0.5, accuracy: 1e-5)
        XCTAssertEqual(mid.y, h, accuracy: 1e-5, "lift peaks at mid-swing")
    }

    func testSwingArc_phaseMonotonicAcross() {
        let from = SIMD3<Float>(0, 0, 0), to = SIMD3<Float>(1, 0, 0)
        var prevX: Float = -1
        for i in 0...10 {
            let x = CaptureStepMath.swingArc(from: from, to: to, t: Float(i) / 10, stepHeight: 0.1).x
            XCTAssertGreaterThanOrEqual(x, prevX, "horizontal progress is monotonic")
            prevX = x
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter CaptureStepControllerTests --disable-sandbox`
Expected: FAIL — `cannot find 'CaptureStepParams'` / `'CaptureStepMath' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/VRMMetalKit/Animation/CaptureStepController.swift`:

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

/// Tuning for the capture-step controller (design 2026-07-06 §6). `captureDistance`
/// is the capture-gain term in the §2 feedback loop — bounded above JOINTLY with
/// `stepDamping` by the stability region, NOT a free firmness knob. Follow regime
/// (driver-driven motion) uses `captureDistance = 0, stepDamping = 0`.
public struct CaptureStepParams: Sendable {
    /// Step when `BalanceState.margin` drops below this.
    public var triggerMargin: Float
    /// Distance the foot reaches BEYOND the CoM. `0` = follow (plant under CoM).
    public var captureDistance: Float
    /// Fraction of the step held back (`[0,1)`; higher = smaller/safer step).
    public var stepDamping: Float
    /// Seconds per swing.
    public var swingDuration: Float
    /// Peak of the swing lift arc.
    public var stepHeight: Float
    /// Minimum time between steps (rate limit — decouples step rhythm from disturbance rate).
    public var minStepInterval: Float

    public init(triggerMargin: Float = 0.02, captureDistance: Float = 0, stepDamping: Float = 0,
                swingDuration: Float = 0.25, stepHeight: Float = 0.06, minStepInterval: Float = 0.15) {
        self.triggerMargin = triggerMargin
        self.captureDistance = captureDistance
        self.stepDamping = stepDamping
        self.swingDuration = swingDuration
        self.stepHeight = stepHeight
        self.minStepInterval = minStepInterval
    }
}

/// Per-foot state: an ankle locked at a world point, or mid-swing.
public enum FootPhase: Sendable {
    case planted(SIMD3<Float>)
    case swinging(from: SIMD3<Float>, to: SIMD3<Float>, elapsed: Float)
}

/// Pure math for the capture-step controller (rig-free).
public enum CaptureStepMath {
    /// Position along a swing at parameter `t ∈ [0,1]`: smoothstep across `from→to`
    /// with a `stepHeight` lift that is zero at both ends and peaks at mid-swing.
    public static func swingArc(from: SIMD3<Float>, to: SIMD3<Float>, t: Float, stepHeight: Float) -> SIMD3<Float> {
        let c = simd_clamp(t, 0, 1)
        let eased = c * c * (3 - 2 * c)
        var p = from + (to - from) * eased
        p.y += stepHeight * sin(Float.pi * c)
        return p
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter CaptureStepControllerTests --disable-sandbox`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/VRMMetalKit/Animation/CaptureStepController.swift Tests/VRMMetalKitTests/Animation/CaptureStepControllerTests.swift
git commit -m "feat(stepping): CaptureStepParams, FootPhase, swing arc (2a core)"
```

---

### Task 2: Trailing-foot selection + follow/arrest capture placement

**Files:**
- Modify: `Sources/VRMMetalKit/Animation/CaptureStepController.swift`
- Test: `Tests/VRMMetalKitTests/Animation/CaptureStepControllerTests.swift`

**Interfaces:**
- Consumes: `BalanceModel.Foot` (increment 1).
- Produces (on `CaptureStepMath`):
  - `static func trailingFoot(leftPlant: SIMD3<Float>, rightPlant: SIMD3<Float>, comGround: SIMD2<Float>, imbalanceDirection: SIMD2<Float>) -> BalanceModel.Foot` — the planted foot furthest *behind* the fall (smaller projection onto `imbalanceDirection`), which is the one to swing toward the CoM.
  - `static func captureTargetXZ(comGround: SIMD2<Float>, imbalanceDirection: SIMD2<Float>, supportCentroid: SIMD2<Float>, captureDistance: Float, stepDamping: Float) -> SIMD2<Float>` — `supportCentroid + (1−stepDamping)·((comGround + imbalanceDirection·captureDistance) − supportCentroid)`.

- [ ] **Step 1: Write the failing tests**

Append to `CaptureStepControllerTests`:

```swift
    // MARK: - Task 2: trailing foot + capture placement

    func testTrailingFoot_isTheOneBehindTheFall() {
        // Fall/imbalance toward +x. Left foot at -x is behind the fall ⇒ trailing.
        let foot = CaptureStepMath.trailingFoot(
            leftPlant: SIMD3<Float>(-0.1, 0, 0), rightPlant: SIMD3<Float>(0.1, 0, 0),
            comGround: SIMD2<Float>(0, 0), imbalanceDirection: SIMD2<Float>(1, 0))
        XCTAssertEqual(foot, .left)
        // Flip the fall ⇒ right becomes trailing.
        let foot2 = CaptureStepMath.trailingFoot(
            leftPlant: SIMD3<Float>(-0.1, 0, 0), rightPlant: SIMD3<Float>(0.1, 0, 0),
            comGround: SIMD2<Float>(0, 0), imbalanceDirection: SIMD2<Float>(-1, 0))
        XCTAssertEqual(foot2, .right)
    }

    func testCaptureTarget_followPlantsExactlyAtCoM() {
        // captureDistance 0, stepDamping 0 ⇒ target == comGround (follow).
        let t = CaptureStepMath.captureTargetXZ(
            comGround: SIMD2<Float>(2, 1), imbalanceDirection: SIMD2<Float>(1, 0),
            supportCentroid: SIMD2<Float>(0, 0), captureDistance: 0, stepDamping: 0)
        XCTAssertEqual(t.x, 2, accuracy: 1e-5)
        XCTAssertEqual(t.y, 1, accuracy: 1e-5)
    }

    func testCaptureTarget_arrestReachesBeyondCoM_thenDamps() {
        let com = SIMD2<Float>(1, 0)
        let dir = SIMD2<Float>(1, 0)
        let centroid = SIMD2<Float>(0, 0)
        // Undamped arrest: full reach to com + dir*0.3 = (1.3, 0).
        let raw = CaptureStepMath.captureTargetXZ(comGround: com, imbalanceDirection: dir,
                                                  supportCentroid: centroid, captureDistance: 0.3, stepDamping: 0)
        XCTAssertEqual(raw.x, 1.3, accuracy: 1e-5)
        // 50% damping halves the step from the centroid: (0 + 0.5*1.3) = 0.65.
        let damped = CaptureStepMath.captureTargetXZ(comGround: com, imbalanceDirection: dir,
                                                     supportCentroid: centroid, captureDistance: 0.3, stepDamping: 0.5)
        XCTAssertEqual(damped.x, 0.65, accuracy: 1e-5, "damping scales the step from the centroid")
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter CaptureStepControllerTests --disable-sandbox`
Expected: FAIL — `type 'CaptureStepMath' has no member 'trailingFoot'`.

- [ ] **Step 3: Write the implementation**

Add to `CaptureStepMath` in `CaptureStepController.swift`:

```swift
    /// The planted foot furthest BEHIND the fall (smallest projection onto
    /// `imbalanceDirection`) — the one to swing toward the CoM for a capture step.
    public static func trailingFoot(leftPlant: SIMD3<Float>, rightPlant: SIMD3<Float>,
                                    comGround: SIMD2<Float>, imbalanceDirection: SIMD2<Float>) -> BalanceModel.Foot {
        let l = SIMD2<Float>(leftPlant.x, leftPlant.z)
        let r = SIMD2<Float>(rightPlant.x, rightPlant.z)
        let lp = simd_dot(l - comGround, imbalanceDirection)
        let rp = simd_dot(r - comGround, imbalanceDirection)
        return lp <= rp ? .left : .right
    }

    /// The damped capture target (xz): from the support centroid, step a fraction
    /// `(1 − stepDamping)` of the way toward the raw capture point
    /// `comGround + imbalanceDirection·captureDistance`. Follow (`captureDistance = 0,
    /// stepDamping = 0`) collapses to `comGround`.
    public static func captureTargetXZ(comGround: SIMD2<Float>, imbalanceDirection: SIMD2<Float>,
                                       supportCentroid: SIMD2<Float>, captureDistance: Float,
                                       stepDamping: Float) -> SIMD2<Float> {
        let rawTarget = comGround + imbalanceDirection * captureDistance
        return supportCentroid + (rawTarget - supportCentroid) * (1 - stepDamping)
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter CaptureStepControllerTests --disable-sandbox`
Expected: PASS (6 tests total).

- [ ] **Step 5: Commit**

```bash
git add Sources/VRMMetalKit/Animation/CaptureStepController.swift Tests/VRMMetalKitTests/Animation/CaptureStepControllerTests.swift
git commit -m "feat(stepping): trailing-foot selection + follow/arrest capture placement"
```

---

### Task 3: `CaptureStepController` state machine + `step(balance:dt:)`

**Files:**
- Modify: `Sources/VRMMetalKit/Animation/CaptureStepController.swift`
- Test: `Tests/VRMMetalKitTests/Animation/CaptureStepControllerTests.swift`

**Interfaces:**
- Consumes: `CaptureStepParams`, `FootPhase`, `CaptureStepMath` (Tasks 1–2), `BalanceState`, `BalanceModel.Foot` (increment 1).
- Produces: `public final class CaptureStepController`:
  - `init(params: CaptureStepParams = CaptureStepParams())`
  - `func seed(leftAnkle: SIMD3<Float>, rightAnkle: SIMD3<Float>)` — both feet `.planted` at the given (synthetic) positions; rig-free.
  - `func phase(_ foot: BalanceModel.Foot) -> FootPhase`
  - `func target(_ foot: BalanceModel.Foot) -> SIMD3<Float>` — planted position or mid-swing arc point.
  - `var plantedFeet: Set<BalanceModel.Foot>` / `func plantedPositions() -> [SIMD3<Float>]`
  - `@discardableResult func step(balance: BalanceState, dt: Float) -> (left: SIMD3<Float>, right: SIMD3<Float>)` — advances one frame; returns the two world-space ankle targets. **No groundY** (a rig/world quantity, deferred to 2b); a stepping foot preserves its own planted height. **Emits targets only — touches no rotation, no rig.**

- [ ] **Step 1: Write the failing tests**

Append to `CaptureStepControllerTests`:

```swift
    // MARK: - Task 3: controller state machine

    /// Build a BalanceState by hand from two foot positions + a CoM (rig-free), using
    /// BalanceModel's pure statics — the same closed-loop the convergence gate uses.
    private func balanceFrom(feet: [SIMD3<Float>], com: SIMD3<Float>, footHalf: Float = 0.05) -> BalanceState {
        var corners: [SIMD2<Float>] = []
        for f in feet {
            corners.append(SIMD2<Float>(f.x - footHalf, f.z - footHalf))
            corners.append(SIMD2<Float>(f.x + footHalf, f.z - footHalf))
            corners.append(SIMD2<Float>(f.x + footHalf, f.z + footHalf))
            corners.append(SIMD2<Float>(f.x - footHalf, f.z + footHalf))
        }
        let poly = BalanceModel.supportPolygon(footCorners: corners)
        let comGround = SIMD2<Float>(com.x, com.z)
        let (margin, centroid) = BalanceModel.stabilityMargin(comGround: comGround, polygon: poly)
        let imbalance = BalanceModel.imbalanceDirection(comGround: comGround, centroid: centroid)
        return BalanceState(centerOfMass: com, comGround: comGround, supportPolygon: poly,
                            supportCentroid: centroid, margin: margin, imbalanceDirection: imbalance)
    }

    func testStep_noStepWhenBalanced() {
        let c = CaptureStepController()
        c.seed(leftAnkle: SIMD3<Float>(-0.1, 0, 0), rightAnkle: SIMD3<Float>(0.1, 0, 0))
        // CoM centered ⇒ margin large positive ⇒ no step; feet stay planted where seeded.
        let b = balanceFrom(feet: [SIMD3<Float>(-0.1, 0, 0), SIMD3<Float>(0.1, 0, 0)], com: SIMD3<Float>(0, 1, 0))
        for _ in 0..<10 { _ = c.step(balance: b, dt: 1.0 / 60.0) }
        XCTAssertEqual(c.plantedFeet, [.left, .right])
        XCTAssertEqual(c.target(.left), SIMD3<Float>(-0.1, 0, 0))
        XCTAssertEqual(c.target(.right), SIMD3<Float>(0.1, 0, 0))
    }

    func testStep_imbalanceStartsASingleSwing_keepsOneFootPlanted() {
        var p = CaptureStepParams(); p.minStepInterval = 0
        let c = CaptureStepController(params: p)
        c.seed(leftAnkle: SIMD3<Float>(-0.1, 0, 0), rightAnkle: SIMD3<Float>(0.1, 0, 0))
        // CoM shoved past the +x edge ⇒ margin < triggerMargin ⇒ a step fires.
        let b = balanceFrom(feet: [SIMD3<Float>(-0.1, 0, 0), SIMD3<Float>(0.1, 0, 0)], com: SIMD3<Float>(0.5, 1, 0))
        _ = c.step(balance: b, dt: 1.0 / 60.0)   // one frame: a swing begins
        XCTAssertEqual(c.plantedFeet.count, 1, "exactly one foot planted during a swing (≥1 invariant)")
    }

    func testStep_swingCompletesToPlantedAtTarget() {
        // Large minStepInterval so exactly ONE step fires; the swing then completes
        // without a second step re-triggering.
        var p = CaptureStepParams(); p.minStepInterval = 10; p.swingDuration = 0.1; p.captureDistance = 0; p.stepDamping = 0
        let c = CaptureStepController(params: p)
        c.seed(leftAnkle: SIMD3<Float>(-0.1, 0, 0), rightAnkle: SIMD3<Float>(0.1, 0, 0))
        let com = SIMD3<Float>(0.5, 1, 0)
        let b = balanceFrom(feet: [SIMD3<Float>(-0.1, 0, 0), SIMD3<Float>(0.1, 0, 0)], com: com)
        _ = c.step(balance: b, dt: 0.02)          // begin the single swing (trailing = left, target ≈ comGround)
        for _ in 0..<10 { _ = c.step(balance: b, dt: 0.02) }   // advance past swingDuration (0.1s)
        XCTAssertEqual(c.plantedFeet.count, 2, "swing completed, both planted again")
        // The swung (left) foot re-planted at the CoM ground projection (follow).
        XCTAssertEqual(c.target(.left).x, com.x, accuracy: 0.05)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter CaptureStepControllerTests --disable-sandbox`
Expected: FAIL — `cannot find 'CaptureStepController' in scope`.

- [ ] **Step 3: Write the implementation**

Add to `CaptureStepController.swift`:

```swift
/// Procedural capture-step controller — the pure core (design 2026-07-06). Consumes a
/// `BalanceState`, emits world-space ankle targets, and owns the per-foot state
/// machine. **Seam invariant: this type never touches a bone rotation, an IK solver,
/// or the rig — 2b owns all of that.** Root motion is an input; the feet follow/catch.
public final class CaptureStepController {
    public var params: CaptureStepParams
    private var left: FootPhase = .planted(SIMD3<Float>(repeating: 0))
    private var right: FootPhase = .planted(SIMD3<Float>(repeating: 0))
    private var timeSinceLastStep: Float = 0

    public init(params: CaptureStepParams = CaptureStepParams()) {
        self.params = params
    }

    /// Seed both feet planted at the given (synthetic in 2a; rig-sourced in 2b) ankle
    /// world positions. Rig-free — takes positions as data.
    public func seed(leftAnkle: SIMD3<Float>, rightAnkle: SIMD3<Float>) {
        left = .planted(leftAnkle)
        right = .planted(rightAnkle)
        timeSinceLastStep = params.minStepInterval   // ready to step immediately
    }

    public func phase(_ foot: BalanceModel.Foot) -> FootPhase { foot == .left ? left : right }

    public func target(_ foot: BalanceModel.Foot) -> SIMD3<Float> {
        switch phase(foot) {
        case .planted(let p):
            return p
        case .swinging(let from, let to, let elapsed):
            let t = params.swingDuration > 0 ? elapsed / params.swingDuration : 1
            return CaptureStepMath.swingArc(from: from, to: to, t: t, stepHeight: params.stepHeight)
        }
    }

    public var plantedFeet: Set<BalanceModel.Foot> {
        var s = Set<BalanceModel.Foot>()
        if case .planted = left { s.insert(.left) }
        if case .planted = right { s.insert(.right) }
        return s
    }

    public func plantedPositions() -> [SIMD3<Float>] {
        var out: [SIMD3<Float>] = []
        if case .planted(let p) = left { out.append(p) }
        if case .planted(let p) = right { out.append(p) }
        return out
    }

    /// Advance one frame and return the two world-space ankle targets. Begins at most
    /// one swing (≥1 foot always planted), rate-limited by `minStepInterval`.
    @discardableResult
    public func step(balance: BalanceState, dt: Float) -> (left: SIMD3<Float>, right: SIMD3<Float>) {
        timeSinceLastStep += dt
        advanceSwing(&left, dt: dt)
        advanceSwing(&right, dt: dt)

        let bothPlanted = { if case .planted = left, case .planted = right { return true }; return false }()
        if bothPlanted, timeSinceLastStep >= params.minStepInterval, balance.margin < params.triggerMargin,
           case .planted(let lp) = left, case .planted(let rp) = right {
            let foot = CaptureStepMath.trailingFoot(leftPlant: lp, rightPlant: rp,
                                                    comGround: balance.comGround,
                                                    imbalanceDirection: balance.imbalanceDirection)
            let txz = CaptureStepMath.captureTargetXZ(comGround: balance.comGround,
                                                      imbalanceDirection: balance.imbalanceDirection,
                                                      supportCentroid: balance.supportCentroid,
                                                      captureDistance: params.captureDistance,
                                                      stepDamping: params.stepDamping)
            let from = foot == .left ? lp : rp
            let to = SIMD3<Float>(txz.x, from.y, txz.y)   // preserve the foot's own height (flat ground; groundY is 2b)
            let swing = FootPhase.swinging(from: from, to: to, elapsed: 0)
            if foot == .left { left = swing } else { right = swing }
            timeSinceLastStep = 0
        }
        return (target(.left), target(.right))
    }

    private func advanceSwing(_ phase: inout FootPhase, dt: Float) {
        guard case .swinging(let from, let to, let elapsed) = phase else { return }
        let e = elapsed + dt
        phase = e >= params.swingDuration ? .planted(to) : .swinging(from: from, to: to, elapsed: e)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter CaptureStepControllerTests --disable-sandbox`
Expected: PASS (9 tests total).

- [ ] **Step 5: Commit**

```bash
git add Sources/VRMMetalKit/Animation/CaptureStepController.swift Tests/VRMMetalKitTests/Animation/CaptureStepControllerTests.swift
git commit -m "feat(stepping): CaptureStepController state machine + step(balance:dt:)"
```

---

### Task 4: The convergence corner gate (the honest gate) + committed bounds

**Files:**
- Modify: `Sources/VRMMetalKit/Animation/CaptureStepController.swift` (add committed-bounds constants)
- Test: `Tests/VRMMetalKitTests/Animation/CaptureStepControllerTests.swift`

**Interfaces:**
- Consumes: everything above + `BalanceModel` pure statics.
- Produces (on `CaptureStepParams`): `static let committedCaptureDistanceMax: Float`, `static let committedStepDampingMin: Float` — the shipped bounds. The corner test runs at `(committedCaptureDistanceMax, committedStepDampingMin)`. **Changing either re-triggers this test** (spec §6/§7).

This task closes the increment's honest gate: driving the assembled controller in a **closed loop against `BalanceModel`'s pure statics with a fixed shoved CoM** (2a's CoM-response model), the residual imbalance must **contract** at the worst-case corner, and a config **outside** the stability region must **not** contract (so the test discriminates stability rather than passing trivially).

The committed bounds must be *calibrated*, not guessed: Step 3 runs the corner test; if it does not contract, tighten the bounds (lower `committedCaptureDistanceMax` and/or raise `committedStepDampingMin`) until the corner contracts, and confirm the just-outside case still fails to contract. This is the empirical calibration the spec mandates (§6) — the bounds are shipped where the corner is proven stable.

- [ ] **Step 1: Write the failing test**

Append to `CaptureStepControllerTests`:

```swift
    // MARK: - Task 4: convergence corner gate (the honest gate)
    //
    // CONDITIONAL ON 2a's CoM-RESPONSE MODEL: the CoM is held fixed under a synthetic
    // shove and the foot lands exactly at its target. 2b's real-rig follow/moonwalk
    // test is what validates that model against an actual rig. This gate proves the
    // STEP LOGIC contracts given the model — not that the real CoM-response matches it.

    /// Drive the controller one full step at a time against BalanceModel's pure statics
    /// with a fixed CoM; return the residual (CoM distance past the support edge) after
    /// each completed step.
    private func residualSequence(params p: CaptureStepParams, comGround: SIMD2<Float>, steps: Int) -> [Float] {
        let c = CaptureStepController(params: p)
        c.seed(leftAnkle: SIMD3<Float>(-0.1, 0, 0), rightAnkle: SIMD3<Float>(0.1, 0, 0))
        let com = SIMD3<Float>(comGround.x, 1, comGround.y)
        var residuals: [Float] = []
        // Deterministic one step per iteration: measure the residual with both feet
        // planted, trigger a step, then advance frames until that swing completes
        // (both planted again) before the next measurement.
        for _ in 0..<steps {
            let feet = c.plantedPositions()
            let b = balanceFrom(feet: feet, com: com)
            residuals.append(max(0, -b.margin))          // distance CoM is OUTSIDE support
            if b.margin >= p.triggerMargin { break }     // converged — support caught the CoM
            _ = c.step(balance: b, dt: 1.0 / 60.0)       // triggers one swing
            var guardFrames = 0
            while c.plantedFeet.count < 2 && guardFrames < 1000 {
                _ = c.step(balance: b, dt: 1.0 / 60.0)   // finish the swing to the (stale-b) target
                guardFrames += 1
            }
        }
        return residuals
    }

    func testConvergence_atCommittedCorner_contracts() {
        // Worst-case corner: max captureDistance × min stepDamping = max loop gain.
        var p = CaptureStepParams()
        p.captureDistance = CaptureStepParams.committedCaptureDistanceMax
        p.stepDamping = CaptureStepParams.committedStepDampingMin
        p.minStepInterval = 0
        let r = residualSequence(params: p, comGround: SIMD2<Float>(0.4, 0), steps: 12)
        // Monotone contraction (no oscillation): each residual ≤ the previous, and it
        // reaches near zero (support caught up to the CoM).
        for i in 1..<r.count { XCTAssertLessThanOrEqual(r[i], r[i - 1] + 1e-4, "step \(i) did not contract: \(r)") }
        XCTAssertLessThan(r.last ?? .greatestFiniteMagnitude, 0.05, "recovery converges: \(r)")
    }

    func testConvergence_outsideRegion_doesNotContract() {
        // A config well outside the stability region (huge capture, zero damping):
        // loop gain > 1 ⇒ the residual must NOT monotonically contract to zero.
        var p = CaptureStepParams()
        p.captureDistance = 1.2
        p.stepDamping = 0
        p.minStepInterval = 0
        let r = residualSequence(params: p, comGround: SIMD2<Float>(0.4, 0), steps: 12)
        let contracted = zip(r.dropFirst(), r).allSatisfy { $0 <= $1 + 1e-4 } && (r.last ?? 1) < 0.05
        XCTAssertFalse(contracted, "outside the region the recovery must not cleanly converge: \(r)")
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter CaptureStepControllerTests --disable-sandbox`
Expected: FAIL — `type 'CaptureStepParams' has no member 'committedCaptureDistanceMax'`.

- [ ] **Step 3: Add the committed bounds, then CALIBRATE**

Add to `CaptureStepParams` in `CaptureStepController.swift`:

```swift
    /// Shipped stability bounds — the corner `(committedCaptureDistanceMax,
    /// committedStepDampingMin)` is where `CaptureStepControllerTests`'
    /// `testConvergence_atCommittedCorner_contracts` proves convergence. The guarantee
    /// is SCOPED to these bounds (design §6/§7): changing either re-triggers that test.
    public static let committedCaptureDistanceMax: Float = 0.12
    public static let committedStepDampingMin: Float = 0.4
```

Then run `testConvergence_atCommittedCorner_contracts`. **If it does not contract**, lower `committedCaptureDistanceMax` (e.g. 0.10, 0.08) and/or raise `committedStepDampingMin` (e.g. 0.5, 0.6) and re-run until the corner contracts. Then run `testConvergence_outsideRegion_doesNotContract` and confirm the outside case still fails to converge (if it accidentally converges, push it further out — larger `captureDistance`). Commit the calibrated bounds. This calibration IS the empirical gate; the committed values are wherever the corner is proven stable.

- [ ] **Step 4: Run the gate to verify it passes**

Run: `swift test --filter CaptureStepControllerTests --disable-sandbox`
Expected: PASS (11 tests total), including both convergence cases.

- [ ] **Step 5: Commit**

```bash
git add Sources/VRMMetalKit/Animation/CaptureStepController.swift Tests/VRMMetalKitTests/Animation/CaptureStepControllerTests.swift
git commit -m "feat(stepping): convergence corner gate + committed stability bounds (2a gate)"
```

---

## Self-Review

**Spec coverage (2a scope):**
- §3 controller shape (params, `FootPhase`, state, ≥1-planted, rate limit) → Tasks 1, 3. ✓
- §4 per-frame algorithm (advance swing, decide step, trigger/trailing/placement) → Task 3 `step`. ✓ (IK step 4 is 2b.)
- §5 follow vs arrest + damping formula + follow=`comGround` → Task 2. ✓ (Swing-lag / speed-cap is a 2b/driver concern; noted.)
- §6 joint stability region + committed bounds → Task 4 (`committed*` constants, corner test). ✓
- §7 convergence corner gate + just-outside discriminator → Task 4. ✓ Follow/moonwalk + non-interference integration tests are **2b** (need the rig + IK) — explicitly out of 2a per the split.
- §2 feedback edge → embodied by the closed-loop gate (Task 4 drives `plantedFeet → margin → step → plantedFeet`). ✓
- Seam invariant (no rig/IK/rotation) → structural: the file imports only `Foundation`/`simd`, references only `BalanceState`/`BalanceModel.Foot`. ✓

**Placeholder scan:** none — complete code and commands throughout. Task 4's calibration is an explicit, bounded loop (not a vague "tune it"), which is the spec-mandated empirical step, with concrete start values and a concrete adjust direction.

**Type consistency:** `CaptureStepParams`, `FootPhase`, `CaptureStepMath` (statics), `CaptureStepController` (`seed`, `step(balance:dt:)`, `target`, `plantedFeet`, `plantedPositions`), and `BalanceModel.Foot`/`BalanceState` are used identically across tasks. `SIMD2` is xz throughout (matching increment 1). `step` takes `(balance:dt:)` — no `groundY` — consistently.

**2b (next plan), for reference — NOT in this plan:** `update(deltaTime:model:rootVelocity:groundY:)` that seeds/sources ankle positions from the rig, computes `BalanceModel.evaluate` from the posed model, calls `step`, and applies the returned targets via `TwoBoneIKSolver` with world→local conversion; real-rig follow/moonwalk (plant-then-step, margin recovers) and non-interference tests.
