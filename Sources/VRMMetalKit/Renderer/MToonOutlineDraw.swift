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

/// Policy for the Guilty Gear-style MToon outline merge: one
/// `drawIndexed(..., instanceCount: 2)` where instance 0 is the shaded
/// surface and instance 1 is the inverted hull.
public enum MToonOutlineDraw {
    /// `[[instance_id]]` of the inverted-hull instance.
    public static let hullInstanceID: UInt32 = 1

    /// Instance count when color and outline share a draw.
    public static let mergedInstanceCount: Int = 2

    /// Index-buffer byte offset for an outline (or merged) draw. Must match
    /// the color draw — never hardcode `0`.
    public static func indexBufferOffset(for primitive: VRMPrimitive) -> Int {
        primitive.indexBufferOffset
    }

    /// `2` when the hull is instanced into the color draw, else `1`.
    public static func instanceCount(mergingOutline: Bool) -> Int {
        mergingOutline ? mergedInstanceCount : 1
    }

    /// Merge only when the outline would actually draw and the mesh is
    /// single-sided. Double-sided materials keep the dedicated outline pass
    /// so both faces stay visible on instance 0.
    public static func shouldMerge(
        globalOutlineWidth: Float,
        mtoon: VRMMToonMaterial?,
        isDoubleSided: Bool
    ) -> Bool {
        guard globalOutlineWidth > 0,
              let mtoon,
              mtoon.outlineWidthMode != .none,
              mtoon.outlineWidthFactor > 0.0001,
              !isDoubleSided else {
            return false
        }
        return true
    }
}
