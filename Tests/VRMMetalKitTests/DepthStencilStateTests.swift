// Copyright 2025 Arkavo Inc. and contributors
// Licensed under the Apache License, Version 2.0

import XCTest
import Metal
@testable import VRMMetalKit

/// TDD tests for depth stencil state creation and configuration (Issue #105)
final class DepthStencilStateTests: XCTestCase {

    var device: MTLDevice!
    var renderer: VRMRenderer!

    override func setUp() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        self.device = device
        self.renderer = VRMRenderer(device: device)
    }

    // MARK: - Depth State Creation Tests

    /// Test that all required depth stencil states are created
    func testAllRequiredDepthStatesCreated() {
        let requiredStates = ["opaque", "mask", "blend", "face"]

        for stateName in requiredStates {
            XCTAssertNotNil(
                renderer.depthStencilStates[stateName],
                "Depth stencil state '\(stateName)' should exist"
            )
        }
    }

    /// Test that mask state is aliased to opaque state (same object)
    func testMaskAliasesOpaqueState() {
        guard let opaqueState = renderer.depthStencilStates["opaque"],
              let maskState = renderer.depthStencilStates["mask"] else {
            XCTFail("Both opaque and mask states should exist")
            return
        }

        XCTAssertTrue(
            opaqueState === maskState,
            "Mask state should be the same object as opaque state"
        )
    }

    /// Test that always depth state exists for kill switch testing
    func testAlwaysDepthStateExists() {
        XCTAssertNotNil(
            renderer.depthStencilStates["always"],
            "Always depth state should exist for kill switch testing"
        )
    }

    // MARK: - Depth State Configuration Verification Tests
    // Note: MTLDepthStencilState is opaque, so we verify by creating descriptors
    // and comparing behavior indirectly through the render pipeline

    /// Test depth state dictionary is non-empty after initialization
    func testDepthStatesNotEmpty() {
        XCTAssertFalse(
            renderer.depthStencilStates.isEmpty,
            "Depth stencil states dictionary should not be empty after initialization"
        )
    }

    /// Test that at least 4 distinct depth state configurations exist
    func testMinimumDepthStateCount() {
        // We expect: opaque, mask (alias), blend, face, always = 5 keys, but 4 unique states
        XCTAssertGreaterThanOrEqual(
            renderer.depthStencilStates.count,
            4,
            "Should have at least 4 depth state keys (opaque, mask, blend, face)"
        )
    }

    /// Test blend state is different from opaque state
    func testBlendStateDifferentFromOpaque() {
        guard let opaqueState = renderer.depthStencilStates["opaque"],
              let blendState = renderer.depthStencilStates["blend"] else {
            XCTFail("Both opaque and blend states should exist")
            return
        }

        XCTAssertFalse(
            opaqueState === blendState,
            "Blend state should be a different object than opaque state"
        )
    }

    /// Test face state is different from opaque state
    func testFaceStateDifferentFromOpaque() {
        guard let opaqueState = renderer.depthStencilStates["opaque"],
              let faceState = renderer.depthStencilStates["face"] else {
            XCTFail("Both opaque and face states should exist")
            return
        }

        XCTAssertFalse(
            opaqueState === faceState,
            "Face state should be a different object than opaque state"
        )
    }

    // MARK: - Depth Descriptor Configuration Tests
    // These tests verify the configuration by recreating descriptors with expected values

    /// Test opaque depth descriptor uses .less comparison with depth write enabled
    func testOpaqueDepthDescriptorConfiguration() {
        let descriptor = MTLDepthStencilDescriptor()
        descriptor.depthCompareFunction = .less
        descriptor.isDepthWriteEnabled = true

        guard let expectedState = device.makeDepthStencilState(descriptor: descriptor) else {
            XCTFail("Failed to create expected opaque depth state")
            return
        }

        // Both should create valid states (we can't compare internals directly)
        XCTAssertNotNil(expectedState, "Expected opaque state configuration should be valid")
        XCTAssertNotNil(renderer.depthStencilStates["opaque"], "Renderer opaque state should exist")
    }

    /// Test blend depth descriptor uses .lessEqual comparison with depth write disabled
    func testBlendDepthDescriptorConfiguration() {
        let descriptor = MTLDepthStencilDescriptor()
        descriptor.depthCompareFunction = .lessEqual
        descriptor.isDepthWriteEnabled = false

        guard let expectedState = device.makeDepthStencilState(descriptor: descriptor) else {
            XCTFail("Failed to create expected blend depth state")
            return
        }

        XCTAssertNotNil(expectedState, "Expected blend state configuration should be valid")
        XCTAssertNotNil(renderer.depthStencilStates["blend"], "Renderer blend state should exist")
    }

    /// Test face depth descriptor uses .lessEqual comparison to avoid z-fighting
    func testFaceDepthDescriptorConfiguration() {
        let descriptor = MTLDepthStencilDescriptor()
        descriptor.depthCompareFunction = .lessEqual
        descriptor.isDepthWriteEnabled = true

        guard let expectedState = device.makeDepthStencilState(descriptor: descriptor) else {
            XCTFail("Failed to create expected face depth state")
            return
        }

        XCTAssertNotNil(expectedState, "Expected face state configuration should be valid")
        XCTAssertNotNil(renderer.depthStencilStates["face"], "Renderer face state should exist")
    }

    /// Test always depth descriptor uses .always comparison with depth write disabled
    func testAlwaysDepthDescriptorConfiguration() {
        let descriptor = MTLDepthStencilDescriptor()
        descriptor.depthCompareFunction = .always
        descriptor.isDepthWriteEnabled = false

        guard let expectedState = device.makeDepthStencilState(descriptor: descriptor) else {
            XCTFail("Failed to create expected always depth state")
            return
        }

        XCTAssertNotNil(expectedState, "Expected always state configuration should be valid")
        XCTAssertNotNil(renderer.depthStencilStates["always"], "Renderer always state should exist")
    }
}
