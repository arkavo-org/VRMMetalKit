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

/// Convenience factory for built-in ``AnimationClip`` presets and a `.vrma` loader entry point.
public enum AnimationLibrary {
    /// Returns a high-amplitude diagnostic dance clip that exaggerates joint motion across the spine, head, and arms.
    ///
    /// Intended for visual smoke-tests where small animation deltas would be
    /// missed. The clip is intentionally loud; production avatars should use
    /// authored VRMA content via ``loadClip(from:model:)`` instead.
    public static func builtinSwayDance() -> AnimationClip {
        var clip = AnimationClip(duration: 2.0)  // Faster cycle for testing

        func sinusoidalSampler(phase: Float = 0, amplitude: Float, frequency: Float = 1.0) -> (Float) -> Float {
            return { time in
                amplitude * sinf(2 * .pi * frequency * (time / 2.0) + phase)  // Updated for 2s duration
            }
        }

        // EXTREME DIAGNOSTIC ANIMATION - IMPOSSIBLE TO MISS
        clip.addEulerTrack(
            bone: .hips,
            axis: .z,
            sample: sinusoidalSampler(amplitude: .pi / 2)  // 90 DEGREES!
        )

        clip.addEulerTrack(
            bone: .hips,
            axis: .y,
            sample: sinusoidalSampler(phase: .pi / 2, amplitude: .pi / 60)
        )

        // EXTREME HEAD MOVEMENT
        clip.addEulerTrack(
            bone: .head,
            axis: .x,
            sample: sinusoidalSampler(phase: .pi / 2, amplitude: .pi / 3)  // 60 degrees nodding!
        )

        clip.addEulerTrack(
            bone: .neck,
            axis: .z,
            sample: sinusoidalSampler(phase: .pi / 3, amplitude: .pi / 60)
        )

        // EXTREME ARM MOVEMENTS - FULL ROTATION
        clip.addEulerTrack(
            bone: .leftUpperArm,
            axis: .z,
            sample: sinusoidalSampler(amplitude: .pi * 0.75)  // 135 degrees!
        )

        clip.addEulerTrack(
            bone: .rightUpperArm,
            axis: .z,
            sample: sinusoidalSampler(phase: .pi, amplitude: .pi * 0.75)  // 135 degrees opposite!
        )

        clip.addEulerTrack(
            bone: .leftLowerArm,
            axis: .x,
            sample: sinusoidalSampler(phase: .pi / 4, amplitude: .pi / 15)
        )

        clip.addEulerTrack(
            bone: .rightLowerArm,
            axis: .x,
            sample: sinusoidalSampler(phase: 3 * .pi / 4, amplitude: .pi / 15)
        )

        clip.addEulerTrack(
            bone: .spine,
            axis: .y,
            sample: sinusoidalSampler(phase: .pi / 6, amplitude: .pi / 90)
        )

        clip.addEulerTrack(
            bone: .chest,
            axis: .z,
            sample: sinusoidalSampler(phase: .pi / 3, amplitude: .pi / 60)
        )

        clip.addMorphTrack(key: "happy") { time in
            max(0, sinf(2 * .pi * time / 3.0)) * 0.35
        }

        clip.addMorphTrack(key: "joy") { time in
            max(0, sinf(2 * .pi * time / 4.0 + .pi / 4)) * 0.2
        }

        return clip
    }

    /// Returns a 4-second subtle idle-breathing clip animating the chest and spine.
    ///
    /// Useful as a low-key fallback when no scripted animation is playing.
    /// For richer procedural breathing, see ``IdleBreathingLayer``.
    public static func builtinIdleBreathing() -> AnimationClip {
        var clip = AnimationClip(duration: 4.0)

        clip.addEulerTrack(
            bone: .chest,
            axis: .x,
            sample: { time in
                let breathCycle = sinf(2 * .pi * time / 4.0)
                return breathCycle * (.pi / 120)
            }
        )

        clip.addEulerTrack(
            bone: .spine,
            axis: .x,
            sample: { time in
                let breathCycle = sinf(2 * .pi * time / 4.0 + .pi / 4)
                return breathCycle * (.pi / 180)
            }
        )

        return clip
    }

    /// Loads a `.vrma` (VRMC_vrm_animation) file from `url` and retargets it to `model`.
    ///
    /// Delegates to ``VRMAnimationLoader/loadVRMA(from:model:)``. Pass the
    /// target model so rest-pose retargeting can produce closures suited to
    /// its skeleton; passing `nil` falls back to a model-less identity
    /// retarget.
    ///
    /// - Throws: Errors from ``VRMAnimationLoader/loadVRMA(from:model:)``
    ///   (file read, glTF parse, missing animation block).
    public static func loadClip(from url: URL, model: VRMModel?) throws -> AnimationClip {
        // Load a .vrma (GLB) file into an AnimationClip using VRMAnimationLoader
        return try VRMAnimationLoader.loadVRMA(from: url, model: model)
    }
}
