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

/// Tests for VRMC_vrm-1.0 §expressions: isBinary quantization and override semantics.
///
/// These tests exercise the VRMExpressionController directly — no GPU required.
/// Each expression is given a morph target bind on mesh 0, morph index 0 with bind.weight=1.0
/// so that the effective expression weight maps directly to the output morph weight.
final class VRMExpressionOverrideTests: XCTestCase {

    // MARK: - Helpers

    /// Creates an expression with a single morph bind (mesh 0, morph 0, bind weight 1.0).
    private func makeExpr(
        preset: VRMExpressionPreset? = nil,
        name: String? = nil,
        isBinary: Bool = false,
        overrideBlink: VRMExpressionOverrideType = .none,
        overrideLookAt: VRMExpressionOverrideType = .none,
        overrideMouth: VRMExpressionOverrideType = .none
    ) -> VRMExpression {
        var expr = VRMExpression(name: name, preset: preset)
        expr.isBinary = isBinary
        expr.overrideBlink = overrideBlink
        expr.overrideLookAt = overrideLookAt
        expr.overrideMouth = overrideMouth
        expr.morphTargetBinds = [VRMMorphTargetBind(node: 0, index: 0, weight: 1.0)]
        return expr
    }

    /// Creates a controller with the given preset expressions pre-registered.
    private func makeController(presets: [(VRMExpressionPreset, VRMExpression)]) -> VRMExpressionController {
        let controller = VRMExpressionController()
        for (preset, expr) in presets {
            controller.registerExpression(expr, for: preset)
        }
        return controller
    }

    /// Reads the morph weight at mesh 0, morph 0.
    private func morphWeight(_ controller: VRMExpressionController) -> Float {
        return controller.weightsForMesh(0, morphCount: 1)[0]
    }

    // MARK: - H4: isBinary Tests

    func testH4_1_isBinaryTrueWeight0_4QuantizesToZero() {
        let expr = makeExpr(preset: .happy, isBinary: true)
        let controller = makeController(presets: [(.happy, expr)])

        controller.setExpressionWeight(.happy, weight: 0.4)

        XCTAssertEqual(morphWeight(controller), 0.0, accuracy: 1e-6,
            "isBinary=true, weight 0.4 must quantize to 0")
    }

    func testH4_2_isBinaryTrueWeight0_6QuantizesToOne() {
        let expr = makeExpr(preset: .happy, isBinary: true)
        let controller = makeController(presets: [(.happy, expr)])

        controller.setExpressionWeight(.happy, weight: 0.6)

        XCTAssertEqual(morphWeight(controller), 1.0, accuracy: 1e-6,
            "isBinary=true, weight 0.6 must quantize to 1")
    }

    func testH4_3_isBinaryTrueWeight0_5QuantizesToOne() {
        let expr = makeExpr(preset: .happy, isBinary: true)
        let controller = makeController(presets: [(.happy, expr)])

        controller.setExpressionWeight(.happy, weight: 0.5)

        XCTAssertEqual(morphWeight(controller), 1.0, accuracy: 1e-6,
            "isBinary=true, weight exactly 0.5 must quantize to 1 (>= threshold)")
    }

    func testH4_4_isBinaryFalseWeight0_7PassesThrough() {
        let expr = makeExpr(preset: .happy, isBinary: false)
        let controller = makeController(presets: [(.happy, expr)])

        controller.setExpressionWeight(.happy, weight: 0.7)

        XCTAssertEqual(morphWeight(controller), 0.7, accuracy: 1e-6,
            "isBinary=false must not quantize: weight 0.7 passes through unchanged")
    }

    // MARK: - H2: Override Tests

    func testH2_1_overrideBlinkBlockSuppressesBlinkGroup() {
        // happy has overrideBlink=block. blink has morph bind at mesh 0, morph 0.
        var blinkExpr = makeExpr(preset: .blink)
        blinkExpr.morphTargetBinds = [VRMMorphTargetBind(node: 0, index: 0, weight: 1.0)]

        var happyExpr = VRMExpression(name: "happy", preset: .happy)
        happyExpr.overrideBlink = .block
        happyExpr.morphTargetBinds = []  // happy doesn't drive morphs in this test

        let controller = makeController(presets: [
            (.blink, blinkExpr),
            (.happy, happyExpr)
        ])

        controller.setExpressionWeight(.blink, weight: 0.8)
        controller.setExpressionWeight(.happy, weight: 0.5)

        XCTAssertEqual(morphWeight(controller), 0.0, accuracy: 1e-6,
            "overrideBlink=block on happy (w=0.5) must suppress blink group to 0")
    }

    func testH2_2_overrideBlinkBlendScalesBlinkGroup() {
        var blinkExpr = makeExpr(preset: .blink)
        blinkExpr.morphTargetBinds = [VRMMorphTargetBind(node: 0, index: 0, weight: 1.0)]

        var happyExpr = VRMExpression(name: "happy", preset: .happy)
        happyExpr.overrideBlink = .blend
        happyExpr.morphTargetBinds = []

        let controller = makeController(presets: [
            (.blink, blinkExpr),
            (.happy, happyExpr)
        ])

        controller.setExpressionWeight(.blink, weight: 0.8)
        controller.setExpressionWeight(.happy, weight: 0.5)

        // blend factor = 1 - 0.5 = 0.5; effective blink = 0.8 * 0.5 = 0.4
        XCTAssertEqual(morphWeight(controller), 0.4, accuracy: 1e-5,
            "overrideBlink=blend on happy (w=0.5) must scale blink from 0.8 to 0.4")
    }

    func testH2_3_blockDominatesBlend() {
        // Two expressions: one block, one blend — block must win (result = 0).
        var blinkExpr = makeExpr(preset: .blink)
        blinkExpr.morphTargetBinds = [VRMMorphTargetBind(node: 0, index: 0, weight: 1.0)]

        var happyExpr = VRMExpression(name: "happy", preset: .happy)
        happyExpr.overrideBlink = .block
        happyExpr.morphTargetBinds = []

        var sadExpr = VRMExpression(name: "sad", preset: .sad)
        sadExpr.overrideBlink = .blend
        sadExpr.morphTargetBinds = []

        let controller = makeController(presets: [
            (.blink, blinkExpr),
            (.happy, happyExpr),
            (.sad, sadExpr)
        ])

        controller.setExpressionWeight(.blink, weight: 0.8)
        controller.setExpressionWeight(.happy, weight: 0.5)
        controller.setExpressionWeight(.sad, weight: 0.4)

        XCTAssertEqual(morphWeight(controller), 0.0, accuracy: 1e-6,
            "When block and blend both apply, block dominates (result must be 0)")
    }

    func testH2_4_blendCompositionMultipliesFactors() {
        // Two blend expressions each at 0.5: factor = (1-0.5)*(1-0.5) = 0.25
        // original blink 0.8 → 0.8 * 0.25 = 0.2
        var blinkExpr = makeExpr(preset: .blink)
        blinkExpr.morphTargetBinds = [VRMMorphTargetBind(node: 0, index: 0, weight: 1.0)]

        var happyExpr = VRMExpression(name: "happy", preset: .happy)
        happyExpr.overrideBlink = .blend
        happyExpr.morphTargetBinds = []

        var sadExpr = VRMExpression(name: "sad", preset: .sad)
        sadExpr.overrideBlink = .blend
        sadExpr.morphTargetBinds = []

        let controller = makeController(presets: [
            (.blink, blinkExpr),
            (.happy, happyExpr),
            (.sad, sadExpr)
        ])

        controller.setExpressionWeight(.blink, weight: 0.8)
        controller.setExpressionWeight(.happy, weight: 0.5)
        controller.setExpressionWeight(.sad, weight: 0.5)

        XCTAssertEqual(morphWeight(controller), 0.2, accuracy: 1e-5,
            "Two blend expressions at 0.5 each compose: 0.8 * (1-0.5) * (1-0.5) = 0.2")
    }

    func testH2_5_overrideLookAtOnlyAffectsGazeGroup() {
        // happy has overrideLookAt=block. lookUp has morph at mesh 0 morph 0.
        // blink also has morph at mesh 0 morph 1. Only lookUp should be suppressed.
        var lookUpExpr = VRMExpression(name: "lookUp", preset: .lookUp)
        lookUpExpr.morphTargetBinds = [VRMMorphTargetBind(node: 0, index: 0, weight: 1.0)]

        var blinkExpr = VRMExpression(name: "blink", preset: .blink)
        blinkExpr.morphTargetBinds = [VRMMorphTargetBind(node: 0, index: 1, weight: 1.0)]

        var happyExpr = VRMExpression(name: "happy", preset: .happy)
        happyExpr.overrideLookAt = .block
        happyExpr.morphTargetBinds = []

        let controller = makeController(presets: [
            (.lookUp, lookUpExpr),
            (.blink, blinkExpr),
            (.happy, happyExpr)
        ])

        controller.setExpressionWeight(.lookUp, weight: 0.9)
        controller.setExpressionWeight(.blink, weight: 0.8)
        controller.setExpressionWeight(.happy, weight: 1.0)

        let weights = controller.weightsForMesh(0, morphCount: 2)
        XCTAssertEqual(weights[0], 0.0, accuracy: 1e-6,
            "overrideLookAt=block must suppress lookUp (morph 0) to 0")
        XCTAssertEqual(weights[1], 0.8, accuracy: 1e-5,
            "overrideLookAt must NOT affect blink (morph 1)")
    }

    func testH2_6_overrideMouthOnlyAffectsMouthGroup() {
        // happy has overrideMouth=block. aa has morph at mesh 0 morph 0.
        // blink has morph at mesh 0 morph 1. Only aa should be suppressed.
        var aaExpr = VRMExpression(name: "aa", preset: .aa)
        aaExpr.morphTargetBinds = [VRMMorphTargetBind(node: 0, index: 0, weight: 1.0)]

        var blinkExpr = VRMExpression(name: "blink", preset: .blink)
        blinkExpr.morphTargetBinds = [VRMMorphTargetBind(node: 0, index: 1, weight: 1.0)]

        var happyExpr = VRMExpression(name: "happy", preset: .happy)
        happyExpr.overrideMouth = .block
        happyExpr.morphTargetBinds = []

        let controller = makeController(presets: [
            (.aa, aaExpr),
            (.blink, blinkExpr),
            (.happy, happyExpr)
        ])

        controller.setExpressionWeight(.aa, weight: 0.9)
        controller.setExpressionWeight(.blink, weight: 0.8)
        controller.setExpressionWeight(.happy, weight: 1.0)

        let weights = controller.weightsForMesh(0, morphCount: 2)
        XCTAssertEqual(weights[0], 0.0, accuracy: 1e-6,
            "overrideMouth=block must suppress aa (morph 0) to 0")
        XCTAssertEqual(weights[1], 0.8, accuracy: 1e-5,
            "overrideMouth must NOT affect blink (morph 1)")
    }

    func testH2_7_customExpressionWithOverrideBlinkBlockAppliesToGroup() {
        // A custom (non-preset) expression with overrideBlink=block suppresses blink group.
        var blinkExpr = makeExpr(preset: .blink)
        blinkExpr.morphTargetBinds = [VRMMorphTargetBind(node: 0, index: 0, weight: 1.0)]

        var customExpr = VRMExpression(name: "myCustom", preset: nil)
        customExpr.overrideBlink = .block
        customExpr.morphTargetBinds = []

        let controller = makeController(presets: [(.blink, blinkExpr)])
        controller.registerCustomExpression(customExpr, name: "myCustom")

        controller.setExpressionWeight(.blink, weight: 0.8)
        controller.setCustomExpressionWeight("myCustom", weight: 1.0)

        XCTAssertEqual(morphWeight(controller), 0.0, accuracy: 1e-6,
            "Custom expression with overrideBlink=block must suppress blink group to 0")
    }
}
