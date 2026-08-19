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
@testable import VRMMetalKit

/// Regression coverage for the frame-0 face-geometry diagnostic walk.
///
/// The diagnostic used to read `primitive.vertexBuffer` with a hardcoded
/// 96-byte stride left over from the interleaved `VRMVertex` layout, but the
/// vertex/attribute buffer split allocates `vertexBuffer` at
/// `MemoryLayout<VRMPositionVertex>.stride` (16) bytes per vertex — up to 6x
/// past the end of the buffer.
final class FaceGeometryDiagnosticTests: XCTestCase {

    func testComputeBoundsMatchesUploadedPositions() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device not available")
        }
        var vertices: [VRMVertex] = []
        for i in 0..<8 {
            var v = VRMVertex()
            v.position = SIMD3<Float>(Float(i), Float(-i), Float(i) * 0.5)
            vertices.append(v)
        }
        let primitive = VRMPrimitive()
        primitive.uploadVertices(vertices, device: device)

        let vertexBuffer = try XCTUnwrap(primitive.vertexBuffer)
        let bounds = try XCTUnwrap(
            FaceGeometryDiagnostic.computeBounds(vertexBuffer: vertexBuffer, vertexCount: primitive.vertexCount)
        )

        XCTAssertEqual(bounds.min, SIMD3<Float>(0, -7, 0))
        XCTAssertEqual(bounds.max, SIMD3<Float>(7, 0, 3.5))
    }

    func testComputeBoundsRefusesUndersizedBuffer() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device not available")
        }
        let vertexCount = 10
        let undersizedLength = vertexCount * MemoryLayout<VRMPositionVertex>.stride - 1
        let buffer = try XCTUnwrap(device.makeBuffer(length: max(undersizedLength, 1), options: []))

        let bounds = FaceGeometryDiagnostic.computeBounds(vertexBuffer: buffer, vertexCount: vertexCount)
        XCTAssertNil(bounds, "must refuse to read past the buffer's allocated length")
    }
}
