// Copyright 2025 Arkavo Inc. and contributors
// Licensed under the Apache License, Version 2.0

import XCTest
import Metal
import simd
@testable import VRMMetalKit

/// Tests for VRM 1.0 per-material VRMC_materials_mtoon extension parsing.
///
/// These tests verify that VRM 1.0 material extensions are properly decoded
/// from the glTF JSON, enabling correct rendering of shade colors, alpha modes,
/// and other MToon properties.
///
/// Related GitHub Issues: #104, #105
///
final class VRM1_0MaterialExtensionTests: XCTestCase {

    var device: MTLDevice!

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
    }

    // MARK: - VRM 1.0 Material Extension Tests

    /// Test: VRM 1.0 model has MToon material parsed from per-material extensions
    func testVRM1_0HasMToonMaterial() async throws {
        guard FileManager.default.fileExists(atPath: vrm1Path) else {
            throw XCTSkip("VRM 1.0 test model not found at \(vrm1Path)")
        }

        let model = try await VRMModel.load(from: URL(fileURLWithPath: vrm1Path), device: device)

        // VRM 1.0 models should have MToon materials parsed from VRMC_materials_mtoon extension
        let hasMToon = model.materials.contains { $0.mtoon != nil }

        print("=== VRM 1.0 Material Analysis ===")
        print("Total materials: \(model.materials.count)")
        print("Materials with MToon: \(model.materials.filter { $0.mtoon != nil }.count)")

        for (i, material) in model.materials.enumerated() {
            let hasMToonStr = material.mtoon != nil ? "YES" : "NO"
            print("  Material \(i) '\(material.name ?? "unnamed")': MToon=\(hasMToonStr), alphaMode=\(material.alphaMode)")
        }

        XCTAssertTrue(hasMToon, "VRM 1.0 model should have MToon materials parsed from extensions")
    }

    /// Test: Shade color is parsed from VRMC_materials_mtoon extension
    func testVRM1_0ShadeColorParsed() async throws {
        guard FileManager.default.fileExists(atPath: vrm1Path) else {
            throw XCTSkip("VRM 1.0 test model not found at \(vrm1Path)")
        }

        let model = try await VRMModel.load(from: URL(fileURLWithPath: vrm1Path), device: device)

        print("=== VRM 1.0 Shade Color Analysis ===")
        var materialsWithShadeColor = 0

        for (i, material) in model.materials.enumerated() {
            guard let mtoon = material.mtoon else { continue }
            let shadeColor = mtoon.shadeColorFactor

            // Check if shade color is non-black (default)
            let isNonBlack = shadeColor.x > 0.001 || shadeColor.y > 0.001 || shadeColor.z > 0.001
            if isNonBlack {
                materialsWithShadeColor += 1
            }

            print("  Material \(i) '\(material.name ?? "unnamed")': shadeColor=(\(String(format: "%.3f", shadeColor.x)), \(String(format: "%.3f", shadeColor.y)), \(String(format: "%.3f", shadeColor.z)))")
        }

        print("Materials with non-black shade color: \(materialsWithShadeColor)")

        // Note: Some materials may legitimately have black shade color
        // This test verifies the parsing pipeline is working
    }

    /// Test: Alpha mode is correctly preserved from glTF material
    func testVRM1_0AlphaModeParsed() async throws {
        guard FileManager.default.fileExists(atPath: vrm1Path) else {
            throw XCTSkip("VRM 1.0 test model not found at \(vrm1Path)")
        }

        let model = try await VRMModel.load(from: URL(fileURLWithPath: vrm1Path), device: device)

        print("=== VRM 1.0 Alpha Mode Analysis ===")

        var alphaModeCount: [String: Int] = [:]
        for material in model.materials {
            alphaModeCount[material.alphaMode, default: 0] += 1
        }

        for (mode, count) in alphaModeCount.sorted(by: { $0.key < $1.key }) {
            print("  \(mode): \(count) materials")
        }

        // VRM models typically have OPAQUE materials for skin/clothing
        XCTAssertTrue(alphaModeCount["OPAQUE", default: 0] > 0 || alphaModeCount["opaque", default: 0] > 0,
                      "VRM 1.0 model should have OPAQUE materials")
    }

    /// Test: Toony factor is parsed (controls toon shading sharpness)
    func testVRM1_0ToonyFactorParsed() async throws {
        guard FileManager.default.fileExists(atPath: vrm1Path) else {
            throw XCTSkip("VRM 1.0 test model not found at \(vrm1Path)")
        }

        let model = try await VRMModel.load(from: URL(fileURLWithPath: vrm1Path), device: device)

        print("=== VRM 1.0 Toony Factor Analysis ===")

        for (i, material) in model.materials.enumerated() {
            guard let mtoon = material.mtoon else { continue }
            print("  Material \(i) '\(material.name ?? "unnamed")': shadingToonyFactor=\(String(format: "%.3f", mtoon.shadingToonyFactor))")
        }

        // At least one material should have non-default toony factor
        let hasNonDefaultToony = model.materials.contains { material in
            guard let mtoon = material.mtoon else { return false }
            // Default is 0.9, check if any material has different value
            return abs(mtoon.shadingToonyFactor - 0.9) > 0.001
        }

        // This is informational - some models may use default values
        print("Has non-default toony factor: \(hasNonDefaultToony)")
    }

    // MARK: - VRM 0.0 Backward Compatibility Tests

    /// Test: VRM 0.0 models still work correctly (regression test)
    func testVRM0_0StillWorks() async throws {
        guard FileManager.default.fileExists(atPath: vrm0Path) else {
            throw XCTSkip("VRM 0.0 test model not found at \(vrm0Path)")
        }

        let model = try await VRMModel.load(from: URL(fileURLWithPath: vrm0Path), device: device)

        print("=== VRM 0.0 Compatibility Check ===")
        print("Model loaded: \(model.meta.name ?? "unnamed")")
        print("isVRM0: \(model.isVRM0)")
        print("Materials: \(model.materials.count)")

        // VRM 0.0 models should still load and have materials
        XCTAssertTrue(model.isVRM0, "Model should be detected as VRM 0.0")
        XCTAssertGreaterThan(model.materials.count, 0, "VRM 0.0 model should have materials")

        // VRM 0.0 models get MToon from document-level materialProperties
        let hasMToon = model.materials.contains { $0.mtoon != nil }
        print("Has MToon materials: \(hasMToon)")
    }

    // MARK: - Extension Parsing Verification

    /// Test: Verify extensions field is being decoded (not nil)
    func testExtensionsFieldDecoded() async throws {
        // This test verifies the fix for GLTFParser.swift line 251
        // where extensions was previously hardcoded to nil

        guard FileManager.default.fileExists(atPath: vrm1Path) else {
            throw XCTSkip("VRM 1.0 test model not found")
        }

        let model = try await VRMModel.load(from: URL(fileURLWithPath: vrm1Path), device: device)

        // If VRM 1.0 materials have MToon data, extensions were decoded
        let vrm1HasMToon = model.materials.contains { $0.mtoon != nil }

        if !model.isVRM0 {
            // For VRM 1.0 models, MToon comes from per-material extensions
            XCTAssertTrue(vrm1HasMToon,
                         "VRM 1.0 model should have MToon from per-material VRMC_materials_mtoon extension")
        }
    }
}
