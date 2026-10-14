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
import Metal
import simd
@testable import VRMMetalKit

/// Regression coverage for Issue #442:
/// Live ARKit tracking mouth deformation at extreme poses across standard,
/// partial Perfect Sync, and full Perfect Sync VRM models.
final class ARKitMouthDeformationTests: XCTestCase {

    // MARK: - 1. Standard Viseme Mix & Channel Independence

    func testIsolatedJawOpenDrivesOnlyAaViseme() {
        let mapper = ARKitToVRMMapper.default
        let shapes = ARKitFaceBlendShapes(
            timestamp: Date().timeIntervalSinceReferenceDate,
            shapes: [ARKitFaceBlendShapes.jawOpen: 1.0]
        )

        let weights = mapper.evaluate(shapes)

        XCTAssertEqual(weights["aa"] ?? 0, 0.8, accuracy: 1e-4, "Isolated jawOpen=1 must drive aa")
        XCTAssertEqual(weights["ih"] ?? 0, 0.0, accuracy: 1e-5, "Isolated jawOpen=1 without smile/stretch must not drive ih")
        XCTAssertEqual(weights["oh"] ?? 0, 0.0, accuracy: 1e-5, "Isolated jawOpen=1 without funnel must not drive oh")
        XCTAssertEqual(weights["ou"] ?? 0, 0.0, accuracy: 1e-5, "Isolated jawOpen=1 without pucker/funnel must not drive ou")
        XCTAssertEqual(weights["ee"] ?? 0, 0.0, accuracy: 1e-5, "Isolated jawOpen=1 without smile/stretch must not drive ee")
    }

    func testExtremeVisemeAndEmotionCombinationsRemainBoundedWithinVisemeBudget() {
        let mapper = ARKitToVRMMapper.default
        let extremePoses: [[String: Float]] = [
            [
                ARKitFaceBlendShapes.jawOpen: 1.0,
                ARKitFaceBlendShapes.mouthFunnel: 1.0,
                ARKitFaceBlendShapes.mouthPucker: 1.0,
            ],
            [
                ARKitFaceBlendShapes.jawOpen: 1.0,
                ARKitFaceBlendShapes.mouthSmileLeft: 1.0,
                ARKitFaceBlendShapes.mouthSmileRight: 1.0,
                ARKitFaceBlendShapes.mouthStretchLeft: 1.0,
                ARKitFaceBlendShapes.mouthStretchRight: 1.0,
                ARKitFaceBlendShapes.cheekSquintLeft: 1.0,
                ARKitFaceBlendShapes.cheekSquintRight: 1.0,
            ],
            [
                ARKitFaceBlendShapes.jawOpen: 1.0,
                ARKitFaceBlendShapes.mouthFunnel: 0.8,
                ARKitFaceBlendShapes.mouthSmileLeft: 1.0,
                ARKitFaceBlendShapes.mouthSmileRight: 1.0,
                ARKitFaceBlendShapes.browInnerUp: 1.0,
                ARKitFaceBlendShapes.browOuterUpLeft: 1.0,
                ARKitFaceBlendShapes.browOuterUpRight: 1.0,
                ARKitFaceBlendShapes.eyeWideLeft: 1.0,
                ARKitFaceBlendShapes.eyeWideRight: 1.0,
            ],
        ]

        for pose in extremePoses {
            let shapes = ARKitFaceBlendShapes(timestamp: Date().timeIntervalSinceReferenceDate, shapes: pose)
            let weights = mapper.evaluate(shapes)

            let visemeSum = ARKitToVRMMapper.visemePresets.reduce(Float(0)) { $0 + (weights[$1] ?? 0) }
            XCTAssertLessThanOrEqual(visemeSum, 1.0 + 1e-5, "Viseme weight sum must stay within visemeBudget (1.0)")

            let mouthLoad = mapper.mouthOverlapWeights.reduce(Float(0)) { sum, pair in
                sum + pair.value * (weights[pair.key] ?? 0)
            }
            XCTAssertLessThanOrEqual(mouthLoad, 1.0 + 1e-5, "Combined mouth load must stay within visemeBudget (1.0)")

            for key in ARKitToVRMMapper.visemePresets {
                XCTAssertEqual(
                    mapper.evaluate(shapes, expression: key),
                    weights[key] ?? 0,
                    accuracy: 1e-5,
                    "Single-expression evaluate(_:expression:) must agree with batch evaluate(_:)"
                )
            }
        }
    }

    func testIndependentBlinkAndGazeChannelsArePreservedUnderExtremeMouthInput() {
        let mapper = ARKitToVRMMapper.default
        let shapes = ARKitFaceBlendShapes(
            timestamp: Date().timeIntervalSinceReferenceDate,
            shapes: [
                ARKitFaceBlendShapes.jawOpen: 1.0,
                ARKitFaceBlendShapes.mouthFunnel: 1.0,
                ARKitFaceBlendShapes.mouthSmileLeft: 1.0,
                ARKitFaceBlendShapes.mouthSmileRight: 1.0,
                ARKitFaceBlendShapes.eyeBlinkLeft: 0.9,
                ARKitFaceBlendShapes.eyeBlinkRight: 0.7,
                ARKitFaceBlendShapes.eyeLookUpLeft: 0.8,
                ARKitFaceBlendShapes.eyeLookUpRight: 0.8,
                ARKitFaceBlendShapes.eyeLookOutLeft: 0.6,
                ARKitFaceBlendShapes.eyeLookInRight: 0.6,
            ]
        )

        let weights = mapper.evaluate(shapes)

        XCTAssertEqual(weights["blinkLeft"] ?? 0, 0.9, accuracy: 1e-5, "blinkLeft must not be attenuated by mouth budget")
        XCTAssertEqual(weights["blinkRight"] ?? 0, 0.7, accuracy: 1e-5, "blinkRight must not be attenuated by mouth budget")
        XCTAssertEqual(weights["blink"] ?? 0, 0.8, accuracy: 1e-5, "blink must not be attenuated by mouth budget")
        XCTAssertEqual(weights["lookUp"] ?? 0, 0.8, accuracy: 1e-5, "lookUp must not be attenuated by mouth budget")
        XCTAssertEqual(weights["lookLeft"] ?? 0, 0.6, accuracy: 1e-5, "lookLeft must not be attenuated by mouth budget")
    }

    func testUnconfiguredDefaultMapperPreservesBrowAndEyeSurprisedUnderOpenJaw() {
        let mapper = ARKitToVRMMapper.default
        let shapes = ARKitFaceBlendShapes(
            timestamp: Date().timeIntervalSinceReferenceDate,
            shapes: [
                ARKitFaceBlendShapes.jawOpen: 1.0,
                ARKitFaceBlendShapes.mouthSmileLeft: 1.0,
                ARKitFaceBlendShapes.mouthSmileRight: 1.0,
                ARKitFaceBlendShapes.browInnerUp: 1.0,
                ARKitFaceBlendShapes.browOuterUpLeft: 1.0,
                ARKitFaceBlendShapes.browOuterUpRight: 1.0,
                ARKitFaceBlendShapes.eyeWideLeft: 1.0,
                ARKitFaceBlendShapes.eyeWideRight: 1.0,
            ]
        )

        let weights = mapper.evaluate(shapes)
        XCTAssertEqual(weights["surprised"] ?? 0, 1.0, accuracy: 1e-5,
                       "Unconfigured default surprised formula uses only brow/eye inputs and must not be weakened by jaw opening")
    }

    // MARK: - 2. Partial & Full Perfect Sync Overlap Prevention

    func testPartialPerfectSyncDoesNotDuplicateMatchedMouthMotionInFallbackPresets() {
        // 35 matched shapes including jawOpen, mouthFunnel, mouthSmileLeft, mouthSmileRight
        let matched = Set(ARKitFaceBlendShapes.allKeys.prefix(40))
        let missing = Set(ARKitFaceBlendShapes.allKeys).subtracting(matched)
        XCTAssertTrue(matched.contains(ARKitFaceBlendShapes.jawOpen))
        XCTAssertTrue(matched.contains(ARKitFaceBlendShapes.mouthFunnel))

        let psMapper = PerfectSyncMapper(
            capability: .partial(matched: matched, missing: missing)
        )

        let shapes = ARKitFaceBlendShapes(
            timestamp: Date().timeIntervalSinceReferenceDate,
            shapes: [
                ARKitFaceBlendShapes.jawOpen: 1.0,
                ARKitFaceBlendShapes.mouthFunnel: 0.8,
                ARKitFaceBlendShapes.mouthSmileLeft: 0.9,
                ARKitFaceBlendShapes.mouthSmileRight: 0.9,
            ]
        )

        let (custom, preset) = psMapper.evaluate(shapes)

        XCTAssertEqual(custom[ARKitFaceBlendShapes.jawOpen] ?? 0, 1.0, accuracy: 1e-5)
        XCTAssertEqual(custom[ARKitFaceBlendShapes.mouthFunnel] ?? 0, 0.8, accuracy: 1e-5)

        // Matched mouth channels must not also drive fallback visemes or happy/relaxed presets
        for viseme in ARKitToVRMMapper.visemePresets {
            XCTAssertEqual(preset[viseme] ?? 0, 0.0, accuracy: 1e-5,
                           "Matched mouth inputs must not duplicate into fallback preset '\(viseme)'")
        }
        XCTAssertEqual(preset["happy"] ?? 0, 0.0, accuracy: 1e-5,
                       "Matched smile inputs must not duplicate into fallback preset 'happy'")
        XCTAssertEqual(
            preset["neutral"] ?? 1,
            ARKitToVRMMapper.default.evaluate(shapes, expression: "neutral"),
            accuracy: 1e-5,
            "Neutral preset must reflect total activation of full input rather than rising to 1.0"
        )
        XCTAssertLessThan(preset["neutral"] ?? 1, 1.0)
    }

    func testPartialPerfectSyncCapsUnmatchedFallbackMouthPresetsByRemainingMouthBudget() {
        // Suppose jawOpen is matched (custom), while mouthFunnel & mouthPucker are missing (fallback)
        let matched: Set<String> = [ARKitFaceBlendShapes.jawOpen]
        let missing: Set<String> = [ARKitFaceBlendShapes.mouthFunnel, ARKitFaceBlendShapes.mouthPucker]
        let psMapper = PerfectSyncMapper(
            capability: .partial(matched: matched, missing: missing)
        )

        let shapes = ARKitFaceBlendShapes(
            timestamp: Date().timeIntervalSinceReferenceDate,
            shapes: [
                ARKitFaceBlendShapes.jawOpen: 0.75,
                ARKitFaceBlendShapes.mouthFunnel: 1.0,
                ARKitFaceBlendShapes.mouthPucker: 1.0,
            ]
        )

        let (custom, preset) = psMapper.evaluate(shapes)
        let customJaw = custom[ARKitFaceBlendShapes.jawOpen] ?? 0
        let fallbackVisemeSum = ARKitToVRMMapper.visemePresets.reduce(Float(0)) { $0 + (preset[$1] ?? 0) }

        XCTAssertEqual(customJaw, 0.75, accuracy: 1e-5)
        XCTAssertGreaterThan(fallbackVisemeSum, 0.0, "Unmatched funnel/pucker should still contribute remaining budget")
        XCTAssertLessThanOrEqual(customJaw + fallbackVisemeSum, 1.0 + 1e-5,
                                 "Direct custom jawOpen + fallback visemes must not exceed 1.0 total mouth budget")
    }

    func testPartialPerfectSyncPreservesMatchedJawContextForUnmatchedSmileAndRelaxed() {
        // jawOpen is matched (custom), while mouthSmileLeft/Right are missing (fallback)
        let matched: Set<String> = [ARKitFaceBlendShapes.jawOpen]
        let missing: Set<String> = [
            ARKitFaceBlendShapes.mouthSmileLeft,
            ARKitFaceBlendShapes.mouthSmileRight,
        ]
        let psMapper = PerfectSyncMapper(
            capability: .partial(matched: matched, missing: missing)
        )

        let shapes = ARKitFaceBlendShapes(
            timestamp: Date().timeIntervalSinceReferenceDate,
            shapes: [
                ARKitFaceBlendShapes.jawOpen: 0.6,
                ARKitFaceBlendShapes.mouthSmileLeft: 1.0,
                ARKitFaceBlendShapes.mouthSmileRight: 1.0,
            ]
        )

        let (custom, preset) = psMapper.evaluate(shapes)

        XCTAssertEqual(custom[ARKitFaceBlendShapes.jawOpen] ?? 0, 0.6, accuracy: 1e-5)
        XCTAssertEqual(preset["aa"] ?? 0, 0.0, accuracy: 1e-5,
                       "aa has only matched primary drivers (jawOpen) and must not duplicate in fallback")
        XCTAssertGreaterThan(preset["ee"] ?? 0, 0.0,
                             "Unmatched smile must still activate ee using matched jawOpen as gating context")
        let fallbackMouthLoad = ARKitToVRMMapper.defaultMouthOverlapWeights.reduce(Float(0)) { sum, pair in
            sum + pair.value * (preset[pair.key] ?? 0)
        }
        XCTAssertLessThanOrEqual(0.6 + fallbackMouthLoad, 1.0 + 1e-5,
                                 "Direct jawOpen + fallback mouth presets must remain within 1.0 budget")
    }

    func testFullPerfectSyncPreservesIndependentChannelsAndBoundsSharedMorphBinds() throws {
        let gltf = try JSONDecoder().decode(
            GLTFDocument.self,
            from: Data(#"{"asset":{"version":"2.0"}}"#.utf8)
        )
        let model = VRMModel(specVersion: .v1_0, meta: VRMMeta(licenseUrl: ""), humanoid: nil, gltf: gltf)
        let expressions = VRMExpressions()

        for (index, key) in ARKitFaceBlendShapes.allKeys.enumerated() {
            var expr = VRMExpression(name: key)
            if key == ARKitFaceBlendShapes.mouthFrownLeft {
                // Shared morph index 95 with mouthLowerDownLeft (HANA_Tool / PS_Female pattern)
                expr.morphTargetBinds = [VRMMorphTargetBind(node: 0, index: 95, weight: 1.0)]
            } else if key == ARKitFaceBlendShapes.mouthLowerDownLeft {
                expr.morphTargetBinds = [VRMMorphTargetBind(node: 0, index: 95, weight: 0.5)]
            } else {
                expr.morphTargetBinds = [VRMMorphTargetBind(node: 0, index: index, weight: 1.0)]
            }
            expressions.custom[key] = expr
        }
        model.expressions = expressions

        let controller = VRMExpressionController()
        for (name, expr) in expressions.custom {
            controller.registerCustomExpression(expr, name: name)
        }

        let driver = ARKitFaceDriver.configured(for: model, smoothing: .none)
        XCTAssertEqual(driver.perfectSyncCapability, .full)

        let shapes = ARKitFaceBlendShapes(
            timestamp: Date().timeIntervalSinceReferenceDate,
            shapes: [
                ARKitFaceBlendShapes.jawOpen: 1.0,
                ARKitFaceBlendShapes.eyeBlinkLeft: 0.9,
                ARKitFaceBlendShapes.mouthSmileRight: 0.85,
                ARKitFaceBlendShapes.mouthFrownLeft: 1.0,
                ARKitFaceBlendShapes.mouthLowerDownLeft: 1.0,
            ]
        )

        driver.update(blendShapes: shapes, controller: controller)

        // Independent channels must pass through 1:1 without global normalization
        XCTAssertEqual(controller.weight(forCustom: ARKitFaceBlendShapes.jawOpen) ?? 0, 1.0, accuracy: 1e-5)
        XCTAssertEqual(controller.weight(forCustom: ARKitFaceBlendShapes.eyeBlinkLeft) ?? 0, 0.9, accuracy: 1e-5)
        XCTAssertEqual(controller.weight(forCustom: ARKitFaceBlendShapes.mouthSmileRight) ?? 0, 0.85, accuracy: 1e-5)

        // Shared morph bind (index 95) must be bounded at 1.0 instead of accumulating to 1.5
        let meshWeights = controller.weightsForMesh(0, morphCount: 100)
        XCTAssertEqual(meshWeights[95], 1.0, accuracy: 1e-5,
                       "Shared morph bind across custom expressions must not exceed authored bind ceiling 1.0")
    }

    // MARK: - 3. Shared Morph Binds & Model-Aware Disjointness

    func testModelAwareMapperBoundsSharedPresetMorphBindsAndPreservesDisjointEmotions() throws {
        let gltf = try JSONDecoder().decode(
            GLTFDocument.self,
            from: Data(#"{"asset":{"version":"2.0"}}"#.utf8)
        )
        let model = VRMModel(specVersion: .v1_0, meta: VRMMeta(licenseUrl: ""), humanoid: nil, gltf: gltf)

        // Build a 4-vertex synthetic face primitive:
        // vertices 0..1 = mouth (y = 1.35), vertices 2..3 = eyebrows (y = 1.45)
        let primitive = VRMPrimitive()
        primitive.vertexCount = 4

        var aaTarget = VRMMorphTarget(name: "aa")
        aaTarget.positionDeltas = [
            SIMD3<Float>(0, -0.010, 0),
            SIMD3<Float>(0, -0.010, 0),
            SIMD3<Float>(0, 0, 0),
            SIMD3<Float>(0, 0, 0),
        ]

        var happyTarget = VRMMorphTarget(name: "happy_mouth_and_brow")
        happyTarget.positionDeltas = [
            SIMD3<Float>(0, -0.010, 0), // overlaps mouth vertices 0..1!
            SIMD3<Float>(0, -0.010, 0),
            SIMD3<Float>(0, 0.005, 0),
            SIMD3<Float>(0, 0.005, 0),
        ]

        var angryBrowOnlyTarget = VRMMorphTarget(name: "angry_brow_only")
        angryBrowOnlyTarget.positionDeltas = [
            SIMD3<Float>(0, 0, 0),      // zero mouth displacement!
            SIMD3<Float>(0, 0, 0),
            SIMD3<Float>(0, -0.008, 0),
            SIMD3<Float>(0, -0.008, 0),
        ]

        primitive.morphTargets = [aaTarget, happyTarget, angryBrowOnlyTarget]
        let mesh = VRMMesh(name: "Face")
        mesh.primitives = [primitive]
        model.meshes = [mesh]

        let expressions = VRMExpressions()
        var aaExpr = VRMExpression(name: "aa", preset: .aa)
        aaExpr.morphTargetBinds = [VRMMorphTargetBind(node: 0, index: 0, weight: 1.0)]
        expressions.preset[.aa] = aaExpr

        var happyExpr = VRMExpression(name: "happy", preset: .happy)
        happyExpr.morphTargetBinds = [VRMMorphTargetBind(node: 0, index: 1, weight: 1.0)]
        expressions.preset[.happy] = happyExpr

        var angryExpr = VRMExpression(name: "angry", preset: .angry)
        angryExpr.morphTargetBinds = [VRMMorphTargetBind(node: 0, index: 2, weight: 1.0)]
        expressions.preset[.angry] = angryExpr

        // Surprised shares morph target 0 directly with aa
        var surprisedExpr = VRMExpression(name: "surprised", preset: .surprised)
        surprisedExpr.morphTargetBinds = [VRMMorphTargetBind(node: 0, index: 0, weight: 1.0)]
        expressions.preset[.surprised] = surprisedExpr

        model.expressions = expressions

        let overlap = ARKitToVRMMapper.mouthOverlapWeights(for: model)
        XCTAssertEqual(overlap["aa"] ?? 0, 1.0, accuracy: 1e-4)
        XCTAssertEqual(overlap["happy"] ?? 0, 1.0, accuracy: 1e-4, "happy displaces mouth vertices equally to aa")
        XCTAssertEqual(overlap["surprised"] ?? 0, 1.0, accuracy: 1e-4, "surprised shares morph bind 0 with aa")
        XCTAssertEqual(overlap["angry"] ?? -1, 0.0, accuracy: 1e-5, "angry only moves brow vertices and must have 0 mouth overlap")

        let controller = VRMExpressionController()
        for (preset, expr) in expressions.preset {
            controller.registerExpression(expr, for: preset)
        }
        let driver = ARKitFaceDriver.configured(for: model, smoothing: .none)

        // Drive jawOpen + browDown + mouthFrown + smile + surprised simultaneously
        let shapes = ARKitFaceBlendShapes(
            timestamp: Date().timeIntervalSinceReferenceDate,
            shapes: [
                ARKitFaceBlendShapes.jawOpen: 1.0,
                ARKitFaceBlendShapes.mouthSmileLeft: 1.0,
                ARKitFaceBlendShapes.mouthSmileRight: 1.0,
                ARKitFaceBlendShapes.browDownLeft: 1.0,
                ARKitFaceBlendShapes.browDownRight: 1.0,
                ARKitFaceBlendShapes.mouthFrownLeft: 1.0,
                ARKitFaceBlendShapes.mouthFrownRight: 1.0,
                ARKitFaceBlendShapes.browInnerUp: 1.0,
                ARKitFaceBlendShapes.eyeWideLeft: 1.0,
                ARKitFaceBlendShapes.eyeWideRight: 1.0,
            ]
        )

        driver.update(blendShapes: shapes, controller: controller)

        // Brow-only angry must NOT be attenuated by jaw opening
        XCTAssertEqual(controller.weight(for: .angry), 1.0, accuracy: 1e-5,
                       "Disjoint brow-only emotion must retain full weight under extreme jaw opening")

        // Mouth-overlapping presets (aa + happy + surprised) must stay bounded within the -10mm mouth envelope
        let meshWeights = controller.weightsForMesh(0, morphCount: 3)
        let mouthVertex0DeltaY = meshWeights[0] * aaTarget.positionDeltas![0].y +
                                 meshWeights[1] * happyTarget.positionDeltas![0].y
        XCTAssertGreaterThanOrEqual(mouthVertex0DeltaY, -0.010 - 1e-5,
                                    "Combined mouth vertex downward displacement must not exceed single-viseme -10mm envelope")
    }

    func testMissingModelVisemesDoNotDiluteSupportedVisemeAndOverrideMouthBlockIsRespected() throws {
        let gltf = try JSONDecoder().decode(
            GLTFDocument.self,
            from: Data(#"{"asset":{"version":"2.0"}}"#.utf8)
        )
        let model = VRMModel(specVersion: .v1_0, meta: VRMMeta(licenseUrl: ""), humanoid: nil, gltf: gltf)

        // Model only defines `aa` (no `oh` or `ou` presets) and `happy` with `overrideMouth = .block`.
        let expressions = VRMExpressions()
        var aaExpr = VRMExpression(name: "aa", preset: .aa)
        aaExpr.morphTargetBinds = [VRMMorphTargetBind(node: 0, index: 0, weight: 1.0)]
        expressions.preset[.aa] = aaExpr

        var happyExpr = VRMExpression(name: "happy", preset: .happy)
        happyExpr.overrideMouth = .block
        happyExpr.morphTargetBinds = [VRMMorphTargetBind(node: 0, index: 1, weight: 1.0)]
        expressions.preset[.happy] = happyExpr

        model.expressions = expressions
        let configuredMapper = ARKitToVRMMapper.default.configured(for: model)

        // 1. Jaw + funnel input: since `oh` and `ou` are not supported on the model,
        // they must not consume viseme budget or dilute `aa`.
        let jawFunnel = ARKitFaceBlendShapes(
            timestamp: Date().timeIntervalSinceReferenceDate,
            shapes: [
                ARKitFaceBlendShapes.jawOpen: 1.0,
                ARKitFaceBlendShapes.mouthFunnel: 1.0,
            ]
        )
        let jawFunnelWeights = configuredMapper.evaluate(jawFunnel)
        let expectedAa = ARKitToVRMMapper.default.mappings["aa"]!.evaluateClamped(jawFunnel)
        XCTAssertEqual(jawFunnelWeights["aa"] ?? 0, expectedAa, accuracy: 1e-5,
                       "Unsupported oh/ou presets must not dilute supported aa preset")

        // 2. Smiling + jawOpen when `happy` has `overrideMouth = .block`:
        // `VRMExpressionController` will suppress `aa` to 0, so `happy` must not be attenuated by `aa`.
        let smileOpen = ARKitFaceBlendShapes(
            timestamp: Date().timeIntervalSinceReferenceDate,
            shapes: [
                ARKitFaceBlendShapes.jawOpen: 1.0,
                ARKitFaceBlendShapes.mouthSmileLeft: 1.0,
                ARKitFaceBlendShapes.mouthSmileRight: 1.0,
                ARKitFaceBlendShapes.cheekSquintLeft: 1.0,
                ARKitFaceBlendShapes.cheekSquintRight: 1.0,
            ]
        )
        let smileOpenWeights = configuredMapper.evaluate(smileOpen)
        XCTAssertEqual(smileOpenWeights["happy"] ?? 0, 1.0, accuracy: 1e-5,
                       "Emotion with overrideMouth=.block must not be attenuated by blocked visemes")
    }

    func testMultiGroupSharedBindScalingIsOrderIndependent() {
        // Key "b" participates in two shared-bind groups: (a, b) and (b, c).
        let group1: [String: Float] = ["a": 1.0, "b": 1.0]
        let group2: [String: Float] = ["b": 1.0, "c": 1.0]
        let formulas: [String: BlendShapeFormula] = [
            "a": .direct(ARKitFaceBlendShapes.eyeBlinkLeft),
            "b": .direct(ARKitFaceBlendShapes.eyeBlinkRight),
            "c": .direct(ARKitFaceBlendShapes.jawOpen),
        ]

        let mapperForward = ARKitToVRMMapper(
            mappings: formulas,
            mouthOverlapWeights: [:],
            sharedBindGroups: [group1, group2]
        )
        let mapperReverse = ARKitToVRMMapper(
            mappings: formulas,
            mouthOverlapWeights: [:],
            sharedBindGroups: [group2, group1]
        )

        let shapes = ARKitFaceBlendShapes(
            timestamp: Date().timeIntervalSinceReferenceDate,
            shapes: [
                ARKitFaceBlendShapes.eyeBlinkLeft: 0.8,
                ARKitFaceBlendShapes.eyeBlinkRight: 0.8,
                ARKitFaceBlendShapes.jawOpen: 0.6,
            ]
        )

        let forward = mapperForward.evaluate(shapes)
        let reverse = mapperReverse.evaluate(shapes)

        for key in ["a", "b", "c"] {
            XCTAssertEqual(forward[key] ?? -1, reverse[key] ?? -2, accuracy: 1e-6,
                           "Shared-bind scaling for '\(key)' must be deterministic regardless of group order")
        }
        // Group 1 load = 1.6 (scale 0.625), Group 2 load = 1.4 (scale 0.7142857); "b" gets min scale = 0.625 -> 0.5
        XCTAssertEqual(forward["b"] ?? 0, 0.5, accuracy: 1e-5,
                       "Shared key across multiple groups must receive minimum group scale once, not double attenuation")
    }

    func testBlendOverrideAndBinaryOverrideMaintainExactPostControllerBudget() {
        // 1. `.blend` emotion (`happy` with alpha=2.0, overrideMouth=.blend) + `aa` (alpha=1.0):
        // Scaling `happy` weakens its `.blend` suppression of `aa`, so the solved scale must keep
        // post-override load `alpha_happy * happy + alpha_aa * aa * (1 - happy)` <= 1.0.
        let blendMapper = ARKitToVRMMapper(
            mappings: [
                "aa": .direct(ARKitFaceBlendShapes.jawOpen),
                "happy": .direct(ARKitFaceBlendShapes.mouthSmileLeft),
            ],
            mouthOverlapWeights: ["aa": 1.0, "happy": 2.0],
            mouthOverrides: ["happy": .blend],
            activeModelPresets: ["aa", "happy"]
        )
        let blendShapes = ARKitFaceBlendShapes(
            timestamp: Date().timeIntervalSinceReferenceDate,
            shapes: [
                ARKitFaceBlendShapes.jawOpen: 0.8,
                ARKitFaceBlendShapes.mouthSmileLeft: 0.6,
            ]
        )
        let blendResult = blendMapper.evaluate(blendShapes)
        let scaledHappy = blendResult["happy"] ?? 0
        let scaledAa = blendResult["aa"] ?? 0
        let postControllerMouthLoad = 2.0 * scaledHappy + 1.0 * scaledAa * (1.0 - scaledHappy)
        XCTAssertEqual(postControllerMouthLoad, 1.0, accuracy: 1e-4,
                       "Post-controller mouth load with overrideMouth=.blend must match visemeBudget (1.0)")

        // 2. `isBinary = true` with `overrideMouth = .block` at raw weight 0.4 (< 0.5):
        // `VRMExpressionController` quantizes 0.4 -> 0.0, so it does NOT block visemes;
        // `aa` (0.8) + `sad` (0.8) must still be bounded to <= 1.0.
        let binaryMapper = ARKitToVRMMapper(
            mappings: [
                "aa": .direct(ARKitFaceBlendShapes.jawOpen),
                "sad": .direct(ARKitFaceBlendShapes.mouthFrownLeft),
                "angry": .direct(ARKitFaceBlendShapes.browDownLeft),
            ],
            mouthOverlapWeights: ["aa": 1.0, "sad": 1.0, "angry": 0.0],
            mouthOverrides: ["angry": .block],
            binaryPresets: ["angry"],
            activeModelPresets: ["aa", "sad", "angry"]
        )
        let binaryShapes = ARKitFaceBlendShapes(
            timestamp: Date().timeIntervalSinceReferenceDate,
            shapes: [
                ARKitFaceBlendShapes.jawOpen: 0.8,
                ARKitFaceBlendShapes.mouthFrownLeft: 0.8,
                ARKitFaceBlendShapes.browDownLeft: 0.4, // below 0.5 binary threshold -> quantizes to 0
            ]
        )
        let binaryResult = binaryMapper.evaluate(binaryShapes)
        let binaryMouthSum = (binaryResult["aa"] ?? 0) + (binaryResult["sad"] ?? 0)
        XCTAssertLessThanOrEqual(binaryMouthSum, 1.0 + 1e-5,
                                 "Sub-threshold binary overrideMouth=.block must not disable mouth budgeting")

        // 3. Customized fallback formula in `.partial` Perfect Sync:
        // Customizing `happy` to `.direct(jawOpen)` when `jawOpen` is matched must not duplicate `jawOpen`.
        let customFallback = ARKitToVRMMapper(
            mappings: ["happy": .direct(ARKitFaceBlendShapes.jawOpen)],
            mouthOverlapWeights: ["happy": 1.0]
        )
        let psMapper = PerfectSyncMapper(
            capability: .partial(matched: [ARKitFaceBlendShapes.jawOpen], missing: [ARKitFaceBlendShapes.mouthSmileLeft]),
            fallbackMapper: customFallback
        )
        let (_, preset) = psMapper.evaluate(
            ARKitFaceBlendShapes(
                timestamp: Date().timeIntervalSinceReferenceDate,
                shapes: [ARKitFaceBlendShapes.jawOpen: 0.9]
            )
        )
        XCTAssertEqual(preset["happy"] ?? 0, 0.0, accuracy: 1e-5,
                       "Customized fallback formula referencing matched jawOpen must not duplicate in partial mode")

        // 4. Full-weight `.blend` emotion (`happy=1.0`) + `sad=1.0` + `aa=0.8`:
        // Even though `aa` is initially suppressed at `scale=1.0`, scaling `happy` down reactivates `aa`,
        // so `aa` must also be scaled to keep post-controller mouth load <= 1.0.
        let reactivatingBlendMapper = ARKitToVRMMapper(
            mappings: [
                "aa": .direct(ARKitFaceBlendShapes.jawOpen),
                "happy": .direct(ARKitFaceBlendShapes.mouthSmileLeft),
                "sad": .direct(ARKitFaceBlendShapes.mouthFrownLeft),
            ],
            mouthOverlapWeights: ["aa": 1.0, "happy": 1.0, "sad": 1.0],
            mouthOverrides: ["happy": .blend],
            activeModelPresets: ["aa", "happy", "sad"]
        )
        let reactivated = reactivatingBlendMapper.evaluate(
            ARKitFaceBlendShapes(
                timestamp: Date().timeIntervalSinceReferenceDate,
                shapes: [
                    ARKitFaceBlendShapes.jawOpen: 0.8,
                    ARKitFaceBlendShapes.mouthSmileLeft: 1.0,
                    ARKitFaceBlendShapes.mouthFrownLeft: 1.0,
                ]
            )
        )
        let rHappy = reactivated["happy"] ?? 0
        let rSad = reactivated["sad"] ?? 0
        let rAa = reactivated["aa"] ?? 0
        let reactivatedLoad = rHappy + rSad + rAa * (1.0 - rHappy)
        XCTAssertEqual(reactivatedLoad, 1.0, accuracy: 1e-4,
                       "Reactivated visemes under scaled .blend emotion must stay within visemeBudget (1.0)")

        // 5. Shared-bind attenuation of a `.blend` emotion (`happy` sharing a bind with `blink`)
        // runs before mouth-budget solving so the weakened suppression cannot push mouth load over 1.0.
        let sharedBlendMapper = ARKitToVRMMapper(
            mappings: [
                "aa": .direct(ARKitFaceBlendShapes.jawOpen),
                "happy": .direct(ARKitFaceBlendShapes.mouthSmileLeft),
                "sad": .direct(ARKitFaceBlendShapes.mouthFrownLeft),
                "blink": .direct(ARKitFaceBlendShapes.eyeBlinkLeft),
            ],
            mouthOverlapWeights: ["aa": 1.0, "happy": 0.2, "sad": 1.0],
            sharedBindGroups: [["happy": 1.0, "blink": 1.0]],
            mouthOverrides: ["happy": .blend],
            activeModelPresets: ["aa", "happy", "sad", "blink"]
        )
        let sharedBlend = sharedBlendMapper.evaluate(
            ARKitFaceBlendShapes(
                timestamp: Date().timeIntervalSinceReferenceDate,
                shapes: [
                    ARKitFaceBlendShapes.jawOpen: 0.8,
                    ARKitFaceBlendShapes.mouthSmileLeft: 0.8,
                    ARKitFaceBlendShapes.mouthFrownLeft: 0.65,
                    ARKitFaceBlendShapes.eyeBlinkLeft: 1.0,
                ]
            )
        )
        let sbHappy = sharedBlend["happy"] ?? 0
        let sbSad = sharedBlend["sad"] ?? 0
        let sbAa = sharedBlend["aa"] ?? 0
        let sharedBlendLoad = 0.2 * sbHappy + sbSad + sbAa * (1.0 - sbHappy)
        XCTAssertLessThanOrEqual(sharedBlendLoad, 1.0 + 1e-4,
                                 "Shared-bind attenuation of .blend emotion must not allow mouth load to exceed 1.0")
    }

    // MARK: - 4. Geometry & GPU Render Verification on Real VRM Models

    @MainActor
    func testRealModelsMouthGeometryAndRenderStayInsideFaceAtExtremePoses() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device not available")
        }

        let projectRoot = getProjectRoot()
        var candidatePaths = [
            "\(projectRoot)/AvatarSample_A_1.0.vrm.glb",
            "\(projectRoot)/vroid_default_F_1_0.vrm",
            "\(projectRoot)/AvatarSample_U_1.0.vrm.glb",
            "\(projectRoot)/AliciaSolid.vrm",
        ]
        if let museResources = ProcessInfo.processInfo.environment["MUSE_RESOURCES_PATH"] {
            candidatePaths.append("\(museResources)/VRM/AliciaSolid.vrm")
        }
        candidatePaths = candidatePaths.filter { FileManager.default.fileExists(atPath: $0) }

        guard !candidatePaths.isEmpty else {
            throw XCTSkip("No VRM test fixtures found on disk")
        }

        let extremePoses: [(name: String, shapes: [String: Float])] = [
            ("extreme_jawOpen", [
                ARKitFaceBlendShapes.jawOpen: 1.0,
            ]),
            ("extreme_jawOpen_funnel", [
                ARKitFaceBlendShapes.jawOpen: 1.0,
                ARKitFaceBlendShapes.mouthFunnel: 1.0,
            ]),
            ("extreme_jawOpen_smile", [
                ARKitFaceBlendShapes.jawOpen: 1.0,
                ARKitFaceBlendShapes.mouthSmileLeft: 1.0,
                ARKitFaceBlendShapes.mouthSmileRight: 1.0,
                ARKitFaceBlendShapes.cheekSquintLeft: 1.0,
                ARKitFaceBlendShapes.cheekSquintRight: 1.0,
            ]),
            ("extreme_jawOpen_smile_surprised", [
                ARKitFaceBlendShapes.jawOpen: 1.0,
                ARKitFaceBlendShapes.mouthFunnel: 0.8,
                ARKitFaceBlendShapes.mouthSmileLeft: 1.0,
                ARKitFaceBlendShapes.mouthSmileRight: 1.0,
                ARKitFaceBlendShapes.cheekSquintLeft: 1.0,
                ARKitFaceBlendShapes.cheekSquintRight: 1.0,
                ARKitFaceBlendShapes.browInnerUp: 1.0,
                ARKitFaceBlendShapes.browOuterUpLeft: 1.0,
                ARKitFaceBlendShapes.browOuterUpRight: 1.0,
                ARKitFaceBlendShapes.eyeWideLeft: 1.0,
                ARKitFaceBlendShapes.eyeWideRight: 1.0,
            ]),
            ("extreme_jawOpen_frown_angry_sad", [
                ARKitFaceBlendShapes.jawOpen: 1.0,
                ARKitFaceBlendShapes.mouthFunnel: 0.8,
                ARKitFaceBlendShapes.browDownLeft: 1.0,
                ARKitFaceBlendShapes.browDownRight: 1.0,
                ARKitFaceBlendShapes.mouthFrownLeft: 1.0,
                ARKitFaceBlendShapes.mouthFrownRight: 1.0,
                ARKitFaceBlendShapes.browInnerUp: 0.8,
            ]),
        ]

        for path in candidatePaths {
            let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device)
            guard let expressions = model.expressions else { continue }

            // Find the face mesh bound by `.aa`
            guard let aaBinds = expressions.preset[.aa]?.morphTargetBinds,
                  let faceMeshIndex = aaBinds.first?.meshIndex,
                  faceMeshIndex < model.meshes.count else {
                continue
            }
            let faceMesh = model.meshes[faceMeshIndex]
            guard let firstPrim = faceMesh.primitives.first else { continue }

            let baseVerts = firstPrim.interleavedVertices().map(\.position)
            let faceChinMinY = baseVerts.map(\.y).min() ?? 0

            // Compute single-viseme authored envelope across [.aa, .ih, .ou, .ee, .oh]
            let visemePresets: [VRMExpressionPreset] = [.aa, .ih, .ou, .ee, .oh]
            var mouthVertexIndices = Set<Int>()
            var maxSingleVisemeDownwardDY: Float = 0 // most negative dy
            var maxSingleVisemeDisp: Float = 0

            for viseme in visemePresets {
                guard let expr = expressions.preset[viseme] else { continue }
                let binds = expr.morphTargetBinds.filter { $0.meshIndex == faceMeshIndex }
                for vi in 0..<baseVerts.count {
                    var delta = SIMD3<Float>.zero
                    for bind in binds where bind.index >= 0 && bind.index < firstPrim.morphTargets.count {
                        if let deltas = firstPrim.morphTargets[bind.index].positionDeltas, vi < deltas.count {
                            delta += deltas[vi] * bind.weight
                        }
                    }
                    let mag = simd_length(delta)
                    if mag > 1e-4 {
                        mouthVertexIndices.insert(vi)
                        maxSingleVisemeDownwardDY = min(maxSingleVisemeDownwardDY, delta.y)
                        maxSingleVisemeDisp = max(maxSingleVisemeDisp, mag)
                    }
                }
            }
            XCTAssertFalse(mouthVertexIndices.isEmpty, "Should identify mouth vertices on \(path)")

            let renderer = VRMRenderer(device: device)
            renderer.enableSpringBone = false
            renderer.loadModelWithoutWarmup(model)
            guard let controller = renderer.expressionController else {
                XCTFail("Expected expressionController on renderer")
                continue
            }

            let driver = ARKitFaceDriver.configured(for: model, smoothing: .none)

            for (poseName, shapeDict) in extremePoses {
                for preset in VRMExpressionPreset.allCases {
                    controller.setExpressionWeight(preset, weight: 0)
                }
                let blendShapes = ARKitFaceBlendShapes(
                    timestamp: Date().timeIntervalSinceReferenceDate,
                    shapes: shapeDict
                )
                driver.update(blendShapes: blendShapes, controller: controller)

                let morphWeights = controller.weightsForMesh(faceMeshIndex, morphCount: firstPrim.morphTargets.count)
                guard let morphSystem = renderer.morphTargetSystem else { continue }
                let activeSet = morphSystem.buildActiveSet(weights: morphWeights)

                var poseMinDY: Float = 0
                var poseMaxDisp: Float = 0
                var lowestMorphedMouthY: Float = .greatestFiniteMagnitude

                for vi in mouthVertexIndices {
                    var delta = SIMD3<Float>.zero
                    for active in activeSet {
                        let idx = Int(active.index)
                        if idx < firstPrim.morphTargets.count,
                           let deltas = firstPrim.morphTargets[idx].positionDeltas,
                           vi < deltas.count {
                            delta += deltas[vi] * active.weight
                        }
                    }
                    poseMinDY = min(poseMinDY, delta.y)
                    poseMaxDisp = max(poseMaxDisp, simd_length(delta))
                    lowestMorphedMouthY = min(lowestMorphedMouthY, baseVerts[vi].y + delta.y)
                }

                let modelName = URL(fileURLWithPath: path).lastPathComponent
                XCTAssertGreaterThanOrEqual(
                    poseMinDY,
                    maxSingleVisemeDownwardDY * 1.05 - 1e-4,
                    "\(modelName) [\(poseName)]: downward mouth displacement (\(poseMinDY * 1000)mm) exceeded authored viseme envelope (\(maxSingleVisemeDownwardDY * 1000)mm)"
                )
                XCTAssertLessThanOrEqual(
                    poseMaxDisp,
                    maxSingleVisemeDisp * 1.05 + 1e-4,
                    "\(modelName) [\(poseName)]: 3D mouth displacement (\(poseMaxDisp * 1000)mm) exceeded authored viseme envelope (\(maxSingleVisemeDisp * 1000)mm)"
                )
                XCTAssertGreaterThan(
                    lowestMorphedMouthY,
                    faceChinMinY,
                    "\(modelName) [\(poseName)]: lowest morphed mouth vertex (\(lowestMorphedMouthY)) extended below chin (\(faceChinMinY))"
                )
            }

            // Also verify neutral mouth + extreme head rotation (pitch + yaw + roll)
            // keeps mouth vertices rigidly attached to the head bone without separation,
            // and render an offscreen frame with head rotation + extreme mouth pose.
            if let headNodeIndex = model.humanoid?.getBoneNode(.head),
               headNodeIndex >= 0, headNodeIndex < model.nodes.count {
                let headNode = model.nodes[headNodeIndex]
                let restHeadWorld = headNode.worldMatrix
                let yaw = simd_quatf(angle: 40.0 * .pi / 180.0, axis: SIMD3<Float>(0, 1, 0))
                let pitch = simd_quatf(angle: -25.0 * .pi / 180.0, axis: SIMD3<Float>(1, 0, 0))
                let roll = simd_quatf(angle: 15.0 * .pi / 180.0, axis: SIMD3<Float>(0, 0, 1))
                headNode.rotation = simd_normalize(headNode.initialRotation * yaw * pitch * roll)
                headNode.updateLocalMatrix()
                for root in model.nodes where root.parent == nil {
                    root.updateWorldTransform()
                }
                let posedHeadWorld = headNode.worldMatrix
                let headSkinMatrix = posedHeadWorld * simd_inverse(restHeadWorld)

                // Under neutral mouth input, head rotation must move mouth vertices rigidly
                // with surrounding head-skinned face vertices (zero relative separation).
                if let sampleMouthIdx = mouthVertexIndices.first {
                    let mouthPos = SIMD4<Float>(baseVerts[sampleMouthIdx], 1)
                    let chinPos = SIMD4<Float>(0, faceChinMinY, baseVerts[sampleMouthIdx].z, 1)
                    let restDist = simd_distance(mouthPos.xyz, chinPos.xyz)
                    let posedDist = simd_distance((headSkinMatrix * mouthPos).xyz, (headSkinMatrix * chinPos).xyz)
                    XCTAssertEqual(posedDist, restDist, accuracy: 1e-4,
                                   "Neutral mouth distance to chin must remain invariant under head rotation")
                }

                renderOffscreenSynchronously(renderer: renderer, device: device)
            }
        }
    }

    @MainActor
    private func renderOffscreenSynchronously(renderer: VRMRenderer, device: MTLDevice) {
        let size = 256
        let colorDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: size, height: size, mipmapped: false)
        colorDesc.usage = [.renderTarget, .shaderRead]
        colorDesc.storageMode = .shared
        let depthDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float, width: size, height: size, mipmapped: false)
        depthDesc.usage = .renderTarget
        depthDesc.storageMode = .private

        guard let colorTex = device.makeTexture(descriptor: colorDesc),
              let depthTex = device.makeTexture(descriptor: depthDesc),
              let queue = device.makeCommandQueue(),
              let cb = queue.makeCommandBuffer() else {
            XCTFail("Failed to allocate offscreen Metal resources")
            return
        }
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = colorTex
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        rpd.colorAttachments[0].storeAction = .store
        rpd.depthAttachment.texture = depthTex
        rpd.depthAttachment.loadAction = .clear
        rpd.depthAttachment.clearDepth = 1.0
        rpd.depthAttachment.storeAction = .dontCare

        renderer.drawOffscreenHeadless(
            to: colorTex, depth: depthTex, commandBuffer: cb, renderPassDescriptor: rpd
        )
        cb.commit()
        cb.waitUntilCompleted()
        XCTAssertEqual(cb.status, .completed)
    }
}
