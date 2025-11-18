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

public enum VRMAnimationLoader {
    // Load a VRMC_vrm_animation-1.0 (.vrma) clip from a GLB file
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

                if let boneDict = value as? [String: Any],
                   let nodeAny = boneDict["node"],
                   let nodeIndex = intValue(from: nodeAny) {
                    map[nodeIndex] = bone
                }
            }
            return map
        }()

        // Map VRMA node names to bones using the target model's humanoid mapping when extension data isn't available.
        let modelNameToBone: [String: VRMHumanoidBone] = {
            guard let model, let humanoid = model.humanoid else { return [:] }
            var map: [String: VRMHumanoidBone] = [:]
            for bone in VRMHumanoidBone.allCases {
                if let nodeIndex = humanoid.getBoneNode(bone),
                   nodeIndex < model.nodes.count,
                   let nodeName = model.nodes[nodeIndex].name {
                    map[normalize(nodeName)] = bone
                }
            }
            return map
        }()

        // Fallback heuristic if model mapping is missing
        let heuristicNameToBone: (String) -> VRMHumanoidBone? = { name in
            let n = name.lowercased()
            if n.contains("hips") { return .hips }
            if n.contains("upperchest") { return .upperChest }
            if n.contains("chest") { return .chest }
            if n.contains("spine") { return .spine }
            if n.contains("neck") { return .neck }
            if n.contains("head") { return .head }
            if n.contains("l_upperarm") { return .leftUpperArm }
            if n.contains("l_lowerarm") { return .leftLowerArm }
            if n.contains("l_hand") { return .leftHand }
            if n.contains("r_upperarm") { return .rightUpperArm }
            if n.contains("r_lowerarm") { return .rightLowerArm }
            if n.contains("r_hand") { return .rightHand }
            if n.contains("l_upperleg") { return .leftUpperLeg }
            if n.contains("l_lowerleg") { return .leftLowerLeg }
            if n.contains("l_foot") { return .leftFoot }
            if n.contains("l_toe") { return .leftToes }
            if n.contains("r_upperleg") { return .rightUpperLeg }
            if n.contains("r_lowerleg") { return .rightLowerLeg }
            if n.contains("r_foot") { return .rightFoot }
            if n.contains("r_toe") { return .rightToes }
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
                                    nodeIndex: nodeIndex, clip: &clip)
            } else {
                // NON-HUMANOID NODE TRACK (hair, bust, accessories)
                processNonHumanoidTrack(nodeName: nodeName, tracks: tracks,
                                       animationRestTransforms: animationRestTransforms,
                                       nodeIndex: nodeIndex, clip: &clip)
            }
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

        let rotationRest = tracks["rotation"].flatMap { trackRotationRest($0) } ?? animationRest.rotation
        let translationRest = tracks["translation"].flatMap { trackVectorRest($0, componentCount: 3) } ?? animationRest.translation
        let scaleRest = tracks["scale"].flatMap { trackVectorRest($0, componentCount: 3) } ?? animationRest.scale

        var rotationSampler: ((Float) -> simd_quatf)? = nil
        if let rot = tracks["rotation"] {
            // VRMA animations preserve authored poses - do NOT retarget rotations
            // The animation data is already in the correct space for the humanoid
            rotationSampler = makeRotationSampler(track: rot,
                                                  animationRestRotation: rotationRest,
                                                  modelRestRotation: nil)  // nil = no retargeting
        }

        var translationSampler: ((Float) -> simd_float3)? = nil
        if let trans = tracks["translation"] {
            translationSampler = makeTranslationSampler(track: trans,
                                                        animationRestTranslation: translationRest,
                                                        modelRestTranslation: modelRest?.translation)
        }

        var scaleSampler: ((Float) -> simd_float3)? = nil
        if let scl = tracks["scale"] {
            scaleSampler = makeScaleSampler(track: scl,
                                            animationRestScale: scaleRest,
                                            modelRestScale: modelRest?.scale)
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
        // For non-humanoid nodes, we don't do rest-pose retargeting
        // We just pass through the animation data as-is
        let animationRest = animationRestTransforms[nodeIndex] ?? RestTransform.identity

        let rotationRest = tracks["rotation"].flatMap { trackRotationRest($0) } ?? animationRest.rotation
        let translationRest = tracks["translation"].flatMap { trackVectorRest($0, componentCount: 3) } ?? animationRest.translation
        let scaleRest = tracks["scale"].flatMap { trackVectorRest($0, componentCount: 3) } ?? animationRest.scale

        var rotationSampler: ((Float) -> simd_quatf)? = nil
        if let rot = tracks["rotation"] {
            // No model rest for non-humanoid - use animation data directly
            rotationSampler = makeRotationSampler(track: rot,
                                                  animationRestRotation: rotationRest,
                                                  modelRestRotation: nil)
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

// Rotation Retargeting with Delta-Based Alignment
//
// VRM ANIMATION SPEC:
// ------------------
// VRMA animation data is preserved as authored. The first keyframe can be any pose
// (T-pose, idle, crouch, wave, etc.). T-pose is the VRM model's humanoid rest pose,
// NOT a requirement on the animation's first frame.
//
// Spec: https://github.com/vrm-c/vrm-specification/blob/master/specification/VRMC_vrm_animation-1.0/
//
// Retargeting Formula (local space):
//   delta = inverse(animationRest) * animationRotation
//   result = modelRest * delta
//
// This transforms the animation rotation from the animation's rest pose space
// to the target VRM model's rest pose space, preserving the animation's intent
// while adapting to different skeleton proportions.
private func makeRotationSampler(track: KeyTrack,
                                 animationRestRotation: simd_quatf,
                                 modelRestRotation: simd_quatf?) -> ((Float) -> simd_quatf)? {
    let modelRest = modelRestRotation
    let rotationRest = simd_normalize(animationRestRotation)

    if modelRest == nil {
        return { t in sampleQuaternion(track, at: t) }
    }

    let modelRestNormalized = simd_normalize(modelRest!)

    return { t in
        let animRotation = sampleQuaternion(track, at: t)
        let delta = simd_normalize(simd_inverse(rotationRest) * animRotation)
        return simd_normalize(modelRestNormalized * delta)
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

private func trackRotationRest(_ track: KeyTrack) -> simd_quatf? {
    guard track.componentCount == 4, !track.times.isEmpty else { return nil }
    return quaternionValue(from: track, keyIndex: 0)
}

private func trackVectorRest(_ track: KeyTrack, componentCount: Int) -> SIMD3<Float>? {
    guard track.componentCount == componentCount, !track.times.isEmpty else { return nil }
    let vector = vectorValue(from: track, keyIndex: 0, componentCount: componentCount)
    return vector
}

private func sampleQuaternion(_ track: KeyTrack, at time: Float) -> simd_quatf {
    guard track.componentCount == 4 else { return simd_quatf(ix: 0, iy: 0, iz: 0, r: 1) }
    guard !track.times.isEmpty else { return simd_quatf(ix: 0, iy: 0, iz: 0, r: 1) }

    switch track.interpolation {
    case .step:
        let index = keyframeIndex(for: track.times, time: time)
        return quaternionValue(from: track, keyIndex: index)
    case .linear:
        let (index, frac) = findKeyframeIndexAndFrac(times: track.times, time: time)
        let q0 = quaternionValue(from: track, keyIndex: index)
        if index + 1 >= track.times.count { return q0 }
        var q1 = quaternionValue(from: track, keyIndex: index + 1)
        if simd_dot(q0.vector, q1.vector) < 0 {
            q1 = simd_quatf(vector: -q1.vector)
        }
        return simd_normalize(simd_slerp(q0, q1, frac))
    case .cubicSpline:
        let (index, frac) = findKeyframeIndexAndFrac(times: track.times, time: time)
        if index + 1 >= track.times.count { return quaternionValue(from: track, keyIndex: index) }
        let next = index + 1
        let dt = max(1e-6, track.times[next] - track.times[index])

        let value0 = quaternionVector(from: track, keyIndex: index)
        var value1 = quaternionVector(from: track, keyIndex: next)
        var inTan1 = quaternionInTangent(from: track, keyIndex: next)
        let outTan0 = quaternionOutTangent(from: track, keyIndex: index)

        if simd_dot(value0, value1) < 0 {
            value1 = -value1
            inTan1 = -inTan1
        }

        let m0 = outTan0 * dt
        let m1 = inTan1 * dt

        let hermiteValue = hermite(value0, m0, value1, m1, frac)
        return simd_normalize(simd_quatf(ix: hermiteValue[0], iy: hermiteValue[1], iz: hermiteValue[2], r: hermiteValue[3]))
    }
}

private func sampleVector3(_ track: KeyTrack, at time: Float) -> SIMD3<Float> {
    guard track.componentCount == 3 else { return SIMD3<Float>(repeating: 0) }
    guard !track.times.isEmpty else { return SIMD3<Float>(repeating: 0) }

    switch track.interpolation {
    case .step:
        let index = keyframeIndex(for: track.times, time: time)
        return vectorValue(from: track, keyIndex: index, componentCount: 3)
    case .linear:
        let (index, frac) = findKeyframeIndexAndFrac(times: track.times, time: time)
        let v0 = vectorValue(from: track, keyIndex: index, componentCount: 3)
        if index + 1 >= track.times.count { return v0 }
        let v1 = vectorValue(from: track, keyIndex: index + 1, componentCount: 3)
        return mix(v0, v1, t: frac)
    case .cubicSpline:
        let (index, frac) = findKeyframeIndexAndFrac(times: track.times, time: time)
        if index + 1 >= track.times.count { return vectorValue(from: track, keyIndex: index, componentCount: 3) }
        let next = index + 1
        let dt = max(1e-6, track.times[next] - track.times[index])

        let value0 = vectorValue(from: track, keyIndex: index, componentCount: 3)
        let value1 = vectorValue(from: track, keyIndex: next, componentCount: 3)
        let outTan0 = vectorOutTangent(from: track, keyIndex: index, componentCount: 3)
        let inTan1 = vectorInTangent(from: track, keyIndex: next, componentCount: 3)

        let m0 = outTan0 * dt
        let m1 = inTan1 * dt
        return hermite(value0, m0, value1, m1, frac)
    }
}

private func keyframeIndex(for times: [Float], time: Float) -> Int {
    if time <= times.first ?? 0 { return 0 }
    if time >= times.last ?? 0 { return max(0, times.count - 1) }
    for i in (0..<(times.count - 1)).reversed() {
        if time >= times[i] {
            return i
        }
    }
    return 0
}

private func findKeyframeIndexAndFrac(times: [Float], time: Float) -> (Int, Float) {
    if times.isEmpty { return (0, 0) }
    if time <= times.first! { return (0, 0) }
    if time >= times.last! { return (max(0, times.count - 2), 1) }

    for i in 0..<(times.count - 1) {
        let t0 = times[i]
        let t1 = times[i + 1]
        if time >= t0 && time <= t1 {
            let frac = (time - t0) / max(1e-6, (t1 - t0))
            return (i, frac)
        }
    }
    return (0, 0)
}

private enum TrackSegment {
    case value
    case inTangent
    case outTangent
}

private func valueRange(for track: KeyTrack, keyIndex: Int, componentCount: Int, segment: TrackSegment) -> Range<Int>? {
    let strideMultiplier = track.interpolation == .cubicSpline ? 3 : 1
    let stride = componentCount * strideMultiplier
    let base = keyIndex * stride
    switch track.interpolation {
    case .cubicSpline:
        switch segment {
        case .inTangent:
            return base..<(base + componentCount)
        case .value:
            return (base + componentCount)..<(base + 2 * componentCount)
        case .outTangent:
            return (base + 2 * componentCount)..<(base + 3 * componentCount)
        }
    case .linear, .step:
        guard segment == .value else { return nil }
        return base..<(base + componentCount)
    }
}

private func quaternionValue(from track: KeyTrack, keyIndex: Int) -> simd_quatf {
    let vector = quaternionVector(from: track, keyIndex: keyIndex)
    return simd_normalize(simd_quatf(ix: vector[0], iy: vector[1], iz: vector[2], r: vector[3]))
}

private func quaternionVector(from track: KeyTrack, keyIndex: Int) -> SIMD4<Float> {
    guard let range = valueRange(for: track, keyIndex: keyIndex, componentCount: 4, segment: .value),
          range.upperBound <= track.values.count else {
        return SIMD4<Float>(0, 0, 0, 1)
    }
    return SIMD4<Float>(track.values[range.lowerBound + 0],
                        track.values[range.lowerBound + 1],
                        track.values[range.lowerBound + 2],
                        track.values[range.lowerBound + 3])
}

private func quaternionInTangent(from track: KeyTrack, keyIndex: Int) -> SIMD4<Float> {
    guard let range = valueRange(for: track, keyIndex: keyIndex, componentCount: 4, segment: .inTangent),
          range.upperBound <= track.values.count else {
        return SIMD4<Float>(repeating: 0)
    }
    return SIMD4<Float>(track.values[range.lowerBound + 0],
                        track.values[range.lowerBound + 1],
                        track.values[range.lowerBound + 2],
                        track.values[range.lowerBound + 3])
}

private func quaternionOutTangent(from track: KeyTrack, keyIndex: Int) -> SIMD4<Float> {
    guard let range = valueRange(for: track, keyIndex: keyIndex, componentCount: 4, segment: .outTangent),
          range.upperBound <= track.values.count else {
        return SIMD4<Float>(repeating: 0)
    }
    return SIMD4<Float>(track.values[range.lowerBound + 0],
                        track.values[range.lowerBound + 1],
                        track.values[range.lowerBound + 2],
                        track.values[range.lowerBound + 3])
}

private func vectorValue(from track: KeyTrack, keyIndex: Int, componentCount: Int) -> SIMD3<Float> {
    guard let range = valueRange(for: track, keyIndex: keyIndex, componentCount: componentCount, segment: .value),
          range.upperBound <= track.values.count else {
        return SIMD3<Float>(repeating: 0)
    }
    return SIMD3<Float>(track.values[range.lowerBound + 0],
                        track.values[range.lowerBound + 1],
                        track.values[range.lowerBound + 2])
}

private func vectorInTangent(from track: KeyTrack, keyIndex: Int, componentCount: Int) -> SIMD3<Float> {
    guard let range = valueRange(for: track, keyIndex: keyIndex, componentCount: componentCount, segment: .inTangent),
          range.upperBound <= track.values.count else {
        return SIMD3<Float>(repeating: 0)
    }
    return SIMD3<Float>(track.values[range.lowerBound + 0],
                        track.values[range.lowerBound + 1],
                        track.values[range.lowerBound + 2])
}

private func vectorOutTangent(from track: KeyTrack, keyIndex: Int, componentCount: Int) -> SIMD3<Float> {
    guard let range = valueRange(for: track, keyIndex: keyIndex, componentCount: componentCount, segment: .outTangent),
          range.upperBound <= track.values.count else {
        return SIMD3<Float>(repeating: 0)
    }
    return SIMD3<Float>(track.values[range.lowerBound + 0],
                        track.values[range.lowerBound + 1],
                        track.values[range.lowerBound + 2])
}

private func hermite(_ p0: SIMD3<Float>, _ m0: SIMD3<Float>, _ p1: SIMD3<Float>, _ m1: SIMD3<Float>, _ t: Float) -> SIMD3<Float> {
    let t2 = t * t
    let t3 = t2 * t
    let h00 = 2 * t3 - 3 * t2 + 1
    let h10 = t3 - 2 * t2 + t
    let h01 = -2 * t3 + 3 * t2
    let h11 = t3 - t2
    return h00 * p0 + h10 * m0 + h01 * p1 + h11 * m1
}

private func hermite(_ p0: SIMD4<Float>, _ m0: SIMD4<Float>, _ p1: SIMD4<Float>, _ m1: SIMD4<Float>, _ t: Float) -> SIMD4<Float> {
    let t2 = t * t
    let t3 = t2 * t
    let h00 = 2 * t3 - 3 * t2 + 1
    let h10 = t3 - 2 * t2 + t
    let h01 = -2 * t3 + 3 * t2
    let h11 = t3 - t2
    return h00 * p0 + h10 * m0 + h01 * p1 + h11 * m1
}

private func buildAnimationRestTransforms(document: GLTFDocument) -> [Int: RestTransform] {
    guard let nodes = document.nodes else { return [:] }
    var map: [Int: RestTransform] = [:]
    for (index, node) in nodes.enumerated() {
        map[index] = RestTransform(node: node)
    }
    return map
}

private func buildModelRestTransforms(model: VRMModel?) -> [VRMHumanoidBone: RestTransform] {
    guard let model, let humanoid = model.humanoid else { return [:] }
    var map: [VRMHumanoidBone: RestTransform] = [:]
    for bone in VRMHumanoidBone.allCases {
        guard let nodeIndex = humanoid.getBoneNode(bone), nodeIndex < model.nodes.count else { continue }
        let node = model.nodes[nodeIndex]
        map[bone] = RestTransform(node: node)
    }
    return map
}

private struct RestTransform {
    var rotation: simd_quatf
    var translation: SIMD3<Float>
    var scale: SIMD3<Float>

    static let identity = RestTransform(rotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
                                         translation: SIMD3<Float>(repeating: 0),
                                         scale: SIMD3<Float>(repeating: 1))

    init(rotation: simd_quatf, translation: SIMD3<Float>, scale: SIMD3<Float>) {
        self.rotation = rotation
        self.translation = translation
        self.scale = scale
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
