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
        let model: VRMModel
    }
    private var members: [Member] = []

    public init() {}

    /// Adds a participant. Fails loudly if the participant cannot support
    /// cross-avatar contact (interpolation off), rather than silently yielding
    /// to no one (design §4.3).
    ///
    /// Not `public`: `SpringBoneComputeSystem` is package-internal, so this
    /// method's access level follows its parameter type (Swift requires a
    /// public method's signature to be built only from public types).
    func add(system: SpringBoneComputeSystem, model: VRMModel) {
        if !VRMConstants.Physics.enableRootInterpolation {
            assertionFailure("SpringBoneContactGroup requires enableRootInterpolation == true; v1 foreign injection hooks only the interpolation path (design §4.3).")
            vrmLogPhysics("❌ [SpringBoneContactGroup] enableRootInterpolation is off; participant will not receive cross-avatar contact.")
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

    /// Phase 1 (snapshot all) + Phase 2 (inject union-minus-self). Precondition
    /// (design §3.2): call after ALL participants' node transforms are in their
    /// last-frame-committed state — the caller sequences this after every
    /// participant's render commit, not merely after "a" commit.
    public func exchange() {
        // Phase 1: pure snapshots, no integrate, no mirror mutation.
        let snapshots = members.map { $0.system.contactColliderSnapshot(model: $0.model) }
        // Phase 2: union-minus-self per participant, then inject (replace-or-clear).
        for (i, member) in members.enumerated() {
            var spheres: [SphereCollider] = []
            var capsules: [CapsuleCollider] = []
            for (j, snap) in snapshots.enumerated() where j != i {
                spheres.append(contentsOf: snap.spheres)
                capsules.append(contentsOf: snap.capsules)
            }
            member.system.setForeignColliders(ForeignColliderSnapshot(spheres: spheres, capsules: capsules))
        }
    }
}
