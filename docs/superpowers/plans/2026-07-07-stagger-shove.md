# Stagger Shove (Increment 3) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Convert crowd contact penetration into a rate-limited ground-plane CoM shove that the already-validated `CaptureStepController` absorbs by visibly stepping — an avatar staggers on contact and stays upright.

**Architecture:** One pure solver (`StaggerShoveSolver`: penetration → rate-limited XZ root offset, no momentum), wired into `CrowdFrameStepper` as a new Phase 0e that is dormant until first contact, shoves the scene root, and runs the unchanged `CaptureStepController` on increment 2's exact validated channel (root translates, planted feet held, controller steps). Opt-in via a `--stagger` renderer flag.

**Tech Stack:** Swift 6.2, simd, XCTest. No Metal shader changes. Spec: `docs/superpowers/specs/2026-07-07-stagger-impulse-design.md`.

## Global Constraints

- New source files start with the Apache 2.0 header (copy the exact 15-line header from `Sources/VRMMetalKit/Animation/CaptureStepController.swift:1-15`).
- Tests always run with `--disable-sandbox`.
- `CaptureStepController.swift` is **not modified** — the controller is used unchanged (spec §1 architectural invariant). Its reserved `rootVelocity` hook stays unused.
- `velocityCap` default is exactly `0.14` (= 0.7 × the rig-confirmed 0.2 m/s capacity). For a more dramatic stagger tune `shoveGain`, never `velocityCap`.
- Phase 0e builds its `CaptureStepController` with the committed arrest defaults (`captureDistance = CaptureStepParams.committedCaptureDistanceMax`, `stepDamping = CaptureStepParams.committedStepDampingMin`) — the exact configuration the ~0.2 m/s capacity was validated with. Never plain `CaptureStepParams()` (that's the unvalidated *follow* regime).
- With `stagger: nil` the crowd path must be byte-identical to today's behavior; with stagger enabled it must stay byte-identical **until first contact** (dormant gating).
- No temporary contextual/informational comments in code (CLAUDE.md). Doc comments stating constraints are fine and expected — match the density of `PosturalContactSolver.swift`.
- Commit after each task. Do **not** push (pushes trigger Xcode Cloud; the user pushes on request).
- Known pre-existing failure: `testShaderSourceHashMatchesKnownGood` (stale hash since #197) may fail regardless of this work — verify any unexpected failure also fails on `main` before investigating.

---

### Task 1: `StaggerShoveSolver` pure core (gates G1–G4)

**Files:**
- Create: `Sources/VRMMetalKit/Animation/StaggerShoveSolver.swift`
- Test: `Tests/VRMMetalKitTests/Animation/StaggerShoveSolverTests.swift`

**Interfaces:**
- Consumes: nothing (pure, Metal-free, model-free).
- Produces (Tasks 2–5 rely on these exact signatures):
  - `public struct StaggerShoveParams: Sendable { var shoveGain: Float; var velocityCap: Float; init(shoveGain: Float = 6.0, velocityCap: Float = 0.14) }`
  - `public struct StaggerShoveSolver: Sendable { var params: StaggerShoveParams; private(set) var offset: SIMD2<Float>; init(params: StaggerShoveParams = StaggerShoveParams()); @discardableResult mutating func update(depth: Float, pushDirXZ: SIMD2<Float>, dt: Float) -> SIMD2<Float> }`

- [ ] **Step 1: Write the failing tests**

Create `Tests/VRMMetalKitTests/Animation/StaggerShoveSolverTests.swift` (Apache header first, then):

```swift
import XCTest
import simd
@testable import VRMMetalKit

/// Solver gates G1–G4 (design 2026-07-07 §6.1). Every gate carries the
/// discriminating counter-case the design names — a variant that must FAIL the
/// gate's criterion, proving the pass is not vacuous.
final class StaggerShoveSolverTests: XCTestCase {
    private let dt: Float = 1.0 / 60.0

    /// G1 — the rate cap binds: a fast-deepening penetration moves the offset by
    /// at most `velocityCap·dt` per frame. Counter-case: an effectively infinite
    /// cap lets the same input jump past that bound.
    func testG1_rateCapBinds_fastDeepeningPenetration() {
        var capped = StaggerShoveSolver(params: StaggerShoveParams(shoveGain: 6.0, velocityCap: 0.14))
        let before = capped.offset
        capped.update(depth: 1.0, pushDirXZ: SIMD2<Float>(1, 0), dt: dt)
        XCTAssertLessThanOrEqual(simd_length(capped.offset - before), 0.14 * dt + 1e-6,
                                 "per-frame move is capped at velocityCap·dt")

        var uncapped = StaggerShoveSolver(params: StaggerShoveParams(shoveGain: 6.0, velocityCap: 1e9))
        uncapped.update(depth: 1.0, pushDirXZ: SIMD2<Float>(1, 0), dt: dt)
        XCTAssertGreaterThan(simd_length(uncapped.offset), 0.14 * dt,
                             "uncapped variant exceeds the bound — the cap genuinely binds")
    }

    /// G2 — zero-on-separation (strict coupling, no momentum): after a contact
    /// ramp, holding depth = 0 decays the offset to zero within the rate-limited
    /// window, and it stays zero. Counter-case: a velocity-integrating variant
    /// coasts past separation and never returns to zero.
    func testG2_zeroOnSeparation_noMomentum() {
        var solver = StaggerShoveSolver(params: StaggerShoveParams(shoveGain: 6.0, velocityCap: 0.14))
        for _ in 0..<60 { solver.update(depth: 0.05, pushDirXZ: SIMD2<Float>(1, 0), dt: dt) }
        XCTAssertGreaterThan(simd_length(solver.offset), 0.01, "contact ramp built a real offset")

        let framesToZero = Int((simd_length(solver.offset) / (0.14 * dt)).rounded(.up)) + 1
        for _ in 0..<framesToZero { solver.update(depth: 0, pushDirXZ: .zero, dt: dt) }
        XCTAssertLessThanOrEqual(simd_length(solver.offset), 1e-5,
                                 "offset decays to zero within ⌈|offset|/(velocityCap·dt)⌉ frames")
        for _ in 0..<30 { solver.update(depth: 0, pushDirXZ: .zero, dt: dt) }
        XCTAssertLessThanOrEqual(simd_length(solver.offset), 1e-5, "and stays zero")

        var pos = SIMD2<Float>.zero
        var vel = SIMD2<Float>.zero
        for _ in 0..<60 {
            vel += 6.0 * 0.05 * SIMD2<Float>(1, 0) * dt
            pos += vel * dt
        }
        let atSeparation = pos
        for _ in 0..<framesToZero { pos += vel * dt }
        XCTAssertGreaterThan(simd_length(pos), simd_length(atSeparation),
                             "momentum variant coasts after separation")
        XCTAssertGreaterThan(simd_length(pos), 1e-5, "and retains a non-zero residual — the criterion discriminates")
    }

    /// G3 — no overshoot: under constant depth the offset converges monotonically
    /// to `shoveGain·depth·d̂` and never exceeds the target magnitude.
    /// Counter-case: an underdamped second-order integrator overshoots on the way in.
    func testG3_noOvershootAtTarget() {
        let params = StaggerShoveParams(shoveGain: 6.0, velocityCap: 0.14)
        var solver = StaggerShoveSolver(params: params)
        let depth: Float = 0.05
        let targetMag = params.shoveGain * depth
        var previous: Float = 0
        for _ in 0..<400 {
            solver.update(depth: depth, pushDirXZ: SIMD2<Float>(0, 1), dt: dt)
            let mag = simd_length(solver.offset)
            XCTAssertGreaterThanOrEqual(mag, previous - 1e-6, "monotone approach")
            XCTAssertLessThanOrEqual(mag, targetMag + 1e-5, "never exceeds the target magnitude")
            previous = mag
        }
        XCTAssertEqual(simd_length(solver.offset), targetMag, accuracy: 1e-4, "converged to shoveGain·depth")

        var pos: Float = 0, vel: Float = 0, peak: Float = 0
        for _ in 0..<400 {
            vel += (targetMag - pos) * 40 * dt
            pos += vel * dt
            peak = max(peak, pos)
        }
        XCTAssertGreaterThan(peak, targetMag + 1e-3,
                             "second-order variant overshoots — the criterion discriminates position-driven from ballistic")
    }

    /// G4 — direction: the converged offset points along pushDirXZ (away from the
    /// partner) across several orientations, including a non-unit input (the
    /// solver normalizes). Direct-measurement metric: rigor comes from orientation
    /// coverage + tight ε; a sign flip would read alignment ≈ −1. Degenerate
    /// direction yields a well-defined zero.
    func testG4_offsetPointsAlongPushDirection() {
        let directions: [SIMD2<Float>] = [
            SIMD2(1, 0), SIMD2(0, 1), SIMD2(-1, 0), SIMD2(0, -1),
            SIMD2(0.6, 0.8), SIMD2(-0.707, 0.707), SIMD2(3, 4),
        ]
        for dir in directions {
            var solver = StaggerShoveSolver(params: StaggerShoveParams(shoveGain: 6.0, velocityCap: 0.14))
            for _ in 0..<120 { solver.update(depth: 0.05, pushDirXZ: dir, dt: dt) }
            let mag = simd_length(solver.offset)
            XCTAssertGreaterThan(mag, 0.01, "offset built up for \(dir)")
            let alignment = simd_dot(solver.offset / mag, simd_normalize(dir))
            XCTAssertGreaterThan(alignment, 0.999, "offset points along pushDir for \(dir)")
        }

        var degenerate = StaggerShoveSolver(params: StaggerShoveParams(shoveGain: 6.0, velocityCap: 0.14))
        degenerate.update(depth: 0.05, pushDirXZ: .zero, dt: dt)
        XCTAssertEqual(degenerate.offset, .zero, "degenerate pushDir yields a well-defined zero target")
    }
}
```

- [ ] **Step 2: Verify the tests fail to compile (red)**

Run: `swift build --build-tests 2>&1 | grep -m3 "StaggerShove"`
Expected: `error: cannot find 'StaggerShoveSolver' in scope` (or equivalent). The type does not exist yet.

- [ ] **Step 3: Write the implementation**

Create `Sources/VRMMetalKit/Animation/StaggerShoveSolver.swift` (Apache header first, then):

```swift
import Foundation
import simd

/// Tuning for the stagger shove (design 2026-07-07 §2). Uniform across avatars
/// in v1 (per-avatar mass/scale weighting is a deferred non-goal).
public struct StaggerShoveParams: Sendable {
    /// Metres of ground-plane CoM offset per metre of penetration depth.
    /// Amplifies a shallow (Component-A-clamped) penetration into an offset that
    /// can exceed the support margin; calibrated against `bodyContactMargin` in
    /// the visual spike (design §5).
    public var shoveGain: Float
    /// Maximum rate of change of the offset (m/s). Defaults to 0.7 × 0.2 = 0.14 —
    /// a safety fraction of the rig-confirmed ~0.2 m/s tracking capacity
    /// (`CaptureStepIKTests.testRigTrackingCapacity_belowHolds_overCapacityGrows`),
    /// so the disturbance the capture-step controller sees stays inside the
    /// validated band. Bounds the shove component only; for a more dramatic
    /// stagger raise `shoveGain`, not this.
    public var velocityCap: Float

    public init(shoveGain: Float = 6.0, velocityCap: Float = 0.14) {
        self.shoveGain = shoveGain
        self.velocityCap = velocityCap
    }
}

/// The pure, deterministic core of the stagger shove (design 2026-07-07 §2):
/// penetration (depth, pushDir) → a rate-limited ground-plane (XZ) CoM offset.
/// A first-order rate limiter — converges to the target, never overshoots,
/// never coasts, so there is no momentum: on separation the target becomes zero
/// and the offset ramps back at ≤ `velocityCap` (the §1 return-glide).
/// Metal-free and model-free; ``CrowdFrameStepper`` wraps it with the
/// root/controller plumbing (Phase 0e).
public struct StaggerShoveSolver: Sendable {
    public var params: StaggerShoveParams
    /// The current ground-plane CoM displacement, carried across frames.
    public private(set) var offset: SIMD2<Float> = .zero

    public init(params: StaggerShoveParams = StaggerShoveParams()) {
        self.params = params
    }

    /// Advance one frame: aim at `shoveGain · depth` along the normalized
    /// ground-plane push direction — zero when there is no contact or the
    /// direction is degenerate — and move `offset` toward that target by at most
    /// `velocityCap · dt`. Returns the updated offset.
    @discardableResult
    public mutating func update(depth: Float, pushDirXZ: SIMD2<Float>, dt: Float) -> SIMD2<Float> {
        let dirLength = simd_length(pushDirXZ)
        let target: SIMD2<Float> = (depth > 0 && dirLength > 1e-6)
            ? params.shoveGain * depth * (pushDirXZ / dirLength)
            : .zero
        let delta = target - offset
        let maxStep = params.velocityCap * max(dt, 0)
        if simd_length(delta) <= maxStep {
            offset = target
        } else if maxStep > 0 {
            offset += simd_normalize(delta) * maxStep
        }
        return offset
    }
}
```

- [ ] **Step 4: Run the tests (green)**

Run: `swift test --filter StaggerShoveSolverTests --disable-sandbox`
Expected: `Executed 4 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add Sources/VRMMetalKit/Animation/StaggerShoveSolver.swift Tests/VRMMetalKitTests/Animation/StaggerShoveSolverTests.swift
git commit -m "feat(stagger): StaggerShoveSolver pure core — rate-limited CoM offset (G1-G4)"
```

---

### Task 2: Crowd wiring — Phase 0e in `CrowdFrameStepper` (gate G7 + activation)

**Files:**
- Modify: `Sources/VRMMetalKit/Crowd/CrowdFrameStepper.swift`
- Test: `Tests/VRMMetalKitTests/Crowd/StaggerShoveIntegrationTests.swift` (create)

**Interfaces:**
- Consumes: `StaggerShoveParams` / `StaggerShoveSolver` (Task 1, exact signatures above); `CaptureStepController(params:)`, `.update(deltaTime:model:)`, `.plantedFeet`; `PosturalContactSolver.penetration(point:capsuleP0:capsuleP1:radius:) -> (depth: Float, pushDir: SIMD3<Float>)`; `CaptureStepParams.committedCaptureDistanceMax` / `.committedStepDampingMin`.
- Produces (Tasks 3 and 5 rely on these):
  - `CrowdFrameStepper.init(avatars:driver:group:fps:bodyContactMargin:postural:stagger:)` — new trailing `stagger: StaggerShoveParams? = nil` parameter.
  - `public func staggerSolver(forAvatar avatarIndex: Int) -> StaggerShoveSolver?` (a copy — read `.offset` for inspection).
  - `public func captureStepController(forAvatar avatarIndex: Int) -> CaptureStepController?`

- [ ] **Step 1: Write the failing tests**

Create `Tests/VRMMetalKitTests/Crowd/StaggerShoveIntegrationTests.swift` (Apache header first, then):

```swift
import XCTest
import Metal
import simd
@testable import VRMMetalKit

/// Crowd-wiring gates for the stagger shove (design 2026-07-07 §6.2/§6.3):
/// G7 (disabled/dormant is a byte-identical no-op), contact-onset activation,
/// and — appended in the integration-gate task — G5/G6 (residual contraction on
/// the real rig, with the over-capacity escape counter-case).
final class StaggerShoveIntegrationTests: XCTestCase {
    @MainActor private func avatar(_ device: MTLDevice, index: Int) async throws -> CrowdFrameStepper.Avatar {
        let path = getTestVRM10ModelPath(); try requireFixture(path, hint: testVRM10Filename)
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device,
            options: VRMLoadingOptions(augmentSpringBoneColliders: false))
        var config = RendererConfig(); config.synchronousSpringBone = true
        let r = VRMRenderer(device: device, config: config)
        r.loadModel(model)
        let player = AnimationPlayer()
        for root in model.nodes where root.parent == nil {
            root.rotation = CrowdPlacement.facing(avatarIndex: index, avatarCount: 2)
        }
        model.updateNodeTransforms()
        return CrowdFrameStepper.Avatar(renderer: r, model: model, player: player, index: index)
    }

    /// Hold-only driver: constant half-separation for the whole run — zero
    /// scripted root motion, so the shove is the only root disturbance
    /// (design §6.2 fixture constraint (a)).
    private func holdOnlyDriver(halfSep: Float) -> CrowdMotionDriver {
        CrowdMotionDriver(startSep: halfSep, holdSep: halfSep,
                          approachStart: 0.0, approachEnd: 0.01, holdEnd: 1.0, partEnd: 1.0)
    }

    /// Leg-bone rotations + root translations — the exact state the stagger path
    /// writes (controller writes hips/knees via IK; the shove writes roots).
    @MainActor private func legAndRootState(_ model: VRMModel) throws -> [SIMD4<Float>] {
        let humanoid = try XCTUnwrap(model.humanoid)
        var out: [SIMD4<Float>] = []
        for bone: VRMHumanoidBone in [.leftUpperLeg, .leftLowerLeg, .rightUpperLeg, .rightLowerLeg] {
            let idx = try XCTUnwrap(humanoid.getBoneNode(bone))
            out.append(model.nodes[idx].rotation.vector)
        }
        for root in model.nodes where root.parent == nil {
            out.append(SIMD4<Float>(root.translation, 0))
        }
        return out
    }

    /// G7 — disabled is a no-op, and enabled-but-never-in-contact is byte-identical
    /// to disabled (the dormant gating): far-separated avatars stepped 60 frames
    /// with `stagger: nil` vs with stagger enabled produce exactly equal leg-bone
    /// rotations and root translations, and the enabled run's solver never leaves
    /// zero. This is the opt-in guarantee — existing renders are unaffected.
    @MainActor func testG7_disabledAndDormantAreByteIdenticalNoOp() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }

        func run(stagger: StaggerShoveParams?) async throws -> (states: [[SIMD4<Float>]], stepper: CrowdFrameStepper, model: VRMModel) {
            let a = try await avatar(device, index: 0)
            let b = try await avatar(device, index: 1)
            let stepper = CrowdFrameStepper(avatars: [a, b], driver: holdOnlyDriver(halfSep: 1.0),
                                            group: nil, fps: 60, stagger: stagger)
            var states: [[SIMD4<Float>]] = []
            for f in 0..<60 {
                stepper.step(frameTime: Float(f) / 60.0)
                states.append(try legAndRootState(a.model))
            }
            return (states, stepper, a.model)
        }

        let disabled = try await run(stagger: nil)
        XCTAssertNil(disabled.stepper.staggerSolver(forAvatar: 0), "stagger nil ⇒ no solver")
        XCTAssertNil(disabled.stepper.captureStepController(forAvatar: 0), "stagger nil ⇒ no controller")

        let dormant = try await run(stagger: StaggerShoveParams())
        let solver = try XCTUnwrap(dormant.stepper.staggerSolver(forAvatar: 0))
        XCTAssertEqual(solver.offset, .zero, "no contact ⇒ solver never activated")

        XCTAssertEqual(disabled.states.count, dormant.states.count)
        for f in disabled.states.indices {
            XCTAssertEqual(disabled.states[f], dormant.states[f],
                           "frame \(f): dormant stagger must be byte-identical to stagger-off")
        }
    }

    /// Activation — contact onset: at deep constant overlap the channel activates,
    /// the offset grows away from the partner (avatar 0 sits at −X, partner at +X,
    /// so its push direction is −X), and the controller exists and has been run
    /// (it seeds itself on its first update, so both feet report planted).
    @MainActor func testActivation_onsetAtFirstContact_offsetGrowsAwayFromPartner() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let a = try await avatar(device, index: 0)
        let b = try await avatar(device, index: 1)
        let stepper = CrowdFrameStepper(avatars: [a, b], driver: holdOnlyDriver(halfSep: 0.06),
                                        group: nil, fps: 60, stagger: StaggerShoveParams())
        for f in 0..<30 { stepper.step(frameTime: Float(f) / 60.0) }
        let solver = try XCTUnwrap(stepper.staggerSolver(forAvatar: 0))
        XCTAssertGreaterThan(simd_length(solver.offset), 0.02, "offset built up after contact onset")
        XCTAssertLessThan(solver.offset.x, 0, "avatar 0 is shoved away from the +X partner")
        XCTAssertNotNil(stepper.captureStepController(forAvatar: 0), "controller wired per avatar")
    }
}
```

- [ ] **Step 2: Verify the tests fail to compile (red)**

Run: `swift build --build-tests 2>&1 | grep -m3 "stagger"`
Expected: `error: extra argument 'stagger' in call` (the init parameter doesn't exist yet).

- [ ] **Step 3: Implement Phase 0e in `CrowdFrameStepper.swift`**

Four edits, all in `Sources/VRMMetalKit/Crowd/CrowdFrameStepper.swift`:

**(a)** After the `posturalLayers` property (currently line 52), add the stagger state:

```swift
    /// Stagger shove tuning (design 2026-07-07 §3). `nil` ⇒ stagger off; the
    /// solver/controller dictionaries below stay empty and Phase 0e is skipped.
    private let staggerParams: StaggerShoveParams?
    /// Per-avatar shove solvers / capture-step controllers, keyed by avatar index.
    private var staggerSolvers: [Int: StaggerShoveSolver] = [:]
    private var captureSteppers: [Int: CaptureStepController] = [:]
    /// Avatars whose stagger channel has activated (first frame with depth > 0).
    /// Dormant avatars are byte-identical to the stagger-off path, so Phase 0b's
    /// scripted approach never reads as a CoM disturbance.
    private var staggerActive: Set<Int> = []
```

**(b)** After `posturalLayer(forAvatar:)` (currently lines 61-63), add the accessors:

```swift
    /// The stagger shove solver state for `avatarIndex` (a copy), if stagger is enabled.
    public func staggerSolver(forAvatar avatarIndex: Int) -> StaggerShoveSolver? {
        staggerSolvers[avatarIndex]
    }

    /// The capture-step controller for `avatarIndex`, if stagger is enabled.
    public func captureStepController(forAvatar avatarIndex: Int) -> CaptureStepController? {
        captureSteppers[avatarIndex]
    }
```

**(c)** Extend `init` — change the signature line to:

```swift
    public init(avatars: [Avatar], driver: CrowdMotionDriver, group: SpringBoneContactGroup?, fps: Float,
                bodyContactMargin: Float? = nil, postural: PosturalContactParams? = nil,
                stagger: StaggerShoveParams? = nil) {
```

and add a `stagger` doc line to the init's parameter doc comment:

```swift
    ///   - stagger: enables the stagger shove (design 2026-07-07) with these params;
    ///     a `StaggerShoveSolver` + `CaptureStepController` (committed arrest
    ///     defaults — the configuration the ~0.2 m/s capacity was validated with)
    ///     is built per avatar, dormant until first contact. `nil` ⇒ off.
```

then, inside the init body after the postural `if/else` block, add:

```swift
        self.staggerParams = stagger
        if let stagger = stagger {
            for avatar in avatars {
                staggerSolvers[avatar.index] = StaggerShoveSolver(params: stagger)
                var stepParams = CaptureStepParams()
                stepParams.captureDistance = CaptureStepParams.committedCaptureDistanceMax
                stepParams.stepDamping = CaptureStepParams.committedStepDampingMin
                captureSteppers[avatar.index] = CaptureStepController(params: stepParams)
            }
        }
```

**(d)** In `step(frameTime:)`, change the `needsTorsos` line (currently line 109) to:

```swift
        let needsTorsos = bodyContactMargin != nil || !posturalLayers.isEmpty || staggerParams != nil
```

and inside the per-avatar loop, immediately after the Phase 0d block (after the closing brace of `if let layer = posturalLayers[avatar.index] { ... }`), add Phase 0e:

```swift
            // Phase 0e: stagger shove + capture step (design 2026-07-07 §3).
            // Dormant until this avatar's first contact so Phase 0b's scripted
            // approach never reads as a CoM disturbance; from onset, the
            // rate-limited shove displaces the scene root and the capture-step
            // controller absorbs it by holding the planted feet and stepping.
            // Runs after 0d so the penetration signal is the lean-relieved one
            // and the spring snapshot sees the stepped pose.
            if staggerParams != nil {
                var depth: Float = 0
                var pushDirXZ = SIMD2<Float>.zero
                if let partner = nearestPartnerTorso(of: avatar.index, torsos: torsos),
                   let chest = chestWorldPosition(avatar.model) {
                    let p = PosturalContactSolver.penetration(
                        point: chest, capsuleP0: partner.p0, capsuleP1: partner.p1, radius: partner.radius)
                    depth = p.depth
                    pushDirXZ = SIMD2<Float>(p.pushDir.x, p.pushDir.z)
                }
                if depth > 0 { staggerActive.insert(avatar.index) }
                if staggerActive.contains(avatar.index) {
                    let offset = staggerSolvers[avatar.index]?.update(depth: depth, pushDirXZ: pushDirXZ, dt: dt) ?? .zero
                    if offset != .zero {
                        for root in avatar.model.nodes where root.parent == nil {
                            root.translation.x += offset.x
                            root.translation.z += offset.y
                        }
                        avatar.model.updateNodeTransforms()
                    }
                    // The controller seeds itself from the current ankle worlds on
                    // its first update — the contact-onset seeding the design's
                    // activation rule requires.
                    captureSteppers[avatar.index]?.update(deltaTime: dt, model: avatar.model)
                    avatar.model.updateNodeTransforms()
                }
            }
```

and add the chest helper next to `nearestPartnerTorso` (after it):

```swift
    /// This avatar's chest world position — the penetration probe point (the chest
    /// sits forward of the torso axis, so it penetrates the partner capsule even
    /// at the torso-torso contact margin; design §5). `nil` when the rig lacks a chest.
    private func chestWorldPosition(_ model: VRMModel) -> SIMD3<Float>? {
        guard let humanoid = model.humanoid, let idx = humanoid.getBoneNode(.chest),
              idx < model.nodes.count else { return nil }
        return model.nodes[idx].worldPosition
    }
```

- [ ] **Step 4: Run the tests (green)**

Run: `swift test --filter StaggerShoveIntegrationTests --disable-sandbox`
Expected: `Executed 2 tests, with 0 failures` (skips without a Metal device).

If `testActivation_onsetAtFirstContact_offsetGrowsAwayFromPartner` fails its `offset > 0.02` assertion, the chest is not penetrating the partner torso at `halfSep: 0.06` — lower the fixture's `halfSep` (0.05, then 0.04) until depth is real. That is the fixture's single knob; do not touch the wiring.

- [ ] **Step 5: Confirm no regression in the existing crowd suite**

Run: `swift test --filter CrowdFrameStepperTests --disable-sandbox && swift test --filter CrowdContactSeamTests --disable-sandbox`
Expected: all pass (the new init parameter defaults to `nil`; existing call sites are untouched).

- [ ] **Step 6: Commit**

```bash
git add Sources/VRMMetalKit/Crowd/CrowdFrameStepper.swift Tests/VRMMetalKitTests/Crowd/StaggerShoveIntegrationTests.swift
git commit -m "feat(stagger): Phase 0e crowd wiring — contact-onset shove drives CaptureStepController (G7 + activation)"
```

---

### Task 3: `--stagger` renderer flag

**Files:**
- Modify: `Sources/VRMVideoRenderer/main.swift` (help text ~line 126, `RenderOptions` ~line 194, parser ~line 293, `buildCrowd` ~line 580)

**Interfaces:**
- Consumes: `StaggerShoveParams(shoveGain:velocityCap:)` (Task 1), `CrowdFrameStepper.init(...stagger:)` (Task 2).
- Produces: CLI flags `--stagger` (enable, default params) and `--stagger-gain G` (override `shoveGain` — the §5 calibration knob Task 4 uses). Off by default: existing renders byte-unaffected.

- [ ] **Step 1: Add the options fields**

In `RenderOptions`, after `var postural: Bool = false`:

```swift
    var stagger: Bool = false           // Increment 3: stagger shove + capture step
    var staggerGain: Float? = nil       // shoveGain override (calibration knob)
```

- [ ] **Step 2: Add the parser cases**

After the `case "--postural":` block, matching the existing style exactly:

```swift
        case "--stagger":
            options.stagger = true
        case "--stagger-gain":
            i += 1
            options.staggerGain = Float(args[i]) ?? options.staggerGain
```

- [ ] **Step 3: Add the help text**

After the `--postural` help line:

```
        --stagger               Stagger shove: contact displaces the CoM and a
                                capture step keeps the avatar upright (crowd only)
        --stagger-gain G        Override the shove gain (metres of CoM offset per
                                metre of penetration; default 6.0)
```

- [ ] **Step 4: Wire into `buildCrowd`**

Replace the current return-statement block at the end of `buildCrowd`:

```swift
    let postural: PosturalContactParams? = options.postural ? PosturalContactParams() : nil
    return (CrowdFrameStepper(avatars: avatars, driver: driver, group: group, fps: Float(options.fps),
                              bodyContactMargin: options.bodyContactMargin, postural: postural), group)
```

with:

```swift
    let postural: PosturalContactParams? = options.postural ? PosturalContactParams() : nil
    var stagger: StaggerShoveParams? = nil
    if options.stagger {
        var p = StaggerShoveParams()
        if let gain = options.staggerGain { p.shoveGain = gain }
        stagger = p
    }
    return (CrowdFrameStepper(avatars: avatars, driver: driver, group: group, fps: Float(options.fps),
                              bodyContactMargin: options.bodyContactMargin, postural: postural,
                              stagger: stagger), group)
```

- [ ] **Step 5: Build and verify the flag parses**

Run: `swift build 2>&1 | tail -3`
Expected: `Build complete!`

Run: `swift run VRMVideoRenderer --help 2>&1 | grep -A1 "stagger"`
Expected: both new flag lines print.

- [ ] **Step 6: Commit**

```bash
git add Sources/VRMVideoRenderer/main.swift
git commit -m "feat(stagger): --stagger / --stagger-gain flags on VRMVideoRenderer (opt-in)"
```

---

### Task 4: Visual spike — calibrate `shoveGain` (§5, precedes gate authoring)

The §5 open question: is the Component-A-clamped chest penetration, amplified by `shoveGain`, enough to drive a convincing stagger? This task answers it empirically and locks the default. **It must run before Task 5** so a G5 failure is unambiguous between mechanism and tuning.

**Files:**
- Possibly modify: `Sources/VRMMetalKit/Animation/StaggerShoveSolver.swift` (the `shoveGain` default only)

- [ ] **Step 1: Render baseline and stagger videos**

```bash
swift build --configuration release
SCRATCH=/private/tmp/claude-502/-Users-arkavo-Projects-VRMMetalKit/4fd90667-087c-4a80-a8f5-5fb789da2fa3/scratchpad
.build/release/VRMVideoRenderer ../Muse/Resources/VRM/AvatarSample_A.vrm.glb ../Muse/Resources/VRMA/idle_neutral4.vrma "$SCRATCH/crowd_baseline.mov" --crowd --crowd-hold-sep 0.06 --body-contact-margin 0.02 --postural
.build/release/VRMVideoRenderer ../Muse/Resources/VRM/AvatarSample_A.vrm.glb ../Muse/Resources/VRMA/idle_neutral4.vrma "$SCRATCH/crowd_stagger.mov" --crowd --crowd-hold-sep 0.06 --body-contact-margin 0.02 --postural --stagger
```

(This register — margin clamp + postural on — is the demo configuration the spec calibrates against. `--crowd-hold-sep 0.06` proposes deep overlap so the Component-A clamp genuinely floors the pair at the margin — the default 0.18 holds the torsos 0.36 m apart, which never reaches contact at all; the clamp only ever *raises* separation.)

- [ ] **Step 2: Extract and inspect frames**

```bash
ffmpeg -y -i "$SCRATCH/crowd_stagger.mov" -vf fps=4 "$SCRATCH/stagger_%03d.png"
ffmpeg -y -i "$SCRATCH/crowd_baseline.mov" -vf fps=4 "$SCRATCH/baseline_%03d.png"
```

Read (view) the frames covering the hold window (40–70% of the run) from both sets. Acceptance:
1. In the stagger render, at least one avatar visibly displaces away from its partner during hold and takes a discernible foot step (leg splits / stance widens vs the baseline frame at the same index).
2. The avatar stays upright and the pose is not oscillating frame-to-frame (compare 3 consecutive frames).
3. The baseline render shows lean only, no step (confirms the shove — not the lean — is what changed).

- [ ] **Step 3: Calibrate if needed**

- No visible step → re-render with `--stagger-gain 12`, then `24`. The first gain that steps cleanly wins.
- Violent / skating / oscillating → halve the gain.
- If even gain 24 produces no step, the clamped-depth signal is too small at margin 0.02: verify the chest probe is actually penetrating by rendering with `--body-contact-margin 0.05`, and report findings before proceeding (this is the §5 risk materializing — stop and surface it rather than tuning blindly).

- [ ] **Step 4: Lock the calibrated default**

If the winning gain differs from `6.0`, change the default in `StaggerShoveParams.init` to the calibrated value and re-run `swift test --filter StaggerShoveSolverTests --disable-sandbox` (the solver tests pass explicit gains, so they must still pass unchanged — if any test hard-codes the default, that's a test bug to fix here).

- [ ] **Step 5: Commit (only if the default changed)**

```bash
git add Sources/VRMMetalKit/Animation/StaggerShoveSolver.swift
git commit -m "feat(stagger): calibrate shoveGain default from crowd visual spike"
```

Record the chosen gain and one sentence of visual observation in the commit body.

---

### Task 5: Integration gates G5 + G6 — stagger stays upright on the real rig

**Files:**
- Modify: `Tests/VRMMetalKitTests/Crowd/StaggerShoveIntegrationTests.swift` (append two tests)

**Interfaces:**
- Consumes: everything above, plus `BalanceModel.evaluate(model:groundY:plantedFeet:)` and `SpringBoneContactColliderSet.worldTorsoCapsule(model:)`.
- Produces: the load-bearing north-star gate. Same residual metric as increment 2's `testRigTrackingCapacity_belowHolds_overCapacityGrows`: residual = `max(0, -balance.margin)`, pass = `tail ≤ peak·0.5 + ε`, escape = `tail > peak·0.5 + 0.02`.

- [ ] **Step 1: Write the failing tests**

Append inside `StaggerShoveIntegrationTests`:

```swift
    /// Shared G5/G6 runner: two avatars at deep constant overlap (hold-only driver,
    /// zero scripted motion), shove target sized to keep the ramp — a constant-rate
    /// root drive at `velocityCap` — running through the whole 180-frame window,
    /// exactly the drive shape increment 2's rig gate validated. Returns the
    /// residual peak/tail (increment 2's metric) and whether a step fired.
    @MainActor private func staggerRun(velocityCap: Float, postural: Bool) async throws
        -> (peak: Float, tail: Float, stepped: Bool, leanAngle: Float) {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let a = try await avatar(device, index: 0)
        let b = try await avatar(device, index: 1)
        // 0.05, not 0.06: the postural lean (G6) is still driven by the CHEST
        // signal, which only fires with the torso axes inside one radius — 0.05
        // is where Task 2 measured it live, so G6's lean is genuinely active.
        let driver = holdOnlyDriver(halfSep: 0.05)

        // Probe the fixture's torso-pair overlap depth (the Phase 0e signal:
        // radiusA + radiusB − segmentDistance) on throwaway avatars (scoped so
        // the ~330MB instances free before the measured run), then size the gain
        // so the shove target (gain·depth = 1.5 m) exceeds the largest
        // whole-window drive (0.4 m/s × 3 s = 1.2 m): the rate limiter then never
        // saturates inside the window and both cases see a constant-rate drive
        // throughout.
        let gain: Float = try await {
            let pa = try await avatar(device, index: 0)
            let pb = try await avatar(device, index: 1)
            let probe = CrowdFrameStepper(avatars: [pa, pb], driver: driver, group: nil, fps: 60)
            probe.step(frameTime: 0)
            let mine = try XCTUnwrap(SpringBoneContactColliderSet.worldTorsoCapsule(model: pa.model))
            let partner = try XCTUnwrap(SpringBoneContactColliderSet.worldTorsoCapsule(model: pb.model))
            let dist = CrowdContactClamp.segmentDistance(mine.p0, mine.p1, partner.p0, partner.p1)
            let depth = max(0, mine.radius + partner.radius - dist)
            XCTAssertGreaterThan(depth, 0.01,
                "fixture precondition: torso capsules overlap at halfSep 0.05 — lower halfSep if this fails")
            return 1.5 / depth
        }()

        let stepper = CrowdFrameStepper(
            avatars: [a, b], driver: driver, group: nil, fps: 60,
            postural: postural ? PosturalContactParams() : nil,
            stagger: StaggerShoveParams(shoveGain: gain, velocityCap: velocityCap))

        var residuals: [Float] = []
        var stepped = false
        var maxLean: Float = 0
        for f in 0..<180 {
            stepper.step(frameTime: Float(f) / 180.0)
            let c = try XCTUnwrap(stepper.captureStepController(forAvatar: 0))
            if c.plantedFeet.count == 1 { stepped = true }
            if let bal = BalanceModel.evaluate(model: a.model, plantedFeet: c.plantedFeet) {
                residuals.append(max(0, -bal.margin))
            }
            maxLean = max(maxLean, stepper.posturalLayer(forAvatar: 0)?.currentLeanAngle ?? 0)
        }
        return (residuals.max() ?? 0, Array(residuals.suffix(15)).max() ?? 0, stepped, maxLean)
    }

    /// G5 — the north-star gate: a shove rate-limited UNDER the rig-confirmed
    /// capacity staggers the avatar (a step fires) and it stays balanced — the
    /// residual CONTRACTS, on the same metric increment 2's rig gate uses.
    /// Counter-case (non-negotiable): the same shove with velocityCap OVER the
    /// 0.2–0.3 escape boundary grows the residual — without it, "gentle shove
    /// stays balanced" would pass vacuously.
    @MainActor func testG5_underCapacityStaggersAndStaysUpright_overCapacityEscapes() async throws {
        let epsilon: Float = 0.001

        let under = try await staggerRun(velocityCap: 0.14, postural: false)
        XCTAssertTrue(under.stepped, "the shove forced at least one capture step (plantedFeet dropped to one)")
        XCTAssertLessThanOrEqual(under.tail, under.peak * 0.5 + epsilon,
            "under capacity the residual contracts — staggered but upright (peak \(under.peak), tail \(under.tail))")

        let over = try await staggerRun(velocityCap: 0.4, postural: false)
        XCTAssertGreaterThan(over.tail, over.peak * 0.5 + 0.02,
            "over capacity the residual grows — the gate detects escape (peak \(over.peak), tail \(over.tail))")
    }

    /// G6 — self-relief independence: G5's under-capacity case with the postural
    /// lean ACTIVE. The lean partially relieves the penetration signal (Phase 0e
    /// reads the chest after 0d), yet the step still fires and balance still
    /// contracts — the shove channel triggers the stagger independently of the
    /// self-relieving yield (validates the §5 tension resolution directly).
    @MainActor func testG6_stepFiresWithPosturalLeanActive() async throws {
        let withLean = try await staggerRun(velocityCap: 0.14, postural: true)
        XCTAssertGreaterThan(withLean.leanAngle, 0.01,
            "non-vacuity: the postural lean genuinely engaged in this run")
        XCTAssertTrue(withLean.stepped, "the step fires even with the self-relieving lean active")
        XCTAssertLessThanOrEqual(withLean.tail, withLean.peak * 0.5 + 0.001,
            "and the residual still contracts (peak \(withLean.peak), tail \(withLean.tail))")
    }
```

- [ ] **Step 2: Run the new gates**

Run: `swift test --filter StaggerShoveIntegrationTests --disable-sandbox`
Expected: `Executed 4 tests, with 0 failures`.

Failure triage (in order):
1. **Probe precondition fails** (`depth > 0.01`): lower the runner's `halfSep` to 0.05/0.04 — fixture knob only.
2. **`under.stepped` false**: the CoM never lost the support margin. Check `under.peak` — if ~0, the shove isn't reaching the root (wiring bug, go back to Task 2); if small but non-zero, the support polygon is wider than 1.5 m of drift can cross, which contradicts increment 2's fixture (~0.1 m half-width) — investigate rather than tune.
3. **Under-capacity contraction fails**: this is the gate doing its job — the crowd path is feeding the controller a disturbance outside the validated band. Verify Phase 0e applies the offset additively *after* 0b (not compounding across frames), and that no other root motion exists in the fixture (`holdOnlyDriver` constant).
4. **Over-capacity counter-case fails to escape** (residual contracts at 0.4): confirm the drive really spans the window (target 1.5 m > 1.2 m) and that `velocityCap` reached the solver (params plumbed, not defaulted).

- [ ] **Step 3: Run the full stagger + capture-step + crowd suites together**

Run: `swift test --filter "StaggerShove|CaptureStep|Crowd" --disable-sandbox`
Expected: all pass. (Memory note: an arm-swing guard test has been flaky under `--parallel`; this invocation is serial, but if it flakes, re-run the single filter in isolation before treating it as a regression.)

- [ ] **Step 4: Commit**

```bash
git add Tests/VRMMetalKitTests/Crowd/StaggerShoveIntegrationTests.swift
git commit -m "test(stagger): G5/G6 rig gates — under-capacity shove staggers and contracts, over-capacity escapes"
```

---

### Task 6: Final verification + sanity render

**Files:**
- Possibly modify: `AvatarSample_A.png` (repo root — regenerated per PR by team convention)

- [ ] **Step 1: Full test suite**

Run: `swift test --parallel --num-workers 14 -j 16 --disable-sandbox 2>&1 | tail -20`
Expected: pass, modulo the two known pre-existing/flaky cases (Global Constraints; verify any failure also occurs on `main` via `git stash` or a worktree before attributing it to this branch).

- [ ] **Step 2: Regenerate the sanity render**

```bash
swift run VRMRender --output AvatarSample_A.png
git diff --stat AvatarSample_A.png
```

Read (view) the PNG and confirm the avatar renders normally (this feature is crowd-only and opt-in, so the single-avatar render must be unchanged). Commit the PNG only if it actually differs:

```bash
git add AvatarSample_A.png && git commit -m "chore: regenerate AvatarSample_A.png sanity render"
```

- [ ] **Step 3: Do not push**

Leave the branch local. Pushing (and PR creation) happens on the user's explicit signal.
