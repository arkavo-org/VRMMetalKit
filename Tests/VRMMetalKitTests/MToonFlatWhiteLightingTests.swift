// Copyright 2025 Arkavo Inc. and contributors
// Licensed under the Apache License, Version 2.0

import XCTest
import Metal
import simd
@testable import VRMMetalKit

/// Regression coverage for VMK#230, the synthetic factor-only sphere side of
/// the #183/#229 tradeoff.
///
/// #183 removed the Half-Lambert remap to make factor-only MToon assets show
/// the raw-NdotL lighting gradient expected by vrm-conformance's synthetic
/// `mtoon_default` sphere. The shader now gates the NdotL mapping by material
/// version: VRM 1.0 uses raw NdotL per spec, while VRM 0.x keeps the
/// Half-Lambert input range used by older authored materials.
@MainActor
final class MToonFlatWhiteLightingTests: XCTestCase {
    private var device: MTLDevice!

    private func ensureDevice() throws {
        if device != nil { return }
        guard let dev = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available on this host")
        }
        device = dev
    }

    func testVRM1FactorOnlySmoothToonProducesRawNdotLGradient() throws {
        try ensureDevice()
        let model = try makeTwoNormalTrianglesModel(toony: 0.0)
        let renderer = makeRenderer(model: model)

        renderer.setLight(0, direction: SIMD3<Float>(0, 1, 0),
                          color: SIMD3<Float>(1, 1, 1), intensity: 1.0)
        renderer.disableLight(1)
        renderer.disableLight(2)
        renderer.setAmbientColor(SIMD3<Float>(0, 0, 0))

        let pixels = try renderTwoTriangleFrame(renderer: renderer)
        let litLuma = sampleLumaRGBA(pixels, quadrant: .bottomLeft)
        let shadowLuma = sampleLumaRGBA(pixels, quadrant: .topRight)

        print("[#230] toony=0 litLuma=\(litLuma) shadowLuma=\(shadowLuma) gap=\(litLuma - shadowLuma)")

        XCTAssertGreaterThan(litLuma - shadowLuma, 0.10,
            "VRM 1.0 factor-only MToon material should show a visible raw-NdotL gradient for vrm-conformance's synthetic sphere.")
    }

    func testVRM1FactorOnlySharpToonUsesRawNdotLShadowEndpoint() throws {
        try ensureDevice()
        let model = try makeTwoNormalTrianglesModel(toony: 0.95)
        let renderer = makeRenderer(model: model)

        renderer.setLight(0, direction: SIMD3<Float>(0, 1, 0),
                          color: SIMD3<Float>(1, 1, 1), intensity: 1.0)
        renderer.disableLight(1)
        renderer.disableLight(2)
        renderer.setAmbientColor(SIMD3<Float>(0, 0, 0))

        let pixels = try renderTwoTriangleFrame(renderer: renderer)
        let shadowLuma = sampleLumaRGBA(pixels, quadrant: .topRight)

        print("[#230] toony=0.95 shadowLuma=\(shadowLuma)")

        XCTAssertLessThan(shadowLuma, 0.20,
            "VRM 1.0 sharp-toon synthetic shadow endpoint should stay near shadeColor/pi instead of the Half-Lambert midpoint.")
    }

    private func makeRenderer(model: VRMModel) -> VRMRenderer {
        var config = RendererConfig()
        config.sampleCount = 1
        config.strict = .off
        config.colorPixelFormat = .rgba8Unorm
        let renderer = VRMRenderer(device: device, config: config)
        renderer.performanceTracker = PerformanceTracker()
        renderer.loadModel(model)
        renderer.viewMatrix = matrix_identity_float4x4
        renderer.projectionMatrix = matrix_identity_float4x4
        return renderer
    }

    private func makeTwoNormalTrianglesModel(toony: Float) throws -> VRMModel {
        let gltfJSON = """
        {"asset":{"version":"2.0"},"scene":0,"scenes":[{"nodes":[0]}],
         "nodes":[{"name":"root","mesh":0}]}
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
        for node in model.nodes {
            node.updateWorldTransform()
        }

        let mesh = VRMMesh(name: "two_normals")
        mesh.primitives = [
            makeTriangle(normal: SIMD3<Float>(0, 1, 0), vertexOffset: SIMD3<Float>(0.5, 0.5, 0)),
            makeTriangle(normal: SIMD3<Float>(0, -1, 0), vertexOffset: SIMD3<Float>(-0.5, -0.5, 0))
        ]
        model.meshes = [mesh]

        let materialJSON = """
        {
          "name":"mtoon_test",
          "pbrMetallicRoughness":{"baseColorFactor":[1.0,1.0,1.0,1.0]},
          "extensions":{
            "VRMC_materials_mtoon":{
              "specVersion":"1.0",
              "shadeColorFactor":[0.5,0.5,0.5],
              "shadingToonyFactor":\(toony),
              "shadingShiftFactor":0.0,
              "giEqualizationFactor":0.9
            }
          }
        }
        """
        let gltfMat = try JSONDecoder().decode(GLTFMaterial.self, from: materialJSON.data(using: .utf8)!)
        model.materials = [VRMMaterial(from: gltfMat, textures: [], vrm0MaterialProperty: nil, vrmVersion: .v1_0)]

        return model
    }

    private func makeTriangle(normal: SIMD3<Float>, vertexOffset: SIMD3<Float>) -> VRMPrimitive {
        let primitive = VRMPrimitive()
        var verts = [VRMVertex(), VRMVertex(), VRMVertex()]
        verts[0].position = SIMD3<Float>(-0.15, -0.15, 0) + vertexOffset
        verts[1].position = SIMD3<Float>(0.15, -0.15, 0) + vertexOffset
        verts[2].position = SIMD3<Float>(0.00, 0.15, 0) + vertexOffset
        for i in 0..<3 {
            verts[i].normal = normal
            verts[i].texCoord = SIMD2<Float>(0, 0)
            verts[i].color = SIMD4<Float>(1, 1, 1, 1)
        }

        primitive.vertexCount = 3
        primitive.vertexBuffer = device.makeBuffer(
            bytes: verts,
            length: 3 * MemoryLayout<VRMVertex>.stride,
            options: .storageModeShared
        )
        primitive.localMin = SIMD3<Float>(-0.15, -0.15, 0) + vertexOffset
        primitive.localMax = SIMD3<Float>(0.15, 0.15, 0) + vertexOffset

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
        primitive.hasJoints = false
        primitive.hasWeights = false
        primitive.requiredPaletteSize = 0
        primitive.materialIndex = 0
        return primitive
    }

    private static let renderSize = 64
    private enum Quadrant { case topRight, bottomLeft }

    private func renderTwoTriangleFrame(renderer: VRMRenderer) throws -> [UInt8] {
        try RenderTestSupport.renderFrame(
            renderer: renderer,
            device: device,
            size: Self.renderSize,
            pixelFormat: .rgba8Unorm,
            clearColor: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        )
    }

    private func sampleLumaRGBA(_ bytes: [UInt8], quadrant: Quadrant) -> Float {
        let size = Self.renderSize
        let half = size / 2
        let xRange: Range<Int>
        let yRange: Range<Int>
        switch quadrant {
        case .topRight:
            xRange = half..<size
            yRange = 0..<half
        case .bottomLeft:
            xRange = 0..<half
            yRange = half..<size
        }

        var lumaSum: Float = 0
        var count = 0
        for y in yRange {
            for x in xRange {
                let i = (y * size + x) * 4
                let r = bytes[i], g = bytes[i + 1], b = bytes[i + 2]
                if r == 0 && g == 0 && b == 0 {
                    continue
                }
                lumaSum += RenderTestSupport.rec709Luma(r: r, g: g, b: b)
                count += 1
            }
        }
        return count > 0 ? lumaSum / Float(count) : 0
    }
}
