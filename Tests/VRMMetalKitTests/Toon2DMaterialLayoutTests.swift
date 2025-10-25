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
        let material = Toon2DMaterialCPU()

        // Use withUnsafePointer to check offsets
        withUnsafePointer(to: material) { ptr in
            let baseAddr = UInt(bitPattern: ptr)

            // Block 0: baseColorFactor at offset 0
            withUnsafePointer(to: material.baseColorFactor) { fieldPtr in
                let offset = UInt(bitPattern: fieldPtr) - baseAddr
                XCTAssertEqual(offset, 0, "baseColorFactor should be at offset 0")
            }

            // Block 1: shadeColorFactor at offset 16
            withUnsafePointer(to: material.shadeColorFactor_x) { fieldPtr in
                let offset = UInt(bitPattern: fieldPtr) - baseAddr
                XCTAssertEqual(offset, 16, "shadeColorFactor should be at offset 16")
            }

            // Block 2: shadingToonyFactor at offset 32
            withUnsafePointer(to: material.shadingToonyFactor) { fieldPtr in
                let offset = UInt(bitPattern: fieldPtr) - baseAddr
                XCTAssertEqual(offset, 32, "shadingToonyFactor should be at offset 32")
            }

            // Block 9: rimLiftFactor at offset 144 (9 × 16)
            withUnsafePointer(to: material.rimLiftFactor) { fieldPtr in
                let offset = UInt(bitPattern: fieldPtr) - baseAddr
                XCTAssertEqual(offset, 144, "rimLiftFactor should be at offset 144")
            }

            // Block 11: alphaCutoff at offset 176 (11 × 16)
            withUnsafePointer(to: material.alphaCutoff) { fieldPtr in
                let offset = UInt(bitPattern: fieldPtr) - baseAddr
                XCTAssertEqual(offset, 176, "alphaCutoff should be at offset 176")
            }
        }
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
        // Metal shader has 11 blocks × 16 bytes = 176 bytes total

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
            ("Block 9", "float + 3×int", 16),
            ("Block 10", "uint32_t alphaMode (padded)", 16),
            ("Block 11", "float alphaCutoff (padded)", 16),
        ]

        let totalBytes = blocks.reduce(0) { $0 + $1.2 }
        XCTAssertEqual(totalBytes, 192, "Metal shader layout should be 192 bytes (12 blocks)")

        print("Metal Shader Layout:")
        for (index, block) in blocks.enumerated() {
            print("  \(block.0): \(block.1) = \(block.2) bytes @ offset \(index * 16)")
        }
    }
}
