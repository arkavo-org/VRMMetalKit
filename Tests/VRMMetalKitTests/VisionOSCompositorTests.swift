//
// Copyright 2026 Arkavo
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

final class VisionOSCompositorTests: XCTestCase {

    func testStereoViewMatricesOffsetByHalfIPD() {
        let center = matrix_identity_float4x4
        let pair = VisionOSStereoLayout.viewMatrices(center: center)
        XCTAssertEqual(pair.right.columns.3.x - pair.left.columns.3.x,
                       VisionOSStereoLayout.ipd, accuracy: 0.0001)
        XCTAssertEqual(VisionOSStereoLayout.frameBudgetMs, 1000.0 / 90.0, accuracy: 0.001)
    }

    func testCompositorViewTargetStoresMatrices() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device not available")
        }
        let color = try XCTUnwrap(device.makeTexture(descriptor: Self.colorDesc))
        let depth = try XCTUnwrap(device.makeTexture(descriptor: Self.depthDesc))
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = color
        rpd.depthAttachment.texture = depth
        var view = matrix_identity_float4x4
        view.columns.3.x = 0.0315
        let target = CompositorViewTarget(
            colorTexture: color,
            depthTexture: depth,
            renderPassDescriptor: rpd,
            viewMatrix: view,
            projectionMatrix: matrix_identity_float4x4)
        XCTAssertEqual(target.viewMatrix.columns.3.x, 0.0315, accuracy: 0.0001)
        XCTAssertTrue(target.colorTexture === color)
    }

    func testEncodeCompositorViewsWithEmptyListIsANoOp() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device not available")
        }
        let renderer = VRMRenderer(device: device, config: RendererConfig())
        guard let queue = device.makeCommandQueue(),
              let cb = queue.makeCommandBuffer() else {
            throw XCTSkip("Command queue unavailable")
        }
        renderer.encodeCompositorViews(commandBuffer: cb, views: [])
        cb.commit()
        cb.waitUntilCompleted()
        XCTAssertEqual(cb.status, .completed)
    }

    func testEncodeCompositorViewsTwoViewsDoesNotDeadlock() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device not available")
        }
        let renderer = VRMRenderer(device: device, config: RendererConfig(strict: .off))
        renderer.useReverseZ = true
        let color0 = try XCTUnwrap(device.makeTexture(descriptor: Self.colorDesc))
        let color1 = try XCTUnwrap(device.makeTexture(descriptor: Self.colorDesc))
        let depth0 = try XCTUnwrap(device.makeTexture(descriptor: Self.depthDesc))
        let depth1 = try XCTUnwrap(device.makeTexture(descriptor: Self.depthDesc))
        func pass(_ color: MTLTexture, _ depth: MTLTexture) -> MTLRenderPassDescriptor {
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = color
            rpd.colorAttachments[0].loadAction = .clear
            rpd.colorAttachments[0].storeAction = .store
            rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            rpd.depthAttachment.texture = depth
            rpd.depthAttachment.loadAction = .clear
            rpd.depthAttachment.storeAction = .store
            rpd.depthAttachment.clearDepth = 0
            return rpd
        }
        let views = [
            CompositorViewTarget(
                colorTexture: color0, depthTexture: depth0,
                renderPassDescriptor: pass(color0, depth0),
                viewMatrix: matrix_identity_float4x4,
                projectionMatrix: matrix_identity_float4x4),
            CompositorViewTarget(
                colorTexture: color1, depthTexture: depth1,
                renderPassDescriptor: pass(color1, depth1),
                viewMatrix: matrix_identity_float4x4,
                projectionMatrix: matrix_identity_float4x4),
        ]
        guard let queue = device.makeCommandQueue(),
              let cb = queue.makeCommandBuffer() else {
            throw XCTSkip("Command queue unavailable")
        }
        renderer.encodeCompositorViews(commandBuffer: cb, views: views)
        cb.commit()
        cb.waitUntilCompleted()
        XCTAssertNotEqual(cb.status, .error)
        XCTAssertEqual(renderer.frameCounter, 1,
                       "preferred submit must count one compositor frame, not one per eye")
    }

    func testEncodeCompositorViewsUsesDistinctPerEyeMatricesForSkinnedDraws() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device not available")
        }
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let modelURL = repoRoot.appendingPathComponent("AvatarSample_A_1.0.vrm.glb")
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw XCTSkip("AvatarSample_A_1.0.vrm.glb not present at repo root")
        }

        let model = try await VRMModel.load(from: modelURL, device: device)
        let renderer = VRMRenderer(device: device, config: RendererConfig(strict: .off))
        renderer.loadModel(model)
        renderer.isAnimationActive = false

        let width = 128
        let height = 128
        func makeColorTexture() throws -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm_srgb, width: width, height: height, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .shared
            return try XCTUnwrap(device.makeTexture(descriptor: d))
        }
        func makeDepthTexture() throws -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .depth32Float, width: width, height: height, mipmapped: false)
            d.usage = .renderTarget
            d.storageMode = .private
            return try XCTUnwrap(device.makeTexture(descriptor: d))
        }
        func makePass(_ color: MTLTexture, _ depth: MTLTexture) -> MTLRenderPassDescriptor {
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = color
            rpd.colorAttachments[0].loadAction = .clear
            rpd.colorAttachments[0].storeAction = .store
            rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            rpd.depthAttachment.texture = depth
            rpd.depthAttachment.loadAction = .clear
            rpd.depthAttachment.storeAction = .store
            rpd.depthAttachment.clearDepth = 1.0
            return rpd
        }
        func readPixels(_ texture: MTLTexture) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            texture.getBytes(
                &bytes,
                bytesPerRow: width * 4,
                from: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0)
            return bytes
        }

        let proj = makePerspective(fovRadians: .pi / 3, aspect: 1.0, near: 0.1, far: 100.0)
        let leftView = makeLookAt(eye: SIMD3<Float>(-0.35, 1.35, 1.8), target: SIMD3<Float>(0, 1.3, 0))
        let rightView = makeLookAt(eye: SIMD3<Float>(0.35, 1.35, 1.8), target: SIMD3<Float>(0, 1.3, 0))

        guard let queue = device.makeCommandQueue() else {
            throw XCTSkip("Command queue unavailable")
        }

        // 1. Render both eyes in a single stereo compositor command buffer
        let stereoLeft = try makeColorTexture()
        let stereoRight = try makeColorTexture()
        let stereoDepthLeft = try makeDepthTexture()
        let stereoDepthRight = try makeDepthTexture()
        let cbStereo = try XCTUnwrap(queue.makeCommandBuffer())
        renderer.encodeCompositorViews(commandBuffer: cbStereo, views: [
            CompositorViewTarget(
                colorTexture: stereoLeft, depthTexture: stereoDepthLeft,
                renderPassDescriptor: makePass(stereoLeft, stereoDepthLeft),
                viewMatrix: leftView, projectionMatrix: proj),
            CompositorViewTarget(
                colorTexture: stereoRight, depthTexture: stereoDepthRight,
                renderPassDescriptor: makePass(stereoRight, stereoDepthRight),
                viewMatrix: rightView, projectionMatrix: proj),
        ])
        cbStereo.commit()
        await cbStereo.completed()
        XCTAssertEqual(cbStereo.status, .completed)

        // 2. Render each eye standalone via drawOffscreen as ground truth
        let refLeft = try makeColorTexture()
        let refRight = try makeColorTexture()
        let refDepthLeft = try makeDepthTexture()
        let refDepthRight = try makeDepthTexture()

        let cbLeft = try XCTUnwrap(queue.makeCommandBuffer())
        renderer.viewMatrix = leftView
        renderer.projectionMatrix = proj
        renderer.drawOffscreen(to: refLeft, depth: refDepthLeft, commandBuffer: cbLeft, renderPassDescriptor: makePass(refLeft, refDepthLeft))
        cbLeft.commit()
        await cbLeft.completed()

        let cbRight = try XCTUnwrap(queue.makeCommandBuffer())
        renderer.viewMatrix = rightView
        renderer.projectionMatrix = proj
        renderer.drawOffscreen(to: refRight, depth: refDepthRight, commandBuffer: cbRight, renderPassDescriptor: makePass(refRight, refDepthRight))
        cbRight.commit()
        await cbRight.completed()

        let stereoLeftPx = readPixels(stereoLeft)
        let stereoRightPx = readPixels(stereoRight)
        let refLeftPx = readPixels(refLeft)
        let refRightPx = readPixels(refRight)

        let nonZeroLeft = stereoLeftPx.filter { $0 != 0 }.count
        XCTAssertGreaterThan(nonZeroLeft, 1000, "Left eye must contain rendered avatar pixels")

        let leftVsRightDiff = zip(stereoLeftPx, stereoRightPx).filter { abs(Int($0) - Int($1)) > 2 }.count
        XCTAssertGreaterThan(leftVsRightDiff, 1000,
                             "Left and right eyes must differ; if identical, eye 0 read eye 1's overwritten uniform buffer")

        let leftVsRefDiff = zip(stereoLeftPx, refLeftPx).filter { abs(Int($0) - Int($1)) > 1 }.count
        let rightVsRefDiff = zip(stereoRightPx, refRightPx).filter { abs(Int($0) - Int($1)) > 1 }.count
        XCTAssertEqual(leftVsRefDiff, 0, "Compositor left eye must match standalone drawOffscreen left eye")
        XCTAssertEqual(rightVsRefDiff, 0, "Compositor right eye must match standalone drawOffscreen right eye")
    }

    private func makePerspective(fovRadians: Float, aspect: Float, near: Float, far: Float) -> float4x4 {
        let yScale = 1 / tan(fovRadians * 0.5)
        let xScale = yScale / aspect
        let zRange = far - near
        let zScale = -(far + near) / zRange
        let wzScale = -2 * far * near / zRange
        return float4x4(columns: (
            SIMD4<Float>(xScale, 0, 0, 0),
            SIMD4<Float>(0, yScale, 0, 0),
            SIMD4<Float>(0, 0, zScale, -1),
            SIMD4<Float>(0, 0, wzScale, 0)
        ))
    }

    private func makeLookAt(eye: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float> = SIMD3<Float>(0, 1, 0)) -> float4x4 {
        let z = simd_normalize(eye - target)
        let x = simd_normalize(simd_cross(up, z))
        let y = simd_cross(z, x)
        return float4x4(columns: (
            SIMD4<Float>(x.x, y.x, z.x, 0),
            SIMD4<Float>(x.y, y.y, z.y, 0),
            SIMD4<Float>(x.z, y.z, z.z, 0),
            SIMD4<Float>(-simd_dot(x, eye), -simd_dot(y, eye), -simd_dot(z, eye), 1)
        ))
    }

    private static var colorDesc: MTLTextureDescriptor {
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb, width: 64, height: 64, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        return d
    }

    private static var depthDesc: MTLTextureDescriptor {
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float, width: 64, height: 64, mipmapped: false)
        d.usage = .renderTarget
        d.storageMode = .private
        return d
    }
}
