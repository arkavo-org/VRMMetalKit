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

final class CrowdFrameStepperTests: XCTestCase {
    @MainActor private func avatar(_ device: MTLDevice, index: Int) async throws -> CrowdFrameStepper.Avatar {
        let path = getTestVRM10ModelPath(); try requireFixture(path, hint: testVRM10Filename)
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device,
            options: VRMLoadingOptions(augmentSpringBoneColliders: true))
        var config = RendererConfig(); config.synchronousSpringBone = true
        let r = VRMRenderer(device: device, config: config)
        r.loadModel(model); r.enableSpringBone = true
        // Minimal no-op player (no VRMA needed for headless pose/exchange checks).
        let player = AnimationPlayer()
        // Bake inward facing once (as the executable does at setup).
        for root in model.nodes where root.parent == nil {
            root.rotation = CrowdPlacement.facing(avatarIndex: index, avatarCount: 2)
        }
        return CrowdFrameStepper.Avatar(renderer: r, model: model, player: player, index: index)
    }

    /// After step() at the hold window, each avatar's spring system has the
    /// partner's contact colliders injected (union-minus-self through the group).
    @MainActor func testStepPosesAndExchangesInjectingPartner() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let a = try await avatar(device, index: 0)
        let b = try await avatar(device, index: 1)
        let group = SpringBoneContactGroup()
        a.renderer.joinContactGroup(group)
        b.renderer.joinContactGroup(group)
        // Hold half-sep 0.12m => 0.24m apart => bodies overlap.
        let driver = CrowdMotionDriver(startSep: 1.0, holdSep: 0.12,
            approachStart: 0.0, approachEnd: 0.1, holdEnd: 0.9, partEnd: 1.0)
        let stepper = CrowdFrameStepper(avatars: [a, b], driver: driver, group: group, fps: 60)

        stepper.step(frameTime: 0.5)  // hold window
        for av in [a, b] {
            av.renderer.springBoneComputeSystem?.update(model: av.model, deltaTime: 1.0/60.0, commandBuffer: nil)
            av.renderer.springBoneComputeSystem?.waitForPendingFrame()
        }
        XCTAssertGreaterThan(a.renderer.springBoneComputeSystem?.activeForeignCapsules ?? 0, 0)
        XCTAssertGreaterThan(b.renderer.springBoneComputeSystem?.activeForeignCapsules ?? 0, 0)
    }

    /// Crowd-level non-interference: an avatar stepped with NO group (contact off)
    /// produces bit-identical bone positions to the same avatar stepped solo.
    @MainActor func testNoGroupIsBitIdenticalToSolo() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }

        func run(withPartner: Bool) async throws -> [SIMD3<Float>] {
            let a = try await avatar(device, index: 0)
            var avatars = [a]
            if withPartner { avatars.append(try await avatar(device, index: 1)) }
            // group: nil => contact off (the --crowd-no-contact path).
            let driver = CrowdMotionDriver(startSep: 1.0, holdSep: 0.12,
                approachStart: 0.0, approachEnd: 0.1, holdEnd: 0.9, partEnd: 1.0)
            let stepper = CrowdFrameStepper(avatars: avatars, driver: driver, group: nil, fps: 60)
            for f in 0..<30 {
                stepper.step(frameTime: Float(f) / 30.0)
                a.renderer.springBoneComputeSystem?.update(model: a.model, deltaTime: 1.0/60.0, commandBuffer: nil)
                a.renderer.springBoneComputeSystem?.waitForPendingFrame()
            }
            return a.model.springBoneBuffers?.getCurrentPositions() ?? []
        }

        let solo = try await run(withPartner: false)
        let crowd = try await run(withPartner: true)
        XCTAssertEqual(solo.count, crowd.count)
        XCTAssertFalse(solo.isEmpty)
        for i in solo.indices { XCTAssertEqual(solo[i], crowd[i], "no-contact crowd must not perturb bone \(i)") }
    }

    /// Smoke: composite two avatars into an offscreen texture for a few frames and
    /// confirm something was drawn (not the clear color everywhere).
    @MainActor func testCompositeRendersNonEmptyFrame() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let a = try await avatar(device, index: 0)
        let b = try await avatar(device, index: 1)
        for av in [a, b] {
            av.renderer.projectionMatrix = perspectiveTest(aspect: 1)
            av.renderer.viewMatrix = lookAtTest(eye: SIMD3<Float>(0, 1.3, 2.5),
                                                center: SIMD3<Float>(0, 1.3, 0), up: SIMD3<Float>(0, 1, 0))
        }
        let driver = CrowdMotionDriver(startSep: 0.6, holdSep: 0.2,
            approachStart: 0.0, approachEnd: 0.1, holdEnd: 0.9, partEnd: 1.0)
        let stepper = CrowdFrameStepper(avatars: [a, b], driver: driver, group: nil, fps: 60)

        let w = 128, h = 128
        let cd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        cd.usage = [.renderTarget, .shaderRead]; cd.storageMode = .shared
        let color = device.makeTexture(descriptor: cd)!
        let dd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: w, height: h, mipmapped: false)
        dd.usage = [.renderTarget]; dd.storageMode = .private
        let depth = device.makeTexture(descriptor: dd)!
        let queue = device.makeCommandQueue()!

        stepper.step(frameTime: 0.5)
        let cb = queue.makeCommandBuffer()!
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = color
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        rpd.depthAttachment.texture = depth
        rpd.depthAttachment.clearDepth = 1.0
        stepper.drawComposite(color: color, depth: depth, commandBuffer: cb, renderPassDescriptor: rpd)
        await withCheckedContinuation { continuation in
            cb.addCompletedHandler { _ in continuation.resume() }
            cb.commit()
        }

        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        color.getBytes(&pixels, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        // Some pixel must differ from the 0.5 gray clear (an avatar drew).
        let gray = Int(UInt8(0.5 * 255))
        var drew = false
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
            if abs(r - gray) > 8 || abs(g - gray) > 8 || abs(b - gray) > 8 {
                drew = true
                break
            }
        }
        XCTAssertTrue(drew, "composite must render at least one avatar (non-clear pixels)")
    }

    // Local camera helpers (avoid depending on the executable's private helpers).
    private func perspectiveTest(aspect: Float) -> float4x4 {
        let fov: Float = .pi / 4, near: Float = 0.1, far: Float = 100
        let y = 1 / tan(fov * 0.5), x = y / aspect, z = far / (near - far)
        return float4x4(SIMD4<Float>(x,0,0,0), SIMD4<Float>(0,y,0,0),
                        SIMD4<Float>(0,0,z,-1), SIMD4<Float>(0,0,z*near,0))
    }
    private func lookAtTest(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> float4x4 {
        let f = simd_normalize(center - eye), s = simd_normalize(simd_cross(f, up)), u = simd_cross(s, f)
        return float4x4(SIMD4<Float>(s.x,u.x,-f.x,0), SIMD4<Float>(s.y,u.y,-f.y,0),
                        SIMD4<Float>(s.z,u.z,-f.z,0),
                        SIMD4<Float>(-simd_dot(s,eye), -simd_dot(u,eye), simd_dot(f,eye), 1))
    }
}
