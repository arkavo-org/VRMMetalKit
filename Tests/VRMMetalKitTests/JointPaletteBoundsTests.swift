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

/// The skinned vertex shader clamps every incoming joint index to
/// `VRMConstants.Animation.maxJointCount - 1` as a last resort, then indexes
/// the joint-matrix buffer — which is bound at *each skin's* slice base
/// (`VRMSkin.matrixOffset`), not at 0. The palette must therefore cover
/// `lastSkinOffset + maxJointCount` matrices, and every draw site that binds a
/// slice must skip primitives whose `requiredPaletteSize` exceeds the bound
/// skin's joint count.
@MainActor
final class JointPaletteBoundsTests: XCTestCase {

    private var device: MTLDevice!

    private func ensureDevice() throws {
        if device != nil { return }
        guard let dev = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available on this host")
        }
        device = dev
    }

    private static let stride = MemoryLayout<float4x4>.stride

    // MARK: - (a) Shared palette padding

    /// Multi-skin layout: the clamp target of the *last* skin's slice must be
    /// inside the buffer, not just the first skin's.
    func testPaletteCoversClampIndexForEverySkinSlice() throws {
        try ensureDevice()
        let system = VRMSkinningSystem(device: device)
        let skins = (0..<4).map { makeSkin(name: "skin\($0)", jointCount: 144) }
        system.setupForSkins(skins)

        let buffer = try XCTUnwrap(system.getJointMatricesBuffer())
        let lastOffset = try XCTUnwrap(skins.map(\.matrixOffset).max())
        let requiredMatrices = lastOffset + VRMConstants.Animation.maxJointCount

        XCTAssertGreaterThanOrEqual(
            buffer.length, requiredMatrices * Self.stride,
            "Palette must cover lastSkinOffset (\(lastOffset)) + the shader clamp index " +
            "(\(VRMConstants.Animation.maxJointCount - 1)); a clamped read from the last " +
            "skin's slice base runs past the end otherwise")
    }

    /// Tightest boundary: a trailing zero-joint skin sits at
    /// `matrixOffset == totalMatrixCount`, so the clamp needs the full
    /// `maxJointCount` tail past the live matrices.
    func testPaletteCoversClampIndexForTrailingZeroJointSkin() throws {
        try ensureDevice()
        let system = VRMSkinningSystem(device: device)
        let skins = [makeSkin(name: "real", jointCount: 3), makeSkin(name: "empty", jointCount: 0)]
        system.setupForSkins(skins)

        let buffer = try XCTUnwrap(system.getJointMatricesBuffer())
        XCTAssertEqual(skins[1].matrixOffset, 3, "Zero-joint skin must sit at the end of the live range")
        let requiredMatrices = skins[1].matrixOffset + VRMConstants.Animation.maxJointCount

        XCTAssertGreaterThanOrEqual(
            buffer.length, requiredMatrices * Self.stride,
            "A zero-joint skin binds at the very end of the live matrices; the clamp tail " +
            "must still be in-bounds")
    }

    /// The tail must be identity so an accidental clamped read yields
    /// un-transformed geometry rather than garbage.
    func testPaletteTailIsIdentity() throws {
        try ensureDevice()
        let system = VRMSkinningSystem(device: device)
        let skins = [makeSkin(name: "a", jointCount: 5), makeSkin(name: "b", jointCount: 7)]
        system.setupForSkins(skins)
        for (index, skin) in skins.enumerated() {
            system.updateJointMatrices(for: skin, skinIndex: index)
        }

        let buffer = try XCTUnwrap(system.getJointMatricesBuffer())
        let count = buffer.length / Self.stride
        let liveCount = 12
        XCTAssertGreaterThan(count, liveCount, "Palette must carry a padding tail")

        let pointer = buffer.contents().bindMemory(to: float4x4.self, capacity: count)
        for i in liveCount..<count {
            XCTAssertEqual(pointer[i], matrix_identity_float4x4,
                           "Padding matrix \(i) must be identity, got \(pointer[i])")
        }
    }

    /// Existing floor: with no skins at all the palette still covers the clamp range.
    func testEmptySkinListKeepsClampFloor() throws {
        try ensureDevice()
        let system = VRMSkinningSystem(device: device)
        system.setupForSkins([])

        let buffer = try XCTUnwrap(system.getJointMatricesBuffer())
        XCTAssertGreaterThanOrEqual(buffer.length,
                                    VRMConstants.Animation.maxJointCount * Self.stride)
    }

    // MARK: - (b) Draw-site palette guards

    /// The depth prepass binds a per-skin palette slice with no fragment shader,
    /// so a primitive whose `requiredPaletteSize` exceeds the bound skin's joint
    /// count reads past that slice. The prepass must skip such draws — proven by
    /// the depth buffer staying at its clear value while the main pass (which
    /// already guards) contributes nothing.
    func testDepthPrepassSkipsDrawWhenPaletteTooSmall() throws {
        try ensureDevice()

        // Control 1: matching palette, prepass on — depth must be written
        // (proves the prepass path and the depth readback both work).
        let matched = try makeSkinnedTriangleModel(requiredPaletteSize: 1, outlineMaterial: false)
        let matchedDepth = try renderDepth(model: matched, depthPrepass: true)
        XCTAssertTrue(matchedDepth.contains { $0 < 0.999 },
                      "Scaffolding invalid: a well-formed skinned triangle wrote no depth")

        // Control 2: oversized palette, prepass off — the main pass's existing
        // guard skips the draw, so any depth in the subject case comes from the
        // prepass alone.
        let oversizedNoPrepass = try makeSkinnedTriangleModel(requiredPaletteSize: 2, outlineMaterial: false)
        let noPrepassDepth = try renderDepth(model: oversizedNoPrepass, depthPrepass: false)
        XCTAssertFalse(noPrepassDepth.contains { $0 < 0.999 },
                       "Main pass should already skip an oversized-palette draw")

        // Subject: oversized palette, prepass on.
        let oversized = try makeSkinnedTriangleModel(requiredPaletteSize: 2, outlineMaterial: false)
        let prepassDepth = try renderDepth(model: oversized, depthPrepass: true)
        let written = prepassDepth.filter { $0 < 0.999 }.count
        XCTAssertEqual(written, 0,
                       "Depth prepass drew a primitive whose requiredPaletteSize (2) exceeds the " +
                       "bound skin's joint count (1) — \(written) depth samples written; the " +
                       "prepass binds the skin slice with no palette-size guard")
    }

    /// The MToon outline pass binds the same per-skin slice and must skip the
    /// same draws. Observed through the draw-call counter: with the guard the
    /// oversized model issues no draws at all (the main pass already skips it).
    func testOutlinePassSkipsDrawWhenPaletteTooSmall() throws {
        try ensureDevice()

        let matched = try makeSkinnedTriangleModel(requiredPaletteSize: 1, outlineMaterial: true)
        let matchedDraws = try renderCountingDraws(model: matched)
        XCTAssertGreaterThanOrEqual(matchedDraws, 2,
            "Scaffolding invalid: expected a main-pass draw plus a dedicated outline draw, got \(matchedDraws)")

        let oversized = try makeSkinnedTriangleModel(requiredPaletteSize: 2, outlineMaterial: true)
        let oversizedDraws = try renderCountingDraws(model: oversized)
        XCTAssertEqual(oversizedDraws, 0,
                       "Outline pass drew a primitive whose requiredPaletteSize (2) exceeds the " +
                       "bound skin's joint count (1) — \(oversizedDraws) draws issued")
    }

    // MARK: - Builders

    private func makeSkin(name: String, jointCount: Int) -> VRMSkin {
        let skin = VRMSkin(name: name)
        skin.joints = (0..<jointCount).map { makeNode(index: $0, name: "\(name)_j\($0)") }
        skin.inverseBindMatrices = Array(repeating: matrix_identity_float4x4, count: jointCount)
        return skin
    }

    private func makeNode(index: Int, name: String) -> VRMNode {
        let json = "{\"name\":\"\(name)\"}"
        // swiftlint:disable:next force_try
        let gltfNode = try! JSONDecoder().decode(GLTFNode.self, from: json.data(using: .utf8)!)
        return VRMNode(index: index, gltfNode: gltfNode)
    }

    /// Single skinned triangle in the middle of NDC, bound to a one-joint skin.
    /// `requiredPaletteSize` is set independently of the actual joint indices so
    /// the mismatch (bad model data) can be exercised without out-of-range
    /// vertex data.
    private func makeSkinnedTriangleModel(requiredPaletteSize: Int, outlineMaterial: Bool) throws -> VRMModel {
        let gltfJSON = """
        {"asset":{"version":"2.0"},"scene":0,"scenes":[{"nodes":[0]}],\
        "nodes":[{"name":"root"},{"name":"joint"},{"name":"mesh_node"}]}
        """
        let gltf = try JSONDecoder().decode(GLTFDocument.self, from: gltfJSON.data(using: .utf8)!)
        let model = VRMModel(
            specVersion: .v1_0,
            meta: VRMMeta(licenseUrl: "https://vrm.dev/licenses/1.0/"),
            humanoid: nil,
            gltf: gltf
        )
        for (i, gltfNode) in (gltf.nodes ?? []).enumerated() {
            model.nodes.append(VRMNode(index: i, gltfNode: gltfNode))
        }
        let nodes = model.nodes
        nodes[1].parent = nodes[0]
        nodes[0].children.append(nodes[1])
        nodes[2].parent = nodes[0]
        nodes[0].children.append(nodes[2])
        nodes[2].mesh = 0
        nodes[2].skin = 0
        nodes[0].updateWorldTransform()

        let skin = VRMSkin(name: "one_joint")
        skin.joints = [nodes[1]]
        skin.inverseBindMatrices = [matrix_identity_float4x4]
        model.skins = [skin]

        if outlineMaterial {
            let materialJSON = #"{"name":"outlined","doubleSided":true}"#
            let gltfMaterial = try JSONDecoder().decode(GLTFMaterial.self, from: materialJSON.data(using: .utf8)!)
            let material = VRMMaterial(from: gltfMaterial, textures: [])
            var mtoon = VRMMToonMaterial()
            mtoon.outlineWidthMode = .worldCoordinates
            mtoon.outlineWidthFactor = 0.05
            mtoon.outlineColorFactor = SIMD3<Float>(0, 0, 0)
            material.mtoon = mtoon
            material.doubleSided = true
            model.materials = [material]
        }

        let mesh = VRMMesh(name: "tri")
        let primitive = VRMPrimitive()
        var verts = [VRMVertex(), VRMVertex(), VRMVertex()]
        verts[0].position = SIMD3<Float>(-0.4, -0.4, 0)
        verts[1].position = SIMD3<Float>( 0.4, -0.4, 0)
        verts[2].position = SIMD3<Float>( 0.0,  0.4, 0)
        for i in 0..<3 {
            verts[i].normal = SIMD3<Float>(0, 0, 1)
            verts[i].texCoord = SIMD2<Float>(0, 0)
            verts[i].color = SIMD4<Float>(1, 1, 1, 1)
            verts[i].joints = SIMD4<UInt32>(0, 0, 0, 0)
            verts[i].weights = SIMD4<Float>(1, 0, 0, 0)
        }
        primitive.uploadVertices(verts, device: device)
        primitive.localMin = SIMD3<Float>(-0.4, -0.4, 0)
        primitive.localMax = SIMD3<Float>( 0.4,  0.4, 0)
        let indices: [UInt16] = [0, 1, 2]
        primitive.indexBuffer = device.makeBuffer(
            bytes: indices, length: 3 * MemoryLayout<UInt16>.stride, options: .storageModeShared)
        primitive.indexCount = 3
        primitive.indexType = .uint16
        primitive.indexBufferOffset = 0
        primitive.primitiveType = .triangle
        primitive.hasNormals = true
        primitive.hasJoints = true
        primitive.hasWeights = true
        primitive.requiredPaletteSize = requiredPaletteSize
        primitive.materialIndex = outlineMaterial ? 0 : nil
        mesh.primitives = [primitive]
        model.meshes = [mesh]

        return model
    }

    // MARK: - Offscreen render helpers

    private static let renderSize = 64

    private func makeRenderer(model: VRMModel, depthPrepass: Bool) -> VRMRenderer {
        var config = RendererConfig()
        config.sampleCount = 1
        config.strict = .off
        config.enableDepthPrepass = depthPrepass
        let renderer = VRMRenderer(device: device, config: config)
        renderer.performanceTracker = PerformanceTracker()
        renderer.loadModel(model)
        renderer.viewMatrix = matrix_identity_float4x4
        renderer.projectionMatrix = matrix_identity_float4x4
        return renderer
    }

    /// Renders one frame and returns the depth attachment contents.
    ///
    /// The depth target is private and comes back through a blit into a shared
    /// buffer rather than `getBytes`. A CPU-visible depth texture is invalid on
    /// iOS: `MTLTextureDescriptor` validation aborts the process inside
    /// `makeTexture` instead of returning nil, so there is nothing to guard on.
    private func renderDepth(model: VRMModel, depthPrepass: Bool) throws -> [Float] {
        let renderer = makeRenderer(model: model, depthPrepass: depthPrepass)
        let size = Self.renderSize
        let bytesPerRow = size * MemoryLayout<Float>.stride

        let colorDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: size, height: size, mipmapped: false)
        colorDesc.usage = [.renderTarget, .shaderRead]
        colorDesc.storageMode = .shared
        let depthDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float, width: size, height: size, mipmapped: false)
        depthDesc.usage = .renderTarget
        depthDesc.storageMode = .private

        guard let colorTex = device.makeTexture(descriptor: colorDesc),
              let depthTex = device.makeTexture(descriptor: depthDesc),
              let readback = device.makeBuffer(length: bytesPerRow * size, options: .storageModeShared),
              let queue = device.makeCommandQueue(),
              let cb = queue.makeCommandBuffer() else {
            throw XCTSkip("Could not allocate render targets on this device")
        }

        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = colorTex
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 1, green: 0, blue: 1, alpha: 1)
        rpd.colorAttachments[0].storeAction = .store
        rpd.depthAttachment.texture = depthTex
        rpd.depthAttachment.loadAction = .clear
        rpd.depthAttachment.clearDepth = 1.0
        rpd.depthAttachment.storeAction = .store

        renderer.drawOffscreenHeadless(
            to: colorTex, depth: depthTex, commandBuffer: cb, renderPassDescriptor: rpd)

        guard let blit = cb.makeBlitCommandEncoder() else {
            throw XCTSkip("Could not create a blit encoder for depth readback")
        }
        blit.copy(from: depthTex,
                  sourceSlice: 0,
                  sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: size, height: size, depth: 1),
                  to: readback,
                  destinationOffset: 0,
                  destinationBytesPerRow: bytesPerRow,
                  destinationBytesPerImage: bytesPerRow * size)
        blit.endEncoding()

        cb.commit()
        cb.waitUntilCompleted()

        let pointer = readback.contents().bindMemory(to: Float.self, capacity: size * size)
        return Array(UnsafeBufferPointer(start: pointer, count: size * size))
    }

    /// Renders one frame and returns the recorded draw-call count.
    private func renderCountingDraws(model: VRMModel) throws -> Int {
        let renderer = makeRenderer(model: model, depthPrepass: false)
        let size = Self.renderSize

        let colorDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: size, height: size, mipmapped: false)
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
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 1, green: 0, blue: 1, alpha: 1)
        rpd.colorAttachments[0].storeAction = .store
        rpd.depthAttachment.texture = depthTex
        rpd.depthAttachment.loadAction = .clear
        rpd.depthAttachment.clearDepth = 1.0
        rpd.depthAttachment.storeAction = .dontCare

        renderer.drawOffscreenHeadless(
            to: colorTex, depth: depthTex, commandBuffer: cb, renderPassDescriptor: rpd)
        cb.commit()
        cb.waitUntilCompleted()

        let metrics = try XCTUnwrap(renderer.getPerformanceMetrics())
        return metrics.drawCalls
    }
}
