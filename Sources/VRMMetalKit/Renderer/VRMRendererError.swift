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

// MARK: - Renderer Errors

/// Failures raised by ``VRMRenderer`` during draw-call validation, encoder creation, or buffer binding.
///
/// ## Discussion
/// These errors are produced by the renderer's own diagnostics (separate from the
/// stricter ``StrictModeError`` validator). Cases group into six surfaces:
///
/// - **Draw validation** (``drawValidationFailed(_:)``, ``invalidDrawCall(reason:)``,
///   ``zeroIndexCount(primitive:)``, ``zeroVertexCount(primitive:)``) — sanity checks before encoding.
/// - **Encoder creation** (``renderEncoderCreationFailed(_:)``, ``computeEncoderCreationFailed(_:)``) —
///   `MTLCommandBuffer` failed to vend an encoder.
/// - **Buffer integrity** (``invalidIndexBuffer(mesh:primitive:reason:)`` and friends) — index/vertex buffer
///   shape mismatches.
/// - **Skinning** (``skinMismatch(node:mesh:primitive:requiredJoints:availableJoints:)`` and friends) —
///   joint palette or weight inconsistencies.
/// - **Pipeline state** (``pipelineStateNil(alphaMode:skinned:)``, ``uniformsBufferEmpty``,
///   ``computePipelineStateNil``) — renderer not finished initialising.
/// - **Frame / material** — final-frame validation and material lookup errors.
///
/// Each case implements `LocalizedError` with a multi-line message containing what
/// went wrong, where, and a suggested fix. Use ``recoverySuggestion`` for a short caller-facing hint.
public enum VRMRendererError: LocalizedError {
    /// Draw-call validation rejected a primitive for the supplied reason.
    case drawValidationFailed(String)
    /// A draw call was rejected (free-form `reason`); thrown before encoding.
    case invalidDrawCall(reason: String)
    /// The named primitive declares zero indices and cannot be drawn.
    case zeroIndexCount(primitive: String)
    /// The named primitive declares zero vertices and cannot be drawn.
    case zeroVertexCount(primitive: String)

    /// Metal failed to vend an `MTLRenderCommandEncoder` from the supplied descriptor.
    case renderEncoderCreationFailed(Error)
    /// Metal failed to vend an `MTLComputeCommandEncoder`; `reason` carries the failing subsystem.
    case computeEncoderCreationFailed(String)

    /// The index buffer for `mesh`/`primitive` is nil or unusable; `reason` carries the specific defect.
    case invalidIndexBuffer(mesh: String, primitive: Int, reason: String)
    /// The vertex buffer for `mesh`/`primitive` is nil or unusable; `reason` carries the specific defect.
    case invalidVertexBuffer(mesh: String, primitive: Int, reason: String)
    /// The index buffer is shorter than `required` bytes.
    case indexBufferTooSmall(mesh: String, primitive: Int, required: Int, actual: Int)
    /// The vertex buffer is shorter than `required` bytes.
    case vertexBufferTooSmall(mesh: String, primitive: Int, required: Int, actual: Int)
    /// An index value in the index buffer addresses past `vertexCount`.
    case indexOutOfBounds(mesh: String, primitive: Int, maxIndex: Int, vertexCount: Int)
    /// `offset` is not a multiple of `alignment` for the index buffer's component type.
    case bufferOffsetMisaligned(mesh: String, primitive: Int, offset: Int, alignment: Int)

    /// A primitive needs more joints than its skin provides (e.g. mesh exported against a different skeleton).
    case skinMismatch(node: String, mesh: String, primitive: Int, requiredJoints: Int, availableJoints: Int)
    /// A vertex references `jointIndex`, but the skin's palette only contains `paletteCount` joints.
    case jointIndexOutOfBounds(node: String, mesh: String, primitive: Int, jointIndex: Int, paletteCount: Int)
    /// A vertex's four skinning weights do not sum to ~1.0; the deformation will be incorrect.
    case invalidSkinningWeights(vertex: Int, weightSum: Float, joints: SIMD4<UInt16>, weights: SIMD4<Float>)
    /// `offset + count` would read past the end of the joint-matrix buffer for `skinIndex`.
    case matrixSliceOutOfBounds(skinIndex: Int, offset: Int, count: Int, total: Int)

    /// The required render `MTLRenderPipelineState` is nil for the given alpha mode / skinning combination.
    case pipelineStateNil(alphaMode: String, skinned: Bool)
    /// The renderer's triple-buffered uniforms array is empty — initialisation did not complete.
    case uniformsBufferEmpty
    /// The morph-target compute `MTLComputePipelineState` is nil; expressions and blend shapes cannot run.
    case computePipelineStateNil

    /// End-of-frame validation reported a downstream error (typically wrapping a ``StrictModeError``).
    case frameValidationFailed(Error)
    /// The submitted `MTLCommandBuffer` finished in `.error` state.
    case commandBufferFailed(String)

    /// A material declared an alpha mode other than `opaque`, `mask`, or `blend`.
    case invalidAlphaMode(String)
    /// A primitive references material `index`, but the model only has `available` materials.
    case invalidMaterialIndex(index: Int, available: Int)

    /// Multi-line description with subsystem prefix, concrete context, and a recovery hint.
    public var errorDescription: String? {
        switch self {
        case .drawValidationFailed(let reason):
            return """
            ❌ VRMRenderer Draw Validation Failed

            The renderer failed to validate a draw call during rendering.

            Reason: \(reason)

            This typically indicates invalid mesh data or buffer configuration.
            Check that your VRM model has valid vertex/index buffers and proper skinning data.

            Suggestion: Enable StrictMode.warn to get detailed validation messages during development.
            """

        case .invalidDrawCall(let reason):
            return "❌ VRMRenderer: Invalid draw call - \(reason)"

        case .zeroIndexCount(let primitive):
            return """
            ❌ VRMRenderer: Zero Index Count

            Primitive '\(primitive)' has zero indices and cannot be rendered.

            This indicates corrupted or incomplete mesh data in the VRM file.
            """

        case .zeroVertexCount(let primitive):
            return """
            ❌ VRMRenderer: Zero Vertex Count

            Primitive '\(primitive)' has zero vertices and cannot be rendered.

            This indicates corrupted or incomplete mesh data in the VRM file.
            """

        case .renderEncoderCreationFailed(let error):
            return """
            ❌ VRMRenderer: Failed to Create Render Encoder

            Metal failed to create a render command encoder.

            Underlying error: \(error.localizedDescription)

            This typically indicates an invalid render pass descriptor or Metal device issues.
            """

        case .computeEncoderCreationFailed(let reason):
            return """
            ❌ VRMRenderer: Failed to Create Compute Encoder

            Reason: \(reason)

            This error occurs when Metal cannot create a compute command encoder,
            typically during morph target computation.
            """

        case .invalidIndexBuffer(let mesh, let primitive, let reason):
            return """
            ❌ VRMRenderer: Invalid Index Buffer

            Mesh: \(mesh)
            Primitive: \(primitive)
            Reason: \(reason)

            The index buffer for this primitive is invalid or corrupted.
            """

        case .invalidVertexBuffer(let mesh, let primitive, let reason):
            return """
            ❌ VRMRenderer: Invalid Vertex Buffer

            Mesh: \(mesh)
            Primitive: \(primitive)
            Reason: \(reason)

            The vertex buffer for this primitive is invalid or corrupted.
            """

        case .indexBufferTooSmall(let mesh, let primitive, let required, let actual):
            return """
            ❌ VRMRenderer: Index Buffer Too Small

            Mesh: \(mesh)
            Primitive: \(primitive)
            Required size: \(required) bytes
            Actual size: \(actual) bytes

            The index buffer is smaller than required for the number of indices.
            This indicates corrupted mesh data in the VRM file.
            """

        case .vertexBufferTooSmall(let mesh, let primitive, let required, let actual):
            return """
            ❌ VRMRenderer: Vertex Buffer Too Small

            Mesh: \(mesh)
            Primitive: \(primitive)
            Required size: \(required) bytes
            Actual size: \(actual) bytes

            The vertex buffer is smaller than required for the number of vertices.
            This indicates corrupted mesh data in the VRM file.
            """

        case .indexOutOfBounds(let mesh, let primitive, let maxIndex, let vertexCount):
            return """
            ❌ VRMRenderer: Index Out of Bounds

            Mesh: \(mesh)
            Primitive: \(primitive)
            Max index found: \(maxIndex)
            Vertex count: \(vertexCount)

            An index in the index buffer references a vertex that doesn't exist.
            This indicates corrupted mesh data in the VRM file.

            Suggestion: Verify the mesh was exported correctly from your 3D modeling software.
            """

        case .bufferOffsetMisaligned(let mesh, let primitive, let offset, let alignment):
            return """
            ❌ VRMRenderer: Buffer Offset Misaligned

            Mesh: \(mesh)
            Primitive: \(primitive)
            Offset: \(offset) bytes
            Required alignment: \(alignment) bytes

            The buffer offset is not properly aligned for the data type.
            Offset must be a multiple of \(alignment).
            """

        case .skinMismatch(let node, let mesh, let primitive, let required, let available):
            return """
            ❌ VRMRenderer: Skin Joint Count Mismatch

            Node: \(node)
            Mesh: \(mesh)
            Primitive: \(primitive)
            Required joints: ≥\(required)
            Available joints: \(available)

            The primitive requires more skinning joints than the skin provides.

            This typically indicates a mismatch between the mesh's joint indices
            and the skeleton's joint count.

            Suggestion: Check that the VRM model's skeleton has all required bones
            and that joint indices in the mesh are valid.

            VRM Spec: https://github.com/vrm-c/vrm-specification/blob/master/specification/VRMC_vrm-1.0/humanoid.md
            """

        case .jointIndexOutOfBounds(let node, let mesh, let primitive, let joint, let palette):
            return """
            ❌ VRMRenderer: Joint Index Out of Bounds

            Node: \(node)
            Mesh: \(mesh)
            Primitive: \(primitive)
            Joint index: \(joint)
            Palette size: \(palette)

            A vertex references a joint index that doesn't exist in the skin's palette.

            Suggestion: Verify that the mesh's skinning data matches the skeleton structure.
            """

        case .invalidSkinningWeights(let vertex, let sum, let joints, let weights):
            return """
            ❌ VRMRenderer: Invalid Skinning Weights

            Vertex: \(vertex)
            Weight sum: \(sum) (expected ~1.0)
            Joints: [\(joints.x), \(joints.y), \(joints.z), \(joints.w)]
            Weights: [\(weights.x), \(weights.y), \(weights.z), \(weights.w)]

            Skinning weights for this vertex don't sum to 1.0.
            This will cause incorrect deformation during animation.

            Suggestion: Re-export the model with normalized skinning weights.
            """

        case .matrixSliceOutOfBounds(let skinIndex, let offset, let count, let total):
            return """
            ❌ VRMRenderer: Joint Matrix Slice Out of Bounds

            Skin index: \(skinIndex)
            Matrix offset: \(offset)
            Palette size: \(count)
            Total matrices: \(total)

            The skin attempts to access joint matrices beyond the allocated buffer range.
            offset(\(offset)) + count(\(count)) > total(\(total))

            This indicates a configuration error in the skinning system.
            """

        case .pipelineStateNil(let alphaMode, let skinned):
            return """
            ❌ VRMRenderer: Pipeline State Not Initialized

            Alpha mode: \(alphaMode)
            Skinned: \(skinned)

            The required render pipeline state is nil.
            This indicates the renderer was not properly initialized.

            Suggestion: Ensure the renderer is fully initialized before calling render().
            """

        case .uniformsBufferEmpty:
            return """
            ❌ VRMRenderer: Uniforms Buffer Not Initialized

            The uniforms buffer array is empty.
            This indicates the renderer was not properly initialized.

            Suggestion: Ensure the renderer is fully initialized before calling render().
            """

        case .computePipelineStateNil:
            return """
            ❌ VRMRenderer: Compute Pipeline State Not Initialized

            The morph target compute pipeline state is nil.
            This indicates the morph target system was not properly initialized.

            Suggestion: Verify that the morph target system is set up before rendering
            models with blend shapes.
            """

        case .frameValidationFailed(let error):
            return """
            ❌ VRMRenderer: Frame Validation Failed

            Error: \(error.localizedDescription)

            The rendered frame failed validation checks.
            Enable StrictMode for detailed diagnostics.
            """

        case .commandBufferFailed(let error):
            return """
            ❌ VRMRenderer: Command Buffer Execution Failed

            Error: \(error)

            The Metal command buffer failed to execute.
            This typically indicates a GPU error or invalid rendering commands.

            Suggestion: Enable Metal API validation in your scheme settings for detailed diagnostics.
            """

        case .invalidAlphaMode(let mode):
            return """
            ❌ VRMRenderer: Invalid Alpha Mode

            Alpha mode: '\(mode)'
            Valid modes: opaque, mask, blend

            The material specifies an unsupported alpha mode.
            """

        case .invalidMaterialIndex(let index, let available):
            return """
            ❌ VRMRenderer: Invalid Material Index

            Material index: \(index)
            Available materials: \(available)

            The primitive references a material that doesn't exist.
            """
        }
    }

    /// One-line caller-facing hint for the most actionable cases (nil for self-explanatory cases).
    public var recoverySuggestion: String? {
        switch self {
        case .drawValidationFailed, .invalidDrawCall:
            return "Enable StrictMode.warn during development to get detailed validation messages."
        case .indexOutOfBounds, .skinMismatch, .jointIndexOutOfBounds:
            return "Verify the VRM model was exported correctly and has valid mesh/skeleton data."
        case .pipelineStateNil, .uniformsBufferEmpty, .computePipelineStateNil:
            return "Ensure the renderer is fully initialized before attempting to render."
        case .commandBufferFailed:
            return "Enable Metal API validation in your Xcode scheme for detailed GPU error diagnostics."
        default:
            return nil
        }
    }
}

// MARK: - Skinning Errors

/// Failures raised by the skinning palette pipeline (joint matrix computation, buffer allocation, lifecycle).
///
/// ## Discussion
/// These errors describe palette-level problems: a per-joint matrix containing
/// `NaN`/`Inf`, a palette that was never populated or has gone stale, or an
/// outright Metal buffer allocation failure. They surface from
/// ``VRMSkinningSystem`` paths and are independent of the per-frame
/// ``VRMRendererError`` checks (which look at *bindings*, not the data inside).
public enum VRMSkinningError: LocalizedError {
    /// The computed skinning matrix for `jointIndex` is invalid (e.g. all zeros or `NaN` in any entry).
    case invalidSkinningMatrix(skinIndex: Int, jointIndex: Int, jointName: String?)
    /// The palette for `skinIndex` was last updated on `lastFrame`, but the current frame is `currentFrame`.
    case stalePalette(skinIndex: Int, lastFrame: Int, currentFrame: Int)
    /// No `updateSkinningData()` call has ever populated the palette for `skinIndex`.
    case neverUpdatedPalette(skinIndex: Int)
    /// The skinning matrix at `jointIndex` contains `NaN` or `Inf` after multiplication with the inverse-bind matrix.
    case matrixContainsNaN(skinIndex: Int, jointIndex: Int, jointName: String?)
    /// `MTLDevice.makeBuffer` returned nil when trying to allocate `size` bytes for joint matrices.
    case bufferAllocationFailed(size: Int)

    /// Multi-line description with `[VRMSkinning]` prefix, indices, joint name (when known), and remediation.
    public var errorDescription: String? {
        switch self {
        case .invalidSkinningMatrix(let skinIndex, let jointIndex, let jointName):
            let name = jointName ?? "unnamed"
            return """
            ❌ VRMSkinning: Invalid Matrix Detected

            Skin index: \(skinIndex)
            Joint index: \(jointIndex)
            Joint name: \(name)

            The skinning matrix contains NaN or Inf values.
            This will cause rendering artifacts or crashes.

            Suggestion: Check that all bone transforms are valid and that
            inverse bind matrices were correctly computed.
            """

        case .stalePalette(let skinIndex, let lastFrame, let currentFrame):
            return """
            ❌ VRMSkinning: Stale Joint Palette

            Skin index: \(skinIndex)
            Last updated frame: \(lastFrame)
            Current frame: \(currentFrame)

            The joint palette for this skin has not been updated for the current frame.
            This will cause rendering with outdated animation data.

            Suggestion: Ensure updateSkinningData() is called every frame before rendering.
            """

        case .neverUpdatedPalette(let skinIndex):
            return """
            ❌ VRMSkinning: Joint Palette Never Updated

            Skin index: \(skinIndex)

            The joint palette for this skin has never been computed.
            This will cause rendering with uninitialized skinning matrices.

            Suggestion: Call updateSkinningData() at least once before rendering.
            """

        case .matrixContainsNaN(let skinIndex, let jointIndex, let jointName):
            let name = jointName ?? "unnamed"
            return """
            ❌ VRMSkinning: Matrix Contains NaN/Inf

            Skin index: \(skinIndex)
            Joint index: \(jointIndex)
            Joint name: \(name)

            The skinning matrix contains NaN or Inf values.
            """

        case .bufferAllocationFailed(let size):
            return """
            ❌ VRMSkinning: Buffer Allocation Failed

            Requested size: \(size) bytes

            Metal failed to allocate the skinning matrices buffer.
            This typically indicates insufficient GPU memory.

            Suggestion: Reduce model complexity or check for memory leaks.
            """
        }
    }
}

// MARK: - Material Validation Errors

/// MToon parameter validation failures, raised when a material's authored value falls outside
/// the spec-mandated range.
///
/// ## Discussion
/// These errors are typically logged at load time when verifying an authored
/// ``VRMMToonMaterial`` against the
/// [MToon 1.0 spec](https://github.com/vrm-c/vrm-specification/blob/master/specification/VRMC_materials_mtoon-1.0/README.md).
/// The renderer continues by clamping to the valid range; the error exists so
/// authors can fix the source file.
public enum VRMMaterialValidationError: LocalizedError {
    /// `outlineWidthMode` was not 0 (none), 1 (world), or 2 (screen).
    case invalidOutlineMode(Int)
    /// One or more components of `matcapFactor` fall outside `0...4`.
    case matcapFactorOutOfRange(SIMD4<Float>)
    /// `parametricRimFresnelPower` is negative.
    case rimFresnelPowerNegative(Float)
    /// `rimLightingMixFactor` is outside `0...1`.
    case rimLightingMixOutOfRange(Float)
    /// `outlineLightingMixFactor` is outside `0...1`.
    case outlineLightingMixOutOfRange(Float)
    /// `giEqualizationFactor` is outside `0...1`.
    case giEqualizationOutOfRange(Float)
    /// `shadingToonyFactor` is outside `0...1`.
    case shadingToonyOutOfRange(Float)
    /// `shadingShiftFactor` is outside `-1...1`.
    case shadingShiftOutOfRange(Float)

    /// Multi-line description with `[MToon Material Validation]` prefix, the offending value, and the valid range.
    public var errorDescription: String? {
        switch self {
        case .invalidOutlineMode(let mode):
            return """
            ❌ MToon Material Validation: Invalid Outline Mode

            Outline mode: \(mode)
            Valid values: 0 (none), 1 (world), 2 (screen)

            The outline mode must be one of the supported values.
            """

        case .matcapFactorOutOfRange(let factor):
            return """
            ❌ MToon Material Validation: Matcap Factor Out of Range

            Matcap factor: \(factor)
            Valid range: [0.0, 4.0] for all components

            The matcap factor must be within the valid range.
            """

        case .rimFresnelPowerNegative(let power):
            return """
            ❌ MToon Material Validation: Negative Rim Fresnel Power

            Rim fresnel power: \(power)
            Valid range: [0.0, ∞)

            The rim fresnel power must be non-negative.
            """

        case .rimLightingMixOutOfRange(let mix):
            return """
            ❌ MToon Material Validation: Rim Lighting Mix Out of Range

            Rim lighting mix: \(mix)
            Valid range: [0.0, 1.0]

            The rim lighting mix factor must be between 0 and 1.
            """

        case .outlineLightingMixOutOfRange(let mix):
            return """
            ❌ MToon Material Validation: Outline Lighting Mix Out of Range

            Outline lighting mix: \(mix)
            Valid range: [0.0, 1.0]

            The outline lighting mix factor must be between 0 and 1.
            """

        case .giEqualizationOutOfRange(let value):
            return """
            ❌ MToon Material Validation: giEqualizationFactor Out of Range

            giEqualizationFactor: \(value)
            Valid range: [0.0, 1.0]

            MToon 1.0 spec defines giEqualizationFactor as the lerp parameter
            between directional indirect (rawGi(n)) and uniform indirect
            (uniformedGi). Default is 0.9. See docs/MTOON_GI_SPEC.md for the
            verbatim spec excerpt and notes on this renderer's deviation.
            """

        case .shadingToonyOutOfRange(let toony):
            return """
            ❌ MToon Material Validation: Shading Toony Factor Out of Range

            Shading toony: \(toony)
            Valid range: [0.0, 1.0]

            The shading toony factor must be between 0 and 1.
            """

        case .shadingShiftOutOfRange(let shift):
            return """
            ❌ MToon Material Validation: Shading Shift Out of Range

            Shading shift: \(shift)
            Valid range: [-1.0, 1.0]

            The shading shift factor must be between -1 and 1.
            """
        }
    }
}

