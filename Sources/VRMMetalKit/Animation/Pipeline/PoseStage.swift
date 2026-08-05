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
