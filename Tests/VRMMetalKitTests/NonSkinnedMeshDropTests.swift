// Copyright 2025 Arkavo
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0

import XCTest
import Metal
import simd
@testable import VRMMetalKit

/// Regression / instrumentation for vrm-conformance issue #181:
/// "Non-skinned meshes dropped when any skin is present in the glTF document".
///
/// The QA team reports that VRMMetalKit drops a non-skinned mesh node
/// (head-mounted sphere) whenever the document also carries a skinned
/// mesh + a VRMC_springBone chain. three-vrm renders both meshes from
/// the same .vrm. Their hypothesis pointed at `VRMRenderer.drawCore`'s
/// mesh-iteration loop, but on inspection that loop iterates
/// `model.nodes.enumerated()` and picks up every node with a mesh.
///
/// This test constructs the minimal dual-mesh scenario programmatically
/// (no glTF round-trip — direct VRMModel/VRMNode/VRMMesh/VRMPrimitive/VRMSkin
/// wiring), renders one offscreen frame, and asserts that the renderer
/// records two draw calls (one per mesh) rather than one. If this passes,
/// the drop is happening upstream of the renderer's mesh iteration; if it
/// fails, the test localizes the bug inside VRMMetalKit.
@MainActor
final class NonSkinnedMeshDropTests: XCTestCase {

    private var device: MTLDevice!

    private func ensureDevice() throws {
        if device != nil { return }
        guard let dev = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available on this host")
        }
        device = dev
    }

    /// Dual-mesh repro: skinned cylinder + non-skinned sphere placed in
    /// opposite framebuffer quadrants so each mesh's pixels are independently
    /// observable in the readback.
    ///
    /// Asserts:
    ///   1. drawCalls == 2 (renderer iterates both nodes).
    ///   2. The non-skinned sphere's quadrant has non-clear pixels (the mesh
    ///      actually wrote to its expected screen area).
    ///   3. The skinned cylinder's quadrant has non-clear pixels.
    func testNonSkinnedMeshRendersWhenSkinIsPresent() throws {
        try ensureDevice()
        let model = try makeDualMeshModel()

        var config = RendererConfig()
        config.sampleCount = 1
        config.strict = .off
        let renderer = VRMRenderer(device: device, config: config)
        renderer.performanceTracker = PerformanceTracker()
        renderer.loadModel(model)
        renderer.viewMatrix = matrix_identity_float4x4
        renderer.projectionMatrix = matrix_identity_float4x4

        let pixels = try renderOneOffscreenFrame(renderer: renderer)

        let metrics = try XCTUnwrap(renderer.getPerformanceMetrics())
        let sphereQuadrantNonClear = countNonClearPixels(pixels, quadrant: .topRight)
        let cylinderQuadrantNonClear = countNonClearPixels(pixels, quadrant: .bottomLeft)
        let totalNonClear = countAllNonClearPixels(pixels)

        print("[#181] drawCalls=\(metrics.drawCalls) culled=\(metrics.culledDraws) " +
              "sphereQuadrantNonClear=\(sphereQuadrantNonClear) " +
              "cylinderQuadrantNonClear=\(cylinderQuadrantNonClear) " +
              "totalNonClear=\(totalNonClear)")
        printPixelMap(pixels, prefix: "[#181 dual-mesh pixmap]")

        XCTAssertEqual(metrics.drawCalls, 2,
            "Both nodes must reach the draw stage. Got \(metrics.drawCalls).")
        XCTAssertGreaterThan(sphereQuadrantNonClear, 0,
            "Non-skinned sphere's quadrant has zero non-clear pixels — the mesh " +
            "was dropped or rendered off-screen despite both nodes being in model.nodes.")
        XCTAssertGreaterThan(cylinderQuadrantNonClear, 0,
            "Skinned cylinder's quadrant has zero non-clear pixels — test scaffolding " +
            "is broken (the comparison baseline is invalid).")
    }

    /// Control: same model **without** the skin. The sphere alone must still
    /// render in its quadrant. If this fails, the test scaffolding itself is
    /// broken and the dual-mesh test result above is meaningless.
    func testSphereAloneRendersWithoutSkin() throws {
        try ensureDevice()
        let model = try makeSphereOnlyModel()

        var config = RendererConfig()
        config.sampleCount = 1
        config.strict = .off
        let renderer = VRMRenderer(device: device, config: config)
        renderer.performanceTracker = PerformanceTracker()
        renderer.loadModel(model)
        renderer.viewMatrix = matrix_identity_float4x4
        renderer.projectionMatrix = matrix_identity_float4x4

        let pixels = try renderOneOffscreenFrame(renderer: renderer)
        let metrics = try XCTUnwrap(renderer.getPerformanceMetrics())
        let sphereQuadrantNonClear = countNonClearPixels(pixels, quadrant: .topRight)
        print("[#181 baseline] drawCalls=\(metrics.drawCalls) " +
              "sphereQuadrantNonClear=\(sphereQuadrantNonClear)")

        XCTAssertEqual(metrics.drawCalls, 1)
        XCTAssertGreaterThan(sphereQuadrantNonClear, 0,
            "Sphere-only baseline must produce visible pixels in the sphere's quadrant.")
    }

    // MARK: - Scene builders

    /// nodes:
    ///   [0] root
    ///   [1] head        (child of root)
    ///   [2] sphere_mesh (child of head, mesh=0, no skin)         ← the "dropped" mesh
    ///   [3] cylinder    (scene root, mesh=1, skin=0)             ← the skinned mesh
    /// skin 0 has 1 joint = node[1] head.
    /// The sphere is translated to the top-right NDC quadrant and the cylinder
    /// vertices live in the bottom-left so the rendered framebuffer separates
    /// their pixels.
    private func makeDualMeshModel() throws -> VRMModel {
        let model = try makeBareModelWithNodes(nodeNames: ["root", "head", "sphere_mesh", "cylinder_mesh"])
        let nodes = model.nodes

        // parent links: head→root, sphere→head; cylinder stays at root.
        link(parent: nodes[0], child: nodes[1])
        link(parent: nodes[1], child: nodes[2])
        nodes[2].mesh = 0
        nodes[3].mesh = 1
        nodes[3].skin = 0

        // Push the non-skinned mesh node into the top-right NDC quadrant.
        nodes[2].translation = SIMD3<Float>(0.5, 0.5, 0)
        nodes[2].updateLocalMatrix()

        for n in nodes where n.parent == nil { n.updateWorldTransform() }

        model.meshes = [
            makeSingleTriMesh(name: "sphere", hasJoints: false, vertexOffset: SIMD3<Float>(0, 0, 0)),
            // Skinned mesh: vertices are placed in the bottom-left quadrant
            // directly (skinning matrices are identity for the single joint).
            makeSingleTriMesh(name: "cylinder", hasJoints: true, vertexOffset: SIMD3<Float>(-0.5, -0.5, 0))
        ]

        // Skin with 1 joint = node[1] head. No inverseBindMatrices accessor
        // (VRMSkin falls back to identity matrices when index is nil).
        let skinJSON = #"{"joints":[1]}"#
        let gltfSkin = try JSONDecoder().decode(GLTFSkin.self, from: skinJSON.data(using: .utf8)!)
        let bufferLoader = BufferLoader(document: model.gltf, binaryData: nil, baseURL: nil, preloadedData: nil)
        let skin = try VRMSkin(from: gltfSkin, nodes: nodes, document: model.gltf, bufferLoader: bufferLoader)
        model.skins = [skin]

        return model
    }

    private func makeSphereOnlyModel() throws -> VRMModel {
        let model = try makeBareModelWithNodes(nodeNames: ["root", "head", "sphere_mesh"])
        let nodes = model.nodes
        link(parent: nodes[0], child: nodes[1])
        link(parent: nodes[1], child: nodes[2])
        nodes[2].mesh = 0
        nodes[2].translation = SIMD3<Float>(0.5, 0.5, 0)
        nodes[2].updateLocalMatrix()
        for n in nodes where n.parent == nil { n.updateWorldTransform() }

        model.meshes = [makeSingleTriMesh(name: "sphere", hasJoints: false, vertexOffset: SIMD3<Float>(0, 0, 0))]
        model.skins = []
        return model
    }

    private func makeBareModelWithNodes(nodeNames: [String]) throws -> VRMModel {
        let nodesJSON = nodeNames.map { "{\"name\":\"\($0)\"}" }.joined(separator: ",")
        let gltfJSON = """
        {"asset":{"version":"2.0"},"scene":0,"scenes":[{"nodes":[0]}],"nodes":[\(nodesJSON)]}
        """
        let gltf = try JSONDecoder().decode(GLTFDocument.self, from: gltfJSON.data(using: .utf8)!)

        let model = VRMModel(
            specVersion: .v1_0,
            meta: VRMMeta(licenseUrl: "https://vrm.dev/licenses/1.0/"),
            humanoid: nil,
            gltf: gltf
        )

        // Build VRMNodes manually (we don't go through the loader's full path).
        for (i, gltfNode) in (gltf.nodes ?? []).enumerated() {
            model.nodes.append(VRMNode(index: i, gltfNode: gltfNode))
        }
        return model
    }

    private func link(parent: VRMNode, child: VRMNode) {
        child.parent = parent
        parent.children.append(child)
    }

    /// Builds a tiny indexed triangle primitive with VRMVertex layout.
    /// Vertices are placed at `vertexOffset` ± 0.1 in NDC so the rendered
    /// triangle lands in a predictable framebuffer quadrant. When
    /// `hasJoints` is true the verts are hard-weighted to joint 0 (the only
    /// entry in our single-joint skin), and the skin's identity IBM means
    /// skinned vertices stay at the same NDC position.
    private func makeSingleTriMesh(name: String, hasJoints: Bool, vertexOffset: SIMD3<Float>) -> VRMMesh {
        let mesh = VRMMesh(name: name)
        let primitive = VRMPrimitive()

        var verts = [VRMVertex(), VRMVertex(), VRMVertex()]
        verts[0].position = SIMD3<Float>(-0.1, -0.1, 0) + vertexOffset
        verts[1].position = SIMD3<Float>( 0.1, -0.1, 0) + vertexOffset
        verts[2].position = SIMD3<Float>( 0.0,  0.1, 0) + vertexOffset
        for i in 0..<3 {
            verts[i].normal = SIMD3<Float>(0, 0, 1)
            verts[i].texCoord = SIMD2<Float>(0, 0)
            verts[i].color = SIMD4<Float>(1, 1, 1, 1)
            if hasJoints {
                verts[i].joints = SIMD4<UInt32>(0, 0, 0, 0)
                verts[i].weights = SIMD4<Float>(1, 0, 0, 0)
            }
        }
        primitive.vertexCount = 3
        primitive.vertexBuffer = device.makeBuffer(
            bytes: verts,
            length: 3 * MemoryLayout<VRMVertex>.stride,
            options: .storageModeShared
        )
        primitive.localMin = SIMD3<Float>(-0.1, -0.1, 0) + vertexOffset
        primitive.localMax = SIMD3<Float>( 0.1,  0.1, 0) + vertexOffset

        let indices: [UInt16] = [0, 1, 2]
        primitive.indexBuffer = device.makeBuffer(
            bytes: indices,
            length: 3 * MemoryLayout<UInt16>.stride,
            options: .storageModeShared
        )
        primitive.indexCount = 3
        primitive.indexType = .uint16
        primitive.indexBufferOffset = 0
        primitive.primitiveType = .triangle
        primitive.hasNormals = true
        primitive.hasTexCoords = false
        primitive.hasColors = false
        primitive.hasJoints = hasJoints
        primitive.hasWeights = hasJoints
        primitive.requiredPaletteSize = hasJoints ? 1 : 0
        primitive.materialIndex = nil  // renderer handles nil material

        mesh.primitives = [primitive]
        return mesh
    }

    // MARK: - Offscreen render helper

    private static let renderSize = 64

    /// Clear color is bright magenta (1, 0, 1, 1). Any rendered pixel from a
    /// VRM mesh will differ — the MToon shader defaults produce white-ish
    /// pixels for our untextured primitives.
    private static let clearColorBGRA: (UInt8, UInt8, UInt8, UInt8) = (255, 0, 255, 255)

    private enum Quadrant {
        case topRight, bottomLeft
    }

    private func renderOneOffscreenFrame(renderer: VRMRenderer) throws -> [UInt8] {
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
            to: colorTex, depth: depthTex,
            commandBuffer: cb, renderPassDescriptor: rpd
        )
        cb.commit()
        cb.waitUntilCompleted()

        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        let region = MTLRegionMake2D(0, 0, size, size)
        bytes.withUnsafeMutableBytes { buf in
            colorTex.getBytes(buf.baseAddress!, bytesPerRow: size * 4, from: region, mipmapLevel: 0)
        }
        return bytes
    }

    private func countAllNonClearPixels(_ bytes: [UInt8]) -> Int {
        let size = Self.renderSize
        var count = 0
        for y in 0..<size {
            for x in 0..<size {
                let i = (y * size + x) * 4
                let b = bytes[i], g = bytes[i + 1], r = bytes[i + 2]
                let isClear = (b == Self.clearColorBGRA.0) &&
                              (g == Self.clearColorBGRA.1) &&
                              (r == Self.clearColorBGRA.2)
                if !isClear { count += 1 }
            }
        }
        return count
    }

    /// Dump a compact 1-char-per-pixel ASCII map: '.'=clear, '#'=non-clear.
    /// Useful to eyeball *where* the triangle ended up.
    private func printPixelMap(_ bytes: [UInt8], prefix: String) {
        let size = Self.renderSize
        print(prefix)
        for y in 0..<size {
            var line = ""
            for x in 0..<size {
                let i = (y * size + x) * 4
                let b = bytes[i], g = bytes[i + 1], r = bytes[i + 2]
                let isClear = (b == Self.clearColorBGRA.0) &&
                              (g == Self.clearColorBGRA.1) &&
                              (r == Self.clearColorBGRA.2)
                line.append(isClear ? "." : "#")
            }
            print("  \(line)")
        }
    }

    /// Counts pixels in the requested quadrant that differ from the magenta
    /// clear color (allowing a small per-channel tolerance for MSAA-free 1x
    /// sample shaded output).
    private func countNonClearPixels(_ bytes: [UInt8], quadrant: Quadrant) -> Int {
        let size = Self.renderSize
        let half = size / 2
        // NDC y is up; the framebuffer Y axis depends on the renderer's
        // viewport convention. Empirically Metal's default places (0,0) at
        // top-left with +Y down, so NDC +Y maps to lower row index.
        let xRange: Range<Int>
        let yRange: Range<Int>
        switch quadrant {
        case .topRight:    xRange = half..<size; yRange = 0..<half
        case .bottomLeft:  xRange = 0..<half;    yRange = half..<size
        }
        var count = 0
        for y in yRange {
            for x in xRange {
                let i = (y * size + x) * 4
                // bgra8Unorm: byte order in memory is B, G, R, A
                let b = bytes[i], g = bytes[i + 1], r = bytes[i + 2]
                let isClear = (b == Self.clearColorBGRA.0) &&
                              (g == Self.clearColorBGRA.1) &&
                              (r == Self.clearColorBGRA.2)
                if !isClear { count += 1 }
            }
        }
        return count
    }
}
