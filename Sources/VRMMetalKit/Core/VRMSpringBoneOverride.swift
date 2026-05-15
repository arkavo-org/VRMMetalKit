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

/// Runtime clamps applied to authored VRMC_springBone joint parameters before they
/// reach the GPU. Use this to rescue badly-authored assets without modifying the
/// source `.vrm` file.
///
/// All fields default to `nil`, which is a strict no-op: authored values pass
/// through unchanged. When a clamp is set, it applies only to joints whose node
/// name satisfies `jointNameMatches` (or to every named joint when the predicate
/// is `nil`). Joints whose node has no name are never touched.
///
/// Recommended values for assets where hair joints author `gravityPower = 0` and
/// `stiffness ≈ 0.85` (e.g., AvatarSample_A_1.0):
///
/// ```
/// VRMSpringBoneOverride(
///     minGravityPower: 0.5,
///     maxStiffness: 0.7,
///     jointNameMatches: { $0.contains("Hair") }
/// )
/// ```
public struct VRMSpringBoneOverride: Sendable {
    public var minGravityPower: Float?
    public var maxStiffness: Float?
    public var maxDragForce: Float?
    public var jointNameMatches: (@Sendable (String) -> Bool)?

    public static let none = VRMSpringBoneOverride()

    public init(
        minGravityPower: Float? = nil,
        maxStiffness: Float? = nil,
        maxDragForce: Float? = nil,
        jointNameMatches: (@Sendable (String) -> Bool)? = nil
    ) {
        self.minGravityPower = minGravityPower
        self.maxStiffness = maxStiffness
        self.maxDragForce = maxDragForce
        self.jointNameMatches = jointNameMatches
    }

    var isNoOp: Bool {
        minGravityPower == nil && maxStiffness == nil && maxDragForce == nil
    }

    func apply(
        stiffness: Float,
        dragForce: Float,
        gravityPower: Float,
        jointName: String?
    ) -> (stiffness: Float, dragForce: Float, gravityPower: Float) {
        guard !isNoOp, let name = jointName else {
            return (stiffness, dragForce, gravityPower)
        }
        if let predicate = jointNameMatches, !predicate(name) {
            return (stiffness, dragForce, gravityPower)
        }
        var s = stiffness
        var d = dragForce
        var g = gravityPower
        if let cap = maxStiffness, s > cap { s = cap }
        if let cap = maxDragForce, d > cap { d = cap }
        if let floor = minGravityPower, g < floor { g = floor }
        return (s, d, g)
    }
}
