// Copyright 2026 Arkavo Inc. and contributors
// Licensed under the Apache License, Version 2.0

import XCTest
import Metal
import simd
@testable import VRMMetalKit

/// The opt-in contact shadow: placement, draw order and encoder state. Off by
/// default; `MToonLegacyGoldenTests` covers the default frame.
@MainActor
final class ContactShadowTests: XCTestCase {
    private var device: MTLDevice!

    override func setUp() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        self.device = device
    }

    /// Camera above and in front of the swatches, looking down at the ground
    /// (y = -0.5) behind and below them.
    private func pitchedSetup(shadow: Bool, _ configure: (inout SwatchScene.Setup) -> Void = { _ in }) -> SwatchScene.Setup {
        var setup = SwatchScene.Setup()
        setup.eye = SIMD3<Float>(0, 2.2, 4.2)
        setup.center = SIMD3<Float>(0, -0.5, 0)
        setup.config.enableContactShadows = shadow
        configure(&setup)
        return setup
    }

    // MARK: - Footprint (no GPU)

    func testMeshFootprintHonoursNestedNodeTransforms() {
        var nested = matrix_identity_float4x4
        nested.columns.3 = SIMD4<Float>(2, 1.5, -1, 1)
        let box = ContactShadowFootprint.MeshBox(
            localMin: SIMD3<Float>(-0.5, 0, -0.25),
            localMax: SIMD3<Float>(0.5, 1, 0.25),
            transform: nested)
        let footprint = try? XCTUnwrap(ContactShadowFootprint.fromMeshBounds([box]))
        XCTAssertEqual(footprint?.center ?? .zero, SIMD3<Float>(2, 1.5, -1))
        XCTAssertEqual(footprint?.radius ?? 0, 0.5, accuracy: 1e-6)
    }

    func testFootFootprintFollowsTheFeetNotTheArms() {
        let feet = [SIMD3<Float>(0.9, 0.08, 0.3), SIMD3<Float>(1.1, 0.08, 0.3)]
        let footprint = ContactShadowFootprint.fromFeet(feet, groundY: 0, legLength: 0.8)
        XCTAssertEqual(footprint?.center ?? .zero, SIMD3<Float>(1, 0, 0.3))
        // Stance half-width 0.1 plus a sole margin of 12% of the leg.
        XCTAssertEqual(footprint?.radius ?? 0, 0.1 + 0.096, accuracy: 1e-5)
        XCTAssertNil(ContactShadowFootprint.fromFeet([], groundY: 0, legLength: 1))
    }

    // MARK: - Rendering

    func testContactShadowDarkensTheGroundBelowTheModel() async throws {
        let model = try await SwatchScene.load(.rigid, device: device)
        let off = try SwatchScene.render(model, device: device, setup: pitchedSetup(shadow: false))
        let on = try SwatchScene.render(model, device: device, setup: pitchedSetup(shadow: true))
        let shadow = SwatchScene.stats(on, reference: off, size: 512)
        XCTAssertGreaterThan(shadow.changedPixels, 2000, "The contact shadow should darken the ground")
        XCTAssertLessThan(shadow.lumaDelta, 0, "The contact shadow must darken, not lighten")
    }

    /// A host that draws its floor into the same depth buffer first must see
    /// the shadow on it, whatever depth bias the model's own draws use.
    func testContactShadowLandsOnAHostDrawnFloor() async throws {
        let floor = try await SwatchScene.load(.floor, device: device)
        let model = try await SwatchScene.load(.rigid, device: device)
        let off = try renderOverFloor(floor: floor, model: model, shadow: false)
        let on = try renderOverFloor(floor: floor, model: model, shadow: true)
        let shadow = SwatchScene.stats(on, reference: off, size: 512)
        XCTAssertGreaterThan(shadow.changedPixels, 2000, "The contact shadow is hidden by the host floor")
        XCTAssertLessThan(shadow.lumaDelta, 0)
    }

    /// Translucent surfaces are composited over the shadowed ground, so a
    /// 90%-opaque sphere can darken by at most 10% of the shadow.
    func testTranslucentSurfacesAreNotPaintedOver() async throws {
        let model = try await SwatchScene.load(.rigid, device: device)
        let leather = model.materials[1]
        leather.alphaMode = "BLEND"
        leather.baseColorFactor.w = 0.9
        // Outline hulls do not write depth either, so a translucent material's
        // own hull would cover it; keep this test about the shadow alone.
        leather.mtoon?.outlineWidthMode = .none
        let setup: (Bool) -> SwatchScene.Setup = { shadow in
            self.pitchedSetup(shadow: shadow) {
                $0.eye = SIMD3<Float>(0, 0.4, 4.2)
                $0.center = SIMD3<Float>(0, -0.3, 0)
                $0.config.contactShadowScale = 3
            }
        }
        let off = try SwatchScene.render(model, device: device, setup: setup(false))
        let on = try SwatchScene.render(model, device: device, setup: setup(true))

        var largestDrop = 0.0
        var overlap = 0
        for y in 0..<512 {
            for x in SwatchScene.third(1, size: 512) {
                let i = (y * 512 + x) * 4
                let isSphere = off[i] < 250 || off[i + 1] < 250 || off[i + 2] < 250
                guard isSphere else { continue }
                let drop = SwatchScene.luma(off, i) - SwatchScene.luma(on, i)
                if drop > 0.002 { overlap += 1 }
                largestDrop = max(largestDrop, drop)
            }
        }
        XCTAssertGreaterThan(overlap, 50, "Test setup: the shadow should sit behind the translucent sphere")
        XCTAssertLessThanOrEqual(largestDrop, 0.1 * 0.45 + 0.01,
            "The shadow darkened a 90%-opaque surface by \(largestDrop) luma; it must be composited under it")
    }

    /// Mixed single- and double-sided outlined materials: enabling the shadow
    /// must not change a single model pixel (the dedicated outline pass must
    /// still cull its hull's front faces).
    func testShadowLeavesModelPixelsAndOutlineCullingAlone() async throws {
        let model = try await SwatchScene.load(.rigid, device: device)
        model.materials[0].doubleSided = true
        let setup: (Bool) -> SwatchScene.Setup = { shadow in
            self.pitchedSetup(shadow: shadow) { $0.outlineWidth = 40 }
        }
        let off = try SwatchScene.render(model, device: device, setup: setup(false))
        let on = try SwatchScene.render(model, device: device, setup: setup(true))
        var changedModelPixels = 0
        for i in stride(from: 0, to: off.count, by: 4) {
            let isModel = off[i] < 250 || off[i + 1] < 250 || off[i + 2] < 250
            if isModel && (off[i] != on[i] || off[i + 1] != on[i + 1] || off[i + 2] != on[i + 2]) {
                changedModelPixels += 1
            }
        }
        XCTAssertEqual(changedModelPixels, 0, "Enabling the contact shadow changed \(changedModelPixels) model pixels")
    }

    func testOpacityAndScaleAreClampedWhenSetDirectly() async throws {
        let model = try await SwatchScene.load(.rigid, device: device)
        let overdriven = try SwatchScene.render(model, device: device, setup: pitchedSetup(shadow: true) {
            $0.config.contactShadowOpacity = 3
        })
        let full = try SwatchScene.render(model, device: device, setup: pitchedSetup(shadow: true) {
            $0.config.contactShadowOpacity = 1
        })
        XCTAssertEqual(overdriven, full, "contactShadowOpacity above 1 must clamp to 1")

        let negative = try SwatchScene.render(model, device: device, setup: pitchedSetup(shadow: true) {
            $0.config.contactShadowScale = -4
        })
        let minimum = try SwatchScene.render(model, device: device, setup: pitchedSetup(shadow: true) {
            $0.config.contactShadowScale = 0.1
        })
        XCTAssertEqual(negative, minimum, "contactShadowScale below 0.1 must clamp to 0.1")
    }

    // MARK: - Humanoid avatar

    /// On a T-posed avatar the shadow belongs under the feet, not across the
    /// arm span, and it follows the skeleton when the hips move.
    func testHumanoidShadowSitsUnderTheFeetAndFollowsTheHips() async throws {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("AvatarSample_U_1.0.vrm.glb").path
        try XCTSkipIf(!FileManager.default.fileExists(atPath: path), "AvatarSample_U_1.0.vrm.glb not present at repo root")
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device)
        let renderer = VRMRenderer(device: device, config: RendererConfig())
        renderer.loadModel(model)
        let restBounds = model.modelLocalBounds
        let armSpan = restBounds.max.x - restBounds.min.x

        let rest = try XCTUnwrap(renderer.contactShadowFootprint(model: model))
        XCTAssertLessThan(rest.radius * 2, armSpan * 0.5,
            "Shadow diameter \(rest.radius * 2) m should follow the stance, not the \(armSpan) m arm span")
        XCTAssertEqual(rest.center.y, restBounds.min.y, accuracy: 0.01, "Shadow should sit at the soles")

        let hipsIndex = try XCTUnwrap(model.humanoid?.getBoneNode(.hips))
        model.nodes[hipsIndex].translation += SIMD3<Float>(1, 0, 0.5)
        for root in model.nodes where root.parent == nil { root.updateWorldTransform() }
        let moved = try XCTUnwrap(renderer.contactShadowFootprint(model: model))
        XCTAssertEqual(moved.center.x - rest.center.x, 1, accuracy: 0.02, "Shadow must follow the hips in x")
        XCTAssertEqual(moved.center.z - rest.center.z, 0.5, accuracy: 0.02, "Shadow must follow the hips in z")
        XCTAssertEqual(moved.center.y, rest.center.y, accuracy: 1e-5, "Shadow stays on the ground")
    }

    // MARK: - Helpers

    private func renderOverFloor(floor: VRMModel, model: VRMModel, shadow: Bool) throws -> [UInt8] {
        let size = 512
        let floorRenderer = SwatchScene.makeRenderer(model: floor, device: device, setup: pitchedSetup(shadow: false))
        let modelRenderer = SwatchScene.makeRenderer(model: model, device: device, setup: pitchedSetup(shadow: shadow) {
            $0.outlineWidth = 40
        })

        let colorDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: size, height: size, mipmapped: false)
        colorDesc.usage = [.renderTarget, .shaderRead]
        colorDesc.storageMode = .shared
        let depthDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float, width: size, height: size, mipmapped: false)
        depthDesc.usage = .renderTarget
        depthDesc.storageMode = .private
        let color = try XCTUnwrap(device.makeTexture(descriptor: colorDesc))
        let depth = try XCTUnwrap(device.makeTexture(descriptor: depthDesc))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())

        let floorPass = MTLRenderPassDescriptor()
        floorPass.colorAttachments[0].texture = color
        floorPass.colorAttachments[0].loadAction = .clear
        floorPass.colorAttachments[0].clearColor = MTLClearColor(red: 1, green: 1, blue: 1, alpha: 1)
        floorPass.colorAttachments[0].storeAction = .store
        floorPass.depthAttachment.texture = depth
        floorPass.depthAttachment.loadAction = .clear
        floorPass.depthAttachment.clearDepth = 1
        floorPass.depthAttachment.storeAction = .store
        floorRenderer.drawOffscreenHeadless(to: color, depth: depth, commandBuffer: commandBuffer, renderPassDescriptor: floorPass)

        let modelPass = MTLRenderPassDescriptor()
        modelPass.colorAttachments[0].texture = color
        modelPass.colorAttachments[0].loadAction = .load
        modelPass.colorAttachments[0].storeAction = .store
        modelPass.depthAttachment.texture = depth
        modelPass.depthAttachment.loadAction = .load
        modelPass.depthAttachment.storeAction = .dontCare
        modelRenderer.drawOffscreenHeadless(to: color, depth: depth, commandBuffer: commandBuffer, renderPassDescriptor: modelPass)

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        bytes.withUnsafeMutableBytes { buffer in
            color.getBytes(buffer.baseAddress!, bytesPerRow: size * 4,
                           from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
        }
        return bytes
    }
}
