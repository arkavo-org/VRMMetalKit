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

import Foundation
import Metal
import simd

/// Decoded scene resources produced by ``VRMResourceLoader``.
internal struct VRMLoadedSceneResources {
    var textures: [VRMTexture]
    var materials: [VRMMaterial]
    var meshes: [VRMMesh]
    var nodes: [VRMNode]
    var skins: [VRMSkin]
    var outlineWidthMaskTextureIndices: Set<Int>
    var uvAnimationMaskTextureIndices: Set<Int>
}

/// Shared glTF/VRM resource loader used by both ``VRMModel`` and standalone
/// cosmetic assets.
///
/// Handles linear-vs-sRGB texture classification (including shared color/data
/// mip-chain splitting), parallel texture/material/mesh decoding, hierarchy
/// construction, Iron Dome joint sanitization, and VRM 0.x coordinate
/// normalization.
internal enum VRMResourceLoader {

    static func load(
        document: GLTFDocument,
        binaryData: Data?,
        baseURL: URL?,
        device: MTLDevice?,
        vrm0MaterialProperties: [VRM0MaterialProperty] = [],
        specVersion: VRMSpecVersion = .v1_0,
        context: VRMLoadingContext? = nil,
        limits: VRMLoaderLimits = .default,
        offlineHierarchy: Bool = false,
        sanitizeJoints: Bool = true
    ) async throws -> VRMLoadedSceneResources {
        let skipLogging = context?.options.optimizations.contains(.skipVerboseLogging) ?? false
        let useBufferPreloading = context?.options.optimizations.contains(.preloadBuffers) ?? false
        let isVRM0 = (specVersion == .v0_0)

        if !skipLogging {
            vrmLog("[VRMResourceLoader] Starting resource load")
        }

        // === Loading Phase: Buffer Preloading ===
        var preloadedBuffers: [Int: Data]?
        if useBufferPreloading {
            await context?.updatePhase(.preloadingBuffers, progress: 0)
            if !skipLogging {
                vrmLog("[VRMResourceLoader] Preloading buffers in parallel...")
            }
            let preloader = BufferPreloader(document: document, baseURL: baseURL)
            preloadedBuffers = await preloader.preloadAllBuffers(binaryData: binaryData)
            if !skipLogging {
                vrmLog("[VRMResourceLoader] ✅ Preloaded \(preloadedBuffers?.count ?? 0) buffers")
            }
            await context?.updatePhase(.preloadingBuffers, progress: 1.0)
        }

        let bufferLoader = BufferLoader(
            document: document,
            binaryData: binaryData,
            baseURL: baseURL,
            preloadedData: preloadedBuffers,
            limits: limits
        )
        try bufferLoader.validateTotalBufferBytes()

        // Identify which textures need linear format (not sRGB):
        // - Normal maps (geometrical data, not color)
        // - Occlusion maps (linear ambient-light attenuation)
        // - Metallic-roughness maps (linear G=roughness, B=metallic)
        // - outlineWidthMultiplyTexture (linear R8 per MToon spec)
        // - uvAnimationMaskTexture (linear R8 per MToon spec)
        var normalMapTextureIndices = Set<Int>()
        var occlusionTextureIndices = Set<Int>()
        var metallicRoughnessTextureIndices = Set<Int>()
        var colorTextureIndices = Set<Int>()
        var outlineWidthMaskTextureIndicesLocal = Set<Int>()
        var uvAnimationMaskTextureIndicesLocal = Set<Int>()

        for material in vrm0MaterialProperties {
            for key in ["_MainTex", "_ShadeTexture", "_SphereAdd", "_RimTexture"] {
                if let index = material.textureProperties[key], index >= 0 {
                    colorTextureIndices.insert(index)
                }
            }
        }

        if !skipLogging {
            vrmLog("[VRMResourceLoader] 🔍 Scanning \(document.materials?.count ?? 0) materials for linear textures...")
        }
        for (matIdx, material) in (document.materials ?? []).enumerated() {
            let matName = material.name ?? "material_\(matIdx)"
            if let occlusionTexture = material.occlusionTexture {
                occlusionTextureIndices.insert(occlusionTexture.index)
            }
            if let baseColorTexture = material.pbrMetallicRoughness?.baseColorTexture {
                colorTextureIndices.insert(baseColorTexture.index)
            }
            if let mrTexture = material.pbrMetallicRoughness?.metallicRoughnessTexture {
                metallicRoughnessTextureIndices.insert(mrTexture.index)
            }
            if let emissiveTexture = material.emissiveTexture {
                colorTextureIndices.insert(emissiveTexture.index)
            }
            if let normalTexture = material.normalTexture {
                normalMapTextureIndices.insert(normalTexture.index)
                if !skipLogging {
                    vrmLog("[VRMResourceLoader] ⚠️ Material '\(matName)' uses texture \(normalTexture.index) as NORMAL MAP (will use linear format)")
                }
            }
            if !skipLogging {
                if let baseColorTex = material.pbrMetallicRoughness?.baseColorTexture {
                    vrmLog("[VRMResourceLoader] ✅ Material '\(matName)' uses texture \(baseColorTex.index) as BASE COLOR (will use sRGB)")
                }
            }
            if let extensions = material.extensions,
               let mtoonExt = extensions["VRMC_materials_mtoon"] as? [String: Any] {
                for key in ["shadeMultiplyTexture", "matcapTexture", "rimMultiplyTexture"] {
                    if let texture = mtoonExt[key] as? [String: Any], let index = texture["index"] as? Int {
                        colorTextureIndices.insert(index)
                    }
                }
                if let outlineTex = mtoonExt["outlineWidthMultiplyTexture"] as? [String: Any],
                   let idx = outlineTex["index"] as? Int {
                    outlineWidthMaskTextureIndicesLocal.insert(idx)
                }
                if let uvAnimTex = mtoonExt["uvAnimationMaskTexture"] as? [String: Any],
                   let idx = uvAnimTex["index"] as? Int {
                    uvAnimationMaskTextureIndicesLocal.insert(idx)
                }
            }
        }

        if !skipLogging {
            vrmLog("[VRMResourceLoader] 📊 Normal map texture indices: \(normalMapTextureIndices.sorted())")
        }

        let sharedOcclusionTextureIndices = occlusionTextureIndices.intersection(colorTextureIndices)
        let sharedMetallicRoughnessTextureIndices = metallicRoughnessTextureIndices.intersection(colorTextureIndices)
        let allLinearTextureIndices = normalMapTextureIndices
            .union(occlusionTextureIndices.subtracting(sharedOcclusionTextureIndices))
            .union(metallicRoughnessTextureIndices.subtracting(sharedMetallicRoughnessTextureIndices))
            .union(outlineWidthMaskTextureIndicesLocal)
            .union(uvAnimationMaskTextureIndicesLocal)

        // === Loading Phase: Textures ===
        let textureCount = document.textures?.count ?? 0
        await context?.updatePhase(.loadingTextures, totalItems: textureCount)
        if !skipLogging {
            vrmLog("[VRMResourceLoader] Loading \(textureCount) textures")
        }

        var textures: [VRMTexture] = []
        textures.reserveCapacity(textureCount)

        let preloadedTextures = context?.options.preloadedTextures ?? [:]

        if let device = device {
            let samplerCache = GLTFSamplerCache(device: device)
            let useParallelLoading = context?.options.optimizations.contains(.parallelTextureLoading) ?? false
            let compressColorTextures = context?.options.optimizations.contains(.aggressiveTextureCompression) ?? false

            var resolvedMTLTextures: [Int: MTLTexture] = [:]
            resolvedMTLTextures.reserveCapacity(textureCount)
            var indicesToDecode: [Int] = []
            indicesToDecode.reserveCapacity(textureCount)

            for textureIndex in 0..<textureCount {
                if let preloaded = preloadedTextures[textureIndex] {
                    try await context?.checkCancellation()
                    let isLinear = allLinearTextureIndices.contains(textureIndex)
                    let mtlTexture = try uploadPreloadedTexture(
                        preloaded,
                        textureIndex: textureIndex,
                        defaultSRGB: !isLinear,
                        compressColorTextures: compressColorTextures,
                        document: document,
                        device: device,
                        baseURL: baseURL
                    )
                    resolvedMTLTextures[textureIndex] = mtlTexture
                } else {
                    indicesToDecode.append(textureIndex)
                }
            }

            if !indicesToDecode.isEmpty {
                if useParallelLoading && indicesToDecode.count > 1 {
                    if !skipLogging {
                        vrmLog("[VRMResourceLoader] Using parallel texture loading (\(indicesToDecode.count) textures)")
                    }
                    let parallelLoader = ParallelTextureLoader(
                        device: device,
                        bufferLoader: bufferLoader,
                        document: document,
                        baseURL: baseURL,
                        maxConcurrentLoads: min(4, indicesToDecode.count)
                    )
                    parallelLoader.compressColorTextures = compressColorTextures

                    let preloadedCount = textureCount - indicesToDecode.count
                    let loadedTextures = try await parallelLoader.loadTexturesParallelThrowing(
                        indices: indicesToDecode,
                        linearTextureIndices: allLinearTextureIndices
                    ) { completed, _ in
                        Task {
                            await context?.updateProgress(
                                itemsCompleted: preloadedCount + completed,
                                totalItems: textureCount
                            )
                        }
                    }
                    for (index, mtlTexture) in loadedTextures {
                        resolvedMTLTextures[index] = mtlTexture
                    }
                } else {
                    let textureLoader = TextureLoader(device: device, bufferLoader: bufferLoader, document: document, baseURL: baseURL)
                    textureLoader.compressColorTextures = compressColorTextures
                    for (offset, textureIndex) in indicesToDecode.enumerated() {
                        try await context?.checkCancellation()
                        await context?.updateProgress(
                            itemsCompleted: (textureCount - indicesToDecode.count) + offset,
                            totalItems: textureCount
                        )

                        let isLinear = allLinearTextureIndices.contains(textureIndex)
                        if let mtlTexture = try await textureLoader.loadTexture(at: textureIndex, sRGB: !isLinear) {
                            resolvedMTLTextures[textureIndex] = mtlTexture
                        }
                    }
                }
            }

            var loadedCount = 0
            for textureIndex in 0..<textureCount {
                let textureName = document.textures?[safe: textureIndex]?.name ?? "texture_\(textureIndex)"
                if let mtlTexture = resolvedMTLTextures[textureIndex] {
                    let vrmTexture = VRMTexture(name: textureName)
                    vrmTexture.mtlTexture = mtlTexture
                    vrmTexture.sampler = samplerCache.samplerState(forTextureAt: textureIndex, in: document)
                    textures.append(vrmTexture)
                    loadedCount += 1
                } else {
                    textures.append(VRMTexture(name: textureName))
                }
            }
            if !skipLogging {
                vrmLog("[VRMResourceLoader] ✅ Texture loading complete: \(loadedCount)/\(textureCount) loaded (\(preloadedTextures.count) preloaded)")
            }
        } else {
            for textureIndex in 0..<textureCount {
                let textureName = document.textures?[safe: textureIndex]?.name
                textures.append(VRMTexture(name: textureName))
            }
        }

        // === Loading Phase: Materials ===
        let materialCount = document.materials?.count ?? 0
        await context?.updatePhase(.loadingMaterials, totalItems: materialCount)
        if !skipLogging {
            vrmLog("[VRMResourceLoader] Loading \(materialCount) materials")
        }

        var materials: [VRMMaterial] = []
        materials.reserveCapacity(materialCount)

        let useParallelMaterials = context?.options.optimizations.contains(.parallelMaterialLoading) ?? false
        if useParallelMaterials && materialCount > 1 {
            if !skipLogging {
                vrmLog("[VRMResourceLoader] Using parallel material loading (\(materialCount) materials)")
            }
            let parallelLoader = ParallelMaterialLoader(
                document: document,
                textures: textures,
                vrm0MaterialProperties: vrm0MaterialProperties,
                vrmVersion: specVersion
            )
            let indices = Array(0..<materialCount)
            let loadedMaterials = await parallelLoader.loadMaterialsParallel(indices: indices) { completed, total in
                Task {
                    await context?.updateProgress(itemsCompleted: completed, totalItems: total)
                }
            }
            var loadedCount = 0
            for materialIndex in 0..<materialCount {
                if let material = loadedMaterials[materialIndex] {
                    materials.append(material)
                    loadedCount += 1
                }
            }
            if !skipLogging {
                vrmLog("[VRMResourceLoader] ✅ Parallel material loading complete: \(loadedCount)/\(materialCount) loaded")
            }
        } else {
            for materialIndex in 0..<materialCount {
                try await context?.checkCancellation()
                await context?.updateProgress(itemsCompleted: materialIndex, totalItems: materialCount)

                if let gltfMaterial = document.materials?[safe: materialIndex] {
                    let vrm0Prop = materialIndex < vrm0MaterialProperties.count ? vrm0MaterialProperties[materialIndex] : nil
                    let material = VRMMaterial(
                        from: gltfMaterial,
                        textures: textures,
                        vrm0MaterialProperty: vrm0Prop,
                        vrmVersion: specVersion
                    )
                    materials.append(material)
                }
            }
        }

        // Shared color/data images need separate mip chains: color averages
        // in linear light and may weight alpha; occlusion and metallic-roughness
        // average raw linear channels.
        let sharedLinearDataIndices = sharedOcclusionTextureIndices.union(sharedMetallicRoughnessTextureIndices)
        if let device, !sharedLinearDataIndices.isEmpty {
            let loader = TextureLoader(device: device, bufferLoader: bufferLoader, document: document, baseURL: baseURL)
            var linearDataTextures: [Int: VRMTexture] = [:]
            for index in sharedLinearDataIndices.sorted() {
                try await context?.checkCancellation()
                let mtlTexture: MTLTexture?
                if let preloaded = preloadedTextures[index] {
                    mtlTexture = try uploadPreloadedTexture(
                        preloaded,
                        textureIndex: index,
                        defaultSRGB: false,
                        compressColorTextures: false,
                        document: document,
                        device: device,
                        baseURL: baseURL,
                        forceLinearData: true
                    )
                } else {
                    mtlTexture = try await loader.loadTexture(at: index, sRGB: false)
                }
                let texture = VRMTexture(
                    name: textures[safe: index]?.name,
                    mtlTexture: mtlTexture
                )
                texture.sampler = textures[safe: index]?.sampler
                linearDataTextures[index] = texture
            }
            for (index, material) in (document.materials ?? []).enumerated() {
                if let textureIndex = material.occlusionTexture?.index,
                   let texture = linearDataTextures[textureIndex] {
                    materials[safe: index]?.occlusionTexture = texture
                }
                if let textureIndex = material.pbrMetallicRoughness?.metallicRoughnessTexture?.index,
                   let texture = linearDataTextures[textureIndex] {
                    materials[safe: index]?.metallicRoughnessTexture = texture
                }
            }
        }

        // === Loading Phase: Meshes ===
        let meshCount = document.meshes?.count ?? 0
        await context?.updatePhase(.loadingMeshes, totalItems: meshCount)
        if !skipLogging {
            vrmLog("[VRMResourceLoader] Loading \(meshCount) meshes")
        }

        var meshes: [VRMMesh] = []
        meshes.reserveCapacity(meshCount)

        let useParallelMeshLoading = context?.options.optimizations.contains(.parallelMeshLoading) ?? false
        let decodeLimiter = AsyncConcurrencyLimiter(limit: ProcessInfo.processInfo.activeProcessorCount)

        if useParallelMeshLoading && meshCount > 1 {
            if !skipLogging {
                vrmLog("[VRMResourceLoader] Using parallel mesh loading (\(meshCount) meshes)")
            }
            let parallelLoader = ParallelMeshLoader(
                device: device,
                document: document,
                bufferLoader: bufferLoader,
                concurrencyLimiter: decodeLimiter
            )
            let indices = Array(0..<meshCount)
            let loadedMeshes = try await parallelLoader.loadMeshesParallelThrowing(indices: indices) { completed, total in
                Task {
                    await context?.updateProgress(itemsCompleted: completed, totalItems: total)
                }
            }
            var loadedCount = 0
            for meshIndex in 0..<meshCount {
                if let mesh = loadedMeshes[meshIndex] {
                    meshes.append(mesh)
                    loadedCount += 1
                }
            }
            if !skipLogging {
                vrmLog("[VRMResourceLoader] ✅ Parallel mesh loading complete: \(loadedCount)/\(meshCount) loaded")
            }
        } else {
            for meshIndex in 0..<meshCount {
                try await context?.checkCancellation()
                await context?.updateProgress(itemsCompleted: meshIndex, totalItems: meshCount)

                if let gltfMesh = document.meshes?[safe: meshIndex] {
                    let mesh = try await VRMMesh.load(
                        from: gltfMesh,
                        document: document,
                        device: device,
                        bufferLoader: bufferLoader,
                        concurrencyLimiter: decodeLimiter
                    )
                    meshes.append(mesh)
                }
            }
        }

        // === Loading Phase: Hierarchy ===
        await context?.updatePhase(.buildingHierarchy, progress: 0)
        try await context?.checkCancellation()
        let nodes = buildNodeHierarchy(
            document: document,
            isVRM0: isVRM0,
            offline: offlineHierarchy
        )
        await context?.updatePhase(.buildingHierarchy, progress: 1.0)

        // === Loading Phase: Skins ===
        let skinCount = document.skins?.count ?? 0
        await context?.updatePhase(.loadingSkins, totalItems: skinCount)
        var skins: [VRMSkin] = []
        skins.reserveCapacity(skinCount)

        for skinIndex in 0..<skinCount {
            try await context?.checkCancellation()
            await context?.updateProgress(itemsCompleted: skinIndex, totalItems: skinCount)

            if let gltfSkin = document.skins?[skinIndex] {
                let skin = try VRMSkin(from: gltfSkin, nodes: nodes, document: document, bufferLoader: bufferLoader)
                skins.append(skin)
            }
        }

        // IRON DOME: Sanitize joint indices
        if sanitizeJoints {
            await context?.updatePhase(.sanitizingJoints, progress: 0.5)
            sanitizeAllMeshJoints(nodes: nodes, meshes: meshes, skins: skins)
            await context?.updatePhase(.sanitizingJoints, progress: 1.0)
        }

        // VRM 0.0 -> 1.0: companion pass to per-node TRS conjugation.
        if isVRM0 {
            applyVRM0InverseBindMatrixConjugation(skins: skins)
        }

        return VRMLoadedSceneResources(
            textures: textures,
            materials: materials,
            meshes: meshes,
            nodes: nodes,
            skins: skins,
            outlineWidthMaskTextureIndices: outlineWidthMaskTextureIndicesLocal,
            uvAnimationMaskTextureIndices: uvAnimationMaskTextureIndicesLocal
        )
    }

    static func buildNodeHierarchy(
        document: GLTFDocument,
        isVRM0: Bool,
        offline: Bool
    ) -> [VRMNode] {
        guard let gltfNodes = document.nodes else { return [] }

        var nodes: [VRMNode] = []
        nodes.reserveCapacity(gltfNodes.count)
        for (index, gltfNode) in gltfNodes.enumerated() {
            nodes.append(VRMNode(index: index, gltfNode: gltfNode))
        }

        for (index, gltfNode) in gltfNodes.enumerated() {
            guard let childIndices = gltfNode.children else { continue }
            for childIndex in childIndices where childIndex < nodes.count {
                let childNode = nodes[childIndex]
                if let existingParent = childNode.parent {
                    vrmLog("⚠️ [HIERARCHY] Node \(childIndex) ('\(childNode.name ?? "unnamed")') already has parent '\(existingParent.name ?? "unnamed")'. Skipping re-parenting to '\(nodes[index].name ?? "unnamed")'.")
                    continue
                }
                if nodes[index].children.contains(where: { $0 === childNode }) {
                    vrmLog("⚠️ [HIERARCHY] Node \(childIndex) is already a child of '\(nodes[index].name ?? "unnamed")'. Skipping duplicate add.")
                    continue
                }
                if offline {
                    childNode.setParentOffline(nodes[index])
                } else {
                    childNode.parent = nodes[index]
                }
                nodes[index].children.append(childNode)
            }
        }

        for node in nodes where node.parent == nil {
            node.updateWorldTransform()
        }

        if isVRM0 {
            for node in nodes {
                node.rotation = simd_normalize(
                    simd_quatf(
                        ix: -node.rotation.imag.x,
                        iy:  node.rotation.imag.y,
                        iz: -node.rotation.imag.z,
                        r:   node.rotation.real
                    )
                )
                node.translation = SIMD3<Float>(
                    -node.translation.x,
                     node.translation.y,
                    -node.translation.z
                )
                node.initialRotation = node.rotation
                node.initialTranslation = node.translation
                node.updateLocalMatrix()
            }
            for node in nodes where node.parent == nil {
                node.updateWorldTransform()
            }
        }

        return nodes
    }

    static func sanitizeAllMeshJoints(nodes: [VRMNode], meshes: [VRMMesh], skins: [VRMSkin]) {
        guard !skins.isEmpty else { return }

        var totalSanitized = 0
        for node in nodes {
            guard let meshIndex = node.mesh,
                  meshIndex < meshes.count,
                  let skinIndex = node.skin,
                  skinIndex < skins.count else {
                continue
            }

            let mesh = meshes[meshIndex]
            let skin = skins[skinIndex]
            let maxJointIndex = skin.joints.count - 1
            guard maxJointIndex >= 0 else { continue }

            for (primIndex, primitive) in mesh.primitives.enumerated() {
                let sanitized = primitive.sanitizeJoints(maxJointIndex: maxJointIndex)
                if sanitized > 0 {
                    vrmLog("[IRON DOME] Mesh '\(mesh.name ?? "unnamed")' prim \(primIndex): sanitized \(sanitized) joints (max valid: \(maxJointIndex))")
                    totalSanitized += sanitized
                }
            }
        }

        if totalSanitized > 0 {
            vrmLog("[IRON DOME] ✅ Total sanitized joint indices: \(totalSanitized)")
        }
    }

    static func applyVRM0InverseBindMatrixConjugation(skins: [VRMSkin]) {
        let ry180 = float4x4(
            SIMD4<Float>(-1, 0,  0, 0),
            SIMD4<Float>( 0, 1,  0, 0),
            SIMD4<Float>( 0, 0, -1, 0),
            SIMD4<Float>( 0, 0,  0, 1)
        )
        for skin in skins {
            for i in 0..<skin.inverseBindMatrices.count {
                skin.inverseBindMatrices[i] = ry180 * skin.inverseBindMatrices[i]
            }
        }
    }

    private static func uploadPreloadedTexture(
        _ preloaded: VRMPreloadedTexture,
        textureIndex: Int,
        defaultSRGB: Bool,
        compressColorTextures: Bool,
        document: GLTFDocument,
        device: MTLDevice,
        baseURL: URL?,
        forceLinearData: Bool = false
    ) throws -> MTLTexture {
        switch preloaded.source {
        case .mtlTexture(let existing):
            return existing
        case .rgba8(let data, let width, let height, let bytesPerRow):
            let sampler = document.textures?[safe: textureIndex]?.sampler.flatMap { document.samplers?[safe: $0] }
            let useSRGB = forceLinearData ? false : (preloaded.sRGB ?? defaultSRGB)
            let mipmapped = preloaded.mipmapped ?? TextureLoader.samplerRequestsMipmaps(sampler)
            let alphaIsCoverage = forceLinearData
                ? false
                : (preloaded.alphaIsCoverage ?? (useSRGB && TextureLoader.textureAlphaIsCoverage(textureIndex, in: document)))
            let pixelFormat: MTLPixelFormat = useSRGB ? .rgba8Unorm_srgb : .rgba8Unorm
            guard let texture = TextureUploader.makeTexture(
                rgba8Data: data,
                width: width,
                height: height,
                bytesPerRow: bytesPerRow,
                pixelFormat: pixelFormat,
                device: device,
                mipmapped: mipmapped,
                alphaIsCoverage: alphaIsCoverage,
                blockCompress: useSRGB && compressColorTextures
            ) else {
                throw GLTFError.invalidImageData(
                    textureIndex: textureIndex,
                    reason: "Failed to upload preloaded RGBA8 texture (\(width)x\(height), \(data.count) bytes)",
                    filePath: baseURL?.path
                )
            }
            return texture
        }
    }
}
