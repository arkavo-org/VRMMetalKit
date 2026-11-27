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

/// Synthesized MToon shading preset applied to plain glTF PBR materials on
/// standalone cosmetic `.glb` assets that lack `VRMC_materials_mtoon` and
/// `KHR_materials_unlit`.
public struct VRMCosmeticMToonFallback: Sendable, Equatable {
    /// Multiplier applied to `baseColorFactor.rgb` to derive `shadeColorFactor`.
    public var shadeColorMultiplier: SIMD3<Float>
    /// Toon ramp hardness (`0` = smooth Lambert, `1` = hard cel step).
    public var shadingToonyFactor: Float
    /// Shadow terminator shift (`-1...1`).
    public var shadingShiftFactor: Float
    /// Global illumination equalization factor (`0...1`).
    public var giEqualizationFactor: Float
    /// Outline width mode for synthesized MToon materials.
    public var outlineWidthMode: VRMOutlineWidthMode
    /// Outline width factor when `outlineWidthMode != .none`.
    public var outlineWidthFactor: Float
    /// Outline color factor.
    public var outlineColorFactor: SIMD3<Float>

    public init(
        shadeColorMultiplier: SIMD3<Float> = SIMD3<Float>(0.78, 0.78, 0.82),
        shadingToonyFactor: Float = 0.9,
        shadingShiftFactor: Float = 0.0,
        giEqualizationFactor: Float = 0.9,
        outlineWidthMode: VRMOutlineWidthMode = .none,
        outlineWidthFactor: Float = 0.0,
        outlineColorFactor: SIMD3<Float> = SIMD3<Float>(0, 0, 0)
    ) {
        self.shadeColorMultiplier = shadeColorMultiplier
        self.shadingToonyFactor = shadingToonyFactor
        self.shadingShiftFactor = shadingShiftFactor
        self.giEqualizationFactor = giEqualizationFactor
        self.outlineWidthMode = outlineWidthMode
        self.outlineWidthFactor = outlineWidthFactor
        self.outlineColorFactor = outlineColorFactor
    }

    /// Standard anime toon shading preset matching typical VRoid accessories.
    public static let `default` = VRMCosmeticMToonFallback()

    /// Softer shading ramp suitable for metallic or glossy accessories.
    public static let softToon = VRMCosmeticMToonFallback(
        shadeColorMultiplier: SIMD3<Float>(0.82, 0.82, 0.85),
        shadingToonyFactor: 0.5,
        shadingShiftFactor: -0.05,
        giEqualizationFactor: 0.85
    )

    internal func apply(to material: VRMMaterial) {
        var mtoon = VRMMToonMaterial()
        mtoon.shadeColorFactor = SIMD3<Float>(
            material.baseColorFactor.x * shadeColorMultiplier.x,
            material.baseColorFactor.y * shadeColorMultiplier.y,
            material.baseColorFactor.z * shadeColorMultiplier.z
        )
        mtoon.shadingToonyFactor = shadingToonyFactor
        mtoon.shadingShiftFactor = shadingShiftFactor
        mtoon.giEqualizationFactor = giEqualizationFactor
        mtoon.outlineWidthMode = outlineWidthMode
        mtoon.outlineWidthFactor = outlineWidthFactor
        mtoon.outlineColorFactor = outlineColorFactor
        // Wire shadeMultiplyTexture = baseColorTexture so VRMRenderer's
        // shadeUsesBaseColor fast path triggers automatically.
        mtoon.shadeMultiplyTexture = material.baseColorTexture
        mtoon.shadeMultiplyTextureTransform = material.khrTextureTransform
        mtoon.textureTransform = material.khrTextureTransform
        material.mtoon = mtoon
    }
}

/// Immutable, reusable 3D cosmetic blueprint loaded from a standalone `.glb` or `.vrm`.
///
/// `VRMCosmeticAsset` parses and uploads GPU geometry and textures once in memory
/// (never writing decrypted bytes to disk) and drops the raw `Data` immediately after
/// upload. Each call to `VRMModel.attach` or `VRMModel.attachSkinned` clones the
/// CPU scene graph while sharing immutable GPU buffers and textures, so one loaded
/// asset can be attached to multiple avatars or slots concurrently without interference.
public final class VRMCosmeticAsset: @unchecked Sendable {
    /// Required glTF/VRM extensions honestly supported for standalone cosmetic assets.
    public static let supportedRequiredExtensions: Set<String> = [
        "VRMC_vrm",
        "VRMC_springBone",
        "VRMC_materials_mtoon",
        "KHR_texture_transform",
        "KHR_materials_unlit",
        VRMFaceLandmarks.extensionName,
    ]

    /// Asset title or name from VRM metadata or file name.
    public let name: String?
    /// Authored VRM spec version (`.v1_0` for plain `.glb` and VRM 1.0, `.v0_0` for VRM 0.x).
    public let specVersion: VRMSpecVersion
    /// `true` when the asset contains at least one skin or skinned primitive.
    public let isSkinned: Bool
    /// Number of meshes in the blueprint.
    public var meshCount: Int { meshes.count }
    /// Number of materials in the blueprint.
    public var materialCount: Int { materials.count }
    /// Number of nodes in the blueprint.
    public var nodeCount: Int { nodes.count }
    /// `true` when the asset carries SpringBone physics data.
    public var hasSpringBone: Bool { springBone != nil }
    /// Set of humanoid bones declared in the asset's VRM humanoid block, if any.
    public var humanoidBones: Set<VRMHumanoidBone> {
        guard let humanoid else { return [] }
        return Set(humanoid.humanBones.keys)
    }
    /// Optional face landmarks parsed from `ARKAVO_vrm_cosmetics` or `extras.vrmFaceLandmarks`.
    public let faceLandmarks: VRMFaceLandmarks?
    /// Approximate buffer footprint in bytes used for cumulative `VRMLoaderLimits` checks.
    public let estimatedBufferBytes: Int

    // Strictly internal blueprint scene graph — always cloned per attachment instance.
    internal let nodes: [VRMNode]
    internal let meshes: [VRMMesh]
    internal let materials: [VRMMaterial]
    internal let textures: [VRMTexture]
    internal let skins: [VRMSkin]
    internal let rootNodeIndices: [Int]
    internal let humanoid: VRMHumanoid?
    internal let springBone: VRMSpringBone?
    internal let pbrFallbackMaterialIndices: Set<Int>
    internal let springBoneJointCount: Int

    internal init(
        name: String?,
        specVersion: VRMSpecVersion,
        nodes: [VRMNode],
        meshes: [VRMMesh],
        materials: [VRMMaterial],
        textures: [VRMTexture],
        skins: [VRMSkin],
        rootNodeIndices: [Int],
        humanoid: VRMHumanoid?,
        springBone: VRMSpringBone?,
        faceLandmarks: VRMFaceLandmarks?,
        pbrFallbackMaterialIndices: Set<Int>,
        estimatedBufferBytes: Int
    ) {
        self.name = name
        self.specVersion = specVersion
        self.nodes = nodes
        self.meshes = meshes
        self.materials = materials
        self.textures = textures
        self.skins = skins
        self.rootNodeIndices = rootNodeIndices
        self.humanoid = humanoid
        self.springBone = springBone
        self.faceLandmarks = faceLandmarks
        self.pbrFallbackMaterialIndices = pbrFallbackMaterialIndices
        self.estimatedBufferBytes = estimatedBufferBytes
        self.isSkinned = !skins.isEmpty || meshes.contains { mesh in
            mesh.primitives.contains { $0.hasJoints && $0.hasWeights }
        }
        if let sb = springBone {
            let expanded = Self.expandVRM0SpringBoneIfNeeded(sb, specVersion: specVersion, nodes: nodes)
            self.springBoneJointCount = expanded.springs.reduce(0) { $0 + $1.joints.count }
        } else {
            self.springBoneJointCount = 0
        }
    }

    // MARK: - Loading

    /// Loads a standalone `.glb` or `.vrm` cosmetic blueprint from a file URL.
    public static func load(
        from url: URL,
        device: MTLDevice? = nil,
        mtoonFallback: VRMCosmeticMToonFallback? = .default,
        limits: VRMLoaderLimits = .default
    ) async throws -> VRMCosmeticAsset {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try await load(
            from: data,
            filePath: url.path,
            baseURL: url.deletingLastPathComponent(),
            device: device,
            mtoonFallback: mtoonFallback,
            limits: limits
        )
    }

    /// Loads a standalone `.glb` or `.vrm` cosmetic blueprint strictly from in-memory `Data`
    /// without writing any temporary files to disk.
    public static func load(
        from data: Data,
        filePath: String? = nil,
        device: MTLDevice? = nil,
        mtoonFallback: VRMCosmeticMToonFallback? = .default,
        limits: VRMLoaderLimits = .default
    ) async throws -> VRMCosmeticAsset {
        try await load(
            from: data,
            filePath: filePath,
            baseURL: nil,
            device: device,
            mtoonFallback: mtoonFallback,
            limits: limits
        )
    }

    private static func load(
        from data: Data,
        filePath: String?,
        baseURL: URL?,
        device: MTLDevice?,
        mtoonFallback: VRMCosmeticMToonFallback?,
        limits: VRMLoaderLimits
    ) async throws -> VRMCosmeticAsset {
        let parser = GLTFParser()
        let (document, binaryData) = try parser.parseZeroCopy(data: data, filePath: filePath)

        // Honest required-extension allowlist (glTF 2.0 §3.2).
        if let required = document.extensionsRequired {
            let unsupported = Set(required).subtracting(supportedRequiredExtensions)
            if !unsupported.isEmpty {
                throw GLTFError.unsupportedRequiredExtension(unsupported.sorted())
            }
        }

        let vrmParser = VRMExtensionParser()
        let extData = try vrmParser.parseCosmeticExtensions(
            document: document,
            filePath: filePath,
            limits: limits
        )

        let loaded: VRMLoadedSceneResources
        do {
            loaded = try await VRMResourceLoader.load(
                document: document,
                binaryData: binaryData,
                baseURL: baseURL,
                device: device,
                vrm0MaterialProperties: extData.vrm0MaterialProperties,
                specVersion: extData.specVersion,
                context: nil,
                limits: limits,
                offlineHierarchy: true,
                sanitizeJoints: false
            )
        } catch GLTFError.limitExceeded(let kind, let limit, let observed) {
            throw VRMError.limitExceeded(kind: kind, limit: limit, observed: observed)
        }

        var pbrFallbackIndices = Set<Int>()
        for (idx, material) in loaded.materials.enumerated() {
            guard material.mtoon == nil else { continue }
            let gltfMat = document.materials?[safe: idx]
            let isUnlit = gltfMat?.extensions?["KHR_materials_unlit"] != nil
            if isUnlit {
                var unlit = VRMMToonMaterial()
                unlit.shadeColorFactor = SIMD3<Float>(
                    material.baseColorFactor.x,
                    material.baseColorFactor.y,
                    material.baseColorFactor.z
                )
                unlit.shadingToonyFactor = 0.0
                unlit.shadingShiftFactor = 0.0
                unlit.giEqualizationFactor = 1.0
                unlit.shadeMultiplyTexture = material.baseColorTexture
                unlit.shadeMultiplyTextureTransform = material.khrTextureTransform
                unlit.textureTransform = material.khrTextureTransform
                material.mtoon = unlit
            } else {
                pbrFallbackIndices.insert(idx)
                mtoonFallback?.apply(to: material)
            }
        }

        // Determine active glTF scene root nodes when present; fallback to parentless nodes.
        let rootNodeIndices: [Int]
        if let scenes = document.scenes, !scenes.isEmpty {
            let activeSceneIdx = document.scene ?? 0
            if activeSceneIdx >= 0, activeSceneIdx < scenes.count,
               let sceneNodes = scenes[activeSceneIdx].nodes, !sceneNodes.isEmpty {
                rootNodeIndices = sceneNodes.filter { $0 >= 0 && $0 < loaded.nodes.count }
            } else {
                rootNodeIndices = loaded.nodes.indices.filter { loaded.nodes[$0].parent == nil }
            }
        } else {
            rootNodeIndices = loaded.nodes.indices.filter { loaded.nodes[$0].parent == nil }
        }

        // Validate spring-bone quota against limits on load.
        if let sb = extData.springBone {
            let expanded = expandVRM0SpringBoneIfNeeded(sb, specVersion: extData.specVersion, nodes: loaded.nodes)
            let jointCount = expanded.springs.reduce(0) { $0 + $1.joints.count }
            if jointCount > limits.maxSpringBones {
                throw VRMError.limitExceeded(
                    kind: "springBones",
                    limit: limits.maxSpringBones,
                    observed: jointCount
                )
            }
        }

        let bufferBytes = document.buffers?.reduce(0) { $0 + max(0, $1.byteLength) } ?? (binaryData?.count ?? 0)
        let derivedName = extData.name
            ?? filePath.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }

        return VRMCosmeticAsset(
            name: derivedName,
            specVersion: extData.specVersion,
            nodes: loaded.nodes,
            meshes: loaded.meshes,
            materials: loaded.materials,
            textures: loaded.textures,
            skins: loaded.skins,
            rootNodeIndices: rootNodeIndices,
            humanoid: extData.humanoid,
            springBone: extData.springBone,
            faceLandmarks: VRMFaceLandmarks.parse(from: document),
            pbrFallbackMaterialIndices: pbrFallbackIndices,
            estimatedBufferBytes: bufferBytes
        )
    }

    // MARK: - Cloning

    internal struct ClonedScene {
        var nodes: [VRMNode]
        var meshes: [VRMMesh]
        var materials: [VRMMaterial]
        var textures: [VRMTexture]
        var skins: [VRMSkin]
        var rootNodeIndices: [Int]
        var springBone: VRMSpringBone?
    }

    /// Deep-clones all CPU scene-graph objects while sharing immutable GPU buffers
    /// and textures. Parent links are wired offline so `VRMNode.parentHierarchyRevision`
    /// is never bumped.
    internal func cloneScene(mtoonFallbackOverride: VRMCosmeticMToonFallback? = nil) -> ClonedScene {
        // 1. Clone texture wrappers (sharing immutable MTLTexture + MTLSamplerState).
        var textureMap: [ObjectIdentifier: VRMTexture] = [:]
        textureMap.reserveCapacity(textures.count)
        var clonedTextures: [VRMTexture] = []
        clonedTextures.reserveCapacity(textures.count)
        for tex in textures {
            let copy = VRMTexture(name: tex.name, mtlTexture: tex.mtlTexture)
            copy.sampler = tex.sampler
            textureMap[ObjectIdentifier(tex)] = copy
            clonedTextures.append(copy)
        }

        func remapTexture(_ original: VRMTexture?) -> VRMTexture? {
            guard let original else { return nil }
            if let existing = textureMap[ObjectIdentifier(original)] {
                return existing
            }
            let copy = VRMTexture(name: original.name, mtlTexture: original.mtlTexture)
            copy.sampler = original.sampler
            textureMap[ObjectIdentifier(original)] = copy
            clonedTextures.append(copy)
            return copy
        }

        // 2. Clone materials with remapped VRMTexture wrappers.
        var clonedMaterials: [VRMMaterial] = []
        clonedMaterials.reserveCapacity(materials.count)
        for (idx, material) in materials.enumerated() {
            let copy = VRMMaterial(cloning: material, remapTexture: remapTexture)
            if let override = mtoonFallbackOverride, pbrFallbackMaterialIndices.contains(idx) {
                override.apply(to: copy)
            }
            clonedMaterials.append(copy)
        }

        // 3. Clone meshes and primitives (sharing GPU buffers with CoW safety).
        var clonedMeshes: [VRMMesh] = []
        clonedMeshes.reserveCapacity(meshes.count)
        for mesh in meshes {
            let copy = VRMMesh(name: mesh.name)
            copy.primitives = mesh.primitives.map { $0.cloneSharingGPUBuffers() }
            clonedMeshes.append(copy)
        }

        // 4. Clone nodes and wire offline parent-child hierarchy.
        var nodeMap: [ObjectIdentifier: VRMNode] = [:]
        nodeMap.reserveCapacity(nodes.count)
        var clonedNodes: [VRMNode] = []
        clonedNodes.reserveCapacity(nodes.count)
        for node in nodes {
            let copy = VRMNode(
                index: node.index,
                name: node.name,
                translation: node.translation,
                rotation: node.rotation,
                scale: node.scale,
                mesh: node.mesh,
                skin: node.skin
            )
            copy.initialTranslation = node.initialTranslation
            copy.initialRotation = node.initialRotation
            copy.initialScale = node.initialScale
            copy.isHidden = node.isHidden
            nodeMap[ObjectIdentifier(node)] = copy
            clonedNodes.append(copy)
        }

        for (idx, node) in nodes.enumerated() {
            let clonedParent = clonedNodes[idx]
            for child in node.children {
                if let clonedChild = nodeMap[ObjectIdentifier(child)] {
                    clonedChild.setParentOffline(clonedParent)
                    clonedParent.children.append(clonedChild)
                }
            }
        }
        for idx in rootNodeIndices where idx >= 0 && idx < clonedNodes.count {
            clonedNodes[idx].updateWorldTransform()
        }
        for node in clonedNodes where node.parent == nil {
            node.updateWorldTransform()
        }

        // 5. Clone skins with remapped joint and skeleton node references.
        var clonedSkins: [VRMSkin] = []
        clonedSkins.reserveCapacity(skins.count)
        for skin in skins {
            let copy = VRMSkin(name: skin.name)
            copy.joints = skin.joints.compactMap { nodeMap[ObjectIdentifier($0)] }
            copy.inverseBindMatrices = skin.inverseBindMatrices
            copy.skeleton = skin.skeleton.flatMap { nodeMap[ObjectIdentifier($0)] }
            clonedSkins.append(copy)
        }

        // 6. Clone SpringBone metadata (value type) and expand VRM 0.x chains on clone.
        let clonedSpringBone = springBone.map {
            Self.expandVRM0SpringBoneIfNeeded($0, specVersion: specVersion, nodes: clonedNodes)
        }

        return ClonedScene(
            nodes: clonedNodes,
            meshes: clonedMeshes,
            materials: clonedMaterials,
            textures: clonedTextures,
            skins: clonedSkins,
            rootNodeIndices: rootNodeIndices,
            springBone: clonedSpringBone
        )
    }

    internal static func expandVRM0SpringBoneIfNeeded(
        _ springBone: VRMSpringBone,
        specVersion: VRMSpecVersion,
        nodes: [VRMNode]
    ) -> VRMSpringBone {
        guard specVersion == .v0_0 else { return springBone }
        var result = springBone
        var expandedSprings: [VRMSpring] = []

        func traverseDFS(node: VRMNode, settings: VRMSpringJoint, joints: inout [VRMSpringJoint]) {
            guard let nodeIndex = nodes.firstIndex(where: { $0 === node }) else { return }
            var joint = VRMSpringJoint(node: nodeIndex)
            joint.stiffness = settings.stiffness
            joint.gravityPower = settings.gravityPower
            joint.dragForce = settings.dragForce
            joint.hitRadius = settings.hitRadius
            joint.gravityDir = settings.gravityDir
            joints.append(joint)
            for child in node.children {
                traverseDFS(node: child, settings: settings, joints: &joints)
            }
        }

        for spring in springBone.springs {
            for rootJoint in spring.joints {
                guard rootJoint.node >= 0 && rootJoint.node < nodes.count else { continue }
                var chainJoints: [VRMSpringJoint] = []
                traverseDFS(node: nodes[rootJoint.node], settings: rootJoint, joints: &chainJoints)
                if chainJoints.count >= 2 {
                    var chainSpring = spring
                    chainSpring.joints = chainJoints
                    expandedSprings.append(chainSpring)
                }
            }
        }

        if !expandedSprings.isEmpty {
            let originalCount = springBone.springs.reduce(0) { $0 + $1.joints.count }
            let expandedCount = expandedSprings.reduce(0) { $0 + $1.joints.count }
            if expandedCount > originalCount {
                result.springs = expandedSprings
            }
        }
        return result
    }
}
