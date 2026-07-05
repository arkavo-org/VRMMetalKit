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

/// Feature-complete subsystem 1: prove cross-avatar spring-bone collision on the
/// ASYNC render path — the path a live interactive app uses (spring compute piped
/// into the shared command buffer, one-frame readback lag, and the sleep gate
/// LIVE, where F1 applies). The offline demo runs synchronous; these tests
/// exercise the async multi-avatar contact path end to end.
final class CrowdAsyncPathTests: XCTestCase {

    private struct Avatar {
        let renderer: VRMRenderer
        let model: VRMModel
        var system: SpringBoneComputeSystem { renderer.springBoneComputeSystem! }
    }

    @MainActor private func makeAvatar(_ device: MTLDevice, index: Int, xOffset: Float,
                                       sampleCount: Int = 1) async throws -> Avatar {
        let path = getTestVRM10ModelPath(); try requireFixture(path, hint: testVRM10Filename)
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device,
            options: VRMLoadingOptions(augmentSpringBoneColliders: true))
        for root in model.nodes where root.parent == nil {
            root.rotation = CrowdPlacement.facing(avatarIndex: index, avatarCount: 2)
            root.translation = root.translation + SIMD3<Float>(xOffset, 0, 0)
        }
        model.updateNodeTransforms()
        var config = RendererConfig()
        config.synchronousSpringBone = false   // ASYNC path: sleep gate live, one-frame lag
        config.sampleCount = sampleCount
        let r = VRMRenderer(device: device, config: config)
        r.loadModel(model)
        r.enableSpringBone = true
        return Avatar(renderer: r, model: model)
    }

    /// F1 end-to-end on the async path: a SETTLED avatar wakes when a partner
    /// approaches, through the contact group (not manual injection).
    @MainActor func testSettledAvatarWakesToApproachingPartnerAsync() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let a = try await makeAvatar(device, index: 0, xOffset: 0)
        let b = try await makeAvatar(device, index: 1, xOffset: 3.0)   // far away — no contact yet
        let group = SpringBoneContactGroup()
        a.renderer.joinContactGroup(group)
        b.renderer.joinContactGroup(group)
        a.model.springBoneGlobalParams?.settlingFrames = 0

        let queue = device.makeCommandQueue()!
        func stepAsync(_ av: Avatar) {
            let cb = queue.makeCommandBuffer()!
            av.system.update(model: av.model, deltaTime: 1.0 / 60.0, commandBuffer: cb)
            cb.commit(); cb.waitUntilCompleted()
        }

        // Settle A to sleep while B is distant and static (foreign present but unchanging).
        var asleep = false
        for _ in 0..<80 {
            group.exchange()
            stepAsync(a); stepAsync(b)
            if a.system.sleepingBoneCount > 0 { asleep = true; break }
        }
        XCTAssertTrue(asleep, "A settles to sleep with a distant static partner on the async path")

        // Partner approaches: B slides onto A, so its contact colliders MOVE.
        for root in b.model.nodes where root.parent == nil {
            root.translation = SIMD3<Float>(0.05, 0, 0)
        }
        b.model.updateNodeTransforms()
        group.exchange()
        stepAsync(a)
        XCTAssertEqual(a.system.sleepingBoneCount, 0,
            "a settled avatar must wake to an approaching partner on the async path (F1 end-to-end)")
    }

    /// The async multi-avatar contact path is stable end to end: contact injects,
    /// and the sim never explodes over many async frames.
    @MainActor func testAsyncMultiAvatarContactStable() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let a = try await makeAvatar(device, index: 0, xOffset: 0)
        let b = try await makeAvatar(device, index: 1, xOffset: 0)   // overlapping bodies
        let group = SpringBoneContactGroup()
        a.renderer.joinContactGroup(group)
        b.renderer.joinContactGroup(group)

        let queue = device.makeCommandQueue()!
        func stepAsync(_ av: Avatar) {
            let cb = queue.makeCommandBuffer()!
            av.system.update(model: av.model, deltaTime: 1.0 / 60.0, commandBuffer: cb)
            cb.commit(); cb.waitUntilCompleted()
        }
        for _ in 0..<60 {
            group.exchange()
            stepAsync(a); stepAsync(b)
        }
        XCTAssertGreaterThan(a.system.activeForeignCapsules, 0,
            "async contact injects the partner's colliders when bodies overlap")
        let positions = a.model.springBoneBuffers?.getCurrentPositions() ?? []
        XCTAssertFalse(positions.isEmpty)
        for p in positions {
            XCTAssertTrue(p.x.isFinite && p.y.isFinite && p.z.isFinite, "async sim stays finite (no explosion)")
        }
    }

    /// The async composite (`[springi][renderi]` sequence in one shared command
    /// buffer) renders BOTH avatars, not just the last.
    @MainActor func testAsyncCompositeRendersBothAvatars() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let a = try await makeAvatar(device, index: 0, xOffset: 0, sampleCount: 4)
        let b = try await makeAvatar(device, index: 1, xOffset: 0, sampleCount: 4)
        for av in [a, b] {
            av.renderer.projectionMatrix = perspectiveTest(aspect: 1)
            av.renderer.viewMatrix = lookAtTest(eye: SIMD3<Float>(0, 1.3, 3.5),
                                                center: SIMD3<Float>(0, 1.3, 0), up: SIMD3<Float>(0, 1, 0))
        }
        // Wide separation so each avatar occupies a distinct half of the frame.
        let driver = CrowdMotionDriver(startSep: 0.6, holdSep: 0.6,
            approachStart: 0.0, approachEnd: 0.1, holdEnd: 0.9, partEnd: 1.0)
        let group = SpringBoneContactGroup()
        a.renderer.joinContactGroup(group); b.renderer.joinContactGroup(group)
        let stepper = CrowdFrameStepper(avatars: [
            CrowdFrameStepper.Avatar(renderer: a.renderer, model: a.model, player: AnimationPlayer(), index: 0),
            CrowdFrameStepper.Avatar(renderer: b.renderer, model: b.model, player: AnimationPlayer(), index: 1),
        ], driver: driver, group: group, fps: 60)

        let w = 128, h = 128
        let queue = device.makeCommandQueue()!
        func makeTargets() -> (MTLTexture, MTLTexture, MTLTexture, MTLRenderPassDescriptor) {
            let cd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
            cd.textureType = .type2DMultisample; cd.sampleCount = 4; cd.usage = [.renderTarget]; cd.storageMode = .private
            let color = device.makeTexture(descriptor: cd)!
            let dd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: w, height: h, mipmapped: false)
            dd.textureType = .type2DMultisample; dd.sampleCount = 4; dd.usage = [.renderTarget]; dd.storageMode = .private
            let depth = device.makeTexture(descriptor: dd)!
            let rd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
            rd.usage = [.renderTarget, .shaderRead]; rd.storageMode = .shared
            let resolve = device.makeTexture(descriptor: rd)!
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = color
            rpd.colorAttachments[0].resolveTexture = resolve
            rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
            rpd.colorAttachments[0].storeAction = .multisampleResolve
            rpd.depthAttachment.texture = depth
            rpd.depthAttachment.clearDepth = 1.0
            rpd.depthAttachment.storeAction = .dontCare
            return (color, depth, resolve, rpd)
        }

        // The async path consumes the previous frame's snapshot; a few warmup
        // frames give a valid composite.
        var resolveTex: MTLTexture!
        for _ in 0..<3 {
            stepper.step(frameTime: 0.5)
            let (c, d, resolve, rpd) = makeTargets()
            let cb = queue.makeCommandBuffer()!
            stepper.drawComposite(color: c, depth: d, commandBuffer: cb, renderPassDescriptor: rpd)
            await withCheckedContinuation { cont in cb.addCompletedHandler { _ in cont.resume() }; cb.commit() }
            resolveTex = resolve
        }
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        resolveTex.getBytes(&pixels, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        let gray = UInt8(0.5 * 255)
        func halfDrew(_ xr: Range<Int>) -> Bool {
            for y in 0..<h {
                for x in xr {
                    let i = (y * w + x) * 4
                    if abs(Int(pixels[i]) - Int(gray)) > 8 || abs(Int(pixels[i + 1]) - Int(gray)) > 8 || abs(Int(pixels[i + 2]) - Int(gray)) > 8 {
                        return true
                    }
                }
            }
            return false
        }
        XCTAssertTrue(halfDrew(0..<(w / 2)), "left avatar renders on the async composite path")
        XCTAssertTrue(halfDrew((w / 2)..<w), "right avatar renders on the async composite path")
    }

    // Local camera helpers (avoid depending on the executable's private helpers).
    private func perspectiveTest(aspect: Float) -> float4x4 {
        let fov: Float = .pi / 4, near: Float = 0.1, far: Float = 100
        let y = 1 / tan(fov * 0.5), x = y / aspect, z = far / (near - far)
        return float4x4(SIMD4<Float>(x, 0, 0, 0), SIMD4<Float>(0, y, 0, 0),
                        SIMD4<Float>(0, 0, z, -1), SIMD4<Float>(0, 0, z * near, 0))
    }
    private func lookAtTest(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> float4x4 {
        let f = simd_normalize(center - eye), s = simd_normalize(simd_cross(f, up)), u = simd_cross(s, f)
        return float4x4(SIMD4<Float>(s.x, u.x, -f.x, 0), SIMD4<Float>(s.y, u.y, -f.y, 0),
                        SIMD4<Float>(s.z, u.z, -f.z, 0),
                        SIMD4<Float>(-simd_dot(s, eye), -simd_dot(u, eye), simd_dot(f, eye), 1))
    }
}
