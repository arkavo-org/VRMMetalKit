// Copyright 2026 Arkavo Inc. and contributors
// Licensed under the Apache License, Version 2.0

import XCTest
import Metal
import simd
@testable import VRMMetalKit

/// Outlines on translucent MToon materials. The inverted hull is drawn after
/// its surface and never writes depth, matching three-vrm (surface group, then
/// a BackSide outline group on the same buffer) and UniVRM (forward pass, then
/// outline pass). So whether the hull covers the surface depends on the
/// surface's depth write: `VRMC_materials_mtoon.transparentWithZWrite`.
@MainActor
final class MToonTransparentOutlineTests: XCTestCase {
    private var device: MTLDevice!

    override func setUp() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        self.device = device
    }

    /// A `transparentWithZWrite` surface writes depth, so its own hull's back
    /// faces behind it fail the depth test and only the silhouette ring shows.
    func testTransparentWithZWriteSurfaceIsNotCoveredByItsOwnHull() async throws {
        for doubleSided in [false, true] {
            let outlined = try await leatherFrame(zWrite: true, outlined: true, doubleSided: doubleSided)
            let bare = try await leatherFrame(zWrite: true, outlined: false, doubleSided: doubleSided)
            let covered = coveredFraction(outlined, bare: bare)
            XCTAssertLessThan(covered, 0.1,
                "\(doubleSided ? "Dedicated" : "Merged") hull covered \(Int(covered * 100))% of a transparentWithZWrite surface")
        }
    }

    /// Plain transparent surfaces do not write depth, so the hull drawn after
    /// them covers them, as in three-vrm and UniVRM. Guards against a change
    /// that would silently diverge from the reference implementations.
    func testPlainTransparentSurfaceFollowsTheReferenceDrawOrder() async throws {
        let outlined = try await leatherFrame(zWrite: false, outlined: true, doubleSided: false)
        let bare = try await leatherFrame(zWrite: false, outlined: false, doubleSided: false)
        XCTAssertGreaterThan(coveredFraction(outlined, bare: bare), 0.5,
            "A plain BLEND surface's hull should draw over it, as in three-vrm and UniVRM")
    }

    // MARK: - Helpers

    private func leatherFrame(zWrite: Bool, outlined: Bool, doubleSided: Bool) async throws -> [UInt8] {
        let model = try await SwatchScene.load(.rigid, device: device)
        let leather = model.materials[1]
        leather.alphaMode = "BLEND"
        leather.baseColorFactor.w = 0.9
        leather.transparentWithZWrite = zWrite
        leather.doubleSided = doubleSided
        if !outlined { leather.mtoon?.outlineWidthMode = .none }
        return try SwatchScene.render(model, device: device)
    }

    /// Fraction of the bare sphere's pixels that the outlined frame darkened
    /// by more than 0.1 luma (the swatch outline colour is near-black).
    private func coveredFraction(_ outlined: [UInt8], bare: [UInt8]) -> Double {
        var sphere = 0
        var covered = 0
        for y in 0..<512 {
            for x in SwatchScene.third(1, size: 512) {
                let i = (y * 512 + x) * 4
                guard bare[i] < 250 || bare[i + 1] < 250 || bare[i + 2] < 250 else { continue }
                sphere += 1
                if SwatchScene.luma(bare, i) - SwatchScene.luma(outlined, i) > 0.1 { covered += 1 }
            }
        }
        return sphere > 0 ? Double(covered) / Double(sphere) : 0
    }
}
