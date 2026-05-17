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
@testable import GLTFMetalKit

/// Phase 3b skinning acceptance: load a Khronos rigged sample and render
/// it. Catches the full skinned pipeline — JOINTS_0/WEIGHTS_0 parsing,
/// vertex-buffer layout for the skinned variant, per-frame skin palette
/// computation from node world transforms × IBMs, pipeline-state switch
/// on each skinned draw call.
///
/// Test fixtures: `RiggedSimple.glb` and `RiggedFigure.glb` from Khronos
/// glTF-Sample-Assets (CC0). At the rest pose the meshes should render
/// identically to whatever bind pose was authored — non-black pixels
/// across a significant portion of the framebuffer.
final class GLTFSkinningTests: XCTestCase {

    func testLoadsRiggedSimpleAndDetectsSkinning() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available (CI without GPU)")
        }
        guard let url = Bundle.module.url(forResource: "RiggedSimple", withExtension: "glb", subdirectory: "TestData") else {
            throw XCTSkip("RiggedSimple.glb not bundled")
        }

        let loader = GLTFAssetLoader()
        let asset = try await loader.load(from: url, device: device)

        XCTAssertGreaterThan(asset.drawCalls.count, 0, "RiggedSimple.glb should emit at least one draw call.")
        XCTAssertTrue(asset.drawCalls.contains { $0.mesh.isSkinned },
            "RiggedSimple.glb has skinned meshes — at least one draw call should be flagged isSkinned.")
        XCTAssertTrue(asset.drawCalls.contains { ($0.skinPalette?.count ?? 0) > 0 },
            "At least one draw call should carry a non-empty skin palette.")
    }

    func testRendersRiggedSimpleAtBindPose() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available (CI without GPU)")
        }
        guard let url = Bundle.module.url(forResource: "RiggedSimple", withExtension: "glb", subdirectory: "TestData") else {
            throw XCTSkip("RiggedSimple.glb not bundled")
        }
        guard let commandQueue = device.makeCommandQueue() else {
            XCTFail("Could not create command queue"); return
        }

        let renderer = try GLTFRenderer(device: device)
        let loader = GLTFAssetLoader()
        let asset = try await loader.load(from: url, device: device)

        let colorFormat: MTLPixelFormat = .bgra8Unorm
        let depthFormat: MTLPixelFormat = .depth32Float
        let pipelines = try renderer.makePipelineStates(colorFormat: colorFormat, depthFormat: depthFormat)

        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .less
        depthDescriptor.isDepthWriteEnabled = true
        guard let depthState = device.makeDepthStencilState(descriptor: depthDescriptor) else {
            XCTFail("Could not create depth state"); return
        }

        // RiggedSimple is a vertical pillar; camera back + up looks at origin.
        let width = 256
        let height = 256
        let aspect = Float(width) / Float(height)
        let proj = perspectiveProjection(fovY: .pi / 3, aspect: aspect, near: 0.1, far: 100)
        let view = lookAt(eye: SIMD3<Float>(0, 1, 4),
                          target: SIMD3<Float>(0, 0.5, 0),
                          up: SIMD3<Float>(0, 1, 0))
        let scene = GLTFSceneState(
            viewProjection: proj * view,
            cameraPosition: SIMD3<Float>(0, 1, 4),
            lightDirection: normalize(SIMD3<Float>(-0.3, -1.0, -0.4)),
            lightColor: SIMD3<Float>(3, 3, 3)
        )

        let colorDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: colorFormat, width: width, height: height, mipmapped: false
        )
        colorDescriptor.usage = [.renderTarget, .shaderRead]
        colorDescriptor.storageMode = .shared
        guard let colorTexture = device.makeTexture(descriptor: colorDescriptor) else {
            XCTFail("Could not create color texture"); return
        }
        let depthDescriptor2 = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: depthFormat, width: width, height: height, mipmapped: false
        )
        depthDescriptor2.usage = [.renderTarget]
        depthDescriptor2.storageMode = .private
        guard let depthTexture = device.makeTexture(descriptor: depthDescriptor2) else {
            XCTFail("Could not create depth texture"); return
        }

        let renderPass = MTLRenderPassDescriptor()
        renderPass.colorAttachments[0].texture = colorTexture
        renderPass.colorAttachments[0].loadAction = .clear
        renderPass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        renderPass.colorAttachments[0].storeAction = .store
        renderPass.depthAttachment.texture = depthTexture
        renderPass.depthAttachment.loadAction = .clear
        renderPass.depthAttachment.clearDepth = 1.0
        renderPass.depthAttachment.storeAction = .dontCare

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass) else {
            XCTFail("Could not create command buffer/encoder"); return
        }
        renderer.encodeOpaqueDrawCalls(
            asset.drawCalls,
            scene: scene,
            pipelineStates: pipelines,
            depthState: depthState,
            encoder: encoder
        )
        encoder.endEncoding()
        commandBuffer.commit()
        await commandBuffer.completed()

        if let error = commandBuffer.error {
            XCTFail("Command buffer failed: \(error.localizedDescription)")
            return
        }

        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBufferPointer { ptr in
            colorTexture.getBytes(ptr.baseAddress!, bytesPerRow: bytesPerRow,
                                  from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        var lit = 0
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * 4
                if Int(pixels[offset + 0]) + Int(pixels[offset + 1]) + Int(pixels[offset + 2]) > 30 {
                    lit += 1
                }
            }
        }
        let frac = Double(lit) / Double(width * height)
        XCTAssertGreaterThan(frac, 0.01,
            "RiggedSimple.glb produced only \(lit) lit pixels (\(String(format: "%.2f%%", frac * 100))) — skinning pipeline likely broken at bind pose.")
    }

    // MARK: - Helpers (shared with other GLTFMetalKit tests)

    private func perspectiveProjection(fovY: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let y = 1 / tan(fovY * 0.5)
        let x = y / aspect
        let z = far / (near - far)
        return simd_float4x4(
            SIMD4<Float>(x, 0, 0, 0),
            SIMD4<Float>(0, y, 0, 0),
            SIMD4<Float>(0, 0, z, -1),
            SIMD4<Float>(0, 0, z * near, 0)
        )
    }

    private func lookAt(eye: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
        let z = normalize(eye - target)
        let x = normalize(cross(up, z))
        let y = cross(z, x)
        return simd_float4x4(
            SIMD4<Float>(x.x, y.x, z.x, 0),
            SIMD4<Float>(x.y, y.y, z.y, 0),
            SIMD4<Float>(x.z, y.z, z.z, 0),
            SIMD4<Float>(-dot(x, eye), -dot(y, eye), -dot(z, eye), 1)
        )
    }
}
