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

/// A loaded VRM avatar with GPU-resident geometry, materials, and runtime state.
///
/// `VRMModel` is the central type produced by ``load(from:device:options:)``
/// and consumed by ``VRMRenderer``. It owns the scene graph (``nodes``),
/// mesh and material arrays, textures, skinning data, optional spring-bone
/// physics state, and the VRM-specific subsystems exposed via ``humanoid``,
/// ``firstPerson``, ``lookAt``, and ``expressions``.
///
/// ## Lifecycle
/// 1. **Load** with ``VRMModel/load(from:device:options:)`` or
///    ``VRMModel/load(from:filePath:device:)``. Pass a Metal device to make
///    the model immediately ready for rendering; omit it to keep the model
///    CPU-only (for headless inspection or offline transforms).
/// 2. **Use** the model with ``VRMRenderer`` and the animation/expression
///    subsystems. Mutations to nodes or expression weights should be
///    coordinated via ``withLock(_:)`` when accessed from multiple threads.
/// 3. **Release** by letting the model deallocate; all Metal resources are
///    owned and freed automatically.
///
/// ## Thread Safety
/// `VRMModel` is declared `@unchecked Sendable` and coordinates concurrent
/// access via an internal `NSLock` that ``AnimationPlayer`` and ``VRMRenderer``
/// acquire automatically. Application code that mutates the model's public
/// collections (``nodes``, ``meshes``, ``materials``) from background threads
/// must do so inside ``withLock(_:)``.
///
/// ```swift
/// model.withLock {
///     model.nodes[headIndex].rotation = simd_quatf(angle: 0.1, axis: [0, 1, 0])
/// }
/// ```
///
/// - SeeAlso: ``VRMRenderer``, ``VRMLoadingOptions``, ``VRMError``.
public class VRMModel: @unchecked Sendable {
    // MARK: - Thread Safety
    let lock = NSLock()

    /// Runs `body` while holding the model's internal lock, serializing access with the renderer and animation player.
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

    /// Node constraints for twist bones and other constrained nodes.
    ///
    /// VRM 1.0 parses these from VRMC_node_constraint extension.
    /// VRM 0.0 synthesizes constraints automatically from humanoid bone definitions.
    public var nodeConstraints: [VRMNodeConstraint] = []

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

    /// Texture indices used as outline-width mask (linear R8, not sRGB).
    public var outlineWidthMaskTextureIndices: Set<Int> = []

    /// Texture indices used as UV animation mask (linear R8, not sRGB).
    public var uvAnimationMaskTextureIndices: Set<Int> = []

    // PERFORMANCE: Pre-computed node lookup table (normalized names)
    private var nodeLookupTable: [String: VRMNode] = [:]

    // MARK: - Initialization

    /// Creates a VRM model from already-parsed VRM extension data and a glTF document.
    ///
    /// Application code rarely calls this directly — prefer
    /// ``load(from:device:options:)`` which parses the file, populates GPU
    /// resources, and wires up physics in one call.
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

    /// Union of all primitive local-space AABBs, computed from
    /// `VRMPrimitive.localMin/localMax`. Used by the renderer for whole-model
    /// frustum culling without touching GPU buffers.
    ///
    /// Populated lazily on first access, or eagerly via
    /// `finalizeModelLocalBounds()` which `VRMModel.load(...)` calls once all
    /// primitives are populated. Access is guarded by `_boundsLock` so reads
    /// from any thread are safe (the model is `@unchecked Sendable`).
    private var _cachedLocalBounds: (min: SIMD3<Float>, max: SIMD3<Float>)?
    private let _boundsLock = NSLock()

    /// Bind-pose model-space AABB across every primitive's `localMin`/`localMax`. Computed lazily and cached.
    public var modelLocalBounds: (min: SIMD3<Float>, max: SIMD3<Float>) {
        _boundsLock.lock()
        defer { _boundsLock.unlock() }
        if let b = _cachedLocalBounds { return b }
        let bounds = computeModelLocalBoundsLocked()
        _cachedLocalBounds = bounds
        return bounds
    }

    /// Eagerly computes and caches `modelLocalBounds`. Call this once after
    /// the model's meshes are populated (e.g. at the end of `load(...)`) so
    /// subsequent concurrent reads from any thread hit the cached value
    /// without contending on the lazy-compute path.
    public func finalizeModelLocalBounds() {
        _boundsLock.lock()
        defer { _boundsLock.unlock() }
        _cachedLocalBounds = computeModelLocalBoundsLocked()
    }

    /// Caller must hold `_boundsLock`.
    private func computeModelLocalBoundsLocked() -> (min: SIMD3<Float>, max: SIMD3<Float>) {
        var lo = SIMD3<Float>(repeating: Float.infinity)
        var hi = SIMD3<Float>(repeating: -Float.infinity)
        var found = false
        for mesh in meshes {
            for primitive in mesh.primitives where primitive.vertexCount > 0 {
                lo = simd_min(lo, primitive.localMin)
                hi = simd_max(hi, primitive.localMax)
                found = true
            }
        }
        if !found {
            lo = SIMD3<Float>(-0.5, 0, -0.5)
            hi = SIMD3<Float>(0.5, 1.8, 0.5)
        }
        return (min: lo, max: hi)
    }

    /// Whole-model frustum cull. Returns `true` when the model's bind-pose
    /// `modelLocalBounds`, transformed by `modelMatrix`, lies entirely outside
    /// `frustum`. Constant-time — does not touch GPU buffers, the node
    /// hierarchy, or animation state, so it is safe (and intended) to call
    /// before spring-bone simulation, skinning, and `VRMRenderer.draw(...)`
    /// to skip those costs for off-screen instances.
    ///
    /// The returned answer is approximate at the bind-pose extent: an avatar
    /// that animates outside its bind-pose AABB (e.g. raised arms beyond the
    /// rest extent) may be culled when partially visible. For typical idle /
    /// locomotion clips the bind-pose envelope is conservative enough.
    public func isOutsideFrustum(_ frustum: Frustum, modelMatrix: matrix_float4x4) -> Bool {
        let local = modelLocalBounds
        let world = AABBTransform.worldAABB(
            localMin: local.min,
            localMax: local.max,
            modelMatrix: modelMatrix)
        return frustum.cullsAABB(min: world.min, max: world.max)
    }

    /// Calculates an axis-aligned bounding box from every mesh vertex.
    ///
    /// Unlike ``modelLocalBounds``, this method walks the actual GPU vertex
    /// buffers and is exact (and considerably slower). Prefer
    /// ``modelLocalBounds`` for per-frame culling.
    ///
    /// - Parameter includeAnimated: When `true`, transforms vertices by their
    ///   owning node's current world matrix; when `false`, uses bind-pose positions.
    /// - Returns: Min/max corners of the resulting AABB in model space.
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

    /// Estimates a skinned bounding box from the current skeleton pose plus humanoid anchor bones.
    ///
    /// Cheaper than ``calculateBoundingBox(includeAnimated:)`` because it only
    /// touches node world positions. Returns the AABB along with its center
    /// and size for camera framing.
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
        let skipLogging = context?.options.optimizations.contains(.skipVerboseLogging) ?? false
        
        if !skipLogging {
            vrmLog("[VRMModel] Starting load from data")
        }
        
        let parser = GLTFParser()
        let (document, binaryData) = try parser.parse(data: data, filePath: filePath)
        try await context?.checkCancellation()
        
        if !skipLogging {
            vrmLog("[VRMModel] Parsed GLTF document")
        }

        // Validate extensionsRequired against the set of extensions this runtime supports.
        // Per glTF spec §3.2: if any required extension is unsupported, loading MUST fail.
        let supportedExtensions: Set<String> = [
            "VRMC_vrm",
            "VRMC_springBone",
            "VRMC_node_constraint",
            "VRMC_materials_mtoon",
            "KHR_texture_transform",
            "KHR_materials_unlit",
        ]
        if let required = document.extensionsRequired {
            let unsupported = Set(required).subtracting(supportedExtensions)
            if !unsupported.isEmpty {
                throw GLTFError.unsupportedRequiredExtension(unsupported.sorted())
            }
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
            let augmentColliders = context?.options.augmentSpringBoneColliders ?? true
            try model.initializeSpringBoneGPUSystem(device: device, augmentColliders: augmentColliders)
            await context?.updatePhase(.initializingPhysics, progress: 1.0)
        }

        // All meshes/primitives are now populated; pre-compute the model AABB so
        // subsequent reads from any thread hit the cached value (#153).
        model.finalizeModelLocalBounds()

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

        // Identify which textures need linear format (not sRGB):
        // - Normal maps (geometrical data, not color)
        // - outlineWidthMultiplyTexture (linear R8 per MToon spec)
        // - uvAnimationMaskTexture (linear R8 per MToon spec)
        var normalMapTextureIndices = Set<Int>()
        var outlineWidthMaskTextureIndicesLocal = Set<Int>()
        var uvAnimationMaskTextureIndicesLocal = Set<Int>()
        if !skipLogging {
            vrmLog("[VRMModel] 🔍 Scanning \(gltf.materials?.count ?? 0) materials for linear textures...")
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
            if let extensions = material.extensions,
               let mtoonExt = extensions["VRMC_materials_mtoon"] as? [String: Any] {
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
            vrmLog("[VRMModel] 📊 Normal map texture indices: \(normalMapTextureIndices.sorted())")
        }
        let allLinearTextureIndices = normalMapTextureIndices
            .union(outlineWidthMaskTextureIndicesLocal)
            .union(uvAnimationMaskTextureIndicesLocal)

        outlineWidthMaskTextureIndices = outlineWidthMaskTextureIndicesLocal
        uvAnimationMaskTextureIndices = uvAnimationMaskTextureIndicesLocal

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
                    normalMapIndices: allLinearTextureIndices
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
                    
                    let isLinear = allLinearTextureIndices.contains(textureIndex)
                    let useSRGB = !isLinear
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

        // One limiter shared by every primitive decode across all meshes gives a
        // true global cap on concurrent decodes (and thus peak live decode memory),
        // independent of how the across-mesh and intra-mesh task groups multiply.
        // Sized to the running machine's cores; only leaf decodes acquire it.
        let decodeLimiter = AsyncConcurrencyLimiter(limit: ProcessInfo.processInfo.activeProcessorCount)

        if useParallelMeshLoading && meshCount > 1 {
            // Use parallel mesh loading for better performance
            if !skipLogging {
                vrmLog("[VRMModel] Using parallel mesh loading (\(meshCount) meshes)")
            }

            let parallelLoader = ParallelMeshLoader(
                device: device,
                document: gltf,
                bufferLoader: bufferLoader,
                concurrencyLimiter: decodeLimiter
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
                    let mesh = try await VRMMesh.load(from: gltfMesh, document: gltf, device: device, bufferLoader: bufferLoader, concurrencyLimiter: decodeLimiter)
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

        // VRM 0.0 → 1.0: companion pass to the per-node TRS conjugation in
        // `buildNodeHierarchy()`. Must run after skins load their IBMs from
        // the glTF accessor.
        applyVRM0InverseBindMatrixConjugation()
    }

    /// VRM 0.0 → 1.0: rotate every skin's `inverseBindMatrix` by `Ry180` (left-multiply).
    ///
    /// Companion to the deliberate VRM 0.x → +Z-facing deviation in
    /// `buildNodeHierarchy()` (see #299, closed as not planned). That pass conjugates each node's local
    /// TRS so joint world matrices end up as `Ry180 · M_old · Ry180⁻¹`.
    /// `inverseBindMatrices` are loaded later from the glTF accessor in the
    /// original VRM 0.x frame, so `jointMatrix = joint.worldMatrix · IBM` would
    /// expand to `Ry180 · M_old · Ry180⁻¹ · M_old⁻¹` — a non-trivial per-joint
    /// translation (`Ry180·p − p` for a joint at position `p` with identity
    /// rotation) rather than the intended `Ry180`.  Left-multiplying every IBM by
    /// `Ry180` cancels the stray `Ry180⁻¹` so the skinning result is
    /// `Ry180 · vertex_world_old` at every pose, matching the render-time Y-axis
    /// rotation this load-time pass replaces.
    private func applyVRM0InverseBindMatrixConjugation() {
        guard isVRM0 else { return }
        // 180° rotation about Y as a 4x4: negate the X and Z components of every
        // column. Cheap to write inline so the math is auditable next to the
        // node-side conjugation in `buildNodeHierarchy()`.
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

        // VRM 0.0 → VRM 1.0 coordinate conversion.
        //
        // DELIBERATE DEVIATION from the VRM 0.x specification (#299, closed as not planned).
        // The VRM 0.x spec says the model faces -Z in glTF coordinates. VRMMetalKit
        // instead rotates every VRM 0.x model 180° around Y at load time so that it
        // faces +Z, matching the VRM 1.0 convention.
        //
        // Rationale:
        //   1. Most VRM 0.x content was authored in Unity and previewed in viewers
        //      that also apply a Z-axis flip; rendering in the raw -Z orientation
        //      produces a back-of-head view under a standard +Z-facing camera.
        //   2. A single consistent +Z-facing coordinate space lets physics, animation,
        //      culling, ARKit body tracking, and client camera code share one convention
        //      regardless of whether the source file is VRM 0.x or VRM 1.0.
        //   3. Left limbs end up at positive X, matching VRM 1.0 humanoid layout.
        //
        // Consequence: VRM 0.x models load visually consistent with VRM 1.0 models and
        // with typical Unity-origin previews, but they do not strictly preserve the
        // spec-mandated -Z forward direction. The matching `inverseBindMatrices` pass
        // runs after skins are loaded — see `applyVRM0InverseBindMatrixConjugation()`;
        // without it skinning at rest would displace vertices by `Ry180·p − p` for each
        // joint.
        if isVRM0 {
            for node in nodes {
                // Conjugate local rotation by 180° Y: (x, y, z, w) → (-x, y, -z, w)
                node.rotation = simd_normalize(
                    simd_quatf(ix: -node.rotation.imag.x,
                               iy:  node.rotation.imag.y,
                               iz: -node.rotation.imag.z,
                               r:   node.rotation.real)
                )
                // Rotate translation: (x, y, z) → (-x, y, -z)
                node.translation = SIMD3<Float>(-node.translation.x,
                                                 node.translation.y,
                                                -node.translation.z)
                // Update bind pose storage so resetToBindPose() stays consistent
                node.initialRotation = node.rotation
                node.initialTranslation = node.translation
                // Scale magnitudes are unchanged under 180° rotation
                node.updateLocalMatrix()
            }
            // Recalculate world transforms after mutating every local matrix
            for node in nodes where node.parent == nil {
                node.updateWorldTransform()
            }
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

    /// Expands VRM 0.0 spring-bone chains by traversing the node hierarchy from each root joint.
    ///
    /// VRM 0.0 stores only root joints; all descendant nodes are implicit
    /// chain members. This method matches three-vrm's `root.traverse()`
    /// behavior using a DFS walk that preserves parent-to-child ordering.
    /// No-op on VRM 1.0 models, which already encode the full joint list.
    public func expandVRM0SpringBoneChains() {
        // VRMC_springBone-1.0 already encodes the full chain in springs[].joints.
        // Re-expanding would treat every joint as a chain root and inflate the
        // joint count (see issue #182).
        guard isVRM0 else { return }
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

    /// Allocates GPU buffers and seeds global parameters for the spring-bone simulation.
    ///
    /// Called automatically by ``load(from:device:options:)`` when both a
    /// Metal device and spring-bone data are present. Per-bone parameters,
    /// rest lengths, and collider data are populated separately by
    /// `SpringBoneComputeSystem.populateSpringBoneData(model:)` once the
    /// renderer's compute system has been created.
    ///
    /// - Parameters:
    ///   - device: Metal device used to allocate spring-bone buffers.
    ///   - augmentColliders: When true, synthesizes additive bone-derived
    ///     colliders (issue #309) and persists them on `springBone.syntheticColliders`
    ///     before sizing GPU buffers. Authored colliders are never mutated.
    /// - Throws: An error if buffer allocation fails.
    public func initializeSpringBoneGPUSystem(device: MTLDevice, augmentColliders: Bool = true) throws {
        guard springBone != nil else {
            return // No SpringBone data in this model
        }

        // Expand VRM 0.0 chains (no-op for VRM 1.0 which already has full joint lists)
        expandVRM0SpringBoneChains()

        // Re-read after expansion
        guard var expandedSpringBone = self.springBone else { return }

        // Synthesize additive colliders (issue #309) BEFORE counting so the GPU
        // buffers are sized to hold authored + synthetic colliders. The upload
        // path hard-guards `colliders.count == numCapsules`, so the count seeded
        // here must match the count uploaded later in
        // `SpringBoneComputeSystem.populateSpringBoneData(model:)`.
        if augmentColliders {
            expandedSpringBone.syntheticColliders = SpringBoneColliderAugmentor.synthesize(model: self)
        } else {
            expandedSpringBone.syntheticColliders = []
        }
        self.springBone = expandedSpringBone

        // Count total bones from all springs
        var totalBones = 0
        for spring in expandedSpringBone.springs {
            totalBones += spring.joints.count
        }

        // Count colliders. Inverted (`insideSphere` / `insideCapsule`) variants
        // from `VRMC_springBone_extended_collider` share the same GPU buffer
        // layout as their non-inverted counterparts (an `inside` flag on the
        // collider struct selects the kernel's containment vs outside math),
        // so they count toward the same totals.
        // Count authored + synthetic colliders together — both share the same
        // GPU buffers, so allocation must cover the combined total.
        let allColliders = expandedSpringBone.colliders + expandedSpringBone.syntheticColliders
        let totalSpheres = allColliders.filter {
            switch $0.shape {
            case .sphere, .insideSphere: return true
            default: return false
            }
        }.count

        let totalCapsules = allColliders.filter {
            switch $0.shape {
            case .capsule, .insideCapsule: return true
            default: return false
            }
        }.count

        let totalPlanes = allColliders.filter {
            switch $0.shape {
            case .plane: return true
            default: return false
            }
        }.count

        // Initialize buffers
        springBoneBuffers = SpringBoneBuffers(device: device)
        springBoneBuffers?.allocateBuffers(
            numBones: totalBones,
            numSpheres: totalSpheres,
            numCapsules: totalCapsules,
            numPlanes: totalPlanes
        )

        // Initialize global parameters
        // settlingFrames: 120 frames (~1 second) to let bones settle with gravity before enabling inertia compensation
        springBoneGlobalParams = SpringBoneGlobalParams(
            gravity: VRMConstants.Physics.defaultGravity, // Additive external force; zero so per-joint gravityPower is the sole gravity source (#324)
            dtSub: 1.0 / 120.0, // 120Hz fixed substeps
            windAmplitude: 0.0,
            windFrequency: 1.0,
            windPhase: 0.0,
            windDirection: SIMD3<Float>(1, 0, 0),
            substeps: 2,
            numBones: UInt32(totalBones),
            numSpheres: UInt32(totalSpheres),
            numCapsules: UInt32(totalCapsules),
            numPlanes: UInt32(totalPlanes),
            settlingFrames: 120
        )

        // Bone parameters, rest lengths, and collider data are populated
        // separately by `SpringBoneComputeSystem.populateSpringBoneData(model:)`,
        // which is called by the renderer (see `VRMRenderer.swift` ~770) after
        // the renderer's compute system is created. This function only
        // allocates the GPU buffers and seeds the global params.
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

    /// Walks every mesh primitive and logs any index/accessor inconsistencies.
    ///
    /// Diagnostic tool used while debugging malformed glTF buffers; safe but
    /// noisy in production. Output goes through the package's `vrmLog` helper.
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

        /// Creates a humanoid bone reference pointing at the given node index.
        public init(node: Int) {
            self.node = node
        }
    }

    /// Creates an empty humanoid configuration. Populate ``humanBones`` to map bones to nodes.
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

        /// Creates a mesh annotation associating a node with a first-person visibility flag.
        public init(node: Int, type: VRMFirstPersonFlag) {
            self.node = node
            self.type = type
        }
    }

    /// Creates an empty first-person configuration. Populate ``meshAnnotations`` per mesh.
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

    /// Creates a look-at configuration with default range maps and zero head offset.
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

    /// Creates an empty expressions container. Populate ``preset`` and ``custom`` during loading.
    public init() {}
}

