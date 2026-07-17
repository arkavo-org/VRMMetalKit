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

/// Coordinates cross-avatar spring-bone contact across independently-stateful
/// `SpringBoneComputeSystem`s (design §2.1, §3). Owns ONLY membership and the
/// snapshot->inject ordering; holds NO per-model simulation state. Each system
/// remains the sole owner of its own mirror.
///
/// Usage per frame (option (b), one-frame-lagged): after ALL participants'
/// last-frame render commits, call `exchange()` once, then run each
/// participant's `update()`/render as usual.
public final class SpringBoneContactGroup {
    private struct Member {
        let system: SpringBoneComputeSystem
        var model: VRMModel
        /// Per-source firmness (subsystem 4): how firmly THIS avatar's body
        /// pushes others' spring bones. 1.0 = full (default), 0.0 = ghost.
        var responseScale: Float = 1.0
    }
    private var members: [Member] = []

    public init() {}

    /// Adds a participant. Re-joining with a system that is already a member
    /// REPLACES its model in place (keeping its `responseScale`) instead of
    /// appending a duplicate: `VRMRenderer.springBoneComputeSystem` is created
    /// once per renderer and reused across `loadModel`, and the documented usage
    /// is "call `joinContactGroup` after `loadModel`", so a model reload re-joins
    /// the same system. A duplicate entry would keep injecting the OLD model's
    /// colliders into partners (ghost) and, since `nearestPartnerIndices` only
    /// excludes the receiver's own index, would become the system's own nearest
    /// partner (self-collision).
    ///
    /// Not `public`: `SpringBoneComputeSystem` is package-internal, so this
    /// method's access level follows its parameter type (Swift requires a
    /// public method's signature to be built only from public types).
    func add(system: SpringBoneComputeSystem, model: VRMModel) {
        if let existing = members.firstIndex(where: { $0.system === system }) {
            members[existing].model = model
            return
        }
        members.append(Member(system: system, model: model))
    }

    /// Not `public`: see `add(system:model:)`. Clears the departing system's
    /// injected foreign colliders (`setForeignColliders` docs: "a departed
    /// partner leaves no ghost") — `exchange()` never revisits a removed
    /// member, so without this the last-injected tail would persist
    /// indefinitely. Every removal path goes through here, so this is the
    /// coordinator's contract, not the caller's (design §4.1, §8.1).
    func remove(system: SpringBoneComputeSystem) {
        members.removeAll { $0.system === system }
        system.setForeignColliders(ForeignColliderSnapshot())
    }

    /// Sets how firmly `system`'s avatar body pushes OTHER participants' spring
    /// bones (subsystem 4, per-source): 1.0 = full (default), 0.5 = gentle,
    /// 0.0 = ghost. Not `public` (takes the internal system); app code calls it
    /// through `VRMRenderer.setContactResponseScale(_:in:)`.
    func setResponseScale(_ scale: Float, for system: SpringBoneComputeSystem) {
        for i in members.indices where members[i].system === system {
            members[i].responseScale = max(0, min(scale, 1))
        }
    }

    /// Phase 1 (snapshot all) + Phase 2 (inject union-minus-self). Precondition
    /// (design §3.2): call after ALL participants' node transforms are in their
    /// last-frame-committed state — the caller sequences this after every
    /// participant's render commit, not merely after "a" commit.
    public func exchange() {
        // Phase 1: pure snapshots, no integrate, no mirror mutation.
        let snapshots = members.map { $0.system.contactColliderSnapshot(model: $0.model) }
        let positions = snapshots.map { Self.centroid(of: $0) }
        // A participant with an empty snapshot (e.g. no humanoid → no torso/arm/head
        // colliders) has no meaningful body position: its centroid falls back to the
        // origin. Exclude such participants from partner SELECTION so they can't sort
        // in at the origin and displace a genuinely nearby partner from the fixed-K
        // slot set (they inject nothing anyway). They still RECEIVE contact below.
        let empty = snapshots.map { $0.spheres.isEmpty && $0.capsules.isEmpty }
        let k = VRMConstants.Physics.maxContactPartners
        // Phase 2: NEAREST-K union-minus-self per participant, then inject.
        // Nearest-K is physically motivated, not just a memory bound: an avatar
        // only contacts nearby neighbours, so keeping the closest K partners is
        // both correct physics (you don't collide with someone across the room)
        // and a bounded-memory guarantee — the union fits the fixed reserved tail
        // for ANY crowd size. When capped it drops the FARTHEST partners, never an
        // arbitrary tail.
        for (i, member) in members.enumerated() {
            var spheres: [SphereCollider] = []
            var capsules: [CapsuleCollider] = []
            for j in Self.nearestPartnerIndices(positions: positions, for: i, count: k, excludingEmpty: empty) {
                // Tag each partner's colliders with THAT partner's firmness
                // (per-source), so avatar i yields to a gentle partner softly and
                // a firm partner firmly (subsystem 4).
                let scale = members[j].responseScale
                spheres.append(contentsOf: snapshots[j].spheres.map { var s = $0; s.responseScale = scale; return s })
                capsules.append(contentsOf: snapshots[j].capsules.map { var c = $0; c.responseScale = scale; return c })
            }
            member.system.setForeignColliders(ForeignColliderSnapshot(spheres: spheres, capsules: capsules))
        }
    }

    /// Indices of the `count` members nearest to member `i` (excluding `i`),
    /// ranked by centroid distance (nearest first). Pure and testable — the
    /// nearest-K partner selection that makes cross-avatar contact correct and
    /// bounded for arbitrary crowd sizes.
    ///
    /// `emptyMask`, when non-empty, marks participants whose contact snapshot is
    /// empty; those indices are excluded from candidacy so an origin-defaulted
    /// empty participant can't displace a real nearby partner from the fixed-K set.
    /// Defaults to no exclusion.
    static func nearestPartnerIndices(positions: [SIMD3<Float>], for i: Int, count: Int,
                                      excludingEmpty emptyMask: [Bool] = []) -> ArraySlice<Int> {
        let others = (0..<positions.count).filter { $0 != i && (emptyMask.isEmpty || !emptyMask[$0]) }
        let sorted = others.sorted {
            simd_distance_squared(positions[i], positions[$0]) < simd_distance_squared(positions[i], positions[$1])
        }
        return sorted.prefix(count)
    }

    /// Centroid of a contact snapshot (sphere centres + capsule midpoints), used
    /// to rank partner proximity. Returns the origin for an empty snapshot.
    static func centroid(of snap: ForeignColliderSnapshot) -> SIMD3<Float> {
        var sum = SIMD3<Float>(0, 0, 0)
        var n = 0
        for s in snap.spheres { sum += s.center; n += 1 }
        for c in snap.capsules { sum += (c.p0 + c.p1) * 0.5; n += 1 }
        return n > 0 ? sum / Float(n) : sum
    }
}
