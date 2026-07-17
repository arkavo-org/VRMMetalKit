# Crowd Collision Demo Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A `--crowd` mode in `VRMVideoRenderer` that renders multiple VRM avatars approaching and touching, hair/cloth spring bones visibly yielding to each other's bodies, output as a `.mov` — the first consumer of the dormant `SpringBoneContactGroup`.

**Architecture:** Add one public seam (`VRMRenderer.joinContactGroup`) keeping `SpringBoneComputeSystem` internal; two small pure/orchestration library types (`CrowdMotionDriver`, `CrowdFrameStepper`) that hold all testable logic; and a thin `--crowd` path in the `VRMVideoRenderer` executable that wires them to the existing offline MSAA→`CVPixelBuffer`→`AVAssetWriter` pipeline and the benchmark's multi-avatar composite. Offline synchronous spring path keeps the sleep gate off (F1 sidestepped); the single-threaded loop poses all avatars before any integrate (zero-lag start-of-frame mutual resolution).

**Tech Stack:** Swift 6.2, Metal, AVFoundation (executable only), XCTest, SPM.

**Design spec:** `docs/superpowers/specs/2026-07-04-crowd-collision-demo-design.md`. Section refs (§N) point into it.

## Global Constraints

- **Platform:** macOS 26+, iOS 26+. Swift 6.2.
- **Branch:** `demo/crowd-collision` (stacked on `design/cross-avatar-collision`). Commit there; do NOT push (Xcode Cloud CI credits); do NOT create further branches.
- **License header** verbatim (Apache 2.0, as `SpringBoneColliderAugmentor.swift:1-15`) on every new `.swift` file.
- **No temporary/contextual scaffolding comments** in code (CLAUDE.md). Doc comments explaining *why* are fine.
- **No `.metal` changes.** Do not run `make shaders`.
- **`SpringBoneComputeSystem` stays `internal`.** The only new public module API is `VRMRenderer.joinContactGroup`/`leaveContactGroup` plus the `CrowdMotionDriver`/`CrowdFrameStepper` types. Do not make the compute system public (§2.2 — the seam IS the coordinator's no-sim-state enforcement).
- **Node placement uses T/R/S, never `localMatrix`.** `VRMNode.updateWorldTransform()` recomposes `localMatrix` from `translation`/`rotation`/`scale` every call (`VRMGeometry.swift:1292-1293`); a direct `node.localMatrix = …` write is transient and gets clobbered. `VRMBenchmark` sets `localMatrix` directly — that is wrong for per-frame placement; do NOT copy it. Set `node.translation` / `node.rotation`.
- **Offline determinism:** the crowd path uses `config.synchronousSpringBone = true` (sleep gate off). Behavior/non-interference tests drive the sync spring path (`system.update(model:deltaTime:commandBuffer:nil)` + `waitForPendingFrame()`), never async.
- **Build:** `swift build`. **Test (one):** `swift test --filter <Class> --disable-sandbox`. **GPU tests SKIP** (not fail) without a Metal device — guard with `guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }`.
- **Fixtures:** `getTestVRM10ModelPath()` + `try requireFixture(path, hint: testVRM10Filename)` then `VRMModel.load(from:device:options:)` (see `SpringBoneColliderAugmentorTests.swift`).

---

## File Structure

**New source files (library — testable):**
- `Sources/VRMMetalKit/Crowd/CrowdMotionDriver.swift` — pure scripted approach-and-part separation curve (Task 2).
- `Sources/VRMMetalKit/Crowd/CrowdPlacement.swift` — per-avatar root translation + inward facing (Task 2).
- `Sources/VRMMetalKit/Crowd/CrowdFrameStepper.swift` — per-frame pose-all → `exchange()` + composite draw (Task 3).

**Modified source files:**
- `Sources/VRMMetalKit/Renderer/VRMRenderer.swift` — add `joinContactGroup`/`leaveContactGroup` (Task 1).
- `Sources/VRMVideoRenderer/main.swift` — add `--crowd` mode + CLI flags (Task 4).

**New test files** under `Tests/VRMMetalKitTests/Crowd/`.

**Task DAG:** Task 1 (seam) and Task 2 (motion/placement) are independent; Task 3 (stepper) depends on 1 + 2; Task 4 (executable) depends on 3.

---

### Task 1: Public seam — `VRMRenderer.joinContactGroup`

The only new public module API bridging an app to the coordinator without exposing the internal `SpringBoneComputeSystem`.

**Files:**
- Modify: `Sources/VRMMetalKit/Renderer/VRMRenderer.swift`
- Test: `Tests/VRMMetalKitTests/Crowd/CrowdContactSeamTests.swift`

**Interfaces:**
- Consumes: `SpringBoneContactGroup.add(system:model:)` / `.remove(system:)` (internal, from the collision feature); `VRMRenderer.springBoneComputeSystem` (internal), `VRMRenderer.model` (public optional).
- Produces:
  - `public func joinContactGroup(_ group: SpringBoneContactGroup)` on `VRMRenderer`
  - `public func leaveContactGroup(_ group: SpringBoneContactGroup)` on `VRMRenderer`

- [ ] **Step 1: Write the failing test**

Create `Tests/VRMMetalKitTests/Crowd/CrowdContactSeamTests.swift` (Apache header):

```swift
import XCTest
import Metal
import simd
@testable import VRMMetalKit

final class CrowdContactSeamTests: XCTestCase {
    @MainActor private func renderer(_ device: MTLDevice, xOffset: Float) async throws -> VRMRenderer {
        let path = getTestVRM10ModelPath(); try requireFixture(path, hint: testVRM10Filename)
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device,
            options: VRMLoadingOptions(augmentSpringBoneColliders: true))
        // Offset via T/R/S (localMatrix would be clobbered by updateWorldTransform).
        for root in model.nodes where root.parent == nil {
            root.translation = root.translation + SIMD3<Float>(xOffset, 0, 0)
        }
        model.updateNodeTransforms()
        var config = RendererConfig()
        config.synchronousSpringBone = true
        let r = VRMRenderer(device: device, config: config)
        r.loadModel(model)
        r.enableSpringBone = true
        return r
    }

    /// Joining two overlapping avatars to a group and exchanging must inject each
    /// one's contact colliders into the other's spring system (seam wires through).
    @MainActor func testJoinContactGroupInjectsPartnerColliders() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let a = try await renderer(device, xOffset: -0.1)
        let b = try await renderer(device, xOffset: 0.1)   // overlapping (~0.2m apart)

        let group = SpringBoneContactGroup()
        a.joinContactGroup(group)
        b.joinContactGroup(group)
        group.exchange()

        // Drive each system's sync update so the sink writes the injected tail.
        for r in [a, b] {
            r.springBoneComputeSystem?.update(model: r.model!, deltaTime: 1.0/60.0, commandBuffer: nil)
            r.springBoneComputeSystem?.waitForPendingFrame()
        }
        let aForeign = a.springBoneComputeSystem?.activeForeignCapsules ?? 0
        let bForeign = b.springBoneComputeSystem?.activeForeignCapsules ?? 0
        XCTAssertGreaterThan(aForeign, 0, "A must receive B's contact capsules")
        XCTAssertGreaterThan(bForeign, 0, "B must receive A's contact capsules")

        // Leaving clears membership: a subsequent exchange injects nothing new.
        a.leaveContactGroup(group)
        b.leaveContactGroup(group)
        group.exchange()
        for r in [a, b] {
            r.springBoneComputeSystem?.update(model: r.model!, deltaTime: 1.0/60.0, commandBuffer: nil)
            r.springBoneComputeSystem?.waitForPendingFrame()
        }
        XCTAssertEqual(a.springBoneComputeSystem?.activeForeignCapsules, 0, "left group => no foreign")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter CrowdContactSeamTests --disable-sandbox`
Expected: FAIL — `value of type 'VRMRenderer' has no member 'joinContactGroup'`.

- [ ] **Step 3: Add the seam methods**

In `Sources/VRMMetalKit/Renderer/VRMRenderer.swift`, add (near the other public model methods; `springBoneComputeSystem` and `model` are accessible from within the class):

```swift
    /// Joins this renderer's spring-bone system to a cross-avatar contact group
    /// so its hair/cloth yields to other members' bodies (and vice versa). Call
    /// after `loadModel`. No-op if this renderer has no spring-bone system yet.
    ///
    /// The internal `SpringBoneComputeSystem` (per-model simulation state) is
    /// never exposed; this seam hands the coordinator only the membership handle.
    /// Validated against offline-synchronous single-caller usage
    /// (`VRMVideoRenderer --crowd`); real-time / async multi-caller ordering is
    /// unproven — see the crowd-collision design §2.2.
    public func joinContactGroup(_ group: SpringBoneContactGroup) {
        guard let system = springBoneComputeSystem, let model = model else { return }
        group.add(system: system, model: model)
    }

    /// Removes this renderer's spring-bone system from a contact group.
    public func leaveContactGroup(_ group: SpringBoneContactGroup) {
        guard let system = springBoneComputeSystem else { return }
        group.remove(system: system)
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter CrowdContactSeamTests --disable-sandbox`
Expected: PASS (or SKIP without a Metal device).

- [ ] **Step 5: Commit**

```bash
git add Sources/VRMMetalKit/Renderer/VRMRenderer.swift \
        Tests/VRMMetalKitTests/Crowd/CrowdContactSeamTests.swift
git commit -m "feat(crowd): public VRMRenderer.joinContactGroup seam (system stays internal)"
```

---

### Task 2: Motion driver + placement

Pure, position-only scripted approach-and-part, plus per-avatar placement with inward facing baked in.

**Files:**
- Create: `Sources/VRMMetalKit/Crowd/CrowdMotionDriver.swift`
- Create: `Sources/VRMMetalKit/Crowd/CrowdPlacement.swift`
- Test: `Tests/VRMMetalKitTests/Crowd/CrowdMotionDriverTests.swift`
- Test: `Tests/VRMMetalKitTests/Crowd/CrowdPlacementTests.swift`

**Interfaces:**
- Produces:
  - `public struct CrowdMotionDriver { init(startSep:holdSep:approachStart:approachEnd:holdEnd:partEnd:); func halfSeparation(at t: Float) -> Float }` — `t` in `[0,1]` over the clip; returns the current half-distance from center along the approach axis.
  - `public enum CrowdPlacement { static func rootTranslation(avatarIndex:avatarCount:halfSeparation:) -> SIMD3<Float>; static func facing(avatarIndex:avatarCount:) -> simd_quatf }`

- [ ] **Step 1: Write the failing motion-driver test**

Create `Tests/VRMMetalKitTests/Crowd/CrowdMotionDriverTests.swift` (Apache header):

```swift
import XCTest
import simd
@testable import VRMMetalKit

final class CrowdMotionDriverTests: XCTestCase {
    private func driver() -> CrowdMotionDriver {
        // start 1.0m half-sep (2m apart), hold 0.15m half-sep (0.3m apart).
        CrowdMotionDriver(startSep: 1.0, holdSep: 0.15,
                          approachStart: 0.1, approachEnd: 0.4, holdEnd: 0.7, partEnd: 0.95)
    }

    func testHoldsAtStartBeforeApproach() {
        XCTAssertEqual(driver().halfSeparation(at: 0.0), 1.0, accuracy: 1e-5)
        XCTAssertEqual(driver().halfSeparation(at: 0.1), 1.0, accuracy: 1e-5)
    }

    func testReachesHoldSeparationDuringHold() {
        XCTAssertEqual(driver().halfSeparation(at: 0.4), 0.15, accuracy: 1e-5)
        XCTAssertEqual(driver().halfSeparation(at: 0.55), 0.15, accuracy: 1e-5)
        XCTAssertEqual(driver().halfSeparation(at: 0.7), 0.15, accuracy: 1e-5)
    }

    func testApproachIsMonotonicInward() {
        let d = driver()
        var prev = d.halfSeparation(at: 0.1)
        for step in stride(from: Float(0.1), through: 0.4, by: 0.02) {
            let cur = d.halfSeparation(at: step)
            XCTAssertLessThanOrEqual(cur, prev + 1e-5, "approach must not move outward")
            prev = cur
        }
    }

    func testPartsBackOutward() {
        let d = driver()
        XCTAssertGreaterThan(d.halfSeparation(at: 0.9), d.halfSeparation(at: 0.7),
                             "part window moves back outward")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter CrowdMotionDriverTests --disable-sandbox`
Expected: FAIL — `cannot find 'CrowdMotionDriver' in scope`.

- [ ] **Step 3: Implement `CrowdMotionDriver`**

Create `Sources/VRMMetalKit/Crowd/CrowdMotionDriver.swift` (Apache header):

```swift
import Foundation

/// Pure scripted approach-and-part separation curve for the crowd collision
/// demo (design §4.2). Position-only: returns the current half-distance from
/// the scene center along the approach axis; `CrowdPlacement` maps it to each
/// avatar's world translation. All windows are normalized clip time in [0,1].
///
/// The `holdSeparation` half-distance is coupled to the torso capsule radius
/// (`SpringBoneContactColliderSet.torsoRadiusFractionOfLength`, design §4.3) —
/// together they decide whether torso capsules just touch (yield) or
/// interpenetrate (clip). Calibrate the pair, not either alone.
public struct CrowdMotionDriver {
    public let startSep: Float
    public let holdSep: Float
    public let approachStart: Float
    public let approachEnd: Float
    public let holdEnd: Float
    public let partEnd: Float

    public init(startSep: Float, holdSep: Float,
                approachStart: Float, approachEnd: Float, holdEnd: Float, partEnd: Float) {
        self.startSep = startSep
        self.holdSep = holdSep
        self.approachStart = approachStart
        self.approachEnd = approachEnd
        self.holdEnd = holdEnd
        self.partEnd = partEnd
    }

    /// Current half-separation at normalized clip time `t` (clamped to [0,1]).
    public func halfSeparation(at t: Float) -> Float {
        let tt = min(max(t, 0), 1)
        if tt <= approachStart { return startSep }
        if tt < approachEnd {
            let u = smoothstep((tt - approachStart) / (approachEnd - approachStart))
            return mix(startSep, holdSep, u)
        }
        if tt <= holdEnd { return holdSep }
        if tt < partEnd {
            let u = smoothstep((tt - holdEnd) / (partEnd - holdEnd))
            return mix(holdSep, startSep, u)
        }
        return startSep
    }

    private func smoothstep(_ x: Float) -> Float {
        let c = min(max(x, 0), 1)
        return c * c * (3 - 2 * c)
    }
    private func mix(_ a: Float, _ b: Float, _ u: Float) -> Float { a + (b - a) * u }
}
```

- [ ] **Step 4: Run the motion-driver test**

Run: `swift test --filter CrowdMotionDriverTests --disable-sandbox`
Expected: PASS.

- [ ] **Step 5: Write the failing placement test**

Create `Tests/VRMMetalKitTests/Crowd/CrowdPlacementTests.swift` (Apache header):

```swift
import XCTest
import simd
@testable import VRMMetalKit

final class CrowdPlacementTests: XCTestCase {
    func testTwoAvatarsPlacedOppositeAlongX() {
        let left = CrowdPlacement.rootTranslation(avatarIndex: 0, avatarCount: 2, halfSeparation: 0.9)
        let right = CrowdPlacement.rootTranslation(avatarIndex: 1, avatarCount: 2, halfSeparation: 0.9)
        XCTAssertEqual(left.x, -0.9, accuracy: 1e-5)
        XCTAssertEqual(right.x, 0.9, accuracy: 1e-5)
        XCTAssertEqual(left.y, 0, accuracy: 1e-5)
        XCTAssertEqual(left.z, 0, accuracy: 1e-5)
    }

    func testFacingPointsInwardTowardCenter() {
        // Avatar 0 at -X should face +X (its +Z forward rotated to +X); avatar 1 the reverse.
        let f0 = CrowdPlacement.facing(avatarIndex: 0, avatarCount: 2)
        let f1 = CrowdPlacement.facing(avatarIndex: 1, avatarCount: 2)
        let forward = SIMD3<Float>(0, 0, 1)  // VRM 1.0 faces +Z natively
        let d0 = f0.act(forward)
        let d1 = f1.act(forward)
        XCTAssertGreaterThan(d0.x, 0.9, "avatar 0 faces +X (toward center/partner)")
        XCTAssertLessThan(d1.x, -0.9, "avatar 1 faces -X")
    }
}
```

- [ ] **Step 6: Run the placement test to verify it fails**

Run: `swift test --filter CrowdPlacementTests --disable-sandbox`
Expected: FAIL — `cannot find 'CrowdPlacement' in scope`.

- [ ] **Step 7: Implement `CrowdPlacement`**

Create `Sources/VRMMetalKit/Crowd/CrowdPlacement.swift` (Apache header):

```swift
import Foundation
import simd

/// Per-avatar placement for the crowd collision demo (design §4.1). For two
/// avatars: opposite ends of the X axis, each facing inward toward the center
/// so they meet chest-to-chest. Facing is baked here (set once at setup); the
/// motion driver contributes only translation along the approach axis.
///
/// For `avatarCount > 2` the avatars ring around the center facing inward — a
/// documented stretch; v1 targets and tests `avatarCount == 2`.
public enum CrowdPlacement {

    /// World-space root translation for `avatarIndex` given the current
    /// `halfSeparation` (distance from center). Two avatars sit at ∓halfSep on X;
    /// N>2 ring on a circle of that radius.
    public static func rootTranslation(avatarIndex: Int, avatarCount: Int, halfSeparation: Float) -> SIMD3<Float> {
        let pos = circlePosition(avatarIndex: avatarIndex, avatarCount: avatarCount, radius: halfSeparation)
        return pos
    }

    /// Inward-facing yaw for `avatarIndex`: +Z forward rotated to point from the
    /// avatar's position toward the center.
    public static func facing(avatarIndex: Int, avatarCount: Int) -> simd_quatf {
        // Facing uses a unit radius; direction is scale-invariant.
        let pos = circlePosition(avatarIndex: avatarIndex, avatarCount: avatarCount, radius: 1)
        let toCenter = -pos
        let len = simd_length(SIMD3<Float>(toCenter.x, 0, toCenter.z))
        guard len > 1e-5 else { return simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0)) }
        let dir = SIMD3<Float>(toCenter.x, 0, toCenter.z) / len
        // Yaw so +Z maps onto `dir`: rotation about +Y by atan2(dir.x, dir.z).
        let yaw = atan2(dir.x, dir.z)
        return simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0))
    }

    private static func circlePosition(avatarIndex: Int, avatarCount: Int, radius: Float) -> SIMD3<Float> {
        if avatarCount <= 2 {
            // Two avatars on the X axis: index 0 at -radius, index 1 at +radius.
            let x = avatarIndex == 0 ? -radius : radius
            return SIMD3<Float>(x, 0, 0)
        }
        let angle = 2 * Float.pi * Float(avatarIndex) / Float(avatarCount)
        return SIMD3<Float>(sin(angle) * radius, 0, cos(angle) * radius)
    }
}
```

- [ ] **Step 8: Run both Task-2 tests**

Run: `swift test --filter CrowdMotionDriverTests --disable-sandbox && swift test --filter CrowdPlacementTests --disable-sandbox`
Expected: PASS (both).

- [ ] **Step 9: Commit**

```bash
git add Sources/VRMMetalKit/Crowd/CrowdMotionDriver.swift \
        Sources/VRMMetalKit/Crowd/CrowdPlacement.swift \
        Tests/VRMMetalKitTests/Crowd/CrowdMotionDriverTests.swift \
        Tests/VRMMetalKitTests/Crowd/CrowdPlacementTests.swift
git commit -m "feat(crowd): pure motion driver + inward-facing placement"
```

---

### Task 3: `CrowdFrameStepper` — pose-all → exchange → composite

The orchestration unit owning the §3 per-frame ordering and the multi-avatar composite draw, so the executable stays thin. Holds the avatars, drives Phase 0 (pose all, T/R/S only) → Phase 1+2 (`exchange`), and provides Phase 3 (composite draw).

**Files:**
- Create: `Sources/VRMMetalKit/Crowd/CrowdFrameStepper.swift`
- Test: `Tests/VRMMetalKitTests/Crowd/CrowdFrameStepperTests.swift`

**Interfaces:**
- Consumes: `VRMRenderer` (+ `joinContactGroup` from Task 1), `AnimationPlayer`, `VRMModel`, `SpringBoneContactGroup`, `CrowdMotionDriver`, `CrowdPlacement` (Task 2), `VRMRenderer.drawOffscreenHeadless`.
- Produces:
  - `public final class CrowdFrameStepper` with:
    - `public struct Avatar { let renderer: VRMRenderer; let model: VRMModel; let player: AnimationPlayer; let index: Int }`
    - `public init(avatars: [Avatar], driver: CrowdMotionDriver, group: SpringBoneContactGroup?, fps: Float)`
    - `public func step(frameTime: Float)` — Phase 0 pose all + Phase 1+2 exchange (skipped if `group == nil`).
    - `public func drawComposite(color: MTLTexture, depth: MTLTexture, commandBuffer: MTLCommandBuffer, renderPassDescriptor: MTLRenderPassDescriptor)` — Phase 3 (first clears, rest `.load`).

- [ ] **Step 1: Write the failing test**

Create `Tests/VRMMetalKitTests/Crowd/CrowdFrameStepperTests.swift` (Apache header):

```swift
import XCTest
import Metal
import simd
@testable import VRMMetalKit

final class CrowdFrameStepperTests: XCTestCase {
    @MainActor private func avatar(_ device: MTLDevice, index: Int) async throws -> CrowdFrameStepper.Avatar {
        let path = getTestVRM10ModelPath(); try requireFixture(path, hint: testVRM10Filename)
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device,
            options: VRMLoadingOptions(augmentSpringBoneColliders: true))
        var config = RendererConfig(); config.synchronousSpringBone = true
        let r = VRMRenderer(device: device, config: config)
        r.loadModel(model); r.enableSpringBone = true
        // Minimal no-op player (no VRMA needed for headless pose/exchange checks).
        let player = AnimationPlayer()
        // Bake inward facing once (as the executable does at setup).
        for root in model.nodes where root.parent == nil {
            root.rotation = CrowdPlacement.facing(avatarIndex: index, avatarCount: 2)
        }
        return CrowdFrameStepper.Avatar(renderer: r, model: model, player: player, index: index)
    }

    /// After step() at the hold window, each avatar's spring system has the
    /// partner's contact colliders injected (union-minus-self through the group).
    @MainActor func testStepPosesAndExchangesInjectingPartner() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let a = try await avatar(device, index: 0)
        let b = try await avatar(device, index: 1)
        let group = SpringBoneContactGroup()
        a.renderer.joinContactGroup(group)
        b.renderer.joinContactGroup(group)
        // Hold half-sep 0.12m => 0.24m apart => bodies overlap.
        let driver = CrowdMotionDriver(startSep: 1.0, holdSep: 0.12,
            approachStart: 0.0, approachEnd: 0.1, holdEnd: 0.9, partEnd: 1.0)
        let stepper = CrowdFrameStepper(avatars: [a, b], driver: driver, group: group, fps: 60)

        stepper.step(frameTime: 0.5)  // hold window
        for av in [a, b] {
            av.renderer.springBoneComputeSystem?.update(model: av.model, deltaTime: 1.0/60.0, commandBuffer: nil)
            av.renderer.springBoneComputeSystem?.waitForPendingFrame()
        }
        XCTAssertGreaterThan(a.renderer.springBoneComputeSystem?.activeForeignCapsules ?? 0, 0)
        XCTAssertGreaterThan(b.renderer.springBoneComputeSystem?.activeForeignCapsules ?? 0, 0)
    }

    /// Crowd-level non-interference: an avatar stepped with NO group (contact off)
    /// produces bit-identical bone positions to the same avatar stepped solo.
    @MainActor func testNoGroupIsBitIdenticalToSolo() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }

        func run(withPartner: Bool) async throws -> [SIMD3<Float>] {
            let a = try await avatar(device, index: 0)
            var avatars = [a]
            if withPartner { avatars.append(try await avatar(device, index: 1)) }
            // group: nil => contact off (the --crowd-no-contact path).
            let driver = CrowdMotionDriver(startSep: 1.0, holdSep: 0.12,
                approachStart: 0.0, approachEnd: 0.1, holdEnd: 0.9, partEnd: 1.0)
            let stepper = CrowdFrameStepper(avatars: avatars, driver: driver, group: nil, fps: 60)
            for f in 0..<30 {
                stepper.step(frameTime: Float(f) / 30.0)
                a.renderer.springBoneComputeSystem?.update(model: a.model, deltaTime: 1.0/60.0, commandBuffer: nil)
                a.renderer.springBoneComputeSystem?.waitForPendingFrame()
            }
            return a.model.springBoneBuffers?.getCurrentPositions() ?? []
        }

        let solo = try await run(withPartner: false)
        let crowd = try await run(withPartner: true)
        XCTAssertEqual(solo.count, crowd.count)
        XCTAssertFalse(solo.isEmpty)
        for i in solo.indices { XCTAssertEqual(solo[i], crowd[i], "no-contact crowd must not perturb bone \(i)") }
    }

    /// Smoke: composite two avatars into an offscreen texture for a few frames and
    /// confirm something was drawn (not the clear color everywhere).
    @MainActor func testCompositeRendersNonEmptyFrame() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let a = try await avatar(device, index: 0)
        let b = try await avatar(device, index: 1)
        for av in [a, b] {
            av.renderer.projectionMatrix = perspectiveTest(aspect: 1)
            av.renderer.viewMatrix = lookAtTest(eye: SIMD3<Float>(0, 1.3, 2.5),
                                                center: SIMD3<Float>(0, 1.3, 0), up: SIMD3<Float>(0, 1, 0))
        }
        let driver = CrowdMotionDriver(startSep: 0.6, holdSep: 0.2,
            approachStart: 0.0, approachEnd: 0.1, holdEnd: 0.9, partEnd: 1.0)
        let stepper = CrowdFrameStepper(avatars: [a, b], driver: driver, group: nil, fps: 60)

        let w = 128, h = 128
        let cd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        cd.usage = [.renderTarget, .shaderRead]; cd.storageMode = .shared
        let color = device.makeTexture(descriptor: cd)!
        let dd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: w, height: h, mipmapped: false)
        dd.usage = [.renderTarget]; dd.storageMode = .private
        let depth = device.makeTexture(descriptor: dd)!
        let queue = device.makeCommandQueue()!

        stepper.step(frameTime: 0.5)
        let cb = queue.makeCommandBuffer()!
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = color
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        rpd.depthAttachment.texture = depth
        rpd.depthAttachment.clearDepth = 1.0
        stepper.drawComposite(color: color, depth: depth, commandBuffer: cb, renderPassDescriptor: rpd)
        cb.commit(); cb.waitUntilCompleted()

        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        color.getBytes(&pixels, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        // Some pixel must differ from the 0.5 gray clear (an avatar drew).
        let gray = UInt8(0.5 * 255)
        let drew = stride(from: 0, to: pixels.count, by: 4).contains { i in
            abs(Int(pixels[i]) - Int(gray)) > 8 || abs(Int(pixels[i+1]) - Int(gray)) > 8 || abs(Int(pixels[i+2]) - Int(gray)) > 8
        }
        XCTAssertTrue(drew, "composite must render at least one avatar (non-clear pixels)")
    }

    // Local camera helpers (avoid depending on the executable's private helpers).
    private func perspectiveTest(aspect: Float) -> float4x4 {
        let fov: Float = .pi / 4, near: Float = 0.1, far: Float = 100
        let y = 1 / tan(fov * 0.5), x = y / aspect, z = far / (near - far)
        return float4x4(SIMD4<Float>(x,0,0,0), SIMD4<Float>(0,y,0,0),
                        SIMD4<Float>(0,0,z,-1), SIMD4<Float>(0,0,z*near,0))
    }
    private func lookAtTest(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> float4x4 {
        let f = simd_normalize(center - eye), s = simd_normalize(simd_cross(f, up)), u = simd_cross(s, f)
        return float4x4(SIMD4<Float>(s.x,u.x,-f.x,0), SIMD4<Float>(s.y,u.y,-f.y,0),
                        SIMD4<Float>(s.z,u.z,-f.z,0),
                        SIMD4<Float>(-simd_dot(s,eye), -simd_dot(u,eye), simd_dot(f,eye), 1))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter CrowdFrameStepperTests --disable-sandbox`
Expected: FAIL — `cannot find 'CrowdFrameStepper' in scope`.

- [ ] **Step 3: Implement `CrowdFrameStepper`**

Create `Sources/VRMMetalKit/Crowd/CrowdFrameStepper.swift` (Apache header):

```swift
import Foundation
import Metal
import simd

/// Per-frame orchestration for the crowd collision demo (design §3). Owns the
/// load-bearing ordering: Phase 0 poses EVERY avatar for this frame (animation +
/// scripted motion, via T/R/S so `updateWorldTransform` picks it up), then
/// Phase 1+2 runs the coordinator's `exchange()` (snapshot all → inject
/// union-minus-self) — so every snapshot reads a fresh, fully-committed pose and
/// all snapshots precede any spring integrate. Phase 3 (`drawComposite`) renders
/// the avatars into one shared frame. Keeps the video executable a thin shell.
///
/// Validated for offline-synchronous single-caller use; see design §2.2.
public final class CrowdFrameStepper {
    public struct Avatar {
        public let renderer: VRMRenderer
        public let model: VRMModel
        public let player: AnimationPlayer
        public let index: Int
        public init(renderer: VRMRenderer, model: VRMModel, player: AnimationPlayer, index: Int) {
            self.renderer = renderer; self.model = model; self.player = player; self.index = index
        }
    }

    private let avatars: [Avatar]
    private let driver: CrowdMotionDriver
    private let group: SpringBoneContactGroup?
    private let dt: Float
    private let baseTranslations: [Int: [ObjectIdentifier: SIMD3<Float>]]

    public init(avatars: [Avatar], driver: CrowdMotionDriver, group: SpringBoneContactGroup?, fps: Float) {
        self.avatars = avatars
        self.driver = driver
        self.group = group
        self.dt = fps > 0 ? 1.0 / fps : 1.0 / 60.0
        // Snapshot each root's authored (bind) translation so scripted motion is
        // applied additively and never loses the model's base pose.
        var bases: [Int: [ObjectIdentifier: SIMD3<Float>]] = [:]
        for avatar in avatars {
            var perRoot: [ObjectIdentifier: SIMD3<Float>] = [:]
            for root in avatar.model.nodes where root.parent == nil {
                perRoot[ObjectIdentifier(root)] = root.translation
            }
            bases[avatar.index] = perRoot
        }
        self.baseTranslations = bases
    }

    /// Phase 0 (pose all) + Phase 1+2 (exchange). `frameTime` is normalized [0,1].
    public func step(frameTime: Float) {
        let halfSep = driver.halfSeparation(at: frameTime)
        for avatar in avatars {
            // Phase 0a: animation (applies to bones + internal updateNodeTransforms).
            avatar.player.update(deltaTime: dt, model: avatar.model)
            // Phase 0b: scripted placement/motion on the scene root(s), via T/R/S.
            let offset = CrowdPlacement.rootTranslation(
                avatarIndex: avatar.index, avatarCount: avatars.count, halfSeparation: halfSep)
            let bases = baseTranslations[avatar.index] ?? [:]
            for root in avatar.model.nodes where root.parent == nil {
                let base = bases[ObjectIdentifier(root)] ?? .zero
                root.translation = base + offset
            }
            // Phase 0c: propagate root motion into world matrices for the snapshot.
            avatar.model.updateNodeTransforms()
        }
        // Phase 1+2: snapshot all (post-motion poses), inject union-minus-self.
        group?.exchange()
    }

    /// Phase 3: composite every avatar into `color`/`depth`. First avatar clears,
    /// the rest load, so all N accumulate in one frame (design §3).
    public func drawComposite(color: MTLTexture, depth: MTLTexture,
                              commandBuffer: MTLCommandBuffer, renderPassDescriptor: MTLRenderPassDescriptor) {
        for (i, avatar) in avatars.enumerated() {
            if i == 0 {
                renderPassDescriptor.colorAttachments[0].loadAction = .clear
                renderPassDescriptor.depthAttachment.loadAction = .clear
            } else {
                renderPassDescriptor.colorAttachments[0].loadAction = .load
                renderPassDescriptor.depthAttachment.loadAction = .load
            }
            avatar.renderer.drawOffscreenHeadless(
                to: color, depth: depth, commandBuffer: commandBuffer, renderPassDescriptor: renderPassDescriptor)
        }
    }
}
```

Note: `step()` applies scripted motion additively on top of each root's captured base translation, so the model's authored pose is preserved; facing is baked once at setup by the caller (the executable / the test), not per-frame.

- [ ] **Step 4: Run the stepper tests**

Run: `swift test --filter CrowdFrameStepperTests --disable-sandbox`
Expected: PASS (4 tests; or SKIP without a Metal device).

- [ ] **Step 5: Run the full crowd + spring-bone suites for regressions**

Run: `swift test --filter Crowd --disable-sandbox && swift test --filter SpringBone --disable-sandbox`
Expected: PASS — the seam/stepper don't perturb existing spring-bone behavior.

- [ ] **Step 6: Commit**

```bash
git add Sources/VRMMetalKit/Crowd/CrowdFrameStepper.swift \
        Tests/VRMMetalKitTests/Crowd/CrowdFrameStepperTests.swift
git commit -m "feat(crowd): CrowdFrameStepper (pose-all -> exchange -> composite) + non-interference"
```

---

### Task 4: `--crowd` mode in `VRMVideoRenderer`

Thin executable glue: parse the crowd flags, build N avatars (each its own renderer/model/player, shared camera, inward facing baked), join a `SpringBoneContactGroup` (unless `--crowd-no-contact`), and run the frame loop driving `CrowdFrameStepper` into the existing MSAA→pixelBuffer→AVAssetWriter path.

**Files:**
- Modify: `Sources/VRMVideoRenderer/main.swift`

**Interfaces:**
- Consumes: `CrowdMotionDriver`, `CrowdPlacement`, `CrowdFrameStepper` (Tasks 2-3), `VRMRenderer.joinContactGroup` (Task 1); existing `main.swift` helpers (`createPixelBuffer`, `copyTextureToPixelBuffer`, `lookAt`, `perspective`, `orthographic`, MSAA textures, AVAssetWriter setup, `VRMAnimationLoader.loadVRMA`, `AnimationPlayer`).

- [ ] **Step 1: Add crowd options to the argument parser**

In `Sources/VRMVideoRenderer/main.swift`, read the existing `RenderOptions` struct and `parseArguments()` (around lines 132-260) first. Add fields to `RenderOptions`:

```swift
    var crowd: Bool = false
    var avatarCount: Int = 2
    var crowdStartSep: Float = 1.0      // half-separation at start (meters)
    var crowdHoldSep: Float = 0.18      // half-separation at hold (the tunable half of the coupled pair)
    var crowdNoContact: Bool = false
```

And the matching cases in the argument loop (mirror the existing `case "--orbit":` style):

```swift
        case "--crowd": opts.crowd = true
        case "--avatar-count":
            i += 1; guard i < args.count else { return nil }
            opts.avatarCount = max(2, Int(args[i]) ?? 2)
        case "--crowd-start-sep":
            i += 1; guard i < args.count else { return nil }
            opts.crowdStartSep = Float(args[i]) ?? opts.crowdStartSep
        case "--crowd-hold-sep":
            i += 1; guard i < args.count else { return nil }
            opts.crowdHoldSep = Float(args[i]) ?? opts.crowdHoldSep
        case "--crowd-no-contact": opts.crowdNoContact = true
```

Add the flags to the `--help` ARGUMENTS text block (mirror the existing lines):

```
        --crowd                 Render multiple avatars approaching/touching
        --avatar-count N        Avatars in the crowd (default 2)
        --crowd-start-sep M     Start half-separation in meters (default 1.0)
        --crowd-hold-sep M      Hold half-separation in meters (default 0.18)
        --crowd-no-contact      Disable cross-avatar collision (before/after baseline)
```

- [ ] **Step 2: Build to confirm the parser compiles**

Run: `swift build`
Expected: builds clean (flags parsed but not yet used).

- [ ] **Step 3: Branch the render path on `--crowd`**

In `main.swift`, locate where the single-avatar renderer + player + frame loop are set up (the `config.synchronousSpringBone = true` block ~line 384 and the `for frameIndex in 0..<totalFrames` loop ~line 543). Wrap the existing single-avatar setup+loop so it runs only when `!options.crowd`, and add a `renderCrowd(...)` path for `options.crowd`. Extract the existing AVAssetWriter/pixelBuffer/MSAA-texture setup so both paths share it (it's already above the loop). Add this crowd function (place it near the single-avatar render code), reusing the existing helpers `lookAt`, `perspective`, `orthographic`, `createPixelBuffer`, `copyTextureToPixelBuffer`, and the already-created `msaaColorTexture`, `msaaDepthTexture`, `resolveTexture`, `sharedCommandQueue`, `writerInput`, `adaptor`, `frameDuration`:

```swift
// Build N avatars, wire a contact group, and drive CrowdFrameStepper into the
// existing MSAA -> pixelBuffer -> AVAssetWriter pipeline.
func buildCrowd(modelURL: URL, animURL: URL, device: MTLDevice,
                options: RenderOptions) async throws -> (CrowdFrameStepper, SpringBoneContactGroup?) {
    var config = RendererConfig()
    config.synchronousSpringBone = true
    config.sampleCount = 4

    let group: SpringBoneContactGroup? = options.crowdNoContact ? nil : SpringBoneContactGroup()
    var avatars: [CrowdFrameStepper.Avatar] = []
    let aspect = Float(options.width) / Float(options.height)

    for index in 0..<options.avatarCount {
        let model = try await VRMModel.load(from: modelURL, device: device, options: VRMLoadingOptions())
        // Bake inward facing once (design §4.1) via T/R/S — never localMatrix.
        for root in model.nodes where root.parent == nil {
            root.rotation = CrowdPlacement.facing(avatarIndex: index, avatarCount: options.avatarCount)
        }
        model.updateNodeTransforms()

        let renderer = VRMRenderer(device: device, config: config)
        renderer.loadModel(model)
        renderer.enableSpringBone = true
        renderer.projectionMatrix = options.orthographic
            ? orthographic(height: 2.0, aspect: aspect, near: 0.1, far: 100)
            : perspective(fovRadians: Float.pi / 4, aspect: aspect, near: 0.1, far: 100)

        let clip = try VRMAnimationLoader.loadVRMA(from: animURL, model: model)
        let player = AnimationPlayer(); player.load(clip); player.play()

        if let group { renderer.joinContactGroup(group) }
        avatars.append(CrowdFrameStepper.Avatar(renderer: renderer, model: model, player: player, index: index))
    }

    let driver = CrowdMotionDriver(
        startSep: options.crowdStartSep, holdSep: options.crowdHoldSep,
        approachStart: 0.1, approachEnd: 0.4, holdEnd: 0.7, partEnd: 0.95)
    return (CrowdFrameStepper(avatars: avatars, driver: driver, group: group, fps: Float(options.fps)), group)
}
```

- [ ] **Step 4: Wire the crowd frame loop**

In the crowd branch, replace the per-frame body with (reuse the existing texture/writer variables and the same shared camera applied to every avatar's renderer):

```swift
let (stepper, _) = try await buildCrowd(modelURL: modelURL, animURL: animURL, device: device, options: options)

for frameIndex in 0..<totalFrames {
    let t = totalFrames > 1 ? Float(frameIndex) / Float(totalFrames - 1) : 0

    // Shared camera for all avatars (orbit or fixed), applied before stepping.
    let view: float4x4
    if options.orbitCamera {
        let angle = Float(frameIndex) / Float(totalFrames) * 2.0 * Float.pi
        let radius = max(options.orbitTarget.radius, Float(options.avatarCount) * options.crowdStartSep * 0.9)
        let cy = options.orbitTarget.centerY
        view = lookAt(eye: SIMD3<Float>(sin(angle) * radius, cy, cos(angle) * radius),
                      center: SIMD3<Float>(0, cy, 0), up: SIMD3<Float>(0, 1, 0))
    } else {
        let dist = max(2.5, Float(options.avatarCount) * options.crowdStartSep * 1.1)
        view = lookAt(eye: SIMD3<Float>(0, 1.3, dist), center: SIMD3<Float>(0, 1.3, 0), up: SIMD3<Float>(0, 1, 0))
    }
    for av in stepper.avatarsForCamera { av.renderer.viewMatrix = view }

    stepper.step(frameTime: t)

    guard let pixelBuffer = createPixelBuffer(width: options.width, height: options.height),
          let commandBuffer = sharedCommandQueue.makeCommandBuffer() else { continue }
    let rpd = MTLRenderPassDescriptor()
    rpd.colorAttachments[0].texture = msaaColorTexture
    rpd.colorAttachments[0].resolveTexture = resolveTexture
    rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1.0)
    rpd.colorAttachments[0].storeAction = .multisampleResolve
    rpd.depthAttachment.texture = msaaDepthTexture
    rpd.depthAttachment.clearDepth = 1.0
    rpd.depthAttachment.storeAction = .dontCare

    stepper.drawComposite(color: msaaColorTexture, depth: msaaDepthTexture,
                          commandBuffer: commandBuffer, renderPassDescriptor: rpd)
    commandBuffer.commit()
    while commandBuffer.status != .completed && commandBuffer.status != .error { await Task.yield() }
    copyTextureToPixelBuffer(resolveTexture, to: pixelBuffer, device: device, commandBuffer: commandBuffer)
    let pts = CMTimeMultiply(frameDuration, multiplier: Int32(frameIndex))
    while !writerInput.isReadyForMoreMediaData { await Task.yield() }
    adaptor.append(pixelBuffer, withPresentationTime: pts)
    CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
}
```

Add a small read accessor on `CrowdFrameStepper` so the loop can set the shared camera (place with the other public members in `CrowdFrameStepper.swift`):

```swift
    /// The avatars, exposed so a host can set a shared camera on each renderer.
    public var avatarsForCamera: [Avatar] { avatars }
```

- [ ] **Step 5: Build**

Run: `swift build`
Expected: builds clean.

- [ ] **Step 6: Manual end-to-end verification (the acceptance artifact)**

Render the contact vs no-contact comparison (needs a Metal device + the fixture VRM + a VRMA). Use the project's test fixture paths or a local model with visible hair/skirt:

```bash
swift run VRMVideoRenderer <model.vrm> <idle.vrma> /tmp/crowd_contact.mov \
    --crowd --duration 4 --orbit --crowd-hold-sep 0.16
swift run VRMVideoRenderer <model.vrm> <idle.vrma> /tmp/crowd_noc.mov \
    --crowd --crowd-no-contact --duration 4 --orbit --crowd-hold-sep 0.16
```

Expected: both `.mov` files exist and are non-empty; in `crowd_contact.mov` the hair/cloth deflects off the partner's torso at the hold window, in `crowd_noc.mov` it clips through. If the torso capsules visibly interpenetrate (mannequin-clip) or leave an air gap, adjust the coupled pair — raise `--crowd-hold-sep` or tune `SpringBoneContactColliderSet.torsoRadiusFractionOfLength` — and re-render (design §4.3).

- [ ] **Step 7: Commit**

```bash
git add Sources/VRMVideoRenderer/main.swift Sources/VRMMetalKit/Crowd/CrowdFrameStepper.swift
git commit -m "feat(crowd): --crowd mode in VRMVideoRenderer (multi-avatar contact video)"
```

---

## Self-Review

**Spec coverage:**
- §2.1 avatar instances / one shared camera → Task 4 (`buildCrowd`, `avatarsForCamera`). ✓
- §2.2 `joinContactGroup` seam, system stays internal, single-caller caveat → Task 1 (doc comment carries the caveat). ✓
- §3 per-frame ordering (pose-all → exchange → render), T/R/S not localMatrix → Task 3 (`step`), Global Constraints + Task 1/3/4 all use T/R/S. ✓
- §4.1 placement bakes inward facing → Task 2 (`CrowdPlacement.facing`), baked once in Task 3 test + Task 4 setup. ✓
- §4.2 pure position-only motion driver → Task 2 (`CrowdMotionDriver`). ✓
- §4.3 holdSep↔radius coupled pair, CLI-tunable → Task 2 doc + Task 4 flags + Step 6 calibration note. ✓
- §4.4 CLI flags → Task 4 Step 1. ✓
- §5 tests: motion driver unit, placement invariants, crowd-step ordering/union-minus-self, no-contact bit-identical-to-solo, Metal-gated smoke → Tasks 2, 3 (`testStepPosesAndExchanges`, `testNoGroupIsBitIdenticalToSolo`, `testCompositeRendersNonEmptyFrame`), Task 4 Step 6 manual. ✓
- §6 out-of-scope (N>2, async, distinct models) → not implemented; N>2 ring degrades gracefully in `CrowdPlacement`, documented. ✓

**Placeholder scan:** none — every step has complete code or an exact command. The Task-4 edits reference existing `main.swift` symbols (read-first instructed) rather than restating the whole file, which is integration, not a placeholder.

**Type consistency:** `CrowdMotionDriver(startSep:holdSep:approachStart:approachEnd:holdEnd:partEnd:)` and `halfSeparation(at:)`, `CrowdPlacement.rootTranslation(avatarIndex:avatarCount:halfSeparation:)` / `.facing(avatarIndex:avatarCount:)`, `CrowdFrameStepper.Avatar(renderer:model:player:index:)` / `.init(avatars:driver:group:fps:)` / `.step(frameTime:)` / `.drawComposite(color:depth:commandBuffer:renderPassDescriptor:)` / `.avatarsForCamera` are used identically across Tasks 2, 3, 4. `joinContactGroup(_:)` / `leaveContactGroup(_:)` consistent Task 1 ↔ 3 ↔ 4. `activeForeignCapsules`, `springBoneComputeSystem`, `getCurrentPositions()`, `update(model:deltaTime:commandBuffer:)`, `waitForPendingFrame()` match the collision feature's shipped signatures.
