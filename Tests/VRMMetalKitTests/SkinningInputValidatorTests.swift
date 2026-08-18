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
import Metal
import simd
@testable import VRMMetalKit

/// Joint / weight data is static after load. Sampling `vertexBuffer.contents()`
/// every draw is wasted CPU traffic. These tests pin the one-shot cache that
/// replaces the per-frame walk in `VRMRenderer.validateSkinningInputs`.
final class SkinningInputValidatorTests: XCTestCase {

    private var device: MTLDevice!

    override func setUp() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device not available")
        }
        self.device = device
    }

    func testFirstResolveSamplesJointsAndWeights() throws {
        let buffer = try makeVertexBuffer(vertices: [
            vertex(joints: SIMD4<UInt32>(1, 2, 0, 0), weights: SIMD4<Float>(0.6, 0.4, 0, 0)),
            vertex(joints: SIMD4<UInt32>(3, 0, 0, 0), weights: SIMD4<Float>(1, 0, 0, 0)),
        ])

        var cache: SkinningInputSample?
        let sample = SkinningInputValidator.resolve(
            cache: &cache,
            vertexBuffer: buffer,
            vertexCount: 2,
            paletteCount: 8
        )

        XCTAssertNotNil(cache)
        XCTAssertEqual(sample?.sampledVertexCount, 2)
        XCTAssertEqual(sample?.maxJointIndex, 3)
        XCTAssertEqual(sample?.hasOutOfRangeJoint, false)
        XCTAssertEqual(sample?.hasUnnormalizedWeight, false)
        XCTAssertEqual(sample, cache)
    }

    func testSecondResolveDoesNotReadTheBuffer() throws {
        let buffer = try makeVertexBuffer(vertices: [
            vertex(joints: SIMD4<UInt32>(4, 0, 0, 0), weights: SIMD4<Float>(1, 0, 0, 0)),
        ])

        var cache: SkinningInputSample?
        let first = SkinningInputValidator.resolve(
            cache: &cache,
            vertexBuffer: buffer,
            vertexCount: 1,
            paletteCount: 8
        )
        XCTAssertEqual(first?.maxJointIndex, 4)

        // Passing a nil buffer on the second call would crash or return nil if
        // the validator re-sampled. A cache hit must ignore the buffer.
        let second = SkinningInputValidator.resolve(
            cache: &cache,
            vertexBuffer: nil,
            vertexCount: 1,
            paletteCount: 8
        )
        XCTAssertEqual(second, first)
        XCTAssertEqual(second?.maxJointIndex, 4)
    }

    func testDetectsJointPastPalette() throws {
        let buffer = try makeVertexBuffer(vertices: [
            vertex(joints: SIMD4<UInt32>(9, 0, 0, 0), weights: SIMD4<Float>(1, 0, 0, 0)),
        ])

        var cache: SkinningInputSample?
        let sample = SkinningInputValidator.resolve(
            cache: &cache,
            vertexBuffer: buffer,
            vertexCount: 1,
            paletteCount: 4
        )

        XCTAssertEqual(sample?.hasOutOfRangeJoint, true)
        XCTAssertEqual(sample?.maxJointIndex, 9)
    }

    func testDetectsUnnormalizedWeights() throws {
        let buffer = try makeVertexBuffer(vertices: [
            vertex(joints: SIMD4<UInt32>(0, 0, 0, 0), weights: SIMD4<Float>(0.5, 0, 0, 0)),
        ])

        var cache: SkinningInputSample?
        let sample = SkinningInputValidator.resolve(
            cache: &cache,
            vertexBuffer: buffer,
            vertexCount: 1,
            paletteCount: 4
        )

        XCTAssertEqual(sample?.hasUnnormalizedWeight, true)
    }

    func testMissingBufferLeavesCacheEmpty() {
        var cache: SkinningInputSample?
        let sample = SkinningInputValidator.resolve(
            cache: &cache,
            vertexBuffer: nil,
            vertexCount: 4,
            paletteCount: 4
        )
        XCTAssertNil(sample)
        XCTAssertNil(cache)
    }

    // MARK: - Fixtures

    private func vertex(joints: SIMD4<UInt32>, weights: SIMD4<Float>) -> VRMVertex {
        var v = VRMVertex()
        v.joints = joints
        v.weights = weights
        return v
    }

    private func makeVertexBuffer(vertices: [VRMVertex]) throws -> MTLBuffer {
        let attributes = VRMVertexStreams.split(vertices).1
        let byteCount = attributes.count * MemoryLayout<VRMAttributeVertex>.stride
        guard let buffer = device.makeBuffer(bytes: attributes, length: byteCount, options: .storageModeShared) else {
            throw XCTSkip("Failed to allocate attribute buffer")
        }
        return buffer
    }
}
