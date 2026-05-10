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
import Metal
import simd
@testable import VRMMetalKit

/// Local regression gate for the SpringBone equilibrium described in #162.
///
/// The parser quirk in `VRMExtensionParser.parseSecondaryAnimation`
/// (forcing `gravityPower=0 → 1.0` for VRM 0.x) and the upward-only
/// inertia compensation block in the `springBonePredict` Metal kernel
/// (re-enabled in PR #143) form a load-bearing combination. Touching either in isolation
/// has historically broken hair behavior on AvatarSample_A. This test
/// freezes a *summary characterization* of currently shipping behavior so
/// any future spring-bone change must either preserve it or knowingly
/// regenerate the baseline.
///
/// **Determinism trick.** The renderer derives spring `deltaTime` from
/// `CACurrentMediaTime()` and clamps it to a max of `1/30 s`. Offscreen
/// 64×64 frames complete in under a millisecond, so without help the
/// real per-frame dt is sub-ms and varies wildly between runs. The
/// test deliberately blocks for ≥ 35 ms before each render so dt
/// always saturates the clamp at exactly `1/30 s`. With dt fixed,
/// substep count and timing are deterministic and trajectories are
/// reproducible across runs.
///
/// Even with that, GPU threadgroup-reduction order and other low-level
/// non-determinism contribute small noise (~1 mm). The gate uses
/// per-bone **mean world position** averaged over the full 4-second
/// simulation, with a 5 mm tolerance — large enough to absorb GPU
/// noise, small enough to flag any real equilibrium shift.
///
/// The test is **not** a correctness assertion against any other VRM
/// implementation — that's QA's vrm-conformance suite. This is a
/// same-model characterization test.
///
/// **Regenerating the baseline.** When an intentional spring-bone change
/// lands, set `VRM162_REGENERATE_BASELINE=1` and re-run the test once.
/// The current summary is written to the source-tree CSV; commit it
/// alongside the change with an explanation.
final class SpringBoneRegressionTests: XCTestCase {

    private var device: MTLDevice!

    override func setUpWithError() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        self.device = device
    }

    /// Per-axis tolerance for mean-position comparison. With deltaTime
    /// pinned to the renderer's 1/30 s clamp, GPU non-determinism is
    /// the only remaining noise source (~1 mm); 5 mm gives comfortable
    /// margin while still flagging the multi-cm drift real spring-bone
    /// changes produce.
    private static let meanTolerance: Float = 0.005

    /// Minimum wall-clock between frames to force the renderer's
    /// `deltaTime` clamp to engage. 1/30 s + a few ms slack.
    private static let minFrameIntervalNanos: UInt64 = 35_000_000

    @MainActor
    func testAvatarSampleASpringBoneTrajectoryMatchesBaseline() async throws {
        let modelPath = getTestVRM10ModelPath()
        try requireFixture(modelPath, hint: testVRM10Filename)

        let samples = try await captureSpringBoneTrajectory(modelPath: modelPath)
        XCTAssertGreaterThan(samples.count, 0, "Trajectory dumper produced no samples")

        let observed = summarize(samples: samples)

        if ProcessInfo.processInfo.environment["VRM162_REGENERATE_BASELINE"] == "1" {
            let outPath = baselineSourcePath()
            try writeBaseline(summaries: observed, to: outPath)
            print("[SpringBoneRegression] Regenerated baseline at \(outPath) (\(observed.count) bones)")
            return
        }

        let baseline = try loadBaseline()
        try compare(observed: observed, baseline: baseline)
    }

    // MARK: - Trajectory capture

    @MainActor
    private func captureSpringBoneTrajectory(modelPath: String) async throws -> [BoneTrajectoryDumper.Sample] {
        let model = try await VRMModel.load(
            from: URL(fileURLWithPath: modelPath),
            device: device
        )

        let clip = makeHeadShakeClip(durationSeconds: 4.0)
        let player = AnimationPlayer()
        player.load(clip)
        player.play()

        var config = RendererConfig()
        config.sampleCount = 1
        config.strict = .off
        let renderer = VRMRenderer(device: device, config: config)
        renderer.loadModel(model)
        renderer.enableSpringBone = true
        renderer.viewMatrix = matrix_identity_float4x4
        renderer.projectionMatrix = matrix_identity_float4x4

        let colorDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 64, height: 64, mipmapped: false)
        colorDesc.usage = [.renderTarget, .shaderRead]
        colorDesc.storageMode = .private
        let depthDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float, width: 64, height: 64, mipmapped: false)
        depthDesc.usage = .renderTarget
        depthDesc.storageMode = .private
        guard let colorTex = device.makeTexture(descriptor: colorDesc),
              let depthTex = device.makeTexture(descriptor: depthDesc),
              let queue = device.makeCommandQueue() else {
            throw XCTSkip("Could not allocate Metal resources")
        }

        let dumper = try BoneTrajectoryDumper()
        let fps: Float = 30
        let frameCount = 120
        let dt: Float = 1.0 / fps

        for frameIndex in 0..<frameCount {
            // Pin renderer's wall-clock-derived spring deltaTime to its
            // 1/30 s clamp by holding off this frame for ≥ 35 ms.
            // Skipped on the first frame (renderer uses 1/60 s default
            // when lastUpdateTime is zero).
            if frameIndex > 0 {
                try await Task.sleep(nanoseconds: Self.minFrameIntervalNanos)
            }

            player.update(deltaTime: dt, model: model)

            guard let cb = queue.makeCommandBuffer() else {
                XCTFail("Could not create command buffer at frame \(frameIndex)")
                return dumper.inMemorySamples
            }
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = colorTex
            rpd.colorAttachments[0].loadAction = .clear
            rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            rpd.colorAttachments[0].storeAction = .store
            rpd.depthAttachment.texture = depthTex
            rpd.depthAttachment.loadAction = .clear
            rpd.depthAttachment.clearDepth = 1.0
            rpd.depthAttachment.storeAction = .dontCare

            renderer.drawOffscreenHeadless(
                to: colorTex, depth: depthTex,
                commandBuffer: cb, renderPassDescriptor: rpd
            )
            cb.commit()
            while cb.status != .completed && cb.status != .error {
                await Task.yield()
            }

            dumper.recordFrame(
                model: model,
                frameIndex: frameIndex,
                timeSeconds: Double(frameIndex) * Double(dt)
            )
        }

        return dumper.inMemorySamples
    }

    /// 1 Hz, ±15° head shake around Y. Cyclic input that exercises both
    /// the parser quirk (gravityPower) and inertia compensation paths.
    private func makeHeadShakeClip(durationSeconds: Float) -> AnimationClip {
        var clip = AnimationClip(duration: durationSeconds)
        let amplitudeRad: Float = .pi / 12     // 15°
        let frequencyHz: Float = 1.0
        let track = JointTrack(
            bone: .head,
            rotationSampler: { time in
                let angle = amplitudeRad * sin(2 * .pi * frequencyHz * time)
                return simd_quatf(angle: angle, axis: SIMD3<Float>(0, 1, 0))
            }
        )
        clip.addJointTrack(track)
        return clip
    }

    // MARK: - Per-bone summary

    /// Per-bone mean-position summary. Mean averages out phase jitter
    /// from wall-clock-derived spring deltaTime while moving when the
    /// equilibrium genuinely drifts.
    fileprivate struct BoneSummary {
        let bone: String
        let meanX: Float
        let meanY: Float
        let meanZ: Float
    }

    private func summarize(samples: [BoneTrajectoryDumper.Sample]) -> [BoneSummary] {
        struct Acc {
            var sum = SIMD3<Float>.zero
            var n: Int = 0
        }
        var accs: [String: Acc] = [:]
        for s in samples {
            var a = accs[s.bone] ?? Acc()
            a.sum += s.world
            a.n += 1
            accs[s.bone] = a
        }
        return accs.keys.sorted().map { bone in
            let a = accs[bone]!
            let mean = a.sum / Float(a.n)
            return BoneSummary(bone: bone, meanX: mean.x, meanY: mean.y, meanZ: mean.z)
        }
    }

    // MARK: - Baseline I/O

    private func baselineSourcePath() -> String {
        return "\(getProjectRoot())/Tests/VRMMetalKitTests/TestData/SpringBoneRegression/avatar_a_baseline.csv"
    }

    private static let csvHeader = "bone,meanX,meanY,meanZ\n"

    private func loadBaseline() throws -> [BoneSummary] {
        guard let url = Bundle.module.url(
            forResource: "avatar_a_baseline",
            withExtension: "csv",
            subdirectory: "TestData/SpringBoneRegression"
        ) else {
            XCTFail("""
                Baseline missing. Generate it with:
                  VRM162_REGENERATE_BASELINE=1 swift test --filter SpringBoneRegressionTests --disable-sandbox
                Then commit the file at Tests/VRMMetalKitTests/TestData/SpringBoneRegression/avatar_a_baseline.csv.
                """)
            throw XCTSkip("baseline missing")
        }
        let content = try String(contentsOf: url, encoding: .utf8)
        var out: [BoneSummary] = []
        for (i, line) in content.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
            if i == 0, line.hasPrefix("bone,") { continue }
            let f = line.split(separator: ",", omittingEmptySubsequences: false)
            guard f.count == 4 else { continue }
            let nums = f[1..<4].compactMap { Float($0) }
            guard nums.count == 3 else { continue }
            out.append(BoneSummary(bone: String(f[0]), meanX: nums[0], meanY: nums[1], meanZ: nums[2]))
        }
        return out
    }

    private func writeBaseline(summaries: [BoneSummary], to path: String) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var content = Self.csvHeader
        for s in summaries {
            content += String(format: "%@,%.6f,%.6f,%.6f\n", s.bone, s.meanX, s.meanY, s.meanZ)
        }
        try content.write(toFile: path, atomically: true, encoding: .utf8)
    }

    // MARK: - Comparison

    private func compare(observed: [BoneSummary], baseline: [BoneSummary]) throws {
        XCTAssertGreaterThan(baseline.count, 0, "Baseline parsed empty")
        let baselineByBone = Dictionary(uniqueKeysWithValues: baseline.map { ($0.bone, $0) })
        let observedByBone = Dictionary(uniqueKeysWithValues: observed.map { ($0.bone, $0) })

        var addedInObserved: [String] = []
        var droppedFromBaseline: [String] = []
        var worst: (bone: String, axis: String, delta: Float)? = nil

        for o in observed {
            guard let b = baselineByBone[o.bone] else {
                addedInObserved.append(o.bone)
                continue
            }
            let deltas: [(String, Float)] = [
                ("x", abs(o.meanX - b.meanX)),
                ("y", abs(o.meanY - b.meanY)),
                ("z", abs(o.meanZ - b.meanZ)),
            ]
            for (axis, d) in deltas where d > Self.meanTolerance {
                if worst == nil || d > worst!.delta {
                    worst = (o.bone, axis, d)
                }
            }
        }

        for b in baseline where observedByBone[b.bone] == nil {
            droppedFromBaseline.append(b.bone)
        }

        XCTAssertEqual(addedInObserved.count, 0,
                       "Spring bones added since baseline: \(addedInObserved.prefix(5))")
        XCTAssertEqual(droppedFromBaseline.count, 0,
                       "Spring bones dropped vs baseline: \(droppedFromBaseline.prefix(5))")

        if let w = worst {
            XCTFail("""
                SpringBone regression gate (#162) failed.

                  mean-position drift: bone=\(w.bone) axis=\(w.axis) Δ=\(w.delta) m (tolerance \(Self.meanTolerance) m)

                If this drift is intentional (e.g. an approved spring-bone change),
                regenerate the baseline:
                  VRM162_REGENERATE_BASELINE=1 swift test \\
                    --filter SpringBoneRegressionTests --disable-sandbox
                and commit the updated CSV with the change's explanation.
                """)
        }
    }
}
