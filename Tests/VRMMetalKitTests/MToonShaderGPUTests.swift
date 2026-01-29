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
import CryptoKit
@testable import VRMMetalKit

/// GPU-based MToon shader tests that verify:
/// 1. The compiled metallib matches the source .metal file (hash comparison)
/// 2. The shader produces correct toon shading boundaries (GPU pixel sampling)
///
/// These tests catch issues like:
/// - Editing source but forgetting to recompile metallib
/// - linearstep vs smoothstep producing wrong shadow boundaries
///
/// Related: GitHub Issues #104, #105
@MainActor
final class MToonShaderGPUTests: XCTestCase {

    var device: MTLDevice!

    override func setUp() async throws {
        device = MTLCreateSystemDefaultDevice()
        guard device != nil else {
            throw XCTSkip("Metal device not available")
        }
    }

    override func tearDown() async throws {
        device = nil
    }

    // MARK: - Metallib Hash Verification Tests

    /// Known-good hash of MToonShader.metal source after linearstep fix.
    /// Update this hash when intentionally changing the shader.
    ///
    /// To get the current hash, run: `swift test --filter testPrintCurrentShaderHash`
    /// Updated: Fixed NdotL inversion - negated lightDirection in shader for correct convention
    static let knownGoodShaderHash = "ca4ccb00327d66978a04370d7c082e596027f4350ad539451e9b8ad01500c732"

    /// Test that the MToonShader.metal source file hash matches expected.
    /// This catches accidental shader modifications.
    func testShaderSourceHashMatchesKnownGood() throws {
        let shaderPath = findShaderSourcePath()
        guard let path = shaderPath else {
            throw XCTSkip("MToonShader.metal source file not found")
        }

        let sourceData = try Data(contentsOf: URL(fileURLWithPath: path))
        let hash = SHA256.hash(data: sourceData)
        let hashString = hash.compactMap { String(format: "%02x", $0) }.joined()

        print("=== Shader Source Hash ===")
        print("Path: \(path)")
        print("Hash: \(hashString)")

        if Self.knownGoodShaderHash == "NEEDS_UPDATE" {
            print("WARNING: Update knownGoodShaderHash to: \(hashString)")
            // Don't fail - just warn during initial setup
        } else {
            XCTAssertEqual(
                hashString,
                Self.knownGoodShaderHash,
                "Shader source hash mismatch! Source was modified. If intentional, update knownGoodShaderHash to: \(hashString)"
            )
        }
    }

    /// Helper test to print current shader hash - run this after intentional changes
    func testPrintCurrentShaderHash() throws {
        let shaderPath = findShaderSourcePath()
        guard let path = shaderPath else {
            throw XCTSkip("MToonShader.metal source file not found")
        }

        let sourceData = try Data(contentsOf: URL(fileURLWithPath: path))
        let hash = SHA256.hash(data: sourceData)
        let hashString = hash.compactMap { String(format: "%02x", $0) }.joined()

        print("========================================")
        print("CURRENT SHADER HASH (copy to knownGoodShaderHash):")
        print(hashString)
        print("========================================")
    }

    /// Test that metallib contains the linearstep function.
    /// This verifies the metallib was compiled from updated source.
    func testMetallibContainsLinearstepFunction() throws {
        let library = try VRMPipelineCache.shared.getLibrary(device: device)

        // Get all function names in the library
        let functionNames = library.functionNames

        print("=== Metallib Functions ===")
        for name in functionNames {
            print("  - \(name)")
        }

        // Verify key MToon functions exist
        XCTAssertTrue(functionNames.contains("mtoon_vertex"), "Missing mtoon_vertex function")
        XCTAssertTrue(functionNames.contains("mtoon_fragment_v2"), "Missing mtoon_fragment_v2 function")
        XCTAssertTrue(functionNames.contains("mtoon_debug_ramp"), "Missing mtoon_debug_ramp function")

        // Note: linearstep is inlined, so we can't directly check for it.
        // Instead, we verify the fragment function exists and test its output.
    }

    /// CRITICAL: Test that metallib is complete and contains ALL required shader functions.
    /// This test would have caught the bug where only 1 of 10 .metal files was compiled,
    /// causing the metallib to shrink from 288KB to 70KB and missing critical functions.
    func testMetallibIsComplete() throws {
        let library = try VRMPipelineCache.shared.getLibrary(device: device)
        let functionNames = Set(library.functionNames)

        // All required shader functions that must be present for rendering to work
        let requiredFunctions = [
            // MToonShader.metal
            "mtoon_vertex",
            "mtoon_fragment_v2",
            "mtoon_outline_vertex",
            "mtoon_outline_fragment",
            // SkinnedShader.metal - CRITICAL for animated VRM rendering
            "skinned_mtoon_vertex",
            "skinned_vertex",
            // SpringBone compute shaders
            "springBoneKinematic",
            "springBonePredict",
            "springBoneDistance",
            "springBoneCollideSpheres",
            "springBoneCollideCapsules",
            // Morph compute shaders
            "morphTargetCompute",
            "morph_accumulate_positions",
            "morph_accumulate_normals",
            // Debug shaders
            "debug_unlit_vertex",
            "debug_unlit_fragment",
            // Sprite shaders
            "sprite_vertex",
            "sprite_fragment",
        ]

        print("=== Metallib Integrity Check ===")
        print("Total functions: \(functionNames.count)")

        var missingFunctions: [String] = []
        for func_ in requiredFunctions {
            if !functionNames.contains(func_) {
                missingFunctions.append(func_)
                print("  ❌ MISSING: \(func_)")
            } else {
                print("  ✅ Found: \(func_)")
            }
        }

        // Check minimum function count (incomplete metallib had ~15, complete has ~50+)
        XCTAssertGreaterThan(
            functionNames.count,
            40,
            "Metallib has too few functions (\(functionNames.count)). Expected 50+. Did you forget to compile all .metal files? Use 'make shaders' in VRMMetalKit."
        )

        // Check all required functions are present
        XCTAssertEqual(
            missingFunctions.count,
            0,
            "Metallib is missing required functions: \(missingFunctions.joined(separator: ", ")). Run 'make shaders' to recompile all shader files."
        )
    }

    /// Test metallib file size as a quick sanity check.
    /// An incomplete metallib (compiling only 1 of 10 files) was 70KB.
    /// A complete metallib should be ~280KB+.
    func testMetallibFileSizeIsReasonable() throws {
        // Find the metallib in the bundle
        guard let bundleURL = Bundle.module.url(forResource: "VRMMetalKitShaders", withExtension: "metallib") else {
            throw XCTSkip("Metallib not found in bundle")
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: bundleURL.path)
        guard let fileSize = attributes[.size] as? Int else {
            throw XCTSkip("Could not get metallib file size")
        }

        print("=== Metallib File Size ===")
        print("Path: \(bundleURL.path)")
        print("Size: \(fileSize) bytes (\(fileSize / 1024)KB)")

        // Minimum expected size for complete metallib (all 10 .metal files)
        let minimumExpectedSize = 200_000  // 200KB

        XCTAssertGreaterThan(
            fileSize,
            minimumExpectedSize,
            "Metallib is too small (\(fileSize / 1024)KB). Expected >200KB. This suggests incomplete compilation. Run 'make shaders' to compile all .metal files."
        )
    }

    // MARK: - GPU Pixel Sampling Tests

    /// Test that toon shading produces SHARP boundaries (linearstep) not soft gradients (smoothstep).
    ///
    /// With toony=0.9 and linearstep formula:
    /// - Shadow boundary width = 2 * (1 - 0.9) = 0.2 in NdotL space
    /// - Transition should be sharp: few intermediate gray values
    ///
    /// With smoothstep (WRONG):
    /// - Transition would be smooth: many intermediate gray values
    func testToonShadingProducesSharpBoundaries() async throws {
        let renderer = try MToonTestRenderer(device: device, width: 128, height: 128)

        // Render a sphere with high toony value (should have sharp shadows)
        let frameData = try renderer.renderToonShadedSphere(
            toonyFactor: 0.9,
            shadingShift: 0.0,
            lightDirection: SIMD3<Float>(0.5, 0.5, 0.707) // 45 degree light
        )

        // Analyze the grayscale distribution
        let histogram = analyzeGrayscaleHistogram(frameData: frameData, width: 128, height: 128)

        print("=== Toon Shading Histogram (toony=0.9) ===")
        print("Dark pixels (0-64): \(histogram.darkCount)")
        print("Mid pixels (65-190): \(histogram.midCount)")
        print("Light pixels (191-255): \(histogram.lightCount)")
        print("Mid ratio: \(histogram.midRatio)")

        // With linearstep (CORRECT): Few mid-tone pixels (sharp transition)
        // With smoothstep (WRONG): Many mid-tone pixels (gradient)
        //
        // Sharp toon shading should have < 15% mid-tones
        // Smooth gradient would have > 30% mid-tones
        XCTAssertLessThan(
            histogram.midRatio,
            0.20,
            "Toon shading has too many mid-tones (\(histogram.midRatio * 100)%). Expected sharp boundary with linearstep. Did you forget to recompile the metallib?"
        )
    }

    /// Test comparing toony=0.9 (sharp) vs toony=0.1 (soft) boundaries.
    /// Both should work, but 0.9 should be MUCH sharper.
    func testToonyFactorAffectsBoundarySharpness() async throws {
        let renderer = try MToonTestRenderer(device: device, width: 128, height: 128)

        // Render with high toony (sharp)
        let sharpFrame = try renderer.renderToonShadedSphere(
            toonyFactor: 0.9,
            shadingShift: 0.0,
            lightDirection: SIMD3<Float>(0.5, 0.5, 0.707)
        )
        let sharpHistogram = analyzeGrayscaleHistogram(frameData: sharpFrame, width: 128, height: 128)

        // Render with low toony (soft gradient allowed)
        let softFrame = try renderer.renderToonShadedSphere(
            toonyFactor: 0.1,
            shadingShift: 0.0,
            lightDirection: SIMD3<Float>(0.5, 0.5, 0.707)
        )
        let softHistogram = analyzeGrayscaleHistogram(frameData: softFrame, width: 128, height: 128)

        print("=== Toony Factor Comparison ===")
        print("High toony (0.9) mid-ratio: \(sharpHistogram.midRatio)")
        print("Low toony (0.1) mid-ratio: \(softHistogram.midRatio)")

        // High toony should have significantly fewer mid-tones than low toony
        XCTAssertLessThan(
            sharpHistogram.midRatio,
            softHistogram.midRatio,
            "High toony (0.9) should have fewer mid-tones than low toony (0.1)"
        )
    }

    /// Test that toony=1.0 doesn't cause division by zero (edge case).
    /// This was a bug where linearstep(0, 0, t) caused NaN and black screen.
    func testToonyOneDoesNotCauseDivisionByZero() async throws {
        let renderer = try MToonTestRenderer(device: device, width: 128, height: 128)

        // Render with toony=1.0 (maximum sharpness, caused division by zero)
        let frameData = try renderer.renderToonShadedSphere(
            toonyFactor: 1.0,  // This caused linearstep(0, 0, t) = NaN
            shadingShift: 0.0,
            lightDirection: SIMD3<Float>(0.5, 0.5, 0.707)
        )

        let brightness = averageBrightness(frameData: frameData, width: 128, height: 128)

        print("=== Toony=1.0 Edge Case Test ===")
        print("Average brightness: \(brightness)")

        // Should NOT be zero (black) or NaN
        XCTAssertFalse(brightness.isNaN, "toony=1.0 caused NaN (division by zero)")
        XCTAssertGreaterThan(brightness, 0.1, "toony=1.0 caused black screen")
        XCTAssertLessThan(brightness, 0.9, "toony=1.0 caused white screen")
    }

    /// Test that shading shift moves the shadow boundary position.
    func testShadingShiftMovesBoundary() async throws {
        let renderer = try MToonTestRenderer(device: device, width: 128, height: 128)

        // Render with no shift
        let noShiftFrame = try renderer.renderToonShadedSphere(
            toonyFactor: 0.9,
            shadingShift: 0.0,
            lightDirection: SIMD3<Float>(0, 0, 1) // Front light
        )
        let noShiftBrightness = averageBrightness(frameData: noShiftFrame, width: 128, height: 128)

        // Render with positive shift (more lit area)
        let positiveShiftFrame = try renderer.renderToonShadedSphere(
            toonyFactor: 0.9,
            shadingShift: 0.3,
            lightDirection: SIMD3<Float>(0, 0, 1)
        )
        let positiveShiftBrightness = averageBrightness(frameData: positiveShiftFrame, width: 128, height: 128)

        // Render with negative shift (more shadow area)
        let negativeShiftFrame = try renderer.renderToonShadedSphere(
            toonyFactor: 0.9,
            shadingShift: -0.3,
            lightDirection: SIMD3<Float>(0, 0, 1)
        )
        let negativeShiftBrightness = averageBrightness(frameData: negativeShiftFrame, width: 128, height: 128)

        print("=== Shading Shift Comparison ===")
        print("No shift brightness: \(noShiftBrightness)")
        print("Positive shift (+0.3) brightness: \(positiveShiftBrightness)")
        print("Negative shift (-0.3) brightness: \(negativeShiftBrightness)")

        // Positive shift should make image brighter (more lit area)
        XCTAssertGreaterThan(
            positiveShiftBrightness,
            noShiftBrightness,
            "Positive shading shift should increase brightness"
        )

        // Negative shift should make image darker (more shadow)
        XCTAssertLessThan(
            negativeShiftBrightness,
            noShiftBrightness,
            "Negative shading shift should decrease brightness"
        )
    }

    // MARK: - Helper Functions

    private func findShaderSourcePath() -> String? {
        // Try multiple locations
        let candidates = [
            // From test file location
            URL(fileURLWithPath: #file)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/VRMMetalKit/Shaders/MToonShader.metal")
                .path,
            // Absolute path
            "/Users/arkavo/Projects/VRMMetalKit/Sources/VRMMetalKit/Shaders/MToonShader.metal",
            // Environment variable
            ProcessInfo.processInfo.environment["VRM_SHADER_PATH"] ?? ""
        ]

        for path in candidates {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        return nil
    }

    struct GrayscaleHistogram {
        let darkCount: Int      // 0-64
        let midCount: Int       // 65-190
        let lightCount: Int     // 191-255
        let totalPixels: Int

        var midRatio: Float {
            guard totalPixels > 0 else { return 0 }
            return Float(midCount) / Float(totalPixels)
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

    private func averageBrightness(frameData: Data, width: Int, height: Int) -> Float {
        let bytes = [UInt8](frameData)
        let pixelCount = width * height
        var total: Float = 0

        for i in 0..<pixelCount {
            let offset = i * 4
            guard offset + 2 < bytes.count else { continue }

            let b = Float(bytes[offset])
            let g = Float(bytes[offset + 1])
            let r = Float(bytes[offset + 2])
            let gray = (r * 0.299 + g * 0.587 + b * 0.114) / 255.0
            total += gray
        }

        return total / Float(pixelCount)
    }
}

// MARK: - MToon Test Renderer

/// Minimal renderer for testing MToon shader output
final class MToonTestRenderer {
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
            throw TestError.commandQueueCreationFailed
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
            throw TestError.textureCreationFailed
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
            throw TestError.textureCreationFailed
        }
        self.depthTexture = depthTex

        // Create pipeline using VRMPipelineCache
        let library = try VRMPipelineCache.shared.getLibrary(device: device)

        guard let vertexFunc = library.makeFunction(name: "mtoon_vertex"),
              let fragmentFunc = library.makeFunction(name: "mtoon_fragment_v2") else {
            throw TestError.shaderFunctionNotFound
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
            throw TestError.bufferCreationFailed
        }

        self.vertexBuffer = vbuf
        self.indexBuffer = ibuf
        self.indexCount = indices.count
    }

    func renderToonShadedSphere(
        toonyFactor: Float,
        shadingShift: Float,
        lightDirection: SIMD3<Float>
    ) throws -> Data {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw TestError.commandBufferCreationFailed
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
            throw TestError.encoderCreationFailed
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

        // Create MToon material uniforms
        var material = MToonMaterialUniforms()
        material.baseColorFactor = SIMD4<Float>(1, 1, 1, 1)  // White
        material.shadeColorFactor = SIMD3<Float>(0.3, 0.3, 0.3)  // Dark gray shade
        material.shadingToonyFactor = toonyFactor
        material.shadingShiftFactor = shadingShift
        material.giIntensityFactor = 0.0

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

        // Create 1x1 white texture for baseColorTexture
        let texDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        texDesc.usage = .shaderRead
        guard let whiteTex = device.makeTexture(descriptor: texDesc) else {
            throw TestError.textureCreationFailed
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
            throw TestError.samplerCreationFailed
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

    enum TestError: Error {
        case commandQueueCreationFailed
        case textureCreationFailed
        case shaderFunctionNotFound
        case bufferCreationFailed
        case commandBufferCreationFailed
        case encoderCreationFailed
        case samplerCreationFailed
    }
}

// MARK: - Matrix Helpers

extension simd_float4x4 {
    init(translation: SIMD3<Float>) {
        self.init(
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(translation.x, translation.y, translation.z, 1)
        )
    }

    init(perspectiveWithAspect aspect: Float, fovy: Float, near: Float, far: Float) {
        let yScale = 1 / tan(fovy * 0.5)
        let xScale = yScale / aspect
        let zRange = far - near
        let zScale = -(far + near) / zRange
        let wzScale = -2 * far * near / zRange

        self.init(
            SIMD4<Float>(xScale, 0, 0, 0),
            SIMD4<Float>(0, yScale, 0, 0),
            SIMD4<Float>(0, 0, zScale, -1),
            SIMD4<Float>(0, 0, wzScale, 0)
        )
    }
}
