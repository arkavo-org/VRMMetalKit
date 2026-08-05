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

/// Foot IK layer that prevents foot sliding during locomotion.
///
/// This layer detects when feet are planted (contact phase) and uses
/// two-bone IK to lock them in place, preventing the "moonwalk" effect
/// when animations are retargeted to models with different proportions.
///
/// `solveIKForLeg` returns absolute bone-local rotations (thigh/shin), meant
/// for direct assignment to `node.rotation` — the construction in
/// `PoseStage.limbSolve` (the pipeline's S3). It is NOT a delta meant to be
/// composed as `basePose * delta`: on a rig with non-identity bind rotations
/// on the leg bones, that composition applies the base twice. See
/// `AnimationLayerCompositor.addIKLayer` for the compositor path this
/// disqualifies.
///
/// ## Usage
/// ```swift
/// let ikLayer = IKLayer()
/// ikLayer.initialize(with: model)
/// var avatar = PipelineAvatar(index: 0, model: model, player: player, baseTranslations: [:])
/// avatar.ikLayer = ikLayer
/// PoseStage.limbSolve(avatar: &avatar, partners: snapshot, dt: dt)
/// ```
public final class IKLayer: AnimationLayer {

    /// Identifies which leg an IK operation targets.
    public enum Side {
        /// Left leg (`leftUpperLeg` → `leftLowerLeg` → `leftFoot`).
        case left
        /// Right leg (`rightUpperLeg` → `rightLowerLeg` → `rightFoot`).
        case right
    }

    /// Foot-locking strategy used by the layer.
    public enum GroundingMode: Sendable {
        /// Use ``FootContactDetector`` to pin feet only during their contact phase. Suitable for walk and run cycles.
        case walkCycle
        /// Continuously pin both feet at their captured hip-relative rest offsets. Suitable for idle stances.
        case idleGrounding
    }

    /// Layer identifier used by ``AnimationLayerCompositor`` for lookup.
    public let identifier: String = "footIK"
    /// Layer evaluation priority. Higher than expression/look-at layers so IK overrides their leg writes.
    public let priority: Int = 4
    /// Whether the layer participates in composition this frame.
    public var isEnabled: Bool = true

    /// Bones this layer may rewrite: both legs from upper through foot.
    public var affectedBones: Set<VRMHumanoidBone> {
        [.leftUpperLeg, .leftLowerLeg, .leftFoot,
         .rightUpperLeg, .rightLowerLeg, .rightFoot]
    }

    /// Stride scale multiplier (1.0 = original animation stride)
    public var strideScale: Float = 1.0

    /// Blend weight for IK corrections (0.0 = no IK, 1.0 = full IK)
    public var ikBlendWeight: Float = 1.0

    /// Forward direction for knee pole vector (default: +Z in VRM coordinate system)
    public var kneeForwardDirection: SIMD3<Float> = SIMD3<Float>(0, 0, 1)

    /// Grounding mode: walkCycle uses FootContactDetector, idleGrounding pins both feet
    public var groundingMode: GroundingMode = .walkCycle

    /// Hip-to-foot offsets captured during initialize() for idle grounding.
    /// Stored as offsets from hips so they work regardless of model world position.
    private var leftFootHipOffset: SIMD3<Float>?
    private var rightFootHipOffset: SIMD3<Float>?

    /// Contact detector configuration
    public var contactConfig: FootContactDetector.Config {
        get { contactDetector.config }
        set { contactDetector.config = newValue }
    }

    private weak var model: VRMModel?
    private let contactDetector = FootContactDetector()

    private var leftLegLength: Float = 0
    private var rightLegLength: Float = 0
    private var leftThighLength: Float = 0
    private var leftShinLength: Float = 0
    private var rightThighLength: Float = 0
    private var rightShinLength: Float = 0

    private var pendingOutput: LayerOutput?

    /// Creates an unconfigured IK layer. Call ``initialize(with:)`` before evaluation.
    public init() {}

    /// Initialize the IK layer with a VRM model.
    ///
    /// This calculates leg bone lengths and sets up internal state.
    /// Must be called before the layer can produce valid output.
    ///
    /// - Parameter model: The VRM model to apply IK to
    public func initialize(with model: VRMModel) {
        self.model = model
        calculateLegLengths()

        // Capture hip-to-foot offsets for idle grounding (position-independent)
        if let hipPos = getJointWorldPosition(.hips) {
            if let leftFoot = getJointWorldPosition(.leftFoot) {
                leftFootHipOffset = leftFoot - hipPos
            }
            if let rightFoot = getJointWorldPosition(.rightFoot) {
                rightFootHipOffset = rightFoot - hipPos
            }
        }
    }

    /// Computes foot-IK rotations for this frame, storing them for the next ``evaluate()`` call.
    ///
    /// In ``GroundingMode/idleGrounding`` mode both feet are pinned to their
    /// captured hip-relative offsets. In ``GroundingMode/walkCycle`` mode
    /// the internal ``FootContactDetector`` is updated and only planted
    /// feet are pinned. Skipped entirely when ``ikBlendWeight`` is `0` or
    /// the layer has not been initialised.
    public func update(deltaTime: Float, context: AnimationContext) {
        guard model != nil, ikBlendWeight > 0 else {
            pendingOutput = nil
            return
        }

        var bones: [VRMHumanoidBone: ProceduralBoneTransform] = [:]

        switch groundingMode {
        case .idleGrounding:
            // Compute foot targets relative to current hip position
            guard let hipPos = getJointWorldPosition(.hips) else { break }
            if let offset = leftFootHipOffset {
                let leftTarget = hipPos + offset
                if let result = solveIKForLeg(side: .left, targetFootPos: leftTarget) {
                    bones[.leftUpperLeg] = ProceduralBoneTransform(rotation: result.rootRotation)
                    bones[.leftLowerLeg] = ProceduralBoneTransform(rotation: result.midRotation)
                }
            }
            if let offset = rightFootHipOffset {
                let rightTarget = hipPos + offset
                if let result = solveIKForLeg(side: .right, targetFootPos: rightTarget) {
                    bones[.rightUpperLeg] = ProceduralBoneTransform(rotation: result.rootRotation)
                    bones[.rightLowerLeg] = ProceduralBoneTransform(rotation: result.midRotation)
                }
            }

        case .walkCycle:
            let leftFootPos = getJointWorldPosition(.leftFoot) ?? .zero
            let rightFootPos = getJointWorldPosition(.rightFoot) ?? .zero

            contactDetector.update(
                leftFootPos: leftFootPos,
                rightFootPos: rightFootPos,
                deltaTime: deltaTime
            )

            if contactDetector.isLeftFootPlanted,
               let targetPos = contactDetector.leftFootPlantedPosition {
                if let result = solveIKForLeg(side: .left, targetFootPos: targetPos) {
                    bones[.leftUpperLeg] = ProceduralBoneTransform(rotation: result.rootRotation)
                    bones[.leftLowerLeg] = ProceduralBoneTransform(rotation: result.midRotation)
                }
            }

            if contactDetector.isRightFootPlanted,
               let targetPos = contactDetector.rightFootPlantedPosition {
                if let result = solveIKForLeg(side: .right, targetFootPos: targetPos) {
                    bones[.rightUpperLeg] = ProceduralBoneTransform(rotation: result.rootRotation)
                    bones[.rightLowerLeg] = ProceduralBoneTransform(rotation: result.midRotation)
                }
            }
        }

        if bones.isEmpty {
            pendingOutput = nil
        } else {
            pendingOutput = LayerOutput(
                bones: bones,
                morphWeights: [:],
                blendMode: .blend(ikBlendWeight)
            )
        }
    }

    /// Returns the leg-rotation overrides computed by the most recent ``update(deltaTime:context:)``, or an empty output when no foot was pinned.
    public func evaluate() -> LayerOutput {
        pendingOutput ?? LayerOutput()
    }

    /// Reset the IK layer state (call when animation changes).
    public func reset() {
        contactDetector.reset()
        pendingOutput = nil
    }

    private func calculateLegLengths() {
        guard let model = model, let humanoid = model.humanoid else { return }

        if let hipIdx = humanoid.getBoneNode(.leftUpperLeg),
           let kneeIdx = humanoid.getBoneNode(.leftLowerLeg),
           let ankleIdx = humanoid.getBoneNode(.leftFoot),
           hipIdx < model.nodes.count,
           kneeIdx < model.nodes.count,
           ankleIdx < model.nodes.count {
            let hipPos = model.nodes[hipIdx].worldPosition
            let kneePos = model.nodes[kneeIdx].worldPosition
            let anklePos = model.nodes[ankleIdx].worldPosition

            leftThighLength = TwoBoneIKSolver.boneLength(from: hipPos, to: kneePos)
            leftShinLength = TwoBoneIKSolver.boneLength(from: kneePos, to: anklePos)
            leftLegLength = leftThighLength + leftShinLength
        }

        if let hipIdx = humanoid.getBoneNode(.rightUpperLeg),
           let kneeIdx = humanoid.getBoneNode(.rightLowerLeg),
           let ankleIdx = humanoid.getBoneNode(.rightFoot),
           hipIdx < model.nodes.count,
           kneeIdx < model.nodes.count,
           ankleIdx < model.nodes.count {
            let hipPos = model.nodes[hipIdx].worldPosition
            let kneePos = model.nodes[kneeIdx].worldPosition
            let anklePos = model.nodes[ankleIdx].worldPosition

            rightThighLength = TwoBoneIKSolver.boneLength(from: hipPos, to: kneePos)
            rightShinLength = TwoBoneIKSolver.boneLength(from: kneePos, to: anklePos)
            rightLegLength = rightThighLength + rightShinLength
        }
    }

    /// Solves the two-bone leg chain against `targetFootPos`, returning bone-local
    /// rotations (root/mid, i.e. thigh/shin).
    ///
    /// Builds the hip–ankle–pole bend plane directly from each bone's actual bind
    /// rest direction (`initialTranslation`) and converts into each bone's own
    /// parent-relative local frame — the same construction as
    /// `CaptureStepController.placeAnkle`, which is the tracked-against-a-moving-root
    /// path this codebase has already validated end to end. `TwoBoneIKSolver.solve`'s
    /// world-frame result cannot be assigned directly as a local rotation: it assumes
    /// the bone's rest direction is world/local +Y and the parent chain carries no
    /// rotation, neither of which holds for a real humanoid rig (thighs rest pointing
    /// downward, hips/upper-leg bones carry non-identity bind rotations) — doing so
    /// produces a bone rotation off by upwards of 90°.
    ///
    /// `kneeForwardDirection` is a world-space hint, not auto-detected per avatar
    /// facing — a yawed avatar (any crowd member) needs the bend kept on the SIDE
    /// the knee already occupies, or the pole hint alone can put the solved knee on
    /// the wrong side of the leg. Mirrors `placeAnkle`'s lateral-preserving flip:
    /// project the current (pre-solve) hip→knee vector against the target direction
    /// and flip the pole if it disagrees, so the solve never crosses the knee to the
    /// opposite side of wherever it already was.
    ///
    /// Not `private`: exercised directly (via `@testable import`) by
    /// `IKLayerRoundTripTests`, since this is the only production path that turns a
    /// world-space foot target into applied bone rotations — nothing upstream of it
    /// is worth pinning in isolation.
    func solveIKForLeg(side: Side, targetFootPos: SIMD3<Float>) -> TwoBoneIKSolver.SolveResult? {
        guard let model = model, let humanoid = model.humanoid else { return nil }

        let (upperBone, lowerBone, endBone): (VRMHumanoidBone, VRMHumanoidBone, VRMHumanoidBone)
        let (thighLen, shinLen): (Float, Float)

        switch side {
        case .left:
            upperBone = .leftUpperLeg
            lowerBone = .leftLowerLeg
            endBone = .leftFoot
            thighLen = leftThighLength
            shinLen = leftShinLength
        case .right:
            upperBone = .rightUpperLeg
            lowerBone = .rightLowerLeg
            endBone = .rightFoot
            thighLen = rightThighLength
            shinLen = rightShinLength
        }

        guard let hipIdx = humanoid.getBoneNode(upperBone),
              let kneeIdx = humanoid.getBoneNode(lowerBone),
              let ankleIdx = humanoid.getBoneNode(endBone),
              hipIdx < model.nodes.count,
              kneeIdx < model.nodes.count,
              ankleIdx < model.nodes.count else {
            return nil
        }

        let hipPos = model.nodes[hipIdx].worldPosition
        let kneePos = model.nodes[kneeIdx].worldPosition
        let a = thighLen, b = shinLen
        guard a > 1e-4, b > 1e-4 else { return nil }

        let rootToTarget = targetFootPos - hipPos
        let rawReach = simd_length(rootToTarget)
        guard rawReach > 1e-4 else { return nil }
        let minReach = abs(a - b) + 0.001
        let maxReach = a + b - 0.001
        let c = simd_clamp(rawReach, minReach, maxReach)
        let targetDir = simd_normalize(rootToTarget)

        var pole = simd_normalize(kneeForwardDirection)
        pole = pole - targetDir * simd_dot(pole, targetDir)
        if simd_length(pole) < 1e-4 {
            let upHint = abs(simd_dot(targetDir, SIMD3<Float>(0, 1, 0))) > 0.9
                ? SIMD3<Float>(1, 0, 0) : SIMD3<Float>(0, 1, 0)
            pole = simd_cross(targetDir, upHint)
        }
        guard simd_length(pole) > 1e-4 else { return nil }
        pole = simd_normalize(pole)

        // Keep the bend on the side the knee already occupies (yaw-safe): a
        // world-space pole hint alone doesn't know which side of the leg plane
        // the avatar's actual forward is on once the rig has been rotated.
        let hipToKnee = kneePos - hipPos
        let lateral = hipToKnee - targetDir * simd_dot(hipToKnee, targetDir)
        if simd_length(lateral) > 0.02, simd_dot(lateral, pole) < 0 {
            pole = -pole
        }

        // Explicit knee position on the hip–ankle–pole plane (law of cosines) so
        // the joint cannot land behind the thigh (reverse knee).
        let h = (a * a - b * b + c * c) / (2 * c)
        let height = sqrtf(max(0, a * a - h * h))
        let kneeWorld = hipPos + targetDir * h + pole * height
        let exactAnkle = hipPos + targetDir * c

        let thighRest = model.nodes[kneeIdx].initialTranslation
        guard simd_length(thighRest) > 1e-6 else { return nil }
        let thighRestDir = simd_normalize(thighRest)
        let desiredThigh = simd_normalize(kneeWorld - hipPos)
        let hipParentWorld = TwoBoneIKSolver.worldRotation(model.nodes[hipIdx].parent?.worldMatrix)
        let desiredThighLocal = simd_act(hipParentWorld.inverse, desiredThigh)
        guard simd_length(desiredThighLocal) > 1e-6 else { return nil }
        let rootRotation = simd_normalize(
            simd_quatf(from: thighRestDir, to: simd_normalize(desiredThighLocal)))

        // `kneeWorld` already sits at distance `a` from `hipPos` along the solved
        // bend plane, so it IS the knee's post-rotation world position — no need to
        // apply `rootRotation` to the model to find it.
        let shinVec = exactAnkle - kneeWorld
        guard simd_length(shinVec) > 1e-6 else { return nil }
        let desiredShin = simd_normalize(shinVec)
        let shinRest = model.nodes[ankleIdx].initialTranslation
        guard simd_length(shinRest) > 1e-6 else { return nil }
        let shinRestDir = simd_normalize(shinRest)
        let kneeParentWorld = simd_normalize(simd_mul(hipParentWorld, rootRotation))
        let desiredShinLocal = simd_act(kneeParentWorld.inverse, desiredShin)
        guard simd_length(desiredShinLocal) > 1e-6 else { return nil }
        let midRotation = simd_normalize(
            simd_quatf(from: shinRestDir, to: simd_normalize(desiredShinLocal)))

        return TwoBoneIKSolver.SolveResult(rootRotation: rootRotation, midRotation: midRotation)
    }

    private func getJointWorldPosition(_ bone: VRMHumanoidBone) -> SIMD3<Float>? {
        guard let model = model,
              let humanoid = model.humanoid,
              let nodeIdx = humanoid.getBoneNode(bone),
              nodeIdx < model.nodes.count else {
            return nil
        }
        return model.nodes[nodeIdx].worldPosition
    }
}

extension AnimationLayerCompositor {
    /// Add an IK layer with automatic initialization.
    ///
    /// - Parameters:
    ///   - layer: The IK layer to add
    ///   - model: VRM model to initialize the layer with
    @available(*, deprecated, message: "IKLayer.solveIKForLeg returns absolute bone-local rotations; AnimationLayerCompositor applies layer output as basePose * delta, which double-applies the base on rigs with non-identity leg bind rotations. Use the pipeline's S3 (PoseStage.limbSolve via PipelineAvatar.ikLayer) instead.")
    public func addIKLayer(_ layer: IKLayer, for model: VRMModel) {
        layer.initialize(with: model)
        addLayer(layer)
    }
}
