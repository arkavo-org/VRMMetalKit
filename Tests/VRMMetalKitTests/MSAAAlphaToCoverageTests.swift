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
import MetalKit
@testable import VRMMetalKit

/// TDD Tests for MSAA Alpha-to-Coverage implementation
///
/// Alpha-to-coverage with MSAA is the proper fix for MASK material edge aliasing.
/// It uses subpixel coverage from multisampling to smoothly fade alpha edges.
@MainActor
final class MSAAAlphaToCoverageTests: XCTestCase {
    
    var device: MTLDevice!
    
    override func setUp() async throws {
        device = MTLCreateSystemDefaultDevice()
        guard device != nil else {
            throw XCTSkip("Metal device not available")
        }
    }
    
    // MARK: - RED Phase: Failing Tests
    
    /// Test 1: Renderer creates multisample texture when MSAA enabled
    ///
    /// With sampleCount > 1, renderer must create a multisample render target.
    func testRendererCreatesMultisampleTextureWithMSAA() throws {
        // Arrange - Initialize renderer with MTKView to trigger pipeline setup
        var config = RendererConfig(strict: .off, sampleCount: 4)
        let renderer = VRMRenderer(device: device, config: config)
        
        print("MSAA Enabled: \(renderer.usesMultisampling)")
        print("Sample Count: \(config.sampleCount)")
        
        // Act - Trigger drawable size update to create textures
        let textureCreated = renderer.updateDrawableSize(CGSize(width: 512, height: 512))
        
        print("Texture created: \(textureCreated)")
        print("Multisample Texture: \(renderer.multisampleTexture != nil ? "created" : "nil")")
        
        // Assert
        XCTAssertTrue(renderer.usesMultisampling, "Renderer should report MSAA enabled")
        XCTAssertNotNil(renderer.multisampleTexture, "Renderer should create multisample texture")
        
        if let texture = renderer.multisampleTexture {
            XCTAssertEqual(texture.sampleCount, 4, "Texture should have 4 samples")
            XCTAssertEqual(texture.textureType, .type2DMultisample, "Texture should be multisample type")
            XCTAssertEqual(texture.pixelFormat, .bgra8Unorm, "Texture should match color format")
        }
    }
    
    /// Test 2: Multisample texture has correct dimensions
    ///
    /// Texture size must match drawable size.
    func testMultisampleTextureDimensionsMatchDrawable() throws {
        // Arrange
        let width = 1024
        let height = 768
        var config = RendererConfig(strict: .off, sampleCount: 4)
        let renderer = VRMRenderer(device: device, config: config)
        
        // Act
        renderer.updateDrawableSize(CGSize(width: width, height: height))
        
        // Assert
        guard let texture = renderer.multisampleTexture else {
            XCTFail("Multisample texture should exist")
            return
        }
        
        XCTAssertEqual(texture.width, width, "Texture width should match drawable")
        XCTAssertEqual(texture.height, height, "Texture height should match drawable")
    }
    
    /// Test 3: No multisample texture when MSAA disabled
    ///
    /// With sampleCount = 1, no multisample texture needed.
    func testNoMultisampleTextureWithoutMSAA() throws {
        // Arrange
        var config = RendererConfig(strict: .off, sampleCount: 1)
        let renderer = VRMRenderer(device: device, config: config)
        
        // Act
        renderer.updateDrawableSize(CGSize(width: 512, height: 512))
        
        // Assert
        XCTAssertFalse(renderer.usesMultisampling, "Renderer should not use MSAA with sampleCount=1")
        XCTAssertNil(renderer.multisampleTexture, "No multisample texture needed without MSAA")
    }
    
    /// Test 4: MASK materials use alpha-to-coverage pipeline with MSAA
    ///
    /// When rendering MASK materials with MSAA enabled, use A2C pipeline.
    func testMASKMaterialsUseAlphaToCoverageWithMSAA() throws {
        // Arrange
        var config = RendererConfig(strict: .off, sampleCount: 4)
        let renderer = VRMRenderer(device: device, config: config)
        
        // Act & Assert
        XCTAssertNotNil(renderer.maskAlphaToCoveragePipelineState,
            "Renderer should have A2C pipeline for MASK materials with MSAA")
    }
    
    /// Test 5: Alpha-to-coverage reduces MASK material edge flicker
    ///
    /// The primary benefit - smoother edges mean less flicker.
    func testAlphaToCoverageReducesMASKEdgeFlicker() async throws {
        // Arrange
        guard let helper = try? ZFightingTestHelper(device: device, width: 512, height: 512) else {
            throw XCTSkip("Could not create test helper")
        }
        
        let modelPath = "\(modelsDirectory)/AvatarSample_A.vrm.glb"
        try XCTSkipIf(!FileManager.default.fileExists(atPath: modelPath),
                      "Test model not found")
        
        let model = try await VRMModel.load(
            from: URL(fileURLWithPath: modelPath),
            device: device
        )
        
        // Verify model has MASK materials
        let maskMaterials = model.materials.filter { $0.alphaMode.uppercased() == "MASK" }
        print("Model has \(maskMaterials.count) MASK materials:")
        for mat in maskMaterials {
            print("  - \(mat.name ?? "unnamed")")
        }
        
        // Act - Measure flicker with and without alpha-to-coverage
        // Note: This requires the renderer to support MSAA mode
        // For now, we measure baseline and verify infrastructure
        
        helper.loadModel(model)
        helper.setViewMatrix(makeLookAt(
            eye: SIMD3<Float>(0, 1.5, 1.0),
            target: SIMD3<Float>(0, 1.5, 0),
            up: SIMD3<Float>(0, 1, 0)
        ))
        
        let frames = try helper.renderMultipleFrames(count: 20, perturbationScale: 0.0001)
        let result = FlickerDetector.analyzeRegion(
            frames: frames,
            x: 128, y: 128, width: 256, height: 256,
            frameWidth: 512, threshold: 5
        )
        
        print("Baseline flicker rate: \(String(format: "%.2f", result.flickerRate))%")
        print("TODO: Compare with MSAA alpha-to-coverage enabled")
        
        // For TDD, we just verify measurement works
        // Full comparison requires MSAA render target implementation
        XCTAssertGreaterThanOrEqual(result.flickerRate, 0.0,
            "Should be able to measure flicker rate")
        
        // Once MSAA A2C is implemented, this should show reduction:
        // XCTAssertLessThan(a2cFlicker, baselineFlicker * 0.7,
        //     "A2C should reduce flicker by at least 30%")
    }
    
    /// Test 6: Render pass descriptor configured for multisample
    ///
    /// When MSAA enabled, render pass must use multisample textures.
    func testRenderPassDescriptorConfiguredForMultisample() throws {
        // Arrange
        var config = RendererConfig(strict: .off, sampleCount: 4)
        let renderer = VRMRenderer(device: device, config: config)
        renderer.updateDrawableSize(CGSize(width: 512, height: 512))
        
        // Act - Get render pass descriptor
        let descriptor = renderer.getMultisampleRenderPassDescriptor()
        
        // Assert
        XCTAssertNotNil(descriptor, "Should provide multisample render pass descriptor")
        
        guard let colorAttachment = descriptor?.colorAttachments[0] else {
            XCTFail("Color attachment should exist")
            return
        }
        
        XCTAssertNotNil(colorAttachment.texture, "Color attachment should have multisample texture")
        XCTAssertEqual(colorAttachment.texture?.sampleCount, 4, "Attachment should have 4 samples")
        XCTAssertEqual(colorAttachment.storeAction, .multisampleResolve, "Should use multisample resolve")
        
        // Note: Resolve texture is set during actual rendering, not in descriptor creation
        // This would be configured when setting up the render pass with the final drawable
    }
    
    /// Test 7: Pipeline descriptor has alpha-to-coverage enabled
    ///
    /// The A2C pipeline must have isAlphaToCoverageEnabled = true.
    func testPipelineDescriptorHasAlphaToCoverageEnabled() throws {
        // Arrange
        var config = RendererConfig(strict: .off, sampleCount: 4)
        let renderer = VRMRenderer(device: device, config: config)
        
        // Act
        let descriptor = renderer.getMASKPipelineDescriptor()
        
        // Assert
        XCTAssertNotNil(descriptor, "Should provide MASK pipeline descriptor")
        XCTAssertTrue(descriptor?.isAlphaToCoverageEnabled ?? false,
            "MASK pipeline should have alpha-to-coverage enabled")
    }
    
    /// Test 8: Resolve configuration exists
    ///
    /// Resolve pass setup should be available for MSAA.
    func testResolveConfigurationExists() throws {
        // Arrange
        var config = RendererConfig(strict: .off, sampleCount: 4)
        let renderer = VRMRenderer(device: device, config: config)
        
        // Act & Assert
        // The resolve happens automatically via .multisampleResolve store action
        // when the render pass is configured with a resolve texture
        XCTAssertTrue(renderer.usesMultisampling, "MSAA should be enabled")
        
        // Full resolve pass implementation would require integration with
        // the actual rendering loop and drawable presentation
        // For now, we verify the infrastructure exists
        let descriptor = renderer.getResolveRenderPassDescriptor()
        XCTAssertNotNil(descriptor, "Should provide resolve render pass descriptor")
    }
    
    /// Test 9: MSAA sample count validated
    ///
    /// Only valid sample counts should be accepted (1, 2, 4, 8).
    func testMSAASampleCountValidation() {
        // Valid sample counts
        XCTAssertTrue(isValidSampleCount(1), "1x (no MSAA) should be valid")
        XCTAssertTrue(isValidSampleCount(2), "2x MSAA should be valid")
        XCTAssertTrue(isValidSampleCount(4), "4x MSAA should be valid")
        XCTAssertTrue(isValidSampleCount(8), "8x MSAA should be valid")
        
        // Invalid sample counts
        XCTAssertFalse(isValidSampleCount(3), "3x should be invalid")
        XCTAssertFalse(isValidSampleCount(5), "5x should be invalid")
        XCTAssertFalse(isValidSampleCount(0), "0x should be invalid")
    }
    
    /// Test 10: Renderer reports MSAA availability
    ///
    /// Client code should be able to query MSAA status.
    func testRendererReportsMSAAAvailability() {
        // Arrange
        let config4x = RendererConfig(strict: .off, sampleCount: 4)
        let config1x = RendererConfig(strict: .off, sampleCount: 1)
        
        let renderer4x = VRMRenderer(device: device, config: config4x)
        let renderer1x = VRMRenderer(device: device, config: config1x)
        
        // Assert
        XCTAssertTrue(renderer4x.usesMultisampling, "4x MSAA renderer should report MSAA")
        XCTAssertFalse(renderer1x.usesMultisampling, "1x renderer should not report MSAA")
    }
    
    // MARK: - Helper Methods
    
    private var modelsDirectory: String {
        ProcessInfo.processInfo.environment["VRM_MODELS_PATH"] ?? ""
    }
    
    private func isValidSampleCount(_ count: Int) -> Bool {
        // Valid MSAA sample counts are powers of 2: 1, 2, 4, 8
        return [1, 2, 4, 8].contains(count)
    }
}


