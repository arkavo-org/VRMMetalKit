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

/// Centralized configuration constants for VRMMetalKit subsystems.
///
/// Each nested namespace (``Rendering``, ``Physics``, ``Animation``,
/// ``BufferLimits``, ``Performance``, ``Debug``) groups defaults that are
/// referenced from across the package. Values are spec-driven where
/// applicable (e.g. ``Physics/substepRateHz`` matches the VRM 1.0
/// `VRMC_springBone` recommendation).
public enum VRMConstants {

    // MARK: - Rendering

    /// Default rendering pipeline parameters (triple-buffering, FOV, clip planes, morph limits).
    public enum Rendering {
        /// Number of in-flight frames for triple-buffered uniforms; prevents CPU-GPU sync stalls.
        public static let maxBufferedFrames: Int = 3

        /// Default field of view in radians (60 degrees).
        public static let defaultFOV: Float = .pi / 3.0

        /// Default near-clip plane distance in meters.
        public static let defaultNearPlane: Float = 0.1

        /// Default far-clip plane distance in meters.
        public static let defaultFarPlane: Float = 100.0

        /// Maximum number of morph targets simultaneously active during vertex shading.
        public static let maxActiveMorphs: Int = 8

        /// Maximum number of morph targets supported per mesh.
        public static let maxMorphTargets: Int = 64

        /// Active-morph count at which the renderer switches from CPU to GPU morph evaluation.
        public static let morphComputeThreshold: Int = 8
    }

    // MARK: - Physics

    /// Quality presets for the spring-bone XPBD simulation, mapping substep rate, iteration count, and frame budget.
    public enum SpringBoneQuality: Int, Sendable {
        /// 120Hz substeps, 4 iterations — highest fidelity, recommended on desktop.
        case ultra = 0
        /// 90Hz substeps, 3 iterations — high fidelity, suitable for ProMotion devices.
        case high = 1
        /// 60Hz substeps, 2 iterations — balanced quality and performance.
        case medium = 2
        /// 30Hz substeps, 1 iteration — battery-saver preset for mobile.
        case low = 3
        /// Spring-bone simulation disabled.
        case off = 4

        /// Substep rate in Hz for this quality level.
        public var substepRateHz: Double {
            switch self {
            case .ultra: return 120.0
            case .high: return 90.0
            case .medium: return 60.0
            case .low: return 30.0
            case .off: return 0.0
            }
        }

        /// Number of XPBD constraint iterations per substep.
        public var constraintIterations: Int {
            switch self {
            case .ultra: return 4
            case .high: return 3
            case .medium: return 2
            case .low: return 1
            case .off: return 0
            }
        }

        /// Maximum substeps allowed per frame before the simulation drops steps to avoid the spiral of death.
        public var maxSubstepsPerFrame: Int {
            switch self {
            case .ultra: return 10
            case .high: return 8
            case .medium: return 6
            case .low: return 4
            case .off: return 0
            }
        }
    }

    /// Spring-bone simulation defaults (substep rate, iteration budget, gravity, settling parameters).
    public enum Physics {
        /// Spring-bone fixed-substep rate in Hz; the VRM 1.0 `VRMC_springBone` reference rate.
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

        /// Number of XPBD constraint iterations per substep
        ///
        /// Higher values improve constraint enforcement (stiffer springs, better collision response)
        /// at the cost of additional GPU dispatches per substep.
        /// Note: Each constraint iteration modifies position without updating prev, which affects
        /// Verlet velocity. Fewer iterations allow more natural velocity accumulation.
        /// - 1: Minimal - collision may not fully resolve if distance constraint fights it
        /// - 2-3: Balanced for responsive motion with good collision
        /// - 4+: Stiffer response, reaches equilibrium faster
        public static let constraintIterations: Int = 4

        /// Default gravity vector in world space (m/s²)
        public static let defaultGravity = SIMD3<Float>(0, -9.8, 0)

        /// Epsilon for morph target weight comparison (weights below this are considered zero)
        public static let morphEpsilon: Float = 1e-4

        /// Enable linear interpolation of root positions across substeps
        /// When true, root bone positions are smoothly interpolated from previous frame to current,
        /// preventing "velocity sledgehammer" that causes hair/cloth explosion
        public static let enableRootInterpolation: Bool = true

        /// Minimum model scale for threshold calculation
        /// Prevents division issues and ensures very small models still have reasonable teleportation detection
        public static let minScaleForThreshold: Float = 0.1
    }

    // MARK: - Animation

    /// Animation defaults (joint capacity, playback speed).
    public enum Animation {
        /// Maximum number of joints supported per skinned mesh.
        public static let maxJointCount: Int = 256

        /// Default animation playback rate multiplier (1.0 = real-time).
        public static let defaultPlaybackSpeed: Float = 1.0
    }

    // MARK: - Buffer Limits

    /// GPU resource budget defaults (texture size, draw-call thresholds).
    public enum BufferLimits {
        /// Maximum texture size in pixels per dimension (Metal hard cap on most devices).
        public static let maxTextureSize: Int = 8192

        /// Preferred texture size that balances visual quality and VRAM footprint.
        public static let preferredTextureSize: Int = 2048

        /// Draw-call count above which a performance warning is logged.
        public static let maxDrawCallsWarningThreshold: Int = 1000
    }

    // MARK: - Performance

    /// Performance-monitoring and timeout defaults.
    public enum Performance {
        /// Frame interval between periodic status log messages.
        public static let statusLogInterval: Int = 120

        /// Command-buffer completion timeout in milliseconds (2 minutes).
        public static let commandBufferTimeout: Int = 120000  // 2 minutes
    }

    // MARK: - Debug

    /// Diagnostic-logging cadence used by the renderer and physics systems.
    public enum Debug {
        /// Number of leading frames to log verbose diagnostics for.
        public static let initialFrameLogCount: Int = 3

        /// Frame interval between periodic debug log messages once the warmup window has elapsed.
        public static let periodicLogInterval: Int = 60
    }
}
