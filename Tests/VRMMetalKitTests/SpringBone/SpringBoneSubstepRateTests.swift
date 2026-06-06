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

/// Guard for #316: the per-frame `update()` substep `dtSub` must track the active
/// quality preset's substep rate. Every dt-scaled term reads `globalParams.dtSub`
/// — gravity, wind, inertial force, AND drag (`dragFactor = 1 - drag*dtSub*60`) —
/// so a stale `dtSub` under-applies all of them on non-ultra tiers (60/90/30 Hz):
/// both an equilibrium shift and a damping/transient error.
///
/// Deliberately a VALUE-level guard (uploaded `dtSub` == 1/rateHz per tier), not
/// a cross-tier pose comparison. The PBD stiffness blend is dt-INDEPENDENT
/// (`stiffness * 0.15` per substep), so stiffness-per-wall-second still scales
/// with substep rate even after this fix — higher tiers legitimately droop less.
/// Asserting cross-tier settled-pose equality would therefore fail even with the
/// correct fix (per VRMConformance review on #316). Isolate the fix instead.
final class SpringBoneSubstepRateTests: XCTestCase {

    var device: MTLDevice!
    var commandQueue: MTLCommandQueue!

    override func setUpWithError() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        guard let queue = device.makeCommandQueue() else {
            throw XCTSkip("Could not create Metal command queue")
        }
        self.device = device
        self.commandQueue = queue
    }

    /// `dtSub` byte offset within `SpringBoneGlobalParams` (gravity float3 is
    /// offset 0, padded to 16; dtSub follows at 16).
    private static let dtSubByteOffset = 16

    func testDtSubTracksSubstepRateAcrossQualityTiers() throws {
        let model = try buildSpringChainModel(boneCount: 3)
        let system = try SpringBoneComputeSystem(device: device)
        try system.populateSpringBoneData(model: model)

        // (quality, expected dtSub = 1 / substepRateHz)
        let cases: [(VRMConstants.SpringBoneQuality, Float)] = [
            (.ultra, 1.0 / 120.0),
            (.high, 1.0 / 90.0),
            (.medium, 1.0 / 60.0),
            (.low, 1.0 / 30.0),
        ]

        for (quality, expectedDtSub) in cases {
            system.quality = quality

            // deltaTime ≥ the largest fixed step (1/30) guarantees ≥1 substep
            // runs at every tier, so params are actually uploaded this call.
            guard let cb = commandQueue.makeCommandBuffer() else {
                throw XCTSkip("Could not create command buffer")
            }
            system.update(model: model, deltaTime: 0.05, commandBuffer: cb)
            cb.commit()
            cb.waitUntilCompleted()

            let buffer = try XCTUnwrap(system.globalParamsBuffer,
                                       "globalParamsBuffer must exist after update")
            let uploadedDtSub = buffer.contents()
                .load(fromByteOffset: Self.dtSubByteOffset, as: Float.self)

            XCTAssertEqual(
                uploadedDtSub, expectedDtSub, accuracy: 1e-6,
                "At quality \(quality), uploaded dtSub \(uploadedDtSub) must equal 1/\(quality.substepRateHz)Hz = \(expectedDtSub). A stale dtSub under-applies gravity/wind on this tier.")
        }
    }

    // MARK: - Helpers

    /// Builds a minimal vertical spring chain (root + `boneCount-1` children) with
    /// allocated GPU buffers and global params seeded at the load default
    /// `dtSub = 1/120`, mirroring `VRMModel`'s setup. No colliders.
    private func buildSpringChainModel(boneCount: Int) throws -> VRMModel {
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
