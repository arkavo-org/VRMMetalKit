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

    // MARK: - Survivor-driven additions
    //
    // Each test below uses a multi-keyword input that exposes the priority chain.
    // Single-keyword inputs are caught by the safety-net partial-match scan in
    // computeBias() and cannot kill the explicit if-chain's logical-connector
    // mutants.

    func testClothBodyReturnsClothing() {
        // Kills ChangeLogicalConnector at line 165 col 41 (cloth || clothing → &&).
        // Original: clothing chain catches "cloth" → 0.015.
        // Mutated: "cloth_body".contains("cloth")=true && contains("clothing")=false
        //   → false → falls through to body check → 0.005.
        let calc = DepthBiasCalculator()
        XCTAssertEqual(calc.depthBias(for: "cloth_body", isOverlay: false), 0.015, accuracy: 1e-6,
                       "Multi-keyword 'cloth_body' must hit clothing branch (Priority 1) before body (Priority 2)")
    }

    func testSkirtBodyReturnsClothing() {
        // Kills ChangeLogicalConnector at line 165 col 76 (clothing || skirt → &&)
        // AND line 166 col 41 (skirt || bottoms → &&).
        // Original: "skirt_body" → 0.015 (clothing chain catches "skirt").
        // Mutated: chain fails → falls through → body → 0.005.
        let calc = DepthBiasCalculator()
        XCTAssertEqual(calc.depthBias(for: "skirt_body", isOverlay: false), 0.015, accuracy: 1e-6,
                       "Multi-keyword 'skirt_body' must hit clothing branch")
    }

    func testBottomsBodyReturnsClothing() {
        // Kills ChangeLogicalConnector at line 166 col 75 (bottoms || pants → &&).
        // Original: "bottoms_body" → 0.015.
        // Mutated: chain fails → body → 0.005.
        let calc = DepthBiasCalculator()
        XCTAssertEqual(calc.depthBias(for: "bottoms_body", isOverlay: false), 0.015, accuracy: 1e-6,
                       "Multi-keyword 'bottoms_body' must hit clothing branch")
    }

    func testMouthEyeReturnsMouth() {
        // Kills ChangeLogicalConnector at line 178 col 41 (mouth || lip → &&).
        // Original: "mouth_eye" → 0.02 (mouth branch catches before eye).
        // Mutated: mouth check fails → eyebrow no → eye yes → 0.03.
        let calc = DepthBiasCalculator()
        XCTAssertEqual(calc.depthBias(for: "mouth_eye", isOverlay: false), 0.02, accuracy: 1e-6,
                       "Multi-keyword 'mouth_eye' must hit mouth branch before eye")
    }

    func testBrowEyeReturnsEyebrow() {
        // Kills ChangeLogicalConnector at line 181 col 43 (eyebrow || brow → &&).
        // Original: "brow_eye" → 0.025 (eyebrow check catches via "brow").
        // Mutated: needs both "eyebrow" AND "brow" → "brow_eye" lacks "eyebrow"
        //   → falls through → eye → 0.03.
        let calc = DepthBiasCalculator()
        XCTAssertEqual(calc.depthBias(for: "brow_eye", isOverlay: false), 0.025, accuracy: 1e-6,
                       "Multi-keyword 'brow_eye' must hit eyebrow branch before eye")
    }

    func testOverlayOffsetIsPositiveNotZero() {
        // Pins the SwapTernary mutant: isOverlay:true must ADD overlayBiasOffset,
        // not substitute 0.0. Verifies the absolute value, not just the delta.
        let calc = DepthBiasCalculator()
        let base = calc.depthBias(for: "unknown_xyz", isOverlay: false)
        let overlay = calc.depthBias(for: "unknown_xyz", isOverlay: true)
        XCTAssertGreaterThan(overlay, base,
            "overlay bias must be strictly greater than base bias for the same material")
        XCTAssertEqual(overlay, 0.02, accuracy: 1e-6,
            "default(0.01) + overlayOffset(0.01) must equal 0.02")
    }

    func testNonOverlayDoesNotApplyOffset() {
        // Complementary pin: isOverlay:false must NOT add the overlay offset.
        let calc = DepthBiasCalculator()
        XCTAssertEqual(calc.depthBias(for: "unknown_xyz", isOverlay: false), 0.01, accuracy: 1e-6,
            "Non-overlay unknown material must return exactly the default bias (0.01), not 0.01 + overlayOffset")
    }
}
