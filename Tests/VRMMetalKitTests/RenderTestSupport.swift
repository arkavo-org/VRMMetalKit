// Copyright 2025 Arkavo Inc. and contributors
// Licensed under the Apache License, Version 2.0

import XCTest
import Metal
import simd
@testable import VRMMetalKit

enum RenderTestSupport {
    @MainActor
    static func renderFrame(
        renderer: VRMRenderer,
        device: MTLDevice,
        size: Int,
        pixelFormat: MTLPixelFormat,
        clearColor: MTLClearColor
    ) throws -> [UInt8] {
        let colorDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat, width: size, height: size, mipmapped: false)
        colorDesc.usage = [.renderTarget, .shaderRead]
        colorDesc.storageMode = .shared

        let depthDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float, width: size, height: size, mipmapped: false)
        depthDesc.usage = .renderTarget
        depthDesc.storageMode = .private

        guard let colorTex = device.makeTexture(descriptor: colorDesc),
              let depthTex = device.makeTexture(descriptor: depthDesc),
              let queue = device.makeCommandQueue(),
              let cb = queue.makeCommandBuffer() else {
            throw XCTSkip("Could not allocate Metal render targets")
        }

        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = colorTex
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = clearColor
        rpd.colorAttachments[0].storeAction = .store
        rpd.depthAttachment.texture = depthTex
        rpd.depthAttachment.loadAction = .clear
        rpd.depthAttachment.clearDepth = 1.0
        rpd.depthAttachment.storeAction = .dontCare

        renderer.drawOffscreenHeadless(
            to: colorTex, depth: depthTex,
            commandBuffer: cb, renderPassDescriptor: rpd
        )
        cb.commit()
        cb.waitUntilCompleted()

        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        bytes.withUnsafeMutableBytes { buf in
            colorTex.getBytes(buf.baseAddress!, bytesPerRow: size * 4,
                              from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
        }
        return bytes
    }

    static func meanChannelRGBA(
        _ bytes: [UInt8],
        size: Int,
        channel: Int,
        xRange: ClosedRange<Int>,
        yRange: ClosedRange<Int>,
        skippingMagentaClear: Bool = false
    ) -> Float {
        var sum: Float = 0
        var count = 0
        for y in yRange {
            for x in xRange {
                let base = (y * size + x) * 4
                let r = bytes[base], g = bytes[base + 1], b = bytes[base + 2]
                if skippingMagentaClear && r == 255 && g == 0 && b == 255 {
                    continue
                }
                sum += Float(bytes[base + channel]) / 255.0
                count += 1
            }
        }
        return count > 0 ? sum / Float(count) : 0
    }

    static func meanRec709LumaRGBA(
        _ bytes: [UInt8],
        size: Int,
        xRange: ClosedRange<Int>,
        yRange: ClosedRange<Int>
    ) -> Float {
        var sum: Float = 0
        var count = 0
        for y in yRange {
            for x in xRange {
                let base = (y * size + x) * 4
                sum += rec709Luma(r: bytes[base], g: bytes[base + 1], b: bytes[base + 2])
                count += 1
            }
        }
        return count > 0 ? sum / Float(count) : 0
    }

    static func rec709Luma(r: UInt8, g: UInt8, b: UInt8) -> Float {
        (0.2126 * Float(r) + 0.7152 * Float(g) + 0.0722 * Float(b)) / 255.0
    }

    static func makePerspective(
        fovRadians: Float,
        aspect: Float,
        near: Float,
        far: Float
    ) -> matrix_float4x4 {
        let yScale = 1.0 / tan(fovRadians * 0.5)
        let xScale = yScale / aspect
        let zRange = far - near
        return matrix_float4x4(columns: (
            SIMD4<Float>(xScale, 0, 0, 0),
            SIMD4<Float>(0, yScale, 0, 0),
            SIMD4<Float>(0, 0, -(far + near) / zRange, -1),
            SIMD4<Float>(0, 0, -2.0 * far * near / zRange, 0)
        ))
    }

    static func makeLookAt(
        eye: SIMD3<Float>,
        center: SIMD3<Float>,
        up: SIMD3<Float>
    ) -> matrix_float4x4 {
        let f = normalize(center - eye)
        let s = normalize(cross(f, up))
        let u = cross(s, f)
        return matrix_float4x4(columns: (
            SIMD4<Float>(s.x, u.x, -f.x, 0),
            SIMD4<Float>(s.y, u.y, -f.y, 0),
            SIMD4<Float>(s.z, u.z, -f.z, 0),
            SIMD4<Float>(-dot(s, eye), -dot(u, eye), dot(f, eye), 1)
        ))
    }
}
