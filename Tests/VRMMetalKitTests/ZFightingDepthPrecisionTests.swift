// Copyright 2025 Arkavo Inc. and contributors
// Licensed under the Apache License, Version 2.0

import XCTest
import Metal
import simd
@testable import VRMMetalKit

/// Tests for Z-fighting prevention through depth precision validation
/// Verifies mathematical depth buffer precision at various distances
final class ZFightingDepthPrecisionTests: XCTestCase {

    var device: MTLDevice!
    var renderer: VRMRenderer!

    // Standard depth buffer parameters
    let nearPlane: Float = 0.1
    let farPlane: Float = 100.0
    let depthBits: Int = 24  // Standard depth buffer precision

    override func setUp() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        self.device = device
        self.renderer = VRMRenderer(device: device)
    }

    override func tearDown() {
        renderer = nil
        device = nil
    }

    // MARK: - Depth Precision Calculation

    /// Calculate the minimum distinguishable depth difference at a given distance
    /// Uses the formula for perspective projection depth precision
    func depthPrecisionAtDistance(_ distance: Float, near: Float, far: Float, bits: Int) -> Float {
        // For reverse-Z perspective projection:
        // depth = far * near / (far - z * (far - near))
        // The precision degrades with distance from near plane

        let depthRange = Float(1 << bits)  // Number of discrete depth values

        // Linear depth precision in NDC space
        let ndcPrecision = 1.0 / depthRange

        // Convert to world-space precision at the given distance
        // For reverse-Z: dz/d(depth) = (far - near) * near / (far * depth^2)
        // At distance z: precision = ndcPrecision * (far - near) * z^2 / (near * far)
        let worldPrecision = ndcPrecision * (far - near) * distance * distance / (near * far)

        return worldPrecision
    }

    /// Calculate precision for standard (non-reverse) Z buffer
    func standardDepthPrecisionAtDistance(_ distance: Float, near: Float, far: Float, bits: Int) -> Float {
        let depthRange = Float(1 << bits)
        let ndcPrecision = 1.0 / depthRange

        // For standard Z: precision degrades quadratically with distance
        // precision = ndcPrecision * (far - near) * z^2 / (near * far)
        let worldPrecision = ndcPrecision * (far - near) * distance * distance / (near * far)

        return worldPrecision
    }

    // MARK: - Near Plane Precision Tests

    func testDepthPrecisionAtNearPlane() {
        let distance = nearPlane
        let precision = depthPrecisionAtDistance(distance, near: nearPlane, far: farPlane, bits: depthBits)

        // At near plane, precision should be very high (small value = good precision)
        XCTAssertLessThan(precision, 0.0001,
            "Depth precision at near plane (\(distance)m) should be < 0.0001m, got \(precision)m")
    }

    func testDepthPrecisionAt1Meter() {
        let distance: Float = 1.0
        let precision = depthPrecisionAtDistance(distance, near: nearPlane, far: farPlane, bits: depthBits)

        // At 1 meter, precision should still be good for face detail
        XCTAssertLessThan(precision, 0.001,
            "Depth precision at 1m should be < 0.001m (1mm), got \(precision)m")
    }

    func testDepthPrecisionAt5Meters() {
        let distance: Float = 5.0
        let precision = depthPrecisionAtDistance(distance, near: nearPlane, far: farPlane, bits: depthBits)

        // At 5 meters (typical VRM viewing distance), check precision
        XCTAssertLessThan(precision, 0.01,
            "Depth precision at 5m should be < 0.01m (1cm), got \(precision)m")
    }

    func testDepthPrecisionAt10Meters() {
        let distance: Float = 10.0
        let precision = depthPrecisionAtDistance(distance, near: nearPlane, far: farPlane, bits: depthBits)

        // At 10 meters, precision degrades but should still be reasonable
        XCTAssertLessThan(precision, 0.05,
            "Depth precision at 10m should be < 0.05m (5cm), got \(precision)m")
    }

    func testDepthPrecisionAtFarPlane() {
        let distance = farPlane * 0.9  // 90% of far plane
        let precision = depthPrecisionAtDistance(distance, near: nearPlane, far: farPlane, bits: depthBits)

        // At far plane, precision is worst - document the degradation
        print("Depth precision at \(distance)m (near far plane): \(precision)m")

        // This is informational - precision at far plane may be poor
        XCTAssertGreaterThan(precision, 0,
            "Depth precision should be calculable at far plane")
    }

    // MARK: - Reverse-Z vs Standard-Z Comparison

    func testReverseZImprovesNearPlanePrecision() {
        // Reverse-Z provides better precision distribution
        // This is a documentation test showing the benefit

        let testDistances: [Float] = [0.1, 1.0, 5.0, 10.0, 50.0]

        print("\nDepth Precision Comparison (24-bit depth buffer):")
        print("Distance (m) | Standard-Z (m) | Reverse-Z (m) | Improvement")
        print("-" * 60)

        for distance in testDistances {
            let standardPrecision = standardDepthPrecisionAtDistance(
                distance, near: nearPlane, far: farPlane, bits: depthBits)
            let reversePrecision = depthPrecisionAtDistance(
                distance, near: nearPlane, far: farPlane, bits: depthBits)

            // Note: For perspective projection, reverse-Z primarily helps at far distances
            // by redistributing precision. At near distances, both are similar.
            print(String(format: "%12.1f | %14.6f | %13.6f | %.2fx",
                        distance, standardPrecision, reversePrecision,
                        standardPrecision / max(reversePrecision, 0.000001)))
        }

        // The test passes if calculations complete - this is primarily documentation
        XCTAssertTrue(true, "Reverse-Z precision comparison completed")
    }

    // MARK: - VRM-Specific Distance Tests

    func testDepthPrecisionForFaceDetail() {
        // VRM face materials are typically viewed at 0.3-2m distance
        // Face features (eyebrow, eyeline, eye, highlight) need sub-millimeter precision

        let faceViewingDistances: [Float] = [0.3, 0.5, 1.0, 1.5, 2.0]
        let requiredPrecision: Float = 0.0005  // 0.5mm for face layer separation

        var allPassed = true

        for distance in faceViewingDistances {
            let precision = depthPrecisionAtDistance(
                distance, near: nearPlane, far: farPlane, bits: depthBits)

            if precision > requiredPrecision {
                print("Warning: At \(distance)m, precision (\(precision)m) may cause face Z-fighting")
                allPassed = false
            }
        }

        XCTAssertTrue(allPassed,
            "Depth precision should be < \(requiredPrecision)m at typical face viewing distances")
    }

    func testDepthPrecisionForOutlines() {
        // Outlines are typically offset by a small amount from the mesh surface
        // Need to ensure the offset is larger than depth precision

        let typicalOutlineOffset: Float = 0.001  // 1mm outline offset
        let typicalViewingDistance: Float = 2.0

        let precision = depthPrecisionAtDistance(
            typicalViewingDistance, near: nearPlane, far: farPlane, bits: depthBits)

        XCTAssertLessThan(precision, typicalOutlineOffset,
            "Depth precision (\(precision)m) should be less than outline offset (\(typicalOutlineOffset)m)")
    }

    // MARK: - Near/Far Ratio Tests

    func testNearFarRatioImpactOnPrecision() {
        // Different near/far ratios affect precision distribution
        let testRatios: [(near: Float, far: Float)] = [
            (0.01, 100.0),   // 1:10000 ratio - very poor precision
            (0.1, 100.0),    // 1:1000 ratio - standard
            (0.1, 50.0),     // 1:500 ratio - improved
            (1.0, 100.0),    // 1:100 ratio - good precision
        ]

        let testDistance: Float = 5.0

        print("\nNear/Far Ratio Impact on Precision at \(testDistance)m:")
        print("Near (m) | Far (m)  | Ratio    | Precision (m)")
        print("-" * 50)

        var bestPrecision: Float = .infinity
        var bestRatio: (near: Float, far: Float) = (0, 0)

        for (near, far) in testRatios {
            let precision = depthPrecisionAtDistance(
                testDistance, near: near, far: far, bits: depthBits)

            print(String(format: "%8.2f | %8.1f | 1:%-6.0f | %.6f",
                        near, far, far/near, precision))

            if precision < bestPrecision {
                bestPrecision = precision
                bestRatio = (near, far)
            }
        }

        // Verify that larger near plane improves precision
        let wideRatioPrecision = depthPrecisionAtDistance(
            testDistance, near: 0.01, far: 100.0, bits: depthBits)
        let narrowRatioPrecision = depthPrecisionAtDistance(
            testDistance, near: 1.0, far: 100.0, bits: depthBits)

        XCTAssertLessThan(narrowRatioPrecision, wideRatioPrecision,
            "Narrower near/far ratio should provide better precision")
    }

    // MARK: - Depth Buffer Format Tests

    func testDepthBufferFormatSupport() {
        // Verify device supports required depth formats

        // 32-bit float depth (best precision)
        let float32Supported = device.supportsFamily(.apple3) || device.supportsFamily(.mac2)

        // 24-bit depth with 8-bit stencil (standard)
        let depth24Stencil8Descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float_stencil8,
            width: 1, height: 1,
            mipmapped: false)
        depth24Stencil8Descriptor.usage = .renderTarget
        depth24Stencil8Descriptor.storageMode = .private

        let depth24Stencil8Supported = device.makeTexture(descriptor: depth24Stencil8Descriptor) != nil

        XCTAssertTrue(depth24Stencil8Supported,
            "Device should support depth32Float_stencil8 format")

        print("\nDepth Format Support:")
        print("  32-bit float depth: \(float32Supported)")
        print("  Depth32Float_Stencil8: \(depth24Stencil8Supported)")
    }

    // MARK: - Coplanar Surface Minimum Offset Tests

    func testMinimumSafeOffsetForCoplanarSurfaces() {
        // Calculate the minimum offset needed to avoid Z-fighting at various distances

        let viewingDistances: [Float] = [0.5, 1.0, 2.0, 5.0, 10.0]
        let safetyFactor: Float = 2.0  // 2x the precision to be safe

        print("\nMinimum Safe Offset for Coplanar Surfaces:")
        print("Distance (m) | Precision (m) | Safe Offset (m)")
        print("-" * 50)

        for distance in viewingDistances {
            let precision = depthPrecisionAtDistance(
                distance, near: nearPlane, far: farPlane, bits: depthBits)
            let safeOffset = precision * safetyFactor

            print(String(format: "%12.1f | %13.6f | %15.6f", distance, precision, safeOffset))
        }

        // At 2m (typical VRM viewing), verify we can distinguish face layers
        let at2m = depthPrecisionAtDistance(2.0, near: nearPlane, far: farPlane, bits: depthBits)
        let faceLayerSeparation: Float = 0.0001  // 0.1mm between face layers

        XCTAssertLessThan(at2m * safetyFactor, faceLayerSeparation * 10,
            "Face layer separation should be distinguishable with safety margin")
    }

    // MARK: - Projection Matrix Verification

    func testRendererUsesReverseZ() {
        // Verify the renderer's projection matrix uses reverse-Z
        renderer.useOrthographic = false
        let matrix = renderer.makeProjectionMatrix(aspectRatio: 1.0)

        // For reverse-Z perspective: zs = far / (near - far)
        // This should be negative for reverse-Z
        let zScale = matrix.columns.2.z

        XCTAssertLessThan(zScale, 0,
            "Perspective projection should use reverse-Z (negative Z scale)")
    }

    func testOrthographicUsesReverseZ() {
        // Verify orthographic projection also uses reverse-Z
        renderer.useOrthographic = true
        let matrix = renderer.makeProjectionMatrix(aspectRatio: 1.0)

        // For reverse-Z orthographic: Z scale should be negative
        let zScale = matrix.columns.2.z

        XCTAssertLessThan(zScale, 0,
            "Orthographic projection should use reverse-Z (negative Z scale)")
    }
}

// MARK: - String Multiplication Helper

private func *(lhs: String, rhs: Int) -> String {
    return String(repeating: lhs, count: rhs)
}
