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

private enum Interpolation: String {
    case linear = "LINEAR"
    case step = "STEP"
    case cubicSpline = "CUBICSPLINE"

    init(_ raw: String?) {
        if let raw, let value = Interpolation(rawValue: raw.uppercased()) {
            self = value
        } else {
            self = .linear
        }
    }

    var description: String { rawValue }
}

private struct KeyTrack {
    let times: [Float]
    let values: [Float]
    let path: String
    let interpolation: Interpolation
    let componentCount: Int
}

/// Loads VRMC_vrm_animation-1.0 (`.vrma`) clips and retargets their tracks onto a target ``VRMModel``.
///
/// ## Discussion
/// `VRMAnimationLoader` is the retargeting nerve centre. VRMA files store
/// animation in their own skeleton's rest pose, which is typically *not* the
/// rest pose of the avatar the animation is being applied to. The loader
/// resolves this by producing per-frame closures that bake the retargeting
/// math at load time, so playback (via ``AnimationPlayer``) only has to
/// sample and write.
///
/// ### Rest-pose retargeting formula
/// Animation rest pose and model rest pose are treated as two independent,
/// immutable sources of truth — neither is inferred from the other. For
/// every humanoid bone, the loader emits a rotation closure of the form:
///
/// ```text
/// delta  = inverse(animationRestRotation) * animationRotation
/// result = modelRestRotation * delta
/// ```
///
/// This works whether the two rest poses are identical (delta collapses to
/// `animationRotation` and `result = modelRest * animationRotation`) or
/// different (T-pose model receiving an A-pose animation, etc.). When the
/// model rest is unavailable (non-humanoid nodes, model-less load), the
/// closure passes the animation rotation through directly.
///
/// Translation deltas use the additive form
/// `result = modelRest + (animTranslation - animRest)` and are emitted only
/// for the `Hips` bone per the VRMC_vrm_animation spec.
///
/// ### Bone mapping precedence
/// Humanoid node-to-bone mapping is resolved in this order:
/// 1. The VRMC_vrm_animation extension's `humanoid.humanBones` table on the
///    animation file (per-spec source of truth).
/// 2. The model's `humanoid.getBoneNode` table matched by normalised name
///    (lowercased, alphanumeric-only).
/// 3. A relaxed substring match against the model's normalised name table.
/// 4. A heuristic that recognises both VRM 1.0 (`leftUpperArm`) and Unity /
///    VRM 0.0 (`J_Bip_L_UpperArm`) naming.
///
/// Nodes that resolve to no humanoid bone are emitted as ``NodeTrack``
/// entries (hair, bust, accessories).
///
/// ### VRM 0.0 coordinate conversion
/// VRMA files use VRM 1.0 (glTF right-handed) coordinates. When the target
/// model is VRM 0.0 (Unity left-handed), every sampled rotation and
/// translation has its X and Z components negated before retargeting. This
/// matches the conversion done by `three-vrm`'s `createVRMAnimationClip.ts`.
///
/// ### Spec-mandated skips
/// The loader silently drops tracks that the spec forbids:
/// - Rotation/translation/scale on `leftEye` / `rightEye` (gaze is driven
///   by ``VRMLookAtController`` or the lookAt block).
/// - The `lookUp` / `lookDown` / `lookLeft` / `lookRight` expression
///   presets.
/// - Translation tracks on humanoid bones other than `Hips`.
/// - Scale tracks on any humanoid bone.
///
/// ### See Also
/// - <doc:AnimationAndRetargeting>
/// - <doc:MigratingFromVRM0>
public enum VRMAnimationLoader {
    /// Loads a `.vrma` GLB file from `url` and returns an ``AnimationClip`` retargeted to `model`.
    ///
    /// Uses the first animation in the file. Duration is the max input time
    /// across all samplers, falling back to `1.0` when no samplers carry
    /// time data. The resulting clip's closures embed coordinate conversion
    /// and rest-pose retargeting per the formulas described in the
    /// type-level Discussion.
    ///
    /// When `model` is `nil`, only the animation's own rest pose is used
    /// (no model-side retargeting); bone resolution falls back to the
    /// animation's VRMC_vrm_animation humanoid mapping if present.
    ///
    /// - Parameters:
    ///   - url: Local file URL to the `.vrma` GLB.
    ///   - model: Optional target ``VRMModel`` whose rest pose drives
    ///     retargeting. VRM 0.0 → 1.0 coordinate conversion is applied at
    ///     model load time (see ``VRMModel/buildNodeHierarchy()``), so VRMA
    ///     samplers can apply directly without per-format conversion.
    /// - Returns: An ``AnimationClip`` with retargeted samplers populated.
    /// - Throws: An `NSError` (domain `"VRMAnimationLoader"`) when the file
    ///   contains no animations, or any error thrown by ``GLTFParser`` /
    ///   ``BufferLoader`` during parsing.
    public static func loadVRMA(from url: URL, model: VRMModel? = nil) throws -> AnimationClip {
        let data = try Data(contentsOf: url)

        let parser = GLTFParser()
        let (document, binary) = try parser.parse(data: data)
        let buffer = BufferLoader(document: document, binaryData: binary, baseURL: url.deletingLastPathComponent())

        guard let animations = document.animations, !animations.isEmpty else {
            throw NSError(domain: "VRMAnimationLoader", code: 400, userInfo: [NSLocalizedDescriptionKey: "No animations in VRMA"])
        }

        // Use first animation for now
        let anim = animations[0]

        // Determine duration as the max of input time tracks
        var duration: Float = 0
        for sampler in anim.samplers {
            let times = try buffer.loadAccessorAsFloat(sampler.input)
            if let last = times.last { duration = max(duration, last) }
        }
        if duration <= 0 { duration = 1.0 }

        var clip = AnimationClip(duration: duration)

        // Build tracks grouped by node and path
        var nodeTracks: [Int: [String: KeyTrack]] = [:]

        for channel in anim.channels {
            guard channel.sampler < anim.samplers.count else { continue }
            let sampler = anim.samplers[channel.sampler]

            let times = try buffer.loadAccessorAsFloat(sampler.input)
            let values = try buffer.loadAccessorAsFloat(sampler.output)
            let path = channel.target.path // "rotation", "translation", "scale", or morph weights (ignored)
            guard let nodeIndex = channel.target.node else { continue }

            let interpolation = Interpolation(sampler.interpolation)
            guard let componentCount = componentCount(for: path) else { continue }

            var tracksForNode = nodeTracks[nodeIndex] ?? [:]
            tracksForNode[path] = KeyTrack(times: times,
                                           values: values,
                                           path: path,
                                           interpolation: interpolation,
                                           componentCount: componentCount)
            nodeTracks[nodeIndex] = tracksForNode
        }

        let animationRestTransforms = buildAnimationRestTransforms(document: document)
        let modelRestTransforms = buildModelRestTransforms(model: model)

        // VRM 0.0 → 1.0 coordinate conversion is now applied at model load time
        // (see VRMModel.buildNodeHierarchy), so animation data can be applied
        // directly without per-format conversion.

        // Map animation node indices to humanoid bones using the VRMA extension data first.
        let animationNodeToBone: [Int: VRMHumanoidBone] = {
            guard
                let extensionDict = document.extensions?["VRMC_vrm_animation"] as? [String: Any],
                let humanoid = extensionDict["humanoid"] as? [String: Any],
                let humanBones = humanoid["humanBones"] as? [String: Any]
            else {
                return [:]
            }

            var map: [Int: VRMHumanoidBone] = [:]
            for (boneName, value) in humanBones {
                guard let bone = VRMHumanoidBone(rawValue: boneName) else { continue }
                // Spec (VRMC_vrm_animation-1.0): leftEye and rightEye must not have animation data.
                if bone == .leftEye || bone == .rightEye {
                    #if VRM_METALKIT_ENABLE_LOGS
                    vrmLogLoader("[VRMAnimationLoader] Skipping eye bone '\(boneName)' per VRMC_vrm_animation spec")
                    #endif
                    continue
                }

                if let boneDict = value as? [String: Any],
                   let nodeAny = boneDict["node"],
                   let nodeIndex = intValue(from: nodeAny) {
                    map[nodeIndex] = bone
                }
            }
            return map
        }()

        // Map expression names to their node indices from VRMC_vrm_animation extension
        let animationExpressionNodes: [String: Int] = {
            guard
                let extensionDict = document.extensions?["VRMC_vrm_animation"] as? [String: Any],
                let expressions = extensionDict["expressions"] as? [String: Any]
            else {
                return [:]
            }

            var map: [String: Int] = [:]

            // Spec (VRMC_vrm_animation-1.0): gaze presets must not have animation data.
            let gazePresets: Set<String> = ["lookUp", "lookDown", "lookLeft", "lookRight"]

            // Parse preset expressions
            if let preset = expressions["preset"] as? [String: Any] {
                for (expressionName, value) in preset {
                    if gazePresets.contains(expressionName) {
                        #if VRM_METALKIT_ENABLE_LOGS
                        vrmLogLoader("[VRMAnimationLoader] Skipping gaze preset '\(expressionName)' per VRMC_vrm_animation spec")
                        #endif
                        continue
                    }
                    if let expressionDict = value as? [String: Any],
                       let nodeAny = expressionDict["node"],
                       let nodeIndex = intValue(from: nodeAny) {
                        map[expressionName] = nodeIndex
                    }
                }
            }

            // Parse custom expressions
            if let custom = expressions["custom"] as? [String: Any] {
                for (expressionName, value) in custom {
                    if let expressionDict = value as? [String: Any],
                       let nodeAny = expressionDict["node"],
                       let nodeIndex = intValue(from: nodeAny) {
                        map[expressionName] = nodeIndex
                    }
                }
            }

            return map
        }()

        // Map VRMA node names to bones using the target model's humanoid mapping when extension data isn't available.
        let modelNameToBone: [String: VRMHumanoidBone] = {
            guard let model, let humanoid = model.humanoid else { return [:] }
            var map: [String: VRMHumanoidBone] = [:]
            for bone in VRMHumanoidBone.allCases {
                // Spec (VRMC_vrm_animation-1.0): leftEye and rightEye must not have animation data.
                if bone == .leftEye || bone == .rightEye { continue }
                if let nodeIndex = humanoid.getBoneNode(bone),
                   nodeIndex < model.nodes.count,
                   let nodeName = model.nodes[nodeIndex].name {
                    map[normalize(nodeName)] = bone
                }
            }
            return map
        }()

        // Fallback heuristic if model mapping is missing
        // Supports both VRM 1.0 naming (leftUpperArm) and Unity/VRM 0.0 naming (J_Bip_L_UpperArm)
        let heuristicNameToBone: (String) -> VRMHumanoidBone? = { name in
            let n = name.lowercased()
            
            // Detect side indicators:
            // - Unity style: "_L_" or "_R_" (e.g., J_Bip_L_UpperArm)
            // - VRM 1.0 style: "left" or "right" (e.g., leftUpperArm)
            let isLeft = n.contains("_l_") || n.contains("left")
            let isRight = n.contains("_r_") || n.contains("right")
            
            // Torso (no side)
            if n.contains("hips") { return .hips }
            if n.contains("upperchest") || (n.contains("upper") && n.contains("chest")) { return .upperChest }
            if n.contains("chest") { return .chest }
            if n.contains("spine") { return .spine }
            if n.contains("neck") { return .neck }
            if n.contains("head") { return .head }
            
            // Left side bones
            if isLeft {
                if n.contains("upperarm") { return .leftUpperArm }
                if n.contains("lowerarm") { return .leftLowerArm }
                if n.contains("hand") && !n.contains("arm") { return .leftHand }
                if n.contains("shoulder") { return .leftShoulder }
                if n.contains("upperleg") { return .leftUpperLeg }
                if n.contains("lowerleg") { return .leftLowerLeg }
                if n.contains("foot") { return .leftFoot }
                if n.contains("toe") { return .leftToes }
            }
            
            // Right side bones
            if isRight {
                if n.contains("upperarm") { return .rightUpperArm }
                if n.contains("lowerarm") { return .rightLowerArm }
                if n.contains("hand") && !n.contains("arm") { return .rightHand }
                if n.contains("shoulder") { return .rightShoulder }
                if n.contains("upperleg") { return .rightUpperLeg }
                if n.contains("lowerleg") { return .rightLowerLeg }
                if n.contains("foot") { return .rightFoot }
                if n.contains("toe") { return .rightToes }
            }
            
            return nil
        }

        // Build JointTracks by sampling functions
        #if DEBUG
        var debugLoggedBones: Set<VRMHumanoidBone> = []
        #endif

        for (nodeIndex, tracks) in nodeTracks {
            // Resolve node name and retarget to model's humanoid bones
            let nodeName = document.nodes?[safe: nodeIndex]?.name ?? ""
            let norm = normalize(nodeName)
            let bone: VRMHumanoidBone?
            if let mappedBone = animationNodeToBone[nodeIndex] {
                bone = mappedBone
            } else if let b = modelNameToBone[norm] {
                bone = b
            } else {
                // Try relaxed matching against model map
                if let (_, mappedBone) = modelNameToBone.first(where: { key, _ in key.contains(norm) || norm.contains(key) }) {
                    bone = mappedBone
                } else {
                    bone = heuristicNameToBone(nodeName)
                }
            }

            // If this node doesn't map to a humanoid bone, treat it as a non-humanoid node
            // (hair, bust, accessories, etc.)
            if let boneUnwrapped = bone {
                // HUMANOID BONE TRACK
                #if DEBUG
                if debugLoggedBones.insert(boneUnwrapped).inserted {
                    vrmLogLoader("[VRMAnimationLoader] Retargeted node \(nodeName) -> bone \(boneUnwrapped)")
                }
                #endif
                processHumanoidTrack(bone: boneUnwrapped, nodeName: nodeName, tracks: tracks,
                                    animationRestTransforms: animationRestTransforms,
                                    modelRestTransforms: modelRestTransforms,
                                    nodeIndex: nodeIndex,
                                    clip: &clip)
            } else {
                // NON-HUMANOID NODE TRACK (hair, bust, accessories)
                processNonHumanoidTrack(nodeName: nodeName, tracks: tracks,
                                       animationRestTransforms: animationRestTransforms,
                                       nodeIndex: nodeIndex,
                                       clip: &clip)
            }
        }

        // Process expression tracks from VRMC_vrm_animation extension
        for (expressionName, nodeIndex) in animationExpressionNodes {
            guard let tracks = nodeTracks[nodeIndex],
                  let translationTrack = tracks["translation"] else {
                continue
            }

            let sampler = makeExpressionWeightSampler(track: translationTrack)
            
            // Add as both morph track (for backward compatibility) and expression track
            clip.addMorphTrack(key: expressionName, sample: sampler)
            
            // Also add to expression tracks if it's a known preset
            if let preset = VRMExpressionPreset(rawValue: expressionName) {
                let expressionTrack = ExpressionTrack(expression: preset, sampler: sampler)
                clip.addExpressionTrack(expressionTrack)
            }

            #if DEBUG
            vrmLogLoader("[VRMAnimationLoader] Added expression track '\(expressionName)' from node \(nodeIndex)")
            #endif
        }

        // B1: Parse lookAt block from VRMC_vrm_animation extension.
        // Two encodings appear in the wild:
        //   1) translation track on the lookAt node — the spec-literal
        //      reading ("difference between the head position and the
        //      position of the node specified by `node`") of
        //      VRMC_vrm_animation-1.0 §lookAt.
        //   2) rotation track on the lookAt node — what
        //      `@pixiv/three-vrm-animation` and Pixiv's distributed VRMA
        //      samples use, applying the rotation to a head-local forward
        //      (-Z) to derive the gaze direction. Any loader claiming VRMA
        //      support needs to accept this encoding too (VMK#286).
        //
        // Distance for the head-local target is 1.0 by convention because
        // VRMLookAtController normalises the direction internally; only the
        // direction matters for the eventual yaw/pitch.
        if let extensionDict = document.extensions?["VRMC_vrm_animation"] as? [String: Any],
           let lookAtBlock = extensionDict["lookAt"] as? [String: Any],
           let lookAtNodeAny = lookAtBlock["node"],
           let lookAtNodeIndex = intValue(from: lookAtNodeAny),
           let lookAtTracks = nodeTracks[lookAtNodeIndex] {
            if let translationTrack = lookAtTracks["translation"] {
                clip.lookAtTargetSampler = { t in sampleVector3(translationTrack, at: t) }
            } else if let rotationTrack = lookAtTracks["rotation"] {
                clip.lookAtTargetSampler = { t in
                    let q = sampleQuaternion(rotationTrack, at: t)
                    return q.act(SIMD3<Float>(0, 0, -1))
                }
            }
            #if VRM_METALKIT_ENABLE_LOGS
            vrmLogLoader("[VRMAnimationLoader] Parsed lookAt block -> node \(lookAtNodeIndex)")
            #endif
        }

        return clip
    }

    // MARK: - Humanoid Track Processing

    private static func processHumanoidTrack(
        bone: VRMHumanoidBone,
        nodeName: String,
        tracks: [String: KeyTrack],
        animationRestTransforms: [Int: RestTransform],
        modelRestTransforms: [VRMHumanoidBone: RestTransform],
        nodeIndex: Int,
        clip: inout AnimationClip
    ) {
        // Prepare samplers
        let animationRest = animationRestTransforms[nodeIndex] ?? RestTransform.identity
        let modelRest = modelRestTransforms[bone]

        // VRMA HUMANOID BONE RETARGETING POLICY (Normalized Rig Approach):
        //
        // VRM 0.0 → 1.0 coordinate conversion is applied at model load time
        // (see VRMModel.buildNodeHierarchy), so animation and model rest poses
        // are already in the same space.
        //
        // Formula: delta = inverse(animationRest) * animRotation
        //          result = modelRest * delta

        // Use animation rest pose from node hierarchy (NOT from animation keyframes)
        // Rest pose and animation data are separate sources of truth:
        // - animationRest: the skeleton's bind pose from VRMA node transforms
        // - tracks: the actual animation data (rotations relative to bind pose)
        let rotationRest = animationRest.rotation
        let translationRest = animationRest.translation

        // Validate rest pose mismatch for debugging
        if let modelRest = modelRest {
            // Calculate angle between quaternions using dot product
            let dot = abs(simd_dot(rotationRest, modelRest.rotation))
            let rotationDiff = acos(min(1.0, dot)) * 2.0  // Angle in radians
            if rotationDiff > 0.1 {  // ~5.7 degrees
                vrmLogAnimation("[VRMA Retargeting] Bone \(bone): rest pose mismatch detected")
                vrmLogAnimation("  Animation rest rotation: \(rotationRest)")
                vrmLogAnimation("  Model rest rotation: \(modelRest.rotation)")
                vrmLogAnimation("  Angle difference: \(String(format: "%.2f", rotationDiff * 180.0 / .pi))°")
                vrmLogAnimation("  → Retargeting will be applied")
            }
        }

        var rotationSampler: ((Float) -> simd_quatf)? = nil
        if let rot = tracks["rotation"] {
            rotationSampler = makeRotationSampler(track: rot,
                                                  animationRestRotation: rotationRest,
                                                  animationRestWorldRotation: animationRest.worldRotation,
                                                  modelRestRotation: modelRest?.rotation,
                                                  modelRestWorldRotation: modelRest?.worldRotation)
        }

        var translationSampler: ((Float) -> simd_float3)? = nil
        if let trans = tracks["translation"] {
            if bone == .hips {
                translationSampler = makeTranslationSampler(track: trans,
                                                            animationRestTranslation: translationRest,
                                                            modelRestTranslation: modelRest?.translation)
            } else {
                // Spec (VRMC_vrm_animation-1.0): only Hips may carry a translation track.
                #if VRM_METALKIT_ENABLE_LOGS
                vrmLogLoader("[VRMAnimationLoader] Ignoring translation track on non-hips bone '\(bone)' per VRMC_vrm_animation spec")
                #endif
            }
        }

        let scaleSampler: ((Float) -> simd_float3)? = nil
        if tracks["scale"] != nil {
            // Spec (VRMC_vrm_animation-1.0): humanoid bones must not include scale animation.
            #if VRM_METALKIT_ENABLE_LOGS
            vrmLogLoader("[VRMAnimationLoader] Ignoring scale track on humanoid bone '\(bone)' per VRMC_vrm_animation spec")
            #endif
        }

        #if DEBUG
        if debugBonesToLog.contains(bone) {
            vrmLogLoader("[VRMAnimationLoader] node \(nodeIndex) (\(nodeName)) → \(bone)")
            if rotationSampler != nil {
                vrmLogLoader("  rotation sampler ready (interpolation: \(tracks["rotation"]?.interpolation.description ?? "none"))")
            }
            if translationSampler != nil {
                vrmLogLoader("  translation sampler ready (interpolation: \(tracks["translation"]?.interpolation.description ?? "none"))")
            }
        }
        #endif

        let jointTrack = JointTrack(
            bone: bone,
            rotationSampler: rotationSampler,
            translationSampler: translationSampler,
            scaleSampler: scaleSampler
        )
        clip.addJointTrack(jointTrack)
    }

    // MARK: - Non-Humanoid Track Processing

    private static func processNonHumanoidTrack(
        nodeName: String,
        tracks: [String: KeyTrack],
        animationRestTransforms: [Int: RestTransform],
        nodeIndex: Int,
        clip: inout AnimationClip
    ) {
        // For non-humanoid nodes, we don't do rest-pose retargeting.
        // VRM 0.0 → 1.0 conversion is already applied at model load time.
        let animationRest = animationRestTransforms[nodeIndex] ?? RestTransform.identity

        // Use animation rest pose from node hierarchy (NOT from animation keyframes)
        let rotationRest = animationRest.rotation
        let translationRest = animationRest.translation
        let scaleRest = animationRest.scale

        var rotationSampler: ((Float) -> simd_quatf)? = nil
        if let rot = tracks["rotation"] {
            // No model rest for non-humanoid - use animation data directly
            rotationSampler = makeRotationSampler(track: rot,
                                                  animationRestRotation: rotationRest,
                                                  animationRestWorldRotation: animationRest.worldRotation,
                                                  modelRestRotation: nil,
                                                  modelRestWorldRotation: nil)
        }

        var translationSampler: ((Float) -> simd_float3)? = nil
        if let trans = tracks["translation"] {
            translationSampler = makeTranslationSampler(track: trans,
                                                        animationRestTranslation: translationRest,
                                                        modelRestTranslation: nil)
        }

        var scaleSampler: ((Float) -> simd_float3)? = nil
        if let scl = tracks["scale"] {
            scaleSampler = makeScaleSampler(track: scl,
                                            animationRestScale: scaleRest,
                                            modelRestScale: nil)
        }

        #if DEBUG
        // Log first few non-humanoid nodes for debugging
        if nodeIndex < 5 || nodeName.contains("Hair") || nodeName.contains("Bust") {
            vrmLogLoader("[VRMAnimationLoader] NON-HUMANOID node \(nodeIndex) (\(nodeName))")
        }
        #endif

        let nodeTrack = NodeTrack(
            nodeName: nodeName,
            rotationSampler: rotationSampler,
            translationSampler: translationSampler,
            scaleSampler: scaleSampler
        )
        clip.addNodeTrack(nodeTrack)
    }

}

// MARK: - Helpers

private func mix(_ a: SIMD3<Float>, _ b: SIMD3<Float>, t: Float) -> SIMD3<Float> {
    return a + (b - a) * t
}

private func normalize(_ name: String) -> String {
    // Lowercase and strip non-alphanumerics to make matching resilient across pipelines
    let lower = name.lowercased()
    let filtered = lower.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
    return String(String.UnicodeScalarView(filtered))
}

private func intValue(from any: Any) -> Int? {
    if let int = any as? Int {
        return int
    }
    if let double = any as? Double {
        return Int(double)
    }
    if let string = any as? String, let int = Int(string) {
        return int
    }
    return nil
}

#if DEBUG
private let debugBonesToLog: Set<VRMHumanoidBone> = [
    .hips, .spine, .chest, .upperChest, .neck, .head,
    .leftUpperArm, .leftLowerArm, .rightUpperArm, .rightLowerArm
]
#endif

private func componentCount(for path: String) -> Int? {
    switch path {
    case "rotation": return 4
    case "translation", "scale": return 3
    default: return nil
    }
}

// Rotation Retargeting (Delta-Based)
//
// VRM ANIMATION SPEC:
// ------------------
// VRMA animations target humanoid bones identified by extension data.
// Retargeting transforms animation from animation's rest space to model's rest space.
//
// Spec: https://github.com/vrm-c/vrm-specification/blob/master/specification/VRMC_vrm_animation-1.0/
//
// Formula (per VRMC_node_constraint-1.0):
//   delta = inverse(animationRestRotation) * animationRotation
//   result = modelRestRotation * delta
//
// This works for all cases:
// - Identical rest poses: delta = animRotation, result = modelRest * animRotation
// - Different rest poses: delta transforms animation to model's coordinate frame
//
private func makeRotationSampler(track: KeyTrack,
                                 animationRestRotation: simd_quatf,
                                 animationRestWorldRotation: simd_quatf,
                                 modelRestRotation: simd_quatf?,
                                 modelRestWorldRotation: simd_quatf?) -> ((Float) -> simd_quatf)? {
    let L_A = simd_normalize(animationRestRotation)
    let W_A = simd_normalize(animationRestWorldRotation)

    // Non-humanoid tracks pass nil for model rest — there's no model-
    // side bone to normalise against, so the animation rotation flows
    // through unchanged.
    guard let modelRest = modelRestRotation,
          let modelWorld = modelRestWorldRotation else {
        return { t in sampleQuaternion(track, at: t) }
    }
    let L_B = simd_normalize(modelRest)
    let W_B = simd_normalize(modelWorld)

    // VRM 1.0 pose-normalisation (`how_to_transform_human_pose.md`):
    //
    //   Normalized       = W_A · L_A⁻¹ · A.LocalRotation · W_A⁻¹
    //   B.LocalRotation  = L_B · W_B⁻¹ · Normalized · W_B
    //
    // Combined: B = L_B · W_B⁻¹ · W_A · L_A⁻¹ · A · W_A⁻¹ · W_B
    //
    // For two rigs that share the same world-rest orientation
    // (`W_A == W_B`), the W terms cancel and the formula collapses to
    // `B = L_B · L_A⁻¹ · A` — the previous "delta retargeting" formula.
    // For VRMAs authored on a different rest pose (e.g. arms-forward
    // when the model is T-pose) the W terms perform the change-of-
    // basis that aligns the animation's world frame with the model's.
    // VMK#269 was the regression where the W terms were missing.
    let invL_A = simd_inverse(L_A)
    let invW_A = simd_inverse(W_A)
    let invW_B = simd_inverse(W_B)
    return { t in
        let A = sampleQuaternion(track, at: t)
        let normalized = simd_normalize(W_A * invL_A * A * invW_A)
        let result = simd_normalize(L_B * invW_B * normalized * W_B)
        return result
    }
}

// Translation Retargeting with Delta-Based Alignment
//
// ROOT MOTION POLICY:
// -------------------
// Translation deltas (including hips XYZ) are applied in LOCAL humanoid space.
// This means hips translation from the animation moves the character relative to
// its own coordinate frame, not the scene/world.
//
// Current Behavior:
//   • Hips XZ translation = character-relative horizontal movement (walk cycles, shifts)
//   • Hips Y translation = vertical movement (crouch, jump, body bounce)
//   • All deltas preserve animation intent while adapting to different skeleton proportions
//
// For Scene Locomotion (Future):
//   If you need the character to move through the world based on animation:
//   1. Extract hips XZ deltas separately (before applying to bone)
//   2. Accumulate as "root motion" vector
//   3. Apply to character's scene transform (not skeleton)
//   4. Optionally zero out the hips XZ in the skeleton to prevent "double movement"
//
// See also: AnimationPlayer.update() for frame-by-frame sampling
//
private func makeTranslationSampler(track: KeyTrack,
                                    animationRestTranslation: SIMD3<Float>,
                                    modelRestTranslation: SIMD3<Float>?) -> ((Float) -> SIMD3<Float>)? {
    guard let modelRest = modelRestTranslation else {
        return { t in sampleVector3(track, at: t) }
    }

    return { t in
        let animTranslation = sampleVector3(track, at: t)
        let delta = animTranslation - animationRestTranslation
        return modelRest + delta
    }
}

private func makeScaleSampler(track: KeyTrack,
                              animationRestScale: SIMD3<Float>,
                              modelRestScale: SIMD3<Float>?) -> ((Float) -> SIMD3<Float>)? {
    guard let modelRest = modelRestScale else {
        return { t in sampleVector3(track, at: t) }
    }

    return { t in
        let animScale = sampleVector3(track, at: t)
        let ratio = safeDivide(animScale, by: animationRestScale)
        return modelRest * ratio
    }
}

// Expression Weight Sampler
// Extracts the X component of a translation track as the expression weight.
// VRMA expression tracks encode weight as translation.x (0.0 to 1.0).
// Spec (VRMC_vrm_animation-1.0): "The implementation must clamp the value to [0, 1]."
private func makeExpressionWeightSampler(track: KeyTrack) -> (Float) -> Float {
    return { t in
        let translation = sampleVector3(track, at: t)
        return simd_clamp(translation.x, 0, 1)
    }
}

// Quaternion + Vector3 keyframe sampling delegates to GLTFCore's shared
// `gltfSampleQuaternion` / `gltfSampleVector3` so both VRMMetalKit (VRMA
// playback) and GLTFMetalKit (glTF animation) interpolate via the same
// spec-correct math — including `simd_slerp` for LINEAR rotations and
// shortest-arc fixup on CUBICSPLINE rotation tangents.

private func sampleQuaternion(_ track: KeyTrack, at time: Float) -> simd_quatf {
    guard track.componentCount == 4, !track.times.isEmpty else {
        return simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    }
    return gltfSampleQuaternion(
        times: track.times,
        values: track.values,
        interpolation: track.interpolation.asGLTFCore,
        at: time
    )
}

private func sampleVector3(_ track: KeyTrack, at time: Float) -> SIMD3<Float> {
    guard track.componentCount == 3, !track.times.isEmpty else {
        return SIMD3<Float>(repeating: 0)
    }
    return gltfSampleVector3(
        times: track.times,
        values: track.values,
        interpolation: track.interpolation.asGLTFCore,
        at: time
    )
}

private extension Interpolation {
    var asGLTFCore: GLTFKeyframeInterpolation {
        switch self {
        case .linear:      return .linear
        case .step:        return .step
        case .cubicSpline: return .cubicSpline
        }
    }
}

private func buildAnimationRestTransforms(document: GLTFDocument) -> [Int: RestTransform] {
    guard let nodes = document.nodes else { return [:] }
    var map: [Int: RestTransform] = [:]
    for (index, node) in nodes.enumerated() {
        map[index] = RestTransform(node: node)
    }
    // Compute world rest rotation `W` for every node by walking up the
    // parent chain. Required for the VMK#269 fix: the VRM 1.0 spec's
    // pose-normalisation formula needs both the local and world rest
    // rotations on each side of the retargeting transform.
    let parents = buildGLTFParentMap(nodes: nodes)
    // Snapshot the local-only map so the W computation reads a frozen
    // copy while we mutate `worldRotation` in `map`. Swift exclusivity
    // forbids overlapping inout + read access to the same dictionary.
    let localOnly = map
    for index in nodes.indices {
        map[index]?.worldRotation = computeWorldRotation(nodeIndex: index,
                                                          parents: parents,
                                                          restMap: localOnly)
    }
    return map
}

private func buildModelRestTransforms(model: VRMModel?) -> [VRMHumanoidBone: RestTransform] {
    guard let model, let humanoid = model.humanoid else { return [:] }
    guard let gltfNodes = model.gltf.nodes else { return [:] }

    // Build all-node rest transforms first so we can compute `W` for any
    // humanoid bone by walking up the glTF parent chain — humanoid bones
    // generally have non-humanoid ancestors (armature root, scene root)
    // whose rotations contribute to `W`.
    var allRest: [Int: RestTransform] = [:]
    for (index, node) in gltfNodes.enumerated() {
        allRest[index] = RestTransform(node: node)
    }
    let parents = buildGLTFParentMap(nodes: gltfNodes)
    let localOnly = allRest
    for index in gltfNodes.indices {
        allRest[index]?.worldRotation = computeWorldRotation(nodeIndex: index,
                                                              parents: parents,
                                                              restMap: localOnly)
    }

    var map: [VRMHumanoidBone: RestTransform] = [:]
    for bone in VRMHumanoidBone.allCases {
        guard let nodeIndex = humanoid.getBoneNode(bone),
              nodeIndex < gltfNodes.count else { continue }
        // CRITICAL: Use the ORIGINAL glTF node data (bind pose from file),
        // NOT the runtime VRMNode transform (which may have been modified by animations)
        map[bone] = allRest[nodeIndex]
    }
    return map
}

/// Build a child→parent index map from a glTF node array's `children`
/// fields. Nodes without a parent (scene roots) are absent from the map.
private func buildGLTFParentMap(nodes: [GLTFNode]) -> [Int: Int] {
    var parents: [Int: Int] = [:]
    for (parentIdx, node) in nodes.enumerated() {
        guard let children = node.children else { continue }
        for childIdx in children {
            parents[childIdx] = parentIdx
        }
    }
    return parents
}

/// Walk up the parent chain from `nodeIndex` and compute the cumulative
/// world-space rest rotation: `W_node = W_parent · L_node`.
///
/// Iterates parent-first so we don't recurse for deep hierarchies. The
/// terminating root contributes its own local rotation as the seed.
private func computeWorldRotation(nodeIndex: Int,
                                  parents: [Int: Int],
                                  restMap: [Int: RestTransform]) -> simd_quatf {
    // Collect the chain from root to this node.
    var chain: [Int] = [nodeIndex]
    var current = nodeIndex
    while let parent = parents[current] {
        chain.append(parent)
        current = parent
    }
    // Compose root → leaf: W_node = L_root · L_a · L_b · … · L_node
    var w = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    for idx in chain.reversed() {
        if let local = restMap[idx]?.rotation {
            w = simd_normalize(w * local)
        }
    }
    return w
}

private struct RestTransform {
    var rotation: simd_quatf
    var translation: SIMD3<Float>
    var scale: SIMD3<Float>
    /// World-space rest rotation `W` — cumulative product of this node's
    /// rest rotation with every ancestor's rest rotation back to the root.
    /// Defaults to the local rotation; callers must set this after
    /// constructing the per-node map so the parent chain is known.
    ///
    /// Used by `makeRotationSampler` to implement the VRM 1.0 spec's
    /// world-space normalisation (see `how_to_transform_human_pose.md` in
    /// the spec repo). Without `W` the retargeting formula assumes
    /// `W_A == W_B`, which fails as soon as a VRMA's authored rest pose
    /// differs from the model's T-pose orientation (VMK#269).
    var worldRotation: simd_quatf

    static let identity = RestTransform(rotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
                                         translation: SIMD3<Float>(repeating: 0),
                                         scale: SIMD3<Float>(repeating: 1),
                                         worldRotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1))

    init(rotation: simd_quatf,
         translation: SIMD3<Float>,
         scale: SIMD3<Float>,
         worldRotation: simd_quatf? = nil) {
        self.rotation = rotation
        self.translation = translation
        self.scale = scale
        // Default world rotation to the local — callers that have parent
        // hierarchy must overwrite this with the cumulative product.
        self.worldRotation = worldRotation ?? rotation
    }

    init(node: GLTFNode) {
        if let matrix = node.matrix, matrix.count == 16 {
            let m = matrixFromGLTF(matrix)
            let components = decomposeMatrix(m)
            self.init(rotation: components.rotation,
                      translation: components.translation,
                      scale: components.scale)
        } else {
            let rotation: simd_quatf
            if let r = node.rotation, r.count == 4 {
                rotation = simd_normalize(simd_quatf(ix: r[0], iy: r[1], iz: r[2], r: r[3]))
            } else {
                rotation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
            }

            let translation: SIMD3<Float>
            if let t = node.translation, t.count == 3 {
                translation = SIMD3<Float>(t[0], t[1], t[2])
            } else {
                translation = SIMD3<Float>(repeating: 0)
            }

            let scale: SIMD3<Float>
            if let s = node.scale, s.count == 3 {
                scale = SIMD3<Float>(s[0], s[1], s[2])
            } else {
                scale = SIMD3<Float>(repeating: 1)
            }

            self.init(rotation: rotation, translation: translation, scale: scale)
        }
    }

    init(node: VRMNode) {
        self.init(rotation: simd_normalize(node.rotation),
                  translation: node.translation,
                  scale: node.scale)
    }
}

private func safeDivide(_ numerator: SIMD3<Float>, by denominator: SIMD3<Float>) -> SIMD3<Float> {
    let epsilon: Float = 1e-6
    return SIMD3<Float>(
        numerator.x / (abs(denominator.x) > epsilon ? denominator.x : 1),
        numerator.y / (abs(denominator.y) > epsilon ? denominator.y : 1),
        numerator.z / (abs(denominator.z) > epsilon ? denominator.z : 1)
    )
}

// MARK: - VRM 0.0 Coordinate Conversion
private func matrixFromGLTF(_ values: [Float]) -> float4x4 {
    return float4x4(
        SIMD4<Float>(values[0], values[4], values[8], values[12]),
        SIMD4<Float>(values[1], values[5], values[9], values[13]),
        SIMD4<Float>(values[2], values[6], values[10], values[14]),
        SIMD4<Float>(values[3], values[7], values[11], values[15])
    )
}

private func decomposeMatrix(_ matrix: float4x4) -> (translation: SIMD3<Float>, rotation: simd_quatf, scale: SIMD3<Float>) {
    let translation = SIMD3<Float>(matrix.columns.3.x, matrix.columns.3.y, matrix.columns.3.z)

    var column0 = SIMD3<Float>(matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z)
    var column1 = SIMD3<Float>(matrix.columns.1.x, matrix.columns.1.y, matrix.columns.1.z)
    var column2 = SIMD3<Float>(matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z)

    var scaleX = length(column0)
    var scaleY = length(column1)
    var scaleZ = length(column2)

    if scaleX > 1e-6 { column0 /= scaleX } else { scaleX = 1 }
    if scaleY > 1e-6 { column1 /= scaleY } else { scaleY = 1 }
    if scaleZ > 1e-6 { column2 /= scaleZ } else { scaleZ = 1 }

    var rotationMatrix = float3x3(columns: (column0, column1, column2))

    // Correct for negative scale
    if simd_determinant(rotationMatrix) < 0 {
        scaleX = -scaleX
        rotationMatrix.columns.0 = -rotationMatrix.columns.0
    }

    let rotation = simd_quatf(rotationMatrix)
    let scale = SIMD3<Float>(scaleX, scaleY, scaleZ)

    return (translation, rotation, scale)
}
