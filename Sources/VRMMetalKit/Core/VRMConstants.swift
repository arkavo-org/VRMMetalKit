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

/// Centralized constants for VRMMetalKit configuration and default values.
/// This provides a single source of truth for magic numbers used throughout the codebase.
public enum VRMConstants {

    // MARK: - Rendering

    public enum Rendering {
        /// Number of frames to triple-buffer uniforms to avoid CPU-GPU sync stalls
        public static let maxBufferedFrames: Int = 3

        /// Default field of view in radians (60 degrees)
        public static let defaultFOV: Float = .pi / 3.0

        /// Default near clipping plane distance
        public static let defaultNearPlane: Float = 0.1

        /// Default far clipping plane distance
        public static let defaultFarPlane: Float = 100.0

        /// Maximum number of active morph targets that can be processed simultaneously
        public static let maxActiveMorphs: Int = 8

        /// Maximum total morph targets supported per mesh
        public static let maxMorphTargets: Int = 64

        /// Threshold for switching from CPU to GPU morph computation
        public static let morphComputeThreshold: Int = 8
    }

    // MARK: - Physics

    public enum Physics {
        /// SpringBone simulation substep rate in Hz for stable physics
        public static let substepRateHz: Double = 120.0

        /// Maximum number of substeps to process per frame to avoid spiral of death
        ///
        /// **Rationale for value of 10:**
        /// - At 120Hz substep rate: 10 substeps = 83ms worst-case processing time
        /// - Allows frame spikes up to 83ms before dropping physics steps (handles 2-3 dropped frames at 60 FPS)
        /// - Higher values risk CPU starvation and runaway accumulation in low-FPS scenarios
        /// - Lower values reduce simulation accuracy during transient lag spikes
        /// - Value of 10 balances stability (tolerates lag) with real-time performance (prevents infinite loop)
        ///
        /// Without this limit, a 1-second frame spike would attempt 120 substeps, causing further lag
        /// and spiraling into unrecoverable performance degradation ("spiral of death").
        public static let maxSubstepsPerFrame: Int = 10

        /// Default gravity vector in world space (m/s²)
        public static let defaultGravity = SIMD3<Float>(0, -9.8, 0)

        /// Epsilon for morph target weight comparison (weights below this are considered zero)
        public static let morphEpsilon: Float = 1e-4
    }

    // MARK: - Animation

    public enum Animation {
        /// Maximum number of joints supported for skeletal animation
        public static let maxJointCount: Int = 256

        /// Default animation playback speed multiplier
        public static let defaultPlaybackSpeed: Float = 1.0
    }

    // MARK: - Buffer Limits

    public enum BufferLimits {
        /// Maximum texture size in pixels
        public static let maxTextureSize: Int = 8192

        /// Preferred texture size for performance
        public static let preferredTextureSize: Int = 2048

        /// Maximum number of draw calls per frame before performance warning
        public static let maxDrawCallsWarningThreshold: Int = 1000
    }

    // MARK: - Performance

    public enum Performance {
        /// Frequency for periodic status logging (every N frames)
        public static let statusLogInterval: Int = 120

        /// Command buffer timeout in milliseconds
        public static let commandBufferTimeout: Int = 120000  // 2 minutes
    }

    // MARK: - Debug

    public enum Debug {
        /// Number of initial frames to log for debugging
        public static let initialFrameLogCount: Int = 3

        /// Interval for periodic logging (every N frames)
        public static let periodicLogInterval: Int = 60
    }
}
