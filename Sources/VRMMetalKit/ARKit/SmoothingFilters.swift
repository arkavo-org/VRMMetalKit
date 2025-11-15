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

// MARK: - Smoothing Configuration

/// Configuration for smoothing filters applied to expression weights and skeletal data
///
/// Smoothing reduces jitter and noise in AR tracking data while balancing responsiveness.
/// Different expressions may require different smoothing strategies (e.g., blinks need
/// fast response, while mouth shapes can be more smoothed).
///
/// ## Usage
///
/// ```swift
/// // Default balanced smoothing
/// let config = SmoothingConfig.default
///
/// // Low latency (more responsive, less smooth)
/// let config = SmoothingConfig.lowLatency
///
/// // Very smooth (less responsive, more stable)
/// let config = SmoothingConfig.smooth
///
/// // Custom per-expression
/// var config = SmoothingConfig.default
/// config.perExpression[.blink] = .none  // No smoothing for blinks
/// config.perExpression[.jawOpen] = .ema(alpha: 0.2)  // Heavy smoothing for jaw
/// ```
public struct SmoothingConfig: Sendable {
    /// Default smoothing applied to all expressions unless overridden
    public var global: SmoothingFilter

    /// Per-expression overrides
    public var perExpression: [String: SmoothingFilter]

    public init(
        global: SmoothingFilter,
        perExpression: [String: SmoothingFilter] = [:]
    ) {
        self.global = global
        self.perExpression = perExpression
    }

    /// Get filter for a specific expression key
    public func filter(for key: String) -> SmoothingFilter {
        return perExpression[key] ?? global
    }

    // MARK: - Presets

    /// Default balanced smoothing (alpha = 0.3)
    /// Good balance between responsiveness and stability
    public static let `default` = SmoothingConfig(
        global: .ema(alpha: 0.3),
        perExpression: [
            ARKitFaceBlendShapes.eyeBlinkLeft: .none,
            ARKitFaceBlendShapes.eyeBlinkRight: .none,
            "blink": .none  // VRM blink should be responsive
        ]
    )

    /// Low latency smoothing (alpha = 0.7)
    /// More responsive, less smooth - good for interactive scenarios
    public static let lowLatency = SmoothingConfig(
        global: .ema(alpha: 0.7)
    )

    /// Heavy smoothing (alpha = 0.1)
    /// Very smooth, less responsive - good for cinematic capture
    public static let smooth = SmoothingConfig(
        global: .ema(alpha: 0.1)
    )

    /// Kalman filtering (adaptive, optimal for linear systems)
    /// Best quality but more computational cost
    public static let kalman = SmoothingConfig(
        global: .kalman(processNoise: 0.01, measurementNoise: 0.1)
    )

    /// No smoothing
    /// Raw data, maximum latency - useful for debugging
    public static let none = SmoothingConfig(
        global: .none
    )
}

// MARK: - Smoothing Filter Enum

/// Type of smoothing filter to apply
public enum SmoothingFilter: Sendable {
    /// No smoothing (pass-through)
    case none

    /// Exponential Moving Average
    /// - Parameter alpha: Smoothing factor (0-1). Higher = more responsive, less smooth
    ///   - 1.0 = no smoothing (instant response)
    ///   - 0.5 = balanced
    ///   - 0.1 = heavy smoothing (slow response)
    case ema(alpha: Float)

    /// Kalman filter (optimal for linear systems with Gaussian noise)
    /// - Parameter processNoise: Process noise covariance (how much the true value changes)
    /// - Parameter measurementNoise: Measurement noise covariance (sensor accuracy)
    case kalman(processNoise: Float, measurementNoise: Float)

    /// Windowed moving average
    /// - Parameter size: Number of samples to average (larger = smoother but more latency)
    case windowed(size: Int)

    /// Create a filter instance from this configuration
    func makeFilter() -> any SmoothingFilterProtocol {
        switch self {
        case .none:
            return PassThroughFilter()
        case .ema(let alpha):
            return EMAFilter(alpha: alpha)
        case .kalman(let processNoise, let measurementNoise):
            return KalmanFilter(processNoise: processNoise, measurementNoise: measurementNoise)
        case .windowed(let size):
            return WindowedAverageFilter(windowSize: size)
        }
    }
}

// MARK: - Filter Protocol

/// Protocol for smoothing filters
protocol SmoothingFilterProtocol {
    /// Update filter with new value and return smoothed output
    mutating func update(_ value: Float) -> Float

    /// Reset filter state
    mutating func reset()
}

// MARK: - Pass-Through Filter

/// No-op filter that passes values through unchanged
struct PassThroughFilter: SmoothingFilterProtocol {
    func update(_ value: Float) -> Float {
        return value
    }

    mutating func reset() {
        // No state to reset
    }
}

// MARK: - Exponential Moving Average Filter

/// Exponential Moving Average (EMA) filter
///
/// Smooths values using weighted average where recent values have more weight.
/// Formula: `smoothed = alpha * newValue + (1 - alpha) * previousSmoothed`
///
/// ## Characteristics
/// - Simple and efficient (single multiply-add per update)
/// - Low memory (stores only current value)
/// - Good general-purpose smoothing
/// - Alpha controls responsiveness vs smoothness trade-off
///
/// ## Performance
/// - O(1) time complexity
/// - O(1) space complexity
/// - ~3-5 CPU cycles per update
struct EMAFilter: SmoothingFilterProtocol {
    private var smoothedValue: Float?
    private let alpha: Float

    init(alpha: Float) {
        self.alpha = min(1.0, max(0.0, alpha))  // Clamp to [0, 1]
    }

    mutating func update(_ value: Float) -> Float {
        if let current = smoothedValue {
            smoothedValue = alpha * value + (1.0 - alpha) * current
        } else {
            // First value - initialize
            smoothedValue = value
        }
        return smoothedValue!
    }

    mutating func reset() {
        smoothedValue = nil
    }
}

// MARK: - Kalman Filter

/// 1D Kalman filter for optimal smoothing with noise estimation
///
/// Kalman filtering provides optimal estimation for linear systems with Gaussian noise.
/// More sophisticated than EMA, adapts to changing noise characteristics.
///
/// ## Characteristics
/// - Optimal for linear systems
/// - Adapts to measurement uncertainty
/// - Provides uncertainty estimates
/// - More complex than EMA but still efficient
///
/// ## Parameters
/// - **processNoise**: How much the true value changes between measurements (Q)
///   - Low (0.001): Value changes slowly (e.g., head pose)
///   - High (0.1): Value changes quickly (e.g., mouth movement)
/// - **measurementNoise**: Sensor accuracy (R)
///   - Low (0.01): Sensor is accurate (trust measurements more)
///   - High (1.0): Sensor is noisy (smooth more)
///
/// ## Performance
/// - O(1) time complexity
/// - O(1) space complexity
/// - ~15-20 CPU cycles per update (5x slower than EMA but still very fast)
struct KalmanFilter: SmoothingFilterProtocol {
    // State estimate
    private var estimate: Float?
    private var errorCovariance: Float = 1.0

    // Filter parameters
    private let processNoise: Float  // Q
    private let measurementNoise: Float  // R

    init(processNoise: Float, measurementNoise: Float) {
        self.processNoise = processNoise
        self.measurementNoise = measurementNoise
    }

    mutating func update(_ value: Float) -> Float {
        if let currentEstimate = estimate {
            // Prediction step
            let predictedEstimate = currentEstimate
            let predictedErrorCovariance = errorCovariance + processNoise

            // Update step
            let kalmanGain = predictedErrorCovariance / (predictedErrorCovariance + measurementNoise)
            estimate = predictedEstimate + kalmanGain * (value - predictedEstimate)
            errorCovariance = (1.0 - kalmanGain) * predictedErrorCovariance
        } else {
            // Initialize with first measurement
            estimate = value
            errorCovariance = measurementNoise
        }

        return estimate!
    }

    mutating func reset() {
        estimate = nil
        errorCovariance = 1.0
    }
}

// MARK: - Windowed Average Filter

/// Simple moving average over a fixed window of samples
///
/// Computes average of the last N samples. Simpler than EMA/Kalman but introduces
/// more latency (half the window size).
///
/// ## Characteristics
/// - Easy to understand and tune
/// - Predictable latency (windowSize / 2)
/// - Removes high-frequency noise well
/// - Can cause "lag" feeling if window too large
///
/// ## Window Size Guidelines
/// - 3-5 samples: Light smoothing, responsive
/// - 5-10 samples: Moderate smoothing, slight lag
/// - 10-20 samples: Heavy smoothing, noticeable lag
///
/// ## Performance
/// - O(1) time complexity (circular buffer)
/// - O(N) space complexity (stores window)
/// - ~10-15 CPU cycles per update
struct WindowedAverageFilter: SmoothingFilterProtocol {
    private var window: [Float] = []
    private let windowSize: Int
    private var sum: Float = 0

    init(windowSize: Int) {
        self.windowSize = max(1, windowSize)
    }

    mutating func update(_ value: Float) -> Float {
        window.append(value)
        sum += value

        if window.count > windowSize {
            sum -= window.removeFirst()
        }

        return sum / Float(window.count)
    }

    mutating func reset() {
        window.removeAll()
        sum = 0
    }
}

// MARK: - Filter Manager

/// Manages multiple smoothing filters for different data streams
///
/// Maintains a dictionary of filters keyed by identifier (e.g., blend shape name).
/// Lazily creates filters on first use based on configuration.
///
/// ## Thread Safety
/// **NOT thread-safe.** Create one FilterManager per thread or protect with locks.
public final class FilterManager {
    private var filters: [String: any SmoothingFilterProtocol] = [:]
    private let config: SmoothingConfig

    public init(config: SmoothingConfig) {
        self.config = config
    }

    /// Update value through appropriate filter
    public func update(key: String, value: Float) -> Float {
        if filters[key] == nil {
            let filterType = config.filter(for: key)
            filters[key] = filterType.makeFilter()
        }
        return filters[key]!.update(value)
    }

    /// Reset specific filter
    public func reset(key: String) {
        filters[key]?.reset()
    }

    /// Reset all filters
    public func resetAll() {
        for key in filters.keys {
            filters[key]?.reset()
        }
    }

    /// Remove unused filters to free memory
    public func prune(activeKeys: Set<String>) {
        let keysToRemove = filters.keys.filter { !activeKeys.contains($0) }
        for key in keysToRemove {
            filters.removeValue(forKey: key)
        }
    }
}

// MARK: - Skeletal Smoothing

/// Smoothing configuration for skeletal/joint data
///
/// Skeleton data often requires different smoothing than blend shapes:
/// - Position smoothing: Reduce positional jitter
/// - Rotation smoothing: Reduce angular jitter (quaternion space)
/// - Scale smoothing: Usually not needed
public struct SkeletonSmoothingConfig: Sendable {
    public var positionFilter: SmoothingFilter
    public var rotationFilter: SmoothingFilter
    public var scaleFilter: SmoothingFilter

    public init(
        positionFilter: SmoothingFilter = .ema(alpha: 0.3),
        rotationFilter: SmoothingFilter = .ema(alpha: 0.2),
        scaleFilter: SmoothingFilter = .none
    ) {
        self.positionFilter = positionFilter
        self.rotationFilter = rotationFilter
        self.scaleFilter = scaleFilter
    }

    /// Default skeletal smoothing (moderate smoothing for position/rotation)
    public static let `default` = SkeletonSmoothingConfig()

    /// Low latency skeletal smoothing
    public static let lowLatency = SkeletonSmoothingConfig(
        positionFilter: .ema(alpha: 0.7),
        rotationFilter: .ema(alpha: 0.7)
    )

    /// Heavy skeletal smoothing (for cinematic capture)
    public static let smooth = SkeletonSmoothingConfig(
        positionFilter: .kalman(processNoise: 0.01, measurementNoise: 0.1),
        rotationFilter: .kalman(processNoise: 0.01, measurementNoise: 0.05)
    )
}

/// Manages smoothing for skeletal joint data
///
/// Handles smoothing of position, rotation (quaternion), and scale components separately.
/// Rotation smoothing uses quaternion SLERP for proper angular interpolation.
public final class SkeletonFilterManager {
    private struct Vec3FilterState {
        var x: any SmoothingFilterProtocol
        var y: any SmoothingFilterProtocol
        var z: any SmoothingFilterProtocol

        mutating func update(_ value: SIMD3<Float>) -> SIMD3<Float> {
            return SIMD3<Float>(
                x.update(value.x),
                y.update(value.y),
                z.update(value.z)
            )
        }

        mutating func reset() {
            x.reset()
            y.reset()
            z.reset()
        }
    }

    private var positionFilters: [String: Vec3FilterState] = [:]
    private var rotationFilters: [String: any SmoothingFilterProtocol] = [:]
    private var scaleFilters: [String: Vec3FilterState] = [:]

    // Store previous quaternions for SLERP interpolation
    private var previousRotations: [String: simd_quatf] = [:]

    private let config: SkeletonSmoothingConfig

    public init(config: SkeletonSmoothingConfig) {
        self.config = config
    }

    /// Smooth a 3D position vector
    public func updatePosition(joint: String, position: SIMD3<Float>) -> SIMD3<Float> {
        if positionFilters[joint] == nil {
            let filterType = config.positionFilter
            positionFilters[joint] = Vec3FilterState(
                x: filterType.makeFilter(),
                y: filterType.makeFilter(),
                z: filterType.makeFilter()
            )
        }

        guard var state = positionFilters[joint] else {
            return position
        }

        let filtered = state.update(position)
        positionFilters[joint] = state
        return filtered
    }

    /// Smooth a quaternion rotation using SLERP interpolation
    ///
    /// Uses spherical linear interpolation (SLERP) for proper quaternion smoothing.
    /// The filter is applied to the interpolation parameter (t) rather than individual
    /// quaternion components, avoiding gimbal lock and ensuring shortest-path rotation.
    ///
    /// ## Algorithm
    /// 1. Get previous smoothed quaternion (or use current if first frame)
    /// 2. Ensure quaternions are on same hemisphere (handle double-cover)
    /// 3. Apply filter to get smoothed interpolation parameter (0 = previous, 1 = new)
    /// 4. Use simd_slerp to interpolate between previous and new rotation
    ///
    /// ## Performance
    /// - SLERP: ~10-15 CPU cycles
    /// - Filter: ~3-5 cycles (EMA) or ~15-20 cycles (Kalman)
    /// - Total: ~15-35 cycles per joint
    public func updateRotation(joint: String, rotation: simd_quatf) -> simd_quatf {
        // Initialize filter on first use
        if rotationFilters[joint] == nil {
            var filter = config.rotationFilter.makeFilter()
            // Prime blend factor at 0 so the first smoothed update lerps partway to the target
            _ = filter.update(0.0)
            rotationFilters[joint] = filter
        }

        // Get previous rotation (or use identity if first frame)
        let previous = previousRotations[joint] ?? simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)

        // Ensure quaternions are on same hemisphere (shortest path)
        // If dot product is negative, negate one quaternion to take shorter arc
        var adjustedRotation = rotation
        let dot = simd_dot(previous.vector, rotation.vector)
        if dot < 0 {
            adjustedRotation = simd_quatf(vector: -rotation.vector)
        }

        // Apply filter to interpolation parameter
        // Filter outputs value in [0, 1] where:
        // - 0 = use previous rotation (maximum smoothing)
        // - 1 = use new rotation (no smoothing)
        var filter = rotationFilters[joint]!
        let t = filter.update(1.0)
        rotationFilters[joint] = filter

        // SLERP between previous and new rotation
        let smoothed = simd_slerp(previous, adjustedRotation, t)

        // Store for next frame
        previousRotations[joint] = smoothed

        return smoothed
    }

    /// Reset all filters for a specific joint
    public func reset(joint: String) {
        positionFilters.removeValue(forKey: joint)
        rotationFilters.removeValue(forKey: joint)
        scaleFilters.removeValue(forKey: joint)
        previousRotations.removeValue(forKey: joint)
    }

    /// Reset all filters
    public func resetAll() {
        positionFilters.removeAll()
        rotationFilters.removeAll()
        scaleFilters.removeAll()
        previousRotations.removeAll()
    }
}
