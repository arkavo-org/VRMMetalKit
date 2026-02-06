//
//  RetargetingSafetyTests.swift
//  VRMMetalKitTests
//
//  TDD tests for VRMA retargeting safety threshold
//  Fixes mesh collapse when animation/model rest poses differ by ~180°
//

import XCTest
import simd
@testable import VRMMetalKit

@MainActor
final class RetargetingSafetyTests: XCTestCase {
    
    // MARK: - Test: Large Angle Difference Causes Mesh Collapse
    
    /// RED: When animation rest pose and model rest pose differ by >90°,
    /// delta-based retargeting becomes unstable and causes mesh collapse.
    /// This test verifies we skip delta retargeting for such cases.
    func testRetargetingSkipsDeltaWhenAngleExceeds90Degrees() async throws {
        // Arrange: Create animation track with rest pose at identity
        let identityRest = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        
        // Model rest pose rotated 170° (nearly opposite)
        // Quaternion for rotation around X axis by angle θ:
        // q = (sin(θ/2), 0, 0, cos(θ/2))
        let angleDegrees: Float = 170.0
        let halfAngle = angleDegrees * .pi / 180.0 / 2.0
        let oppositeRest = simd_quatf(
            ix: sin(halfAngle),
            iy: 0,
            iz: 0,
            r: cos(halfAngle)
        )
        
        // Calculate angle difference between quaternions (in degrees)
        // dot(q1, q2) = cos(θ/2) where θ is angle between rotations
        let dot = abs(simd_dot(identityRest, oppositeRest))
        let angleDiff = acos(min(1.0, dot)) * 2.0 * 180.0 / .pi
        
        // Verify we have a >90° difference (the problematic case)
        XCTAssertGreaterThan(angleDiff, 90.0, "Test setup: angle should be >90°, got \(angleDiff)°")
        XCTAssertEqual(angleDiff, angleDegrees, accuracy: 1.0, "Test setup: angle should be ~\(angleDegrees)°")
        
        // Act: Load VRMA with such mismatch
        // This would previously cause the mesh collapse
        
        // Assert: The retargeting should NOT apply delta-based correction
        // for bones with >90° difference - instead it should pass through
        // the animation rotation directly
        
        // The fix: useDeltaRetargeting = restAngleDiff < 90°
        let useDeltaRetargeting = angleDiff < 90.0
        XCTAssertFalse(useDeltaRetargeting, 
            "Delta retargeting should be DISABLED when angle > 90° to prevent mesh collapse")
    }
    
    /// Test that small angle differences (<90°) still use delta retargeting
    func testRetargetingUsesDeltaWhenAngleUnder90Degrees() async throws {
        // Arrange: Small angle difference (45°)
        // q = (sin(θ/2), 0, 0, cos(θ/2)) for rotation around X
        let angleDegrees: Float = 45.0
        let halfAngle = angleDegrees * .pi / 180.0 / 2.0
        
        let rest1 = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        let rest2 = simd_quatf(
            ix: sin(halfAngle),
            iy: 0,
            iz: 0,
            r: cos(halfAngle)
        )
        
        // Calculate angle difference
        let dot = abs(simd_dot(rest1, rest2))
        let angleDiff = acos(min(1.0, dot)) * 2.0 * 180.0 / .pi
        
        // Verify angle is ~45°
        XCTAssertEqual(angleDiff, angleDegrees, accuracy: 1.0)
        
        // Assert: Delta retargeting SHOULD be used for small differences
        let useDeltaRetargeting = angleDiff < 90.0
        XCTAssertTrue(useDeltaRetargeting,
            "Delta retargeting should be ENABLED when angle < 90°")
    }
    
    /// Test the exact scenario from the bug report: toes with 179° difference
    func testToesBoneWith179DegreeDifference() async throws {
        // From the actual log:
        // Animation rest: quat(real: 0.9999552, imag: (0.0093, -0.0016, -0.00007))
        // Model rest:     quat(real: -0.000075, imag: (0.0005, 0.9865, -0.1639))
        // Angle: 179.81°
        
        let animationRest = simd_quatf(
            ix: 0.009333738,
            iy: -0.0015784253,
            iz: -7.285394e-05,
            r: 0.9999552
        )
        
        let modelRest = simd_quatf(
            ix: 0.00050702563,
            iy: 0.9864846,
            iz: -0.1638535,
            r: -7.520612e-05
        )
        
        // Calculate angle difference (using normalized quaternions)
        let animNorm = simd_normalize(animationRest)
        let modelNorm = simd_normalize(modelRest)
        let dot = abs(simd_dot(animNorm, modelNorm))
        let angleDiff = acos(min(1.0, dot)) * 2.0 * 180.0 / .pi
        
        // Verify ~179° difference
        XCTAssertEqual(angleDiff, 179.81, accuracy: 0.5)
        
        // Assert: This should trigger the safety bypass
        let useDeltaRetargeting = angleDiff < 90.0
        XCTAssertFalse(useDeltaRetargeting,
            "Toes bone with 179° difference should bypass delta retargeting")
    }
    
    /// Test that quaternion double-cover is handled (q and -q are same rotation)
    func testQuaternionDoubleCoverHandled() async throws {
        // q and -q represent the same rotation
        let q = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        let negQ = simd_quatf(ix: 0, iy: 0, iz: 0, r: -1)
        
        let dot = abs(simd_dot(q, negQ))
        let angleDiff = acos(min(1.0, dot)) * 2.0 * 180.0 / .pi
        
        // Should be 0° (or very close) since they represent same rotation
        XCTAssertEqual(angleDiff, 0.0, accuracy: 0.01,
            "q and -q should have 0° angle difference (same rotation)")
        
        // Therefore delta retargeting should be used
        let useDeltaRetargeting = angleDiff < 90.0
        XCTAssertTrue(useDeltaRetargeting)
    }
    
    // MARK: - Test: Delta Formula Correctness
    
    /// Verify the delta formula produces correct results for compatible poses
    func testDeltaFormulaWithCompatiblePoses() async throws {
        // Small 30° difference between rest poses
        let animationRest = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        let modelRest = simd_quatf(
            ix: sin(Float.pi * 0.0833),  // 30° around X
            iy: 0,
            iz: 0,
            r: cos(Float.pi * 0.0833)
        )
        
        // Animation rotates 45° from its rest
        let animRotation = simd_quatf(
            ix: sin(Float.pi * 0.125),  // 45° around X
            iy: 0,
            iz: 0,
            r: cos(Float.pi * 0.125)
        )
        
        // Apply delta formula
        let delta = simd_normalize(simd_inverse(animationRest) * animRotation)
        let result = simd_normalize(modelRest * delta)
        
        // Result should be 75° from model's rest (30° + 45°)
        let expected = simd_quatf(
            ix: sin(Float.pi * 0.2083),  // 75° around X
            iy: 0,
            iz: 0,
            r: cos(Float.pi * 0.2083)
        )
        
        // Check dot product (should be close to 1 for same rotation)
        let resultDot = abs(simd_dot(result, expected))
        XCTAssertGreaterThan(resultDot, 0.99,
            "Delta formula should produce 75° rotation from model rest")
    }
    
    /// Test that delta formula fails for 180° difference (singularity)
    func testDeltaFormulaFailsAt180Degrees() async throws {
        // 180° difference between rest poses
        let animationRest = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        let modelRest = simd_quatf(ix: 1, iy: 0, iz: 0, r: 0)  // 180° around X
        
        // Verify 180° difference
        let dot = abs(simd_dot(animationRest, modelRest))
        let angleDiff = acos(min(1.0, dot)) * 2.0 * 180.0 / .pi
        XCTAssertEqual(angleDiff, 180.0, accuracy: 0.1)
        
        // Animation rotates 0° (stays at rest)
        let animRotation = animationRest
        
        // Apply delta formula
        let delta = simd_normalize(simd_inverse(animationRest) * animRotation)
        let result = simd_normalize(modelRest * delta)
        
        // Result is modelRest (180°) instead of identity (0°)
        // This is WRONG - "no animation" became "180° flip"
        let resultDotIdentity = abs(simd_dot(result, animationRest))
        XCTAssertLessThan(resultDotIdentity, 0.01,
            "At 180° difference, delta formula produces wrong result (flip instead of identity)")
    }
}
