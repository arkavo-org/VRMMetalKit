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

/// Coverage for the three `debugUVs` defects found in the #420 review:
///
/// 1. The A2C / alpha-mode guard in `specializedMToonPipelineIfAvailable` ran
///    before the debug branch, so MASK materials under MSAA + alpha-to-coverage
///    (and any material whose uniform alpha mode was remapped to 3) kept their
///    shaded PSO while the rest of the frame went debug-coloured.
/// 2. Modes 11 and 35 have no case in `mtoon_debug_visualize` and render the
///    terminal 'unknown mode' magenta. They visualize mid-shading state, so
///    they belong to the production fragment (``MToonDebugMode``).
/// 3. The merged outline hull kept being encoded in debug mode. The debug
///    fragment has no `instance_id == 1` outline branch, so the hull came back
///    as an opaque debug-coloured shell over the avatar.
@MainActor
final class DebugVisualizationRegressionTests: XCTestCase {

    private var device: MTLDevice!

    override func setUpWithError() throws {
        guard let dev = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available on this host")
        }
        device = dev
    }

    // MARK: - Routing policy

    func testDebugFragmentRoutingExcludesProductionFragmentModes() {
        XCTAssertFalse(MToonDebugMode.usesDebugFragment(0), "0 is 'no debug visualization'.")
        XCTAssertTrue(MToonDebugMode.usesDebugFragment(1))
        XCTAssertTrue(MToonDebugMode.usesDebugFragment(35 - 1))
        XCTAssertFalse(MToonDebugMode.usesDebugFragment(11),
            "Mode 11 visualizes the flipped normal, which only exists inside mtoon_fragment_v2.")
        XCTAssertFalse(MToonDebugMode.usesDebugFragment(35),
            "Mode 35 visualizes accumulated litColor, which only exists inside mtoon_fragment_v2.")
        XCTAssertEqual(MToonDebugMode.inlineProductionModes, [11, 35])
    }

    func testMergedHullIsSkippedOnlyForDebugFragmentModes() {
        XCTAssertTrue(MToonOutlineDraw.shouldEncodeMergedHull(merged: true, debugMode: 0))
        XCTAssertFalse(MToonOutlineDraw.shouldEncodeMergedHull(merged: true, debugMode: 1),
            "The debug fragment has no outline branch — the hull would be an opaque debug shell.")
        XCTAssertTrue(MToonOutlineDraw.shouldEncodeMergedHull(merged: true, debugMode: 11),
            "Production-fragment debug modes still shade instance_id == 1 as the outline.")
        XCTAssertFalse(MToonOutlineDraw.shouldEncodeMergedHull(merged: false, debugMode: 0),
            "Non-merged primitives never grow a hull draw.")
    }

    // MARK: - Regression 1: debug must win over the A2C / alpha-mode guard

    private func maskA2CRenderer(debugMode: Int32) -> VRMRenderer {
        var config = RendererConfig()
        config.sampleCount = 4
        config.alphaToCoverageForMASK = true
        let renderer = VRMRenderer(device: device, config: config)
        renderer.debugUVs = debugMode
        return renderer
    }

    /// A MASK material routed to the alpha-to-coverage pipeline must still get
    /// the debug fragment, and it must be the *same* PSO the debug feature key
    /// resolves to — not the shaded A2C pipeline.
    func testMaskAlphaToCoverageMaterialStillGetsDebugPipeline() throws {
        var mtoon = MToonMaterialUniforms()
        mtoon.alphaMode = 1

        let control = maskA2CRenderer(debugMode: 0)
        XCTAssertNil(
            control.specializedMToonPipelineIfAvailable(
                isSkinned: false, materialAlphaMode: "mask", mtoonUniforms: mtoon),
            "Control: without debug, A2C MASK keeps the fallback A2C PSO.")

        let renderer = maskA2CRenderer(debugMode: 1)
        guard let resolved = renderer.specializedMToonPipelineIfAvailable(
            isSkinned: false, materialAlphaMode: "mask", mtoonUniforms: mtoon
        ) else {
            return XCTFail(
                "debugUVs must apply to MASK + MSAA + alphaToCoverage materials; " +
                "returning nil leaves them shaded in a debug frame.")
        }

        var expectedFeatures = MToonFunctionConstantKey(material: mtoon)
        expectedFeatures.lightCount = MToonLightSpecialization.count(
            keyIntensity: renderer.uniforms.lightColor_packed.w,
            fillIntensity: renderer.uniforms.light1Color_packed.w,
            rimIntensity: renderer.uniforms.light2Color_packed.w
        )
        expectedFeatures.debugVisualization = true
        let expected = renderer.specializedMToonPipelineState(
            isSkinned: false, features: expectedFeatures)
        XCTAssertTrue(resolved === expected,
            "The A2C MASK draw must bind the debug-fragment PSO for its feature key.")
    }

    /// Uniform alpha mode 3 (MASK_A2C) was also excluded by the guard.
    func testAlphaModeThreeMaterialStillGetsDebugPipeline() throws {
        var mtoon = MToonMaterialUniforms()
        mtoon.alphaMode = 3

        let control = maskA2CRenderer(debugMode: 0)
        XCTAssertNil(
            control.specializedMToonPipelineIfAvailable(
                isSkinned: false, materialAlphaMode: "opaque", mtoonUniforms: mtoon),
            "Control: alpha mode 3 has no specialized production PSO.")

        let renderer = maskA2CRenderer(debugMode: 1)
        XCTAssertNotNil(
            renderer.specializedMToonPipelineIfAvailable(
                isSkinned: false, materialAlphaMode: "opaque", mtoonUniforms: mtoon),
            "Alpha mode 3 must not silently opt out of debug visualization.")
    }

    /// Modes served by the production fragment must keep the material's own
    /// PSO — binding the debug fragment for them is what produced magenta.
    func testProductionFragmentModeKeepsTheShadedPipeline() throws {
        let mtoon = MToonMaterialUniforms()

        var config = RendererConfig()
        let shaded = VRMRenderer(device: device, config: config)
        shaded.debugUVs = 0
        guard let production = shaded.specializedMToonPipelineIfAvailable(
            isSkinned: false, materialAlphaMode: "opaque", mtoonUniforms: mtoon
        ) else {
            throw XCTSkip("MToon specialization unavailable on this device")
        }

        config = RendererConfig()
        let debug11 = VRMRenderer(device: device, config: config)
        debug11.debugUVs = 11
        let resolved = debug11.specializedMToonPipelineIfAvailable(
            isSkinned: false, materialAlphaMode: "opaque", mtoonUniforms: mtoon)
        XCTAssertNotNil(resolved)
        XCTAssertEqual(resolved?.label, production.label,
            "Mode 11 must stay on the production fragment; the debug fragment has no case for it.")
    }

    // MARK: - Regression 3: no debug-coloured outline shell

    /// The merged hull is a second `drawIndexed` counted by the performance
    /// tracker. A debug frame must not encode it.
    func testMergedHullIsNotEncodedInDebugMode() throws {
        let shadedDraws = try renderOutlinedTriangle(debugMode: 0)
        XCTAssertEqual(shadedDraws, 2,
            "Baseline: colour draw + merged hull. Without this the debug comparison is meaningless.")

        let debugDraws = try renderOutlinedTriangle(debugMode: 1)
        XCTAssertEqual(debugDraws, 1,
            "The merged hull must be skipped while the debug fragment is bound — it would " +
            "paint an opaque debug-coloured shell over the avatar.")

        let inlineDebugDraws = try renderOutlinedTriangle(debugMode: 11)
        XCTAssertEqual(inlineDebugDraws, 2,
            "Production-fragment debug modes keep their outline: that fragment shades the hull.")
    }

    /// Renders one offscreen frame of a single-triangle model whose material
    /// has MToon outlines enabled, and returns the recorded draw-call count.
    private func renderOutlinedTriangle(debugMode: Int32) throws -> Int {
        let model = try makeOutlinedTriangleModel()

        var config = RendererConfig()
        config.sampleCount = 1
        config.strict = .off
        let renderer = VRMRenderer(device: device, config: config)
        renderer.performanceTracker = PerformanceTracker()
        renderer.loadModel(model)
        renderer.viewMatrix = matrix_identity_float4x4
        renderer.projectionMatrix = matrix_identity_float4x4
        renderer.outlineWidth = 0.02
        renderer.debugUVs = debugMode

        let size = 32
        let colorDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: size, height: size, mipmapped: false)
        colorDesc.usage = [.renderTarget, .shaderRead]
        colorDesc.storageMode = .shared
        let depthDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float, width: size, height: size, mipmapped: false)
        depthDesc.usage = .renderTarget
        depthDesc.storageMode = .private

        guard let colorTex = device.makeTexture(descriptor: colorDesc),
              let depthTex = device.makeTexture(descriptor: depthDesc),
              let queue = device.makeCommandQueue(),
              let cb = queue.makeCommandBuffer() else {
            throw XCTSkip("Could not allocate Metal render targets")
        }

        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = colorTex
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        rpd.colorAttachments[0].storeAction = .store
        rpd.depthAttachment.texture = depthTex
        rpd.depthAttachment.loadAction = .clear
        rpd.depthAttachment.clearDepth = 1.0
        rpd.depthAttachment.storeAction = .dontCare

        renderer.drawOffscreenHeadless(
            to: colorTex, depth: depthTex, commandBuffer: cb, renderPassDescriptor: rpd)
        cb.commit()
        cb.waitUntilCompleted()

        let metrics = try XCTUnwrap(renderer.getPerformanceMetrics())
        return metrics.drawCalls
    }

    /// Single triangle, single-sided MToon material with a world-coordinate
    /// outline — the exact shape `MToonOutlineDraw.shouldMerge` accepts.
    private func makeOutlinedTriangleModel() throws -> VRMModel {
        let gltfJSON = """
        {"asset":{"version":"2.0"},"scene":0,"scenes":[{"nodes":[0]}],"nodes":[{"name":"tri"}]}
        """
        let gltf = try JSONDecoder().decode(GLTFDocument.self, from: gltfJSON.data(using: .utf8)!)
        let model = VRMModel(
            specVersion: .v1_0,
            meta: VRMMeta(licenseUrl: "https://vrm.dev/licenses/1.0/"),
            humanoid: nil,
            gltf: gltf
        )
        for (i, gltfNode) in (gltf.nodes ?? []).enumerated() {
            model.nodes.append(VRMNode(index: i, gltfNode: gltfNode))
        }
        model.nodes[0].mesh = 0
        model.nodes[0].updateLocalMatrix()
        model.nodes[0].updateWorldTransform()

        let materialJSON = #"{"name":"outlined","doubleSided":false}"#
        let gltfMaterial = try JSONDecoder().decode(
            GLTFMaterial.self, from: materialJSON.data(using: .utf8)!)
        let material = VRMMaterial(from: gltfMaterial, textures: [])
        var mtoon = VRMMToonMaterial()
        mtoon.outlineWidthMode = .worldCoordinates
        mtoon.outlineWidthFactor = 0.05
        material.mtoon = mtoon
        model.materials = [material]

        let mesh = VRMMesh(name: "tri")
        let primitive = VRMPrimitive()
        var verts = [VRMVertex(), VRMVertex(), VRMVertex()]
        verts[0].position = SIMD3<Float>(-0.5, -0.5, 0)
        verts[1].position = SIMD3<Float>( 0.5, -0.5, 0)
        verts[2].position = SIMD3<Float>( 0.0,  0.5, 0)
        for i in 0..<3 {
            verts[i].normal = SIMD3<Float>(0, 0, 1)
            verts[i].texCoord = SIMD2<Float>(0, 0)
            verts[i].color = SIMD4<Float>(1, 1, 1, 1)
        }
        primitive.uploadVertices(verts, device: device)
        primitive.localMin = SIMD3<Float>(-0.5, -0.5, 0)
        primitive.localMax = SIMD3<Float>( 0.5,  0.5, 0)
        let indices: [UInt16] = [0, 1, 2]
        primitive.indexBuffer = device.makeBuffer(
            bytes: indices, length: 3 * MemoryLayout<UInt16>.stride, options: .storageModeShared)
        primitive.indexCount = 3
        primitive.indexType = .uint16
        primitive.indexBufferOffset = 0
        primitive.primitiveType = .triangle
        primitive.hasNormals = true
        primitive.materialIndex = 0
        mesh.primitives = [primitive]
        model.meshes = [mesh]
        return model
    }
}

/// Regression 2: modes 11 and 35 must not fall through to the terminal
/// 'unknown mode' magenta. Rendered on the shared `LightingTestRenderer`
/// sphere, which routes debug modes through ``MToonDebugMode``.
final class DebugVisualizationShaderModeTests: XCTestCase {

    private var device: MTLDevice!
    private var renderer: LightingTestRenderer!
    private let size = 128

    override func setUpWithError() throws {
        guard let dev = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device not available")
        }
        device = dev
        renderer = try LightingTestRenderer(device: dev, width: size, height: size)
    }

    override func tearDownWithError() throws {
        renderer = nil
        device = nil
    }

    private func pixel(_ data: Data, x: Int, y: Int) -> (r: Float, g: Float, b: Float) {
        let offset = (y * size + x) * 4
        let bytes = [UInt8](data)
        guard offset + 3 < bytes.count else { return (0, 0, 0) }
        // bgra8Unorm
        return (Float(bytes[offset + 2]) / 255.0,
                Float(bytes[offset + 1]) / 255.0,
                Float(bytes[offset]) / 255.0)
    }

    private func isMagenta(_ p: (r: Float, g: Float, b: Float)) -> Bool {
        p.r > 0.9 && p.g < 0.1 && p.b > 0.9
    }

    /// Fully unlit material: shading shift pins the toon ramp to the shade
    /// side, shade colour is black, ambient is off. Production shading then
    /// returns the 8% minimum-light floor, while mode 35 — read before that
    /// floor — must return ~0.
    private func unlitMaterial() -> MToonMaterialUniforms {
        var material = MToonMaterialUniforms()
        material.baseColorFactor = SIMD4<Float>(1, 1, 1, 1)
        material.shadeColorFactor = SIMD3<Float>(0, 0, 0)
        material.shadingToonyFactor = 0
        material.shadingShiftFactor = -1
        material.giEqualizationFactor = 1
        return material
    }

    func testMode35ReturnsLitColorBeforeTheMinimumLightFloor() throws {
        let material = unlitMaterial()
        // Light from behind: the toon ramp lands fully on the (black) shade
        // side, so the accumulated litColor is zero.
        let lightDir = SIMD3<Float>(0, 0, -1)

        let shaded = try renderer.renderWithDebugMode(
            0, material: material, lightDir: lightDir, ambientColor: SIMD3<Float>(0, 0, 0))
        let debug35 = try renderer.renderWithDebugMode(
            35, material: material, lightDir: lightDir, ambientColor: SIMD3<Float>(0, 0, 0))

        let shadedCenter = pixel(shaded, x: size / 2, y: size / 2)
        let debugCenter = pixel(debug35, x: size / 2, y: size / 2)
        print("[mode35] shaded=\(shadedCenter) debug=\(debugCenter)")

        XCTAssertFalse(isMagenta(debugCenter),
            "Mode 35 fell through to the 'unknown debug mode' magenta: \(debugCenter)")
        XCTAssertGreaterThan(shadedCenter.r, 0.04,
            "Control: production shading applies the 8% minimum-light floor.")
        XCTAssertLessThan(debugCenter.r, shadedCenter.r - 0.02,
            "Mode 35 must show the accumulated litColor from *before* the minimum-light floor.")
    }

    /// Front faces are never flipped, so mode 11 falls through to normal
    /// shading — identical to a mode 0 render of the same scene.
    func testMode11LeavesUnflippedFragmentsShaded() throws {
        var material = MToonMaterialUniforms()
        material.baseColorFactor = SIMD4<Float>(1, 1, 1, 1)
        material.shadeColorFactor = SIMD3<Float>(0.2, 0.2, 0.2)
        let lightDir = SIMD3<Float>(0, 0, 1)

        let shaded = try renderer.renderWithDebugMode(0, material: material, lightDir: lightDir)
        let debug11 = try renderer.renderWithDebugMode(11, material: material, lightDir: lightDir)

        let shadedCenter = pixel(shaded, x: size / 2, y: size / 2)
        let debugCenter = pixel(debug11, x: size / 2, y: size / 2)
        print("[mode11 front] shaded=\(shadedCenter) debug=\(debugCenter)")

        XCTAssertFalse(isMagenta(debugCenter),
            "Mode 11 must not paint unflipped fragments magenta: \(debugCenter)")
        XCTAssertEqual(debugCenter.r, shadedCenter.r, accuracy: 0.01)
        XCTAssertEqual(debugCenter.g, shadedCenter.g, accuracy: 0.01)
        XCTAssertEqual(debugCenter.b, shadedCenter.b, accuracy: 0.01)
    }

    /// Back faces (rendered by culling the front) are the flipped-normal case
    /// mode 11 exists to expose: magenta there, shaded under mode 0.
    func testMode11MarksFlippedNormalsMagenta() throws {
        var material = MToonMaterialUniforms()
        material.baseColorFactor = SIMD4<Float>(1, 1, 1, 1)
        material.shadeColorFactor = SIMD3<Float>(0.2, 0.2, 0.2)
        let lightDir = SIMD3<Float>(0, 0, 1)

        let shaded = try renderer.renderWithDebugMode(
            0, material: material, lightDir: lightDir, cullMode: .front)
        let debug11 = try renderer.renderWithDebugMode(
            11, material: material, lightDir: lightDir, cullMode: .front)

        let shadedCenter = pixel(shaded, x: size / 2, y: size / 2)
        let debugCenter = pixel(debug11, x: size / 2, y: size / 2)
        print("[mode11 back] shaded=\(shadedCenter) debug=\(debugCenter)")

        XCTAssertFalse(isMagenta(shadedCenter),
            "Control: back faces shade normally without the debug mode.")
        XCTAssertTrue(isMagenta(debugCenter),
            "Mode 11 marks fragments whose normal was flipped for a back face: got \(debugCenter)")
    }
}
