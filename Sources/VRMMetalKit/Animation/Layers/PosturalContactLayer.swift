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

/// Procedural postural yield (design §3, lever 2): a stiff lean of the upper
/// body *away* from a penetrating partner torso, so the rig visibly yields on
/// contact rather than interpenetrating. Wraps ``PosturalContactSolver`` (the
/// pure yield math) with the model plumbing, splitting the computed lean across
/// `spine` and `chest` so it reads as a natural bend.
///
/// ## Two apply paths (design §3.1)
/// - **Library / compositor path:** conforms to ``AnimationLayer`` — apps already
///   running an ``AnimationLayerCompositor`` get the yield by adding the layer and
///   feeding it a partner torso capsule each frame. ``evaluate()`` emits per-bone
///   deltas the compositor composes onto its captured base pose.
/// - **Clip-driven path (crowd):** call ``applyDirect(to:)`` to **post-multiply**
///   the yield onto each bone's *current animated* local rotation. This is the
///   path the crowd stepper uses, because the compositor's `baseRotation × delta`
///   compose (from a setup-time capture) would clobber a live clip's spine motion.
///
/// The yield is written in the kinematic phase, *before* the spring solver runs,
/// so the chest's spring bones (hair) inherit the lean for free.
public final class PosturalContactLayer: AnimationLayer {

    // MARK: AnimationLayer conformance

    public let identifier: String = "posturalContact"
    /// Higher than foot-IK (4): the spine yield composes after leg IK has run.
    public let priority: Int = 5
    public var isEnabled: Bool = true
    /// The upper-body bones the yield distributes across (chest falls back to
    /// upperChest/neck/head when a rig omits `.chest` — common on VRM 1.0).
    public var affectedBones: Set<VRMHumanoidBone> {
        var s: Set<VRMHumanoidBone> = [.spine]
        if let model = model, let humanoid = model.humanoid {
            if humanoid.getBoneNode(.chest) != nil { s.insert(.chest) }
            else if humanoid.getBoneNode(.upperChest) != nil { s.insert(.upperChest) }
            else if humanoid.getBoneNode(.neck) != nil { s.insert(.neck) }
            else if humanoid.getBoneNode(.head) != nil { s.insert(.head) }
        } else {
            s.insert(.chest)
        }
        return s
    }

    // MARK: Configuration

    /// Yield tuning (forwarded to the solver).
    public var params: PosturalContactParams {
        get { solver.params }
        set { solver.params = newValue }
    }

    /// The partner torso capsule to yield away from, in world space, fed per frame
    /// by the coordinator (design §4). `nil` ⇒ no partner ⇒ the layer decays to
    /// identity and emits nothing.
    public var partnerTorso: CapsuleCollider?

    /// Fraction of the total lean taken by the `spine` bone; the remainder is
    /// taken by `chest`. `0.5` reads as an even two-segment bend.
    public var spineFraction: Float = 0.5

    // MARK: State

    private var solver: PosturalContactSolver
    private weak var model: VRMModel?
    private var pending: [VRMHumanoidBone: simd_quatf] = [:]

    /// The magnitude (radians) of the currently-applied world-space lean. `0` at
    /// rest; grows on contact and decays on separation. Diagnostics / tests.
    public var currentLeanAngle: Float { solver.lean.angle }

    public init(params: PosturalContactParams = PosturalContactParams()) {
        self.solver = PosturalContactSolver(params: params)
    }

    /// Bind the layer to a model so it can read spine/chest world positions.
    public func initialize(with model: VRMModel) {
        self.model = model
    }

    // MARK: Frame update

    /// Recompute the yield for this frame from ``partnerTorso`` and the model's
    /// current spine/chest world positions, then split it into per-bone local
    /// deltas stored for ``evaluate()`` / ``applyDirect(to:)``. A no-op (empty
    /// deltas, solver decays toward identity) when disabled, `blendWeight <= 0`,
    /// unbound, or the rig lacks a spine/chest.
    public func update(deltaTime: Float, context: AnimationContext) {
        pending.removeAll(keepingCapacity: true)
        guard isEnabled, params.blendWeight > 0, let model = model,
              let trunk = trunkEndpoints(model: model) else {
            // Still decay any residual lean toward identity so a disable mid-lean
            // eases out rather than snapping (target identity via no penetration).
            solver.update(partnerTorso: CapsuleCollider(p0: .zero, p1: SIMD3<Float>(0, 1, 0), radius: 0),
                          chestWorld: SIMD3<Float>(0, 1e6, 0), spineUp: SIMD3<Float>(0, 1, 0), dt: deltaTime)
            return
        }

        let spineWorld = trunk.spine
        let chestWorld = trunk.chest
        let upperBone = trunk.upperBone

        // Trunk axis (spine -> chest/upperChest/…) as the lean's "up".
        let trunkAxis = chestWorld - spineWorld
        let spineUp = simd_length(trunkAxis) > 1e-6 ? simd_normalize(trunkAxis) : SIMD3<Float>(0, 1, 0)

        let torso = partnerTorso ?? CapsuleCollider(p0: .zero, p1: SIMD3<Float>(0, 1, 0), radius: 0)
        let worldLean = solver.update(partnerTorso: torso, chestWorld: chestWorld,
                                      spineUp: spineUp, dt: deltaTime)

        // Weight the whole lean, then split across spine + upper trunk bone.
        let identity = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        let weighted = simd_slerp(identity, worldLean, simd_clamp(params.blendWeight, 0, 1))
        guard weighted.angle > 1e-5 else { return }

        let spineWorldShare = simd_slerp(identity, weighted, spineFraction)
        let chestWorldShare = simd_slerp(identity, weighted, 1 - spineFraction)
        if let ls = localDelta(spineWorldShare, bone: .spine, model: model) { pending[.spine] = ls }
        if let lc = localDelta(chestWorldShare, bone: upperBone, model: model) { pending[upperBone] = lc }
    }

    /// Per-bone local yield deltas from the most recent ``update(deltaTime:context:)``,
    /// for the compositor path. Empty ⇒ exact no-op.
    public func evaluate() -> LayerOutput {
        guard !pending.isEmpty else { return LayerOutput() }
        var bones: [VRMHumanoidBone: ProceduralBoneTransform] = [:]
        for (bone, q) in pending { bones[bone] = ProceduralBoneTransform(rotation: q) }
        return LayerOutput(bones: bones, morphWeights: [:], blendMode: .blend(1.0))
    }

    /// Post-multiply the yield onto each affected bone's *current animated* local
    /// rotation (design §3.1 / §3D): `node.rotation = animRotation × yieldShare`.
    /// The caller runs `updateNodeTransforms()` afterward. No-op when ``evaluate()``
    /// is empty. Unlike the compositor, this preserves the live clip pose.
    public func applyDirect(to model: VRMModel) {
        guard !pending.isEmpty, let humanoid = model.humanoid else { return }
        for (bone, share) in pending {
            guard let idx = humanoid.getBoneNode(bone), idx < model.nodes.count else { continue }
            model.nodes[idx].rotation = simd_normalize(model.nodes[idx].rotation * share)
        }
    }

    // MARK: Helpers

    /// Spine + upper-trunk sample points. Falls back through chest → upperChest
    /// → neck → head so lean still runs on rigs that omit a VRM `.chest` bone.
    private func trunkEndpoints(model: VRMModel)
        -> (spine: SIMD3<Float>, chest: SIMD3<Float>, upperBone: VRMHumanoidBone)? {
        guard let spine = boneWorldPosition(.spine, model) else { return nil }
        let upperCandidates: [VRMHumanoidBone] = [.chest, .upperChest, .neck, .head]
        for bone in upperCandidates {
            if let p = boneWorldPosition(bone, model) {
                return (spine, p, bone)
            }
        }
        return nil
    }

    private func boneWorldPosition(_ bone: VRMHumanoidBone, _ model: VRMModel) -> SIMD3<Float>? {
        guard let humanoid = model.humanoid, let idx = humanoid.getBoneNode(bone),
              idx < model.nodes.count else { return nil }
        return model.nodes[idx].worldPosition
    }

    /// Convert a world-space rotation delta into `bone`'s local space so applying
    /// it as a local rotation produces that world tilt regardless of the avatar's
    /// facing: `qLocal = parentWorldRot⁻¹ · qWorld · parentWorldRot`.
    private func localDelta(_ worldDelta: simd_quatf, bone: VRMHumanoidBone,
                            model: VRMModel) -> simd_quatf? {
        guard let humanoid = model.humanoid, let idx = humanoid.getBoneNode(bone),
              idx < model.nodes.count else { return nil }
        let parentWorldRot: simd_quatf
        if let parent = model.nodes[idx].parent {
            parentWorldRot = worldRotation(parent.worldMatrix)
        } else {
            parentWorldRot = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        }
        return simd_normalize(parentWorldRot.inverse * worldDelta * parentWorldRot)
    }

    /// Orthonormalized rotation quaternion from a (possibly scaled) world matrix.
    private func worldRotation(_ m: simd_float4x4) -> simd_quatf {
        let c0 = simd_normalize(SIMD3<Float>(m[0][0], m[0][1], m[0][2]))
        let c1 = simd_normalize(SIMD3<Float>(m[1][0], m[1][1], m[1][2]))
        let c2 = simd_normalize(SIMD3<Float>(m[2][0], m[2][1], m[2][2]))
        return simd_quatf(simd_float3x3(c0, c1, c2))
    }
}
