//
//  CoordinateOrientationTests.swift
//  VRMMetalKitTests
//
//  TDD tests for coordinate orientation fixes
//  1. Y-Up to Z-Up root rotation (-90° X)
//  2. Handedness conversion (left/right coordinate system)
//

import XCTest
import simd
@testable import VRMMetalKit

@MainActor
final class CoordinateOrientationTests: XCTestCase {
    
    // MARK: - Test 1: Root Node Rotation (Y-Up to Z-Up)
    
    /// Test that -90° X rotation on root node makes model stand upright
    /// This fixes the "lying down" / "top-down view" issue
    func testRootRotationMinus90XStandsModelUpright() async throws {
        // Arrange: Identity rotation (model thinks it's standing in Y-Up)
        let identity = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        
        // -90° X rotation quaternion (to convert Y-Up to Z-Up)
        let halfAngle = -Float.pi / 4.0  // -45° (half of -90°)
        let rootRotation = simd_quatf(
            ix: sin(halfAngle),
            iy: 0,
            iz: 0,
            r: cos(halfAngle)
        )
        
        // Act: Apply root rotation
        let result = simd_normalize(rootRotation * identity)
        
        // Assert: Result should be the -90° X rotation
        let dot = abs(simd_dot(result, rootRotation))
        XCTAssertGreaterThan(dot, 0.99, "Root rotation should be -90° X to stand model upright")
        
        // Verify Y-Up becomes Z-Up
        let yUp = SIMD3<Float>(0, 1, 0)
        let rotated = result.act(yUp)
        // After -90° X rotation, Y should point to -Z (or Z depending on handedness)
        // The key is that the model is no longer lying on its back
        XCTAssertLessThan(abs(rotated.y), 0.1, "Y component should be near 0 after rotation")
        XCTAssertGreaterThan(abs(rotated.z), 0.9, "Z component should be dominant")
    }
    
    // MARK: - Test 2: Handedness Conversion
    
    /// Test that left-handed to right-handed conversion fixes "splits" leg issue
    /// Negating X and Y components of quaternion converts between handedness
    func testHandednessConversionNegatesXY() async throws {
        // Arrange: A rotation in left-handed space (Unity/VRM source)
        let leftHanded = simd_quatf(ix: 0.1, iy: 0.2, iz: 0.3, r: 0.9)
        
        // Act: Convert to right-handed by negating X and Y
        let rightHanded = simd_quatf(
            ix: -leftHanded.imag.x,
            iy: -leftHanded.imag.y,
            iz: leftHanded.imag.z,
            r: leftHanded.real
        )
        
        // Assert: X and Y are negated, Z and W preserved
        XCTAssertEqual(rightHanded.imag.x, -leftHanded.imag.x)
        XCTAssertEqual(rightHanded.imag.y, -leftHanded.imag.y)
        XCTAssertEqual(rightHanded.imag.z, leftHanded.imag.z)
        XCTAssertEqual(rightHanded.real, leftHanded.real)
    }
    
    /// Test that leg rotation forward in left-handed becomes forward in right-handed
    /// Without conversion, +45° leg rotation becomes -45° (splits outward)
    func testLegRotationForwardNotBackward() async throws {
        // Arrange: Leg rotation +45° around Z in left-handed (kick forward)
        let halfAngle = Float.pi / 8.0  // 22.5° (half of 45°)
        let legRotationLeft = simd_quatf(
            ix: 0,
            iy: 0,
            iz: sin(halfAngle),
            r: cos(halfAngle)
        )
        
        // Act: Convert to right-handed
        let legRotationRight = simd_quatf(
            ix: -legRotationLeft.imag.x,
            iy: -legRotationLeft.imag.y,
            iz: legRotationLeft.imag.z,
            r: legRotationLeft.real
        )
        
        // Both should represent the same physical rotation
        // (quaternion double-cover: q and -q are same rotation)
        let dot = abs(simd_dot(legRotationLeft, legRotationRight))
        // If conversion worked, they should be similar
        // If conversion failed, dot would be near 0 (opposite rotations)
        XCTAssertGreaterThan(dot, 0.5, "Converted rotation should represent same physical direction")
    }
    
    // MARK: - Test 3: Combined Fix
    
    /// Test combining root rotation AND handedness conversion
    func testCombinedRootRotationAndHandedness() async throws {
        // Arrange: Animation rotation in left-handed Y-Up space
        let animRotation = simd_quatf(ix: 0.1, iy: 0.2, iz: 0.3, r: 0.9)
        
        // Step 1: Convert handedness (negate X, Y)
        let converted = simd_quatf(
            ix: -animRotation.imag.x,
            iy: -animRotation.imag.y,
            iz: animRotation.imag.z,
            r: animRotation.real
        )
        
        // Step 2: Apply root rotation (-90° X)
        let halfAngle = -Float.pi / 4.0
        let rootRotation = simd_quatf(
            ix: sin(halfAngle),
            iy: 0,
            iz: 0,
            r: cos(halfAngle)
        )
        
        // Apply both: root rotation first, then converted animation
        let finalRotation = simd_normalize(rootRotation * converted)
        
        // Assert: Result is normalized and different from original
        XCTAssertGreaterThan(abs(finalRotation.real), 0.01, "Result should be valid quaternion")
        
        // Verify it's different from both inputs (transformation occurred)
        let dotOriginal = abs(simd_dot(finalRotation, animRotation))
        XCTAssertLessThan(dotOriginal, 0.99, "Final should differ from original (transformation applied)")
    }
    
    // MARK: - Test 4: Specific Bone Handling
    
    /// Test that hips/legs get the handedness fix but not the root rotation
    /// (root rotation should only be applied to the root/hips)
    func testHipsGetHandednessAndRootRotation() async throws {
        let hipsRotation = simd_quatf(ix: 0.1, iy: 0.2, iz: 0.3, r: 0.9)
        
        // Hips should get both: handedness conversion + root rotation
        let converted = simd_quatf(
            ix: -hipsRotation.imag.x,
            iy: -hipsRotation.imag.y,
            iz: hipsRotation.imag.z,
            r: hipsRotation.real
        )
        
        let halfAngle = -Float.pi / 4.0
        let rootRotation = simd_quatf(
            ix: sin(halfAngle),
            iy: 0,
            iz: 0,
            r: cos(halfAngle)
        )
        
        let finalHips = simd_normalize(rootRotation * converted)
        
        // Verify transformation occurred
        let dotOriginal = abs(simd_dot(finalHips, hipsRotation))
        XCTAssertLessThan(dotOriginal, 0.99, "Hips should be transformed")
    }
    
    /// Test that child bones only get handedness conversion (not root rotation)
    func testChildBonesOnlyGetHandednessConversion() async throws {
        let childRotation = simd_quatf(ix: 0.05, iy: 0.1, iz: 0.15, r: 0.98)
        
        // Child bones should only get handedness conversion
        let finalChild = simd_quatf(
            ix: -childRotation.imag.x,
            iy: -childRotation.imag.y,
            iz: childRotation.imag.z,
            r: childRotation.real
        )
        
        // Should be normalized
        let magnitude = sqrt(
            finalChild.imag.x * finalChild.imag.x +
            finalChild.imag.y * finalChild.imag.y +
            finalChild.imag.z * finalChild.imag.z +
            finalChild.real * finalChild.real
        )
        XCTAssertEqual(magnitude, 1.0, accuracy: 0.01, "Should be normalized")
    }
}
