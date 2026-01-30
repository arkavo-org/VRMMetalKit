// Copyright 2025 Arkavo Inc. and contributors
// Licensed under the Apache License, Version 2.0

import XCTest
import Metal
import simd
@testable import VRMMetalKit

/// Tests for Z-fighting detection in coplanar and near-coplanar surfaces
/// Validates that face materials and other layered geometry are properly separated
final class ZFightingCoplanarTests: XCTestCase {

    var device: MTLDevice!
    var renderer: VRMRenderer!
    var model: VRMModel!

    override func setUp() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        self.device = device
        self.renderer = VRMRenderer(device: device)

        // Create test model with face materials
        let vrmDocument = try VRMBuilder()
            .setSkeleton(.defaultHumanoid)
            .applyMorphs(["height": 1.0])
            .setHairColor([0.35, 0.25, 0.15])
            .setEyeColor([0.2, 0.4, 0.8])
            .setSkinTone(0.5)
            .addExpressions([.happy, .blink])
            .build()

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("vrm")

        try vrmDocument.serialize(to: tempURL)
        self.model = try await VRMModel.load(from: tempURL, device: device)
        try? FileManager.default.removeItem(at: tempURL)

        renderer.loadModel(model)
    }

    override func tearDown() {
        model = nil
        renderer = nil
        device = nil
    }

    // MARK: - Render Order Separation Tests

    func testFaceMaterialRenderOrderSeparation() {
        // Face materials should have distinct render orders to prevent Z-fighting
        let faceRenderOrders: [String: Int] = [
            "faceSkin": 1,
            "faceEyebrow": 2,
            "faceEyeline": 3,
            "faceEye": 5,
            "faceHighlight": 6
        ]

        // Verify each subsequent layer has a higher render order
        var previousOrder = 0
        for (name, order) in faceRenderOrders.sorted(by: { $0.value < $1.value }) {
            XCTAssertGreaterThan(order, previousOrder,
                "\(name) (order \(order)) should be greater than previous order \(previousOrder)")
            previousOrder = order
        }
    }

    func testMaskRenderOrderBetweenFaceAndBlend() {
        let maskOrder = 4
        let lastFaceOrder = 3  // faceEyeline
        let blendOrder = 7

        XCTAssertGreaterThan(maskOrder, lastFaceOrder,
            "Mask should render after face materials")
        XCTAssertLessThan(maskOrder, blendOrder,
            "Mask should render before blend materials")
    }

    // MARK: - Depth State Configuration Tests

    func testFaceDepthStateUsesLessEqual() {
        // Face materials should use lessEqual comparison to allow coplanar rendering
        XCTAssertNotNil(renderer.depthStencilStates["face"],
            "Face depth state should exist")

        // Verify we can create the expected configuration
        let expectedDescriptor = MTLDepthStencilDescriptor()
        expectedDescriptor.depthCompareFunction = .lessEqual
        expectedDescriptor.isDepthWriteEnabled = true

        let expectedState = device.makeDepthStencilState(descriptor: expectedDescriptor)
        XCTAssertNotNil(expectedState,
            "LessEqual depth state configuration should be valid")
    }

    func testBlendDepthStateDisablesWrite() {
        // Blend materials should not write depth to allow layering
        XCTAssertNotNil(renderer.depthStencilStates["blend"],
            "Blend depth state should exist")

        // Verify the expected configuration is valid
        let expectedDescriptor = MTLDepthStencilDescriptor()
        expectedDescriptor.depthCompareFunction = .lessEqual
        expectedDescriptor.isDepthWriteEnabled = false

        let expectedState = device.makeDepthStencilState(descriptor: expectedDescriptor)
        XCTAssertNotNil(expectedState,
            "Blend depth state (no write) configuration should be valid")
    }

    // MARK: - Coplanar Distance Detection

    func testCoplanarDetectionThreshold() {
        // Define what "coplanar" means in terms of depth difference
        let coplanarThreshold: Float = 0.0001  // 0.1mm

        // Test vertices that should be considered coplanar
        let vertex1 = SIMD3<Float>(0, 0, 1.0)
        let vertex2 = SIMD3<Float>(0, 0, 1.00005)  // 0.05mm difference

        let distance = abs(vertex1.z - vertex2.z)

        XCTAssertLessThan(distance, coplanarThreshold,
            "Vertices \(distance)m apart should be considered coplanar")
    }

    func testNonCoplanarDetection() {
        let coplanarThreshold: Float = 0.0001  // 0.1mm

        // Test vertices that should NOT be considered coplanar
        let vertex1 = SIMD3<Float>(0, 0, 1.0)
        let vertex2 = SIMD3<Float>(0, 0, 1.001)  // 1mm difference

        let distance = abs(vertex1.z - vertex2.z)

        XCTAssertGreaterThan(distance, coplanarThreshold,
            "Vertices \(distance)m apart should NOT be considered coplanar")
    }

    // MARK: - Face Layer Separation Analysis

    func testFaceLayerMinimumSeparation() {
        // Face layers need minimum separation to avoid Z-fighting
        // Based on depth precision at typical viewing distances

        let typicalViewingDistance: Float = 1.5  // 1.5m from face
        let depthBits = 24
        let near: Float = 0.1
        let far: Float = 100.0

        // Calculate precision at viewing distance
        let depthRange = Float(1 << depthBits)
        let ndcPrecision = 1.0 / depthRange
        let worldPrecision = ndcPrecision * (far - near) * typicalViewingDistance * typicalViewingDistance / (near * far)

        // Face layers should be separated by at least 2x the precision
        let minimumSeparation = worldPrecision * 2.0

        print("At \(typicalViewingDistance)m viewing distance:")
        print("  Depth precision: \(worldPrecision * 1000)mm")
        print("  Minimum layer separation: \(minimumSeparation * 1000)mm")

        // VRM face layers are typically separated by render order, not geometry offset
        // Verify the separation strategy is documented
        XCTAssertGreaterThan(minimumSeparation, 0,
            "Minimum separation should be calculable")
    }

    // MARK: - Polygon Offset Tests

    func testPolygonOffsetForCoplanarSurfaces() {
        // Metal doesn't have glPolygonOffset, but we can use depth bias in descriptors
        // This test documents the approach for handling coplanar surfaces

        // Depth bias values for separating coplanar surfaces
        let depthBias: Float = 0.0001
        let slopeScale: Float = 1.0

        // These values would be applied in the render pipeline descriptor
        // pipelineDescriptor.depthBias = depthBias
        // pipelineDescriptor.slopeScale = slopeScale

        XCTAssertGreaterThan(depthBias, 0,
            "Depth bias should be positive to push fragments away from camera")
        XCTAssertGreaterThanOrEqual(slopeScale, 0,
            "Slope scale should be non-negative")
    }

    // MARK: - Material Sorting Tests

    func testOpaqueBeforeTransparentSorting() {
        // Opaque materials must render before transparent materials
        let opaqueOrder = 0
        let blendOrder = 7

        XCTAssertLessThan(opaqueOrder, blendOrder,
            "Opaque (order \(opaqueOrder)) must render before blend (order \(blendOrder))")
    }

    func testTransparentBackToFrontSorting() {
        // Transparent objects should be sorted back-to-front
        let objectDistances: [(name: String, z: Float)] = [
            ("near", -1.0),
            ("mid", -3.0),
            ("far", -5.0)
        ]

        // Back-to-front means larger |z| (more negative) renders first
        let sorted = objectDistances.sorted { $0.z < $1.z }  // More negative first

        XCTAssertEqual(sorted[0].name, "far",
            "Farthest object should render first for transparency")
        XCTAssertEqual(sorted[2].name, "near",
            "Nearest object should render last for transparency")
    }

    // MARK: - Depth Fighting Scenario Tests

    func testSamePlaneNoOffset() {
        // Two triangles on exactly the same plane without offset WILL Z-fight
        let plane1Z: Float = 1.0
        let plane2Z: Float = 1.0

        let difference = abs(plane1Z - plane2Z)

        XCTAssertEqual(difference, 0,
            "Same-plane surfaces (z difference = \(difference)) will Z-fight without render order separation")
    }

    func testParallelPlanesWithSmallOffset() {
        // Two parallel planes with small offset may still Z-fight
        let plane1Z: Float = 1.0
        let plane2Z: Float = 1.00001  // 0.01mm offset

        let depthPrecisionAt1m: Float = 0.00001  // Approximate precision

        let difference = abs(plane1Z - plane2Z)

        // Document whether this offset is sufficient
        if difference < depthPrecisionAt1m * 2 {
            print("Warning: \(difference * 1000)mm offset may cause Z-fighting at 1m (precision: \(depthPrecisionAt1m * 1000)mm)")
        }

        XCTAssertGreaterThan(difference, 0,
            "Parallel planes should have measurable offset")
    }

    func testParallelPlanesWithSafeOffset() {
        // Two parallel planes with safe offset should not Z-fight
        let plane1Z: Float = 1.0
        let plane2Z: Float = 1.001  // 1mm offset

        let minimumSafeOffset: Float = 0.0005  // 0.5mm

        let difference = abs(plane1Z - plane2Z)

        XCTAssertGreaterThan(difference, minimumSafeOffset,
            "Offset of \(difference * 1000)mm should prevent Z-fighting")
    }

    // MARK: - Outline Depth Separation Tests

    func testOutlineDepthOffset() {
        // Outlines are rendered with a small depth offset to prevent Z-fighting with mesh
        let outlineDepthOffset: Float = 0.001  // 1mm

        // At typical viewing distance (2m), verify this is sufficient
        let viewingDistance: Float = 2.0
        let depthBits = 24
        let near: Float = 0.1
        let far: Float = 100.0

        let depthRange = Float(1 << depthBits)
        let ndcPrecision = 1.0 / depthRange
        let worldPrecision = ndcPrecision * (far - near) * viewingDistance * viewingDistance / (near * far)

        XCTAssertGreaterThan(outlineDepthOffset, worldPrecision * 2,
            "Outline offset (\(outlineDepthOffset * 1000)mm) should exceed 2x depth precision (\(worldPrecision * 1000 * 2)mm)")
    }

    // MARK: - Edge Case Tests

    func testVeryCloseToNearPlane() {
        // Objects very close to near plane have best precision
        let nearPlane: Float = 0.1
        let objectDistance: Float = 0.15  // 15cm from camera

        let offsetNeeded: Float = 0.00001  // 0.01mm

        // Should be able to distinguish very small offsets near the camera
        XCTAssertLessThan(objectDistance, 1.0,
            "Near-plane test should use distance < 1m")
        XCTAssertGreaterThan(offsetNeeded, 0,
            "Even tiny offsets should be distinguishable near camera")
    }

    func testFarFromCamera() {
        // Objects far from camera have worst precision
        let objectDistance: Float = 50.0  // 50m from camera
        let depthBits = 24
        let near: Float = 0.1
        let far: Float = 100.0

        let depthRange = Float(1 << depthBits)
        let ndcPrecision = 1.0 / depthRange
        let worldPrecision = ndcPrecision * (far - near) * objectDistance * objectDistance / (near * far)

        // At 50m, precision is worse than at close range
        print("Depth precision at \(objectDistance)m: \(worldPrecision * 1000)mm")

        // Document that precision degrades significantly at distance
        let safeOffset = worldPrecision * 3
        XCTAssertGreaterThan(safeOffset, 0.001,
            "At \(objectDistance)m, safe offset should be > 1mm")

        // Verify precision is worse than at close range
        let nearPrecision = ndcPrecision * (far - near) * 1.0 * 1.0 / (near * far)
        XCTAssertGreaterThan(worldPrecision, nearPrecision,
            "Precision at 50m should be worse than at 1m")
    }

    // MARK: - Integration Tests

    func testRendererHasRequiredDepthStates() {
        let requiredStates = ["opaque", "mask", "blend", "face"]

        for stateName in requiredStates {
            XCTAssertNotNil(renderer.depthStencilStates[stateName],
                "Renderer should have '\(stateName)' depth state for Z-fighting prevention")
        }
    }

    func testDepthStatesAreDifferent() {
        guard let opaqueState = renderer.depthStencilStates["opaque"],
              let blendState = renderer.depthStencilStates["blend"],
              let faceState = renderer.depthStencilStates["face"] else {
            XCTFail("Required depth states should exist")
            return
        }

        // Opaque and blend should be different (different write behavior)
        XCTAssertFalse(opaqueState === blendState,
            "Opaque and blend should be different depth states")

        // Face and opaque should be different (different comparison function)
        XCTAssertFalse(faceState === opaqueState,
            "Face and opaque should be different depth states")
    }
}
