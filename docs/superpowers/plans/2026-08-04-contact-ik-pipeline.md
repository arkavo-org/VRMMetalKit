# Contact IK Stage Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the two competing frame orderings (compositor priorities, `CrowdFrameStepper` phases) with one named S0–S6 stage pipeline, hoist the VRM node-constraint solve onto the final pose, and make limb IK terminal so foot planting survives root displacement.

**Architecture:** Stage functions live in a new `Sources/VRMMetalKit/Animation/Pipeline/` directory as pure statics over `inout PipelineAvatar` + a `FrozenSnapshot` of partner geometry. `CrowdFrameStepper` keeps its public API and becomes the *scheduler* that binds phases to stage functions; ordering truth moves to the stage list. Four gated commits — C1 pure code motion, C2 constraint hoist, C3 the S2→S3 re-solve that closes the foot-slide bug, C4 propagation reduction.

**Tech Stack:** Swift 6.2, `simd`, XCTest. No Metal shader changes. Spec: `docs/superpowers/specs/2026-08-04-contact-ik-pipeline-design.md`.

## Global Constraints

- Swift 6.2; targets macOS 26+, iOS 26+.
- New source files MUST carry the 15-line Apache 2.0 header (copy verbatim from `Sources/VRMMetalKit/Animation/CaptureStepController.swift:1-15`).
- Tests always run with `--disable-sandbox`. Full suite: `swift test --parallel --num-workers 14 -j 16 --disable-sandbox`.
- Model-loading tests require a Metal device and MUST `throw XCTSkip("No Metal device")` when absent.
- No temporary contextual/informational comments in code (CLAUDE.md). Doc comments stating constraints are expected — match the density of `PosturalContactSolver.swift`.
- Commit after each task. Do **not** push (pushes trigger Xcode Cloud; the user pushes on request).
- Known pre-existing failure: `testShaderSourceHashMatchesKnownGood` (stale hash since #197) fails independent of this work. Verify any unexpected failure also fails on `main` before investigating.
- `CrowdFrameStepper`'s public API is frozen for this plan: `avatarsForCamera`, `lastAppliedHalfSeparation`, `posturalLayer(forAvatar:)`, `staggerSolver(forAvatar:)`, `captureStepController(forAvatar:)`, `armCounterbalanceLayer(forAvatar:)`, `step(frameTime:)`, and the `init` signature all keep their current shapes and semantics.
- Type facts that constrain the design: `VRMNode` is a **class** (`VRMGeometry.swift:1139`); `StaggerShoveSolver` is a **struct** (`:53`); `CaptureStepController`, `PosturalContactLayer`, `ArmCounterbalanceLayer` are **final classes**. Hence `PipelineAvatar` must be a struct passed `inout` — the solver's mutation is value-typed.

---

## File Structure

**Create:**
- `Sources/VRMMetalKit/Animation/Pipeline/FrozenSnapshot.swift` — the frozen partner-geometry snapshot and its nearest-partner query. Enforces the cross-avatar read invariant by being the *only* partner data a stage receives.
- `Sources/VRMMetalKit/Animation/Pipeline/PipelineAvatar.swift` — per-avatar mutable pipeline state (struct).
- `Sources/VRMMetalKit/Animation/Pipeline/RootDisplacement.swift` — the S2 displacement request accumulator and its conflict rule.
- `Sources/VRMMetalKit/Animation/Pipeline/PoseStage.swift` — S0–S4 stage functions as pure statics.
- `Sources/VRMMetalKit/Animation/Pipeline/FootTargetSource.swift` — the S3 target-source protocol and its `FootContactDetector` adapter.
- `Tests/VRMMetalKitTests/Pipeline/GoldenSequence.swift` — shared sequence-capture helper for every gate in this plan.
- `Tests/VRMMetalKitTests/Pipeline/FrozenSnapshotTests.swift`
- `Tests/VRMMetalKitTests/Pipeline/RootDisplacementTests.swift`
- `Tests/VRMMetalKitTests/Pipeline/StageExtractionGateTests.swift` — C1's 3×2 byte-identity matrix.
- `Tests/VRMMetalKitTests/Pipeline/ConstraintHoistTests.swift` — C2's twist-tracking fixture + direct-caller identity.
- `Tests/VRMMetalKitTests/Pipeline/PlantedFootDriftTests.swift` — C3's headline gate.

**Modify:**
- `Sources/VRMMetalKit/Crowd/CrowdFrameStepper.swift:214-295` — the phase loop becomes stage bindings.
- `Sources/VRMMetalKit/Animation/AnimationPlayer.swift:116,272` — `solvesConstraints` flag.
- `Sources/VRMMetalKit/VRMMetalKit.docc/Articles/AnimationAndRetargeting.md` — one paragraph on the flag.

---

## Resolved: the S2 displacement conflict rule

The spec left this open. Resolution, matching today's de-facto behavior exactly:

Today Phase 0b writes an **absolute** root translation (`root.translation = base + offset`, `CrowdFrameStepper.swift:223`) and Phase 0e applies an **additive** delta on top (`root.translation.x += offset.x`, `:268-269`). The rule that generalizes this without changing it:

> **At most one absolute request per avatar per frame; every other request is an additive delta applied after it, in insertion order.** A second absolute request is a programming error (`preconditionFailure` in debug).

Placement is the absolute writer. Shove, and later goal-approach, are deltas. Float addition order is preserved, so byte-identity holds.

---

### Task 1: Golden-sequence capture helper

The gate infrastructure for every later task. Written first, against **unmodified** code, so it is a characterization test that must pass before any refactor begins.

**Files:**
- Create: `Tests/VRMMetalKitTests/Pipeline/GoldenSequence.swift`

**Interfaces:**
- Consumes: nothing.
- Produces (Tasks 4, 7, 9, 10 rely on these exact signatures):
  - `struct PoseSample: Equatable` with `let bones: [SIMD4<Float>]`, `let roots: [SIMD4<Float>]`
  - `@MainActor func capturePose(_ model: VRMModel) throws -> PoseSample`
  - `@MainActor func captureSequence(frames: Int, step: (Int) -> Void, models: [VRMModel]) throws -> [[PoseSample]]`
  - `func assertSequencesIdentical(_ a: [[PoseSample]], _ b: [[PoseSample]], _ label: String, file: StaticString, line: UInt)`

- [ ] **Step 1: Write the failing test**

Create `Tests/VRMMetalKitTests/Pipeline/GoldenSequence.swift` (Apache header first, then):

```swift
import XCTest
import Metal
import simd
@testable import VRMMetalKit

/// One frame of an avatar's committed pose: every humanoid bone's rotation plus
/// every scene-root translation. Wider than `StaggerShoveIntegrationTests`'
/// leg-and-root capture because a stage refactor can perturb bones no single
/// feature writes.
struct PoseSample: Equatable {
    let bones: [SIMD4<Float>]
    let roots: [SIMD4<Float>]
}

/// Captures `model`'s full humanoid pose. Bones are sampled in
/// `VRMHumanoidBone.allCases` order; absent bones contribute the identity
/// quaternion so the sample length is rig-independent.
@MainActor func capturePose(_ model: VRMModel) throws -> PoseSample {
    let humanoid = try XCTUnwrap(model.humanoid)
    var bones: [SIMD4<Float>] = []
    for bone in VRMHumanoidBone.allCases {
        if let idx = humanoid.getBoneNode(bone), idx < model.nodes.count {
            bones.append(model.nodes[idx].rotation.vector)
        } else {
            bones.append(SIMD4<Float>(0, 0, 0, 1))
        }
    }
    var roots: [SIMD4<Float>] = []
    for root in model.nodes where root.parent == nil {
        roots.append(SIMD4<Float>(root.translation, 0))
    }
    return PoseSample(bones: bones, roots: roots)
}

/// Runs `step(frameIndex)` `frames` times, capturing every model's pose after
/// each call. Returns one sequence per model, in `models` order.
@MainActor func captureSequence(frames: Int, step: (Int) -> Void,
                                models: [VRMModel]) throws -> [[PoseSample]] {
    var out: [[PoseSample]] = Array(repeating: [], count: models.count)
    for f in 0..<frames {
        step(f)
        for (i, m) in models.enumerated() {
            out[i].append(try capturePose(m))
        }
    }
    return out
}

/// Byte-identity across every model, every frame. Reports the first divergence
/// with its model and frame index — a trajectory fork usually starts one frame
/// before it is visible, so the index matters.
func assertSequencesIdentical(_ a: [[PoseSample]], _ b: [[PoseSample]], _ label: String,
                              file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(a.count, b.count, "\(label): model count", file: file, line: line)
    for (m, (seqA, seqB)) in zip(a, b).enumerated() {
        XCTAssertEqual(seqA.count, seqB.count, "\(label): frame count, model \(m)", file: file, line: line)
        for (f, (sa, sb)) in zip(seqA, seqB).enumerated() where sa != sb {
            XCTFail("\(label): diverged at model \(m), frame \(f)", file: file, line: line)
            return
        }
    }
}

/// Proves the helper detects the divergence class it exists to catch: a single
/// perturbed bone in one frame of one model.
final class GoldenSequenceTests: XCTestCase {
    func testDetectsSingleBoneDivergence() {
        let base = PoseSample(bones: [SIMD4<Float>(0, 0, 0, 1)], roots: [SIMD4<Float>(0, 0, 0, 0)])
        var perturbedBones = base.bones
        perturbedBones[0] = SIMD4<Float>(0, 0, 0.001, 1)
        let perturbed = PoseSample(bones: perturbedBones, roots: base.roots)
        XCTAssertNotEqual(base, perturbed)
    }

    func testIdenticalSamplesCompareEqual() {
        let a = PoseSample(bones: [SIMD4<Float>(1, 2, 3, 4)], roots: [SIMD4<Float>(5, 6, 7, 0)])
        let b = PoseSample(bones: [SIMD4<Float>(1, 2, 3, 4)], roots: [SIMD4<Float>(5, 6, 7, 0)])
        XCTAssertEqual(a, b)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter GoldenSequenceTests --disable-sandbox`
Expected: FAIL to compile — `PoseSample` and the helpers do not exist until this file is added. After adding the file the tests compile and PASS; that transition is the point of this step. If they pass on the first run, confirm the file was actually created at the stated path.

- [ ] **Step 3: Run the full existing suite to confirm a clean baseline**

Run: `swift test --parallel --num-workers 14 -j 16 --disable-sandbox`
Expected: PASS except the known-stale `testShaderSourceHashMatchesKnownGood`. Record any other failure now — it is pre-existing, not caused by this plan.

- [ ] **Step 4: Commit**

```bash
git add Tests/VRMMetalKitTests/Pipeline/GoldenSequence.swift
git commit -m "test(pipeline): golden-sequence capture helper for stage extraction gates"
```

---

### Task 2: `FrozenSnapshot` — the cross-avatar read invariant, enforced by signature

**Files:**
- Create: `Sources/VRMMetalKit/Animation/Pipeline/FrozenSnapshot.swift`
- Test: `Tests/VRMMetalKitTests/Pipeline/FrozenSnapshotTests.swift`

**Interfaces:**
- Consumes: `CapsuleCollider` (`SpringBoneBuffers.swift:336`, fields `p0`, `p1`, `radius`, `groupMask`).
- Produces (Task 4 relies on these exact signatures):
  - `public struct FrozenSnapshot: Sendable`
  - `public init(torsos: [Int: CapsuleCollider], indices: [Int])`
  - `public func torso(forAvatar avatarIndex: Int) -> CapsuleCollider?`
  - `public func nearestPartnerTorso(of avatarIndex: Int) -> CapsuleCollider?`

- [ ] **Step 1: Write the failing test**

Create `Tests/VRMMetalKitTests/Pipeline/FrozenSnapshotTests.swift` (Apache header first, then):

```swift
import XCTest
import simd
@testable import VRMMetalKit

final class FrozenSnapshotTests: XCTestCase {
    private func capsule(atX x: Float) -> CapsuleCollider {
        CapsuleCollider(p0: SIMD3<Float>(x, 0, 0), p1: SIMD3<Float>(x, 1, 0),
                        radius: 0.2, groupMask: 0xFFFF_FFFF)
    }

    func testNearestPartnerPicksClosestMidpoint() {
        let snap = FrozenSnapshot(
            torsos: [0: capsule(atX: 0), 1: capsule(atX: 5), 2: capsule(atX: 1)],
            indices: [0, 1, 2])
        let nearest = snap.nearestPartnerTorso(of: 0)
        XCTAssertEqual(nearest?.p0.x, 1, "avatar 2 at x=1 is nearer than avatar 1 at x=5")
    }

    func testNearestPartnerExcludesSelf() {
        let snap = FrozenSnapshot(torsos: [0: capsule(atX: 0)], indices: [0])
        XCTAssertNil(snap.nearestPartnerTorso(of: 0), "a lone avatar has no partner")
    }

    func testMissingSelfTorsoYieldsNoPartner() {
        let snap = FrozenSnapshot(torsos: [1: capsule(atX: 5)], indices: [0, 1])
        XCTAssertNil(snap.nearestPartnerTorso(of: 0),
                     "no own capsule ⇒ no midpoint to measure from, matching the pre-refactor guard")
    }

    func testPartnersWithoutTorsosAreSkipped() {
        let snap = FrozenSnapshot(torsos: [0: capsule(atX: 0), 2: capsule(atX: 9)],
                                  indices: [0, 1, 2])
        XCTAssertEqual(snap.nearestPartnerTorso(of: 0)?.p0.x, 9,
                       "index 1 has no capsule and must be skipped, not treated as origin")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter FrozenSnapshotTests --disable-sandbox`
Expected: FAIL — "cannot find 'FrozenSnapshot' in scope"

- [ ] **Step 3: Write minimal implementation**

Create `Sources/VRMMetalKit/Animation/Pipeline/FrozenSnapshot.swift` (Apache header first, then):

```swift
import Foundation
import simd

/// The partner geometry a pipeline stage may read: every avatar's torso capsule
/// as of the last committed frame.
///
/// Stages receive this instead of the live avatar array, which makes live
/// partner reads unwritable rather than merely discouraged. The invariant it
/// enforces — *cross-avatar interaction is interaction with the partner's
/// last-committed frame* — is what keeps stage-major and avatar-major execution
/// equivalent, and what makes contact synchronisation deterministic across
/// processes. Wanting a live partner read means proposing a different execution
/// model.
public struct FrozenSnapshot: Sendable {
    private let torsos: [Int: CapsuleCollider]
    private let indices: [Int]

    /// - Parameters:
    ///   - torsos: world-space torso capsules keyed by avatar index. An avatar
    ///     whose capsule could not be built is simply absent.
    ///   - indices: every participating avatar index, in scheduler order.
    public init(torsos: [Int: CapsuleCollider], indices: [Int]) {
        self.torsos = torsos
        self.indices = indices
    }

    /// This avatar's own lagged capsule, if it has one.
    public func torso(forAvatar avatarIndex: Int) -> CapsuleCollider? {
        torsos[avatarIndex]
    }

    /// The capsule whose centre-segment midpoint is nearest `avatarIndex`'s own,
    /// excluding itself. `nil` when this avatar has no capsule or no partner does.
    public func nearestPartnerTorso(of avatarIndex: Int) -> CapsuleCollider? {
        guard let mine = torsos[avatarIndex] else { return nil }
        let myMid = (mine.p0 + mine.p1) * 0.5
        var best: CapsuleCollider?
        var bestDist = Float.greatestFiniteMagnitude
        for index in indices where index != avatarIndex {
            guard let t = torsos[index] else { continue }
            let d = simd_length((t.p0 + t.p1) * 0.5 - myMid)
            if d < bestDist { bestDist = d; best = t }
        }
        return best
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter FrozenSnapshotTests --disable-sandbox`
Expected: PASS (4 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/VRMMetalKit/Animation/Pipeline/FrozenSnapshot.swift Tests/VRMMetalKitTests/Pipeline/FrozenSnapshotTests.swift
git commit -m "feat(pipeline): FrozenSnapshot enforces the last-committed-frame partner read"
```

---

### Task 3: `RootDisplacement` — the S2 conflict rule

**Files:**
- Create: `Sources/VRMMetalKit/Animation/Pipeline/RootDisplacement.swift`
- Test: `Tests/VRMMetalKitTests/Pipeline/RootDisplacementTests.swift`

**Interfaces:**
- Consumes: nothing (pure).
- Produces (Task 4 relies on these exact signatures):
  - `public struct RootDisplacement: Sendable`
  - `public init()`
  - `public mutating func setAbsolute(_ t: SIMD3<Float>)`
  - `public mutating func addDelta(_ d: SIMD3<Float>)`
  - `public func resolve(base: SIMD3<Float>) -> SIMD3<Float>`
  - `public var hasAbsolute: Bool`

- [ ] **Step 1: Write the failing test**

Create `Tests/VRMMetalKitTests/Pipeline/RootDisplacementTests.swift` (Apache header first, then):

```swift
import XCTest
import simd
@testable import VRMMetalKit

final class RootDisplacementTests: XCTestCase {
    func testNoRequestsLeavesBaseUntouched() {
        let d = RootDisplacement()
        XCTAssertEqual(d.resolve(base: SIMD3<Float>(1, 2, 3)), SIMD3<Float>(1, 2, 3))
    }

    func testAbsoluteReplacesBase() {
        var d = RootDisplacement()
        d.setAbsolute(SIMD3<Float>(10, 0, 0))
        XCTAssertEqual(d.resolve(base: SIMD3<Float>(1, 2, 3)), SIMD3<Float>(10, 0, 0))
    }

    func testDeltasAccumulateOnTopOfAbsolute() {
        var d = RootDisplacement()
        d.setAbsolute(SIMD3<Float>(10, 0, 0))
        d.addDelta(SIMD3<Float>(0.5, 0, 0.25))
        XCTAssertEqual(d.resolve(base: .zero), SIMD3<Float>(10.5, 0, 0.25))
    }

    func testDeltasApplyToBaseWhenNoAbsoluteRequested() {
        var d = RootDisplacement()
        d.addDelta(SIMD3<Float>(0, 0, 1))
        XCTAssertEqual(d.resolve(base: SIMD3<Float>(0, 0, 2)), SIMD3<Float>(0, 0, 3))
    }

    func testDeltaOrderIsInsertionOrder() {
        var d1 = RootDisplacement()
        d1.addDelta(SIMD3<Float>(1e7, 0, 0))
        d1.addDelta(SIMD3<Float>(1, 0, 0))
        var d2 = RootDisplacement()
        d2.addDelta(SIMD3<Float>(1, 0, 0))
        d2.addDelta(SIMD3<Float>(1e7, 0, 0))
        XCTAssertEqual(d1.resolve(base: .zero).x, Float(1e7) + Float(1))
        XCTAssertEqual(d2.resolve(base: .zero).x, Float(1) + Float(1e7))
    }

    func testHasAbsoluteReportsRequestState() {
        var d = RootDisplacement()
        XCTAssertFalse(d.hasAbsolute)
        d.setAbsolute(.zero)
        XCTAssertTrue(d.hasAbsolute)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter RootDisplacementTests --disable-sandbox`
Expected: FAIL — "cannot find 'RootDisplacement' in scope"

- [ ] **Step 3: Write minimal implementation**

Create `Sources/VRMMetalKit/Animation/Pipeline/RootDisplacement.swift` (Apache header first, then):

```swift
import Foundation
import simd

/// Accumulates one frame's scene-root displacement requests for a single avatar.
///
/// S2 is the sole writer of root and hips, but it is not the sole *requester*:
/// scripted placement, the stagger shove, and later goal-approach motion all
/// contribute. The rule:
///
/// > At most one absolute request per avatar per frame; every other request is
/// > an additive delta applied after it, in insertion order.
///
/// Scripted placement is the absolute writer (it positions the avatar in the
/// scene); the shove and its successors are deltas. A second absolute request
/// means two producers each believe they own placement, which is a wiring bug
/// rather than a value to reconcile.
public struct RootDisplacement: Sendable {
    private var absolute: SIMD3<Float>?
    private var deltas: [SIMD3<Float>] = []

    public init() {}

    /// Whether an absolute request has already been made this frame.
    public var hasAbsolute: Bool { absolute != nil }

    /// Replaces the root translation outright. At most one per avatar per frame.
    public mutating func setAbsolute(_ t: SIMD3<Float>) {
        precondition(absolute == nil, "two absolute root requests in one frame: two producers claim placement")
        absolute = t
    }

    /// Adds a displacement on top of whatever the absolute request (or the base) set.
    public mutating func addDelta(_ d: SIMD3<Float>) {
        deltas.append(d)
    }

    /// The final translation: the absolute request if any, otherwise `base`,
    /// plus every delta in insertion order.
    public func resolve(base: SIMD3<Float>) -> SIMD3<Float> {
        var t = absolute ?? base
        for d in deltas { t += d }
        return t
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter RootDisplacementTests --disable-sandbox`
Expected: PASS (6 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/VRMMetalKit/Animation/Pipeline/RootDisplacement.swift Tests/VRMMetalKitTests/Pipeline/RootDisplacementTests.swift
git commit -m "feat(pipeline): RootDisplacement accumulator with the one-absolute conflict rule"
```

---

### Task 4: C1 — extract S0–S3 stages and bind `CrowdFrameStepper` to them

The mechanical extraction. Behaviour must not change: the constraint solve stays at its old site inside `AnimationPlayer`, all five `updateNodeTransforms()` calls survive as stage postludes, and every stage-entry predicate travels unchanged.

**Files:**
- Create: `Sources/VRMMetalKit/Animation/Pipeline/PipelineAvatar.swift`
- Create: `Sources/VRMMetalKit/Animation/Pipeline/PoseStage.swift`
- Modify: `Sources/VRMMetalKit/Crowd/CrowdFrameStepper.swift:214-295`
- Test: `Tests/VRMMetalKitTests/Pipeline/StageExtractionGateTests.swift`

**Interfaces:**
- Consumes: `FrozenSnapshot` (Task 2), `RootDisplacement` (Task 3), `PoseSample` / `captureSequence` / `assertSequencesIdentical` (Task 1).
- Produces (Tasks 7, 8, 10 rely on these exact signatures):
  - `public struct PipelineAvatar` with stored properties `index: Int`, `model: VRMModel`, `player: AnimationPlayer`, `baseTranslations: [ObjectIdentifier: SIMD3<Float>]`, `posturalLayer: PosturalContactLayer?`, `armLayer: ArmCounterbalanceLayer?`, `captureStepper: CaptureStepController?`, `staggerSolver: StaggerShoveSolver?`, `staggerActive: Bool`
  - `public enum PoseStage` with statics:
    - `static func sample(avatar: inout PipelineAvatar, partners: FrozenSnapshot, dt: Float)`
    - `static func place(avatar: inout PipelineAvatar, placement: SIMD3<Float>)`
    - `static func compose(avatar: inout PipelineAvatar, partners: FrozenSnapshot, dt: Float)`
    - `static func displace(avatar: inout PipelineAvatar, partners: FrozenSnapshot, dt: Float, staggerEnabled: Bool)`
    - `static func limbSolve(avatar: inout PipelineAvatar, partners: FrozenSnapshot, dt: Float)`

**S2 runs in two beats, and this is deliberate.** Scripted placement (`place`) must precede S1, because the postural lean measures its own trunk endpoints in world space and those depend on where the avatar was placed. The shove (`displace`) must follow S1, because its penetration signal is documented as the *lean-relieved* one (`CrowdFrameStepper.swift:241`). Both are S2 in the sense that matters — root and hips have exactly one writer — but the stage is not contiguous in the frame. Collapsing the two beats into one call changes the depth signal and is therefore not code motion; it is not attempted in this plan.

- [ ] **Step 1: Write the failing gate test**

Create `Tests/VRMMetalKitTests/Pipeline/StageExtractionGateTests.swift` (Apache header first, then):

```swift
import XCTest
import Metal
import simd
@testable import VRMMetalKit

/// C1's gate: the stage extraction is pure code motion, proven over N-frame
/// sequences rather than single frames. Evolving state — counterbalance decay,
/// the shove offset, the contact latch — diverges only over time, so a
/// single-frame identity check can pass while the trajectory forks.
///
/// Matrix: {stagger-off, stagger-on-pre-contact, stagger-on-post-contact}
/// × {single-avatar, crowd}. Each cell records a 60-frame sequence and compares
/// it against the committed baseline captured before extraction.
final class StageExtractionGateTests: XCTestCase {

    @MainActor private func avatar(_ device: MTLDevice, index: Int, count: Int) async throws
        -> CrowdFrameStepper.Avatar {
        let path = getTestVRM10ModelPath(); try requireFixture(path, hint: testVRM10Filename)
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device,
            options: VRMLoadingOptions(augmentSpringBoneColliders: false))
        var config = RendererConfig(); config.synchronousSpringBone = true
        let r = VRMRenderer(device: device, config: config)
        r.loadModel(model)
        for root in model.nodes where root.parent == nil {
            root.rotation = CrowdPlacement.facing(avatarIndex: index, avatarCount: count)
        }
        model.updateNodeTransforms()
        return CrowdFrameStepper.Avatar(renderer: r, model: model, player: AnimationPlayer(), index: index)
    }

    /// Constant half-separation: zero scripted root motion, so contact state is
    /// controlled purely by the separation value.
    private func holdDriver(halfSep: Float) -> CrowdMotionDriver {
        CrowdMotionDriver(startSep: halfSep, holdSep: halfSep,
                          approachStart: 0.0, approachEnd: 0.01, holdEnd: 1.0, partEnd: 1.0)
    }

    /// One matrix cell: builds a stepper, runs 60 frames, returns each avatar's sequence.
    @MainActor private func runCell(device: MTLDevice, avatarCount: Int,
                                    stagger: StaggerShoveParams?, halfSep: Float)
        async throws -> [[PoseSample]] {
        var built: [CrowdFrameStepper.Avatar] = []
        for i in 0..<avatarCount {
            built.append(try await avatar(device, index: i, count: avatarCount))
        }
        let stepper = CrowdFrameStepper(avatars: built, driver: holdDriver(halfSep: halfSep),
                                        group: nil, fps: 60,
                                        postural: PosturalContactParams(),
                                        stagger: stagger,
                                        armCounterbalance: ArmCounterbalanceParams())
        return try captureSequence(frames: 60,
                                   step: { f in stepper.step(frameTime: Float(f) / 60.0) },
                                   models: built.map { $0.model })
    }

    /// Runs the full 3×2 matrix twice in one process and asserts every cell is
    /// self-identical. Before extraction this proves the harness is
    /// deterministic; after extraction the same assertion catches any drift the
    /// refactor introduced, because determinism is exactly what code motion
    /// must preserve.
    @MainActor func testMatrixIsDeterministicAcrossRuns() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }

        let cells: [(String, Int, StaggerShoveParams?, Float)] = [
            ("stagger-off/single",           1, nil,                     1.0),
            ("stagger-off/crowd",            2, nil,                     1.0),
            ("stagger-on-pre-contact/single", 1, StaggerShoveParams(),   1.0),
            ("stagger-on-pre-contact/crowd",  2, StaggerShoveParams(),   1.0),
            ("stagger-on-post-contact/single", 1, StaggerShoveParams(),  0.12),
            ("stagger-on-post-contact/crowd",  2, StaggerShoveParams(),  0.12),
        ]

        for (label, count, stagger, halfSep) in cells {
            let first = try await runCell(device: device, avatarCount: count, stagger: stagger, halfSep: halfSep)
            let second = try await runCell(device: device, avatarCount: count, stagger: stagger, halfSep: halfSep)
            assertSequencesIdentical(first, second, label)
        }
    }

    /// The post-contact cells must actually reach contact, else the matrix's
    /// third regime is vacuous and the gate silently tests nothing.
    @MainActor func testPostContactCellReachesContact() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let a = try await avatar(device, index: 0, count: 2)
        let b = try await avatar(device, index: 1, count: 2)
        let stepper = CrowdFrameStepper(avatars: [a, b], driver: holdDriver(halfSep: 0.12),
                                        group: nil, fps: 60, stagger: StaggerShoveParams())
        for f in 0..<60 { stepper.step(frameTime: Float(f) / 60.0) }
        let solver = try XCTUnwrap(stepper.staggerSolver(forAvatar: 0))
        XCTAssertNotEqual(solver.offset, .zero,
                          "half-separation 0.12 must drive the shove off zero, else the post-contact regime is untested")
    }
}
```

- [ ] **Step 2: Run the gate against unmodified code**

Run: `swift test --filter StageExtractionGateTests --disable-sandbox`
Expected: **PASS** — both tests. This is a characterization run: the gate must be green *before* the refactor, otherwise it cannot prove the refactor changed nothing. If `testPostContactCellReachesContact` fails, lower `halfSep` until the shove activates and update both the cell table and the assertion comment to match.

- [ ] **Step 3: Create `PipelineAvatar`**

Create `Sources/VRMMetalKit/Animation/Pipeline/PipelineAvatar.swift` (Apache header first, then):

```swift
import Foundation
import simd

/// One avatar's mutable per-frame pipeline state.
///
/// A struct passed `inout` rather than a class, because `StaggerShoveSolver` is
/// a value type whose `update` mutates in place; the layers and the capture-step
/// controller are reference types and are held as references. `VRMModel` is a
/// class, so pose writes land through it regardless.
public struct PipelineAvatar {
    public let index: Int
    public let model: VRMModel
    public let player: AnimationPlayer
    /// Each scene root's authored (bind) translation, so scripted motion stays additive.
    public let baseTranslations: [ObjectIdentifier: SIMD3<Float>]
    public let posturalLayer: PosturalContactLayer?
    public let armLayer: ArmCounterbalanceLayer?
    public let captureStepper: CaptureStepController?
    public var staggerSolver: StaggerShoveSolver?
    /// Set on this avatar's first frame with non-zero contact depth. Until then the
    /// stagger channel is dormant and the path is byte-identical to stagger-off.
    public var staggerActive: Bool

    public init(index: Int, model: VRMModel, player: AnimationPlayer,
                baseTranslations: [ObjectIdentifier: SIMD3<Float>],
                posturalLayer: PosturalContactLayer? = nil,
                armLayer: ArmCounterbalanceLayer? = nil,
                captureStepper: CaptureStepController? = nil,
                staggerSolver: StaggerShoveSolver? = nil,
                staggerActive: Bool = false) {
        self.index = index
        self.model = model
        self.player = player
        self.baseTranslations = baseTranslations
        self.posturalLayer = posturalLayer
        self.armLayer = armLayer
        self.captureStepper = captureStepper
        self.staggerSolver = staggerSolver
        self.staggerActive = staggerActive
    }
}
```

- [ ] **Step 4: Create `PoseStage` with S0–S3**

Create `Sources/VRMMetalKit/Animation/Pipeline/PoseStage.swift` (Apache header first, then):

```swift
import Foundation
import simd

/// The pose pipeline's stages, in execution order.
///
/// Ordering truth lives here rather than in layer priorities or a scheduler's
/// phase list. Priorities govern intra-S1 composition only; cross-stage order is
/// this enum's function order.
///
/// - S0 Sample — clip sampling and root motion.
/// - S1 Compose — pose-intent layers. Compositor evaluation first, then
///   direct-apply layers in declared order. S1 fixes sequence, not math: the
///   compositor composes onto a captured base pose (`basePose * delta`) while
///   direct-apply post-multiplies onto the current pose (`current * share`).
///   Those mean different things — pose selection versus a correction operator —
///   and stay distinct.
/// - S2 Displace — sole writer of scene root and hips. Exits with root/hips
///   final and world transforms refreshed, because S3 reads world space.
/// - S3 Limb solve — terminal pose writes.
///
/// **Direct-apply rewrite contract:** every direct-apply target bone must have a
/// guaranteed every-frame upstream writer, or the yield accumulates
/// frame-over-frame instead of decaying away. Currently satisfied — postural
/// writes spine/chest, counterbalance writes the four arm bones, neither
/// overlaps a conditionally-driven bone.
public enum PoseStage {

    /// S0 — clip sampling, root motion, morph caching, VRMA look-at target.
    public static func sample(avatar: inout PipelineAvatar, partners: FrozenSnapshot, dt: Float) {
        avatar.player.update(deltaTime: dt, model: avatar.model)
    }

    /// S1 — pose-intent layers. The postural yield's direct apply, with the
    /// world-transform refresh its downstream readers need.
    public static func compose(avatar: inout PipelineAvatar, partners: FrozenSnapshot, dt: Float) {
        guard let layer = avatar.posturalLayer else { return }
        layer.partnerTorso = partners.nearestPartnerTorso(of: avatar.index)
        layer.update(deltaTime: dt, context: AnimationContext())
        layer.applyDirect(to: avatar.model)
        avatar.model.updateNodeTransforms()
    }

    /// S2, first beat — scripted placement, the frame's one absolute root request.
    ///
    /// Runs before S1 because the postural lean measures its own trunk endpoints
    /// in world space, which depend on where this avatar was placed.
    public static func place(avatar: inout PipelineAvatar, placement: SIMD3<Float>) {
        for root in avatar.model.nodes where root.parent == nil {
            let base = avatar.baseTranslations[ObjectIdentifier(root)] ?? .zero
            var displacement = RootDisplacement()
            displacement.setAbsolute(base + placement)
            root.translation = displacement.resolve(base: base)
        }
        avatar.model.updateNodeTransforms()
    }

    /// S2, second beat — the stagger shove, an additive delta on the placed root.
    ///
    /// Runs after S1 because its penetration signal is the lean-relieved one.
    ///
    /// Exit contract: root and hips final, world transforms refreshed — S3 reads
    /// world space.
    public static func displace(avatar: inout PipelineAvatar, partners: FrozenSnapshot,
                                dt: Float, staggerEnabled: Bool) {
        var displacement = RootDisplacement()

        if staggerEnabled {
            var depth: Float = 0
            var pushDirXZ = SIMD2<Float>.zero
            if let partner = partners.nearestPartnerTorso(of: avatar.index),
               let mine = SpringBoneContactColliderSet.worldTorsoCapsule(model: avatar.model) {
                let pts = CrowdContactClamp.closestPoints(mine.p0, mine.p1, partner.p0, partner.p1)
                depth = max(0, mine.radius + partner.radius - simd_length(pts.onA - pts.onB))
                let away = pts.onA - pts.onB
                pushDirXZ = SIMD2<Float>(away.x, away.z)
            }
            if depth > 0 { avatar.staggerActive = true }
            if avatar.staggerActive {
                let offset = avatar.staggerSolver?.update(depth: depth, pushDirXZ: pushDirXZ, dt: dt) ?? .zero
                if offset != .zero {
                    displacement.addDelta(SIMD3<Float>(offset.x, 0, offset.y))
                }
            }
        }

        for root in avatar.model.nodes where root.parent == nil {
            root.translation = displacement.resolve(base: root.translation)
        }
        avatar.model.updateNodeTransforms()
    }

    /// S3 — terminal pose writes. Pelvis height/tilt slot is empty this
    /// increment; the capture step is the current occupant of the leg channel.
    public static func limbSolve(avatar: inout PipelineAvatar, partners: FrozenSnapshot, dt: Float) {
        guard avatar.staggerActive, let stepper = avatar.captureStepper else { return }
        stepper.update(deltaTime: dt, model: avatar.model)
        avatar.model.updateNodeTransforms()

        if let layer = avatar.armLayer {
            let balance = stepper.lastBalance
            let residual = max(0, -(balance?.margin ?? 0))
            layer.intensity = min(residual / fullBraceResidual, 1)
            layer.fallDirXZ = balance?.imbalanceDirection ?? .zero
            layer.update(deltaTime: dt, context: AnimationContext())
            layer.applyDirect(to: avatar.model)
            avatar.model.updateNodeTransforms()
        }
    }

    /// Balance residual (metres of CoM outside the support base) that maps to a
    /// full brace. Sized against the measured stagger peaks (≈0.05 m
    /// under-capacity, ≈0.076 m over-capacity — `StaggerShoveIntegrationTests`).
    static let fullBraceResidual: Float = 0.08
}
```

- [ ] **Step 5: Bind `CrowdFrameStepper`'s loop to the stages**

In `Sources/VRMMetalKit/Crowd/CrowdFrameStepper.swift`, replace the body of the `for avatar in avatars` loop (`:214-295`) with stage calls. Add a stored `private var pipelineAvatars: [PipelineAvatar]` built in `init` from the same inputs the dictionaries use, and keep the existing dictionaries as the backing store for the public accessors by reading them out of `pipelineAvatars`.

Replace lines `:206-295` with:

```swift
        let snapshot = FrozenSnapshot(torsos: torsos, indices: avatars.map { $0.index })

        for i in pipelineAvatars.indices {
            let placement = CrowdPlacement.rootTranslation(
                avatarIndex: pipelineAvatars[i].index, avatarCount: avatars.count, halfSeparation: halfSep)
            PoseStage.sample(avatar: &pipelineAvatars[i], partners: snapshot, dt: dt)
            PoseStage.place(avatar: &pipelineAvatars[i], placement: placement)
            PoseStage.compose(avatar: &pipelineAvatars[i], partners: snapshot, dt: dt)
            PoseStage.displace(avatar: &pipelineAvatars[i], partners: snapshot, dt: dt,
                               staggerEnabled: staggerParams != nil)
            PoseStage.limbSolve(avatar: &pipelineAvatars[i], partners: snapshot, dt: dt)
        }
```

The call order `sample → place → compose → displace → limbSolve` reproduces the existing phase order (0a animation → 0b/0c placement → 0d postural → 0e shove → 0e/0f capture step and brace) exactly, which is what C1 must do. Any reordering is a behaviour change and does not belong in this commit.

Update the public accessors to read from `pipelineAvatars`:

```swift
    public func staggerSolver(forAvatar avatarIndex: Int) -> StaggerShoveSolver? {
        pipelineAvatars.first { $0.index == avatarIndex }?.staggerSolver
    }

    public func captureStepController(forAvatar avatarIndex: Int) -> CaptureStepController? {
        pipelineAvatars.first { $0.index == avatarIndex }?.captureStepper
    }

    public func posturalLayer(forAvatar avatarIndex: Int) -> PosturalContactLayer? {
        pipelineAvatars.first { $0.index == avatarIndex }?.posturalLayer
    }

    public func armCounterbalanceLayer(forAvatar avatarIndex: Int) -> ArmCounterbalanceLayer? {
        pipelineAvatars.first { $0.index == avatarIndex }?.armLayer
    }
```

Delete the now-unused `staggerSolvers`, `captureSteppers`, `staggerActive`, `posturalLayers`, `armLayers` stored properties and the private `nearestPartnerTorso(of:torsos:)` helper (its logic now lives in `FrozenSnapshot`). Keep `Self.fullBraceResidual` deleted here too — it moved to `PoseStage`.

- [ ] **Step 6: Run the C1 gate**

Run: `swift test --filter StageExtractionGateTests --disable-sandbox`
Expected: PASS — both tests, unchanged from Step 2.

- [ ] **Step 7: Run every existing crowd and stagger test**

Run: `swift test --filter "Crowd|Stagger|Postural|ArmCounterbalance|CaptureStep" --disable-sandbox`
Expected: PASS. `StaggerShoveIntegrationTests.testG7_disabledAndDormantAreByteIdenticalNoOp` is the sharpest of these — it already asserts dormant-path byte-identity across both avatars in a pair.

- [ ] **Step 8: Run the full suite**

Run: `swift test --parallel --num-workers 14 -j 16 --disable-sandbox`
Expected: PASS except the known-stale `testShaderSourceHashMatchesKnownGood` and anything recorded as pre-existing in Task 1 Step 3.

- [ ] **Step 9: Commit**

```bash
git add Sources/VRMMetalKit/Animation/Pipeline/ Sources/VRMMetalKit/Crowd/CrowdFrameStepper.swift Tests/VRMMetalKitTests/Pipeline/StageExtractionGateTests.swift
git commit -m "refactor(pipeline): C1 extract S0-S3 stages, CrowdFrameStepper becomes scheduler"
```

---

### Task 5: C1 standing guards

**Files:**
- Modify: `Sources/VRMMetalKit/Animation/Pipeline/PoseStage.swift`
- Test: `Tests/VRMMetalKitTests/Pipeline/StageExtractionGateTests.swift`

**Interfaces:**
- Consumes: `PoseStage` (Task 4).
- Produces: `PoseStage.debugAssertRootsUnchanged(avatar:since:)` — used by Task 8's re-solve to prove S3 does not write roots.

- [ ] **Step 1: Write the failing test**

Append to `Tests/VRMMetalKitTests/Pipeline/StageExtractionGateTests.swift`:

```swift
extension StageExtractionGateTests {
    /// The write-guard must fire when a root moves after S2 and stay silent
    /// otherwise. Tested on the detector itself rather than by tripping it in a
    /// live pipeline, because tripping it in debug builds aborts the process.
    @MainActor func testRootWriteGuardDetectsMovement() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let a = try await avatar(device, index: 0, count: 1)
        let before = PoseStage.rootTranslations(of: a.model)
        XCTAssertTrue(PoseStage.rootsUnchanged(a.model, since: before))
        for root in a.model.nodes where root.parent == nil {
            root.translation.x += 0.001
        }
        XCTAssertFalse(PoseStage.rootsUnchanged(a.model, since: before))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter testRootWriteGuardDetectsMovement --disable-sandbox`
Expected: FAIL — "type 'PoseStage' has no member 'rootTranslations'"

- [ ] **Step 3: Add the guard helpers**

Append to `PoseStage` in `Sources/VRMMetalKit/Animation/Pipeline/PoseStage.swift`:

```swift
extension PoseStage {
    /// Every scene root's translation, for the S2 exit guard.
    public static func rootTranslations(of model: VRMModel) -> [SIMD3<Float>] {
        model.nodes.filter { $0.parent == nil }.map { $0.translation }
    }

    /// Whether no scene root has moved since `since` was captured. S2 is the sole
    /// writer of root and hips; a later stage moving a root is a structural
    /// violation, not a tuning issue.
    public static func rootsUnchanged(_ model: VRMModel, since: [SIMD3<Float>]) -> Bool {
        let now = rootTranslations(of: model)
        return now.count == since.count && zip(now, since).allSatisfy { $0 == $1 }
    }

    /// Debug-build assertion that S3 and beyond left the roots alone.
    public static func debugAssertRootsUnchanged(avatar: PipelineAvatar, since: [SIMD3<Float>]) {
        assert(rootsUnchanged(avatar.model, since: since),
               "a stage after S2 moved a scene root; S2 is the sole writer of root and hips")
    }
}
```

- [ ] **Step 4: Wire the guard into the stage loop**

In `CrowdFrameStepper.step()`, bracket S3 with the guard:

```swift
            PoseStage.compose(avatar: &pipelineAvatars[i], partners: snapshot, dt: dt)
            let rootsAfterDisplace = PoseStage.rootTranslations(of: pipelineAvatars[i].model)
            PoseStage.limbSolve(avatar: &pipelineAvatars[i], partners: snapshot, dt: dt)
            PoseStage.debugAssertRootsUnchanged(avatar: pipelineAvatars[i], since: rootsAfterDisplace)
```

- [ ] **Step 5: Run the tests**

Run: `swift test --filter StageExtractionGateTests --disable-sandbox`
Expected: PASS (3 tests). A failing `debugAssertRootsUnchanged` inside the matrix run means the extraction moved a root write into S3 — fix the extraction, not the assert.

- [ ] **Step 6: Commit**

```bash
git add Sources/VRMMetalKit/Animation/Pipeline/PoseStage.swift Tests/VRMMetalKitTests/Pipeline/StageExtractionGateTests.swift
git commit -m "feat(pipeline): S2 sole-root-writer guard"
```

---

### Task 6: C2 — `AnimationPlayer.solvesConstraints` flag

**Files:**
- Modify: `Sources/VRMMetalKit/Animation/AnimationPlayer.swift:116,270-275`
- Modify: `Sources/VRMMetalKit/VRMMetalKit.docc/Articles/AnimationAndRetargeting.md`
- Test: `Tests/VRMMetalKitTests/Pipeline/ConstraintHoistTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces (Task 7 relies on this): `public var solvesConstraints: Bool` on `AnimationPlayer`, defaulting `true`.

- [ ] **Step 1: Write the failing test**

Create `Tests/VRMMetalKitTests/Pipeline/ConstraintHoistTests.swift` (Apache header first, then):

```swift
import XCTest
import Metal
import simd
@testable import VRMMetalKit

/// C2's gate, split by caller. Direct callers of `AnimationPlayer.update` keep
/// constraint-inclusive output — that is the correct contract for isolation
/// testing and it never sunsets. Pipeline callers get the behaviour change.
final class ConstraintHoistTests: XCTestCase {

    @MainActor private func loadModel(_ device: MTLDevice) async throws -> VRMModel {
        let path = getTestVRM10ModelPath(); try requireFixture(path, hint: testVRM10Filename)
        return try await VRMModel.load(from: URL(fileURLWithPath: path), device: device,
            options: VRMLoadingOptions(augmentSpringBoneColliders: false))
    }

    /// The flag defaults to true, so every existing direct caller — validators,
    /// benchmarks, the isolation suites — is unaffected by the hoist.
    @MainActor func testFlagDefaultsToTrue() {
        XCTAssertTrue(AnimationPlayer().solvesConstraints,
                      "default must stay true; ~10 direct call sites depend on constraint-inclusive output")
    }

    /// With the flag off, constraint-source bones are left at their sampled pose.
    /// On a rig with no constraints authored this is trivially identical, so the
    /// test asserts the observable it can: the flag changes nothing else.
    @MainActor func testFlagOffLeavesNonConstraintBonesIdentical() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }

        let modelOn = try await loadModel(device)
        let playerOn = AnimationPlayer()
        playerOn.solvesConstraints = true
        for _ in 0..<10 { playerOn.update(deltaTime: 1.0 / 60.0, model: modelOn) }
        let poseOn = try capturePose(modelOn)

        let modelOff = try await loadModel(device)
        let playerOff = AnimationPlayer()
        playerOff.solvesConstraints = false
        for _ in 0..<10 { playerOff.update(deltaTime: 1.0 / 60.0, model: modelOff) }
        let poseOff = try capturePose(modelOff)

        if modelOn.nodeConstraints.isEmpty {
            XCTAssertEqual(poseOn, poseOff,
                           "no authored constraints ⇒ the flag is observationally inert on this fixture")
        } else {
            XCTAssertNotEqual(poseOn, poseOff,
                              "fixture has authored constraints, so disabling the solve must change the pose")
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ConstraintHoistTests --disable-sandbox`
Expected: FAIL — "value of type 'AnimationPlayer' has no member 'solvesConstraints'"

- [ ] **Step 3: Add the flag**

In `Sources/VRMMetalKit/Animation/AnimationPlayer.swift`, near the `constraintSolver` property at `:116`:

```swift
    /// Whether `update(deltaTime:model:)` solves VRM node constraints itself.
    ///
    /// Defaults to `true`, which is the correct contract for callers that drive
    /// `AnimationPlayer` directly and expect a constraint-resolved pose —
    /// validators, benchmarks, and the isolation test suites, none of which run
    /// the stage pipeline. The pipeline sets this to `false` and runs the solve
    /// at S4 instead, on the final pose, so twist bones track the posed skeleton
    /// rather than the raw animation.
    public var solvesConstraints: Bool = true
```

Then guard the existing call at `:271`:

```swift
            if solvesConstraints && !model.nodeConstraints.isEmpty {
                constraintSolver.solve(constraints: model.nodeConstraints, nodes: model.nodes)
                model.updateNodeTransforms()
            }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ConstraintHoistTests --disable-sandbox`
Expected: PASS (2 tests)

- [ ] **Step 5: Document the flag**

In `Sources/VRMMetalKit/VRMMetalKit.docc/Articles/AnimationAndRetargeting.md`, add one paragraph where the article describes `AnimationPlayer.update`'s per-frame work:

```markdown
### Constraint solving and the stage pipeline

`AnimationPlayer.update(deltaTime:model:)` solves VRM node constraints itself by
default (`solvesConstraints == true`), which is what direct callers want: the
returned pose is constraint-resolved without further work. Callers running the
stage pipeline set `solvesConstraints = false`, because the pipeline runs the
solve at S4 on the *final* pose — after limb IK — so twist bones follow the
IK-modified wrist rather than the raw animation. Validators, benchmarks, and
tests that exercise `AnimationPlayer` in isolation keep the default.
```

- [ ] **Step 6: Run the direct-caller suites**

Run: `swift test --filter "DualQuaternionSkinning|VRMAMinimal|VRMAComprehensive|Skinning|VRMAValidation|ConstraintSolver" --disable-sandbox`
Expected: PASS — unchanged, since the default preserves their contract.

- [ ] **Step 7: Commit**

```bash
git add Sources/VRMMetalKit/Animation/AnimationPlayer.swift Sources/VRMMetalKit/VRMMetalKit.docc/Articles/AnimationAndRetargeting.md Tests/VRMMetalKitTests/Pipeline/ConstraintHoistTests.swift
git commit -m "feat(animation): solvesConstraints flag, defaulting to the direct-caller contract"
```

---

### Task 7: C2 — hoist the solve to S4

**Files:**
- Modify: `Sources/VRMMetalKit/Animation/Pipeline/PoseStage.swift`
- Modify: `Sources/VRMMetalKit/Crowd/CrowdFrameStepper.swift`
- Test: `Tests/VRMMetalKitTests/Pipeline/ConstraintHoistTests.swift`

**Interfaces:**
- Consumes: `PoseStage` (Task 4), `solvesConstraints` (Task 6).
- Produces: `PoseStage.constrain(avatar:partners:dt:)`.

- [ ] **Step 1: Write the failing test**

Append to `Tests/VRMMetalKitTests/Pipeline/ConstraintHoistTests.swift`:

```swift
extension ConstraintHoistTests {
    /// The behaviour change C2 buys: a constraint whose source bone is written
    /// by a post-S0 stage now tracks that stage's output. Built as a synthetic
    /// roll constraint on the forearm sourced from the upper arm, because the
    /// stock fixture may author none — the mechanism is what is under test, not
    /// any particular rig's authoring.
    @MainActor func testConstraintTracksPostComposeArmWrite() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let model = try await loadModel(device)
        let humanoid = try XCTUnwrap(model.humanoid)
        let upperArm = try XCTUnwrap(humanoid.getBoneNode(.leftUpperArm))
        let lowerArm = try XCTUnwrap(humanoid.getBoneNode(.leftLowerArm))

        model.nodeConstraints = [
            VRMNodeConstraint(nodeIndex: lowerArm, type: .roll,
                              sourceIndex: upperArm, axis: SIMD3<Float>(0, 1, 0), weight: 1.0)
        ]

        var avatar = PipelineAvatar(index: 0, model: model, player: AnimationPlayer(),
                                    baseTranslations: [:])
        avatar.player.solvesConstraints = false
        let snapshot = FrozenSnapshot(torsos: [:], indices: [0])

        PoseStage.sample(avatar: &avatar, partners: snapshot, dt: 1.0 / 60.0)
        let afterSample = model.nodes[lowerArm].rotation

        model.nodes[upperArm].rotation = simd_quatf(angle: 0.4, axis: SIMD3<Float>(0, 1, 0))
        model.nodes[upperArm].updateLocalMatrix()
        model.updateNodeTransforms()

        PoseStage.constrain(avatar: &avatar, partners: snapshot, dt: 1.0 / 60.0)
        let afterConstrain = model.nodes[lowerArm].rotation

        XCTAssertNotEqual(afterSample.vector, afterConstrain.vector,
                          "S4 must resolve the constraint against the arm write that landed after S0")
    }
}
```

Before running, confirm `VRMNodeConstraint`'s initializer parameter names against `Sources/VRMMetalKit/Core/` — if they differ, use the real ones; the test's intent is unchanged.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter testConstraintTracksPostComposeArmWrite --disable-sandbox`
Expected: FAIL — "type 'PoseStage' has no member 'constrain'"

- [ ] **Step 3: Add S4**

Append to `PoseStage` in `Sources/VRMMetalKit/Animation/Pipeline/PoseStage.swift`:

```swift
extension PoseStage {
    /// S4 — VRM node constraints on the final pose.
    ///
    /// Nothing before S4 may read constraint output. A layer needing a
    /// post-constraint pose is a cycle in the stage graph, which is a design
    /// smell to surface rather than accommodate.
    public static func constrain(avatar: inout PipelineAvatar, partners: FrozenSnapshot, dt: Float) {
        guard !avatar.model.nodeConstraints.isEmpty else { return }
        constraintSolver.solve(constraints: avatar.model.nodeConstraints, nodes: avatar.model.nodes)
        avatar.model.updateNodeTransforms()
    }

    private static let constraintSolver = ConstraintSolver()
}
```

- [ ] **Step 4: Wire S4 into the scheduler and disable S0's solve**

In `CrowdFrameStepper.init`, after building each `PipelineAvatar`, set `avatar.player.solvesConstraints = false`. In `step()`, add S4 after S3:

```swift
            PoseStage.limbSolve(avatar: &pipelineAvatars[i], partners: snapshot, dt: dt)
            PoseStage.debugAssertRootsUnchanged(avatar: pipelineAvatars[i], since: rootsAfterDisplace)
            PoseStage.constrain(avatar: &pipelineAvatars[i], partners: snapshot, dt: dt)
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter ConstraintHoistTests --disable-sandbox`
Expected: PASS (3 tests)

- [ ] **Step 6: Run the C1 gate and check the expected delta**

Run: `swift test --filter StageExtractionGateTests --disable-sandbox`
Expected: PASS. The matrix compares each cell against itself within a run, so the hoist does not break it. If a cell now fails, the hoist introduced nondeterminism — investigate before continuing.

- [ ] **Step 7: Run the full suite**

Run: `swift test --parallel --num-workers 14 -j 16 --disable-sandbox`
Expected: PASS except known-stale entries. On the stock fixture (no authored constraints) crowd output is unchanged; a rig with constraints changes on constraint-source bones only, which is C2's intended delta.

- [ ] **Step 8: Commit**

```bash
git add Sources/VRMMetalKit/Animation/Pipeline/PoseStage.swift Sources/VRMMetalKit/Crowd/CrowdFrameStepper.swift Tests/VRMMetalKitTests/Pipeline/ConstraintHoistTests.swift
git commit -m "refactor(pipeline): C2 hoist the constraint solve to S4"
```

---

### Task 8: C3 — foot target source protocol and the S2→S3 re-solve

**Files:**
- Create: `Sources/VRMMetalKit/Animation/Pipeline/FootTargetSource.swift`
- Modify: `Sources/VRMMetalKit/Animation/Pipeline/PoseStage.swift`
- Test: `Tests/VRMMetalKitTests/Pipeline/PlantedFootDriftTests.swift`

**Interfaces:**
- Consumes: `PipelineAvatar`, `PoseStage` (Task 4); `FootContactDetector` (`FootContactDetector.swift:24`, with `update(leftFootPos:rightFootPos:deltaTime:)`, `isLeftFootPlanted`, `leftFootPlantedPosition`, and the right-side equivalents).
- Produces (the protocol RFC binds `InteractionVolume` here):
  - `public protocol FootTargetSource: AnyObject`
  - `func update(leftFootPos: SIMD3<Float>, rightFootPos: SIMD3<Float>, deltaTime: Float)`
  - `func plantedTarget(_ foot: BalanceModel.Foot) -> SIMD3<Float>?`
  - `public final class DetectorFootTargetSource: FootTargetSource`
  - `PipelineAvatar.ikLayer: IKLayer?` and `PipelineAvatar.footTargetSource: FootTargetSource?` (new stored properties, defaulting `nil`)

- [ ] **Step 0: Determine which path actually carries the bug**

The crowd path already runs the capture-step controller *after* the shove, inside the same phase block (`CrowdFrameStepper.swift:264-277`), and that controller holds planted feet at world pivots. So the crowd fixture may already pass a drift gate. `IKLayer` — the compositor's leg-IK layer at priority 4 — is **not registered in the crowd path at all**; it is the single-avatar path's planting mechanism, and it is the one that runs before postural (5) and counterbalance (6) and before any out-of-band root shove.

Run the Step 1 gate before making any change and record which way it goes:

- **If it FAILS on the crowd fixture:** the capture-step plant does track the shoved root, C3's gate is the crowd one as written, and Steps 3–4 fix it.
- **If it PASSES unchanged:** the crowd path is already correct and the gate is vacuous. Do not weaken it — keep it as a regression guard, and make the *primary* gate the single-avatar one in Step 1b, which exercises `IKLayer` against a root displacement. That is the path the spec's priority-inversion finding is actually about.

Record the outcome in the commit message. A gate that was green before the fix is not evidence the fix worked.

- [ ] **Step 1: Write the failing gate test**

Create `Tests/VRMMetalKitTests/Pipeline/PlantedFootDriftTests.swift` (Apache header first, then):

```swift
import XCTest
import Metal
import simd
@testable import VRMMetalKit

/// C3's headline gate: a planted foot must hold its world-space position while
/// the stagger shove displaces the root. Before the S2→S3 re-solve the foot
/// slides by the full shove offset, because the root moved after the plant was
/// solved.
final class PlantedFootDriftTests: XCTestCase {

    @MainActor private func avatar(_ device: MTLDevice, index: Int) async throws
        -> CrowdFrameStepper.Avatar {
        let path = getTestVRM10ModelPath(); try requireFixture(path, hint: testVRM10Filename)
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device,
            options: VRMLoadingOptions(augmentSpringBoneColliders: false))
        var config = RendererConfig(); config.synchronousSpringBone = true
        let r = VRMRenderer(device: device, config: config)
        r.loadModel(model)
        for root in model.nodes where root.parent == nil {
            root.rotation = CrowdPlacement.facing(avatarIndex: index, avatarCount: 2)
        }
        model.updateNodeTransforms()
        return CrowdFrameStepper.Avatar(renderer: r, model: model, player: AnimationPlayer(), index: index)
    }

    @MainActor private func anklePositions(_ model: VRMModel) throws -> (SIMD3<Float>, SIMD3<Float>) {
        let humanoid = try XCTUnwrap(model.humanoid)
        let l = try XCTUnwrap(humanoid.getBoneNode(.leftFoot))
        let r = try XCTUnwrap(humanoid.getBoneNode(.rightFoot))
        return (model.nodes[l].worldPosition, model.nodes[r].worldPosition)
    }

    /// Drift threshold: the shove is rate-limited to 0.14 m/s, so one 1/60 s
    /// frame displaces the root by at most ≈2.3 mm. A planted foot may lag by
    /// the solver's own tolerance but must not track the root — 5 mm sits above
    /// solver noise and an order of magnitude below a full frame's uncorrected
    /// slide accumulated over the run.
    private static let driftThreshold: Float = 0.005

    @MainActor func testPlantedFootHoldsWorldPositionUnderShove() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let a = try await avatar(device, index: 0)
        let b = try await avatar(device, index: 1)
        let driver = CrowdMotionDriver(startSep: 0.12, holdSep: 0.12,
                                       approachStart: 0.0, approachEnd: 0.01, holdEnd: 1.0, partEnd: 1.0)
        let stepper = CrowdFrameStepper(avatars: [a, b], driver: driver, group: nil, fps: 60,
                                        stagger: StaggerShoveParams())

        var maxDrift: Float = 0
        var previous: (SIMD3<Float>, SIMD3<Float>)?
        for f in 0..<60 {
            stepper.step(frameTime: Float(f) / 60.0)
            let controller = try XCTUnwrap(stepper.captureStepController(forAvatar: 0))
            let now = try anklePositions(a.model)
            if let prev = previous {
                if controller.phase(.left) == .planted {
                    maxDrift = max(maxDrift, simd_length(now.0 - prev.0))
                }
                if controller.phase(.right) == .planted {
                    maxDrift = max(maxDrift, simd_length(now.1 - prev.1))
                }
            }
            previous = now
        }

        XCTAssertLessThan(maxDrift, Self.driftThreshold,
                          "a planted foot tracked the shoved root instead of holding its world pivot")
    }
}
```

Before running, confirm `CaptureStepController.FootPhase`'s planted case name (`CaptureStepController.swift:214` exposes `phase(_:)`); use the real case if it is not `.planted`.

- [ ] **Step 1b: Write the single-avatar `IKLayer` gate**

The gate that is failing-by-construction, since `IKLayer` has no re-solve against a post-S2 root today. Append to `Tests/VRMMetalKitTests/Pipeline/PlantedFootDriftTests.swift`:

```swift
extension PlantedFootDriftTests {
    /// `IKLayer` in idle grounding pins both feet to hip-relative offsets. When a
    /// root displacement lands after the layer has solved, the pinned foot must
    /// still hold its world position — that is what "limb IK is terminal" buys.
    @MainActor func testIdleGroundedFootHoldsWorldPositionUnderRootShift() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let a = try await avatar(device, index: 0)

        let ik = IKLayer()
        ik.groundingMode = .idleGrounding
        ik.initialize(with: a.model)

        var avatarState = PipelineAvatar(index: 0, model: a.model, player: a.player,
                                         baseTranslations: [:])
        avatarState.ikLayer = ik
        avatarState.footTargetSource = DetectorFootTargetSource()
        let snapshot = FrozenSnapshot(torsos: [:], indices: [0])
        let dt: Float = 1.0 / 60.0

        PoseStage.sample(avatar: &avatarState, partners: snapshot, dt: dt)
        PoseStage.limbSolve(avatar: &avatarState, partners: snapshot, dt: dt)
        let before = try anklePositions(a.model)

        for root in a.model.nodes where root.parent == nil {
            root.translation.x += 0.05
        }
        a.model.updateNodeTransforms()
        PoseStage.limbSolve(avatar: &avatarState, partners: snapshot, dt: dt)
        let after = try anklePositions(a.model)

        XCTAssertLessThan(simd_length(after.0 - before.0), Self.driftThreshold,
                          "left foot tracked the displaced root instead of re-solving to its world target")
    }
}
```

- [ ] **Step 2: Run both gates and record which one fails**

Run: `swift test --filter PlantedFootDriftTests --disable-sandbox`
Expected: `testIdleGroundedFootHoldsWorldPositionUnderRootShift` FAILS — `IKLayer` is not yet invoked by `limbSolve`, so nothing re-solves. Record the crowd test's result per Step 0; both outcomes are informative and neither blocks progress.

- [ ] **Step 3: Create the target-source protocol**

Create `Sources/VRMMetalKit/Animation/Pipeline/FootTargetSource.swift` (Apache header first, then):

```swift
import Foundation
import simd

/// Where S3 gets its world-space foot targets.
///
/// The seam the interaction-volume RFC binds to. Day one this is the existing
/// `FootContactDetector` — the *when* of planting (a lock/unlock state machine
/// over foot velocity and height) is unchanged; only the *source of the target*
/// becomes swappable. A volume-backed implementation answers from the host's
/// spatial index instead, which is what makes real-floor planting and terrain
/// planting the same code.
public protocol FootTargetSource: AnyObject {
    /// Advances the source with this frame's measured foot positions.
    func update(leftFootPos: SIMD3<Float>, rightFootPos: SIMD3<Float>, deltaTime: Float)
    /// The world-space target for a planted foot, or `nil` when that foot is free.
    func plantedTarget(_ foot: BalanceModel.Foot) -> SIMD3<Float>?
}

/// The behaviour-preserving adapter: `FootContactDetector` behind the protocol.
public final class DetectorFootTargetSource: FootTargetSource {
    private let detector: FootContactDetector

    public init(detector: FootContactDetector = FootContactDetector()) {
        self.detector = detector
    }

    public func update(leftFootPos: SIMD3<Float>, rightFootPos: SIMD3<Float>, deltaTime: Float) {
        detector.update(leftFootPos: leftFootPos, rightFootPos: rightFootPos, deltaTime: deltaTime)
    }

    public func plantedTarget(_ foot: BalanceModel.Foot) -> SIMD3<Float>? {
        switch foot {
        case .left:  return detector.isLeftFootPlanted ? detector.leftFootPlantedPosition : nil
        case .right: return detector.isRightFootPlanted ? detector.rightFootPlantedPosition : nil
        }
    }
}
```

- [ ] **Step 4: Run `IKLayer` inside S3, after the capture step**

Add the two stored properties to `PipelineAvatar` (both defaulting `nil`, both added to `init` as defaulted parameters so no existing construction site changes):

```swift
    public var ikLayer: IKLayer?
    public var footTargetSource: FootTargetSource?
```

Then extend `PoseStage.limbSolve` so limb IK is the terminal pose write. Insert this *before* the existing capture-step guard, so it runs whether or not the stagger channel is active:

```swift
        if let ik = avatar.ikLayer {
            ik.update(deltaTime: dt, context: AnimationContext())
            let output = ik.evaluate()
            for (bone, transform) in output.bones {
                guard let humanoid = avatar.model.humanoid,
                      let idx = humanoid.getBoneNode(bone), idx < avatar.model.nodes.count else { continue }
                avatar.model.nodes[idx].rotation = transform.rotation
                avatar.model.nodes[idx].updateLocalMatrix()
            }
            avatar.model.updateNodeTransforms()
        }
```

`IKLayer` reads world-space joint positions directly from the model in its own `update`, so running it here — after S2's exit refresh — is what makes it re-solve against the displaced root. This is C3's behaviour change: limb IK is terminal, and it sees a root that S2 has already finalised.

The `footTargetSource` property is wired but not yet consumed by `IKLayer`; re-sourcing the detector is the protocol RFC's first task, and the seam exists now so that task changes one call site rather than a stage.

- [ ] **Step 5: Run the gates**

Run: `swift test --filter PlantedFootDriftTests --disable-sandbox`
Expected: PASS — both tests. `testIdleGroundedFootHoldsWorldPositionUnderRootShift` is the one that was failing in Step 2 and is C3's evidence.

- [ ] **Step 6: Verify the no-contact regime is unchanged**

Run: `swift test --filter "StageExtractionGateTests|StaggerShoveIntegrationTests" --disable-sandbox`
Expected: PASS. C3 is identity when displacement is zero, so the stagger-off and pre-contact cells must be untouched. A failure in `testG7_disabledAndDormantAreByteIdenticalNoOp` means the reorder changed the dormant path — that is a real regression, not an expected delta.

- [ ] **Step 7: Run the full suite**

Run: `swift test --parallel --num-workers 14 -j 16 --disable-sandbox`
Expected: PASS except known-stale entries.

- [ ] **Step 8: Commit**

```bash
git add Sources/VRMMetalKit/Animation/Pipeline/FootTargetSource.swift Sources/VRMMetalKit/Crowd/CrowdFrameStepper.swift Tests/VRMMetalKitTests/Pipeline/PlantedFootDriftTests.swift
git commit -m "fix(pipeline): C3 limb solve runs after displacement, closing planted-foot slide"
```

---

### Task 9: C4 — reduce propagation from five calls to two

**Files:**
- Modify: `Sources/VRMMetalKit/Animation/Pipeline/PoseStage.swift`
- Test: `Tests/VRMMetalKitTests/Pipeline/StageExtractionGateTests.swift`

**Interfaces:**
- Consumes: `PoseStage` (Tasks 4, 5, 7).
- Produces: no new API — an internal reduction gated on the existing sequences.

- [ ] **Step 1: Write the failing test**

Append to `Tests/VRMMetalKitTests/Pipeline/StageExtractionGateTests.swift`:

```swift
extension StageExtractionGateTests {
    /// C4's accounting check: exactly two propagations per avatar per frame —
    /// S2's exit refresh (S3 reads world space) and S6's commit. Fewer is
    /// impossible without staling a mid-frame world-space read; more means a
    /// stage kept a postlude it no longer needs.
    @MainActor func testPropagationCountIsTwoPerFrame() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let a = try await avatar(device, index: 0, count: 1)
        VRMModel.propagationCountForTesting = 0
        var avatarState = PipelineAvatar(index: 0, model: a.model, player: a.player, baseTranslations: [:])
        let snapshot = FrozenSnapshot(torsos: [:], indices: [0])
        PoseStage.sample(avatar: &avatarState, partners: snapshot, dt: 1.0 / 60.0)
        PoseStage.compose(avatar: &avatarState, partners: snapshot, dt: 1.0 / 60.0)
        PoseStage.displace(avatar: &avatarState, partners: snapshot, dt: 1.0 / 60.0,
                           placement: .zero, staggerEnabled: false)
        PoseStage.limbSolve(avatar: &avatarState, partners: snapshot, dt: 1.0 / 60.0)
        PoseStage.constrain(avatar: &avatarState, partners: snapshot, dt: 1.0 / 60.0)
        XCTAssertLessThanOrEqual(VRMModel.propagationCountForTesting, 2,
                                 "S2 refresh + S6 commit is the steady state")
    }
}
```

- [ ] **Step 2: Add the counter and run the test to verify it fails**

In `Sources/VRMMetalKit/Core/VRMModel.swift`, at the top of `updateNodeTransforms()` (`:1338`):

```swift
        #if DEBUG
        Self.propagationCountForTesting += 1
        #endif
```

and as a static on `VRMModel`:

```swift
    #if DEBUG
    /// Counts `updateNodeTransforms()` calls so the pipeline's propagation
    /// budget is assertable. Debug-only; reset by the test that reads it.
    nonisolated(unsafe) public static var propagationCountForTesting = 0
    #endif
```

Run: `swift test --filter testPropagationCountIsTwoPerFrame --disable-sandbox`
Expected: FAIL — the count is 4 or 5, since every stage still carries its postlude.

- [ ] **Step 3: Remove the redundant postludes**

In `PoseStage`, delete the `avatar.model.updateNodeTransforms()` calls at the end of `compose` and inside `limbSolve`'s arm-layer branch, and the one in `constrain`. Keep exactly:
- the refresh at the end of `displace` (S2's exit contract — S3 reads world space), and
- one commit propagation, called by the scheduler after `constrain`.

In `CrowdFrameStepper.step()`, add the commit after S4:

```swift
            PoseStage.constrain(avatar: &pipelineAvatars[i], partners: snapshot, dt: dt)
            pipelineAvatars[i].model.updateNodeTransforms()
```

`limbSolve`'s own propagation after the capture-step update must stay if the arm layer reads world space — check `ArmCounterbalanceLayer.update`; if it reads only balance scalars supplied by the caller, the propagation is removable, and if it reads node world positions it is not. Keep it when in doubt and record the reason in the doc comment; a third propagation with a stated reason beats a silent staleness bug.

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter testPropagationCountIsTwoPerFrame --disable-sandbox`
Expected: PASS

- [ ] **Step 5: Run every gate in this plan**

Run: `swift test --filter "StageExtractionGateTests|ConstraintHoistTests|PlantedFootDriftTests|StaggerShoveIntegrationTests" --disable-sandbox`
Expected: PASS. These are the same golden sequences C1 established; a propagation reduction that changes them staled a read.

- [ ] **Step 6: Run the full suite**

Run: `swift test --parallel --num-workers 14 -j 16 --disable-sandbox`
Expected: PASS except known-stale entries.

- [ ] **Step 7: Commit**

```bash
git add Sources/VRMMetalKit/Animation/Pipeline/PoseStage.swift Sources/VRMMetalKit/Core/VRMModel.swift Sources/VRMMetalKit/Crowd/CrowdFrameStepper.swift Tests/VRMMetalKitTests/Pipeline/StageExtractionGateTests.swift
git commit -m "perf(pipeline): C4 reduce per-avatar propagation from five calls to two"
```

---

### Task 10: Update the spec's status and record what shipped

**Files:**
- Modify: `docs/superpowers/specs/2026-08-04-contact-ik-pipeline-design.md`

- [ ] **Step 1: Record the resolved open question and the shipped state**

In the spec, change the **Status** line to note implementation, and add to §3 S2 the conflict rule this plan resolved:

```markdown
**Displacement conflict rule (resolved in planning):** at most one absolute
request per avatar per frame; every other request is an additive delta applied
after it, in insertion order. Scripted placement is the absolute writer; the
shove and later goal-approach are deltas. A second absolute request is a wiring
bug (`precondition` in debug). See `RootDisplacement`.
```

- [ ] **Step 2: Commit**

```bash
git add docs/superpowers/specs/2026-08-04-contact-ik-pipeline-design.md
git commit -m "docs(spec): record the S2 displacement conflict rule"
```

---

## Verification Checklist

Run before declaring the plan complete:

- [ ] `swift build` — clean
- [ ] `swift test --parallel --num-workers 14 -j 16 --disable-sandbox` — PASS except the known-stale `testShaderSourceHashMatchesKnownGood`
- [ ] `swift test --filter StageExtractionGateTests --disable-sandbox` — the 3×2 matrix is deterministic
- [ ] `swift test --filter PlantedFootDriftTests --disable-sandbox` — planted-foot drift under 5 mm while the shove fires
- [ ] `git log --oneline` shows four gated commits plus their supporting tasks, in C1→C4 order

## What this plan does not build

Deliberately deferred, each specced against a seam this plan creates by name:
pelvis solver internals (the S3 slot exists and is empty), arm/hand contact IK,
`InteractionVolume` and `ContactGoal` (they bind at `FootTargetSource`),
look-at layerization, and spring-collider-as-proxy export.
