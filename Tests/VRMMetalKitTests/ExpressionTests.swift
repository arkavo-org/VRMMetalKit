import XCTest
import Metal
@testable import VRMMetalKit

/// Tests for VRM expression system at VRMMetalKit level
final class ExpressionTests: XCTestCase {

    var device: MTLDevice!
    var model: VRMModel!
    var renderer: VRMRenderer!

    override func setUp() async throws {
        // Get Metal device
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        self.device = device

        // Load AliciaSolid.vrm
        let testModelPath = "/Users/paul/Projects/GameOfMods/Resources/vrm/AliciaSolid.vrm"
        guard FileManager.default.fileExists(atPath: testModelPath) else {
            throw XCTSkip("Test model not found at \(testModelPath)")
        }

        let modelURL = URL(fileURLWithPath: testModelPath)
        self.model = try await VRMModel.load(from: modelURL, device: device)

        // Create renderer
        self.renderer = VRMRenderer(device: device)
        self.renderer.loadModel(model)

        print("✅ Test setup complete: model loaded, renderer initialized")
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

    func testSetMoodHappy() {
        guard let controller = renderer.expressionController else {
            XCTFail("Expression controller not available")
            return
        }

        // Set happy mood
        controller.setMood(.happy, intensity: 0.8)

        print("✅ Set happy mood @ 0.8 intensity")
        // No crash = success at VRMMetalKit level
    }

    func testSetMoodSad() {
        guard let controller = renderer.expressionController else {
            XCTFail("Expression controller not available")
            return
        }

        // Set sad mood
        controller.setMood(.sad, intensity: 0.6)

        print("✅ Set sad mood @ 0.6 intensity")
    }

    func testSetMoodAngry() {
        guard let controller = renderer.expressionController else {
            XCTFail("Expression controller not available")
            return
        }

        // Set angry mood
        controller.setMood(.angry, intensity: 0.7)

        print("✅ Set angry mood @ 0.7 intensity")
    }

    func testSetMoodSurprised() {
        guard let controller = renderer.expressionController else {
            XCTFail("Expression controller not available")
            return
        }

        // Set surprised mood
        controller.setMood(.surprised, intensity: 0.9)

        print("✅ Set surprised mood @ 0.9 intensity")
    }

    func testSetMoodRelaxed() {
        guard let controller = renderer.expressionController else {
            XCTFail("Expression controller not available")
            return
        }

        // Set relaxed mood
        controller.setMood(.relaxed, intensity: 0.5)

        print("✅ Set relaxed mood @ 0.5 intensity")
    }

    func testSetMoodNeutral() {
        guard let controller = renderer.expressionController else {
            XCTFail("Expression controller not available")
            return
        }

        // Set neutral mood
        controller.setMood(.neutral, intensity: 1.0)

        print("✅ Set neutral mood @ 1.0 intensity")
    }

    func testExpressionCycling() {
        guard let controller = renderer.expressionController else {
            XCTFail("Expression controller not available")
            return
        }

        // Cycle through all moods
        let moods: [VRMExpressionPreset] = [.neutral, .happy, .sad, .angry, .surprised, .relaxed]

        for mood in moods {
            controller.setMood(mood, intensity: 0.8)
            print("  → Set \(mood.rawValue) @ 0.8")
        }

        print("✅ Cycled through all moods successfully")
    }

    func testRapidExpressionChanges() {
        guard let controller = renderer.expressionController else {
            XCTFail("Expression controller not available")
            return
        }

        // Rapid changes to test stability
        for _ in 0..<100 {
            let randomMood = [VRMExpressionPreset.happy, .sad, .angry, .surprised, .relaxed, .neutral].randomElement()!
            let randomIntensity = Float.random(in: 0.0...1.0)
            controller.setMood(randomMood, intensity: randomIntensity)
        }

        print("✅ 100 rapid expression changes completed")
    }

    func testExpressionWeightDirect() {
        guard let controller = renderer.expressionController else {
            XCTFail("Expression controller not available")
            return
        }

        // Test direct weight setting
        controller.setExpressionWeight(.happy, weight: 0.7)
        controller.setExpressionWeight(.blink, weight: 0.3)

        print("✅ Set expression weights directly")
    }

    func testMorphTargetSystemExists() {
        XCTAssertNotNil(renderer.morphTargetSystem, "Morph target system should be initialized")
    }

    func testMorphWeightsUpdate() {
        guard let morphSystem = renderer.morphTargetSystem else {
            XCTFail("Morph target system not available")
            return
        }

        // Create test weights
        let testWeights = [Float](repeating: 0.5, count: 10)
        morphSystem.updateMorphWeights(testWeights)

        print("✅ Updated morph weights")
    }

    func testActiveSetBuilding() {
        guard let morphSystem = renderer.morphTargetSystem else {
            XCTFail("Morph target system not available")
            return
        }

        // Build active set from weights
        var weights = [Float](repeating: 0, count: 64)
        weights[0] = 0.8
        weights[1] = 0.6
        weights[2] = 0.4
        weights[5] = 0.2

        let activeSet = morphSystem.buildActiveSet(weights: weights)

        XCTAssertGreaterThan(activeSet.count, 0, "Active set should contain morphs")
        XCTAssertLessThanOrEqual(activeSet.count, VRMMorphTargetSystem.maxActiveMorphs,
                                "Active set should not exceed max")

        print("✅ Built active set with \(activeSet.count) morphs")
    }

    // MARK: - Integration Tests

    func testExpressionToMorphPipeline() {
        guard let controller = renderer.expressionController,
              let morphSystem = renderer.morphTargetSystem else {
            XCTFail("Expression or morph system not available")
            return
        }

        // Check what expressions are actually available
        print("  Model expressions:")
        if let expressions = model.expressions {
            print("    Preset expressions: \(expressions.preset.keys.map { $0.rawValue })")
            print("    Custom expressions: \(expressions.custom.keys)")
        } else {
            print("    ⚠️  No expressions found in model!")
        }

        // Set expression
        controller.setMood(.happy, intensity: 0.8)

        // Check mesh-level weights
        for meshIndex in 0..<(model.meshes.count) {
            let weights = controller.weightsForMesh(meshIndex, morphCount: 64)
            let nonZero = weights.enumerated().filter { $0.element > 0.001 }
            if !nonZero.isEmpty {
                print("    Mesh \(meshIndex): \(nonZero.count) active morphs: \(nonZero.map { "[\($0.offset)]=\(String(format: "%.3f", $0.element))" }.joined(separator: ", "))")
            }
        }

        // Verify the expression → morph pipeline works
        // Note: GPU buffer only gets updated during draw() call, not immediately
        // So we check the mesh-level weights which are updated immediately
        var totalNonZeroMorphs = 0
        for meshIndex in 0..<model.meshes.count {
            let weights = controller.weightsForMesh(meshIndex, morphCount: 64)
            let nonZero = weights.filter { $0 > 0.001 }
            totalNonZeroMorphs += nonZero.count
        }

        XCTAssertGreaterThan(totalNonZeroMorphs, 0, "Expression should activate morph targets")
        print("✅ Expression pipeline working: \(totalNonZeroMorphs) total active morphs across all meshes")
    }

    func testSentimentToExpressionScenario() {
        guard let controller = renderer.expressionController else {
            XCTFail("Expression controller not available")
            return
        }

        // Simulate the sentiment → expression flow from Muse
        let scenarios: [(sentiment: Double, expectedMood: VRMExpressionPreset, intensity: Float)] = [
            (0.8, .happy, 0.8),      // Positive sentiment
            (-0.7, .sad, 0.7),        // Negative sentiment
            (0.0, .neutral, 1.0),     // Neutral sentiment
            (0.9, .surprised, 0.8),   // Very positive (with context clue)
            (-0.8, .angry, 0.8)       // Very negative (with anger context)
        ]

        for (sentiment, mood, intensity) in scenarios {
            controller.setMood(mood, intensity: intensity)
            print("  → Sentiment \(sentiment) → \(mood.rawValue) @ \(intensity)")
        }

        print("✅ Sentiment → expression scenarios completed")
    }
}
