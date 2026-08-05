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

    /// Max torso-capsule overlap allowed by the contact-aware clamp (Component A,
    /// design §2). `nil` ⇒ clamp off (the driver's raw separation passes through).
    private let bodyContactMargin: Float?
    /// The half-separation actually applied last frame — the radius the clamp's
    /// one-frame-lagged torso snapshot was measured at (design §2/§4).
    public private(set) var lastAppliedHalfSeparation: Float?
    /// Stagger shove tuning (design 2026-07-07 §3). `nil` ⇒ stagger off; S2's
    /// second beat is skipped.
    private let staggerParams: StaggerShoveParams?
    /// Every avatar's mutable per-frame pipeline state (S0–S3), keyed by
    /// position, in the same order as `avatars`.
    private var pipelineAvatars: [PipelineAvatar]

    /// The avatars, exposed so a host can set a shared camera on each renderer.
    public var avatarsForCamera: [Avatar] { avatars }

    /// The postural yield layer for `avatarIndex`, if postural yield is enabled.
    public func posturalLayer(forAvatar avatarIndex: Int) -> PosturalContactLayer? {
        pipelineAvatars.first { $0.index == avatarIndex }?.posturalLayer
    }

    /// The stagger shove solver state for `avatarIndex` (a copy), if stagger is enabled.
    public func staggerSolver(forAvatar avatarIndex: Int) -> StaggerShoveSolver? {
        pipelineAvatars.first { $0.index == avatarIndex }?.staggerSolver
    }

    /// The capture-step controller for `avatarIndex`, if stagger is enabled.
    public func captureStepController(forAvatar avatarIndex: Int) -> CaptureStepController? {
        pipelineAvatars.first { $0.index == avatarIndex }?.captureStepper
    }

    /// The arm-counterbalance layer for `avatarIndex`, if the brace is enabled.
    public func armCounterbalanceLayer(forAvatar avatarIndex: Int) -> ArmCounterbalanceLayer? {
        pipelineAvatars.first { $0.index == avatarIndex }?.armLayer
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
        self.staggerParams = stagger
        self.pipelineAvatars = avatars.map { avatar in
            // Snapshot each root's authored (bind) translation so scripted
            // motion is applied additively and never loses the model's base pose.
            var baseTranslations: [ObjectIdentifier: SIMD3<Float>] = [:]
            for root in avatar.model.nodes where root.parent == nil {
                baseTranslations[ObjectIdentifier(root)] = root.translation
            }

            let posturalLayer: PosturalContactLayer?
            if let postural = postural {
                let layer = PosturalContactLayer(params: postural)
                layer.initialize(with: avatar.model)
                posturalLayer = layer
            } else {
                posturalLayer = nil
            }

            let staggerSolver: StaggerShoveSolver?
            let captureStepper: CaptureStepController?
            if let stagger = stagger {
                staggerSolver = StaggerShoveSolver(params: stagger)
                var stepParams = CaptureStepParams()
                stepParams.captureDistance = CaptureStepParams.committedCaptureDistanceMax
                stepParams.stepDamping = CaptureStepParams.committedStepDampingMin
                captureStepper = CaptureStepController(params: stepParams)
            } else {
                staggerSolver = nil
                captureStepper = nil
            }

            let armLayer: ArmCounterbalanceLayer?
            if let armCounterbalance = armCounterbalance {
                let layer = ArmCounterbalanceLayer(params: armCounterbalance)
                layer.initialize(with: avatar.model)
                armLayer = layer
            } else {
                armLayer = nil
            }

            return PipelineAvatar(index: avatar.index, model: avatar.model, player: avatar.player,
                                  baseTranslations: baseTranslations, posturalLayer: posturalLayer,
                                  armLayer: armLayer, captureStepper: captureStepper,
                                  staggerSolver: staggerSolver, staggerActive: false)
        }
    }

    /// Phase 0 (pose all) + Phase 1+2 (exchange). `frameTime` is normalized [0,1].
    public func step(frameTime: Float) {
        let driverHalfSep = driver.halfSeparation(at: frameTime)

        // World-space torso capsules from the CURRENT (previous-frame-committed)
        // world matrices — the one-frame-lagged partner geometry (design §4) both
        // the clamp and the postural feed read. Gathered only when a component
        // needs it, so the default path stays untouched.
        let hasPostural = pipelineAvatars.contains { $0.posturalLayer != nil }
        let needsTorsos = bodyContactMargin != nil || hasPostural || staggerParams != nil
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

        let snapshot = FrozenSnapshot(torsos: torsos, indices: avatars.map { $0.index })

        for i in pipelineAvatars.indices {
            let placement = CrowdPlacement.rootTranslation(
                avatarIndex: pipelineAvatars[i].index, avatarCount: avatars.count, halfSeparation: halfSep)
            PoseStage.sample(avatar: &pipelineAvatars[i], partners: snapshot, dt: dt)
            PoseStage.place(avatar: &pipelineAvatars[i], placement: placement)
            PoseStage.compose(avatar: &pipelineAvatars[i], partners: snapshot, dt: dt)
            PoseStage.displace(avatar: &pipelineAvatars[i], partners: snapshot, dt: dt,
                               staggerEnabled: staggerParams != nil)
            let rootsAfterDisplace = PoseStage.rootTranslations(of: pipelineAvatars[i].model)
            PoseStage.limbSolve(avatar: &pipelineAvatars[i], partners: snapshot, dt: dt)
            PoseStage.debugAssertRootsUnchanged(avatar: pipelineAvatars[i], since: rootsAfterDisplace)
        }
        // Phase 1+2: snapshot all (post-motion, post-yield poses), inject union-minus-self.
        group?.exchange()
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
