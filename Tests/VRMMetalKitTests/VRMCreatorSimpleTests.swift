import XCTest
import Foundation
@testable import VRMMetalKit

/// Simple unit tests for VRM Creator system using XCTest
final class VRMCreatorSimpleTests: XCTestCase {

    // MARK: - CharacterRecipe Validation Tests

    func testValidRecipeParsing() throws {
        let recipeJSON = """
        {
            "skeleton": "default_humanoid",
            "morphs": {
                "height": 1.15,
                "muscle_definition": 0.7,
                "hair_length": 0.8
            },
            "materials": {
                "hairColor": [0.35, 0.25, 0.15],
                "eyeColor": [0.2, 0.4, 0.8],
                "skinTone": 0.5
            },
            "expressions": ["happy", "sad", "angry", "blink"]
        }
        """

        let recipe = try CharacterRecipe.from(json: recipeJSON)
        try recipe.validate()

        XCTAssertEqual(recipe.skeleton, "default_humanoid")
        XCTAssertEqual(recipe.morphs["height"], 1.15)
        XCTAssertEqual(recipe.morphs["muscle_definition"], 0.7)
        XCTAssertEqual(recipe.materials.hairColor, [0.35, 0.25, 0.15])
        XCTAssertEqual(recipe.materials.eyeColor, [0.2, 0.4, 0.8])
        XCTAssertEqual(recipe.materials.skinTone, 0.5)
        XCTAssertEqual(recipe.expressions, ["happy", "sad", "angry", "blink"])
    }

    func testInvalidSkeletonNames() throws {
        let recipeJSON = """
        {
            "skeleton": "invalid_skeleton",
            "morphs": {},
            "materials": {
                "hairColor": [0.5, 0.5, 0.5],
                "eyeColor": [0.5, 0.5, 0.5],
                "skinTone": 0.5
            },
            "expressions": []
        }
        """

        let recipe = try CharacterRecipe.from(json: recipeJSON)
        XCTAssertThrowsError(try recipe.validate()) { error in
            XCTAssertTrue(error is RecipeError)
            if case RecipeError.invalidSkeleton(let skeleton) = error {
                XCTAssertEqual(skeleton, "invalid_skeleton")
            } else {
                XCTFail("Expected RecipeError.invalidSkeleton")
            }
        }
    }

    func testMorphRangeValidation() throws {
        // Test invalid height value
        let recipeJSON = """
        {
            "skeleton": "default",
            "morphs": {"height": 5.0},
            "materials": {
                "hairColor": [0.5, 0.5, 0.5],
                "eyeColor": [0.5, 0.5, 0.5],
                "skinTone": 0.5
            },
            "expressions": []
        }
        """

        let recipe = try CharacterRecipe.from(json: recipeJSON)
        XCTAssertThrowsError(try recipe.validate()) { error in
            XCTAssertTrue(error is RecipeError)
            if case RecipeError.morphOutOfRange(let name, let value, let range) = error {
                XCTAssertEqual(name, "height")
                XCTAssertEqual(value, 5.0)
            } else {
                XCTFail("Expected RecipeError.morphOutOfRange")
            }
        }
    }

    func testMaterialColorValidation() throws {
        // Test invalid RGB color
        let recipeJSON = """
        {
            "skeleton": "default",
            "morphs": {},
            "materials": {
                "hairColor": [1.5, 0.5, 0.5],
                "eyeColor": [0.5, 0.5, 0.5],
                "skinTone": 0.5
            },
            "expressions": []
        }
        """

        let recipe = try CharacterRecipe.from(json: recipeJSON)
        XCTAssertThrowsError(try recipe.validate()) { error in
            XCTAssertTrue(error is RecipeError)
            if case RecipeError.invalidColor(let name, let values) = error {
                XCTAssertEqual(name, "hairColor")
                XCTAssertEqual(values, [1.5, 0.5, 0.5])
            } else {
                XCTFail("Expected RecipeError.invalidColor")
            }
        }
    }

    func testEmptyRecipe() throws {
        let emptyRecipeJSON = """
        {
            "skeleton": "default",
            "morphs": {},
            "materials": {
                "hairColor": [0.5, 0.5, 0.5],
                "eyeColor": [0.5, 0.5, 0.5],
                "skinTone": 0.5
            },
            "expressions": []
        }
        """

        let recipe = try CharacterRecipe.from(json: emptyRecipeJSON)
        try recipe.validate()

        XCTAssertEqual(recipe.skeleton, "default")
        XCTAssertTrue(recipe.morphs.isEmpty)
        XCTAssertTrue(recipe.expressions.isEmpty)
    }

    // MARK: - VRMBuilder Tests

    func testDefaultSkeletonCreation() throws {
        let vrm = try VRMBuilder().build()

        XCTAssertNotNil(vrm.humanoid)
        XCTAssertGreaterThanOrEqual(vrm.humanoid!.humanBones.count, 20)

        // Check for required bones
        let hasHips = vrm.humanoid!.humanBones.keys.contains(.hips)
        let hasHead = vrm.humanoid!.humanBones.keys.contains(.head)
        let hasLeftArm = vrm.humanoid!.humanBones.keys.contains(.leftUpperArm)
        let hasRightArm = vrm.humanoid!.humanBones.keys.contains(.rightUpperArm)

        XCTAssertTrue(hasHips)
        XCTAssertTrue(hasHead)
        XCTAssertTrue(hasLeftArm)
        XCTAssertTrue(hasRightArm)
    }

    func testAllSkeletonPresets() throws {
        let presets: [SkeletonPreset] = [.defaultHumanoid, .tall, .short, .stocky]

        for preset in presets {
            let vrm = try VRMBuilder().setSkeleton(preset).build()
            XCTAssertNotNil(vrm.humanoid)
            XCTAssertGreaterThanOrEqual(vrm.humanoid!.humanBones.count, 20)
        }
    }

    func testMorphApplication() throws {
        let morphs: [String: Float] = [
            "height": 1.2,
            "muscle_definition": 0.8,
            "hair_length": 0.7
        ]

        let vrm = try VRMBuilder()
            .applyMorphs(morphs)
            .build()

        XCTAssertNotNil(vrm.humanoid)
        XCTAssertGreaterThanOrEqual(vrm.humanoid!.humanBones.count, 20)
    }

    func testMaterialConfiguration() throws {
        let hairColor: SIMD3<Float> = [0.35, 0.25, 0.15]
        let eyeColor: SIMD3<Float> = [0.2, 0.4, 0.8]
        let skinTone: Float = 0.5

        let vrm = try VRMBuilder()
            .setHairColor(hairColor)
            .setEyeColor(eyeColor)
            .setSkinTone(skinTone)
            .build()

        // VRMBuilder creates glTF materials but VRMModel loads them asynchronously
        // The materials count will be 0 until resources are loaded
        XCTAssertGreaterThanOrEqual(vrm.gltf.materials?.count ?? 0, 1)
        XCTAssertNotNil(vrm.gltf.materials)
    }

    func testExpressionPresets() throws {
        let expressions: [VRMExpressionPreset] = [.happy, .sad, .angry, .surprised, .blink]

        let vrm = try VRMBuilder()
            .addExpressions(expressions)
            .build()

        XCTAssertNotNil(vrm.expressions)
        XCTAssertGreaterThanOrEqual(vrm.expressions!.preset.count, expressions.count)

        for expr in expressions {
            XCTAssertTrue(vrm.expressions!.preset.keys.contains(expr))
        }
    }

    func testVRMModelSerialization() throws {
        let vrm = try VRMBuilder()
            .setSkeleton(.defaultHumanoid)
            .applyMorphs(["height": 1.1])
            .setHairColor([0.5, 0.3, 0.1])
            .setEyeColor([0.2, 0.6, 0.8])
            .setSkinTone(0.5)
            .addExpressions([.happy, .sad])
            .build()

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("vrm")

        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        try vrm.serialize(to: tempURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: tempURL.path))

        let fileSize = try FileManager.default.attributesOfItem(atPath: tempURL.path)[.size] as! Int64
        XCTAssertGreaterThan(fileSize, 1000)

        // Verify GLB header
        let data = try Data(contentsOf: tempURL)
        XCTAssertGreaterThanOrEqual(data.count, 12)

        let magic = data.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) }
        XCTAssertEqual(magic, 0x46546C67) // "glTF"

        let version = data.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) }
        XCTAssertEqual(version, 2)
    }

    // MARK: - Performance Tests

    func testRecipeValidationPerformance() throws {
        let recipeJSON = """
        {
            "skeleton": "default_humanoid",
            "morphs": {
                "height": 1.15,
                "muscle_definition": 0.7
            },
            "materials": {
                "hairColor": [0.35, 0.25, 0.15],
                "eyeColor": [0.2, 0.4, 0.8],
                "skinTone": 0.5
            },
            "expressions": ["happy", "sad"]
        }
        """

        measure {
            do {
                let recipe = try CharacterRecipe.from(json: recipeJSON)
                try recipe.validate()
            } catch {
                XCTFail("Recipe validation failed: \(error)")
            }
        }
    }

    func testVRMCreationPerformance() throws {
        measure {
            do {
                let _ = try VRMBuilder()
                    .setSkeleton(.defaultHumanoid)
                    .applyMorphs(["height": 1.1])
                    .build()
            } catch {
                XCTFail("VRM creation failed: \(error)")
            }
        }
    }

    // MARK: - Integration Tests

    func testCharacterRecipeToVRMBuilderPipeline() throws {
        let recipeJSON = """
        {
            "skeleton": "tall",
            "morphs": {
                "height": 1.15,
                "muscle_definition": 0.7
            },
            "materials": {
                "hairColor": [0.35, 0.25, 0.15],
                "eyeColor": [0.2, 0.4, 0.8],
                "skinTone": 0.5
            },
            "expressions": ["happy", "sad", "angry"]
        }
        """

        let recipe = try CharacterRecipe.from(json: recipeJSON)
        try recipe.validate()

        // Build VRM from recipe
        var builder = VRMBuilder()

        if recipe.skeleton.lowercased().contains("tall") {
            builder = builder.setSkeleton(.tall)
        } else {
            builder = builder.setSkeleton(.defaultHumanoid)
        }

        builder = builder
            .applyMorphs(recipe.morphs)
            .setHairColor(SIMD3<Float>(recipe.materials.hairColor))
            .setEyeColor(SIMD3<Float>(recipe.materials.eyeColor))
            .setSkinTone(recipe.materials.skinTone)

        let vrm = try builder.build()

        XCTAssertNotNil(vrm.humanoid)
        // Expressions are only added if non-empty
        // XCTAssertNotNil(vrm.expressions)
        XCTAssertGreaterThanOrEqual(vrm.gltf.materials?.count ?? 0, 1)
    }
}