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
import simd

// NOTE: MToon shaders are pre-compiled into VRMMetalKitShaders.metallib
// See Sources/VRMMetalKit/Shaders/MToonShader.metal for the actual shader source
// The structs below must match the Metal shader struct layouts exactly

// MARK: - MToonMaterialUniforms

/// CPU-side uniform payload uploaded to the MToon shader.
///
/// Field layout, ordering, and padding must match the `MToonMaterialUniforms`
/// struct in the Metal shader source. Floating-point colours are stored as
/// explicit packed R/G/B fields (rather than `SIMD3`) to mirror Metal's
/// `float3` storage layout exactly — the `*Factor` computed properties on this
/// type provide a `SIMD3<Float>` view for convenience.
///
/// ## Responsibility split
///
/// This Swift type is responsible for **uniform packing** — it gathers VRM 1.0
/// MToon material parameters into a 16-byte-aligned blob, exposes
/// ``MToonMaterialUniforms/init(from:time:)`` to derive that blob from a
/// ``VRMMToonMaterial``, and provides ``MToonMaterialUniforms/validate()``
/// for range checks before binding.
///
/// The **actual MToon shading** is implemented in
/// `Sources/VRMMetalKit/Shaders/MToonShader.metal`. That `.metal` source is
/// excluded from SPM build (see `Package.swift` exclusions) and is pre-compiled
/// into `Resources/VRMMetalKitShaders.metallib` via `make shaders`; the
/// runtime pipeline is built by ``VRMPipelineCache`` against the metallib.
public struct MToonMaterialUniforms {
    // Block 0: 16 bytes - Base material properties

    /// Base colour (sRGB) and alpha factor.
    public var baseColorFactor: SIMD4<Float> = [1, 1, 1, 1]

    // Block 1: 16 bytes - Shade and basic factors (packed float3 + float)

    /// Shade colour, red channel. Use ``MToonMaterialUniforms/shadeColorFactor`` for a `SIMD3` view.
    public var shadeColorR: Float = 0.0
    /// Shade colour, green channel.
    public var shadeColorG: Float = 0.0
    /// Shade colour, blue channel.
    public var shadeColorB: Float = 0.0
    /// MToon "toony" factor (0…1). Higher values produce harder shade transitions.
    public var shadingToonyFactor: Float = 0.9

    // Block 2: 16 bytes - Material factors (float + packed float3)

    /// MToon shading shift (-1…1). Offsets the lit/shade transition along
    /// the shader's restored Half-Lambert NdotL input; see `MToonShader.metal`.
    public var shadingShiftFactor: Float = 0.0
    /// Emissive colour, red channel. Use ``MToonMaterialUniforms/emissiveFactor`` for a `SIMD3` view.
    public var emissiveR: Float = 0.0
    /// Emissive colour, green channel.
    public var emissiveG: Float = 0.0
    /// Emissive colour, blue channel.
    public var emissiveB: Float = 0.0

    // Block 3: 16 bytes - PBR factors

    /// Metallic factor (0…1). MToon ignores this for lighting but it is kept for glTF fallback.
    public var metallicFactor: Float = 0.0
    /// Roughness factor (0…1). Kept for glTF fallback; MToon shading is non-PBR.
    public var roughnessFactor: Float = 1.0
    /// GI equalization factor (0…1) controlling how strongly indirect light is normalized.
    public var giEqualizationFactor: Float = 0.9
    /// Multiplier applied to sampled shading-shift texture values.
    public var shadingShiftTextureScale: Float = 1.0

    // Block 4: 16 bytes - MatCap properties (packed float3 + int)

    /// MatCap colour, red channel. Use ``MToonMaterialUniforms/matcapFactor`` for a `SIMD3` view.
    public var matcapR: Float = 1.0
    /// MatCap colour, green channel.
    public var matcapG: Float = 1.0
    /// MatCap colour, blue channel.
    public var matcapB: Float = 1.0
    /// Non-zero if a MatCap texture is bound for this material.
    public var hasMatcapTexture: Int32 = 0

    // Block 5: 16 bytes - Rim lighting part 1 (packed float3 + float)

    /// Parametric rim colour, red channel.
    public var rimColorR: Float = 0.0
    /// Parametric rim colour, green channel.
    public var rimColorG: Float = 0.0
    /// Parametric rim colour, blue channel.
    public var rimColorB: Float = 0.0
    /// Fresnel power for the parametric rim term; higher values narrow the rim edge.
    public var parametricRimFresnelPowerFactor: Float = 5.0

    // Block 6: 16 bytes - Rim lighting part 2

    /// Parametric rim lift (typically 0…1). Lifts the rim term off zero.
    public var parametricRimLiftFactor: Float = 0.0
    /// Mix between unlit rim and scene-radiance-modulated rim (0…1).
    /// Validation rejects out-of-range CPU values; the shader also clamps this
    /// defensively for fuzzed or unchecked uniform buffers.
    public var rimLightingMixFactor: Float = 1.0
    /// Non-zero if a rim-multiply texture is bound for this material.
    public var hasRimMultiplyTexture: Int32 = 0
    private var _padding1: Float = 0.0

    // Block 7: 16 bytes - Outline properties part 1 (float + packed float3)

    /// Inverted-hull outline width factor (world or screen units depending on `outlineMode`).
    public var outlineWidthFactor: Float = 0.0
    /// Outline colour, red channel.
    public var outlineColorR: Float = 0.0
    /// Outline colour, green channel.
    public var outlineColorG: Float = 0.0
    /// Outline colour, blue channel.
    public var outlineColorB: Float = 0.0

    // Block 8: 16 bytes - Outline properties part 2

    /// Mix between unlit outline and lit-coloured outline (0…1).
    public var outlineLightingMixFactor: Float = 1.0
    /// Outline mode: 0 = none, 1 = world coordinates, 2 = screen coordinates.
    public var outlineMode: Float = 0.0
    /// Non-zero if an outline-width-multiply texture is bound for this material.
    public var hasOutlineWidthMultiplyTexture: Int32 = 0
    private var _padding2: Float = 0.0

    // Block 9: 16 bytes - UV Animation

    /// UV scroll speed along X in UV-units per second.
    public var uvAnimationScrollXSpeedFactor: Float = 0.0
    /// UV scroll speed along Y in UV-units per second.
    public var uvAnimationScrollYSpeedFactor: Float = 0.0
    /// UV rotation speed in radians per second.
    public var uvAnimationRotationSpeedFactor: Float = 0.0
    /// Animation time in seconds; the renderer ticks this each frame.
    public var time: Float = 0.0

    // Block 10: 16 bytes - Texture flags

    /// Non-zero if a UV-animation mask texture is bound.
    public var hasUvAnimationMaskTexture: Int32 = 0
    /// Non-zero if a base-colour texture is bound.
    public var hasBaseColorTexture: Int32 = 0
    /// Non-zero if a shade-multiply texture is bound.
    public var hasShadeMultiplyTexture: Int32 = 0
    /// Non-zero if a shading-shift texture is bound.
    public var hasShadingShiftTexture: Int32 = 0

    // Block 11: 16 bytes - More texture flags

    /// Non-zero if a normal map is bound.
    public var hasNormalTexture: Int32 = 0
    /// Non-zero if an emissive texture is bound.
    public var hasEmissiveTexture: Int32 = 0
    /// Alpha mode: 0 = OPAQUE, 1 = MASK, 2 = BLEND.
    public var alphaMode: UInt32 = 0
    /// Alpha cutoff value used when `alphaMode` is MASK.
    public var alphaCutoff: Float = 0.5

    // Block 12: 16 bytes - Version flag and UV offset

    /// VRM spec version (0 = VRM 0.x, 1 = VRM 1.0). Selects spec-conformant shading paths in MSL.
    public var vrmVersion: UInt32 = 1
    /// UV offset for texture remapping (e.g., face overlays), X component.
    public var uvOffsetX: Float = 0.0
    /// UV offset for texture remapping, Y component.
    public var uvOffsetY: Float = 0.0
    /// UV scale for texture remapping.
    public var uvScale: Float = 1.0

    // Block 13: 16 bytes - KHR_texture_transform (offset, rotation, scale)

    /// `KHR_texture_transform` offset, X component.
    public var textureTransformOffsetX: Float = 0.0
    /// `KHR_texture_transform` offset, Y component.
    public var textureTransformOffsetY: Float = 0.0
    /// `KHR_texture_transform` rotation in radians.
    public var textureTransformRotation: Float = 0.0
    /// `KHR_texture_transform` scale, X component.
    public var textureTransformScaleX: Float = 1.0

    // Block 14: 16 bytes - KHR_texture_transform scale Y + padding

    /// `KHR_texture_transform` scale, Y component.
    public var textureTransformScaleY: Float = 1.0
    private var _ttPad0: Float = 0.0
    private var _ttPad1: Float = 0.0
    private var _ttPad2: Float = 0.0

    /// Creates a default-initialized uniform payload.
    public init() {}

    // Computed properties for convenient SIMD3 access

    /// Shade colour as a `SIMD3<Float>` view over the packed R/G/B fields.
    public var shadeColorFactor: SIMD3<Float> {
        get { SIMD3<Float>(shadeColorR, shadeColorG, shadeColorB) }
        set { shadeColorR = newValue.x; shadeColorG = newValue.y; shadeColorB = newValue.z }
    }

    /// Emissive colour as a `SIMD3<Float>` view over the packed R/G/B fields.
    public var emissiveFactor: SIMD3<Float> {
        get { SIMD3<Float>(emissiveR, emissiveG, emissiveB) }
        set { emissiveR = newValue.x; emissiveG = newValue.y; emissiveB = newValue.z }
    }

    /// MatCap colour as a `SIMD3<Float>` view over the packed R/G/B fields.
    public var matcapFactor: SIMD3<Float> {
        get { SIMD3<Float>(matcapR, matcapG, matcapB) }
        set { matcapR = newValue.x; matcapG = newValue.y; matcapB = newValue.z }
    }

    /// Parametric rim colour as a `SIMD3<Float>` view over the packed R/G/B fields.
    public var parametricRimColorFactor: SIMD3<Float> {
        get { SIMD3<Float>(rimColorR, rimColorG, rimColorB) }
        set { rimColorR = newValue.x; rimColorG = newValue.y; rimColorB = newValue.z }
    }

    /// Outline colour as a `SIMD3<Float>` view over the packed R/G/B fields.
    public var outlineColorFactor: SIMD3<Float> {
        get { SIMD3<Float>(outlineColorR, outlineColorG, outlineColorB) }
        set { outlineColorR = newValue.x; outlineColorG = newValue.y; outlineColorB = newValue.z }
    }

    /// Builds a uniform payload from a ``VRMMToonMaterial`` plus the current animation time.
    public init(from mtoon: VRMMToonMaterial, time: Float = 0.0) {
        self.shadeColorFactor = mtoon.shadeColorFactor
        self.shadingToonyFactor = mtoon.shadingToonyFactor
        self.shadingShiftFactor = mtoon.shadingShiftFactor
        self.giEqualizationFactor = mtoon.giEqualizationFactor
        self.shadingShiftTextureScale = mtoon.shadingShiftTexture?.scale ?? 1.0

        self.matcapFactor = mtoon.matcapFactor
        self.hasMatcapTexture = mtoon.matcapTexture != nil ? 1 : 0

        self.parametricRimColorFactor = mtoon.parametricRimColorFactor
        self.parametricRimFresnelPowerFactor = mtoon.parametricRimFresnelPowerFactor
        self.parametricRimLiftFactor = mtoon.parametricRimLiftFactor
        self.rimLightingMixFactor = mtoon.rimLightingMixFactor
        self.hasRimMultiplyTexture = mtoon.rimMultiplyTexture != nil ? 1 : 0

        self.outlineWidthFactor = mtoon.outlineWidthFactor
        self.outlineColorFactor = mtoon.outlineColorFactor
        self.outlineLightingMixFactor = mtoon.outlineLightingMixFactor
        switch mtoon.outlineWidthMode {
        case .none:
            self.outlineMode = 0.0
        case .worldCoordinates:
            self.outlineMode = 1.0
        case .screenCoordinates:
            self.outlineMode = 2.0
        }
        self.hasOutlineWidthMultiplyTexture = mtoon.outlineWidthMultiplyTexture != nil ? 1 : 0

        self.uvAnimationScrollXSpeedFactor = mtoon.uvAnimationScrollXSpeedFactor
        self.uvAnimationScrollYSpeedFactor = mtoon.uvAnimationScrollYSpeedFactor
        self.uvAnimationRotationSpeedFactor = mtoon.uvAnimationRotationSpeedFactor
        self.time = time
        self.hasUvAnimationMaskTexture = mtoon.uvAnimationMaskTexture != nil ? 1 : 0

        self.hasShadeMultiplyTexture = mtoon.shadeMultiplyTexture != nil ? 1 : 0
        self.hasShadingShiftTexture = mtoon.shadingShiftTexture != nil ? 1 : 0

        if let transform = mtoon.textureTransform {
            self.textureTransformOffsetX = transform.offset.x
            self.textureTransformOffsetY = transform.offset.y
            self.textureTransformRotation = transform.rotation
            self.textureTransformScaleX = transform.scale.x
            self.textureTransformScaleY = transform.scale.y
        }
    }

    /// Validates packed uniform values against MToon parameter ranges.
    ///
    /// Throws ``VRMMaterialValidationError`` when any of the following holds:
    /// `outlineMode` is not 0/1/2, `matcapFactor` falls outside `[0, 4]`,
    /// `parametricRimFresnelPowerFactor` is negative, `rimLightingMixFactor` /
    /// `outlineLightingMixFactor` / `giEqualizationFactor` / `shadingToonyFactor`
    /// fall outside `[0, 1]`, or `shadingShiftFactor` falls outside `[-1, 1]`.
    /// In debug builds, additional non-fatal warnings are logged for unusually
    /// large rim-lift, UV-rotation, or outline-width values.
    public func validate() throws {
        // Validate outline mode
        guard outlineMode == 0 || outlineMode == 1 || outlineMode == 2 else {
            throw VRMMaterialValidationError.invalidOutlineMode(Int(outlineMode))
        }

        // Validate matcap factor
        guard all(matcapFactor .>= 0) && all(matcapFactor .<= 4) else {
            throw VRMMaterialValidationError.matcapFactorOutOfRange(SIMD4<Float>(matcapFactor, 1.0))
        }

        // Validate rim fresnel power
        guard parametricRimFresnelPowerFactor >= 0 else {
            throw VRMMaterialValidationError.rimFresnelPowerNegative(parametricRimFresnelPowerFactor)
        }

        // Validate rim lighting mix
        guard rimLightingMixFactor >= 0 && rimLightingMixFactor <= 1 else {
            throw VRMMaterialValidationError.rimLightingMixOutOfRange(rimLightingMixFactor)
        }

        // Validate outline lighting mix
        guard outlineLightingMixFactor >= 0 && outlineLightingMixFactor <= 1 else {
            throw VRMMaterialValidationError.outlineLightingMixOutOfRange(outlineLightingMixFactor)
        }

        // Validate GI intensity
        guard giEqualizationFactor >= 0 && giEqualizationFactor <= 1 else {
            throw VRMMaterialValidationError.giEqualizationOutOfRange(giEqualizationFactor)
        }

        // Validate shading toony factor
        guard shadingToonyFactor >= 0 && shadingToonyFactor <= 1 else {
            throw VRMMaterialValidationError.shadingToonyOutOfRange(shadingToonyFactor)
        }

        // Validate shading shift factor
        guard shadingShiftFactor >= -1 && shadingShiftFactor <= 1 else {
            throw VRMMaterialValidationError.shadingShiftOutOfRange(shadingShiftFactor)
        }

        #if DEBUG
        // Additional debug checks
        let epsilon: Float = 0.001
        if parametricRimLiftFactor < -epsilon || parametricRimLiftFactor > 1 + epsilon {
            vrmLog("Warning: Rim lift factor unusual value: \(parametricRimLiftFactor)")
        }
        if uvAnimationRotationSpeedFactor > 10 {
            vrmLog("Warning: Very high UV rotation speed: \(uvAnimationRotationSpeedFactor) rad/s")
        }
        if outlineWidthFactor > 0.1 {
            vrmLog("Warning: Very large outline width: \(outlineWidthFactor)")
        }
        #endif
    }

    /// Multi-line human-readable summary of the uniform payload for debugging.
    public var debugDescription: String {
        return """
        MToon Material Debug:
        - Outline Mode: \(outlineMode) (0=none, 1=world, 2=screen)
        - MatCap Factor: \(matcapFactor)
        - Rim Color: \(parametricRimColorFactor), Power: \(parametricRimFresnelPowerFactor), Lift: \(parametricRimLiftFactor)
        - Outline Width: \(outlineWidthFactor), Color: \(outlineColorFactor)
        - UV Animation: scroll(\(uvAnimationScrollXSpeedFactor), \(uvAnimationScrollYSpeedFactor)), rot(\(uvAnimationRotationSpeedFactor))
        - Textures: base(\(hasBaseColorTexture)), matcap(\(hasMatcapTexture)), rim(\(hasRimMultiplyTexture))
        """
    }
}

/// MToon outline width interpretation mode.
///
/// Mirrors the VRM 1.0 MToon spec values that select how
/// ``MToonMaterialUniforms/outlineWidthFactor`` is interpreted by the
/// inverted-hull pass.
public enum MToonOutlineWidthMode: String {
    /// No outline is rendered.
    case none = "none"
    /// Outline width is measured in world units.
    case worldCoordinates = "worldCoordinates"
    /// Outline width is measured in screen units.
    case screenCoordinates = "screenCoordinates"
}
