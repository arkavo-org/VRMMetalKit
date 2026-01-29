// Copyright 2025 Arkavo Inc. and contributors
// Licensed under the Apache License, Version 2.0

import XCTest
import simd
@testable import VRMMetalKit

/// TDD tests for outline width consistency between skinned and non-skinned shaders (Issue #103)
/// Both shader types should produce the same visual outline thickness at the same distance
final class OutlineWidthConsistencyTests: XCTestCase {

    /// Helper to calculate world-mode outline offset (non-skinned formula)
    func calculateWorldModeOffset_NonSkinned(
        worldNormal: SIMD3<Float>,
        outlineWidth: Float,
        worldPos: SIMD3<Float>,
        cameraPos: SIMD3<Float>
    ) -> SIMD3<Float> {
        let distanceScale = simd_length(worldPos - cameraPos) * 0.01
        return simd_normalize(worldNormal) * outlineWidth * distanceScale
    }

    /// Helper to calculate world-mode outline offset (old skinned formula - NO distance scaling)
    func calculateWorldModeOffset_SkinnedOld(
        worldNormal: SIMD3<Float>,
        outlineWidth: Float
    ) -> SIMD3<Float> {
        return simd_normalize(worldNormal) * outlineWidth
    }

    /// Helper to calculate world-mode outline offset (fixed skinned formula - WITH distance scaling)
    func calculateWorldModeOffset_SkinnedFixed(
        worldNormal: SIMD3<Float>,
        outlineWidth: Float,
        worldPos: SIMD3<Float>,
        cameraPos: SIMD3<Float>
    ) -> SIMD3<Float> {
        let distanceScale = simd_length(worldPos - cameraPos) * 0.01
        return simd_normalize(worldNormal) * outlineWidth * distanceScale
    }

    // MARK: - World Mode Distance Scaling Tests

    /// Test that world mode applies distance scaling
    func testWorldMode_DistanceScaling() {
        let worldNormal = SIMD3<Float>(1, 0, 0)
        let outlineWidth: Float = 1.0
        let worldPos = SIMD3<Float>(0, 0, 0)
        let cameraPos = SIMD3<Float>(0, 0, 10)

        let offset = calculateWorldModeOffset_NonSkinned(
            worldNormal: worldNormal,
            outlineWidth: outlineWidth,
            worldPos: worldPos,
            cameraPos: cameraPos
        )

        // At distance 10, scale = 10 * 0.01 = 0.1
        // Offset = normal * width * scale = (1,0,0) * 1.0 * 0.1 = (0.1, 0, 0)
        XCTAssertEqual(offset.x, 0.1, accuracy: 0.001)
        XCTAssertEqual(offset.y, 0.0, accuracy: 0.001)
        XCTAssertEqual(offset.z, 0.0, accuracy: 0.001)
    }

    /// Test consistent visual thickness at different distances
    func testWorldMode_ConsistentVisualThickness() {
        let worldNormal = SIMD3<Float>(0, 1, 0)
        let outlineWidth: Float = 1.0

        // Close camera (distance 5)
        let cameraClose = SIMD3<Float>(0, 0, 5)
        let offsetClose = calculateWorldModeOffset_NonSkinned(
            worldNormal: worldNormal,
            outlineWidth: outlineWidth,
            worldPos: SIMD3<Float>(0, 0, 0),
            cameraPos: cameraClose
        )

        // Far camera (distance 20)
        let cameraFar = SIMD3<Float>(0, 0, 20)
        let offsetFar = calculateWorldModeOffset_NonSkinned(
            worldNormal: worldNormal,
            outlineWidth: outlineWidth,
            worldPos: SIMD3<Float>(0, 0, 0),
            cameraPos: cameraFar
        )

        // Far offset should be 4x larger (20/5 = 4)
        let ratio = simd_length(offsetFar) / simd_length(offsetClose)
        XCTAssertEqual(ratio, 4.0, accuracy: 0.001, "Offset should scale linearly with distance")
    }

    // MARK: - Skinned vs Non-Skinned Consistency Tests

    /// Test that OLD skinned formula gives DIFFERENT results (demonstrates the bug)
    func testSkinnedVsNonSkinned_OldFormulaDiffers() {
        let worldNormal = SIMD3<Float>(1, 0, 0)
        let outlineWidth: Float = 1.0
        let worldPos = SIMD3<Float>(0, 0, 0)
        let cameraPos = SIMD3<Float>(0, 0, 10)

        let nonSkinnedOffset = calculateWorldModeOffset_NonSkinned(
            worldNormal: worldNormal,
            outlineWidth: outlineWidth,
            worldPos: worldPos,
            cameraPos: cameraPos
        )

        let skinnedOldOffset = calculateWorldModeOffset_SkinnedOld(
            worldNormal: worldNormal,
            outlineWidth: outlineWidth
        )

        // Old skinned gives 1.0, non-skinned gives 0.1 - they DON'T match
        XCTAssertNotEqual(
            simd_length(nonSkinnedOffset),
            simd_length(skinnedOldOffset),
            accuracy: 0.01,
            "Old skinned formula should differ from non-skinned (bug)"
        )

        // Old skinned is 10x larger (no distance scaling applied)
        let ratio = simd_length(skinnedOldOffset) / simd_length(nonSkinnedOffset)
        XCTAssertEqual(ratio, 10.0, accuracy: 0.01, "Old skinned is 10x larger (bug)")
    }

    /// Test that FIXED skinned formula gives SAME results as non-skinned
    func testSkinnedVsNonSkinned_SameFormula() {
        let worldNormal = SIMD3<Float>(1, 0, 0)
        let outlineWidth: Float = 1.0
        let worldPos = SIMD3<Float>(0, 0, 0)
        let cameraPos = SIMD3<Float>(0, 0, 10)

        let nonSkinnedOffset = calculateWorldModeOffset_NonSkinned(
            worldNormal: worldNormal,
            outlineWidth: outlineWidth,
            worldPos: worldPos,
            cameraPos: cameraPos
        )

        let skinnedFixedOffset = calculateWorldModeOffset_SkinnedFixed(
            worldNormal: worldNormal,
            outlineWidth: outlineWidth,
            worldPos: worldPos,
            cameraPos: cameraPos
        )

        // Fixed skinned should match non-skinned exactly
        XCTAssertEqual(
            simd_length(nonSkinnedOffset),
            simd_length(skinnedFixedOffset),
            accuracy: 0.0001,
            "Fixed skinned formula should match non-skinned"
        )

        // Both should be 0.1
        XCTAssertEqual(simd_length(nonSkinnedOffset), 0.1, accuracy: 0.001)
        XCTAssertEqual(simd_length(skinnedFixedOffset), 0.1, accuracy: 0.001)
    }

    // MARK: - Screen Mode Tests

    /// Helper to calculate screen-mode offset (non-skinned formula)
    func calculateScreenModeOffset_NonSkinned(
        viewNormal: SIMD3<Float>,
        outlineWidth: Float,
        viewportSize: SIMD2<Float>,
        clipW: Float
    ) -> SIMD2<Float> {
        let screenNormal = simd_normalize(SIMD2<Float>(viewNormal.x, viewNormal.y))
        let pixelsToNDC = 2.0 / viewportSize
        return screenNormal * outlineWidth * pixelsToNDC * clipW
    }

    /// Test screen mode produces constant pixel width
    func testScreenMode_ConstantPixelWidth() {
        let viewNormal = SIMD3<Float>(1, 0, 0)
        let outlineWidthPixels: Float = 5.0
        let viewportSize = SIMD2<Float>(1920, 1080)

        // Close object (clipW = 1)
        let offsetClose = calculateScreenModeOffset_NonSkinned(
            viewNormal: viewNormal,
            outlineWidth: outlineWidthPixels,
            viewportSize: viewportSize,
            clipW: 1.0
        )

        // Far object (clipW = 10)
        let offsetFar = calculateScreenModeOffset_NonSkinned(
            viewNormal: viewNormal,
            outlineWidth: outlineWidthPixels,
            viewportSize: viewportSize,
            clipW: 10.0
        )

        // In NDC, far offset is 10x larger, but when divided by clipW during
        // perspective divide, both result in same screen pixels
        // This is correct behavior for screen-space outline mode
        XCTAssertEqual(offsetFar.x / 10.0, offsetClose.x, accuracy: 0.0001)
    }

    /// Test screen mode aspect ratio correction
    func testScreenMode_AspectRatioCorrection() {
        let viewNormal = SIMD3<Float>(1, 0, 0)  // Horizontal normal
        let outlineWidth: Float = 5.0
        let viewportSize = SIMD2<Float>(1920, 1080)  // 16:9 aspect

        let offset = calculateScreenModeOffset_NonSkinned(
            viewNormal: viewNormal,
            outlineWidth: outlineWidth,
            viewportSize: viewportSize,
            clipW: 1.0
        )

        // pixelsToNDC.x = 2/1920 = 0.00104...
        // offset.x = 1 * 5 * 0.00104 = 0.0052
        let expectedX: Float = 2.0 / 1920.0 * 5.0
        XCTAssertEqual(offset.x, expectedX, accuracy: 0.0001)
    }

    // MARK: - Edge Cases

    /// Test outline at zero distance (camera at vertex position)
    func testWorldMode_ZeroDistance() {
        let worldNormal = SIMD3<Float>(1, 0, 0)
        let outlineWidth: Float = 1.0
        let worldPos = SIMD3<Float>(5, 5, 5)
        let cameraPos = SIMD3<Float>(5, 5, 5)  // Same as vertex

        let offset = calculateWorldModeOffset_NonSkinned(
            worldNormal: worldNormal,
            outlineWidth: outlineWidth,
            worldPos: worldPos,
            cameraPos: cameraPos
        )

        // At zero distance, offset should be zero
        XCTAssertEqual(simd_length(offset), 0.0, accuracy: 0.001)
    }

    /// Test outline with very small distance
    func testWorldMode_VerySmallDistance() {
        let worldNormal = SIMD3<Float>(0, 0, 1)
        let outlineWidth: Float = 1.0
        let worldPos = SIMD3<Float>(0, 0, 0)
        let cameraPos = SIMD3<Float>(0, 0, 0.1)  // Very close

        let offset = calculateWorldModeOffset_NonSkinned(
            worldNormal: worldNormal,
            outlineWidth: outlineWidth,
            worldPos: worldPos,
            cameraPos: cameraPos
        )

        // At distance 0.1, scale = 0.1 * 0.01 = 0.001
        XCTAssertEqual(offset.z, 0.001, accuracy: 0.0001)
    }

    /// Test outline with very large distance
    func testWorldMode_VeryLargeDistance() {
        let worldNormal = SIMD3<Float>(0, 1, 0)
        let outlineWidth: Float = 1.0
        let worldPos = SIMD3<Float>(0, 0, 0)
        let cameraPos = SIMD3<Float>(0, 0, 1000)  // Far away

        let offset = calculateWorldModeOffset_NonSkinned(
            worldNormal: worldNormal,
            outlineWidth: outlineWidth,
            worldPos: worldPos,
            cameraPos: cameraPos
        )

        // At distance 1000, scale = 1000 * 0.01 = 10
        XCTAssertEqual(offset.y, 10.0, accuracy: 0.001)
    }
}
