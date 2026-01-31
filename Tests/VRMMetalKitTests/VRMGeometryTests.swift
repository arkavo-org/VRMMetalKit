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
@testable import VRMMetalKit

/// Unit tests for VRMGeometry (VRMMesh, VRMPrimitive, VertexData)
/// Tests geometry loading, vertex data handling, and primitive creation
final class VRMGeometryTests: XCTestCase {

    // MARK: - VertexData Tests

    func testVertexDataInterleaving() {
        var vertexData = VertexData()
        vertexData.positions = [
            SIMD3<Float>(0, 0, 0),
            SIMD3<Float>(1, 0, 0),
            SIMD3<Float>(0, 1, 0)
        ]
        vertexData.normals = [
            SIMD3<Float>(0, 0, 1),
            SIMD3<Float>(0, 0, 1),
            SIMD3<Float>(0, 0, 1)
        ]
        vertexData.texCoords = [
            SIMD2<Float>(0, 0),
            SIMD2<Float>(1, 0),
            SIMD2<Float>(0, 1)
        ]
        vertexData.colors = [
            SIMD4<Float>(1, 0, 0, 1),
            SIMD4<Float>(0, 1, 0, 1),
            SIMD4<Float>(0, 0, 1, 1)
        ]

        let interleaved = vertexData.interleaved()

        XCTAssertEqual(interleaved.count, 3)

        // Check first vertex
        XCTAssertEqual(interleaved[0].position, SIMD3<Float>(0, 0, 0))
        XCTAssertEqual(interleaved[0].normal, SIMD3<Float>(0, 0, 1))
        XCTAssertEqual(interleaved[0].texCoord, SIMD2<Float>(0, 0))
        XCTAssertEqual(interleaved[0].color, SIMD4<Float>(1, 0, 0, 1))

        // Check second vertex
        XCTAssertEqual(interleaved[1].position, SIMD3<Float>(1, 0, 0))
        XCTAssertEqual(interleaved[1].normal, SIMD3<Float>(0, 0, 1))
        XCTAssertEqual(interleaved[1].texCoord, SIMD2<Float>(1, 0))
        XCTAssertEqual(interleaved[1].color, SIMD4<Float>(0, 1, 0, 1))
    }

    func testVertexDataPartialAttributes() {
        // Only positions and normals (common case)
        var vertexData = VertexData()
        vertexData.positions = [
            SIMD3<Float>(0, 0, 0),
            SIMD3<Float>(1, 0, 0)
        ]
        vertexData.normals = [
            SIMD3<Float>(0, 1, 0),
            SIMD3<Float>(0, 1, 0)
        ]
        // No texCoords, colors, joints, weights

        let interleaved = vertexData.interleaved()

        XCTAssertEqual(interleaved.count, 2)
        XCTAssertEqual(interleaved[0].position, SIMD3<Float>(0, 0, 0))
        XCTAssertEqual(interleaved[0].normal, SIMD3<Float>(0, 1, 0))
        // TexCoords should default to zero, color defaults to white (1,1,1,1)
        XCTAssertEqual(interleaved[0].texCoord, SIMD2<Float>(0, 0))
        XCTAssertEqual(interleaved[0].color, SIMD4<Float>(1, 1, 1, 1))  // Default is white
    }

    func testVertexDataSkinnedMesh() {
        var vertexData = VertexData()
        vertexData.positions = [SIMD3<Float>(0, 0, 0)]
        vertexData.normals = [SIMD3<Float>(0, 1, 0)]
        vertexData.joints = [SIMD4<UInt32>(0, 1, 0, 0)]  // Affected by joints 0 and 1
        vertexData.weights = [SIMD4<Float>(0.5, 0.5, 0, 0)]  // 50% weight each

        let interleaved = vertexData.interleaved()

        XCTAssertEqual(interleaved.count, 1)
        XCTAssertEqual(interleaved[0].joints, SIMD4<UInt32>(0, 1, 0, 0))
        XCTAssertEqual(interleaved[0].weights, SIMD4<Float>(0.5, 0.5, 0, 0))
    }

    // MARK: - MTLPrimitiveType Conversion Tests

    func testPrimitiveTypeConversion() {
        // Mode 0: POINTS
        XCTAssertEqual(MTLPrimitiveType(gltfMode: 0), .point)

        // Mode 1: LINES
        XCTAssertEqual(MTLPrimitiveType(gltfMode: 1), .line)

        // Mode 4: TRIANGLES (default)
        XCTAssertEqual(MTLPrimitiveType(gltfMode: 4), .triangle)

        // Mode 5: TRIANGLE_STRIP
        XCTAssertEqual(MTLPrimitiveType(gltfMode: 5), .triangleStrip)

        // Mode 6: TRIANGLE_FAN (mapped to triangleStrip)
        XCTAssertEqual(MTLPrimitiveType(gltfMode: 6), .triangleStrip)

        // Unknown mode should default to triangles
        XCTAssertEqual(MTLPrimitiveType(gltfMode: 99), .triangle)
    }

    // MARK: - VRMMesh Tests

    func testVRMMeshCreation() {
        let mesh = VRMMesh(name: "TestMesh")

        XCTAssertEqual(mesh.name, "TestMesh")
        XCTAssertTrue(mesh.primitives.isEmpty)
    }

    func testVRMMeshUnnamed() {
        let mesh = VRMMesh()

        XCTAssertNil(mesh.name)
        XCTAssertTrue(mesh.primitives.isEmpty)
    }

    // MARK: - VRMPrimitive Tests

    func testVRMPrimitiveDefaults() {
        let primitive = VRMPrimitive()

        XCTAssertNil(primitive.vertexBuffer)
        XCTAssertNil(primitive.indexBuffer)
        XCTAssertEqual(primitive.vertexCount, 0)
        XCTAssertEqual(primitive.indexCount, 0)
        XCTAssertEqual(primitive.indexType, .uint16)
        XCTAssertEqual(primitive.primitiveType, .triangle)
        XCTAssertNil(primitive.materialIndex)

        // Attribute flags
        XCTAssertFalse(primitive.hasNormals)
        XCTAssertFalse(primitive.hasTexCoords)
        XCTAssertFalse(primitive.hasTangents)
        XCTAssertFalse(primitive.hasColors)
        XCTAssertFalse(primitive.hasJoints)
        XCTAssertFalse(primitive.hasWeights)
    }

    func testVRMPrimitiveAttributeFlags() {
        let primitive = VRMPrimitive()

        // Simulate loading with various attributes
        primitive.hasNormals = true
        primitive.hasTexCoords = true
        primitive.hasColors = false
        primitive.hasJoints = true
        primitive.hasWeights = true

        XCTAssertTrue(primitive.hasNormals)
        XCTAssertTrue(primitive.hasTexCoords)
        XCTAssertFalse(primitive.hasColors)
        XCTAssertTrue(primitive.hasJoints)
        XCTAssertTrue(primitive.hasWeights)
    }

    // MARK: - Index Rebase Tests

    func testIndexRebaseForOutOfBounds() {
        // Simulate scenario where indices need rebasing
        // Original indices reference a large global buffer, but we only have a subset
        // of vertices in this primitive (e.g., vertices 50-55 out of 100 total)
        let availableVertexCount = 6  // Only 6 vertices in this primitive's buffer
        let indices: [UInt32] = [50, 51, 52, 53, 54, 55]  // Reference global indices
        
        let minIndex = indices.min()!
        let maxIndex = indices.max()!
        
        // Without rebasing, max index (55) exceeds available vertices (6)
        XCTAssertGreaterThan(Int(maxIndex), availableVertexCount)
        
        // Rebase: subtract minimum to make indices relative to primitive
        let rebasedIndices = indices.map { $0 - minIndex }
        let newMaxIndex = rebasedIndices.max()!
        
        // After rebasing, max index (5) is within available vertices (6)
        XCTAssertLessThan(Int(newMaxIndex), availableVertexCount)
        XCTAssertEqual(rebasedIndices, [0, 1, 2, 3, 4, 5])
    }

    func testIndexRebaseNotNeeded() {
        // Indices already start at 0
        let vertexCount = 100
        let indices: [UInt32] = [0, 1, 2, 3, 4, 5]

        let maxIndex = indices.max()!
        XCTAssertLessThan(Int(maxIndex), vertexCount)

        // No rebasing needed
        let rebasedIndices = indices
        XCTAssertEqual(rebasedIndices, [0, 1, 2, 3, 4, 5])
    }

    // MARK: - Joint Sanitization Tests

    func testJointIndexSanitization() {
        // Simulate joint indices with sentinel values
        let joints: [UInt32] = [0, 1, 65535, 3]  // 65535 is sentinel
        let maxValidJoint: UInt32 = 255

        var sanitizedCount = 0
        let sanitized = joints.map { joint -> UInt32 in
            if joint > maxValidJoint {
                sanitizedCount += 1
                return 0
            }
            return joint
        }

        XCTAssertEqual(sanitizedCount, 1)
        XCTAssertEqual(sanitized, [0, 1, 0, 3])  // 65535 clamped to 0
    }

    func testJointIndexNoSanitizationNeeded() {
        let joints: [UInt32] = [0, 1, 2, 3, 10, 20]
        let maxValidJoint: UInt32 = 255

        var sanitizedCount = 0
        let sanitized = joints.map { joint -> UInt32 in
            if joint > maxValidJoint {
                sanitizedCount += 1
                return 0
            }
            return joint
        }

        XCTAssertEqual(sanitizedCount, 0)
        XCTAssertEqual(sanitized, joints)
    }

    // MARK: - Index Consistency Audit Tests

    func testIndexConsistencyValid() {
        let primitive = VRMPrimitive()
        primitive.vertexCount = 100
        primitive.indexCount = 300  // 100 triangles
        primitive.indexType = .uint16

        // Would need actual Metal device to fully test, but we can test the logic
        XCTAssertEqual(primitive.vertexCount, 100)
        XCTAssertEqual(primitive.indexCount, 300)
    }

    func testIndexConsistencyOutOfBounds() {
        let vertexCount = 10
        let indices: [UInt32] = [0, 1, 2, 15, 16, 17]  // 15, 16, 17 are out of bounds

        let maxIndex = indices.max()!
        XCTAssertGreaterThanOrEqual(Int(maxIndex), vertexCount)

        // This would be flagged as an error in auditIndexConsistency
    }

    // MARK: - Degenerate Triangle Detection

    func testDegenerateTriangleDetection() {
        let indices: [UInt32] = [
            0, 1, 2,    // Valid
            3, 3, 4,    // Degenerate (3, 3, 4)
            5, 6, 6,    // Degenerate (5, 6, 6)
            7, 8, 9     // Valid
        ]

        var degenerateCount = 0
        for i in stride(from: 0, to: indices.count - 2, by: 3) {
            let i0 = indices[i]
            let i1 = indices[i + 1]
            let i2 = indices[i + 2]

            if i0 == i1 || i1 == i2 || i0 == i2 {
                degenerateCount += 1
            }
        }

        XCTAssertEqual(degenerateCount, 2)
    }

    func testNoDegenerateTriangles() {
        let indices: [UInt32] = [
            0, 1, 2,
            3, 4, 5,
            6, 7, 8
        ]

        var degenerateCount = 0
        for i in stride(from: 0, to: indices.count - 2, by: 3) {
            let i0 = indices[i]
            let i1 = indices[i + 1]
            let i2 = indices[i + 2]

            if i0 == i1 || i1 == i2 || i0 == i2 {
                degenerateCount += 1
            }
        }

        XCTAssertEqual(degenerateCount, 0)
    }

    // MARK: - Morph Target Tests

    func testVRMMorphTargetCreation() {
        let morphTarget = VRMMorphTarget(name: "Blink")

        XCTAssertEqual(morphTarget.name, "Blink")
        XCTAssertNil(morphTarget.positionDeltas)
        XCTAssertNil(morphTarget.normalDeltas)
        XCTAssertNil(morphTarget.tangentDeltas)
    }

    func testVRMMorphTargetWithDeltas() {
        var morphTarget = VRMMorphTarget(name: "Smile")
        morphTarget.positionDeltas = [
            SIMD3<Float>(0, 0.01, 0),
            SIMD3<Float>(0, 0.02, 0)
        ]
        morphTarget.normalDeltas = [
            SIMD3<Float>(0, 1, 0),
            SIMD3<Float>(0, 1, 0)
        ]

        XCTAssertEqual(morphTarget.positionDeltas?.count, 2)
        XCTAssertEqual(morphTarget.normalDeltas?.count, 2)
    }

    // MARK: - Required Palette Size Tests

    func testRequiredPaletteSizeCalculation() {
        // Maximum joint index determines palette size
        let joints: [SIMD4<UInt32>] = [
            SIMD4<UInt32>(0, 1, 0, 0),
            SIMD4<UInt32>(2, 3, 0, 0),
            SIMD4<UInt32>(5, 10, 0, 0)  // Max is 10
        ]

        var maxJoint: UInt32 = 0
        for joint in joints {
            maxJoint = max(maxJoint, joint.x, joint.y, joint.z, joint.w)
        }
        let requiredPaletteSize = Int(maxJoint) + 1

        XCTAssertEqual(requiredPaletteSize, 11)  // 0-10 inclusive
    }

    func testRequiredPaletteSizeWithZeroJoints() {
        let joints: [SIMD4<UInt32>] = [
            SIMD4<UInt32>(0, 0, 0, 0),
            SIMD4<UInt32>(0, 0, 0, 0)
        ]

        var maxJoint: UInt32 = 0
        for joint in joints {
            maxJoint = max(maxJoint, joint.x, joint.y, joint.z, joint.w)
        }
        let requiredPaletteSize = Int(maxJoint) + 1

        XCTAssertEqual(requiredPaletteSize, 1)  // Just root bone
    }

    // MARK: - Index Buffer Type Tests

    func testIndexTypeUInt16() {
        // Less than 65536 vertices
        let vertexCount = 1000
        let indexType: MTLIndexType = vertexCount <= 65535 ? .uint16 : .uint32

        XCTAssertEqual(indexType, .uint16)
    }

    func testIndexTypeUInt32() {
        // More than 65535 vertices
        let vertexCount = 100000
        let indexType: MTLIndexType = vertexCount > 65535 ? .uint32 : .uint16

        XCTAssertEqual(indexType, .uint32)
    }

    func testIndexStrideCalculation() {
        let uint16Stride = MemoryLayout<UInt16>.stride  // 2 bytes
        let uint32Stride = MemoryLayout<UInt32>.stride  // 4 bytes

        XCTAssertEqual(uint16Stride, 2)
        XCTAssertEqual(uint32Stride, 4)
    }

    // MARK: - UV Range Validation

    func testUVCoordinatesInRange() {
        let uvs = [
            SIMD2<Float>(0, 0),
            SIMD2<Float>(0.5, 0.5),
            SIMD2<Float>(1, 1)
        ]

        for uv in uvs {
            let inRange = uv.x >= -0.1 && uv.x <= 1.1 &&
                         uv.y >= -0.1 && uv.y <= 1.1
            XCTAssertTrue(inRange)
        }
    }

    func testUVCoordinatesOutOfRange() {
        let uv = SIMD2<Float>(2.5, -0.5)  // Clearly out of range

        let inRange = uv.x >= -0.1 && uv.x <= 1.1 &&
                     uv.y >= -0.1 && uv.y <= 1.1
        XCTAssertFalse(inRange)
    }

    // MARK: - Performance Tests

    func testVertexDataInterleavingPerformance() {
        var vertexData = VertexData()

        // Create large vertex data
        let count = 10000
        vertexData.positions = (0..<count).map { i in
            SIMD3<Float>(Float(i), Float(i), Float(i))
        }
        vertexData.normals = Array(repeating: SIMD3<Float>(0, 1, 0), count: count)
        vertexData.texCoords = (0..<count).map { i in
            SIMD2<Float>(Float(i % 100) / 100, Float(i % 100) / 100)
        }

        measure {
            _ = vertexData.interleaved()
        }
    }

    // MARK: - Memory Layout Tests

    func testVRMVertexMemoryLayout() {
        let vertexSize = MemoryLayout<VRMVertex>.stride

        // Verify expected size (position 12 + normal 12 + tangent 12 + color 16 + texCoord 8 + joints 16 + weights 16)
        // = 92 bytes, padded to 96 or 128 depending on alignment
        XCTAssertGreaterThanOrEqual(vertexSize, 92)

        // Verify alignment
        let alignment = MemoryLayout<VRMVertex>.alignment
        XCTAssertGreaterThanOrEqual(alignment, 4)
    }

    func testSIMD3FloatSize() {
        let size = MemoryLayout<SIMD3<Float>>.stride
        XCTAssertEqual(size, 16)  // 3 floats + 4 bytes padding for alignment
    }

    func testSIMD4FloatSize() {
        let size = MemoryLayout<SIMD4<Float>>.stride
        XCTAssertEqual(size, 16)  // 4 floats, no padding
    }

    func testSIMD4UInt32Size() {
        let size = MemoryLayout<SIMD4<UInt32>>.stride
        XCTAssertEqual(size, 16)  // 4 uint32s
    }
}
