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

/// How an ``AnimationLayer``'s output combines with the running composite produced by lower-priority layers.
public enum AnimationBlendMode: Sendable {
    /// Overwrite any existing composite for the bones this layer writes.
    case replace
    /// Multiply rotation quaternions and add translation/scale to the running composite.
    case additive
    /// SLERP rotation and lerp translation and scale toward this layer's output by the associated weight in [0, 1].
    case blend(Float)
}

// MARK: - Conversation State

/// Coarse conversational state hint forwarded through ``AnimationContext`` so layers can adapt behaviour.
public enum ProceduralConversationState: Sendable {
    /// No active interaction.
    case idle
    /// Listening to a user; layers may soften tracking.
    case listening
    /// Composing a response; layers may add look-away or hesitation cues.
    case thinking
    /// Currently speaking; layers may dampen blinks or boost mouth motion.
    case speaking
}

// MARK: - Bone Transform

/// Local TRS triplet describing a procedural bone delta applied on top of the base pose by ``AnimationLayerCompositor``.
public struct ProceduralBoneTransform: Sendable {
    /// Local rotation delta. Identity means "no change".
    public var rotation: simd_quatf
    /// Local translation delta added to the base pose.
    public var translation: SIMD3<Float>
    /// Local scale multiplier applied to the base pose (unit scale = no change).
    public var scale: SIMD3<Float>

    /// Identity transform: no rotation, zero translation, unit scale.
    public static let identity = ProceduralBoneTransform(
        rotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
        translation: .zero,
        scale: SIMD3<Float>(1, 1, 1)
    )

    /// Creates a transform from optional rotation, translation, and scale components.
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

/// Per-frame inputs forwarded to every ``AnimationLayer`` so layers can read shared scene state without coupling to a host renderer.
public struct AnimationContext: Sendable {
    /// Current accumulated time in seconds (used by time-driven layers like breathing).
    public var time: Float
    /// Time since the previous frame in seconds.
    public var deltaTime: Float
    /// World-space camera position; used by gaze layers to compute look direction.
    public var cameraPosition: SIMD3<Float>
    /// World-space avatar root position; layers use this to derive head/eye positions.
    public var avatarPosition: SIMD3<Float>
    /// Current conversational state (idle / listening / thinking / speaking).
    public var conversationState: ProceduralConversationState
    /// Optional sentiment preset that ``ExpressionLayer`` should drive toward this frame.
    public var sentimentPreset: VRMExpressionPreset?
    /// Target intensity for the sentiment preset, in [0, 1].
    public var sentimentIntensity: Float
    /// When `true`, ``ExpressionLayer`` may trigger flirty wink behaviours.
    public var isFlirty: Bool

    /// Creates a context with the given inputs. All parameters have neutral defaults so layers can be unit-tested without scene state.
    public init(
        time: Float = 0,
        deltaTime: Float = 0,
        cameraPosition: SIMD3<Float> = .zero,
        avatarPosition: SIMD3<Float> = .zero,
        conversationState: ProceduralConversationState = .idle,
        sentimentPreset: VRMExpressionPreset? = nil,
        sentimentIntensity: Float = 0,
        isFlirty: Bool = false
    ) {
        self.time = time
        self.deltaTime = deltaTime
        self.cameraPosition = cameraPosition
        self.avatarPosition = avatarPosition
        self.conversationState = conversationState
        self.sentimentPreset = sentimentPreset
        self.sentimentIntensity = sentimentIntensity
        self.isFlirty = isFlirty
    }
}

// MARK: - Layer Output

/// Sparse per-frame output from an ``AnimationLayer``: bone deltas, morph weights, and a blend mode for composition.
public struct LayerOutput: Sendable {
    /// Per-bone procedural deltas. Bones not present are not written by this layer.
    public var bones: [VRMHumanoidBone: ProceduralBoneTransform]
    /// Morph-weight contributions keyed by expression name. Always accumulated additively across layers.
    public var morphWeights: [String: Float]
    /// How this output combines with the running composite (see ``AnimationBlendMode``).
    public var blendMode: AnimationBlendMode

    /// Creates an output. Defaults produce an empty additive blend (no effect).
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

/// Composites multiple ``AnimationLayer`` outputs onto a captured base pose and applies the result to the model each frame.
///
/// ## Discussion
/// `AnimationLayerCompositor` runs layers in ascending ``AnimationLayer/priority``
/// order. Each layer's ``LayerOutput`` is folded into a running composite
/// according to its ``LayerOutput/blendMode``:
/// - ``AnimationBlendMode/replace`` overwrites the existing bone delta.
/// - ``AnimationBlendMode/additive`` multiplies rotation quaternions and
///   adds translation / scale.
/// - ``AnimationBlendMode/blend(_:)`` slerps rotation and lerps translation
///   and scale toward the new delta with the given weight; when no
///   composite exists yet the blend is performed against identity.
///
/// Morph weights are *always* accumulated additively across layers.
///
/// After all layers are composited, the result is composed onto the
/// captured base pose as `node.rotation = baseRotation * delta`,
/// `node.translation = baseTranslation + delta`, `node.scale = baseScale * delta`,
/// and world transforms are propagated from each root.
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

    /// Creates an empty compositor. Call ``setup(model:)`` before ``update(deltaTime:context:)``.
    public init() {}

    /// Binds the compositor to `model` and captures the model's current rotation, translation, and scale per humanoid bone as the base pose.
    ///
    /// Layer outputs are composited as deltas on top of this base pose, so
    /// disabling all layers returns the model to the pose it had at the
    /// moment of setup.
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

    /// Get the current composited morph weights (for debugging/inspection)
    public func getCompositedMorphs() -> [String: Float] {
        compositedMorphs
    }

    /// Get the composited rotation for a specific bone after all layers are evaluated
    public func getCompositedBoneRotation(_ bone: VRMHumanoidBone) -> simd_quatf? {
        compositedBones[bone]?.rotation
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
