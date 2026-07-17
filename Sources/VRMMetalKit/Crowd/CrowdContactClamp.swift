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

/// Pure geometry for the contact-aware clamp (Component A, design §2): given the
/// avatars' world-space torso capsules, decide the smallest shared placement
/// radius (`halfSeparation`) that keeps the closest torso pair overlapping by no
/// more than `bodyContactMargin`.
///
/// `CrowdPlacement` positions every avatar on a circle of radius `halfSeparation`,
/// so pushing the whole ring out by ∆radius grows the closest chord by
/// `2·sin(π/N)·∆radius` (for two avatars, `2·∆radius`). The clamp only ever
/// *raises* the radius — it prevents deep clip-through, never pulls avatars in —
/// and is a one-frame-lagged feedback (§4) that BOUNDS the overlap at the margin:
/// the bump lands the re-measured overlap exactly on the margin, `excess > 0` then
/// passes the driver through until the overlap re-exceeds — a period-2 oscillation
/// around the margin in exact arithmetic, pinned within float rounding in practice
/// and never diverging. Worst case is a bounded root tremor of amplitude
/// (overlap−margin)/chordFactor, not a drift.
public enum CrowdContactClamp {

    /// Largest pairwise surface overlap among the torso capsules (`0` when the
    /// closest pair is separated). `nil` entries (rigs without a torso) are skipped.
    public static func maxOverlap(torsos: [CapsuleCollider?]) -> Float {
        let present = torsos.compactMap { $0 }
        guard present.count >= 2 else { return 0 }
        var maxOv: Float = 0
        for i in 0..<present.count {
            for j in (i + 1)..<present.count {
                let dist = segmentDistance(present[i].p0, present[i].p1, present[j].p0, present[j].p1)
                let overlap = present[i].radius + present[j].radius - dist
                if overlap > maxOv { maxOv = overlap }
            }
        }
        return maxOv
    }

    /// The applied `halfSeparation` for this frame: the driver's proposal, raised
    /// just enough that the closest torso pair overlaps by at most `margin`.
    ///
    /// `lastAppliedHalfSep` is the radius the `torsos` were measured at (the prior
    /// frame's applied value); the excess overlap is converted back into a radius
    /// bump via the chord factor `2·sin(π/N)`. Returns `max(driverHalfSep, floor)`
    /// so the driver still governs approach/hold/part whenever it is already at or
    /// beyond the contact floor.
    public static func clampedHalfSeparation(driverHalfSep: Float, lastAppliedHalfSep: Float,
                                             torsos: [CapsuleCollider?], avatarCount: Int,
                                             margin: Float) -> Float {
        let overlap = maxOverlap(torsos: torsos)
        let excess = overlap - margin
        guard excess > 0 else { return driverHalfSep }
        let n = max(2, avatarCount)
        let chordFactor = 2 * sin(Float.pi / Float(n))   // d(chord)/d(radius)
        let radiusBump = chordFactor > 1e-5 ? excess / chordFactor : excess * 0.5
        let floor = lastAppliedHalfSep + radiusBump
        return max(driverHalfSep, floor)
    }

    /// Closest points between segments `[a0,a1]` and `[b0,b1]` (clamped).
    /// `segmentDistance` is its length; exposed so callers that need a
    /// direction (e.g. the stagger shove's push direction) share the same
    /// Ericson routine.
    public static func closestPoints(_ a0: SIMD3<Float>, _ a1: SIMD3<Float>,
                                     _ b0: SIMD3<Float>, _ b1: SIMD3<Float>) -> (onA: SIMD3<Float>, onB: SIMD3<Float>) {
        let d1 = a1 - a0        // direction of segment A
        let d2 = b1 - b0        // direction of segment B
        let r = a0 - b0
        let aa = simd_dot(d1, d1)
        let ee = simd_dot(d2, d2)
        let f = simd_dot(d2, r)

        var s: Float = 0
        var t: Float = 0
        let eps: Float = 1e-8
        if aa <= eps && ee <= eps {
            return (a0, b0)     // both degenerate to points
        }
        if aa <= eps {
            s = 0
            t = simd_clamp(f / ee, 0, 1)
        } else {
            let c = simd_dot(d1, r)
            if ee <= eps {
                t = 0
                s = simd_clamp(-c / aa, 0, 1)
            } else {
                let b = simd_dot(d1, d2)
                let denom = aa * ee - b * b
                s = denom > eps ? simd_clamp((b * f - c * ee) / denom, 0, 1) : 0
                t = (b * s + f) / ee
                if t < 0 { t = 0; s = simd_clamp(-c / aa, 0, 1) }
                else if t > 1 { t = 1; s = simd_clamp((b - c) / aa, 0, 1) }
            }
        }
        let closestA = a0 + d1 * s
        let closestB = b0 + d2 * t
        return (closestA, closestB)
    }

    /// Shortest distance between segments `[a0,a1]` and `[b0,b1]` (clamped closest
    /// points). Standard Ericson routine; robust to parallel/degenerate segments.
    public static func segmentDistance(_ a0: SIMD3<Float>, _ a1: SIMD3<Float>,
                                       _ b0: SIMD3<Float>, _ b1: SIMD3<Float>) -> Float {
        let pts = closestPoints(a0, a1, b0, b1)
        return simd_length(pts.onA - pts.onB)
    }
}
