//
// VRMVersionAwareTests.swift
// Tests for version-aware VRM shader behavior
//

import XCTest
import Metal
@testable import VRMMetalKit

final class VRMVersionAwareTests: XCTestCase {

    var device: MTLDevice!

    override func setUpWithError() throws {
        device = MTLCreateSystemDefaultDevice()
        try XCTSkipIf(device == nil, "Metal device not available")
    }

    // MARK: - VRM 0.0 Tests

    func testVRM0ModelVersionDetection() async throws {
        // Try environment variable first, then fallback to known path
        let vrm0Path = ProcessInfo.processInfo.environment["VRM_TEST_VRM0_PATH"]
            ?? "/Users/arkavo/Documents/VRMModels/AvatarSample_A.vrm.glb"

        let url = URL(fileURLWithPath: vrm0Path)
        guard FileManager.default.fileExists(atPath: vrm0Path) else {
            throw XCTSkip("VRM 0.0 test model not found at: \(vrm0Path)")
        }

        let model = try await VRMModel.load(from: url, device: device)

        // Verify version detection
        XCTAssertEqual(model.specVersion, .v0_0, "Model should be detected as VRM 0.0")
        XCTAssertTrue(model.isVRM0, "isVRM0 should be true")

        print("=== VRM 0.0 Model Info ===")
        print("  Name: \(model.meta.name ?? "unnamed")")
        print("  Spec Version: \(model.specVersion)")
        print("  Materials: \(model.materials.count)")
    }

    func testVRM0MaterialVersionPropagation() async throws {
        let vrm0Path = ProcessInfo.processInfo.environment["VRM_TEST_VRM0_PATH"]
            ?? "/Users/arkavo/Documents/VRMModels/AvatarSample_A.vrm.glb"

        let url = URL(fileURLWithPath: vrm0Path)
        guard FileManager.default.fileExists(atPath: vrm0Path) else {
            throw XCTSkip("VRM 0.0 test model not found at: \(vrm0Path)")
        }

        let model = try await VRMModel.load(from: url, device: device)

        // Verify ALL materials have version set to v0_0
        XCTAssertFalse(model.materials.isEmpty, "Model should have materials")

        print("\n=== VRM 0.0 Material Version Check ===")
        for (index, material) in model.materials.enumerated() {
            print("  Material[\(index)] '\(material.name ?? "unnamed")': vrmVersion = \(material.vrmVersion)")
            XCTAssertEqual(material.vrmVersion, .v0_0,
                          "Material \(index) (\(material.name ?? "unnamed")) should have vrmVersion = .v0_0")
        }
        print("  All \(model.materials.count) materials have correct VRM 0.0 version")
    }

    func testVRM0MToonUniformsVersion() async throws {
        let vrm0Path = ProcessInfo.processInfo.environment["VRM_TEST_VRM0_PATH"]
            ?? "/Users/arkavo/Documents/VRMModels/AvatarSample_A.vrm.glb"

        let url = URL(fileURLWithPath: vrm0Path)
        guard FileManager.default.fileExists(atPath: vrm0Path) else {
            throw XCTSkip("VRM 0.0 test model not found at: \(vrm0Path)")
        }

        let model = try await VRMModel.load(from: url, device: device)

        print("\n=== VRM 0.0 MToonMaterialUniforms Version Check ===")
        for (index, material) in model.materials.enumerated() {
            // Simulate what renderer does
            var mtoonUniforms = MToonMaterialUniforms()
            mtoonUniforms.vrmVersion = material.vrmVersion == .v0_0 ? 0 : 1

            print("  Material[\(index)]: uniform.vrmVersion = \(mtoonUniforms.vrmVersion)")
            XCTAssertEqual(mtoonUniforms.vrmVersion, 0,
                          "MToonMaterialUniforms.vrmVersion should be 0 for VRM 0.0")
        }
    }

    // MARK: - VRM 1.0 Tests

    func testVRM1ModelVersionDetection() async throws {
        let vrm1Path = ProcessInfo.processInfo.environment["VRM_TEST_VRM1_PATH"]
            ?? "/Users/arkavo/Documents/VRMModels/Seed-san.vrm"

        let url = URL(fileURLWithPath: vrm1Path)
        guard FileManager.default.fileExists(atPath: vrm1Path) else {
            throw XCTSkip("VRM 1.0 test model not found at: \(vrm1Path)")
        }

        let model = try await VRMModel.load(from: url, device: device)

        // Verify version detection
        XCTAssertEqual(model.specVersion, .v1_0, "Model should be detected as VRM 1.0")
        XCTAssertFalse(model.isVRM0, "isVRM0 should be false")

        print("\n=== VRM 1.0 Model Info ===")
        print("  Name: \(model.meta.name ?? "unnamed")")
        print("  Spec Version: \(model.specVersion)")
        print("  Materials: \(model.materials.count)")
    }

    func testVRM1MaterialVersionPropagation() async throws {
        let vrm1Path = ProcessInfo.processInfo.environment["VRM_TEST_VRM1_PATH"]
            ?? "/Users/arkavo/Documents/VRMModels/Seed-san.vrm"

        let url = URL(fileURLWithPath: vrm1Path)
        guard FileManager.default.fileExists(atPath: vrm1Path) else {
            throw XCTSkip("VRM 1.0 test model not found at: \(vrm1Path)")
        }

        let model = try await VRMModel.load(from: url, device: device)

        // Verify ALL materials have version set to v1_0
        XCTAssertFalse(model.materials.isEmpty, "Model should have materials")

        print("\n=== VRM 1.0 Material Version Check ===")
        for (index, material) in model.materials.enumerated() {
            print("  Material[\(index)] '\(material.name ?? "unnamed")': vrmVersion = \(material.vrmVersion)")
            XCTAssertEqual(material.vrmVersion, .v1_0,
                          "Material \(index) (\(material.name ?? "unnamed")) should have vrmVersion = .v1_0")
        }
        print("  All \(model.materials.count) materials have correct VRM 1.0 version")
    }

    func testVRM1MToonUniformsVersion() async throws {
        let vrm1Path = ProcessInfo.processInfo.environment["VRM_TEST_VRM1_PATH"]
            ?? "/Users/arkavo/Documents/VRMModels/Seed-san.vrm"

        let url = URL(fileURLWithPath: vrm1Path)
        guard FileManager.default.fileExists(atPath: vrm1Path) else {
            throw XCTSkip("VRM 1.0 test model not found at: \(vrm1Path)")
        }

        let model = try await VRMModel.load(from: url, device: device)

        print("\n=== VRM 1.0 MToonMaterialUniforms Version Check ===")
        for (index, material) in model.materials.enumerated() {
            // Simulate what renderer does
            var mtoonUniforms = MToonMaterialUniforms()
            mtoonUniforms.vrmVersion = material.vrmVersion == .v0_0 ? 0 : 1

            print("  Material[\(index)]: uniform.vrmVersion = \(mtoonUniforms.vrmVersion)")
            XCTAssertEqual(mtoonUniforms.vrmVersion, 1,
                          "MToonMaterialUniforms.vrmVersion should be 1 for VRM 1.0")
        }
    }

    // MARK: - Comparison Test

    func testVersionDifferentiationBetweenModels() async throws {
        let vrm0Path = ProcessInfo.processInfo.environment["VRM_TEST_VRM0_PATH"]
            ?? "/Users/arkavo/Documents/VRMModels/AvatarSample_A.vrm.glb"
        let vrm1Path = ProcessInfo.processInfo.environment["VRM_TEST_VRM1_PATH"]
            ?? "/Users/arkavo/Documents/VRMModels/Seed-san.vrm"

        guard FileManager.default.fileExists(atPath: vrm0Path) else {
            throw XCTSkip("VRM 0.0 test model not found")
        }
        guard FileManager.default.fileExists(atPath: vrm1Path) else {
            throw XCTSkip("VRM 1.0 test model not found")
        }

        let vrm0Model = try await VRMModel.load(from: URL(fileURLWithPath: vrm0Path), device: device)
        let vrm1Model = try await VRMModel.load(from: URL(fileURLWithPath: vrm1Path), device: device)

        print("\n=== Version Differentiation Test ===")
        print("VRM 0.0 model: \(vrm0Model.meta.name ?? "unnamed")")
        print("  - specVersion: \(vrm0Model.specVersion)")
        print("  - isVRM0: \(vrm0Model.isVRM0)")
        print("  - material[0].vrmVersion: \(vrm0Model.materials.first?.vrmVersion ?? .v1_0)")

        print("\nVRM 1.0 model: \(vrm1Model.meta.name ?? "unnamed")")
        print("  - specVersion: \(vrm1Model.specVersion)")
        print("  - isVRM0: \(vrm1Model.isVRM0)")
        print("  - material[0].vrmVersion: \(vrm1Model.materials.first?.vrmVersion ?? .v0_0)")

        // Verify they're different
        XCTAssertNotEqual(vrm0Model.specVersion, vrm1Model.specVersion,
                         "VRM 0.0 and VRM 1.0 models should have different spec versions")
        XCTAssertNotEqual(vrm0Model.materials.first?.vrmVersion, vrm1Model.materials.first?.vrmVersion,
                         "Materials should have different vrmVersion values")

        print("\n✅ Version differentiation working correctly!")
    }
}
