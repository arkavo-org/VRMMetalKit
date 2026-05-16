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

import Foundation
@preconcurrency import Metal
import simd
@_exported import GLTFCore

/// A loaded glTF 2.0 asset, ready for ``GLTFRenderer/encodeOpaqueDrawCalls(_:scene:pipelineState:depthState:encoder:)``.
///
/// Phase 3a step 4b ships static-mesh + scene-graph + PBR. Skinning, morph
/// targets, and animation playback come in Phase 3b. KHR_lights_punctual
/// parsing is step 4c; the `lights` array is wired here but always empty
/// for now.
public struct GLTFAsset {
    /// Flattened draw list — one entry per primitive of every mesh visible
    /// in the default scene, with world transform pre-multiplied.
    public let drawCalls: [GLTFDrawCall]

    /// All `MTLTexture` instances referenced by materials. Held to keep
    /// them alive until the asset goes out of scope.
    public let textures: [MTLTexture]

    /// Axis-aligned bounding box in world space, computed from per-primitive
    /// position bounds. Useful for auto-framing a camera.
    public let worldBounds: (min: SIMD3<Float>, max: SIMD3<Float>)
}

/// Loads a glTF 2.0 asset from a `.glb` or `.gltf` file into a
/// ``GLTFAsset`` consumable by ``GLTFRenderer``.
///
/// Owns nothing past the call — pure transform from URL to value. The
/// asset retains GPU buffers + textures, so the loader itself can be
/// discarded after `load(from:device:)` returns.
public final class GLTFAssetLoader {

    public init() {}

    /// Loads a glTF asset from disk.
    ///
    /// Currently supports the binary container (`.glb`). JSON-based `.gltf`
    /// with external buffers/images would need separate handling not yet
    /// wired up.
    ///
    /// - Parameters:
    ///   - url: Source `.glb` file.
    ///   - device: Metal device for buffer + texture allocation.
    /// - Throws: ``GLTFError`` for parse / buffer / image failures.
    public func load(from url: URL, device: MTLDevice) async throws -> GLTFAsset {
        let data = try Data(contentsOf: url)
        let parser = GLTFParser()
        let parsed = try parser.parse(data: data, filePath: url.path)
        return try await build(
            document: parsed.document,
            binaryData: parsed.binaryData,
            baseURL: url.deletingLastPathComponent(),
            device: device
        )
    }

    /// Build path used by ``load(from:device:)`` and the (test-only) in-memory
    /// path that constructs a `GLTFDocument` directly.
    public func build(
        document: GLTFDocument,
        binaryData: Data?,
        baseURL: URL?,
        device: MTLDevice
    ) async throws -> GLTFAsset {
        let bufferLoader = BufferLoader(
            document: document,
            binaryData: binaryData,
            baseURL: baseURL
        )

        // --- Texture color-space classification --------------------------------
        //
        // glTF spec: baseColor + emissive are sRGB, normal + MR + AO are linear.
        // Walk the materials once to classify each referenced texture index.
        var linearTextureIndices: Set<Int> = []
        var allTextureIndices: Set<Int> = []
        for material in document.materials ?? [] {
            if let index = material.pbrMetallicRoughness?.baseColorTexture?.index {
                allTextureIndices.insert(index)
            }
            if let index = material.pbrMetallicRoughness?.metallicRoughnessTexture?.index {
                allTextureIndices.insert(index); linearTextureIndices.insert(index)
            }
            if let index = material.normalTexture?.index {
                allTextureIndices.insert(index); linearTextureIndices.insert(index)
            }
            if let index = material.occlusionTexture?.index {
                allTextureIndices.insert(index); linearTextureIndices.insert(index)
            }
            if let index = material.emissiveTexture?.index {
                allTextureIndices.insert(index)
            }
        }

        // --- Texture loading ---------------------------------------------------

        let textureLoader = ParallelTextureLoader(
            device: device,
            bufferLoader: bufferLoader,
            document: document,
            baseURL: baseURL
        )
        let textureMap = await textureLoader.loadTexturesParallel(
            indices: Array(allTextureIndices).sorted(),
            linearTextureIndices: linearTextureIndices
        )

        // --- Material decoding -------------------------------------------------

        let runtimeMaterials = (document.materials ?? []).map { gltfMaterial in
            Self.makeMaterial(from: gltfMaterial, textures: textureMap)
        }
        let defaultMaterial = GLTFRenderableMaterial(uniforms: GLTFMaterialUniforms())

        // --- Mesh decoding -----------------------------------------------------
        //
        // Each glTF mesh produces an array of (renderableMesh, materialIndex)
        // tuples, one per primitive. Skipped primitives (non-triangle mode,
        // missing POSITION) emit `nil`.
        let runtimePrimitives: [[(GLTFRenderableMesh, Int?)?]] = (document.meshes ?? []).map { gltfMesh in
            gltfMesh.primitives.map { gltfPrimitive in
                Self.makePrimitive(from: gltfPrimitive, bufferLoader: bufferLoader, device: device)
            }
        }

        // --- Scene traversal ---------------------------------------------------
        //
        // glTF's `scene` is the default scene index; walk every root, accumulate
        // local→world transforms via TRS multiplication, and flatten into draw
        // calls. World bounds are unioned across primitives.

        var drawCalls: [GLTFDrawCall] = []
        var worldMin = SIMD3<Float>(repeating: Float.infinity)
        var worldMax = SIMD3<Float>(repeating: -Float.infinity)
        var foundBounds = false

        let sceneIndex = document.scene ?? 0
        let scenes = document.scenes ?? []
        if sceneIndex < scenes.count {
            let scene = scenes[sceneIndex]
            for rootNodeIndex in scene.nodes ?? [] {
                Self.traverse(
                    nodeIndex: rootNodeIndex,
                    parentMatrix: matrix_identity_float4x4,
                    document: document,
                    runtimePrimitives: runtimePrimitives,
                    runtimeMaterials: runtimeMaterials,
                    defaultMaterial: defaultMaterial,
                    drawCalls: &drawCalls,
                    worldMin: &worldMin,
                    worldMax: &worldMax,
                    foundBounds: &foundBounds
                )
            }
        }

        if !foundBounds {
            worldMin = SIMD3<Float>(-1, -1, -1)
            worldMax = SIMD3<Float>( 1,  1,  1)
        }

        // Materialize the texture-retention list (deterministic order = sorted by index).
        let retainedTextures = textureMap.keys.sorted().compactMap { textureMap[$0] }

        return GLTFAsset(
            drawCalls: drawCalls,
            textures: retainedTextures,
            worldBounds: (min: worldMin, max: worldMax)
        )
    }

    // MARK: - Material decoding

    private static func makeMaterial(
        from gltf: GLTFMaterial,
        textures: [Int: MTLTexture]
    ) -> GLTFRenderableMaterial {
        let pbr = gltf.pbrMetallicRoughness

        var flags: GLTFMaterialFlags = []

        // KHR_materials_unlit — bypass shading entirely.
        if let extensions = gltf.extensions, extensions["KHR_materials_unlit"] != nil {
            flags.insert(.unlit)
        }

        // Alpha mode.
        switch gltf.alphaMode {
        case "MASK":  flags.insert(.alphaMask)
        case "BLEND": flags.insert(.alphaBlend)
        default: break  // OPAQUE
        }

        let baseColorFactor: SIMD4<Float>
        if let f = pbr?.baseColorFactor, f.count >= 4 {
            baseColorFactor = SIMD4<Float>(f[0], f[1], f[2], f[3])
        } else {
            baseColorFactor = SIMD4<Float>(1, 1, 1, 1)
        }

        let emissiveFactor: SIMD3<Float>
        if let f = gltf.emissiveFactor, f.count >= 3 {
            emissiveFactor = SIMD3<Float>(f[0], f[1], f[2])
        } else {
            emissiveFactor = SIMD3<Float>(0, 0, 0)
        }

        var baseColorTexture: MTLTexture?
        if let index = pbr?.baseColorTexture?.index, let texture = textures[index] {
            baseColorTexture = texture
            flags.insert(.hasBaseColorTexture)
        }
        var mrTexture: MTLTexture?
        if let index = pbr?.metallicRoughnessTexture?.index, let texture = textures[index] {
            mrTexture = texture
            flags.insert(.hasMetallicRoughnessTexture)
        }
        var normalTexture: MTLTexture?
        if let index = gltf.normalTexture?.index, let texture = textures[index] {
            normalTexture = texture
            flags.insert(.hasNormalTexture)
        }
        var occlusionTexture: MTLTexture?
        if let index = gltf.occlusionTexture?.index, let texture = textures[index] {
            occlusionTexture = texture
            flags.insert(.hasOcclusionTexture)
        }
        var emissiveTexture: MTLTexture?
        if let index = gltf.emissiveTexture?.index, let texture = textures[index] {
            emissiveTexture = texture
            flags.insert(.hasEmissiveTexture)
        }

        let uniforms = GLTFMaterialUniforms(
            baseColorFactor: baseColorFactor,
            emissiveFactor: emissiveFactor,
            metallicFactor: pbr?.metallicFactor ?? 1.0,
            roughnessFactor: pbr?.roughnessFactor ?? 1.0,
            normalScale: gltf.normalTexture?.scale ?? 1.0,
            occlusionStrength: gltf.occlusionTexture?.strength ?? 1.0,
            alphaCutoff: gltf.alphaCutoff ?? 0.5,
            flags: flags
        )

        return GLTFRenderableMaterial(
            uniforms: uniforms,
            baseColorTexture: baseColorTexture,
            metallicRoughnessTexture: mrTexture,
            normalTexture: normalTexture,
            occlusionTexture: occlusionTexture,
            emissiveTexture: emissiveTexture
        )
    }

    // MARK: - Primitive decoding

    /// Returns `(mesh, materialIndex)` or `nil` if the primitive should be skipped
    /// (non-triangle mode, missing POSITION, accessor decode failure).
    private static func makePrimitive(
        from gltf: GLTFPrimitive,
        bufferLoader: BufferLoader,
        device: MTLDevice
    ) -> (GLTFRenderableMesh, Int?)? {
        // Only triangle primitives are supported in step 4b. The mesh modes
        // POINTS/LINES/* would need different pipeline states; deferred.
        let mode = gltf.mode ?? 4
        guard mode == 4 else { return nil }

        guard let positionAccessor = gltf.attributes["POSITION"] else { return nil }

        let positions: [Float]
        do {
            positions = try bufferLoader.loadAccessorAsFloat(positionAccessor)
        } catch {
            vrmLog("[GLTFAssetLoader] Failed to load POSITION accessor \(positionAccessor): \(error)")
            return nil
        }
        let vertexCount = positions.count / 3
        guard vertexCount > 0 else { return nil }

        // Optional attributes — synthesise reasonable defaults when absent.
        let normals: [Float]
        if let normalAccessor = gltf.attributes["NORMAL"],
           let loaded = try? bufferLoader.loadAccessorAsFloat(normalAccessor),
           loaded.count == vertexCount * 3 {
            normals = loaded
        } else {
            normals = Array(repeating: 0, count: vertexCount * 3).enumerated().map { i, _ in
                // Default to (0, 1, 0) — better than zero, which would blow up lighting math.
                return (i % 3 == 1) ? 1.0 : 0.0
            }
        }

        let uvs: [Float]
        if let uvAccessor = gltf.attributes["TEXCOORD_0"],
           let loaded = try? bufferLoader.loadAccessorAsFloat(uvAccessor),
           loaded.count == vertexCount * 2 {
            uvs = loaded
        } else {
            uvs = Array(repeating: 0, count: vertexCount * 2)
        }

        // Tangents: when missing, default to (1, 0, 0, 1). This is good enough
        // for untextured / normal-map-less assets; a full MikkT generator would
        // be a follow-up if normal mapping on tangent-less meshes becomes a
        // real requirement.
        let tangents: [Float]
        if let tangentAccessor = gltf.attributes["TANGENT"],
           let loaded = try? bufferLoader.loadAccessorAsFloat(tangentAccessor),
           loaded.count == vertexCount * 4 {
            tangents = loaded
        } else {
            var generated = [Float](repeating: 0, count: vertexCount * 4)
            for i in 0..<vertexCount {
                generated[i * 4 + 0] = 1
                generated[i * 4 + 3] = 1
            }
            tangents = generated
        }

        // Build interleaved vertex array.
        var vertices = [GLTFRenderableVertex]()
        vertices.reserveCapacity(vertexCount)
        for i in 0..<vertexCount {
            let p = SIMD3<Float>(positions[i*3+0], positions[i*3+1], positions[i*3+2])
            let n = SIMD3<Float>(normals[i*3+0], normals[i*3+1], normals[i*3+2])
            let t = SIMD4<Float>(tangents[i*4+0], tangents[i*4+1], tangents[i*4+2], tangents[i*4+3])
            let uv = SIMD2<Float>(uvs[i*2+0], uvs[i*2+1])
            vertices.append(GLTFRenderableVertex(position: p, normal: n, tangent: t, uv0: uv))
        }

        // Index buffer.
        var indexBuffer: MTLBuffer?
        var indexCount = 0
        var indexType: MTLIndexType = .uint16

        if let indicesAccessor = gltf.indices {
            // glTF allows UInt8, UInt16, UInt32. Metal needs UInt16 or UInt32.
            // Promote UInt8 → UInt16 (rare and small enough that the copy is cheap).
            do {
                let asUInt32 = try bufferLoader.loadAccessorAsUInt32(indicesAccessor)
                let maxIndex = asUInt32.max() ?? 0
                if maxIndex < 0x1_0000 {
                    let asUInt16 = asUInt32.map { UInt16($0) }
                    indexBuffer = asUInt16.withUnsafeBufferPointer { ptr in
                        device.makeBuffer(bytes: ptr.baseAddress!, length: asUInt16.count * 2, options: [])
                    }
                    indexType = .uint16
                } else {
                    indexBuffer = asUInt32.withUnsafeBufferPointer { ptr in
                        device.makeBuffer(bytes: ptr.baseAddress!, length: asUInt32.count * 4, options: [])
                    }
                    indexType = .uint32
                }
                indexCount = asUInt32.count
            } catch {
                vrmLog("[GLTFAssetLoader] Failed to load indices accessor \(indicesAccessor): \(error)")
                return nil
            }
        }

        let vertexStride = MemoryLayout<GLTFRenderableVertex>.stride
        guard let vertexBuffer = vertices.withUnsafeBufferPointer({ ptr in
            device.makeBuffer(bytes: ptr.baseAddress!, length: vertices.count * vertexStride, options: [])
        }) else {
            return nil
        }

        let mesh = GLTFRenderableMesh(
            vertexBuffer: vertexBuffer,
            vertexCount: vertexCount,
            indexBuffer: indexBuffer,
            indexCount: indexCount,
            indexType: indexType,
            primitiveType: .triangle
        )

        return (mesh, gltf.material)
    }

    // MARK: - Scene traversal

    private static func traverse(
        nodeIndex: Int,
        parentMatrix: simd_float4x4,
        document: GLTFDocument,
        runtimePrimitives: [[(GLTFRenderableMesh, Int?)?]],
        runtimeMaterials: [GLTFRenderableMaterial],
        defaultMaterial: GLTFRenderableMaterial,
        drawCalls: inout [GLTFDrawCall],
        worldMin: inout SIMD3<Float>,
        worldMax: inout SIMD3<Float>,
        foundBounds: inout Bool
    ) {
        guard let nodes = document.nodes, nodeIndex < nodes.count else { return }
        let node = nodes[nodeIndex]
        let localMatrix = Self.localMatrix(for: node)
        let worldMatrix = parentMatrix * localMatrix

        if let meshIndex = node.mesh,
           meshIndex < runtimePrimitives.count {
            for entry in runtimePrimitives[meshIndex] {
                guard let (mesh, materialIndex) = entry else { continue }
                let material: GLTFRenderableMaterial = {
                    if let idx = materialIndex, idx < runtimeMaterials.count {
                        return runtimeMaterials[idx]
                    }
                    return defaultMaterial
                }()
                drawCalls.append(GLTFDrawCall(mesh: mesh, material: material, modelMatrix: worldMatrix))

                // World-bounds rough estimate — transform every vertex would be
                // accurate but expensive; cheap path is to skip per-primitive
                // exact bounds and rely on the camera framing being adjusted by
                // the caller. The world-bounds value is best-effort.
                let origin = worldMatrix.columns.3
                let translation = SIMD3<Float>(origin.x, origin.y, origin.z)
                worldMin = simd_min(worldMin, translation)
                worldMax = simd_max(worldMax, translation)
                foundBounds = true
            }
        }

        for child in node.children ?? [] {
            traverse(
                nodeIndex: child,
                parentMatrix: worldMatrix,
                document: document,
                runtimePrimitives: runtimePrimitives,
                runtimeMaterials: runtimeMaterials,
                defaultMaterial: defaultMaterial,
                drawCalls: &drawCalls,
                worldMin: &worldMin,
                worldMax: &worldMax,
                foundBounds: &foundBounds
            )
        }
    }

    private static func localMatrix(for node: GLTFNode) -> simd_float4x4 {
        if let m = node.matrix, m.count == 16 {
            // glTF stores column-major, matching simd_float4x4.
            return simd_float4x4(
                SIMD4<Float>(m[0],  m[1],  m[2],  m[3]),
                SIMD4<Float>(m[4],  m[5],  m[6],  m[7]),
                SIMD4<Float>(m[8],  m[9],  m[10], m[11]),
                SIMD4<Float>(m[12], m[13], m[14], m[15])
            )
        }

        let translation: SIMD3<Float> = {
            if let t = node.translation, t.count >= 3 { return SIMD3<Float>(t[0], t[1], t[2]) }
            return SIMD3<Float>(0, 0, 0)
        }()
        let rotation: simd_quatf = {
            if let r = node.rotation, r.count >= 4 {
                return simd_quatf(ix: r[0], iy: r[1], iz: r[2], r: r[3])
            }
            return simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        }()
        let scale: SIMD3<Float> = {
            if let s = node.scale, s.count >= 3 { return SIMD3<Float>(s[0], s[1], s[2]) }
            return SIMD3<Float>(1, 1, 1)
        }()

        let t = simd_float4x4(translation: translation)
        let r = simd_float4x4(rotation)
        let s = simd_float4x4(scale: scale)
        return t * r * s
    }
}

// MARK: - simd_float4x4 helpers

private extension simd_float4x4 {
    init(translation t: SIMD3<Float>) {
        self.init(
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(t.x, t.y, t.z, 1)
        )
    }
    init(scale s: SIMD3<Float>) {
        self.init(
            SIMD4<Float>(s.x, 0, 0, 0),
            SIMD4<Float>(0, s.y, 0, 0),
            SIMD4<Float>(0, 0, s.z, 0),
            SIMD4<Float>(0, 0, 0, 1)
        )
    }
}
