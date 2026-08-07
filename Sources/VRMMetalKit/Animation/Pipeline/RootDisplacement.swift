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

/// Accumulates one frame's scene-root displacement requests for a single avatar.
///
/// S2 is the sole writer of root and hips, but it is not the sole *requester*:
/// scripted placement, the stagger shove, and later goal-approach motion all
/// contribute. The rule:
///
/// > At most one absolute request per avatar per frame; every other request is
/// > an additive delta applied after it, in insertion order.
///
/// Scripted placement is the absolute writer (it positions the avatar in the
/// scene); the shove and its successors are deltas. A second absolute request
/// means two producers each believe they own placement, which is a wiring bug
/// rather than a value to reconcile.
///
/// The rule is only as real as the accumulator it's checked against:
/// `PoseStage.place` and `PoseStage.displace` — S2's two beats — thread ONE
/// instance per top-level root through `avatar.rootDisplacements` rather than
/// each building its own, so a stray second `setAbsolute` anywhere between
/// `place` and `displace` hits the same accumulator `place` seeded and trips
/// this type's `precondition` instead of silently landing in a blank one.
public struct RootDisplacement: Sendable {
    private var absolute: SIMD3<Float>?
    private var deltas: [SIMD3<Float>] = []

    public init() {}

    /// Whether an absolute request has already been made this frame.
    public var hasAbsolute: Bool { absolute != nil }

    /// Replaces the root translation outright. At most one per avatar per frame.
    public mutating func setAbsolute(_ t: SIMD3<Float>) {
        precondition(absolute == nil, "two absolute root requests in one frame: two producers claim placement")
        absolute = t
    }

    /// Adds a displacement on top of whatever the absolute request (or the base) set.
    public mutating func addDelta(_ d: SIMD3<Float>) {
        deltas.append(d)
    }

    /// The final translation: the absolute request if any, otherwise `base`,
    /// plus every delta in insertion order.
    public func resolve(base: SIMD3<Float>) -> SIMD3<Float> {
        var t = absolute ?? base
        for d in deltas { t += d }
        return t
    }
}
