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
import MetalKit
import simd
import QuartzCore  // For CACurrentMediaTime

/// VRMRenderer manages the rendering pipeline for VRM models using Metal.
///
/// ## Thread Safety
/// **Thread-safe (with conditions).** The renderer itself is thread-safe for command encoding,
/// and safe to use concurrently with `AnimationPlayer` updates on the same model because `VRMModel`
/// is now protected by an internal lock.
///
/// ### Concurrency Model:
/// - **Animation/Render Sync**: `VRMModel` uses an internal lock. `VRMRenderer` acquires this lock
///   during the draw command encoding phase. `AnimationPlayer` acquires it during updates.
///   This prevents data races on node transforms.
/// - **Metal Context**: You can encode commands from any thread.
///
/// ### Safe Usage Patterns:
/// ```swift
/// // ✅ SAFE: Animation on background thread
/// DispatchQueue.global().async {
///     animationPlayer.update(deltaTime: dt, model: model)
/// }
///
/// // ✅ SAFE: Rendering on main thread (concurrently)
/// renderer.render(in: view, commandBuffer: commandBuffer)
/// ```
///
/// - Note: Rendering blocks animation updates on the model for the duration of command encoding.
///   This is necessary to ensure the scene graph is consistent during drawing.
public final class VRMRenderer: NSObject, @unchecked Sendable {
    // OPTIMIZATION: Numeric key for morph buffer dictionary (avoids string interpolation)
    typealias MorphKey = UInt64

    // Helper wrapper to capture Metal buffers in @Sendable closures
    private final class SendableMTLBuffer: @unchecked Sendable {
        let buffer: MTLBuffer
        init(_ buffer: MTLBuffer) { self.buffer = buffer }
    }
    // Metal resources
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    // Pipeline states for different alpha modes (non-skinned)
    var opaquePipelineState: MTLRenderPipelineState?     // OPAQUE/MASK (no blending)
    var blendPipelineState: MTLRenderPipelineState?      // BLEND (blending enabled)
    var wireframePipelineState: MTLRenderPipelineState?  // WIREFRAME (debug mode)

    // Pipeline states for different alpha modes (skinned)
    var skinnedOpaquePipelineState: MTLRenderPipelineState?  // OPAQUE/MASK (no blending)
    var skinnedBlendPipelineState: MTLRenderPipelineState?   // BLEND (blending enabled)
    
    // Pipeline states for alpha-to-coverage (MASK materials with MSAA)
    var maskAlphaToCoveragePipelineState: MTLRenderPipelineState?      // Non-skinned
    var skinnedMaskAlphaToCoveragePipelineState: MTLRenderPipelineState? // Skinned
    
    // Multisample texture for MSAA render targets
    var multisampleTexture: MTLTexture?
    
    /// Returns true if multisampling is enabled (sampleCount > 1)
    var usesMultisampling: Bool { config.sampleCount > 1 }
    
    // MARK: - Depth Bias
    
    /// Calculator for material-specific depth bias values
    ///
    /// Depth bias resolves true Z-fighting between coplanar surfaces
    /// by pushing fragments toward the camera in depth buffer space.
    public lazy var depthBiasCalculator: DepthBiasCalculator = {
        DepthBiasCalculator(scale: config.depthBiasScale)
    }()

    // MARK: - Configuration

    /// Renderer configuration including strict mode validation level.
    ///
    /// Use `.warn` during development to catch issues, `.off` in production for performance.
    public var config = RendererConfig(strict: .off)
    var strictValidator: StrictValidator?

    /// The VRM model to render. Set via `loadModel(_:)`.
    public var model: VRMModel?

    /// Model rotation correction for VRM coordinate system differences.
    /// Standard camera setup: camera at +Z looking towards origin.
    /// VRM 0.0 (Unity) models face -Z (away from camera) → need 180° Y rotation.
    /// VRM 1.0 (glTF) models face +Z (towards camera) → no rotation needed.
    private var vrmVersionRotation: matrix_float4x4 {
        guard let model = model else { return matrix_identity_float4x4 }
        if model.isVRM0 {
            // VRM 0.0 faces -Z, rotate 180° around Y to face +Z (towards camera at +Z)
            return matrix_float4x4(simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 1, 0)))
        } else {
            // VRM 1.0 already faces +Z (towards camera at +Z), no rotation needed
            return matrix_identity_float4x4
        }
    }

    // MARK: - Debug Options

    /// Debug UV visualization mode.
    /// - 0: Off (normal rendering)
    /// - 1: UV gradient visualization
    /// - 2: Base color texture presence (red=missing, green=present)
    /// - 3: Base color factor only
    public var debugUVs: Int32 = 0

    /// Enable wireframe rendering mode for debugging geometry.
    public var debugWireframe: Bool = false

    // MARK: - 2.5D Rendering Mode

    /// Light normalization mode for multi-light setups
    public enum LightNormalizationMode {
        case automatic              // Auto-normalize when total intensity > 1.0 (default)
        case disabled               // No normalization (naive additive, for testing)
        case manual(Float)          // Custom normalization factor
    }

    /// Current light normalization mode
    public var lightNormalizationMode: LightNormalizationMode = .automatic

    /// Stored light directions (world-space, shader negates for NdotL calculation)
    /// VRM models face -Z after rotation. For front lighting, use positive Z direction.
    private var storedLightDirections: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>) = (
        SIMD3<Float>(0.2, 0.3, 0.9),   // Key light: front with slight right/above
        SIMD3<Float>(-0.3, 0.1, 0.9),  // Fill light: front-left
        SIMD3<Float>(0.0, -0.5, -0.85) // Rim light: from behind/above
    )

    /// Orthographic camera height in world units
    public var orthoSize: Float = 1.7 {
        didSet {
            if orthoSize <= 0 {
                vrmLog("[VRMRenderer] Warning: orthoSize must be positive, clamping \(orthoSize) to 0.1")
                orthoSize = max(0.1, orthoSize)
            }
        }
    }

    /// Global outline width scale factor.
    /// Multiplies per-material outline widths. Default (0.02) preserves material values.
    /// Set to 0 to disable all outlines.
    public var outlineWidth: Float = 0.02 {
        didSet {
            if outlineWidth < 0 {
                vrmLog("[VRMRenderer] Warning: outlineWidth cannot be negative, clamping \(outlineWidth) to 0")
                outlineWidth = max(0, outlineWidth)
            }
        }
    }

    /// Global outline color override (RGB). When non-zero, overrides per-material outline colors.
    /// Expression-driven overrides take precedence over this value.
    public var outlineColor: SIMD3<Float> = SIMD3<Float>(0, 0, 0)

    /// Use orthographic projection instead of perspective
    public var useOrthographic: Bool = false

    /// Field of view in degrees (for perspective projection)
    public var fovDegrees: Float = 60.0 {
        didSet {
            if fovDegrees <= 0 || fovDegrees >= 180 {
                let clampedValue = max(1.0, min(179.0, fovDegrees))
                vrmLog("[VRMRenderer] Warning: fovDegrees \(fovDegrees) out of range (0, 180), clamped to \(clampedValue)")
                fovDegrees = clampedValue
            }
        }
    }

    /// Calculate projection matrix based on useOrthographic flag
    /// - Parameter aspectRatio: Viewport aspect ratio (width / height)
    /// - Returns: Projection matrix for current settings
    public func makeProjectionMatrix(aspectRatio: Float) -> matrix_float4x4 {
        // Validate aspect ratio
        guard aspectRatio > 0 && aspectRatio.isFinite else {
            vrmLog("[VRMRenderer] Warning: Invalid aspectRatio \(aspectRatio), using default 1.0")
            return makeProjectionMatrix(aspectRatio: 1.0)
        }

        if useOrthographic {
            let halfHeight = orthoSize / 2.0
            let halfWidth = halfHeight * aspectRatio
            let width = halfWidth * 2.0
            let height = halfHeight * 2.0
            let nearZ: Float = 0.1
            let farZ: Float = 100.0
            let depth = farZ - nearZ
            // Metal uses reverse-Z with NDC Z in [0, 1]
            // Maps nearZ -> 1.0, farZ -> 0.0 in clip space
            return matrix_float4x4(columns: (
                SIMD4<Float>(2.0 / width, 0, 0, 0),
                SIMD4<Float>(0, 2.0 / height, 0, 0),
                SIMD4<Float>(0, 0, -1.0 / depth, 0),
                SIMD4<Float>(0, 0, farZ / depth, 1)
            ))
        } else {
            // Convert FOV from degrees to radians
            let fovy = fovDegrees * Float.pi / 180.0
            let ys = 1.0 / tan(fovy * 0.5)
            let xs = ys / aspectRatio
            let nearZ: Float = 0.1
            let farZ: Float = 100.0
            let zs = farZ / (nearZ - farZ)
            return matrix_float4x4(columns: (
                SIMD4<Float>(xs, 0, 0, 0),
                SIMD4<Float>(0, ys, 0, 0),
                SIMD4<Float>(0, 0, zs, -1),
                SIMD4<Float>(0, 0, zs * nearZ, 0)
            ))
        }
    }

    // MARK: - Lighting API

    /// Set a light source (0 = key, 1 = fill, 2 = rim/back)
    /// - Parameters:
    ///   - index: Light index (0-2)
    ///   - direction: Light direction in world space (will be normalized)
    ///   - color: Light color (RGB, typically 0-1 range)
    ///   - intensity: Light intensity multiplier (default 1.0)
    public func setLight(
        _ index: Int,
        direction: SIMD3<Float>,
        color: SIMD3<Float>,
        intensity: Float = 1.0
    ) {
        // Validate direction vector
        var normalizedDir = direction
        let length = simd_length(direction)
        if length < 0.0001 {
            vrmLog("[VRMRenderer] Warning: Light \(index) direction near zero, using default (0,1,0)")
            normalizedDir = SIMD3<Float>(0, 1, 0)
        } else {
            normalizedDir = simd_normalize(direction)
        }

        let finalColor = color * intensity

        // Store directions separately - they'll be transformed by camera each frame
        // Also update uniforms directly so values are accessible immediately
        switch index {
        case 0:
            storedLightDirections.0 = normalizedDir
            uniforms.lightDirection = normalizedDir
            uniforms.lightColor = finalColor
        case 1:
            storedLightDirections.1 = normalizedDir
            uniforms.light1Direction = normalizedDir
            uniforms.light1Color = finalColor
        case 2:
            storedLightDirections.2 = normalizedDir
            uniforms.light2Direction = normalizedDir
            uniforms.light2Color = finalColor
        default:
            vrmLog("[VRMRenderer] Warning: Invalid light index \(index), must be 0-2")
        }
    }

    /// Disable a light source by setting its color to black
    /// - Parameter index: Light index (0-2)
    public func disableLight(_ index: Int) {
        setLight(index, direction: SIMD3<Float>(0, 1, 0), color: SIMD3<Float>(0, 0, 0))
    }

    /// Configure classic 3-point lighting setup for VTuber/character rendering
    /// - Parameters:
    ///   - keyIntensity: Key light intensity (default 1.0)
    ///   - fillIntensity: Fill light intensity (default 0.5)
    ///   - rimIntensity: Rim light intensity (default 0.3)
    public func setup3PointLighting(
        keyIntensity: Float = 1.0,
        fillIntensity: Float = 0.5,
        rimIntensity: Float = 0.3
    ) {
        // VRM models face +Z. Light direction points FROM light TO scene.
        // Shader negates direction: NdotL = dot(normal, -lightDir)
        // So lightDir with negative Z = light from front

        // Key light: front-right-slightly-above (anime-style soft lighting)
        setLight(0,
                 direction: SIMD3<Float>(0.3, -0.2, -0.9),
                 color: SIMD3<Float>(1.0, 0.98, 0.95),
                 intensity: keyIntensity)

        // Fill light: front-left at eye level (softer, slightly cool)
        setLight(1,
                 direction: SIMD3<Float>(-0.4, -0.1, -0.9),
                 color: SIMD3<Float>(0.85, 0.88, 0.95),
                 intensity: fillIntensity)

        // Rim/back light: behind and above (edge highlight)
        setLight(2,
                 direction: SIMD3<Float>(0.0, -0.5, 0.85),
                 color: SIMD3<Float>(0.9, 0.95, 1.0),
                 intensity: rimIntensity)
    }

    /// Set ambient light color
    /// - Parameter color: Ambient light color (RGB, will be clamped to 0-1 range)
    public func setAmbientColor(_ color: SIMD3<Float>) {
        uniforms.ambientColor = simd_clamp(color, SIMD3<Float>(repeating: 0.0), SIMD3<Float>(repeating: 1.0))
    }

    /// Set light normalization mode for multi-light setups
    /// - Parameter mode: Normalization mode (.automatic, .disabled, or .manual(factor))
    ///
    /// # Modes:
    /// - `.automatic`: Normalize when total light intensity > 1.0 (prevents over-brightness)
    /// - `.disabled`: No normalization (naive additive accumulation, for testing)
    /// - `.manual(factor)`: Custom normalization factor (for artistic control)
    public func setLightNormalizationMode(_ mode: LightNormalizationMode) {
        lightNormalizationMode = mode
    }

    // Pipeline states for MToon outline rendering
    var mtoonOutlinePipelineState: MTLRenderPipelineState?
    var mtoonSkinnedOutlinePipelineState: MTLRenderPipelineState?

    // Sprite Cache System for multi-character optimization
    public var spriteCacheSystem: SpriteCacheSystem?

    /// Detail level for rendering (controls sprite cache usage)
    public enum DetailLevel {
        case full3D        // Always render full 3D
        case cachedSprite  // Use sprite cache when available
        case hybrid        // Priority-based (main speaker = 3D, background = cached)
    }

    /// Current detail level
    public var detailLevel: DetailLevel = .full3D

    // Character priority system for hybrid rendering
    public var prioritySystem: CharacterPrioritySystem?

    // Sprite rendering pipeline
    var spritePipelineState: MTLRenderPipelineState?
    var spriteVertexBuffer: MTLBuffer?
    var spriteIndexBuffer: MTLBuffer?
    let spriteIndexCount: Int = 6

    // Skinning
    private var skinningSystem: VRMSkinningSystem?
    public var animationState: VRMAnimationState?

    // Morph Targets
    public var morphTargetSystem: VRMMorphTargetSystem?
    public var expressionController: VRMExpressionController?

    // LookAt
    public var lookAtController: VRMLookAtController?

    // MARK: - Spring Bone Physics

    private var springBoneComputeSystem: SpringBoneComputeSystem?

    /// Enables GPU-accelerated spring bone physics simulation.
    ///
    /// When enabled, hair, clothing, and accessories with spring bone configurations
    /// will simulate physics each frame. Physics runs on the GPU at 120Hz fixed timestep.
    ///
    /// - Note: The model must have spring bone data for this to have any effect.
    public var enableSpringBone: Bool = false

    /// Quality preset for spring bone physics simulation.
    ///
    /// Higher quality uses more substeps and constraint iterations for more stable physics,
    /// at the cost of GPU performance.
    ///
    /// - `.ultra`: 120Hz substeps, 3 constraint iterations (highest quality)
    /// - `.high`: 90Hz substeps, 2 constraint iterations
    /// - `.medium`: 60Hz substeps, 2 constraint iterations
    /// - `.low`: 30Hz substeps, 1 constraint iteration (fastest)
    public var springBoneQuality: VRMConstants.SpringBoneQuality = .ultra

    private var lastUpdateTime: CFTimeInterval = 0
    var temporaryGravity: SIMD3<Float>?
    var temporaryWind: SIMD3<Float>?
    var forceTimer: Float = 0

    /// Resets spring bone physics state (zeros velocities).
    ///
    /// Call this when teleporting the character or resetting to idle pose to prevent
    /// physics artifacts from large position changes.
    public func resetPhysics() {
        springBoneComputeSystem?.requestPhysicsReset = true
    }

    /// Sets a runtime radius override for a sphere collider.
    ///
    /// Use this to dynamically adjust collision boundaries at runtime, for example
    /// to prevent hair from clipping through the forehead during head tilts.
    ///
    /// - Parameters:
    ///   - index: The index of the sphere collider (0-based, as defined in VRM metadata)
    ///   - radius: The new radius value in meters
    public func setColliderRadius(at index: Int, radius: Float) {
        springBoneComputeSystem?.setSphereColliderRadius(index: index, radius: radius)
    }

    /// Clears a sphere collider radius override, reverting to the original VRM-defined value.
    ///
    /// - Parameter index: The index of the sphere collider
    public func clearColliderRadiusOverride(at index: Int) {
        springBoneComputeSystem?.clearSphereColliderRadiusOverride(index: index)
    }

    /// Clears all sphere collider radius overrides, reverting all to VRM-defined values.
    public func clearAllColliderRadiusOverrides() {
        springBoneComputeSystem?.clearAllColliderRadiusOverrides()
    }

    /// Warms up physics to prevent initial bounce/oscillation when loading a model.
    ///
    /// This runs silent physics steps to let spring bones settle into their natural
    /// hanging positions before the first render frame. Call this after loading
    /// a model if you see violent bouncing on initial display.
    ///
    /// - Parameter steps: Number of physics steps to run (default: 30, ~0.5s at 60fps)
    public func warmupPhysics(steps: Int = 30) {
        guard let model = model else { return }
        springBoneComputeSystem?.warmupPhysics(model: model, steps: steps)
    }

    // OPTIMIZATION: Static zero weights array (avoids allocation per primitive)
    private static let zeroMorphWeights = [Float](repeating: 0, count: 8)
    private var hasLoggedSpringBone = false

    // Prefer modern AnimationPlayer; defensively ignore legacy animationState if set elsewhere
    public var disableLegacyAnimation: Bool = true

    // Triple-buffered uniforms for avoiding CPU-GPU sync
    static let maxBufferedFrames = VRMConstants.Rendering.maxBufferedFrames
    var uniformsBuffers: [MTLBuffer] = []
    private var currentUniformBufferIndex = 0
    var uniforms = Uniforms()
    let inflightSemaphore: DispatchSemaphore

    // MARK: - Camera

    /// View matrix (camera transform). Set this each frame before calling `draw()`.
    ///
    /// The view matrix transforms world coordinates to camera/eye space.
    /// Use `simd_inverse(cameraWorldMatrix)` or a look-at function to compute this.
    public var viewMatrix = matrix_identity_float4x4

    /// Projection matrix (perspective or orthographic). Set this each frame or when viewport changes.
    ///
    /// Use `makeProjectionMatrix(aspectRatio:)` for convenience, or compute manually
    /// for custom projection parameters.
    public var projectionMatrix = matrix_identity_float4x4

    // MARK: - Debug Flags

    /// Disables back-face culling (shows both sides of all triangles).
    public var disableCulling = false

    /// Renders all materials as solid white color for debugging.
    public var solidColorMode = false

    /// Disables skeletal skinning (shows bind pose).
    public var disableSkinning = false

    /// Disables morph target/blend shape deformation.
    public var disableMorphs = false

    /// Renders only the first mesh for debugging.
    public var debugSingleMesh = false

    // Frame counter for debug logging
    var frameCounter = 0

    // PERFORMANCE OPTIMIZATION: Cached render items to avoid rebuilding every frame
    private var cachedRenderItems: [RenderItem]?
    private var cacheNeedsRebuild = true

    // RENDER ITEM: Structure for sorting and rendering primitives
    private struct RenderItem {
        let node: VRMNode
        let mesh: VRMMesh
        let primitive: VRMPrimitive
        let alphaMode: String  // Original material alpha mode
        let materialName: String
        let meshIndex: Int
        var effectiveAlphaMode: String  // Override-able alpha mode
        var effectiveDoubleSided: Bool  // Override-able double sided
        var effectiveAlphaCutoff: Float  // Override-able alpha cutoff for MASK mode
        var faceCategory: String?  // Face sub-category: skin, eyebrow, eyeline, eye, highlight

        // OPTIMIZATION: Cached lowercased strings to avoid repeated allocations
        let materialNameLower: String
        let nodeNameLower: String
        let meshNameLower: String
        let isFaceMaterial: Bool
        let isEyeMaterial: Bool

        // OPTIMIZATION: Render order for single-array sorting (avoids concatenation)
        var renderOrder: Int  // 0=opaque, 1=faceSkin, 2=faceEyebrow, 3=faceEyeline, 4=mask, 5=faceEye, 6=faceHighlight, 7=blend

        // VRM material renderQueue for primary sorting (computed from base + offset)
        // OPAQUE base=2000, MASK base=2450, BLEND base=3000
        let materialRenderQueue: Int

        // Scene graph order for stable tie-breaking in sort (global)
        let primitiveIndex: Int

        // Per-mesh primitive index for morph buffer lookup (matches compute pass key)
        let primIdxInMesh: Int
    }

    /// Get current performance metrics
    /// - Returns: Performance metrics snapshot, or nil if tracking is disabled
    public func getPerformanceMetrics() -> PerformanceMetrics? {
        return performanceTracker?.generateMetrics()
    }

    /// Reset accumulated performance metrics
    public func resetPerformanceMetrics() {
        performanceTracker?.reset()
    }

    // Performance tracking
    public var performanceTracker: PerformanceTracker?

    // State caching to reduce allocations
    var depthStencilStates: [String: MTLDepthStencilState] = [:]
    var samplerStates: [String: MTLSamplerState] = [:]
    private var lastPipelineState: MTLRenderPipelineState?
    private var lastMaterialId: Int = -1
    // Dummy buffer to satisfy Metal validation when morphs are not used
    private var emptyFloat3Buffer: MTLBuffer?

    public init(device: MTLDevice, config: RendererConfig = RendererConfig(strict: .off)) {
        self.device = device
        self.commandQueue = device.makeCommandQueue()!
        self.config = config
        self.strictValidator = StrictValidator(config: config)
        self.skinningSystem = VRMSkinningSystem(device: device)
        self.skinningSystem?.testIdentityPalette = config.testIdentityPalette

        // Initialize morph target system (may fail if GPU compute unavailable)
        do {
            self.morphTargetSystem = try VRMMorphTargetSystem(device: device)
            vrmLog("[VRMRenderer] Morph target system initialized successfully")
        } catch {
            vrmLog("⚠️ [VRMRenderer] Failed to create morph target system: \(error)")
            self.morphTargetSystem = nil
        }

        self.expressionController = VRMExpressionController()
        do {
            self.springBoneComputeSystem = try SpringBoneComputeSystem(device: device)
            vrmLogPhysics("[VRMRenderer] SpringBone GPU compute system created")
        } catch {
            vrmLogPhysics("⚠️ [VRMRenderer] Failed to create SpringBone GPU system: \(error)")
            self.springBoneComputeSystem = nil
        }
        self.lookAtController = VRMLookAtController()
        self.inflightSemaphore = DispatchSemaphore(value: Self.maxBufferedFrames)

        // Initialize sprite cache system for multi-character optimization
        self.spriteCacheSystem = SpriteCacheSystem(device: device, commandQueue: commandQueue)

        // Initialize character priority system
        self.prioritySystem = CharacterPrioritySystem()

        super.init()

        vrmLog("[VRMRenderer] Initializing VRMRenderer...")

        // Verify MToonMaterialUniforms alignment
        validateMaterialUniformAlignment()

        // Set up expression controller with morph target system
        if let morphTargetSystem = morphTargetSystem {
            self.expressionController?.setMorphTargetSystem(morphTargetSystem)
        } else {
            vrmLog("⚠️ [VRMRenderer] Morph target system unavailable, expressions may be limited")
        }

        setupPipeline()
        vrmLog("[VRMRenderer] About to setup skinned pipeline...")
        setupSkinnedPipeline()
        vrmLog("[VRMRenderer] Finished setup skinned pipeline")
        vrmLog("[VRMRenderer] About to setup sprite pipeline...")
        setupSpritePipeline()
        vrmLog("[VRMRenderer] Finished setup sprite pipeline")
        setupCachedStates()
        setupTripleBuffering()
    }

    /// Loads a VRM model into the renderer and initializes all subsystems.
    ///
    /// This method sets up skinning, expressions, spring bone physics, and look-at controllers.
    /// Call this after creating the renderer and before the first draw call.
    ///
    /// - Parameter model: The VRM model to render (loaded via `VRMModel.load(from:)`).
    ///
    /// ## Example
    /// ```swift
    /// let renderer = VRMRenderer(device: device)
    /// let model = try await VRMModel.load(from: modelURL, device: device)
    /// renderer.loadModel(model)
    /// renderer.enableSpringBone = true  // Enable physics after loading
    /// ```
    ///
    /// - Note: Loading a new model invalidates cached render data and reinitializes all subsystems.
    public func loadModel(_ model: VRMModel) {
        self.model = model

        // PERFORMANCE: Invalidate cached render items when model changes
        cacheNeedsRebuild = true
        cachedRenderItems = nil

        // Initialize skinning system with all skins for proper offset allocation
        if !model.skins.isEmpty {
            skinningSystem?.setupForSkins(model.skins)

            // DIFFERENTIAL TRANSFORM ANALYSIS: Capture clean baseline for skin 4
            if model.skins.count > 4 {
                skinningSystem?.captureCleanBaseline(for: model.skins[4], skinIndex: 4)
            }
        }

        // Load expressions if available
        if let expressions = model.expressions {
            // Register preset expressions
            for (preset, expression) in expressions.preset {
                expressionController?.registerExpression(expression, for: preset)
            }

            // Register custom expressions
            for (name, expression) in expressions.custom {
                expressionController?.registerCustomExpression(expression, name: name)
            }
        }

        // Initialize base material colors for expression-driven material color binds
        for (materialIndex, material) in model.materials.enumerated() {
            // Store base color factor (RGBA)
            expressionController?.setBaseMaterialColor(
                materialIndex: materialIndex,
                type: .color,
                color: material.baseColorFactor
            )

            // Store emissive factor (RGB + 1.0 alpha)
            expressionController?.setBaseMaterialColor(
                materialIndex: materialIndex,
                type: .emissionColor,
                color: SIMD4<Float>(material.emissiveFactor, 1.0)
            )

            // Store MToon-specific colors if available
            if let mtoon = material.mtoon {
                expressionController?.setBaseMaterialColor(
                    materialIndex: materialIndex,
                    type: .shadeColor,
                    color: SIMD4<Float>(mtoon.shadeColorFactor, 1.0)
                )
                expressionController?.setBaseMaterialColor(
                    materialIndex: materialIndex,
                    type: .matcapColor,
                    color: SIMD4<Float>(mtoon.matcapFactor, 1.0)
                )
                expressionController?.setBaseMaterialColor(
                    materialIndex: materialIndex,
                    type: .rimColor,
                    color: SIMD4<Float>(mtoon.parametricRimColorFactor, 1.0)
                )
                expressionController?.setBaseMaterialColor(
                    materialIndex: materialIndex,
                    type: .outlineColor,
                    color: SIMD4<Float>(mtoon.outlineColorFactor, 1.0)
                )
            }
        }

        // Initialize SpringBone GPU compute system if available
        if model.springBone != nil {
            do {
                try springBoneComputeSystem?.populateSpringBoneData(model: model)
                vrmLog("[VRMRenderer] SpringBone GPU compute system initialized")
                vrmLog("  - Total bones: \(model.springBoneBuffers?.numBones ?? 0)")
                vrmLog("  - Sphere colliders: \(model.springBoneBuffers?.numSpheres ?? 0)")
                vrmLog("  - Capsule colliders: \(model.springBoneBuffers?.numCapsules ?? 0)")

                // Warm up physics to prevent initial bounce/oscillation
                // This zeros velocity and runs silent physics steps to settle bones
                springBoneComputeSystem?.warmupPhysics(model: model, steps: 30)
            } catch {
                vrmLog("[VRMRenderer] Failed to initialize SpringBone GPU: \(error)")
            }
        }

        // Initialize LookAt controller if model has lookAt data or eye bones
        if model.lookAt != nil || model.humanoid?.humanBones[.leftEye] != nil || model.humanoid?.humanBones[.rightEye] != nil {
            lookAtController?.setup(model: model, expressionController: expressionController)
            // Default to DISABLED to avoid misaligned eyes; can be enabled explicitly by apps
            lookAtController?.enabled = false
            lookAtController?.target = .camera
            vrmLog("[VRMRenderer] LookAt controller initialized - DISABLED by default")
        }
    }

    // MARK: - Compute Pass for Morphs

    private func applyMorphTargetsCompute(commandBuffer: MTLCommandBuffer) -> [MorphKey: MTLBuffer] {
        guard let model = model,
              let morphTargetSystem = morphTargetSystem else { return [:] }

        // Decide if compute path is needed (presence of any morphs > 0 or >8 targets anywhere)
        var needsComputePath = false

        // Check if any primitive has active morphs with non-zero weights
        var hasActiveMorphs = false
        if let controller = expressionController {
            for (meshIndex, mesh) in model.meshes.enumerated() {
                for primitive in mesh.primitives where !primitive.morphTargets.isEmpty {
                    let weights = controller.weightsForMesh(meshIndex, morphCount: primitive.morphTargets.count)
                    let hasNonZero = weights.contains { $0 > 0.001 }
                    if hasNonZero {
                        hasActiveMorphs = true
                        break
                    }
                }
                if hasActiveMorphs { break }
            }
        }

        // Check if any primitive has too many morphs for direct binding
        if !needsComputePath {
            for mesh in model.meshes {
                for primitive in mesh.primitives {
                    if primitive.morphTargets.count > 8 {
                        needsComputePath = true
                        if frameCounter % 60 == 0 {
                            vrmLog("[VRMRenderer] Forcing compute path for primitive with \(primitive.morphTargets.count) morphs")
                        }
                        break
                    }
                }
                if needsComputePath { break }
            }
        }

        // ALWAYS run compute path if we have active morphs, regardless of morph count
        if !needsComputePath && hasActiveMorphs {
            needsComputePath = true
            if frameCounter % 60 == 0 {
                vrmLog("[VRMRenderer] FORCING compute path: active morphs detected")
            }
        }

        guard needsComputePath else {
            // No active morphs and few enough morphs for direct binding
            if frameCounter % 60 == 0 {
                vrmLog("[VRMRenderer] Skipping compute pass - no active morphs and <=8 morphs per primitive")
            }
            return [:]
        }

        // Apply morphs to each primitive that has morph targets
        // Store morphed buffer references for render pass using STABLE KEYS
        var morphedBuffers: [MorphKey: MTLBuffer] = [:]  // Key: (meshIndex << 32) | primitiveIndex

        for (meshIndex, mesh) in model.meshes.enumerated() {
            for (primitiveIndex, primitive) in mesh.primitives.enumerated() where !primitive.morphTargets.isEmpty {
                // Ensure SoA buffers exist
                if primitive.morphTargets.count > 8 {
                    assert(primitive.basePositionsBuffer != nil,
                           "[VRMRenderer] FATAL: Compute path required but basePositionsBuffer is nil for primitive with \(primitive.morphTargets.count) morphs!")
                }

                guard let basePositions = primitive.basePositionsBuffer,
                      let deltaPositions = primitive.morphPositionsSoA,
                      let outputBuffer = morphTargetSystem.getOrCreateMorphedPositionBuffer(
                          primitiveID: ObjectIdentifier(primitive).hashValue,
                          vertexCount: primitive.vertexCount
                      ) else {
                    // Debug: Log why compute path fails
                    if primitive.basePositionsBuffer == nil {
                        vrmLog("[VRMRenderer] ❌ No basePositionsBuffer for primitive with \(primitive.morphTargets.count) morphs")
                        vrmLog("[VRMRenderer] ❌ This should have been created in createSoAMorphBuffers!")
                    }
                    if primitive.morphPositionsSoA == nil {
                        vrmLog("[VRMRenderer] ❌ No morphPositionsSoA for primitive with \(primitive.morphTargets.count) morphs")
                    }
                    continue
                }

                // Build weights for THIS mesh/primitive
                let localWeights = expressionController?.weightsForMesh(meshIndex, morphCount: primitive.morphTargets.count) ?? []

                // Build active set for this primitive (MUST be done before applyMorphsCompute!)
                let primitiveActiveSet = morphTargetSystem.buildActiveSet(weights: localWeights)

                if frameCounter % 60 == 0 && !primitiveActiveSet.isEmpty {
                    vrmLog("[VRMRenderer] Active morphs for mesh=\(meshIndex) prim=\(primitiveIndex): \(primitiveActiveSet.map{Int($0.index)})")
                    let nonZeroWeights = localWeights.enumerated().filter { $0.element > 0.001 }
                    if !nonZeroWeights.isEmpty {
                        vrmLog("[VRMRenderer]   Weights: \(nonZeroWeights.map { "[\($0.offset)]=\(String(format: "%.3f", $0.element))" }.joined(separator: ", "))")
                    }
                }

                // Skip GPU work when no morph weights are active. This avoids dispatching a
                // blit/copy for primitives that currently render with their base pose, which
                // otherwise costs a command encoder per primitive even though the output is
                // identical to the input. In practice most meshes idle in that state, so
                // bailing out here removes unnecessary GPU + driver overhead.
                guard !primitiveActiveSet.isEmpty else {
                    if frameCounter <= 2 || frameCounter % 120 == 0 {
                        vrmLog("[VRMRenderer] Skipping morph compute: no active morphs for mesh=\(meshIndex) prim=\(primitiveIndex)")
                    }
                    continue
                }

                // Run compute kernel
                let success = morphTargetSystem.applyMorphsCompute(
                    basePositions: basePositions,
                    deltaPositions: deltaPositions,
                    outputPositions: outputBuffer,
                    vertexCount: primitive.vertexCount,
                    morphCount: primitive.morphTargets.count,
                    commandBuffer: commandBuffer
                )

                if success {
                    // OPTIMIZATION: Store morphed buffer using numeric key (avoids string allocation)
                    let stableKey: MorphKey = (UInt64(meshIndex) << 32) | UInt64(primitiveIndex)
                    morphedBuffers[stableKey] = outputBuffer

                    // Track morph compute dispatch
                    performanceTracker?.recordMorphCompute()

                    if frameCounter <= 2 || frameCounter % 60 == 0 {
                        vrmLog("[VRMRenderer] Applied compute morphs: mesh=\(meshIndex) prim=\(primitiveIndex) key=\(stableKey)")

                        // Log active morph weights
                        if let controller = expressionController {
                            let weights = controller.weightsForMesh(meshIndex, morphCount: primitive.morphTargets.count)
                            let nonZero = weights.enumerated().filter { $0.element > 0.001 }
                            if !nonZero.isEmpty {
                                vrmLog("   Active weights: \(nonZero.map { "[\($0.offset)]=\(String(format: "%.3f", $0.element))" }.joined(separator: ", "))")
                            }
                        }
                    }

                    // 🔍 DEBUG: Validate BOTH base and morphed positions for draw 14 (face.baked prim 0)
                    if frameCounter == 0 && meshIndex == 3 && primitiveIndex == 0 {
                        // First validate BASE positions (input to compute shader)
                        let basePosPointer = basePositions.contents().bindMemory(to: SIMD3<Float>.self, capacity: primitive.vertexCount)

                        var baseExtremeCount = 0
                        var baseMaxMag: Float = 0

                        for i in 0..<primitive.vertexCount {
                            let pos = basePosPointer[i]
                            let mag = sqrt(pos.x*pos.x + pos.y*pos.y + pos.z*pos.z)
                            baseMaxMag = max(baseMaxMag, mag)
                            if mag > 10.0 || pos.x.isNaN {
                                baseExtremeCount += 1
                            }
                        }

                        vrmLog("")
                        vrmLog("🔍 [BASE POSITIONS VALIDATION] mesh=\(meshIndex) prim=\(primitiveIndex)")
                        vrmLog("   Vertex count: \(primitive.vertexCount)")
                        vrmLog("   Max base position magnitude: \(baseMaxMag)")
                        vrmLog("   Extreme base positions: \(baseExtremeCount)")
                        if baseExtremeCount > 0 {
                            vrmLog("   ❌ BASE POSITIONS CORRUPTED!")
                        } else {
                            vrmLog("   ✅ Base positions OK")
                        }

                        // Create a temporary shared buffer to read back the GPU data
                        let readbackSize = primitive.vertexCount * MemoryLayout<SIMD3<Float>>.stride
                        guard let readbackBuffer = device.makeBuffer(length: readbackSize, options: .storageModeShared) else {
                            vrmLog("[MORPH VALIDATION] Failed to create readback buffer")
                            continue
                        }

                        // Use blit encoder to copy from private GPU buffer to shared CPU-accessible buffer
                guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
                    vrmLog("[MORPH VALIDATION] Failed to create blit encoder")
                    continue
                }
                blitEncoder.copy(from: outputBuffer, sourceOffset: 0,
                                       to: readbackBuffer, destinationOffset: 0,
                                       size: readbackSize)
                blitEncoder.endEncoding()

                        // OPTIMIZATION: GPU validation only in DEBUG mode, first frame only, async
                        #if DEBUG
                        if frameCounter == 0 {
                            // Prepare thread-safe captures to avoid Sendable warnings
                            let vertexCount = primitive.vertexCount
                            let readback = SendableMTLBuffer(readbackBuffer)

                            // Add completion handler to read data after GPU finishes
                            // Run validation on background queue to avoid blocking render thread
                            commandBuffer.addCompletedHandler { _ in
                                DispatchQueue.global(qos: .utility).async {
                                    // Bind the pointer inside the @Sendable closure
                                    let positions = readback.buffer.contents().bindMemory(to: SIMD3<Float>.self, capacity: vertexCount)

                                    var extremeCount = 0
                                    var maxMagnitude: Float = 0
                                    var extremeIndices: [Int] = []

                                    for i in 0..<vertexCount {
                                        let pos = positions[i]
                                        let mag = sqrt(pos.x*pos.x + pos.y*pos.y + pos.z*pos.z)
                                        maxMagnitude = max(maxMagnitude, mag)

                                        // Flag positions that are way outside normal range (>10 units from origin)
                                        if mag > 10.0 || pos.x.isNaN || pos.y.isNaN || pos.z.isNaN {
                                            extremeCount += 1
                                            if extremeIndices.count < 10 {
                                                extremeIndices.append(i)
                                            }
                                        }
                                    }

                                    vrmLog("")
                                    vrmLog("🔍 [GPU MORPHED BUFFER VALIDATION] mesh=\(meshIndex) prim=\(primitiveIndex)")
                                    vrmLog("   Vertex count: \(vertexCount)")
                                    vrmLog("   Max position magnitude: \(maxMagnitude)")
                                    vrmLog("   Extreme positions (>10 units): \(extremeCount)")

                                    if extremeCount > 0 {
                                        vrmLog("   ❌ FOUND EXTREME POSITIONS IN MORPHED BUFFER!")
                                        vrmLog("   First few extreme vertex indices: \(extremeIndices)")
                                        for idx in extremeIndices.prefix(5) {
                                            let pos = positions[idx]
                                            vrmLog("      v[\(idx)]: (\(pos.x), \(pos.y), \(pos.z)) mag=\(sqrt(pos.x*pos.x + pos.y*pos.y + pos.z*pos.z))")
                                        }
                                        vrmLog("   → This is the source of the wedge artifact!")
                                    } else {
                                        vrmLog("   ✅ All morphed positions within normal range")
                                    }
                                }
                            }
                        }
                        #endif
                    }
                } else {
                    vrmLog("[VRMRenderer] ❌ FAILED to apply compute morphs for primitive with \(primitive.morphTargets.count) morphs")
                }
            }
        }

        // Return morphed buffers to be used in render pass
        return morphedBuffers
    }

    /// Renders the model to an offscreen texture (headless rendering).
    ///
    /// Use this for thumbnail generation, sprite caching, or server-side rendering
    /// without an `MTKView`.
    ///
    /// - Parameters:
    ///   - colorTexture: Target color texture to render into.
    ///   - depth: Depth texture for z-buffering.
    ///   - commandBuffer: Command buffer for encoding render commands.
    ///   - renderPassDescriptor: Render pass configuration with attachments.
    @MainActor
    public func drawOffscreenHeadless(to colorTexture: MTLTexture, depth: MTLTexture, commandBuffer: MTLCommandBuffer, renderPassDescriptor: MTLRenderPassDescriptor) {
        let dummyView = DummyView(size: CGSize(width: colorTexture.width, height: colorTexture.height))
        vrmLog("[VRMRenderer] drawOffscreenHeadless called - size: \(colorTexture.width)x\(colorTexture.height)")
        drawCore(in: dummyView, commandBuffer: commandBuffer, renderPassDescriptor: renderPassDescriptor)
    }

    /// Renders the VRM model to the view.
    ///
    /// Call this method once per frame from your `MTKViewDelegate.draw(in:)` implementation.
    /// The renderer handles skinning, morphs, physics, and all material types automatically.
    ///
    /// - Parameters:
    ///   - view: The MetalKit view to render into.
    ///   - commandBuffer: Command buffer for encoding render commands.
    ///   - renderPassDescriptor: Render pass configuration (typically from `view.currentRenderPassDescriptor`).
    ///
    /// ## Example
    /// ```swift
    /// func draw(in view: MTKView) {
    ///     guard let commandBuffer = commandQueue.makeCommandBuffer(),
    ///           let descriptor = view.currentRenderPassDescriptor else { return }
    ///     renderer.draw(in: view, commandBuffer: commandBuffer, renderPassDescriptor: descriptor)
    ///     commandBuffer.present(view.currentDrawable!)
    ///     commandBuffer.commit()
    /// }
    /// ```
    ///
    /// - Important: Ensure `viewMatrix` and `projectionMatrix` are set before calling.
    @MainActor public func draw(in view: MTKView, commandBuffer: MTLCommandBuffer, renderPassDescriptor: MTLRenderPassDescriptor) {
        drawCore(in: view, commandBuffer: commandBuffer, renderPassDescriptor: renderPassDescriptor)
    }

    private func drawCore(in view: MTKView, commandBuffer: MTLCommandBuffer, renderPassDescriptor: MTLRenderPassDescriptor) {
        // DEBUG: Confirm we're in drawCore
        if frameCounter <= 2 || frameCounter % 60 == 0 {
            vrmLog("[VRMRenderer] drawCore() executing, frame \(frameCounter)")
            vrmLog("[VRMRenderer] useOrthographic = \(useOrthographic)")
        }

        // Wait for a free uniform buffer (triple buffering sync)
        _ = inflightSemaphore.wait(timeout: .distantFuture)

        // Optionally disable legacy animation state to prevent conflicts with AnimationPlayer
        if disableLegacyAnimation && animationState != nil {
            if frameCounter == 0 { vrmLog("[VRMRenderer] Disabling legacy animationState (prefer AnimationPlayer)") }
            animationState = nil
        }

        // Start performance tracking
        performanceTracker?.beginFrame()

        // Start frame validation
        strictValidator?.beginFrame()

        guard let model = model else {
            vrmLog("[VRMRenderer] No model loaded!")
            inflightSemaphore.signal()
            return
        }

        // LOCK THE MODEL: Prevent animation updates while we encode draw commands
        model.lock.lock()
        defer { model.lock.unlock() }

        vrmLog("[VRMRenderer] Model has \(model.nodes.count) nodes, \(model.meshes.count) meshes")

        // CRITICAL: Update world transforms for all nodes
        // This must be done before rendering to calculate proper positions
        for node in model.nodes where node.parent == nil {
            node.updateWorldTransform()
        }

        // DEBUG: Check if transforms are actually set
        if frameCounter <= 2 {
            for (idx, node) in model.nodes.prefix(5).enumerated() {
                let local = node.localMatrix.columns.3
                let world = node.worldMatrix.columns.3
                vrmLog("[TRANSFORM DEBUG] Node \(idx) '\(node.name ?? "unnamed")': local=(\(local.x),\(local.y),\(local.z)) world=(\(world.x),\(world.y),\(world.z))")
            }
        }

        // Get the next uniform buffer in the ring
        currentUniformBufferIndex = (currentUniformBufferIndex + 1) % Self.maxBufferedFrames
        guard currentUniformBufferIndex < uniformsBuffers.count else {
            vrmLog("[VRMRenderer] No uniform buffer available at index \(currentUniformBufferIndex)")
            inflightSemaphore.signal()
            return
        }
        let uniformsBuffer = uniformsBuffers[currentUniformBufferIndex]

        // Validate pipeline states in strict mode
        if config.strict != .off {
            do {
                try strictValidator?.validatePipelineState(opaquePipelineState, name: "opaque_pipeline")
                try strictValidator?.validateUniformBuffer(uniformsBuffer, requiredSize: MemoryLayout<Uniforms>.size)
                if morphTargetSystem?.morphAccumulatePipelineState == nil {
                    throw StrictModeError.missingComputeFunction(name: "morph_accumulate")
                }
            } catch {
                if config.strict == .fail {
                    inflightSemaphore.signal()
                    vrmLog("❌ [VRMRenderer] Draw validation failed: \(error)")
                } else {
                    vrmLog("⚠️ [VRMRenderer] Draw validation warning: \(error)")
                }
            }
        } else {
            // Legacy asserts for non-strict mode
            assert(opaquePipelineState != nil, "[VRMRenderer] Opaque pipeline state is nil")
            assert(!uniformsBuffers.isEmpty, "[VRMRenderer] Uniforms buffers are empty")
            assert(morphTargetSystem?.morphAccumulatePipelineState != nil, "[VRMRenderer] Compute pipeline state is nil")
        }

        // Run compute pass for morphs BEFORE render encoder
        let morphedBuffers = applyMorphTargetsCompute(commandBuffer: commandBuffer)
        if !morphedBuffers.isEmpty {
            performanceTracker?.recordMorphCompute()
        }

        // Debug: Log morphed buffer count
        if frameCounter == 1 || frameCounter % 60 == 0 {
            if !morphedBuffers.isEmpty {
                vrmLog("[VRMRenderer] Frame \(frameCounter): \(morphedBuffers.count) primitives have morphed positions")
            }
        }

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            if config.strict != .off {
                do {
                    try strictValidator?.handle(.encoderCreationFailed(type: "render"))
                } catch {
                    vrmLog("❌ [VRMRenderer] Failed to create render encoder: \(error)")
                }
            }
            return
        }

        // Debug: Log rendering statistics
        var totalMeshesWithNodes = 0
        var totalPrimitivesDrawn = 0
        var totalTriangles = 0

        // Update LookAt controller
        if let lookAtController = lookAtController, lookAtController.enabled {
            // Extract camera position from view matrix
            // The view matrix transforms world to view space, so we need the inverse
            // For a view matrix, the camera position in world space is the inverse translation
            let viewMatrixInv = viewMatrix.inverse
            let cameraPos = SIMD3<Float>(
                viewMatrixInv[3][0],
                viewMatrixInv[3][1],
                viewMatrixInv[3][2]
            )

            // DEBUG: Log camera position occasionally
            // TODO: Add proper frame counting later

            lookAtController.cameraPosition = cameraPos
            lookAtController.update(deltaTime: 1.0 / 60.0) // Assume 60 FPS for now

            // Apply LookAt to animation state if in bone mode
            if let animationState = animationState,
               lookAtController.mode == .bone {
                lookAtController.applyToAnimationState(animationState)
            }
        }

        // PHASE 3 FIX: Disable legacy animationState to allow AnimationPlayer to work
        // AnimationPlayer is the correct, modern animation system
        // animationState was causing T-pose bug by overriding AnimationPlayer transforms
        if let _ = animationState {
            if frameCounter == 1 {
                vrmLog("[VRMRenderer] ⚠️  Legacy animationState present but SKIPPED - AnimationPlayer takes priority")
            }
        } else {
            if frameCounter == 1 {
                vrmLog("[VRMRenderer] ✅ No animationState - AnimationPlayer transforms preserved")
            }
        }

        // Debug SpringBone status once
        if !hasLoggedSpringBone {
            vrmLog("[VRMRenderer] Draw called: enableSpringBone=\(enableSpringBone), springBone=\(model.springBone != nil ? "exists" : "nil"), springBoneComputeSystem=\(springBoneComputeSystem != nil ? "exists" : "nil")")
            hasLoggedSpringBone = true
        }

        // Update SpringBone GPU physics if enabled
        // IMPORTANT: Must be done BEFORE skinning matrix update so SpringBone transforms are included
        if enableSpringBone, model.springBone != nil {

            // Calculate actual deltaTime
            let currentTime = CACurrentMediaTime()
            let deltaTime = lastUpdateTime > 0 ? Float(currentTime - lastUpdateTime) : 1.0 / 60.0
            lastUpdateTime = currentTime

            // Clamp deltaTime to reasonable values (prevent huge jumps)
            let clampedDeltaTime = min(deltaTime, 1.0 / 30.0)  // Max 30ms per frame

            // Update temporary forces if any
            updateSpringBoneForces(deltaTime: clampedDeltaTime)

            // Run GPU physics simulation
            if let springBoneCompute = springBoneComputeSystem {
                springBoneCompute.update(model: model, deltaTime: TimeInterval(clampedDeltaTime))

                // Read back GPU positions and update node transforms
                springBoneCompute.writeBonesToNodes(model: model)

                // CRITICAL: Propagate spring bone transforms through entire hierarchy before skinning
                model.updateNodeTransforms()

                // Periodic status logging
                if frameCounter % 120 == 1 {  // Every 2 seconds at 60fps
                    vrmLogPhysics("[SpringBone] GPU physics running: \(model.springBoneBuffers?.numBones ?? 0) bones simulated")
                }
            } else {
                vrmLogPhysics("⚠️ [VRMRenderer] Warning: SpringBone GPU system is nil despite having SpringBone data")
                if frameCounter % 120 == 1 {
                    vrmLogPhysics("❌ [SpringBone] ERROR: GPU system is nil despite Spring Bone data present")
                }
            }
        } else if model.springBone != nil {
            // SpringBone disabled but data exists
            // vrmLog("[VRMRenderer] SpringBone disabled (enableSpringBone=\(enableSpringBone))")
        }

        // CRITICAL UPDATE ORDER: Update all skinning matrices BEFORE any drawing
        // This ensures all joint palettes are fresh for the entire frame
        let hasSkinning = !model.skins.isEmpty

        if hasSkinning {
            vrmLog("[UPDATE ORDER] Frame \(frameCounter): Updating all skin palettes BEFORE drawing")

            // Reset skinning cache at frame boundary
            skinningSystem?.beginFrame()

            // Update joint matrices for ALL skins
            for (skinIndex, skin) in model.skins.enumerated() {
                vrmLog("[SKINNING] Updating \(skin.joints.count) joint matrices for skin \(skinIndex) at offset \(skin.matrixOffset)")
                skinningSystem?.updateJointMatrices(for: skin, skinIndex: skinIndex)

                // PHASE 1 VALIDATION: GPU readback check (every 60 frames)
                if frameCounter % 60 == 0 && skinIndex == 0 {
                    vrmLog("\n═══ PHASE 1: GPU VALIDATION ═══")
                    skinningSystem?.validateJointMatricesGPU(for: skin, skinIndex: skinIndex, expectNonIdentity: animationState != nil)
                }
            }

            // PHASE 1 VALIDATION: Vertex attributes check (once at start)
            if frameCounter == 10 {
                vrmLog("\n═══ PHASE 1: VERTEX VALIDATION ═══")
                // Find first skinned mesh and validate its vertices
                for node in model.nodes {
                    if let meshIndex = node.mesh, meshIndex < model.meshes.count,
                       let skinIndex = node.skin, skinIndex < model.skins.count {
                        let mesh = model.meshes[meshIndex]
                        let skin = model.skins[skinIndex]
                        if let firstPrim = mesh.primitives.first, firstPrim.hasJoints && firstPrim.hasWeights {
                            skinningSystem?.validateVertexAttributes(primitive: firstPrim, meshName: mesh.name ?? "unnamed", paletteCount: skin.joints.count)
                            break
                        }
                    }
                }
            }

            // Mark all skins as fresh for this frame
            skinningSystem?.markAllSkinsUpdated(frameNumber: frameCounter)

            vrmLog("[UPDATE ORDER] All skins updated, now starting draw calls")
        }

        // We'll set the pipeline per-mesh based on whether it has a skin
        encoder.setDepthStencilState(depthStencilStates["opaque"])

        // Enable back-face culling for proper rendering
        encoder.setCullMode(.back)
        encoder.setFrontFacing(.counterClockwise) // glTF uses CCW winding

        // Update uniforms with camera matrices
        uniforms.viewMatrix = viewMatrix
        uniforms.projectionMatrix = projectionMatrix

        // Use stored light directions directly (world-space lighting)
        // Camera-following lights caused washout - reverting to fixed world-space
        uniforms.lightDirection = storedLightDirections.0
        uniforms.light1Direction = storedLightDirections.1
        uniforms.light2Direction = storedLightDirections.2

        // Lighting colors are configured via setup3PointLighting() or setLight()
        // Ambient color default is set in Uniforms struct initialization
        // Get viewport size from view
        let viewportSize: CGSize
        if let dummyView = view as? DummyView {
            // DummyView's drawableSize is nonisolated, safe to access directly
            viewportSize = dummyView.drawableSize
        } else {
            // Real MTKView requires main actor isolation
            viewportSize = MainActor.assumeIsolated { view.drawableSize }
        }
        uniforms.viewportSize = SIMD2<Float>(Float(viewportSize.width), Float(viewportSize.height))
        // Set debug mode (0=off, 1=UV, 2=hasBaseColorTexture, 3=baseColorFactor)
        uniforms.debugUVs = debugUVs

        // DEBUG: Log what's being set to track UV debug issue
        if frameCounter <= 2 {
            vrmLog("[UNIFORMS] Setting debugUVs uniform to \(uniforms.debugUVs)")
        }

        // Calculate light normalization factor based on mode
        switch lightNormalizationMode {
        case .automatic:
            // Shader handles energy conservation internally via intensity-weighted lighting
            uniforms.lightNormalizationFactor = 1.0
        case .disabled:
            uniforms.lightNormalizationFactor = 1.0
        case .manual(let factor):
            uniforms.lightNormalizationFactor = max(0.0, factor)  // Clamp to non-negative
        }

        // DEBUG: Log lighting values to verify 3-point lighting is configured
        #if DEBUG
        if frameCounter % 60 == 0 {  // Log every second at 60fps
            vrmLog("[Lighting] Frame \(frameCounter) GPU upload:")
            vrmLog("  Light 0 (key):  dir=\(uniforms.lightDirection), color=\(uniforms.lightColor)")
            vrmLog("  Light 1 (fill): dir=\(uniforms.light1Direction), color=\(uniforms.light1Color)")
            vrmLog("  Light 2 (rim):  dir=\(uniforms.light2Direction), color=\(uniforms.light2Color)")
            vrmLog("  Ambient: \(uniforms.ambientColor)")
            vrmLog("  Normalization: \(uniforms.lightNormalizationFactor) (mode: \(lightNormalizationMode))")
        }
        #endif

        // Copy uniforms to the current buffer
        uniformsBuffer.contents().copyMemory(from: &uniforms, byteCount: MemoryLayout<Uniforms>.size)

        // ALPHA MODE QUEUING: Collect all primitives and sort by alpha mode
        // PERFORMANCE OPTIMIZATION: Use cached render items if available
        var allItems: [RenderItem]

        if let cached = cachedRenderItems, !cacheNeedsRebuild {
            // Use cached items - no need to rebuild
            allItems = cached
            if frameCounter % 300 == 0 {
                vrmLog("[VRMRenderer] 🚀 PERF: Using cached render items (\(allItems.count) items)")
            }
        } else {
            // Build render items from scratch
            if frameCounter % 60 == 0 {
                vrmLog("[VRMRenderer] 🔨 Building render item cache...")
            }

            // OPTIMIZATION: Pre-allocate single array instead of 8 separate arrays + concatenation
            // Typical models have 20-100 primitives across all meshes
            let estimatedPrimitiveCount = model.meshes.reduce(0) { $0 + $1.primitives.count }
            allItems = []
            allItems.reserveCapacity(estimatedPrimitiveCount)

            // Keep counters for logging (no longer need separate arrays)
            var opaqueCount = 0
            var maskCount = 0
            var blendCount = 0
            var faceSkinCount = 0
            var faceEyebrowCount = 0
            var faceEyelineCount = 0
            var faceEyeCount = 0
            var faceHighlightCount = 0
            var globalPrimitiveIndex = 0

            // Collect all primitives and categorize by alpha mode
            for (nodeIndex, node) in model.nodes.enumerated() {
            // Debug: Log ALL nodes to find which one has the mesh
            if frameCounter <= 2 {
                vrmLog("[NODE SCAN] Node \(nodeIndex) '\(node.name ?? "unnamed")': mesh=\(node.mesh ?? -1)")
            }

            guard let meshIndex = node.mesh,
                  meshIndex < model.meshes.count else {
                // Debug nodes without meshes
                if node.name?.lowercased().contains("face") == true || frameCounter <= 2 {
                    vrmLog("[NODE DEBUG] Node '\(node.name ?? "")' (index \(nodeIndex)) has no mesh (mesh=\(node.mesh ?? -1))")
                }
                continue
            }

            // Debug all nodes with meshes - log (node, mesh, skin) triplet
            let mesh = model.meshes[meshIndex]
            if frameCounter < 2 {
                vrmLog("[DRAW LIST] Node[\(nodeIndex)] '\(node.name ?? "?")' → mesh[\(meshIndex)] '\(mesh.name ?? "?")' skin=\(node.skin ?? -1)")
            }
            totalMeshesWithNodes += 1

            for (primIdxInMesh, primitive) in mesh.primitives.enumerated() {
                let alphaMode = primitive.materialIndex.flatMap { idx in
                    idx < model.materials.count ? model.materials[idx].alphaMode : nil
                }?.lowercased() ?? "opaque"

                let materialName = (primitive.materialIndex.flatMap { idx in
                    idx < model.materials.count ? model.materials[idx].name : nil
                }) ?? "unnamed"

                // Enhanced face material detection logging
                let nodeName = node.name ?? "unnamed"
                let meshName = mesh.name ?? "unnamed_mesh"

                // OPTIMIZATION: Compute lowercased strings once early for debug logging
                let materialNameLower = materialName.lowercased()
                let nodeNameLower = nodeName.lowercased()
                let meshNameLower = meshName.lowercased()

                // Check if this is a face-related primitive
                let nodeIsFace = nodeNameLower.contains("face") || nodeNameLower.contains("eye")
                let meshIsFace = meshNameLower.contains("face") || meshNameLower.contains("eye")
                let materialIsFace = materialNameLower.contains("face") || materialNameLower.contains("eye")

                if nodeIsFace || meshIsFace || materialIsFace {
                    vrmLog("[FACE MATERIAL DEBUG] Potential face material detected:")
                    vrmLog("  - Node: '\(nodeName)' (face: \(nodeIsFace))")
                    vrmLog("  - Mesh: '\(meshName)' (face: \(meshIsFace))")
                    vrmLog("  - Material: '\(materialName)' (face: \(materialIsFace))")
                    vrmLog("  - Alpha mode: \(alphaMode)")
                    vrmLog("  - Material index: \(primitive.materialIndex ?? -1)")

                    // Check texture transparency if available
                    if let matIdx = primitive.materialIndex, matIdx < model.materials.count {
                        let material = model.materials[matIdx]
                        vrmLog("  - Base color texture: \(material.baseColorTexture != nil)")
                        vrmLog("  - Double sided: \(material.doubleSided)")
                        vrmLog("  - Alpha cutoff: \(material.alphaCutoff)")
                    }
                }

                // Get original doubleSided and alphaCutoff from material
                let originalDoubleSided = primitive.materialIndex.flatMap { idx in
                    idx < model.materials.count ? model.materials[idx].doubleSided : false
                } ?? false

                let originalAlphaCutoff = primitive.materialIndex.flatMap { idx in
                    idx < model.materials.count ? model.materials[idx].alphaCutoff : 0.5
                } ?? 0.5

                // Get renderQueue from VRM material (for sorting face/transparent materials)
                let materialRenderQueue = primitive.materialIndex.flatMap { idx in
                    idx < model.materials.count ? model.materials[idx].renderQueue : 2000
                } ?? 2000

                // OPTIMIZATION: Single face/body detection pass (consolidates 3 separate checks)
                // Include body, clothing, and transparentZWrite materials for proper categorization
                let isFaceMaterial = materialNameLower.contains("face") || materialNameLower.contains("eye") ||
                                    nodeNameLower.contains("face") || nodeNameLower.contains("eye") ||
                                    (materialNameLower.contains("body") && !materialNameLower.contains("face")) ||
                                    materialNameLower.contains("cloth") || materialNameLower.contains("tops") ||
                                    materialNameLower.contains("bottoms") || materialNameLower.contains("skirt") ||
                                    materialNameLower.contains("shorts") || materialNameLower.contains("pants") ||
                                    materialNameLower.contains("lace") || materialNameLower.contains("collar") ||
                                    materialNameLower.contains("ribbon") || materialNameLower.contains("frill") ||
                                    materialNameLower.contains("ruffle")
                let isEyeMaterial = materialNameLower.contains("eye") && !materialNameLower.contains("brow")
                let nodeOrMeshIsFace = nodeNameLower.contains("face") || nodeNameLower.contains("eye") ||
                                      meshNameLower.contains("face") || meshNameLower.contains("eye")
                let isBodyOrSkinMaterial = materialNameLower.contains("body") || materialNameLower.contains("skin") ||
                                         nodeNameLower.contains("body") || meshNameLower.contains("body")

                var item = RenderItem(
                    node: node,
                    mesh: mesh,
                    primitive: primitive,
                    alphaMode: alphaMode,
                    materialName: materialName,
                    meshIndex: meshIndex,
                    effectiveAlphaMode: alphaMode,  // Start with original
                    effectiveDoubleSided: originalDoubleSided,  // Start with original
                    effectiveAlphaCutoff: originalAlphaCutoff,  // Start with original cutoff
                    faceCategory: nil,  // Will be set if this is a face material
                    materialNameLower: materialNameLower,
                    nodeNameLower: nodeNameLower,
                    meshNameLower: meshNameLower,
                    isFaceMaterial: isFaceMaterial,
                    isEyeMaterial: isEyeMaterial,
                    renderOrder: 0,  // Will be set based on category
                    materialRenderQueue: materialRenderQueue,
                    primitiveIndex: globalPrimitiveIndex,
                    primIdxInMesh: primIdxInMesh
                )

                // Enhanced face/body material detection and overrides
                // OPTIMIZATION: Use pre-computed flags (nodeOrMeshIsFace, isBodyOrSkinMaterial)
                if nodeOrMeshIsFace {
                    // Override double-sided for face materials to ensure visibility
                    item.effectiveDoubleSided = true

                    // For face materials, handle different material types:
                    // - Face skin (OPAQUE or MASK) - main face surface
                    // - Eyelashes/Eyebrows (MASK) - need transparency
                    // - Eyes/Mouth interior (OPAQUE) - solid surfaces

                    if let matIdx = primitive.materialIndex, matIdx < model.materials.count {
                        let material = model.materials[matIdx]

                        // OPTIMIZATION: Use cached lowercased string
                        if item.materialNameLower.contains("skin") && item.effectiveAlphaMode == "mask" {
                            // Lower the alpha cutoff for skin to ensure it renders
                            vrmLog("[FACE FIX] Adjusting alpha cutoff for face skin (favor cutouts)")
                            vrmLog("  - Material: \(materialName)")
                            vrmLog("  - Original cutoff: \(material.alphaCutoff)")
                            // Use a mid cutoff to respect cutout regions (eyes/mouth)
                            item.effectiveAlphaCutoff = max(0.5, material.alphaCutoff)
                        }
                    }

                    vrmLog("[FACE HANDLING] node '\(nodeName)' / mesh '\(meshName)'")
                    vrmLog("  - Material: \(materialName)")
                    vrmLog("  - Effective alpha mode: \(item.effectiveAlphaMode)")
                    vrmLog("  - Effective alpha cutoff: \(item.effectiveAlphaCutoff)")
                    vrmLog("  - Effective double-sided: \(item.effectiveDoubleSided)")
                }

                // DON'T override MASK to OPAQUE for face materials - they often need transparency!
                // Only do this for body/skin materials where it helps with rendering
                if isBodyOrSkinMaterial && !nodeOrMeshIsFace && item.effectiveAlphaMode == "mask" {
                    item.effectiveAlphaMode = "opaque"
                    vrmLog("[ALPHA OVERRIDE] Converting MASK to OPAQUE for face/body/skin material: \(materialName)")
                }


                // OPTIMIZATION: Use cached face detection
                vrmLog("[MAT CLASSIFY] '\(materialName)' isFace=\(item.isFaceMaterial) node='\(node.name ?? "nil")'")

                // OPTIMIZATION: Set renderOrder instead of appending to separate arrays
                if item.isFaceMaterial {
                    // Classify face material by type and set category + renderOrder
                    // Body detection - must come before skin check since body materials contain "skin"
                    if item.materialNameLower.contains("body") && !item.materialNameLower.contains("face") {
                        item.faceCategory = "body"
                        item.renderOrder = 0  // body renders first, pushed back by depth bias
                        vrmLog("  → Assigned to: body queue (order=0)")
                    } else if item.materialNameLower.contains("lace") || item.materialNameLower.contains("collar") ||
                              item.materialNameLower.contains("ribbon") || item.materialNameLower.contains("frill") ||
                              item.materialNameLower.contains("ruffle") {
                        // TransparentWithZWrite - semi-transparent overlays that need depth writing
                        item.faceCategory = "transparentZWrite"
                        item.renderOrder = 8  // After opaque, before regular blend
                        vrmLog("  → Assigned to: transparentZWrite queue (order=8)")
                    } else if item.materialNameLower.contains("cloth") || item.materialNameLower.contains("tops") ||
                              item.materialNameLower.contains("bottoms") || item.materialNameLower.contains("skirt") ||
                              item.materialNameLower.contains("shorts") || item.materialNameLower.contains("pants") {
                        item.faceCategory = "clothing"
                        item.renderOrder = 8  // Same as transparentZWrite for proper layering
                        vrmLog("  → Assigned to: clothing queue (order=8)")
                    } else if item.materialNameLower.contains("mouth") || item.materialNameLower.contains("lip") {
                        // Face mouth/lip overlays - render after base face skin
                        item.faceCategory = "faceOverlay"
                        item.renderOrder = 2  // after skin (1), before eyebrow (2) - same as eyebrow but named differently
                        faceSkinCount += 1
                        vrmLog("  → Assigned to: face overlay queue (order=2)")
                    } else if item.materialNameLower.contains("skin") || (item.materialNameLower.contains("face") && !item.materialNameLower.contains("eye")) {
                        item.faceCategory = "skin"
                        item.renderOrder = 1  // faceSkin - base face renders first
                        faceSkinCount += 1
                        vrmLog("  → Assigned to: skin queue (order=1)")
                    } else if item.materialNameLower.contains("brow") {
                        item.faceCategory = "eyebrow"
                        item.renderOrder = 2  // faceEyebrow
                        faceEyebrowCount += 1
                        vrmLog("  → Assigned to: eyebrow queue (order=2)")
                    } else if item.materialNameLower.contains("line") || item.materialNameLower.contains("lash") {
                        item.faceCategory = "eyeline"
                        item.renderOrder = 3  // faceEyeline
                        faceEyelineCount += 1
                        vrmLog("  → Assigned to: eyeline queue (order=3)")
                    } else if item.materialNameLower.contains("highlight") {
                        item.faceCategory = "highlight"
                        item.renderOrder = 6  // faceHighlight
                        faceHighlightCount += 1
                        vrmLog("  → Assigned to: highlight queue (order=6)")
                    } else if item.materialNameLower.contains("eye") {
                        item.faceCategory = "eye"
                        item.renderOrder = 5  // faceEye
                        faceEyeCount += 1
                        vrmLog("  → Assigned to: eye queue (order=5)")
                    } else {
                        // Unknown face material - default to skin queue
                        item.faceCategory = "skin"
                        item.renderOrder = 1  // faceSkin
                        faceSkinCount += 1
                        vrmLog("  → Assigned to: skin queue (default, order=1)")
                    }

                    // Enforce effective alpha modes per face part for correct pipeline selection
                    switch item.faceCategory {
                    case "eye":
                        // Eyes should be fully opaque geometry rendered after face skin
                        item.effectiveAlphaMode = "opaque"
                        item.effectiveDoubleSided = true
                    case "highlight":
                        // Eye highlights remain blended overlays
                        item.effectiveAlphaMode = "blend"
                        item.effectiveDoubleSided = true
                    case "eyeline", "eyebrow":
                        // Often alpha-cutout; ensure double-sided to avoid missing strokes
                        item.effectiveDoubleSided = true
                    default:
                        break
                    }
                } else {
                    // OPTIMIZATION: Set renderOrder for non-face materials
                    switch item.effectiveAlphaMode {
                    case "opaque":
                        item.renderOrder = 0  // opaque
                        opaqueCount += 1
                    case "mask":
                        item.renderOrder = 4  // mask
                        maskCount += 1
                    case "blend":
                        item.renderOrder = 7  // blend
                        blendCount += 1
                    default:
                        item.renderOrder = 0  // opaque (default)
                        opaqueCount += 1
                    }
                }

                // OPTIMIZATION: Add to single pre-allocated array
                allItems.append(item)
                globalPrimitiveIndex += 1
            }
        }

        vrmLog("[VRMRenderer] 🎨 Alpha queuing: opaque=\(opaqueCount), mask=\(maskCount), blend=\(blendCount)")

        // Pre-compute view-space Z for transparent items to avoid redundant matrix multiplies in comparator
        var viewZByIndex = [Int: Float]()
        viewZByIndex.reserveCapacity(blendCount)
        for item in allItems where item.materialRenderQueue >= 2500 {
            let worldPos = item.node.worldMatrix.columns.3
            viewZByIndex[item.primitiveIndex] = (viewMatrix * worldPos).z
        }

        // Multi-tier sorting: renderOrder (name-based) + VRM queue + view-Z + stable order
        allItems.sort { a, b in
            // 1. Primary: renderOrder (name-based face/body category ordering)
            // Order: 0=body/opaque, 1=skin, 2=brow, 3=line, 4=mask, 5=eye, 6=highlight, 7=blend, 8=clothing
            if a.renderOrder != b.renderOrder {
                return a.renderOrder < b.renderOrder
            }

            // 2. Secondary: VRM render queue (author's intent for fine-grained ordering)
            // Within same renderOrder, respect explicit queue differences
            if a.materialRenderQueue != b.materialRenderQueue {
                return a.materialRenderQueue < b.materialRenderQueue
            }

            // 3. Tertiary: Transparent materials (queue >= 2500): back-to-front Z-sorting
            // This threshold covers TransparentWithZWrite (2450+) and Transparent (3000+)
            if a.materialRenderQueue >= 2500 {
                let aViewZ = viewZByIndex[a.primitiveIndex] ?? 0
                let bViewZ = viewZByIndex[b.primitiveIndex] ?? 0
                return aViewZ < bViewZ  // Far to near (Painter's Algorithm)
            }

            // 4. Quaternary: stable definition order for tie-breaking
            return a.primitiveIndex < b.primitiveIndex
        }

        if blendCount > 0 && frameCounter < 10 {
            vrmLog("[VRMRenderer] Sorted \(blendCount) BLEND items by view-space Z (far to near)")
        }
        vrmLog("[WORKAROUND CHECK] Got allItems with count: \(allItems.count)")

        // Log render items count using counters
        if frameCounter <= 2 || allItems.count > 50 {
            vrmLog("[RENDER ITEMS] Total: \(allItems.count)")
            vrmLog("  - Opaque (non-face): \(opaqueCount)")
            vrmLog("  - Face.skin: \(faceSkinCount)")
            vrmLog("  - Face.eyebrow: \(faceEyebrowCount)")
            vrmLog("  - Face.eyeline: \(faceEyelineCount)")
            vrmLog("  - Mask (non-face): \(maskCount)")
            vrmLog("  - Face.eye: \(faceEyeCount)")
            vrmLog("  - Face.highlight: \(faceHighlightCount)")
            vrmLog("  - Blend (non-face): \(blendCount)")
            vrmLog("[RENDER ITEMS] Processing \(allItems.count) primitives from \(totalMeshesWithNodes) nodes")
        }

            // Store in cache for future frames
            cachedRenderItems = allItems
            cacheNeedsRebuild = false
            if frameCounter % 60 == 0 {
                vrmLog("[VRMRenderer] ✅ Cached \(allItems.count) render items for reuse")
            }
        } // End of cache rebuild block

        // DEBUG SINGLE MESH MODE: Only render the first item for systematic testing
        // CRITICAL DEBUG: Log execution path to understand why workaround isn't triggered
        vrmLog("[WORKAROUND PATH] debugSingleMesh = \(debugSingleMesh), allItems.count = \(allItems.count)")

        let itemsToRender: [RenderItem]
        if debugSingleMesh {
            if let firstItem = allItems.first {
                itemsToRender = [firstItem]
                vrmLog("[DEBUG] 🔧 Debug single-mesh mode: rendering only '\(firstItem.materialName)' from mesh '\(firstItem.mesh.name ?? "unnamed")'")
            } else {
                itemsToRender = []
                vrmLog("[DEBUG] 🔧 Debug single-mesh mode: no items to render")
            }
        } else {
            itemsToRender = allItems
        }

        // CRITICAL: Log all items we're about to render to understand what's happening
        vrmLog("[WORKAROUND LOOP] Starting render loop with \(itemsToRender.count) items")

        // DRAW LIST BISECT: Filter by draw index if requested
        var drawIndex = 0

        vrmLog("[LOOP DEBUG] About to iterate over \(itemsToRender.count) items")
        for (index, item) in itemsToRender.enumerated() {
            vrmLog("[LOOP DEBUG] Entering iteration \(index)")
            let meshName = item.mesh.name ?? "unnamed"
            let materialName = item.materialName

            // DEBUG: Log EVERY item unconditionally to catch filtering issues
            vrmLog("[RENDER CHECK] Item \(index): mesh='\(meshName)', material='\(materialName)')")

            // RENDER FILTER: Skip items that don't match the filter
            if let filter = config.renderFilter {
                let shouldRender: Bool
                switch filter {
                case .mesh(let name):
                    shouldRender = meshName == name
                case .material(let name):
                    shouldRender = materialName == name
                case .primitive(let primIndex):
                    let meshPrimIndex = item.mesh.primitives.firstIndex(where: { $0 === item.primitive }) ?? -1
                    shouldRender = meshPrimIndex == primIndex
                }

                if !shouldRender {
                    continue
                }

                if frameCounter == 1 {
                    let meshPrimIndex = item.mesh.primitives.firstIndex(where: { $0 === item.primitive }) ?? -1
                    vrmLog("[FILTER] Rendering: mesh='\(meshName)', material='\(materialName)', primIndex=\(meshPrimIndex)")

                    // Log detailed primitive information once
                    let prim = item.primitive
                    vrmLog("\n━━━━━ FILTERED PRIMITIVE DETAILS ━━━━━")
                    vrmLog("Mesh: '\(meshName)'")
                    vrmLog("Material: '\(materialName)'")
                    vrmLog("Primitive index: \(meshPrimIndex)")
                    vrmLog("")

                    // Mode mapping
                    let modeStr: String
                    switch prim.primitiveType {
                    case .point: modeStr = "POINTS (0)"
                    case .line: modeStr = "LINES (1)"
                    case .lineStrip: modeStr = "LINE_STRIP (2)"
                    case .triangle: modeStr = "TRIANGLES (4)"
                    case .triangleStrip: modeStr = "TRIANGLE_STRIP (5)"
                    @unknown default: modeStr = "UNKNOWN"
                    }
                    vrmLog("Mode (glTF → Metal): \(modeStr) → \(prim.primitiveType)")

                    // Index type
                    let indexTypeStr = prim.indexType == .uint16 ? "uint16" : "uint32"
                    let indexElemSize = prim.indexType == .uint16 ? 2 : 4
                    vrmLog("Index type: \(indexTypeStr)")
                    vrmLog("Index count: \(prim.indexCount)")
                    vrmLog("Index buffer offset: \(prim.indexBufferOffset) bytes")

                    if let indexBuffer = prim.indexBuffer {
                        vrmLog("Index buffer length: \(indexBuffer.length) bytes")

                        // Assertions
                        assert(prim.indexBufferOffset % indexElemSize == 0,
                               "❌ Index buffer offset \(prim.indexBufferOffset) not aligned to element size \(indexElemSize)")
                        assert(prim.indexBufferOffset + prim.indexCount * indexElemSize <= indexBuffer.length,
                               "❌ Index buffer overflow: offset(\(prim.indexBufferOffset)) + count(\(prim.indexCount)) * elemSize(\(indexElemSize)) > buffer.length(\(indexBuffer.length))")

                        // Read first 24 indices
                        vrmLog("\nFirst 24 indices:")
                        let indicesToRead = min(24, prim.indexCount)
                        var indicesStr: [String] = []
                        var maxIndex = 0

                        if prim.indexType == .uint16 {
                            let base = indexBuffer.contents().advanced(by: prim.indexBufferOffset)
                            let indexPtr = base.bindMemory(to: UInt16.self, capacity: prim.indexCount)
                            for i in 0..<indicesToRead {
                                let idx = Int(indexPtr[i])
                                indicesStr.append("\(idx)")
                                maxIndex = max(maxIndex, idx)
                            }
                        } else {
                            let base = indexBuffer.contents().advanced(by: prim.indexBufferOffset)
                            let indexPtr = base.bindMemory(to: UInt32.self, capacity: prim.indexCount)
                            for i in 0..<indicesToRead {
                                let idx = Int(indexPtr[i])
                                indicesStr.append("\(idx)")
                                maxIndex = max(maxIndex, idx)
                            }
                        }
                        vrmLog("  [\(indicesStr.joined(separator: ", "))]")
                        vrmLog("  Max index in sample: \(maxIndex)")

                        // Check max index against vertex count
                        vrmLog("\nPOSITION.count (vertexCount): \(prim.vertexCount)")
                        assert(maxIndex < prim.vertexCount,
                               "❌ Max index \(maxIndex) >= vertex count \(prim.vertexCount)")

                        vrmLog("\n✅ All assertions passed")
                    } else {
                        vrmLog("❌ No index buffer!")
                    }

                    vrmLog("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")
                }
            }

            // DRAW LIST BISECT: Check if this draw should be rendered
            if let drawUntil = config.drawUntil {
                if drawIndex > drawUntil {
                    continue
                }
            }

            if let drawOnlyIndex = config.drawOnlyIndex {
                if drawIndex != drawOnlyIndex {
                    drawIndex += 1
                    continue
                }
            }

            // PER-DRAW LOGGING: Comprehensive state dump
            let prim = item.primitive
            let meshPrimIndex = item.mesh.primitives.firstIndex(where: { $0 === prim }) ?? -1

            // Get skinning info
            var skinIdxStr = "none"
            var paletteCountStr = "0"
            let paletteVersionStr = "0"
            if let skinIndex = item.node.skin {
                skinIdxStr = "\(skinIndex)"
                if skinIndex < model.skins.count {
                    let skin = model.skins[skinIndex]
                    paletteCountStr = "\(skin.joints.count)"
                }
            }

            // Get position slot (0 for base, 20 for morphed)
            let positionSlot = prim.morphTargets.isEmpty ? 0 : 20

            // Mode string
            let modeStr: String
            switch prim.primitiveType {
            case .point: modeStr = "POINTS"
            case .line: modeStr = "LINES"
            case .lineStrip: modeStr = "LINE_STRIP"
            case .triangle: modeStr = "TRIANGLES"
            case .triangleStrip: modeStr = "TRIANGLE_STRIP"
            @unknown default: modeStr = "UNKNOWN"
            }

            // Index type string
            let indexTypeStr = prim.indexType == .uint16 ? "u16" : "u32"

            // PSO label (based on alpha mode)
            let psoLabel: String
            switch item.effectiveAlphaMode {
            case "opaque": psoLabel = "opaque"
            case "mask": psoLabel = "mask"
            case "blend": psoLabel = "blend"
            default: psoLabel = "unknown"
            }

            vrmLog("[DRAW] i=\(drawIndex) mesh='\(meshName)' prim=\(meshPrimIndex) mat='\(materialName)' mode=\(modeStr) idx=\(indexTypeStr)/\(prim.indexBufferOffset)/\(prim.indexCount) skin=\(skinIdxStr)/\(paletteCountStr)/\(paletteVersionStr) pso=\(psoLabel) pos_slot=\(positionSlot)")

            // 🔵 WEDGE DEBUG: Make ALL flonthair primitives render BLUE to identify the wedge

            // 🎯 DECISIVE CHECK: For draw index 14 (face.baked prim 0 - the WEDGE primitive), validate INDEX BUFFER
            if drawIndex == 14 && frameCounter <= 2 {
                vrmLog("")
                vrmLog("🔍 [DRAW 5 DECISIVE CHECK] Frame=\(frameCounter) - Validating index buffer and primitive mode...")

                // Check 1: Primitive mode
                let gltfModeStr: String
                switch prim.primitiveType {
                case .point: gltfModeStr = "POINTS (0)"
                case .line: gltfModeStr = "LINES (1)"
                case .lineStrip: gltfModeStr = "LINE_STRIP (3)"
                case .triangle: gltfModeStr = "TRIANGLES (4)"
                case .triangleStrip: gltfModeStr = "TRIANGLE_STRIP (5)"
                @unknown default: gltfModeStr = "UNKNOWN"
                }

                vrmLog("📐 [PRIMITIVE MODE]")
                vrmLog("   Stored primitiveType: \(gltfModeStr)")
                vrmLog("   IndexType: \(prim.indexType == .uint16 ? "uint16" : "uint32")")
                vrmLog("   Index buffer offset: \(prim.indexBufferOffset)")
                vrmLog("   Index count: \(prim.indexCount)")
                vrmLog("   Vertex count: \(prim.vertexCount)")

                // Check 2: Scan ALL indices for out-of-range values
                if let indexBuffer = prim.indexBuffer {
                    vrmLog("")
                    vrmLog("📊 [INDEX BUFFER VALIDATION] Scanning ALL \(prim.indexCount) indices:")

                    let indicesToCheck = prim.indexCount  // Scan all to find any out-of-range
                    var indices: [UInt32] = []
                    var outOfRangeCount = 0
                    var maxIndex: UInt32 = 0

                    if prim.indexType == .uint16 {
                        let ptr = indexBuffer.contents().advanced(by: prim.indexBufferOffset).assumingMemoryBound(to: UInt16.self)
                        for i in 0..<indicesToCheck {
                            let idx = UInt32(ptr[i])
                            indices.append(idx)
                            if idx >= prim.vertexCount {
                                outOfRangeCount += 1
                            }
                            maxIndex = max(maxIndex, idx)
                        }
                    } else {
                        let ptr = indexBuffer.contents().advanced(by: prim.indexBufferOffset).assumingMemoryBound(to: UInt32.self)
                        for i in 0..<indicesToCheck {
                            let idx = ptr[i]
                            indices.append(idx)
                            if idx >= prim.vertexCount {
                                outOfRangeCount += 1
                            }
                            maxIndex = max(maxIndex, idx)
                        }
                    }

                    vrmLog("   First 24 of \(indicesToCheck) indices: \(Array(indices.prefix(24)))")
                    vrmLog("   Max index across ALL \(indicesToCheck) indices: \(maxIndex) (vertexCount=\(prim.vertexCount))")

                    if outOfRangeCount > 0 {
                        vrmLog("")
                        vrmLog("❌ [CRITICAL] Found \(outOfRangeCount) out-of-range indices!")
                        vrmLog("   → This WILL cause the wedge artifact (referencing invalid vertices)")
                    } else if maxIndex < prim.vertexCount {
                        vrmLog("   ✅ All indices within valid range [0..\(prim.vertexCount-1)]")
                    }

                    // Check 3: Sample vertex positions to look for extreme values
                    if let vertexBuffer = prim.vertexBuffer {
                        vrmLog("")
                        vrmLog("📍 [VERTEX POSITION CHECK] Sampling positions referenced by first 24 indices:")

                        let verts = vertexBuffer.contents().bindMemory(to: VRMVertex.self, capacity: prim.vertexCount)
                        var extremeFound = false

                        for (i, idx) in indices.prefix(12).enumerated() {
                            let pos = verts[Int(idx)].position
                            let magnitude = sqrt(pos.x*pos.x + pos.y*pos.y + pos.z*pos.z)

                            if magnitude > 100.0 || pos.x.isNaN || pos.y.isNaN || pos.z.isNaN {
                                vrmLog("   ❌ idx[\(i)]=\(idx): pos=(\(pos.x), \(pos.y), \(pos.z)) mag=\(magnitude) EXTREME!")
                                extremeFound = true
                            } else if i < 6 {
                                vrmLog("   idx[\(i)]=\(idx): pos=(\(String(format: "%.3f", pos.x)), \(String(format: "%.3f", pos.y)), \(String(format: "%.3f", pos.z))) mag=\(String(format: "%.3f", magnitude))")
                            }
                        }

                        if !extremeFound {
                            vrmLog("   ✅ All sampled positions within normal range")
                        }
                    }
                }

                vrmLog("")
            }

            // Increment draw index for next iteration
            drawIndex += 1

            // PERFORMANCE: Wedge detection disabled - this was running every frame for every primitive
            // causing significant performance overhead (memory binding + SIMD calculations × 400+ primitives/frame)
            // If wedge artifacts appear, this should be moved to load time and cached
            let primitive = item.primitive

            if frameCounter <= 2 {
                vrmLog("[WEDGE DEBUG] Mesh: '\(meshName)', Primitive: \(meshPrimIndex), Material: '\(item.materialName)'")
                vrmLog("  - Primitive type: \(primitive.primitiveType == .triangle ? "triangles" : "other(\(primitive.primitiveType.rawValue))")")
                vrmLog("  - Index type: \(primitive.indexType == .uint16 ? "uint16" : "uint32")")
                vrmLog("  - Index offset: \(primitive.indexBufferOffset)")
            }

            // PERFORMANCE: Vertex bounds checking disabled - this was iterating through EVERY VERTEX
            // of EVERY PRIMITIVE EVERY FRAME (tens of thousands of vertices × 60fps)
            // If needed for debugging, should be load-time only and cached as a flag

            // Use effective properties from RenderItem (includes overrides)
            let materialAlphaMode = item.effectiveAlphaMode
            let isDoubleSided = item.effectiveDoubleSided

            // Contract validation: effective alpha mode should be valid
            precondition(["opaque", "mask", "blend"].contains(materialAlphaMode),
                        "Invalid effective alpha mode: \(materialAlphaMode)")

            // Choose pipeline based on skinning AND alpha mode
            let nodeHasSkin = item.node.skin != nil

            // Debug: Check if this mesh uses skinning even if node doesn't have skin property
            let meshUsesSkinning = item.primitive.hasJoints && item.primitive.hasWeights
            if meshUsesSkinning && !nodeHasSkin {
                vrmLog("[SKINNING DEBUG] Mesh '\(item.mesh.name ?? "unnamed")' has JOINTS/WEIGHTS but node.skin=\(item.node.skin ?? -1)")
            }

            // A mesh needs skinning if either the node has skin OR the primitive has joint attributes
            let isSkinned = (nodeHasSkin || meshUsesSkinning) && hasSkinning

            // Debug pipeline selection
            if frameCounter % 60 == 0 && (nodeHasSkin || meshUsesSkinning) {
                vrmLog("[PIPELINE DEBUG] Node '\(item.node.name ?? "unnamed")': nodeHasSkin=\(nodeHasSkin), meshUsesSkinning=\(meshUsesSkinning), hasSkinning=\(hasSkinning), isSkinned=\(isSkinned)")
            }

            // Select correct pipeline based on alpha mode and debug settings
            let activePipelineState: MTLRenderPipelineState?
            if debugWireframe {
                // Use wireframe pipeline for debugging (non-skinned only for now)
                activePipelineState = wireframePipelineState
            } else if materialAlphaMode == "blend" {
                // Standard 3D BLEND mode requires blending-enabled PSO
                activePipelineState = isSkinned ? skinnedBlendPipelineState : blendPipelineState
            } else {
                // Standard 3D OPAQUE and MASK modes can share the same PSO (no blending)
                activePipelineState = isSkinned ? skinnedOpaquePipelineState : opaquePipelineState

                // Debug which pipeline is selected
                if frameCounter % 60 == 0 && isSkinned {
                    vrmLog("[PIPELINE SELECT] Using skinned pipeline: \(skinnedOpaquePipelineState != nil ? "exists" : "NIL")")
                }
            }

            guard let pipeline = activePipelineState else {
                vrmLog("[VRMRenderer] ❌ No pipeline state! isSkinned=\(isSkinned), alphaMode=\(materialAlphaMode)")
                continue
            }

            // Log which PSO is being used - CRITICAL for debugging
            if frameCounter < 2 {
                vrmLog("[PSO] Setting pipeline: \(pipeline.label ?? "UNKNOWN")")
            }
            encoder.setRenderPipelineState(pipeline)

            // Set triangle fill mode for wireframe debug
            #if os(macOS)
            if debugWireframe {
                encoder.setTriangleFillMode(.lines)
            }
            #endif

            // Track pipeline state change
            if lastPipelineState !== pipeline {
                performanceTracker?.recordStateChange(type: .pipeline)
                lastPipelineState = pipeline
            }

            // DEBUG: Log render pass info for diagnosis
            if frameCounter <= 2 || (frameCounter % 180 == 0 && item.materialName.lowercased().contains("body")) {
                let psoType: String
                if isSkinned {
                    psoType = materialAlphaMode == "blend" ? "SKINNED_BLEND_PSO" : "SKINNED_OPAQUE_PSO"
                } else {
                    psoType = materialAlphaMode == "blend" ? "BLEND_PSO" : "OPAQUE_PSO"
                }
                let depthWrite = materialAlphaMode != "blend"
                vrmLog("[DRAW CALL] Mesh: \(item.mesh.name ?? "unnamed"), Material: \(item.materialName)")
                vrmLog("  - Alpha: \(materialAlphaMode), PSO: \(psoType), DepthWrite: \(depthWrite)")
                let worldPos = item.node.worldMatrix.columns.3
                vrmLog("  - Node: \(item.node.name ?? "unnamed"), WorldPos: (\(worldPos.x), \(worldPos.y), \(worldPos.z))")
            }

            // Update model matrix for this node
            // Apply VRM version rotation: VRM 1.0 models face +Z, need 180° Y rotation to face camera at -Z
            // For skinned meshes, use vrmVersionRotation (transforms are in skinning data)
            // For non-skinned meshes, multiply vrmVersionRotation with node's world transform
            let vrmRotation = vrmVersionRotation
            if isSkinned {
                uniforms.modelMatrix = vrmRotation
                uniforms.normalMatrix = vrmRotation // Rotation-only matrix works for normals
                if frameCounter % 60 == 0 {
                    vrmLog("[MATRIX DEBUG] Node '\(item.node.name ?? "unnamed")' isSkinned=true, VRM\(model.isVRM0 ? "0.0" : "1.0") rotation applied")
                }
            } else {
                uniforms.modelMatrix = simd_mul(vrmRotation, item.node.worldMatrix)
                uniforms.normalMatrix = uniforms.modelMatrix.inverse.transpose
                if frameCounter % 60 == 0 {
                    vrmLog("[MATRIX DEBUG] Node '\(item.node.name ?? "unnamed")' isSkinned=false, VRM\(model.isVRM0 ? "0.0" : "1.0") rotation * WORLD matrix")
                }
            }
            uniformsBuffer.contents().copyMemory(from: &uniforms, byteCount: MemoryLayout<Uniforms>.size)

            // Always use the unified vertex buffer
            guard let vertexBuffer = primitive.vertexBuffer else {
                vrmLog("[VRMRenderer] Warning: Primitive has no vertex buffer")
                continue
            }

            // Track vertex offset for this primitive
            var currentVertexOffset: UInt32 = 0

            // Binding order contract for vertex shader:
            // Uses ResourceIndices constants for strict validation

            // Use cached meshIndex/primIdxInMesh for O(1) lookup instead of O(n) search
            // This ensures stable key matches the morph compute pass (per-mesh primitive index)
            let meshIdx = item.meshIndex
            let primIdx = item.primIdxInMesh
            let stableKey: MorphKey = (UInt64(meshIdx) << 32) | UInt64(primIdx)
            let morphedPosBuffer = morphedBuffers[stableKey]

            if !primitive.morphTargets.isEmpty && frameCounter < 2 {
                let meshName = item.mesh.name ?? "?"
                vrmLog("[DICT LOOKUP] frame=\(frameCounter) draw=\(drawIndex) mesh[\(meshIdx)]='\(meshName)' prim[\(primIdx)] key=\(stableKey) found=\(morphedPosBuffer != nil) dictSize=\(morphedBuffers.count)")
            }

            if let morphedPosBuffer {
                // CORRECT BINDING: Original vertex buffer at stage_in (index 0) for UVs/normals/etc.
                encoder.setVertexBuffer(vertexBuffer, offset: 0, index: ResourceIndices.vertexBuffer)

                // Morphed positions as shader expects
                encoder.setVertexBuffer(morphedPosBuffer, offset: 0, index: ResourceIndices.morphedPositionsBuffer)

                // Signal presence of morphed positions to the shader
                var hasMorphedFlag: UInt32 = 1
                encoder.setVertexBytes(&hasMorphedFlag, length: MemoryLayout<UInt32>.size, index: ResourceIndices.hasMorphedPositionsFlag)

                if frameCounter % 60 == 0 {
                    let meshName = item.mesh.name ?? "?"
                    vrmLog("[VRMRenderer] BINDING morphed buffer: mesh='\(meshName)' draw=\(drawIndex) bufferSize=\(morphedPosBuffer.length) vertices=\(primitive.vertexCount)")
                }
            } else {
                // No morphed positions - use original vertex buffer for all attributes
                encoder.setVertexBuffer(vertexBuffer, offset: 0, index: ResourceIndices.vertexBuffer)

                // Bind a small dummy buffer to satisfy Metal debug validation, and set flag=0
                if emptyFloat3Buffer == nil {
                    emptyFloat3Buffer = device.makeBuffer(length: MemoryLayout<SIMD3<Float>>.stride, options: .storageModeShared)
                }
                encoder.setVertexBuffer(emptyFloat3Buffer, offset: 0, index: ResourceIndices.morphedPositionsBuffer)
                var hasMorphedFlag: UInt32 = 0
                encoder.setVertexBytes(&hasMorphedFlag, length: MemoryLayout<UInt32>.size, index: ResourceIndices.hasMorphedPositionsFlag)
            }

            encoder.setVertexBuffer(uniformsBuffer, offset: 0, index: ResourceIndices.uniformsBuffer)

            // Update and set joint matrices for skinned meshes
            // meshUsesSkinning was already defined above
            if hasSkinning && (item.node.skin != nil || meshUsesSkinning) {
                // Determine which skin to use
                let skinIndex: Int
                if let nodeSkinIndex = item.node.skin {
                    skinIndex = nodeSkinIndex
                } else if meshUsesSkinning && model.skins.count > 0 {
                    // If mesh has skinning attributes but node doesn't specify skin, use first skin
                    // This is common in some GLTF/VRM exporters
                    skinIndex = 0
                    if frameCounter % 60 == 0 {
                        vrmLog("[SKIN FALLBACK] Mesh '\(item.mesh.name ?? "unnamed")' has JOINTS/WEIGHTS, using skin 0")
                    }
                } else {
                    // No skin available
                    skinIndex = -1
                }

                if skinIndex >= 0 && skinIndex < model.skins.count {
                    let skin = model.skins[skinIndex]

                    // Debug which skin is used for which mesh
                    if frameCounter % 60 == 0 && primitive === item.mesh.primitives.first {
                        vrmLog("[SKIN DEBUG] Node '\(item.node.name ?? "unnamed")' mesh \(item.meshIndex) uses skin \(skinIndex)")
                    }

                    // Verify skin freshness (palette should already be updated at frame start)
                    skinningSystem?.verifySkinFreshness(skinIndex: skinIndex, frameNumber: frameCounter)

                    // VALIDATION: Check joints/weights bounds for first few vertices
                    let paletteCount = skin.joints.count
                    if primitive.hasJoints && primitive.hasWeights {
                        validateSkinningInputs(
                            primitive: primitive,
                            paletteCount: paletteCount,
                            meshName: item.node.name ?? "unknown",
                            materialName: item.materialName,
                            skinIndex: skinIndex
                        )
                    }

                    // Set the buffer at offset 0 and pass the matrix offset explicitly
                    if let jointBuffer = skinningSystem?.getJointMatricesBuffer() {
                        // Debug: Log which skin is being used for which mesh
                        if frameCounter % 60 == 0 {
                            vrmLog("[SKIN DEBUG] Mesh \(item.node.name ?? "unnamed") using skin \(skinIndex): offset=\(skin.matrixOffset), joints=\(skin.joints.count)")
                            if item.node.name == "face" {
                                vrmLog("[FACE DEBUG] Rendering face with \(skin.joints.count) joints")
                            }
                        }

                        // Set the buffer with the correct byte offset for this skin
                        // Use the pre-calculated bufferByteOffset from setupForSkins()
                        let byteOffset = skin.bufferByteOffset

                        // Debug: Log what we're doing for face rendering
                        if frameCounter % 60 == 0 && item.node.name?.contains("face") == true {
                            vrmLog("[FACE SKIN] Using skin \(skinIndex): matrixOffset=\(skin.matrixOffset), bufferByteOffset=\(byteOffset), joints=\(skin.joints.count)")
                        }

                        // Debug: Log joint count for shorts to check for buffer overflow
                        if frameCounter % 60 == 0 && (item.nodeNameLower.contains("short") || item.nodeNameLower.contains("pants") || item.nodeNameLower.contains("body")) {
                            vrmLog("[SHORTS DEBUG] Mesh '\(item.node.name ?? "unnamed")' using skin \(skinIndex): jointCount=\(skin.joints.count), bufferOffset=\(byteOffset)")
                        }

                        encoder.setVertexBuffer(jointBuffer, offset: byteOffset, index: ResourceIndices.jointMatricesBuffer)
                    }
                } else {
                    // Skin index is out of range - this shouldn't happen
                    vrmLog("[SKIN ERROR] Node '\(item.node.name ?? "unnamed")' has invalid skin index \(skinIndex) (max: \(model.skins.count - 1))")
                }
            } else if hasSkinning {
                // This node doesn't have a skin but we're in skinned pipeline
                // This means it's a rigid mesh that should use the regular (non-skinned) pipeline
                // For now, just pass identity matrices
                if frameCounter % 60 == 0 && primitive === item.mesh.primitives.first {
                    vrmLog("[SKIN DEBUG] Node '\(item.node.name ?? "unnamed")' mesh \(item.meshIndex) has NO skin - using rigid transform")
                }
            }

            // Morphed positions are already set at the primary vertex buffer slot above
            // No need to pass them again at a different index

                // GPU compute has already applied morphs - no need for vertex shader morphing
                // OPTIMIZATION: Use static zero weights array
                if !primitive.morphTargets.isEmpty {
                    encoder.setVertexBytes(Self.zeroMorphWeights,
                                           length: Self.zeroMorphWeights.count * MemoryLayout<Float>.size,
                                           index: ResourceIndices.morphWeightsBuffer)

                    // Morph deltas are no longer used (GPU compute path handles morphs)
                    // Do NOT clear buffer indices here - it would overwrite jointCount (4),
                    // morphedPositions (20), and other active bindings
                }

                // Pass vertex offset for proper morph buffer indexing
                encoder.setVertexBytes(&currentVertexOffset, length: MemoryLayout<UInt32>.size, index: ResourceIndices.vertexOffsetBuffer)

                // Set material and textures using MToon system
                // Initialize with sensible defaults to prevent white rendering
                var mtoonUniforms = MToonMaterialUniforms()
                mtoonUniforms.baseColorFactor = SIMD4<Float>(1.0, 1.0, 1.0, 1.0)  // White base
                var textureCount = 0

                // Check if this is a face or body material EARLY for alpha mode override
                // OPTIMIZATION: Use cached lowercased strings from RenderItem
                let materialNameLower = item.materialNameLower
                let nodeName = item.nodeNameLower
                let meshNameLower = item.meshNameLower

                let isFaceOrBodyMaterial = materialNameLower.contains("face") || materialNameLower.contains("eye") ||
                                          materialNameLower.contains("body") || materialNameLower.contains("skin") ||
                                          nodeName.contains("face") || nodeName.contains("eye") ||
                                          nodeName.contains("body") || meshNameLower.contains("face") ||
                                          meshNameLower.contains("eye") || meshNameLower.contains("body")

                // PHASE 4: Enhanced face material debug logging
                let isFaceMaterial = materialNameLower.contains("face") || materialNameLower.contains("eye") ||
                                    nodeName.contains("face") || nodeName.contains("eye") ||
                                    meshNameLower.contains("face") || meshNameLower.contains("eye")

                // Log material processing for debugging
                if frameCounter <= 2 || (frameCounter % 60 == 0 && isFaceMaterial) {
                    vrmLog("[MATERIAL PROCESSING] Material: '\(item.materialName)', Node: '\(item.node.name ?? "unnamed")', Mesh: '\(item.mesh.name ?? "unnamed")'")
                    vrmLog("  - Original alpha mode: \(materialAlphaMode)")
                    vrmLog("  - Is face/body: \(isFaceOrBodyMaterial)")
                    vrmLog("  - Is face: \(isFaceMaterial)")
                }

                // Track material changes
                if let materialIndex = primitive.materialIndex {
                    if materialIndex != lastMaterialId {
                        performanceTracker?.recordStateChange(type: .other)
                        lastMaterialId = materialIndex
                    }
                }

                if let materialIndex = primitive.materialIndex,
                   materialIndex < model.materials.count {
                    let material = model.materials[materialIndex]

                    // Set VRM version for version-aware shading (0 = VRM 0.0, 1 = VRM 1.0)
                    mtoonUniforms.vrmVersion = material.vrmVersion == .v0_0 ? 0 : 1

                    // Set base PBR properties
                    mtoonUniforms.baseColorFactor = material.baseColorFactor
                    mtoonUniforms.metallicFactor = material.metallicFactor
                    mtoonUniforms.roughnessFactor = material.roughnessFactor
                    mtoonUniforms.emissiveFactor = material.emissiveFactor

                    // LIGHTING FIX: Zero out emissive to prevent washout
                    mtoonUniforms.emissiveFactor = SIMD3<Float>(0, 0, 0)

                    // DEBUG: Log original baseColorFactor for all materials
                    #if DEBUG
                    if frameCounter <= 2 {
                        vrmLog("[Material] '\(item.materialName)' baseColorFactor: \(material.baseColorFactor)")
                        if material.baseColorFactor.x > 10.0 || material.baseColorFactor.y > 10.0 ||
                           material.baseColorFactor.z > 10.0 || material.baseColorFactor.w > 10.0 {
                            vrmLog("  ⚠️ WARNING: baseColorFactor has extreme values!")
                        }
                    }
                    #endif

                    // PHASE 4 FIX: Force face materials to render with full brightness
                    if isFaceMaterial {
                        // AGGRESSIVE FIX: Always force white baseColorFactor for face materials
                        // This ensures the texture shows at full brightness
                        if frameCounter <= 2 {
                            vrmLog("  🔧 [FACE FIX] Forcing baseColorFactor to white for '\(item.materialName)'")
                            vrmLog("     - Original: \(mtoonUniforms.baseColorFactor)")
                        }
                        mtoonUniforms.baseColorFactor = SIMD4<Float>(1.0, 1.0, 1.0, 1.0)

                        // LIGHTING FIX: Improve face shading for contours (skin only, not eyes)
                        if item.faceCategory != "eye" {
                            mtoonUniforms.shadeColorFactor = SIMD3<Float>(0.78, 0.65, 0.60)  // Stronger warm shadow
                            mtoonUniforms.shadingToonyFactor = 0.3  // Even softer transition
                            mtoonUniforms.shadingShiftFactor = -0.2  // More shadow for contours
                        }

                        // Ensure texture flag is set
                        if material.baseColorTexture != nil {
                            mtoonUniforms.hasBaseColorTexture = 1
                        }
                    }

                    // Set alpha mode properties - DO NOT override for face parts
                    if isFaceMaterial {
                        // Preserve original alpha behavior for face parts (skin/eyes/lashes/lines)
                        switch materialAlphaMode {
                        case "mask": mtoonUniforms.alphaMode = 1
                        case "blend": mtoonUniforms.alphaMode = 2
                        default: mtoonUniforms.alphaMode = 0
                        }
                        mtoonUniforms.alphaCutoff = item.effectiveAlphaCutoff
                    } else if materialAlphaMode == "mask" && (materialNameLower.contains("skin") || materialNameLower.contains("body")) {
                        // For non-face body/skin, convert MASK→OPAQUE to avoid punch-through artifacts
                        mtoonUniforms.alphaMode = 0
                        mtoonUniforms.alphaCutoff = 0.0
                        if frameCounter % 60 == 0 { vrmLog("[ALPHA OVERRIDE] MASK→OPAQUE for body/skin: \(item.materialName)") }
                    } else {
                        // Use EFFECTIVE alpha mode for other materials and non-mask face materials
                        switch materialAlphaMode {
                        case "mask":
                            mtoonUniforms.alphaMode = 1
                        case "blend":
                            mtoonUniforms.alphaMode = 2
                        default: // "opaque" or unknown
                            mtoonUniforms.alphaMode = 0
                        }
                        mtoonUniforms.alphaCutoff = item.effectiveAlphaCutoff
                    }

                    // If material has MToon extension, use those properties
                    if let mtoon = material.mtoon {
                        mtoonUniforms = MToonMaterialUniforms(from: mtoon)
                        mtoonUniforms.baseColorFactor = material.baseColorFactor // Keep base color from PBR
                        // Set VRM version for version-aware shading (0 = VRM 0.0, 1 = VRM 1.0)
                        mtoonUniforms.vrmVersion = material.vrmVersion == .v0_0 ? 0 : 1

                        // UV FIX: Shift FaceMouth UVs to lip texture area (bottom right of atlas)
                        // The mouth mesh UVs are centered at (0.4, 0.48) which is the blank face area
                        // We need to shift them to the lip texture area around (0.7, 0.7)
                        if item.materialNameLower.contains("mouth") || item.materialNameLower.contains("lip") {
                            mtoonUniforms.uvOffsetX = 0.35  // Shift right to lip area
                            mtoonUniforms.uvOffsetY = 0.25  // Shift down to lip area
                            mtoonUniforms.uvScale = 0.5     // Scale down to fit lip texture
                            if frameCounter <= 2 {
                                vrmLog("🔧 [MOUTH UV FIX] Applied UV offset for \(item.materialName)")
                            }
                        }

                        // LIGHTING FIX: Zero emissive AFTER MToon init to prevent washout
                        mtoonUniforms.emissiveFactor = SIMD3<Float>(0, 0, 0)

                        // ALPHA FIX: Restore effectiveAlphaMode AFTER MToon init
                        // MToon extension may have wrong alphaMode; use our detected/fixed value
                        switch materialAlphaMode {
                        case "mask":
                            mtoonUniforms.alphaMode = 1
                            mtoonUniforms.alphaCutoff = item.effectiveAlphaCutoff
                        case "blend":
                            mtoonUniforms.alphaMode = 2
                        default:
                            mtoonUniforms.alphaMode = 0
                        }
                    } else {
                        // NO MToon extension - use default PBR values
                        // Apply SELECTIVE alpha mode override for face/body materials AFTER MToon init
                        if isFaceOrBodyMaterial && materialAlphaMode == "mask" {
                            // Only override MASK mode to prevent incorrect discard
                            mtoonUniforms.alphaMode = 0  // Force OPAQUE instead of MASK
                            mtoonUniforms.alphaCutoff = 0.0  // Disable cutoff
                        } else {
                            // Use EFFECTIVE alpha mode (includes overrides)
                            switch materialAlphaMode {
                            case "mask":
                                mtoonUniforms.alphaMode = 1
                            case "blend":
                                mtoonUniforms.alphaMode = 2
                            default:
                                mtoonUniforms.alphaMode = 0
                            }
                        mtoonUniforms.alphaCutoff = item.effectiveAlphaCutoff
                    }

                    // Eye material rendering adjustments
                    if let faceCat = item.faceCategory, faceCat == "eye" {
                        // Eyes should appear vivid and unshaded; disable stylized shading paths
                        mtoonUniforms.shadeColorFactor = SIMD3<Float>(repeating: 1.0)
                        mtoonUniforms.shadingToonyFactor = 0.0
                        mtoonUniforms.shadingShiftFactor = 0.0
                        mtoonUniforms.rimLightingMixFactor = 0.0
                        mtoonUniforms.parametricRimColorFactor = SIMD3<Float>(repeating: 0.0)
                        mtoonUniforms.hasMatcapTexture = 0
                        // LIGHTING FIX: Don't boost emissive - let lighting handle visibility
                        // if all(mtoonUniforms.emissiveFactor .< SIMD3<Float>(repeating: 0.2)) {
                        //     mtoonUniforms.emissiveFactor = SIMD3<Float>(repeating: 0.2)
                        // }
                    }

                        // Log MToon material properties (commented out to reduce noise)
                        // vrmLog("[VRMRenderer] Using MToon material for primitive:")
                        // vrmLog("  - Shade color: \(mtoon.shadeColorFactor)")
                        // vrmLog("  - Matcap factor: \(mtoon.matcapFactor)")
                        // vrmLog("  - Rim color: \(mtoon.parametricRimColorFactor)")
                    }

                    // Bind textures in MToon order
                    // Index 0: Base color texture
                    if let texture = material.baseColorTexture,
                       let mtlTexture = texture.mtlTexture {
                        encoder.setFragmentTexture(mtlTexture, index: 0)
                        mtoonUniforms.hasBaseColorTexture = 1
                        textureCount += 1
                        performanceTracker?.recordStateChange(type: .texture)
                    }

                    // Index 1: Shade multiply texture (from MToon)
                    if let mtoon = material.mtoon,
                       let textureIndex = mtoon.shadeMultiplyTexture,
                       textureIndex < model.textures.count,
                       let mtlTexture = model.textures[textureIndex].mtlTexture {
                        encoder.setFragmentTexture(mtlTexture, index: 1)
                        mtoonUniforms.hasShadeMultiplyTexture = 1
                        textureCount += 1
                        // vrmLog("[VRMRenderer] Bound shade multiply texture at index 1")
                    }

                    // Index 2: Shading shift texture
                    if let mtoon = material.mtoon,
                       let shadingShift = mtoon.shadingShiftTexture,
                       shadingShift.index < model.textures.count,
                       let mtlTexture = model.textures[shadingShift.index].mtlTexture {
                        encoder.setFragmentTexture(mtlTexture, index: 2)
                        mtoonUniforms.hasShadingShiftTexture = 1
                        mtoonUniforms.shadingShiftTextureScale = shadingShift.scale ?? 1.0
                        textureCount += 1
                        // vrmLog("[VRMRenderer] Bound shading shift texture at index 2")
                    }

                    // Index 3: Normal texture (provides surface detail)
                    if let mtlTexture = material.normalTexture?.mtlTexture {
                        encoder.setFragmentTexture(mtlTexture, index: 3)
                        mtoonUniforms.hasNormalTexture = 1
                        textureCount += 1
                    }

                    // Index 4: Emissive texture
                    if let mtlTexture = material.emissiveTexture?.mtlTexture {
                        encoder.setFragmentTexture(mtlTexture, index: 4)
                        mtoonUniforms.hasEmissiveTexture = 1
                        textureCount += 1
                    }

                    // Index 5: Matcap texture
                    if let mtoon = material.mtoon,
                       let textureIndex = mtoon.matcapTexture,
                       textureIndex < model.textures.count,
                       let mtlTexture = model.textures[textureIndex].mtlTexture {
                        encoder.setFragmentTexture(mtlTexture, index: 5)
                        mtoonUniforms.hasMatcapTexture = 1
                        textureCount += 1
                        // vrmLog("[VRMRenderer] Bound matcap texture at index 5")
                    }

                    // Index 6: Rim multiply texture
                    if let mtoon = material.mtoon,
                       let textureIndex = mtoon.rimMultiplyTexture,
                       textureIndex < model.textures.count,
                       let mtlTexture = model.textures[textureIndex].mtlTexture {
                        encoder.setFragmentTexture(mtlTexture, index: 6)
                        mtoonUniforms.hasRimMultiplyTexture = 1
                        textureCount += 1
                        // vrmLog("[VRMRenderer] Bound rim multiply texture at index 6")
                    }

                    // Index 7: UV animation mask texture
                    if let mtoon = material.mtoon,
                       let textureIndex = mtoon.uvAnimationMaskTexture,
                       textureIndex < model.textures.count,
                       let mtlTexture = model.textures[textureIndex].mtlTexture {
                        encoder.setFragmentTexture(mtlTexture, index: 7)
                        mtoonUniforms.hasUvAnimationMaskTexture = 1
                        textureCount += 1
                        // vrmLog("[VRMRenderer] Bound UV animation mask texture at index 7")
                    }

                    // Set sampler for all texture indices (cached in setupCachedStates)
                    if let cachedSampler = samplerStates["default"] {
                        encoder.setFragmentSamplerState(cachedSampler, index: 0)
                    }

                    // Log texture binding only once per material
                    // Removed per-primitive logging to reduce noise
                }

            // Enhanced face/body material detection - check both material names AND mesh/node names
            // Variables already declared above, reuse them

            let isBodyMaterial = materialNameLower.contains("body") ||
                               materialNameLower.contains("skin") ||
                               nodeName.contains("body") ||
                               meshNameLower.contains("body")

            // PHASE 4: Log MToon uniforms for face materials
            if isFaceMaterial && frameCounter % 60 == 0 {
                vrmLog("\n━━━ [FACE MATERIAL DEBUG] ━━━")
                vrmLog("  Material: '\(item.materialName)'")
                vrmLog("  Node: '\(item.node.name ?? "unnamed")', Mesh: '\(item.mesh.name ?? "unnamed")'")
                vrmLog("  Alpha mode: \(materialAlphaMode), Double-sided: \(isDoubleSided)")
                vrmLog("  MToon Uniforms:")
                vrmLog("    - baseColorFactor: \(mtoonUniforms.baseColorFactor)")
                vrmLog("    - hasBaseColorTexture: \(mtoonUniforms.hasBaseColorTexture)")
                vrmLog("    - alphaMode: \(mtoonUniforms.alphaMode) (0=opaque, 1=mask, 2=blend)")
                vrmLog("    - alphaCutoff: \(mtoonUniforms.alphaCutoff)")
                vrmLog("    - emissiveFactor: \(mtoonUniforms.emissiveFactor)")
                vrmLog("  Textures bound: \(textureCount)")
                vrmLog("━━━━━━━━━━━━━━━━━━━━━━━━━\n")
            }

            if (isFaceMaterial || isBodyMaterial) && frameCounter % 60 == 0 {
                vrmLog("[MATERIAL FIX] Face/Body material detected:")
                vrmLog("  - Material: '\(item.materialName)'")
                vrmLog("  - Node: '\(item.node.name ?? "unnamed")'")
                vrmLog("  - Mesh: '\(item.mesh.name ?? "unnamed")'")
                vrmLog("  - Alpha mode: \(materialAlphaMode)")
                vrmLog("  - Will apply special rendering fixes")
            }

            // FACE RENDERING: Apply deterministic states per face category
            if let faceCategory = item.faceCategory {
                // Calculate view-space Z for logging
                let viewPos = uniforms.viewMatrix * item.node.worldMatrix.columns.3
                let viewZ = viewPos.z

                switch faceCategory {
                case "body":
                    // Body (with lace texture) renders FIRST (order=0)
                    // Uses lessEqual - later materials win at equal depths
                    // Depth bias: pushed back slightly to allow clothing/skin to win at seams
                    if let faceState = depthStencilStates["face"] {
                        encoder.setDepthStencilState(faceState)
                    } else {
                        encoder.setDepthStencilState(depthStencilStates["opaque"])
                    }
                    encoder.setCullMode(.back)
                    encoder.setFrontFacing(.counterClockwise)
                    // Z-FIGHTING FIX: Body renders first but pushed back in depth
                    // Negative bias pushes away from camera, allowing overlays to win
                    encoder.setDepthBias(-0.1, slopeScale: 4.0, clamp: 1.0)
                    if frameCounter % 60 == 0 {
                        vrmLog("[FACE] order=body  z=\(viewZ)  mat=\(item.materialName)")
                    }

                case "clothing":
                    // Clothing renders AFTER body - wins at overlaps via render order
                    if let faceState = depthStencilStates["face"] {
                        encoder.setDepthStencilState(faceState)
                    } else {
                        encoder.setDepthStencilState(depthStencilStates["opaque"])
                    }
                    encoder.setCullMode(.back)
                    encoder.setFrontFacing(.counterClockwise)
                    // Apply depth bias for clothing (overlay layer)
                    let bias = depthBiasCalculator.depthBias(for: item.materialName, isOverlay: true)
                    encoder.setDepthBias(bias, slopeScale: depthBiasCalculator.slopeScale, clamp: depthBiasCalculator.clamp)
                    if frameCounter % 60 == 0 {
                        vrmLog("[FACE] order=clothing  z=\(viewZ)  mat=\(item.materialName)")
                    }

                case "skin":
                    // Face skin renders AFTER body - wins at neck seam via render order
                    // Z-FIGHTING FIX: Use different depth states for base vs overlay materials
                    let isOverlay = item.materialNameLower.contains("mouth") || item.materialNameLower.contains("eyebrow")

                    if isOverlay {
                        // Overlay materials (mouth, eyebrows): use faceOverlay state
                        // lessEqual allows winning at equal depth, no depth write prevents Z-fighting
                        if let overlayState = depthStencilStates["faceOverlay"] {
                            encoder.setDepthStencilState(overlayState)
                        } else {
                            encoder.setDepthStencilState(depthStencilStates["face"])
                        }
                    } else {
                        // Base face skin: use normal face state with depth write
                        if let faceState = depthStencilStates["face"] {
                            encoder.setDepthStencilState(faceState)
                        } else {
                            encoder.setDepthStencilState(depthStencilStates["opaque"])
                        }
                    }

                    encoder.setCullMode(.back)
                    encoder.setFrontFacing(.counterClockwise)

                    // Apply material-specific depth bias from calculator
                    let bias = depthBiasCalculator.depthBias(
                        for: item.materialName,
                        isOverlay: isOverlay
                    )
                    encoder.setDepthBias(bias, slopeScale: depthBiasCalculator.slopeScale, clamp: depthBiasCalculator.clamp)

                    if frameCounter % 60 == 0 {
                        vrmLog("[FACE] order=skin  z=\(viewZ)  mat=\(item.materialName)  overlay=\(isOverlay)")
                    }

                case "faceOverlay":
                    // Face mouth/lip overlays - render on top of face skin
                    // Uses face state with depth bias to win depth test
                    if let faceState = depthStencilStates["face"] {
                        encoder.setDepthStencilState(faceState)
                    } else {
                        encoder.setDepthStencilState(depthStencilStates["mask"])
                    }
                    encoder.setCullMode(.none)
                    encoder.setFrontFacing(.counterClockwise)
                    // Apply depth bias for mouth/lip overlays
                    let bias = depthBiasCalculator.depthBias(for: item.materialName, isOverlay: true)
                    encoder.setDepthBias(bias, slopeScale: depthBiasCalculator.slopeScale, clamp: depthBiasCalculator.clamp)
                    // Face overlays use MASK mode for proper alpha cutout
                    // This allows mouth/lip shapes to be properly masked without
                    // edge artifacts from OPAQUE mode blending

                case "eyebrow", "eyeline":
                    // Face features render after skin - win via render order
                    if let faceState = depthStencilStates["face"] {
                        encoder.setDepthStencilState(faceState)
                    } else {
                        encoder.setDepthStencilState(depthStencilStates["mask"])
                    }
                    encoder.setCullMode(.none)
                    encoder.setFrontFacing(.counterClockwise)
                    // Apply depth bias for eyebrow/eyeline overlays
                    let bias = depthBiasCalculator.depthBias(for: item.materialName, isOverlay: true)
                    encoder.setDepthBias(bias, slopeScale: depthBiasCalculator.slopeScale, clamp: depthBiasCalculator.clamp)
                    if frameCounter % 60 == 0 {
                        vrmLog("[FACE] order=\(faceCategory)  z=\(viewZ)  mat=\(item.materialName)")
                    }

                case "eye":
                    // Eyes render after skin - win via render order
                    // Depth bias: higher bias to ensure eyes win over eyelids/face
                    if let faceState = depthStencilStates["face"] {
                        encoder.setDepthStencilState(faceState)
                    } else {
                        encoder.setDepthStencilState(depthStencilStates["opaque"])
                    }
                    encoder.setCullMode(.none)
                    encoder.setFrontFacing(.counterClockwise)
                    // Apply depth bias for eye overlays (highest priority)
                    let bias = depthBiasCalculator.depthBias(for: item.materialName, isOverlay: true)
                    encoder.setDepthBias(bias, slopeScale: depthBiasCalculator.slopeScale, clamp: depthBiasCalculator.clamp)
                    if frameCounter % 60 == 0 {
                        vrmLog("[FACE] order=eye  z=\(viewZ)  mat=\(item.materialName)")
                    }
                case "highlight":
                    // Eye highlights render last - win via render order
                    if let blendDepthState = depthStencilStates["blend"] {
                        encoder.setDepthStencilState(blendDepthState)
                    } else {
                        encoder.setDepthStencilState(depthStencilStates["opaque"])
                    }
                    encoder.setCullMode(.none)
                    encoder.setFrontFacing(.counterClockwise)
                    // Apply depth bias for highlight overlays (highest bias)
                    let bias = depthBiasCalculator.depthBias(for: item.materialName, isOverlay: true)
                    encoder.setDepthBias(bias, slopeScale: depthBiasCalculator.slopeScale, clamp: depthBiasCalculator.clamp)
                    if frameCounter % 60 == 0 {
                        vrmLog("[FACE] order=highlight  z=\(viewZ)  mat=\(item.materialName)")
                    }

                case "transparentZWrite":
                    // TransparentWithZWrite: blend with depth write ON
                    // Uses face state (.lessEqual + depth write) to occlude what's behind
                    // Key for lace, collar, and semi-transparent overlays
                    if let faceState = depthStencilStates["face"] {
                        encoder.setDepthStencilState(faceState)
                    } else {
                        encoder.setDepthStencilState(depthStencilStates["opaque"])
                    }
                    encoder.setCullMode(.none)  // Often double-sided for overlays
                    encoder.setFrontFacing(.counterClockwise)
                    // Apply depth bias for transparent overlays
                    let bias = depthBiasCalculator.depthBias(for: item.materialName, isOverlay: true)
                    encoder.setDepthBias(bias, slopeScale: depthBiasCalculator.slopeScale, clamp: depthBiasCalculator.clamp)
                    if frameCounter % 60 == 0 {
                        vrmLog("[FACE] order=transparentZWrite  pso=face(.lessEqual+depthWrite)  z=\(viewZ)  mat=\(item.materialName)")
                    }

                default:
                    // Unknown face category - fallback to opaque
                    encoder.setDepthStencilState(depthStencilStates["opaque"])
                    encoder.setCullMode(.back)
                    encoder.setFrontFacing(.counterClockwise)
                }
            } else {
                // NON-FACE rendering: use standard alpha mode logic
                // Apply material-specific depth bias for all non-face materials
                let baseBias = depthBiasCalculator.depthBias(for: item.materialName, isOverlay: false)
                
                switch materialAlphaMode {
                case "opaque":
                    encoder.setDepthStencilState(depthStencilStates["opaque"])
                    let cullMode = isDoubleSided ? MTLCullMode.none : .back
                    encoder.setCullMode(cullMode)
                    encoder.setFrontFacing(.counterClockwise)
                    encoder.setDepthBias(baseBias, slopeScale: depthBiasCalculator.slopeScale, clamp: depthBiasCalculator.clamp)

                case "mask":
                    encoder.setDepthStencilState(depthStencilStates["mask"])
                    let cullMode = isDoubleSided ? MTLCullMode.none : .back
                    encoder.setCullMode(cullMode)
                    encoder.setFrontFacing(.counterClockwise)
                    // Apply base depth bias for MASK materials
                    encoder.setDepthBias(baseBias, slopeScale: depthBiasCalculator.slopeScale, clamp: depthBiasCalculator.clamp)

                case "blend":
                    if let blendDepthState = depthStencilStates["blend"] {
                        encoder.setDepthStencilState(blendDepthState)
                    } else {
                        encoder.setDepthStencilState(depthStencilStates["opaque"])
                    }
                    encoder.setCullMode(.none)
                    // Apply base depth bias for BLEND materials
                    encoder.setDepthBias(baseBias, slopeScale: depthBiasCalculator.slopeScale, clamp: depthBiasCalculator.clamp)

                default:
                    encoder.setDepthStencilState(depthStencilStates["opaque"])
                    let cullMode = isDoubleSided ? MTLCullMode.none : .back
                    encoder.setCullMode(cullMode)
                    encoder.setDepthBias(baseBias, slopeScale: depthBiasCalculator.slopeScale, clamp: depthBiasCalculator.clamp)
                }
            }

            // Debug: Log draw call details for Roblox model
            if false && (item.mesh.name?.contains("baked") == true || frameCounter <= 3) {
                vrmLog("[DRAW DEBUG] About to draw:")
                vrmLog("  - Mesh: \(item.mesh.name ?? "unnamed")")
                vrmLog("  - Node: \(item.node.name ?? "unnamed")")
                vrmLog("  - isSkinned: \(isSkinned)")
                vrmLog("  - Pipeline: \(isSkinned ? "skinned" : "non-skinned")")
                vrmLog("  - Vertex count: \(primitive.vertexCount)")
                vrmLog("  - Index count: \(primitive.indexCount)")
                vrmLog("  - Has joints: \(primitive.hasJoints)")
                vrmLog("  - Has weights: \(primitive.hasWeights)")
                vrmLog("  - Node skin: \(item.node.skin ?? -1)")
                let worldPos = item.node.worldMatrix.columns.3
                vrmLog("  - World position: (\(worldPos.x), \(worldPos.y), \(worldPos.z))")

                // Check uniform matrices
                vrmLog("  - Model matrix: \(isSkinned ? "IDENTITY" : "WORLD")")

                // Check if joint buffer is set
                if isSkinned && hasSkinning {
                    vrmLog("  - Joint buffer will be set for skin index: \(item.node.skin ?? 0)")
                }
            }

            // Draw with validation
            if let indexBuffer = primitive.indexBuffer {
                // Validate draw call in strict mode
                if config.strict != .off {
                    do {
                        try strictValidator?.recordDrawCall(
                            vertexCount: primitive.vertexCount,
                            indexCount: primitive.indexCount,
                            primitiveIndex: item.meshIndex
                        )
                    } catch {
                        if config.strict == .fail {
                            encoder.endEncoding()
                            vrmLog("❌ [VRMRenderer] Draw validation failed: \(error)")
                        } else {
                            vrmLog("⚠️ [VRMRenderer] Draw validation warning: \(error)")
                        }
                        continue  // Skip this primitive
                    }
                }

                if frameCounter % 180 == 0 {  // Log every 3 seconds
                    vrmLog("[VRMRenderer] Drawing mesh \(item.meshIndex): indexCount=\(primitive.indexCount), vertexCount=\(primitive.vertexCount)")
                }

                // Apply expression-driven material color overrides
                if let materialIndex = primitive.materialIndex {
                    if let colorOverride = expressionController?.getMaterialColorOverride(materialIndex: materialIndex, type: .color) {
                        mtoonUniforms.baseColorFactor = colorOverride
                    }
                    if let emissionOverride = expressionController?.getMaterialColorOverride(materialIndex: materialIndex, type: .emissionColor) {
                        mtoonUniforms.emissiveFactor = SIMD3<Float>(emissionOverride.x, emissionOverride.y, emissionOverride.z)
                    }
                    if let shadeOverride = expressionController?.getMaterialColorOverride(materialIndex: materialIndex, type: .shadeColor) {
                        mtoonUniforms.shadeColorFactor = SIMD3<Float>(shadeOverride.x, shadeOverride.y, shadeOverride.z)
                    }
                    if let matcapOverride = expressionController?.getMaterialColorOverride(materialIndex: materialIndex, type: .matcapColor) {
                        mtoonUniforms.matcapFactor = SIMD3<Float>(matcapOverride.x, matcapOverride.y, matcapOverride.z)
                    }
                    if let rimOverride = expressionController?.getMaterialColorOverride(materialIndex: materialIndex, type: .rimColor) {
                        mtoonUniforms.parametricRimColorFactor = SIMD3<Float>(rimOverride.x, rimOverride.y, rimOverride.z)
                    }
                    if let outlineOverride = expressionController?.getMaterialColorOverride(materialIndex: materialIndex, type: .outlineColor) {
                        mtoonUniforms.outlineColorFactor = SIMD3<Float>(outlineOverride.x, outlineOverride.y, outlineOverride.z)
                    }
                }

                // Set MToon material uniforms
                // Note: Both vertex and fragment shaders expect MToonMaterial at buffer(8)
                encoder.setVertexBytes(&mtoonUniforms,
                                       length: MemoryLayout<MToonMaterialUniforms>.stride,
                                       index: 8)
                encoder.setFragmentBytes(&mtoonUniforms,
                                       length: MemoryLayout<MToonMaterialUniforms>.stride,
                                       index: 8)

                // Also pass main uniforms to fragment shader for lighting
                encoder.setFragmentBuffer(uniformsBuffer, offset: 0, index: 1)

                // CRITICAL DEBUG: Test if we're reaching draw code
                if frameCounter < 2 {
                    vrmLog("[DRAW DEBUG] Frame \(frameCounter): About to draw primitive, index=\(index), material=\(item.materialName)")
                }

                // PHASE 4: Diagnose face geometry issues (artifact is PART OF FACE)
                if isFaceMaterial && frameCounter == 0, let vertexBuffer = primitive.vertexBuffer {
                    let stride = 96  // VRMVertex stride
                    let pointer = vertexBuffer.contents()
                    var minPos = SIMD3<Float>(Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude)
                    var maxPos = SIMD3<Float>(-Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude)

                    // Find bounds of face geometry
                    for i in 0..<primitive.vertexCount {
                        let offset = i * stride
                        let posPtr = pointer.advanced(by: offset).assumingMemoryBound(to: Float.self)
                        let pos = SIMD3<Float>(posPtr[0], posPtr[1], posPtr[2])
                        minPos = simd_min(minPos, pos)
                        maxPos = simd_max(maxPos, pos)
                    }

                    let center = (minPos + maxPos) * 0.5
                    let size = maxPos - minPos

                    vrmLog("📐 [FACE GEOMETRY] '\(item.mesh.name ?? "unnamed")'")
                    vrmLog("    - Center: (\(center.x), \(center.y), \(center.z))")
                    vrmLog("    - Size: (\(size.x), \(size.y), \(size.z))")
                    vrmLog("    - Bounds: [\(minPos.x) to \(maxPos.x), \(minPos.y) to \(maxPos.y), \(minPos.z) to \(maxPos.z)]")
                    vrmLog("    - Vertex count: \(primitive.vertexCount)")
                    vrmLog("    - Node world transform: \(item.node.worldMatrix.columns.3)")
                }

                // DEBUG: Log actual draw calls
                if allItems.count > 50 {
                    totalPrimitivesDrawn += 1
                    vrmLog("[DRAW CALL] Drawing primitive \(totalPrimitivesDrawn)/\(itemsToRender.count) - IndexCount: \(primitive.indexCount)")
                }

                // DEBUG RENDERER: Use debug renderer if in debug mode
                // CRITICAL: Simple test to see which path we're taking
                if index == 0 && frameCounter == 0 {
                    vrmLog("[PATH TEST] Reached draw code, debugSingleMesh=\(debugSingleMesh)")
                }

                // Normal production render path
                    if frameCounter < 2 {  // Only log first couple frames
                        vrmLog("[SHADER PATH DEBUG] Frame \(frameCounter): USING PRODUCTION RENDERER (mtoon_fragment_v2)")
                        vrmLog("[SHADER PATH DEBUG]   - pipeline = \(isSkinned ? "skinned" : "static") \(materialAlphaMode != "blend" ? "opaque" : "blend")")
                        vrmLog("[SHADER PATH DEBUG]   - debugUVs uniform = \(uniforms.debugUVs)")
                    }
                    // Texture binding verification in strict mode
                    if config.strict != .off {
                        // Verify texture binding consistency for the current material
                        if let materialIndex = primitive.materialIndex,
                           materialIndex < model.materials.count {
                            let material = model.materials[materialIndex]

                            if mtoonUniforms.hasBaseColorTexture > 0 && material.baseColorTexture == nil {
                                let message = "Material \(material.name ?? "unknown") expects base texture but none loaded!"
                                vrmLog("⚠️ [StrictMode] \(message)")
                            }

                            // Verify alpha mode consistency
                            if material.alphaMode.lowercased() == "opaque" && material.baseColorFactor.w < 0.99 {
                                let message = "OPAQUE material has alpha < 1.0: \(material.baseColorFactor.w)"
                                vrmLog("⚠️ [StrictMode] \(message)")
                            }
                        }
                    }

                    // Matrix slice validation before draw
                    if isSkinned, let skinIndex = item.node.skin ?? (primitive.hasJoints ? 0 : nil),
                       skinIndex >= 0 && skinIndex < model.skins.count {
                        let skin = model.skins[skinIndex]
                        let jointBuffer = skinningSystem?.getJointMatricesBuffer()

                        // Validate matrix slice bounds
                        assert(jointBuffer != nil, "[MATRIX SLICE] Joint buffer is nil for skinned draw!")
                        let totalMatrices = skinningSystem?.getTotalMatrixCount() ?? 0
                        let matrixOffset = skin.matrixOffset
                        let paletteCount = skin.joints.count

                        assert(matrixOffset + paletteCount <= totalMatrices,
                               "[MATRIX SLICE] Out of bounds! offset=\(matrixOffset) + count=\(paletteCount) > total=\(totalMatrices)")

                        if frameCounter < 5 {
                            vrmLog("[MATRIX SLICE] Valid: skin \(skinIndex) offset=\(matrixOffset), count=\(paletteCount), total=\(totalMatrices)")
                        }
                    }

                    // Index buffer validation
                    if frameCounter < 2 {
                        vrmLog("\n[INDEX BUFFER] Mesh '\(item.node.name ?? "unknown")':")
                        vrmLog("  - Index count: \(primitive.indexCount)")
                        vrmLog("  - Index type: \(primitive.indexType == MTLIndexType.uint16 ? "uint16" : "uint32")")
                        vrmLog("  - Buffer size: \(indexBuffer.length) bytes")
                        vrmLog("  - Required size: \(primitive.indexCount * (primitive.indexType == MTLIndexType.uint16 ? 2 : 4)) bytes")

                        // Validate buffer size
                        let requiredSize = primitive.indexCount * (primitive.indexType == MTLIndexType.uint16 ? 2 : 4)
                        assert(indexBuffer.length >= requiredSize,
                               "[INDEX BUFFER] Too small! Has \(indexBuffer.length) bytes, needs \(requiredSize)")

                        // Sample first few indices - use offset!
                        if primitive.indexType == MTLIndexType.uint16 {
                            let base = indexBuffer.contents().advanced(by: primitive.indexBufferOffset)
                            let ptr = base.bindMemory(to: UInt16.self, capacity: primitive.indexCount)
                            let samples = min(10, primitive.indexCount)
                            var maxIndex: UInt16 = 0
                            for i in 0..<samples {
                                maxIndex = max(maxIndex, ptr[i])
                            }
                            vrmLog("  - Sample indices (first \(samples)): \((0..<samples).map { ptr[$0] })")
                            vrmLog("  - Max index in sample: \(maxIndex) (vertex count: \(primitive.vertexCount))")

                            assert(Int(maxIndex) < primitive.vertexCount,
                                   "[INDEX BUFFER] Index \(maxIndex) >= vertex count \(primitive.vertexCount)!")
                        }
                    }

                    // Bind MToon material uniforms to fragment shader (CRITICAL - was missing!)
                    var materialUniforms = mtoonUniforms
                    encoder.setFragmentBytes(&materialUniforms, length: MemoryLayout<MToonMaterialUniforms>.stride, index: 8)

                    // CPU GUARDRAIL: Assert indexType + indexBufferOffset are correct and in-range
                    let indexBufferSize = indexBuffer.length
                    let indexTypeSize = primitive.indexType == MTLIndexType.uint16 ? 2 : 4
                    let requiredSize = primitive.indexBufferOffset + (primitive.indexCount * indexTypeSize)

                    precondition(primitive.indexBufferOffset < indexBufferSize,
                               "[INDEX GUARDRAIL] indexBufferOffset \(primitive.indexBufferOffset) >= buffer size \(indexBufferSize)")
                    precondition(requiredSize <= indexBufferSize,
                               "[INDEX GUARDRAIL] Required size \(requiredSize) > buffer size \(indexBufferSize) (offset=\(primitive.indexBufferOffset), count=\(primitive.indexCount), typeSize=\(indexTypeSize))")
                    precondition(primitive.indexCount > 0,
                               "[INDEX GUARDRAIL] indexCount must be > 0, got \(primitive.indexCount)")
                    precondition(primitive.indexBufferOffset % indexTypeSize == 0,
                               "[INDEX GUARDRAIL] indexBufferOffset \(primitive.indexBufferOffset) not aligned to \(indexTypeSize) bytes")

                    // 🎯 CRITICAL VALIDATION: Skin/palette compatibility check
                    if let skinIndex = item.node.skin, skinIndex < model.skins.count {
                        let skin = model.skins[skinIndex]
                        let paletteCount = skin.joints.count
                        let required = prim.requiredPaletteSize

                        // Condition 1: Required palette fits
                        if required > paletteCount {
                            preconditionFailure(
                                "[SKIN MISMATCH] Node '\(item.node.name ?? "?")' mesh '\(meshName)' prim \(meshPrimIndex):\n" +
                                "  Primitive needs ≥\(required) joints (maxJoint=\(required-1))\n" +
                                "  Bound skin \(skinIndex) '\(skin.name ?? "?")' has \(paletteCount) joints\n" +
                                "  → Palette too small! Check node.skin assignment in VRM file."
                            )
                        }

                        // Condition 2: Sample vertices to double-check
                        if let vertexBuffer = prim.vertexBuffer, prim.hasJoints {
                            let verts = vertexBuffer.contents().bindMemory(to: VRMVertex.self, capacity: min(10, prim.vertexCount))
                            var sampleMaxJoint: UInt32 = 0
                            let samplesToCheck = min(10, prim.vertexCount)

                            for i in 0..<samplesToCheck {
                                let v = verts[i]
                                sampleMaxJoint = max(sampleMaxJoint, v.joints.x, v.joints.y, v.joints.z, v.joints.w)
                            }

                            if Int(sampleMaxJoint) >= paletteCount {
                                preconditionFailure(
                                    "[SKIN MISMATCH] Node '\(item.node.name ?? "?")' mesh '\(meshName)' prim \(meshPrimIndex):\n" +
                                    "  Sample vertices: maxJoint=\(sampleMaxJoint) >= paletteCount=\(paletteCount)\n" +
                                    "  → Joint indices out of range for bound skin \(skinIndex)!"
                                )
                            }

                            // Log success for first few frames
                            if frameCounter < 2 {
                                vrmLog("[SKIN OK] draw=\(drawIndex) node='\(item.node.name ?? "?")' mesh='\(meshName)' skin=\(skinIndex): required=\(required), palette=\(paletteCount), sample_max=\(sampleMaxJoint) ✅")
                            }
                        }
                    }

                    // Edge case: node.skin == nil but primitive has JOINTS_0
                    if item.node.skin == nil && prim.hasJoints {
                        if frameCounter < 2 {
                            vrmLog("[SKIN WARNING] Mesh '\(meshName)' prim \(meshPrimIndex) has JOINTS_0 but node.skin=nil (treating as rigid)")
                        }
                    }

                    // 🎯 FACE DEBUG: Dump vertex/index data for face meshes
                    if item.materialName.lowercased().contains("face") && frameCounter < 2 {
                        vrmLog("\n[FACE DATA DUMP] Material: '\(item.materialName)'")
                        vrmLog("[FACE DATA DUMP] Primitive: vertices=\(primitive.vertexCount), indices=\(primitive.indexCount), indexType=\(primitive.indexType)")

                        let vertexPointer = vertexBuffer.contents().bindMemory(to: VRMVertex.self, capacity: primitive.vertexCount)

                        // Handle both uint16 and uint32 index types
                        // Use offset even though it should be 0 for safety
                        if primitive.indexType == MTLIndexType.uint16 {
                            let base = indexBuffer.contents().advanced(by: primitive.indexBufferOffset)
                            let indexPointer = base.bindMemory(to: UInt16.self, capacity: primitive.indexCount)
                            for i in 0..<min(5, primitive.indexCount) {
                                let index = indexPointer[i]
                                if Int(index) < primitive.vertexCount {
                                    let vertex = vertexPointer[Int(index)]
                                    vrmLog("  - Index[\(i)]=\(index) -> Pos=\(vertex.position), UV=\(vertex.texCoord), Normal=\(vertex.normal)")
                                } else {
                                    vrmLog("  - Index[\(i)]=\(index) -> OUT OF BOUNDS (vertexCount=\(primitive.vertexCount))")
                                }
                            }
                        } else {
                            let base = indexBuffer.contents().advanced(by: primitive.indexBufferOffset)
                            let indexPointer = base.bindMemory(to: UInt32.self, capacity: primitive.indexCount)
                            for i in 0..<min(5, primitive.indexCount) {
                                let index = indexPointer[i]
                                if Int(index) < primitive.vertexCount {
                                    let vertex = vertexPointer[Int(index)]
                                    vrmLog("  - Index[\(i)]=\(index) -> Pos=\(vertex.position), UV=\(vertex.texCoord), Normal=\(vertex.normal)")
                                } else {
                                    vrmLog("  - Index[\(i)]=\(index) -> OUT OF BOUNDS (vertexCount=\(primitive.vertexCount))")
                                }
                            }
                        }
                        vrmLog("[FACE DATA DUMP] Complete\n")
                    }

                    // 🎯 WEDGE TRIANGLE DEBUG: Comprehensive index buffer validation
                    let elemSize = primitive.indexType == .uint32 ? 4 : 2
                    let offset = primitive.indexBufferOffset
                    let length = indexBuffer.length
                    let count = primitive.indexCount

                    // Critical validations
                    if offset != 0 {
                        vrmLog("[OFFSET WARNING] Non-zero offset! mesh='\(meshName)' offset=\(offset)")
                    }
                    if offset % elemSize != 0 {
                        vrmLog("[INDEX ERROR] Misaligned offset! offset=\(offset) elemSize=\(elemSize)")
                    }
                    if offset + count * elemSize > length {
                        vrmLog("[INDEX ERROR] Out of bounds! offset=\(offset) + count*elemSize=\(count*elemSize) > length=\(length)")
                    }

                    // Offset must be 0 for newly created buffers
                    precondition(primitive.indexBufferOffset == 0,
                               "[INDEX BUG] Primitive has its own buffer but a non-zero offset! Offset: \(primitive.indexBufferOffset)")

                    // Check primitive mode
                    if primitive.primitiveType == MTLPrimitiveType.triangleStrip {
                        vrmLog("[DRAW] ⚠️ Drawing TRIANGLE_STRIP with \(primitive.indexCount) indices - mesh='\(meshName)'")
                    }

                    // Sample first few indices to check for out-of-bounds - MUST use offset!
                    if primitive.indexType == .uint16 {
                        let base = indexBuffer.contents().advanced(by: primitive.indexBufferOffset)
                        let ptr = base.bindMemory(to: UInt16.self, capacity: primitive.indexCount)
                        let samplesToCheck = min(24, primitive.indexCount)
                        var maxIdx: UInt16 = 0
                        for i in 0..<samplesToCheck {
                            let idx = ptr[i]
                            maxIdx = max(maxIdx, idx)
                            if idx >= primitive.vertexCount {
                                vrmLog("[WEDGE FOUND] Out-of-bounds index! mesh='\(meshName)' index[\(i)]=\(idx) >= vertexCount=\(primitive.vertexCount)")
                            }
                        }
                        // Always log for suspicious meshes
                        if meshName.lowercased().contains("other") || meshName.lowercased().contains("hair") {
                            vrmLog("[INDEX SAMPLE] mesh='\(meshName)' material='\(materialName)' meshIndex=\(item.meshIndex) primitiveIndex=\(meshPrimIndex)")
                            vrmLog("  - First 12 indices: \((0..<min(12, primitive.indexCount)).map { ptr[$0] })")
                            vrmLog("  - Max index in sample: \(maxIdx), vertexCount: \(primitive.vertexCount)")
                            vrmLog("  - Index count: \(primitive.indexCount), triangles: \(primitive.indexCount/3)")

                            // 🔍 BUFFER IDENTITY CHECK: Verify each primitive has unique buffers
                            vrmLog("  - Index buffer GPU address: 0x\(String(indexBuffer.gpuAddress, radix: 16))")
                            vrmLog("  - Index buffer length: \(indexBuffer.length) bytes")
                            vrmLog("  - Index buffer offset: \(primitive.indexBufferOffset)")
                            if let vertexBuffer = primitive.vertexBuffer {
                                vrmLog("  - Vertex buffer GPU address: 0x\(String(vertexBuffer.gpuAddress, radix: 16))")
                                vrmLog("  - Vertex buffer length: \(vertexBuffer.length) bytes")
                            }
                        }
                    } else {
                        let base = indexBuffer.contents().advanced(by: primitive.indexBufferOffset)
                        let ptr = base.bindMemory(to: UInt32.self, capacity: primitive.indexCount)
                        let samplesToCheck = min(24, primitive.indexCount)
                        var maxIdx: UInt32 = 0
                        for i in 0..<samplesToCheck {
                            let idx = ptr[i]
                            maxIdx = max(maxIdx, idx)
                            if idx >= primitive.vertexCount {
                                vrmLog("[WEDGE FOUND] Out-of-bounds index! mesh='\(meshName)' index[\(i)]=\(idx) >= vertexCount=\(primitive.vertexCount)")
                            }
                        }
                        // Also log for suspicious meshes with UInt32 indices
                        if meshName.lowercased().contains("other") || meshName.lowercased().contains("hair") {
                            vrmLog("[INDEX SAMPLE] mesh='\(meshName)' material='\(materialName)' meshIndex=\(item.meshIndex) primitiveIndex=\(meshPrimIndex)")
                            vrmLog("  - First 12 indices: \((0..<min(12, primitive.indexCount)).map { ptr[$0] })")
                            vrmLog("  - Max index: \(maxIdx), vertexCount: \(primitive.vertexCount)")
                            vrmLog("  - Index count: \(primitive.indexCount), triangles: \(primitive.indexCount/3)")

                            // 🔍 BUFFER IDENTITY CHECK: Verify each primitive has unique buffers
                            vrmLog("  - Index buffer GPU address: 0x\(String(indexBuffer.gpuAddress, radix: 16))")
                            vrmLog("  - Index buffer length: \(indexBuffer.length) bytes")
                            vrmLog("  - Index buffer offset: \(primitive.indexBufferOffset)")
                            if let vertexBuffer = primitive.vertexBuffer {
                                vrmLog("  - Vertex buffer GPU address: 0x\(String(vertexBuffer.gpuAddress, radix: 16))")
                                vrmLog("  - Vertex buffer length: \(vertexBuffer.length) bytes")
                            }
                        }
                    }

                    // 🛡️ PRECONDITION: Validate buffer identity for hair meshes (frame 0-2 only)
                    if meshName.lowercased().contains("hair") && frameCounter <= 2 {
                        precondition(indexBuffer.gpuAddress != 0,
                                   "[BUFFER GUARD] Invalid index buffer GPU address for \(meshName) prim \(meshPrimIndex)")
                        precondition(indexBuffer.length > 0,
                                   "[BUFFER GUARD] Zero-length index buffer for \(meshName) prim \(meshPrimIndex)")
                    }

                    encoder.drawIndexedPrimitives(
                        type: primitive.primitiveType,
                        indexCount: primitive.indexCount,
                        indexType: primitive.indexType,
                        indexBuffer: indexBuffer,
                        indexBufferOffset: primitive.indexBufferOffset
                    )
                totalPrimitivesDrawn += 1
                totalTriangles += primitive.indexCount / 3
                performanceTracker?.recordDrawCall(triangles: primitive.indexCount / 3, vertices: primitive.vertexCount)
            } else {
                // Validate draw call in strict mode
                if config.strict != .off {
                    do {
                        try strictValidator?.recordDrawCall(
                            vertexCount: primitive.vertexCount,
                            indexCount: 0,
                            primitiveIndex: item.meshIndex
                        )
                    } catch {
                        if config.strict == .fail {
                            encoder.endEncoding()
                            vrmLog("❌ [VRMRenderer] Draw validation failed: \(error)")
                        } else {
                            vrmLog("⚠️ [VRMRenderer] Draw validation warning: \(error)")
                        }
                        continue  // Skip this primitive
                    }
                }

                // Set MToon material uniforms
                // Note: Both vertex and fragment shaders expect MToonMaterial at buffer(8)
                encoder.setVertexBytes(&mtoonUniforms,
                                       length: MemoryLayout<MToonMaterialUniforms>.stride,
                                       index: 8)
                encoder.setFragmentBytes(&mtoonUniforms,
                                       length: MemoryLayout<MToonMaterialUniforms>.stride,
                                       index: 8)

                // Also pass main uniforms to fragment shader for lighting
                encoder.setFragmentBuffer(uniformsBuffer, offset: 0, index: 1)

                encoder.drawPrimitives(
                    type: primitive.primitiveType,
                    vertexStart: 0,
                    vertexCount: primitive.vertexCount
                )
                totalPrimitivesDrawn += 1
                totalTriangles += primitive.vertexCount / 3
                performanceTracker?.recordDrawCall(triangles: primitive.vertexCount / 3, vertices: primitive.vertexCount)
            }
        }

        // Log rendering statistics periodically
        frameCounter += 1

        // DEBUG: Log animation transforms every second
        if frameCounter % 60 == 0 {
            if let hipsNode = model.nodes.first(where: { $0.name?.lowercased().contains("hips") ?? false }) {
                let pos = hipsNode.worldMatrix.columns.3
                vrmLog("[ANIMATION DEBUG] Frame \(frameCounter) Hips pos: (\(pos.x), \(pos.y), \(pos.z))")
            }
            if let headNode = model.nodes.first(where: { $0.name?.lowercased().contains("head") ?? false }) {
                let pos = headNode.worldMatrix.columns.3
                vrmLog("[ANIMATION DEBUG] Frame \(frameCounter) Head pos: (\(pos.x), \(pos.y), \(pos.z))")
            }
        }
        if frameCounter == 1 || frameCounter % 60 == 0 {  // Log on first frame and every 60 frames
            vrmLog("[VRMRenderer] Frame \(frameCounter) rendering stats:")
            vrmLog("  - Nodes with meshes: \(totalMeshesWithNodes)")
            vrmLog("  - Primitives drawn: \(totalPrimitivesDrawn) (expected ~19 for AliciaSolid)")
            vrmLog("  - Total triangles: \(totalTriangles)")
            vrmLog("  - All body parts should be visible: hair, skin, outfit, accessories")
        }

        // Render outlines for MToon mode (inverted hull technique)
        renderMToonOutlines(
            encoder: encoder,
            renderItems: allItems,
            model: model
        )

        encoder.endEncoding()

        // End performance tracking
        performanceTracker?.endFrame()

        // End frame validation
        if config.strict != .off {
            do {
                try strictValidator?.endFrame()
            } catch {
                if config.strict == .fail {
                    vrmLog("❌ [VRMRenderer] Frame validation failed: \(error)")
                } else {
                    vrmLog("⚠️ [VRMRenderer] Frame validation warning: \(error)")
                }
            }
        }

        // Add command buffer completion handler for error checking and semaphore signaling
        commandBuffer.addCompletedHandler { [weak self] buffer in
            // Signal that this frame's uniform buffer is available again
            self?.inflightSemaphore.signal()

            // Record GPU timing if performance tracking is enabled
            if let tracker = self?.performanceTracker {
                let gpuTime = buffer.gpuEndTime - buffer.gpuStartTime
                tracker.recordGPUTime(gpuTime)
            }

            if self?.config.checkCommandBufferErrors == true {
                if buffer.status == .error {
                    let error = buffer.error
                    if self?.config.strict == .fail {
                        vrmLog("❌ [VRMRenderer] Command buffer failed: \(error?.localizedDescription ?? "unknown error")")
                    } else if self?.config.strict == .warn {
                        vrmLog("⚠️ [StrictMode] Command buffer error: \(error?.localizedDescription ?? "unknown")")
                    }
                }
            }
        }
    }

    // MARK: - MToon Outline Rendering

    private func renderMToonOutlines(
        encoder: MTLRenderCommandEncoder,
        renderItems: [RenderItem],
        model: VRMModel
    ) {
        // Only render outlines if we have a pipeline and global outline width is non-zero
        guard mtoonOutlinePipelineState != nil || mtoonSkinnedOutlinePipelineState != nil else {
            return
        }

        // Global outline width of 0 disables all outlines
        guard self.outlineWidth > 0 else {
            return
        }

        let hasSkinning = !model.skins.isEmpty

        // Cull front faces for inverted hull technique
        encoder.setCullMode(.front)
        encoder.setFrontFacing(.counterClockwise)

        // Set depth state for outlines (test depth but don't write)
        // Prevents outlines from incorrectly writing to depth buffer
        if let outlineDepthState = depthStencilStates["blend"] {
            encoder.setDepthStencilState(outlineDepthState)
        }

        // Minimal depth bias for outlines - the real fix is proper vertex skinning
        encoder.setDepthBias(0.0, slopeScale: 0.0, clamp: 0.0)

        var outlinesRendered = 0

        for item in renderItems {
            let primitive = item.primitive

            // Check if material has outline enabled
            guard let materialIndex = primitive.materialIndex,
                  materialIndex < model.materials.count else {
                continue
            }

            let material = model.materials[materialIndex]

            // Skip if no MToon data or outline disabled
            guard let mtoon = material.mtoon,
                  mtoon.outlineWidthMode != .none,
                  mtoon.outlineWidthFactor > 0.0001 else {
                continue
            }

            guard let vertexBuffer = primitive.vertexBuffer,
                  let indexBuffer = primitive.indexBuffer else {
                continue
            }

            // Determine if this mesh needs skinning
            let nodeHasSkin = item.node.skin != nil && hasSkinning
            let meshUsesSkinning = primitive.hasJoints && primitive.hasWeights
            let isSkinned = (nodeHasSkin || meshUsesSkinning) && hasSkinning

            // Select appropriate outline pipeline
            let outlinePipeline: MTLRenderPipelineState?
            if isSkinned {
                outlinePipeline = mtoonSkinnedOutlinePipelineState
            } else {
                outlinePipeline = mtoonOutlinePipelineState
            }

            guard let pipeline = outlinePipeline else {
                continue
            }

            encoder.setRenderPipelineState(pipeline)

            // Set vertex buffer
            encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)

            // Set uniforms
            encoder.setVertexBuffer(uniformsBuffers[currentUniformBufferIndex], offset: 0, index: 1)

            // Set MToon material uniforms
            var mtoonUniforms = MToonMaterialUniforms(from: mtoon)
            mtoonUniforms.baseColorFactor = material.baseColorFactor
            // Set VRM version for version-aware shading (0 = VRM 0.0, 1 = VRM 1.0)
            mtoonUniforms.vrmVersion = material.vrmVersion == .v0_0 ? 0 : 1

            // Apply global outline width as a multiplier on per-material width
            mtoonUniforms.outlineWidthFactor *= self.outlineWidth / 0.02

            // Apply global outline color override (non-black means user set it)
            let globalColor = self.outlineColor
            if globalColor.x > 0 || globalColor.y > 0 || globalColor.z > 0 {
                mtoonUniforms.outlineColorFactor = globalColor
            }

            // Apply expression-driven material color overrides for outlines
            if let outlineOverride = expressionController?.getMaterialColorOverride(materialIndex: materialIndex, type: .outlineColor) {
                mtoonUniforms.outlineColorFactor = SIMD3<Float>(outlineOverride.x, outlineOverride.y, outlineOverride.z)
            }

            // Note: Both vertex and fragment shaders expect MToonMaterial at buffer(8)
            encoder.setVertexBytes(&mtoonUniforms, length: MemoryLayout<MToonMaterialUniforms>.stride, index: 8)
            encoder.setFragmentBytes(&mtoonUniforms, length: MemoryLayout<MToonMaterialUniforms>.stride, index: 8)

            // Set joint matrices for skinned meshes
            if isSkinned, let skinIndex = item.node.skin, skinIndex < model.skins.count {
                let skin = model.skins[skinIndex]
                if let jointBuffer = skinningSystem?.getJointMatricesBuffer() {
                    let byteOffset = skin.matrixOffset * MemoryLayout<float4x4>.stride
                    encoder.setVertexBuffer(jointBuffer, offset: byteOffset, index: ResourceIndices.jointMatricesBuffer)
                }
            }

            // Draw the outline
            encoder.drawIndexedPrimitives(
                type: primitive.primitiveType,
                indexCount: primitive.indexCount,
                indexType: primitive.indexType,
                indexBuffer: indexBuffer,
                indexBufferOffset: 0
            )

            outlinesRendered += 1
        }

        // Restore default cull mode
        encoder.setCullMode(.back)

        // Reset depth bias for subsequent render passes
        encoder.setDepthBias(0.0, slopeScale: 0.0, clamp: 0.0)

        // Restore depth state for subsequent render passes
        if let opaqueState = depthStencilStates["opaque"] {
            encoder.setDepthStencilState(opaqueState)
        }
    }

    // MARK: - Skinning Input Validation

    private func validateSkinningInputs(primitive: VRMPrimitive, paletteCount: Int, meshName: String, materialName: String, skinIndex: Int) {
        // Log vertex descriptor info on first call
        if frameCounter < 2 {
            vrmLog("\n[VERTEX DESCRIPTOR] Mesh '\(meshName)':")
            vrmLog("  - Vertex count: \(primitive.vertexCount)")
            vrmLog("  - Index count: \(primitive.indexCount)")
            vrmLog("  - Index type: \(primitive.indexType)")
            vrmLog("  - Primitive type: \(primitive.primitiveType)")
            vrmLog("  - Has joints: \(primitive.hasJoints)")
            vrmLog("  - Has weights: \(primitive.hasWeights)")
            vrmLog("  - Vertex stride: \(MemoryLayout<VRMVertex>.stride) bytes")
            vrmLog("  - VRMVertex layout:")
            vrmLog("    • position: offset \(MemoryLayout.offset(of: \VRMVertex.position) ?? -1), size \(MemoryLayout<SIMD3<Float>>.size)")
            vrmLog("    • normal: offset \(MemoryLayout.offset(of: \VRMVertex.normal) ?? -1), size \(MemoryLayout<SIMD3<Float>>.size)")
            vrmLog("    • texCoord: offset \(MemoryLayout.offset(of: \VRMVertex.texCoord) ?? -1), size \(MemoryLayout<SIMD2<Float>>.size)")
            vrmLog("    • color: offset \(MemoryLayout.offset(of: \VRMVertex.color) ?? -1), size \(MemoryLayout<SIMD4<Float>>.size)")
            vrmLog("    • joints: offset \(MemoryLayout.offset(of: \VRMVertex.joints) ?? -1), size \(MemoryLayout<SIMD4<UInt16>>.size)")
            vrmLog("    • weights: offset \(MemoryLayout.offset(of: \VRMVertex.weights) ?? -1), size \(MemoryLayout<SIMD4<Float>>.size)")
        }

        // Sample first 8 vertices to validate joints/weights
        let sampleCount = min(8, primitive.vertexCount)

        // Get vertex data pointers
        guard let vertexBuffer = primitive.vertexBuffer else { return }

        let vertexPointer = vertexBuffer.contents().bindMemory(to: VRMVertex.self, capacity: primitive.vertexCount)

        for i in 0..<sampleCount {
            let vertex = vertexPointer[i]

            // Check joint indices are within palette bounds
            let joints = vertex.joints
            let maxJoint = Int(max(joints.x, joints.y, joints.z, joints.w))

            if maxJoint >= paletteCount {
                // Log but don't crash - Iron Dome should have caught this, but log as warning
                vrmLog("⚠️ [JOINTS BOUNDS] Mesh '\(meshName)' material '\(materialName)' skin \(skinIndex):")
                vrmLog("   Vertex \(i) has joint index \(maxJoint) >= palette count \(paletteCount)")
                vrmLog("   Joints: [\(joints.x), \(joints.y), \(joints.z), \(joints.w)]")
                vrmLog("   → Iron Dome should have sanitized this. Check sanitizeAllMeshJoints() was called.")
                // Don't crash - just log the issue
            }

            // Check weights sum to ~1.0
            let weights = vertex.weights
            let weightSum = weights.x + weights.y + weights.z + weights.w

            if weightSum < 0.99 || weightSum > 1.01 {
                // Log but don't crash - weight normalization issues are common
                if frameCounter < 2 {
                    vrmLog("⚠️ [WEIGHTS SUM] Mesh '\(meshName)' material '\(materialName)' skin \(skinIndex):")
                    vrmLog("   Vertex \(i) weights sum to \(weightSum) (expected ~1.0)")
                    vrmLog("   Weights: [\(weights.x), \(weights.y), \(weights.z), \(weights.w)]")
                }
                // Don't crash - GPU shaders can handle unnormalized weights
            }
        }

        // Log validation success on first frame
        if frameCounter < 2 {
            vrmLog("✅ [SKINNING VALIDATION] Mesh '\(meshName)' skin \(skinIndex): \(sampleCount) vertices valid")
        }
    }

    // MARK: - MSAA Alpha-to-Coverage Support
    
    /// Current drawable size for MSAA texture management
    private var currentDrawableSize: CGSize = .zero
    
    /// Updates drawable size and creates/updates multisample textures if needed
    /// Returns true if multisample texture was created/updated
    @discardableResult
    public func updateDrawableSize(_ size: CGSize) -> Bool {
        // Only recreate if size changed and MSAA is enabled
        guard size != currentDrawableSize || multisampleTexture == nil else {
            return multisampleTexture != nil
        }
        
        currentDrawableSize = size
        
        // Clean up existing texture
        multisampleTexture = nil
        
        // Create multisample texture if MSAA enabled
        guard usesMultisampling else {
            return false
        }
        
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type2DMultisample
        descriptor.width = Int(size.width)
        descriptor.height = Int(size.height)
        descriptor.pixelFormat = config.colorPixelFormat
        descriptor.sampleCount = config.sampleCount
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        
        // Debug logging
        vrmLog("[MSAA] Creating texture: \(Int(size.width))x\(Int(size.height)), samples: \(config.sampleCount), format: \(config.colorPixelFormat)")
        
        multisampleTexture = device.makeTexture(descriptor: descriptor)
        multisampleTexture?.label = "MSAA Color Texture (\(config.sampleCount)x)"
        
        if multisampleTexture != nil {
            vrmLog("[MSAA] ✅ Created multisample texture: \(Int(size.width))x\(Int(size.height)) @ \(config.sampleCount)x")
        } else {
            vrmLog("❌ [MSAA] Failed to create multisample texture - descriptor may be invalid")
            vrmLog("   Width: \(descriptor.width), Height: \(descriptor.height)")
            vrmLog("   SampleCount: \(descriptor.sampleCount), PixelFormat: \(descriptor.pixelFormat)")
        }
        
        return multisampleTexture != nil
    }
    
    /// Returns render pass descriptor for multisample rendering
    /// This is used when MSAA is enabled to render to multisample texture
    public func getMultisampleRenderPassDescriptor() -> MTLRenderPassDescriptor? {
        guard usesMultisampling, let multisampleTexture = multisampleTexture else {
            return nil
        }
        
        let descriptor = MTLRenderPassDescriptor()
        
        // Color attachment - multisample
        let colorAttachment = descriptor.colorAttachments[0]
        colorAttachment?.texture = multisampleTexture
        colorAttachment?.loadAction = .clear
        colorAttachment?.storeAction = .multisampleResolve
        colorAttachment?.clearColor = MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0)
        
        return descriptor
    }
    
    /// Returns render pass descriptor for resolve pass
    /// Used to blit multisample result to final drawable
    public func getResolveRenderPassDescriptor() -> MTLRenderPassDescriptor? {
        // For now, return a basic descriptor - actual resolve happens automatically
        // when using .multisampleResolve store action
        let descriptor = MTLRenderPassDescriptor()
        return descriptor
    }
    
    /// Returns pipeline descriptor for MASK materials with alpha-to-coverage
    public func getMASKPipelineDescriptor() -> MTLRenderPipelineDescriptor? {
        // Use the existing A2C pipeline if available
        guard let a2cPipeline = maskAlphaToCoveragePipelineState else {
            return nil
        }
        
        // Create a descriptor from the existing pipeline
        // This is a simplified version - in practice, you'd recreate from library
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.isAlphaToCoverageEnabled = true
        descriptor.colorAttachments[0].pixelFormat = config.colorPixelFormat
        
        return descriptor
    }
    
    // MARK: - CLI Rendering Support
    
    /// Sets the debug mode for rendering (used by CLI tool)
    public func setDebugMode(_ mode: Int) {
        currentDebugMode = mode
    }
    
    /// Current debug mode (0 = normal, 1-16 = various debug visualizations)
    private var currentDebugMode: Int = 0

}

