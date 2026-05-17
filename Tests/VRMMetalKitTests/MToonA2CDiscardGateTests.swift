// Copyright 2025 Arkavo Inc. and contributors
// Licensed under the Apache License, Version 2.0

import XCTest
import Metal
@testable import VRMMetalKit

/// Tests for VMK#264 + VMK#266: the MToon shader's
/// `discard_fragment()` call on MASK materials defeats hardware
/// alpha-to-coverage even when the draw loop binds the A2C pipeline.
///
/// VMK#264 calls for a shader gate so the discard only fires when A2C
/// is NOT active. VMK#266 calls for a behavioral test that the gate is
/// wired through — a renderer-level check that the material uniform's
/// `alphaMode` is remapped from `1` (MASK with discard) to `3`
/// (MASK_A2C, no discard, hardware computes coverage from output alpha)
/// when the A2C pipeline is the one being bound for a MASK material.
///
/// This is a unit-level test against `selectPipelineForDraw` +
/// `alphaModeForUniform` so the wire-up regresses cleanly. A
/// pixel-level behavioral test (compare sampleCount=1 vs sampleCount=4
/// renders of an alpha-gradient quad and assert the alpha histogram
/// differs) is the next step but requires MSAA support in the offscreen
/// render harness.
@MainActor
final class MToonA2CDiscardGateTests: XCTestCase {

    private var device: MTLDevice!

    override func setUp() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device not available")
        }
        self.device = device
    }

    /// VMK#264 spec: when A2C is active for a MASK material (the renderer
    /// is binding `mtoon_mask_a2c`), the material uniform uploaded to the
    /// shader must use `alphaMode = 3` (MASK_A2C), not `1` (MASK).
    /// Otherwise the shader's `discard_fragment()` on
    /// `alphaMode == 1 && baseColor.a < alphaCutoff` fires and removes
    /// the fragment before hardware A2C can compute subsample coverage.
    func testMaskWithA2CActiveUsesAlphaModeThreeForUniform() throws {
        let config = RendererConfig(strict: .off,
                                    sampleCount: 4,
                                    alphaToCoverageForMASK: true)
        let renderer = VRMRenderer(device: device, config: config)

        // Pipeline selection picks the A2C variant for MASK + MSAA + opt-in.
        let pipeline = renderer.selectPipelineForDraw(
            alphaMode: "mask",
            isSkinned: false,
            debugWireframe: false
        )
        XCTAssertEqual(pipeline?.label, "mtoon_mask_a2c",
            "Sanity: MASK + sampleCount=4 + alphaToCoverageForMASK=true " +
            "must route to mtoon_mask_a2c. Got \(pipeline?.label ?? "nil").")

        // Uniform's alphaMode must be 3 (MASK_A2C) so the shader's
        // discard_fragment() check (which fires only on alphaMode == 1)
        // does not run.
        let uniformAlphaMode = renderer.alphaModeForUniform(
            alphaMode: "mask",
            isSkinned: false
        )
        XCTAssertEqual(uniformAlphaMode, 3,
            "VMK#264: MASK material under A2C must upload alphaMode=3 " +
            "(MASK_A2C) so the shader skips discard_fragment() and " +
            "outputs sampled alpha for hardware coverage. Got " +
            "\(uniformAlphaMode); if 1 the discard runs and A2C is dead code.")
    }

    /// Same MASK material, A2C opt-OUT (default): pipeline routes to
    /// opaque and uniform alphaMode stays 1, preserving the spec-default
    /// alpha-test path.
    func testMaskWithA2COptedOutUsesAlphaModeOneForUniform() throws {
        let config = RendererConfig(strict: .off,
                                    sampleCount: 4,
                                    alphaToCoverageForMASK: false)
        let renderer = VRMRenderer(device: device, config: config)

        let pipeline = renderer.selectPipelineForDraw(
            alphaMode: "mask", isSkinned: false, debugWireframe: false
        )
        XCTAssertNotEqual(pipeline?.label, "mtoon_mask_a2c",
            "Without alphaToCoverageForMASK opt-in MASK must NOT route to A2C.")

        let uniformAlphaMode = renderer.alphaModeForUniform(
            alphaMode: "mask", isSkinned: false
        )
        XCTAssertEqual(uniformAlphaMode, 1,
            "Without A2C opt-in, MASK upload must stay at alphaMode=1 " +
            "(the shader's spec-default discard_fragment path).")
    }

    /// Same MASK material with the opt-in but sampleCount=1: no MSAA, so
    /// the A2C pipeline can't be active; uniform stays at 1.
    func testMaskWithoutMSAAUsesAlphaModeOneEvenWithA2COptIn() throws {
        let config = RendererConfig(strict: .off,
                                    sampleCount: 1,
                                    alphaToCoverageForMASK: true)
        let renderer = VRMRenderer(device: device, config: config)

        let uniformAlphaMode = renderer.alphaModeForUniform(
            alphaMode: "mask", isSkinned: false
        )
        XCTAssertEqual(uniformAlphaMode, 1,
            "A2C requires MSAA. sampleCount=1 must keep MASK at alphaMode=1 " +
            "regardless of the alphaToCoverageForMASK opt-in.")
    }

    /// Skinned MASK + A2C: must also remap to 3 so the skinned A2C
    /// pipeline (`mtoon_skinned_mask_a2c`) sees the right shader path.
    func testSkinnedMaskWithA2CActiveUsesAlphaModeThree() throws {
        let config = RendererConfig(strict: .off,
                                    sampleCount: 4,
                                    alphaToCoverageForMASK: true)
        let renderer = VRMRenderer(device: device, config: config)

        let uniformAlphaMode = renderer.alphaModeForUniform(
            alphaMode: "mask", isSkinned: true
        )
        XCTAssertEqual(uniformAlphaMode, 3,
            "Skinned MASK under A2C must also upload alphaMode=3.")
    }

    /// BLEND and OPAQUE are unaffected by the A2C gate.
    func testBlendAndOpaqueUniformAlphaModeUnchangedByA2COptIn() throws {
        let config = RendererConfig(strict: .off,
                                    sampleCount: 4,
                                    alphaToCoverageForMASK: true)
        let renderer = VRMRenderer(device: device, config: config)

        XCTAssertEqual(renderer.alphaModeForUniform(alphaMode: "blend", isSkinned: false), 2)
        XCTAssertEqual(renderer.alphaModeForUniform(alphaMode: "opaque", isSkinned: false), 0)
    }
}
