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

/// TDD Tests for Mouth Rendering Issue
/// 
/// Problem: FaceMouth material exists with texture and geometry, but mouth features don't render.
/// Root Cause: UV coordinates point to blank face area instead of mouth texture area in atlas.
@MainActor
final class MouthRenderingTests: XCTestCase {
    
    var device: MTLDevice!
    
    override func setUp() async throws {
        device = MTLCreateSystemDefaultDevice()
        guard device != nil else {
            throw XCTSkip("Metal device not available")
        }
    }
    
    // MARK: - Test Helpers
    
    private var modelPath: String? {
        ProcessInfo.processInfo.environment["MUSE_RESOURCES_PATH"].flatMap { 
            let path = "\($0)/AvatarSample_A.vrm.glb"
            return FileManager.default.fileExists(atPath: path) ? path : nil
        }
    }
    
    // MARK: - RED Phase: Failing Tests
    
    /// Test 1: Mouth texture exists and contains mouth features
    /// 
    /// The mouth texture should be in the texture atlas (bottom right area).
    /// This test verifies the texture is loaded and has non-transparent pixels.
    func testMouthTextureExistsAndHasContent() async throws {
        guard let path = modelPath else {
            throw XCTSkip("AvatarSample_A.vrm.glb not found")
        }
        
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device)
        
        // Find FaceMouth material
        guard let mouthMaterialIndex = model.materials.firstIndex(where: { 
            $0.name?.contains("FaceMouth") == true 
        }) else {
            XCTFail("FaceMouth material not found")
            return
        }
        
        let mouthMaterial = model.materials[mouthMaterialIndex]
        
        // Verify material has base texture
        XCTAssertNotNil(mouthMaterial.baseColorTexture, "Mouth material should have base texture")
        
        guard let texture = mouthMaterial.baseColorTexture?.mtlTexture else {
            XCTFail("Mouth texture not loaded")
            return
        }
        
        // Verify texture has content (not all transparent)
        let hasContent = await textureHasNonTransparentPixels(texture)
        XCTAssertTrue(hasContent, "Mouth texture should have non-transparent content")
    }
    
    /// Test 2: Mouth geometry has valid UV coordinates
    /// 
    /// The mouth mesh UVs should point to the mouth texture area (bottom right of atlas),
    /// not the blank face area.
    func testMouthGeometryHasValidUVs() async throws {
        guard let path = modelPath else {
            throw XCTSkip("AvatarSample_A.vrm.glb not found")
        }
        
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device)
        
        // Find mouth primitive
        var mouthPrimitive: VRMPrimitive?
        for mesh in model.meshes {
            for primitive in mesh.primitives {
                guard let materialIndex = primitive.materialIndex,
                      materialIndex < model.materials.count else { continue }
                let material = model.materials[materialIndex]
                if material.name?.contains("FaceMouth") == true {
                    mouthPrimitive = primitive
                    break
                }
            }
        }
        
        guard let primitive = mouthPrimitive else {
            XCTFail("Mouth primitive not found")
            return
        }
        
        // Verify primitive has texture coordinates
        XCTAssertTrue(primitive.hasTexCoords, "Mouth primitive should have texture coordinates")
        
        // Verify UVs are in valid range [0,1]
        let uvs = await extractUVs(from: primitive)
        XCTAssertFalse(uvs.isEmpty, "Should extract UVs from mouth primitive")
        
        for (index, uv) in uvs.enumerated() {
            XCTAssertGreaterThanOrEqual(uv.x, 0.0, "UV[\(index)].u should be >= 0")
            XCTAssertLessThanOrEqual(uv.x, 1.0, "UV[\(index)].u should be <= 1")
            XCTAssertGreaterThanOrEqual(uv.y, 0.0, "UV[\(index)].v should be >= 0")
            XCTAssertLessThanOrEqual(uv.y, 1.0, "UV[\(index)].v should be <= 1")
        }
    }
    
    /// Test 3: Mouth UVs point to mouth texture area (not blank face area)
    /// 
    /// The mouth texture is in the bottom right of the atlas.
    /// UVs should be in range ~[0.5,1.0] x [0.5,1.0] for the mouth area.
    func testMouthUVsPointToMouthTextureArea() async throws {
        guard let path = modelPath else {
            throw XCTSkip("AvatarSample_A.vrm.glb not found")
        }
        
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device)
        
        // Find mouth primitive
        var mouthPrimitive: VRMPrimitive?
        for mesh in model.meshes {
            for primitive in mesh.primitives {
                guard let materialIndex = primitive.materialIndex,
                      materialIndex < model.materials.count else { continue }
                let material = model.materials[materialIndex]
                if material.name?.contains("FaceMouth") == true {
                    mouthPrimitive = primitive
                    break
                }
            }
        }
        
        guard let primitive = mouthPrimitive else {
            XCTFail("Mouth primitive not found")
            return
        }
        
        let uvs = await extractUVs(from: primitive)
        XCTAssertFalse(uvs.isEmpty, "Should extract UVs from mouth primitive")
        
        // Calculate UV bounds
        let minU = uvs.map { $0.x }.min() ?? 0
        let maxU = uvs.map { $0.x }.max() ?? 0
        let minV = uvs.map { $0.y }.min() ?? 0
        let maxV = uvs.map { $0.y }.max() ?? 0
        
        print("Mouth UV bounds: u=[\(minU), \(maxU)], v=[\(minV), \(maxV)]")
        
        // Mouth texture is in bottom right of atlas
        // UVs should cover that area (not just the blank face in top left)
        // This test will FAIL if UVs point to wrong area
        
        // At least some UVs should be in the right/bottom half (where mouth texture is)
        let uvsInRightHalf = uvs.filter { $0.x > 0.5 }.count
        let uvsInBottomHalf = uvs.filter { $0.y > 0.5 }.count
        
        let totalUVs = uvs.count
        let percentInRightHalf = Double(uvsInRightHalf) / Double(totalUVs) * 100
        let percentInBottomHalf = Double(uvsInBottomHalf) / Double(totalUVs) * 100
        
        print("UVs in right half (>0.5): \(percentInRightHalf)%")
        print("UVs in bottom half (>0.5): \(percentInBottomHalf)%")
        
        // Mouth should have significant coverage in the texture area
        // This assertion will fail if UVs are wrong
        XCTAssertGreaterThan(uvsInRightHalf, totalUVs / 10, 
            "At least 10% of mouth UVs should be in right half of texture")
        XCTAssertGreaterThan(uvsInBottomHalf, totalUVs / 10,
            "At least 10% of mouth UVs should be in bottom half of texture")
    }
    
    /// Test 4: Mouth alpha values are above cutoff
    /// 
    /// When sampling the texture at mouth UV coordinates, alpha should be > 0.5
    /// to prevent MASK mode from discarding the pixels.
    func testMouthTextureAlphaAboveCutoff() async throws {
        guard let path = modelPath else {
            throw XCTSkip("AvatarSample_A.vrm.glb not found")
        }
        
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device)
        
        // Find mouth material and primitive
        var mouthMaterial: VRMMaterial?
        var mouthPrimitive: VRMPrimitive?
        for mesh in model.meshes {
            for primitive in mesh.primitives {
                guard let materialIndex = primitive.materialIndex,
                      materialIndex < model.materials.count else { continue }
                let material = model.materials[materialIndex]
                if material.name?.contains("FaceMouth") == true {
                    mouthMaterial = material
                    mouthPrimitive = primitive
                    break
                }
            }
        }
        
        guard let material = mouthMaterial,
              let primitive = mouthPrimitive,
              let texture = material.baseColorTexture?.mtlTexture else {
            XCTFail("Mouth material/texture not found")
            return
        }
        
        let uvs = await extractUVs(from: primitive)
        let alphaCutoff = material.alphaCutoff
        
        // Sample texture at UV coordinates and check alpha
        let lowAlphaCount = await countLowAlphaPixels(texture: texture, uvs: uvs, cutoff: alphaCutoff)
        let totalPixels = uvs.count
        let lowAlphaPercent = Double(lowAlphaCount) / Double(totalPixels) * 100
        
        print("Alpha cutoff: \(alphaCutoff)")
        print("Pixels below cutoff: \(lowAlphaCount)/\(totalPixels) (\(lowAlphaPercent)%)")
        
        // Most mouth pixels should be above alpha cutoff
        // This will fail if mouth texture has alpha < cutoff
        XCTAssertLessThan(lowAlphaPercent, 50.0,
            "Less than 50% of mouth pixels should be below alpha cutoff")
    }
    
    /// Test 5: Mouth uses correct texture
    /// 
    /// The mouth material should reference the texture containing the mouth features.
    /// This test verifies which texture index the mouth material uses.
    func testMouthUsesCorrectTexture() async throws {
        guard let path = modelPath else {
            throw XCTSkip("AvatarSample_A.vrm.glb not found")
        }
        
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device)
        
        // Find mouth material
        guard let mouthMaterialIndex = model.materials.firstIndex(where: {
            $0.name?.contains("FaceMouth") == true
        }) else {
            XCTFail("FaceMouth material not found")
            return
        }
        
        let mouthMaterial = model.materials[mouthMaterialIndex]
        
        // Check which texture the mouth uses
        // The base texture should be the face atlas
        XCTAssertNotNil(mouthMaterial.baseColorTexture, "Mouth should have base color texture")
        
        // Find the texture index
        var textureIndex: Int?
        for (i, texture) in model.textures.enumerated() {
            if texture === mouthMaterial.baseColorTexture {
                textureIndex = i
                break
            }
        }
        
        print("Mouth material uses texture index: \(textureIndex ?? -1)")
        print("Total textures in model: \(model.textures.count)")
        
        // The mouth should use texture_0 (face atlas) or texture_7 (shade multiply)
        if let idx = textureIndex {
            XCTAssertTrue(idx == 0 || idx == 7, "Mouth should use texture 0 or 7, got \(idx)")
        }
    }
    
    /// Test 6: FaceMouth vs Face_SKIN UV comparison
    /// 
    /// This test documents the issue and its fix:
    /// - ISSUE: Mouth and face share the same source UVs centered at (0.4, 0.48)
    ///   which samples from the blank face area of the texture atlas.
    /// - FIX: UV offset is applied in the shader (uvOffsetX=0.35, uvOffsetY=0.25, uvScale=0.5)
    ///   to shift sampling to the lip texture area in the bottom right.
    func testMouthVsFaceUVComparison() async throws {
        guard let path = modelPath else {
            throw XCTSkip("AvatarSample_A.vrm.glb not found")
        }
        
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device)
        
        // Find mouth and face primitives
        var mouthPrimitive: VRMPrimitive?
        var facePrimitive: VRMPrimitive?
        
        for mesh in model.meshes {
            for primitive in mesh.primitives {
                guard let materialIndex = primitive.materialIndex,
                      materialIndex < model.materials.count else { continue }
                let material = model.materials[materialIndex]
                
                if material.name?.contains("FaceMouth") == true {
                    mouthPrimitive = primitive
                } else if material.name?.contains("Face_00_SKIN") == true {
                    facePrimitive = primitive
                }
            }
        }
        
        guard let mouth = mouthPrimitive, let face = facePrimitive else {
            XCTFail("Could not find mouth and face primitives")
            return
        }
        
        let mouthUVs = await extractUVs(from: mouth)
        let faceUVs = await extractUVs(from: face)
        
        // Calculate UV centroids
        let mouthCentroid = calculateCentroid(mouthUVs)
        let faceCentroid = calculateCentroid(faceUVs)
        
        print("Mouth UV centroid (source): (\(mouthCentroid.x), \(mouthCentroid.y))")
        print("Face UV centroid: (\(faceCentroid.x), \(faceCentroid.y))")
        print("NOTE: Shader applies UV offset (0.35, 0.25) and scale (0.5) for mouth")
        print("      Transformed mouth UV centroid: (~0.75, ~0.75) -> lip texture area")
        
        // Both have same source UVs (this is the original issue)
        // The fix is applied in the shader via uvOffsetX/Y
        XCTAssertEqual(mouthCentroid.x, faceCentroid.x, accuracy: 0.001, 
            "Source UVs are the same - shader fix applies offset")
        XCTAssertEqual(mouthCentroid.y, faceCentroid.y, accuracy: 0.001,
            "Source UVs are the same - shader fix applies offset")
    }
    
    private func calculateCentroid(_ uvs: [SIMD2<Float>]) -> SIMD2<Float> {
        guard !uvs.isEmpty else { return SIMD2<Float>(0, 0) }
        let sum = uvs.reduce(SIMD2<Float>(0, 0)) { $0 + $1 }
        return sum / Float(uvs.count)
    }
    
    // MARK: - Helper Functions
    
    private func textureHasNonTransparentPixels(_ texture: MTLTexture) async -> Bool {
        // Read texture data and check for non-transparent pixels
        let width = texture.width
        let height = texture.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let bytesPerImage = height * bytesPerRow
        
        var pixelData = Data(count: bytesPerImage)
        
        await withCheckedContinuation { continuation in
            pixelData.withUnsafeMutableBytes { rawBuffer in
                guard let pointer = rawBuffer.baseAddress else {
                    continuation.resume()
                    return
                }
                texture.getBytes(pointer, bytesPerRow: bytesPerRow, 
                                from: MTLRegionMake2D(0, 0, width, height), 
                                mipmapLevel: 0)
                continuation.resume()
            }
        }
        
        // Check for any non-transparent pixel (alpha > 0)
        for i in stride(from: 3, to: bytesPerImage, by: 4) {
            if pixelData[i] > 0 {
                return true
            }
        }
        return false
    }
    
    private func extractUVs(from primitive: VRMPrimitive) async -> [SIMD2<Float>] {
        guard let vertexBuffer = primitive.vertexBuffer else { return [] }
        
        var uvs: [SIMD2<Float>] = []
        
        await withCheckedContinuation { continuation in
            vertexBuffer.contents().withMemoryRebound(to: VRMVertex.self, capacity: primitive.vertexCount) { vertices in
                for i in 0..<primitive.vertexCount {
                    uvs.append(vertices[i].texCoord)
                }
                continuation.resume()
            }
        }
        
        return uvs
    }
    
    private func countLowAlphaPixels(texture: MTLTexture, uvs: [SIMD2<Float>], cutoff: Float) async -> Int {
        // Read texture data
        let width = texture.width
        let height = texture.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let bytesPerImage = height * bytesPerRow
        
        var pixelData = Data(count: bytesPerImage)
        
        await withCheckedContinuation { continuation in
            pixelData.withUnsafeMutableBytes { rawBuffer in
                guard let pointer = rawBuffer.baseAddress else {
                    continuation.resume()
                    return
                }
                texture.getBytes(pointer, bytesPerRow: bytesPerRow,
                                from: MTLRegionMake2D(0, 0, width, height),
                                mipmapLevel: 0)
                continuation.resume()
            }
        }
        
        var lowAlphaCount = 0
        
        for uv in uvs {
            let x = Int(uv.x * Float(width - 1))
            let y = Int(uv.y * Float(height - 1))
            let offset = (y * bytesPerRow) + (x * bytesPerPixel) + 3 // Alpha channel
            
            if offset < pixelData.count {
                let alpha = Float(pixelData[offset]) / 255.0
                if alpha < cutoff {
                    lowAlphaCount += 1
                }
            }
        }
        
        return lowAlphaCount
    }
}
