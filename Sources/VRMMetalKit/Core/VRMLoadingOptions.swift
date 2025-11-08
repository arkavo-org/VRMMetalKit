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

/// Configuration options for loading VRM models with resource limits to prevent exhaustion.
///
/// VRMLoadingOptions allows you to set maximum limits on model complexity to prevent
/// memory exhaustion, performance degradation, or denial-of-service from malicious models.
///
/// ## Usage
///
/// ```swift
/// // Default limits (balanced for desktop)
/// let options = VRMLoadingOptions.default
///
/// // Mobile-optimized limits
/// let mobileOptions = VRMLoadingOptions.mobile
///
/// // Custom limits
/// var customOptions = VRMLoadingOptions.default
/// customOptions.maxTriangles = 50_000
/// customOptions.maxTextures = 20
/// customOptions.enforcement = .strict
///
/// // Load with limits
/// let model = try GLTFParser.loadVRM(from: url, device: device, options: customOptions)
/// ```
///
/// ## Enforcement Modes
///
/// - `.warn`: Log warnings when limits exceeded but continue loading (development)
/// - `.strict`: Throw error when limits exceeded (production, security-critical)
///
/// ## Presets
///
/// - `VRMLoadingOptions.default`: Balanced limits for desktop (macOS, high-end iOS devices)
/// - `VRMLoadingOptions.mobile`: Conservative limits for mobile devices
/// - `VRMLoadingOptions.desktop`: Generous limits for high-end desktop workstations
/// - `VRMLoadingOptions.unlimited`: No limits (use with caution!)
///
public struct VRMLoadingOptions {
    /// Enforcement mode for resource limits
    public enum EnforcementMode {
        /// Log warnings when limits exceeded but continue loading
        case warn
        /// Throw error when limits exceeded
        case strict
    }

    /// Enforcement mode for resource limits (default: .warn)
    public var enforcement: EnforcementMode = .warn

    // MARK: - Geometry Limits

    /// Maximum triangles per model (default: 100,000)
    /// Typical VRM avatar: 5,000-30,000 triangles
    public var maxTriangles: Int = 100_000

    /// Maximum vertices per mesh primitive (default: 65,536)
    /// Metal limit: UInt16 index = 65,536 max vertices
    public var maxVerticesPerMesh: Int = 65_536

    // MARK: - Texture Limits

    /// Maximum number of textures per model (default: 50)
    /// Typical VRM: 5-20 textures (body, face, hair, clothes)
    public var maxTextures: Int = 50

    /// Maximum texture dimension in pixels (default: 4096×4096)
    /// Larger textures consume excessive memory and GPU bandwidth
    public var maxTextureSize: Int = 4096

    /// Maximum total texture memory in megabytes (default: 512 MB)
    /// Prevents models with hundreds of high-res textures
    public var maxTextureMemoryMB: Int = 512

    // MARK: - Skeletal Animation Limits

    /// Maximum bones (joints) per model (default: 500)
    /// VRM humanoid: 55 bones (spec), but some models add accessories/hair
    public var maxBones: Int = 500

    /// Maximum bones per skin (default: 256)
    /// Metal uniform buffer limit for joint matrices
    public var maxBonesPerSkin: Int = 256

    // MARK: - Morph Target Limits

    /// Maximum morph targets per mesh (default: 100)
    /// VRM expressions: ~10-20 morphs, but some models have 50+
    public var maxMorphTargetsPerMesh: Int = 100

    /// Maximum total morph targets across all meshes (default: 500)
    /// Prevents models with excessive blend shapes
    public var maxTotalMorphTargets: Int = 500

    // MARK: - Scene Complexity Limits

    /// Maximum number of nodes (transforms) in scene graph (default: 1000)
    /// Typical VRM: 100-300 nodes
    public var maxNodes: Int = 1000

    /// Maximum number of meshes (default: 200)
    /// Typical VRM: 10-50 meshes
    public var maxMeshes: Int = 200

    /// Maximum number of materials (default: 100)
    /// Typical VRM: 5-30 materials
    public var maxMaterials: Int = 100

    // MARK: - Physics Limits

    /// Maximum SpringBone chains (default: 50)
    /// Typical VRM: 5-20 chains (hair, skirt, tail)
    public var maxSpringBoneChains: Int = 50

    /// Maximum SpringBone colliders (default: 100)
    /// Typical VRM: 10-30 colliders (body, head, hands)
    public var maxSpringBoneColliders: Int = 100

    // MARK: - Presets

    /// Default balanced limits for desktop platforms (macOS, high-end iOS)
    public static let `default` = VRMLoadingOptions()

    /// Conservative limits optimized for mobile devices (iPhone, iPad)
    public static let mobile = VRMLoadingOptions(
        enforcement: .strict,
        maxTriangles: 30_000,
        maxTextures: 20,
        maxTextureSize: 2048,
        maxTextureMemoryMB: 256,
        maxBones: 256,
        maxMorphTargetsPerMesh: 50,
        maxTotalMorphTargets: 200,
        maxNodes: 500,
        maxMeshes: 50,
        maxMaterials: 30,
        maxSpringBoneChains: 20,
        maxSpringBoneColliders: 50
    )

    /// Generous limits for high-end desktop workstations
    public static let desktop = VRMLoadingOptions(
        enforcement: .warn,
        maxTriangles: 500_000,
        maxTextures: 100,
        maxTextureSize: 8192,
        maxTextureMemoryMB: 2048,
        maxBones: 1000,
        maxMorphTargetsPerMesh: 200,
        maxTotalMorphTargets: 1000,
        maxNodes: 5000,
        maxMeshes: 500,
        maxMaterials: 200,
        maxSpringBoneChains: 100,
        maxSpringBoneColliders: 200
    )

    /// No limits (use with caution - vulnerable to DoS)
    public static let unlimited = VRMLoadingOptions(
        enforcement: .warn,
        maxTriangles: Int.max,
        maxTextures: Int.max,
        maxTextureSize: 16384,
        maxTextureMemoryMB: 8192,
        maxBones: Int.max,
        maxMorphTargetsPerMesh: Int.max,
        maxTotalMorphTargets: Int.max,
        maxNodes: Int.max,
        maxMeshes: Int.max,
        maxMaterials: Int.max,
        maxSpringBoneChains: Int.max,
        maxSpringBoneColliders: Int.max
    )

    public init(
        enforcement: EnforcementMode = .warn,
        maxTriangles: Int = 100_000,
        maxVerticesPerMesh: Int = 65_536,
        maxTextures: Int = 50,
        maxTextureSize: Int = 4096,
        maxTextureMemoryMB: Int = 512,
        maxBones: Int = 500,
        maxBonesPerSkin: Int = 256,
        maxMorphTargetsPerMesh: Int = 100,
        maxTotalMorphTargets: Int = 500,
        maxNodes: Int = 1000,
        maxMeshes: Int = 200,
        maxMaterials: Int = 100,
        maxSpringBoneChains: Int = 50,
        maxSpringBoneColliders: Int = 100
    ) {
        self.enforcement = enforcement
        self.maxTriangles = maxTriangles
        self.maxVerticesPerMesh = maxVerticesPerMesh
        self.maxTextures = maxTextures
        self.maxTextureSize = maxTextureSize
        self.maxTextureMemoryMB = maxTextureMemoryMB
        self.maxBones = maxBones
        self.maxBonesPerSkin = maxBonesPerSkin
        self.maxMorphTargetsPerMesh = maxMorphTargetsPerMesh
        self.maxTotalMorphTargets = maxTotalMorphTargets
        self.maxNodes = maxNodes
        self.maxMeshes = maxMeshes
        self.maxMaterials = maxMaterials
        self.maxSpringBoneChains = maxSpringBoneChains
        self.maxSpringBoneColliders = maxSpringBoneColliders
    }
}

/// Errors thrown when resource limits are exceeded
public enum VRMResourceLimitError: Error, LocalizedError {
    case triangleLimitExceeded(actual: Int, limit: Int)
    case vertexLimitExceeded(meshIndex: Int, actual: Int, limit: Int)
    case textureLimitExceeded(actual: Int, limit: Int)
    case textureSizeLimitExceeded(textureIndex: Int, width: Int, height: Int, limit: Int)
    case textureMemoryLimitExceeded(actualMB: Int, limitMB: Int)
    case boneLimitExceeded(actual: Int, limit: Int)
    case bonesPerSkinLimitExceeded(skinIndex: Int, actual: Int, limit: Int)
    case morphTargetLimitExceeded(meshIndex: Int, actual: Int, limit: Int)
    case totalMorphTargetLimitExceeded(actual: Int, limit: Int)
    case nodeLimitExceeded(actual: Int, limit: Int)
    case meshLimitExceeded(actual: Int, limit: Int)
    case materialLimitExceeded(actual: Int, limit: Int)
    case springBoneChainLimitExceeded(actual: Int, limit: Int)
    case springBoneColliderLimitExceeded(actual: Int, limit: Int)

    public var errorDescription: String? {
        switch self {
        case .triangleLimitExceeded(let actual, let limit):
            return """
            ❌ Triangle Limit Exceeded

            Model has \(actual) triangles, exceeding limit of \(limit).

            This may indicate:
            • Overly detailed model (reduce polygon count)
            • Malicious model attempting DoS
            • Need to increase VRMLoadingOptions.maxTriangles

            Suggestion: Optimize model in Blender/Maya, or increase limit if trusted source.
            """

        case .vertexLimitExceeded(let meshIndex, let actual, let limit):
            return """
            ❌ Vertex Limit Exceeded for Mesh #\(meshIndex)

            Mesh has \(actual) vertices, exceeding limit of \(limit).

            Metal index buffer (UInt16) supports max 65,536 vertices per mesh.

            Suggestion: Split mesh into multiple primitives or use UInt32 indices.
            """

        case .textureLimitExceeded(let actual, let limit):
            return """
            ❌ Texture Count Limit Exceeded

            Model has \(actual) textures, exceeding limit of \(limit).

            Suggestion: Consolidate textures into atlases or increase limit.
            """

        case .textureSizeLimitExceeded(let idx, let width, let height, let limit):
            return """
            ❌ Texture Size Limit Exceeded for Texture #\(idx)

            Texture is \(width)×\(height)px, exceeding limit of \(limit)×\(limit)px.

            Large textures consume excessive GPU memory and bandwidth.

            Suggestion: Resize texture to \(limit)×\(limit) or smaller.
            """

        case .textureMemoryLimitExceeded(let actualMB, let limitMB):
            return """
            ❌ Texture Memory Limit Exceeded

            Total texture memory: \(actualMB) MB, exceeding limit of \(limitMB) MB.

            This model uses excessive texture memory.

            Suggestion: Reduce texture resolution or count, or increase limit.
            """

        case .boneLimitExceeded(let actual, let limit):
            return """
            ❌ Bone Count Limit Exceeded

            Model has \(actual) bones, exceeding limit of \(limit).

            Suggestion: Remove accessory bones or increase limit.
            """

        case .bonesPerSkinLimitExceeded(let skinIndex, let actual, let limit):
            return """
            ❌ Bones Per Skin Limit Exceeded for Skin #\(skinIndex)

            Skin has \(actual) bones, exceeding limit of \(limit).

            Metal uniform buffer limit: 256 joint matrices.

            Suggestion: Split model into multiple skins.
            """

        case .morphTargetLimitExceeded(let meshIndex, let actual, let limit):
            return """
            ❌ Morph Target Limit Exceeded for Mesh #\(meshIndex)

            Mesh has \(actual) morph targets, exceeding limit of \(limit).

            Suggestion: Reduce blend shapes or increase limit.
            """

        case .totalMorphTargetLimitExceeded(let actual, let limit):
            return """
            ❌ Total Morph Target Limit Exceeded

            Model has \(actual) total morph targets, exceeding limit of \(limit).

            Suggestion: Reduce blend shapes across all meshes.
            """

        case .nodeLimitExceeded(let actual, let limit):
            return """
            ❌ Node Count Limit Exceeded

            Model has \(actual) nodes, exceeding limit of \(limit).

            Excessive node count may indicate complex scene graph.

            Suggestion: Simplify hierarchy or increase limit.
            """

        case .meshLimitExceeded(let actual, let limit):
            return """
            ❌ Mesh Count Limit Exceeded

            Model has \(actual) meshes, exceeding limit of \(limit).

            Suggestion: Merge meshes or increase limit.
            """

        case .materialLimitExceeded(let actual, let limit):
            return """
            ❌ Material Count Limit Exceeded

            Model has \(actual) materials, exceeding limit of \(limit).

            Suggestion: Consolidate materials or increase limit.
            """

        case .springBoneChainLimitExceeded(let actual, let limit):
            return """
            ❌ SpringBone Chain Limit Exceeded

            Model has \(actual) SpringBone chains, exceeding limit of \(limit).

            Suggestion: Reduce physics chains or increase limit.
            """

        case .springBoneColliderLimitExceeded(let actual, let limit):
            return """
            ❌ SpringBone Collider Limit Exceeded

            Model has \(actual) colliders, exceeding limit of \(limit).

            Suggestion: Reduce collider count or increase limit.
            """
        }
    }
}

/// Runtime resource usage statistics for a loaded VRM model
public struct VRMResourceUsage {
    public let triangles: Int
    public let vertices: Int
    public let textures: Int
    public let textureMemoryMB: Int
    public let bones: Int
    public let morphTargets: Int
    public let nodes: Int
    public let meshes: Int
    public let materials: Int
    public let springBoneChains: Int
    public let springBoneColliders: Int

    /// Check if usage exceeds limits
    public func validate(against options: VRMLoadingOptions) throws {
        if triangles > options.maxTriangles {
            throw VRMResourceLimitError.triangleLimitExceeded(actual: triangles, limit: options.maxTriangles)
        }
        if textures > options.maxTextures {
            throw VRMResourceLimitError.textureLimitExceeded(actual: textures, limit: options.maxTextures)
        }
        if textureMemoryMB > options.maxTextureMemoryMB {
            throw VRMResourceLimitError.textureMemoryLimitExceeded(actualMB: textureMemoryMB, limitMB: options.maxTextureMemoryMB)
        }
        if bones > options.maxBones {
            throw VRMResourceLimitError.boneLimitExceeded(actual: bones, limit: options.maxBones)
        }
        if morphTargets > options.maxTotalMorphTargets {
            throw VRMResourceLimitError.totalMorphTargetLimitExceeded(actual: morphTargets, limit: options.maxTotalMorphTargets)
        }
        if nodes > options.maxNodes {
            throw VRMResourceLimitError.nodeLimitExceeded(actual: nodes, limit: options.maxNodes)
        }
        if meshes > options.maxMeshes {
            throw VRMResourceLimitError.meshLimitExceeded(actual: meshes, limit: options.maxMeshes)
        }
        if materials > options.maxMaterials {
            throw VRMResourceLimitError.materialLimitExceeded(actual: materials, limit: options.maxMaterials)
        }
        if springBoneChains > options.maxSpringBoneChains {
            throw VRMResourceLimitError.springBoneChainLimitExceeded(actual: springBoneChains, limit: options.maxSpringBoneChains)
        }
        if springBoneColliders > options.maxSpringBoneColliders {
            throw VRMResourceLimitError.springBoneColliderLimitExceeded(actual: springBoneColliders, limit: options.maxSpringBoneColliders)
        }
    }

    /// Generate human-readable report
    public func report(options: VRMLoadingOptions) -> String {
        let usage = [
            ("Triangles", triangles, options.maxTriangles),
            ("Vertices", vertices, Int.max),  // No direct limit
            ("Textures", textures, options.maxTextures),
            ("Texture Memory (MB)", textureMemoryMB, options.maxTextureMemoryMB),
            ("Bones", bones, options.maxBones),
            ("Morph Targets", morphTargets, options.maxTotalMorphTargets),
            ("Nodes", nodes, options.maxNodes),
            ("Meshes", meshes, options.maxMeshes),
            ("Materials", materials, options.maxMaterials),
            ("SpringBone Chains", springBoneChains, options.maxSpringBoneChains),
            ("SpringBone Colliders", springBoneColliders, options.maxSpringBoneColliders),
        ]

        var report = "VRM Resource Usage:\n"
        for (name, actual, limit) in usage {
            let percentage = limit == Int.max ? 0 : (actual * 100) / limit
            let status = actual > limit ? "❌ EXCEEDED" : percentage > 80 ? "⚠️  HIGH" : "✅"
            report += String(format: "  %@ %-25s %6d / %6d (%3d%%)\n", status, name + ":", actual, limit, percentage)
        }
        return report
    }
}
