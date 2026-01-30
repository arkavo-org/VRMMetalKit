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
import simd

/// Simple test renderer for Z-fighting detection tests.
/// Renders colored triangles with configurable depth state - no VRM complexity.
@MainActor
final class SimpleTestRenderer {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let pipelineState: MTLRenderPipelineState
    var depthStencilStates: [String: MTLDepthStencilState] = [:]

    let renderWidth: Int
    let renderHeight: Int

    private var colorTexture: MTLTexture!
    private var depthTexture: MTLTexture!
    private var colorReadbackBuffer: MTLBuffer!
    private var depthReadbackBuffer: MTLBuffer!

    var viewMatrix: float4x4 = matrix_identity_float4x4
    var projectionMatrix: float4x4 = matrix_identity_float4x4

    init(device: MTLDevice, width: Int = 256, height: Int = 256) throws {
        self.device = device
        self.renderWidth = width
        self.renderHeight = height

        guard let commandQueue = device.makeCommandQueue() else {
            throw SimpleRendererError.initFailed("Failed to create command queue")
        }
        self.commandQueue = commandQueue

        self.pipelineState = try Self.createPipeline(device: device)
        self.setupDepthStates()
        try self.setupTextures()
        try self.setupReadbackBuffers()
        self.setupDefaultMatrices()
    }

    private static func createPipeline(device: MTLDevice) throws -> MTLRenderPipelineState {
        let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;

        struct VertexIn {
            float3 position [[attribute(0)]];
            float4 color [[attribute(1)]];
        };

        struct VertexOut {
            float4 position [[position]];
            float4 color;
        };

        struct Uniforms {
            float4x4 mvp;
            float depthBias;
        };

        vertex VertexOut simple_vertex(
            VertexIn in [[stage_in]],
            constant Uniforms& uniforms [[buffer(1)]]
        ) {
            VertexOut out;
            out.position = uniforms.mvp * float4(in.position, 1.0);
            out.position.z += uniforms.depthBias;
            out.color = in.color;
            return out;
        }

        fragment float4 simple_fragment(VertexOut in [[stage_in]]) {
            return in.color;
        }
        """

        let library = try device.makeLibrary(source: shaderSource, options: nil)

        guard let vertexFunc = library.makeFunction(name: "simple_vertex"),
              let fragmentFunc = library.makeFunction(name: "simple_fragment") else {
            throw SimpleRendererError.initFailed("Failed to create shader functions")
        }

        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .float3
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = 0
        vertexDescriptor.attributes[1].format = .float4
        vertexDescriptor.attributes[1].offset = MemoryLayout<SIMD3<Float>>.stride
        vertexDescriptor.attributes[1].bufferIndex = 0
        vertexDescriptor.layouts[0].stride = MemoryLayout<SIMD3<Float>>.stride + MemoryLayout<SIMD4<Float>>.stride

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunc
        pipelineDescriptor.fragmentFunction = fragmentFunc
        pipelineDescriptor.vertexDescriptor = vertexDescriptor
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipelineDescriptor.depthAttachmentPixelFormat = .depth32Float

        return try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
    }

    private func setupDepthStates() {
        // Standard depth test - strict .less
        let lessDescriptor = MTLDepthStencilDescriptor()
        lessDescriptor.depthCompareFunction = .less
        lessDescriptor.isDepthWriteEnabled = true
        if let state = device.makeDepthStencilState(descriptor: lessDescriptor) {
            depthStencilStates["less"] = state
        }

        // Permissive depth test - .lessEqual (helps with coplanar surfaces)
        let lessEqualDescriptor = MTLDepthStencilDescriptor()
        lessEqualDescriptor.depthCompareFunction = .lessEqual
        lessEqualDescriptor.isDepthWriteEnabled = true
        if let state = device.makeDepthStencilState(descriptor: lessEqualDescriptor) {
            depthStencilStates["lessEqual"] = state
        }

        // No depth test
        let alwaysDescriptor = MTLDepthStencilDescriptor()
        alwaysDescriptor.depthCompareFunction = .always
        alwaysDescriptor.isDepthWriteEnabled = false
        if let state = device.makeDepthStencilState(descriptor: alwaysDescriptor) {
            depthStencilStates["always"] = state
        }
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
            throw SimpleRendererError.initFailed("Failed to create color texture")
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
            throw SimpleRendererError.initFailed("Failed to create depth texture")
        }
        self.depthTexture = depthTex
    }

    private func setupReadbackBuffers() throws {
        let colorBufferSize = renderWidth * renderHeight * 4
        guard let colorBuffer = device.makeBuffer(length: colorBufferSize, options: .storageModeShared) else {
            throw SimpleRendererError.initFailed("Failed to create color readback buffer")
        }
        self.colorReadbackBuffer = colorBuffer

        let depthBufferSize = renderWidth * renderHeight * MemoryLayout<Float>.stride
        guard let depthBuffer = device.makeBuffer(length: depthBufferSize, options: .storageModeShared) else {
            throw SimpleRendererError.initFailed("Failed to create depth readback buffer")
        }
        self.depthReadbackBuffer = depthBuffer
    }

    private func setupDefaultMatrices() {
        let aspect = Float(renderWidth) / Float(renderHeight)
        projectionMatrix = makePerspectiveProjection(
            fovY: Float.pi / 4,
            aspectRatio: aspect,
            nearZ: 0.01,
            farZ: 100.0
        )

        viewMatrix = makeLookAt(
            eye: SIMD3<Float>(0, 0, 3),
            target: SIMD3<Float>(0, 0, 0),
            up: SIMD3<Float>(0, 1, 0)
        )
    }

    struct DrawCommand {
        let mesh: TestMesh
        let depthBias: Float
        let depthState: String
    }

    /// Render multiple meshes and return color buffer.
    func render(commands: [DrawCommand], viewPerturbation: SIMD3<Float> = .zero) throws -> [UInt8] {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw SimpleRendererError.renderFailed("Failed to create command buffer")
        }

        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = colorTexture
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0.2, green: 0.2, blue: 0.2, alpha: 1.0)
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        renderPassDescriptor.depthAttachment.texture = depthTexture
        renderPassDescriptor.depthAttachment.loadAction = .clear
        renderPassDescriptor.depthAttachment.clearDepth = 1.0
        renderPassDescriptor.depthAttachment.storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            throw SimpleRendererError.renderFailed("Failed to create render encoder")
        }

        encoder.setRenderPipelineState(pipelineState)

        let perturbedView = viewMatrix * makeTranslation(viewPerturbation)
        let vp = projectionMatrix * perturbedView

        for command in commands {
            guard let depthState = depthStencilStates[command.depthState] else { continue }
            encoder.setDepthStencilState(depthState)

            let vertexData = createVertexData(mesh: command.mesh)
            guard let vertexBuffer = device.makeBuffer(bytes: vertexData, length: vertexData.count * MemoryLayout<Float>.stride, options: .storageModeShared) else {
                continue
            }

            var uniforms = SimpleUniforms(mvp: vp, depthBias: command.depthBias)

            encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<SimpleUniforms>.stride, index: 1)

            let indexData = command.mesh.indices
            guard let indexBuffer = device.makeBuffer(bytes: indexData, length: indexData.count * MemoryLayout<UInt16>.stride, options: .storageModeShared) else {
                continue
            }

            encoder.drawIndexedPrimitives(
                type: .triangle,
                indexCount: indexData.count,
                indexType: .uint16,
                indexBuffer: indexBuffer,
                indexBufferOffset: 0
            )
        }

        encoder.endEncoding()

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

    /// Render multiple frames with view perturbations.
    func renderMultipleFrames(commands: [DrawCommand], count: Int, perturbationScale: Float = 0.0001) throws -> [[UInt8]] {
        var frames: [[UInt8]] = []

        for i in 0..<count {
            let perturbation = SIMD3<Float>(Float(i) * perturbationScale, Float(i) * perturbationScale * 0.7, 0)
            let frameData = try render(commands: commands, viewPerturbation: perturbation)
            frames.append(frameData)
        }

        return frames
    }

    private func createVertexData(mesh: TestMesh) -> [Float] {
        var data: [Float] = []
        for i in 0..<mesh.positions.count {
            let pos = mesh.positions[i]
            let color = mesh.color
            data.append(contentsOf: [pos.x, pos.y, pos.z])
            data.append(contentsOf: [color.x, color.y, color.z, color.w])
        }
        return data
    }

    private func readColorBuffer() -> [UInt8] {
        let pixelCount = renderWidth * renderHeight * 4
        let pointer = colorReadbackBuffer.contents().bindMemory(to: UInt8.self, capacity: pixelCount)
        return Array(UnsafeBufferPointer(start: pointer, count: pixelCount))
    }
}

struct SimpleUniforms {
    var mvp: float4x4
    var depthBias: Float
}

enum SimpleRendererError: Error, LocalizedError {
    case initFailed(String)
    case renderFailed(String)

    var errorDescription: String? {
        switch self {
        case .initFailed(let msg): return "Initialization failed: \(msg)"
        case .renderFailed(let msg): return "Render failed: \(msg)"
        }
    }
}
