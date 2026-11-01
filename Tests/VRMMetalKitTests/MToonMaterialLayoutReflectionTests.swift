// Copyright 2026 Arkavo Inc. and contributors
// Licensed under the Apache License, Version 2.0

import XCTest
import Metal
@testable import VRMMetalKit

/// Compares the Metal-side `MToonMaterial` struct, as the compiled shaders
/// see it through pipeline reflection, with the Swift `MToonMaterialUniforms`
/// stride. Every vertex and fragment entry point that binds the material at
/// `buffer(8)` must agree; a stale copy of the struct in one `.metal` file
/// would otherwise read the newer blocks as garbage on that path only.
final class MToonMaterialLayoutReflectionTests: XCTestCase {
    private static let materialBufferIndex = 8

    func testEveryMToonEntryPointSeesTheSwiftMaterialStride() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        let library = try VRMPipelineCache.shared.getLibrary(device: device)
        let constants = MToonFunctionConstantKey.fallback.makeFunctionConstantValues()
        let swiftStride = MemoryLayout<MToonMaterialUniforms>.stride

        let pairs: [(vertex: String, fragment: String)] = [
            ("mtoon_vertex", "mtoon_fragment_v2"),
            ("skinned_mtoon_vertex", "mtoon_fragment_v2"),
            ("mtoon_outline_vertex", "mtoon_outline_fragment"),
            ("skinned_mtoon_outline_vertex", "mtoon_outline_fragment"),
        ]
        for pair in pairs {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = try library.makeFunction(name: pair.vertex, constantValues: constants)
            descriptor.fragmentFunction = try library.makeFunction(name: pair.fragment, constantValues: constants)
            descriptor.vertexDescriptor = Self.vertexDescriptor()
            descriptor.colorAttachments[0].pixelFormat = .rgba8Unorm
            descriptor.depthAttachmentPixelFormat = .depth32Float

            var reflection: MTLAutoreleasedRenderPipelineReflection?
            _ = try device.makeRenderPipelineState(
                descriptor: descriptor,
                options: [.bindingInfo, .bufferTypeInfo],
                reflection: &reflection)
            let vertexSize = Self.materialSize(in: reflection?.vertexBindings ?? [])
            let fragmentSize = Self.materialSize(in: reflection?.fragmentBindings ?? [])

            XCTAssertNotNil(vertexSize, "\(pair.vertex) does not bind MToonMaterial at buffer(8)")
            if let vertexSize {
                XCTAssertEqual(vertexSize, swiftStride,
                    "\(pair.vertex): Metal MToonMaterial is \(vertexSize) bytes, Swift MToonMaterialUniforms is \(swiftStride)")
            }
            if let fragmentSize {
                XCTAssertEqual(fragmentSize, swiftStride,
                    "\(pair.fragment): Metal MToonMaterial is \(fragmentSize) bytes, Swift MToonMaterialUniforms is \(swiftStride)")
            }
        }
    }

    private static func materialSize(in bindings: [any MTLBinding]) -> Int? {
        for binding in bindings where binding.index == materialBufferIndex && binding.type == .buffer {
            if let buffer = binding as? any MTLBufferBinding {
                return buffer.bufferDataSize
            }
        }
        return nil
    }

    private static func vertexDescriptor() -> MTLVertexDescriptor {
        let descriptor = MTLVertexDescriptor()
        let formats: [MTLVertexFormat] = [.float3, .float3, .float2, .float4, .uint4, .float4]
        let sizes = [12, 12, 8, 16, 16, 16]
        var offset = 0
        for (index, format) in formats.enumerated() {
            descriptor.attributes[index].format = format
            descriptor.attributes[index].offset = offset
            descriptor.attributes[index].bufferIndex = 0
            offset += sizes[index]
        }
        descriptor.layouts[0].stride = offset
        return descriptor
    }
}
