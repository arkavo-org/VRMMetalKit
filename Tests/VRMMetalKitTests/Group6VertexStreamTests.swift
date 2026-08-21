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

/// Group 6b: split `VRMVertex` into a position stream and an attribute stream
/// without quantizing values.
final class Group6VertexStreamTests: XCTestCase {

    func testSplitJoinIsBitIdentical() {
        var vertex = VRMVertex()
        vertex.position = SIMD3<Float>(1.25, -2.5, 3.75)
        vertex.normal = SIMD3<Float>(0, 0, 1)
        vertex.texCoord = SIMD2<Float>(0.25, 0.75)
        vertex.color = SIMD4<Float>(0.1, 0.2, 0.3, 0.4)
        vertex.joints = SIMD4<UInt32>(1, 2, 3, 4)
        vertex.weights = SIMD4<Float>(0.4, 0.3, 0.2, 0.1)

        let (position, attributes) = VRMVertexStreams.split(vertex)
        let restored = VRMVertexStreams.join(position: position, attributes: attributes)
        XCTAssertEqual(restored.position, vertex.position)
        XCTAssertEqual(restored.normal, vertex.normal)
        XCTAssertEqual(restored.texCoord, vertex.texCoord)
        XCTAssertEqual(restored.color, vertex.color)
        XCTAssertEqual(restored.joints, vertex.joints)
        XCTAssertEqual(restored.weights, vertex.weights)
    }

    func testPositionStreamIsSixteenBytes() {
        XCTAssertEqual(MemoryLayout<VRMPositionVertex>.stride, 16)
        XCTAssertLessThan(MemoryLayout<VRMAttributeVertex>.stride, MemoryLayout<VRMVertex>.stride)
    }

    func testMainPassDescriptorUsesTwoBuffers() {
        let descriptor = MTLVertexDescriptor()
        VRMVertexStreams.applyMainPass(to: descriptor, skinned: true)
        XCTAssertEqual(descriptor.attributes[0].bufferIndex, ResourceIndices.vertexBuffer)
        XCTAssertEqual(descriptor.attributes[1].bufferIndex, ResourceIndices.attributeBuffer)
        XCTAssertEqual(descriptor.attributes[4].bufferIndex, ResourceIndices.attributeBuffer)
        XCTAssertEqual(descriptor.layouts[ResourceIndices.vertexBuffer].stride, MemoryLayout<VRMPositionVertex>.stride)
        XCTAssertEqual(descriptor.layouts[ResourceIndices.attributeBuffer].stride, MemoryLayout<VRMAttributeVertex>.stride)
    }

    func testDepthDescriptorDropsUnneededAttributes() {
        let rigid = MTLVertexDescriptor()
        VRMVertexStreams.applyDepth(to: rigid, skinned: false)
        XCTAssertEqual(rigid.layouts[ResourceIndices.vertexBuffer].stride, MemoryLayout<VRMPositionVertex>.stride)
        XCTAssertEqual(rigid.attributes[1].format, .invalid)

        let skinned = MTLVertexDescriptor()
        VRMVertexStreams.applyDepth(to: skinned, skinned: true)
        XCTAssertEqual(skinned.attributes[4].bufferIndex, ResourceIndices.attributeBuffer)
        XCTAssertEqual(skinned.attributes[5].format, .float4)
    }

    func testUploadWritesBothStreams() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device not available")
        }
        var vertex = VRMVertex()
        vertex.position = SIMD3<Float>(9, 8, 7)
        vertex.joints = SIMD4<UInt32>(3, 0, 0, 0)
        vertex.weights = SIMD4<Float>(1, 0, 0, 0)
        let primitive = VRMPrimitive()
        primitive.uploadVertices([vertex], device: device)
        XCTAssertEqual(primitive.vertexCount, 1)
        XCTAssertEqual(try XCTUnwrap(primitive.vertexBuffer).length, MemoryLayout<VRMPositionVertex>.stride)
        XCTAssertEqual(try XCTUnwrap(primitive.attributeBuffer).length, MemoryLayout<VRMAttributeVertex>.stride)
        let restored = primitive.interleavedVertices()
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored[0].position, vertex.position)
        XCTAssertEqual(restored[0].joints, vertex.joints)
    }
}
