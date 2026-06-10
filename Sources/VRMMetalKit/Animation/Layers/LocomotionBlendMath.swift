import Foundation

/// Pure blend math for the 1-D locomotion blend space (locomotion design
/// §5). Stateless and clock-free by construction: a function from speed to
/// weights/rate.
///
/// Low-speed policy: below `kneeFraction` of the walk entry's stride speed,
/// speed is expressed by idle↔walk WEIGHT blending with walk at its
/// authored rate; above the knee, weight continues to saturate while
/// playback RATE stays authored until full walk weight, then rate scales
/// speed/strideSpeed clamped to [minRate, maxRate] so neither moonwalk nor
/// benny-hill is reachable.
public struct LocomotionBlendMath: Sendable {
    public static let minRate: Float = 0.75
    public static let maxRate: Float = 1.3
    /// Fraction of stride speed where weight blending hands over to rate
    /// scaling. Tunable (design §5).
    public var kneeFraction: Float = 0.5

    public let walkStrideSpeed: Float

    public init(walkStrideSpeed: Float, kneeFraction: Float = 0.5) {
        precondition(walkStrideSpeed > 0, "walk entry must have strideSpeed > 0; idle is the speed-0 entry")
        self.walkStrideSpeed = walkStrideSpeed
        self.kneeFraction = kneeFraction
    }

    public struct Blend: Sendable, Equatable {
        public var idleWeight: Float
        public var walkWeight: Float
        /// Playback-rate multiplier for the walk clip (1.0 = authored).
        public var walkRate: Float
    }

    public func blend(forSpeed rawSpeed: Float) -> Blend {
        let speed = max(0, rawSpeed)
        if speed <= 0 {
            return Blend(idleWeight: 1, walkWeight: 0, walkRate: 1)
        }
        if speed < walkStrideSpeed {
            // Weight expresses speed up to the stride speed; walk stays at
            // its authored rate (residual ground-speed mismatch between the
            // knee and full weight is the IK layer's plant correction to
            // absorb).
            let w = speed / walkStrideSpeed
            return Blend(idleWeight: 1 - w, walkWeight: w, walkRate: 1)
        }
        // At/above stride speed: full walk; rate carries the difference.
        let rate = min(Self.maxRate, max(Self.minRate, speed / walkStrideSpeed))
        return Blend(idleWeight: 0, walkWeight: 1, walkRate: rate)
    }
}
