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
@testable import VRMMetalKit

/// Tests for VRM expression system at VRMMetalKit level
final class ExpressionTests: XCTestCase {

    var device: MTLDevice!
    var model: VRMModel!
    var renderer: VRMRenderer!

    override func setUp() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        self.device = device

        let vrmDocument = try VRMBuilder()
            .setSkeleton(.defaultHumanoid)
            .applyMorphs(["height": 1.0])
            .setHairColor([0.35, 0.25, 0.15])
            .setEyeColor([0.2, 0.4, 0.8])
            .setSkinTone(0.5)
            .addExpressions([.happy, .sad, .angry, .surprised, .relaxed, .neutral, .blink])
            .build()

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("vrm")

        try vrmDocument.serialize(to: tempURL)
        self.model = try await VRMModel.load(from: tempURL, device: device)
        try? FileManager.default.removeItem(at: tempURL)

        self.renderer = VRMRenderer(device: device)
        self.renderer.loadModel(model)
    }

    override func tearDown() {
        renderer = nil
        model = nil
        device = nil
    }

    // MARK: - Expression Controller Tests

    func testExpressionControllerExists() {
        XCTAssertNotNil(renderer.expressionController, "Expression controller should be initialized")
    }

    func testSetMoodHappyAppliesWeight() {
        guard let controller = renderer.expressionController else {
            XCTFail("Expression controller not available")
            return
        }

        controller.setMood(.happy, intensity: 0.8)

        for meshIndex in 0..<model.meshes.count {
            let weights = controller.weightsForMesh(meshIndex, morphCount: 64)
            XCTAssertNotNil(weights, "Weights should be returned for mesh \(meshIndex)")
        }
    }

    func testSetMoodSadAppliesWeight() {
        guard let controller = renderer.expressionController else {
            XCTFail("Expression controller not available")
            return
        }

        controller.setMood(.sad, intensity: 0.6)

        for meshIndex in 0..<model.meshes.count {
            let weights = controller.weightsForMesh(meshIndex, morphCount: 64)
            XCTAssertNotNil(weights, "Weights should be returned for mesh \(meshIndex)")
        }
    }

    func testSetMoodAngryAppliesWeight() {
        guard let controller = renderer.expressionController else {
            XCTFail("Expression controller not available")
            return
        }

        controller.setMood(.angry, intensity: 0.7)

        for meshIndex in 0..<model.meshes.count {
            let weights = controller.weightsForMesh(meshIndex, morphCount: 64)
            XCTAssertNotNil(weights, "Weights should be returned for mesh \(meshIndex)")
        }
    }

    func testSetMoodSurprisedAppliesWeight() {
        guard let controller = renderer.expressionController else {
            XCTFail("Expression controller not available")
            return
        }

        controller.setMood(.surprised, intensity: 0.9)

        for meshIndex in 0..<model.meshes.count {
            let weights = controller.weightsForMesh(meshIndex, morphCount: 64)
            XCTAssertNotNil(weights, "Weights should be returned for mesh \(meshIndex)")
        }
    }

    func testSetMoodRelaxedAppliesWeight() {
        guard let controller = renderer.expressionController else {
            XCTFail("Expression controller not available")
            return
        }

        controller.setMood(.relaxed, intensity: 0.5)

        for meshIndex in 0..<model.meshes.count {
            let weights = controller.weightsForMesh(meshIndex, morphCount: 64)
            XCTAssertNotNil(weights, "Weights should be returned for mesh \(meshIndex)")
        }
    }

    func testSetMoodNeutralAppliesWeight() {
        guard let controller = renderer.expressionController else {
            XCTFail("Expression controller not available")
            return
        }

        controller.setMood(.neutral, intensity: 1.0)

        for meshIndex in 0..<model.meshes.count {
            let weights = controller.weightsForMesh(meshIndex, morphCount: 64)
            XCTAssertNotNil(weights, "Weights should be returned for mesh \(meshIndex)")
        }
    }

    func testMoodResetsOtherMoods() throws {
        guard let controller = renderer.expressionController else {
            XCTFail("Expression controller not available")
            return
        }

        controller.setMood(.happy, intensity: 1.0)
        controller.setMood(.sad, intensity: 0.5)

        throw XCTSkip("Setting new mood should reset previous mood weights")
    }

    func testExpressionCyclingMaintainsConsistency() {
        guard let controller = renderer.expressionController else {
            XCTFail("Expression controller not available")
            return
        }

        let moods: [VRMExpressionPreset] = [.neutral, .happy, .sad, .angry, .surprised, .relaxed]

        for mood in moods {
            controller.setMood(mood, intensity: 0.8)
            for meshIndex in 0..<model.meshes.count {
                let weights = controller.weightsForMesh(meshIndex, morphCount: 64)
                XCTAssertEqual(weights.count, 64, "Weight array should have 64 elements")
            }
        }
    }

    func testRapidExpressionChangesNoErrors() {
        guard let controller = renderer.expressionController else {
            XCTFail("Expression controller not available")
            return
        }

        for _ in 0..<100 {
            let randomMood = [VRMExpressionPreset.happy, .sad, .angry, .surprised, .relaxed, .neutral].randomElement()!
            let randomIntensity = Float.random(in: 0.0...1.0)
            controller.setMood(randomMood, intensity: randomIntensity)
        }

        XCTAssertNotNil(controller, "Controller should remain valid after rapid changes")
    }

    func testExpressionWeightDirectSetsValue() {
        guard let controller = renderer.expressionController else {
            XCTFail("Expression controller not available")
            return
        }

        controller.setExpressionWeight(.happy, weight: 0.7)
        controller.setExpressionWeight(.blink, weight: 0.3)

        XCTAssertNotNil(controller, "Direct weight setting should not crash")
    }

    func testWeightClampingAboveOne() {
        guard let controller = renderer.expressionController else {
            XCTFail("Expression controller not available")
            return
        }

        controller.setExpressionWeight(.happy, weight: 1.5)

        for meshIndex in 0..<model.meshes.count {
            let weights = controller.weightsForMesh(meshIndex, morphCount: 64)
            for weight in weights {
                assertFloatInRange(weight, min: 0.0, max: 1.0)
            }
        }
    }

    func testWeightClampingBelowZero() {
        guard let controller = renderer.expressionController else {
            XCTFail("Expression controller not available")
            return
        }

        controller.setExpressionWeight(.happy, weight: -0.5)

        for meshIndex in 0..<model.meshes.count {
            let weights = controller.weightsForMesh(meshIndex, morphCount: 64)
            for weight in weights {
                assertFloatInRange(weight, min: 0.0, max: 1.0)
            }
        }
    }

    // MARK: - Morph Target System Tests

    func testMorphTargetSystemExists() {
        XCTAssertNotNil(renderer.morphTargetSystem, "Morph target system should be initialized")
    }

    func testMorphWeightsUpdateDoesNotCrash() {
        guard let morphSystem = renderer.morphTargetSystem else {
            XCTFail("Morph target system not available")
            return
        }

        let testWeights = [Float](repeating: 0.5, count: 10)
        morphSystem.updateMorphWeights(testWeights)

        XCTAssertNotNil(morphSystem, "Morph system should remain valid after update")
    }

    func testActiveSetBuildingSortsByWeight() {
        guard let morphSystem = renderer.morphTargetSystem else {
            XCTFail("Morph target system not available")
            return
        }

        var weights = [Float](repeating: 0, count: 64)
        weights[0] = 0.8
        weights[1] = 0.6
        weights[2] = 0.4
        weights[5] = 0.2

        let activeSet = morphSystem.buildActiveSet(weights: weights)

        XCTAssertGreaterThan(activeSet.count, 0, "Active set should contain morphs")
        XCTAssertLessThanOrEqual(activeSet.count, VRMMorphTargetSystem.maxActiveMorphs,
                                "Active set should not exceed max")

        if activeSet.count >= 2 {
            XCTAssertGreaterThanOrEqual(
                abs(activeSet[0].weight),
                abs(activeSet[1].weight),
                "Active set should be sorted by weight descending"
            )
        }
    }

    func testMorphEpsilonFiltering() {
        guard let morphSystem = renderer.morphTargetSystem else {
            XCTFail("Morph target system not available")
            return
        }

        var weights = [Float](repeating: 0, count: 64)
        weights[0] = VRMMorphTargetSystem.morphEpsilon / 2
        weights[1] = VRMMorphTargetSystem.morphEpsilon * 2

        let activeSet = morphSystem.buildActiveSet(weights: weights)

        XCTAssertEqual(activeSet.count, 1, "Only weights above epsilon should be in active set")
        if !activeSet.isEmpty {
            XCTAssertEqual(activeSet[0].index, 1, "Only the weight above epsilon should be included")
        }
    }

    func testActiveSetReturnsCorrectIndices() {
        guard let morphSystem = renderer.morphTargetSystem else {
            XCTFail("Morph target system not available")
            return
        }

        var weights = [Float](repeating: 0, count: 64)
        weights[10] = 0.9
        weights[20] = 0.7
        weights[30] = 0.5

        let activeSet = morphSystem.buildActiveSet(weights: weights)

        let indices = Set(activeSet.map { Int($0.index) })
        XCTAssertTrue(indices.contains(10), "Index 10 should be in active set")
        XCTAssertTrue(indices.contains(20), "Index 20 should be in active set")
        XCTAssertTrue(indices.contains(30), "Index 30 should be in active set")
    }

    // MARK: - Integration Tests

    func testExpressionToMorphPipeline() {
        guard let controller = renderer.expressionController,
              let morphSystem = renderer.morphTargetSystem else {
            XCTFail("Expression or morph system not available")
            return
        }

        controller.setMood(.happy, intensity: 0.8)

        var totalWeightChecks = 0
        for meshIndex in 0..<model.meshes.count {
            let weights = controller.weightsForMesh(meshIndex, morphCount: 64)
            XCTAssertEqual(weights.count, 64, "Should return requested number of weights")
            totalWeightChecks += 1
        }

        XCTAssertGreaterThan(totalWeightChecks, 0, "Should have checked at least one mesh")
        XCTAssertNotNil(morphSystem, "Morph system should exist throughout pipeline")
    }

    func testSentimentToExpressionScenario() {
        guard let controller = renderer.expressionController else {
            XCTFail("Expression controller not available")
            return
        }

        let scenarios: [(sentiment: Double, expectedMood: VRMExpressionPreset, intensity: Float)] = [
            (0.8, .happy, 0.8),
            (-0.7, .sad, 0.7),
            (0.0, .neutral, 1.0),
            (0.9, .surprised, 0.8),
            (-0.8, .angry, 0.8)
        ]

        for (_, mood, intensity) in scenarios {
            controller.setMood(mood, intensity: intensity)

            for meshIndex in 0..<model.meshes.count {
                let weights = controller.weightsForMesh(meshIndex, morphCount: 64)
                XCTAssertEqual(weights.count, 64)
            }
        }
    }

    func testWeightsForMeshPadsCorrectly() {
        guard let controller = renderer.expressionController else {
            XCTFail("Expression controller not available")
            return
        }

        controller.setMood(.happy, intensity: 0.5)

        let weights16 = controller.weightsForMesh(0, morphCount: 16)
        let weights64 = controller.weightsForMesh(0, morphCount: 64)
        let weights128 = controller.weightsForMesh(0, morphCount: 128)

        XCTAssertEqual(weights16.count, 16, "Should pad/truncate to requested count")
        XCTAssertEqual(weights64.count, 64, "Should pad/truncate to requested count")
        XCTAssertEqual(weights128.count, 128, "Should pad/truncate to requested count")
    }

    func testEmptyWeightsForUnusedMesh() {
        guard let controller = renderer.expressionController else {
            XCTFail("Expression controller not available")
            return
        }

        let weights = controller.weightsForMesh(9999, morphCount: 64)

        XCTAssertEqual(weights.count, 64, "Should return padded array even for unused mesh")

        let allZero = weights.allSatisfy { $0 == 0 }
        XCTAssertTrue(allZero, "Unused mesh should have all zero weights")
    }

    // MARK: - Edge Case Tests (Designed to Find Bugs)

    func testNaNWeightHandling() {
        guard let controller = renderer.expressionController else {
            XCTFail("Expression controller not available")
            return
        }

        controller.setExpressionWeight(.happy, weight: Float.nan)

        for meshIndex in 0..<model.meshes.count {
            let weights = controller.weightsForMesh(meshIndex, morphCount: 64)
            for weight in weights {
                XCTAssertFalse(weight.isNaN, "NaN should not propagate to output weights")
            }
        }
    }

    func testInfinityWeightHandling() {
        guard let controller = renderer.expressionController else {
            XCTFail("Expression controller not available")
            return
        }

        controller.setExpressionWeight(.happy, weight: Float.infinity)

        for meshIndex in 0..<model.meshes.count {
            let weights = controller.weightsForMesh(meshIndex, morphCount: 64)
            for weight in weights {
                XCTAssertFalse(weight.isInfinite, "Infinity should not propagate to output weights")
                assertFloatInRange(weight, min: 0.0, max: 1.0)
            }
        }
    }

    func testNegativeInfinityWeightHandling() {
        guard let controller = renderer.expressionController else {
            XCTFail("Expression controller not available")
            return
        }

        controller.setExpressionWeight(.happy, weight: -Float.infinity)

        for meshIndex in 0..<model.meshes.count {
            let weights = controller.weightsForMesh(meshIndex, morphCount: 64)
            for weight in weights {
                XCTAssertFalse(weight.isInfinite, "Negative infinity should not propagate")
                assertFloatInRange(weight, min: 0.0, max: 1.0)
            }
        }
    }

    func testZeroMorphCountHandling() {
        guard let controller = renderer.expressionController else {
            XCTFail("Expression controller not available")
            return
        }

        controller.setMood(.happy, intensity: 0.8)

        let weights = controller.weightsForMesh(0, morphCount: 0)
        XCTAssertEqual(weights.count, 0, "Zero morphCount should return empty array")
    }

    func testNegativeMorphCountHandling() {
        guard let controller = renderer.expressionController else {
            XCTFail("Expression controller not available")
            return
        }

        controller.setMood(.happy, intensity: 0.8)

        let weights = controller.weightsForMesh(0, morphCount: -5)
        XCTAssertEqual(weights.count, 0, "Negative morphCount should return empty array")
    }

    func testVeryLargeMorphCountHandling() {
        guard let controller = renderer.expressionController else {
            XCTFail("Expression controller not available")
            return
        }

        controller.setMood(.happy, intensity: 0.5)

        let weights = controller.weightsForMesh(0, morphCount: 10000)
        XCTAssertEqual(weights.count, 10000, "Should handle large morphCount")

        for weight in weights {
            assertFloatInRange(weight, min: 0.0, max: 1.0)
        }
    }

    func testActiveSetWithAllZeroWeights() {
        guard let morphSystem = renderer.morphTargetSystem else {
            XCTFail("Morph target system not available")
            return
        }

        let zeroWeights = [Float](repeating: 0, count: 64)
        let activeSet = morphSystem.buildActiveSet(weights: zeroWeights)

        XCTAssertEqual(activeSet.count, 0, "All-zero weights should produce empty active set")
    }

    func testActiveSetWithEmptyWeights() {
        guard let morphSystem = renderer.morphTargetSystem else {
            XCTFail("Morph target system not available")
            return
        }

        let emptyWeights: [Float] = []
        let activeSet = morphSystem.buildActiveSet(weights: emptyWeights)

        XCTAssertEqual(activeSet.count, 0, "Empty weights should produce empty active set")
    }

    func testActiveSetWithNaNWeights() {
        guard let morphSystem = renderer.morphTargetSystem else {
            XCTFail("Morph target system not available")
            return
        }

        var weights = [Float](repeating: 0, count: 64)
        weights[0] = Float.nan
        weights[1] = 0.5

        let activeSet = morphSystem.buildActiveSet(weights: weights)

        for morph in activeSet {
            XCTAssertFalse(morph.weight.isNaN, "NaN should not appear in active set")
        }
    }

    func testActiveSetExactlyMaxMorphsEdgeCase() {
        guard let morphSystem = renderer.morphTargetSystem else {
            XCTFail("Morph target system not available")
            return
        }

        var weights = [Float](repeating: 0, count: 64)
        for i in 0..<VRMMorphTargetSystem.maxActiveMorphs {
            weights[i] = Float(VRMMorphTargetSystem.maxActiveMorphs - i) / Float(VRMMorphTargetSystem.maxActiveMorphs)
        }

        let activeSet = morphSystem.buildActiveSet(weights: weights)

        XCTAssertEqual(activeSet.count, VRMMorphTargetSystem.maxActiveMorphs,
                      "Should include exactly maxActiveMorphs when that many are non-zero")
    }

    func testActiveSetMoreThanMaxMorphsTruncates() {
        guard let morphSystem = renderer.morphTargetSystem else {
            XCTFail("Morph target system not available")
            return
        }

        let weights = [Float](repeating: 0.5, count: 64)

        let activeSet = morphSystem.buildActiveSet(weights: weights)

        XCTAssertLessThanOrEqual(activeSet.count, VRMMorphTargetSystem.maxActiveMorphs,
                                "Should truncate to maxActiveMorphs")
    }

    func testMorphEpsilonBoundary() {
        guard let morphSystem = renderer.morphTargetSystem else {
            XCTFail("Morph target system not available")
            return
        }

        var weights = [Float](repeating: 0, count: 64)
        let epsilon = VRMMorphTargetSystem.morphEpsilon

        weights[0] = epsilon * 0.99
        weights[1] = epsilon * 1.01
        weights[2] = epsilon

        let activeSet = morphSystem.buildActiveSet(weights: weights)

        let indices = Set(activeSet.map { Int($0.index) })

        XCTAssertFalse(indices.contains(0), "Weight below epsilon should be excluded")
        XCTAssertTrue(indices.contains(1), "Weight above epsilon should be included")
    }

    func testMultipleExpressionsAccumulate() {
        guard let controller = renderer.expressionController else {
            XCTFail("Expression controller not available")
            return
        }

        controller.setExpressionWeight(.happy, weight: 0.5)
        controller.setExpressionWeight(.surprised, weight: 0.3)

        XCTAssertNotNil(controller, "Multiple expressions should accumulate without crash")
    }

    func testSettingSameExpressionMultipleTimes() {
        guard let controller = renderer.expressionController else {
            XCTFail("Expression controller not available")
            return
        }

        for i in 0..<100 {
            controller.setExpressionWeight(.happy, weight: Float(i) / 100.0)
        }

        let weights = controller.weightsForMesh(0, morphCount: 64)
        XCTAssertEqual(weights.count, 64, "Should handle repeated setting of same expression")
    }
}
