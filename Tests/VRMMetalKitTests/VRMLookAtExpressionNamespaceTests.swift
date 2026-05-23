//
// Copyright 2025 Arkavo
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//

import XCTest
import simd
@testable import VRMMetalKit

/// VMK#297 — `VRMLookAtController.applyToExpressions` historically only
/// wrote to the custom-namespace PascalCase `"LookLeft"`/`"LookRight"`/
/// `"LookUp"`/`"LookDown"`, but the VRM 1.0 spec defines these as
/// **preset** expressions (`expressions.preset.lookLeft`, lowercase).
/// Spec-compliant VRM 1.0 assets with `lookAt.type = expression` and
/// preset look-direction binds would render with no gaze deviation
/// because the controller's writes landed in an orphan custom name.
///
/// These tests cover both namespaces — the spec-compliant preset path
/// (which was broken pre-#297) and the legacy custom path that VRM 0.x
/// assets continue to depend on through the
/// `VRMExtensionParser.mapVRM0PresetToVRM1` mapping.
final class VRMLookAtExpressionNamespaceTests: XCTestCase {

    private func makeMinimalGLTF() -> GLTFDocument {
        let json: [String: Any] = ["asset": ["version": "2.0", "generator": "Test"]]
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(GLTFDocument.self, from: data)
    }

    private func makeGLTFNode(name: String) throws -> GLTFNode {
        let json: [String: Any] = ["name": name]
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode(GLTFNode.self, from: data)
    }

    /// Builds an expression-mode rig with `expressions.preset[.lookLeft]`
    /// etc. populated (spec-compliant VRM 1.0 path). Each preset
    /// expression carries a non-empty morphTargetBinds list so
    /// `setup()`'s "working expressions" detection passes.
    private func makePresetNamespaceRig() throws -> (model: VRMModel, controller: VRMLookAtController, expressions: VRMExpressionController) {
        let head = try VRMNode(index: 0, gltfNode: makeGLTFNode(name: "head"))

        let humanoid = VRMHumanoid()
        humanoid.humanBones[.head] = VRMHumanoid.VRMHumanBone(node: 0)

        let model = VRMModel(
            specVersion: .v1_0,
            meta: VRMMeta(licenseUrl: ""),
            humanoid: humanoid,
            gltf: makeMinimalGLTF()
        )
        model.nodes = [head]
        model.lookAt = VRMLookAt()
        model.lookAt?.type = .expression

        // Spec-compliant: lookLeft/lookRight/lookUp/lookDown are PRESET
        // expressions. Authored binds aren't actually consumed by the
        // controller — they're inspected by setup() to detect that
        // expression mode has working targets.
        let modelExpressions = VRMExpressions()
        for preset in [VRMExpressionPreset.lookLeft, .lookRight, .lookUp, .lookDown] {
            var expr = VRMExpression(preset: preset)
            expr.morphTargetBinds = [VRMMorphTargetBind(node: 0, index: 0, weight: 1.0)]
            modelExpressions.preset[preset] = expr
        }
        model.expressions = modelExpressions

        let expressionController = VRMExpressionController()
        // Register the same presets on the controller so the apply path
        // has somewhere to write.
        for preset in [VRMExpressionPreset.lookLeft, .lookRight, .lookUp, .lookDown] {
            expressionController.registerExpression(VRMExpression(preset: preset), for: preset)
        }

        let controller = VRMLookAtController()
        controller.smoothing = 0
        controller.saccadeEnabled = false
        controller.setup(model: model, expressionController: expressionController)
        controller.mode = .expression

        return (model, controller, expressionController)
    }

    /// Builds a VRM 0.x legacy rig with custom-namespace `"LookLeft"`
    /// etc. (PascalCase) — the namespace the broken
    /// `mapVRM0PresetToVRM1` puts VRM 0.x BlendShapeGroups in. Authored
    /// binds populate `expressions.custom["LookLeft"]`.
    private func makeCustomNamespaceLegacyRig() throws -> (model: VRMModel, controller: VRMLookAtController, expressions: VRMExpressionController) {
        let head = try VRMNode(index: 0, gltfNode: makeGLTFNode(name: "head"))

        let humanoid = VRMHumanoid()
        humanoid.humanBones[.head] = VRMHumanoid.VRMHumanBone(node: 0)

        let model = VRMModel(
            specVersion: .v0_0,
            meta: VRMMeta(licenseUrl: ""),
            humanoid: humanoid,
            gltf: makeMinimalGLTF()
        )
        model.nodes = [head]
        model.lookAt = VRMLookAt()
        model.lookAt?.type = .expression

        let modelExpressions = VRMExpressions()
        for name in ["LookLeft", "LookRight", "LookUp", "LookDown"] {
            var expr = VRMExpression(name: name)
            expr.morphTargetBinds = [VRMMorphTargetBind(node: 0, index: 0, weight: 1.0)]
            modelExpressions.custom[name] = expr
        }
        model.expressions = modelExpressions

        let expressionController = VRMExpressionController()
        for name in ["LookLeft", "LookRight", "LookUp", "LookDown"] {
            expressionController.registerCustomExpression(VRMExpression(name: name), name: name)
        }

        let controller = VRMLookAtController()
        controller.smoothing = 0
        controller.saccadeEnabled = false
        controller.setup(model: model, expressionController: expressionController)
        controller.mode = .expression

        return (model, controller, expressionController)
    }

    // MARK: - Apply path

    /// VMK#297 — spec path: with `expressions.preset[.lookRight]`
    /// populated (and no custom-namespace entry), driving the gaze
    /// rightward must produce a non-zero weight on the preset enum.
    /// Pre-fix the controller wrote to `setCustomExpressionWeight("LookRight", …)`
    /// which is a no-op on an unregistered custom name, so this assertion
    /// fails.
    func testApplyToExpressionsWritesPresetLookRightForRightwardGaze() throws {
        let rig = try makePresetNamespaceRig()

        // Head is at origin; point gaze to the right of the head.
        rig.controller.target = .point(SIMD3<Float>(1, 0, 0))
        rig.controller.update(deltaTime: 1.0 / 60.0)

        let lookRight = rig.expressions.weight(for: .lookRight)
        XCTAssertGreaterThan(lookRight, 0,
            "VMK#297: expressions.preset[.lookRight] weight must be > 0 after a " +
            "rightward gaze update on a spec-compliant VRM 1.0 rig. Got \(lookRight). " +
            "Zero means the controller is writing to the custom namespace " +
            "(`setCustomExpressionWeight(\"LookRight\", …)`) instead of the preset " +
            "namespace (`setExpressionWeight(.lookRight, …)`).")

        // Sanity: the other three axes should be zero or near-zero.
        XCTAssertEqual(rig.expressions.weight(for: .lookLeft), 0, accuracy: 1e-6)
        XCTAssertEqual(rig.expressions.weight(for: .lookUp), 0, accuracy: 1e-6)
        XCTAssertEqual(rig.expressions.weight(for: .lookDown), 0, accuracy: 1e-6)
    }

    /// VMK#297 — same axis coverage for the remaining three direction
    /// presets so a one-sided fix doesn't pass the suite.
    func testApplyToExpressionsWritesPresetLookLeftLookUpLookDown() throws {
        let cases: [(target: SIMD3<Float>, preset: VRMExpressionPreset)] = [
            (SIMD3<Float>(-1, 0, 0), .lookLeft),
            (SIMD3<Float>(0,  1, 0), .lookUp),
            (SIMD3<Float>(0, -1, 0), .lookDown),
        ]
        for (target, preset) in cases {
            let rig = try makePresetNamespaceRig()
            rig.controller.target = .point(target)
            rig.controller.update(deltaTime: 1.0 / 60.0)

            let weight = rig.expressions.weight(for: preset)
            XCTAssertGreaterThan(weight, 0,
                "VMK#297: gaze toward \(target) must drive preset .\(preset) " +
                "weight > 0. Got \(weight) — controller is still writing to the " +
                "custom namespace instead of the preset enum.")
        }
    }

    /// Regression-guard for the VRM 0.x legacy path: assets whose
    /// expressions live in `custom["LookRight"]` (because the pre-#297
    /// `mapVRM0PresetToVRM1` didn't recognise the look-direction names)
    /// must continue to be driven correctly. The fix writes to both
    /// namespaces, so this assertion passes today AND after the fix.
    func testApplyToExpressionsWritesCustomLookRightLegacyPath() throws {
        let rig = try makeCustomNamespaceLegacyRig()

        rig.controller.target = .point(SIMD3<Float>(1, 0, 0))
        rig.controller.update(deltaTime: 1.0 / 60.0)

        let lookRight = rig.expressions.weight(forCustom: "LookRight") ?? 0
        XCTAssertGreaterThan(lookRight, 0,
            "VMK#297 regression guard: custom-namespace \"LookRight\" must " +
            "still be driven for VRM 0.x legacy assets that landed in the " +
            "custom namespace (the pre-fix path). Got \(lookRight).")
    }

    // MARK: - Setup-time detection

    /// VMK#297 — with preset look-direction expressions registered (and
    /// no custom entries), the controller's auto-detection at `setup`
    /// should pick `.expression` mode. Pre-fix the detection only checked
    /// `expressions.custom["LookLeft"]` and missed the preset entries.
    ///
    /// The fixture deliberately includes non-rigid eye bones and sets
    /// `lookAt.type = .bone` so that the existing fallback branches
    /// (`eyesAreRigid`, `type == .expression || no-eye-bones`) cannot
    /// carry the test — only the preset detection can produce
    /// `mode == .expression`.
    func testSetupDetectsExpressionModeForPresetNamespace() throws {
        let head = try VRMNode(index: 0, gltfNode: makeGLTFNode(name: "head"))
        let leftEye = try VRMNode(index: 1, gltfNode: makeGLTFNode(name: "leftEye"))
        let rightEye = try VRMNode(index: 2, gltfNode: makeGLTFNode(name: "rightEye"))

        let humanoid = VRMHumanoid()
        humanoid.humanBones[.head] = VRMHumanoid.VRMHumanBone(node: 0)
        humanoid.humanBones[.leftEye] = VRMHumanoid.VRMHumanBone(node: 1)
        humanoid.humanBones[.rightEye] = VRMHumanoid.VRMHumanBone(node: 2)

        let model = VRMModel(
            specVersion: .v1_0,
            meta: VRMMeta(licenseUrl: ""),
            humanoid: humanoid,
            gltf: makeMinimalGLTF()
        )
        model.nodes = [head, leftEye, rightEye]
        model.lookAt = VRMLookAt()
        model.lookAt?.type = .bone   // disables the type-based fallback

        let modelExpressions = VRMExpressions()
        for preset in [VRMExpressionPreset.lookLeft, .lookRight, .lookUp, .lookDown] {
            var expr = VRMExpression(preset: preset)
            expr.morphTargetBinds = [VRMMorphTargetBind(node: 0, index: 0, weight: 1.0)]
            modelExpressions.preset[preset] = expr
        }
        model.expressions = modelExpressions

        let expressionController = VRMExpressionController()
        for preset in [VRMExpressionPreset.lookLeft, .lookRight, .lookUp, .lookDown] {
            expressionController.registerExpression(VRMExpression(preset: preset), for: preset)
        }

        let controller = VRMLookAtController()
        controller.setup(model: model, expressionController: expressionController)

        XCTAssertEqual(controller.mode, .expression,
            "VMK#297: setup() must detect expression mode when preset " +
            "look-direction expressions are registered on " +
            "expressions.preset. Pre-fix the detection only looked at " +
            "expressions.custom[\"LookLeft\"] and missed the spec path.")
    }

    // MARK: - VRM 0.x BlendShapeGroup preset mapping

    /// VMK#297 — VRM 0.x `LookLeft`/`LookRight`/`LookUp`/`LookDown`
    /// BlendShapeGroups must land in `expressions.preset[.lookLeft]`
    /// etc., not in `expressions.custom["LookLeft"]`. Pre-fix
    /// `mapVRM0PresetToVRM1` had no entries for the four look-direction
    /// names, so they fell into the `else` branch and were stored as
    /// custom expressions.
    func testParserMapsVRM0LookDirectionsToPresetNamespace() throws {
        let parser = VRMExtensionParser()
        let vrmDict: [String: Any] = [
            "version": "0.0",
            "meta": ["title": "VMK297-test"],
            "humanoid": [
                "humanBones": [
                    ["bone": "hips", "node": 0],
                    ["bone": "leftUpperLeg", "node": 0],
                    ["bone": "rightUpperLeg", "node": 0],
                    ["bone": "leftLowerLeg", "node": 0],
                    ["bone": "rightLowerLeg", "node": 0],
                    ["bone": "leftFoot", "node": 0],
                    ["bone": "rightFoot", "node": 0],
                    ["bone": "spine", "node": 0],
                    ["bone": "head", "node": 0],
                    ["bone": "leftUpperArm", "node": 0],
                    ["bone": "rightUpperArm", "node": 0],
                    ["bone": "leftLowerArm", "node": 0],
                    ["bone": "rightLowerArm", "node": 0],
                    ["bone": "leftHand", "node": 0],
                    ["bone": "rightHand", "node": 0],
                ],
            ],
            "blendShapeMaster": [
                "blendShapeGroups": [
                    [
                        "name": "LookLeft",
                        "presetName": "LookLeft",
                        "binds": [
                            ["mesh": 0, "index": 0, "weight": 100.0],
                        ],
                    ],
                    [
                        "name": "LookRight",
                        "presetName": "LookRight",
                        "binds": [
                            ["mesh": 0, "index": 1, "weight": 100.0],
                        ],
                    ],
                    [
                        "name": "LookUp",
                        "presetName": "LookUp",
                        "binds": [
                            ["mesh": 0, "index": 2, "weight": 100.0],
                        ],
                    ],
                    [
                        "name": "LookDown",
                        "presetName": "LookDown",
                        "binds": [
                            ["mesh": 0, "index": 3, "weight": 100.0],
                        ],
                    ],
                ],
            ],
        ]
        let document = try JSONDecoder().decode(
            GLTFDocument.self,
            from: JSONSerialization.data(withJSONObject: ["asset": ["version": "2.0", "generator": "Test"]])
        )
        let model = try parser.parseVRMExtension(vrmDict, document: document)

        XCTAssertNotNil(model.expressions?.preset[.lookLeft],
            "VMK#297: VRM 0.x `LookLeft` BlendShapeGroup must map to expressions.preset[.lookLeft]")
        XCTAssertNotNil(model.expressions?.preset[.lookRight],
            "VMK#297: VRM 0.x `LookRight` BlendShapeGroup must map to expressions.preset[.lookRight]")
        XCTAssertNotNil(model.expressions?.preset[.lookUp],
            "VMK#297: VRM 0.x `LookUp` BlendShapeGroup must map to expressions.preset[.lookUp]")
        XCTAssertNotNil(model.expressions?.preset[.lookDown],
            "VMK#297: VRM 0.x `LookDown` BlendShapeGroup must map to expressions.preset[.lookDown]")
        // None of these should have leaked into the custom namespace.
        XCTAssertNil(model.expressions?.custom["LookLeft"],
            "VMK#297: post-fix, VRM 0.x `LookLeft` should NOT appear in expressions.custom")
    }
}
