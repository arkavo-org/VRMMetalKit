// Copyright 2026 Arkavo Inc. and contributors
// Licensed under the Apache License, Version 2.0

import XCTest
import Metal
import simd
@testable import VRMMetalKit

/// `KHR_texture_transform` is declared per `textureInfo` (glTF 2.0), and
/// three-vrm applies each texture's own transform. A transform on
/// `baseColorTexture` must move only the base colour, every other MToon
/// texture follows its own transform, and skinned meshes honour them too.
@MainActor
final class MToonPerTextureTransformTests: XCTestCase {
    private var device: MTLDevice!

    override func setUp() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        self.device = device
    }

    // MARK: - Loader

    func testLoaderReadsTransformOnEveryTextureInfo() throws {
        func info(_ index: Int) -> [String: Any] {
            ["index": index, "extensions": ["KHR_texture_transform": ["offset": [Double(index) / 10, 0]]]]
        }
        let json: [String: Any] = [
            "name": "AllSlots",
            "pbrMetallicRoughness": ["baseColorTexture": info(0)],
            "normalTexture": info(1),
            "occlusionTexture": info(2),
            "emissiveTexture": info(3),
            "extensions": [
                "VRMC_materials_mtoon": [
                    "specVersion": "1.0",
                    "shadeMultiplyTexture": info(4),
                    "shadingShiftTexture": info(5),
                    "matcapTexture": info(6),
                    "rimMultiplyTexture": info(7),
                    "outlineWidthMultiplyTexture": info(8),
                    "uvAnimationMaskTexture": info(9),
                ],
            ],
        ]
        let gltfMaterial = try JSONDecoder().decode(
            GLTFMaterial.self, from: JSONSerialization.data(withJSONObject: json))
        let textures = (0..<10).map { VRMTexture(name: "t\($0)") }
        let material = VRMMaterial(from: gltfMaterial, textures: textures)
        let mtoon = try XCTUnwrap(material.mtoon)

        let offsets: [(String, GLTFKHRTextureTransform?, Float)] = [
            ("baseColor", mtoon.textureTransform, 0.0),
            ("normal", material.normalTextureTransform, 0.1),
            ("occlusion", material.occlusionTextureTransform, 0.2),
            ("emissive", material.emissiveTextureTransform, 0.3),
            ("shadeMultiply", mtoon.shadeMultiplyTextureTransform, 0.4),
            ("shadingShift", mtoon.shadingShiftTextureTransform, 0.5),
            ("matcap", mtoon.matcapTextureTransform, 0.6),
            ("rimMultiply", mtoon.rimMultiplyTextureTransform, 0.7),
            ("outlineWidthMultiply", mtoon.outlineWidthMultiplyTextureTransform, 0.8),
            ("uvAnimationMask", mtoon.uvAnimationMaskTextureTransform, 0.9),
        ]
        for (slot, transform, expected) in offsets {
            let transform = try XCTUnwrap(transform, "\(slot)Texture lost its KHR_texture_transform")
            XCTAssertEqual(transform.offset.x, expected, accuracy: 1e-6, "\(slot)Texture read the wrong transform")
        }
    }

    /// The affine rows reproduce the shader's base-colour formula
    /// (`applyTextureTransform`, three.js `setUvTransform`): scale, then
    /// `(c*u + s*v, -s*u + c*v)`, then offset.
    func testTextureTransformRowsMatchBaseColorFormula() {
        let transform = GLTFKHRTextureTransform(offset: [0.25, -0.5], rotation: 0.7, scale: [2, 0.5])
        let (row0, row1) = MToonMaterialUniforms.textureTransformRows(transform)
        let c = cos(transform.rotation)
        let s = sin(transform.rotation)
        for uv in [SIMD2<Float>(0, 0), [1, 0], [0, 1], [0.3, 0.8]] {
            let scaled = uv * transform.scale
            let expected = SIMD2<Float>(c * scaled.x + s * scaled.y, -s * scaled.x + c * scaled.y) + transform.offset
            let h = SIMD3<Float>(uv.x, uv.y, 1)
            let actual = SIMD2<Float>(simd_dot(SIMD3(row0.x, row0.y, row0.z), h),
                                      simd_dot(SIMD3(row1.x, row1.y, row1.z), h))
            XCTAssertEqual(actual.x, expected.x, accuracy: 1e-6, "u at \(uv)")
            XCTAssertEqual(actual.y, expected.y, accuracy: 1e-6, "v at \(uv)")
        }
        let identity = MToonMaterialUniforms.textureTransformRows(nil)
        XCTAssertEqual(identity.row0, [1, 0, 0, 0])
        XCTAssertEqual(identity.row1, [0, 1, 0, 0])
    }

    // MARK: - Rendering

    func testBaseColorTransformLeavesEmissiveTextureInPlace() async throws {
        let plain = try await emissiveFrame(baseTransform: nil, emissiveTransform: nil)
        let baseShifted = try await emissiveFrame(
            baseTransform: GLTFKHRTextureTransform(offset: [0.5, 0.5]), emissiveTransform: nil)
        let stats = SwatchScene.stats(baseShifted, reference: plain, size: 512, threshold: 0)
        XCTAssertEqual(stats.changedPixels, 0,
            "A baseColorTexture transform moved the emissive texture (\(stats.changedPixels) px, max Δ \(stats.maxDelta))")
    }

    func testEmissiveTextureUsesItsOwnTransform() async throws {
        let plain = try await emissiveFrame(baseTransform: nil, emissiveTransform: nil)
        let shifted = try await emissiveFrame(
            baseTransform: nil, emissiveTransform: GLTFKHRTextureTransform(offset: [0.5, 0.5]))
        let stats = SwatchScene.stats(shifted, reference: plain, size: 512,
                                      columns: SwatchScene.third(1, size: 512))
        XCTAssertGreaterThan(stats.changedPixels, 1000,
            "The emissive texture ignored its own KHR_texture_transform")
    }

    func testShadeMultiplyTextureUsesItsOwnTransform() async throws {
        let plain = try await shadeFrame(shadeTransform: nil)
        let shifted = try await shadeFrame(shadeTransform: GLTFKHRTextureTransform(offset: [0.5, 0.5]))
        let stats = SwatchScene.stats(shifted, reference: plain, size: 512,
                                      columns: SwatchScene.third(1, size: 512))
        XCTAssertGreaterThan(stats.changedPixels, 200,
            "The MToon shadeMultiplyTexture ignored its own KHR_texture_transform")
    }

    func testSkinnedMeshAppliesBaseColorTransform() async throws {
        let plain = try await baseColorFrame(.skinned, transform: nil)
        let shifted = try await baseColorFrame(.skinned, transform: GLTFKHRTextureTransform(offset: [0.5, 0.5]))
        let stats = SwatchScene.stats(shifted, reference: plain, size: 512,
                                      columns: SwatchScene.third(1, size: 512))
        XCTAssertGreaterThan(stats.changedPixels, 1000,
            "The skinned path ignored KHR_texture_transform on baseColorTexture")
    }

    func testRigidMeshAppliesBaseColorTransform() async throws {
        let plain = try await baseColorFrame(.rigid, transform: nil)
        let shifted = try await baseColorFrame(.rigid, transform: GLTFKHRTextureTransform(offset: [0.5, 0.5]))
        let stats = SwatchScene.stats(shifted, reference: plain, size: 512,
                                      columns: SwatchScene.third(1, size: 512))
        XCTAssertGreaterThan(stats.changedPixels, 1000,
            "The rigid path ignored KHR_texture_transform on baseColorTexture")
    }

    // MARK: - Helpers

    /// 2×2 texture with red, green, blue and yellow quadrants, so any UV
    /// offset by half a tile swaps colours.
    private func quadrantTexture(name: String) throws -> VRMTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 2, height: 2, mipmapped: false)
        descriptor.usage = .shaderRead
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        var pixels: [UInt8] = [
            255, 0, 0, 255, 0, 255, 0, 255,
            0, 0, 255, 255, 255, 255, 0, 255,
        ]
        texture.replace(region: MTLRegionMake2D(0, 0, 2, 2), mipmapLevel: 0, withBytes: &pixels, bytesPerRow: 8)
        return VRMTexture(name: name, mtlTexture: texture)
    }

    private func whiteTexture(name: String) throws -> VRMTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        descriptor.usage = .shaderRead
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        var pixel: [UInt8] = [255, 255, 255, 255]
        texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &pixel, bytesPerRow: 4)
        return VRMTexture(name: name, mtlTexture: texture)
    }

    private func baseColorFrame(_ fixture: SwatchScene.Fixture, transform: GLTFKHRTextureTransform?) async throws -> [UInt8] {
        let model = try await SwatchScene.load(fixture, device: device)
        let sphere = model.materials[1]
        sphere.baseColorTexture = try quadrantTexture(name: "base")
        sphere.mtoon?.textureTransform = transform
        sphere.mtoon?.outlineWidthMode = .none
        return try SwatchScene.render(model, device: device)
    }

    private func emissiveFrame(
        baseTransform: GLTFKHRTextureTransform?,
        emissiveTransform: GLTFKHRTextureTransform?
    ) async throws -> [UInt8] {
        let model = try await SwatchScene.load(.rigid, device: device)
        let sphere = model.materials[1]
        sphere.baseColorTexture = try whiteTexture(name: "base")
        sphere.baseColorFactor = [0.1, 0.1, 0.1, 1]
        sphere.mtoon?.textureTransform = baseTransform
        sphere.emissiveTexture = try quadrantTexture(name: "emissive")
        sphere.emissiveFactor = [1, 1, 1]
        sphere.emissiveTextureTransform = emissiveTransform
        sphere.mtoon?.outlineWidthMode = .none
        return try SwatchScene.render(model, device: device)
    }

    private func shadeFrame(shadeTransform: GLTFKHRTextureTransform?) async throws -> [UInt8] {
        let model = try await SwatchScene.load(.rigid, device: device)
        model.textures.append(try quadrantTexture(name: "shade"))
        let shadeIndex = model.textures.count - 1
        let sphere = model.materials[1]
        sphere.mtoon?.shadeColorFactor = [1, 1, 1]
        sphere.mtoon?.shadeMultiplyTexture = shadeIndex
        sphere.mtoon?.shadeMultiplyTextureTransform = shadeTransform
        sphere.mtoon?.outlineWidthMode = .none
        return try SwatchScene.render(model, device: device)
    }
}
