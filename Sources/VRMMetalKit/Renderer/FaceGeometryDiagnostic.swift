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

import Metal
import simd

/// World-space AABB of a primitive's vertex positions, sampled for the
/// frame-0 face-geometry log.
struct FaceGeometryBounds: Equatable {
    var min: SIMD3<Float>
    var max: SIMD3<Float>

    var center: SIMD3<Float> { (min + max) * 0.5 }
    var size: SIMD3<Float> { max - min }
}

/// Computes the position bounds of a primitive for the frame-0 face-geometry
/// diagnostic log.
///
/// Reads `vertexBuffer` in ``VRMPositionVertex`` layout — the position-only
/// stream produced by the vertex/attribute buffer split. Refuses to read
/// past the buffer's allocated length.
enum FaceGeometryDiagnostic {
    static func computeBounds(vertexBuffer: MTLBuffer, vertexCount: Int) -> FaceGeometryBounds? {
        guard vertexCount > 0 else { return nil }
        let requiredBytes = vertexCount * MemoryLayout<VRMPositionVertex>.stride
        guard vertexBuffer.length >= requiredBytes else { return nil }

        let pointer = vertexBuffer.contents().bindMemory(to: VRMPositionVertex.self, capacity: vertexCount)
        var minPos = SIMD3<Float>(repeating: Float.greatestFiniteMagnitude)
        var maxPos = SIMD3<Float>(repeating: -Float.greatestFiniteMagnitude)
        for i in 0..<vertexCount {
            let pos = pointer[i].position
            minPos = simd_min(minPos, pos)
            maxPos = simd_max(maxPos, pos)
        }
        return FaceGeometryBounds(min: minPos, max: maxPos)
    }
}
