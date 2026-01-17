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
import simd
import Metal

/// VRMModel represents a loaded VRM avatar with all its data, nodes, meshes, and materials.
///
/// ## Thread Safety
/// **Thread-safe (with locking).** VRMModel is marked `@unchecked Sendable` and uses internal locking
/// to allow concurrent access from animation and rendering threads.
///
/// ### Concurrency Model:
/// - **Coarse-Grained Locking**: The entire model is protected by a single `NSLock`.
/// - **Animation**: `AnimationPlayer` automatically acquires the lock during updates.
/// - **Rendering**: `VRMRenderer` automatically acquires the lock during draw command encoding.
/// - **Manual Access**: If you need to read/write model data from multiple threads manually,
///   use the `withLock { ... }` method to ensure safety.
///
/// ### Usage Example:
/// ```swift
/// // ✅ SAFE: Animation on background thread
/// DispatchQueue.global().async {
///     animationPlayer.update(deltaTime: dt, model: model) // Internally locks
/// }
///
/// // ✅ SAFE: Rendering on main thread
/// draw(in: view) {
///     renderer.render(model: model, ...) // Internally locks
/// }
///
/// // ✅ SAFE: Manual thread-safe access
/// model.withLock {
///     model.nodes[0].translation = SIMD3<Float>(0, 1, 0)
/// }
/// ```
public class VRMModel: @unchecked Sendable {
    // MARK: - Thread Safety
    let lock = NSLock()
    
    /// Execute a closure while holding the model's lock
    public func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    // MARK: - Properties

    public let specVersion: VRMSpecVersion
    public let meta: VRMMeta
    public var humanoid: VRMHumanoid?
    public var firstPerson: VRMFirstPerson?
    public var lookAt: VRMLookAt?
    public var expressions: VRMExpressions?
    public var springBone: VRMSpringBone?

    // VRM 0.x material properties (MToon data stored at document level)
    public var vrm0MaterialProperties: [VRM0MaterialProperty] = []

    // glTF Data
    public var gltf: GLTFDocument
    public var meshes: [VRMMesh] = []
    public var materials: [VRMMaterial] = []
    public var textures: [VRMTexture] = []
    public var nodes: [VRMNode] = []
    public var skins: [VRMSkin] = []

    // File loading context
    public var baseURL: URL?

    // Render resources
    public var device: MTLDevice?

    // GPU SpringBone system
    public var springBoneBuffers: SpringBoneBuffers?
    public var springBoneGlobalParams: SpringBoneGlobalParams?

    // PERFORMANCE: Pre-computed node lookup table (normalized names)
    private var nodeLookupTable: [String: VRMNode] = [:]

    // MARK: - Initialization

    public init(specVersion: VRMSpecVersion,
                meta: VRMMeta,
                humanoid: VRMHumanoid?,
                gltf: GLTFDocument) {
        self.specVersion = specVersion
        self.meta = meta
        self.humanoid = humanoid
        self.gltf = gltf
    }

    // MARK: - Bounding Box Calculation

    /// Calculate axis-aligned bounding box from all mesh vertices in model space
    /// - Parameter includeAnimated: If true, considers current world transforms; if false, uses bind pose
    /// - Returns: Min and max corners of the bounding box
    public func calculateBoundingBox(includeAnimated: Bool = false) -> (min: SIMD3<Float>, max: SIMD3<Float>) {
        var minBounds = SIMD3<Float>(Float.infinity, Float.infinity, Float.infinity)
        var maxBounds = SIMD3<Float>(-Float.infinity, -Float.infinity, -Float.infinity)
        var foundAnyVertex = false

        // Iterate through all meshes and primitives
        for (meshIndex, mesh) in meshes.enumerated() {
            for primitive in mesh.primitives {
                // Try to read vertex positions from the Metal buffer
                guard let vertexBuffer = primitive.vertexBuffer,
                      primitive.vertexCount > 0 else {
                    continue
                }

                // Map the buffer to read vertex data
                let bufferPointer = vertexBuffer.contents().bindMemory(to: VRMVertex.self, capacity: primitive.vertexCount)

                // Apply world transform if requested
                let worldTransform: float4x4
                if includeAnimated {
                    // Find the node that references this mesh
                    if let nodeIndex = nodes.firstIndex(where: { $0.mesh == meshIndex }) {
                        worldTransform = nodes[nodeIndex].worldMatrix
                    } else {
                        worldTransform = matrix_identity_float4x4
                    }
                } else {
                    worldTransform = matrix_identity_float4x4
                }

                // Process each vertex
                for vertexIndex in 0..<primitive.vertexCount {
                    let vertex = bufferPointer[vertexIndex]
                    var position = vertex.position

                    // Apply transform if not identity
                    if includeAnimated {
                        let position4 = worldTransform * SIMD4<Float>(position.x, position.y, position.z, 1.0)
                        position = SIMD3<Float>(position4.x, position4.y, position4.z)
                    }

                    minBounds = min(minBounds, position)
                    maxBounds = max(maxBounds, position)
                    foundAnyVertex = true
                }
            }
        }

        // Fallback to reasonable defaults if no vertices found
        if !foundAnyVertex {
            vrmLog("[BOUNDS] No vertices found, using default humanoid bounds")
            minBounds = SIMD3<Float>(-0.5, 0, -0.5)
            maxBounds = SIMD3<Float>(0.5, 1.8, 0.5)  // ~1.8m tall
        }

        vrmLog("[BOUNDS] Calculated from vertex buffers: min=\(minBounds), max=\(maxBounds)")

        return (minBounds, maxBounds)
    }

    public func calculateSkinnedBoundingBox() -> (min: SIMD3<Float>, max: SIMD3<Float>, center: SIMD3<Float>, size: SIMD3<Float>) {
        // For skinned models, estimate from the skeleton
        var minBounds = SIMD3<Float>(Float.infinity, Float.infinity, Float.infinity)
        var maxBounds = SIMD3<Float>(-Float.infinity, -Float.infinity, -Float.infinity)

        // Use joint positions after skinning
        for node in nodes {
            let worldPos = SIMD3<Float>(
                node.worldMatrix[3][0],
                node.worldMatrix[3][1],
                node.worldMatrix[3][2]
            )

            // Add some padding around each joint
            let padding: Float = 0.1
            minBounds = min(minBounds, worldPos - padding)
            maxBounds = max(maxBounds, worldPos + padding)
        }

        // If we have a humanoid, use key bones to estimate bounds
        if let humanoid = humanoid {
            // Get hips position as center reference
            if let hipsIndex = humanoid.getBoneNode(.hips),
               hipsIndex < nodes.count {
                let hipsNode = nodes[hipsIndex]
                let hipsPos = SIMD3<Float>(
                    hipsNode.worldMatrix[3][0],
                    hipsNode.worldMatrix[3][1],
                    hipsNode.worldMatrix[3][2]
                )

                // Get head for height
                if let headIndex = humanoid.getBoneNode(.head),
                   headIndex < nodes.count {
                    let headNode = nodes[headIndex]
                    let headPos = SIMD3<Float>(
                        headNode.worldMatrix[3][0],
                        headNode.worldMatrix[3][1],
                        headNode.worldMatrix[3][2]
                    )
                    maxBounds = max(maxBounds, headPos + SIMD3<Float>(0.2, 0.2, 0.2))  // Add head padding
                }

                // Get feet for bottom
                if let leftFootIndex = humanoid.getBoneNode(.leftFoot),
                   leftFootIndex < nodes.count {
                    let footNode = nodes[leftFootIndex]
                    let footPos = SIMD3<Float>(
                        footNode.worldMatrix[3][0],
                        footNode.worldMatrix[3][1],
                        footNode.worldMatrix[3][2]
                    )
                    minBounds = min(minBounds, footPos - SIMD3<Float>(0.1, 0.1, 0.1))
                }

                // Log hips position for debugging
                vrmLog("[BOUNDS] Hips world position: \(hipsPos)")
            }
        }

        // Fallback to reasonable defaults if bounds are invalid
        if minBounds.x == Float.infinity {
            vrmLog("[BOUNDS] Using default humanoid bounds")
            minBounds = SIMD3<Float>(-0.5, 0, -0.5)
            maxBounds = SIMD3<Float>(0.5, 1.8, 0.5)  // ~1.8m tall
        }

        let center = (minBounds + maxBounds) * 0.5
        let size = maxBounds - minBounds

        vrmLog("[BOUNDS] Calculated: min=\(minBounds), max=\(maxBounds), center=\(center), size=\(size)")

        return (minBounds, maxBounds, center, size)
    }

    // MARK: - Loading

    public static func load(from url: URL, device: MTLDevice? = nil) async throws -> VRMModel {
        let data = try Data(contentsOf: url)
        let model = try await load(from: data, filePath: url.path, device: device)
        // Store the base URL for loading external resources
        model.baseURL = url.deletingLastPathComponent()
        return model
    }

    public static func load(from data: Data, filePath: String? = nil, device: MTLDevice? = nil) async throws -> VRMModel {
        vrmLog("[VRMModel] Starting load from data")
        let parser = GLTFParser()
        let (document, binaryData) = try parser.parse(data: data, filePath: filePath)
        vrmLog("[VRMModel] Parsed GLTF document")

        // Debug: Print what extensions we found
        if let extensions = document.extensions {
            vrmLog("[VRMModel] Found extensions: \(extensions.keys)")
        } else {
            vrmLog("[VRMModel] No extensions found in document")
        }

        // Check for VRM 1.0 (VRMC_vrm) or VRM 0.0 (VRM)
        let vrmExtension = document.extensions?["VRMC_vrm"] ?? document.extensions?["VRM"]
        guard let vrmExtension = vrmExtension else {
            throw VRMError.missingVRMExtension(
                filePath: filePath,
                suggestion: "Ensure this file is a VRM model exported with proper VRM extensions. If it's a regular glTF/GLB file, convert it to VRM format using VRM exporter tools."
            )
        }

        vrmLog("[VRMModel] Parsing VRM extension")
        let vrmParser = VRMExtensionParser()
        let model = try vrmParser.parseVRMExtension(vrmExtension, document: document, filePath: filePath)
        model.device = device
        vrmLog("[VRMModel] VRM extension parsed, starting loadResources")

        // Load resources with buffer data
        try await model.loadResources(binaryData: binaryData)

        // Initialize SpringBone GPU system if device and spring bone data present
        if let device = device, model.springBone != nil {
            try model.initializeSpringBoneGPUSystem(device: device)
            vrmLog("[VRMModel] SpringBone GPU buffers initialized: \(model.springBoneBuffers?.numBones ?? 0) bones")
        }

        return model
    }

    private func loadResources(binaryData: Data? = nil) async throws {
        vrmLog("[VRMModel] Starting loadResources")
        let bufferLoader = BufferLoader(document: gltf, binaryData: binaryData, baseURL: baseURL)

        // Identify which textures are used as normal maps (need linear format, not sRGB)
        var normalMapTextureIndices = Set<Int>()
        vrmLog("[VRMModel] 🔍 Scanning \(gltf.materials?.count ?? 0) materials for normal map textures...")
        for (matIdx, material) in (gltf.materials ?? []).enumerated() {
            let matName = material.name ?? "material_\(matIdx)"
            if let normalTexture = material.normalTexture {
                normalMapTextureIndices.insert(normalTexture.index)
                vrmLog("[VRMModel] ⚠️ Material '\(matName)' uses texture \(normalTexture.index) as NORMAL MAP (will use linear format)")
            }
            // Log base color texture for comparison
            if let baseColorTex = material.pbrMetallicRoughness?.baseColorTexture {
                vrmLog("[VRMModel] ✅ Material '\(matName)' uses texture \(baseColorTex.index) as BASE COLOR (will use sRGB)")
            }
        }
        vrmLog("[VRMModel] 📊 Normal map texture indices: \(normalMapTextureIndices.sorted())")

        // Load ALL textures first - must complete before materials reference them
        vrmLog("[VRMModel] Loading \(gltf.textures?.count ?? 0) textures")
        if let device = device {
            let textureLoader = TextureLoader(device: device, bufferLoader: bufferLoader, document: gltf, baseURL: baseURL)
            for textureIndex in 0..<(gltf.textures?.count ?? 0) {
                // Normal maps should be linear (sRGB=false), color textures should be sRGB (sRGB=true)
                let isNormalMap = normalMapTextureIndices.contains(textureIndex)
                let useSRGB = !isNormalMap
                let textureName = gltf.textures?[safe: textureIndex]?.name ?? "texture_\(textureIndex)"
                let formatStr = useSRGB ? "sRGB" : "LINEAR"
                vrmLog("[VRMModel] Loading texture \(textureIndex) '\(textureName)' as \(formatStr)")
                if let mtlTexture = try await textureLoader.loadTexture(at: textureIndex, sRGB: useSRGB) {
                    let vrmTexture = VRMTexture(name: textureName)
                    vrmTexture.mtlTexture = mtlTexture
                    textures.append(vrmTexture)
                    vrmLog("[VRMModel] ✅ Texture \(textureIndex) loaded: \(mtlTexture.width)x\(mtlTexture.height) format=\(mtlTexture.pixelFormat.rawValue)")
                } else {
                    // Add placeholder texture
                    textures.append(VRMTexture(name: textureName))
                    vrmLog("[VRMModel] ❌ Texture \(textureIndex) FAILED to load - using placeholder!")
                }
            }
        } else {
            // No device, create empty texture placeholders
            for textureIndex in 0..<(gltf.textures?.count ?? 0) {
                let textureName = gltf.textures?[safe: textureIndex]?.name
                textures.append(VRMTexture(name: textureName))
            }
        }

        // Load materials AFTER all textures are loaded to avoid index out of bounds
        vrmLog("[VRMModel] Loading \(gltf.materials?.count ?? 0) materials (VRM 0.x props: \(vrm0MaterialProperties.count))")
        for materialIndex in 0..<(gltf.materials?.count ?? 0) {
            if let gltfMaterial = gltf.materials?[safe: materialIndex] {
                // Pass VRM 0.x material property if available (MToon data at document level)
                let vrm0Prop = materialIndex < vrm0MaterialProperties.count ? vrm0MaterialProperties[materialIndex] : nil
                let material = VRMMaterial(from: gltfMaterial, textures: textures, vrm0MaterialProperty: vrm0Prop)
                materials.append(material)
            }
        }

        // Load meshes
        vrmLog("[VRMModel] Loading \(gltf.meshes?.count ?? 0) meshes")
        for meshIndex in 0..<(gltf.meshes?.count ?? 0) {
            if let gltfMesh = gltf.meshes?[safe: meshIndex] {
                let mesh = try await VRMMesh.load(from: gltfMesh, document: gltf, device: device, bufferLoader: bufferLoader)
                meshes.append(mesh)
            }
        }

        // Build node hierarchy
        buildNodeHierarchy()

        // Load skins
        for skinIndex in 0..<(gltf.skins?.count ?? 0) {
            if let gltfSkin = gltf.skins?[skinIndex] {
                let skin = try VRMSkin(from: gltfSkin, nodes: nodes, document: gltf, bufferLoader: bufferLoader)
                skins.append(skin)
            }
        }
    }

    private func buildNodeHierarchy() {
        guard let gltfNodes = gltf.nodes else { return }

        // Create all nodes
        for (index, gltfNode) in gltfNodes.enumerated() {
            let node = VRMNode(index: index, gltfNode: gltfNode)
            nodes.append(node)
        }

        // Build parent-child relationships with validation
        for (index, gltfNode) in gltfNodes.enumerated() {
            if let childIndices = gltfNode.children {
                for childIndex in childIndices {
                    if childIndex < nodes.count {
                        let childNode = nodes[childIndex]
                        
                        // Validation: Prevent multiple parents (graph cycles/dag)
                        if let existingParent = childNode.parent {
                            vrmLog("⚠️ [HIERARCHY] Node \(childIndex) ('\(childNode.name ?? "unnamed")') already has parent '\(existingParent.name ?? "unnamed")'. Skipping re-parenting to '\(nodes[index].name ?? "unnamed")'.")
                            continue
                        }
                        
                        // Validation: Prevent duplicate children
                        if nodes[index].children.contains(where: { $0 === childNode }) {
                            vrmLog("⚠️ [HIERARCHY] Node \(childIndex) is already a child of '\(nodes[index].name ?? "unnamed")'. Skipping duplicate add.")
                            continue
                        }

                        childNode.parent = nodes[index]
                        nodes[index].children.append(childNode)
                    }
                }
            }
        }

        // Calculate initial transforms
        for node in nodes {
            node.updateWorldTransform()
        }

        // PERFORMANCE: Build normalized name lookup table for fast animation lookups
        buildNodeLookupTable()
    }

    private func buildNodeLookupTable() {
        nodeLookupTable.removeAll()
        for node in nodes {
            guard let name = node.name else { continue }

            // Normalize name the same way AnimationPlayer does
            let normalizedName = name.lowercased()
                .replacingOccurrences(of: "_", with: "")
                .replacingOccurrences(of: ".", with: "")

            nodeLookupTable[normalizedName] = node
        }

        vrmLog("[VRMModel] Built node lookup table with \(nodeLookupTable.count) entries")
    }

    /// Fast O(1) node lookup by normalized name (for animation system)
    public func findNodeByNormalizedName(_ normalizedName: String) -> VRMNode? {
        // O(1) hash table lookup - NO string operations!
        return nodeLookupTable[normalizedName]
    }

    // MARK: - SpringBone GPU System

    public func initializeSpringBoneGPUSystem(device: MTLDevice) throws {
        guard let springBone = springBone else {
            return // No SpringBone data in this model
        }

        // Count total bones from all springs
        var totalBones = 0
        for spring in springBone.springs {
            totalBones += spring.joints.count
        }

        // Count colliders
        let totalSpheres = springBone.colliders.filter {
            if case .sphere = $0.shape { return true }
            return false
        }.count

        let totalCapsules = springBone.colliders.filter {
            if case .capsule = $0.shape { return true }
            return false
        }.count

        // Initialize buffers
        springBoneBuffers = SpringBoneBuffers(device: device)
        springBoneBuffers?.allocateBuffers(
            numBones: totalBones,
            numSpheres: totalSpheres,
            numCapsules: totalCapsules
        )

        // Initialize global parameters
        springBoneGlobalParams = SpringBoneGlobalParams(
            gravity: SIMD3<Float>(0, -9.8, 0), // Standard gravity
            dtSub: 1.0 / 120.0, // 120Hz fixed substeps
            windAmplitude: 0.0,
            windFrequency: 1.0,
            windPhase: 0.0,
            windDirection: SIMD3<Float>(1, 0, 0),
            substeps: 2,
            numBones: UInt32(totalBones),
            numSpheres: UInt32(totalSpheres),
            numCapsules: UInt32(totalCapsules)
        )

        // TODO: Populate bone parameters, rest lengths, and colliders
        // This will be implemented in the compute system
    }

    // MARK: - Floor Plane Colliders

    /// Set floor plane collider at specified Y position
    /// - Parameter floorY: The Y position of the floor plane in world space
    public func setFloorPlane(at floorY: Float) {
        let floor = PlaneCollider(
            point: SIMD3<Float>(0, floorY, 0),
            normal: SIMD3<Float>(0, 1, 0),
            groupIndex: 0
        )
        springBoneBuffers?.setPlaneColliders([floor])
        springBoneGlobalParams?.numPlanes = 1
    }

    /// Remove floor plane collider
    public func removeFloorPlane() {
        springBoneBuffers?.setPlaneColliders([])
        springBoneGlobalParams?.numPlanes = 0
    }

    /// Update all node world transforms based on their local transforms
    public func updateNodeTransforms() {
        // Update root nodes first, then children recursively
        for node in nodes where node.parent == nil {
            node.updateWorldTransform()
        }
    }

    // MARK: - Index/Accessor Audit

    public func runIndexAccessorAudit() {
        vrmLog("\n" + String(repeating: "=", count: 80))
        vrmLog("INDEX/ACCESSOR CONSISTENCY AUDIT")
        vrmLog(String(repeating: "=", count: 80))

        var totalPrimitives = 0
        var failedPrimitives = 0

        for (meshIndex, mesh) in meshes.enumerated() {
            let meshName = mesh.name ?? "mesh_\(meshIndex)"
            vrmLog("\n📦 Mesh \(meshIndex): \(meshName)")

            for (primitiveIndex, primitive) in mesh.primitives.enumerated() {
                totalPrimitives += 1

                // Get material name if available
                var materialName: String? = nil
                if let materialIndex = primitive.materialIndex,
                   materialIndex < materials.count {
                    materialName = materials[materialIndex].name ?? "material_\(materialIndex)"
                }

                // Run audit
                let passed = primitive.auditIndexConsistency(
                    meshIndex: meshIndex,
                    primitiveIndex: primitiveIndex,
                    materialName: materialName
                )

                if !passed {
                    failedPrimitives += 1
                    vrmLog("    🚨 PRIMITIVE FAILED AUDIT!")
                }
            }
        }

        vrmLog("\n" + String(repeating: "=", count: 80))
        vrmLog("AUDIT SUMMARY:")
        vrmLog("  Total primitives: \(totalPrimitives)")
        vrmLog("  Failed primitives: \(failedPrimitives)")
        if failedPrimitives > 0 {
            vrmLog("  ❌ AUDIT FAILED - Found \(failedPrimitives) primitives with index/accessor issues")
        } else {
            vrmLog("  ✅ AUDIT PASSED - All primitives have valid index/accessor data")
        }
        vrmLog(String(repeating: "=", count: 80) + "\n")
    }
}

// MARK: - Supporting Classes

public class VRMHumanoid {
    public var humanBones: [VRMHumanoidBone: VRMHumanBone] = [:]

    public struct VRMHumanBone {
        public let node: Int

        public init(node: Int) {
            self.node = node
        }
    }

    public init() {}

    public func getBoneNode(_ bone: VRMHumanoidBone) -> Int? {
        return humanBones[bone]?.node
    }

    public func validate(filePath: String? = nil) throws {
        // Check all required bones are present
        for bone in VRMHumanoidBone.allCases where bone.isRequired {
            guard humanBones[bone] != nil else {
                let availableBoneNames = humanBones.keys.map { $0.rawValue }
                throw VRMError.missingRequiredBone(
                    bone: bone,
                    availableBones: availableBoneNames,
                    filePath: filePath
                )
            }
        }
    }
}

public class VRMFirstPerson {
    public var meshAnnotations: [VRMMeshAnnotation] = []

    public struct VRMMeshAnnotation {
        public let node: Int
        public let type: VRMFirstPersonFlag

        public init(node: Int, type: VRMFirstPersonFlag) {
            self.node = node
            self.type = type
        }
    }

    public init() {}
}

public class VRMLookAt {
    public var type: VRMLookAtType = .bone
    public var offsetFromHeadBone: SIMD3<Float> = [0, 0, 0]
    public var rangeMapHorizontalInner: VRMLookAtRangeMap = VRMLookAtRangeMap()
    public var rangeMapHorizontalOuter: VRMLookAtRangeMap = VRMLookAtRangeMap()
    public var rangeMapVerticalDown: VRMLookAtRangeMap = VRMLookAtRangeMap()
    public var rangeMapVerticalUp: VRMLookAtRangeMap = VRMLookAtRangeMap()

    public init() {}
}

public class VRMExpressions {
    public var preset: [VRMExpressionPreset: VRMExpression] = [:]
    public var custom: [String: VRMExpression] = [:]

    public init() {}
}

// MARK: - Errors

/// Comprehensive VRM loading and validation errors with LLM-friendly contextual information
public enum VRMError: Error {
    // VRM Extension Errors
    case missingVRMExtension(filePath: String?, suggestion: String)

    // Humanoid Bone Errors
    case missingRequiredBone(bone: VRMHumanoidBone, availableBones: [String], filePath: String?)

    // File Format Errors
    case invalidGLBFormat(reason: String, filePath: String?)
    case invalidJSON(context: String, underlyingError: String?, filePath: String?)
    case unsupportedVersion(version: String, supported: [String], filePath: String?)

    // Buffer and Accessor Errors
    case missingBuffer(bufferIndex: Int, requiredBy: String, expectedSize: Int?, filePath: String?)
    case invalidAccessor(accessorIndex: Int, reason: String, context: String, filePath: String?)

    // Texture Errors
    case missingTexture(textureIndex: Int, materialName: String?, uri: String?, filePath: String?)
    case invalidImageData(textureIndex: Int, reason: String, filePath: String?)

    // Mesh and Geometry Errors
    case invalidMesh(meshIndex: Int, primitiveIndex: Int?, reason: String, filePath: String?)
    case missingVertexAttribute(meshIndex: Int, attributeName: String, filePath: String?)

    // Resource Errors
    case deviceNotSet(context: String)
    case invalidPath(path: String, reason: String, filePath: String?)

    // Material Errors
    case invalidMaterial(materialIndex: Int, reason: String, filePath: String?)
}

extension VRMError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingVRMExtension(let filePath, let suggestion):
            let fileInfo = filePath.map { " in file '\($0)'" } ?? ""
            return """
            ❌ Missing VRM Extension

            The file\(fileInfo) does not contain a valid VRMC_vrm extension. This is required for VRM 1.0 models.

            Suggestion: \(suggestion)

            VRM Spec: https://github.com/vrm-c/vrm-specification/blob/master/specification/VRMC_vrm-1.0/
            """

        case .missingRequiredBone(let bone, let availableBones, let filePath):
            let fileInfo = filePath.map { " in file '\($0)'" } ?? ""
            let bonesListStr = availableBones.isEmpty ? "(none)" : availableBones.joined(separator: ", ")
            return """
            ❌ Missing Required Humanoid Bone: '\(bone.rawValue)'

            The VRM model\(fileInfo) is missing the required humanoid bone '\(bone.rawValue)'.
            Available bones: \(bonesListStr)

            Suggestion: Ensure your 3D model has a bone for '\(bone.rawValue)' and that it's properly mapped in the VRM humanoid configuration. Common bone names include: Hips, Spine, Chest, Neck, Head, LeftUpperArm, RightUpperArm, etc.

            VRM Spec: https://github.com/vrm-c/vrm-specification/blob/master/specification/VRMC_vrm-1.0/humanoid.md
            """

        case .invalidGLBFormat(let reason, let filePath):
            let fileInfo = filePath.map { "File: '\($0)'\n" } ?? ""
            return """
            ❌ Invalid GLB Format

            \(fileInfo)Reason: \(reason)

            Suggestion: Ensure the file is a valid GLB (binary glTF) file. GLB files must start with the magic number 0x46546C67 ('glTF' in ASCII) and have a valid header structure.

            glTF Spec: https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html#glb-file-format-specification
            """

        case .invalidJSON(let context, let underlyingError, let filePath):
            let fileInfo = filePath.map { "File: '\($0)'\n" } ?? ""
            let errorInfo = underlyingError.map { "\nUnderlying error: \($0)" } ?? ""
            return """
            ❌ Invalid JSON Data

            \(fileInfo)Context: \(context)\(errorInfo)

            Suggestion: Check that the JSON structure in your VRM/GLB file is valid and follows the glTF 2.0 specification. Use a JSON validator or glTF validator tool.

            Tools: https://github.khronos.org/glTF-Validator/
            """

        case .unsupportedVersion(let version, let supported, let filePath):
            let fileInfo = filePath.map { "File: '\($0)'\n" } ?? ""
            let supportedStr = supported.joined(separator: ", ")
            return """
            ❌ Unsupported Version

            \(fileInfo)Version found: \(version)
            Supported versions: \(supportedStr)

            Suggestion: Convert your VRM model to a supported version. Use VRM conversion tools or export from your 3D software with the correct VRM version settings.
            """

        case .missingBuffer(let bufferIndex, let requiredBy, let expectedSize, let filePath):
            let fileInfo = filePath.map { "File: '\($0)'\n" } ?? ""
            let sizeInfo = expectedSize.map { " (expected size: \($0) bytes)" } ?? ""
            return """
            ❌ Missing Buffer Data

            \(fileInfo)Buffer index: \(bufferIndex)
            Required by: \(requiredBy)\(sizeInfo)

            Suggestion: The buffer data is missing or incomplete. Check that all buffers referenced in the glTF JSON are present in the GLB binary chunk or as external files. Ensure buffer byte lengths match the declared sizes.

            glTF Spec: https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html#buffers-and-buffer-views
            """

        case .invalidAccessor(let accessorIndex, let reason, let context, let filePath):
            let fileInfo = filePath.map { "File: '\($0)'\n" } ?? ""
            return """
            ❌ Invalid Accessor

            \(fileInfo)Accessor index: \(accessorIndex)
            Context: \(context)
            Reason: \(reason)

            Suggestion: Accessors define how to read vertex data from buffers. Check that the accessor's bufferView, componentType, type, and count are valid. Ensure the accessor doesn't read beyond the buffer bounds.

            glTF Spec: https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html#accessors
            """

        case .missingTexture(let textureIndex, let materialName, let uri, let filePath):
            let fileInfo = filePath.map { "File: '\($0)'\n" } ?? ""
            let materialInfo = materialName.map { "Material: '\($0)'\n" } ?? ""
            let uriInfo = uri.map { "URI: '\($0)'\n" } ?? ""
            return """
            ❌ Missing Texture

            \(fileInfo)\(materialInfo)Texture index: \(textureIndex)
            \(uriInfo)
            Suggestion: The texture file is missing or cannot be loaded. Check that:
            • External texture files exist at the specified URI
            • Embedded textures are properly stored in the GLB binary chunk
            • Data URIs are valid base64-encoded images
            • File paths are correct and accessible

            Supported formats: PNG, JPEG, KTX2, Basis Universal
            """

        case .invalidImageData(let textureIndex, let reason, let filePath):
            let fileInfo = filePath.map { "File: '\($0)'\n" } ?? ""
            return """
            ❌ Invalid Image Data

            \(fileInfo)Texture index: \(textureIndex)
            Reason: \(reason)

            Suggestion: The image data is corrupted or in an unsupported format. Re-export your textures as PNG or JPEG and ensure they're properly embedded or referenced in your VRM file.
            """

        case .invalidMesh(let meshIndex, let primitiveIndex, let reason, let filePath):
            let fileInfo = filePath.map { "File: '\($0)'\n" } ?? ""
            let primInfo = primitiveIndex.map { ", primitive \($0)" } ?? ""
            return """
            ❌ Invalid Mesh Data

            \(fileInfo)Mesh index: \(meshIndex)\(primInfo)
            Reason: \(reason)

            Suggestion: Check that your mesh has:
            • Valid vertex positions (POSITION attribute)
            • Valid normals (NORMAL attribute)
            • Valid UVs if textures are used (TEXCOORD_0)
            • Valid indices if indexed drawing is used
            • Skinning data (JOINTS_0, WEIGHTS_0) if the mesh is rigged

            glTF Spec: https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html#meshes
            """

        case .missingVertexAttribute(let meshIndex, let attributeName, let filePath):
            let fileInfo = filePath.map { "File: '\($0)'\n" } ?? ""
            return """
            ❌ Missing Vertex Attribute

            \(fileInfo)Mesh index: \(meshIndex)
            Attribute: \(attributeName)

            Suggestion: The mesh is missing the '\(attributeName)' vertex attribute. Common attributes:
            • POSITION (required) - vertex positions
            • NORMAL (recommended) - for lighting
            • TEXCOORD_0 (for textures) - UV coordinates
            • JOINTS_0, WEIGHTS_0 (for skinning) - bone influences

            Ensure your 3D model has this data and it's properly exported.
            """

        case .deviceNotSet(let context):
            return """
            ❌ Metal Device Not Set

            Context: \(context)

            Suggestion: You must set a Metal device before performing GPU operations. Call `model.device = MTLCreateSystemDefaultDevice()` or pass a device during initialization.
            """

        case .invalidPath(let path, let reason, let filePath):
            let fileInfo = filePath.map { "File: '\($0)'\n" } ?? ""
            return """
            ❌ Invalid File Path

            \(fileInfo)Path: '\(path)'
            Reason: \(reason)

            Suggestion: Check that the file path is correct and accessible. Ensure:
            • The file exists at the specified location
            • You have read permissions
            • The path doesn't contain invalid characters
            • Relative paths are resolved correctly from the base directory
            """

        case .invalidMaterial(let materialIndex, let reason, let filePath):
            let fileInfo = filePath.map { "File: '\($0)'\n" } ?? ""
            return """
            ❌ Invalid Material

            \(fileInfo)Material index: \(materialIndex)
            Reason: \(reason)

            Suggestion: Check that the material has valid properties:
            • Base color texture references valid texture indices
            • PBR metallic-roughness values are in valid ranges [0, 1]
            • MToon shader parameters are correctly configured
            • Alpha mode is one of: OPAQUE, MASK, BLEND

            VRM MToon Spec: https://github.com/vrm-c/vrm-specification/blob/master/specification/VRMC_materials_mtoon-1.0/README.md
            """
        }
    }
}