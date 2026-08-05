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

    /// Query set per spec §6: hair / skirt / hood / sleeve chains, roots exempt,
    /// NEVER Bust. Bust joints sit inside the chest by construction, and the
    /// moment the torso is in the oracle they report deep permanent penetration
    /// that swamps the millimetre-scale finger signal.
    private func querySet(_ model: VRMModel) -> [(node: Int, radius: Float, chain: String)] {
        guard let springBone = model.springBone else { return [] }
        var out: [(Int, Float, String)] = []
        for spring in springBone.springs {
            let name = (spring.name ?? "").lowercased()
            guard name.contains("hair") || name.contains("skirt")
                || name.contains("hood") || name.contains("sleeve") else { continue }
            for (i, joint) in spring.joints.enumerated() where i > 0 {
                out.append((joint.node, joint.hitRadius, spring.name ?? "?"))
            }
        }
        return out
    }

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
        XCTAssertFalse(queries.isEmpty, "the fixture must simulate hair/skirt/sleeve chains")

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

        // The deliverable is a RECORDED FAILURE, pinned to the hand region so
        // the marker is not satisfied by penetration anywhere else. When SP2/SP3
        // fix it, XCTExpectFailure itself fails ("expected failure not
        // observed") and forces removal of this marker.
        XCTExpectFailure("#381: hands/fingers penetrate the dress. \(handReport). "
                         + "Contact-region baselines: \(baselines)")
        XCTAssertNil(worstHand, handReport)
    }
}
