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
import Metal

// MARK: - Strict Mode Configuration

/// Renderer validation severity. Configured via ``RendererConfig/strict`` and reported through ``StrictModeError``.
///
/// - ``off`` is the production default: validators silently fall back and only log.
/// - ``warn`` keeps frames rendering but flags every violation and surfaces a
///   per-frame summary. Use in CI smoke tests and integration runs.
/// - ``fail`` aborts the encoder on the first violation. Use in unit tests
///   and during local debugging to catch regressions immediately.
public enum StrictLevel: String, CaseIterable, Sendable {
    /// Validation is disabled; the renderer logs violations but continues with soft fallbacks.
    case off
    /// Validation logs violations and tags the frame as invalid, without throwing.
    case warn
    /// Validation throws ``StrictModeError`` on the first violation, aborting the frame.
    case fail
}

/// Single-primitive selector used during renderer debugging to isolate a draw call.
///
/// Set on ``RendererConfig/renderFilter`` to instruct ``VRMRenderer`` to skip
/// every draw call except the one matching this filter.
public enum RenderFilter: Sendable {
    /// Render only primitives belonging to the named mesh.
    case mesh(String)
    /// Render only primitives using the named material.
    case material(String)
    /// Render only the primitive at the given sorted-draw-list index.
    case primitive(Int)
}

/// Configuration for ``VRMRenderer`` covering pixel format, validation level, MSAA, depth bias, and debug filters.
public struct RendererConfig {
    /// Strict-mode validation level applied to every draw call.
    public var strict: StrictLevel = .off

    /// Color-attachment pixel format. Defaults to `MTKView`'s standard `.bgra8Unorm`.
    public var colorPixelFormat: MTLPixelFormat = .bgra8Unorm

    /// Enables Metal API validation in debug builds.
    public var enableMetalValidation: Bool = true

    /// Enables command-buffer error checking at frame end.
    public var checkCommandBufferErrors: Bool = true

    /// Minimum number of draw calls expected per frame; `0` disables the check.
    public var minDrawCallsPerFrame: Int = 0

    /// Maximum average luma allowed by ``StrictModeError/frameAllWhite(luma:)`` validation (1.0 = pure white).
    public var maxFrameLuma: Float = 0.95

    /// Optional debug filter that restricts rendering to a single mesh, material, or primitive.
    public var renderFilter: RenderFilter? = nil

    /// Debug: render only draw calls `0...N` from the sorted draw list.
    public var drawUntil: Int? = nil

    /// Debug: render only the single draw call `K` from the sorted draw list.
    public var drawOnlyIndex: Int? = nil

    /// Debug: replace the palette of skin index `i` with identity matrices (A/B testing for palette corruption).
    public var testIdentityPalette: Int? = nil

    /// MSAA sample count (`1` = disabled, `4` = 4x MSAA). Alpha-to-coverage for `MASK` materials requires `> 1`.
    public var sampleCount: Int = 1

    /// Global multiplier for per-material depth bias. Increase to push coplanar surfaces further apart.
    public var depthBiasScale: Float = 1.0

    /// Creates a renderer configuration. Defaults match the production baseline.
    public init(strict: StrictLevel = .off, colorPixelFormat: MTLPixelFormat = .bgra8Unorm, renderFilter: RenderFilter? = nil, drawUntil: Int? = nil, drawOnlyIndex: Int? = nil, testIdentityPalette: Int? = nil, sampleCount: Int = 1, depthBiasScale: Float = 1.0) {
        self.strict = strict
        self.colorPixelFormat = colorPixelFormat
        self.renderFilter = renderFilter
        self.drawUntil = drawUntil
        self.drawOnlyIndex = drawOnlyIndex
        self.testIdentityPalette = testIdentityPalette
        self.sampleCount = sampleCount
        self.depthBiasScale = depthBiasScale
    }
}

// MARK: - Strict Mode Errors

/// Validation failures detected by ``StrictValidator``.
///
/// Cases are grouped by validation surface: pipeline creation, uniform/buffer
/// binding, vertex layout, draw-call shape, frame-level sanity checks, and
/// skinning/morph index ranges. Each case provides enough context for a
/// log-level read (which buffer, which index) without dumping full stack
/// state.
public enum StrictModeError: LocalizedError {
    /// A vertex function with the given name is missing from the shader library.
    case missingVertexFunction(name: String)
    /// A fragment function with the given name is missing from the shader library.
    case missingFragmentFunction(name: String)
    /// A compute function with the given name is missing from the shader library.
    case missingComputeFunction(name: String)
    /// Pipeline-state creation failed for the named pipeline.
    case pipelineCreationFailed(String)
    /// Depth-stencil state creation failed.
    case depthStencilCreationFailed

    /// A uniform struct size differs between Swift and Metal declarations.
    case uniformLayoutMismatch(swift: Int, metal: Int, type: String)
    /// A uniform buffer is smaller than the encoder expects.
    case uniformBufferTooSmall(required: Int, actual: Int)
    /// Two distinct uniforms try to bind to the same buffer index.
    case uniformIndexConflict(index: Int, usage: String)

    /// A resource index falls outside the valid range for its argument table.
    case resourceIndexOutOfBounds(index: Int, max: Int)
    /// A buffer index conflict: an existing binding collides with a new one.
    case bufferIndexConflict(index: Int, existing: String, new: String)
    /// A texture index is already bound and cannot be reused.
    case textureIndexConflict(index: Int)
    /// A sampler index is already bound and cannot be reused.
    case samplerIndexConflict(index: Int)

    /// A vertex attribute has an unexpected Metal format.
    case invalidVertexFormat(attribute: String, expected: String, actual: String)
    /// A vertex buffer is smaller than `vertexCount * stride`.
    case vertexBufferTooSmall(required: Int, actual: Int)
    /// A vertex stride differs from the expected value.
    case vertexStrideInvalid(expected: Int, actual: Int)
    /// A required vertex attribute (e.g. `POSITION`, `NORMAL`) is missing.
    case missingVertexAttribute(name: String)

    /// The frame contained fewer draw calls than ``RendererConfig/minDrawCallsPerFrame`` requires.
    case noDrawCalls(expected: Int)
    /// A primitive's vertex count is zero.
    case zeroVertices(primitive: Int)
    /// A primitive's index count is zero.
    case zeroIndices(primitive: Int)
    /// An index value exceeds the vertex count.
    case invalidIndexRange(max: Int, vertexCount: Int)

    /// The captured frame is uniformly white above the configured luma threshold.
    case frameAllWhite(luma: Float)
    /// The captured frame is uniformly black.
    case frameAllBlack
    /// The command buffer ended in the `.error` state.
    case commandBufferFailed(error: Error?)
    /// Creating a command encoder of the named type failed.
    case encoderCreationFailed(type: String)

    /// A primitive declares skinning but lacks the required `JOINTS_0`/`WEIGHTS_0` data.
    case missingSkinningData
    /// A joint index references a joint outside the skin's joint array.
    case jointIndexOutOfBounds(joint: Int, max: Int)
    /// A skin's joint count differs from the expected value.
    case invalidJointCount(expected: Int, actual: Int)

    /// A morph target index references a target outside the mesh's morph array.
    case morphIndexOutOfBounds(index: Int, max: Int)
    /// A morph buffer's byte length differs from the expected value.
    case morphBufferSizeMismatch(expected: Int, actual: Int)
    /// A morph weight is `NaN`, infinite, or outside `0...1`.
    case morphWeightInvalid(index: Int, weight: Float)

    /// Human-readable description with subsystem prefix and concrete numeric context.
    public var errorDescription: String? {
        switch self {
        case .missingVertexFunction(let name):
            return "❌ [StrictMode] Missing vertex function '\(name)' in shader library"
        case .missingFragmentFunction(let name):
            return "❌ [StrictMode] Missing fragment function '\(name)' in shader library"
        case .missingComputeFunction(let name):
            return "❌ [StrictMode] Missing compute function '\(name)' in shader library"
        case .pipelineCreationFailed(let reason):
            return "❌ [StrictMode] Pipeline state creation failed: \(reason)"
        case .depthStencilCreationFailed:
            return "❌ [StrictMode] Depth stencil state creation failed"

        case .uniformLayoutMismatch(let swift, let metal, let type):
            return "❌ [StrictMode] Uniform struct size mismatch for \(type): Swift=\(swift) bytes, Metal=\(metal) bytes"
        case .uniformBufferTooSmall(let required, let actual):
            return "❌ [StrictMode] Uniform buffer too small: required=\(required), actual=\(actual)"
        case .uniformIndexConflict(let index, let usage):
            return "❌ [StrictMode] Buffer index \(index) conflict: already used for \(usage)"

        case .resourceIndexOutOfBounds(let index, let max):
            return "❌ [StrictMode] Resource index \(index) out of bounds (max: \(max))"
        case .bufferIndexConflict(let index, let existing, let new):
            return "❌ [StrictMode] Buffer index \(index) conflict: existing=\(existing), new=\(new)"
        case .textureIndexConflict(let index):
            return "❌ [StrictMode] Texture index \(index) already in use"
        case .samplerIndexConflict(let index):
            return "❌ [StrictMode] Sampler index \(index) already in use"

        case .invalidVertexFormat(let attribute, let expected, let actual):
            return "❌ [StrictMode] Invalid vertex format for \(attribute): expected=\(expected), actual=\(actual)"
        case .vertexBufferTooSmall(let required, let actual):
            return "❌ [StrictMode] Vertex buffer too small: required=\(required), actual=\(actual)"
        case .vertexStrideInvalid(let expected, let actual):
            return "❌ [StrictMode] Invalid vertex stride: expected=\(expected), actual=\(actual)"
        case .missingVertexAttribute(let name):
            return "❌ [StrictMode] Missing required vertex attribute: \(name)"

        case .noDrawCalls(let expected):
            return "❌ [StrictMode] No draw calls in frame (expected >= \(expected))"
        case .zeroVertices(let primitive):
            return "❌ [StrictMode] Primitive \(primitive) has zero vertices"
        case .zeroIndices(let primitive):
            return "❌ [StrictMode] Primitive \(primitive) has zero indices"
        case .invalidIndexRange(let max, let vertexCount):
            return "❌ [StrictMode] Index \(max) exceeds vertex count \(vertexCount)"

        case .frameAllWhite(let luma):
            return "❌ [StrictMode] Frame is all white (luma=\(luma))"
        case .frameAllBlack:
            return "❌ [StrictMode] Frame is all black"
        case .commandBufferFailed(let error):
            return "❌ [StrictMode] Command buffer failed: \(error?.localizedDescription ?? "unknown")"
        case .encoderCreationFailed(let type):
            return "❌ [StrictMode] Failed to create \(type) encoder"

        case .missingSkinningData:
            return "❌ [StrictMode] Missing skinning data for skinned mesh"
        case .jointIndexOutOfBounds(let joint, let max):
            return "❌ [StrictMode] Joint index \(joint) out of bounds (max: \(max))"
        case .invalidJointCount(let expected, let actual):
            return "❌ [StrictMode] Invalid joint count: expected=\(expected), actual=\(actual)"

        case .morphIndexOutOfBounds(let index, let max):
            return "❌ [StrictMode] Morph target index \(index) out of bounds (max: \(max))"
        case .morphBufferSizeMismatch(let expected, let actual):
            return "❌ [StrictMode] Morph buffer size mismatch: expected=\(expected), actual=\(actual)"
        case .morphWeightInvalid(let index, let weight):
            return "❌ [StrictMode] Invalid morph weight at index \(index): \(weight)"
        }
    }
}

// MARK: - Resource Index Contract

/// Canonical buffer, texture, and sampler indices shared by Swift and Metal code.
///
/// These constants are the single source of truth for argument-table layout.
/// Vertex/fragment indices, spring-bone compute kernel indices, and texture
/// slots are namespaced by comment groups below. Changes here must be
/// mirrored in the corresponding `.metal` shaders.
public struct ResourceIndices {
    /// Vertex shader: vertex buffer (positions, normals, UVs, joints, weights).
    public static let vertexBuffer = 0
    /// Vertex shader: per-frame uniform buffer.
    public static let uniformsBuffer = 1
    /// Vertex shader: legacy skin-data buffer; retained for backward compatibility, currently unused.
    public static let skinDataBuffer = 2
    /// Vertex shader: morph-target weights buffer.
    public static let morphWeightsBuffer = 4
    /// Vertex shader: morph-position delta buffers (8 slots).
    public static let morphPositionDeltas = 5...12
    /// Vertex shader: morph-normal delta buffers (7 slots; avoids collision with `morphedPositionsBuffer`).
    public static let morphNormalDeltas = 13...19
    /// Vertex shader: morphed-position output from the compute pass.
    public static let morphedPositionsBuffer = 20
    /// Vertex shader: per-draw vertex offset (`uint32`).
    public static let vertexOffsetBuffer = 21
    /// Vertex shader: flag indicating whether `morphedPositionsBuffer` holds valid data.
    public static let hasMorphedPositionsFlag = 22
    /// Vertex shader: joint matrices for skinning, placed high to avoid argument-table collisions.
    public static let jointMatricesBuffer = 25
    /// Vertex shader: per-vertex first-person visibility flags (`uint8`, 0 = visible, 1 = hidden).
    public static let firstPersonHiddenFlagsBuffer = 26

    /// Fragment shader: material uniform buffer.
    public static let materialUniforms = 0

    /// Fragment shader: base color (albedo) texture.
    public static let baseColorTexture = 0
    /// Fragment shader: MToon shade texture.
    public static let shadeTexture = 1
    /// Fragment shader: tangent-space normal map.
    public static let normalTexture = 2
    /// Fragment shader: emissive texture.
    public static let emissiveTexture = 3
    /// Fragment shader: MToon matcap texture.
    public static let matcapTexture = 4
    /// Fragment shader: MToon rim multiply texture.
    public static let rimMultiplyTexture = 5
    /// Fragment shader: MToon outline-width mask (linear R8).
    public static let outlineWidthMultiplyTexture = 6
    /// Fragment shader: MToon UV-animation mask (linear R8).
    public static let uvAnimationMaskTexture = 7

    /// Fragment shader: default sampler slot.
    public static let defaultSampler = 0

    // MARK: - SpringBone Compute Shader Buffer Indices

    /// Spring-bone compute: previous-frame bone positions (read/write).
    public static let springBonePosPrev = 0
    /// Spring-bone compute: current-frame bone positions (read/write).
    public static let springBonePosCurr = 1
    /// Spring-bone compute: per-bone parameters (stiffness, drag, etc.).
    public static let springBoneParams = 2
    /// Spring-bone compute: global simulation parameters (gravity, wind, etc.).
    public static let springBoneGlobalParams = 3
    /// Spring-bone compute: rest-length constraints between bones.
    public static let springBoneRestLengths = 4
    /// Spring-bone compute: sphere colliders array.
    public static let springBoneSphereColliders = 5
    /// Spring-bone compute: capsule colliders array.
    public static let springBoneCapsuleColliders = 6
    /// Spring-bone compute: plane colliders array.
    public static let springBonePlaneColliders = 7
    /// Spring-bone compute: animated root positions (kinematic kernel).
    public static let springBoneAnimatedRootPositions = 8
    /// Spring-bone compute: root-bone indices (kinematic kernel).
    public static let springBoneRootIndices = 9
    /// Spring-bone compute: number of root bones (kinematic kernel).
    public static let springBoneNumRootBones = 10
}

// MARK: - Strict Mode Validator

/// Validates renderer state across a frame, dispatching ``StrictModeError`` according to ``RendererConfig/strict``.
public class StrictValidator {
    private let config: RendererConfig
    private var drawCallCount = 0
    private var frameErrors: [StrictModeError] = []

    /// Creates a validator bound to the supplied renderer configuration.
    public init(config: RendererConfig) {
        self.config = config
    }

    // MARK: - Error Handling

    /// Routes a validation failure through the configured ``StrictLevel`` (log, warn-and-collect, or throw).
    public func handle(_ error: StrictModeError) throws {
        switch config.strict {
        case .off:
            // Log only
            vrmLog(error.localizedDescription)
        case .warn:
            // Log and track
            vrmLog("⚠️ [StrictMode.warn] \(error.localizedDescription)")
            frameErrors.append(error)
        case .fail:
            // Fail immediately
            throw error
        }
    }

    /// Resets per-frame counters and the collected-error list. Call at the start of each frame.
    public func beginFrame() {
        drawCallCount = 0
        frameErrors = []
    }

    /// Performs end-of-frame validation (minimum draw-call count, summary logging in `.warn` mode).
    public func endFrame() throws {
        // Check minimum draw calls
        if config.minDrawCallsPerFrame > 0 && drawCallCount < config.minDrawCallsPerFrame {
            try handle(.noDrawCalls(expected: config.minDrawCallsPerFrame))
        }

        // In warn mode, report all collected errors
        if config.strict == .warn && !frameErrors.isEmpty {
            vrmLog("⚠️ [StrictMode] Frame completed with \(frameErrors.count) errors")
        }
    }

    // MARK: - Pipeline Validation

    /// Verifies that a shader function was loaded; raises ``StrictModeError/missingVertexFunction(name:)`` and friends otherwise.
    public func validateFunction(_ function: MTLFunction?, name: String, type: String) throws {
        guard function != nil else {
            switch type {
            case "vertex":
                try handle(.missingVertexFunction(name: name))
            case "fragment":
                try handle(.missingFragmentFunction(name: name))
            case "compute":
                try handle(.missingComputeFunction(name: name))
            default:
                try handle(.pipelineCreationFailed("Unknown function type: \(type)"))
            }
            return
        }
    }

    /// Verifies that a render pipeline state was created; raises ``StrictModeError/pipelineCreationFailed(_:)`` otherwise.
    public func validatePipelineState(_ state: MTLRenderPipelineState?, name: String) throws {
        guard state != nil else {
            try handle(.pipelineCreationFailed(name))
            return
        }
    }

    // MARK: - Uniform Validation

    /// Verifies that a Swift uniform struct matches its Metal counterpart in size.
    public func validateUniformSize(swift: Int, metal: Int, type: String) throws {
        guard swift == metal else {
            try handle(.uniformLayoutMismatch(swift: swift, metal: metal, type: type))
            return
        }
    }

    /// Verifies that a uniform buffer is non-nil and at least `requiredSize` bytes.
    public func validateUniformBuffer(_ buffer: MTLBuffer?, requiredSize: Int) throws {
        guard let buffer = buffer else {
            try handle(.uniformBufferTooSmall(required: requiredSize, actual: 0))
            return
        }

        guard buffer.length >= requiredSize else {
            try handle(.uniformBufferTooSmall(required: requiredSize, actual: buffer.length))
            return
        }
    }

    // MARK: - Draw Call Validation

    /// Records a draw call and raises validation errors for zero-vertex or zero-index primitives.
    public func recordDrawCall(vertexCount: Int, indexCount: Int, primitiveIndex: Int) throws {
        drawCallCount += 1

        if vertexCount == 0 {
            try handle(.zeroVertices(primitive: primitiveIndex))
        }

        if indexCount == 0 {
            try handle(.zeroIndices(primitive: primitiveIndex))
        }
    }

    // MARK: - Command Buffer Validation

    /// Checks that a completed command buffer is not in the `.error` state.
    public func validateCommandBuffer(_ buffer: MTLCommandBuffer) throws {
        guard config.checkCommandBufferErrors else { return }

        if buffer.status == .error {
            try handle(.commandBufferFailed(error: buffer.error))
        }
    }

    // MARK: - Vertex Format Validation

    /// Verifies a vertex attribute's Metal format matches the expected value.
    public func validateVertexFormat(attribute: String, expected: MTLVertexFormat, actual: MTLVertexFormat) throws {
        guard expected == actual else {
            try handle(.invalidVertexFormat(
                attribute: attribute,
                expected: String(describing: expected),
                actual: String(describing: actual)
            ))
            return
        }
    }

    /// Verifies that a vertex buffer is non-nil and at least `vertexCount * stride` bytes.
    public func validateVertexBuffer(_ buffer: MTLBuffer?, vertexCount: Int, stride: Int) throws {
        let requiredSize = vertexCount * stride

        guard let buffer = buffer else {
            try handle(.vertexBufferTooSmall(required: requiredSize, actual: 0))
            return
        }

        guard buffer.length >= requiredSize else {
            try handle(.vertexBufferTooSmall(required: requiredSize, actual: buffer.length))
            return
        }
    }
}

// MARK: - Metal Size Constants

/// Byte sizes of key Metal shader structs, used by ``StrictValidator`` to detect layout drift.
///
/// Any change to a corresponding Metal struct must be mirrored here or the
/// validator will raise ``StrictModeError/uniformLayoutMismatch(swift:metal:type:)``.
public struct MetalSizeConstants {
    /// Byte size of the Metal `Uniforms` struct (4× 64-byte matrices + 3 lights + normalization + aligned fields).
    public static let uniformsSize = 432

    /// Byte size of the Metal `MToonMaterial` struct (15 blocks × 16 bytes).
    public static let mtoonMaterialSize = 240

    /// Byte size of the Metal `Vertex` struct.
    public static let vertexSize = 44

    /// Byte size of the Metal `SkinnedVertex` struct.
    public static let skinnedVertexSize = 60
}
