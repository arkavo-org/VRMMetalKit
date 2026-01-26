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

import Metal
import MetalKit
import simd
@testable import VRMMetalKit

/// Helper class for GPU-based Z-fighting detection tests.
/// Provides infrastructure for rendering frames to textures and reading back data for analysis.
@MainActor
final class ZFightingTestHelper {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let renderer: VRMRenderer

    let renderWidth: Int
    let renderHeight: Int

    private var colorTexture: MTLTexture!
    private var depthTexture: MTLTexture!
    private var colorReadbackBuffer: MTLBuffer!
    private var depthReadbackBuffer: MTLBuffer!

    init(device: MTLDevice, width: Int = 256, height: Int = 256) throws {
        self.device = device
        self.renderWidth = width
        self.renderHeight = height

        guard let commandQueue = device.makeCommandQueue() else {
            throw ZFightingTestError.metalInitializationFailed("Failed to create command queue")
        }
        self.commandQueue = commandQueue

        self.renderer = VRMRenderer(device: device)

        try setupTextures()
        try setupReadbackBuffers()
        setupDefaultMatrices()
    }

    private func setupTextures() throws {
        let colorDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: renderWidth,
            height: renderHeight,
            mipmapped: false
        )
        colorDescriptor.usage = [.renderTarget, .shaderRead]
        colorDescriptor.storageMode = .private

        guard let colorTex = device.makeTexture(descriptor: colorDescriptor) else {
            throw ZFightingTestError.metalInitializationFailed("Failed to create color texture")
        }
        self.colorTexture = colorTex

        let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float,
            width: renderWidth,
            height: renderHeight,
            mipmapped: false
        )
        depthDescriptor.usage = [.renderTarget, .shaderRead]
        depthDescriptor.storageMode = .private

        guard let depthTex = device.makeTexture(descriptor: depthDescriptor) else {
            throw ZFightingTestError.metalInitializationFailed("Failed to create depth texture")
        }
        self.depthTexture = depthTex
    }

    private func setupReadbackBuffers() throws {
        let colorBufferSize = renderWidth * renderHeight * 4
        guard let colorBuffer = device.makeBuffer(length: colorBufferSize, options: .storageModeShared) else {
            throw ZFightingTestError.metalInitializationFailed("Failed to create color readback buffer")
        }
        self.colorReadbackBuffer = colorBuffer

        let depthBufferSize = renderWidth * renderHeight * MemoryLayout<Float>.stride
        guard let depthBuffer = device.makeBuffer(length: depthBufferSize, options: .storageModeShared) else {
            throw ZFightingTestError.metalInitializationFailed("Failed to create depth readback buffer")
        }
        self.depthReadbackBuffer = depthBuffer
    }

    private func setupDefaultMatrices() {
        let aspect = Float(renderWidth) / Float(renderHeight)
        renderer.projectionMatrix = makePerspectiveProjection(
            fovY: Float.pi / 4,
            aspectRatio: aspect,
            nearZ: 0.01,
            farZ: 100.0
        )

        renderer.viewMatrix = makeLookAt(
            eye: SIMD3<Float>(0, 0, 3),
            target: SIMD3<Float>(0, 0, 0),
            up: SIMD3<Float>(0, 1, 0)
        )
    }

    func createRenderPassDescriptor() -> MTLRenderPassDescriptor {
        let descriptor = MTLRenderPassDescriptor()

        descriptor.colorAttachments[0].texture = colorTexture
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1.0)
        descriptor.colorAttachments[0].storeAction = .store

        descriptor.depthAttachment.texture = depthTexture
        descriptor.depthAttachment.loadAction = .clear
        descriptor.depthAttachment.clearDepth = 1.0  // Standard depth: 1.0 = far, 0.0 = near
        descriptor.depthAttachment.storeAction = .store

        return descriptor
    }

    /// Render a single frame and return the color buffer data.
    func renderFrame() throws -> [UInt8] {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw ZFightingTestError.renderFailed("Failed to create command buffer")
        }

        let renderPassDescriptor = createRenderPassDescriptor()

        renderer.drawOffscreenHeadless(
            to: colorTexture,
            depth: depthTexture,
            commandBuffer: commandBuffer,
            renderPassDescriptor: renderPassDescriptor
        )

        if let blitEncoder = commandBuffer.makeBlitCommandEncoder() {
            let bytesPerRow = renderWidth * 4
            blitEncoder.copy(
                from: colorTexture,
                sourceSlice: 0,
                sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(width: renderWidth, height: renderHeight, depth: 1),
                to: colorReadbackBuffer,
                destinationOffset: 0,
                destinationBytesPerRow: bytesPerRow,
                destinationBytesPerImage: bytesPerRow * renderHeight
            )
            blitEncoder.endEncoding()
        }

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        return readColorBuffer()
    }

    /// Render multiple frames with micro-perturbations to trigger Z-fighting.
    func renderMultipleFrames(count: Int, perturbationScale: Float = 0.00001) throws -> [[UInt8]] {
        var frames: [[UInt8]] = []
        let baseViewMatrix = renderer.viewMatrix

        for i in 0..<count {
            let perturbation = Float(i) * perturbationScale
            renderer.viewMatrix = baseViewMatrix * makeTranslation(SIMD3<Float>(perturbation, 0, 0))

            let frameData = try renderFrame()
            frames.append(frameData)
        }

        renderer.viewMatrix = baseViewMatrix
        return frames
    }

    /// Render and read depth buffer values.
    func renderAndReadDepth() throws -> [Float] {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw ZFightingTestError.renderFailed("Failed to create command buffer")
        }

        let renderPassDescriptor = createRenderPassDescriptor()

        renderer.drawOffscreenHeadless(
            to: colorTexture,
            depth: depthTexture,
            commandBuffer: commandBuffer,
            renderPassDescriptor: renderPassDescriptor
        )

        if let blitEncoder = commandBuffer.makeBlitCommandEncoder() {
            let bytesPerRow = renderWidth * MemoryLayout<Float>.stride
            blitEncoder.copy(
                from: depthTexture,
                sourceSlice: 0,
                sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(width: renderWidth, height: renderHeight, depth: 1),
                to: depthReadbackBuffer,
                destinationOffset: 0,
                destinationBytesPerRow: bytesPerRow,
                destinationBytesPerImage: bytesPerRow * renderHeight
            )
            blitEncoder.endEncoding()
        }

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        return readDepthBuffer()
    }

    private func readColorBuffer() -> [UInt8] {
        let pixelCount = renderWidth * renderHeight * 4
        let pointer = colorReadbackBuffer.contents().bindMemory(to: UInt8.self, capacity: pixelCount)
        return Array(UnsafeBufferPointer(start: pointer, count: pixelCount))
    }

    private func readDepthBuffer() -> [Float] {
        let pixelCount = renderWidth * renderHeight
        let pointer = depthReadbackBuffer.contents().bindMemory(to: Float.self, capacity: pixelCount)
        return Array(UnsafeBufferPointer(start: pointer, count: pixelCount))
    }

    func loadModel(_ model: VRMModel) {
        renderer.loadModel(model)
    }

    func setViewMatrix(_ matrix: float4x4) {
        renderer.viewMatrix = matrix
    }

    func setProjectionMatrix(_ matrix: float4x4) {
        renderer.projectionMatrix = matrix
    }
}

// MARK: - Matrix Helpers

func makePerspectiveProjection(fovY: Float, aspectRatio: Float, nearZ: Float, farZ: Float) -> float4x4 {
    let y = 1 / tan(fovY * 0.5)
    let x = y / aspectRatio
    let z = farZ / (nearZ - farZ)

    return float4x4(columns: (
        SIMD4<Float>(x, 0, 0, 0),
        SIMD4<Float>(0, y, 0, 0),
        SIMD4<Float>(0, 0, z, -1),
        SIMD4<Float>(0, 0, z * nearZ, 0)
    ))
}

func makeLookAt(eye: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float>) -> float4x4 {
    let z = normalize(eye - target)
    let x = normalize(cross(up, z))
    let y = cross(z, x)

    return float4x4(columns: (
        SIMD4<Float>(x.x, y.x, z.x, 0),
        SIMD4<Float>(x.y, y.y, z.y, 0),
        SIMD4<Float>(x.z, y.z, z.z, 0),
        SIMD4<Float>(-dot(x, eye), -dot(y, eye), -dot(z, eye), 1)
    ))
}

func makeTranslation(_ translation: SIMD3<Float>) -> float4x4 {
    return float4x4(columns: (
        SIMD4<Float>(1, 0, 0, 0),
        SIMD4<Float>(0, 1, 0, 0),
        SIMD4<Float>(0, 0, 1, 0),
        SIMD4<Float>(translation.x, translation.y, translation.z, 1)
    ))
}

// MARK: - Errors

enum ZFightingTestError: Error, LocalizedError {
    case metalInitializationFailed(String)
    case renderFailed(String)
    case textureReadbackFailed(String)

    var errorDescription: String? {
        switch self {
        case .metalInitializationFailed(let message):
            return "Metal initialization failed: \(message)"
        case .renderFailed(let message):
            return "Render failed: \(message)"
        case .textureReadbackFailed(let message):
            return "Texture readback failed: \(message)"
        }
    }
}
