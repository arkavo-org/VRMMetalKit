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
import Metal
import simd
@testable import VRMMetalKit

final class SkinMeshCoverageTests: XCTestCase {

    @MainActor func testArmsAtSidesPlacesWristsBesideTheHips() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let path = getTestModelPath("AvatarSample_U_1.0.vrm.glb")
        try requireFixture(path, hint: "AvatarSample_U_1.0.vrm.glb")
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device,
            options: VRMLoadingOptions(augmentSpringBoneColliders: false))
        let humanoid = try XCTUnwrap(model.humanoid)

        let player = AnimationPlayer()
        player.load(StressPoseFactory.clip(.armsAtSides, duration: 1))
        player.play()
        player.update(deltaTime: 0.5, model: model)
        model.updateNodeTransforms()

        let hips = model.nodes[try XCTUnwrap(humanoid.getBoneNode(.hips))].worldPosition
        let wrist = model.nodes[try XCTUnwrap(humanoid.getBoneNode(.leftHand))].worldPosition
        let shoulder = model.nodes[try XCTUnwrap(humanoid.getBoneNode(.leftUpperArm))].worldPosition

        // Rest is T-pose, so the wrist starts level with the shoulder and far
        // lateral. At the sides it must be BELOW the shoulder and near the hips
        // in height — asserted, not eyeballed.
        XCTAssertLessThan(wrist.y, shoulder.y - 0.2, "the arm hangs down")
        XCTAssertLessThan(abs(wrist.y - hips.y), 0.25, "the wrist is beside the hips in height")
        XCTAssertLessThan(abs(wrist.x - hips.x), 0.30, "the wrist is close to the body laterally")
    }
}

extension SkinMeshCoverageTests {

    /// Hand and finger bones take a tighter bound. `SkinReferenceMeasureUtil`
    /// measured finger half-thickness directly against the skinned mesh on
    /// both fixtures (leftIndexProximal/Intermediate, leftMiddleProximal):
    /// 2.7mm-6.1mm across all three sampled joints. A flat 5mm body tolerance
    /// would equal or exceed that entire range, blinding the case this gate
    /// exists to catch, so hand/finger regions use 1mm instead.
    private static let handTolerance: Float = 0.001
    private static let bodyTolerance: Float = 0.005

    private static let handBones: Set<VRMHumanoidBone> = {
        var s: Set<VRMHumanoidBone> = [.leftHand, .rightHand]
        for bone in VRMHumanoidBone.allCases where "\(bone)".contains("Thumb")
            || "\(bone)".contains("Index") || "\(bone)".contains("Middle")
            || "\(bone)".contains("Ring") || "\(bone)".contains("Little") {
            s.insert(bone)
        }
        return s
    }()

    private static func tolerance(for region: VRMHumanoidBone?) -> Float {
        guard let region else { return bodyTolerance }
        return handBones.contains(region) ? handTolerance : bodyTolerance
    }

    /// Query set: ALL spring chains except those inside the body BY
    /// CONSTRUCTION, roots exempt. Bust is the only current exclusion — Bust
    /// joints sit inside the chest by construction, and the moment the torso
    /// is in the oracle they report deep permanent penetration that swamps
    /// the millimetre-scale finger signal.
    ///
    /// This was originally an allowlist (hair/skirt/hood/sleeve), inherited
    /// from the #309 cloth work where the subject was hair and skirts. That
    /// silently dropped `CatTail`, `CatEar`, and `TopsUpperArm` — real
    /// simulated appendages that can and do penetrate the body — from
    /// coverage entirely, which is how a cat-tail-through-hand defect went
    /// unmeasured. A denylist means every new chain type is queried by
    /// default; add an exclusion here only when a chain is INSIDE the body BY
    /// CONSTRUCTION (like Bust), never because a chain "isn't the kind of
    /// thing that usually penetrates."
    private func querySet(_ model: VRMModel) -> [(node: Int, radius: Float, chain: String)] {
        guard let springBone = model.springBone else { return [] }
        var out: [(Int, Float, String)] = []
        for spring in springBone.springs {
            let name = (spring.name ?? "").lowercased()
            guard !name.contains("bust") else { continue }
            for (i, joint) in spring.joints.enumerated() where i > 0 {
                out.append((joint.node, joint.hitRadius, spring.name ?? "?"))
            }
        }
        return out
    }

    /// Regression guard for #381 (hands/fingers penetrating simulated
    /// appendages): asserts no spring-simulated joint — hair, skirt, sleeve,
    /// cat tail/ear, or any other non-Bust chain — penetrates a hand or
    /// finger region of the skinned body mesh beyond tolerance.
    ///
    /// The defect this guards against (a cat tail passing through the hand
    /// and forearm, fingers emerging on the far side) is NOT reproducible on
    /// the bundled `AvatarSample_U` fixture: measured here across every
    /// non-Bust chain (`Hair`, `Skirt`, `Sleeve`, `CatTail`, `CatEar`,
    /// `TopsUpperArm`) at both single-joint and 5-point-per-segment density,
    /// U's tail hangs clear of the hand. It was observed on a machine-local
    /// host avatar (`modelH-final.vrm`, not part of this repository) via
    /// direct video review, not measured through this harness. This test
    /// therefore passes today on the bundled fixture and exists to fire the
    /// day a chain penetrates a hand region here — whether from a fixture
    /// swap, a pose change, or a genuine regression.
    @MainActor func testHandsDoNotPenetrateTheDress() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let path = getTestModelPath("AvatarSample_U_1.0.vrm.glb")
        try requireFixture(path, hint: "AvatarSample_U_1.0.vrm.glb")
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device,
            options: VRMLoadingOptions(augmentSpringBoneColliders: true))

        var config = RendererConfig()
        config.sampleCount = 1
        config.strict = .off
        config.synchronousSpringBone = true
        let renderer = VRMRenderer(device: device, config: config)
        renderer.loadModel(model)
        renderer.enableSpringBone = true
        renderer.viewMatrix = matrix_identity_float4x4
        renderer.projectionMatrix = matrix_identity_float4x4

        let player = AnimationPlayer()
        player.load(StressPoseFactory.clip(.armsAtSides, duration: 5))
        player.play()

        let queries = querySet(model)
        XCTAssertFalse(queries.isEmpty, "the fixture must simulate spring chains")

        let colorDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 64, height: 64, mipmapped: false)
        colorDesc.usage = [.renderTarget, .shaderRead]; colorDesc.storageMode = .private
        let depthDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float, width: 64, height: 64, mipmapped: false)
        depthDesc.usage = .renderTarget; depthDesc.storageMode = .private
        guard let colorTex = device.makeTexture(descriptor: colorDesc),
              let depthTex = device.makeTexture(descriptor: depthDesc),
              let queue = device.makeCommandQueue() else { throw XCTSkip("Could not allocate Metal resources") }

        // Same cadence as the existing harness: 150 frames at 30fps, measured
        // over the settled second half.
        let frameCount = 150, fps: Float = 30
        var worstHand: (depth: Float, region: VRMHumanoidBone?, chain: String)?
        var worstPerChain: [String: Float] = [:]

        for frame in 0..<frameCount {
            player.update(deltaTime: 1 / fps, model: model)
            guard let cb = queue.makeCommandBuffer() else { break }
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = colorTex
            rpd.colorAttachments[0].loadAction = .clear
            rpd.colorAttachments[0].storeAction = .store
            rpd.depthAttachment.texture = depthTex
            rpd.depthAttachment.loadAction = .clear
            rpd.depthAttachment.clearDepth = 1.0
            rpd.depthAttachment.storeAction = .dontCare
            renderer.drawOffscreenHeadless(to: colorTex, depth: depthTex,
                                           commandBuffer: cb, renderPassDescriptor: rpd)
            cb.commit()
            while cb.status != .completed && cb.status != .error { await Task.yield() }
            guard frame >= frameCount / 2 else { continue }

            guard let oracle = SkinMeshOracle.build(model: model) else {
                XCTFail("oracle failed to build — the predicate found no body surface")
                return
            }
            for q in queries where q.node >= 0 && q.node < model.nodes.count {
                let node = model.nodes[q.node]
                var samples: [SIMD3<Float>] = [node.worldPosition]
                if let parent = node.parent {
                    let a = parent.worldPosition, b = node.worldPosition
                    for k in 1..<5 { samples.append(a + (b - a) * (Float(k) / 5)) }
                }
                for s in samples {
                    guard let pen = oracle.penetration(of: s, radius: q.radius) else { continue }
                    guard pen.depth > Self.tolerance(for: pen.region) else { continue }
                    worstPerChain[q.chain] = max(worstPerChain[q.chain] ?? 0, pen.depth)
                    if Self.handBones.contains(pen.region ?? .hips) {
                        if pen.depth > (worstHand?.depth ?? 0) {
                            worstHand = (pen.depth, pen.region, q.chain)
                        }
                    }
                }
            }
        }

        let baselines = worstPerChain.sorted { $0.key < $1.key }
            .map { "\($0.key)=\(String(format: "%.4f", $0.value))m" }.joined(separator: " ")
        let handReport = worstHand.map {
            "worst hand penetration \(String(format: "%.4f", $0.depth))m at \($0.region.map { "\($0)" } ?? "?") from chain \($0.chain)"
        } ?? "no hand-region penetration above \(Self.handTolerance)m"

        // A real regression guard, not an expected failure: no chain (of any
        // name, per the denylist querySet above) currently penetrates a hand
        // or finger region on the bundled fixture beyond tolerance. If this
        // ever fails, `handReport` and `baselines` name the offending chain,
        // its depth, and every other chain's worst contact for context.
        XCTAssertNil(worstHand, "#381: \(handReport). Contact-region baselines: \(baselines)")
    }
}

extension SkinMeshCoverageTests {

    /// Oracle improvement gate (cloth-collision-fidelity spec §6.3): proves,
    /// on a real avatar, that `VRMLoadingOptions.fitClothCollisionToMesh`
    /// measurably reduces cloth-into-body penetration rather than merely
    /// changing numbers. `AvatarSample_M_1.0.vrm`'s non-Bust springs are all
    /// named either `Hair` or `Skirt` (verified against the fixture's
    /// `VRMC_springBone` spring list) — those are the two chain families
    /// this file's denylist `querySet` reaches for M.
    private static func chainFamily(_ chainName: String) -> String {
        let lower = chainName.lowercased()
        if lower.contains("hair") { return "Hair" }
        if lower.contains("skirt") { return "Skirt" }
        return chainName
    }

    /// Same denylist as `querySet` (every spring chain except Bust, which sits
    /// inside the chest by construction) but measured at the radius the SIM
    /// actually used: `effectiveHitRadius` when `fitClothCollisionToMesh`
    /// raised it, else the authored `hitRadius`. Flag-off and flag-on runs
    /// therefore query at different radii by design — the question this gate
    /// answers is whether the simulated configuration penetrates the body,
    /// not whether some fixed radius does. `chain` is qualified with the
    /// spring's index so per-chain printing can distinguish the 24 identically
    /// named `Skirt` springs (and 10 `Hair` springs) from one another.
    private func effectiveQuerySet(_ model: VRMModel) -> [(node: Int, radius: Float, chain: String)] {
        guard let springBone = model.springBone else { return [] }
        var out: [(Int, Float, String)] = []
        for (si, spring) in springBone.springs.enumerated() {
            let name = (spring.name ?? "").lowercased()
            guard !name.contains("bust") else { continue }
            let label = "\(spring.name ?? "?")#\(si)"
            for (i, joint) in spring.joints.enumerated() where i > 0 {
                out.append((joint.node, joint.effectiveHitRadius ?? joint.hitRadius, label))
            }
        }
        return out
    }

    private struct OraclePassResult {
        /// Keyed by the qualified per-spring label (`"Skirt#7"`), the
        /// feature's headline per-chain evidence.
        var worstPerChain: [String: Float] = [:]
        /// Keyed by family (`"Hair"`, `"Skirt"`), what the improvement
        /// assertion is measured against.
        var worstPerFamily: [String: Float] = [:]
    }

    /// Loads `AvatarSample_M_1.0.vrm` fresh with `fitClothCollisionToMesh`
    /// set to `flagOn`, runs `pose`, and measures worst oracle penetration
    /// per chain over the settled second half of the run — same 150-frame
    /// @30fps cadence, offscreen harness, and settled-half window as
    /// `testHandsDoNotPenetrateTheDress`, so a phantom-velocity coast after
    /// hard contact (a pre-existing solver defect, not this gate's subject)
    /// is measured past, not into.
    @MainActor
    private func measureWorstPenetrationPerFamily(
        pose: StressPose, flagOn: Bool, device: MTLDevice
    ) async throws -> OraclePassResult {
        let path = getTestModelPath("AvatarSample_M_1.0.vrm")
        try requireFixture(path, hint: "AvatarSample_M_1.0.vrm")
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device,
            options: VRMLoadingOptions(augmentSpringBoneColliders: true, fitClothCollisionToMesh: flagOn))

        var config = RendererConfig()
        config.sampleCount = 1
        config.strict = .off
        config.synchronousSpringBone = true
        let renderer = VRMRenderer(device: device, config: config)
        renderer.loadModel(model)
        renderer.enableSpringBone = true
        renderer.viewMatrix = matrix_identity_float4x4
        renderer.projectionMatrix = matrix_identity_float4x4

        let player = AnimationPlayer()
        player.load(StressPoseFactory.clip(pose, duration: 5))
        player.play()

        let queries = effectiveQuerySet(model)
        XCTAssertFalse(queries.isEmpty, "the fixture must simulate spring chains")

        let colorDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 64, height: 64, mipmapped: false)
        colorDesc.usage = [.renderTarget, .shaderRead]; colorDesc.storageMode = .private
        let depthDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float, width: 64, height: 64, mipmapped: false)
        depthDesc.usage = .renderTarget; depthDesc.storageMode = .private
        guard let colorTex = device.makeTexture(descriptor: colorDesc),
              let depthTex = device.makeTexture(descriptor: depthDesc),
              let queue = device.makeCommandQueue() else { throw XCTSkip("Could not allocate Metal resources") }

        let frameCount = 150, fps: Float = 30
        var result = OraclePassResult()
        // Seed every chain/family the query set actually reaches at zero, so a
        // chain (or a whole family, e.g. Skirt on the arm poses) that never
        // penetrates above tolerance still reports an explicit 0.000m rather
        // than silently dropping out of the printed table and the "stays
        // clean" assertion.
        for q in queries {
            result.worstPerChain[q.chain] = result.worstPerChain[q.chain] ?? 0
            result.worstPerFamily[Self.chainFamily(q.chain)] = result.worstPerFamily[Self.chainFamily(q.chain)] ?? 0
        }

        for frame in 0..<frameCount {
            player.update(deltaTime: 1 / fps, model: model)
            guard let cb = queue.makeCommandBuffer() else { break }
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = colorTex
            rpd.colorAttachments[0].loadAction = .clear
            rpd.colorAttachments[0].storeAction = .store
            rpd.depthAttachment.texture = depthTex
            rpd.depthAttachment.loadAction = .clear
            rpd.depthAttachment.clearDepth = 1.0
            rpd.depthAttachment.storeAction = .dontCare
            renderer.drawOffscreenHeadless(to: colorTex, depth: depthTex,
                                           commandBuffer: cb, renderPassDescriptor: rpd)
            cb.commit()
            while cb.status != .completed && cb.status != .error { await Task.yield() }
            guard frame >= frameCount / 2 else { continue }

            guard let oracle = SkinMeshOracle.build(model: model) else {
                XCTFail("oracle failed to build — the predicate found no body surface")
                return result
            }
            for q in queries where q.node >= 0 && q.node < model.nodes.count {
                let node = model.nodes[q.node]
                var samples: [SIMD3<Float>] = [node.worldPosition]
                if let parent = node.parent {
                    let a = parent.worldPosition, b = node.worldPosition
                    for k in 1..<5 { samples.append(a + (b - a) * (Float(k) / 5)) }
                }
                for s in samples {
                    guard let pen = oracle.penetration(of: s, radius: q.radius) else { continue }
                    guard pen.depth > Self.tolerance(for: pen.region) else { continue }
                    result.worstPerChain[q.chain] = max(result.worstPerChain[q.chain] ?? 0, pen.depth)
                    let family = Self.chainFamily(q.chain)
                    result.worstPerFamily[family] = max(result.worstPerFamily[family] ?? 0, pen.depth)
                }
            }
        }
        return result
    }

    /// Absolute combined-mechanism bound for the Hair family (fix round 1,
    /// spec §6.3 dual sabotage): the relative margin (`max(2mm, 20%)`) below
    /// is cleared by EITHER half of `fitClothCollisionToMesh` alone —
    /// confirmed by the armsCrossed sabotage cycles recorded in the task
    /// report, both run against `AvatarSample_M_1.0.vrm`:
    ///   - measurement stubbed (segments-only): worst Hair 0.0160m
    ///   - segments disabled (radii-only):      worst Hair 0.0111m
    ///   - both on (combined):                  worst Hair 0.0084m
    /// 0.010 sits strictly below the better of the two single-half results
    /// (0.0111m, ~10% headroom) and strictly above the combined result
    /// (0.0084m, ~20% headroom) — reachable only when BOTH mechanisms are
    /// live. This is a fixture-and-solver-coupled pin, not a general
    /// physical law: it must be re-derived (new sabotage cycles, new bound)
    /// if the underlying spring solver changes in a way that shifts these
    /// numbers — e.g. a future fix to the phantom-velocity coast noted in
    /// `measureWorstPenetrationPerFamily`'s doc comment.
    ///
    /// Risk: on this machine's GPU the combined-mechanism measurement was
    /// 0.0084m against this 0.010m bound — 16% headroom. The bound is
    /// solver- and silicon-coupled (XPBD substep ordering, float rounding),
    /// so it may not hold bit-for-bit on other hardware. If it flakes
    /// elsewhere, RE-DERIVE the bound from fresh sabotage cycles on that
    /// hardware — never just nudge the constant to make CI pass.
    private static let hairAbsoluteBound: Float = 0.010

    /// Margin: `max(0.002, 0.2 * flagOff.worst)` — 2mm or 20% of the recorded
    /// flag-off depth, whichever is larger — below the flag-off depth, for
    /// every family that was non-zero flag-off. A family already clean
    /// flag-off (no penetration above tolerance anywhere in the run) must
    /// stay clean flag-on rather than being exempted from the gate.
    private func assertFlagImprovesPenetration(
        pose: StressPose, flagOff: OraclePassResult, flagOn: OraclePassResult
    ) {
        let chainLabel = "\(pose)"
        for chain in Set(flagOff.worstPerChain.keys).union(flagOn.worstPerChain.keys).sorted() {
            let off = flagOff.worstPerChain[chain] ?? 0
            let on = flagOn.worstPerChain[chain] ?? 0
            print(String(format: "[ORACLEGATE-CHAIN] pose=%@ chain=%@ flagOff=%.4fm flagOn=%.4fm",
                chainLabel, chain, off, on))
        }

        let families = Set(flagOff.worstPerFamily.keys).union(flagOn.worstPerFamily.keys)
        XCTAssertFalse(families.isEmpty, "\(chainLabel): no chain family produced any query result")

        for family in families.sorted() {
            let off = flagOff.worstPerFamily[family] ?? 0
            let on = flagOn.worstPerFamily[family] ?? 0
            print(String(format: "[ORACLEGATE-FAMILY] pose=%@ family=%@ flagOff=%.4fm flagOn=%.4fm",
                chainLabel, family, off, on))

            if off <= 1e-9 {
                // Skirt carries no signal on this fixture: 0.0000 m worst penetration
                // flag-off on BOTH poses, so there is nothing for the flag to improve.
                // This branch is a clean-stays-clean assertion only — it does not, and
                // cannot, demonstrate that fitClothCollisionToMesh helps Skirt.
                XCTAssertLessThanOrEqual(on, Self.bodyTolerance,
                    "\(chainLabel)/\(family): already clean flag-off (0m worst penetration) and must " +
                    "stay clean flag-on — got \(on)m")
                continue
            }
            let margin = max(0.002, 0.2 * off)
            XCTAssertLessThan(on, off - margin,
                "\(chainLabel)/\(family): flag-on worst penetration (\(on)m) must be below flag-off " +
                "(\(off)m) minus the derived margin \(margin)m (max of 2mm absolute or 20% of the " +
                "\(off)m flag-off depth, whichever is larger) — actual improvement was only " +
                "\(off - on)m. Either fitClothCollisionToMesh regressed on this pose, or one of its " +
                "two mechanisms (measured radii, segment collision) stopped contributing.")

            if family == "Hair" {
                XCTAssertLessThan(on, Self.hairAbsoluteBound,
                    "\(chainLabel)/Hair: flag-on worst penetration (\(on)m) must be below the " +
                    "absolute combined-mechanism bound \(Self.hairAbsoluteBound)m — derived on " +
                    "armsCrossed from radii-only 0.0111m and segments-only 0.0160m (see " +
                    "hairAbsoluteBound's doc comment); this bound is only reachable with BOTH " +
                    "measured-radius flooring and segment collision live, so a value at or above " +
                    "it means one of the two mechanisms silently stopped contributing even though " +
                    "the looser relative margin above didn't catch it.")
            }
        }
    }

    /// One test per pose (spec §6.3 step 1): `armsCrossed`.
    @MainActor func testArmsCrossedOraclePenetrationImprovesWithFitClothCollisionToMesh() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let flagOff = try await measureWorstPenetrationPerFamily(pose: .armsCrossed, flagOn: false, device: device)
        let flagOn = try await measureWorstPenetrationPerFamily(pose: .armsCrossed, flagOn: true, device: device)
        assertFlagImprovesPenetration(pose: .armsCrossed, flagOff: flagOff, flagOn: flagOn)
    }

    /// One test per pose (spec §6.3 step 1): `armsAtSides`.
    @MainActor func testArmsAtSidesOraclePenetrationImprovesWithFitClothCollisionToMesh() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let flagOff = try await measureWorstPenetrationPerFamily(pose: .armsAtSides, flagOn: false, device: device)
        let flagOn = try await measureWorstPenetrationPerFamily(pose: .armsAtSides, flagOn: true, device: device)
        assertFlagImprovesPenetration(pose: .armsAtSides, flagOff: flagOff, flagOn: flagOn)
    }
}
