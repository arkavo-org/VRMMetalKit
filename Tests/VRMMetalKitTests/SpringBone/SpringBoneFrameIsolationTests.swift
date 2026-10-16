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

final class SpringBoneFrameIsolationTests: XCTestCase {
    func testQueuedAnimatedFramesMatchSerialGPUResults() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let serial = try simulate(device: device, queued: false, teleport: false)
        let queued = try simulate(device: device, queued: true, teleport: false)
        assertEqual(serial, queued)
    }

    func testQueuedTeleportDoesNotModifyEarlierFrames() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let serial = try simulate(device: device, queued: false, teleport: true)
        let queued = try simulate(device: device, queued: true, teleport: true)
        assertEqual(serial, queued)
    }

    private func assertEqual(_ expected: [[SIMD3<Float>]], _ actual: [[SIMD3<Float>]],
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(expected.count, actual.count, file: file, line: line)
        for frame in expected.indices {
            for bone in expected[frame].indices {
                XCTAssertEqual(simd_distance(expected[frame][bone], actual[frame][bone]), 0,
                               accuracy: 0.000001, "frame \(frame), bone \(bone)", file: file, line: line)
            }
        }
    }

    private func simulate(device: MTLDevice, queued: Bool, teleport: Bool) throws -> [[SIMD3<Float>]] {
        let model = try buildSpringChainModel(boneCount: 5, device: device)
        let system = try SpringBoneComputeSystem(device: device)
        try system.populateSpringBoneData(model: model)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let source = try XCTUnwrap(model.springBoneBuffers?.bonePosCurr)
        var frames: [(MTLCommandBuffer, MTLBuffer)] = []
        for frame in 0..<3 {
            model.nodes[0].translation.x = teleport && frame == 2 ? 3 : Float(frame + 1) * 0.01
            model.nodes[0].rotation = simd_quatf(angle: Float(frame) * 0.1, axis: SIMD3<Float>(0, 0, 1))
            model.updateNodeTransforms()
            model.springBoneGlobalParams?.gravity.x = Float(frame) * 2
            system.wakeAllBones()
            let cb = try XCTUnwrap(queue.makeCommandBuffer())
            system.update(model: model, deltaTime: 1.0 / 60, commandBuffer: cb)
            let output = try XCTUnwrap(device.makeBuffer(length: source.length, options: .storageModeShared))
            let blit = try XCTUnwrap(cb.makeBlitCommandEncoder())
            blit.copy(from: source, sourceOffset: 0, to: output, destinationOffset: 0, size: source.length)
            blit.endEncoding()
            frames.append((cb, output))
            if !queued { cb.commit(); cb.waitUntilCompleted() }
        }
        if queued { for (cb, _) in frames { cb.commit() } }
        return frames.map { cb, output in
            cb.waitUntilCompleted()
            XCTAssertNil(cb.error)
            return Array(UnsafeBufferPointer(start: output.contents().bindMemory(to: SIMD3<Float>.self, capacity: 5), count: 5))
        }
    }

    private func buildSpringChainModel(boneCount: Int, device: MTLDevice) throws -> VRMModel {
        let model = try VRMBuilder().setSkeleton(.defaultHumanoid).build()
        model.nodes.removeAll()

        let boneLength: Float = 0.1
        var previous: VRMNode? = nil
        for i in 0..<boneCount {
            let localY: Float = (i == 0) ? 1.0 : -boneLength
            let json = """
            {"name":"spring_\(i)","translation":[0,\(localY),0],"rotation":[0,0,0,1],"scale":[1,1,1]}
            """
            let gltfNode = try JSONDecoder().decode(GLTFNode.self, from: json.data(using: .utf8)!)
            let node = VRMNode(index: i, gltfNode: gltfNode)
            if let parent = previous {
                node.parent = parent
                parent.children.append(node)
            }
            model.nodes.append(node)
            previous = node
        }
        for node in model.nodes where node.parent == nil {
            node.updateWorldTransform()
        }

        var joints: [VRMSpringJoint] = []
        for i in 0..<boneCount {
            var joint = VRMSpringJoint(node: i)
            joint.hitRadius = 0.02
            joint.stiffness = 0.5
            joint.gravityPower = 1.0
            joint.gravityDir = SIMD3<Float>(0, -1, 0)
            joint.dragForce = 0.4
            joints.append(joint)
        }
        var spring = VRMSpring(name: "TestSpring")
        spring.joints = joints
        var springBone = VRMSpringBone()
        springBone.springs = [spring]
        model.springBone = springBone
        model.device = device

        let buffers = SpringBoneBuffers(device: device)
        buffers.allocateBuffers(numBones: boneCount, numSpheres: 0, numCapsules: 0, numPlanes: 0)
        model.springBoneBuffers = buffers

        model.springBoneGlobalParams = SpringBoneGlobalParams(
            gravity: SIMD3<Float>(0, -9.8, 0),
            dtSub: Float(1.0 / 120.0),
            windAmplitude: 0, windFrequency: 0, windPhase: 0,
            windDirection: SIMD3<Float>(1, 0, 0),
            substeps: 2,
            numBones: UInt32(boneCount),
            numSpheres: 0, numCapsules: 0, numPlanes: 0)

        return model
    }
}
