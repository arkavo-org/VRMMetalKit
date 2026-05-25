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

// VRMA rest-pose retargeting samplers.
//
// Extracted from VRMAnimationLoader.swift so the retargeting math is an
// isolated, directly-testable unit (issue #282). VRMAnimationLoader builds
// `KeyTrack`s from parsed GLB data and calls these to produce per-frame
// closures.
//
// Rest-pose retargeting (VRM 1.0 `how_to_transform_human_pose.md`):
//   delta  = inverse(animationRestRotation) * animationRotation
//   result = modelRestRotation * delta
// with the W-term change-of-basis applied for rigs whose world-rest
// orientations differ. See makeRotationSampler for the full derivation.

func makeRotationSampler(track: KeyTrack,
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
func makeTranslationSampler(track: KeyTrack,
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

func makeScaleSampler(track: KeyTrack,
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

func safeDivide(_ numerator: SIMD3<Float>, by denominator: SIMD3<Float>) -> SIMD3<Float> {
    let epsilon: Float = 1e-6
    return SIMD3<Float>(
        numerator.x / (abs(denominator.x) > epsilon ? denominator.x : 1),
        numerator.y / (abs(denominator.y) > epsilon ? denominator.y : 1),
        numerator.z / (abs(denominator.z) > epsilon ? denominator.z : 1)
    )
}
