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

import XCTest
import Metal
import simd
@testable import GLTFMetalKit

/// Phase 3b animation acceptance: parse glTF animation clips, sample them
/// at multiple times, and verify the rebuilt draw list reflects the
/// animated transforms.
///
/// Test fixture: Khronos `BoxAnimated.glb` — a cube with a rotation
/// animation. The same cube at t=0 vs t=halfway-through should produce
/// distinct world-space draw calls.
final class GLTFAnimationTests: XCTestCase {

    func testSamplerLinearInterpolatesCorrectly() {
        // Hand-built sampler: 2 keyframes, scalar values 0 → 10 between t=0 and t=1.
        let sampler = GLTFRuntimeSampler(
            times: [0.0, 1.0],
            values: [0.0, 10.0],
            interpolation: .linear,
            componentsPerKeyframe: 1
        )
        XCTAssertEqual(sampler.sample(at: 0.0)[0], 0.0, accuracy: 1e-5)
        XCTAssertEqual(sampler.sample(at: 0.25)[0], 2.5, accuracy: 1e-5)
        XCTAssertEqual(sampler.sample(at: 0.5)[0], 5.0, accuracy: 1e-5)
        XCTAssertEqual(sampler.sample(at: 1.0)[0], 10.0, accuracy: 1e-5)
        // Clamps outside range.
        XCTAssertEqual(sampler.sample(at: -1)[0], 0.0, accuracy: 1e-5)
        XCTAssertEqual(sampler.sample(at: 2)[0], 10.0, accuracy: 1e-5)
    }

    func testSamplerStepUsesPreviousKeyframe() {
        let sampler = GLTFRuntimeSampler(
            times: [0.0, 1.0, 2.0],
            values: [0.0, 10.0, 20.0],
            interpolation: .step,
            componentsPerKeyframe: 1
        )
        XCTAssertEqual(sampler.sample(at: 0.0)[0], 0.0)
        XCTAssertEqual(sampler.sample(at: 0.5)[0], 0.0)
        XCTAssertEqual(sampler.sample(at: 1.0)[0], 10.0)
        XCTAssertEqual(sampler.sample(at: 1.99)[0], 10.0)
        XCTAssertEqual(sampler.sample(at: 2.0)[0], 20.0)
    }

    func testSamplerRotationLerpRenormalizes() {
        // Two unit quaternions; midpoint should still be unit length after lerp+renorm.
        let q0 = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
        let q1 = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 1, 0))
        let sampler = GLTFRuntimeSampler(
            times: [0.0, 1.0],
            values: [q0.imag.x, q0.imag.y, q0.imag.z, q0.real,
                     q1.imag.x, q1.imag.y, q1.imag.z, q1.real],
            interpolation: .linear,
            componentsPerKeyframe: 4
        )
        let v = sampler.sample(at: 0.5)
        let len = sqrt(v[0]*v[0] + v[1]*v[1] + v[2]*v[2] + v[3]*v[3])
        XCTAssertEqual(len, 1.0, accuracy: 1e-4,
            "Rotation lerp should renormalize to unit length, got \(len)")
    }

    func testLoadsBoxAnimatedAndParsesAClip() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available (CI without GPU)")
        }
        guard let url = Bundle.module.url(forResource: "BoxAnimated", withExtension: "glb", subdirectory: "TestData") else {
            throw XCTSkip("BoxAnimated.glb not bundled")
        }

        let loader = GLTFAssetLoader()
        let asset = try await loader.load(from: url, device: device)

        XCTAssertGreaterThan(asset.animations.count, 0,
            "BoxAnimated.glb should declare at least one animation clip.")
        let clip = asset.animations[0]
        XCTAssertGreaterThan(clip.channels.count, 0, "Clip has no channels — parse failed silently.")
        XCTAssertGreaterThan(clip.duration, 0, "Clip duration is zero — likely no time keyframes parsed.")
    }

    /// The credibility check: rebuilding the draw list at two different
    /// animation times should produce *different* model matrices. If the
    /// asset's `drawCalls(animationIndex:time:)` path is broken, both
    /// invocations return the same bind-pose draws.
    func testAnimationProducesDifferentModelMatrices() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available (CI without GPU)")
        }
        guard let url = Bundle.module.url(forResource: "BoxAnimated", withExtension: "glb", subdirectory: "TestData") else {
            throw XCTSkip("BoxAnimated.glb not bundled")
        }

        let loader = GLTFAssetLoader()
        let asset = try await loader.load(from: url, device: device)
        guard !asset.animations.isEmpty else {
            XCTFail("BoxAnimated.glb has no animations to test"); return
        }

        let duration = asset.animations[0].duration
        let t0 = duration * 0.0
        let t1 = duration * 0.5

        let drawsAtT0 = asset.drawCalls(animationIndex: 0, time: t0)
        let drawsAtT1 = asset.drawCalls(animationIndex: 0, time: t1)

        XCTAssertEqual(drawsAtT0.count, drawsAtT1.count,
            "Animation rebuild changed draw-call count — scene-traversal regression.")
        XCTAssertGreaterThan(drawsAtT0.count, 0)

        // Check at least one draw's model matrix differs meaningfully between the two times.
        var totalDelta: Float = 0
        for (a, b) in zip(drawsAtT0, drawsAtT1) {
            // Frobenius norm of (a - b) over the 4×4 matrices.
            let ma = a.modelMatrix
            let mb = b.modelMatrix
            for col in 0..<4 {
                let da = ma[col] - mb[col]
                totalDelta += abs(da.x) + abs(da.y) + abs(da.z) + abs(da.w)
            }
        }
        XCTAssertGreaterThan(totalDelta, 0.01,
            "Animation produced identical draw calls at t=0 and t=duration/2 (Δ=\(totalDelta)) — sampler/rebuild not landing.")
    }
}
