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
/// ## Usage
/// ```swift
/// let compositor = AnimationLayerCompositor()
/// compositor.setup(model: model)
///
/// let ikLayer = IKLayer()
/// compositor.addIKLayer(ikLayer, for: model)
/// ```
public final class IKLayer: AnimationLayer {

    public enum Side {
        case left
        case right
    }

    public enum GroundingMode: Sendable {
        case walkCycle       // Original: use FootContactDetector
        case idleGrounding   // Pin both feet at rest positions
    }

    public let identifier: String = "footIK"
    public let priority: Int = 4
    public var isEnabled: Bool = true

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

    public func evaluate() -> LayerOutput {
        pendingOutput ?? LayerOutput()
    }

    /// Reset the IK layer state (call when animation changes).
    public func reset() {
        contactDetector.reset()
        pendingOutput = nil
    }

    /// Calculate total leg length for a side.
    ///
    /// - Parameters:
    ///   - model: VRM model
    ///   - side: Left or right leg
    /// - Returns: Total leg length (thigh + shin)
    public func calculateLegLength(model: VRMModel, side: Side) -> Float {
        self.model = model
        calculateLegLengths()
        return side == .left ? leftLegLength : rightLegLength
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

    private func solveIKForLeg(side: Side, targetFootPos: SIMD3<Float>) -> TwoBoneIKSolver.SolveResult? {
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
        let anklePos = model.nodes[ankleIdx].worldPosition

        return TwoBoneIKSolver.solve(
            rootPos: hipPos,
            midPos: kneePos,
            endPos: anklePos,
            targetPos: targetFootPos,
            poleVector: kneeForwardDirection,
            upperLength: thighLen,
            lowerLength: shinLen
        )
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
    public func addIKLayer(_ layer: IKLayer, for model: VRMModel) {
        layer.initialize(with: model)
        addLayer(layer)
    }
}
