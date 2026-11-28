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

/// GPU regression tests for MToon shader and renderer correctness fixes:
/// - Rigid `mtoon_vertex` and `mtoon_outline_vertex` viewNormal w-component leak
/// - `needsViewDirection` missing `additiveDirectionalRimEnabled` in Silhouette mode
/// - `rimMultiplyTexture` RGB color multiplication (`.rgb` vs `.r`)
/// - Non-MToon `"eye"` auto-override honoring `disableAutoMaterialOverrides`
@MainActor
final class MToonBugFixRegressionTests: XCTestCase {
    private var device: MTLDevice!

    override func setUp() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        self.device = device
    }

    // MARK: - Rigid viewNormal w-component leak hardening (MatCap & screen-space outlines)

    /// Translating a rigid mesh and camera together by the same world offset must
    /// produce the same MatCap shading even when `node.normalMatrix` is set to a
    /// raw full 4x4 `worldMatrix.inverse.transpose` (non-zero 4th row). Before the
    /// fix, `mtoon_vertex` multiplied `viewMatrix * normalMatrix * float4(N, 0)`,
    /// leaking row 4 into `viewMatrix`'s translation column and corrupting `viewNormal`.
    func testRigidMatCapMatchesOriginWhenMeshAndCameraTranslated() async throws {
        let originFrame = try await renderMatCapFrame(translation: SIMD3<Float>(0, 0, 0))
        let translatedFrame = try await renderMatCapFrame(translation: SIMD3<Float>(0, 10, 0))

        let stats = SwatchScene.stats(translatedFrame, reference: originFrame, size: 256,
                                      columns: SwatchScene.third(1, size: 256), threshold: 3)
        XCTAssertLessThanOrEqual(stats.maxDelta, 4,
            "Translated rigid MatCap diverged from origin frame (changedPixels=\(stats.changedPixels), maxDelta=\(stats.maxDelta))")
    }

    /// Translating a double-sided rigid mesh with screen-coordinates outline and
    /// camera together must produce the same outline hull even with a raw 4x4
    /// `worldMatrix.inverse.transpose` normalMatrix. Before the fix,
    /// `mtoon_outline_vertex` had the same `viewMatrix * normalMatrix * float4(N, 0)` w-leak.
    func testRigidScreenSpaceOutlineMatchesOriginWhenTranslated() async throws {
        let originFrame = try await renderScreenOutlineFrame(translation: SIMD3<Float>(0, 0, 0))
        let translatedFrame = try await renderScreenOutlineFrame(translation: SIMD3<Float>(0, 10, 0))

        let stats = SwatchScene.stats(translatedFrame, reference: originFrame, size: 256,
                                      columns: SwatchScene.third(1, size: 256), threshold: 3)
        XCTAssertLessThanOrEqual(stats.maxDelta, 4,
            "Translated rigid screen-space outline diverged from origin frame (changedPixels=\(stats.changedPixels), maxDelta=\(stats.maxDelta))")
    }

    // MARK: - Silhouette additive directional rim viewDirection

    /// When `additiveDirectionalRimEnabled` is true and `parametricRimColorFactor`
    /// is zero (as configured by `applySilhouetteMode`), both rigid and skinned
    /// vertex shaders must compute the true world-space `viewDirection` rather
    /// than emitting the dummy `(0, 0, 1)` vector.
    ///
    /// Viewing from `+X` with a light illuminating `+X` and `+Y`:
    /// - Camera-facing center (`N = +X`, `V = +X`) has `N·V = 1` → near-zero rim.
    ///   (With dummy `V = (0, 0, 1)`, `N·V = 0` → maximum rim at the center.)
    /// - Upper silhouette edge (`N ≈ +Y`, `V = +X`) has `N·V ≈ 0` → bright rim.
    func testSilhouetteAdditiveDirectionalRimUsesActualCameraViewDirection() async throws {
        for fixture in [SwatchScene.Fixture.rigid, .skinned] {
            let model = try await SwatchScene.load(fixture, device: device)
            // Keep only the center sphere (material 1) visible so the side camera
            // doesn't overlap the -1.3 / +1.3 neighbor spheres along the X axis.
            for idx in [0, 2] where idx < model.materials.count {
                model.materials[idx].alphaMode = .mask
                model.materials[idx].alphaCutoff = 1.1
                model.materials[idx].baseColorFactor = SIMD4<Float>(0, 0, 0, 0)
            }

            var setup = SwatchScene.Setup()
            setup.size = 256
            setup.eye = SIMD3<Float>(3.0, 0, 0)
            setup.center = SIMD3<Float>(0, 0, 0)
            setup.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

            var silConfig = SilhouetteRenderConfig()
            // Light from (+X, +Y) lights both the center (+X) and top silhouette (+Y)
            silConfig.rimLightDirection = simd_normalize(SIMD3<Float>(-1.0, -1.0, 0.0))
            silConfig.rimLightColor = SIMD3<Float>(1.0, 0.6, 0.2)
            silConfig.rimLightIntensity = 1.0
            silConfig.rimFresnelPower = 4.0

            let pixels = try SwatchScene.render(model, device: device, setup: setup) { renderer in
                renderer.applySilhouetteMode(model: model, config: silConfig)
            }

            let centerIdx = (128 * 256 + 128) * 4
            let centerLuma = SwatchScene.luma(pixels, centerIdx)
            XCTAssertLessThan(centerLuma, 0.05,
                "\(fixture.rawValue): camera-facing center (N=+X, V=+X) must have near-zero silhouette rim, got luma=\(centerLuma)")

            // Scan vertical centerline above center to find the upper grazing silhouette rim
            var upperRimMaxLuma = 0.0
            for y in 40..<120 {
                let i = (y * 256 + 128) * 4
                upperRimMaxLuma = max(upperRimMaxLuma, SwatchScene.luma(pixels, i))
            }
            XCTAssertGreaterThan(upperRimMaxLuma, 0.20,
                "\(fixture.rawValue): upper grazing silhouette edge (N≈+Y, V=+X) must show bright additive rim, got max luma=\(upperRimMaxLuma)")
        }
    }

    // MARK: - rimMultiplyTexture RGB color multiplication

    /// Per VRMC_materials_mtoon-1.0, `rimMultiplyTexture` multiplies rim color
    /// across all RGB channels, not only the red channel.
    func testRimMultiplyTextureModulatesAllRGBChannels() async throws {
        let model = try await SwatchScene.load(.rigid, device: device)
        let blueTex = try makeSolidTexture(r: 0, g: 0, b: 255, a: 255, name: "rim_blue")
        model.textures.append(blueTex)

        let sphere = model.materials[1]
        sphere.baseColorFactor = SIMD4<Float>(0, 0, 0, 1)
        sphere.mtoon?.shadeColorFactor = SIMD3<Float>(0, 0, 0)
        sphere.mtoon?.parametricRimColorFactor = SIMD3<Float>(1, 1, 1)
        sphere.mtoon?.parametricRimFresnelPowerFactor = 2.0
        sphere.mtoon?.parametricRimLiftFactor = 0.0
        sphere.mtoon?.rimLightingMixFactor = 0.0
        sphere.mtoon?.rimMultiplyTexture = blueTex
        sphere.mtoon?.outlineWidthMode = .none

        var setup = SwatchScene.Setup()
        setup.size = 256
        setup.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        let pixels = try SwatchScene.render(model, device: device, setup: setup) { renderer in
            renderer.setAmbientColor(SIMD3<Float>(0, 0, 0))
        }

        let cols = SwatchScene.third(1, size: 256)
        var maxR = 0
        var maxG = 0
        var maxB = 0
        for y in 0..<256 {
            for x in cols {
                let i = (y * 256 + x) * 4
                maxR = max(maxR, Int(pixels[i]))
                maxG = max(maxG, Int(pixels[i + 1]))
                maxB = max(maxB, Int(pixels[i + 2]))
            }
        }

        XCTAssertGreaterThan(maxB, 140,
            "Pure-blue rimMultiplyTexture must pass blue channel through to rim (got max RGB=(\(maxR),\(maxG),\(maxB)))")
        XCTAssertLessThan(maxR, 15,
            "Pure-blue rimMultiplyTexture must suppress red channel (got maxR=\(maxR))")
        XCTAssertLessThan(maxG, 15,
            "Pure-blue rimMultiplyTexture must suppress green channel (got maxG=\(maxG))")
    }

    // MARK: - Non-MToon eye material preserves authored black albedo in spec-driven mode

    /// Under v2.0 spec-driven default (`legacyMaterialHeuristics == false`),
    /// non-MToon `"FaceEye_00"` keeps its authored black albedo instead of
    /// getting forced to white.
    func testDisableAutoMaterialOverridesProtectsNonMToonEyeMaterial() async throws {
        let model = try await SwatchScene.load(.rigid, device: device)
        let gltfMat = try JSONDecoder().decode(
            GLTFMaterial.self,
            from: JSONSerialization.data(withJSONObject: ["name": "FaceEye_00"]))
        let eyeMat = VRMMaterial(from: gltfMat, textures: model.textures)
        eyeMat.mtoon = nil
        eyeMat.baseColorTexture = nil
        eyeMat.baseColorFactor = SIMD4<Float>(0, 0, 0, 1)
        eyeMat.emissiveFactor = SIMD3<Float>(0, 0, 0)
        model.materials[1] = eyeMat

        var setup = SwatchScene.Setup()
        setup.size = 256
        setup.lightDirection = SIMD3<Float>(-1, 0, 0)
        setup.lightIntensity = 2.5
        setup.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        let pixels = try SwatchScene.render(model, device: device, setup: setup) { renderer in
            renderer.setAmbientColor(SIMD3<Float>(0, 0, 0))
        }

        let cols = SwatchScene.third(1, size: 256)
        var maxLuma = 0.0
        for y in 0..<256 {
            for x in cols {
                let i = (y * 256 + x) * 4
                maxLuma = max(maxLuma, SwatchScene.luma(pixels, i))
            }
        }

        XCTAssertLessThan(maxLuma, 0.05,
            "Non-MToon FaceEye_00 with black albedo in spec-driven mode must remain black, got max luma=\(maxLuma)")
    }

    // MARK: - mtoon_debug_rim single-channel parametricRimColorFactor

    /// `mtoon_debug_rim` must treat single-channel rim colors (e.g. `(1, 0, 0)`) as active
    /// (`all(rimColorFactor <= 0.0)`), rather than returning black when any channel is zero.
    func testDebugRimShaderAcceptsSingleChannelRimColor() throws {
        let library = try VRMPipelineCache.shared.getLibrary(device: device)
        let constants = MToonFunctionConstantKey.fallback.makeFunctionConstantValues()
        let vertexFn = try library.makeFunction(name: "mtoon_vertex", constantValues: constants)
        let fragmentFn = try library.makeFunction(name: "mtoon_debug_rim", constantValues: constants)

        // Fullscreen quad with grazing normals pointing along +X while camera looks down -Z (V = +Z)
        struct TestVertex {
            var pos: SIMD3<Float>
            var normal: SIMD3<Float>
            var uv: SIMD2<Float>
            var color: SIMD4<Float>
        }

        let vDesc = MTLVertexDescriptor()
        vDesc.attributes[0].format = .float3
        vDesc.attributes[0].offset = MemoryLayout<TestVertex>.offset(of: \.pos)!
        vDesc.attributes[0].bufferIndex = 0
        vDesc.attributes[1].format = .float3
        vDesc.attributes[1].offset = MemoryLayout<TestVertex>.offset(of: \.normal)!
        vDesc.attributes[1].bufferIndex = 0
        vDesc.attributes[2].format = .float2
        vDesc.attributes[2].offset = MemoryLayout<TestVertex>.offset(of: \.uv)!
        vDesc.attributes[2].bufferIndex = 0
        vDesc.attributes[3].format = .float4
        vDesc.attributes[3].offset = MemoryLayout<TestVertex>.offset(of: \.color)!
        vDesc.attributes[3].bufferIndex = 0
        vDesc.layouts[0].stride = MemoryLayout<TestVertex>.stride

        let pDesc = MTLRenderPipelineDescriptor()
        pDesc.vertexFunction = vertexFn
        pDesc.fragmentFunction = fragmentFn
        pDesc.vertexDescriptor = vDesc
        pDesc.colorAttachments[0].pixelFormat = .rgba8Unorm
        let pipeline = try device.makeRenderPipelineState(descriptor: pDesc)

        let vertices: [TestVertex] = [
            TestVertex(pos: [-1, -1, 0], normal: [1, 0, 0], uv: [0, 1], color: [1, 1, 1, 1]),
            TestVertex(pos: [ 1, -1, 0], normal: [1, 0, 0], uv: [1, 1], color: [1, 1, 1, 1]),
            TestVertex(pos: [ 1,  1, 0], normal: [1, 0, 0], uv: [1, 0], color: [1, 1, 1, 1]),
            TestVertex(pos: [-1, -1, 0], normal: [1, 0, 0], uv: [0, 1], color: [1, 1, 1, 1]),
            TestVertex(pos: [ 1,  1, 0], normal: [1, 0, 0], uv: [1, 0], color: [1, 1, 1, 1]),
            TestVertex(pos: [-1,  1, 0], normal: [1, 0, 0], uv: [0, 0], color: [1, 1, 1, 1]),
        ]
        let vBuf = try XCTUnwrap(device.makeBuffer(
            bytes: vertices, length: MemoryLayout<TestVertex>.stride * vertices.count, options: .storageModeShared))

        var uniforms = Uniforms()
        uniforms.modelMatrix = matrix_identity_float4x4
        uniforms.normalMatrix = matrix_identity_float4x4
        uniforms.viewMatrix = RenderTestSupport.makeLookAt(eye: [0, 0, 2], center: [0, 0, 0], up: [0, 1, 0])
        uniforms.projectionMatrix = RenderTestSupport.makePerspective(
            fovRadians: Float.pi / 2, aspect: 1.0, near: 0.1, far: 10.0)

        var material = MToonMaterialUniforms()
        material.parametricRimColorFactor = SIMD3<Float>(1.0, 0.0, 0.0)
        material.parametricRimFresnelPowerFactor = 1.0
        material.parametricRimLiftFactor = 0.0

        var hasMorphed: UInt32 = 0
        let dummyMorph = try XCTUnwrap(device.makeBuffer(length: 16, options: .storageModeShared))

        let size = 16
        let texDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: size, height: size, mipmapped: false)
        texDesc.usage = [.renderTarget, .shaderRead]
        let target = try XCTUnwrap(device.makeTexture(descriptor: texDesc))

        let rpDesc = MTLRenderPassDescriptor()
        rpDesc.colorAttachments[0].texture = target
        rpDesc.colorAttachments[0].loadAction = .clear
        rpDesc.colorAttachments[0].storeAction = .store
        rpDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        let queue = try XCTUnwrap(device.makeCommandQueue())
        let cmd = try XCTUnwrap(queue.makeCommandBuffer())
        let enc = try XCTUnwrap(cmd.makeRenderCommandEncoder(descriptor: rpDesc))
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBuffer(vBuf, offset: 0, index: 0)
        enc.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        enc.setVertexBytes(&material, length: MemoryLayout<MToonMaterialUniforms>.stride, index: 8)
        enc.setVertexBuffer(dummyMorph, offset: 0, index: 20)
        enc.setVertexBytes(&hasMorphed, length: MemoryLayout<UInt32>.stride, index: 22)
        enc.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        enc.setFragmentBytes(&material, length: MemoryLayout<MToonMaterialUniforms>.stride, index: 8)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()

        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        target.getBytes(&pixels, bytesPerRow: size * 4, from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
        let centerIdx = (size / 2 * size + size / 2) * 4
        XCTAssertGreaterThan(pixels[centerIdx], 200,
            "mtoon_debug_rim must output grazing rim (>200) for single-channel (1, 0, 0) rim factor, got \(pixels[centerIdx])")
    }

    // MARK: - Helpers

    private func renderMatCapFrame(translation: SIMD3<Float>) async throws -> [UInt8] {
        let model = try await SwatchScene.load(.rigid, device: device)
        let matcap = try makeDirectionalMatCapTexture(size: 64)
        model.textures.append(matcap)

        let sphere = model.materials[1]
        sphere.baseColorFactor = SIMD4<Float>(0, 0, 0, 1)
        sphere.mtoon?.shadeColorFactor = SIMD3<Float>(0, 0, 0)
        sphere.mtoon?.matcapTexture = matcap
        sphere.mtoon?.matcapFactor = SIMD3<Float>(1, 1, 1)
        sphere.mtoon?.outlineWidthMode = .none

        for node in model.nodes where node.parent == nil {
            node.translation += translation
            node.updateLocalMatrix()
            node.updateWorldTransform()
        }

        var setup = SwatchScene.Setup()
        setup.size = 256
        setup.eye = SIMD3<Float>(0, 0, 5) + translation
        setup.center = SIMD3<Float>(0, 0, 0) + translation
        setup.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        return try SwatchScene.render(model, device: device, setup: setup) { renderer in
            // Inject raw full inverse-transpose (non-zero 4th row) to exercise the shader's w=0 path.
            for node in model.nodes {
                let rawNormal: float4x4 = simd_transpose(simd_inverse(node.worldMatrix))
                node.normalMatrix = rawNormal
            }
            renderer.disableLight(0)
            renderer.setAmbientColor(SIMD3<Float>(0, 0, 0))
        }
    }

    private func renderScreenOutlineFrame(translation: SIMD3<Float>) async throws -> [UInt8] {
        let model = try await SwatchScene.load(.rigid, device: device)
        let sphere = model.materials[1]
        sphere.doubleSided = true // Routes through dedicated `mtoon_outline_vertex` pass
        sphere.baseColorFactor = SIMD4<Float>(0.2, 0.2, 0.2, 1)
        sphere.mtoon?.shadeColorFactor = SIMD3<Float>(0.2, 0.2, 0.2)
        sphere.mtoon?.outlineWidthMode = .screenCoordinates
        sphere.mtoon?.outlineWidthFactor = 0.03
        sphere.mtoon?.outlineColorFactor = SIMD3<Float>(1, 0, 0)
        sphere.mtoon?.outlineLightingMixFactor = 1.0

        for node in model.nodes where node.parent == nil {
            node.translation += translation
            node.updateLocalMatrix()
            node.updateWorldTransform()
        }

        var setup = SwatchScene.Setup()
        setup.size = 256
        setup.eye = SIMD3<Float>(0, 0, 5) + translation
        setup.center = SIMD3<Float>(0, 0, 0) + translation
        setup.clearColor = MTLClearColor(red: 1, green: 1, blue: 1, alpha: 1)

        return try SwatchScene.render(model, device: device, setup: setup) { _ in
            // Inject raw full inverse-transpose (non-zero 4th row) to exercise the shader's w=0 path.
            for node in model.nodes {
                let rawNormal: float4x4 = simd_transpose(simd_inverse(node.worldMatrix))
                node.normalMatrix = rawNormal
            }
        }
    }

    private func makeDirectionalMatCapTexture(size: Int) throws -> VRMTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: size, height: size, mipmapped: false)
        desc.usage = .shaderRead
        let texture = try XCTUnwrap(device.makeTexture(descriptor: desc))
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        for y in 0..<size {
            let v = Float(y) / Float(size - 1)
            for x in 0..<size {
                let u = Float(x) / Float(size - 1)
                let idx = (y * size + x) * 4
                pixels[idx] = UInt8(clamping: Int(u * 255))
                pixels[idx + 1] = UInt8(clamping: Int(v * 255))
                pixels[idx + 2] = UInt8(clamping: Int((1.0 - u) * 255))
                pixels[idx + 3] = 255
            }
        }
        texture.replace(region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0,
                        withBytes: &pixels, bytesPerRow: size * 4)
        return VRMTexture(name: "directional_matcap", mtlTexture: texture)
    }

    private func makeSolidTexture(r: UInt8, g: UInt8, b: UInt8, a: UInt8, name: String) throws -> VRMTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 2, height: 2, mipmapped: false)
        desc.usage = .shaderRead
        let texture = try XCTUnwrap(device.makeTexture(descriptor: desc))
        var pixels: [UInt8] = [r, g, b, a, r, g, b, a, r, g, b, a, r, g, b, a]
        texture.replace(region: MTLRegionMake2D(0, 0, 2, 2), mipmapLevel: 0,
                        withBytes: &pixels, bytesPerRow: 8)
        return VRMTexture(name: name, mtlTexture: texture)
    }
}
