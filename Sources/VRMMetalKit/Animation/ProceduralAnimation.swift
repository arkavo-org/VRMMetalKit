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

// MARK: - Blend Modes

/// How animation layers combine their transforms with lower priority layers
public enum AnimationBlendMode: Sendable {
    /// Completely override transforms from lower layers
    case replace
    /// Add transforms to existing values (rotation = multiply quaternions, translation = add)
    case additive
    /// Weighted blend with lower layers using SLERP for rotations
    case blend(Float)
}

// MARK: - Conversation State

/// Current state of avatar conversation for animation context
public enum ProceduralConversationState: Sendable {
    case idle
    case listening
    case thinking
    case speaking
}

// MARK: - Bone Transform

/// Represents a bone's local transform for animation
public struct ProceduralBoneTransform: Sendable {
    public var rotation: simd_quatf
    public var translation: SIMD3<Float>
    public var scale: SIMD3<Float>

    public static let identity = ProceduralBoneTransform(
        rotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
        translation: .zero,
        scale: SIMD3<Float>(1, 1, 1)
    )

    public init(
        rotation: simd_quatf = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
        translation: SIMD3<Float> = .zero,
        scale: SIMD3<Float> = SIMD3<Float>(1, 1, 1)
    ) {
        self.rotation = rotation
        self.translation = translation
        self.scale = scale
    }
}

// MARK: - Animation Context

/// Shared context passed to all animation layers each frame
public struct AnimationContext: Sendable {
    public var time: Float
    public var deltaTime: Float
    public var cameraPosition: SIMD3<Float>
    public var avatarPosition: SIMD3<Float>
    public var conversationState: ProceduralConversationState
    public var sentimentPreset: VRMExpressionPreset?
    public var sentimentIntensity: Float

    public init(
        time: Float = 0,
        deltaTime: Float = 0,
        cameraPosition: SIMD3<Float> = .zero,
        avatarPosition: SIMD3<Float> = .zero,
        conversationState: ProceduralConversationState = .idle,
        sentimentPreset: VRMExpressionPreset? = nil,
        sentimentIntensity: Float = 0
    ) {
        self.time = time
        self.deltaTime = deltaTime
        self.cameraPosition = cameraPosition
        self.avatarPosition = avatarPosition
        self.conversationState = conversationState
        self.sentimentPreset = sentimentPreset
        self.sentimentIntensity = sentimentIntensity
    }
}

// MARK: - Layer Output

/// Output from an animation layer containing sparse bone transforms and morph weights
public struct LayerOutput: Sendable {
    public var bones: [VRMHumanoidBone: ProceduralBoneTransform]
    public var morphWeights: [String: Float]
    public var blendMode: AnimationBlendMode

    public init(
        bones: [VRMHumanoidBone: ProceduralBoneTransform] = [:],
        morphWeights: [String: Float] = [:],
        blendMode: AnimationBlendMode = .blend(1.0)
    ) {
        self.bones = bones
        self.morphWeights = morphWeights
        self.blendMode = blendMode
    }
}

// MARK: - Animation Layer Protocol

/// Protocol for procedural animation layers
public protocol AnimationLayer: AnyObject {
    /// Unique identifier for this layer
    var identifier: String { get }

    /// Priority (lower = evaluated first, higher priority layers override lower)
    var priority: Int { get }

    /// Whether this layer is currently active
    var isEnabled: Bool { get set }

    /// Set of bones this layer may affect (used for masking/debugging)
    var affectedBones: Set<VRMHumanoidBone> { get }

    /// Update internal state with current context
    func update(deltaTime: Float, context: AnimationContext)

    /// Evaluate and return the layer's output transforms
    func evaluate() -> LayerOutput
}

// MARK: - Animation Layer Compositor

/// Manages and composites multiple animation layers
public class AnimationLayerCompositor {
    private var layers: [AnimationLayer] = []
    private weak var model: VRMModel?

    // Pre-allocated storage to avoid per-frame allocations
    private var compositedBones: [VRMHumanoidBone: ProceduralBoneTransform] = [:]
    private var compositedMorphs: [String: Float] = [:]

    // Base pose storage - the original rotations from the VRM model
    private var basePoseRotations: [VRMHumanoidBone: simd_quatf] = [:]
    private var basePoseTranslations: [VRMHumanoidBone: SIMD3<Float>] = [:]
    private var basePoseScales: [VRMHumanoidBone: SIMD3<Float>] = [:]

    public init() {}

    /// Setup with VRM model reference and capture base pose
    public func setup(model: VRMModel) {
        self.model = model

        // Capture base pose rotations for all humanoid bones
        guard let humanoid = model.humanoid else { return }
        for bone in VRMHumanoidBone.allCases {
            if let nodeIndex = humanoid.getBoneNode(bone), nodeIndex < model.nodes.count {
                let node = model.nodes[nodeIndex]
                basePoseRotations[bone] = node.rotation
                basePoseTranslations[bone] = node.translation
                basePoseScales[bone] = node.scale
            }
        }
    }

    /// Add an animation layer (automatically sorted by priority)
    public func addLayer(_ layer: AnimationLayer) {
        layers.append(layer)
        layers.sort { $0.priority < $1.priority }
    }

    /// Remove a layer by identifier
    public func removeLayer(identifier: String) {
        layers.removeAll { $0.identifier == identifier }
    }

    /// Get a layer by identifier
    public func getLayer(identifier: String) -> AnimationLayer? {
        layers.first { $0.identifier == identifier }
    }

    /// Get all registered layers
    public var allLayers: [AnimationLayer] {
        layers
    }

    /// Update all layers and apply composited result to model
    public func update(deltaTime: Float, context: AnimationContext) {
        guard let model = model else { return }

        // Update all enabled layers
        for layer in layers where layer.isEnabled {
            layer.update(deltaTime: deltaTime, context: context)
        }

        // Clear previous frame's data
        compositedBones.removeAll(keepingCapacity: true)
        compositedMorphs.removeAll(keepingCapacity: true)

        // Composite outputs from lowest to highest priority
        for layer in layers where layer.isEnabled {
            let output = layer.evaluate()
            compositeOutput(output)
        }

        // Apply to model
        applyToModel(model: model)
    }

    /// Apply only morph weights without affecting bone transforms
    public func applyMorphsToController(_ controller: VRMExpressionController?) {
        guard let controller = controller else { return }

        for (name, weight) in compositedMorphs {
            if let preset = VRMExpressionPreset(rawValue: name) {
                controller.setExpressionWeight(preset, weight: weight)
            } else {
                controller.setCustomExpressionWeight(name, weight: weight)
            }
        }
    }

    // MARK: - Private Methods

    private func compositeOutput(_ output: LayerOutput) {
        // Blend bones
        for (bone, transform) in output.bones {
            switch output.blendMode {
            case .replace:
                compositedBones[bone] = transform

            case .additive:
                if let existing = compositedBones[bone] {
                    compositedBones[bone] = blendAdditive(existing, transform)
                } else {
                    compositedBones[bone] = transform
                }

            case .blend(let weight):
                if let existing = compositedBones[bone] {
                    compositedBones[bone] = blendWeighted(existing, transform, weight: weight)
                } else {
                    // No existing transform - blend with identity
                    compositedBones[bone] = blendWeighted(.identity, transform, weight: weight)
                }
            }
        }

        // Morphs always accumulate additively
        for (key, value) in output.morphWeights {
            compositedMorphs[key, default: 0] += value
        }
    }

    private func blendAdditive(_ a: ProceduralBoneTransform, _ b: ProceduralBoneTransform) -> ProceduralBoneTransform {
        ProceduralBoneTransform(
            rotation: simd_mul(a.rotation, b.rotation),
            translation: a.translation + b.translation,
            scale: a.scale * b.scale
        )
    }

    private func blendWeighted(_ a: ProceduralBoneTransform, _ b: ProceduralBoneTransform, weight: Float) -> ProceduralBoneTransform {
        ProceduralBoneTransform(
            rotation: simd_slerp(a.rotation, b.rotation, weight),
            translation: simd_mix(a.translation, b.translation, SIMD3<Float>(repeating: weight)),
            scale: simd_mix(a.scale, b.scale, SIMD3<Float>(repeating: weight))
        )
    }

    private func applyToModel(model: VRMModel) {
        guard let humanoid = model.humanoid else { return }

        // Apply bone transforms by composing procedural deltas with base pose
        for (bone, proceduralTransform) in compositedBones {
            guard let nodeIndex = humanoid.getBoneNode(bone),
                  nodeIndex < model.nodes.count else { continue }

            let node = model.nodes[nodeIndex]

            // Get base pose (default to identity if not captured)
            let baseRotation = basePoseRotations[bone] ?? simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
            let baseTranslation = basePoseTranslations[bone] ?? .zero
            let baseScale = basePoseScales[bone] ?? SIMD3<Float>(1, 1, 1)

            // Compose: final = basePose * proceduralDelta
            node.rotation = simd_mul(baseRotation, proceduralTransform.rotation)
            node.translation = baseTranslation + proceduralTransform.translation
            node.scale = baseScale * proceduralTransform.scale
            node.updateLocalMatrix()
        }

        // Propagate world transforms from root nodes
        for node in model.nodes where node.parent == nil {
            node.updateWorldTransform()
        }
    }
}
