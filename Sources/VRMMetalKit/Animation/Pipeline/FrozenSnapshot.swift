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

/// The partner geometry a pipeline stage may read: every avatar's torso capsule
/// as of the last committed frame.
///
/// Stages receive this instead of the live avatar array, which makes live
/// partner reads unwritable rather than merely discouraged. The invariant it
/// enforces — *cross-avatar interaction is interaction with the partner's
/// last-committed frame* — is what keeps stage-major and avatar-major execution
/// equivalent, and what makes contact synchronisation deterministic across
/// processes. Wanting a live partner read means proposing a different execution
/// model.
public struct FrozenSnapshot: Sendable {
    private let torsos: [Int: CapsuleCollider]
    private let indices: [Int]

    /// - Parameters:
    ///   - torsos: world-space torso capsules keyed by avatar index. An avatar
    ///     whose capsule could not be built is simply absent.
    ///   - indices: every participating avatar index, in scheduler order.
    public init(torsos: [Int: CapsuleCollider], indices: [Int]) {
        self.torsos = torsos
        self.indices = indices
    }

    /// This avatar's own lagged capsule, if it has one.
    public func torso(forAvatar avatarIndex: Int) -> CapsuleCollider? {
        torsos[avatarIndex]
    }

    /// The capsule whose centre-segment midpoint is nearest `avatarIndex`'s own,
    /// excluding itself. `nil` when this avatar has no capsule or no partner does.
    public func nearestPartnerTorso(of avatarIndex: Int) -> CapsuleCollider? {
        guard let mine = torsos[avatarIndex] else { return nil }
        let myMid = (mine.p0 + mine.p1) * 0.5
        var best: CapsuleCollider?
        var bestDist = Float.greatestFiniteMagnitude
        for index in indices where index != avatarIndex {
            guard let t = torsos[index] else { continue }
            let d = simd_length((t.p0 + t.p1) * 0.5 - myMid)
            if d < bestDist { bestDist = d; best = t }
        }
        return best
    }
}
