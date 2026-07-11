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

/// Tuning for impact arm counterbalance — the primary human strategy for
/// staying upright after a shove (raise + spread arms, soft elbows).
public struct ArmCounterbalanceParams: Sendable {
    /// Maps impact intensity ∈ [0,1] into raise angle (radians) at full intensity.
    public var maxRaise: Float
    /// Forward reach (radians) on the fall-side arm at full intensity.
    public var maxReach: Float
    /// Lateral spread (radians) so arms open away from the body.
    public var maxSpread: Float
    /// Elbow bend (radians) — soft, not locked straight.
    public var maxElbow: Float
    /// Critically-damped approach rate toward targets (and recovery to rest).
    public var stiffness: Float
    /// Overall 0–1 weight.
    public var blendWeight: Float

    public init(maxRaise: Float = 0.55,   // ~31° — readable raise, not windmill
                maxReach: Float = 0,      // unused (world-axis raise only)
                maxSpread: Float = 0,     // unused
                maxElbow: Float = 0.40,   // ~23°
                stiffness: Float = 14.0,
                blendWeight: Float = 1.0) {
        self.maxRaise = maxRaise
        self.maxReach = maxReach
        self.maxSpread = maxSpread
        self.maxElbow = maxElbow
        self.stiffness = stiffness
        self.blendWeight = blendWeight
    }
}

/// Per-arm local rotation targets (radians) the layer springs toward.
public struct ArmCounterbalancePose: Sendable, Equatable {
    public var leftRaise: Float
    public var rightRaise: Float
    public var leftReach: Float
    public var rightReach: Float
    public var leftSpread: Float
    public var rightSpread: Float
    public var leftElbow: Float
    public var rightElbow: Float
    /// Diagnostic 0–1 activity after blend.
    public var intensity: Float

    public static let zero = ArmCounterbalancePose(
        leftRaise: 0, rightRaise: 0, leftReach: 0, rightReach: 0,
        leftSpread: 0, rightSpread: 0, leftElbow: 0, rightElbow: 0, intensity: 0)

    public init(leftRaise: Float, rightRaise: Float, leftReach: Float, rightReach: Float,
                leftSpread: Float, rightSpread: Float, leftElbow: Float, rightElbow: Float,
                intensity: Float) {
        self.leftRaise = leftRaise
        self.rightRaise = rightRaise
        self.leftReach = leftReach
        self.rightReach = rightReach
        self.leftSpread = leftSpread
        self.rightSpread = rightSpread
        self.leftElbow = leftElbow
        self.rightElbow = rightElbow
        self.intensity = intensity
    }

    public var isActive: Bool { intensity > 0.02 }
}

/// Pure arm-counterbalance math. Humans primarily use the arms to keep the
/// body upright after an impact: both arms rise and open (raise moment of
/// inertia + catch readiness), the fall-side arm reaches more, elbows stay soft.
///
/// Input is character-local fall direction on the ground plane
/// (`+x` = character right, `+y` component of the SIMD2 = character forward /
/// VRM +Z) and an intensity in `[0,1]`.
public struct ArmCounterbalanceSolver: Sendable {
    public var params: ArmCounterbalanceParams
    public private(set) var pose: ArmCounterbalancePose = .zero

    public init(params: ArmCounterbalanceParams = ArmCounterbalanceParams()) {
        self.params = params
    }

    /// Map intensity + local fall direction to a rest-relative target pose.
    /// Fall to the character's right loads the right arm more (catch) and still
    /// raises the left (counterweight); pure forward fall raises both evenly
    /// with forward reach.
    public static func targetPose(intensity: Float,
                                  localFallXZ: SIMD2<Float>,
                                  params: ArmCounterbalanceParams) -> ArmCounterbalancePose {
        let i = simd_clamp(intensity, 0, 1) * simd_clamp(params.blendWeight, 0, 1)
        guard i > 1e-5 else { return .zero }

        let fallLen = simd_length(localFallXZ)
        // Unit local fall; default pure forward when direction is degenerate so
        // a depth-only impact still raises arms (brace).
        let fall = fallLen > 1e-5 ? localFallXZ / fallLen : SIMD2<Float>(0, 1)
        // Lateral bias ∈ [-1, 1]: +1 = falling right.
        let lateral = fall.x
        // Forward bias ∈ [0, 1]: how much of the fall is forward/back (abs).
        let forward = abs(fall.y)

        // Both arms always rise — primary upright strategy. Fall-side gets more.
        let baseRaise = params.maxRaise * i * 0.55
        let sideRaise = params.maxRaise * i * 0.45
        let leftRaise = baseRaise + sideRaise * max(0, -lateral)
        let rightRaise = baseRaise + sideRaise * max(0, lateral)

        // Reach/spread left at 0 by default — layer applies raise+elbow only.
        // Kept in the pose struct for API stability / future axis-safe use.
        let leftReach = params.maxReach * i * (0.35 + 0.65 * forward)
        let rightReach = leftReach
        let leftSpread = params.maxSpread * i * 0.5
        let rightSpread = leftSpread

        // Soft elbows — more bend as intensity grows (catch, not stiff rods).
        let elbow = params.maxElbow * i * (0.55 + 0.45 * forward)

        return ArmCounterbalancePose(
            leftRaise: leftRaise, rightRaise: rightRaise,
            leftReach: leftReach, rightReach: rightReach,
            leftSpread: leftSpread, rightSpread: rightSpread,
            leftElbow: elbow, rightElbow: elbow,
            intensity: i)
    }

    /// Critically-damped step of `pose` toward `target`.
    @discardableResult
    public mutating func update(intensity: Float,
                                localFallXZ: SIMD2<Float>,
                                dt: Float) -> ArmCounterbalancePose {
        let target = Self.targetPose(intensity: intensity,
                                     localFallXZ: localFallXZ,
                                     params: params)
        let a = min(max(params.stiffness, 0) * max(dt, 0), 1)
        pose = ArmCounterbalancePose(
            leftRaise:  pose.leftRaise  + (target.leftRaise  - pose.leftRaise)  * a,
            rightRaise: pose.rightRaise + (target.rightRaise - pose.rightRaise) * a,
            leftReach:  pose.leftReach  + (target.leftReach  - pose.leftReach)  * a,
            rightReach: pose.rightReach + (target.rightReach - pose.rightReach) * a,
            leftSpread: pose.leftSpread + (target.leftSpread - pose.leftSpread) * a,
            rightSpread: pose.rightSpread + (target.rightSpread - pose.rightSpread) * a,
            leftElbow:  pose.leftElbow  + (target.leftElbow  - pose.leftElbow)  * a,
            rightElbow: pose.rightElbow + (target.rightElbow - pose.rightElbow) * a,
            intensity:  pose.intensity  + (target.intensity  - pose.intensity)  * a)
        return pose
    }
}
