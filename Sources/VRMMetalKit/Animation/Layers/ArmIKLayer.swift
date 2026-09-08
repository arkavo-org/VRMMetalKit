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

/// Procedural layer that drives each arm toward a world-space hand target
/// with two-bone IK and curls the fingers by amount.
///
/// ## Discussion
/// The typical use is device-driven motion with no tracker: the app maps a
/// keyboard, mouse, or controller into avatar space and moves the hand
/// targets there every frame. The layer solves shoulder and elbow rotations
/// with ``TwoBoneIKSolver`` and, unlike ``IKLayer``, never reads the live
/// arm pose: it rebuilds each chain from the bone rest transforms captured in
/// ``initialize(with:)`` under the parent's current world matrix, so the
/// deltas it emits are always relative to the compositor's base pose and a
/// constant target produces a constant pose frame after frame.
///
/// Finger curl is expressed as a rotation about a model-space axis
/// (``fingerCurlAxis(for:)`` and ``thumbCurlAxis``) converted into each
/// phalanx's local frame using its rest world rotation, so it works on rigs
/// whose finger bones do not share the hand's orientation.
///
/// Priority is above ``ArmCounterbalanceLayer`` and ``PosturalContactLayer``
/// so an explicit hand target wins over the procedural brace.
public final class ArmIKLayer: AnimationLayer {

    /// Which arm a target or curl applies to.
    public enum Side: Sendable, Hashable, CaseIterable {
        case left
        case right
    }

    /// A world-space goal for one hand.
    public struct HandTarget: Sendable, Equatable {
        /// Desired hand (wrist joint) position in model world space.
        public var position: SIMD3<Float>
        /// Direction the elbow should bend toward. `nil` uses ``ArmIKLayer/elbowHintDirection`` mirrored per side.
        public var elbowHint: SIMD3<Float>?
        /// Blend toward the solved pose, 0 = rest, 1 = fully on target.
        public var weight: Float

        public init(position: SIMD3<Float>, elbowHint: SIMD3<Float>? = nil, weight: Float = 1.0) {
            self.position = position
            self.elbowHint = elbowHint
            self.weight = weight
        }
    }

    /// One finger of a hand.
    public enum Finger: Sendable, CaseIterable {
        case thumb, index, middle, ring, little
    }

    /// Per-finger curl amounts in `0...1` (0 = straight, 1 = fully curled).
    public struct FingerCurl: Sendable, Equatable {
        public var thumb: Float
        public var index: Float
        public var middle: Float
        public var ring: Float
        public var little: Float

        public init(thumb: Float = 0, index: Float = 0, middle: Float = 0, ring: Float = 0, little: Float = 0) {
            self.thumb = thumb
            self.index = index
            self.middle = middle
            self.ring = ring
            self.little = little
        }

        /// All fingers straight.
        public static let open = FingerCurl()
        /// All fingers fully curled.
        public static let fist = FingerCurl(thumb: 1, index: 1, middle: 1, ring: 1, little: 1)
        /// Resting typing hand: light curl on every finger.
        public static let relaxed = FingerCurl(thumb: 0.3, index: 0.35, middle: 0.4, ring: 0.45, little: 0.5)

        public func amount(for finger: Finger) -> Float {
            switch finger {
            case .thumb: return thumb
            case .index: return index
            case .middle: return middle
            case .ring: return ring
            case .little: return little
            }
        }
    }

    public let identifier: String = "armIK"
    /// Above ``ArmCounterbalanceLayer`` (6) so hand targets override the brace.
    public let priority: Int = 7
    public var isEnabled: Bool = true

    public var affectedBones: Set<VRMHumanoidBone> {
        var bones: Set<VRMHumanoidBone> = [
            .leftUpperArm, .leftLowerArm, .leftHand,
            .rightUpperArm, .rightLowerArm, .rightHand
        ]
        for side in Side.allCases {
            for finger in Finger.allCases {
                bones.formUnion(Self.phalanges(side: side, finger: finger))
            }
        }
        return bones
    }

    /// Target for the left hand, or `nil` to leave the arm on its base pose.
    public var leftHand: HandTarget?
    /// Target for the right hand, or `nil` to leave the arm on its base pose.
    public var rightHand: HandTarget?
    /// Finger curl for the left hand, or `nil` for no finger writes.
    public var leftFingers: FingerCurl?
    /// Finger curl for the right hand, or `nil` for no finger writes.
    public var rightFingers: FingerCurl?

    /// Layer-wide blend weight applied on top of each target's own weight.
    public var ikBlendWeight: Float = 1.0

    /// Default elbow bend direction for the left arm in model space; the right arm mirrors X.
    /// Down and slightly back with a little outward flare suits typing and mouse poses.
    public var elbowHintDirection: SIMD3<Float> = SIMD3<Float>(0.25, -1.0, -0.35)

    /// Curl angle, in radians, for a fully curled proximal phalanx.
    public var maxFingerCurlAngle: Float = 1.4
    /// Fraction of ``maxFingerCurlAngle`` applied to proximal, intermediate, and distal phalanges.
    public var phalanxCurlScale: SIMD3<Float> = SIMD3<Float>(1.0, 0.85, 0.6)
    /// Model-space axis thumbs curl about (thumbs point +Z in a VRM T-pose; palms face -Y).
    public var thumbCurlAxis: SIMD3<Float> = SIMD3<Float>(1, 0, 0)

    /// Model-space axis the four fingers of `side` curl about.
    ///
    /// In a VRM T-pose the left fingers point +X and curl toward -Y, which is a
    /// rotation about -Z; the right hand mirrors to +Z.
    public func fingerCurlAxis(for side: Side) -> SIMD3<Float> {
        side == .left ? SIMD3<Float>(0, 0, -1) : SIMD3<Float>(0, 0, 1)
    }

    private struct RestTransform {
        var translation: SIMD3<Float>
        var rotation: simd_quatf
        var scale: SIMD3<Float>

        var matrix: float4x4 {
            var m = float4x4(rotation)
            m.columns.0 *= scale.x
            m.columns.1 *= scale.y
            m.columns.2 *= scale.z
            m.columns.3 = SIMD4<Float>(translation, 1)
            return m
        }
    }

    private struct ArmChain {
        var upper: Int
        var lower: Int
        var hand: Int
        var upperRest: RestTransform
        var lowerRest: RestTransform
        var handRest: RestTransform
        var upperLength: Float
        var lowerLength: Float
    }

    private weak var model: VRMModel?
    private var chains: [Side: ArmChain] = [:]
    private var restWorldRotations: [VRMHumanoidBone: simd_quatf] = [:]
    private var pendingOutput: LayerOutput?
    private var activeArms: Set<Side> = []
    private var activeFingers: Set<Side> = []

    /// Creates an unconfigured layer. Call ``initialize(with:)`` (or ``AnimationLayerCompositor/addArmIKLayer(_:for:)``) before evaluation.
    public init() {}

    /// Captures arm rest transforms and bone lengths from the model's current pose.
    ///
    /// Call with the model at the same pose the compositor captured as its
    /// base pose (normally the loaded rest pose).
    public func initialize(with model: VRMModel) {
        self.model = model
        chains = [:]
        restWorldRotations = [:]
        guard let humanoid = model.humanoid else { return }

        for side in Side.allCases {
            let (upperBone, lowerBone, handBone) = Self.armBones(side: side)
            guard let upper = humanoid.getBoneNode(upperBone),
                  let lower = humanoid.getBoneNode(lowerBone),
                  let hand = humanoid.getBoneNode(handBone),
                  upper < model.nodes.count, lower < model.nodes.count, hand < model.nodes.count else { continue }
            let upperNode = model.nodes[upper]
            let lowerNode = model.nodes[lower]
            let handNode = model.nodes[hand]
            chains[side] = ArmChain(
                upper: upper, lower: lower, hand: hand,
                upperRest: Self.rest(of: upperNode),
                lowerRest: Self.rest(of: lowerNode),
                handRest: Self.rest(of: handNode),
                upperLength: TwoBoneIKSolver.boneLength(from: upperNode.worldPosition, to: lowerNode.worldPosition),
                lowerLength: TwoBoneIKSolver.boneLength(from: lowerNode.worldPosition, to: handNode.worldPosition)
            )

            for finger in Finger.allCases {
                for bone in Self.phalanges(side: side, finger: finger) {
                    guard let index = humanoid.getBoneNode(bone), index < model.nodes.count else { continue }
                    restWorldRotations[bone] = Self.rotationPart(of: model.nodes[index].worldMatrix)
                }
            }
        }
    }

    public func update(deltaTime: Float, context: AnimationContext) {
        guard let model, ikBlendWeight > 0 else {
            pendingOutput = nil
            return
        }

        var bones: [VRMHumanoidBone: ProceduralBoneTransform] = [:]
        let identity = ProceduralBoneTransform(rotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1))

        for side in Side.allCases {
            let target = side == .left ? leftHand : rightHand
            let (upperBone, lowerBone, _) = Self.armBones(side: side)
            if let target, let chain = chains[side], let result = solve(chain: chain, side: side, target: target, model: model) {
                let weight = simd_clamp(target.weight, 0, 1)
                bones[upperBone] = ProceduralBoneTransform(rotation: Self.scaled(result.rootRotation, by: weight))
                bones[lowerBone] = ProceduralBoneTransform(rotation: Self.scaled(result.midRotation, by: weight))
                activeArms.insert(side)
            } else if activeArms.remove(side) != nil {
                // The compositor only rewrites bones a layer outputs, so a
                // released arm needs one explicit identity write to return
                // to the base pose instead of freezing where it was.
                bones[upperBone] = identity
                bones[lowerBone] = identity
            }

            if let curl = side == .left ? leftFingers : rightFingers {
                appendFingerCurls(curl, side: side, into: &bones)
                activeFingers.insert(side)
            } else if activeFingers.remove(side) != nil {
                for finger in Finger.allCases {
                    for bone in Self.phalanges(side: side, finger: finger) where restWorldRotations[bone] != nil {
                        bones[bone] = identity
                    }
                }
            }
        }

        pendingOutput = bones.isEmpty ? nil : LayerOutput(bones: bones, morphWeights: [:], blendMode: .blend(ikBlendWeight))
    }

    public func evaluate() -> LayerOutput {
        pendingOutput ?? LayerOutput()
    }

    /// Clears targets, curls, and the pending output.
    public func reset() {
        leftHand = nil
        rightHand = nil
        leftFingers = nil
        rightFingers = nil
        pendingOutput = nil
        activeArms = []
        activeFingers = []
    }

    // MARK: - Solving

    private func solve(chain: ArmChain, side: Side, target: HandTarget, model: VRMModel) -> TwoBoneIKSolver.SolveResult? {
        // Rebuild the chain at rest under the live parent so the solve is
        // independent of whatever this layer wrote last frame.
        let parentWorld = model.nodes[chain.upper].parent?.worldMatrix ?? matrix_identity_float4x4
        let upperWorld = parentWorld * chain.upperRest.matrix
        let lowerWorld = upperWorld * chain.lowerRest.matrix
        let handWorld = lowerWorld * chain.handRest.matrix

        let pole: SIMD3<Float>
        if let hint = target.elbowHint {
            pole = hint
        } else {
            var mirrored = elbowHintDirection
            if side == .right { mirrored.x = -mirrored.x }
            pole = mirrored
        }

        return TwoBoneIKSolver.solve(
            rootPos: Self.translation(of: upperWorld),
            midPos: Self.translation(of: lowerWorld),
            endPos: Self.translation(of: handWorld),
            targetPos: target.position,
            poleVector: pole,
            upperLength: chain.upperLength,
            lowerLength: chain.lowerLength,
            rootWorldRotation: Self.rotationPart(of: upperWorld),
            midWorldRotation: Self.rotationPart(of: lowerWorld)
        )
    }

    private func appendFingerCurls(_ curl: FingerCurl, side: Side, into bones: inout [VRMHumanoidBone: ProceduralBoneTransform]) {
        for finger in Finger.allCases {
            let amount = simd_clamp(curl.amount(for: finger), 0, 1)
            guard amount > 0 else { continue }
            let axis = finger == .thumb ? thumbCurlAxis : fingerCurlAxis(for: side)
            let phalanges = Self.phalanges(side: side, finger: finger)
            for (i, bone) in phalanges.enumerated() {
                guard let restWorld = restWorldRotations[bone] else { continue }
                let angle = amount * maxFingerCurlAngle * phalanxCurlScale[min(i, 2)]
                let worldDelta = simd_quatf(angle: angle, axis: simd_normalize(axis))
                let localDelta = simd_normalize(restWorld.inverse * worldDelta * restWorld)
                bones[bone] = ProceduralBoneTransform(rotation: localDelta)
            }
        }
    }

    // MARK: - Bone tables

    private static func armBones(side: Side) -> (VRMHumanoidBone, VRMHumanoidBone, VRMHumanoidBone) {
        side == .left ? (.leftUpperArm, .leftLowerArm, .leftHand) : (.rightUpperArm, .rightLowerArm, .rightHand)
    }

    /// Phalanges from proximal to distal (thumb: metacarpal, proximal, distal).
    static func phalanges(side: Side, finger: Finger) -> [VRMHumanoidBone] {
        switch (side, finger) {
        case (.left, .thumb): return [.leftThumbMetacarpal, .leftThumbProximal, .leftThumbDistal]
        case (.left, .index): return [.leftIndexProximal, .leftIndexIntermediate, .leftIndexDistal]
        case (.left, .middle): return [.leftMiddleProximal, .leftMiddleIntermediate, .leftMiddleDistal]
        case (.left, .ring): return [.leftRingProximal, .leftRingIntermediate, .leftRingDistal]
        case (.left, .little): return [.leftLittleProximal, .leftLittleIntermediate, .leftLittleDistal]
        case (.right, .thumb): return [.rightThumbMetacarpal, .rightThumbProximal, .rightThumbDistal]
        case (.right, .index): return [.rightIndexProximal, .rightIndexIntermediate, .rightIndexDistal]
        case (.right, .middle): return [.rightMiddleProximal, .rightMiddleIntermediate, .rightMiddleDistal]
        case (.right, .ring): return [.rightRingProximal, .rightRingIntermediate, .rightRingDistal]
        case (.right, .little): return [.rightLittleProximal, .rightLittleIntermediate, .rightLittleDistal]
        }
    }

    // MARK: - Math helpers

    private static func rest(of node: VRMNode) -> RestTransform {
        RestTransform(translation: node.translation, rotation: node.rotation, scale: node.scale)
    }

    private static func translation(of m: float4x4) -> SIMD3<Float> {
        SIMD3<Float>(m.columns.3.x, m.columns.3.y, m.columns.3.z)
    }

    /// Rotation part of a matrix with any scale removed.
    static func rotationPart(of m: float4x4) -> simd_quatf {
        let c0 = SIMD3<Float>(m.columns.0.x, m.columns.0.y, m.columns.0.z)
        let c1 = SIMD3<Float>(m.columns.1.x, m.columns.1.y, m.columns.1.z)
        let c2 = SIMD3<Float>(m.columns.2.x, m.columns.2.y, m.columns.2.z)
        let l0 = simd_length(c0), l1 = simd_length(c1), l2 = simd_length(c2)
        guard l0 > 1e-8, l1 > 1e-8, l2 > 1e-8 else { return simd_quatf(ix: 0, iy: 0, iz: 0, r: 1) }
        return simd_normalize(simd_quatf(simd_float3x3(c0 / l0, c1 / l1, c2 / l2)))
    }

    private static func scaled(_ q: simd_quatf, by weight: Float) -> simd_quatf {
        guard weight < 1 else { return q }
        return simd_normalize(simd_slerp(simd_quatf(ix: 0, iy: 0, iz: 0, r: 1), q, weight))
    }
}

extension AnimationLayerCompositor {
    /// Adds an arm IK layer, initializing it against `model` first.
    public func addArmIKLayer(_ layer: ArmIKLayer, for model: VRMModel) {
        layer.initialize(with: model)
        addLayer(layer)
    }
}
