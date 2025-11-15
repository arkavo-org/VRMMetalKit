import XCTest
@testable import VRMMetalKit

/// Tests to validate Toon2DMaterialCPU struct layout matches Metal shader expectations
final class Toon2DMaterialLayoutTests: XCTestCase {

    func testStructSize() {
        let expectedSize = 176  // 11 × 16-byte blocks
        let actualSize = MemoryLayout<Toon2DMaterialCPU>.size

        XCTAssertEqual(actualSize, expectedSize,
                      "Toon2DMaterialCPU size mismatch! Expected \(expectedSize) bytes, got \(actualSize) bytes. " +
                      "This struct must match the Metal shader's memory layout exactly.")
    }

    func testStructStride() {
        let expectedStride = 176  // Should be 16-byte aligned
        let actualStride = MemoryLayout<Toon2DMaterialCPU>.stride

        XCTAssertEqual(actualStride, expectedStride,
                      "Toon2DMaterialCPU stride mismatch! Expected \(expectedStride) bytes, got \(actualStride) bytes.")
    }

    func testToBytesLength() {
        let material = Toon2DMaterialCPU()
        let bytes = material.toBytes()
        let expectedLength = 176

        XCTAssertEqual(bytes.count, expectedLength,
                      "toBytes() returned wrong size! Expected \(expectedLength) bytes, got \(bytes.count) bytes.")
    }

    func testBlockAlignment() {
        // Each field should be at a specific offset
        // Use MemoryLayout.offset which is safer than pointer arithmetic

        // Block 0: baseColorFactor at offset 0
        let offset0 = MemoryLayout<Toon2DMaterialCPU>.offset(of: \Toon2DMaterialCPU.baseColorFactor)!
        XCTAssertEqual(offset0, 0, "baseColorFactor should be at offset 0")

        // Block 1: shadeColorFactor at offset 16
        let offset1 = MemoryLayout<Toon2DMaterialCPU>.offset(of: \Toon2DMaterialCPU.shadeColorFactor_x)!
        XCTAssertEqual(offset1, 16, "shadeColorFactor should be at offset 16")

        // Block 2: shadingToonyFactor at offset 32
        let offset2 = MemoryLayout<Toon2DMaterialCPU>.offset(of: \Toon2DMaterialCPU.shadingToonyFactor)!
        XCTAssertEqual(offset2, 32, "shadingToonyFactor should be at offset 32")

        // Block 9: rimLiftFactor at offset 144 (9 × 16)
        let offset9 = MemoryLayout<Toon2DMaterialCPU>.offset(of: \Toon2DMaterialCPU.rimLiftFactor)!
        XCTAssertEqual(offset9, 144, "rimLiftFactor should be at offset 144")

        // Block 10: alphaCutoff at offset 164 (160 + 4 for alphaMode)
        let offset10 = MemoryLayout<Toon2DMaterialCPU>.offset(of: \Toon2DMaterialCPU.alphaCutoff)!
        XCTAssertEqual(offset10, 164, "alphaCutoff should be at offset 164")
    }

    func testConvenienceAccessors() {
        var material = Toon2DMaterialCPU()

        // Test shadeColorFactor accessor
        material.shadeColorFactor = SIMD3<Float>(0.1, 0.2, 0.3)
        XCTAssertEqual(material.shadeColorFactor_x, 0.1)
        XCTAssertEqual(material.shadeColorFactor_y, 0.2)
        XCTAssertEqual(material.shadeColorFactor_z, 0.3)
        XCTAssertEqual(material.shadeColorFactor, SIMD3<Float>(0.1, 0.2, 0.3))

        // Test emissiveFactor accessor
        material.emissiveFactor = SIMD3<Float>(0.4, 0.5, 0.6)
        XCTAssertEqual(material.emissiveFactor_x, 0.4)
        XCTAssertEqual(material.emissiveFactor_y, 0.5)
        XCTAssertEqual(material.emissiveFactor_z, 0.6)
        XCTAssertEqual(material.emissiveFactor, SIMD3<Float>(0.4, 0.5, 0.6))
    }

    func testMetalCompatibility() {
        // This test documents the Metal shader struct layout
        // Metal shader has 10 blocks × 16 bytes = 160 bytes, plus final block with alphaMode+alphaCutoff = 176 bytes total

        let blocks = [
            ("Block 0", "float4 baseColorFactor", 16),
            ("Block 1", "float3 shadeColorFactor (padded)", 16),
            ("Block 2", "float shadingToonyFactor (padded)", 16),
            ("Block 3", "float3 emissiveFactor (padded)", 16),
            ("Block 4", "float outlineWidth (padded)", 16),
            ("Block 5", "float3 outlineColorFactor (padded)", 16),
            ("Block 6", "float outlineMode (padded)", 16),
            ("Block 7", "float3 rimColorFactor (padded)", 16),
            ("Block 8", "float rimFresnelPower (padded)", 16),
            ("Block 9", "float rimLiftFactor + 3×int32", 16),
            ("Block 10", "uint32_t alphaMode + float alphaCutoff + padding", 16),
        ]

        let totalBytes = blocks.reduce(0) { $0 + $1.2 }
        XCTAssertEqual(totalBytes, 176, "Metal shader layout should be 176 bytes (11 blocks)")

        print("Metal Shader Layout:")
        for (index, block) in blocks.enumerated() {
            print("  \(block.0): \(block.1) = \(block.2) bytes @ offset \(index * 16)")
        }
    }
}
