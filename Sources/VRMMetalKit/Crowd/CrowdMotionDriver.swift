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

/// Pure scripted approach-and-part separation curve for the crowd collision
/// demo (design §4.2). Position-only: returns the current half-distance from
/// the scene center along the approach axis; `CrowdPlacement` maps it to each
/// avatar's world translation. All windows are normalized clip time in [0,1].
///
/// The `holdSeparation` half-distance is coupled to the torso capsule radius
/// (`SpringBoneContactColliderSet.torsoRadiusFractionOfLength`, design §4.3) —
/// together they decide whether torso capsules just touch (yield) or
/// interpenetrate (clip). Calibrate the pair, not either alone.
public struct CrowdMotionDriver {
    public let startSep: Float
    public let holdSep: Float
    public let approachStart: Float
    public let approachEnd: Float
    public let holdEnd: Float
    public let partEnd: Float

    public init(startSep: Float, holdSep: Float,
                approachStart: Float, approachEnd: Float, holdEnd: Float, partEnd: Float) {
        self.startSep = startSep
        self.holdSep = holdSep
        self.approachStart = approachStart
        self.approachEnd = approachEnd
        self.holdEnd = holdEnd
        self.partEnd = partEnd
    }

    /// Current half-separation at normalized clip time `t` (clamped to [0,1]).
    public func halfSeparation(at t: Float) -> Float {
        let tt = min(max(t, 0), 1)
        if tt <= approachStart { return startSep }
        if tt < approachEnd {
            let u = smoothstep((tt - approachStart) / (approachEnd - approachStart))
            return mix(startSep, holdSep, u)
        }
        if tt <= holdEnd { return holdSep }
        if tt < partEnd {
            let u = smoothstep((tt - holdEnd) / (partEnd - holdEnd))
            return mix(holdSep, startSep, u)
        }
        return startSep
    }

    private func smoothstep(_ x: Float) -> Float {
        let c = min(max(x, 0), 1)
        return c * c * (3 - 2 * c)
    }
    private func mix(_ a: Float, _ b: Float, _ u: Float) -> Float { a + (b - a) * u }
}
