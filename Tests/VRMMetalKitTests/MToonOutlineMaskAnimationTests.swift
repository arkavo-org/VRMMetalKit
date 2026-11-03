// Copyright 2026 Arkavo Inc. and contributors
// Licensed under the Apache License, Version 2.0

import XCTest
import Metal
@testable import VRMMetalKit

/// MToon 1.0 lists `outlineWidthMultiplyTexture` among the textures UV
/// animation moves, with the animation applied before the texture's own
/// `KHR_texture_transform`, and the `uvAnimationMaskTexture` B channel scaling
/// the animation.
///
/// The fixture's width mask is 0 on the left half of U and 1 on the right, so
/// the swatch spheres' outline ring covers half of each sphere. Scrolling U by
/// 0.5 swaps the halves.
@MainActor
final class MToonOutlineMaskAnimationTests: XCTestCase {

    private var device: MTLDevice!

    override func setUp() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device not available")
        }
        self.device = device
    }

    func testUVAnimationScrollsTheOutlineWidthMask() async throws {
        for (fixture, doubleSided) in Self.hullPaths {
            let still = try await outlineMask(fixture, doubleSided: doubleSided, time: 0, animationMaskB: nil)
            let scrolled = try await outlineMask(fixture, doubleSided: doubleSided, time: 1, animationMaskB: nil)
            let moved = zip(still, scrolled).filter { $0 != $1 }.count
            XCTAssertGreaterThan(moved, 500,
                "\(Self.label(fixture, doubleSided)): a 0.5 U scroll left the outline ring in place (\(moved) px changed)")
        }
    }

    func testAnimationMaskBlueChannelStopsTheOutlineMaskAnimation() async throws {
        for (fixture, doubleSided) in Self.hullPaths {
            let still = try await outlineMask(fixture, doubleSided: doubleSided, time: 0, animationMaskB: 0)
            let later = try await outlineMask(fixture, doubleSided: doubleSided, time: 1, animationMaskB: 0)
            XCTAssertEqual(still, later,
                "\(Self.label(fixture, doubleSided)): the outline ring moved although the animation mask's B channel is 0")
        }
    }

    // MARK: - Harness

    private static let hullPaths: [(SwatchScene.Fixture, Bool)] = [
        (.rigid, false), (.rigid, true), (.skinned, false), (.skinned, true),
    ]

    private static func label(_ fixture: SwatchScene.Fixture, _ doubleSided: Bool) -> String {
        "\(fixture.rawValue), \(doubleSided ? "dedicated" : "merged") hull"
    }

    /// Positions of outline-dark pixels at the given animation time.
    private func outlineMask(
        _ fixture: SwatchScene.Fixture,
        doubleSided: Bool,
        time: TimeInterval,
        animationMaskB: UInt8?
    ) async throws -> [Bool] {
        let model = try await SwatchScene.load(fixture, device: device)
        let widthMask = try texture(width: 2, pixels: [0, 0, 0, 255, 255, 255, 255, 255])
        model.textures.append(VRMTexture(name: "outlineWidthMask", mtlTexture: widthMask))
        let widthMaskIndex = model.textures.count - 1
        var animationMaskIndex: Int?
        if let animationMaskB {
            let mask = try texture(width: 1, pixels: [255, 255, animationMaskB, 255])
            model.textures.append(VRMTexture(name: "uvAnimationMask", mtlTexture: mask))
            animationMaskIndex = model.textures.count - 1
        }
        for material in model.materials {
            material.doubleSided = doubleSided
            if var mtoon = material.mtoon {
                mtoon.outlineWidthMode = .worldCoordinates
                mtoon.outlineWidthFactor = 0.05
                mtoon.outlineWidthMultiplyTexture = widthMaskIndex
                mtoon.uvAnimationScrollXSpeedFactor = 0.5
                if let animationMaskIndex { mtoon.uvAnimationMaskTexture = animationMaskIndex }
                material.mtoon = mtoon
            }
        }
        let frame = try SwatchScene.render(model, device: device) { renderer in
            renderer.uvAnimationTime = time
        }
        return stride(from: 0, to: frame.count, by: 4).map { SwatchScene.luma(frame, $0) < 0.10 }
    }

    private func texture(width: Int, pixels: [UInt8]) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: 1, mipmapped: false)
        descriptor.usage = .shaderRead
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        var bytes = pixels
        texture.replace(region: MTLRegionMake2D(0, 0, width, 1), mipmapLevel: 0, withBytes: &bytes, bytesPerRow: width * 4)
        return texture
    }
}
