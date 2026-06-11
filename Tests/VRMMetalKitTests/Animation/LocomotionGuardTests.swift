import XCTest
import Metal
import simd
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
        // Locate the repo root by marker (Package.swift), not fixed depth, so
        // moving this file can't silently misroute the grep. No marker within
        // 8 levels ⇒ no source checkout (CI runner) ⇒ skip. Marker found but a
        // banned-list source missing ⇒ loud failure (structure regression).
        var probe = thisFile.deletingLastPathComponent()
        var foundRoot: URL?
        for _ in 0..<8 {
            if FileManager.default.fileExists(atPath: probe.appendingPathComponent("Package.swift").path) {
                foundRoot = probe
                break
            }
            probe.deleteLastPathComponent()
        }
        guard let repoRoot = foundRoot else {
            throw XCTSkip("no Package.swift above \(thisFile.path) — source checkout not reachable; the lint workflow greps sources as the CI backstop")
        }
        let sources = [
            "Sources/VRMMetalKit/Animation/Layers/LocomotionBlendLayer.swift",
            "Sources/VRMMetalKit/Animation/Layers/LocomotionBlendMath.swift",
        ]
        let banned = ["CACurrentMediaTime", "Date(", "DispatchTime.now", "ProcessInfo.processInfo.systemUptime"]
        for rel in sources {
            let fileURL = repoRoot.appendingPathComponent(rel)
            // The checkout exists (marker found) — a missing source file here
            // is a real structure regression, not an environment gap.
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: fileURL.path),
                "\(rel) missing under \(repoRoot.path) — banned-list paths out of date?"
            )
            let text = try String(contentsOf: fileURL, encoding: .utf8)
            for token in banned {
                XCTAssertFalse(text.contains(token),
                               "\(rel) must not use \(token) — caller-dt purity (locomotion design §7)")
            }
        }
    }

    /// The compositor applies `base * delta`; the locomotion layer emits
    /// rest-relative deltas. Together they must reproduce the clip rotation
    /// exactly — this is the seam no per-task test covered.
    func testCompositorProducesClipPoseThroughLocomotionLayer() async throws {
        let modelURL = URL(fileURLWithPath: getTestVRM10ModelPath())
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw XCTSkip("AvatarSample_A_1.0.vrm.glb fixture not present")
        }
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device not available")
        }
        let model = try await VRMModel.load(from: modelURL, device: device)

        var walk = AnimationClip(duration: 1.0)
        walk.locomotion = LocomotionMetadata(version: 1, strideSpeed: 1.5, inPlace: true, sourceHipsHeight: 0.85)
        let fixedQ = simd_quatf(angle: 0.35, axis: SIMD3<Float>(1, 0, 0))
        walk.addJointTrack(JointTrack(bone: .rightUpperLeg, rotationSampler: { _ in fixedQ }))
        var idle = AnimationClip(duration: 1.0)
        idle.locomotion = LocomotionMetadata(version: 1, strideSpeed: 0, inPlace: true, sourceHipsHeight: 0.85)
        idle.addJointTrack(JointTrack(bone: .rightUpperLeg, rotationSampler: { _ in fixedQ }))

        let compositor = AnimationLayerCompositor()
        compositor.setup(model: model)
        let layer = LocomotionBlendLayer()
        layer.setup(model: model)
        try layer.setClips(idle: idle, walk: walk)
        layer.targetSpeed = 1.5
        compositor.addLayer(layer)
        compositor.update(deltaTime: 1.0 / 60.0, context: AnimationContext())

        let humanoid = try XCTUnwrap(model.humanoid)
        let idx = try XCTUnwrap(humanoid.getBoneNode(.rightUpperLeg))
        let applied = model.nodes[idx].rotation
        let dot = abs(simd_dot(applied.vector, fixedQ.vector))
        XCTAssertEqual(dot, 1.0, accuracy: 1e-4,
                       "compositor(base * layerDelta) must reproduce the clip rotation")
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
