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

/// Tests for ARKit mapping (face blend shapes → VRM expressions, body skeleton → VRM bones)
final class ARKitMapperTests: XCTestCase {

    // MARK: - Mapping Formula Tests

    func testDirectMapping() {
        let mapper = ARKitToVRMMapper(
            mappings: [
                "blink": .direct(ARKitFaceBlendShapes.eyeBlinkLeft)
            ]
        )

        let shapes = ARKitFaceBlendShapes(
            timestamp: 0,
            shapes: [ARKitFaceBlendShapes.eyeBlinkLeft: 0.8]
        )

        let result = mapper.map(shapes)
        XCTAssertEqual(result["blink"], 0.8, accuracy: 0.001)
    }

    func testAverageMapping() {
        let mapper = ARKitToVRMMapper(
            mappings: [
                "blink": .average([
                    ARKitFaceBlendShapes.eyeBlinkLeft,
                    ARKitFaceBlendShapes.eyeBlinkRight
                ])
            ]
        )

        let shapes = ARKitFaceBlendShapes(
            timestamp: 0,
            shapes: [
                ARKitFaceBlendShapes.eyeBlinkLeft: 1.0,
                ARKitFaceBlendShapes.eyeBlinkRight: 0.6
            ]
        )

        let result = mapper.map(shapes)
        XCTAssertEqual(result["blink"], 0.8, accuracy: 0.001)  // (1.0 + 0.6) / 2
    }

    func testWeightedMapping() {
        let mapper = ARKitToVRMMapper(
            mappings: [
                "happy": .weighted([
                    (ARKitFaceBlendShapes.mouthSmileLeft, 0.4),
                    (ARKitFaceBlendShapes.mouthSmileRight, 0.4),
                    (ARKitFaceBlendShapes.cheekSquintLeft, 0.1),
                    (ARKitFaceBlendShapes.cheekSquintRight, 0.1)
                ])
            ]
        )

        let shapes = ARKitFaceBlendShapes(
            timestamp: 0,
            shapes: [
                ARKitFaceBlendShapes.mouthSmileLeft: 1.0,
                ARKitFaceBlendShapes.mouthSmileRight: 1.0,
                ARKitFaceBlendShapes.cheekSquintLeft: 0.5,
                ARKitFaceBlendShapes.cheekSquintRight: 0.5
            ]
        )

        let result = mapper.map(shapes)
        // 0.4 * 1.0 + 0.4 * 1.0 + 0.1 * 0.5 + 0.1 * 0.5 = 0.9
        XCTAssertEqual(result["happy"], 0.9, accuracy: 0.001)
    }

    func testMaxMapping() {
        let mapper = ARKitToVRMMapper(
            mappings: [
                "eyeWide": .max([
                    ARKitFaceBlendShapes.eyeWideLeft,
                    ARKitFaceBlendShapes.eyeWideRight
                ])
            ]
        )

        let shapes = ARKitFaceBlendShapes(
            timestamp: 0,
            shapes: [
                ARKitFaceBlendShapes.eyeWideLeft: 0.3,
                ARKitFaceBlendShapes.eyeWideRight: 0.7
            ]
        )

        let result = mapper.map(shapes)
        XCTAssertEqual(result["eyeWide"], 0.7, accuracy: 0.001)
    }

    func testMinMapping() {
        let mapper = ARKitToVRMMapper(
            mappings: [
                "test": .min([
                    ARKitFaceBlendShapes.eyeBlinkLeft,
                    ARKitFaceBlendShapes.eyeBlinkRight
                ])
            ]
        )

        let shapes = ARKitFaceBlendShapes(
            timestamp: 0,
            shapes: [
                ARKitFaceBlendShapes.eyeBlinkLeft: 0.9,
                ARKitFaceBlendShapes.eyeBlinkRight: 0.3
            ]
        )

        let result = mapper.map(shapes)
        XCTAssertEqual(result["test"], 0.3, accuracy: 0.001)
    }

    func testCustomMapping() {
        let mapper = ARKitToVRMMapper(
            mappings: [
                "custom": .custom { shapes in
                    let left = shapes.weight(for: ARKitFaceBlendShapes.eyeBlinkLeft)
                    let right = shapes.weight(for: ARKitFaceBlendShapes.eyeBlinkRight)
                    return left * right  // Product instead of average
                }
            ]
        )

        let shapes = ARKitFaceBlendShapes(
            timestamp: 0,
            shapes: [
                ARKitFaceBlendShapes.eyeBlinkLeft: 0.8,
                ARKitFaceBlendShapes.eyeBlinkRight: 0.5
            ]
        )

        let result = mapper.map(shapes)
        XCTAssertEqual(result["custom"], 0.4, accuracy: 0.001)  // 0.8 * 0.5
    }

    // MARK: - Preset Mapper Tests

    func testDefaultMapperCoverage() {
        let mapper = ARKitToVRMMapper.default

        // Test that default mapper covers all 18 VRM expressions
        let expressions = [
            "happy", "angry", "sad", "relaxed", "surprised",
            "aa", "ih", "ou", "ee", "oh",
            "blink", "blinkLeft", "blinkRight",
            "lookUp", "lookDown", "lookLeft", "lookRight",
            "neutral"
        ]

        for expression in expressions {
            XCTAssertNotNil(mapper.mappings[expression], "Default mapper missing: \(expression)")
        }
    }

    func testSimplifiedMapperSubset() {
        let mapper = ARKitToVRMMapper.simplified

        // Simplified should have fewer mappings than default
        XCTAssert(mapper.mappings.count < ARKitToVRMMapper.default.mappings.count)

        // But should still cover core expressions
        XCTAssertNotNil(mapper.mappings["happy"])
        XCTAssertNotNil(mapper.mappings["blink"])
    }

    func testAggressiveMapperAmplification() {
        let defaultMapper = ARKitToVRMMapper.default
        let aggressiveMapper = ARKitToVRMMapper.aggressive

        let shapes = ARKitFaceBlendShapes(
            timestamp: 0,
            shapes: [
                ARKitFaceBlendShapes.mouthSmileLeft: 0.5,
                ARKitFaceBlendShapes.mouthSmileRight: 0.5
            ]
        )

        let defaultResult = defaultMapper.map(shapes)
        let aggressiveResult = aggressiveMapper.map(shapes)

        // Aggressive should produce higher values
        if let defaultHappy = defaultResult["happy"],
           let aggressiveHappy = aggressiveResult["happy"] {
            XCTAssert(aggressiveHappy >= defaultHappy, "Aggressive should amplify")
        }
    }

    // MARK: - Skeleton Mapper Tests

    func testDefaultSkeletonMapping() {
        let mapper = ARKitSkeletonMapper.default

        // Should map core humanoid bones
        XCTAssertNotNil(mapper.jointMap["hips"])
        XCTAssertNotNil(mapper.jointMap["spine"])
        XCTAssertNotNil(mapper.jointMap["chest"])
        XCTAssertNotNil(mapper.jointMap["neck"])
        XCTAssertNotNil(mapper.jointMap["head"])
    }

    func testUpperBodyOnlyMapping() {
        let mapper = ARKitSkeletonMapper.upperBodyOnly

        // Should have upper body
        XCTAssertNotNil(mapper.jointMap["spine"])
        XCTAssertNotNil(mapper.jointMap["leftShoulder"])

        // Should NOT have lower body
        XCTAssertNil(mapper.jointMap["leftHip"])
        XCTAssertNil(mapper.jointMap["leftKnee"])
    }

    func testCoreOnlyMapping() {
        let mapper = ARKitSkeletonMapper.coreOnly

        // Should have minimal core
        let coreJoints = ["hips", "spine", "chest", "neck", "head"]
        for joint in coreJoints {
            XCTAssertNotNil(mapper.jointMap[joint], "Core should include \(joint)")
        }

        // Should have fewer mappings than default
        XCTAssert(mapper.jointMap.count < ARKitSkeletonMapper.default.jointMap.count)
    }

    // MARK: - Edge Cases

    func testMissingBlendShape() {
        let mapper = ARKitToVRMMapper(
            mappings: [
                "test": .direct("nonexistent")
            ]
        )

        let shapes = ARKitFaceBlendShapes(timestamp: 0, shapes: [:])
        let result = mapper.map(shapes)

        XCTAssertEqual(result["test"], 0.0, accuracy: 0.001)
    }

    func testEmptyBlendShapes() {
        let mapper = ARKitToVRMMapper.default
        let shapes = ARKitFaceBlendShapes(timestamp: 0, shapes: [:])

        let result = mapper.map(shapes)

        // All expressions should return 0.0
        for (_, value) in result {
            XCTAssertEqual(value, 0.0, accuracy: 0.001)
        }
    }

    func testEmptyWeightedMapping() {
        let mapper = ARKitToVRMMapper(
            mappings: [
                "test": .weighted([])
            ]
        )

        let shapes = ARKitFaceBlendShapes(
            timestamp: 0,
            shapes: [ARKitFaceBlendShapes.eyeBlinkLeft: 1.0]
        )

        let result = mapper.map(shapes)
        XCTAssertEqual(result["test"], 0.0, accuracy: 0.001)
    }

    func testSingleValueAverage() {
        let mapper = ARKitToVRMMapper(
            mappings: [
                "test": .average([ARKitFaceBlendShapes.eyeBlinkLeft])
            ]
        )

        let shapes = ARKitFaceBlendShapes(
            timestamp: 0,
            shapes: [ARKitFaceBlendShapes.eyeBlinkLeft: 0.7]
        )

        let result = mapper.map(shapes)
        XCTAssertEqual(result["test"], 0.7, accuracy: 0.001)
    }

    // MARK: - Performance Tests

    func testMappingPerformance() {
        let mapper = ARKitToVRMMapper.default

        let shapes = ARKitFaceBlendShapes(
            timestamp: 0,
            shapes: [
                ARKitFaceBlendShapes.mouthSmileLeft: 0.8,
                ARKitFaceBlendShapes.mouthSmileRight: 0.8,
                ARKitFaceBlendShapes.eyeBlinkLeft: 0.5,
                ARKitFaceBlendShapes.eyeBlinkRight: 0.5,
                ARKitFaceBlendShapes.jawOpen: 0.3
            ]
        )

        measure {
            for _ in 0..<1000 {
                _ = mapper.map(shapes)
            }
        }
    }
}
