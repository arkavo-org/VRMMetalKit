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

import simd

/// Inverse-transpose of an affine transform's linear 3×3, packed as a 4×4
/// so the existing `normalMatrix * float4(N, 0)` shader path is unchanged.
///
/// Cheaper than `world.inverse.transpose` (no 4×4 inverse) and equal in the
/// upper 3×3 for affine VRM nodes.
enum AffineNormalMatrix {
    static func inverseTranspose(of world: float4x4) -> float4x4 {
        let linear = float3x3(
            SIMD3<Float>(world.columns.0.x, world.columns.0.y, world.columns.0.z),
            SIMD3<Float>(world.columns.1.x, world.columns.1.y, world.columns.1.z),
            SIMD3<Float>(world.columns.2.x, world.columns.2.y, world.columns.2.z)
        )
        let det = simd_determinant(linear)
        guard det.isFinite, abs(det) > 1e-12 else {
            return matrix_identity_float4x4
        }
        let invT = simd_transpose(simd_inverse(linear))
        return float4x4(
            SIMD4<Float>(invT.columns.0, 0),
            SIMD4<Float>(invT.columns.1, 0),
            SIMD4<Float>(invT.columns.2, 0),
            SIMD4<Float>(0, 0, 0, 1)
        )
    }
}
