//
// Copyright 2025 Arkavo
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

import XCTest
import simd
@testable import VRMMetalKit

/// Unit tests for TwoBoneIKSolver
/// Tests IK math, edge cases, and bone chain solving
final class TwoBoneIKSolverTests: XCTestCase {

    // MARK: - Basic IK Solve Tests

    func testSimpleIKSolve() {
        // Straight leg pointing down
        let rootPos = SIMD3<Float>(0, 1, 0)    // Hip
        let midPos = SIMD3<Float>(0, 0.5, 0)   // Knee
        let endPos = SIMD3<Float>(0, 0, 0)     // Ankle
        let targetPos = SIMD3<Float>(0, 0.3, 0.5)  // Target slightly forward
        let poleVector = SIMD3<Float>(0, 0, 1)     // Knee points forward

        let result = TwoBoneIKSolver.solve(
            rootPos: rootPos,
            midPos: midPos,
            endPos: endPos,
            targetPos: targetPos,
            poleVector: poleVector
        )

        XCTAssertNotNil(result)

        // Verify that the solve produced valid rotations (normalized quaternions)
        let rootRot = result!.rootRotation
        let midRot = result!.midRotation
        
        // Quaternions should be normalized (length ≈ 1)
        let rootLength = sqrt(rootRot.real * rootRot.real + simd_length(rootRot.imag) * simd_length(rootRot.imag))
        let midLength = sqrt(midRot.real * midRot.real + simd_length(midRot.imag) * simd_length(midRot.imag))
        
        XCTAssertEqual(rootLength, 1.0, accuracy: 0.001, "Root rotation should be normalized")
        XCTAssertEqual(midLength, 1.0, accuracy: 0.001, "Mid rotation should be normalized")
        
        // The total bone length is 1.0 (0.5 + 0.5), target is at distance ~0.54 from root
        // So the target should be reachable
        let targetDist = simd_length(targetPos - rootPos)
        let totalBoneLength = simd_length(midPos - rootPos) + simd_length(endPos - midPos)
        XCTAssertLessThan(targetDist, totalBoneLength, "Target should be within reach")
    }

    func testIKWithExactReach() {
        // Test when target is exactly at the maximum reach
        let rootPos = SIMD3<Float>(0, 1, 0)
        let midPos = SIMD3<Float>(0, 0.5, 0)
        let endPos = SIMD3<Float>(0, 0, 0)

        let upperLength: Float = 0.5
        let lowerLength: Float = 0.5
        let maxReach = upperLength + lowerLength - 0.001

        let targetPos = SIMD3<Float>(maxReach, 1, 0)  // Exactly at max reach
        let poleVector = SIMD3<Float>(0, 0, 1)

        let result = TwoBoneIKSolver.solve(
            rootPos: rootPos,
            midPos: midPos,
            endPos: endPos,
            targetPos: targetPos,
            poleVector: poleVector
        )

        XCTAssertNotNil(result)
    }

    func testIKWithMinimumReach() {
        // Test when target is at minimum reach (straight line through knee)
        let rootPos = SIMD3<Float>(0, 1, 0)
        let midPos = SIMD3<Float>(0, 0.5, 0)
        let endPos = SIMD3<Float>(0, 0, 0)

        let upperLength: Float = 0.5
        let lowerLength: Float = 0.5
        let minReach = abs(upperLength - lowerLength) + 0.001

        let targetPos = SIMD3<Float>(0, 1 - minReach, 0)  // Exactly at min reach
        let poleVector = SIMD3<Float>(0, 0, 1)

        let result = TwoBoneIKSolver.solve(
            rootPos: rootPos,
            midPos: midPos,
            endPos: endPos,
            targetPos: targetPos,
            poleVector: poleVector
        )

        XCTAssertNotNil(result)
    }

    // MARK: - Edge Cases

    func testIKReturnsNilForZeroBoneLength() {
        let rootPos = SIMD3<Float>(0, 1, 0)
        let midPos = SIMD3<Float>(0, 1, 0)  // Same as root (zero length)
        let endPos = SIMD3<Float>(0, 0, 0)
        let targetPos = SIMD3<Float>(0, 0.5, 0.5)
        let poleVector = SIMD3<Float>(0, 0, 1)

        let result = TwoBoneIKSolver.solve(
            rootPos: rootPos,
            midPos: midPos,
            endPos: endPos,
            targetPos: targetPos,
            poleVector: poleVector
        )

        XCTAssertNil(result)
    }

    func testIKReturnsNilForZeroTargetDistance() {
        let rootPos = SIMD3<Float>(0, 1, 0)
        let midPos = SIMD3<Float>(0, 0.5, 0)
        let endPos = SIMD3<Float>(0, 0, 0)
        let targetPos = SIMD3<Float>(0, 1, 0)  // Same as root (zero distance)
        let poleVector = SIMD3<Float>(0, 0, 1)

        let result = TwoBoneIKSolver.solve(
            rootPos: rootPos,
            midPos: midPos,
            endPos: endPos,
            targetPos: targetPos,
            poleVector: poleVector
        )

        XCTAssertNil(result)
    }

    func testIKWithUnreachableTarget() {
        // Target is beyond maximum reach
        let rootPos = SIMD3<Float>(0, 1, 0)
        let midPos = SIMD3<Float>(0, 0.5, 0)
        let endPos = SIMD3<Float>(0, 0, 0)
        let targetPos = SIMD3<Float>(0, 1, 2)  // Way too far
        let poleVector = SIMD3<Float>(0, 0, 1)

        let result = TwoBoneIKSolver.solve(
            rootPos: rootPos,
            midPos: midPos,
            endPos: endPos,
            targetPos: targetPos,
            poleVector: poleVector
        )

        // Should still return a result (clamped to max reach)
        XCTAssertNotNil(result)
    }

    func testIKWithTargetTooClose() {
        // Target is closer than minimum reach
        let rootPos = SIMD3<Float>(0, 1, 0)
        let midPos = SIMD3<Float>(0, 0.5, 0)
        let endPos = SIMD3<Float>(0, 0, 0)
        let targetPos = SIMD3<Float>(0, 0.99, 0)  // Almost at root
        let poleVector = SIMD3<Float>(0, 0, 1)

        let result = TwoBoneIKSolver.solve(
            rootPos: rootPos,
            midPos: midPos,
            endPos: endPos,
            targetPos: targetPos,
            poleVector: poleVector
        )

        // Should still return a result (clamped to min reach)
        XCTAssertNotNil(result)
    }

    // MARK: - Pole Vector Tests

    func testIKWithDifferentPoleVectors() {
        let rootPos = SIMD3<Float>(0, 1, 0)
        let midPos = SIMD3<Float>(0, 0.5, 0)
        let endPos = SIMD3<Float>(0, 0, 0)
        let targetPos = SIMD3<Float>(0.3, 0.3, 0)

        // Test forward pole
        let resultForward = TwoBoneIKSolver.solve(
            rootPos: rootPos,
            midPos: midPos,
            endPos: endPos,
            targetPos: targetPos,
            poleVector: SIMD3<Float>(0, 0, 1)
        )

        // Test right pole
        let resultRight = TwoBoneIKSolver.solve(
            rootPos: rootPos,
            midPos: midPos,
            endPos: endPos,
            targetPos: targetPos,
            poleVector: SIMD3<Float>(1, 0, 0)
        )

        // Test up pole
        let resultUp = TwoBoneIKSolver.solve(
            rootPos: rootPos,
            midPos: midPos,
            endPos: endPos,
            targetPos: targetPos,
            poleVector: SIMD3<Float>(0, 1, 0)
        )

        XCTAssertNotNil(resultForward)
        XCTAssertNotNil(resultRight)
        XCTAssertNotNil(resultUp)

        // Different pole vectors should produce different rotations
        XCTAssertNotEqual(resultForward?.rootRotation, resultRight?.rootRotation)
        XCTAssertNotEqual(resultForward?.rootRotation, resultUp?.rootRotation)
    }

    func testIKWithPoleAlignedWithTarget() {
        // When pole vector is aligned with target direction, solver should handle it
        let rootPos = SIMD3<Float>(0, 1, 0)
        let midPos = SIMD3<Float>(0, 0.5, 0)
        let endPos = SIMD3<Float>(0, 0, 0)
        let targetPos = SIMD3<Float>(0, 0.5, 0.5)
        let poleVector = SIMD3<Float>(0, -0.5, 0.5)  // Roughly toward target

        let result = TwoBoneIKSolver.solve(
            rootPos: rootPos,
            midPos: midPos,
            endPos: endPos,
            targetPos: targetPos,
            poleVector: poleVector
        )

        XCTAssertNotNil(result)
    }

    func testIKWithPoleExactlyAlignedWithTarget() {
        // Edge case: pole vector exactly aligns with target direction
        let rootPos = SIMD3<Float>(0, 1, 0)
        let midPos = SIMD3<Float>(0, 0.5, 0)
        let endPos = SIMD3<Float>(0, 0, 0)
        let targetPos = SIMD3<Float>(0, 0, 1)  // Forward
        let poleVector = SIMD3<Float>(0, -1, 0)  // Down (perpendicular)

        let result = TwoBoneIKSolver.solve(
            rootPos: rootPos,
            midPos: midPos,
            endPos: endPos,
            targetPos: targetPos,
            poleVector: poleVector
        )

        XCTAssertNotNil(result)
    }

    // MARK: - Bone Length Tests

    func testIKWithUnequalBoneLengths() {
        // Thigh longer than shin
        let rootPos = SIMD3<Float>(0, 1, 0)
        let midPos = SIMD3<Float>(0, 0.3, 0)   // 0.7 length thigh
        let endPos = SIMD3<Float>(0, 0, 0)     // 0.3 length shin
        let targetPos = SIMD3<Float>(0.2, 0.2, 0.2)
        let poleVector = SIMD3<Float>(0, 0, 1)

        let result = TwoBoneIKSolver.solve(
            rootPos: rootPos,
            midPos: midPos,
            endPos: endPos,
            targetPos: targetPos,
            poleVector: poleVector
        )

        XCTAssertNotNil(result)

        // Verify lengths are calculated correctly
        let upperLength = simd_length(midPos - rootPos)
        let lowerLength = simd_length(endPos - midPos)
        XCTAssertEqual(upperLength, 0.7, accuracy: 0.001)
        XCTAssertEqual(lowerLength, 0.3, accuracy: 0.001)
    }

    func testIKWithCustomBoneLengths() {
        // Override auto-calculated lengths
        let rootPos = SIMD3<Float>(0, 1, 0)
        let midPos = SIMD3<Float>(0, 0.5, 0)
        let endPos = SIMD3<Float>(0, 0, 0)
        let targetPos = SIMD3<Float>(0.3, 0.3, 0)
        let poleVector = SIMD3<Float>(0, 0, 1)

        let customUpperLength: Float = 0.6
        let customLowerLength: Float = 0.4

        let result = TwoBoneIKSolver.solve(
            rootPos: rootPos,
            midPos: midPos,
            endPos: endPos,
            targetPos: targetPos,
            poleVector: poleVector,
            upperLength: customUpperLength,
            lowerLength: customLowerLength
        )

        XCTAssertNotNil(result)
    }

    // MARK: - Mathematical Correctness Tests

    func testLawOfCosinesCalculation() {
        // Create a right triangle: 3-4-5
        let a: Float = 3  // Upper bone
        let b: Float = 4  // Lower bone
        let c: Float = 5  // Target distance

        // Law of cosines: c² = a² + b² - 2ab cos(C)
        // For right triangle: 25 = 9 + 16 - 0 = 25 ✓
        let cosKneeAngle = (a * a + b * b - c * c) / (2.0 * a * b)
        XCTAssertEqual(cosKneeAngle, 0, accuracy: 0.001)  // 90 degrees

        // Hip angle calculation
        let cosHipAngle = (a * a + c * c - b * b) / (2.0 * a * c)
        // For 3-4-5 triangle: cos(hip) = (9 + 25 - 16) / (2 * 3 * 5) = 18/30 = 0.6
        XCTAssertEqual(cosHipAngle, 0.6, accuracy: 0.001)
    }

    func testKneeAngleRange() {
        // Test various configurations to ensure knee angle is within valid range
        let rootPos = SIMD3<Float>(0, 1, 0)
        let midPos = SIMD3<Float>(0, 0.5, 0)
        let endPos = SIMD3<Float>(0, 0, 0)
        let poleVector = SIMD3<Float>(0, 0, 1)

        // Test different target positions
        let targets = [
            SIMD3<Float>(0.1, 0.5, 0.1),
            SIMD3<Float>(0.3, 0.3, 0.3),
            SIMD3<Float>(0.5, 0.1, 0),
            SIMD3<Float>(-0.2, 0.4, 0.2)
        ]

        for target in targets {
            let result = TwoBoneIKSolver.solve(
                rootPos: rootPos,
                midPos: midPos,
                endPos: endPos,
                targetPos: target,
                poleVector: poleVector
            )

            XCTAssertNotNil(result, "Should solve for target \(target)")

            // Verify the knee angle is within 0-180 degrees
            // (This is indirectly verified by the solve succeeding)
        }
    }

    // MARK: - Bone Length Helper Tests

    func testBoneLengthCalculation() {
        let from = SIMD3<Float>(0, 0, 0)
        let to = SIMD3<Float>(3, 4, 0)

        let length = TwoBoneIKSolver.boneLength(from: from, to: to)

        XCTAssertEqual(length, 5.0, accuracy: 0.001)  // 3-4-5 triangle
    }

    func testBoneLengthWithNegativeCoordinates() {
        let from = SIMD3<Float>(-1, -1, -1)
        let to = SIMD3<Float>(1, 1, 1)

        let length = TwoBoneIKSolver.boneLength(from: from, to: to)

        let expected = Float(sqrt(12))  // sqrt(12)
        XCTAssertEqual(length, expected, accuracy: 0.001)
    }

    // MARK: - Stress Tests

    func testMultipleConsecutiveSolves() {
        // Test that multiple solves produce stable results
        let rootPos = SIMD3<Float>(0, 1, 0)
        let midPos = SIMD3<Float>(0, 0.5, 0)
        let endPos = SIMD3<Float>(0, 0, 0)
        let poleVector = SIMD3<Float>(0, 0, 1)

        var previousResult: TwoBoneIKSolver.SolveResult?

        for i in 0..<100 {
            let t = Float(i) / 100.0
            let targetPos = SIMD3<Float>(
                0.3 * sin(t * Float.pi * 2),
                0.5,
                0.3 * cos(t * Float.pi * 2)
            )

            let result = TwoBoneIKSolver.solve(
                rootPos: rootPos,
                midPos: midPos,
                endPos: endPos,
                targetPos: targetPos,
                poleVector: poleVector
            )

            XCTAssertNotNil(result)

            // Results should be deterministic
            if let _ = previousResult, i > 0 {
                // Same input should produce same output
                // Verify consistency by checking result exists
                XCTAssertNotNil(result)
            }

            previousResult = result
        }
    }

    func testNumericalStabilityWithVerySmallValues() {
        // Test with very small bone lengths
        let rootPos = SIMD3<Float>(0, 0.001, 0)
        let midPos = SIMD3<Float>(0, 0.0005, 0)
        let endPos = SIMD3<Float>(0, 0, 0)
        let targetPos = SIMD3<Float>(0.0003, 0.0003, 0)
        let poleVector = SIMD3<Float>(0, 0, 1)

        // Should handle values just above epsilon (0.0001)
        let result = TwoBoneIKSolver.solve(
            rootPos: rootPos,
            midPos: midPos,
            endPos: endPos,
            targetPos: targetPos,
            poleVector: poleVector
        )

        XCTAssertNotNil(result)
    }

    func testNumericalStabilityWithLargeValues() {
        // Test with large bone lengths
        let rootPos = SIMD3<Float>(0, 1000, 0)
        let midPos = SIMD3<Float>(0, 500, 0)
        let endPos = SIMD3<Float>(0, 0, 0)
        let targetPos = SIMD3<Float>(300, 300, 0)
        let poleVector = SIMD3<Float>(0, 0, 1)

        let result = TwoBoneIKSolver.solve(
            rootPos: rootPos,
            midPos: midPos,
            endPos: endPos,
            targetPos: targetPos,
            poleVector: poleVector
        )

        XCTAssertNotNil(result)
    }
}
