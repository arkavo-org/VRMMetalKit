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

import XCTest
import Metal
import simd
@testable import VRMMetalKit

/// VRMC_springBone-1.0 defines a capsule's `tail` as "the center position of
/// the capsule end-side semicircle in the local coordinates of the target
/// node" — an absolute local position, exactly like `offset`, not a vector
/// from `offset`. three-vrm and UniVRM both transform `tail` as a point.
final class SpringBoneCapsuleTailTests: XCTestCase {
    private let nodeWorld = SIMD3<Float>(0.3, 1.36, -0.1)
    private let offset = SIMD3<Float>(0.02, -0.1, 0)
    private let tail = SIMD3<Float>(0, -0.05, 0.04)
    private let nodeRotation = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 1, 0))

    private func makeGLTFNode(name: String, translation: SIMD3<Float>, rotation: simd_quatf) throws -> GLTFNode {
        let json = """
        {
            "name": "\(name)",
            "translation": [\(translation.x), \(translation.y), \(translation.z)],
            "rotation": [\(rotation.imag.x), \(rotation.imag.y), \(rotation.imag.z), \(rotation.real)],
            "scale": [1.0, 1.0, 1.0]
        }
        """
        return try JSONDecoder().decode(GLTFNode.self, from: Data(json.utf8))
    }

    /// A rotated, translated collider node (index 0) plus two chain joints
    /// hanging below it, with one authored capsule on the node.
    private func makeModel(device: MTLDevice?) throws -> VRMModel {
        let model = try VRMBuilder().setSkeleton(.defaultHumanoid).build()
        model.nodes.removeAll()

        let colliderNode = VRMNode(index: 0, gltfNode: try makeGLTFNode(name: "collider", translation: nodeWorld, rotation: nodeRotation))
        model.nodes.append(colliderNode)
        var previous = colliderNode
        for i in 1...2 {
            let node = VRMNode(index: i, gltfNode: try makeGLTFNode(name: "joint\(i)", translation: SIMD3<Float>(0, -0.1, 0), rotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)))
            node.parent = previous
            previous.children.append(node)
            model.nodes.append(node)
            previous = node
        }
        colliderNode.updateWorldTransform()

        var springBone = VRMSpringBone()
        springBone.colliders = [VRMCollider(node: 0, shape: .capsule(offset: offset, radius: 0.05, tail: tail))]
        springBone.colliderGroups = [VRMColliderGroup(name: "g", colliders: [0])]
        var spring = VRMSpring(name: "s")
        spring.joints = (0..<3).map { i in
            var joint = VRMSpringJoint(node: i)
            joint.hitRadius = 0.02
            joint.stiffness = 0.5
            joint.gravityPower = 0.5
            joint.gravityDir = SIMD3<Float>(0, -1, 0)
            joint.dragForce = 0.4
            return joint
        }
        spring.colliderGroups = [0]
        springBone.springs = [spring]
        model.springBone = springBone

        if let device {
            model.device = device
            let buffers = SpringBoneBuffers(device: device)
            buffers.allocateBuffers(numBones: 3, numSpheres: 0, numCapsules: 1, numPlanes: 0)
            model.springBoneBuffers = buffers
            model.springBoneGlobalParams = SpringBoneGlobalParams(
                gravity: .zero, dtSub: Float(1.0 / 120.0),
                windAmplitude: 0, windFrequency: 0, windPhase: 0, windDirection: SIMD3<Float>(1, 0, 0),
                substeps: 1, numBones: 3, numSpheres: 0, numCapsules: 1, numPlanes: 0)
        }
        return model
    }

    private var expectedP0: SIMD3<Float> { nodeWorld + nodeRotation.act(offset) }
    private var expectedP1: SIMD3<Float> { nodeWorld + nodeRotation.act(tail) }

    private func assertClose(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ message: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThan(simd_length(a - b), 1e-5, "\(message): got \(a), expected \(b)", file: file, line: line)
    }

    func testContactSetWorldCapsuleTreatsTailAsLocalPosition() throws {
        let model = try makeModel(device: nil)
        let capsule = try XCTUnwrap(SpringBoneContactColliderSet.worldCapsule(model.springBone!.colliders[0], model: model))
        assertClose(capsule.p0, expectedP0, "p0 = node world + R * offset")
        assertClose(capsule.p1, expectedP1, "p1 = node world + R * tail")
    }

    func testPopulateUploadsAbsoluteCapsuleTail() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let model = try makeModel(device: device)
        let system = try SpringBoneComputeSystem(device: device)
        try system.populateSpringBoneData(model: model)

        let buffer = try XCTUnwrap(model.springBoneBuffers?.capsuleColliders)
        let uploaded = buffer.contents().bindMemory(to: CapsuleCollider.self, capacity: 1)[0]
        assertClose(uploaded.p0, expectedP0, "uploaded p0")
        assertClose(uploaded.p1, expectedP1, "uploaded p1")
    }
}
