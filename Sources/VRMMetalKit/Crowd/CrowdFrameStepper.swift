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

    /// Max torso-capsule overlap allowed by the contact-aware clamp (Component A,
    /// design §2). `nil` ⇒ clamp off (the driver's raw separation passes through).
    private let bodyContactMargin: Float?
    /// Per-avatar postural yield layers (Component B), keyed by avatar index.
    /// Empty ⇒ postural yield off. Fed each frame with the nearest partner torso.
    private let posturalLayers: [Int: PosturalContactLayer]
    /// The half-separation actually applied last frame — the radius the clamp's
    /// one-frame-lagged torso snapshot was measured at (design §2/§4).
    public private(set) var lastAppliedHalfSeparation: Float?
    /// Stagger shove tuning (design 2026-07-07 §3). `nil` ⇒ stagger off; the
    /// solver/controller dictionaries below stay empty and Phase 0e is skipped.
    private let staggerParams: StaggerShoveParams?
    /// Per-avatar shove solvers / capture-step controllers, keyed by avatar index.
    private var staggerSolvers: [Int: StaggerShoveSolver] = [:]
    private var captureSteppers: [Int: CaptureStepController] = [:]
    /// Per-avatar arm-counterbalance layers, keyed by avatar index. Empty ⇒ brace
    /// off. Driven by the capture-step controller's own balance read (Phase 0f),
    /// so the brace tracks the imbalance transient and releases as the step
    /// restores the margin — never a latched pose.
    private let armLayers: [Int: ArmCounterbalanceLayer]
    /// Balance residual (metres of CoM outside the support base) that maps to a
    /// full brace. Sized against the measured stagger peaks (≈0.05 m under-capacity,
    /// ≈0.076 m over-capacity — StaggerShoveIntegrationTests) so a hard shove reads
    /// as a near-full brace and the step's contraction releases it.
    private static let fullBraceResidual: Float = 0.08
    /// Avatars whose stagger channel has activated (first frame with depth > 0).
    /// Dormant avatars are byte-identical to the stagger-off path, so Phase 0b's
    /// scripted approach never reads as a CoM disturbance.
    private var staggerActive: Set<Int> = []

    /// The avatars, exposed so a host can set a shared camera on each renderer.
    public var avatarsForCamera: [Avatar] { avatars }

    /// The postural yield layer for `avatarIndex`, if postural yield is enabled.
    public func posturalLayer(forAvatar avatarIndex: Int) -> PosturalContactLayer? {
        posturalLayers[avatarIndex]
    }

    /// The stagger shove solver state for `avatarIndex` (a copy), if stagger is enabled.
    public func staggerSolver(forAvatar avatarIndex: Int) -> StaggerShoveSolver? {
        staggerSolvers[avatarIndex]
    }

    /// The capture-step controller for `avatarIndex`, if stagger is enabled.
    public func captureStepController(forAvatar avatarIndex: Int) -> CaptureStepController? {
        captureSteppers[avatarIndex]
    }

    /// The arm-counterbalance layer for `avatarIndex`, if the brace is enabled.
    public func armCounterbalanceLayer(forAvatar avatarIndex: Int) -> ArmCounterbalanceLayer? {
        armLayers[avatarIndex]
    }

    /// - Parameters:
    ///   - bodyContactMargin: enables Component A (contact-aware clamp) — the max
    ///     torso overlap allowed. `nil` leaves the driver's separation untouched.
    ///   - postural: enables Component B (postural yield) with these params; a
    ///     `PosturalContactLayer` is built and bound per avatar. `nil` ⇒ off.
    ///   - stagger: enables the stagger shove (design 2026-07-07) with these params;
    ///     a `StaggerShoveSolver` + `CaptureStepController` (committed arrest
    ///     defaults — the configuration the ~0.2 m/s capacity was validated with)
    ///     is built per avatar, dormant until first contact. `nil` ⇒ off.
    ///   - armCounterbalance: enables the arm brace (Component C) with these params;
    ///     an `ArmCounterbalanceLayer` is built and bound per avatar, driven each
    ///     frame by that avatar's balance residual (Phase 0f). Requires the stagger
    ///     channel (its `CaptureStepController` provides the balance read); with
    ///     stagger off the layers exist but never see a non-zero intensity.
    ///     `nil` ⇒ off.
    public init(avatars: [Avatar], driver: CrowdMotionDriver, group: SpringBoneContactGroup?, fps: Float,
                bodyContactMargin: Float? = nil, postural: PosturalContactParams? = nil,
                stagger: StaggerShoveParams? = nil, armCounterbalance: ArmCounterbalanceParams? = nil) {
        self.avatars = avatars
        self.driver = driver
        self.group = group
        self.dt = fps > 0 ? 1.0 / fps : 1.0 / 60.0
        self.bodyContactMargin = bodyContactMargin
        if let postural = postural {
            var layers: [Int: PosturalContactLayer] = [:]
            for avatar in avatars {
                let layer = PosturalContactLayer(params: postural)
                layer.initialize(with: avatar.model)
                layers[avatar.index] = layer
            }
            self.posturalLayers = layers
        } else {
            self.posturalLayers = [:]
        }
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
        if let armCounterbalance = armCounterbalance {
            var layers: [Int: ArmCounterbalanceLayer] = [:]
            for avatar in avatars {
                let layer = ArmCounterbalanceLayer(params: armCounterbalance)
                layer.initialize(with: avatar.model)
                layers[avatar.index] = layer
            }
            self.armLayers = layers
        } else {
            self.armLayers = [:]
        }
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
        let driverHalfSep = driver.halfSeparation(at: frameTime)

        // World-space torso capsules from the CURRENT (previous-frame-committed)
        // world matrices — the one-frame-lagged partner geometry (design §4) both
        // the clamp and the postural feed read. Gathered only when a component
        // needs it, so the default path stays untouched.
        let needsTorsos = bodyContactMargin != nil || !posturalLayers.isEmpty || staggerParams != nil
        var torsos: [Int: CapsuleCollider] = [:]
        if needsTorsos {
            for avatar in avatars {
                if let t = SpringBoneContactColliderSet.worldTorsoCapsule(model: avatar.model) {
                    torsos[avatar.index] = t
                }
            }
        }

        // Component A: raise the shared placement radius so the closest torso pair
        // overlaps by at most `bodyContactMargin` (the driver still governs when it
        // is already beyond the contact floor). Skipped on the first frame: there is
        // no committed-pose measurement to correct against yet — the lagged torsos
        // still reflect the un-placed bind pose (all roots coincident at origin ⇒
        // overlap ≈ 2·r), so clamping against them would kick frame 0's placement
        // outward by ≈(2r − margin)/chordFactor for exactly one frame, a visible
        // pop at video start.
        let halfSep: Float
        if let margin = bodyContactMargin, let lastHalfSep = lastAppliedHalfSeparation {
            halfSep = CrowdContactClamp.clampedHalfSeparation(
                driverHalfSep: driverHalfSep,
                lastAppliedHalfSep: lastHalfSep,
                torsos: avatars.map { torsos[$0.index] },
                avatarCount: avatars.count, margin: margin)
        } else {
            halfSep = driverHalfSep
        }
        lastAppliedHalfSeparation = halfSep

        // Component B: feed each avatar's layer its nearest partner's torso (lag).
        if !posturalLayers.isEmpty {
            for avatar in avatars {
                posturalLayers[avatar.index]?.partnerTorso =
                    nearestPartnerTorso(of: avatar.index, torsos: torsos)
            }
        }

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
            // Phase 0d: postural yield in the kinematic phase — writes the leaned
            // spine/chest BEFORE the spring solver (in drawComposite) runs, so the
            // chest's spring bones inherit the lean (design §3/§3.1). Direct
            // post-multiply onto the animated pose, then re-propagate for the snapshot.
            if let layer = posturalLayers[avatar.index] {
                layer.update(deltaTime: dt, context: AnimationContext())
                layer.applyDirect(to: avatar.model)
                avatar.model.updateNodeTransforms()
            }
            // Phase 0e: stagger shove + capture step (design 2026-07-07 §3).
            // Dormant until this avatar's first contact so Phase 0b's scripted
            // approach never reads as a CoM disturbance; from onset, the
            // rate-limited shove displaces the scene root and the capture-step
            // controller absorbs it by holding the planted feet and stepping.
            // Runs after 0d so the penetration signal is the lean-relieved one
            // and the spring snapshot sees the stepped pose.
            // Depth is the torso-pair surface overlap -- the same quantity
            // Component A's clamp measures -- rather than the chest point's
            // penetration into the partner capsule: the chest bone lies ON its
            // own torso capsule axis (torsoCollider is spine->chest), so that
            // signal is structurally zero at the clamp's contact floor, where
            // depth = bodyContactMargin. `mine` is recomputed fresh from this
            // avatar's just-updated pose (not the one-frame-stale `torsos`
            // snapshot) so it reflects 0d's lean and never spuriously overlaps
            // the partner's equally-stale pre-placement pose on frame 0; the
            // partner side stays on the stale snapshot by design (§4 lag).
            if staggerParams != nil {
                var depth: Float = 0
                var pushDirXZ = SIMD2<Float>.zero
                if let partner = nearestPartnerTorso(of: avatar.index, torsos: torsos),
                   let mine = SpringBoneContactColliderSet.worldTorsoCapsule(model: avatar.model) {
                    let pts = CrowdContactClamp.closestPoints(mine.p0, mine.p1, partner.p0, partner.p1)
                    depth = max(0, mine.radius + partner.radius - simd_length(pts.onA - pts.onB))
                    let away = pts.onA - pts.onB
                    pushDirXZ = SIMD2<Float>(away.x, away.z)
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
                    // Phase 0f: arm counterbalance. Driven by the controller's own
                    // balance read, so the brace engages with the imbalance
                    // transient and RELEASES as the capture step restores the
                    // margin — intensity is this frame's residual, never a latched
                    // state. Runs after 0e so the brace sits on the stepped pose
                    // and the snapshot sees the braced arms.
                    if let layer = armLayers[avatar.index] {
                        let balance = captureSteppers[avatar.index]?.lastBalance
                        let residual = max(0, -(balance?.margin ?? 0))
                        layer.intensity = min(residual / Self.fullBraceResidual, 1)
                        layer.fallDirXZ = balance?.imbalanceDirection ?? .zero
                        layer.update(deltaTime: dt, context: AnimationContext())
                        layer.applyDirect(to: avatar.model)
                        avatar.model.updateNodeTransforms()
                    }
                }
            }
        }
        // Phase 1+2: snapshot all (post-motion, post-yield poses), inject union-minus-self.
        group?.exchange()
    }

    /// The nearest OTHER avatar's torso capsule to `avatarIndex`, by capsule-midpoint
    /// distance. `nil` when this or every other avatar lacks a torso.
    private func nearestPartnerTorso(of avatarIndex: Int, torsos: [Int: CapsuleCollider]) -> CapsuleCollider? {
        guard let mine = torsos[avatarIndex] else { return nil }
        let myMid = (mine.p0 + mine.p1) * 0.5
        var best: CapsuleCollider?
        var bestDist = Float.greatestFiniteMagnitude
        for avatar in avatars where avatar.index != avatarIndex {
            guard let t = torsos[avatar.index] else { continue }
            let d = simd_length((t.p0 + t.p1) * 0.5 - myMid)
            if d < bestDist { bestDist = d; best = t }
        }
        return best
    }

    /// Phase 3: composite every avatar into `color`/`depth`. Each avatar is a
    /// separate render pass into the SAME MSAA `color`/`depth` textures, so the
    /// store-action contract matters as much as the load-action one: an
    /// intermediate pass's `.load` only sees a prior avatar's pixels if that
    /// prior pass actually stored the MSAA color+depth (not just resolved or
    /// discarded them). First avatar clears, the rest load; every avatar except
    /// the last stores MSAA color+depth so the next pass's `.load` is valid; only
    /// the last pass resolves color into the caller's resolve texture and
    /// discards MSAA depth, since nothing reads either after the frame (design
    /// §3).
    @MainActor
    public func drawComposite(color: MTLTexture, depth: MTLTexture,
                              commandBuffer: MTLCommandBuffer, renderPassDescriptor: MTLRenderPassDescriptor) {
        for (i, avatar) in avatars.enumerated() {
            let isFirst = i == 0
            let isLast = i == avatars.count - 1
            renderPassDescriptor.colorAttachments[0].loadAction = isFirst ? .clear : .load
            renderPassDescriptor.depthAttachment.loadAction = isFirst ? .clear : .load
            renderPassDescriptor.colorAttachments[0].storeAction = isLast ? .multisampleResolve : .store
            renderPassDescriptor.depthAttachment.storeAction = isLast ? .dontCare : .store
            avatar.renderer.drawOffscreenHeadless(
                to: color, depth: depth, commandBuffer: commandBuffer, renderPassDescriptor: renderPassDescriptor)
        }
    }
}
