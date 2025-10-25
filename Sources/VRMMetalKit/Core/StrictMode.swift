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

/// Level of strictness for renderer validation
public enum StrictLevel: String, CaseIterable, Sendable {
    /// Default behavior - soft fallbacks, logs only
    case off
    /// No fallbacks - log errors and mark frame invalid
    case warn
    /// Fail fast - throw/abort on first violation
    case fail
}

/// Render filter for debugging specific primitives
public enum RenderFilter: Sendable {
    case mesh(String)
    case material(String)
    case primitive(Int)
}

/// Renderer configuration including strict mode settings
public struct RendererConfig {
    /// Strict mode level for validation
    public var strict: StrictLevel = .off

    /// Enable Metal validation layers (debug builds only)
    public var enableMetalValidation: Bool = true

    /// Enable command buffer error checking
    public var checkCommandBufferErrors: Bool = true

    /// Minimum draw calls per frame (0 = disabled)
    public var minDrawCallsPerFrame: Int = 0

    /// Maximum average luma for frame validation (1.0 = white)
    public var maxFrameLuma: Float = 0.95

    /// Filter to render only specific mesh/material/primitive (for debugging)
    public var renderFilter: RenderFilter? = nil

    /// Render only draw calls [0..N] from sorted draw list (for debugging)
    public var drawUntil: Int? = nil

    /// Render only draw call K from sorted draw list (for debugging)
    public var drawOnlyIndex: Int? = nil

    /// Use identity matrices for specified skin index (A/B test for palette corruption)
    public var testIdentityPalette: Int? = nil

    public init(strict: StrictLevel = .off, renderFilter: RenderFilter? = nil, drawUntil: Int? = nil, drawOnlyIndex: Int? = nil, testIdentityPalette: Int? = nil) {
        self.strict = strict
        self.renderFilter = renderFilter
        self.drawUntil = drawUntil
        self.drawOnlyIndex = drawOnlyIndex
        self.testIdentityPalette = testIdentityPalette
    }
}

// MARK: - Strict Mode Errors

/// Errors that can occur during strict mode validation
public enum StrictModeError: LocalizedError {
    // Pipeline errors
    case missingVertexFunction(name: String)
    case missingFragmentFunction(name: String)
    case missingComputeFunction(name: String)
    case pipelineCreationFailed(String)
    case depthStencilCreationFailed

    // Uniform errors
    case uniformLayoutMismatch(swift: Int, metal: Int, type: String)
    case uniformBufferTooSmall(required: Int, actual: Int)
    case uniformIndexConflict(index: Int, usage: String)

    // Resource errors
    case resourceIndexOutOfBounds(index: Int, max: Int)
    case bufferIndexConflict(index: Int, existing: String, new: String)
    case textureIndexConflict(index: Int)
    case samplerIndexConflict(index: Int)

    // Vertex format errors
    case invalidVertexFormat(attribute: String, expected: String, actual: String)
    case vertexBufferTooSmall(required: Int, actual: Int)
    case vertexStrideInvalid(expected: Int, actual: Int)
    case missingVertexAttribute(name: String)

    // Draw call errors
    case noDrawCalls(expected: Int)
    case zeroVertices(primitive: Int)
    case zeroIndices(primitive: Int)
    case invalidIndexRange(max: Int, vertexCount: Int)

    // Frame validation errors
    case frameAllWhite(luma: Float)
    case frameAllBlack
    case commandBufferFailed(error: Error?)
    case encoderCreationFailed(type: String)

    // Skinning errors
    case missingSkinningData
    case jointIndexOutOfBounds(joint: Int, max: Int)
    case invalidJointCount(expected: Int, actual: Int)

    // Morph target errors
    case morphIndexOutOfBounds(index: Int, max: Int)
    case morphBufferSizeMismatch(expected: Int, actual: Int)
    case morphWeightInvalid(index: Int, weight: Float)

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

/// Single source of truth for buffer/texture indices
public struct ResourceIndices {
    // Vertex shader buffer indices
    public static let vertexBuffer = 0
    public static let uniformsBuffer = 1
    public static let skinDataBuffer = 2      // Joint indices/weights
    public static let jointMatricesBuffer = 3
    public static let morphWeightsBuffer = 4
    public static let morphPositionDeltas = 5...12  // 8 slots
    public static let morphNormalDeltas = 13...20   // 8 slots
    // Runtime morphed positions from compute pass
    public static let morphedPositionsBuffer = 20
    // Per-draw vertex offset (uint32)
    public static let vertexOffsetBuffer = 21
    // Flag: 1 if morphedPositions is valid, 0 otherwise (uint32)
    public static let hasMorphedPositionsFlag = 22

    // Fragment shader buffer indices
    public static let materialUniforms = 0

    // Fragment shader texture indices
    public static let baseColorTexture = 0
    public static let shadeTexture = 1
    public static let normalTexture = 2
    public static let emissiveTexture = 3
    public static let matcapTexture = 4
    public static let rimMultiplyTexture = 5
    public static let outlineWidthMultiplyTexture = 6
    public static let uvAnimationMaskTexture = 7

    // Sampler indices
    public static let defaultSampler = 0
}

// MARK: - Strict Mode Validator

/// Validates renderer state according to strict mode settings
public class StrictValidator {
    private let config: RendererConfig
    private var drawCallCount = 0
    private var frameErrors: [StrictModeError] = []

    public init(config: RendererConfig) {
        self.config = config
    }

    // MARK: - Error Handling

    /// Handle an error according to the strict level
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

    /// Reset frame tracking
    public func beginFrame() {
        drawCallCount = 0
        frameErrors = []
    }

    /// Validate frame completion
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

    /// Validate shader function exists
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

    /// Validate pipeline state creation
    public func validatePipelineState(_ state: MTLRenderPipelineState?, name: String) throws {
        guard state != nil else {
            try handle(.pipelineCreationFailed(name))
            return
        }
    }

    // MARK: - Uniform Validation

    /// Validate uniform struct size matches between Swift and Metal
    public func validateUniformSize(swift: Int, metal: Int, type: String) throws {
        guard swift == metal else {
            try handle(.uniformLayoutMismatch(swift: swift, metal: metal, type: type))
            return
        }
    }

    /// Validate buffer size for uniforms
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

    /// Track a draw call
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

    /// Validate command buffer completed successfully
    public func validateCommandBuffer(_ buffer: MTLCommandBuffer) throws {
        guard config.checkCommandBufferErrors else { return }

        if buffer.status == .error {
            try handle(.commandBufferFailed(error: buffer.error))
        }
    }

    // MARK: - Vertex Format Validation

    /// Validate vertex attribute format
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

    /// Validate vertex buffer size
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

/// Size constants that must match Metal shader structs
public struct MetalSizeConstants {
    // Must match shader Uniforms struct
    public static let uniformsSize = 336  // sizeof(Uniforms) in Metal (4x 64-byte matrices + aligned fields)

    // Must match shader MToonMaterial struct
    public static let mtoonMaterialSize = 192  // sizeof(MToonMaterial) in Metal (12 blocks × 16 bytes)

    // Vertex struct sizes
    public static let vertexSize = 44  // sizeof(Vertex) in Metal
    public static let skinnedVertexSize = 60  // sizeof(SkinnedVertex) in Metal
}
