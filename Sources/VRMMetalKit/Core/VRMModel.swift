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

    /// The VRM specification version of this model (0.0 or 1.0).
    public let specVersion: VRMSpecVersion

    /// Model metadata including title, author, license, and usage permissions.
    public let meta: VRMMeta

    /// Returns `true` if this model uses VRM 0.0 format.
    ///
    /// VRM 0.0 uses Unity's left-handed coordinate system while VRM 1.0 uses glTF's right-handed system.
    /// This affects coordinate conversion when playing VRMA animations.
    public var isVRM0: Bool {
        return specVersion == .v0_0
    }

    /// Humanoid bone mapping for this avatar.
    ///
    /// Maps standard VRM bones (hips, spine, head, arms, legs, etc.) to node indices.
    /// Use `humanoid?.getBoneNode(.hips)` to get a specific bone's node index.
    public var humanoid: VRMHumanoid?

    /// First-person rendering configuration.
    ///
    /// Defines which meshes should be visible in first-person vs third-person cameras.
    public var firstPerson: VRMFirstPerson?

    /// Eye gaze (look-at) configuration.
    ///
    /// Defines how the avatar's eyes track a target point, including range limits.
    public var lookAt: VRMLookAt?

    /// Facial expressions (blend shapes) for this avatar.
    ///
    /// Contains both preset expressions (happy, angry, blink, etc.) and custom expressions.
    /// Use `VRMExpressionController` to animate expressions at runtime.
    public var expressions: VRMExpressions?

    /// Spring bone physics configuration for hair, clothing, and accessories.
    ///
    /// Defines physics chains, stiffness, gravity, and colliders. Physics simulation
    /// is performed on the GPU via `SpringBoneComputeSystem`.
    public var springBone: VRMSpringBone?

    /// VRM 0.x MToon material properties stored at document level.
    public var vrm0MaterialProperties: [VRM0MaterialProperty] = []

    // MARK: - glTF Data

    /// The underlying glTF document structure.
    public var gltf: GLTFDocument

    /// All meshes in the model, each containing one or more primitives.
    public var meshes: [VRMMesh] = []

    /// All materials used by this model (MToon, PBR, or unlit).
    public var materials: [VRMMaterial] = []

    /// All textures loaded for this model.
    public var textures: [VRMTexture] = []

    /// All nodes in the scene graph hierarchy.
    ///
    /// Nodes form a tree structure via `parent` and `children` properties.
    /// Each node has local and world transforms that can be animated.
    public var nodes: [VRMNode] = []

    /// Skin data for skeletal animation (joint matrices, inverse bind matrices).
    public var skins: [VRMSkin] = []

    // MARK: - Runtime State

    /// Base URL for resolving relative resource paths (set during loading).
    public var baseURL: URL?

    /// Metal device used for GPU resources. Required for rendering and physics.
    public var device: MTLDevice?

    /// GPU buffers for spring bone physics simulation.
    public var springBoneBuffers: SpringBoneBuffers?

    /// Global parameters for spring bone physics (gravity, wind, substeps).
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

    /// Loads a VRM model from a file URL with progress and cancellation support.
    ///
    /// This is the primary entry point for loading VRM avatars. The method parses the VRM/GLB file,
    /// loads all resources (meshes, textures, materials), and initializes physics if a Metal device is provided.
    ///
    /// - Parameters:
    ///   - url: File URL to a `.vrm` or `.glb` file.
    ///   - device: Optional Metal device for GPU resources. If provided, textures and physics buffers are created.
    ///   - options: Loading options including progress callbacks and cancellation support.
    ///
    /// - Returns: A fully loaded `VRMModel` ready for rendering.
    ///
    /// - Throws: `VRMError` if the file is invalid or missing required data, or if loading is cancelled.
    ///
    /// ## Example
    /// ```swift
    /// let device = MTLCreateSystemDefaultDevice()!
    /// 
    /// // With progress
    /// let options = VRMLoadingOptions(
    ///     progressCallback: { progress in
    ///         print("Loading: \(Int(progress.overallProgress * 100))%")
    ///     }
    /// )
    /// let model = try await VRMModel.load(from: modelURL, device: device, options: options)
    /// ```
    ///
    /// ## Performance
    /// Loading is asynchronous and may take 100-500ms depending on model complexity.
    /// Textures are loaded in parallel for better performance.
    public static func load(
        from url: URL,
        device: MTLDevice? = nil,
        options: VRMLoadingOptions = .default
    ) async throws -> VRMModel {
        let context = await VRMLoadingContext(options: options)
        
        await context.updatePhase(.parsingGLTF, progress: 0.0)
        
        let data = try Data(contentsOf: url)
        try await context.checkCancellation()
        
        await context.updatePhase(.parsingGLTF, progress: 1.0)
        
        let model = try await load(
            from: data,
            filePath: url.path,
            device: device,
            context: context
        )
        // Store the base URL for loading external resources
        model.baseURL = url.deletingLastPathComponent()
        return model
    }

    /// Loads a VRM model from raw data.
    ///
    /// Use this method when loading from network responses or in-memory data.
    ///
    /// - Parameters:
    ///   - data: Raw VRM/GLB file data.
    ///   - filePath: Optional path for error messages.
    ///   - device: Optional Metal device for GPU resources.
    ///
    /// - Returns: A fully loaded `VRMModel` ready for rendering.
    ///
    /// - Throws: `VRMError` if the data is invalid.
    public static func load(from data: Data, filePath: String? = nil, device: MTLDevice? = nil) async throws -> VRMModel {
        try await load(from: data, filePath: filePath, device: device, context: nil)
    }
    
    /// Internal loading method with context for progress and cancellation.
    private static func load(
        from data: Data,
        filePath: String? = nil,
        device: MTLDevice? = nil,
        context: VRMLoadingContext?
    ) async throws -> VRMModel {
        let skipLogging = await context?.options.optimizations.contains(.skipVerboseLogging) ?? false
        
        if !skipLogging {
            vrmLog("[VRMModel] Starting load from data")
        }
        
        let parser = GLTFParser()
        let (document, binaryData) = try parser.parse(data: data, filePath: filePath)
        try await context?.checkCancellation()
        
        if !skipLogging {
            vrmLog("[VRMModel] Parsed GLTF document")
        }

        // Check for VRM 1.0 (VRMC_vrm) or VRM 0.0 (VRM)
        let vrmExtension = document.extensions?["VRMC_vrm"] ?? document.extensions?["VRM"]
        guard let vrmExtension = vrmExtension else {
            throw VRMError.missingVRMExtension(
                filePath: filePath,
                suggestion: "Ensure this file is a VRM model exported with proper VRM extensions. If it's a regular glTF/GLB file, convert it to VRM format using VRM exporter tools."
            )
        }

        await context?.updatePhase(.parsingVRMExtension, progress: 0.5)
        
        let vrmParser = VRMExtensionParser()
        let model = try vrmParser.parseVRMExtension(vrmExtension, document: document, filePath: filePath)
        model.device = device
        
        await context?.updatePhase(.parsingVRMExtension, progress: 1.0)
        
        // Load resources with buffer data
        try await model.loadResources(binaryData: binaryData, context: context)

        // Initialize SpringBone GPU system if device and spring bone data present
        if let device = device, model.springBone != nil {
            await context?.updatePhase(.initializingPhysics, progress: 0.5)
            try model.initializeSpringBoneGPUSystem(device: device)
            await context?.updatePhase(.initializingPhysics, progress: 1.0)
        }
        
        await context?.updatePhase(.complete, progress: 1.0)

        return model
    }

    private func loadResources(
        binaryData: Data? = nil,
        context: VRMLoadingContext? = nil
    ) async throws {
        let skipLogging = context?.options.optimizations.contains(.skipVerboseLogging) ?? false
        let useBufferPreloading = context?.options.optimizations.contains(.preloadBuffers) ?? false
        
        if !skipLogging {
            vrmLog("[VRMModel] Starting loadResources")
        }
        
        // === Loading Phase: Buffer Preloading ===
        var preloadedBuffers: [Int: Data]?
        if useBufferPreloading {
            await context?.updatePhase(.preloadingBuffers, progress: 0)
            
            if !skipLogging {
                vrmLog("[VRMModel] Preloading buffers in parallel...")
            }
            
            let preloader = BufferPreloader(document: gltf, baseURL: baseURL)
            preloadedBuffers = await preloader.preloadAllBuffers(binaryData: binaryData)
            
            if !skipLogging {
                vrmLog("[VRMModel] ✅ Preloaded \(preloadedBuffers?.count ?? 0) buffers")
            }
            
            await context?.updatePhase(.preloadingBuffers, progress: 1.0)
        }
        
        let bufferLoader = BufferLoader(
            document: gltf,
            binaryData: binaryData,
            baseURL: baseURL,
            preloadedData: preloadedBuffers
        )

        // Identify which textures are used as normal maps (need linear format, not sRGB)
        var normalMapTextureIndices = Set<Int>()
        if !skipLogging {
            vrmLog("[VRMModel] 🔍 Scanning \(gltf.materials?.count ?? 0) materials for normal map textures...")
        }
        for (matIdx, material) in (gltf.materials ?? []).enumerated() {
            let matName = material.name ?? "material_\(matIdx)"
            if let normalTexture = material.normalTexture {
                normalMapTextureIndices.insert(normalTexture.index)
                if !skipLogging {
                    vrmLog("[VRMModel] ⚠️ Material '\(matName)' uses texture \(normalTexture.index) as NORMAL MAP (will use linear format)")
                }
            }
            if !skipLogging {
                if let baseColorTex = material.pbrMetallicRoughness?.baseColorTexture {
                    vrmLog("[VRMModel] ✅ Material '\(matName)' uses texture \(baseColorTex.index) as BASE COLOR (will use sRGB)")
                }
            }
        }
        if !skipLogging {
            vrmLog("[VRMModel] 📊 Normal map texture indices: \(normalMapTextureIndices.sorted())")
        }

        // === Loading Phase: Textures ===
        let textureCount = gltf.textures?.count ?? 0
        await context?.updatePhase(.loadingTextures, totalItems: textureCount)
        
        if !skipLogging {
            vrmLog("[VRMModel] Loading \(textureCount) textures")
        }
        
        if let device = device {
            let useParallelLoading = context?.options.optimizations.contains(.parallelTextureLoading) ?? false
            
            if useParallelLoading && textureCount > 1 {
                // Use parallel texture loader for better performance
                if !skipLogging {
                    vrmLog("[VRMModel] Using parallel texture loading (\(textureCount) textures)")
                }
                
                let parallelLoader = ParallelTextureLoader(
                    device: device,
                    bufferLoader: bufferLoader,
                    document: gltf,
                    baseURL: baseURL,
                    maxConcurrentLoads: min(4, textureCount)
                )
                
                let indices = Array(0..<textureCount)
                let loadedTextures = await parallelLoader.loadTexturesParallel(
                    indices: indices,
                    normalMapIndices: normalMapTextureIndices
                ) { completed, total in
                    Task {
                        await context?.updateProgress(
                            itemsCompleted: completed,
                            totalItems: total
                        )
                    }
                }
                
                // Build textures array in order
                var loadedCount = 0
                for textureIndex in 0..<textureCount {
                    let textureName = gltf.textures?[safe: textureIndex]?.name ?? "texture_\(textureIndex)"
                    if let mtlTexture = loadedTextures[textureIndex] {
                        let vrmTexture = VRMTexture(name: textureName)
                        vrmTexture.mtlTexture = mtlTexture
                        textures.append(vrmTexture)
                        loadedCount += 1
                    } else {
                        textures.append(VRMTexture(name: textureName))
                    }
                }
                
                if !skipLogging {
                    vrmLog("[VRMModel] ✅ Parallel texture loading complete: \(loadedCount)/\(textureCount) loaded")
                }
            } else {
                // Sequential loading (original implementation)
                let textureLoader = TextureLoader(device: device, bufferLoader: bufferLoader, document: gltf, baseURL: baseURL)
                for textureIndex in 0..<textureCount {
                    try await context?.checkCancellation()
                    await context?.updateProgress(
                        itemsCompleted: textureIndex,
                        totalItems: textureCount
                    )
                    
                    let isNormalMap = normalMapTextureIndices.contains(textureIndex)
                    let useSRGB = !isNormalMap
                    let textureName = gltf.textures?[safe: textureIndex]?.name ?? "texture_\(textureIndex)"
                    
                    if let mtlTexture = try await textureLoader.loadTexture(at: textureIndex, sRGB: useSRGB) {
                        let vrmTexture = VRMTexture(name: textureName)
                        vrmTexture.mtlTexture = mtlTexture
                        textures.append(vrmTexture)
                    } else {
                        textures.append(VRMTexture(name: textureName))
                    }
                }
            }
        } else {
            // No device, create empty texture placeholders
            for textureIndex in 0..<textureCount {
                let textureName = gltf.textures?[safe: textureIndex]?.name
                textures.append(VRMTexture(name: textureName))
            }
        }

        // === Loading Phase: Materials ===
        let materialCount = gltf.materials?.count ?? 0
        await context?.updatePhase(.loadingMaterials, totalItems: materialCount)
        
        if !skipLogging {
            vrmLog("[VRMModel] Loading \(materialCount) materials")
        }
        
        let useParallelMaterials = context?.options.optimizations.contains(.parallelMaterialLoading) ?? false
        
        if useParallelMaterials && materialCount > 1 {
            // Use parallel material loading
            if !skipLogging {
                vrmLog("[VRMModel] Using parallel material loading (\(materialCount) materials)")
            }
            
            let parallelLoader = ParallelMaterialLoader(
                document: gltf,
                textures: textures,
                vrm0MaterialProperties: vrm0MaterialProperties,
                vrmVersion: specVersion
            )
            
            let indices = Array(0..<materialCount)
            let loadedMaterials = await parallelLoader.loadMaterialsParallel(
                indices: indices
            ) { completed, total in
                Task {
                    await context?.updateProgress(
                        itemsCompleted: completed,
                        totalItems: total
                    )
                }
            }
            
            // Build materials array in order
            var loadedCount = 0
            for materialIndex in 0..<materialCount {
                if let material = loadedMaterials[materialIndex] {
                    materials.append(material)
                    loadedCount += 1
                }
            }
            
            if !skipLogging {
                vrmLog("[VRMModel] ✅ Parallel material loading complete: \(loadedCount)/\(materialCount) loaded")
            }
        } else {
            // Sequential loading
            for materialIndex in 0..<materialCount {
                try await context?.checkCancellation()
                await context?.updateProgress(itemsCompleted: materialIndex, totalItems: materialCount)
                
                if let gltfMaterial = gltf.materials?[safe: materialIndex] {
                    let vrm0Prop = materialIndex < vrm0MaterialProperties.count ? vrm0MaterialProperties[materialIndex] : nil
                    let material = VRMMaterial(from: gltfMaterial, textures: textures, vrm0MaterialProperty: vrm0Prop, vrmVersion: specVersion)
                    materials.append(material)
                }
            }
        }

        // === Loading Phase: Meshes ===
        let meshCount = gltf.meshes?.count ?? 0
        await context?.updatePhase(.loadingMeshes, totalItems: meshCount)
        
        if !skipLogging {
            vrmLog("[VRMModel] Loading \(meshCount) meshes")
        }
        
        let useParallelMeshLoading = context?.options.optimizations.contains(.parallelMeshLoading) ?? false
        
        if useParallelMeshLoading && meshCount > 1 {
            // Use parallel mesh loading for better performance
            if !skipLogging {
                vrmLog("[VRMModel] Using parallel mesh loading (\(meshCount) meshes)")
            }
            
            let parallelLoader = ParallelMeshLoader(
                device: device,
                document: gltf,
                bufferLoader: bufferLoader
            )
            
            let indices = Array(0..<meshCount)
            let loadedMeshes = await parallelLoader.loadMeshesParallel(
                indices: indices
            ) { completed, total in
                Task {
                    await context?.updateProgress(
                        itemsCompleted: completed,
                        totalItems: total
                    )
                }
            }
            
            // Build meshes array in order
            var loadedCount = 0
            for meshIndex in 0..<meshCount {
                if let mesh = loadedMeshes[meshIndex] {
                    meshes.append(mesh)
                    loadedCount += 1
                }
            }
            
            if !skipLogging {
                vrmLog("[VRMModel] ✅ Parallel mesh loading complete: \(loadedCount)/\(meshCount) loaded")
            }
        } else {
            // Sequential loading
            for meshIndex in 0..<meshCount {
                try await context?.checkCancellation()
                await context?.updateProgress(itemsCompleted: meshIndex, totalItems: meshCount)
                
                if let gltfMesh = gltf.meshes?[safe: meshIndex] {
                    let mesh = try await VRMMesh.load(from: gltfMesh, document: gltf, device: device, bufferLoader: bufferLoader)
                    meshes.append(mesh)
                }
            }
        }

        // === Loading Phase: Hierarchy ===
        await context?.updatePhase(.buildingHierarchy, progress: 0)
        try await context?.checkCancellation()
        buildNodeHierarchy()
        await context?.updatePhase(.buildingHierarchy, progress: 1.0)

        // === Loading Phase: Skins ===
        let skinCount = gltf.skins?.count ?? 0
        await context?.updatePhase(.loadingSkins, totalItems: skinCount)
        
        for skinIndex in 0..<skinCount {
            try await context?.checkCancellation()
            await context?.updateProgress(itemsCompleted: skinIndex, totalItems: skinCount)
            
            if let gltfSkin = gltf.skins?[skinIndex] {
                let skin = try VRMSkin(from: gltfSkin, nodes: nodes, document: gltf, bufferLoader: bufferLoader)
                skins.append(skin)
            }
        }

        // IRON DOME: Sanitize joint indices
        await context?.updatePhase(.sanitizingJoints, progress: 0.5)
        sanitizeAllMeshJoints()
        await context?.updatePhase(.sanitizingJoints, progress: 1.0)
    }

    /// "Iron Dome" joint sanitization - ensures all mesh joint indices are within valid bounds.
    ///
    /// This is called after skins are loaded, when we know the actual bone count for each skin.
    /// It iterates through all node->mesh->skin associations and sanitizes any out-of-bounds
    /// joint indices, preventing vertex explosions from sentinel values (65535) or
    /// indices that exceed the skeleton size.
    private func sanitizeAllMeshJoints() {
        guard !skins.isEmpty else { return }

        var totalSanitized = 0

        // Iterate through nodes that have both mesh and skin
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

            // Sanitize each primitive in the mesh
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

    /// Finds a node by its normalized name using O(1) hash table lookup.
    ///
    /// This method is optimized for the animation system which needs fast bone lookups.
    /// Names are normalized by lowercasing and removing underscores/periods.
    ///
    /// - Parameter normalizedName: The normalized node name (lowercase, no underscores or periods).
    /// - Returns: The matching node, or `nil` if not found.
    ///
    /// ## Example
    /// ```swift
    /// // "LeftUpperArm" -> "leftupperarm"
    /// if let node = model.findNodeByNormalizedName("leftupperarm") {
    ///     node.rotation = newRotation
    /// }
    /// ```
    public func findNodeByNormalizedName(_ normalizedName: String) -> VRMNode? {
        return nodeLookupTable[normalizedName]
    }

    // MARK: - SpringBone GPU System

    /// Expand VRM 0.0 spring bone chains by traversing node hierarchy
    /// In VRM 0.0, the bones array contains ROOT bone indices, and all descendants should become joints
    /// This mimics three-vrm's root.traverse() behavior
    /// IMPORTANT: Uses DFS to maintain parent-child ordering within each chain
    public func expandVRM0SpringBoneChains() {
        guard var springBone = springBone else { return }

        var expandedSprings: [VRMSpring] = []

        for spring in springBone.springs {
            // For each root in the spring, create a separate chain with proper ordering
            for rootJoint in spring.joints {
                guard rootJoint.node < nodes.count else { continue }
                let rootNode = nodes[rootJoint.node]

                // DFS traversal to build chain in parent-child order
                var chainJoints: [VRMSpringJoint] = []
                traverseChainDFS(node: rootNode, settings: rootJoint, joints: &chainJoints)

                if chainJoints.count >= 2 {
                    // Create a new spring for this chain
                    var chainSpring = spring
                    chainSpring.joints = chainJoints
                    expandedSprings.append(chainSpring)
                    vrmLog("[SpringBone] Created chain from root '\(rootNode.name ?? "?")': \(chainJoints.count) joints")
                }
            }
        }

        // Only replace if we expanded
        if !expandedSprings.isEmpty {
            let originalCount = springBone.springs.reduce(0) { $0 + $1.joints.count }
            let expandedCount = expandedSprings.reduce(0) { $0 + $1.joints.count }
            if expandedCount > originalCount {
                springBone.springs = expandedSprings
                self.springBone = springBone
                vrmLog("[SpringBone] Expanded VRM 0.0: \(originalCount) → \(expandedCount) joints across \(expandedSprings.count) chains")
            }
        }
    }

    /// DFS traversal to build a chain in correct parent-child order
    private func traverseChainDFS(node: VRMNode, settings: VRMSpringJoint, joints: inout [VRMSpringJoint]) {
        guard let nodeIndex = nodes.firstIndex(where: { $0 === node }) else { return }

        // Create joint for this node
        var joint = VRMSpringJoint(node: nodeIndex)
        joint.stiffness = settings.stiffness
        joint.gravityPower = settings.gravityPower
        joint.dragForce = settings.dragForce
        joint.hitRadius = settings.hitRadius
        joint.gravityDir = settings.gravityDir
        joints.append(joint)

        // Recurse to children (DFS maintains order)
        for child in node.children {
            traverseChainDFS(node: child, settings: settings, joints: &joints)
        }
    }

    public func initializeSpringBoneGPUSystem(device: MTLDevice) throws {
        guard let springBone = springBone else {
            return // No SpringBone data in this model
        }

        // Expand VRM 0.0 chains (no-op for VRM 1.0 which already has full joint lists)
        expandVRM0SpringBoneChains()

        // Re-read after expansion
        guard let expandedSpringBone = self.springBone else { return }

        // Count total bones from all springs
        var totalBones = 0
        for spring in expandedSpringBone.springs {
            totalBones += spring.joints.count
        }

        // Count colliders
        let totalSpheres = expandedSpringBone.colliders.filter {
            if case .sphere = $0.shape { return true }
            return false
        }.count

        let totalCapsules = expandedSpringBone.colliders.filter {
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
        // settlingFrames: 120 frames (~1 second) to let bones settle with gravity before enabling inertia compensation
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
            numCapsules: UInt32(totalCapsules),
            settlingFrames: 120
        )

        // TODO: Populate bone parameters, rest lengths, and colliders
        // This will be implemented in the compute system
    }

    // MARK: - Floor Plane Colliders

    /// Adds a horizontal floor plane collider at the specified Y position.
    ///
    /// Floor planes prevent spring bone chains (hair, clothing) from passing through the ground.
    /// The plane extends infinitely in the X and Z directions.
    ///
    /// - Parameter floorY: The Y position of the floor in world space (typically 0).
    ///
    /// ## Example
    /// ```swift
    /// model.setFloorPlane(at: 0.0)  // Ground level
    /// ```
    public func setFloorPlane(at floorY: Float) {
        let floor = PlaneCollider(floorY: floorY)
        springBoneBuffers?.setPlaneColliders([floor])
        springBoneGlobalParams?.numPlanes = 1
    }

    /// Adds a floor plane collider from an ARKit plane anchor transform.
    ///
    /// Use this method when integrating with ARKit plane detection to create
    /// physics-accurate floor collision from detected surfaces.
    ///
    /// - Parameter transform: The `ARPlaneAnchor.transform` matrix.
    public func setFloorPlane(arkitTransform transform: simd_float4x4) {
        let floor = PlaneCollider(arkitTransform: transform)
        springBoneBuffers?.setPlaneColliders([floor])
        springBoneGlobalParams?.numPlanes = 1
    }

    /// Removes the floor plane collider.
    ///
    /// Call this when the avatar is no longer grounded (e.g., jumping, flying).
    public func removeFloorPlane() {
        springBoneBuffers?.setPlaneColliders([])
        springBoneGlobalParams?.numPlanes = 0
    }

    /// Recalculates world transforms for all nodes based on their local transforms.
    ///
    /// Call this after modifying node local transforms (translation, rotation, scale)
    /// to propagate changes through the hierarchy. This is automatically called
    /// during animation updates.
    ///
    /// - Complexity: O(n) where n is the number of nodes.
    public func updateNodeTransforms() {
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

    // MARK: - Convenience Methods for Bone Manipulation

    /// Sets the local rotation for a specific humanoid bone.
    ///
    /// This is a convenience method for directly manipulating bone rotations. The rotation
    /// is applied in the bone's local space (relative to its parent).
    ///
    /// - Parameters:
    ///   - rotation: The quaternion rotation to apply in local space
    ///   - bone: The humanoid bone to rotate (e.g., `.leftUpperArm`, `.head`)
    ///
    /// ## Example
    /// ```swift
    /// // Rotate the head to look left
    /// let rotation = simd_quatf(angle: Float.pi/4, axis: SIMD3<Float>(0, 1, 0))
    /// model.setLocalRotation(rotation, for: .head)
    /// ```
    public func setLocalRotation(_ rotation: simd_quatf, for bone: VRMHumanoidBone) {
        guard let humanoid = humanoid,
              let nodeIndex = humanoid.getBoneNode(bone),
              nodeIndex < nodes.count else {
            vrmLog("[VRMModel] Warning: Cannot set rotation for bone \(bone) - bone not found")
            return
        }
        
        withLock {
            nodes[nodeIndex].rotation = rotation
            nodes[nodeIndex].updateLocalMatrix()
        }
    }

    /// Gets the local rotation for a specific humanoid bone.
    ///
    /// - Parameter bone: The humanoid bone to query (e.g., `.leftUpperArm`, `.head`)
    /// - Returns: The current local rotation quaternion, or `nil` if the bone doesn't exist
    ///
    /// ## Example
    /// ```swift
    /// // Get current head rotation
    /// if let currentRotation = model.getLocalRotation(for: .head) {
    ///     print("Head is rotated: \(currentRotation)")
    /// }
    /// ```
    public func getLocalRotation(for bone: VRMHumanoidBone) -> simd_quatf? {
        guard let humanoid = humanoid,
              let nodeIndex = humanoid.getBoneNode(bone),
              nodeIndex < nodes.count else {
            return nil
        }
        
        return withLock {
            nodes[nodeIndex].rotation
        }
    }

    /// Sets the translation of the hips bone.
    ///
    /// This is commonly used for root motion - moving the character's entire body
    /// through the scene. The hips is the root of the humanoid skeleton.
    ///
    /// - Parameter translation: The translation vector in local space (typically relative to parent)
    ///
    /// ## Example
    /// ```swift
    /// // Move character up by 1 unit (jump)
    /// model.setHipsTranslation(SIMD3<Float>(0, 1, 0))
    /// ```
    public func setHipsTranslation(_ translation: simd_float3) {
        guard let humanoid = humanoid,
              let hipsIndex = humanoid.getBoneNode(.hips),
              hipsIndex < nodes.count else {
            vrmLog("[VRMModel] Warning: Cannot set hips translation - hips bone not found")
            return
        }
        
        withLock {
            nodes[hipsIndex].translation = translation
            nodes[hipsIndex].updateLocalMatrix()
        }
    }

    /// Gets the current translation of the hips bone.
    ///
    /// - Returns: The current hips translation in local space, or `nil` if hips bone doesn't exist
    ///
    /// ## Example
    /// ```swift
    /// // Get current hips position
    /// if let hipsPos = model.getHipsTranslation() {
    ///     print("Character is at: \(hipsPos)")
    /// }
    /// ```
    public func getHipsTranslation() -> simd_float3? {
        guard let humanoid = humanoid,
              let hipsIndex = humanoid.getBoneNode(.hips),
              hipsIndex < nodes.count else {
            return nil
        }
        
        return withLock {
            nodes[hipsIndex].translation
        }
    }
}

// MARK: - Supporting Classes

/// Humanoid bone configuration for a VRM avatar.
///
/// Maps standard humanoid bones (hips, spine, arms, legs, etc.) to node indices
/// in the model's scene graph. This enables animations to target bones by semantic
/// name rather than model-specific node names.
///
/// ## Required Bones
/// VRM requires these bones: hips, spine, head, and all arm/leg bones.
/// Use `validate()` to check if all required bones are present.
public class VRMHumanoid {
    /// Maps humanoid bone types to their node references.
    public var humanBones: [VRMHumanoidBone: VRMHumanBone] = [:]

    /// A reference to a humanoid bone's node.
    public struct VRMHumanBone {
        /// The index into `VRMModel.nodes` for this bone.
        public let node: Int

        public init(node: Int) {
            self.node = node
        }
    }

    public init() {}

    /// Returns the node index for a humanoid bone.
    ///
    /// - Parameter bone: The bone type to look up (e.g., `.hips`, `.leftHand`).
    /// - Returns: The node index, or `nil` if the bone isn't mapped.
    public func getBoneNode(_ bone: VRMHumanoidBone) -> Int? {
        return humanBones[bone]?.node
    }

    /// Validates that all required humanoid bones are present.
    ///
    /// - Parameter filePath: Optional file path for error messages.
    /// - Throws: `VRMError.missingRequiredBone` if a required bone is missing.
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

/// First-person camera configuration for VRM avatars.
///
/// Defines which meshes should be visible or hidden when rendering from the avatar's
/// perspective. This prevents the avatar's head from blocking the camera view.
public class VRMFirstPerson {
    /// Mesh visibility annotations for first-person rendering.
    public var meshAnnotations: [VRMMeshAnnotation] = []

    /// Annotation specifying how a mesh should be rendered in first-person view.
    public struct VRMMeshAnnotation {
        /// The node index of the annotated mesh.
        public let node: Int
        /// The visibility flag for this mesh.
        public let type: VRMFirstPersonFlag

        public init(node: Int, type: VRMFirstPersonFlag) {
            self.node = node
            self.type = type
        }
    }

    public init() {}
}

/// Eye gaze (look-at) configuration for VRM avatars.
///
/// Defines how the avatar's eyes track a target point, including the offset from the
/// head bone and range limits for horizontal and vertical eye movement.
public class VRMLookAt {
    /// The method used to control gaze (bone rotation or blend shapes).
    public var type: VRMLookAtType = .bone

    /// Offset from the head bone to the eye position in local space.
    public var offsetFromHeadBone: SIMD3<Float> = [0, 0, 0]

    /// Range map for inward horizontal eye movement.
    public var rangeMapHorizontalInner: VRMLookAtRangeMap = VRMLookAtRangeMap()

    /// Range map for outward horizontal eye movement.
    public var rangeMapHorizontalOuter: VRMLookAtRangeMap = VRMLookAtRangeMap()

    /// Range map for downward vertical eye movement.
    public var rangeMapVerticalDown: VRMLookAtRangeMap = VRMLookAtRangeMap()

    /// Range map for upward vertical eye movement.
    public var rangeMapVerticalUp: VRMLookAtRangeMap = VRMLookAtRangeMap()

    public init() {}
}

/// Facial expression configuration for VRM avatars.
///
/// Contains both preset expressions (happy, angry, sad, etc.) defined by the VRM spec
/// and custom expressions defined by the model creator.
///
/// ## Usage
/// ```swift
/// // Get a preset expression
/// if let happy = model.expressions?.preset[.happy] {
///     // Apply with VRMExpressionController
/// }
///
/// // Get a custom expression
/// if let wink = model.expressions?.custom["wink"] {
///     // Apply custom expression
/// }
/// ```
public class VRMExpressions {
    /// Standard VRM expressions (happy, angry, sad, surprised, blink, etc.).
    public var preset: [VRMExpressionPreset: VRMExpression] = [:]

    /// Model-specific custom expressions keyed by name.
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
    
    // Loading Errors
    case loadingCancelled
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
            
        case .loadingCancelled:
            return """
            ⚠️ Loading Cancelled
            
            The VRM model loading was cancelled by the user.
            
            Suggestion: If this was unexpected, check that:
            • The loading task wasn't explicitly cancelled
            • The parent Task wasn't cancelled
            • No timeout or cancellation token was triggered
            """
        }
    }
}