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

// MARK: - Blend Shape Formula

/// Formula for computing VRM expression weight from ARKit blend shapes
///
/// Defines how one or more ARKit blend shapes map to a single VRM expression.
/// Formulas are data-driven and can be serialized for external configuration.
///
/// ## Examples
///
/// ```swift
/// // Direct 1:1 mapping
/// .direct(ARKitFaceBlendShapes.eyeBlinkLeft)
///
/// // Average of multiple shapes
/// .average([ARKitFaceBlendShapes.eyeBlinkLeft, ARKitFaceBlendShapes.eyeBlinkRight])
///
/// // Weighted combination
/// .weighted([
///     (ARKitFaceBlendShapes.jawOpen, 0.7),
///     (ARKitFaceBlendShapes.mouthFunnel, 0.3)
/// ])
///
/// // Custom function
/// .custom { shapes in
///     let left = shapes.weight(for: ARKitFaceBlendShapes.eyeBlinkLeft)
///     let right = shapes.weight(for: ARKitFaceBlendShapes.eyeBlinkRight)
///     return max(left, right)  // Use stronger blink
/// }
/// ```
public enum BlendShapeFormula: Sendable {
    /// Direct 1:1 mapping from single ARKit blend shape
    case direct(String)

    /// Average of multiple ARKit blend shapes
    case average([String])

    /// Maximum value among multiple shapes
    case max([String])

    /// Minimum value among multiple shapes
    case min([String])

    /// Weighted sum of blend shapes
    /// Format: [(blendShapeKey, weight), ...]
    case weighted([(String, Float)])

    /// Custom evaluation function
    /// Note: Cannot be serialized
    case custom(@Sendable (ARKitFaceBlendShapes) -> Float)

    /// Evaluate formula against blend shape data
    public func evaluate(_ blendShapes: ARKitFaceBlendShapes) -> Float {
        switch self {
        case .direct(let key):
            return blendShapes.weight(for: key)

        case .average(let keys):
            guard !keys.isEmpty else { return 0 }
            let sum = keys.reduce(0.0) { $0 + blendShapes.weight(for: $1) }
            return sum / Float(keys.count)

        case .max(let keys):
            return keys.map { blendShapes.weight(for: $0) }.max() ?? 0

        case .min(let keys):
            return keys.map { blendShapes.weight(for: $0) }.min() ?? 0

        case .weighted(let components):
            return components.reduce(0.0) { sum, component in
                let (key, weight) = component
                return sum + blendShapes.weight(for: key) * weight
            }

        case .custom(let evaluate):
            return evaluate(blendShapes)
        }
    }

    /// Clamp result to [0, 1] range
    func evaluateClamped(_ blendShapes: ARKitFaceBlendShapes) -> Float {
        let value = evaluate(blendShapes)
        return Swift.min(1.0, Swift.max(0.0, value))
    }
}

// MARK: - ARKit to VRM Mapper

/// Maps ARKit face blend shapes to VRM expression presets
///
/// Provides configurable mappings between ARKit's 52 blend shapes and VRM's
/// 18 expression presets. Mappings can be customized or loaded from external data.
///
/// ## Thread Safety
/// **Thread-safe for reading** after initialization. Create separate instances
/// for concurrent modification or protect with locks.
///
/// ## Usage
///
/// ```swift
/// // Use default mappings
/// let mapper = ARKitToVRMMapper.default
///
/// // Evaluate expressions
/// let blendShapes = ARKitFaceBlendShapes(...)
/// let weights = mapper.evaluate(blendShapes)
///
/// // weights[.blink] contains computed blink weight
/// // weights[.happy] contains computed happy weight
/// // etc.
///
/// // Custom mapping
/// var mapper = ARKitToVRMMapper.default
/// mapper.mappings[.happy] = .weighted([
///     (ARKitFaceBlendShapes.mouthSmileLeft, 0.5),
///     (ARKitFaceBlendShapes.mouthSmileRight, 0.5),
///     (ARKitFaceBlendShapes.cheekSquintLeft, 0.2),
///     (ARKitFaceBlendShapes.cheekSquintRight, 0.2)
/// ])
/// ```
public struct ARKitToVRMMapper: Sendable {
    /// Canonical VRM viseme preset keys that compete for the mouth opening.
    public static let visemePresets: [String] = ["aa", "ih", "ou", "ee", "oh"]

    /// Canonical VRM emotion preset keys that frequently include authored mouth shapes.
    public static let emotionPresets: [String] = ["happy", "angry", "sad", "relaxed", "surprised"]

    /// Mapping from VRM expression preset to blend shape formula
    public var mappings: [String: BlendShapeFormula]

    /// Swap every left/right expression pair (`lookLeft`/`lookRight`,
    /// `blinkLeft`/`blinkRight`) on evaluation.
    ///
    /// ARKit blend shapes are face-relative and VRM lateral presets name the
    /// model's own side, so the default (`false`) keeps laterality: the avatar
    /// stands in for the user, which is what a recording or a stream needs.
    /// Set `true` for a self-view where the user watches their avatar like a
    /// mirror, so a glance to the user's left appears on the same screen side.
    public var mirrorLateral: Bool = false

    /// Maximum combined activation budget for competing viseme / mouth-deforming presets.
    public var visemeBudget: Float = 1.0

    /// Per-expression mouth-overlap participation factor (`0` = does not deform mouth,
    /// `1` = full viseme-scale mouth deformation). Derived from the bound model's morph
    /// targets via ``configured(for:)`` or populated with conservative defaults.
    public var mouthOverlapWeights: [String: Float]

    /// Groups of preset expression keys that bind to the same `(meshIndex, morphIndex)`
    /// on a configured model, mapped to their relative bind weights.
    public var sharedBindGroups: [[String: Float]] = []

    /// Creates a mapper with an explicit dictionary of VRM-expression-key to ``BlendShapeFormula``.
    /// The default value `[:]` is useful when assembling mappings post-init via ``mappings``.
    public init(
        mappings: [String: BlendShapeFormula] = [:],
        mirrorLateral: Bool = false,
        visemeBudget: Float = 1.0,
        mouthOverlapWeights: [String: Float]? = nil,
        sharedBindGroups: [[String: Float]] = []
    ) {
        self.mappings = mappings
        self.mirrorLateral = mirrorLateral
        self.visemeBudget = visemeBudget
        if let mouthOverlapWeights {
            self.mouthOverlapWeights = mouthOverlapWeights
        } else {
            var defaults: [String: Float] = [:]
            for key in Self.visemePresets {
                defaults[key] = 1.0
            }
            self.mouthOverlapWeights = defaults
        }
        self.sharedBindGroups = sharedBindGroups
    }

    /// Returns a copy of this mapper tuned to `model`'s actual morph-target geometry and binds.
    ///
    /// Inspects the model's viseme morph targets to identify which vertices belong to the mouth
    /// and measures how strongly each non-viseme preset displaces those same vertices or shares
    /// morph-target binds. Emotions that do not move the mouth (for example, eye-only or brow-only
    /// expressions) receive an overlap weight of `0` and are never attenuated by jaw opening.
    public func configured(for model: VRMModel) -> ARKitToVRMMapper {
        var copy = self
        copy.mouthOverlapWeights = Self.mouthOverlapWeights(for: model)
        copy.sharedBindGroups = Self.sharedPresetBindGroups(for: model)
        return copy
    }

    /// Evaluate all mapped expressions from ARKit blend shapes
    /// Returns dictionary of VRM expression keys to weights [0-1]
    public func evaluate(_ blendShapes: ARKitFaceBlendShapes) -> [String: Float] {
        var result: [String: Float] = [:]
        for (vrmExpression, formula) in mappings {
            result[Self.outputKey(for: vrmExpression, mirrored: mirrorLateral)] = formula.evaluateClamped(blendShapes)
        }
        applyMouthAndSharedBindPolicy(&result)
        return result
    }

    /// Evaluate single expression
    public func evaluate(_ blendShapes: ARKitFaceBlendShapes, expression: String) -> Float {
        guard let formula = mappings[Self.outputKey(for: expression, mirrored: mirrorLateral)] else { return 0 }
        let participatesInGroupPolicy =
            Self.visemePresets.contains(expression)
            || (mouthOverlapWeights[expression] ?? 0) > 0
            || sharedBindGroups.contains(where: { ($0[expression] ?? 0) > 0 })
        if participatesInGroupPolicy {
            return evaluate(blendShapes)[expression] ?? 0
        }
        return formula.evaluateClamped(blendShapes)
    }

    private func applyMouthAndSharedBindPolicy(_ result: inout [String: Float]) {
        guard visemeBudget > 0 else { return }

        // 1. Bound the 5 competing vowel visemes (aa, ih, ou, ee, oh) to a convex combination.
        var visemeSum: Float = 0
        var activeVisemeCount = 0
        for key in Self.visemePresets {
            if let w = result[key], w > 1e-4 {
                visemeSum += w
                activeVisemeCount += 1
            }
        }
        if activeVisemeCount > 1 && visemeSum > visemeBudget {
            let scale = visemeBudget / visemeSum
            for key in Self.visemePresets {
                if let w = result[key], w > 0 {
                    result[key] = w * scale
                }
            }
        }

        // 2. Bound combined mouth displacement across active visemes and mouth-deforming emotions.
        // Single active expressions keep their full weight; only overlapping combinations scale.
        var activeMouthKeys: [String] = []
        var mouthLoad: Float = 0
        for (key, alpha) in mouthOverlapWeights where alpha > 1e-4 {
            if let w = result[key], w > 1e-4 {
                activeMouthKeys.append(key)
                mouthLoad += alpha * w
            }
        }
        if activeMouthKeys.count > 1 && mouthLoad > visemeBudget {
            let scale = visemeBudget / mouthLoad
            for key in activeMouthKeys {
                if let w = result[key] {
                    result[key] = w * scale
                }
            }
        }

        // 3. Bound presets that share an identical (meshIndex, morphIndex) morph target bind.
        for group in sharedBindGroups {
            var activeKeys: [String] = []
            var groupLoad: Float = 0
            for (key, factor) in group where factor > 1e-4 {
                if let w = result[key], w > 1e-4 {
                    activeKeys.append(key)
                    groupLoad += factor * w
                }
            }
            if activeKeys.count > 1 && groupLoad > 1.0 {
                let scale = 1.0 / groupLoad
                for key in activeKeys {
                    if let w = result[key] {
                        result[key] = w * scale
                    }
                }
            }
        }
    }

    // MARK: - Model-Aware Overlap Analysis

    private struct MorphBindKey: Hashable {
        let meshIndex: Int
        let morphIndex: Int
    }

    /// Computes per-preset mouth-overlap participation factors from `model`'s morph targets and binds.
    public static func mouthOverlapWeights(for model: VRMModel) -> [String: Float] {
        var overlap: [String: Float] = [:]
        for key in visemePresets {
            overlap[key] = 1.0
        }

        guard let expressions = model.expressions else {
            for key in emotionPresets {
                overlap[key] = 1.0
            }
            return overlap
        }

        let visemeEnums: [VRMExpressionPreset] = [.aa, .ih, .ou, .ee, .oh]
        let emotionEnums: [VRMExpressionPreset] = [.happy, .angry, .sad, .relaxed, .surprised]

        var visemeBindMaxWeight: [MorphBindKey: Float] = [:]
        for v in visemeEnums {
            guard let expr = expressions.preset[v] else { continue }
            for bind in expr.morphTargetBinds where abs(bind.weight) > 1e-5 {
                let key = MorphBindKey(meshIndex: bind.meshIndex, morphIndex: bind.index)
                visemeBindMaxWeight[key] = Swift.max(visemeBindMaxWeight[key] ?? 0, abs(bind.weight))
            }
        }

        // Identify mouth vertices per (meshIndex, primitiveIndex) from viseme morph deltas.
        struct PrimKey: Hashable {
            let meshIndex: Int
            let primIndex: Int
        }
        var mouthVerticesByPrim: [PrimKey: [Int]] = [:]
        for (meshIndex, mesh) in model.meshes.enumerated() {
            let visemeBindsForMesh = visemeEnums.flatMap { preset -> [VRMMorphTargetBind] in
                expressions.preset[preset]?.morphTargetBinds.filter { $0.meshIndex == meshIndex } ?? []
            }
            guard !visemeBindsForMesh.isEmpty else { continue }

            for (primIndex, prim) in mesh.primitives.enumerated() where !prim.morphTargets.isEmpty {
                var vertexSet = Set<Int>()
                for bind in visemeBindsForMesh {
                    guard bind.index >= 0, bind.index < prim.morphTargets.count,
                          let deltas = prim.morphTargets[bind.index].positionDeltas else { continue }
                    for (vi, delta) in deltas.enumerated() {
                        if simd_length_squared(delta * bind.weight) > 1e-8 {
                            vertexSet.insert(vi)
                        }
                    }
                }
                if !vertexSet.isEmpty {
                    mouthVerticesByPrim[PrimKey(meshIndex: meshIndex, primIndex: primIndex)] = vertexSet.sorted()
                }
            }
        }

        if !mouthVerticesByPrim.isEmpty {
            func peakMouthDisplacement(for expression: VRMExpression) -> Float {
                var maxDisp: Float = 0
                for (primKey, vertices) in mouthVerticesByPrim {
                    let binds = expression.morphTargetBinds.filter { $0.meshIndex == primKey.meshIndex && abs($0.weight) > 1e-5 }
                    guard !binds.isEmpty else { continue }
                    let prim = model.meshes[primKey.meshIndex].primitives[primKey.primIndex]
                    for vi in vertices {
                        var sumDelta = SIMD3<Float>.zero
                        for bind in binds {
                            guard bind.index >= 0, bind.index < prim.morphTargets.count,
                                  let deltas = prim.morphTargets[bind.index].positionDeltas,
                                  vi < deltas.count else { continue }
                            sumDelta += deltas[vi] * bind.weight
                        }
                        maxDisp = Swift.max(maxDisp, simd_length(sumDelta))
                    }
                }
                return maxDisp
            }

            var visemeDisps: [VRMExpressionPreset: Float] = [:]
            for v in visemeEnums {
                if let expr = expressions.preset[v] {
                    visemeDisps[v] = peakMouthDisplacement(for: expr)
                }
            }
            let aaDisp = visemeDisps[.aa] ?? 0
            let maxVisemeDisp = visemeDisps.values.max() ?? 0
            let refDisp = aaDisp > 1e-5 ? aaDisp : maxVisemeDisp

            if refDisp > 1e-5 {
                for emotion in emotionEnums {
                    guard let expr = expressions.preset[emotion], !expr.morphTargetBinds.isEmpty else {
                        overlap[emotion.rawValue] = 0
                        continue
                    }
                    let dispRatio = peakMouthDisplacement(for: expr) / refDisp
                    var sharedRatio: Float = 0
                    for bind in expr.morphTargetBinds {
                        let key = MorphBindKey(meshIndex: bind.meshIndex, morphIndex: bind.index)
                        if let vWeight = visemeBindMaxWeight[key], vWeight > 1e-5 {
                            sharedRatio = Swift.max(sharedRatio, abs(bind.weight) / vWeight)
                        }
                    }
                    overlap[emotion.rawValue] = Swift.max(dispRatio, sharedRatio)
                }
                return overlap
            }
        }

        // Fallback when morph target vertex deltas are not loaded on the model:
        // inspect morphTargetBinds for shared binds or non-empty mouth-unblocked binds.
        for emotion in emotionEnums {
            guard let expr = expressions.preset[emotion], !expr.morphTargetBinds.isEmpty else {
                overlap[emotion.rawValue] = 0
                continue
            }
            var sharedRatio: Float = 0
            for bind in expr.morphTargetBinds {
                let key = MorphBindKey(meshIndex: bind.meshIndex, morphIndex: bind.index)
                if let vWeight = visemeBindMaxWeight[key], vWeight > 1e-5 {
                    sharedRatio = Swift.max(sharedRatio, abs(bind.weight) / vWeight)
                }
            }
            if sharedRatio > 0 {
                overlap[emotion.rawValue] = sharedRatio
            } else if expr.overrideMouth == .none {
                overlap[emotion.rawValue] = 1.0
            } else {
                overlap[emotion.rawValue] = 0
            }
        }
        return overlap
    }

    /// Finds groups of preset expressions on `model` that bind to the same `(meshIndex, morphIndex)`.
    public static func sharedPresetBindGroups(for model: VRMModel) -> [[String: Float]] {
        guard let expressions = model.expressions else { return [] }
        var byTarget: [MorphBindKey: [String: Float]] = [:]
        for (preset, expr) in expressions.preset {
            for bind in expr.morphTargetBinds where abs(bind.weight) > 1e-5 {
                let key = MorphBindKey(meshIndex: bind.meshIndex, morphIndex: bind.index)
                let current = byTarget[key]?[preset.rawValue] ?? 0
                byTarget[key, default: [:]][preset.rawValue] = Swift.max(current, abs(bind.weight))
            }
        }
        var groups: [[String: Float]] = []
        for (_, contributors) in byTarget where contributors.count > 1 {
            guard let maxBind = contributors.values.max(), maxBind > 1e-5 else { continue }
            var normalized: [String: Float] = [:]
            for (exprKey, weight) in contributors {
                normalized[exprKey] = weight / maxBind
            }
            groups.append(normalized)
        }
        return groups
    }

    /// Lateral presets and their mirror partners. Swapping is an involution,
    /// so the same table maps an output key back to its source formula.
    private static let lateralPartners: [String: String] = [
        "lookLeft": "lookRight", "lookRight": "lookLeft",
        "blinkLeft": "blinkRight", "blinkRight": "blinkLeft",
    ]

    private static func outputKey(for expression: String, mirrored: Bool) -> String {
        guard mirrored, let partner = lateralPartners[expression] else { return expression }
        return partner
    }

    // MARK: - Default Mappings

    /// Default per-expression mouth-overlap weights for standard VRM avatars before a model is inspected.
    public static let defaultMouthOverlapWeights: [String: Float] = [
        "aa": 1.0, "ih": 1.0, "ou": 1.0, "ee": 1.0, "oh": 1.0,
        "happy": 1.0, "angry": 1.0, "sad": 1.0, "relaxed": 1.0, "surprised": 1.0,
    ]

    /// Default ARKit → VRM expression mappings
    ///
    /// Carefully tuned to provide good results for most VRM avatars.
    /// Based on VRM specification and common usage patterns.
    public static let `default` = ARKitToVRMMapper(
        mappings: [
            // Emotions
            "happy": .weighted([
                (ARKitFaceBlendShapes.mouthSmileLeft, Float(0.4)),
                (ARKitFaceBlendShapes.mouthSmileRight, Float(0.4)),
                (ARKitFaceBlendShapes.cheekSquintLeft, Float(0.1)),
                (ARKitFaceBlendShapes.cheekSquintRight, Float(0.1))
            ]),

            "angry": .weighted([
                (ARKitFaceBlendShapes.browDownLeft, Float(0.3)),
                (ARKitFaceBlendShapes.browDownRight, Float(0.3)),
                (ARKitFaceBlendShapes.mouthFrownLeft, Float(0.2)),
                (ARKitFaceBlendShapes.mouthFrownRight, Float(0.2))
            ]),

            "sad": .custom { shapes in
                let browInner = shapes.weight(for: ARKitFaceBlendShapes.browInnerUp)
                let eyeWide = (shapes.weight(for: ARKitFaceBlendShapes.eyeWideLeft) +
                               shapes.weight(for: ARKitFaceBlendShapes.eyeWideRight)) * 0.5
                let browDown = (shapes.weight(for: ARKitFaceBlendShapes.browDownLeft) +
                                shapes.weight(for: ARKitFaceBlendShapes.browDownRight)) * 0.5
                let frown = (shapes.weight(for: ARKitFaceBlendShapes.mouthFrownLeft) +
                             shapes.weight(for: ARKitFaceBlendShapes.mouthFrownRight)) * 0.3
                return Swift.min(1.0, browInner * 0.4 * (1.0 - eyeWide) + frown * (1.0 - browDown * 0.5))
            },

            "relaxed": .custom { shapes in
                // Relaxed = neutral with slight smile
                let smile = (shapes.weight(for: ARKitFaceBlendShapes.mouthSmileLeft) +
                            shapes.weight(for: ARKitFaceBlendShapes.mouthSmileRight)) * 0.3
                let open = shapes.weight(for: ARKitFaceBlendShapes.jawOpen)
                return Swift.min(1.0, smile * (1.0 - open))
            },

            "surprised": .weighted([
                (ARKitFaceBlendShapes.browInnerUp, Float(0.3)),
                (ARKitFaceBlendShapes.browOuterUpLeft, Float(0.15)),
                (ARKitFaceBlendShapes.browOuterUpRight, Float(0.15)),
                (ARKitFaceBlendShapes.eyeWideLeft, Float(0.2)),
                (ARKitFaceBlendShapes.eyeWideRight, Float(0.2))
            ]),

            // Visemes (vowel shapes)
            // Partitioned across jaw opening, lip rounding (funnel/pucker), and lip spread
            // (smile/stretch) so isolated jaw opening drives `aa` without simultaneously
            // activating `ih` and `oh`.
            "aa": .custom { shapes in
                let open = Swift.max(0, shapes.weight(for: ARKitFaceBlendShapes.jawOpen) -
                                        shapes.weight(for: ARKitFaceBlendShapes.mouthClose) * 0.5)
                let round = Swift.max(shapes.weight(for: ARKitFaceBlendShapes.mouthFunnel),
                                      shapes.weight(for: ARKitFaceBlendShapes.mouthPucker))
                return Swift.min(1.0, open * 0.8 * (1.0 - round * 0.6))
            },

            "ih": .custom { shapes in
                let open = Swift.max(0, shapes.weight(for: ARKitFaceBlendShapes.jawOpen) -
                                        shapes.weight(for: ARKitFaceBlendShapes.mouthClose) * 0.5)
                let smile = (shapes.weight(for: ARKitFaceBlendShapes.mouthSmileLeft) +
                             shapes.weight(for: ARKitFaceBlendShapes.mouthSmileRight)) * 0.5
                let stretch = (shapes.weight(for: ARKitFaceBlendShapes.mouthStretchLeft) +
                               shapes.weight(for: ARKitFaceBlendShapes.mouthStretchRight)) * 0.5
                return Swift.min(1.0, (stretch * 0.7 + smile * 0.35 * open) * (1.0 - open * 0.4))
            },

            "ou": .custom { shapes in
                let open = Swift.max(0, shapes.weight(for: ARKitFaceBlendShapes.jawOpen) -
                                        shapes.weight(for: ARKitFaceBlendShapes.mouthClose) * 0.5)
                let funnel = shapes.weight(for: ARKitFaceBlendShapes.mouthFunnel)
                let pucker = shapes.weight(for: ARKitFaceBlendShapes.mouthPucker)
                return Swift.min(1.0, (pucker * 0.6 + funnel * 0.4) * (1.0 - open * 0.5))
            },

            "ee": .custom { shapes in
                let open = Swift.max(0, shapes.weight(for: ARKitFaceBlendShapes.jawOpen) -
                                        shapes.weight(for: ARKitFaceBlendShapes.mouthClose) * 0.5)
                let smile = (shapes.weight(for: ARKitFaceBlendShapes.mouthSmileLeft) +
                             shapes.weight(for: ARKitFaceBlendShapes.mouthSmileRight)) * 0.5
                let stretch = (shapes.weight(for: ARKitFaceBlendShapes.mouthStretchLeft) +
                               shapes.weight(for: ARKitFaceBlendShapes.mouthStretchRight)) * 0.5
                return Swift.min(1.0, Swift.max(smile * 0.7, stretch * 0.8) * open)
            },

            "oh": .custom { shapes in
                let open = Swift.max(0, shapes.weight(for: ARKitFaceBlendShapes.jawOpen) -
                                        shapes.weight(for: ARKitFaceBlendShapes.mouthClose) * 0.5)
                let funnel = shapes.weight(for: ARKitFaceBlendShapes.mouthFunnel)
                return Swift.min(1.0, funnel * (0.4 + 0.6 * open))
            },

            // Blink
            "blink": .average([
                ARKitFaceBlendShapes.eyeBlinkLeft,
                ARKitFaceBlendShapes.eyeBlinkRight
            ]),

            "blinkLeft": .direct(ARKitFaceBlendShapes.eyeBlinkLeft),

            "blinkRight": .direct(ARKitFaceBlendShapes.eyeBlinkRight),

            // Eye gaze
            "lookUp": .average([
                ARKitFaceBlendShapes.eyeLookUpLeft,
                ARKitFaceBlendShapes.eyeLookUpRight
            ]),

            "lookDown": .average([
                ARKitFaceBlendShapes.eyeLookDownLeft,
                ARKitFaceBlendShapes.eyeLookDownRight
            ]),

            // ARKit names gaze by the eyelid it moves: a leftward gaze is
            // eyeLookOutLeft + eyeLookInRight (Apple ARFaceAnchor.BlendShapeLocation).
            // Laterality is kept, like the blinks above; see `mirrorLateral`.
            "lookLeft": .weighted([
                (ARKitFaceBlendShapes.eyeLookOutLeft, Float(0.5)),
                (ARKitFaceBlendShapes.eyeLookInRight, Float(0.5))
            ]),

            "lookRight": .weighted([
                (ARKitFaceBlendShapes.eyeLookInLeft, Float(0.5)),
                (ARKitFaceBlendShapes.eyeLookOutRight, Float(0.5))
            ]),

            // Neutral (default expression)
            "neutral": .custom { shapes in
                // Neutral = no strong expressions active
                let allWeights = ARKitFaceBlendShapes.allKeys.map { shapes.weight(for: $0) }
                let totalActivation = allWeights.reduce(0, +) / Float(allWeights.count)
                return Swift.max(0, 1.0 - totalActivation * 3.0)
            }
        ],
        mouthOverlapWeights: defaultMouthOverlapWeights
    )

    /// Simplified mappings (fewer dependencies, faster evaluation)
    public static let simplified = ARKitToVRMMapper(mappings: [
        "happy": .average([ARKitFaceBlendShapes.mouthSmileLeft, ARKitFaceBlendShapes.mouthSmileRight]),
        "angry": .average([ARKitFaceBlendShapes.browDownLeft, ARKitFaceBlendShapes.browDownRight]),
        "sad": .direct(ARKitFaceBlendShapes.browInnerUp),
        "surprised": .average([ARKitFaceBlendShapes.eyeWideLeft, ARKitFaceBlendShapes.eyeWideRight]),
        "aa": .direct(ARKitFaceBlendShapes.jawOpen),
        "ou": .direct(ARKitFaceBlendShapes.mouthFunnel),
        "blink": .average([ARKitFaceBlendShapes.eyeBlinkLeft, ARKitFaceBlendShapes.eyeBlinkRight]),
        "blinkLeft": .direct(ARKitFaceBlendShapes.eyeBlinkLeft),
        "blinkRight": .direct(ARKitFaceBlendShapes.eyeBlinkRight),
        "lookUp": .average([ARKitFaceBlendShapes.eyeLookUpLeft, ARKitFaceBlendShapes.eyeLookUpRight]),
        "lookDown": .average([ARKitFaceBlendShapes.eyeLookDownLeft, ARKitFaceBlendShapes.eyeLookDownRight])
    ])

    /// Aggressive mappings (stronger expression response)
    public static let aggressive = ARKitToVRMMapper(mappings: [
        "happy": .custom { shapes in
            let smile = (shapes.weight(for: ARKitFaceBlendShapes.mouthSmileLeft) +
                        shapes.weight(for: ARKitFaceBlendShapes.mouthSmileRight)) * 0.75
            return Swift.min(1.0, smile * 1.5)  // Amplify
        },
        "angry": .custom { shapes in
            let brow = (shapes.weight(for: ARKitFaceBlendShapes.browDownLeft) +
                       shapes.weight(for: ARKitFaceBlendShapes.browDownRight)) * 0.75
            return Swift.min(1.0, brow * 1.5)
        },
        "blink": .average([ARKitFaceBlendShapes.eyeBlinkLeft, ARKitFaceBlendShapes.eyeBlinkRight]),
        "blinkLeft": .direct(ARKitFaceBlendShapes.eyeBlinkLeft),
        "blinkRight": .direct(ARKitFaceBlendShapes.eyeBlinkRight)
    ])
}

// MARK: - Skeleton Mapper

/// Maps ARKit skeleton joints to VRM humanoid bones
///
/// Provides retargeting from ARKit's body tracking skeleton to VRM's humanoid rig.
/// Handles differences in joint hierarchies and coordinate systems.
public struct ARKitSkeletonMapper: Sendable {
    /// Mapping from ARKit joint to VRM humanoid bone
    public var jointMap: [ARKitJoint: String]

    /// Creates a mapper from an ARKit-joint to VRM-humanoid-bone-name dictionary.
    /// Pass `[:]` when building incrementally via ``jointMap``.
    public init(jointMap: [ARKitJoint: String] = [:]) {
        self.jointMap = jointMap
    }

    /// Get VRM bone name for ARKit joint
    public func vrmBone(for joint: ARKitJoint) -> String? {
        return jointMap[joint]
    }

    /// Check if joint is mapped
    public func isMapped(_ joint: ARKitJoint) -> Bool {
        return jointMap[joint] != nil
    }

    // MARK: - Default Mapping

    /// Default ARKit → VRM humanoid bone mapping
    ///
    /// Maps ARKit's skeleton to VRM's humanoid bones using standard naming.
    /// Some ARKit joints may not have direct VRM equivalents and are omitted.
    public static let `default` = ARKitSkeletonMapper(jointMap: [
        // Torso
        .hips: "hips",
        .spine: "spine",
        .chest: "chest",
        .upperChest: "upperChest",
        .neck: "neck",
        .head: "head",

        // Left arm
        .leftShoulder: "leftShoulder",
        .leftUpperArm: "leftUpperArm",
        .leftLowerArm: "leftLowerArm",
        .leftHand: "leftHand",

        // Right arm
        .rightShoulder: "rightShoulder",
        .rightUpperArm: "rightUpperArm",
        .rightLowerArm: "rightLowerArm",
        .rightHand: "rightHand",

        // Left leg
        .leftUpperLeg: "leftUpperLeg",
        .leftLowerLeg: "leftLowerLeg",
        .leftFoot: "leftFoot",
        .leftToes: "leftToes",

        // Right leg
        .rightUpperLeg: "rightUpperLeg",
        .rightLowerLeg: "rightLowerLeg",
        .rightFoot: "rightFoot",
        .rightToes: "rightToes",

        // Fingers - left hand
        .leftHandThumb1: "leftThumbProximal",
        .leftHandThumb2: "leftThumbIntermediate",
        .leftHandThumb3: "leftThumbDistal",

        .leftHandIndex1: "leftIndexProximal",
        .leftHandIndex2: "leftIndexIntermediate",
        .leftHandIndex3: "leftIndexDistal",

        .leftHandMiddle1: "leftMiddleProximal",
        .leftHandMiddle2: "leftMiddleIntermediate",
        .leftHandMiddle3: "leftMiddleDistal",

        .leftHandRing1: "leftRingProximal",
        .leftHandRing2: "leftRingIntermediate",
        .leftHandRing3: "leftRingDistal",

        .leftHandPinky1: "leftLittleProximal",
        .leftHandPinky2: "leftLittleIntermediate",
        .leftHandPinky3: "leftLittleDistal",

        // Fingers - right hand
        .rightHandThumb1: "rightThumbProximal",
        .rightHandThumb2: "rightThumbIntermediate",
        .rightHandThumb3: "rightThumbDistal",

        .rightHandIndex1: "rightIndexProximal",
        .rightHandIndex2: "rightIndexIntermediate",
        .rightHandIndex3: "rightIndexDistal",

        .rightHandMiddle1: "rightMiddleProximal",
        .rightHandMiddle2: "rightMiddleIntermediate",
        .rightHandMiddle3: "rightMiddleDistal",

        .rightHandRing1: "rightRingProximal",
        .rightHandRing2: "rightRingIntermediate",
        .rightHandRing3: "rightRingDistal",

        .rightHandPinky1: "rightLittleProximal",
        .rightHandPinky2: "rightLittleIntermediate",
        .rightHandPinky3: "rightLittleDistal"
    ])

    /// Upper body only mapping (for desk/seated scenarios)
    public static let upperBodyOnly = ARKitSkeletonMapper(jointMap: [
        .hips: "hips",
        .spine: "spine",
        .chest: "chest",
        .upperChest: "upperChest",
        .neck: "neck",
        .head: "head",
        .leftShoulder: "leftShoulder",
        .leftUpperArm: "leftUpperArm",
        .leftLowerArm: "leftLowerArm",
        .leftHand: "leftHand",
        .rightShoulder: "rightShoulder",
        .rightUpperArm: "rightUpperArm",
        .rightLowerArm: "rightLowerArm",
        .rightHand: "rightHand"
    ])

    /// Core bones only (minimal tracking)
    public static let coreOnly = ARKitSkeletonMapper(jointMap: [
        .hips: "hips",
        .spine: "spine",
        .chest: "chest",
        .neck: "neck",
        .head: "head",
        .leftUpperArm: "leftUpperArm",
        .leftLowerArm: "leftLowerArm",
        .leftHand: "leftHand",
        .rightUpperArm: "rightUpperArm",
        .rightLowerArm: "rightLowerArm",
        .rightHand: "rightHand",
        .leftUpperLeg: "leftUpperLeg",
        .leftLowerLeg: "leftLowerLeg",
        .leftFoot: "leftFoot",
        .rightUpperLeg: "rightUpperLeg",
        .rightLowerLeg: "rightLowerLeg",
        .rightFoot: "rightFoot"
    ])
}
