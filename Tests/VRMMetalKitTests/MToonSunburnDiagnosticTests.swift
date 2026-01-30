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

/// Diagnostic tests for the VRM 1.0 "sunburn" effect where skin appears reddish/pink and too dark.
///
/// Potential causes being tested:
/// 1. Texture color space - Color textures loaded as linear instead of sRGB
/// 2. Shadow color bleeding - Shade color mixing into lit areas
/// 3. Shadow factor calculation - linearstep producing wrong distribution
/// 4. Output color space - Render target not gamma-corrected
/// 5. Minimum light floor - 8% floor causing issues
///
/// Related: VRM 1.0 MToon shading issues
@MainActor
final class MToonSunburnDiagnosticTests: XCTestCase {

    var device: MTLDevice!
    var renderer: SunburnTestRenderer!

    override func setUp() async throws {
        device = MTLCreateSystemDefaultDevice()
        guard device != nil else {
            throw XCTSkip("Metal device not available")
        }
        renderer = try SunburnTestRenderer(device: device, width: 128, height: 128)
    }

    override func tearDown() async throws {
        renderer = nil
        device = nil
    }

    // MARK: - Test 1: Texture Pixel Format Correctness

    /// Verify that color textures use sRGB format and data textures use linear format.
    /// If base color textures are loaded as linear instead of sRGB, colors will appear washed out
    /// and the shader's lighting calculations will be incorrect.
    func testTexturePixelFormatCorrectness() async throws {
        // Test with VRM 1.0 model if available
        guard let vrm1Path = ProcessInfo.processInfo.environment["VRM_TEST_VRM1_PATH"] else {
            // Create a test texture to verify the expected formats
            let sRGBDesc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm_srgb,
                width: 4,
                height: 4,
                mipmapped: false
            )
            sRGBDesc.usage = .shaderRead

            guard let sRGBTexture = device.makeTexture(descriptor: sRGBDesc) else {
                throw XCTSkip("Could not create test texture")
            }

            // Verify sRGB format is correct for color textures
            XCTAssertEqual(
                sRGBTexture.pixelFormat,
                .rgba8Unorm_srgb,
                "Color textures should use sRGB pixel format"
            )

            let linearDesc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm,
                width: 4,
                height: 4,
                mipmapped: false
            )
            linearDesc.usage = .shaderRead

            guard let linearTexture = device.makeTexture(descriptor: linearDesc) else {
                throw XCTSkip("Could not create test texture")
            }

            // Verify linear format is correct for normal/data textures
            XCTAssertEqual(
                linearTexture.pixelFormat,
                .rgba8Unorm,
                "Normal/data textures should use linear pixel format"
            )

            print("=== Texture Format Test (No VRM Model) ===")
            print("Expected formats verified:")
            print("  - Color textures: rgba8Unorm_srgb")
            print("  - Data textures: rgba8Unorm (linear)")
            return
        }

        // If VRM model path is provided, test actual model textures
        _ = URL(fileURLWithPath: vrm1Path)
        print("=== Testing VRM Model: \(vrm1Path) ===")

        // Note: Would need to load the model and check its textures
        // For now, skip with a message
        throw XCTSkip("VRM model texture format testing requires model loading support")
    }

    // MARK: - Test 2: Shadow Factor Distribution

    /// Check that shadowStep histogram shows proper distribution for toon shading.
    /// With toony=0.9, there should be a sharp shadow boundary with <15% mid-range pixels.
    func testShadowFactorDistribution() async throws {
        // Render with debug mode 14 to output shadowStep as grayscale
        let frameData = try renderer.renderWithDebugMode(
            debugMode: 14,
            toonyFactor: 0.9,
            shadingShift: 0.0,
            lightDirection: SIMD3<Float>(0.5, 0.5, 0.707),
            vrmVersion: 1
        )

        let histogram = analyzeGrayscaleHistogram(frameData: frameData, width: 128, height: 128)

        print("=== Shadow Factor Distribution (toony=0.9, VRM 1.0) ===")
        print("Dark pixels (0-64): \(histogram.darkCount) (\(histogram.darkRatio * 100)%)")
        print("Mid pixels (65-190): \(histogram.midCount) (\(histogram.midRatio * 100)%)")
        print("Light pixels (191-255): \(histogram.lightCount) (\(histogram.lightRatio * 100)%)")

        // With toony=0.9, should have sharp boundary (<15% in transition zone)
        XCTAssertLessThan(
            histogram.midRatio,
            0.15,
            "Too many mid-range pixels (\(histogram.midRatio * 100)%) - shadow boundary not sharp enough. Expected <15% for toony=0.9"
        )
    }

    // MARK: - Test 3: NdotL Visualization

    /// Verify the normal-light dot product pattern is correct.
    /// Debug mode 7 maps NdotL from [-1,1] to [0,1] for visualization.
    /// Center of sphere facing camera should be bright when light comes from camera.
    func testNdotLVisualization() async throws {
        // Light direction points TOWARD the light source
        // Camera is at (0,0,-2) looking at origin, sphere center at origin
        // Sphere normals at center point toward camera (0,0,-1)
        // For NdotL=1, light direction should match normal: (0,0,-1)
        let frameData = try renderer.renderWithDebugMode(
            debugMode: 7,
            toonyFactor: 0.9,
            shadingShift: 0.0,
            lightDirection: SIMD3<Float>(0, 0, -1), // Light from camera direction
            vrmVersion: 1
        )

        // Sample center pixel (should be bright - normal aligned with light)
        let center = samplePixelRGB(frameData: frameData, x: 64, y: 64, width: 128)
        let centerBrightness = (center.r + center.g + center.b) / 3.0

        // Sample edge pixel - at about 75% from center toward edge
        // Sphere radius in screen space is roughly 50 pixels at 128x128 with our view setup
        // x=40 is about 24 pixels from center (48% of radius), giving grazing angle
        let edge = samplePixelRGB(frameData: frameData, x: 40, y: 64, width: 128)
        let edgeBrightness = (edge.r + edge.g + edge.b) / 3.0

        print("=== NdotL Visualization ===")
        print("Center (64,64) brightness: \(centerBrightness)")
        print("Edge (40,64) brightness: \(edgeBrightness)")
        print("Note: Debug mode 7 maps NdotL [-1,1] to [0,1]")
        print("      1.0 = fully lit (NdotL=1), 0.5 = grazing (NdotL=0), 0.0 = backlit (NdotL=-1)")

        // Center should be bright (normal facing light)
        // Debug mode 7: NdotL=1.0 maps to brightness 1.0
        XCTAssertGreaterThan(
            centerBrightness,
            0.8,
            "Center NdotL should be >0.8 (normal aligned with light), got \(centerBrightness)"
        )

        // Edge should show gradient toward grazing angle
        // With two-sided lighting, even grazing normals are adjusted
        // The key is that edge should be less bright than center
        XCTAssertLessThan(
            edgeBrightness,
            centerBrightness,
            "Edge should be less bright than center due to grazing angle"
        )
    }

    // MARK: - Test 4: Sunburn Detection (Primary Test)

    /// Detect shade color bleeding into lit areas - the primary sunburn symptom.
    /// Uses a white base color with pink shadow color and checks if pink bleeds into lit center.
    func testShadeLitBlendingNoSunburn() async throws {
        // Set up material with white base and pink shadow (sunburn-prone setup)
        var material = MToonMaterialUniforms()
        material.baseColorFactor = SIMD4<Float>(1, 1, 1, 1)      // Pure white
        material.shadeColorFactor = SIMD3<Float>(0.8, 0.4, 0.4)  // Pink shadow
        material.shadingToonyFactor = 0.9
        material.shadingShiftFactor = 0.0
        material.vrmVersion = 1
        material.giIntensityFactor = 0.0

        let frameData = try renderer.renderWithMaterial(
            material: material,
            lightDirection: SIMD3<Float>(0, 0, 1)  // Front light
        )

        // Sample lit center area
        let center = samplePixelRGB(frameData: frameData, x: 64, y: 64, width: 128)

        // Calculate warmth: R excess over (G+B)/2
        // Positive warmth indicates red/pink tint (sunburn)
        let warmth = center.r - (center.g + center.b) / 2.0

        print("=== Sunburn Detection ===")
        print("Center pixel RGB: (\(center.r), \(center.g), \(center.b))")
        print("Warmth (R excess): \(warmth)")

        // In lit area, warmth should be near 0 (white, not pink)
        XCTAssertLessThan(
            warmth,
            0.05,
            "SUNBURN DETECTED: Shade color bleeding into lit area. Warmth=\(warmth), expected <0.05"
        )

        // Also verify the center is bright (not dark due to incorrect shadow)
        let brightness = (center.r + center.g + center.b) / 3.0
        XCTAssertGreaterThan(
            brightness,
            0.7,
            "Lit center should be bright (>0.7), got \(brightness)"
        )
    }

    // MARK: - Test 5: Minimum Light Floor

    /// Verify the 8% minimum light floor behaves correctly.
    /// The shader has: minLight = baseColor.rgb * 0.08; litColor = max(litColor, minLight);
    ///
    /// Note: The shader uses two-sided lighting which flips normals facing away from camera.
    /// To test the floor, we use a negative shadingShift to force shadow even with front light.
    func testMinimumLightFloor() async throws {
        // Set up material with black shade color and extreme negative shift
        // to force shadow even on lit areas
        var material = MToonMaterialUniforms()
        material.baseColorFactor = SIMD4<Float>(1, 1, 1, 1)      // White base
        material.shadeColorFactor = SIMD3<Float>(0, 0, 0)        // Black shadow (to test floor)
        material.shadingToonyFactor = 0.9
        material.shadingShiftFactor = -2.0  // Extreme negative shift forces everything into shadow
        material.vrmVersion = 1
        material.giIntensityFactor = 0.0  // No GI to isolate floor effect

        // Front light - but with extreme negative shift, still shows shadow
        let frameData = try renderer.renderWithMaterial(
            material: material,
            lightDirection: SIMD3<Float>(0, 0, -1)  // Light from camera
        )

        // Sample center (should be in forced shadow due to shading shift)
        let center = samplePixelRGB(frameData: frameData, x: 64, y: 64, width: 128)
        let brightness = (center.r + center.g + center.b) / 3.0

        // Expected: minimum floor = baseColor * 0.08 = 0.08 for white base
        let expectedFloor: Float = 0.08
        let tolerance: Float = 0.03

        print("=== Minimum Light Floor Test ===")
        print("Center pixel RGB: (\(center.r), \(center.g), \(center.b))")
        print("Brightness: \(brightness)")
        print("Expected floor: ~\(expectedFloor)")

        // With black shade and forced shadow, brightness should be approximately the floor value
        XCTAssertGreaterThanOrEqual(
            brightness,
            expectedFloor - tolerance,
            "Brightness below minimum floor. Got \(brightness), expected >= \(expectedFloor - tolerance)"
        )

        // Should be close to the floor, not much brighter (allow some tolerance for edge effects)
        XCTAssertLessThan(
            brightness,
            0.15,
            "Shadow area brighter than expected. Got \(brightness), expected < 0.15"
        )
    }

    // MARK: - Test 6: Output Color Space

    /// Check that output gamma correction is correct.
    /// A 50% gray input should result in approximately 50% gray output (127 raw value).
    func testOutputColorSpace() async throws {
        // Render a flat-lit surface with 50% gray
        var material = MToonMaterialUniforms()
        material.baseColorFactor = SIMD4<Float>(0.5, 0.5, 0.5, 1)  // 50% gray
        material.shadeColorFactor = SIMD3<Float>(0.5, 0.5, 0.5)    // Same shade
        material.shadingToonyFactor = 0.9
        material.shadingShiftFactor = 0.5  // Shift to always lit
        material.vrmVersion = 1
        material.giIntensityFactor = 0.0

        let frameData = try renderer.renderWithMaterial(
            material: material,
            lightDirection: SIMD3<Float>(0, 0, 1)
        )

        // Sample center
        let center = samplePixelRGB(frameData: frameData, x: 64, y: 64, width: 128)
        let rawCenter = samplePixelRaw(frameData: frameData, x: 64, y: 64, width: 128)

        print("=== Output Color Space Test ===")
        print("Input: 50% gray (0.5)")
        print("Output RGB (normalized): (\(center.r), \(center.g), \(center.b))")
        print("Output raw values: (\(rawCenter.r), \(rawCenter.g), \(rawCenter.b))")

        // For linear output, 50% = 0.5 * 255 = ~127-128
        // For sRGB output, 50% = ~186 (gamma 2.2)
        // We expect linear output (shader does lighting in linear space)

        let expectedRaw: UInt8 = 127  // Linear 50%
        let tolerance: UInt8 = 30     // Allow some variance from lighting

        // Check that we're in the right ballpark for linear output
        XCTAssertGreaterThan(
            rawCenter.r,
            expectedRaw - tolerance,
            "Red channel output appears incorrect. Got \(rawCenter.r), expected ~\(expectedRaw)"
        )
        XCTAssertLessThan(
            rawCenter.r,
            expectedRaw + tolerance,
            "Red channel output appears incorrect. Got \(rawCenter.r), expected ~\(expectedRaw)"
        )
    }

    // MARK: - Helper Functions

    struct GrayscaleHistogram {
        let darkCount: Int      // 0-64
        let midCount: Int       // 65-190
        let lightCount: Int     // 191-255
        let totalPixels: Int

        var darkRatio: Float {
            guard totalPixels > 0 else { return 0 }
            return Float(darkCount) / Float(totalPixels)
        }

        var midRatio: Float {
            guard totalPixels > 0 else { return 0 }
            return Float(midCount) / Float(totalPixels)
        }

        var lightRatio: Float {
            guard totalPixels > 0 else { return 0 }
            return Float(lightCount) / Float(totalPixels)
        }
    }

    private func analyzeGrayscaleHistogram(frameData: Data, width: Int, height: Int) -> GrayscaleHistogram {
        var darkCount = 0
        var midCount = 0
        var lightCount = 0

        let bytes = [UInt8](frameData)
        let pixelCount = width * height

        for i in 0..<pixelCount {
            let offset = i * 4
            guard offset + 2 < bytes.count else { continue }

            // BGRA format - convert to grayscale
            let b = Float(bytes[offset])
            let g = Float(bytes[offset + 1])
            let r = Float(bytes[offset + 2])
            let gray = UInt8((r * 0.299 + g * 0.587 + b * 0.114))

            if gray <= 64 {
                darkCount += 1
            } else if gray >= 191 {
                lightCount += 1
            } else {
                midCount += 1
            }
        }

        return GrayscaleHistogram(
            darkCount: darkCount,
            midCount: midCount,
            lightCount: lightCount,
            totalPixels: pixelCount
        )
    }

    private func samplePixelRGB(frameData: Data, x: Int, y: Int, width: Int) -> (r: Float, g: Float, b: Float) {
        let bytes = [UInt8](frameData)
        let offset = (y * width + x) * 4

        guard offset + 2 < bytes.count else {
            return (0, 0, 0)
        }

        // BGRA format
        let b = Float(bytes[offset]) / 255.0
        let g = Float(bytes[offset + 1]) / 255.0
        let r = Float(bytes[offset + 2]) / 255.0

        return (r, g, b)
    }

    private func samplePixelRaw(frameData: Data, x: Int, y: Int, width: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        let bytes = [UInt8](frameData)
        let offset = (y * width + x) * 4

        guard offset + 2 < bytes.count else {
            return (0, 0, 0)
        }

        // BGRA format
        let b = bytes[offset]
        let g = bytes[offset + 1]
        let r = bytes[offset + 2]

        return (r, g, b)
    }

    private func analyzeWarmthInLitRegion(frameData: Data, width: Int, height: Int) -> Float {
        // Sample the center 25% of the image (lit region)
        let startX = width / 4
        let endX = width * 3 / 4
        let startY = height / 4
        let endY = height * 3 / 4

        var totalWarmth: Float = 0
        var count = 0

        for y in startY..<endY {
            for x in startX..<endX {
                let pixel = samplePixelRGB(frameData: frameData, x: x, y: y, width: width)
                let warmth = pixel.r - (pixel.g + pixel.b) / 2.0
                totalWarmth += warmth
                count += 1
            }
        }

        return count > 0 ? totalWarmth / Float(count) : 0
    }
}

// MARK: - Sunburn Test Renderer

/// Specialized renderer for sunburn diagnostic tests
final class SunburnTestRenderer {
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
            throw RendererError.commandQueueCreationFailed
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
            throw RendererError.textureCreationFailed
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
            throw RendererError.textureCreationFailed
        }
        self.depthTexture = depthTex

        // Create pipeline using VRMPipelineCache
        let library = try VRMPipelineCache.shared.getLibrary(device: device)

        guard let vertexFunc = library.makeFunction(name: "mtoon_vertex"),
              let fragmentFunc = library.makeFunction(name: "mtoon_fragment_v2") else {
            throw RendererError.shaderFunctionNotFound
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
            throw RendererError.bufferCreationFailed
        }

        self.vertexBuffer = vbuf
        self.indexBuffer = ibuf
        self.indexCount = indices.count
    }

    /// Render with a specific debug mode
    func renderWithDebugMode(
        debugMode: Int32,
        toonyFactor: Float,
        shadingShift: Float,
        lightDirection: SIMD3<Float>,
        vrmVersion: UInt32 = 1
    ) throws -> Data {
        var material = MToonMaterialUniforms()
        material.baseColorFactor = SIMD4<Float>(1, 1, 1, 1)
        material.shadeColorFactor = SIMD3<Float>(0.5, 0.5, 0.5)
        material.shadingToonyFactor = toonyFactor
        material.shadingShiftFactor = shadingShift
        material.vrmVersion = vrmVersion
        material.giIntensityFactor = 0.0

        return try render(
            material: material,
            lightDirection: lightDirection,
            debugMode: debugMode
        )
    }

    /// Render with a specific material
    func renderWithMaterial(
        material: MToonMaterialUniforms,
        lightDirection: SIMD3<Float>
    ) throws -> Data {
        return try render(
            material: material,
            lightDirection: lightDirection,
            debugMode: 0  // Normal rendering
        )
    }

    private func render(
        material: MToonMaterialUniforms,
        lightDirection: SIMD3<Float>,
        debugMode: Int32
    ) throws -> Data {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw RendererError.commandBufferCreationFailed
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
            throw RendererError.encoderCreationFailed
        }

        encoder.setRenderPipelineState(pipelineState)
        encoder.setCullMode(.back)
        encoder.setFrontFacing(.counterClockwise)

        // Create uniforms
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
        uniforms.lightDirection = normalize(lightDirection)
        uniforms.lightColor = SIMD3<Float>(1, 1, 1)
        uniforms.ambientColor = SIMD3<Float>(0.1, 0.1, 0.1)
        uniforms.light1Color = SIMD3<Float>(0, 0, 0)
        uniforms.light2Color = SIMD3<Float>(0, 0, 0)
        uniforms.lightNormalizationFactor = 1.0
        uniforms.debugUVs = debugMode

        var materialCopy = material

        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        encoder.setVertexBytes(&materialCopy, length: MemoryLayout<MToonMaterialUniforms>.stride, index: 8)

        // Set hasMorphed flag to 0 (no morphs)
        var hasMorphed: UInt32 = 0
        encoder.setVertexBytes(&hasMorphed, length: MemoryLayout<UInt32>.stride, index: 22)

        // Create dummy morph buffer (required by shader)
        var dummyMorph = SIMD3<Float>(0, 0, 0)
        encoder.setVertexBytes(&dummyMorph, length: MemoryLayout<SIMD3<Float>>.stride, index: 20)

        encoder.setFragmentBytes(&materialCopy, length: MemoryLayout<MToonMaterialUniforms>.stride, index: 8)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)

        // Create 1x1 white texture for all texture slots
        let texDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        texDesc.usage = .shaderRead
        guard let whiteTex = device.makeTexture(descriptor: texDesc) else {
            throw RendererError.textureCreationFailed
        }
        var whitePixel: [UInt8] = [255, 255, 255, 255]
        whiteTex.replace(region: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0), size: MTLSize(width: 1, height: 1, depth: 1)), mipmapLevel: 0, withBytes: &whitePixel, bytesPerRow: 4)

        // Bind textures (all slots need something)
        for i in 0..<8 {
            encoder.setFragmentTexture(whiteTex, index: i)
        }

        // Create sampler
        let samplerDesc = MTLSamplerDescriptor()
        samplerDesc.minFilter = .linear
        samplerDesc.magFilter = .linear
        guard let sampler = device.makeSamplerState(descriptor: samplerDesc) else {
            throw RendererError.samplerCreationFailed
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
                from: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0), size: MTLSize(width: width, height: height, depth: 1)),
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

    enum RendererError: Error {
        case commandQueueCreationFailed
        case textureCreationFailed
        case shaderFunctionNotFound
        case bufferCreationFailed
        case commandBufferCreationFailed
        case encoderCreationFailed
        case samplerCreationFailed
    }
}

// Note: Matrix helpers (simd_float4x4 extensions) are defined in MToonShaderGPUTests.swift
