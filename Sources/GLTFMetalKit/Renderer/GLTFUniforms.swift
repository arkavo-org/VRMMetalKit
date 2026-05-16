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

/// Buffer / texture / sampler slot assignments shared between Swift and the
/// PBR shader.
///
/// **Single source of truth in Swift** — the constants in
/// `Sources/GLTFMetalKit/Shaders/GLTFPBRShader.metal` mirror these. Update
/// both sides if a slot changes.
public enum GLTFShaderBindings {

    // MARK: Buffers

    /// Vertex buffer.
    public static let vertexBuffer = 0
    /// Per-frame uniforms (camera, light, model transform).
    public static let frameUniforms = 1
    /// Per-draw material uniforms (factors, flags).
    public static let materialUniforms = 2
    /// Per-frame punctual-light array (KHR_lights_punctual).
    public static let lightsBuffer = 3

    /// Hard cap on per-draw punctual lights. Must match `kMaxPunctualLights`
    /// in the Metal shader.
    public static let maxPunctualLights = 8

    // MARK: Textures

    public static let baseColorTexture = 0
    public static let metallicRoughnessTexture = 1
    public static let normalTexture = 2
    public static let occlusionTexture = 3
    public static let emissiveTexture = 4
    public static let diffuseEnvironmentTexture = 5
    public static let specularEnvironmentTexture = 6
    public static let brdfLUTTexture = 7

    // MARK: Samplers

    /// Sampler bound to sRGB-decoded color textures (baseColor, emissive).
    public static let colorSampler = 0
    /// Sampler bound to linear-data textures (normal, MR, occlusion).
    public static let linearSampler = 1
    /// Sampler bound to IBL cubemaps and the BRDF LUT (clamp-to-edge, mipped linear).
    public static let environmentSampler = 2
}

/// Per-frame uniforms — model transform, camera, single directional light.
///
/// Memory layout must match the matching struct in `GLTFPBRShader.metal`.
/// SIMD types use Metal-friendly alignment (`float3` is 16-byte-aligned in
/// MSL, so explicit padding floats are inserted after each `SIMD3<Float>`).
public struct GLTFFrameUniforms {
    public var viewProjection: simd_float4x4
    public var model: simd_float4x4
    public var normalMatrix: simd_float3x3
    public var cameraPosition: SIMD3<Float>
    public var _pad0: Float = 0
    /// World-space direction pointing *from* the light *toward* the scene
    /// (i.e. the direction light is travelling). Conventional sunlight from
    /// above + slightly behind the camera works well as a default.
    public var lightDirection: SIMD3<Float>
    public var _pad1: Float = 0
    /// Linear RGB, pre-multiplied by intensity. `[1, 1, 1] * 3.0` gives a
    /// neutral mid-bright key light for a Khronos PBR Neutral pipeline.
    public var lightColor: SIMD3<Float>
    /// Number of mip levels in the bound specular prefiltered cubemap.
    /// Set to `0` to fall back to the gray-ambient path (no real IBL bound);
    /// otherwise pass `Float(environment.specularMipCount)`.
    public var specularMipCount: Float
    /// Number of valid entries in the punctual-light buffer. `0` selects the
    /// fallback `lightDirection` / `lightColor`; otherwise the shader loops
    /// over the bound `GLTFPunctualLightUniform` array.
    public var lightCount: UInt32
    public var _pad2: UInt32 = 0
    public var _pad3: UInt32 = 0
    public var _pad4: UInt32 = 0

    public init(
        viewProjection: simd_float4x4,
        model: simd_float4x4,
        normalMatrix: simd_float3x3,
        cameraPosition: SIMD3<Float>,
        lightDirection: SIMD3<Float>,
        lightColor: SIMD3<Float>,
        specularMipCount: Float,
        lightCount: UInt32 = 0
    ) {
        self.viewProjection = viewProjection
        self.model = model
        self.normalMatrix = normalMatrix
        self.cameraPosition = cameraPosition
        self.lightDirection = lightDirection
        self.lightColor = lightColor
        self.specularMipCount = specularMipCount
        self.lightCount = lightCount
    }
}

/// KHR_lights_punctual light type. Must match the `kLightType*` constants in
/// `GLTFPBRShader.metal`.
public enum GLTFLightType: UInt32, Sendable {
    case directional = 0
    case point       = 1
    case spot        = 2
}

/// Per-light shader uniform — fixed-stride GPU layout matching
/// `GLTFPunctualLight` in `GLTFPBRShader.metal`.
public struct GLTFPunctualLightUniform {
    /// World-space position. Ignored for `.directional`.
    public var position: SIMD3<Float>
    /// Light type encoded as `GLTFLightType.rawValue`.
    public var type: UInt32
    /// World-space direction the light travels. Ignored for `.point`.
    public var direction: SIMD3<Float>
    /// Cosine of the spot inner-cone half-angle (1 for non-spot).
    public var innerConeCos: Float
    /// Linear RGB pre-multiplied by intensity.
    public var color: SIMD3<Float>
    /// Cosine of the spot outer-cone half-angle (-1 for non-spot).
    public var outerConeCos: Float
    /// Point/spot falloff range in world units. `0` = infinite (no falloff).
    public var range: Float
    public var _pad0: Float = 0
    public var _pad1: Float = 0
    public var _pad2: Float = 0

    public init(
        type: GLTFLightType,
        color: SIMD3<Float>,
        intensity: Float = 1,
        position: SIMD3<Float> = .zero,
        direction: SIMD3<Float> = SIMD3<Float>(0, -1, 0),
        range: Float = 0,
        innerConeAngle: Float = 0,
        outerConeAngle: Float = .pi / 4
    ) {
        self.type = type.rawValue
        self.position = position
        self.direction = direction
        self.color = color * intensity
        self.range = range
        self.innerConeCos = type == .spot ? cos(innerConeAngle) : 1
        self.outerConeCos = type == .spot ? cos(outerConeAngle) : -1
    }
}

/// Per-draw material uniforms — glTF 2.0 PBR metallic-roughness factors,
/// emissive, alpha, and the bitmask of optional texture bindings.
public struct GLTFMaterialUniforms {
    public var baseColorFactor: SIMD4<Float>
    public var emissiveFactor: SIMD3<Float>
    public var metallicFactor: Float
    public var roughnessFactor: Float
    public var normalScale: Float
    public var occlusionStrength: Float
    public var alphaCutoff: Float
    /// Bitmask of ``GLTFMaterialFlags`` raw values.
    public var flags: UInt32
    public var _pad0: UInt32 = 0
    public var _pad1: UInt32 = 0
    public var _pad2: UInt32 = 0

    public init(
        baseColorFactor: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 1),
        emissiveFactor: SIMD3<Float> = SIMD3<Float>(0, 0, 0),
        metallicFactor: Float = 1,
        roughnessFactor: Float = 1,
        normalScale: Float = 1,
        occlusionStrength: Float = 1,
        alphaCutoff: Float = 0.5,
        flags: GLTFMaterialFlags = []
    ) {
        self.baseColorFactor = baseColorFactor
        self.emissiveFactor = emissiveFactor
        self.metallicFactor = metallicFactor
        self.roughnessFactor = roughnessFactor
        self.normalScale = normalScale
        self.occlusionStrength = occlusionStrength
        self.alphaCutoff = alphaCutoff
        self.flags = flags.rawValue
    }
}

/// Optional-feature bitmask for ``GLTFMaterialUniforms/flags``.
///
/// Mirrors the `kFlagX` constants in `GLTFPBRShader.metal`. Both sides must
/// stay in sync — bit positions are part of the shader ABI.
public struct GLTFMaterialFlags: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let hasBaseColorTexture         = GLTFMaterialFlags(rawValue: 1 << 0)
    public static let hasMetallicRoughnessTexture = GLTFMaterialFlags(rawValue: 1 << 1)
    public static let hasNormalTexture            = GLTFMaterialFlags(rawValue: 1 << 2)
    public static let hasOcclusionTexture         = GLTFMaterialFlags(rawValue: 1 << 3)
    public static let hasEmissiveTexture          = GLTFMaterialFlags(rawValue: 1 << 4)
    /// `KHR_materials_unlit` — bypass shading entirely, output tonemapped baseColor.
    public static let unlit                       = GLTFMaterialFlags(rawValue: 1 << 5)
    /// glTF `alphaMode` == "MASK".
    public static let alphaMask                   = GLTFMaterialFlags(rawValue: 1 << 6)
    /// glTF `alphaMode` == "BLEND".
    public static let alphaBlend                  = GLTFMaterialFlags(rawValue: 1 << 7)
}
