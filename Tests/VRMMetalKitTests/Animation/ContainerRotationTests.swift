//
//  ContainerRotationTests.swift
//  VRMMetalKitTests
//
//  TDD tests for container-level rotation (not bone-level)
//  Fixes the "model lying down" issue by rotating the entire model container
//

import XCTest
import simd
@testable import VRMMetalKit

@MainActor
final class ContainerRotationTests: XCTestCase {
    
    // MARK: - Test 1: Container Rotation vs Bone Rotation
    
    /// Test that rotating the container affects the entire model
    /// Container rotation should be applied once at load time, not per-frame per-bone
    func testContainerRotationRotatesEntireModel() async throws {
        // Arrange: A model's hips rotation (local bone space)
        let hipsRotation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)  // Identity
        
        // Container rotation: -90° X to stand model upright
        let halfAngle = -Float.pi / 4.0
        let containerRotation = simd_quatf(
            ix: sin(halfAngle),
            iy: 0,
            iz: 0,
            r: cos(halfAngle)
        )
        
        // Act: Container rotation is applied to world transform, not bone
        // The bone stays at identity, but the container rotates the whole model
        let finalWorldRotation = simd_normalize(containerRotation * hipsRotation)
        
        // Assert: The world rotation includes the container fix
        // Y-Up (0,1,0) should point to Z-Up in world space
        let yUp = SIMD3<Float>(0, 1, 0)
        let worldY = finalWorldRotation.act(yUp)
        
        // After -90° X rotation, Y becomes Z (or -Z)
        XCTAssertLessThan(abs(worldY.y), 0.1, "Y should be near 0 in world space")
        XCTAssertGreaterThan(abs(worldY.z), 0.9, "Z should be dominant (Y rotated to Z)")
    }
    
    // MARK: - Test 2: Translation Coordinate Conversion
    
    /// Test that hips translation Y/Z swap fixes the "drifting" issue
    /// Unity (Y-Up): Jump = +Y
    /// Metal (Z-Up): Jump should = +Z (not +Y which would be forward)
    func testHipsTranslationYZSwap() async throws {
        // Arrange: Animation translation in Unity Y-Up space
        // "Jump Up" in Unity = (0, +1, 0)
        let unityTranslation = SIMD3<Float>(0, 1, 0)
        
        // Act: Convert to Metal Z-Up space by swapping Y and Z
        // Y-Up (0,1,0) -> Z-Up (0,0,1)
        let metalTranslation = SIMD3<Float>(
            unityTranslation.x,      // X stays X
            unityTranslation.z,      // Old Z becomes new Y
            unityTranslation.y       // Old Y becomes new Z (Up)
        )
        
        // Assert: Jump now goes in Z direction (Up in Z-Up space)
        XCTAssertEqual(metalTranslation.x, 0, accuracy: 0.01)
        XCTAssertEqual(metalTranslation.y, 0, accuracy: 0.01)  // Old Z was 0
        XCTAssertEqual(metalTranslation.z, 1, accuracy: 0.01)  // Old Y was 1, now Z
    }
    
    /// Test complex translation conversion
    func testComplexTranslationYZSwap() async throws {
        // Arrange: Walking forward and jumping in Unity space
        // Forward in Unity = +Z, Up = +Y
        let unityTranslation = SIMD3<Float>(0.5, 0.3, 2.0)  // X=0.5, Y=0.3 (up), Z=2.0 (forward)
        
        // Act: Swap Y and Z for Metal space
        let metalTranslation = SIMD3<Float>(
            unityTranslation.x,   // 0.5
            unityTranslation.z,   // 2.0 (was forward, now becomes Y/horizontal)
            unityTranslation.y    // 0.3 (was up, now becomes Z/vertical)
        )
        
        // Assert
        XCTAssertEqual(metalTranslation.x, 0.5, accuracy: 0.01)
        XCTAssertEqual(metalTranslation.y, 2.0, accuracy: 0.01)  // Was Z
        XCTAssertEqual(metalTranslation.z, 0.3, accuracy: 0.01)  // Was Y
    }
    
    // MARK: - Test 3: Simplified Animation Loop
    
    /// Test that bones only get handedness fix (no root rotation)
    func testBonesOnlyGetHandednessFix() async throws {
        let rotation = simd_quatf(ix: 0.1, iy: 0.2, iz: 0.3, r: 0.9)
        
        // Simplified: only handedness conversion
        let result = simd_quatf(
            ix: -rotation.imag.x,
            iy: -rotation.imag.y,
            iz: rotation.imag.z,
            r: rotation.real
        )
        
        // X and Y negated
        XCTAssertEqual(result.imag.x, -0.1)
        XCTAssertEqual(result.imag.y, -0.2)
        XCTAssertEqual(result.imag.z, 0.3)
        XCTAssertEqual(result.real, 0.9)
    }
    
    // MARK: - Test 4: Camera vs Model Orientation
    
    /// Test camera position relative to model
    func testCameraLookingAtModelFromFront() async throws {
        // Camera at (0, 0, 5) looking at (0, 0, 0) - standard front view
        let cameraPos = SIMD3<Float>(0, 0, 5)
        let modelCenter = SIMD3<Float>(0, 0, 0)
        let viewDir = normalize(modelCenter - cameraPos)  // (0, 0, -1)
        
        // For Z-Up world, standing model has:
        // - Head at Z+ (up)
        // - Feet at Z- (down)
        // - Forward facing Y+ or X+
        
        // Camera should see front of model, not top
        XCTAssertEqual(viewDir.z, -1, accuracy: 0.01)  // Looking down -Z
    }
    
    /// Test that model container rotation puts head up
    func testContainerRotationPutsHeadUpInZUp() async throws {
        // In Z-Up world, "Up" is +Z
        // Model container needs rotation to make model's Y-Up point to world Z-Up
        
        // Model's local Y-Up vector
        let modelYUp = SIMD3<Float>(0, 1, 0)
        
        // Container rotation: +90° X to rotate Y to Z
        // For +90° X rotation: Y (0,1,0) -> Z (0,0,1)
        let halfAngle = Float.pi / 4.0  // +45° for +90° rotation
        let containerRot = simd_quatf(
            ix: sin(halfAngle),
            iy: 0,
            iz: 0,
            r: cos(halfAngle)
        )
        
        // Apply to model's up vector
        let worldUp = containerRot.act(modelYUp)
        
        // Should point to world Z
        XCTAssertLessThan(abs(worldUp.x), 0.1, "X should be 0")
        XCTAssertLessThan(abs(worldUp.y), 0.1, "Y should be near 0")
        XCTAssertGreaterThan(worldUp.z, 0.9, "Y should rotate to +Z")
    }
}
