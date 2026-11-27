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

/// Verifies that `SpringBoneComputeSystem` rounds up to whole threadgroups via
/// `dispatchThreadgroups` when non-uniform threadgroup sizes are unavailable,
/// producing valid finite positions on all GPUs and bit-identical output on
/// devices that also support `dispatchThreads`.
final class SpringBoneUniformThreadgroupTests: XCTestCase {

    private var device: MTLDevice!

    override func setUpWithError() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        self.device = device
    }

    #if targetEnvironment(simulator)
    func testSimulatorDisablesNonUniformThreadgroups() throws {
        let system = try SpringBoneComputeSystem(device: device)
        XCTAssertFalse(system.supportsNonUniformThreadgroups,
                       "Simulator GPUs must fall back to uniform threadgroup dispatches")
    }
    #endif

    func testThreadgroupGridSizeRounding() {
        let tg1D = MTLSize(width: 256, height: 1, depth: 1)

        let one = SpringBoneComputeSystem.threadgroupGridSize(
            for: MTLSize(width: 1, height: 1, depth: 1),
            threadsPerThreadgroup: tg1D
        )
        XCTAssertEqual(one.width, 1)
        XCTAssertEqual(one.height, 1)
        XCTAssertEqual(one.depth, 1)

        let exact = SpringBoneComputeSystem.threadgroupGridSize(
            for: MTLSize(width: 256, height: 1, depth: 1),
            threadsPerThreadgroup: tg1D
        )
        XCTAssertEqual(exact.width, 1)

        let overflow = SpringBoneComputeSystem.threadgroupGridSize(
            for: MTLSize(width: 257, height: 1, depth: 1),
            threadsPerThreadgroup: tg1D
        )
        XCTAssertEqual(overflow.width, 2)

        let exactTwo = SpringBoneComputeSystem.threadgroupGridSize(
            for: MTLSize(width: 512, height: 1, depth: 1),
            threadsPerThreadgroup: tg1D
        )
        XCTAssertEqual(exactTwo.width, 2)

        let mip = SpringBoneComputeSystem.threadgroupGridSize(
            for: MTLSize(width: 4, height: 4, depth: 6),
            threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1)
        )
        XCTAssertEqual(mip.width, 1)
        XCTAssertEqual(mip.height, 1)
        XCTAssertEqual(mip.depth, 6)
    }

    /// Exercises all 5 compute dispatch sites in `executeXPBDStep` (kinematic,
    /// center delta, copy parent positions, per-bone kernels, and colliders)
    /// for a small partial threadgroup (8 bones < 256).
    func testUniformThreadgroupFallbackForSmallChain() throws {
        let uniform = try simulateChain(
            boneCount: 8,
            supportsNonUniform: false,
            includeCenterNode: true,
            includeColliders: true,
            serialized: false
        )
        assertFinitePositions(uniform, expectedCount: 8)

        guard SpringBoneComputeSystem.deviceSupportsNonUniformThreadgroups(device) else {
            return
        }
        let nonUniform = try simulateChain(
            boneCount: 8,
            supportsNonUniform: true,
            includeCenterNode: true,
            includeColliders: true,
            serialized: false
        )
        assertExactMatch(uniform, nonUniform, context: "small chain")
    }

    /// Exercises a bone count spanning multiple 256-thread groups with a partial
    /// tail group (260 bones = 1 full group + 4 active threads + 252 tail lanes).
    func testUniformThreadgroupFallbackAcrossMultipleGroups() throws {
        let uniform = try simulateChain(
            boneCount: 260,
            supportsNonUniform: false,
            includeCenterNode: false,
            includeColliders: true,
            serialized: false
        )
        assertFinitePositions(uniform, expectedCount: 260)

        guard SpringBoneComputeSystem.deviceSupportsNonUniformThreadgroups(device) else {
            return
        }
        let nonUniform = try simulateChain(
            boneCount: 260,
            supportsNonUniform: true,
            includeCenterNode: false,
            includeColliders: true,
            serialized: false
        )
        assertExactMatch(uniform, nonUniform, context: "multi-group")
    }

    /// Exercises the serialized per-bone dispatch branch under uniform fallback.
    func testUniformThreadgroupFallbackWhenSerialized() throws {
        let uniform = try simulateChain(
            boneCount: 6,
            supportsNonUniform: false,
            includeCenterNode: false,
            includeColliders: false,
            serialized: true
        )
        assertFinitePositions(uniform, expectedCount: 6)

        guard SpringBoneComputeSystem.deviceSupportsNonUniformThreadgroups(device) else {
            return
        }
        let nonUniform = try simulateChain(
            boneCount: 6,
            supportsNonUniform: true,
            includeCenterNode: false,
            includeColliders: false,
            serialized: true
        )
        assertExactMatch(uniform, nonUniform, context: "serialized")
    }

    // MARK: - Helpers

    private func assertFinitePositions(
        _ result: (curr: [SIMD3<Float>], prev: [SIMD3<Float>]),
        expectedCount: Int
    ) {
        XCTAssertEqual(result.curr.count, expectedCount)
        XCTAssertEqual(result.prev.count, expectedCount)
        for bone in 0..<expectedCount {
            XCTAssertTrue(result.curr[bone].x.isFinite && result.curr[bone].y.isFinite && result.curr[bone].z.isFinite,
                          "bonePosCurr[\(bone)] is non-finite: \(result.curr[bone])")
            XCTAssertTrue(result.prev[bone].x.isFinite && result.prev[bone].y.isFinite && result.prev[bone].z.isFinite,
                          "bonePosPrev[\(bone)] is non-finite: \(result.prev[bone])")
        }
    }

    private func assertExactMatch(
        _ uniform: (curr: [SIMD3<Float>], prev: [SIMD3<Float>]),
        _ nonUniform: (curr: [SIMD3<Float>], prev: [SIMD3<Float>]),
        context: String
    ) {
        XCTAssertEqual(uniform.curr.count, nonUniform.curr.count)
        for bone in uniform.curr.indices {
            XCTAssertEqual(uniform.curr[bone], nonUniform.curr[bone],
                           "\(context) bonePosCurr[\(bone)] differed between uniform and non-uniform dispatch")
            XCTAssertEqual(uniform.prev[bone], nonUniform.prev[bone],
                           "\(context) bonePosPrev[\(bone)] differed between uniform and non-uniform dispatch")
        }
    }

    private func simulateChain(
        boneCount: Int,
        supportsNonUniform: Bool,
        includeCenterNode: Bool,
        includeColliders: Bool,
        serialized: Bool
    ) throws -> (curr: [SIMD3<Float>], prev: [SIMD3<Float>]) {
        let model = try SpringBoneTestFixtures.makeVerticalChain(
            device: device,
            boneCount: boneCount,
            boneLength: 0.05,
            rootY: 1.0
        )

        var centerNodeIndex: Int?
        if includeCenterNode {
            let centerGltf = try SpringBoneTestFixtures.makeGLTFNode(
                name: "center_node",
                translation: SIMD3<Float>(0, 0, 0)
            )
            let centerNode = VRMNode(index: model.nodes.count, gltfNode: centerGltf)
            centerNode.updateWorldTransform()
            model.nodes.append(centerNode)
            centerNodeIndex = centerNode.index
        }

        var colliderNodeIndex: Int?
        if includeColliders {
            let colliderGltf = try SpringBoneTestFixtures.makeGLTFNode(
                name: "collider_anchor",
                translation: SIMD3<Float>(0, 0.85, 0)
            )
            let colliderNode = VRMNode(index: model.nodes.count, gltfNode: colliderGltf)
            colliderNode.updateWorldTransform()
            model.nodes.append(colliderNode)
            colliderNodeIndex = colliderNode.index
        }

        var spring = VRMSpring(name: "UniformTestChain")
        spring.joints = (0..<boneCount).map { SpringBoneTestFixtures.defaultJoint(node: $0) }
        spring.center = centerNodeIndex

        var springBone = VRMSpringBone()
        if let colNodeIdx = colliderNodeIndex {
            springBone.colliders = [
                VRMCollider(node: colNodeIdx, shape: .sphere(offset: SIMD3<Float>(0.02, 0, 0), radius: 0.05)),
                VRMCollider(node: colNodeIdx, shape: .capsule(offset: SIMD3<Float>(-0.02, -0.05, 0), radius: 0.04, tail: SIMD3<Float>(-0.02, -0.15, 0))),
                VRMCollider(node: colNodeIdx, shape: .plane(offset: SIMD3<Float>(0, -0.5, 0), normal: SIMD3<Float>(0, 1, 0)))
            ]
            springBone.colliderGroups = [
                VRMColliderGroup(name: "All", colliders: [0, 1, 2])
            ]
            spring.colliderGroups = [0]
        }
        springBone.springs = [spring]
        model.springBone = springBone

        let buffers = SpringBoneBuffers(device: device)
        buffers.allocateBuffers(
            numBones: boneCount,
            numSpheres: includeColliders ? 1 : 0,
            numCapsules: includeColliders ? 1 : 0,
            numPlanes: includeColliders ? 1 : 0
        )
        model.springBoneBuffers = buffers
        model.springBoneGlobalParams = SpringBoneTestFixtures.defaultGlobalParams(
            numBones: boneCount,
            numSpheres: includeColliders ? 1 : 0,
            numCapsules: includeColliders ? 1 : 0,
            numPlanes: includeColliders ? 1 : 0
        )

        let system = try SpringBoneComputeSystem(
            device: device,
            supportsNonUniformThreadgroups: supportsNonUniform
        )
        system.testSerializeBoneDispatches = serialized
        try system.populateSpringBoneData(model: model)

        for bone in 1..<boneCount {
            let rest = SpringBoneTestFixtures.readBonePosition(model: model, boneIndex: bone)
            let phase = Float(bone % 7) * 0.005
            let swing = SIMD3<Float>(0.02 + phase, 0.005, -0.015)
            SpringBoneTestFixtures.seedBonePosition(
                buffers: buffers,
                boneIndex: bone,
                curr: rest + swing,
                prev: rest + swing * 0.5
            )
        }

        model.nodes[0].translation += SIMD3<Float>(0.02, 0.01, 0)
        model.nodes[0].updateWorldTransform()
        if let centerIdx = centerNodeIndex {
            model.nodes[centerIdx].translation += SIMD3<Float>(0.05, 0, -0.02)
            model.nodes[centerIdx].updateWorldTransform()
        }

        system.update(model: model, deltaTime: 1.0 / 60.0, commandBuffer: nil)
        system.waitForPendingFrame()

        let prevBuffer = try XCTUnwrap(buffers.bonePosPrev)
        let prevPointer = prevBuffer.contents().bindMemory(to: SIMD3<Float>.self, capacity: boneCount)
        return (
            SpringBoneTestFixtures.readBonePositions(model: model),
            Array(UnsafeBufferPointer(start: prevPointer, count: boneCount))
        )
    }
}
