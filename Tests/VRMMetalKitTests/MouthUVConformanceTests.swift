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

/// Regression tests for issue #477: MToon materials named `*mouth*` or `*lip*`
/// must sample authored `TEXCOORD_0` unmodified instead of applying a hardcoded
/// UV offset/scale transform.
@MainActor
final class MouthUVConformanceTests: XCTestCase {
    private var device: MTLDevice!

    override func setUp() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        self.device = device
    }

    /// Renaming an MToon material to `FaceMouth_00` or `UpperLip_00` must
    /// produce identical pixels to a non-mouth material with matching face-overlay
    /// or default cull/depth state on both rigid and skinned geometry, with
    /// default `disableAutoMaterialOverrides = false`.
    func testMouthAndLipMaterialsSampleAuthoredUVsUnmodified() async throws {
        for fixture in [SwatchScene.Fixture.rigid, .skinned] {
            let neutralRef = try await renderQuadrantSwatch(fixture: fixture, materialName: "NeutralSwatch_00")
            // FaceMouth_00 and FaceEyebrow_00 share faceOverlay cull (.none) and depth-bias state,
            // isolating UV sampling from cull-mode differences at sphere silhouette edges.
            let faceOverlayRef = try await renderQuadrantSwatch(fixture: fixture, materialName: "FaceEyebrow_00")
            let mouth = try await renderQuadrantSwatch(fixture: fixture, materialName: "FaceMouth_00")
            let lip = try await renderQuadrantSwatch(fixture: fixture, materialName: "UpperLip_00")

            let mouthStats = SwatchScene.stats(mouth, reference: faceOverlayRef, size: 512,
                                               columns: SwatchScene.third(1, size: 512), threshold: 0)
            XCTAssertEqual(mouthStats.changedPixels, 0,
                "\(fixture.rawValue): FaceMouth_00 shifted UVs relative to authored TEXCOORD_0 (\(mouthStats.changedPixels) px changed, max Δ \(mouthStats.maxDelta))")

            let lipStats = SwatchScene.stats(lip, reference: neutralRef, size: 512,
                                             columns: SwatchScene.third(1, size: 512), threshold: 0)
            XCTAssertEqual(lipStats.changedPixels, 0,
                "\(fixture.rawValue): UpperLip_00 shifted UVs relative to authored TEXCOORD_0 (\(lipStats.changedPixels) px changed, max Δ \(lipStats.maxDelta))")
        }
    }

    /// Reproduces issue #477's symmetric radial `FaceMouth_00` lip + oral-cavity
    /// texture on a unit-UV quad: left lip `(u=0.15, v=0.5)` and right lip
    /// `(u=0.85, v=0.5)` must sample identical pink lip pigment while the center
    /// `(u=0.50, v=0.50)` samples the dark oral cavity.
    func testSymmetricRadialFaceMouthTextureRendersSymmetrically() async throws {
        let model = try await makeQuadVRM(materialName: "FaceMouth_00")
        let radial = try makeRadialMouthTexture(size: 64)
        model.materials[0].baseColorTexture = radial
        model.materials[0].baseColorFactor = SIMD4<Float>(1, 1, 1, 1)
        model.materials[0].mtoon?.shadeColorFactor = SIMD3<Float>(1, 1, 1)
        model.materials[0].mtoon?.outlineWidthMode = .none

        var config = RendererConfig()
        config.colorPixelFormat = .rgba8Unorm
        config.sampleCount = 1
        let renderer = VRMRenderer(device: device, config: config)
        XCTAssertFalse(renderer.config.legacyMaterialHeuristics, "Must pass under default spec-driven rendering")
        renderer.loadModel(model)
        renderer.setLight(0, direction: SIMD3<Float>(0, 0, -1), color: SIMD3<Float>(1, 1, 1), intensity: 1.0)
        renderer.disableLight(1)
        renderer.disableLight(2)
        renderer.setAmbientColor(SIMD3<Float>(1, 1, 1))
        renderer.viewMatrix = RenderTestSupport.makeLookAt(
            eye: SIMD3<Float>(0, 0, 2.0),
            center: SIMD3<Float>(0, 0, 0),
            up: SIMD3<Float>(0, 1, 0))
        renderer.projectionMatrix = makeOrthographic(left: -0.5, right: 0.5, bottom: -0.5, top: 0.5, near: 0.1, far: 10.0)

        let size = 128
        let pixels = try RenderTestSupport.renderFrame(
            renderer: renderer,
            device: device,
            size: size,
            pixelFormat: .rgba8Unorm,
            clearColor: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1))

        let leftLip = sampleRGB(pixels, size: size, x: Int(Double(size) * 0.15), y: size / 2)
        let centerCavity = sampleRGB(pixels, size: size, x: size / 2, y: size / 2)
        let rightLip = sampleRGB(pixels, size: size, x: Int(Double(size) * 0.85), y: size / 2)

        XCTAssertEqual(leftLip.x, rightLip.x, accuracy: 2,
            "Left lip R (\(leftLip.x)) must match right lip R (\(rightLip.x)) for symmetric FaceMouth_00 texture")
        XCTAssertEqual(leftLip.y, rightLip.y, accuracy: 2,
            "Left lip G (\(leftLip.y)) must match right lip G (\(rightLip.y))")
        XCTAssertEqual(leftLip.z, rightLip.z, accuracy: 2,
            "Left lip B (\(leftLip.z)) must match right lip B (\(rightLip.z))")

        XCTAssertGreaterThan(leftLip.y, centerCavity.y + 60,
            "Left lip must sample bright pink lip band (G=\(leftLip.y)), not dark oral cavity (G=\(centerCavity.y))")
        XCTAssertGreaterThan(rightLip.y, centerCavity.y + 60,
            "Right lip must sample bright pink lip band (G=\(rightLip.y)), not dark oral cavity (G=\(centerCavity.y))")
    }

    /// Four-quadrant test on a unit-UV `FaceMouth_00` quad verifying every
    /// quadrant samples its authored region directly.
    func testQuadrantFaceMouthQuadSamplesAllFourQuadrants() async throws {
        let model = try await makeQuadVRM(materialName: "FaceMouth_00")
        model.materials[0].baseColorTexture = try makeCrispQuadrantTexture(size: 64)
        model.materials[0].baseColorFactor = SIMD4<Float>(1, 1, 1, 1)
        model.materials[0].mtoon?.shadeColorFactor = SIMD3<Float>(1, 1, 1)
        model.materials[0].mtoon?.outlineWidthMode = .none

        var config = RendererConfig()
        config.colorPixelFormat = .rgba8Unorm
        config.sampleCount = 1
        let renderer = VRMRenderer(device: device, config: config)
        renderer.loadModel(model)
        renderer.setLight(0, direction: SIMD3<Float>(0, 0, -1), color: SIMD3<Float>(1, 1, 1), intensity: 1.0)
        renderer.disableLight(1)
        renderer.disableLight(2)
        renderer.setAmbientColor(SIMD3<Float>(1, 1, 1))
        renderer.viewMatrix = RenderTestSupport.makeLookAt(
            eye: SIMD3<Float>(0, 0, 2.0),
            center: SIMD3<Float>(0, 0, 0),
            up: SIMD3<Float>(0, 1, 0))
        renderer.projectionMatrix = makeOrthographic(left: -0.5, right: 0.5, bottom: -0.5, top: 0.5, near: 0.1, far: 10.0)

        let size = 128
        let pixels = try RenderTestSupport.renderFrame(
            renderer: renderer,
            device: device,
            size: size,
            pixelFormat: .rgba8Unorm,
            clearColor: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1))

        // Sample inner corners close to u=0.40 where old uv*0.5+0.35 crossed u'=0.55 into the right half
        let tl = sampleRGB(pixels, size: size, x: Int(Double(size) * 0.40), y: Int(Double(size) * 0.25))
        let tr = sampleRGB(pixels, size: size, x: Int(Double(size) * 0.75), y: Int(Double(size) * 0.25))
        let bl = sampleRGB(pixels, size: size, x: Int(Double(size) * 0.40), y: Int(Double(size) * 0.75))
        let br = sampleRGB(pixels, size: size, x: Int(Double(size) * 0.75), y: Int(Double(size) * 0.75))

        XCTAssertGreaterThan(tl.x, tl.y + 100, "Top-left (u=0.40, v=0.25) must stay red, got \(tl)")
        XCTAssertGreaterThan(tl.x, tl.z + 100, "Top-left (u=0.40, v=0.25) must stay red, got \(tl)")
        XCTAssertGreaterThan(tr.y, tr.x + 100, "Top-right (u=0.75, v=0.25) must be green, got \(tr)")
        XCTAssertGreaterThan(tr.y, tr.z + 100, "Top-right (u=0.75, v=0.25) must be green, got \(tr)")
        XCTAssertGreaterThan(bl.z, bl.x + 100, "Bottom-left (u=0.40, v=0.75) must stay blue, got \(bl)")
        XCTAssertGreaterThan(bl.z, bl.y + 100, "Bottom-left (u=0.40, v=0.75) must stay blue, got \(bl)")
        XCTAssertGreaterThan(br.x, br.z + 100, "Bottom-right (u=0.75, v=0.75) must be yellow, got \(br)")
        XCTAssertGreaterThan(br.y, br.z + 100, "Bottom-right (u=0.75, v=0.75) must be yellow, got \(br)")
    }

    // MARK: - Helpers

    private func renderQuadrantSwatch(fixture: SwatchScene.Fixture, materialName: String) async throws -> [UInt8] {
        let model = try await SwatchScene.load(fixture, device: device)
        let original = model.materials[1]
        let gltfMat = try JSONDecoder().decode(
            GLTFMaterial.self,
            from: JSONSerialization.data(withJSONObject: ["name": materialName]))
        let renamed = VRMMaterial(from: gltfMat, textures: model.textures)
        renamed.baseColorFactor = original.baseColorFactor
        renamed.baseColorTexture = try makeCrispQuadrantTexture(size: 64)
        renamed.doubleSided = original.doubleSided
        renamed.alphaMode = original.alphaMode
        renamed.alphaCutoff = original.alphaCutoff
        renamed.mtoon = original.mtoon
        renamed.mtoon?.outlineWidthMode = .none
        model.materials[1] = renamed
        return try SwatchScene.render(model, device: device)
    }

    private func makeCrispQuadrantTexture(size: Int) throws -> VRMTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: size, height: size, mipmapped: false)
        desc.usage = .shaderRead
        let texture = try XCTUnwrap(device.makeTexture(descriptor: desc))
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        let half = size / 2
        for y in 0..<size {
            for x in 0..<size {
                let idx = (y * size + x) * 4
                if y < half && x < half {
                    pixels[idx] = 255; pixels[idx + 1] = 0; pixels[idx + 2] = 0; pixels[idx + 3] = 255
                } else if y < half && x >= half {
                    pixels[idx] = 0; pixels[idx + 1] = 255; pixels[idx + 2] = 0; pixels[idx + 3] = 255
                } else if y >= half && x < half {
                    pixels[idx] = 0; pixels[idx + 1] = 0; pixels[idx + 2] = 255; pixels[idx + 3] = 255
                } else {
                    pixels[idx] = 255; pixels[idx + 1] = 255; pixels[idx + 2] = 0; pixels[idx + 3] = 255
                }
            }
        }
        texture.replace(region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0,
                        withBytes: &pixels, bytesPerRow: size * 4)
        return VRMTexture(name: "quadrant", mtlTexture: texture)
    }

    private func makeRadialMouthTexture(size: Int) throws -> VRMTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: size, height: size, mipmapped: false)
        desc.usage = .shaderRead
        let texture = try XCTUnwrap(device.makeTexture(descriptor: desc))
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        for y in 0..<size {
            let v = (Double(y) + 0.5) / Double(size)
            for x in 0..<size {
                let u = (Double(x) + 0.5) / Double(size)
                let r = hypot(u - 0.5, v - 0.5)
                let idx = (y * size + x) * 4
                if r < 0.20 {
                    // Dark oral cavity (#7d2f35)
                    pixels[idx] = 0x7d; pixels[idx + 1] = 0x2f; pixels[idx + 2] = 0x35; pixels[idx + 3] = 255
                } else {
                    // Pink lip pigment (#d2988f)
                    pixels[idx] = 0xd2; pixels[idx + 1] = 0x98; pixels[idx + 2] = 0x8f; pixels[idx + 3] = 255
                }
            }
        }
        texture.replace(region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0,
                        withBytes: &pixels, bytesPerRow: size * 4)
        return VRMTexture(name: "radial_mouth", mtlTexture: texture)
    }

    private func sampleRGB(_ bytes: [UInt8], size: Int, x: Int, y: Int) -> SIMD3<Int> {
        let idx = (y * size + x) * 4
        return SIMD3<Int>(Int(bytes[idx]), Int(bytes[idx + 1]), Int(bytes[idx + 2]))
    }

    private func makeOrthographic(left: Float, right: Float, bottom: Float, top: Float, near: Float, far: Float) -> float4x4 {
        let rl = right - left
        let tb = top - bottom
        let fn = far - near
        return float4x4(columns: (
            SIMD4<Float>(2 / rl, 0, 0, 0),
            SIMD4<Float>(0, 2 / tb, 0, 0),
            SIMD4<Float>(0, 0, -1 / fn, 0),
            SIMD4<Float>(-(right + left) / rl, -(top + bottom) / tb, -near / fn, 1)
        ))
    }

    /// Builds a minimal VRM 1.0 GLB containing a single front-facing unit quad
    /// covering `[-0.5, 0.5] x [-0.5, 0.5]` at `z = 0` with authored `TEXCOORD_0`
    /// in `[0, 1] x [0, 1]` (`v = 0` at top, `v = 1` at bottom).
    private func makeQuadVRM(materialName: String) async throws -> VRMModel {
        let positions: [Float] = [
            -0.5,  0.5, 0.0,
             0.5,  0.5, 0.0,
             0.5, -0.5, 0.0,
            -0.5, -0.5, 0.0,
        ]
        let normals: [Float] = [
            0, 0, 1,
            0, 0, 1,
            0, 0, 1,
            0, 0, 1,
        ]
        let texCoords: [Float] = [
            0, 0,
            1, 0,
            1, 1,
            0, 1,
        ]
        let indices: [UInt16] = [0, 3, 2, 0, 2, 1]

        var bin = Data()
        func append<T>(_ array: [T]) -> (offset: Int, length: Int) {
            let offset = bin.count
            array.withUnsafeBytes { bin.append(contentsOf: $0) }
            let length = bin.count - offset
            while bin.count % 4 != 0 { bin.append(0) }
            return (offset, length)
        }
        let posSlice = append(positions)
        let normSlice = append(normals)
        let uvSlice = append(texCoords)
        let idxSlice = append(indices)

        let requiredBones = VRMHumanoidBone.allCases.filter(\.isRequired)
        var nodes: [[String: Any]] = [["name": "Quad", "mesh": 0]]
        var humanBones: [String: Any] = [:]
        for bone in requiredBones {
            let nodeIndex = nodes.count
            nodes.append(["name": bone.rawValue])
            humanBones[bone.rawValue] = ["node": nodeIndex]
        }

        let json: [String: Any] = [
            "asset": ["version": "2.0"],
            "scene": 0,
            "scenes": [["nodes": [0]]],
            "nodes": nodes,
            "materials": [[
                "name": materialName,
                "alphaMode": "OPAQUE",
                "doubleSided": true,
                "pbrMetallicRoughness": ["baseColorFactor": [1.0, 1.0, 1.0, 1.0]],
                "extensions": [
                    "VRMC_materials_mtoon": [
                        "specVersion": "1.0",
                        "shadeColorFactor": [1.0, 1.0, 1.0],
                        "shadingToonyFactor": 0.0,
                        "shadingShiftFactor": 0.0,
                    ]
                ],
            ]],
            "meshes": [[
                "name": "QuadMesh",
                "primitives": [[
                    "attributes": ["POSITION": 0, "NORMAL": 1, "TEXCOORD_0": 2],
                    "indices": 3,
                    "material": 0,
                ]]
            ]],
            "buffers": [["byteLength": bin.count]],
            "bufferViews": [
                ["buffer": 0, "byteOffset": posSlice.offset, "byteLength": posSlice.length, "target": 34962],
                ["buffer": 0, "byteOffset": normSlice.offset, "byteLength": normSlice.length, "target": 34962],
                ["buffer": 0, "byteOffset": uvSlice.offset, "byteLength": uvSlice.length, "target": 34962],
                ["buffer": 0, "byteOffset": idxSlice.offset, "byteLength": idxSlice.length, "target": 34963],
            ],
            "accessors": [
                ["bufferView": 0, "componentType": 5126, "count": 4, "type": "VEC3",
                 "min": [-0.5, -0.5, 0.0], "max": [0.5, 0.5, 0.0]],
                ["bufferView": 1, "componentType": 5126, "count": 4, "type": "VEC3"],
                ["bufferView": 2, "componentType": 5126, "count": 4, "type": "VEC2"],
                ["bufferView": 3, "componentType": 5123, "count": 6, "type": "SCALAR"],
            ],
            "extensionsUsed": ["VRMC_vrm", "VRMC_materials_mtoon"],
            "extensions": [
                "VRMC_vrm": [
                    "specVersion": "1.0",
                    "meta": [
                        "name": "QuadMouthTest",
                        "authors": ["Test"],
                        "licenseUrl": "https://vrm.dev/licenses/1.0/",
                    ],
                    "humanoid": [
                        "humanBones": humanBones
                    ],
                ]
            ],
        ]

        var jsonData = try JSONSerialization.data(withJSONObject: json)
        while jsonData.count % 4 != 0 { jsonData.append(0x20) }

        var glb = Data()
        func appendU32(_ v: UInt32) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { glb.append(contentsOf: $0) }
        }
        let totalLength = UInt32(12 + 8 + jsonData.count + 8 + bin.count)
        appendU32(0x46546C67) // glTF
        appendU32(2)
        appendU32(totalLength)
        appendU32(UInt32(jsonData.count))
        appendU32(0x4E4F534A) // JSON
        glb.append(jsonData)
        appendU32(UInt32(bin.count))
        appendU32(0x004E4942) // BIN\0
        glb.append(bin)

        return try await VRMModel.load(from: glb, device: device)
    }
}
