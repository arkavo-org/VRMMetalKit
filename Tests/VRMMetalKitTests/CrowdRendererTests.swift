//
// Copyright 2026 Arkavo
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

final class CrowdRendererTests: XCTestCase {
    func testSharedPassMatchesIndividualPassesIncludingMSAA() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let queue = try XCTUnwrap(device.makeCommandQueue())
        for sampleCount in [1, 4] {
            var avatars: [VRMCrowdRenderer.Avatar] = []
            for index in 0..<4 {
                let renderer = try await makeRenderer(device: device, sampleCount: sampleCount)
                renderer.viewMatrix.columns.3.x += Float(index - 2) * 0.35
                renderer.outlineWidth = index.isMultiple(of: 2) ? 0.02 : 0
                renderer.setAmbientColor(SIMD3<Float>(repeating: 0.04 * Float(index + 1)))
                avatars.append(.init(renderer: renderer))
            }
            let scene = VRMCrowdRenderer(avatars: avatars)
            let individual = try target(device: device, samples: sampleCount)
            let shared = try target(device: device, samples: sampleCount)
            // More than one uniform-ring rotation, and more avatars than ring slots.
            for _ in 0..<4 {
                for (pass, submission) in [(individual, VRMCrowdRenderer.Submission.individualPasses),
                                            (shared, .sharedPass)] {
                    let cb = try XCTUnwrap(queue.makeCommandBuffer())
                    scene.draw(deltaTime: 1 / 60, viewportSize: CGSize(width: 128, height: 128),
                               commandBuffer: cb, renderPassDescriptor: pass, submission: submission)
                    cb.commit()
                    waitForGPU(cb)
                    XCTAssertNil(cb.error)
                    XCTAssertEqual(scene.visibleAvatarCount, 4)
                }
            }
            let actual = try pixels(shared, device: device, queue: queue)
            let expected = try pixels(individual, device: device, queue: queue)
            XCTAssertEqual(actual, expected, "MSAA \(sampleCount): shared-pass state must not leak between avatars")
            XCTAssertGreaterThan(actual.filter { $0 != 0 }.count, 128 * 128,
                                 "Comparison must contain drawn geometry, not just the clear color")
            for avatar in avatars { XCTAssertEqual(avatar.renderer.frameCounter, 8) }
        }
    }

    func testVisibilitySkipsComputeAndBackgroundSamplingKeepsPlaybackSpeed() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let renderer = try await makeRenderer(device: device, sampleCount: 1)
        let model = try XCTUnwrap(renderer.model)
        let head = try XCTUnwrap(model.humanoid?.getBoneNode(.head))
        var clip = AnimationClip(duration: 10)
        clip.addEulerTrack(bone: .head, axis: .y) { $0 }
        let player = AnimationPlayer()
        player.load(clip)
        player.play()
        let scene = VRMCrowdRenderer(avatars: [.init(renderer: renderer, player: player)],
                                    policy: .init(maxFullQualityAvatars: 0, backgroundAnimationFPS: 30))
        let pass = try target(device: device, samples: 1)
        func frame() throws {
            let cb = try XCTUnwrap(queue.makeCommandBuffer())
            scene.draw(deltaTime: 1 / 60, viewportSize: CGSize(width: 128, height: 128),
                       commandBuffer: cb, renderPassDescriptor: pass)
            cb.commit()
            waitForGPU(cb)
            XCTAssertNil(cb.error)
        }
        try frame()
        let first = model.nodes[head].rotation
        try frame()
        XCTAssertEqual(scene.animationUpdates, 0)
        XCTAssertEqual(model.nodes[head].rotation.vector, first.vector)
        try frame()
        XCTAssertEqual(scene.animationUpdates, 1)
        XCTAssertEqual(model.nodes[head].rotation.angle, 3 / 60, accuracy: 0.0001)
        XCTAssertEqual(scene.fullQualityAvatarCount, 0)
        XCTAssertEqual(renderer.springBoneQuality, .low)

        let visibleView = renderer.viewMatrix
        renderer.viewMatrix.columns.3.x = 1000
        let before = renderer.frameCounter
        for _ in 0..<3 { try frame() }
        XCTAssertEqual(scene.visibleAvatarCount, 0)
        XCTAssertEqual(renderer.frameCounter, before, "Hidden avatars must not prepare morphs, skinning, or physics")

        renderer.viewMatrix = visibleView
        scene.policy = .full
        try frame()
        XCTAssertEqual(scene.fullQualityAvatarCount, 1)
        XCTAssertEqual(renderer.springBoneQuality, .ultra)
        XCTAssertEqual(model.nodes[head].rotation.angle, 7 / 60, accuracy: 0.0001,
                       "Promotion must consume the accumulated animation time")
        XCTAssertFalse(renderer.skipPreDrawTransformUpdate, "Host flags must be restored")
    }

    func testAlwaysUpdateAvatarSurvivesOffscreenCulling() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let renderer = try await makeRenderer(device: device, sampleCount: 1)
        renderer.viewMatrix.columns.3.x = 1000
        let scene = VRMCrowdRenderer(avatars: [.init(renderer: renderer, alwaysUpdate: true)],
                                    policy: .init(maxFullQualityAvatars: 0))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let cb = try XCTUnwrap(queue.makeCommandBuffer())
        scene.draw(deltaTime: 1 / 60, viewportSize: CGSize(width: 128, height: 128),
                   commandBuffer: cb, renderPassDescriptor: try target(device: device, samples: 1))
        cb.commit()
        waitForGPU(cb)
        XCTAssertNil(cb.error)
        XCTAssertEqual(scene.visibleAvatarCount, 0)
        XCTAssertEqual(scene.fullQualityAvatarCount, 1)
        XCTAssertEqual(renderer.frameCounter, 1)
    }

    func testRuntimeAvatarSettingsPreservePlaybackAndOffscreenPromotion() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let renderer = try await makeRenderer(device: device, sampleCount: 1)
        let model = try XCTUnwrap(renderer.model)
        let head = try XCTUnwrap(model.humanoid?.getBoneNode(.head))
        let player = AnimationPlayer()
        var clip = AnimationClip(duration: 10)
        clip.addEulerTrack(bone: .head, axis: .y) { $0 }
        player.load(clip)
        player.play()
        let scene = VRMCrowdRenderer(avatars: [.init(renderer: renderer, player: player)],
                                    policy: .init(maxFullQualityAvatars: 0))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let pass = try target(device: device, samples: 1)
        func frame() throws {
            let cb = try XCTUnwrap(queue.makeCommandBuffer())
            scene.draw(deltaTime: 1 / 60, viewportSize: CGSize(width: 128, height: 128),
                       commandBuffer: cb, renderPassDescriptor: pass)
            cb.commit()
            waitForGPU(cb)
            XCTAssertNil(cb.error)
        }
        try frame()
        try frame()
        XCTAssertEqual(scene.animationUpdates, 0)
        renderer.viewMatrix.columns.3.x = 1000
        scene.updateAvatar(at: 0, alwaysUpdate: true, springBoneQuality: .medium)
        try frame()
        XCTAssertEqual(scene.fullQualityAvatarCount, 1)
        XCTAssertEqual(renderer.springBoneQuality, .medium)
        XCTAssertEqual(model.nodes[head].rotation.angle, 3 / 60, accuracy: 0.0001,
                       "Promotion must consume time accumulated before the settings change")
        XCTAssertTrue(scene.avatars[0].renderer === renderer)
        XCTAssertTrue(scene.avatars[0].player === player)

        let before = renderer.frameCounter
        scene.updateAvatar(at: 0, alwaysUpdate: false)
        try frame()
        XCTAssertEqual(renderer.frameCounter, before, "Clearing the override must restore offscreen skipping")
        XCTAssertEqual(scene.avatars[0].springBoneQuality, .medium, "Omitted settings must be retained")
        scene.updateAvatar(at: 0, alwaysUpdate: true)
        try frame()
        XCTAssertEqual(model.nodes[head].rotation.angle, 5 / 60, accuracy: 0.0001)
        XCTAssertEqual(renderer.springBoneQuality, .medium)
    }

    func testRuntimePhysicsQualitySurvivesBackgroundAndFullTransitions() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let renderer = try await makeRenderer(device: device, sampleCount: 1)
        let scene = VRMCrowdRenderer(avatars: [.init(renderer: renderer)],
                                    policy: .init(maxFullQualityAvatars: 0))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let pass = try target(device: device, samples: 1)
        func frame() throws {
            let cb = try XCTUnwrap(queue.makeCommandBuffer())
            scene.draw(deltaTime: 1 / 60, viewportSize: CGSize(width: 128, height: 128),
                       commandBuffer: cb, renderPassDescriptor: pass)
            cb.commit()
            waitForGPU(cb)
            XCTAssertNil(cb.error)
        }
        scene.updateAvatar(at: 0, springBoneQuality: .high)
        try frame()
        XCTAssertEqual(renderer.springBoneQuality, .low)
        XCTAssertEqual(scene.avatars[0].springBoneQuality, .high)
        XCTAssertFalse(scene.avatars[0].alwaysUpdate)
        scene.policy = .full
        try frame()
        XCTAssertEqual(renderer.springBoneQuality, .high, "Promotion must use the updated full-quality setting")
        scene.updateAvatar(at: 0, springBoneQuality: .off)
        try frame()
        XCTAssertEqual(renderer.springBoneQuality, .off)
        XCTAssertEqual(renderer.frameCounter, 3, "Updating settings must retain the renderer's frame state")
    }

    private func waitForGPU(_ buffer: MTLCommandBuffer) { buffer.waitUntilCompleted() }

    private func makeRenderer(device: MTLDevice, sampleCount: Int) async throws -> VRMRenderer {
        let path = getTestVRM10ModelPath()
        try requireFixture(path, hint: "AvatarSample_A_1.0.vrm.glb")
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device)
        var config = RendererConfig()
        config.colorPixelFormat = .rgba8Unorm
        config.sampleCount = sampleCount
        config.enableDepthPrepass = true
        config.strict = .fail
        let renderer = VRMRenderer(device: device, config: config)
        renderer.loadModel(model)
        renderer.enableSpringBone = false
        renderer.springBoneQuality = .ultra
        renderer.performanceTracker = PerformanceTracker()
        renderer.viewMatrix = RenderTestSupport.makeLookAt(
            eye: SIMD3<Float>(0, 1, 4), center: SIMD3<Float>(0, 1, 0), up: SIMD3<Float>(0, 1, 0))
        renderer.projectionMatrix = makePerspectiveProjection(fovY: .pi / 3, aspectRatio: 1, nearZ: 0.01, farZ: 100)
        return renderer
    }

    private func target(device: MTLDevice, samples: Int) throws -> MTLRenderPassDescriptor {
        func texture(_ format: MTLPixelFormat, _ samples: Int) throws -> MTLTexture {
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: 128, height: 128, mipmapped: false)
            desc.sampleCount = samples
            desc.textureType = samples > 1 ? .type2DMultisample : .type2D
            desc.storageMode = .private
            desc.usage = .renderTarget
            return try XCTUnwrap(device.makeTexture(descriptor: desc))
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = try texture(.rgba8Unorm, samples)
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = samples > 1 ? .multisampleResolve : .store
        if samples > 1 { pass.colorAttachments[0].resolveTexture = try texture(.rgba8Unorm, 1) }
        pass.depthAttachment.texture = try texture(.depth32Float, samples)
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 1
        pass.depthAttachment.storeAction = .dontCare
        return pass
    }

    private func pixels(_ pass: MTLRenderPassDescriptor, device: MTLDevice, queue: MTLCommandQueue) throws -> [UInt8] {
        let color = try XCTUnwrap(pass.colorAttachments[0].resolveTexture ?? pass.colorAttachments[0].texture)
        let buffer = try XCTUnwrap(device.makeBuffer(length: 128 * 128 * 4, options: .storageModeShared))
        let cb = try XCTUnwrap(queue.makeCommandBuffer())
        let blit = try XCTUnwrap(cb.makeBlitCommandEncoder())
        blit.copy(from: color, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                  sourceSize: MTLSize(width: 128, height: 128, depth: 1), to: buffer,
                  destinationOffset: 0, destinationBytesPerRow: 128 * 4, destinationBytesPerImage: 128 * 128 * 4)
        blit.endEncoding()
        cb.commit()
        waitForGPU(cb)
        XCTAssertNil(cb.error)
        return Array(UnsafeBufferPointer(start: buffer.contents().assumingMemoryBound(to: UInt8.self), count: buffer.length))
    }
}
