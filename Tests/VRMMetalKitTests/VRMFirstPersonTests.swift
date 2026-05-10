// Copyright 2025 Arkavo Inc. and contributors
// Licensed under the Apache License, Version 2.0

import XCTest
import Metal
import simd
@testable import VRMMetalKit

/// Tests for VRMC_vrm-1.0 §firstPerson spec compliance.
///
/// Covers F2 (annotation-based mesh filtering), F3 (auto-mode head-bone vertex flags),
/// and F4 (public camera mode API).
final class VRMFirstPersonTests: XCTestCase {

    // MARK: - F4: Public Camera Mode API

    /// Default camera mode must be third-person so VR is strictly opt-in.
    func testDefaultCameraModeIsThirdPerson() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        let renderer = VRMRenderer(device: device)
        XCTAssertEqual(renderer.cameraMode, .thirdPerson)
    }

    /// Setting first-person mode is reflected on the renderer.
    func testSetFirstPersonMode() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        let renderer = VRMRenderer(device: device)
        renderer.cameraMode = .firstPerson
        XCTAssertEqual(renderer.cameraMode, .firstPerson)
    }

    /// Toggling back to third-person mode is reflected on the renderer.
    func testRoundTripCameraMode() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        let renderer = VRMRenderer(device: device)
        renderer.cameraMode = .firstPerson
        renderer.cameraMode = .thirdPerson
        XCTAssertEqual(renderer.cameraMode, .thirdPerson)
    }

    // MARK: - F2: Annotation-Based Primitive Filtering

    /// `both` annotation is visible in both camera modes.
    func testBothAnnotationAlwaysVisible() {
        XCTAssertTrue(shouldRenderPrimitive(annotation: .both, cameraMode: .thirdPerson))
        XCTAssertTrue(shouldRenderPrimitive(annotation: .both, cameraMode: .firstPerson))
    }

    /// `auto` annotation is visible in both camera modes (vertex-level culling handles first-person).
    func testAutoAnnotationAlwaysVisible() {
        XCTAssertTrue(shouldRenderPrimitive(annotation: .auto, cameraMode: .thirdPerson))
        XCTAssertTrue(shouldRenderPrimitive(annotation: .auto, cameraMode: .firstPerson))
    }

    /// `firstPersonOnly` meshes are hidden in third-person and shown in first-person.
    func testFirstPersonOnlyAnnotation() {
        XCTAssertFalse(shouldRenderPrimitive(annotation: .firstPersonOnly, cameraMode: .thirdPerson))
        XCTAssertTrue(shouldRenderPrimitive(annotation: .firstPersonOnly, cameraMode: .firstPerson))
    }

    /// `thirdPersonOnly` meshes are shown in third-person and hidden in first-person.
    func testThirdPersonOnlyAnnotation() {
        XCTAssertTrue(shouldRenderPrimitive(annotation: .thirdPersonOnly, cameraMode: .thirdPerson))
        XCTAssertFalse(shouldRenderPrimitive(annotation: .thirdPersonOnly, cameraMode: .firstPerson))
    }

    /// A node without any annotation defaults to `auto`, which is visible in both modes.
    func testMissingAnnotationDefaultsToAutoAndIsVisible() {
        let model = makeMinimalModel()
        // Node 0 has no annotation in firstPerson.meshAnnotations
        let annotation = firstPersonAnnotation(for: 0, in: model)
        XCTAssertEqual(annotation, .auto)
        XCTAssertTrue(shouldRenderPrimitive(annotation: annotation, cameraMode: .thirdPerson))
        XCTAssertTrue(shouldRenderPrimitive(annotation: annotation, cameraMode: .firstPerson))
    }

    /// A node with an explicit annotation resolves to that annotation.
    func testExplicitAnnotationIsResolved() {
        let model = makeMinimalModel()
        model.firstPerson?.meshAnnotations.append(
            VRMFirstPerson.VRMMeshAnnotation(node: 0, type: .thirdPersonOnly)
        )
        let annotation = firstPersonAnnotation(for: 0, in: model)
        XCTAssertEqual(annotation, .thirdPersonOnly)
    }

    /// When `firstPerson` is nil on the model, all nodes default to `auto`.
    func testNilFirstPersonDefaultsToAuto() {
        let model = makeMinimalModel()
        model.firstPerson = nil
        let annotation = firstPersonAnnotation(for: 42, in: model)
        XCTAssertEqual(annotation, .auto)
    }

    // MARK: - F3: Per-Vertex Head-Bone Hidden Flags

    /// Vertices with any head-bone weight above the threshold are flagged as hidden.
    func testHeadSkinnedVerticesAreFlagged() {
        let headJointIndex: UInt32 = 2

        // Vertex 0: joint 2 (head) with weight 0.5 → should be hidden
        // Vertex 1: joint 0 with weight 1.0 → not hidden
        // Vertex 2: joint 2 (head) with weight 0.001 (at threshold boundary) → not hidden (≤ threshold)
        // Vertex 3: joint 2 (head) with weight 0.002 → hidden (> threshold)
        let joints: [SIMD4<UInt32>] = [
            SIMD4<UInt32>(2, 0, 0, 0),
            SIMD4<UInt32>(0, 1, 3, 0),
            SIMD4<UInt32>(2, 0, 0, 0),
            SIMD4<UInt32>(0, 2, 0, 0),
        ]
        let weights: [SIMD4<Float>] = [
            SIMD4<Float>(0.5, 0.5, 0.0, 0.0),
            SIMD4<Float>(0.6, 0.3, 0.1, 0.0),
            SIMD4<Float>(0.001, 0.999, 0.0, 0.0),
            SIMD4<Float>(0.998, 0.002, 0.0, 0.0),
        ]

        let flags = VRMPrimitive.computeFirstPersonHiddenFlags(
            joints: joints,
            weights: weights,
            headJointIndex: headJointIndex,
            weightThreshold: 0.001
        )

        XCTAssertEqual(flags.count, 4)
        XCTAssertEqual(flags[0], 1, "Vertex with head weight 0.5 must be hidden")
        XCTAssertEqual(flags[1], 0, "Vertex with no head influence must be visible")
        XCTAssertEqual(flags[2], 0, "Vertex with head weight at threshold (not strictly greater) must be visible")
        XCTAssertEqual(flags[3], 1, "Vertex with head weight 0.002 > 0.001 must be hidden")
    }

    /// All vertices with no head influence produce all-zero flags.
    func testNonHeadVerticesProduceZeroFlags() {
        let headJointIndex: UInt32 = 5
        let joints: [SIMD4<UInt32>] = [
            SIMD4<UInt32>(0, 1, 2, 3),
            SIMD4<UInt32>(4, 6, 7, 8),
        ]
        let weights: [SIMD4<Float>] = [
            SIMD4<Float>(0.25, 0.25, 0.25, 0.25),
            SIMD4<Float>(0.5, 0.3, 0.2, 0.0),
        ]
        let flags = VRMPrimitive.computeFirstPersonHiddenFlags(
            joints: joints,
            weights: weights,
            headJointIndex: headJointIndex
        )
        XCTAssertEqual(flags, [0, 0])
    }

    /// A vertex where multiple joint slots reference the head bone is still only flagged once.
    func testMultipleHeadJointSlotsAreHandled() {
        let flags = VRMPrimitive.computeFirstPersonHiddenFlags(
            joints: [SIMD4<UInt32>(3, 3, 3, 3)],
            weights: [SIMD4<Float>(0.25, 0.25, 0.25, 0.25)],
            headJointIndex: 3
        )
        XCTAssertEqual(flags, [1])
    }

    /// Empty input produces empty output.
    func testEmptyInputProducesEmptyFlags() {
        let flags = VRMPrimitive.computeFirstPersonHiddenFlags(
            joints: [],
            weights: [],
            headJointIndex: 0
        )
        XCTAssertTrue(flags.isEmpty)
    }

    /// Flag buffer upload creates a non-nil Metal buffer of correct byte length.
    func testFlagBufferUpload() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        let primitive = VRMPrimitive()
        primitive.firstPersonHiddenFlags = [0, 1, 0, 1, 0]
        primitive.uploadFirstPersonHiddenFlagsBuffer(device: device)
        let buffer = try XCTUnwrap(primitive.firstPersonHiddenFlagsBuffer)
        XCTAssertEqual(buffer.length, 5 * MemoryLayout<UInt8>.stride)
    }

    /// Upload with empty flags produces no buffer (no-op).
    func testFlagBufferUploadWithEmptyFlagsIsNoOp() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        let primitive = VRMPrimitive()
        primitive.uploadFirstPersonHiddenFlagsBuffer(device: device)
        XCTAssertNil(primitive.firstPersonHiddenFlagsBuffer)
    }

    // MARK: - Helpers

    private func makeMinimalModel() -> VRMModel {
        let json: [String: Any] = [
            "asset": ["version": "2.0"],
            "scene": 0,
            "scenes": [["nodes": [0]]],
            "nodes": [["name": "root"]],
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        let gltf = try! JSONDecoder().decode(GLTFDocument.self, from: data)
        let model = VRMModel(
            specVersion: .v1_0,
            meta: VRMMeta(licenseUrl: "https://vrm.dev/licenses/1.0/"),
            humanoid: nil,
            gltf: gltf
        )
        model.firstPerson = VRMFirstPerson()
        return model
    }
}
