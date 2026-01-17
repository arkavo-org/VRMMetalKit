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

/// Validation strictness levels for renderer operations
public enum StrictLevel: Sendable {
    /// No validation - soft fallbacks, logs only (production default)
    case off
    /// Log errors and mark frame invalid, but continue rendering
    case warn
    /// Throw/abort on first violation (development mode)
    case fail
}

/// Renderer configuration with strict mode settings
public struct RendererConfig: Sendable {
    /// Validation strictness level
    public var strict: StrictLevel

    /// Optional: Only render specific mesh by name (for debugging)
    public var renderFilter: RenderFilter?

    /// Optional: Stop rendering after N draw calls (for debugging)
    public var drawUntil: Int?

    /// Optional: Only render draw call at index K (for debugging)
    public var drawOnlyIndex: Int?

    /// Optional: Test with identity joint matrices for skin N (for debugging)
    public var testIdentityPalette: Int?

    /// Enable wireframe rendering (for debugging)
    public var debugWireframe: Bool

    /// Disable skinning (for debugging)
    public var disableSkinning: Bool

    /// Disable morph targets (for debugging)
    public var disableMorphs: Bool

    public init(
        strict: StrictLevel = .off,
        renderFilter: RenderFilter? = nil,
        drawUntil: Int? = nil,
        drawOnlyIndex: Int? = nil,
        testIdentityPalette: Int? = nil,
        debugWireframe: Bool = false,
        disableSkinning: Bool = false,
        disableMorphs: Bool = false
    ) {
        self.strict = strict
        self.renderFilter = renderFilter
        self.drawUntil = drawUntil
        self.drawOnlyIndex = drawOnlyIndex
        self.testIdentityPalette = testIdentityPalette
        self.debugWireframe = debugWireframe
        self.disableSkinning = disableSkinning
        self.disableMorphs = disableMorphs
    }

    /// Default configuration for production
    public static let production = RendererConfig(strict: .off)

    /// Default configuration for development
    public static let development = RendererConfig(strict: .warn)

    /// Strict configuration for debugging
    public static let debug = RendererConfig(strict: .fail)
}

/// Filter for selective rendering
public enum RenderFilter: Sendable {
    /// Render only meshes matching this name
    case mesh(String)
    /// Render only primitives with this material name
    case material(String)
    /// Render only specific node index
    case node(Int)
}

// MARK: - Strict Mode Errors

/// Errors that can occur during strict mode validation
public enum StrictModeError: Error, LocalizedError {
    // Pipeline errors
    case shaderFunctionNotFound(name: String)
    case pipelineCreationFailed(reason: String)
    case depthStencilCreationFailed(reason: String)

    // Uniform errors
    case uniformSizeMismatch(expected: Int, actual: Int, structName: String)
    case bufferTooSmall(required: Int, actual: Int, bufferName: String)
    case bufferIndexConflict(index: Int, existingUsage: String, newUsage: String)

    // Resource errors
    case bufferIndexOutOfBounds(index: Int, maxIndex: Int)
    case textureSlotConflict(slot: Int, existingTexture: String, newTexture: String)
    case samplerSlotConflict(slot: Int)
    case invalidVertexFormat(attribute: String, expected: String, actual: String)

    // Draw call errors
    case zeroVertexCount(meshName: String, primitiveIndex: Int)
    case zeroIndexCount(meshName: String, primitiveIndex: Int)
    case indexOutOfBounds(index: Int, vertexCount: Int, meshName: String)
    case noDrawCalls

    // Frame errors
    case commandBufferFailed(reason: String)
    case frameContentInvalid(reason: String)

    public var errorDescription: String? {
        switch self {
        case .shaderFunctionNotFound(let name):
            return "Shader function '\(name)' not found in Metal library"
        case .pipelineCreationFailed(let reason):
            return "Failed to create render pipeline: \(reason)"
        case .depthStencilCreationFailed(let reason):
            return "Failed to create depth stencil state: \(reason)"
        case .uniformSizeMismatch(let expected, let actual, let structName):
            return "Uniform size mismatch for '\(structName)': expected \(expected) bytes, got \(actual)"
        case .bufferTooSmall(let required, let actual, let bufferName):
            return "Buffer '\(bufferName)' too small: requires \(required) bytes, has \(actual)"
        case .bufferIndexConflict(let index, let existingUsage, let newUsage):
            return "Buffer index \(index) conflict: already used for '\(existingUsage)', attempting to use for '\(newUsage)'"
        case .bufferIndexOutOfBounds(let index, let maxIndex):
            return "Buffer index \(index) out of bounds (max: \(maxIndex))"
        case .textureSlotConflict(let slot, let existingTexture, let newTexture):
            return "Texture slot \(slot) conflict: '\(existingTexture)' vs '\(newTexture)'"
        case .samplerSlotConflict(let slot):
            return "Sampler slot \(slot) already in use"
        case .invalidVertexFormat(let attribute, let expected, let actual):
            return "Invalid vertex format for '\(attribute)': expected \(expected), got \(actual)"
        case .zeroVertexCount(let meshName, let primitiveIndex):
            return "Zero vertex count for mesh '\(meshName)' primitive \(primitiveIndex)"
        case .zeroIndexCount(let meshName, let primitiveIndex):
            return "Zero index count for mesh '\(meshName)' primitive \(primitiveIndex)"
        case .indexOutOfBounds(let index, let vertexCount, let meshName):
            return "Index \(index) out of bounds (vertex count: \(vertexCount)) in mesh '\(meshName)'"
        case .noDrawCalls:
            return "Frame completed with no draw calls"
        case .commandBufferFailed(let reason):
            return "Command buffer failed: \(reason)"
        case .frameContentInvalid(let reason):
            return "Frame content invalid: \(reason)"
        }
    }
}

// MARK: - Resource Index Contract

/// Defines the contract for buffer and texture indices used by VRMMetalKit.
/// This prevents conflicts between different systems (rendering, morphs, physics).
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

    // MARK: - SpringBone Compute Shader Buffer Indices
    // These indices are used by the SpringBone GPU compute kernels
    // and are separate from the vertex/fragment shader indices above.

    /// SpringBone: Previous frame bone positions (read/write)
    public static let springBonePosPrev = 0
    /// SpringBone: Current frame bone positions (read/write)
    public static let springBonePosCurr = 1
    /// SpringBone: Per-bone parameters (stiffness, drag, etc.)
    public static let springBoneParams = 2
    /// SpringBone: Global simulation parameters (gravity, wind, etc.)
    public static let springBoneGlobalParams = 3
    /// SpringBone: Rest length constraints between bones
    public static let springBoneRestLengths = 4
    /// SpringBone: Sphere colliders array
    public static let springBoneSphereColliders = 5
    /// SpringBone: Capsule colliders array
    public static let springBoneCapsuleColliders = 6
    /// SpringBone: Plane colliders array
    public static let springBonePlaneColliders = 7
    /// SpringBone: Animated root positions (kinematic kernel)
    public static let springBoneAnimatedRootPositions = 8
    /// SpringBone: Root bone indices (kinematic kernel)
    public static let springBoneRootIndices = 9
    /// SpringBone: Number of root bones (kinematic kernel)
    public static let springBoneNumRootBones = 10
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
            // Log and record
            vrmLog("⚠️ [StrictMode] \(error.localizedDescription)")
            frameErrors.append(error)
        case .fail:
            // Throw immediately
            vrmLog("❌ [StrictMode] \(error.localizedDescription)")
            throw error
        }
    }

    // MARK: - Draw Call Tracking

    /// Called before each draw call
    public func willDraw() -> Bool {
        drawCallCount += 1

        // Check drawUntil limit
        if let limit = config.drawUntil, drawCallCount > limit {
            return false
        }

        // Check drawOnlyIndex
        if let onlyIndex = config.drawOnlyIndex, drawCallCount != onlyIndex {
            return false
        }

        return true
    }

    /// Reset for new frame
    public func beginFrame() {
        drawCallCount = 0
        frameErrors.removeAll()
    }

    /// Validate frame completion
    public func endFrame() throws {
        if config.strict != .off && drawCallCount == 0 {
            try handle(.noDrawCalls)
        }
    }

    /// Get errors from current frame
    public var errors: [StrictModeError] {
        return frameErrors
    }

    /// Check if frame had any errors
    public var hasErrors: Bool {
        return !frameErrors.isEmpty
    }
}

// MARK: - Validation Helpers

extension StrictValidator {
    /// Validate buffer size
    public func validateBufferSize(buffer: MTLBuffer?, required: Int, name: String) throws {
        guard let buffer = buffer else { return }
        if buffer.length < required {
            try handle(.bufferTooSmall(required: required, actual: buffer.length, bufferName: name))
        }
    }

    /// Validate uniform struct size matches Metal expectations
    public func validateUniformSize<T>(type: T.Type, expected: Int, name: String) throws {
        let actual = MemoryLayout<T>.stride
        if actual != expected {
            try handle(.uniformSizeMismatch(expected: expected, actual: actual, structName: name))
        }
    }

    /// Validate vertex count is non-zero
    public func validateVertexCount(_ count: Int, meshName: String, primitiveIndex: Int) throws {
        if count == 0 {
            try handle(.zeroVertexCount(meshName: meshName, primitiveIndex: primitiveIndex))
        }
    }

    /// Validate index count is non-zero
    public func validateIndexCount(_ count: Int, meshName: String, primitiveIndex: Int) throws {
        if count == 0 {
            try handle(.zeroIndexCount(meshName: meshName, primitiveIndex: primitiveIndex))
        }
    }
}