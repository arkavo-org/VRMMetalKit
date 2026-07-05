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

/// Per-avatar placement for the crowd collision demo (design §4.1). For two
/// avatars: opposite ends of the X axis, each facing inward toward the center
/// so they meet chest-to-chest. Facing is baked here (set once at setup); the
/// motion driver contributes only translation along the approach axis.
///
/// For `avatarCount > 2` the avatars ring around the center facing inward — a
/// documented stretch; v1 targets and tests `avatarCount == 2`.
public enum CrowdPlacement {

    /// World-space root translation for `avatarIndex` given the current
    /// `halfSeparation` (distance from center). Two avatars sit at ∓halfSep on X;
    /// N>2 ring on a circle of that radius.
    public static func rootTranslation(avatarIndex: Int, avatarCount: Int, halfSeparation: Float) -> SIMD3<Float> {
        let pos = circlePosition(avatarIndex: avatarIndex, avatarCount: avatarCount, radius: halfSeparation)
        return pos
    }

    /// Inward-facing yaw for `avatarIndex`: +Z forward rotated to point from the
    /// avatar's position toward the center.
    public static func facing(avatarIndex: Int, avatarCount: Int) -> simd_quatf {
        // Facing uses a unit radius; direction is scale-invariant.
        let pos = circlePosition(avatarIndex: avatarIndex, avatarCount: avatarCount, radius: 1)
        let toCenter = -pos
        let len = simd_length(SIMD3<Float>(toCenter.x, 0, toCenter.z))
        guard len > 1e-5 else { return simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0)) }
        let dir = SIMD3<Float>(toCenter.x, 0, toCenter.z) / len
        // Yaw so +Z maps onto `dir`: rotation about +Y by atan2(dir.x, dir.z).
        let yaw = atan2(dir.x, dir.z)
        return simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0))
    }

    private static func circlePosition(avatarIndex: Int, avatarCount: Int, radius: Float) -> SIMD3<Float> {
        if avatarCount <= 2 {
            // Two avatars on the X axis: index 0 at -radius, index 1 at +radius.
            let x = avatarIndex == 0 ? -radius : radius
            return SIMD3<Float>(x, 0, 0)
        }
        let angle = 2 * Float.pi * Float(avatarIndex) / Float(avatarCount)
        return SIMD3<Float>(sin(angle) * radius, 0, cos(angle) * radius)
    }
}
