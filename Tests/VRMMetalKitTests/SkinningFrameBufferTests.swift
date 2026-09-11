// Copyright 2026 Arkavo Inc. and contributors
// Licensed under the Apache License, Version 2.0.

import XCTest
import Metal
import simd
@testable import VRMMetalKit

final class SkinningFrameBufferTests: XCTestCase {
    private func fixture() throws -> (MTLDevice, VRMSkinningSystem, VRMSkin, VRMNode) {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let gltf = try JSONDecoder().decode(GLTFNode.self, from: Data("{}".utf8))
        let joint = VRMNode(index: 0, gltfNode: gltf)
        let skin = VRMSkin()
        skin.joints = [joint]
        skin.inverseBindMatrices = [matrix_identity_float4x4]
        let system = VRMSkinningSystem(device: device)
        system.setupForSkins([skin])
        return (device, system, skin, joint)
    }

    // Queue all reads before submitting any work. A single shared palette would
    // make every GPU read observe the third pose, even without timing luck.
    func testQueuedGPUFramesKeepTheirOwnPose() throws {
        let (device, system, skin, joint) = try fixture()
        let queue = try XCTUnwrap(device.makeCommandQueue())
        var reads: [(MTLCommandBuffer, MTLBuffer)] = []
        for slot in 0..<VRMConstants.Rendering.maxBufferedFrames {
            system.beginFrame(bufferIndex: slot)
            joint.translation = SIMD3<Float>(Float(slot + 1), 0, 0)
            joint.updateWorldTransform()
            system.markSkinsDirtyIfJointsMoved([skin])
            system.updateJointMatrices(for: skin, skinIndex: 0)
            let palette = try XCTUnwrap(system.getJointMatricesBuffer())
            let output = try XCTUnwrap(device.makeBuffer(length: MemoryLayout<float4x4>.stride))
            let cb = try XCTUnwrap(queue.makeCommandBuffer())
            let blit = try XCTUnwrap(cb.makeBlitCommandEncoder())
            blit.copy(from: palette, sourceOffset: skin.bufferByteOffset,
                      to: output, destinationOffset: 0, size: output.length)
            blit.endEncoding()
            reads.append((cb, output))
        }
        for (cb, _) in reads { cb.commit() }
        for (slot, read) in reads.enumerated() {
            read.0.waitUntilCompleted()
            XCTAssertNil(read.0.error)
            let matrix = read.1.contents().load(as: float4x4.self)
            XCTAssertEqual(matrix.columns.3.x, Float(slot + 1))
        }
    }

    func testIdlePosePropagatesToReusedSlots() throws {
        let (_, system, skin, joint) = try fixture()
        for slot in 0..<VRMConstants.Rendering.maxBufferedFrames {
            system.beginFrame(bufferIndex: slot)
            joint.translation = SIMD3<Float>(Float(slot + 1), 0, 0)
            joint.updateWorldTransform()
            system.markSkinsDirtyIfJointsMoved([skin])
            system.updateJointMatrices(for: skin, skinIndex: 0)
        }
        let lastPose = Float(VRMConstants.Rendering.maxBufferedFrames)
        // No further world-generation changes: every reused slot must acquire
        // the final pose even though the shared dirty flag is already clear.
        for slot in 0..<VRMConstants.Rendering.maxBufferedFrames {
            system.beginFrame(bufferIndex: slot)
            system.markSkinsDirtyIfJointsMoved([skin])
            XCTAssertFalse(system.isSkinDirty(skinIndex: 0))
            system.updateJointMatrices(for: skin, skinIndex: 0)
            let palette = try XCTUnwrap(system.getJointMatricesBuffer())
            XCTAssertEqual(palette.contents().load(as: float4x4.self).columns.3.x, lastPose)
        }
    }

    func testIdentityOverrideRestoresPoseAcrossSlots() throws {
        let (_, system, skin, joint) = try fixture()
        joint.translation = SIMD3<Float>(4, 0, 0)
        joint.updateWorldTransform()
        system.updateJointMatrices(for: skin, skinIndex: 0)
        system.testIdentityPalette = 0
        system.beginFrame(bufferIndex: 1)
        system.updateJointMatrices(for: skin, skinIndex: 0)
        XCTAssertEqual(try XCTUnwrap(system.getJointMatricesBuffer()).contents().load(as: float4x4.self),
                       matrix_identity_float4x4)
        system.testIdentityPalette = nil
        system.beginFrame(bufferIndex: 2)
        system.updateJointMatrices(for: skin, skinIndex: 0)
        XCTAssertEqual(try XCTUnwrap(system.getJointMatricesBuffer()).contents().load(as: float4x4.self).columns.3.x, 4)
        system.beginFrame(bufferIndex: 1)
        system.updateJointMatrices(for: skin, skinIndex: 0)
        XCTAssertEqual(try XCTUnwrap(system.getJointMatricesBuffer()).contents().load(as: float4x4.self).columns.3.x, 4)
    }
}
