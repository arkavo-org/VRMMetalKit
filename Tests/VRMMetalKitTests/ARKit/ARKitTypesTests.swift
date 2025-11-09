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
import Foundation
import simd
@testable import VRMMetalKit

/// Tests for ARKit data types (ARKitFaceBlendShapes, ARKitBodySkeleton, metadata sources)
final class ARKitTypesTests: XCTestCase {

    // MARK: - Face Blend Shapes Tests

    func testFaceBlendShapesCreation() {
        let timestamp = 1000.0
        let shapes: [String: Float] = [
            ARKitFaceBlendShapes.eyeBlinkLeft: 0.8,
            ARKitFaceBlendShapes.eyeBlinkRight: 0.7,
            ARKitFaceBlendShapes.jawOpen: 0.5
        ]

        let blendShapes = ARKitFaceBlendShapes(timestamp: timestamp, shapes: shapes)

        XCTAssertEqual(blendShapes.timestamp, timestamp)
        XCTAssertEqual(blendShapes.shapes.count, 3)
        XCTAssertEqual(blendShapes.weight(for: ARKitFaceBlendShapes.eyeBlinkLeft), 0.8)
        XCTAssertEqual(blendShapes.weight(for: ARKitFaceBlendShapes.eyeBlinkRight), 0.7)
        XCTAssertEqual(blendShapes.weight(for: ARKitFaceBlendShapes.jawOpen), 0.5)
    }

    func testFaceBlendShapesWeightDefault() {
        let blendShapes = ARKitFaceBlendShapes(timestamp: 0, shapes: [:])

        // Non-existent shape should return 0.0
        XCTAssertEqual(blendShapes.weight(for: "nonexistent"), 0.0)
    }

    func testFaceBlendShapesStaleness() {
        let now = Date().timeIntervalSinceReferenceDate
        let threshold: TimeInterval = 0.15  // 150ms

        // Recent data (not stale)
        let recent = ARKitFaceBlendShapes(timestamp: now - 0.05, shapes: [:])
        let recentAge = now - recent.timestamp
        XCTAssertLessThan(recentAge, threshold)

        // Old data (stale)
        let old = ARKitFaceBlendShapes(timestamp: now - 0.2, shapes: [:])
        let oldAge = now - old.timestamp
        XCTAssertGreaterThan(oldAge, threshold)

        // Exactly at threshold (boundary)
        let exact = ARKitFaceBlendShapes(timestamp: now - threshold, shapes: [:])
        let exactAge = now - exact.timestamp
        XCTAssertEqual(exactAge, threshold, accuracy: 0.001)
    }

    func testFaceBlendShapesCodable() throws {
        let original = ARKitFaceBlendShapes(
            timestamp: 123.456,
            shapes: [
                ARKitFaceBlendShapes.mouthSmileLeft: 0.9,
                ARKitFaceBlendShapes.mouthSmileRight: 0.85
            ]
        )

        // Encode
        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        // Decode
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ARKitFaceBlendShapes.self, from: data)

        XCTAssertEqual(decoded.timestamp, original.timestamp)
        XCTAssertEqual(decoded.shapes.count, original.shapes.count)
        XCTAssertEqual(decoded.weight(for: ARKitFaceBlendShapes.mouthSmileLeft), 0.9, accuracy: 0.001)
        XCTAssertEqual(decoded.weight(for: ARKitFaceBlendShapes.mouthSmileRight), 0.85, accuracy: 0.001)
    }

    // MARK: - Body Skeleton Tests

    func testBodySkeletonCreation() {
        let timestamp = 2000.0
        let joints: [ARKitJoint: simd_float4x4] = [
            .hips: simd_float4x4(1),
            .spine: simd_float4x4(1)
        ]

        let skeleton = ARKitBodySkeleton(timestamp: timestamp, joints: joints, isTracked: true)

        XCTAssertEqual(skeleton.timestamp, timestamp)
        XCTAssertEqual(skeleton.joints.count, 2)
        XCTAssertTrue(skeleton.isTracked)
        XCTAssertNotNil(skeleton.joints[.hips])
        XCTAssertNotNil(skeleton.joints[.spine])
    }

    func testBodySkeletonTransformAccess() {
        let identity = simd_float4x4(1)
        let skeleton = ARKitBodySkeleton(timestamp: 0, joints: [.root: identity], isTracked: true)

        XCTAssertNotNil(skeleton.transform(for: .root))
        XCTAssertNil(skeleton.transform(for: .hips))

        let retrieved = skeleton.transform(for: .root)!
        XCTAssertEqual(retrieved, identity)
    }

    func testBodySkeletonStaleness() {
        let now = Date().timeIntervalSinceReferenceDate
        let threshold: TimeInterval = 0.15

        let recent = ARKitBodySkeleton(timestamp: now - 0.05, joints: [:], isTracked: true)
        let recentAge = now - recent.timestamp
        XCTAssertLessThan(recentAge, threshold)

        let old = ARKitBodySkeleton(timestamp: now - 0.3, joints: [:], isTracked: true)
        let oldAge = now - old.timestamp
        XCTAssertGreaterThan(oldAge, threshold)
    }

    func testBodySkeletonCodable() throws {
        let identity = simd_float4x4(1)
        let original = ARKitBodySkeleton(
            timestamp: 456.789,
            joints: [
                .hips: identity,
                .spine: identity
            ],
            isTracked: true
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ARKitBodySkeleton.self, from: data)

        XCTAssertEqual(decoded.timestamp, original.timestamp)
        XCTAssertEqual(decoded.joints.count, 2)
        XCTAssertTrue(decoded.isTracked)
    }

    func testBodySkeletonSubsetExtraction() {
        let joints: [ARKitJoint: simd_float4x4] = [
            .hips: simd_float4x4(1),
            .spine: simd_float4x4(1),
            .leftShoulder: simd_float4x4(1),
            .rightShoulder: simd_float4x4(1),
            .leftUpperLeg: simd_float4x4(1)
        ]

        let skeleton = ARKitBodySkeleton(timestamp: 0, joints: joints, isTracked: true)
        let subset = skeleton.subset(joints: [.hips, .spine, .neck])

        XCTAssertEqual(subset.joints.count, 2)  // Only hips and spine (neck not in original)
        XCTAssertNotNil(subset.joints[.hips])
        XCTAssertNotNil(subset.joints[.spine])
        XCTAssertNil(subset.joints[.leftShoulder])
    }

    // MARK: - Metadata Source Tests

    func testARFaceSourceCreation() {
        let source = ARFaceSource(
            sourceID: UUID(),
            name: "iPhone 15 Pro",
            metadata: ["device": "iPhone15,2"]
        )

        XCTAssertEqual(source.name, "iPhone 15 Pro")
        XCTAssertEqual(source.metadata["device"], "iPhone15,2")
        XCTAssertFalse(source.isActive)  // No data yet, so not active
    }

    func testARBodySourceCreation() {
        let source = ARBodySource(
            sourceID: UUID(),
            name: "iPad Pro",
            metadata: ["connection": "wifi"]
        )

        XCTAssertEqual(source.name, "iPad Pro")
        XCTAssertEqual(source.metadata["connection"], "wifi")
        XCTAssertFalse(source.isActive)  // No data yet
    }

    func testARCombinedSourceCreation() {
        let source = ARCombinedSource(
            sourceID: UUID(),
            name: "iPhone Front",
            metadata: [:]
        )

        XCTAssertEqual(source.name, "iPhone Front")
        XCTAssertFalse(source.isActive)  // No data yet
    }

    func testFaceSourceUpdate() {
        let source = ARFaceSource(
            sourceID: UUID(),
            name: "Test",
            metadata: [:]
        )

        let now = Date().timeIntervalSinceReferenceDate
        let blendShapes = ARKitFaceBlendShapes(timestamp: now, shapes: [:])
        source.update(blendShapes: blendShapes)

        XCTAssertTrue(source.isActive)
        XCTAssertNotNil(source.blendShapes)
    }

    func testBodySourceUpdate() {
        let source = ARBodySource(
            sourceID: UUID(),
            name: "Test",
            metadata: [:]
        )

        let skeleton = ARKitBodySkeleton(timestamp: Date().timeIntervalSinceReferenceDate, joints: [:], isTracked: true)
        source.update(skeleton: skeleton)

        XCTAssertTrue(source.isActive)
        XCTAssertNotNil(source.skeleton)
    }

    // MARK: - Edge Cases

    func testEmptyBlendShapes() {
        let empty = ARKitFaceBlendShapes(timestamp: 0, shapes: [:])
        XCTAssertEqual(empty.shapes.count, 0)
        XCTAssertEqual(empty.weight(for: ARKitFaceBlendShapes.eyeBlinkLeft), 0.0)
    }

    func testEmptySkeleton() {
        let empty = ARKitBodySkeleton(timestamp: 0, joints: [:], isTracked: false)
        XCTAssertEqual(empty.joints.count, 0)
        XCTAssertNil(empty.transform(for: .hips))
        XCTAssertFalse(empty.isTracked)
    }

    func testBlendShapeWeightClamping() {
        let shapes: [String: Float] = [
            "negative": -0.5,
            "normal": 0.5,
            "overOne": 1.5
        ]
        let blendShapes = ARKitFaceBlendShapes(timestamp: 0, shapes: shapes)

        // Values should be stored as-is (clamping happens at usage if needed)
        XCTAssertEqual(blendShapes.weight(for: "negative"), -0.5)
        XCTAssertEqual(blendShapes.weight(for: "normal"), 0.5)
        XCTAssertEqual(blendShapes.weight(for: "overOne"), 1.5)
    }
}
