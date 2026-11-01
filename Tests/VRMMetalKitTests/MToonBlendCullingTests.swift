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

    /// When BLEND draws come first in the encoder, no opaque draw has set the
    /// winding. A full-alpha single-sided BLEND sphere must still show its
    /// front faces, like its opaque twin, not its inside.
    func testFirstDrawSingleSidedBlendShowsFrontFaces() async throws {
        let blend = try await allSpheresFrame(alphaMode: "BLEND")
        let opaque = try await allSpheresFrame(alphaMode: "OPAQUE")
        let stats = SwatchScene.stats(blend, reference: opaque, size: 512, threshold: 6)
        XCTAssertLessThan(stats.changedPixels, 200,
            "Full-alpha single-sided BLEND spheres differ from opaque in \(stats.changedPixels) px (max Δ \(stats.maxDelta)); back faces may be drawn instead of front faces")
    }

    /// #456: a material whose name matches the lace/collar/ribbon/frill/ruffle
    /// heuristic still follows its authored `doubleSided`.
    func testNameMatchedBlendHonoursDoubleSided() async throws {
        let singleSided = try await collarSphereFrame(zWrite: false, doubleSided: false)
        let doubleSided = try await collarSphereFrame(zWrite: false, doubleSided: true)
        let stats = SwatchScene.stats(singleSided, reference: doubleSided, size: 512,
                                      columns: SwatchScene.third(1, size: 512))
        XCTAssertGreaterThan(stats.changedPixels, 1000,
            "A single-sided BLEND sphere named \"Collars\" rendered like a double-sided one; its back faces were not culled")
    }

    /// #456: a name-matched BLEND material writes depth only when it authors
    /// `transparentWithZWrite`. On a double-sided sphere a depth write lets
    /// back faces earlier in index order hide front faces, so the two differ.
    func testNameMatchedBlendHonoursTransparentWithZWrite() async throws {
        let zWrite = try await collarSphereFrame(zWrite: true, doubleSided: true)
        let plain = try await collarSphereFrame(zWrite: false, doubleSided: true)
        let stats = SwatchScene.stats(zWrite, reference: plain, size: 512,
                                      columns: SwatchScene.third(1, size: 512))
        XCTAssertGreaterThan(stats.changedPixels, 100,
            "A double-sided BLEND sphere named \"Collars\" rendered identically with transparentWithZWrite on and off; its depth write ignores the authored flag")
    }

    // MARK: - Helpers

    private func collarSphereFrame(zWrite: Bool, doubleSided: Bool) async throws -> [UInt8] {
        let model = try await loadSwatchesRenamingMiddleMaterial(to: "Collars")
        let sphere = model.materials[1]
        XCTAssertEqual(sphere.name, "Collars")
        sphere.alphaMode = "BLEND"
        sphere.baseColorFactor.w = 0.6
        sphere.transparentWithZWrite = zWrite
        sphere.doubleSided = doubleSided
        sphere.mtoon?.outlineWidthMode = .none
        return try SwatchScene.render(model, device: device)
    }

    /// Loads the rigid swatch fixture with its middle material (`Leather`)
    /// renamed. The new name must have the same byte length so the GLB chunk
    /// lengths stay valid.
    private func loadSwatchesRenamingMiddleMaterial(to name: String) async throws -> VRMModel {
        guard let url = Bundle.module.url(
            forResource: SwatchScene.Fixture.rigid.rawValue,
            withExtension: "vrm",
            subdirectory: "TestData/MToon") else {
            throw XCTSkip("swatch fixture missing")
        }
        let original = Data("\"Leather\"".utf8)
        let renamed = Data("\"\(name)\"".utf8)
        precondition(original.count == renamed.count, "replacement name must be 7 bytes")
        var data = try Data(contentsOf: url)
        guard let range = data.range(of: original) else {
            throw XCTSkip("swatch fixture has no material named Leather")
        }
        data.replaceSubrange(range, with: renamed)
        return try await VRMModel.load(from: data, device: device)
    }

    private func allSpheresFrame(alphaMode: String) async throws -> [UInt8] {
        let model = try await SwatchScene.load(.rigid, device: device)
        for material in model.materials {
            material.alphaMode = alphaMode
            material.baseColorFactor.w = 1
            material.doubleSided = false
            material.mtoon?.outlineWidthMode = .none
        }
        return try SwatchScene.render(model, device: device)
    }

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
