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

/// Tests for Dual Quaternion Skinning implementation
///
/// Verifies:
/// 1. Memory layout matches Metal shader expectations
/// 2. TRS-to-DQ conversion correctness
/// 3. Antipodality handling
/// 4. Point/normal transformation
/// 5. Blending behavior
final class DualQuaternionTests: XCTestCase {

    // MARK: - Memory Layout Tests (Critical for GPU compatibility)

    func testDualQuaternionMemoryLayout() {
        // Must match Metal's DualQuaternion struct exactly
        XCTAssertEqual(MemoryLayout<DualQuaternion>.size, 32,
                      "DualQuaternion must be 32 bytes (two float4)")
        XCTAssertEqual(MemoryLayout<DualQuaternion>.stride, 32,
                      "DualQuaternion stride must be 32 bytes")
        XCTAssertEqual(MemoryLayout<DualQuaternion>.alignment, 16,
                      "DualQuaternion must be 16-byte aligned for float4")
    }

    func testDualQuaternionComponentLayout() {
        var dq = DualQuaternion.identity
        withUnsafeBytes(of: &dq) { buffer in
            let floats = buffer.bindMemory(to: Float.self)

            // real quaternion: identity = (x=0, y=0, z=0, w=1)
            XCTAssertEqual(floats[0], 0.0, accuracy: 0.0001, "real.x should be 0")
            XCTAssertEqual(floats[1], 0.0, accuracy: 0.0001, "real.y should be 0")
            XCTAssertEqual(floats[2], 0.0, accuracy: 0.0001, "real.z should be 0")
            XCTAssertEqual(floats[3], 1.0, accuracy: 0.0001, "real.w should be 1")

            // dual quaternion: zero = (x=0, y=0, z=0, w=0)
            XCTAssertEqual(floats[4], 0.0, accuracy: 0.0001, "dual.x should be 0")
            XCTAssertEqual(floats[5], 0.0, accuracy: 0.0001, "dual.y should be 0")
            XCTAssertEqual(floats[6], 0.0, accuracy: 0.0001, "dual.z should be 0")
            XCTAssertEqual(floats[7], 0.0, accuracy: 0.0001, "dual.w should be 0")
        }
    }

    // MARK: - Identity Tests

    func testIdentityDualQuaternion() {
        let dq = DualQuaternion.identity

        // Real part should be identity quaternion
        XCTAssertEqual(dq.real.real, 1.0, accuracy: 0.0001)
        XCTAssertEqual(simd_length(dq.real.imag), 0.0, accuracy: 0.0001)

        // Dual part should be zero
        XCTAssertEqual(simd_length(dq.dual.vector), 0.0, accuracy: 0.0001)
    }

    func testIdentityTransformPoint() {
        let dq = DualQuaternion.identity
        let point = SIMD3<Float>(1.0, 2.0, 3.0)

        let transformed = dq.transformPoint(point)

        XCTAssertEqual(transformed.x, point.x, accuracy: 0.0001)
        XCTAssertEqual(transformed.y, point.y, accuracy: 0.0001)
        XCTAssertEqual(transformed.z, point.z, accuracy: 0.0001)
    }

    func testIdentityTransformNormal() {
        let dq = DualQuaternion.identity
        let normal = SIMD3<Float>(0.0, 1.0, 0.0)

        let transformed = dq.transformNormal(normal)

        XCTAssertEqual(transformed.x, normal.x, accuracy: 0.0001)
        XCTAssertEqual(transformed.y, normal.y, accuracy: 0.0001)
        XCTAssertEqual(transformed.z, normal.z, accuracy: 0.0001)
    }

    // MARK: - Translation Tests

    func testPureTranslation() {
        let translation = SIMD3<Float>(5.0, 10.0, 15.0)
        let dq = DualQuaternion(
            rotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
            translation: translation
        )

        // Extract translation should match input
        let extracted = dq.translation
        XCTAssertEqual(extracted.x, translation.x, accuracy: 0.0001)
        XCTAssertEqual(extracted.y, translation.y, accuracy: 0.0001)
        XCTAssertEqual(extracted.z, translation.z, accuracy: 0.0001)

        // Transform origin should give translation
        let origin = SIMD3<Float>(0, 0, 0)
        let transformed = dq.transformPoint(origin)
        XCTAssertEqual(transformed.x, translation.x, accuracy: 0.0001)
        XCTAssertEqual(transformed.y, translation.y, accuracy: 0.0001)
        XCTAssertEqual(transformed.z, translation.z, accuracy: 0.0001)
    }

    // MARK: - Rotation Tests

    func testPureRotation90DegreesAroundY() {
        let rotation = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 1, 0))
        let dq = DualQuaternion(
            rotation: rotation,
            translation: SIMD3<Float>(0, 0, 0)
        )

        // Point on X-axis should rotate to Z-axis
        let point = SIMD3<Float>(1.0, 0.0, 0.0)
        let transformed = dq.transformPoint(point)

        XCTAssertEqual(transformed.x, 0.0, accuracy: 0.0001)
        XCTAssertEqual(transformed.y, 0.0, accuracy: 0.0001)
        XCTAssertEqual(transformed.z, -1.0, accuracy: 0.0001)
    }

    func testPureRotation90DegreesAroundX() {
        let rotation = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(1, 0, 0))
        let dq = DualQuaternion(
            rotation: rotation,
            translation: SIMD3<Float>(0, 0, 0)
        )

        // Point on Y-axis should rotate to Z-axis
        let point = SIMD3<Float>(0.0, 1.0, 0.0)
        let transformed = dq.transformPoint(point)

        XCTAssertEqual(transformed.x, 0.0, accuracy: 0.0001)
        XCTAssertEqual(transformed.y, 0.0, accuracy: 0.0001)
        XCTAssertEqual(transformed.z, 1.0, accuracy: 0.0001)
    }

    // MARK: - Combined Transform Tests

    func testRotationThenTranslation() {
        let rotation = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 1, 0))
        let translation = SIMD3<Float>(10.0, 0.0, 0.0)
        let dq = DualQuaternion(rotation: rotation, translation: translation)

        // Origin should just get translation
        let origin = SIMD3<Float>(0, 0, 0)
        let transformedOrigin = dq.transformPoint(origin)
        XCTAssertEqual(transformedOrigin.x, translation.x, accuracy: 0.0001)
        XCTAssertEqual(transformedOrigin.y, translation.y, accuracy: 0.0001)
        XCTAssertEqual(transformedOrigin.z, translation.z, accuracy: 0.0001)

        // Point at (1,0,0) rotated 90° around Y becomes (0,0,-1), then translated
        let point = SIMD3<Float>(1.0, 0.0, 0.0)
        let transformed = dq.transformPoint(point)
        XCTAssertEqual(transformed.x, 10.0, accuracy: 0.0001)  // 0 + 10
        XCTAssertEqual(transformed.y, 0.0, accuracy: 0.0001)
        XCTAssertEqual(transformed.z, -1.0, accuracy: 0.0001)
    }

    // MARK: - Matrix Conversion Tests

    func testMatrixConversionIdentity() {
        let matrix = matrix_identity_float4x4
        let dq = DualQuaternion(matrix: matrix)

        // Should be identity
        XCTAssertEqual(dq.real.real, 1.0, accuracy: 0.0001)
        XCTAssertEqual(simd_length(dq.real.imag), 0.0, accuracy: 0.0001)
        XCTAssertEqual(simd_length(dq.translation), 0.0, accuracy: 0.0001)
    }

    func testMatrixConversionTranslationOnly() {
        var matrix = matrix_identity_float4x4
        matrix.columns.3 = SIMD4<Float>(5.0, 10.0, 15.0, 1.0)

        let dq = DualQuaternion(matrix: matrix)
        let translation = dq.translation

        XCTAssertEqual(translation.x, 5.0, accuracy: 0.0001)
        XCTAssertEqual(translation.y, 10.0, accuracy: 0.0001)
        XCTAssertEqual(translation.z, 15.0, accuracy: 0.0001)
    }

    func testMatrixConversionRotationOnly() {
        let rotation = simd_quatf(angle: .pi / 4, axis: normalize(SIMD3<Float>(1, 1, 1)))
        let matrix = float4x4(rotation)

        let dq = DualQuaternion(matrix: matrix)

        // Extract rotation should match original
        let extractedRot = dq.rotation
        // Compare by checking they produce same rotation
        let testPoint = SIMD3<Float>(1.0, 0.0, 0.0)
        let rotatedByOriginal = simd_act(rotation, testPoint)
        let rotatedByExtracted = simd_act(extractedRot, testPoint)

        XCTAssertEqual(rotatedByOriginal.x, rotatedByExtracted.x, accuracy: 0.001)
        XCTAssertEqual(rotatedByOriginal.y, rotatedByExtracted.y, accuracy: 0.001)
        XCTAssertEqual(rotatedByOriginal.z, rotatedByExtracted.z, accuracy: 0.001)
    }

    // MARK: - Blending Tests

    func testBlendIdentities() {
        let dqs = [DualQuaternion.identity, DualQuaternion.identity]
        let weights: [Float] = [0.5, 0.5]

        let blended = DualQuaternion.blend(dqs, weights: weights)

        // Blending identities should give identity
        XCTAssertEqual(blended.real.real, 1.0, accuracy: 0.0001)
        XCTAssertEqual(simd_length(blended.real.imag), 0.0, accuracy: 0.0001)
    }

    func testBlendTranslations() {
        let dq1 = DualQuaternion(
            rotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
            translation: SIMD3<Float>(0, 0, 0)
        )
        let dq2 = DualQuaternion(
            rotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
            translation: SIMD3<Float>(10, 0, 0)
        )

        let blended = DualQuaternion.blend([dq1, dq2], weights: [0.5, 0.5])
        let translation = blended.translation

        // Should be halfway
        XCTAssertEqual(translation.x, 5.0, accuracy: 0.01)
        XCTAssertEqual(translation.y, 0.0, accuracy: 0.01)
        XCTAssertEqual(translation.z, 0.0, accuracy: 0.01)
    }

    func testBlendRotations() {
        let rot1 = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
        let rot2 = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 1, 0))

        let dq1 = DualQuaternion(rotation: rot1, translation: .zero)
        let dq2 = DualQuaternion(rotation: rot2, translation: .zero)

        let blended = DualQuaternion.blend([dq1, dq2], weights: [0.5, 0.5])

        // Should be approximately 45 degrees
        let testPoint = SIMD3<Float>(1.0, 0.0, 0.0)
        let transformed = blended.transformPoint(testPoint)

        // At 45 degrees, x and z should be equal (within sign)
        let expectedAngle = Float.pi / 4
        let expectedX = cos(expectedAngle)
        let expectedZ = -sin(expectedAngle)

        XCTAssertEqual(transformed.x, expectedX, accuracy: 0.01)
        XCTAssertEqual(transformed.z, expectedZ, accuracy: 0.01)
    }

    func testBlendWithZeroWeight() {
        let dq1 = DualQuaternion(
            rotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
            translation: SIMD3<Float>(10, 0, 0)
        )
        let dq2 = DualQuaternion(
            rotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
            translation: SIMD3<Float>(0, 10, 0)
        )

        // Full weight on first, zero on second
        let blended = DualQuaternion.blend([dq1, dq2], weights: [1.0, 0.0])
        let translation = blended.translation

        XCTAssertEqual(translation.x, 10.0, accuracy: 0.01)
        XCTAssertEqual(translation.y, 0.0, accuracy: 0.01)
    }

    // MARK: - Antipodality Tests

    func testAntipodalQuaternionsSameRotation() {
        // q and -q represent the same rotation
        let rot = simd_quatf(angle: .pi / 3, axis: normalize(SIMD3<Float>(1, 1, 0)))
        let negRot = simd_quatf(vector: -rot.vector)

        let dq1 = DualQuaternion(rotation: rot, translation: .zero)
        let dq2 = DualQuaternion(rotation: negRot, translation: .zero)

        // Both should transform the same
        let point = SIMD3<Float>(1.0, 2.0, 3.0)
        let t1 = dq1.transformPoint(point)
        let t2 = dq2.transformPoint(point)

        XCTAssertEqual(t1.x, t2.x, accuracy: 0.001)
        XCTAssertEqual(t1.y, t2.y, accuracy: 0.001)
        XCTAssertEqual(t1.z, t2.z, accuracy: 0.001)
    }

    func testBlendingHandlesAntipodality() {
        // Create two quaternions that are antipodal (q and -q)
        let rot = simd_quatf(angle: .pi / 4, axis: SIMD3<Float>(0, 1, 0))
        let antiRot = simd_quatf(vector: -rot.vector)

        let dq1 = DualQuaternion(rotation: rot, translation: .zero)
        let dq2 = DualQuaternion(rotation: antiRot, translation: .zero)

        // Blending should handle antipodality correctly (not average to zero)
        let blended = DualQuaternion.blend([dq1, dq2], weights: [0.5, 0.5])

        // The blended quaternion should still represent the same rotation
        let point = SIMD3<Float>(1.0, 0.0, 0.0)
        let expected = dq1.transformPoint(point)
        let actual = blended.transformPoint(point)

        XCTAssertEqual(actual.x, expected.x, accuracy: 0.01)
        XCTAssertEqual(actual.y, expected.y, accuracy: 0.01)
        XCTAssertEqual(actual.z, expected.z, accuracy: 0.01)
    }

    // MARK: - Normalization Tests

    func testNormalizedDualQuaternion() {
        let dq = DualQuaternion(
            rotation: simd_quatf(angle: .pi / 3, axis: SIMD3<Float>(1, 0, 0)),
            translation: SIMD3<Float>(5, 10, 15)
        )

        let normalized = dq.normalized()

        // Real part should be unit length
        XCTAssertEqual(simd_length(normalized.real.vector), 1.0, accuracy: 0.0001)
    }

    // MARK: - Edge Cases

    func testEmptyBlend() {
        let blended = DualQuaternion.blend([], weights: [])
        // Should return identity for empty input
        XCTAssertEqual(blended.real.real, 1.0, accuracy: 0.0001)
    }

    func testSingleElementBlend() {
        let dq = DualQuaternion(
            rotation: simd_quatf(angle: .pi / 4, axis: SIMD3<Float>(0, 0, 1)),
            translation: SIMD3<Float>(1, 2, 3)
        )

        let blended = DualQuaternion.blend([dq], weights: [1.0])

        // Should be equal to original
        let point = SIMD3<Float>(1.0, 0.0, 0.0)
        let expected = dq.transformPoint(point)
        let actual = blended.transformPoint(point)

        XCTAssertEqual(actual.x, expected.x, accuracy: 0.001)
        XCTAssertEqual(actual.y, expected.y, accuracy: 0.001)
        XCTAssertEqual(actual.z, expected.z, accuracy: 0.001)
    }
}
