//
// Copyright 2025 Arkavo
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//

import XCTest
import Metal
import simd
@testable import VRMMetalKit

/// Tests for the rigid-fallback joint binding (#161).
///
/// When the renderer is using the skinned pipeline but encounters a node where
/// `node.skin == nil`, it must bind a buffer of identity matrices at the joint
/// matrices slot so the next draw does NOT inherit the previous draw's joint
/// palette. Previously the `else if hasSkinning` branch logged "using rigid
/// transform" but did not bind any joint buffer at all.
final class SkinningIdentityFallbackTests: XCTestCase {

    private var device: MTLDevice!

    override func setUp() async throws {
        device = MTLCreateSystemDefaultDevice()
        guard device != nil else {
            throw XCTSkip("Metal device not available")
        }
    }

    /// The skinning system must expose an identity-matrix buffer suitable for
    /// binding at `ResourceIndices.jointMatricesBuffer` when a skinned-pipeline
    /// draw has no actual skin to use.
    func testIdentityJointBufferExposedAfterSetup() {
        let system = VRMSkinningSystem(device: device)
        system.setupForSkins([])

        guard let buffer = system.identityJointMatricesBuffer else {
            return XCTFail("VRMSkinningSystem must expose an identity-matrix buffer for the rigid-fallback path")
        }

        // The buffer must be large enough to satisfy the same shader read pattern
        // as the live joint buffer — at least 256 matrices (matches the existing
        // padding floor in setupForSkins).
        let stride = MemoryLayout<float4x4>.stride
        XCTAssertGreaterThanOrEqual(buffer.length, 256 * stride,
                                    "Identity joint buffer must hold at least 256 matrices to match shader clamp range")
    }

    /// Every matrix in the identity buffer must be the identity transform.
    func testIdentityJointBufferContainsOnlyIdentities() {
        let system = VRMSkinningSystem(device: device)
        system.setupForSkins([])

        guard let buffer = system.identityJointMatricesBuffer else {
            return XCTFail("identityJointMatricesBuffer must be allocated even when no skins are present")
        }

        let count = buffer.length / MemoryLayout<float4x4>.stride
        let ptr = buffer.contents().bindMemory(to: float4x4.self, capacity: count)
        for i in 0..<count {
            let m = ptr[i]
            XCTAssertEqual(m, matrix_identity_float4x4,
                           "Matrix \(i) of identity joint buffer is not identity: \(m)")
        }
    }

    /// The accessor must be idempotent — calling it twice returns the same buffer
    /// (no per-call allocation, no reset of contents).
    func testIdentityJointBufferIsIdempotent() {
        let system = VRMSkinningSystem(device: device)
        system.setupForSkins([])

        let first = system.identityJointMatricesBuffer
        let second = system.identityJointMatricesBuffer
        XCTAssertNotNil(first)
        XCTAssertTrue(first === second,
                      "identityJointMatricesBuffer must return the same MTLBuffer instance on repeated access")
    }

    /// The identity buffer must NOT alias the live joint buffer — otherwise an
    /// updateJointMatrices call would overwrite the identities and reintroduce
    /// the original bug.
    func testIdentityJointBufferIsDistinctFromLiveJointBuffer() {
        let system = VRMSkinningSystem(device: device)
        system.setupForSkins([])

        guard let identity = system.identityJointMatricesBuffer,
              let live = system.getJointMatricesBuffer() else {
            return XCTFail("Both buffers must be allocated after setupForSkins")
        }
        XCTAssertFalse(identity === live,
                       "Identity buffer must be a separate allocation so live updates cannot corrupt it")
    }
}
