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

/// Direct unit tests for the VRMA retargeting samplers — the mutation-testing
/// oracle suite for issue #282.
///
/// The samplers return closures; each test builds a single-keyframe STEP
/// `KeyTrack`, obtains the closure, invokes it, and asserts the output.
final class RetargetingSamplersTests: XCTestCase {

    // MARK: - Track builders

    /// Single-keyframe STEP quaternion track holding `q`.
    private func quatTrack(_ q: simd_quatf) -> KeyTrack {
        KeyTrack(times: [0],
                 values: [q.imag.x, q.imag.y, q.imag.z, q.real],
                 path: "rotation",
                 interpolation: .step,
                 componentCount: 4)
    }

    /// Single-keyframe STEP vec3 track holding `v`.
    private func vec3Track(_ v: SIMD3<Float>) -> KeyTrack {
        KeyTrack(times: [0],
                 values: [v.x, v.y, v.z],
                 path: "translation",
                 interpolation: .step,
                 componentCount: 3)
    }

    /// Asserts two quaternions are equal component-wise (no ± double-cover
    /// tolerance — the retargeting formula is sign-deterministic for these
    /// inputs, and allowing ± would let a sign-flip mutant survive).
    private func assertQuat(_ a: simd_quatf, _ b: simd_quatf,
                            accuracy: Float = 1e-5,
                            _ message: String = "",
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.imag.x, b.imag.x, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(a.imag.y, b.imag.y, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(a.imag.z, b.imag.z, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(a.real,   b.real,   accuracy: accuracy, message, file: file, line: line)
    }

    private func assertVec3(_ a: SIMD3<Float>, _ b: SIMD3<Float>,
                            accuracy: Float = 1e-5,
                            _ message: String = "",
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(a.z, b.z, accuracy: accuracy, message, file: file, line: line)
    }

    private let identity = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)

    // MARK: - Rotation sampler: nil model rest (passthrough)

    func testRotationNilModelRestPassesAnimationThrough() {
        let q = simd_normalize(simd_quatf(angle: .pi / 3, axis: [0, 1, 0]))
        let sampler = makeRotationSampler(track: quatTrack(q),
                                          animationRestRotation: identity,
                                          animationRestWorldRotation: identity,
                                          modelRestRotation: nil,
                                          modelRestWorldRotation: nil)
        XCTAssertNotNil(sampler)
        assertQuat(sampler!(0), q, "nil model rest must pass the animation rotation through")
    }

    // MARK: - Rotation sampler: identity rest poses

    func testRotationIdentityRestPosesReturnNormalizedAnimation() {
        let q = simd_normalize(simd_quatf(angle: .pi / 2, axis: [1, 0, 0]))
        let sampler = makeRotationSampler(track: quatTrack(q),
                                          animationRestRotation: identity,
                                          animationRestWorldRotation: identity,
                                          modelRestRotation: identity,
                                          modelRestWorldRotation: identity)
        XCTAssertNotNil(sampler)
        assertQuat(sampler!(0), q, "identity rests must reduce to result = animation rotation")
    }

    // MARK: - Rotation sampler: W_A == W_B collapse

    func testRotationWorldRestsEqualCollapseToDeltaFormula() {
        let L_A = simd_normalize(simd_quatf(angle: .pi / 6, axis: [0, 1, 0]))
        let L_B = simd_normalize(simd_quatf(angle: .pi / 2, axis: [0, 1, 0]))
        let W   = simd_normalize(simd_quatf(angle: .pi / 4, axis: [1, 0, 0]))
        let A   = simd_normalize(simd_quatf(angle: .pi / 3, axis: [0, 0, 1]))

        let sampler = makeRotationSampler(track: quatTrack(A),
                                          animationRestRotation: L_A,
                                          animationRestWorldRotation: W,
                                          modelRestRotation: L_B,
                                          modelRestWorldRotation: W)
        XCTAssertNotNil(sampler)
        let expected = simd_normalize(L_B * simd_inverse(L_A) * A)
        assertQuat(sampler!(0), expected,
                   "W_A == W_B must collapse to result = L_B · L_A⁻¹ · A")
    }

    // MARK: - Rotation sampler: full W-term change-of-basis

    func testRotationDifferingWorldRestsApplyChangeOfBasis() {
        let L_A = simd_normalize(simd_quatf(angle: .pi / 6, axis: [0, 1, 0]))
        let L_B = simd_normalize(simd_quatf(angle: .pi / 2, axis: [0, 1, 0]))
        let W_A = simd_normalize(simd_quatf(angle: .pi / 4, axis: [1, 0, 0]))
        let W_B = simd_normalize(simd_quatf(angle: .pi / 3, axis: [0, 0, 1]))
        let A   = simd_normalize(simd_quatf(angle: .pi / 3, axis: [0, 0, 1]))

        let withChangeOfBasis = makeRotationSampler(track: quatTrack(A),
                                                    animationRestRotation: L_A,
                                                    animationRestWorldRotation: W_A,
                                                    modelRestRotation: L_B,
                                                    modelRestWorldRotation: W_B)
        let collapsed = simd_normalize(L_B * simd_inverse(L_A) * A)
        XCTAssertNotNil(withChangeOfBasis)

        let result = withChangeOfBasis!(0)
        let delta = abs(result.imag.x - collapsed.imag.x)
                  + abs(result.imag.y - collapsed.imag.y)
                  + abs(result.imag.z - collapsed.imag.z)
                  + abs(result.real   - collapsed.real)
        XCTAssertGreaterThan(delta, 1e-3,
            "Differing world rests must apply a change of basis (W terms not dead code)")
    }

    func testRotationFullWTermFormulaMatchesReference() {
        let L_A = simd_normalize(simd_quatf(angle: .pi / 6, axis: [0, 1, 0]))
        let L_B = simd_normalize(simd_quatf(angle: .pi / 2, axis: [0, 1, 0]))
        let W_A = simd_normalize(simd_quatf(angle: .pi / 4, axis: [1, 0, 0]))
        let W_B = simd_normalize(simd_quatf(angle: .pi / 3, axis: [0, 0, 1]))
        let A   = simd_normalize(simd_quatf(angle: .pi / 5, axis: [0, 1, 0]))

        let sampler = makeRotationSampler(track: quatTrack(A),
                                          animationRestRotation: L_A,
                                          animationRestWorldRotation: W_A,
                                          modelRestRotation: L_B,
                                          modelRestWorldRotation: W_B)
        XCTAssertNotNil(sampler)

        let normalized = simd_normalize(W_A * simd_inverse(L_A) * A * simd_inverse(W_A))
        let expected = simd_normalize(L_B * simd_inverse(W_B) * normalized * W_B)
        assertQuat(sampler!(0), expected,
                   "full W-term formula must match the documented two-step reference")
    }

    // MARK: - Translation sampler

    func testTranslationNilModelRestPassesThrough() {
        let v = SIMD3<Float>(3, -2, 7)
        let sampler = makeTranslationSampler(track: vec3Track(v),
                                             animationRestTranslation: SIMD3<Float>(1, 1, 1),
                                             modelRestTranslation: nil)
        XCTAssertNotNil(sampler)
        assertVec3(sampler!(0), v, "nil model rest must pass translation through")
    }

    func testTranslationAppliesAdditiveDelta() {
        let sampler = makeTranslationSampler(track: vec3Track(SIMD3<Float>(3, 0, 0)),
                                             animationRestTranslation: SIMD3<Float>(1, 0, 0),
                                             modelRestTranslation: SIMD3<Float>(0, 5, 0))
        XCTAssertNotNil(sampler)
        assertVec3(sampler!(0), SIMD3<Float>(2, 5, 0),
                   "translation must apply modelRest + (anim - animRest)")
    }

    func testTranslationZeroDeltaWhenAnimEqualsRest() {
        let sampler = makeTranslationSampler(track: vec3Track(SIMD3<Float>(4, 4, 4)),
                                             animationRestTranslation: SIMD3<Float>(4, 4, 4),
                                             modelRestTranslation: SIMD3<Float>(9, 8, 7))
        XCTAssertNotNil(sampler)
        assertVec3(sampler!(0), SIMD3<Float>(9, 8, 7),
                   "anim == animRest must yield exactly modelRest")
    }

    // MARK: - Scale sampler

    func testScaleNilModelRestPassesThrough() {
        let v = SIMD3<Float>(2, 3, 4)
        let sampler = makeScaleSampler(track: vec3Track(v),
                                       animationRestScale: SIMD3<Float>(1, 1, 1),
                                       modelRestScale: nil)
        XCTAssertNotNil(sampler)
        assertVec3(sampler!(0), v, "nil model rest must pass scale through")
    }

    func testScaleAppliesRatio() {
        let sampler = makeScaleSampler(track: vec3Track(SIMD3<Float>(4, 4, 4)),
                                       animationRestScale: SIMD3<Float>(2, 2, 2),
                                       modelRestScale: SIMD3<Float>(3, 3, 3))
        XCTAssertNotNil(sampler)
        assertVec3(sampler!(0), SIMD3<Float>(6, 6, 6),
                   "scale must apply modelRest * (animScale / animRest)")
    }

    func testScaleUnitRatioWhenAnimEqualsRest() {
        let sampler = makeScaleSampler(track: vec3Track(SIMD3<Float>(5, 5, 5)),
                                       animationRestScale: SIMD3<Float>(5, 5, 5),
                                       modelRestScale: SIMD3<Float>(2, 3, 4))
        XCTAssertNotNil(sampler)
        assertVec3(sampler!(0), SIMD3<Float>(2, 3, 4),
                   "animScale == animRest must yield exactly modelRest")
    }

    // MARK: - safeDivide

    func testSafeDivideNormal() {
        assertVec3(safeDivide(SIMD3<Float>(4, 9, 6), by: SIMD3<Float>(2, 3, 2)),
                   SIMD3<Float>(2, 3, 3))
    }

    func testSafeDivideByZeroFallsBackToOne() {
        assertVec3(safeDivide(SIMD3<Float>(4, 4, 4), by: SIMD3<Float>(0, 0, 0)),
                   SIMD3<Float>(4, 4, 4),
                   "zero denominator must fall back to dividing by 1")
    }

    func testSafeDivideBelowEpsilonFallsBackToOne() {
        assertVec3(safeDivide(SIMD3<Float>(4, 4, 4), by: SIMD3<Float>(1e-7, 1e-7, 1e-7)),
                   SIMD3<Float>(4, 4, 4),
                   "sub-epsilon denominator must fall back to dividing by 1")
    }

    func testSafeDivideNegativeDenominatorDivides() {
        assertVec3(safeDivide(SIMD3<Float>(4, 4, 4), by: SIMD3<Float>(-2, -2, -2)),
                   SIMD3<Float>(-2, -2, -2),
                   "negative denominator above epsilon must divide normally")
    }
}
