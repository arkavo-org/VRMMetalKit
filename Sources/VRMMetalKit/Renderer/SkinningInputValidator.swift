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

/// One-shot sample of a primitive's joint indices and weight sums.
///
/// Vertex `JOINTS_0` / `WEIGHTS_0` are static after load, so the renderer
/// must not walk `attributeBuffer.contents()` every draw.
struct SkinningInputSample: Equatable, Sendable {
    var sampledVertexCount: Int
    var maxJointIndex: Int
    var hasOutOfRangeJoint: Bool
    var hasUnnormalizedWeight: Bool
}

/// Samples skinning attributes once and reuses the result.
enum SkinningInputValidator {
    static let defaultSampleCount = 8

    /// Fills `cache` on the first call that has a vertex buffer. Later calls
    /// return the cached sample and do not read the buffer — even if
    /// `vertexBuffer` is `nil`.
    @discardableResult
    static func resolve(
        cache: inout SkinningInputSample?,
        vertexBuffer: MTLBuffer?,
        vertexCount: Int,
        paletteCount: Int,
        sampleCount: Int = defaultSampleCount
    ) -> SkinningInputSample? {
        if let cached = cache {
            return cached
        }
        guard let vertexBuffer else { return nil }

        let count = min(sampleCount, max(vertexCount, 0))
        guard count > 0 else {
            let empty = SkinningInputSample(
                sampledVertexCount: 0,
                maxJointIndex: 0,
                hasOutOfRangeJoint: false,
                hasUnnormalizedWeight: false
            )
            cache = empty
            return empty
        }

        let pointer = vertexBuffer.contents().bindMemory(to: VRMAttributeVertex.self, capacity: vertexCount)
        var maxJoint = 0
        var outOfRange = false
        var unnormalized = false
        for i in 0..<count {
            let vertex = pointer[i]
            let joints = vertex.joints
            let localMax = Int(max(joints.x, joints.y, joints.z, joints.w))
            if localMax > maxJoint { maxJoint = localMax }
            if localMax >= paletteCount { outOfRange = true }
            let sum = vertex.weights.x + vertex.weights.y + vertex.weights.z + vertex.weights.w
            if sum < 0.99 || sum > 1.01 { unnormalized = true }
        }

        let sample = SkinningInputSample(
            sampledVertexCount: count,
            maxJointIndex: maxJoint,
            hasOutOfRangeJoint: outOfRange,
            hasUnnormalizedWeight: unnormalized
        )
        cache = sample
        return sample
    }
}
