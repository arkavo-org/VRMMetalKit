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
@testable import VRMMetalKit

/// Direct unit tests for `DepthBiasCalculator` — the mutation-testing oracle suite.
///
/// These tests assert known input/output pairs on the calculator's public
/// surface so that mutation testing (issue #282) has a meaningful target.
/// `HipSkirtTests` exercises the calculator only incidentally via the
/// hip-skirt scenario; muter must not be pointed at it.
final class DepthBiasCalculatorTests: XCTestCase {

    // MARK: - Construction & constants

    func testDefaultScaleIsOne() {
        let calc = DepthBiasCalculator()
        XCTAssertEqual(calc.scale, 1.0)
    }

    func testExplicitScaleIsRetained() {
        let calc = DepthBiasCalculator(scale: 2.5)
        XCTAssertEqual(calc.scale, 2.5)
    }

    func testSlopeScaleConstant() {
        XCTAssertEqual(DepthBiasCalculator().slopeScale, 2.0)
    }

    func testClampConstant() {
        XCTAssertEqual(DepthBiasCalculator().clamp, 0.1)
    }

    // MARK: - Exact-match lookups (from baseBiasValues table)

    func testBodySkinExactMatch() {
        let calc = DepthBiasCalculator()
        XCTAssertEqual(calc.depthBias(for: "Body_SKIN", isOverlay: false), 0.005, accuracy: 1e-6)
    }

    func testFaceExactMatch() {
        let calc = DepthBiasCalculator()
        XCTAssertEqual(calc.depthBias(for: "Face", isOverlay: false), 0.01, accuracy: 1e-6)
    }

    func testEyeExactMatch() {
        let calc = DepthBiasCalculator()
        XCTAssertEqual(calc.depthBias(for: "Eye", isOverlay: false), 0.03, accuracy: 1e-6)
    }

    func testHighlightExactMatch() {
        let calc = DepthBiasCalculator()
        XCTAssertEqual(calc.depthBias(for: "Highlight", isOverlay: false), 0.04, accuracy: 1e-6)
    }

    // MARK: - Priority ordering in computeBias

    func testClothingPriorityBeatsBody() {
        // "Body_Clothing" — clothing check (Priority 1) must fire before body check (Priority 2).
        let calc = DepthBiasCalculator()
        XCTAssertEqual(calc.depthBias(for: "Body_Clothing", isOverlay: false), 0.015, accuracy: 1e-6,
                       "Material containing both 'body' and 'clothing' must hit the clothing branch first")
    }

    func testBodyPriorityBeatsFaceAndSkin() {
        // "Body_Face_Skin" — body (Priority 2) must fire before face (Priority 3) and skin (Priority 4).
        let calc = DepthBiasCalculator()
        XCTAssertEqual(calc.depthBias(for: "Body_Face_Skin", isOverlay: false), 0.005, accuracy: 1e-6)
    }

    func testEyebrowPriorityBeatsEye() {
        // "Eyebrow" contains "eye", but the eyebrow check fires first.
        let calc = DepthBiasCalculator()
        let bias = calc.depthBias(for: "left_eyebrow_inner", isOverlay: false)
        XCTAssertEqual(bias, 0.025, accuracy: 1e-6,
                       "Eyebrow-containing names must hit eyebrow (0.025), not eye (0.03)")
    }

    func testMouthPriorityFires() {
        let calc = DepthBiasCalculator()
        XCTAssertEqual(calc.depthBias(for: "mouth_inner", isOverlay: false), 0.02, accuracy: 1e-6)
    }

    // MARK: - Case-insensitive substring match

    func testLowercaseInputMatchesBody() {
        let calc = DepthBiasCalculator()
        XCTAssertEqual(calc.depthBias(for: "body_mesh", isOverlay: false), 0.005, accuracy: 1e-6)
    }

    func testUppercaseInputMatchesBody() {
        let calc = DepthBiasCalculator()
        XCTAssertEqual(calc.depthBias(for: "BODY_MESH", isOverlay: false), 0.005, accuracy: 1e-6)
    }

    func testMixedCaseInputMatchesClothing() {
        let calc = DepthBiasCalculator()
        XCTAssertEqual(calc.depthBias(for: "MyCloThInG_Material", isOverlay: false), 0.015, accuracy: 1e-6)
    }

    // MARK: - Default fallback

    func testUnknownMaterialReturnsDefault() {
        let calc = DepthBiasCalculator()
        XCTAssertEqual(calc.depthBias(for: "totally_unknown_material_xyz", isOverlay: false), 0.01, accuracy: 1e-6)
    }

    func testEmptyStringReturnsDefault() {
        let calc = DepthBiasCalculator()
        XCTAssertEqual(calc.depthBias(for: "", isOverlay: false), 0.01, accuracy: 1e-6)
    }

    // MARK: - Overlay offset

    func testOverlayAddsOffsetToBody() {
        let calc = DepthBiasCalculator()
        let base = calc.depthBias(for: "Body_SKIN", isOverlay: false)
        let overlay = calc.depthBias(for: "Body_SKIN", isOverlay: true)
        XCTAssertEqual(overlay - base, 0.01, accuracy: 1e-6,
                       "isOverlay:true must add exactly 0.01 to the base bias")
    }

    func testOverlayAddsOffsetToDefault() {
        let calc = DepthBiasCalculator()
        let base = calc.depthBias(for: "unknown_xyz", isOverlay: false)
        let overlay = calc.depthBias(for: "unknown_xyz", isOverlay: true)
        XCTAssertEqual(overlay - base, 0.01, accuracy: 1e-6)
    }

    // MARK: - Scale multiplication

    func testScaleMultipliesBase() {
        let calc = DepthBiasCalculator(scale: 3.0)
        let bias = calc.depthBias(for: "Body_SKIN", isOverlay: false)
        XCTAssertEqual(bias, 0.015, accuracy: 1e-6, "0.005 * 3.0 = 0.015")
    }

    func testScaleMultipliesOverlay() {
        let calc = DepthBiasCalculator(scale: 2.0)
        let bias = calc.depthBias(for: "Body_SKIN", isOverlay: true)
        XCTAssertEqual(bias, 0.03, accuracy: 1e-6, "(0.005 + 0.01) * 2.0 = 0.03")
    }

    func testScaleZeroProducesZero() {
        let calc = DepthBiasCalculator(scale: 0.0)
        XCTAssertEqual(calc.depthBias(for: "Highlight", isOverlay: true), 0.0, accuracy: 1e-6)
    }

    func testNegativeScaleNegates() {
        let calc = DepthBiasCalculator(scale: -1.0)
        XCTAssertEqual(calc.depthBias(for: "Body_SKIN", isOverlay: false), -0.005, accuracy: 1e-6)
    }

    // MARK: - Cache behavior (observable via repeated calls)

    func testRepeatCallsReturnSameValue() {
        let calc = DepthBiasCalculator()
        let first = calc.depthBias(for: "Skirt_v2", isOverlay: true)
        let second = calc.depthBias(for: "Skirt_v2", isOverlay: true)
        let third = calc.depthBias(for: "Skirt_v2", isOverlay: true)
        XCTAssertEqual(first, second, accuracy: 0.0,
                       "Cache hit must return bit-identical value")
        XCTAssertEqual(second, third, accuracy: 0.0)
    }

    func testCacheDoesNotConflateDistinctMaterials() {
        let calc = DepthBiasCalculator()
        let body = calc.depthBias(for: "Body_SKIN", isOverlay: false)
        let cloth = calc.depthBias(for: "Skirt", isOverlay: false)
        XCTAssertNotEqual(body, cloth,
                          "Distinct material names must produce distinct biases")
    }
}
