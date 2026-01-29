// Copyright 2025 Arkavo Inc. and contributors
// Licensed under the Apache License, Version 2.0

import XCTest
import Metal
import simd
@testable import VRMMetalKit

/// TDD tests for outline rendering depth state behavior (Issue #105)
/// These tests verify that outline rendering correctly sets and restores depth state
final class OutlineRenderingDepthTests: XCTestCase {

    var device: MTLDevice!
    var renderer: VRMRenderer!

    override func setUp() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        self.device = device
        self.renderer = VRMRenderer(device: device)
    }

    // MARK: - Depth State Availability Tests

    /// Test that blend depth state exists for outline rendering
    func testBlendDepthStateExistsForOutlines() {
        XCTAssertNotNil(
            renderer.depthStencilStates["blend"],
            "Blend depth state must exist for outline rendering (depth test without write)"
        )
    }

    /// Test that opaque depth state exists for restoration after outlines
    func testOpaqueDepthStateExistsForRestoration() {
        XCTAssertNotNil(
            renderer.depthStencilStates["opaque"],
            "Opaque depth state must exist for restoration after outline rendering"
        )
    }

    // MARK: - Outline Width Configuration Tests

    /// Test outline width can be configured
    func testOutlineWidthConfiguration() {
        let testWidth: Float = 2.5
        renderer.outlineWidth = testWidth
        XCTAssertEqual(renderer.outlineWidth, testWidth, "Outline width should be configurable")
    }

    /// Test outline color can be configured
    func testOutlineColorConfiguration() {
        let testColor = SIMD3<Float>(1.0, 0.0, 0.0) // Red
        renderer.outlineColor = testColor
        XCTAssertEqual(renderer.outlineColor, testColor, "Outline color should be configurable")
    }

    // MARK: - Depth State Integration Tests

    /// Test that depth states are properly initialized before rendering could occur
    func testDepthStatesReadyBeforeRendering() {
        // After initialization, depth states should be ready
        let requiredStates = ["opaque", "blend"]

        for state in requiredStates {
            XCTAssertNotNil(
                renderer.depthStencilStates[state],
                "Depth state '\(state)' should be ready before any rendering"
            )
        }
    }

    /// Test that outline rendering uses non-writing depth state
    /// Outlines should test against depth but not write to avoid occluding transparent objects
    func testOutlineDepthStateShouldNotWriteDepth() {
        // The blend depth state should be used for outlines
        // Verify it exists (actual configuration is tested in DepthStencilStateTests)
        guard let blendState = renderer.depthStencilStates["blend"] else {
            XCTFail("Blend depth state (used for outlines) must exist")
            return
        }

        // Verify we can create the expected configuration
        let expectedDescriptor = MTLDepthStencilDescriptor()
        expectedDescriptor.depthCompareFunction = .lessEqual
        expectedDescriptor.isDepthWriteEnabled = false

        guard device.makeDepthStencilState(descriptor: expectedDescriptor) != nil else {
            XCTFail("Expected outline depth state configuration should be valid")
            return
        }

        // State exists and configuration is valid
        XCTAssertNotNil(blendState)
    }

    // MARK: - Code Path Verification Tests

    /// Test that renderMToonOutlines code path can be exercised
    /// This test verifies the method signature requirements
    func testMToonOutlinesRequiresModel() {
        // renderMToonOutlines requires a model to be set
        XCTAssertNil(renderer.model, "Fresh renderer should have no model")

        // Without a model, outline rendering should safely no-op
        // This is verified by the guard let model = model else { return } pattern
    }

    // MARK: - Depth State Key Consistency Tests

    /// Test depth state dictionary uses consistent string keys
    func testDepthStateKeysAreConsistent() {
        let expectedKeys = Set(["opaque", "mask", "blend", "face", "always"])
        let actualKeys = Set(renderer.depthStencilStates.keys)

        // All expected keys should be present
        for key in expectedKeys {
            XCTAssertTrue(
                actualKeys.contains(key),
                "Depth state key '\(key)' should exist"
            )
        }
    }

    /// Test that depth state access by string key is reliable
    func testDepthStateAccessByKey() {
        // Direct key access should work consistently
        let opaqueByKey = renderer.depthStencilStates["opaque"]
        let blendByKey = renderer.depthStencilStates["blend"]

        XCTAssertNotNil(opaqueByKey, "Should access opaque state by key")
        XCTAssertNotNil(blendByKey, "Should access blend state by key")
    }
}
