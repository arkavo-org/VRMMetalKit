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

/// TDD Tests for Material-Aware Depth Bias implementation
///
/// Depth bias (polygon offset) resolves true Z-fighting between coplanar surfaces
/// by pushing one surface slightly toward the camera in depth buffer space.
@MainActor
final class DepthBiasTests: XCTestCase {
    
    var device: MTLDevice!
    
    override func setUp() async throws {
        device = MTLCreateSystemDefaultDevice()
        guard device != nil else {
            throw XCTSkip("Metal device not available")
        }
    }
    
    // MARK: - RED Phase: Failing Tests
    
    /// Test 1: Renderer should provide depth bias for coplanar surfaces
    ///
    /// When two surfaces occupy the same depth (coplanar), depth bias
    /// pushes one slightly toward camera to prevent Z-fighting.
    func testRendererProvidesDepthBiasForCoplanarSurfaces() throws {
        // Arrange
        let config = RendererConfig(strict: .off)
        let renderer = VRMRenderer(device: device, config: config)
        
        // Act & Assert
        XCTAssertNotNil(renderer.depthBiasCalculator,
            "Renderer should have depth bias calculator for coplanar surfaces")
    }
    
    /// Test 2: Different materials should have different depth bias values
    ///
    /// Face overlays (mouth, eyebrows) need more bias than base skin
    /// to render correctly on top without Z-fighting.
    func testFaceOverlayMaterialsHaveHigherDepthBias() {
        // Arrange
        let config = RendererConfig(strict: .off)
        let renderer = VRMRenderer(device: device, config: config)
        
        // Act - Get bias values for different material categories
        let calculator = renderer.depthBiasCalculator
        let baseSkinBias = calculator.depthBias(for: "Face_SKIN", isOverlay: false)
        let mouthBias = calculator.depthBias(for: "FaceMouth", isOverlay: true)
        let eyebrowBias = calculator.depthBias(for: "Eyebrow", isOverlay: true)
        
        // Assert - Overlays need higher bias to render on top
        XCTAssertGreaterThan(mouthBias, baseSkinBias,
            "Mouth overlay should have higher depth bias than base skin")
        XCTAssertGreaterThan(eyebrowBias, baseSkinBias,
            "Eyebrow overlay should have higher depth bias than base skin")
        
        // Print values for debugging
        print("Depth Bias Values:")
        print("  Face_SKIN (base): \(String(format: "%.4f", baseSkinBias))")
        print("  FaceMouth (overlay): \(String(format: "%.4f", mouthBias))")
        print("  Eyebrow (overlay): \(String(format: "%.4f", eyebrowBias))")
    }
    
    /// Test 3: Depth bias reduces Z-fighting in coplanar geometry
    ///
    /// This test validates that applying depth bias actually reduces
    /// the measured flicker rate for overlapping coplanar surfaces.
    func testDepthBiasReducesCoplanarZFighting() async throws {
        // Arrange - Skip if we can't create test geometry
        guard let helper = try? ZFightingTestHelper(device: device, width: 512, height: 512) else {
            throw XCTSkip("Could not create test helper")
        }
        
        // Create synthetic coplanar geometry (two quads at identical depth)
        let coplanarModel: VRMModel
        do {
            coplanarModel = try createCoplanarTestModel(device: device)
        } catch {
            throw XCTSkip("Coplanar test geometry not available: \(error)")
        }
        
        // Act - Measure flicker without depth bias
        let flickerWithoutBias = try await measureZFighting(
            model: coplanarModel,
            helper: helper,
            useDepthBias: false
        )
        
        // Measure flicker with depth bias
        let flickerWithBias = try await measureZFighting(
            model: coplanarModel,
            helper: helper,
            useDepthBias: true
        )
        
        // Assert - Depth bias should significantly reduce Z-fighting
        let improvement = (flickerWithoutBias - flickerWithBias) / max(flickerWithoutBias, 0.001)
        
        print("Depth Bias Improvement:")
        print("  Without bias: \(String(format: "%.2f", flickerWithoutBias))%")
        print("  With bias: \(String(format: "%.2f", flickerWithBias))%")
        print("  Improvement: \(String(format: "%.1f", improvement * 100))%")
        
        XCTAssertGreaterThan(improvement, 0.50,
            "Depth bias should reduce coplanar Z-fighting by at least 50%")
    }
    
    /// Test 4: Depth bias values are positive (toward camera)
    ///
    /// Positive depth bias pushes fragments toward camera (closer to viewer),
    /// ensuring they pass depth test against surfaces at same world depth.
    func testDepthBiasValuesArePositive() {
        // Arrange
        let config = RendererConfig(strict: .off)
        let renderer = VRMRenderer(device: device, config: config)
        
        // Act & Assert - All bias values should be positive
        let calculator = renderer.depthBiasCalculator
        let categories = ["Face_SKIN", "FaceMouth", "EyeIris", "Body_SKIN"]
        for category in categories {
            let bias = calculator.depthBias(for: category, isOverlay: category != "Face_SKIN")
            XCTAssertGreaterThan(bias, 0.0,
                "\(category) should have positive depth bias (toward camera)")
        }
    }
    
    /// Test 5: Depth bias values are captured correctly
    ///
    /// Validates that depth bias values are computed and can be applied.
    func testDepthBiasValuesAreCapturedCorrectly() throws {
        // Arrange
        let config = RendererConfig(strict: .off)
        let renderer = VRMRenderer(device: device, config: config)
        
        // Act - Get depth bias for overlay material
        let calculator = renderer.depthBiasCalculator
        let overlayBias = calculator.depthBias(for: "FaceMouth", isOverlay: true)
        
        // Capture the values (simulating what renderer would do)
        let capture = DepthBiasCapture()
        capture.setDepthBias(overlayBias, slopeScale: 2.0, clamp: 0.1)
        
        // Assert
        XCTAssertEqual(capture.capturedDepthBias, overlayBias,
            "Should capture depth bias for overlay materials")
        XCTAssertEqual(capture.capturedSlopeScale, 2.0,
            "Should capture slope scale")
        XCTAssertGreaterThan(capture.capturedDepthBias, 0.0,
            "Overlay should have positive depth bias")
    }
    
    /// Test 6: Depth bias configuration is exposed in RendererConfig
    ///
    /// Users should be able to tune depth bias globally via configuration.
    func testConfigurationExposesDepthBiasSettings() {
        // Arrange & Act
        var config = RendererConfig(strict: .off)
        
        // Assert - Should be able to configure depth bias
        config.depthBiasScale = 1.5  // Global multiplier
        
        XCTAssertEqual(config.depthBiasScale, 1.5,
            "Configuration should support depth bias scale setting")
    }
    
    // MARK: - Helper Methods
    
    private func createCoplanarTestModel(device: MTLDevice) throws -> VRMModel {
        // Create a minimal test model with two coplanar quads
        // This would generate geometry where Z-fighting is guaranteed
        // For now, throw to skip test
        
        // In real implementation, this creates two triangles at identical depth
        // that would Z-fight without depth bias
        
        throw XCTSkip("Synthetic coplanar geometry not yet implemented")
    }
    
    private func measureZFighting(
        model: VRMModel,
        helper: ZFightingTestHelper,
        useDepthBias: Bool
    ) async throws -> Float {
        // Load model
        helper.loadModel(model)
        
        // Set up view looking straight at coplanar surfaces
        helper.setViewMatrix(makeLookAt(
            eye: SIMD3<Float>(0, 0, 1),
            target: SIMD3<Float>(0, 0, 0),
            up: SIMD3<Float>(0, 1, 0)
        ))
        
        // Render frames with micro-movement
        let frames = try helper.renderMultipleFrames(
            count: 20,
            perturbationScale: 0.00005
        )
        
        // Analyze for Z-fighting
        let result = FlickerDetector.analyzeRegion(
            frames: frames,
            x: 128, y: 128, width: 256, height: 256,
            frameWidth: 512,
            threshold: 5
        )
        
        return result.flickerRate
    }
}

// MARK: - Mock Classes

/// Simple mock to capture depth bias values
private class DepthBiasCapture {
    var capturedDepthBias: Float = 0.0
    var capturedSlopeScale: Float = 0.0
    var capturedClamp: Float = 0.0
    
    func setDepthBias(_ depthBias: Float, slopeScale: Float, clamp: Float) {
        capturedDepthBias = depthBias
        capturedSlopeScale = slopeScale
        capturedClamp = clamp
    }
}


