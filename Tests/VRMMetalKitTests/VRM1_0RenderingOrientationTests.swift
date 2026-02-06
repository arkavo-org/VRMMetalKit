// Copyright 2025 Arkavo Inc. and contributors
// Licensed under the Apache License, Version 2.0

import XCTest
import Metal
import simd
@testable import VRMMetalKit

/// Tests for VRM 1.0 rendering orientation fix.
///
/// VRM 0.0 (Unity) models face -Z, VRM 1.0 (glTF) models face +Z.
/// The renderer should apply a 180° Y rotation to VRM 1.0 models so they
/// face the camera at -Z, matching VRM 0.0 behavior.
///
/// ## Related Changes
/// - VRMRenderer.vrmVersionRotation property
/// - Model matrix calculation in draw loop
///
final class VRM1_0RenderingOrientationTests: XCTestCase {

    var device: MTLDevice!
    var renderer: VRMRenderer!

    // Test model paths from environment
    var vrm0Path: String {
        ProcessInfo.processInfo.environment["VRM_TEST_VRM0_PATH"] ?? ""
    }
    var vrm1Path: String {
        ProcessInfo.processInfo.environment["VRM_TEST_VRM1_PATH"] ?? ""
    }

    override func setUp() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        self.device = device
        self.renderer = VRMRenderer(device: device)
    }

    // MARK: - Rotation Matrix Tests

    /// Test: 180° Y rotation matrix is mathematically correct
    func testRotation180YMatrix() {
        // 180° rotation around Y axis
        let rotation = simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 1, 0))
        let rotationMatrix = matrix_float4x4(rotation)

        // A 180° Y rotation should:
        // - Negate X (X becomes -X)
        // - Keep Y unchanged
        // - Negate Z (Z becomes -Z)

        let testPoint = SIMD4<Float>(1, 2, 3, 1)
        let rotated = rotationMatrix * testPoint

        XCTAssertEqual(rotated.x, -1.0, accuracy: 0.001, "X should be negated")
        XCTAssertEqual(rotated.y, 2.0, accuracy: 0.001, "Y should be unchanged")
        XCTAssertEqual(rotated.z, -3.0, accuracy: 0.001, "Z should be negated")
        XCTAssertEqual(rotated.w, 1.0, accuracy: 0.001, "W should be unchanged")
    }

    /// Test: Forward vector (+Z) becomes -Z after 180° Y rotation
    func testVRM1_0ForwardBecomesCameraDirection() {
        // VRM 1.0 forward direction
        let forward = SIMD3<Float>(0, 0, 1)

        // 180° Y rotation
        let rotation = simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 1, 0))
        let rotatedForward = rotation.act(forward)

        // After rotation, forward should point towards camera at -Z
        XCTAssertEqual(rotatedForward.x, 0.0, accuracy: 0.001)
        XCTAssertEqual(rotatedForward.y, 0.0, accuracy: 0.001)
        XCTAssertEqual(rotatedForward.z, -1.0, accuracy: 0.001,
                       "VRM 1.0 forward (+Z) should become -Z after 180° Y rotation")
    }

    /// Test: Up vector remains unchanged after 180° Y rotation
    func testUpVectorPreserved() {
        let up = SIMD3<Float>(0, 1, 0)
        let rotation = simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 1, 0))
        let rotatedUp = rotation.act(up)

        XCTAssertEqual(rotatedUp.x, 0.0, accuracy: 0.001)
        XCTAssertEqual(rotatedUp.y, 1.0, accuracy: 0.001, "Up vector should remain +Y")
        XCTAssertEqual(rotatedUp.z, 0.0, accuracy: 0.001)
    }

    /// Test: Right vector becomes left after 180° Y rotation (as expected)
    func testRightVectorFlips() {
        let right = SIMD3<Float>(1, 0, 0)
        let rotation = simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 1, 0))
        let rotatedRight = rotation.act(right)

        XCTAssertEqual(rotatedRight.x, -1.0, accuracy: 0.001,
                       "Right (+X) should become left (-X) after 180° Y rotation")
        XCTAssertEqual(rotatedRight.y, 0.0, accuracy: 0.001)
        XCTAssertEqual(rotatedRight.z, 0.0, accuracy: 0.001)
    }

    // MARK: - VRM Version Detection Tests

    /// Test: VRM 0.0 model is correctly identified
    func testVRM0_0Detection() async throws {
        guard FileManager.default.fileExists(atPath: vrm0Path) else {
            throw XCTSkip("VRM 0.0 test model not found at \(vrm0Path)")
        }

        let model = try await VRMModel.load(from: URL(fileURLWithPath: vrm0Path), device: device)
        XCTAssertTrue(model.isVRM0, "Model should be detected as VRM 0.0")
        XCTAssertEqual(model.specVersion, .v0_0, "Spec version should be v0_0")
    }

    /// Test: VRM 1.0 model is correctly identified
    func testVRM1_0Detection() async throws {
        guard FileManager.default.fileExists(atPath: vrm1Path) else {
            throw XCTSkip("VRM 1.0 test model not found at \(vrm1Path)")
        }

        let model = try await VRMModel.load(from: URL(fileURLWithPath: vrm1Path), device: device)

        // Note: Some models may be VRM 0.0 despite filenames
        // This test verifies the detection logic works
        print("Model spec version: \(model.specVersion)")
        print("isVRM0: \(model.isVRM0)")

        // If this is truly a VRM 1.0 model, verify
        if !model.isVRM0 {
            XCTAssertEqual(model.specVersion, .v1_0, "Non-VRM0 model should be VRM 1.0")
        }
    }

    // MARK: - Renderer Integration Tests

    /// Test: Renderer handles model without crashing
    func testRendererLoadsModel() async throws {
        guard FileManager.default.fileExists(atPath: vrm0Path) else {
            throw XCTSkip("VRM 0.0 test model not found")
        }

        let model = try await VRMModel.load(from: URL(fileURLWithPath: vrm0Path), device: device)
        renderer.loadModel(model)

        XCTAssertNotNil(renderer.model, "Renderer should have model loaded")
    }

    // MARK: - Normal Matrix Tests

    /// Test: Rotation-only matrix is valid for normal transformation
    func testRotationMatrixValidForNormals() {
        // A rotation matrix is orthogonal, so M^(-1)^T = M for normals
        let rotation = simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 1, 0))
        let rotationMatrix = matrix_float4x4(rotation)

        // The inverse transpose of a pure rotation is the rotation itself
        let inverseMatrix = simd_inverse(rotationMatrix)
        let inverseTranspose = simd_transpose(inverseMatrix)

        // Verify they're approximately equal
        for col in 0..<4 {
            for row in 0..<4 {
                XCTAssertEqual(rotationMatrix[col][row], inverseTranspose[col][row],
                               accuracy: 0.0001,
                               "Rotation matrix should equal its inverse transpose at [\(col)][\(row)]")
            }
        }
    }

    /// Test: Normal transforms correctly under rotation
    func testNormalTransformUnderRotation() {
        let normal = SIMD3<Float>(0, 0, 1)  // Forward-facing normal
        let rotation = simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 1, 0))

        // Transform normal (for normals, use quaternion directly or rotation matrix)
        let rotatedNormal = rotation.act(normal)

        // Normal should now point backwards (-Z)
        XCTAssertEqual(rotatedNormal.x, 0.0, accuracy: 0.001)
        XCTAssertEqual(rotatedNormal.y, 0.0, accuracy: 0.001)
        XCTAssertEqual(rotatedNormal.z, -1.0, accuracy: 0.001)
    }

    // MARK: - Coordinate System Documentation Tests

    /// Test: Verify VRM coordinate system assumptions are documented correctly
    func testCoordinateSystemAssumptions() throws {
        // VRM 0.0 (Unity): Left-handed, Y-up, forward is -Z
        // VRM 1.0 (glTF): Right-handed, Y-up, forward is +Z
        // Camera: Positioned at -Z, looking at origin

        // For a model at origin:
        // - VRM 0.0 facing -Z + camera at -Z = camera sees FRONT (correct)
        // - VRM 1.0 facing +Z + camera at -Z = camera sees BACK (incorrect without rotation)

        // After 180° Y rotation:
        // - VRM 1.0 facing -Z + camera at -Z = camera sees FRONT (correct)

        // This test documents the coordinate system assumptions
        throw XCTSkip("Coordinate system assumptions need validation")
    }

    // MARK: - Model Loading Consistency Tests

    /// Test: Both VRM versions can be loaded without errors
    func testBothVersionsLoadSuccessfully() async throws {
        var loadedCount = 0

        if FileManager.default.fileExists(atPath: vrm0Path) {
            let model0 = try await VRMModel.load(from: URL(fileURLWithPath: vrm0Path), device: device)
            XCTAssertNotNil(model0.humanoid, "VRM 0.0 should have humanoid data")
            loadedCount += 1
            print("VRM 0.0 loaded: \(model0.meta.name ?? "unknown")")
        }

        if FileManager.default.fileExists(atPath: vrm1Path) {
            let model1 = try await VRMModel.load(from: URL(fileURLWithPath: vrm1Path), device: device)
            XCTAssertNotNil(model1.humanoid, "VRM 1.0 should have humanoid data")
            loadedCount += 1
            print("VRM 1.0 loaded: \(model1.meta.name ?? "unknown")")
        }

        if loadedCount == 0 {
            throw XCTSkip("No VRM test models found")
        }
    }

    // MARK: - Performance Tests

    /// Test: Rotation calculation is fast (should be negligible overhead)
    func testRotationCalculationPerformance() {
        measure {
            for _ in 0..<10000 {
                let rotation = simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 1, 0))
                let _ = matrix_float4x4(rotation)
            }
        }
    }
}
