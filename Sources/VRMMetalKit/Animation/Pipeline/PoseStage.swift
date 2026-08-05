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

    /// S0 — clip sampling, morph caching, VRMA look-at target.
    ///
    /// Root motion is NOT yet routed through this pipeline. `AnimationPlayer.update`
    /// writes hips translation directly, in clip space, whenever
    /// `applyRootMotion == true` — bypassing S2's `RootDisplacement`, the frame's
    /// only sanctioned root/hips writer (see the enum doc above). The S2 exit
    /// guard (`rootTranslations` / `debugAssertRootsUnchanged`) cannot see this:
    /// it only ever compares *scene-root* translations captured between `displace`
    /// and `limbSolve`, never hips, and never anything from S0. A locomotion clip
    /// driven with `applyRootMotion == true` would compose placement and clip-space
    /// root motion silently, with no test or assertion catching it.
    ///
    /// Every current construction site leaves `applyRootMotion` at its `false`
    /// default (crowd players carry no clip with hips translation tracks), so this
    /// fires nowhere today. It exists to fail loudly the moment a caller tries to
    /// route a locomotion clip through this pipeline before that routing has
    /// actually been built: `applyRootMotion` needs to become a delta contributed
    /// to S2's `RootDisplacement`, not a direct hips write in S0. That routing is
    /// a design decision out of scope here.
    public static func sample(avatar: inout PipelineAvatar, partners: FrozenSnapshot, dt: Float) {
        assert(!avatar.player.applyRootMotion,
               "S0 sampled a clip with applyRootMotion == true; AnimationPlayer writes hips " +
               "translation directly and bypasses S2's RootDisplacement, the pipeline's sole " +
               "sanctioned root/hips writer. Root motion must be routed through S2 as a delta " +
               "before a locomotion clip can use this pipeline.")
        avatar.player.update(deltaTime: dt, model: avatar.model)
    }

    /// S1 — pose-intent layers. The postural yield's direct apply, with the
    /// world-transform refresh its downstream readers need.
    public static func compose(avatar: inout PipelineAvatar, partners: FrozenSnapshot, dt: Float) {
        guard let layer = avatar.posturalLayer else { return }
        layer.partnerTorso = partners.nearestPartnerTorso(of: avatar.index)
        layer.update(deltaTime: dt, context: AnimationContext())
        layer.applyDirect(to: avatar.model)
        // Required: S2's second beat (`displace`) reads this avatar's own
        // world-space torso capsule to measure penetration, and that capsule
        // must reflect the postural lean this call just applied — otherwise
        // `displace` would clamp against a pre-lean torso.
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
        // Required: S1's postural lean (`compose`) measures its own trunk
        // endpoints in world space, which must reflect this placement.
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
    ///
    /// If both `avatar.ikLayer` and `avatar.captureStepper` are set, both may
    /// write the same four leg bones this call — `ikLayer` runs first, so the
    /// capture step's write wins (last writer). No construction site sets both
    /// today (`CrowdFrameStepper` never sets `ikLayer`), so this is a latent,
    /// untested interaction, not an exercised one; a future caller combining
    /// the two channels on one avatar needs an explicit precedence decision,
    /// not silent overwrite.
    public static func limbSolve(avatar: inout PipelineAvatar, partners: FrozenSnapshot, dt: Float) {
        if let ik = avatar.ikLayer {
            ik.update(deltaTime: dt, context: AnimationContext())
            let output = ik.evaluate()
            if !output.bones.isEmpty {
                for (bone, transform) in output.bones {
                    guard let humanoid = avatar.model.humanoid,
                          let idx = humanoid.getBoneNode(bone), idx < avatar.model.nodes.count else { continue }
                    let node = avatar.model.nodes[idx]
                    switch output.blendMode {
                    case .replace:
                        node.rotation = transform.rotation
                    case .additive:
                        node.rotation = simd_mul(node.rotation, transform.rotation)
                    case .blend(let weight):
                        node.rotation = simd_slerp(node.rotation, transform.rotation, weight)
                    }
                    node.updateLocalMatrix()
                }
                // Required: an early return here (staggerActive false, or no
                // captureStepper) hands control back to the caller with the IK
                // write as the pipeline's last action this call — callers read
                // world-space bone positions (`PlantedFootDriftTests`) straight
                // off this return with no further propagation of their own.
                avatar.model.updateNodeTransforms()
            }
        }

        guard avatar.staggerActive, let stepper = avatar.captureStepper else { return }
        // `stepper.update` (`CaptureStepController`) propagates after every
        // return path that writes a node local: the restore placement it
        // evaluates balance against (`:174`), and — if it re-steps — the
        // applied target (`:183`). Its two return paths that write nothing
        // (`guard isEnabled, let humanoid = model.humanoid else { return }`
        // at `:159`, and the missing-foot-bone `else { return }` at `:167`)
        // correctly propagate zero times. No further propagation is needed
        // here; adding one would just repeat a walk `stepper.update` already
        // did. This depends on `stepper.update` never adding a write above
        // its `isEnabled` guard without also adding a propagate there.
        stepper.update(deltaTime: dt, model: avatar.model)

        if let layer = avatar.armLayer {
            let balance = stepper.lastBalance
            let residual = max(0, -(balance?.margin ?? 0))
            layer.intensity = min(residual / fullBraceResidual, 1)
            layer.fallDirXZ = balance?.imbalanceDirection ?? .zero
            layer.update(deltaTime: dt, context: AnimationContext())
            layer.applyDirect(to: avatar.model)
            // Required: S4 (`constrain`) reads world position/matrix for aim
            // constraints, and this arm write is the last local write before
            // S4 runs — without this refresh S4 would solve against a pose
            // that predates the brace.
            avatar.model.updateNodeTransforms()
        }
    }

    /// Balance residual (metres of CoM outside the support base) that maps to a
    /// full brace. Sized against the measured stagger peaks (≈0.05 m
    /// under-capacity, ≈0.076 m over-capacity — `StaggerShoveIntegrationTests`).
    static let fullBraceResidual: Float = 0.08

    /// S4 — VRM node constraints on the final pose.
    ///
    /// Nothing before S4 may read constraint output. A layer needing a
    /// post-constraint pose is a cycle in the stage graph, which is a design
    /// smell to surface rather than accommodate.
    ///
    /// Precondition: `avatar.model`'s world transforms are already propagated
    /// when this runs. Aim constraints read `worldPosition` / the parent's
    /// `worldMatrix`, so a stale world matrix from a stage that wrote locals
    /// without calling `updateNodeTransforms()` would solve against last
    /// frame's geometry. This holds because every S0–S3 stage that writes a
    /// node local propagates before returning — NOT because every stage
    /// propagates unconditionally on every call: `limbSolve` can return
    /// having written and propagated zero times (no `ikLayer`, `staggerActive`
    /// false or no `captureStepper`, no `armLayer`), which satisfies this
    /// precondition trivially (nothing changed since the prior refresh), not
    /// vacuously. It is not re-verified here.
    ///
    /// Deliberately does NOT re-propagate after solving: `ConstraintSolver`
    /// writes each target's local matrix but not its world matrix (see
    /// `solveAimConstraint`), so a chained constraint reading a just-solved
    /// node's `worldPosition` within the same `solve()` call already reads
    /// pre-solve data — a pre-existing property of `ConstraintSolver`, not
    /// this stage. Nothing between this call and the scheduler's end-of-frame
    /// commit reads world space, so the commit is this stage's exit refresh.
    ///
    /// Contract change: this function used to end with its own
    /// `updateNodeTransforms()` call whenever it solved anything. It no
    /// longer does — an out-of-tree caller invoking `constrain` directly
    /// (outside `CrowdFrameStepper`, which now issues the commit itself)
    /// must propagate on its own afterward before reading world space.
    public static func constrain(avatar: inout PipelineAvatar, partners: FrozenSnapshot, dt: Float) {
        guard !avatar.model.nodeConstraints.isEmpty else { return }
        avatar.constraintSolver.solve(constraints: avatar.model.nodeConstraints, nodes: avatar.model.nodes)
    }
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
