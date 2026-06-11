//
// Copyright 2026 Arkavo
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

/// Pure blend math for the 1-D locomotion blend space (locomotion design
/// §5). Stateless and clock-free by construction: a function from speed to
/// weights/rate.
///
/// Curve: weight expresses speed linearly up to the walk entry's stride speed
/// (walkWeight = speed / strideSpeed, walkRate = 1.0 = authored). At or
/// above stride speed the walk weight saturates at 1 and playback rate scales
/// speed / strideSpeed, clamped to [minRate, maxRate] so neither moonwalk
/// nor benny-hill is reachable.
///
/// Curve shaping (knee tunables) lands with M3 tuning.
public struct LocomotionBlendMath: Sendable {
    public static let minRate: Float = 0.75
    public static let maxRate: Float = 1.3

    public let walkStrideSpeed: Float

    public init(walkStrideSpeed: Float) {
        precondition(walkStrideSpeed > 0, "walk entry must have strideSpeed > 0; idle is the speed-0 entry")
        self.walkStrideSpeed = walkStrideSpeed
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
