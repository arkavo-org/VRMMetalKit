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

/// Policy for the Guilty Gear-style MToon outline merge: the inverted hull
/// rides along with the material's color draw, reusing its pipeline and every
/// buffer/texture binding instead of being re-encoded by the dedicated outline
/// pass.
///
/// The hull is its own `drawIndexed` — `instanceCount: 1`, `baseInstance:
/// hullInstanceID` so `[[instance_id]]` reports the hull — rather than a second
/// instance of the color draw. Metal has no per-instance depth-stencil state,
/// and a hull that inherits a depth-writing color state stamps depth into a
/// band outside the silhouette at the material's sort position, clipping every
/// later draw that lands in that band.
public enum MToonOutlineDraw {
    /// `[[instance_id]]` the hull draw reports, via `baseInstance`.
    public static let hullInstanceID: UInt32 = 1

    /// Depth-stencil state key the hull must bind, whatever depth policy the
    /// material's own draw uses: test `.lessEqual`, never write. Shared by the
    /// merged hull draw and the dedicated outline pass so the two cannot drift.
    public static let hullDepthStateKey = "blend"

    /// Index-buffer byte offset for an outline (or merged) draw. Must match
    /// the color draw — never hardcode `0`.
    public static func indexBufferOffset(for primitive: VRMPrimitive) -> Int {
        primitive.indexBufferOffset
    }

    /// Merge only when the outline would actually draw and the mesh is
    /// single-sided. Double-sided materials keep the dedicated outline pass
    /// so both faces stay visible on the color draw.
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
