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

import XCTest
import simd
// Deliberately a plain import, not `@testable`: the visionOS benchmark
// targets (`VRMBenchmark`, the VisionHost app) consume `VRMMetalKit` the
// same way, so this file exercises the same public-API surface they do.
import VRMMetalKit

/// Locks in the projection convention the visionOS benchmarks must use to
/// stay depth-consistent with the live `ImmersiveRenderer` path, which
/// composes `makePerspective` (Metal forward-Z, clip z spans [0, w]) with
/// `reverseZProjection` (near -> 1, far -> 0).
final class VisionOSBenchmarkProjectionTests: XCTestCase {
    private func ndcDepth(_ projection: float4x4, viewZ: Float) -> Float {
        let clip = projection * SIMD4<Float>(0, 0, viewZ, 1)
        return clip.z / clip.w
    }

    /// The classic OpenGL-convention perspective matrix the benchmarks used
    /// before the fix (`Sources/VRMBenchmark/main.swift`'s and
    /// `VisionHost/Sources/VisionOSGPUBench.swift`'s local
    /// `perspectiveMatrix`): clip z spans [-w, w], so ndc z runs -1 (near)
    /// to 1 (far) — a forward mapping, and out of Metal's [0, 1] depth
    /// range to boot. Reproduced locally (not from VRMMetalKit) purely to
    /// document the bug the fix removes from the reverse-Z call sites.
    private func glConventionPerspective(
        fovRadians: Float, aspect: Float, near: Float, far: Float
    ) -> float4x4 {
        let t = tan(fovRadians / 2)
        var r = float4x4()
        r.columns.0 = SIMD4<Float>(1 / (aspect * t), 0, 0, 0)
        r.columns.1 = SIMD4<Float>(0, 1 / t, 0, 0)
        r.columns.2 = SIMD4<Float>(0, 0, -(far + near) / (far - near), -1)
        r.columns.3 = SIMD4<Float>(0, 0, -(2 * far * near) / (far - near), 0)
        return r
    }

    func testGLConventionMatrixIsNotReverseZ() {
        let near: Float = 0.01
        let far: Float = 100.0
        let projection = glConventionPerspective(
            fovRadians: 45.0 * .pi / 180.0, aspect: 1.0, near: near, far: far)
        let nearDepth = ndcDepth(projection, viewZ: -near)
        let farDepth = ndcDepth(projection, viewZ: -far)
        // Forward mapping (near low, far high) — paired with a reverse-Z
        // `.greater` depth compare and a 0.0 clear, this is exactly the
        // inversion the benchmarks shipped with: farther fragments win.
        XCTAssertEqual(nearDepth, -1, accuracy: 0.001)
        XCTAssertEqual(farDepth, 1, accuracy: 0.001)
    }

    func testReverseZProjectionMatchesLivePathConvention() {
        let near: Float = 0.01
        let far: Float = 100.0
        let standard = makePerspective(
            fovyRadians: 45.0 * .pi / 180.0, aspectRatio: 1.0, nearZ: near, farZ: far)
        let projection = reverseZProjection(standard)
        let nearDepth = ndcDepth(projection, viewZ: -near)
        let farDepth = ndcDepth(projection, viewZ: -far)
        XCTAssertEqual(nearDepth, 1, accuracy: 0.001)
        XCTAssertEqual(farDepth, 0, accuracy: 0.001)
    }
}
