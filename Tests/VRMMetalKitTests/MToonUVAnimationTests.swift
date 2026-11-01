// Copyright 2026 Arkavo Inc. and contributors
// Licensed under the Apache License, Version 2.0

import XCTest
import Metal
import simd
@testable import VRMMetalKit

/// MToon UV animation (VRMC_materials_mtoon-1.0, three-vrm, UniVRM): after
/// `t` seconds, UVs rotate by `uvAnimationRotationSpeedFactor * t` radians
/// about (0.5, 0.5), then scroll by `uvAnimationScroll*SpeedFactor * t` UV
/// units toward +u/+v in glTF UV space. The B channel of
/// `uvAnimationMaskTexture` scales `t`.
@MainActor
final class MToonUVAnimationTests: XCTestCase {
    private var device: MTLDevice!

    override func setUp() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        self.device = device
    }

    func testScrollAfterOneSecondEqualsTheSameUVOffset() async throws {
        for fixture in [SwatchScene.Fixture.rigid, .skinned] {
            let still = try await frame(fixture)
            let offset = try await frame(fixture, baseTransform: GLTFKHRTextureTransform(offset: [0.5, 0.25]))
            let scrolled = try await frame(fixture, scroll: [0.5, 0.25], time: 1)
            XCTAssertGreaterThan(SwatchScene.differingBytes(still, offset), 1000, "\(fixture): the offset is not visible")
            let stats = SwatchScene.stats(scrolled, reference: offset, size: 512, threshold: 0)
            XCTAssertEqual(stats.changedPixels, 0,
                "\(fixture): scrolling (0.5, 0.25) UV/s for 1 s differs from a (0.5, 0.25) UV offset in \(stats.changedPixels) px")
        }
    }

    func testRotationTurnsAboutTheUVCentreInRadians() async throws {
        let angle = Float.pi / 2
        let c = cos(angle)
        let s = sin(angle)
        // M * (uv - 0.5) + 0.5 with M = [[c, s], [-s, c]], the matrix
        // KHR_texture_transform applies, written as a transform about the origin.
        let aboutCentre = GLTFKHRTextureTransform(
            offset: [0.5 - 0.5 * c - 0.5 * s, 0.5 + 0.5 * s - 0.5 * c], rotation: angle)
        let still = try await frame(.rigid)
        let expected = try await frame(.rigid, baseTransform: aboutCentre)
        let rotated = try await frame(.rigid, rotation: angle, time: 1)
        XCTAssertGreaterThan(SwatchScene.differingBytes(still, expected), 1000, "the rotation is not visible")
        let stats = SwatchScene.stats(rotated, reference: expected, size: 512, threshold: 2)
        XCTAssertLessThan(stats.changedPixels, 50,
            "Rotating π/2 rad/s for 1 s differs from a π/2 turn about (0.5, 0.5) in \(stats.changedPixels) px")
    }

    func testMaskBlueChannelScalesAnimationTime() async throws {
        let still = try await frame(.rigid)
        let offset = try await frame(.rigid, baseTransform: GLTFKHRTextureTransform(offset: [0.5, 0.25]))
        let blueMask = try await frame(.rigid, scroll: [0.5, 0.25], time: 1, mask: [0, 0, 255, 255])
        let redMask = try await frame(.rigid, scroll: [0.5, 0.25], time: 1, mask: [255, 255, 0, 255])
        XCTAssertEqual(SwatchScene.differingBytes(blueMask, offset), 0,
            "A mask with B = 1 did not let the UVs scroll")
        XCTAssertEqual(SwatchScene.differingBytes(redMask, still), 0,
            "A mask with B = 0 (R = G = 1) let the UVs scroll")
    }

    func testAnimationTimeAdvancesBySimulationStep() async throws {
        let model = try await SwatchScene.load(.rigid, device: device)
        try prepare(model, scroll: [0.5, 0.25])
        let renderer = SwatchScene.makeRenderer(model: model, device: device, setup: SwatchScene.Setup())
        renderer.simulationDeltaTime = 0.5
        let first = try RenderTestSupport.renderFrame(
            renderer: renderer, device: device, size: 512, pixelFormat: .rgba8Unorm,
            clearColor: SwatchScene.Setup().clearColor)
        let second = try RenderTestSupport.renderFrame(
            renderer: renderer, device: device, size: 512, pixelFormat: .rgba8Unorm,
            clearColor: SwatchScene.Setup().clearColor)
        let still = try await frame(.rigid)
        XCTAssertEqual(renderer.uvAnimationTime, 1.0, accuracy: 1e-9)
        XCTAssertEqual(SwatchScene.differingBytes(first, still), 0,
            "The first draw did not render at uvAnimationTime 0")
        XCTAssertGreaterThan(SwatchScene.differingBytes(first, second), 1000,
            "UV animation did not advance between draws")
    }

    // MARK: - Helpers

    private func frame(
        _ fixture: SwatchScene.Fixture,
        scroll: SIMD2<Float> = .zero,
        rotation: Float = 0,
        time: TimeInterval = 0,
        mask: [UInt8]? = nil,
        baseTransform: GLTFKHRTextureTransform? = nil
    ) async throws -> [UInt8] {
        let model = try await SwatchScene.load(fixture, device: device)
        try prepare(model, scroll: scroll, rotation: rotation, mask: mask, baseTransform: baseTransform)
        return try SwatchScene.render(model, device: device) { renderer in
            renderer.uvAnimationTime = time
        }
    }

    private func prepare(
        _ model: VRMModel,
        scroll: SIMD2<Float>,
        rotation: Float = 0,
        mask: [UInt8]? = nil,
        baseTransform: GLTFKHRTextureTransform? = nil
    ) throws {
        let sphere = model.materials[1]
        sphere.baseColorTexture = try texture(width: 2, height: 2, pixels: [
            255, 0, 0, 255, 0, 255, 0, 255,
            0, 0, 255, 255, 255, 255, 0, 255,
        ])
        sphere.mtoon?.textureTransform = baseTransform
        sphere.mtoon?.uvAnimationScrollXSpeedFactor = scroll.x
        sphere.mtoon?.uvAnimationScrollYSpeedFactor = scroll.y
        sphere.mtoon?.uvAnimationRotationSpeedFactor = rotation
        sphere.mtoon?.outlineWidthMode = .none
        if let mask {
            model.textures.append(try texture(width: 1, height: 1, pixels: mask))
            sphere.mtoon?.uvAnimationMaskTexture = model.textures.count - 1
        }
    }

    private func texture(width: Int, height: Int, pixels: [UInt8]) throws -> VRMTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = .shaderRead
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        var bytes = pixels
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                        withBytes: &bytes, bytesPerRow: width * 4)
        return VRMTexture(name: "uvAnimation", mtlTexture: texture)
    }
}
