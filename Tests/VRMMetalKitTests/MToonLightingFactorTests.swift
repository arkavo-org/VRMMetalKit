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

/// Tests for MToon lighting factor calculation.
/// Verifies that shade color only appears in shadow regions, not lit areas.
///
/// The "sunburn effect" bug occurs when shade color (pink) is applied to LIT areas
/// (forehead, cheeks, nose) when it should ONLY appear in SHADOW areas (under chin, creases).
///
/// These tests use debug mode 15 to visualize the lightingFactor directly:
/// - WHITE (1.0) = fully lit area, should show baseColor
/// - BLACK (0.0) = fully shadow area, should show shadeColor
/// - GRAY = transition zone
///
/// Related: GitHub Issues #104, #105 (MToon sunburn diagnosis)
@MainActor
final class MToonLightingFactorTests: XCTestCase {

    var device: MTLDevice!
    var renderer: LightingTestRenderer!

    override func setUp() async throws {
        device = MTLCreateSystemDefaultDevice()
        guard device != nil else {
            throw XCTSkip("Metal device not available")
        }
        renderer = try LightingTestRenderer(device: device, width: 128, height: 128)
    }

    override func tearDown() async throws {
        renderer = nil
        device = nil
    }

    // MARK: - Test 1: Front-Lit Face Should Be Mostly White

    /// When light faces the model directly, the front face should be lit (white).
    /// Tests center pixel which should have NdotL close to 1.0 for a front-lit sphere.
    func testFrontLitFaceMostlyWhite() async throws {
        // Setup: Front-facing light, typical skin material
        var material = MToonMaterialUniforms()
        material.baseColorFactor = SIMD4<Float>(1, 1, 1, 1)      // White base
        material.shadeColorFactor = SIMD3<Float>(0.93, 0.62, 0.71) // Pink shade (from VRM)
        material.shadingToonyFactor = 0.9
        material.shadingShiftFactor = -0.05  // Typical VRM value
        material.vrmVersion = 1

        // Render with debug mode 15 (lightingFactor visualization)
        let frameData = try renderer.renderWithDebugMode(
            15,
            material: material,
            lightDir: SIMD3<Float>(0, 0, 1)  // Light pointing at face
        )

        // Sample center of sphere (should be lit = white = 1.0)
        let center = sampleGrayscale(frameData, x: 64, y: 64, width: 128)

        XCTAssertGreaterThan(
            center, 0.8,
            "LIGHTING BUG: Center face lightingFactor=\(center), expected >0.8 (lit). Shade color is bleeding into lit areas!"
        )

        // Sample multiple points on the front-facing hemisphere
        // These should all be lit (lightingFactor > 0.7) for a front-lit sphere
        let frontFacePoints = [
            (x: 64, y: 64),   // center
            (x: 50, y: 64),   // left of center
            (x: 78, y: 64),   // right of center
            (x: 64, y: 50),   // above center
            (x: 64, y: 78),   // below center
        ]

        var litCount = 0
        for point in frontFacePoints {
            let value = sampleGrayscale(frameData, x: point.x, y: point.y, width: 128)
            if value > 0.7 {
                litCount += 1
            }
        }

        XCTAssertGreaterThanOrEqual(
            litCount, 4,
            "LIGHTING BUG: Only \(litCount)/5 front-facing points are lit. Expected at least 4."
        )

        print("=== Front-Lit Face Test ===")
        print("Center lightingFactor: \(center)")
        print("Front-face lit points: \(litCount)/5")
    }

    // MARK: - Test 2: shadingShift Affects Shadow Threshold

    /// VRM 1.0: shading = NdotL + shadingShift
    /// Positive shadingShift adds to NdotL, making shading higher → more lit
    /// Negative shadingShift subtracts from NdotL, making shading lower → more shadow
    ///
    /// Use side lighting so NdotL at center is ~0, making the shift effect clearly visible.
    func testShadingShiftAffectsThreshold() async throws {
        // Use side lighting so NdotL at center ≈ 0 (grazing angle)
        // This makes the shift effect clearly visible
        let sideLightDir = normalize(SIMD3<Float>(1, 0, 0))  // Light from right side

        // Test with positive shift (more lit) - should push the grazing angle into lit
        var materialPos = MToonMaterialUniforms()
        materialPos.shadingShiftFactor = +0.5
        materialPos.shadingToonyFactor = 0.9
        materialPos.vrmVersion = 1

        let framePos = try renderer.renderWithDebugMode(
            15,
            material: materialPos,
            lightDir: sideLightDir
        )
        let centerPos = sampleGrayscale(framePos, x: 64, y: 64, width: 128)

        // Test with negative shift (more shadow) - should push the grazing angle into shadow
        var materialNeg = MToonMaterialUniforms()
        materialNeg.shadingShiftFactor = -0.5
        materialNeg.shadingToonyFactor = 0.9
        materialNeg.vrmVersion = 1

        let frameNeg = try renderer.renderWithDebugMode(
            15,
            material: materialNeg,
            lightDir: sideLightDir
        )
        let centerNeg = sampleGrayscale(frameNeg, x: 64, y: 64, width: 128)

        print("=== Shading Shift Test (side lighting) ===")
        print("Positive shift (+0.5) center: \(centerPos)")
        print("Negative shift (-0.5) center: \(centerNeg)")

        XCTAssertGreaterThan(
            centerPos, centerNeg,
            "shadingShift not working: positive shift (\(centerPos)) should be brighter than negative shift (\(centerNeg))"
        )

        // With side lighting and positive shift, center should be mostly lit
        XCTAssertGreaterThan(
            centerPos, 0.5,
            "Positive shadingShift not pushing threshold: center=\(centerPos), expected >0.5 with side light"
        )

        // With side lighting and negative shift, center should be mostly shadow
        XCTAssertLessThan(
            centerNeg, 0.5,
            "Negative shadingShift not pushing threshold: center=\(centerNeg), expected <0.5 with side light"
        )
    }

    // MARK: - Test 3: mix() Direction Correct

    /// Verify mix(shadeColor, litColor, factor) - NOT reversed.
    /// When lightingFactor=1.0, output should equal baseColor.
    /// When lightingFactor=0.0, output should equal shadeColor.
    ///
    /// VRM 1.0: shading = NdotL + shadingShift
    /// - Positive shift adds to NdotL → more lit → lightingFactor → 1 → baseColor
    /// - Negative shift subtracts from NdotL → more shadow → lightingFactor → 0 → shadeColor
    func testMixDirectionCorrect() async throws {
        // Test at lightingFactor = 1.0 (fully lit)
        // Use extreme POSITIVE shift to force fully lit
        var materialLit = MToonMaterialUniforms()
        materialLit.baseColorFactor = SIMD4<Float>(0, 1, 0, 1)    // Green base
        materialLit.shadeColorFactor = SIMD3<Float>(1, 0, 0)       // Red shade
        materialLit.shadingShiftFactor = +2.0  // Force fully lit (extreme positive shift)
        materialLit.shadingToonyFactor = 0.99
        materialLit.vrmVersion = 1

        let frameLit = try renderer.render(material: materialLit, lightDir: SIMD3<Float>(0, 0, 1))
        let colorLit = samplePixelRGB(frameLit, x: 64, y: 64, width: 128)

        print("=== Mix Direction Test ===")
        print("Fully lit pixel (should be GREEN): R=\(colorLit.r), G=\(colorLit.g), B=\(colorLit.b)")

        // Should be GREEN (base), not RED (shade)
        XCTAssertGreaterThan(
            colorLit.g, colorLit.r,
            "MIX REVERSED: Fully lit area showing shade color (red=\(colorLit.r)) instead of base (green=\(colorLit.g))"
        )

        // Test at lightingFactor = 0.0 (fully shadow)
        // Use extreme NEGATIVE shift to force fully shadow
        var materialShade = MToonMaterialUniforms()
        materialShade.baseColorFactor = SIMD4<Float>(0, 1, 0, 1)   // Green base
        materialShade.shadeColorFactor = SIMD3<Float>(1, 0, 0)      // Red shade
        materialShade.shadingShiftFactor = -2.0  // Force fully shadow (extreme negative shift)
        materialShade.shadingToonyFactor = 0.99
        materialShade.vrmVersion = 1

        let frameShade = try renderer.render(material: materialShade, lightDir: SIMD3<Float>(0, 0, 1))
        let colorShade = samplePixelRGB(frameShade, x: 64, y: 64, width: 128)

        print("Fully shadow pixel (should be RED): R=\(colorShade.r), G=\(colorShade.g), B=\(colorShade.b)")

        // Should be RED (shade), not GREEN (base)
        XCTAssertGreaterThan(
            colorShade.r, colorShade.g,
            "MIX REVERSED: Fully shadow area showing base color (green=\(colorShade.g)) instead of shade (red=\(colorShade.r))"
        )
    }

    // MARK: - Test 4: Ambient Light Not Polluting Shade

    /// Ambient light should affect brightness, NOT add shade color globally.
    /// Use positive shadingShift to force fully lit area.
    func testAmbientNotPollutingShade() async throws {
        var material = MToonMaterialUniforms()
        material.baseColorFactor = SIMD4<Float>(1, 1, 1, 1)        // White
        material.shadeColorFactor = SIMD3<Float>(1, 0, 0)           // Red shade
        material.shadingShiftFactor = +2.0  // Force fully lit (no shadow) - positive shift adds to NdotL
        material.shadingToonyFactor = 0.9
        material.vrmVersion = 1

        // Render with ambient enabled
        let frameWithAmbient = try renderer.render(
            material: material,
            lightDir: SIMD3<Float>(0, 0, 1),
            ambientIntensity: 0.5
        )
        let colorWithAmbient = samplePixelRGB(frameWithAmbient, x: 64, y: 64, width: 128)

        // Should be WHITE-ish (possibly dimmed), NOT RED
        let warmth = colorWithAmbient.r - (colorWithAmbient.g + colorWithAmbient.b) / 2.0

        print("=== Ambient Pollution Test ===")
        print("Lit pixel with ambient: R=\(colorWithAmbient.r), G=\(colorWithAmbient.g), B=\(colorWithAmbient.b)")
        print("Warmth (red bias): \(warmth)")

        XCTAssertLessThan(
            warmth, 0.1,
            "AMBIENT POLLUTION: Lit area has warmth=\(warmth), shade color bleeding through ambient"
        )
    }

    // MARK: - Test 5: VRM 1.0 linearstep Range Correct

    /// VRM 1.0 uses linearstep(-1+toony, 1-toony, NdotL+shift).
    /// With toony=0.9: range is [-0.1, 0.1] - very narrow transition.
    /// Front face (NdotL approx 0.9) should be well above upper bound.
    func testVRM1LinearstepRange() async throws {
        var material = MToonMaterialUniforms()
        material.shadingToonyFactor = 0.9
        material.shadingShiftFactor = 0.0  // No shift
        material.vrmVersion = 1

        let frame = try renderer.renderWithDebugMode(
            15,
            material: material,
            lightDir: SIMD3<Float>(0, 0, 1)
        )

        // With toony=0.9, linearstep range is [-0.1, 0.1]
        // Front face NdotL is approximately 0.9, which is >> 0.1
        // So lightingFactor should be clamped to 1.0
        let center = sampleGrayscale(frame, x: 64, y: 64, width: 128)

        print("=== VRM 1.0 Linearstep Range Test ===")
        print("Center lightingFactor: \(center)")
        print("Expected: >0.95 (NdotL approx 0.9 >> upper bound 0.1)")

        XCTAssertGreaterThan(
            center, 0.95,
            "VRM1 linearstep wrong: center=\(center), NdotL approx 0.9 should give factor approx 1.0"
        )
    }

    // MARK: - Test: NdotL Sign Check (Debug Mode 16)

    /// Debug test to check if NdotL is positive (green) or negative (red).
    /// For front-lit geometry, NdotL should be POSITIVE (green).
    /// If it's RED, the light direction is inverted.
    func testNdotLSign() async throws {
        var material = MToonMaterialUniforms()
        material.vrmVersion = 1

        // Render with debug mode 16 (NdotL sign visualization)
        // GREEN = positive NdotL (correct), RED = negative NdotL (inverted)
        let frameData = try renderer.renderWithDebugMode(
            16,
            material: material,
            lightDir: SIMD3<Float>(0, 0, 1)  // Light FROM camera direction
        )

        // Sample center pixel
        let color = samplePixelRGB(frameData, x: 64, y: 64, width: 128)

        print("=== NdotL Sign Test ===")
        print("Center pixel: R=\(color.r), G=\(color.g), B=\(color.b)")
        print("GREEN means NdotL > 0 (correct for front-lit)")
        print("RED means NdotL < 0 (INVERTED - bug!)")

        // For front-lit face, should be GREEN (positive NdotL)
        XCTAssertGreaterThan(
            color.g, color.r,
            "NdotL IS INVERTED! Front-lit face shows negative NdotL. Light direction needs to be negated."
        )
    }

    // MARK: - Test 6: Real VRM Model Lighting Distribution

    /// Load actual VRM and verify face is mostly lit, not mostly shadow.
    /// This test is EXPECTED TO FAIL if the "sunburn" bug is present.
    func testRealVRMFaceMostlyLit() async throws {
        guard let vrmPath = ProcessInfo.processInfo.environment["VRM_TEST_VRM1_PATH"] else {
            throw XCTSkip("Set VRM_TEST_VRM1_PATH environment variable to test with real model")
        }

        print("=== Real VRM Face Lighting Test ===")
        print("Loading VRM from: \(vrmPath)")

        let vrmURL = URL(fileURLWithPath: vrmPath)
        guard FileManager.default.fileExists(atPath: vrmPath) else {
            throw XCTSkip("VRM file not found at path: \(vrmPath)")
        }

        let model = try await VRMModel.load(from: vrmURL, device: device)

        // Find skin material
        guard let skinMaterial = model.materials.first(where: {
            $0.name?.localizedCaseInsensitiveContains("SKIN") == true ||
            $0.name?.localizedCaseInsensitiveContains("Face") == true ||
            $0.name?.localizedCaseInsensitiveContains("Body") == true
        }) else {
            print("Available materials:")
            for mat in model.materials {
                print("  - \(mat.name ?? "unnamed")")
            }
            throw XCTSkip("No skin material found in VRM")
        }

        // Log the material properties
        print("Skin material: \(skinMaterial.name ?? "?")")
        if let mtoon = skinMaterial.mtoon {
            print("  shadingShift: \(mtoon.shadingShiftFactor)")
            print("  shadingToony: \(mtoon.shadingToonyFactor)")
            print("  shadeColor: \(mtoon.shadeColorFactor)")
        }

        // Create material uniforms from the VRM material
        var materialUniforms = MToonMaterialUniforms()
        if let mtoon = skinMaterial.mtoon {
            materialUniforms = MToonMaterialUniforms(from: mtoon)
        }
        materialUniforms.baseColorFactor = skinMaterial.baseColorFactor
        materialUniforms.vrmVersion = 1

        // Render with debug mode 15
        let frame = try renderer.renderWithDebugMode(
            15,
            material: materialUniforms,
            lightDir: SIMD3<Float>(0, 0, 1)
        )

        let histogram = analyzeGrayscaleHistogram(frame, width: 128, height: 128)

        print("Lighting distribution:")
        print("  Dark (shadow): \(histogram.darkRatio * 100)%")
        print("  Mid (transition): \(histogram.midRatio * 100)%")
        print("  Bright (lit): \(histogram.brightRatio * 100)%")

        // For front-lit face, expect the sphere area to be lit
        // The sphere covers ~25-30% of the 128x128 render area
        // Background (clear color 0.2) is counted as "dark"
        // So we expect ~25-30% bright (sphere) and ~70% dark (background)
        XCTAssertGreaterThan(
            histogram.brightRatio, 0.20,
            "Too much shadow: only \(histogram.brightRatio * 100)% lit (expected >20% for sphere coverage)"
        )
        XCTAssertLessThan(
            histogram.midRatio, 0.1,
            "Too much transition: \(histogram.midRatio * 100)% in mid-range (should be sharp toon shading)"
        )
    }

    // MARK: - Helper Functions

    /// Sample single pixel grayscale (for debug modes that output grayscale)
    func sampleGrayscale(_ data: Data, x: Int, y: Int, width: Int) -> Float {
        let bytesPerPixel = 4
        let offset = (y * width + x) * bytesPerPixel
        guard offset + 2 < data.count else { return 0 }

        let bytes = [UInt8](data)
        // BGRA format - convert to grayscale (for debug mode, R=G=B)
        let r = Float(bytes[offset + 2]) / 255.0
        return r
    }

    /// Sample RGB pixel
    func samplePixelRGB(_ data: Data, x: Int, y: Int, width: Int) -> (r: Float, g: Float, b: Float) {
        let bytesPerPixel = 4
        let offset = (y * width + x) * bytesPerPixel
        guard offset + 3 < data.count else { return (0, 0, 0) }

        let bytes = [UInt8](data)
        // BGRA format
        return (
            r: Float(bytes[offset + 2]) / 255.0,
            g: Float(bytes[offset + 1]) / 255.0,
            b: Float(bytes[offset]) / 255.0
        )
    }

    /// Analyze grayscale histogram
    func analyzeGrayscaleHistogram(_ data: Data, width: Int, height: Int)
        -> (darkRatio: Float, midRatio: Float, brightRatio: Float) {
        var dark = 0, mid = 0, bright = 0
        let total = width * height

        for y in 0..<height {
            for x in 0..<width {
                let value = sampleGrayscale(data, x: x, y: y, width: width)
                if value < 0.3 {
                    dark += 1
                } else if value < 0.7 {
                    mid += 1
                } else {
                    bright += 1
                }
            }
        }

        return (
            Float(dark) / Float(total),
            Float(mid) / Float(total),
            Float(bright) / Float(total)
        )
    }
}

// MARK: - LightingTestRenderer

/// Renderer for testing MToon lighting factor calculations
final class LightingTestRenderer {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let pipelineState: MTLRenderPipelineState
    let colorTexture: MTLTexture
    let depthTexture: MTLTexture
    let width: Int
    let height: Int

    // Sphere geometry
    let vertexBuffer: MTLBuffer
    let indexBuffer: MTLBuffer
    let indexCount: Int

    init(device: MTLDevice, width: Int, height: Int) throws {
        self.device = device
        self.width = width
        self.height = height

        guard let queue = device.makeCommandQueue() else {
            throw LightingTestError.commandQueueCreationFailed
        }
        self.commandQueue = queue

        // Create render target textures
        let colorDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        colorDesc.usage = [.renderTarget, .shaderRead]
        colorDesc.storageMode = .shared

        guard let colorTex = device.makeTexture(descriptor: colorDesc) else {
            throw LightingTestError.textureCreationFailed
        }
        self.colorTexture = colorTex

        let depthDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float,
            width: width,
            height: height,
            mipmapped: false
        )
        depthDesc.usage = [.renderTarget]
        depthDesc.storageMode = .private

        guard let depthTex = device.makeTexture(descriptor: depthDesc) else {
            throw LightingTestError.textureCreationFailed
        }
        self.depthTexture = depthTex

        // Create pipeline using VRMPipelineCache
        let library = try VRMPipelineCache.shared.getLibrary(device: device)

        guard let vertexFunc = library.makeFunction(name: "mtoon_vertex"),
              let fragmentFunc = library.makeFunction(name: "mtoon_fragment_v2") else {
            throw LightingTestError.shaderFunctionNotFound
        }

        let pipelineDesc = MTLRenderPipelineDescriptor()
        pipelineDesc.vertexFunction = vertexFunc
        pipelineDesc.fragmentFunction = fragmentFunc
        pipelineDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipelineDesc.depthAttachmentPixelFormat = .depth32Float

        // Vertex descriptor matching VRMVertex
        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .float3  // position
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = 0
        vertexDescriptor.attributes[1].format = .float3  // normal
        vertexDescriptor.attributes[1].offset = MemoryLayout<SIMD3<Float>>.stride
        vertexDescriptor.attributes[1].bufferIndex = 0
        vertexDescriptor.attributes[2].format = .float2  // texCoord
        vertexDescriptor.attributes[2].offset = MemoryLayout<SIMD3<Float>>.stride * 2
        vertexDescriptor.attributes[2].bufferIndex = 0
        vertexDescriptor.attributes[3].format = .float4  // color
        vertexDescriptor.attributes[3].offset = MemoryLayout<SIMD3<Float>>.stride * 2 + MemoryLayout<SIMD2<Float>>.stride
        vertexDescriptor.attributes[3].bufferIndex = 0
        vertexDescriptor.layouts[0].stride = MemoryLayout<VRMVertex>.stride

        pipelineDesc.vertexDescriptor = vertexDescriptor

        self.pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDesc)

        // Create sphere geometry
        let (vertices, indices) = Self.createSphere(radius: 0.5, segments: 32)

        guard let vbuf = device.makeBuffer(bytes: vertices, length: vertices.count * MemoryLayout<VRMVertex>.stride, options: .storageModeShared),
              let ibuf = device.makeBuffer(bytes: indices, length: indices.count * MemoryLayout<UInt32>.stride, options: .storageModeShared) else {
            throw LightingTestError.bufferCreationFailed
        }

        self.vertexBuffer = vbuf
        self.indexBuffer = ibuf
        self.indexCount = indices.count
    }

    /// Render with a specific debug mode (e.g., mode 15 for lightingFactor visualization)
    func renderWithDebugMode(
        _ debugMode: Int32,
        material: MToonMaterialUniforms,
        lightDir: SIMD3<Float>
    ) throws -> Data {
        var uniforms = createUniforms(lightDir: lightDir, debugMode: debugMode)
        var materialCopy = material

        return try renderInternal(uniforms: &uniforms, material: &materialCopy)
    }

    /// Render with normal lighting (no debug mode)
    func render(
        material: MToonMaterialUniforms,
        lightDir: SIMD3<Float>,
        ambientIntensity: Float = 0.1
    ) throws -> Data {
        var uniforms = createUniforms(lightDir: lightDir, debugMode: 0)
        uniforms.ambientColor = SIMD3<Float>(repeating: ambientIntensity)
        var materialCopy = material

        return try renderInternal(uniforms: &uniforms, material: &materialCopy)
    }

    private func createUniforms(lightDir: SIMD3<Float>, debugMode: Int32) -> Uniforms {
        var uniforms = Uniforms()
        uniforms.modelMatrix = matrix_identity_float4x4
        uniforms.viewMatrix = simd_float4x4(translation: SIMD3<Float>(0, 0, -2))
        uniforms.projectionMatrix = simd_float4x4(
            perspectiveWithAspect: Float(width) / Float(height),
            fovy: Float.pi / 4,
            near: 0.1,
            far: 100
        )
        uniforms.normalMatrix = matrix_identity_float4x4
        uniforms.lightDirection = normalize(lightDir)
        uniforms.lightColor = SIMD3<Float>(1, 1, 1)
        uniforms.ambientColor = SIMD3<Float>(0.1, 0.1, 0.1)
        uniforms.light1Color = SIMD3<Float>(0, 0, 0)
        uniforms.light2Color = SIMD3<Float>(0, 0, 0)
        uniforms.lightNormalizationFactor = 1.0
        uniforms.debugUVs = debugMode
        return uniforms
    }

    private func renderInternal(uniforms: inout Uniforms, material: inout MToonMaterialUniforms) throws -> Data {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw LightingTestError.commandBufferCreationFailed
        }

        let renderPassDesc = MTLRenderPassDescriptor()
        renderPassDesc.colorAttachments[0].texture = colorTexture
        renderPassDesc.colorAttachments[0].loadAction = .clear
        renderPassDesc.colorAttachments[0].storeAction = .store
        renderPassDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0.2, green: 0.2, blue: 0.2, alpha: 1.0)
        renderPassDesc.depthAttachment.texture = depthTexture
        renderPassDesc.depthAttachment.loadAction = .clear
        renderPassDesc.depthAttachment.storeAction = .dontCare
        renderPassDesc.depthAttachment.clearDepth = 1.0

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDesc) else {
            throw LightingTestError.encoderCreationFailed
        }

        encoder.setRenderPipelineState(pipelineState)
        encoder.setCullMode(.back)
        encoder.setFrontFacing(.counterClockwise)

        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        encoder.setVertexBytes(&material, length: MemoryLayout<MToonMaterialUniforms>.stride, index: 8)

        // Set hasMorphed flag to 0 (no morphs)
        var hasMorphed: UInt32 = 0
        encoder.setVertexBytes(&hasMorphed, length: MemoryLayout<UInt32>.stride, index: 22)

        // Create dummy morph buffer (required by shader)
        var dummyMorph = SIMD3<Float>(0, 0, 0)
        encoder.setVertexBytes(&dummyMorph, length: MemoryLayout<SIMD3<Float>>.stride, index: 20)

        encoder.setFragmentBytes(&material, length: MemoryLayout<MToonMaterialUniforms>.stride, index: 8)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)

        // Create 1x1 white texture for all texture slots
        let texDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: 1,
            height: 1,
            mipmapped: false
        )
        texDesc.usage = .shaderRead
        guard let whiteTex = device.makeTexture(descriptor: texDesc) else {
            throw LightingTestError.textureCreationFailed
        }
        var whitePixel: [UInt8] = [255, 255, 255, 255]
        whiteTex.replace(
            region: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0), size: MTLSize(width: 1, height: 1, depth: 1)),
            mipmapLevel: 0,
            withBytes: &whitePixel,
            bytesPerRow: 4
        )

        // Bind textures (all slots need something)
        for i in 0..<8 {
            encoder.setFragmentTexture(whiteTex, index: i)
        }

        // Create sampler
        let samplerDesc = MTLSamplerDescriptor()
        samplerDesc.minFilter = .linear
        samplerDesc.magFilter = .linear
        guard let sampler = device.makeSamplerState(descriptor: samplerDesc) else {
            throw LightingTestError.samplerCreationFailed
        }
        encoder.setFragmentSamplerState(sampler, index: 0)

        encoder.drawIndexedPrimitives(
            type: .triangle,
            indexCount: indexCount,
            indexType: .uint32,
            indexBuffer: indexBuffer,
            indexBufferOffset: 0
        )

        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        // Read back pixels
        let bytesPerRow = width * 4
        let dataSize = bytesPerRow * height
        var pixelData = Data(count: dataSize)

        pixelData.withUnsafeMutableBytes { ptr in
            colorTexture.getBytes(
                ptr.baseAddress!,
                bytesPerRow: bytesPerRow,
                from: MTLRegion(
                    origin: MTLOrigin(x: 0, y: 0, z: 0),
                    size: MTLSize(width: width, height: height, depth: 1)
                ),
                mipmapLevel: 0
            )
        }

        return pixelData
    }

    private static func createSphere(radius: Float, segments: Int) -> ([VRMVertex], [UInt32]) {
        var vertices: [VRMVertex] = []
        var indices: [UInt32] = []

        for lat in 0...segments {
            let theta = Float(lat) * Float.pi / Float(segments)
            let sinTheta = sin(theta)
            let cosTheta = cos(theta)

            for lon in 0...segments {
                let phi = Float(lon) * 2 * Float.pi / Float(segments)
                let sinPhi = sin(phi)
                let cosPhi = cos(phi)

                let x = cosPhi * sinTheta
                let y = cosTheta
                let z = sinPhi * sinTheta

                let position = SIMD3<Float>(x * radius, y * radius, z * radius)
                let normal = SIMD3<Float>(x, y, z)
                let texCoord = SIMD2<Float>(Float(lon) / Float(segments), Float(lat) / Float(segments))

                vertices.append(VRMVertex(
                    position: position,
                    normal: normal,
                    texCoord: texCoord,
                    color: SIMD4<Float>(1, 1, 1, 1)
                ))
            }
        }

        for lat in 0..<segments {
            for lon in 0..<segments {
                let first = UInt32(lat * (segments + 1) + lon)
                let second = first + UInt32(segments + 1)

                indices.append(first)
                indices.append(second)
                indices.append(first + 1)

                indices.append(second)
                indices.append(second + 1)
                indices.append(first + 1)
            }
        }

        return (vertices, indices)
    }

    enum LightingTestError: Error {
        case commandQueueCreationFailed
        case textureCreationFailed
        case shaderFunctionNotFound
        case bufferCreationFailed
        case commandBufferCreationFailed
        case encoderCreationFailed
        case samplerCreationFailed
    }
}

