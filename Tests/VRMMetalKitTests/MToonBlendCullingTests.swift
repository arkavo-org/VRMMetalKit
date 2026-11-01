// Copyright 2026 Arkavo Inc. and contributors
// Licensed under the Apache License, Version 2.0

import XCTest
import Metal
import simd
@testable import VRMMetalKit

/// Back-face culling of translucent (`BLEND`) MToon surfaces. glTF 2.0 requires
/// back-face culling when `doubleSided` is false, and three-vrm culls them
/// (`side: FrontSide`). A closed single-sided sphere therefore shows only its
/// front faces, so its depth write (`transparentWithZWrite`) cannot change the
/// image: no front face of a convex mesh occludes another.
@MainActor
final class MToonBlendCullingTests: XCTestCase {
    private var device: MTLDevice!

    override func setUp() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        self.device = device
    }

    /// With back faces drawn, a depth-writing surface lets back faces that come
    /// earlier in index order hide front faces, giving triangle-order stripes.
    func testSingleSidedBlendSphereIsIdenticalWithAndWithoutZWrite() async throws {
        let zWrite = try await blendSphereFrame(zWrite: true, doubleSided: false)
        let plain = try await blendSphereFrame(zWrite: false, doubleSided: false)
        let stats = SwatchScene.stats(zWrite, reference: plain, size: 512, threshold: 0)
        XCTAssertEqual(stats.changedPixels, 0,
            "transparentWithZWrite changed \(stats.changedPixels) px (max Δ \(stats.maxDelta)) of a closed single-sided BLEND sphere")
    }

    func testSingleSidedBlendCullsBackFaces() async throws {
        let singleSided = try await blendSphereFrame(zWrite: false, doubleSided: false)
        let doubleSided = try await blendSphereFrame(zWrite: false, doubleSided: true)
        let stats = SwatchScene.stats(singleSided, reference: doubleSided, size: 512,
                                      columns: SwatchScene.third(1, size: 512))
        XCTAssertGreaterThan(stats.changedPixels, 1000,
            "A single-sided BLEND sphere rendered like a double-sided one; its back faces were not culled")
    }

    // MARK: - Helpers

    private func blendSphereFrame(zWrite: Bool, doubleSided: Bool) async throws -> [UInt8] {
        let model = try await SwatchScene.load(.rigid, device: device)
        let sphere = model.materials[1]
        sphere.alphaMode = "BLEND"
        sphere.baseColorFactor.w = 0.6
        sphere.transparentWithZWrite = zWrite
        sphere.doubleSided = doubleSided
        sphere.mtoon?.outlineWidthMode = .none
        return try SwatchScene.render(model, device: device)
    }
}
