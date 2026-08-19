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

/// The MToon inverted hull must never write depth, whether it is drawn by the
/// dedicated outline pass or as part of the material's own draw.
///
/// Scene (identity view + projection, so vertex positions are NDC and clip `z`
/// is the depth value; near = small z):
///
///   * geometry A — a back-to-back triangle pair at `z = 0.4`, opaque,
///     single-sided, MToon outline enabled (red). Being closed, its inverted
///     hull has back faces that survive the hull's front-face discard and land
///     in a band outside A's silhouette.
///   * geometry B — a screen-filling quad over the RIGHT half at `z = 0.85`
///     (blue), defined after A so the renderer draws it after A.
///
/// A depth-writing hull stamps `z = 0.4` into the band; B then fails its
/// `.less` depth test everywhere the band covers it, so the band stays red and
/// B is clipped. With the hull on a no-depth-write state, B paints over the
/// band on the right half, exactly as it did before the outline draw was
/// merged into the color draw.
@MainActor
final class MergedOutlineHullDepthTests: XCTestCase {

    private var device: MTLDevice!
    private static let renderSize = 64

    private func ensureDevice() throws {
        if device != nil { return }
        guard let dev = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available on this host")
        }
        device = dev
    }

    func testHullDoesNotClipGeometryDrawnAfterIt() throws {
        try ensureDevice()
        let model = try makeOutlinedPlusBackdropModel()

        var config = RendererConfig()
        config.sampleCount = 1
        config.strict = .off
        let renderer = VRMRenderer(device: device, config: config)
        renderer.loadModel(model)
        renderer.viewMatrix = matrix_identity_float4x4
        renderer.projectionMatrix = matrix_identity_float4x4
        renderer.outlineWidth = 0.02          // neutral global multiplier (÷ 0.02 == 1)
        renderer.outlineColor = SIMD3<Float>(1, 0, 0)
        renderer.setLight(0, direction: SIMD3<Float>(0, 0, 1), color: SIMD3<Float>(1, 1, 1), intensity: 1.0)
        renderer.disableLight(1)
        renderer.disableLight(2)
        renderer.setAmbientColor(SIMD3<Float>(1, 1, 1))

        let pixels = try RenderTestSupport.renderFrame(
            renderer: renderer,
            device: device,
            size: Self.renderSize,
            pixelFormat: .bgra8Unorm,
            clearColor: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1))

        printClassMap(pixels)

        let redLeft = count(pixels, .red, xRange: 0..<(Self.renderSize / 2 - 4))
        let redRight = count(pixels, .red, xRange: (Self.renderSize / 2 + 2)..<Self.renderSize)
        let blueRight = count(pixels, .blue, xRange: (Self.renderSize / 2 + 2)..<Self.renderSize)
        let green = count(pixels, .green, xRange: 0..<Self.renderSize)
        print("[hull-depth] redLeft=\(redLeft) redRight=\(redRight) blueRight=\(blueRight) green=\(green)")

        XCTAssertGreaterThan(green, 0,
            "Scaffolding: geometry A's shaded surface must be visible.")
        XCTAssertGreaterThan(blueRight, 0,
            "Scaffolding: backdrop B must be visible on the right half.")
        XCTAssertGreaterThan(redLeft, 0,
            "The inverted hull must still render its outline band where nothing covers it. " +
            "Zero red pixels means the hull instance never rasterized — check the hull draw's " +
            "baseInstance / instance_id wiring.")
        XCTAssertEqual(redRight, 0,
            "Outline hull pixels survive on the right half, where backdrop B (drawn after A, " +
            "and behind it) should have painted over them. The hull is writing depth at A's " +
            "sort position and clipping every later draw inside the outline band.")
    }

    // MARK: - Scene

    private func makeOutlinedPlusBackdropModel() throws -> VRMModel {
        let gltfJSON = """
        {"asset":{"version":"2.0"},"scene":0,
         "scenes":[{"nodes":[0,1]}],
         "nodes":[{"name":"geoA","mesh":0},{"name":"geoB","mesh":1}]}
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
        for node in model.nodes { node.updateWorldTransform() }

        model.meshes = [makeOutlinedShellMesh(), makeBackdropMesh()]
        model.materials = [try makeOutlinedMaterial(), try makeBackdropMaterial()]
        return model
    }

    /// Back-to-back triangle pair: one winding is front-facing whatever the
    /// renderer's front-face convention is, the other is its back face — so the
    /// shell is closed and the hull always has a visible back face.
    private func makeOutlinedShellMesh() -> VRMMesh {
        let z: Float = 0.4
        let corners: [SIMD2<Float>] = [
            SIMD2(0.00, 0.45),
            SIMD2(-0.39, -0.225),
            SIMD2(0.39, -0.225)
        ]
        var verts = [VRMVertex](repeating: VRMVertex(), count: 3)
        for i in 0..<3 {
            verts[i].position = SIMD3<Float>(corners[i].x, corners[i].y, z)
            // Radially outward, tilted away from the camera: the hull lands in a
            // band around the silhouette *and* behind the shaded surface, as it
            // does on a real closed mesh. A hull coplanar with the surface would
            // win the `.lessEqual` test everywhere and hide the surface.
            verts[i].normal = normalize(SIMD3<Float>(corners[i].x, corners[i].y, 0.3 * length(corners[i])))
            verts[i].texCoord = SIMD2<Float>(0, 0)
            verts[i].color = SIMD4<Float>(1, 1, 1, 1)
        }
        let indices: [UInt16] = [0, 1, 2, 0, 2, 1]

        let primitive = VRMPrimitive()
        primitive.uploadVertices(verts, device: device)
        primitive.localMin = SIMD3<Float>(-0.39, -0.225, z)
        primitive.localMax = SIMD3<Float>(0.39, 0.45, z)
        finishPrimitive(primitive, indices: indices, materialIndex: 0)

        let mesh = VRMMesh(name: "geoA")
        mesh.primitives = [primitive]
        return mesh
    }

    /// Screen-filling quad over the right half, far behind geometry A.
    private func makeBackdropMesh() -> VRMMesh {
        let z: Float = 0.85
        let corners: [SIMD2<Float>] = [
            SIMD2(0.0, -1.0), SIMD2(1.0, -1.0), SIMD2(1.0, 1.0), SIMD2(0.0, 1.0)
        ]
        var verts = [VRMVertex](repeating: VRMVertex(), count: 4)
        for i in 0..<4 {
            verts[i].position = SIMD3<Float>(corners[i].x, corners[i].y, z)
            verts[i].normal = SIMD3<Float>(0, 0, -1)
            verts[i].texCoord = SIMD2<Float>(0, 0)
            verts[i].color = SIMD4<Float>(1, 1, 1, 1)
        }
        let indices: [UInt16] = [0, 1, 2, 0, 2, 3]

        let primitive = VRMPrimitive()
        primitive.uploadVertices(verts, device: device)
        primitive.localMin = SIMD3<Float>(0.0, -1.0, z)
        primitive.localMax = SIMD3<Float>(1.0, 1.0, z)
        finishPrimitive(primitive, indices: indices, materialIndex: 1)

        let mesh = VRMMesh(name: "geoB")
        mesh.primitives = [primitive]
        return mesh
    }

    private func finishPrimitive(_ primitive: VRMPrimitive, indices: [UInt16], materialIndex: Int) {
        primitive.indexBuffer = device.makeBuffer(
            bytes: indices,
            length: indices.count * MemoryLayout<UInt16>.stride,
            options: .storageModeShared)
        primitive.indexCount = indices.count
        primitive.indexType = .uint16
        primitive.indexBufferOffset = 0
        primitive.primitiveType = .triangle
        primitive.hasNormals = true
        primitive.hasTexCoords = false
        primitive.hasColors = false
        primitive.hasJoints = false
        primitive.hasWeights = false
        primitive.requiredPaletteSize = 0
        primitive.materialIndex = materialIndex
    }

    private func makeOutlinedMaterial() throws -> VRMMaterial {
        let material = try makeMaterial(name: "matA", baseColor: [0, 1, 0, 1])
        material.doubleSided = false
        var mtoon = VRMMToonMaterial()
        mtoon.outlineWidthMode = .worldCoordinates
        // World-mode extrusion is scaled by |worldPos - cameraPos| * 0.01; with
        // the camera at the origin and the shell ~0.6 away that is 0.006, so a
        // ~0.24 NDC band needs a factor of 40.
        mtoon.outlineWidthFactor = 40.0
        mtoon.outlineColorFactor = SIMD3<Float>(1, 0, 0)
        mtoon.outlineLightingMixFactor = 1.0
        material.mtoon = mtoon
        return material
    }

    private func makeBackdropMaterial() throws -> VRMMaterial {
        let material = try makeMaterial(name: "matB", baseColor: [0, 0, 1, 1])
        material.doubleSided = true
        material.mtoon = VRMMToonMaterial()
        return material
    }

    private func makeMaterial(name: String, baseColor: [Float]) throws -> VRMMaterial {
        let json = """
        {"name":"\(name)","alphaMode":"OPAQUE",
         "pbrMetallicRoughness":{"baseColorFactor":[\(baseColor[0]),\(baseColor[1]),\(baseColor[2]),\(baseColor[3])]}}
        """
        let gltfMaterial = try JSONDecoder().decode(GLTFMaterial.self, from: json.data(using: .utf8)!)
        return VRMMaterial(from: gltfMaterial, textures: [], vrm0MaterialProperty: nil, vrmVersion: .v1_0)
    }

    // MARK: - Pixel classification

    private enum PixelClass: Character {
        case clear = "."
        case red = "R"
        case green = "G"
        case blue = "B"
        case other = "?"
    }

    private func classify(_ bytes: [UInt8], _ index: Int) -> PixelClass {
        let b = Int(bytes[index]), g = Int(bytes[index + 1]), r = Int(bytes[index + 2])
        if r < 12 && g < 12 && b < 12 { return .clear }
        if r > g + 24 && r > b + 24 { return .red }
        if g > r + 24 && g > b + 24 { return .green }
        if b > r + 24 && b > g + 24 { return .blue }
        return .other
    }

    private func count(_ bytes: [UInt8], _ wanted: PixelClass, xRange: Range<Int>) -> Int {
        let size = Self.renderSize
        var total = 0
        for y in 0..<size {
            for x in xRange {
                if classify(bytes, (y * size + x) * 4) == wanted { total += 1 }
            }
        }
        return total
    }

    private func printClassMap(_ bytes: [UInt8]) {
        let size = Self.renderSize
        print("[hull-depth] R=outline G=surface B=backdrop .=clear")
        for y in 0..<size {
            var line = ""
            for x in 0..<size {
                line.append(classify(bytes, (y * size + x) * 4).rawValue)
            }
            print("  \(line)")
        }
    }
}
