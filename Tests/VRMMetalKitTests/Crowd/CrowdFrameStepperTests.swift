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
    @MainActor private func avatar(_ device: MTLDevice, index: Int, sampleCount: Int = 1) async throws -> CrowdFrameStepper.Avatar {
        let path = getTestVRM10ModelPath(); try requireFixture(path, hint: testVRM10Filename)
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device,
            options: VRMLoadingOptions(augmentSpringBoneColliders: true))
        var config = RendererConfig(); config.synchronousSpringBone = true; config.sampleCount = sampleCount
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

    /// Real MSAA+resolve path (design's actual executable shape, unlike the
    /// single-sample smoke test above): two avatars placed on opposite sides of
    /// the frame must BOTH survive compositing into a shared 4x MSAA target that
    /// resolves once at the end. Before the storeAction fix, the first avatar's
    /// pass only had `storeAction = .multisampleResolve` (never `.store`), so its
    /// MSAA color/depth samples were never written back; the second avatar's
    /// `.load` then read undefined backing memory (commonly zero-filled, i.e.
    /// black — NOT the clear-gray background), and its own resolve pass
    /// overwrote the ENTIRE resolve texture with [undefined + avatar B], erasing
    /// avatar A. A naive "differs from clear-gray" pixel check does not catch
    /// this: undefined/black content already differs from gray, so it passes
    /// even when avatar A is missing. Instead this test compares each half of
    /// the composite against a SOLO render of that avatar alone (the N=1 path,
    /// correct under both old and new code, since first==last there) — an exact
    /// match proves the pair composite actually preserved that avatar's pixels
    /// rather than merely showing "something non-gray."
    @MainActor func testMSAACompositeRendersBothAvatarsAcrossFrameHalves() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let a = try await avatar(device, index: 0, sampleCount: 4)
        let b = try await avatar(device, index: 1, sampleCount: 4)
        for av in [a, b] {
            // Spring bones tick on wall-clock time inside each draw call, which
            // would make repeated re-renders (solo references vs. pair
            // composite, below) diverge by a few hair-jitter pixels for reasons
            // unrelated to compositing. Disable so all renders below are
            // pixel-reproducible and any diff is attributable to the store
            // action bug under test, not physics timing.
            av.renderer.enableSpringBone = false
            av.renderer.projectionMatrix = perspectiveTest(aspect: 1)
            av.renderer.viewMatrix = lookAtTest(eye: SIMD3<Float>(0, 1.3, 3.5),
                                                center: SIMD3<Float>(0, 1.3, 0), up: SIMD3<Float>(0, 1, 0))
        }
        // Hold at wide half-separation (~0.6m each side) so each avatar occupies
        // a distinct half of the frame.
        let driver = CrowdMotionDriver(startSep: 0.6, holdSep: 0.6,
            approachStart: 0.0, approachEnd: 0.1, holdEnd: 0.9, partEnd: 1.0)
        let pairStepper = CrowdFrameStepper(avatars: [a, b], driver: driver, group: nil, fps: 60)
        // Pose both avatars once; solo reference renders below reuse this exact
        // pose (they draw, not step, so no re-posing/animation drift occurs).
        pairStepper.step(frameTime: 0.5)

        let w = 128, h = 128
        let queue = device.makeCommandQueue()!

        func makeTargets() -> (msaaColor: MTLTexture, msaaDepth: MTLTexture, resolve: MTLTexture, rpd: MTLRenderPassDescriptor) {
            let msaaColorDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
            msaaColorDesc.textureType = .type2DMultisample
            msaaColorDesc.sampleCount = 4
            msaaColorDesc.usage = [.renderTarget]
            msaaColorDesc.storageMode = .private
            let msaaColor = device.makeTexture(descriptor: msaaColorDesc)!

            let msaaDepthDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: w, height: h, mipmapped: false)
            msaaDepthDesc.textureType = .type2DMultisample
            msaaDepthDesc.sampleCount = 4
            msaaDepthDesc.usage = [.renderTarget]
            msaaDepthDesc.storageMode = .private
            let msaaDepth = device.makeTexture(descriptor: msaaDepthDesc)!

            let resolveDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
            resolveDesc.usage = [.renderTarget, .shaderRead]
            resolveDesc.storageMode = .shared
            let resolve = device.makeTexture(descriptor: resolveDesc)!

            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = msaaColor
            rpd.colorAttachments[0].resolveTexture = resolve
            rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
            rpd.colorAttachments[0].storeAction = .multisampleResolve
            rpd.depthAttachment.texture = msaaDepth
            rpd.depthAttachment.clearDepth = 1.0
            rpd.depthAttachment.storeAction = .dontCare
            return (msaaColor, msaaDepth, resolve, rpd)
        }

        func renderAndReadback(_ stepper: CrowdFrameStepper) async -> [UInt8] {
            let targets = makeTargets()
            let cb = queue.makeCommandBuffer()!
            stepper.drawComposite(color: targets.msaaColor, depth: targets.msaaDepth,
                                  commandBuffer: cb, renderPassDescriptor: targets.rpd)
            await withCheckedContinuation { continuation in
                cb.addCompletedHandler { _ in continuation.resume() }
                cb.commit()
            }
            var pixels = [UInt8](repeating: 0, count: w * h * 4)
            targets.resolve.getBytes(&pixels, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
            return pixels
        }

        // Solo references (N=1: first == last, identical old/new code path) at
        // the SAME already-posed transforms as the pair composite above.
        let refA = await renderAndReadback(CrowdFrameStepper(avatars: [a], driver: driver, group: nil, fps: 60))
        let refB = await renderAndReadback(CrowdFrameStepper(avatars: [b], driver: driver, group: nil, fps: 60))
        // Actual: both avatars composited into one shared MSAA target — the
        // code path under test.
        let pairPixels = await renderAndReadback(pairStepper)

        func halfMatchesReference(_ actual: [UInt8], _ reference: [UInt8], xRange: Range<Int>) -> Bool {
            for y in 0..<h {
                for x in xRange {
                    let i = (y * w + x) * 4
                    for c in 0..<3 {
                        if abs(Int(actual[i + c]) - Int(reference[i + c])) > 4 { return false }
                    }
                }
            }
            return true
        }

        XCTAssertTrue(halfMatchesReference(pairPixels, refA, xRange: 0..<(w / 2)),
            "left half (avatar A, drawn FIRST/non-last) must match its solo render — composite must not lose/corrupt it")
        XCTAssertTrue(halfMatchesReference(pairPixels, refB, xRange: (w / 2)..<w),
            "right half (avatar B, drawn LAST) must match its solo render")
    }

    /// Component A (design §2/§6): with `bodyContactMargin` set, the closest torso
    /// pair never stays overlapped past the margin, even when the driver holds at a
    /// deep-overlap separation. Control: the same deep hold WITHOUT the clamp leaves
    /// the torsos overlapping far past the margin.
    @MainActor func testBodyContactMarginClampsTorsoOverlap() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let margin: Float = 0.05
        // Deep hold: 0.05 half-sep => 0.10m apart => torsos deeply interpenetrate.
        let driver = CrowdMotionDriver(startSep: 1.0, holdSep: 0.05,
            approachStart: 0.0, approachEnd: 0.1, holdEnd: 0.9, partEnd: 1.0)

        func overlapAfterHold(margin: Float?) async throws -> (overlap: Float, applied: Float?) {
            let a = try await avatar(device, index: 0)
            let b = try await avatar(device, index: 1)
            let stepper = CrowdFrameStepper(avatars: [a, b], driver: driver, group: nil, fps: 60,
                                            bodyContactMargin: margin)
            for _ in 0..<48 { stepper.step(frameTime: 0.5) }  // hold; let the clamp converge
            let ta = try XCTUnwrap(SpringBoneContactColliderSet.worldTorsoCapsule(model: a.model))
            let tb = try XCTUnwrap(SpringBoneContactColliderSet.worldTorsoCapsule(model: b.model))
            return (CrowdContactClamp.maxOverlap(torsos: [ta, tb]), stepper.lastAppliedHalfSeparation)
        }

        let unclamped = try await overlapAfterHold(margin: nil)
        XCTAssertGreaterThan(unclamped.overlap, margin + 0.05,
            "control: without the clamp the torsos deeply overlap")

        let clamped = try await overlapAfterHold(margin: margin)
        XCTAssertLessThanOrEqual(clamped.overlap, margin + 0.02,
            "clamp holds torso overlap at/under the margin")
        XCTAssertGreaterThan(try XCTUnwrap(clamped.applied), driver.holdSep,
            "clamp raised the applied half-separation above the driver's deep hold")
    }

    /// Component B, load-bearing (design §3/§6): the postural yield is written in
    /// the kinematic phase BEFORE the spring solver, so spring bones anchored above
    /// the chest (head hair — head descends from chest via neck) inherit the lean.
    /// With `bodyContactMargin` OFF the placement is identical between the two runs,
    /// so the ONLY difference is the lean — any change in the solved spring-bone
    /// positions therefore proves the solver saw the leaned chest.
    ///
    /// The yield is *self-relieving* (the torso capsule is anchored to the leaning
    /// chest, so leaning away reduces the penetration driving it, settling toward
    /// light contact), so we assert on the transient PEAK across the run — the lean
    /// magnitude and the spring divergence at their largest — not the settled end.
    @MainActor func testPosturalYieldIsInheritedBySpringBones() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        // Deep hold so each chest penetrates the partner's torso capsule => lean.
        // Torso radius ~0.10m; the chest penetrates when 2·halfSep < radius, so a
        // 0.03 half-separation (0.06m apart) drives a clear overlap.
        let driver = CrowdMotionDriver(startSep: 1.0, holdSep: 0.03,
            approachStart: 0.0, approachEnd: 0.1, holdEnd: 0.9, partEnd: 1.0)
        let postural = PosturalContactParams(kGain: 6.0, maxLeanAngle: 0.6, stiffness: 20.0, blendWeight: 1.0)

        func run(postural params: PosturalContactParams?) async throws -> (frames: [[SIMD3<Float>]], peakLean: Float) {
            let a = try await avatar(device, index: 0)
            let b = try await avatar(device, index: 1)
            let group = SpringBoneContactGroup()
            a.renderer.joinContactGroup(group); b.renderer.joinContactGroup(group)
            let stepper = CrowdFrameStepper(avatars: [a, b], driver: driver, group: group, fps: 60,
                                            bodyContactMargin: nil, postural: params)
            var frames: [[SIMD3<Float>]] = []
            var peakLean: Float = 0
            for _ in 0..<20 {
                stepper.step(frameTime: 0.5)  // hold window
                a.renderer.springBoneComputeSystem?.update(model: a.model, deltaTime: 1.0/60.0, commandBuffer: nil)
                a.renderer.springBoneComputeSystem?.waitForPendingFrame()
                frames.append(a.model.springBoneBuffers?.getCurrentPositions() ?? [])
                peakLean = max(peakLean, stepper.posturalLayer(forAvatar: 0)?.currentLeanAngle ?? 0)
            }
            return (frames, peakLean)
        }

        let off = try await run(postural: nil)
        let on = try await run(postural: postural)

        XCTAssertGreaterThan(on.peakLean, 0.05, "chest penetrated the partner torso => a real lean accrued")
        XCTAssertEqual(off.frames.count, on.frames.count)
        XCTAssertFalse(off.frames.first?.isEmpty ?? true, "fixture has spring bones to inherit the lean")
        // Largest per-bone spring divergence across ALL frames: the transient lean
        // propagated into the solver's output.
        var maxDelta: Float = 0
        for f in off.frames.indices {
            for i in off.frames[f].indices where i < on.frames[f].count {
                maxDelta = max(maxDelta, simd_length(off.frames[f][i] - on.frames[f][i]))
            }
        }
        XCTAssertGreaterThan(maxDelta, 1e-4,
            "spring bones moved because the solver saw the leaned chest (kinematic-phase inheritance)")
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
