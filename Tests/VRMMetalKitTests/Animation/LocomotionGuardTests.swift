import XCTest
import VRMAProcessKit
@testable import VRMMetalKit

final class LocomotionGuardTests: XCTestCase {
    /// Locomotion design §5: the composition stack is a contract.
    /// Locomotion (base) → breathing (additive) → expression → lookAt → IK last.
    func testCanonicalLayerOrder() {
        let locomotion = LocomotionBlendLayer().priority
        let breathing = IdleBreathingLayer().priority
        let ik = IKLayer().priority  // IKLayer.init() is public and takes no arguments
        XCTAssertLessThan(locomotion, breathing, "locomotion is the base pose; breathing rides on top")
        XCTAssertLessThan(breathing, ik)
        // IK must be strictly last among the canonical set (expression 1, lookAt 2).
        XCTAssertTrue([locomotion, breathing, 1, 2].allSatisfy { $0 < ik },
                      "IKLayer must compose last so plant correction sees the final pose")
    }

    /// Locomotion design §7: clock APIs are forbidden in locomotion code paths.
    func testNoClockAPIsInLocomotionSources() throws {
        let thisFile = URL(fileURLWithPath: #filePath)
        // Path: Tests/VRMMetalKitTests/Animation/LocomotionGuardTests.swift
        // 4x deletingLastPathComponent: Animation → VRMMetalKitTests → Tests → repo root
        let repoRoot = thisFile
            .deletingLastPathComponent()  // Animation/
            .deletingLastPathComponent()  // VRMMetalKitTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // repo root
        let sources = [
            "Sources/VRMMetalKit/Animation/Layers/LocomotionBlendLayer.swift",
            "Sources/VRMMetalKit/Animation/Layers/LocomotionBlendMath.swift",
        ]
        let banned = ["CACurrentMediaTime", "Date(", "DispatchTime.now", "ProcessInfo.processInfo.systemUptime"]
        for rel in sources {
            let fileURL = repoRoot.appendingPathComponent(rel)
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: fileURL.path),
                "source file not found at \(fileURL.path) — repoRoot path math may be wrong"
            )
            let text = try String(contentsOf: fileURL, encoding: .utf8)
            for token in banned {
                XCTAssertFalse(text.contains(token),
                               "\(rel) must not use \(token) — caller-dt purity (locomotion design §7)")
            }
        }
    }

    /// The extras.arkavo block is the one cross-repo contract (design §4):
    /// what VRMAProcessKit WRITES, VRMAnimationLoader must READ. A key
    /// rename on the tool side that updates its own tests consistently
    /// would otherwise silently nil out engine-side metadata.
    func testToolWrittenExtrasParseInEngine() throws {
        // Minimal VRMA json the tool can stamp and the engine can load.
        let json: [String: Any] = [
            "asset": ["version": "2.0"],
            "buffers": [["byteLength": 32]],
            "bufferViews": [
                ["buffer": 0, "byteOffset": 0, "byteLength": 8],
                ["buffer": 0, "byteOffset": 8, "byteLength": 24],
            ],
            "accessors": [
                ["bufferView": 0, "componentType": 5126, "count": 2, "type": "SCALAR", "min": [0], "max": [1]],
                ["bufferView": 1, "componentType": 5126, "count": 2, "type": "VEC3"],
            ],
            "nodes": [["name": "hips"]],
            "animations": [[
                "channels": [["sampler": 0, "target": ["node": 0, "path": "translation"]]],
                "samplers": [["input": 0, "output": 1, "interpolation": "LINEAR"]],
            ]],
            "extensions": ["VRMC_vrm_animation": ["specVersion": "1.0",
                "humanoid": ["humanBones": ["hips": ["node": 0]]]]],
        ]
        var bin = Data()
        let times: [Float] = [0, 1], vals: [Float] = [0, 0.9, 0, 0, 0.9, 0]
        times.withUnsafeBytes { bin.append(contentsOf: $0) }
        vals.withUnsafeBytes { bin.append(contentsOf: $0) }
        var container = VRMAProcessKit.GLBContainer(json: json, bin: bin)
        let written = VRMAProcessKit.LocomotionExtras(strideSpeed: 1.42, inPlace: true, sourceHipsHeight: 0.9)
        try written.write(into: &container)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("contract-roundtrip.vrma")
        try container.serialize().write(to: url)

        let clip = try VRMAnimationLoader.loadVRMA(from: url, model: nil)
        let meta = try XCTUnwrap(clip.locomotion, "tool-written extras must parse in the engine")
        XCTAssertEqual(meta.strideSpeed, 1.42, accuracy: 1e-5)
        XCTAssertEqual(meta.version, 1)
        XCTAssertTrue(meta.inPlace)
        XCTAssertEqual(meta.sourceHipsHeight, 0.9, accuracy: 1e-5)
    }
}
