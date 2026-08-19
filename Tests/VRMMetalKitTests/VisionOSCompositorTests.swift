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
