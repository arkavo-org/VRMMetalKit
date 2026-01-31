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

/// Diagnostic tests for material loading issues
@MainActor
final class MaterialDiagnosticTests: XCTestCase {
    
    var device: MTLDevice!
    
    override func setUp() async throws {
        device = MTLCreateSystemDefaultDevice()
        guard device != nil else {
            throw XCTSkip("Metal device not available")
        }
    }
    
    private var modelPath: String? {
        let candidates = [
            "/Users/arkavo/Projects/Muse/Resources/VRM/AvatarSample_A.vrm.glb",
            ProcessInfo.processInfo.environment["MUSE_RESOURCES_PATH"].flatMap { "\($0)/AvatarSample_A.vrm.glb" }
        ].compactMap { $0 }
        
        for path in candidates {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        return nil
    }
    
    /// Test: Print all material shade colors from AvatarSample_A
    func testAvatarSampleAShadeColors() async throws {
        guard let path = modelPath else {
            throw XCTSkip("AvatarSample_A.vrm.glb not found")
        }
        
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device)
        
        print("\n=== Material Diagnostic Report for AvatarSample_A ===\n")
        print("Total materials: \(model.materials.count)")
        print("")
        
        for (index, material) in model.materials.enumerated() {
            print("Material \(index): \(material.name ?? "unnamed")")
            print("  - Alpha Mode: \(material.alphaMode)")
            print("  - Base Color: \(material.baseColorFactor)")
            print("  - Double Sided: \(material.doubleSided)")
            print("  - Has Base Texture: \(material.baseColorTexture != nil)")
            
            if let mtoon = material.mtoon {
                print("  - MToon Properties:")
                print("    * Shade Color: \(mtoon.shadeColorFactor)")
                print("    * Shading Toony: \(mtoon.shadingToonyFactor)")
                print("    * Shading Shift: \(mtoon.shadingShiftFactor)")
                print("    * GI Intensity: \(mtoon.giIntensityFactor)")
                print("    * Has Shade Multiply Texture: \(mtoon.shadeMultiplyTexture != nil)")
            } else {
                print("  - MToon: NONE (using default PBR)")
            }
            print("")
        }
        
        // Verify at least some materials have MToon data
        let mtoonMaterials = model.materials.filter { $0.mtoon != nil }
        print("Materials with MToon: \(mtoonMaterials.count)/\(model.materials.count)")
        
        // Verify shade colors are being loaded (not all black)
        let materialsWithNonBlackShade = mtoonMaterials.filter { mat in
            guard let mtoon = mat.mtoon else { return false }
            return mtoon.shadeColorFactor.x > 0.001 || 
                   mtoon.shadeColorFactor.y > 0.001 || 
                   mtoon.shadeColorFactor.z > 0.001
        }
        print("Materials with non-black shade color: \(materialsWithNonBlackShade.count)")
        
        // This is a diagnostic test - we just want to see the output
        // Don't assert, just print information
    }
    
    /// Test: Verify material uniforms are correctly created
    func testMaterialUniformsCreation() async throws {
        guard let path = modelPath else {
            throw XCTSkip("AvatarSample_A.vrm.glb not found")
        }
        
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device)
        
        print("\n=== Material Uniforms Diagnostic ===\n")
        
        for (index, material) in model.materials.enumerated() {
            guard let mtoon = material.mtoon else { continue }
            
            let uniforms = MToonMaterialUniforms(from: mtoon)
            
            print("Material \(index): \(material.name ?? "unnamed")")
            print("  Source shadeColorFactor: \(mtoon.shadeColorFactor)")
            print("  Uniforms shadeColor: (R:\(uniforms.shadeColorR), G:\(uniforms.shadeColorG), B:\(uniforms.shadeColorB))")
            print("")
        }
    }
    
    /// Test: Analyze shade multiply textures
    func testShadeMultiplyTextureAnalysis() async throws {
        guard let path = modelPath else {
            throw XCTSkip("AvatarSample_A.vrm.glb not found")
        }
        
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device)
        
        print("\n=== Shade Multiply Texture Analysis ===\n")
        
        for (index, material) in model.materials.enumerated() {
            guard let mtoon = material.mtoon,
                  let shadeTexIndex = mtoon.shadeMultiplyTexture,
                  shadeTexIndex < model.textures.count else {
                print("Material \(index): \(material.name ?? "unnamed") - No shade multiply texture")
                continue
            }
            
            let texture = model.textures[shadeTexIndex]
            print("Material \(index): \(material.name ?? "unnamed")")
            print("  - Texture Index: \(shadeTexIndex)")
            print("  - Texture Name: \(texture.name ?? "unnamed")")
            
            if let mtlTexture = texture.mtlTexture {
                print("  - Metal Texture: YES")
                print("  - Size: \(mtlTexture.width)x\(mtlTexture.height)")
                print("  - Mipmapped: \(mtlTexture.mipmapLevelCount > 1)")
            } else {
                print("  - Metal Texture: NO (not loaded)")
            }
            print("")
        }
    }
    
    /// Test: Analyze base color textures (for face detail verification)
    func testBaseColorTextureAnalysis() async throws {
        guard let path = modelPath else {
            throw XCTSkip("AvatarSample_A.vrm.glb not found")
        }
        
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device)
        
        print("\n=== Base Color Texture Analysis ===\n")
        
        for (index, material) in model.materials.enumerated() {
            print("Material \(index): \(material.name ?? "unnamed")")
            print("  - Alpha Mode: \(material.alphaMode)")
            
            if let baseTexture = material.baseColorTexture {
                print("  - Base Texture: \(baseTexture.name ?? "unnamed")")
                if let mtlTexture = baseTexture.mtlTexture {
                    print("  - Texture Size: \(mtlTexture.width)x\(mtlTexture.height)")
                    print("  - Pixel Format: \(mtlTexture.pixelFormat)")
                } else {
                    print("  - Texture: NOT LOADED")
                }
            } else {
                print("  - Base Texture: NONE")
            }
            print("")
        }
    }
    
    /// Test: Check render order and mesh assignments for face materials
    func testFaceMaterialRenderOrder() async throws {
        guard let path = modelPath else {
            throw XCTSkip("AvatarSample_A.vrm.glb not found")
        }
        
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device)
        
        print("\n=== Face Material Render Order Analysis ===\n")
        
        // Find meshes that use face materials
        for (meshIndex, mesh) in model.meshes.enumerated() {
            for (primIndex, primitive) in mesh.primitives.enumerated() {
                guard let materialIndex = primitive.materialIndex,
                      materialIndex < model.materials.count else { continue }
                
                let material = model.materials[materialIndex]
                let name = material.name ?? "Material_\(materialIndex)"
                
                // Only show face-related materials
                if name.lowercased().contains("face") || name.lowercased().contains("mouth") || name.lowercased().contains("eye") {
                    print("Mesh \(meshIndex), Primitive \(primIndex):")
                    print("  - Material: \(name) (index: \(materialIndex))")
                    print("  - Alpha Mode: \(material.alphaMode)")
                    print("  - Alpha Cutoff: \(material.alphaCutoff)")
                    print("  - Render Queue: \(material.renderQueue ?? -1)")
                    print("  - Vertex Count: \(primitive.vertexCount)")
                    print("  - Index Count: \(primitive.indexCount)")
                    print("")
                }
            }
        }
    }
    
    /// Test: Verify renderer correctly classifies face materials by name
    func testRendererFaceMaterialClassification() async throws {
        guard let path = modelPath else {
            throw XCTSkip("AvatarSample_A.vrm.glb not found")
        }
        
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device)
        
        print("\n=== Face Material Classification Test ===\n")
        
        for material in model.materials {
            let nameLower = material.name?.lowercased() ?? ""
            
            var classification: String
            var expectedOrder: Int
            
            // Match the logic in VRMRenderer
            if nameLower.contains("mouth") || nameLower.contains("lip") {
                classification = "faceOverlay (mouth/lip)"
                expectedOrder = 2
            } else if nameLower.contains("skin") || (nameLower.contains("face") && !nameLower.contains("eye")) {
                classification = "faceSkin (base)"
                expectedOrder = 1
            } else if nameLower.contains("brow") {
                classification = "eyebrow"
                expectedOrder = 2
            } else if nameLower.contains("eye") {
                classification = "eye"
                expectedOrder = 5
            } else if nameLower.contains("highlight") {
                classification = "highlight"
                expectedOrder = 6
            } else {
                classification = "other"
                expectedOrder = -1
            }
            
            print("Material: \(material.name ?? "unnamed")")
            print("  Classification: \(classification)")
            print("  Expected Render Order: \(expectedOrder)")
            print("")
        }
    }
}
