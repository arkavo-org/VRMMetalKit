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
@testable import VRMMetalKit

/// TDD Tests for Hip/Skirt Z-fighting fix
///
/// The hip/skirt boundary suffers from Z-fighting because body and clothing
/// materials overlap. This test suite validates proper depth bias separation.
@MainActor
final class HipSkirtTests: XCTestCase {
    
    var device: MTLDevice!
    var calculator: DepthBiasCalculator!
    
    override func setUp() async throws {
        device = MTLCreateSystemDefaultDevice()
        guard device != nil else {
            throw XCTSkip("Metal device not available")
        }
        calculator = DepthBiasCalculator()
    }
    
    // MARK: - RED Phase: Failing Tests
    
    /// Test 1: Clothing materials should have higher bias than body
    ///
    /// At hip/skirt boundary, clothing must render on top of body.
    /// This requires clothing bias > body bias.
    func testClothingBiasHigherThanBody() {
        // Arrange
        let bodyBias = calculator.depthBias(for: "Body_SKIN", isOverlay: false)
        let clothingBias = calculator.depthBias(for: "Bottoms_CLOTH", isOverlay: true)
        
        // Act & Assert
        XCTAssertGreaterThan(clothingBias, bodyBias,
            "Clothing bias (\(clothingBias)) must be greater than body bias (\(bodyBias)) to prevent Z-fighting at hip/skirt")
        
        print("Hip/Skirt Depth Bias:")
        print("  Body: \(String(format: "%.4f", bodyBias))")
        print("  Clothing: \(String(format: "%.4f", clothingBias))")
        print("  Separation: \(String(format: "%.4f", clothingBias - bodyBias))")
    }
    
    /// Test 2: Skirt materials are recognized
    ///
    /// Materials with "skirt", "bottom", "pants" in name should get clothing bias.
    func testSkirtMaterialsRecognized() {
        // Arrange & Act
        let skirtBias = calculator.depthBias(for: "Skirt", isOverlay: true)
        let bottomBias = calculator.depthBias(for: "Bottoms_CLOTH", isOverlay: true)
        let pantsBias = calculator.depthBias(for: "Pants", isOverlay: true)
        
        // Assert - All should have clothing-level bias (> 0.01)
        XCTAssertGreaterThan(skirtBias, 0.01, "Skirt should have clothing bias")
        XCTAssertGreaterThan(bottomBias, 0.01, "Bottoms should have clothing bias")
        XCTAssertGreaterThan(pantsBias, 0.01, "Pants should have clothing bias")
        
        print("Clothing Material Biases:")
        print("  Skirt: \(String(format: "%.4f", skirtBias))")
        print("  Bottoms: \(String(format: "%.4f", bottomBias))")
        print("  Pants: \(String(format: "%.4f", pantsBias))")
    }
    
    /// Test 3: Minimum separation for hip/skirt boundary
    ///
    /// To prevent Z-fighting, we need at least 0.01 separation
    /// between body and clothing at the hip boundary.
    func testMinimumSeparationForHipSkirt() {
        // Arrange
        let bodyBias = calculator.depthBias(for: "Body_SKIN", isOverlay: false)
        let skirtBias = calculator.depthBias(for: "Skirt", isOverlay: true)
        
        // Act
        let separation = skirtBias - bodyBias
        
        // Assert - Need at least 0.01 separation
        XCTAssertGreaterThanOrEqual(separation, 0.01,
            "Hip/skirt needs at least 0.01 depth bias separation, got \(separation)")
    }
    
    /// Test 4: Clothing overlay gets additional offset
    ///
    /// When clothing is explicitly marked as overlay, it gets extra bias.
    func testClothingOverlayGetsAdditionalOffset() {
        // Arrange
        let baseClothing = calculator.depthBias(for: "Skirt", isOverlay: false)
        let overlayClothing = calculator.depthBias(for: "Skirt", isOverlay: true)
        
        // Act & Assert
        XCTAssertGreaterThan(overlayClothing, baseClothing,
            "Clothing overlay should get additional bias offset")
        
        let offset = overlayClothing - baseClothing
        // The overlay offset is 0.01, but floating point may give 0.009999999
        XCTAssertGreaterThanOrEqual(offset, 0.0099,
            "Clothing overlay offset should be at least 0.01")
    }
    
    /// Test 5: Scale factor affects clothing bias
    ///
    /// Global scale should apply to clothing materials.
    func testScaleFactorAffectsClothingBias() {
        // Arrange
        let baseScale = DepthBiasCalculator(scale: 1.0)
        let doubledScale = DepthBiasCalculator(scale: 2.0)
        
        // Act
        let baseBias = baseScale.depthBias(for: "Skirt", isOverlay: true)
        let doubledBias = doubledScale.depthBias(for: "Skirt", isOverlay: true)
        
        // Assert
        XCTAssertEqual(doubledBias, baseBias * 2.0, accuracy: 0.0001,
            "Scale factor should double clothing bias")
    }
    
    /// Test 6: Hip skirt depth bias separation
    ///
    /// Validates that body and clothing materials have proper depth bias separation.
    /// Note: MASK material edge aliasing requires alpha-to-coverage, not depth bias.
    func testHipSkirtDepthBiasSeparation() async throws {
        // Arrange
        let modelPath = "\(modelsDirectory)/AvatarSample_A.vrm.glb"
        try XCTSkipIf(!FileManager.default.fileExists(atPath: modelPath),
                      "Test model not found at \(modelPath)")
        
        let model = try await VRMModel.load(
            from: URL(fileURLWithPath: modelPath),
            device: device
        )
        
        // Act - Check depth bias values for hip/skirt materials
        let bodyMat = model.materials.first { ($0.name ?? "").lowercased().contains("body") }
        let clothingMat = model.materials.first { ($0.name ?? "").lowercased().contains("cloth") }
        
        guard let body = bodyMat, let clothing = clothingMat else {
            throw XCTSkip("Model missing body or clothing materials")
        }
        
        let bodyBias = calculator.depthBias(for: body.name!, isOverlay: false)
        let clothingBias = calculator.depthBias(for: clothing.name!, isOverlay: true)
        let separation = clothingBias - bodyBias
        
        print("Hip/Skirt Depth Bias Analysis:")
        print("  Body (\(body.name!)): \(String(format: "%.4f", bodyBias))")
        print("  Clothing (\(clothing.name!)): \(String(format: "%.4f", clothingBias))")
        print("  Separation: \(String(format: "%.4f", separation))")
        print("  Body alphaMode: \(body.alphaMode)")
        print("  Clothing alphaMode: \(clothing.alphaMode)")
        
        // Assert
        XCTAssertGreaterThan(clothingBias, bodyBias,
            "Clothing must have higher depth bias than body")
        
        // For MASK materials, we need alpha-to-coverage to truly fix edge aliasing
        // Depth bias only helps with true Z-fighting (coplanar surfaces)
        if body.alphaMode.uppercased() == "MASK" && clothing.alphaMode.uppercased() == "MASK" {
            print("Note: Both materials use MASK alpha mode.")
            print("Edge aliasing requires alpha-to-coverage, not depth bias.")
        }
        
        // Minimum separation for depth test conflicts
        XCTAssertGreaterThanOrEqual(separation, 0.01,
            "Need at least 0.01 depth bias separation for hip/skirt boundary")
    }
    
    // MARK: - Helper Methods
    
    private var modelsDirectory: String {
        let candidates: [String] = [
            "/Users/arkavo/Documents/VRMModels",
            ProcessInfo.processInfo.environment["VRM_MODELS_PATH"]
        ].compactMap { $0 }
        
        for candidate in candidates {
            if FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
        }
        return ""
    }
}
