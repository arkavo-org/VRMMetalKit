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

/// VMK#287 — VRMC_materials_hdr_emissiveMultiplier-1.0 and the named
/// glTF replacement KHR_materials_emissive_strength were both unwired on
/// the VRM MToon material parser (PR #277 wired KHR for the plain-glTF
/// PBR sibling-package path only). Both extensions multiply
/// `material.emissiveFactor` by a scalar; the conformance suite's
/// 7-variant emissiveMultiplier sweep produced 1 distinct PNG before the
/// fix, 7 after.
///
/// These tests synthesise a minimal `GLTFMaterial` in memory and assert
/// the resulting `VRMMaterial.emissiveFactor` carries the multiplier.
/// No bundled fixture needed.
final class MToonEmissiveMultiplierTests: XCTestCase {

    /// VRMC variant — the VRM-spec extension. Multiplier `2.0` on a
    /// declared factor `[0.4, 0.2, 0.1]` must yield `[0.8, 0.4, 0.2]`.
    func testVRMCEmissiveMultiplierIsApplied() throws {
        let material = try makeMaterial(
            emissiveFactor: [0.4, 0.2, 0.1],
            extensions: [
                "VRMC_materials_hdr_emissiveMultiplier": [
                    "emissiveMultiplier": 2.0
                ]
            ]
        )
        XCTAssertEqual(material.emissiveFactor.x, 0.8, accuracy: 1e-6)
        XCTAssertEqual(material.emissiveFactor.y, 0.4, accuracy: 1e-6)
        XCTAssertEqual(material.emissiveFactor.z, 0.2, accuracy: 1e-6)
    }

    /// KHR variant — the named glTF replacement. Same math.
    func testKHREmissiveStrengthIsApplied() throws {
        let material = try makeMaterial(
            emissiveFactor: [0.4, 0.2, 0.1],
            extensions: [
                "KHR_materials_emissive_strength": [
                    "emissiveStrength": 2.0
                ]
            ]
        )
        XCTAssertEqual(material.emissiveFactor.x, 0.8, accuracy: 1e-6)
        XCTAssertEqual(material.emissiveFactor.y, 0.4, accuracy: 1e-6)
        XCTAssertEqual(material.emissiveFactor.z, 0.2, accuracy: 1e-6)
    }

    /// Both extensions present — VRMC wins. `0.5 * [0.4, 0.2, 0.1] = [0.2, 0.1, 0.05]`.
    /// If KHR's `2.0` was applied instead, we'd see `[0.8, 0.4, 0.2]`.
    func testVRMCWinsWhenBothExtensionsPresent() throws {
        let material = try makeMaterial(
            emissiveFactor: [0.4, 0.2, 0.1],
            extensions: [
                "VRMC_materials_hdr_emissiveMultiplier": [
                    "emissiveMultiplier": 0.5
                ],
                "KHR_materials_emissive_strength": [
                    "emissiveStrength": 2.0
                ]
            ]
        )
        XCTAssertEqual(material.emissiveFactor.x, 0.2, accuracy: 1e-6,
            "VRMC variant must take precedence when both extensions are present")
        XCTAssertEqual(material.emissiveFactor.y, 0.1, accuracy: 1e-6)
        XCTAssertEqual(material.emissiveFactor.z, 0.05, accuracy: 1e-6)
    }

    /// Neither extension present — factor unchanged.
    func testNoExtensionLeavesEmissiveFactorAlone() throws {
        let material = try makeMaterial(
            emissiveFactor: [0.4, 0.2, 0.1],
            extensions: nil
        )
        XCTAssertEqual(material.emissiveFactor.x, 0.4, accuracy: 1e-6)
        XCTAssertEqual(material.emissiveFactor.y, 0.2, accuracy: 1e-6)
        XCTAssertEqual(material.emissiveFactor.z, 0.1, accuracy: 1e-6)
    }

    /// Multiplier `0` zeros the emissive — covers the
    /// `mtoon_emissive_multiplier_0` corpus variant from the issue body.
    func testMultiplierZeroProducesZeroEmissive() throws {
        let material = try makeMaterial(
            emissiveFactor: [0.7, 0.8, 0.9],
            extensions: [
                "VRMC_materials_hdr_emissiveMultiplier": [
                    "emissiveMultiplier": 0.0
                ]
            ]
        )
        XCTAssertEqual(material.emissiveFactor.x, 0, accuracy: 1e-6)
        XCTAssertEqual(material.emissiveFactor.y, 0, accuracy: 1e-6)
        XCTAssertEqual(material.emissiveFactor.z, 0, accuracy: 1e-6)
    }

    /// Same Int-vs-Double parse-coercion bug class as VMK#239. JSON
    /// `2` (Int literal) must coerce just like JSON `2.0` (Double).
    func testJSONIntegerMultiplierCoercion() throws {
        // The JSON literal `2` (no decimal point) decodes as Int through
        // JSONSerialization → AnyCodable; the parser's floatScalar helper
        // must accept that branch.
        let material = try makeMaterial(
            emissiveFactor: [0.4, 0.2, 0.1],
            extensionsJSON: """
            { "VRMC_materials_hdr_emissiveMultiplier": { "emissiveMultiplier": 2 } }
            """
        )
        XCTAssertEqual(material.emissiveFactor.x, 0.8, accuracy: 1e-6,
            "Int(2) multiplier must coerce identically to Double(2.0); regression-locks the floatScalar branch")
        XCTAssertEqual(material.emissiveFactor.y, 0.4, accuracy: 1e-6)
        XCTAssertEqual(material.emissiveFactor.z, 0.2, accuracy: 1e-6)
    }

    // MARK: - Harness

    private func makeMaterial(
        emissiveFactor: [Float],
        extensions: [String: Any]?
    ) throws -> VRMMaterial {
        var materialJSON: [String: Any] = [
            "emissiveFactor": emissiveFactor
        ]
        if let extensions = extensions {
            materialJSON["extensions"] = extensions
        }
        let data = try JSONSerialization.data(withJSONObject: materialJSON)
        let gltfMaterial = try JSONDecoder().decode(GLTFMaterial.self, from: data)
        return VRMMaterial(from: gltfMaterial, textures: [])
    }

    /// Overload that takes a raw extensions JSON string so callers can
    /// pin exact JSON-number literal types (Int vs Double) — required
    /// for the coercion test.
    private func makeMaterial(
        emissiveFactor: [Float],
        extensionsJSON: String
    ) throws -> VRMMaterial {
        let efBytes = try JSONSerialization.data(withJSONObject: emissiveFactor)
        let efString = String(data: efBytes, encoding: .utf8)!
        let fullJSON = """
        { "emissiveFactor": \(efString), "extensions": \(extensionsJSON) }
        """
        let data = fullJSON.data(using: .utf8)!
        let gltfMaterial = try JSONDecoder().decode(GLTFMaterial.self, from: data)
        return VRMMaterial(from: gltfMaterial, textures: [])
    }
}
