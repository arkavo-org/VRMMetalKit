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

// glTF 2.0 PBR (metallic-roughness) — Phase 3a step 2.
//
// Direct lighting only this round: one default directional light, Lambert
// diffuse + GGX/Trowbridge–Reitz specular with Schlick Fresnel + Schlick-
// GGX geometry (k = (roughness + 1)² / 8). Khronos PBR Neutral output
// tonemap. IBL split-sum (diffuse irradiance + specular prefiltered +
// BRDF LUT) lands in step 3. Skinning + morph variants in Phase 3b.
//
// Texture color-space contract (caller's responsibility — see
// ParallelTextureLoader linearTextureIndices):
//   - baseColor, emissive    → sRGB sampler  (.rgba8Unorm_srgb)
//   - normal, MR, occlusion  → linear sampler (.rgba8Unorm)
//
// glTF metallic-roughness texture channel layout (spec §3.9.2):
//   - R: unused
//   - G: roughness
//   - B: metallic
//   - A: unused

#include <metal_stdlib>
using namespace metal;

// MARK: - Buffer indices (must match GLTFUniforms.swift)
//
// Single source of truth in Swift; keep these in sync if they change.
constant int kFrameUniformsIndex    = 1;
constant int kMaterialUniformsIndex = 2;
constant int kLightsBufferIndex     = 3;
constant int kSkinPaletteIndex      = 4;

// Maximum number of punctual lights bound per draw. KHR_lights_punctual
// scenes that exceed this are clamped — the renderer drops the rest with
// a log. 8 is the conventional small-scene budget; tuneable.
constant uint kMaxPunctualLights = 8u;

// Light type enum — mirrors KHR_lights_punctual + GLTFLightType in Swift.
constant uint kLightTypeDirectional = 0u;
constant uint kLightTypePoint       = 1u;
constant uint kLightTypeSpot        = 2u;

// MARK: - Texture indices
constant int kBaseColorTextureIndex          = 0;
constant int kMetallicRoughnessTextureIndex  = 1;
constant int kNormalTextureIndex             = 2;
constant int kOcclusionTextureIndex          = 3;
constant int kEmissiveTextureIndex           = 4;
// IBL slots — bound from GLTFRenderer.environment.
constant int kDiffuseEnvironmentIndex        = 5;  // cubemap (irradiance)
constant int kSpecularEnvironmentIndex       = 6;  // cubemap (prefiltered mip chain)
constant int kBRDFLUTIndex                   = 7;  // 2D RG16Float

// MARK: - Sampler indices
constant int kColorSamplerIndex       = 0;  // wraps + linear filtering
constant int kLinearSamplerIndex      = 1;
constant int kEnvironmentSamplerIndex = 2;  // clamp to edge, linear mip filtering

// MARK: - Material flags (must match GLTFMaterialFlags in GLTFUniforms.swift)
constant uint kFlagHasBaseColorTexture        = 1u << 0;
constant uint kFlagHasMetallicRoughnessTexture = 1u << 1;
constant uint kFlagHasNormalTexture           = 1u << 2;
constant uint kFlagHasOcclusionTexture        = 1u << 3;
constant uint kFlagHasEmissiveTexture         = 1u << 4;
constant uint kFlagUnlit                      = 1u << 5;
constant uint kFlagAlphaMask                  = 1u << 6;
constant uint kFlagAlphaBlend                 = 1u << 7;

// MARK: - Uniform structs (must match GLTFUniforms.swift)

struct GLTFFrameUniforms {
    float4x4 viewProjection;
    float4x4 model;
    float3x3 normalMatrix;
    float3 cameraPosition;
    float _pad0;
    /// Default-fallback directional light, used when `lightCount == 0`.
    /// World-space, points *from* the light *toward* the scene.
    float3 lightDirection;
    float _pad1;
    /// Linear RGB, pre-multiplied by intensity.
    float3 lightColor;
    /// Number of mip levels in the prefiltered specular cubemap.
    /// 0 falls back to the gray ambient.
    float specularMipCount;
    /// Number of valid entries in the punctual-light buffer. 0 = use the
    /// fallback lightDirection/lightColor above.
    uint lightCount;
    float _pad2;
    float _pad3;
    float _pad4;
};

struct GLTFPunctualLight {
    /// World-space position (point + spot).
    float3 position;
    /// One of kLightType* — must match GLTFLightType in Swift.
    uint type;
    /// World-space direction the light travels (directional + spot).
    float3 direction;
    /// Spot inner-cone cosine (light type spot only; 1.0 for others).
    float innerConeCos;
    /// Linear RGB pre-multiplied by intensity.
    float3 color;
    /// Spot outer-cone cosine (light type spot only; -1.0 for others).
    float outerConeCos;
    /// Point/spot falloff range in world units. 0 = infinite (no falloff).
    float range;
    float _pad0;
    float _pad1;
    float _pad2;
};

struct GLTFMaterialUniforms {
    float4 baseColorFactor;
    float3 emissiveFactor;
    float metallicFactor;
    float roughnessFactor;
    float normalScale;
    float occlusionStrength;
    float alphaCutoff;
    uint flags;
    uint _pad0;
    uint _pad1;
    uint _pad2;
};

// MARK: - Stage I/O

struct GLTFVertexIn {
    float3 position [[attribute(0)]];
    float3 normal   [[attribute(1)]];
    float4 tangent  [[attribute(2)]];   // xyz = tangent, w = bitangent sign (±1)
    float2 uv0      [[attribute(3)]];
};

struct GLTFSkinnedVertexIn {
    float3 position [[attribute(0)]];
    float3 normal   [[attribute(1)]];
    float4 tangent  [[attribute(2)]];
    float2 uv0      [[attribute(3)]];
    ushort4 joints  [[attribute(4)]];   // JOINTS_0
    float4 weights  [[attribute(5)]];   // WEIGHTS_0
};

struct GLTFVertexOut {
    float4 position [[position]];
    float3 worldPosition;
    float3 worldNormal;
    float3 worldTangent;
    float3 worldBitangent;
    float2 uv0;
};

// MARK: - Tonemap

// Khronos PBR Neutral — designed for glTF and recommended in the spec.
// Reference: https://github.com/KhronosGroup/ToneMapping (Neutral.glsl)
static float3 pbrNeutralToneMap(float3 color) {
    constexpr float startCompression = 0.8 - 0.04;
    constexpr float desaturation = 0.15;

    float x = min(color.r, min(color.g, color.b));
    float offset = x < 0.08 ? x - 6.25 * x * x : 0.04;
    color -= offset;

    float peak = max(color.r, max(color.g, color.b));
    if (peak < startCompression) return color;

    constexpr float d = 1.0 - startCompression;
    float newPeak = 1.0 - d * d / (peak + d - startCompression);
    color *= newPeak / peak;

    float g = 1.0 - 1.0 / (desaturation * (peak - newPeak) + 1.0);
    return mix(color, float3(newPeak), g);
}

// MARK: - BRDF helpers

static float3 fresnelSchlick(float cosTheta, float3 F0) {
    float oneMinusCos = 1.0 - cosTheta;
    return F0 + (1.0 - F0) * (oneMinusCos * oneMinusCos * oneMinusCos * oneMinusCos * oneMinusCos);
}

static float distributionGGX(float NdotH, float roughness) {
    float a = roughness * roughness;
    float a2 = a * a;
    float denom = NdotH * NdotH * (a2 - 1.0) + 1.0;
    return a2 / (M_PI_F * denom * denom + 1e-6);
}

static float geometrySchlickGGX(float NdotV, float roughness) {
    float r = roughness + 1.0;
    float k = (r * r) * (1.0 / 8.0);
    return NdotV / (NdotV * (1.0 - k) + k + 1e-6);
}

static float geometrySmith(float NdotV, float NdotL, float roughness) {
    return geometrySchlickGGX(NdotV, roughness) * geometrySchlickGGX(NdotL, roughness);
}

// MARK: - Normal mapping

static float3 applyNormalMap(
    float3 sampledNormal,    // tangent-space normal in [0, 1]
    float normalScale,
    float3 worldTangent,
    float3 worldBitangent,
    float3 worldNormal
) {
    float3 tangentNormal = sampledNormal * 2.0 - 1.0;
    tangentNormal.xy *= normalScale;
    float3x3 TBN = float3x3(
        normalize(worldTangent),
        normalize(worldBitangent),
        normalize(worldNormal)
    );
    return normalize(TBN * tangentNormal);
}

// MARK: - Vertex

vertex GLTFVertexOut gltf_pbr_vertex(
    GLTFVertexIn in [[stage_in]],
    constant GLTFFrameUniforms& frame [[buffer(kFrameUniformsIndex)]]
) {
    float4 worldPosition4 = frame.model * float4(in.position, 1.0);
    float3 worldNormal    = normalize(frame.normalMatrix * in.normal);
    float3 worldTangent   = normalize(frame.normalMatrix * in.tangent.xyz);
    float3 worldBitangent = cross(worldNormal, worldTangent) * in.tangent.w;

    GLTFVertexOut out;
    out.position       = frame.viewProjection * worldPosition4;
    out.worldPosition  = worldPosition4.xyz;
    out.worldNormal    = worldNormal;
    out.worldTangent   = worldTangent;
    out.worldBitangent = worldBitangent;
    out.uv0            = in.uv0;
    return out;
}

/// Skinned variant: blends four joint matrices weighted by per-vertex
/// WEIGHTS_0, then applies the model transform like the non-skinned path.
/// `frame.model` should be identity when the asset's mesh node carries no
/// own transform (joint matrices already encode world-space placement); use
/// the node world matrix as `model` when the mesh node has its own offset.
vertex GLTFVertexOut gltf_pbr_vertex_skinned(
    GLTFSkinnedVertexIn in [[stage_in]],
    constant GLTFFrameUniforms& frame [[buffer(kFrameUniformsIndex)]],
    constant float4x4* skinPalette    [[buffer(kSkinPaletteIndex)]]
) {
    float4x4 skinMatrix =
        in.weights.x * skinPalette[in.joints.x] +
        in.weights.y * skinPalette[in.joints.y] +
        in.weights.z * skinPalette[in.joints.z] +
        in.weights.w * skinPalette[in.joints.w];

    float4 skinned4 = skinMatrix * float4(in.position, 1.0);
    float4 worldPosition4 = frame.model * skinned4;

    // Skinning math: transforming a normal under a skinMatrix is the same
    // as under the model matrix — strip translation, normalize. Using
    // skinMatrix's upper-left 3×3 is correct in the common case (rigid
    // skinning, no non-uniform bone scale).
    float3x3 skinNormal3 = float3x3(skinMatrix[0].xyz, skinMatrix[1].xyz, skinMatrix[2].xyz);
    float3 worldNormal    = normalize(frame.normalMatrix * (skinNormal3 * in.normal));
    float3 worldTangent   = normalize(frame.normalMatrix * (skinNormal3 * in.tangent.xyz));
    float3 worldBitangent = cross(worldNormal, worldTangent) * in.tangent.w;

    GLTFVertexOut out;
    out.position       = frame.viewProjection * worldPosition4;
    out.worldPosition  = worldPosition4.xyz;
    out.worldNormal    = worldNormal;
    out.worldTangent   = worldTangent;
    out.worldBitangent = worldBitangent;
    out.uv0            = in.uv0;
    return out;
}

// MARK: - Fragment

/// Debug fragment that outputs the world-space normal mapped from [-1, 1] to
/// [0, 1] as RGB. Used by GLTFRender's `--debug normals` mode to confirm the
/// NORMAL accessor is being decoded correctly and the per-vertex normals are
/// being smoothly interpolated by the rasterizer. A face-shaded mesh shows
/// uniform RGB per face; a smooth-shaded mesh shows continuous gradients.
fragment float4 gltf_debug_normals_fragment(
    GLTFVertexOut in [[stage_in]]
) {
    float3 N = normalize(in.worldNormal);
    return float4(N * 0.5 + 0.5, 1.0);
}

/// Debug fragment that visualizes the primary UV channel. Red = u, green = v
/// (each fractionally wrapped to keep the range in [0, 1] for assets with
/// tiled UVs). Used by `--debug uvs` to confirm TEXCOORD_0 decoding and to
/// inspect chart layout. A clean UV chart shows a smooth red/green gradient
/// across each chart island.
fragment float4 gltf_debug_uvs_fragment(
    GLTFVertexOut in [[stage_in]]
) {
    float2 uv = fract(in.uv0);
    return float4(uv.x, uv.y, 0.0, 1.0);
}

/// Debug fragment that visualizes per-fragment roughness as greyscale.
/// Samples the metallic-roughness texture's G channel (glTF spec §3.9.2)
/// scaled by `roughnessFactor`; falls back to the factor alone if no
/// texture is bound. Used by `--debug roughness` to inspect microfacet
/// distribution input.
fragment float4 gltf_debug_roughness_fragment(
    GLTFVertexOut in [[stage_in]],
    constant GLTFMaterialUniforms& material [[buffer(kMaterialUniformsIndex)]],
    texture2d<float> metallicRoughnessTexture [[texture(kMetallicRoughnessTextureIndex)]],
    sampler linearSampler [[sampler(kLinearSamplerIndex)]]
) {
    float roughness = material.roughnessFactor;
    if (material.flags & kFlagHasMetallicRoughnessTexture) {
        roughness *= metallicRoughnessTexture.sample(linearSampler, in.uv0).g;
    }
    return float4(float3(roughness), 1.0);
}

fragment float4 gltf_pbr_fragment(
    GLTFVertexOut in [[stage_in]],
    constant GLTFFrameUniforms& frame [[buffer(kFrameUniformsIndex)]],
    constant GLTFMaterialUniforms& material [[buffer(kMaterialUniformsIndex)]],
    constant GLTFPunctualLight* lights [[buffer(kLightsBufferIndex)]],
    texture2d<float>   baseColorTexture          [[texture(kBaseColorTextureIndex)]],
    texture2d<float>   metallicRoughnessTexture  [[texture(kMetallicRoughnessTextureIndex)]],
    texture2d<float>   normalTexture             [[texture(kNormalTextureIndex)]],
    texture2d<float>   occlusionTexture          [[texture(kOcclusionTextureIndex)]],
    texture2d<float>   emissiveTexture           [[texture(kEmissiveTextureIndex)]],
    texturecube<float> diffuseEnvironment       [[texture(kDiffuseEnvironmentIndex)]],
    texturecube<float> specularEnvironment      [[texture(kSpecularEnvironmentIndex)]],
    texture2d<float>   brdfLUT                  [[texture(kBRDFLUTIndex)]],
    sampler colorSampler       [[sampler(kColorSamplerIndex)]],
    sampler linearSampler      [[sampler(kLinearSamplerIndex)]],
    sampler environmentSampler [[sampler(kEnvironmentSamplerIndex)]]
) {
    // --- Material sampling --------------------------------------------------

    float4 baseColor = material.baseColorFactor;
    if (material.flags & kFlagHasBaseColorTexture) {
        // colorSampler binds to an sRGB-decoding texture; sample returns linear RGBA.
        baseColor *= baseColorTexture.sample(colorSampler, in.uv0);
    }

    // Alpha test (MASK mode)
    if ((material.flags & kFlagAlphaMask) && baseColor.a < material.alphaCutoff) {
        discard_fragment();
    }

    // KHR_materials_unlit shortcut — bypass shading entirely, just tonemap baseColor.
    if (material.flags & kFlagUnlit) {
        float3 unlit = pbrNeutralToneMap(baseColor.rgb);
        float outAlpha = (material.flags & kFlagAlphaBlend) ? baseColor.a : 1.0;
        return float4(unlit, outAlpha);
    }

    float metallic  = material.metallicFactor;
    float roughness = material.roughnessFactor;
    if (material.flags & kFlagHasMetallicRoughnessTexture) {
        // glTF spec: B = metallic, G = roughness.
        float4 mr = metallicRoughnessTexture.sample(linearSampler, in.uv0);
        metallic  *= mr.b;
        roughness *= mr.g;
    }
    roughness = clamp(roughness, 0.04, 1.0);

    float3 emissive = material.emissiveFactor;
    if (material.flags & kFlagHasEmissiveTexture) {
        emissive *= emissiveTexture.sample(colorSampler, in.uv0).rgb;
    }

    float occlusion = 1.0;
    if (material.flags & kFlagHasOcclusionTexture) {
        float ao = occlusionTexture.sample(linearSampler, in.uv0).r;
        occlusion = mix(1.0, ao, material.occlusionStrength);
    }

    // --- Surface frame ------------------------------------------------------

    float3 N;
    if (material.flags & kFlagHasNormalTexture) {
        float3 sampled = normalTexture.sample(linearSampler, in.uv0).rgb;
        N = applyNormalMap(sampled, material.normalScale, in.worldTangent, in.worldBitangent, in.worldNormal);
    } else {
        N = normalize(in.worldNormal);
    }
    float3 V = normalize(frame.cameraPosition - in.worldPosition);
    float NdotV = saturate(dot(N, V));

    // --- BRDF ---------------------------------------------------------------

    float3 F0  = mix(float3(0.04), baseColor.rgb, metallic);

    // Direct lighting — punctual-light array (KHR_lights_punctual) when
    // bound, falling back to the single directional light in frame uniforms.
    float3 direct = float3(0.0);

    uint lightCount = min(frame.lightCount, kMaxPunctualLights);
    if (lightCount == 0u) {
        // Fallback: one default directional light from the frame uniforms.
        float3 L = normalize(-frame.lightDirection);
        float3 H = normalize(V + L);
        float NdotL = saturate(dot(N, L));
        float NdotH = saturate(dot(N, H));
        float VdotH = saturate(dot(V, H));

        float3 F = fresnelSchlick(VdotH, F0);
        float  D = distributionGGX(NdotH, roughness);
        float  G = geometrySmith(NdotV, NdotL, roughness);

        float3 spec = (D * G) * F / max(4.0 * NdotL * NdotV, 1e-4);
        float3 kS = F;
        float3 kD = (1.0 - kS) * (1.0 - metallic);
        float3 diff = kD * baseColor.rgb / M_PI_F;
        direct = (diff + spec) * frame.lightColor * NdotL;
    } else {
        for (uint i = 0u; i < lightCount; ++i) {
            constant GLTFPunctualLight& light = lights[i];

            // Per-type L and attenuation.
            float3 toLight;
            float attenuation = 1.0;
            if (light.type == kLightTypeDirectional) {
                toLight = -light.direction;
            } else if (light.type == kLightTypePoint || light.type == kLightTypeSpot) {
                float3 delta = light.position - in.worldPosition;
                float dist = length(delta);
                toLight = delta / max(dist, 1e-4);
                if (light.range > 0.0) {
                    float t = saturate(1.0 - pow(dist / light.range, 4.0));
                    attenuation = t * t / max(dist * dist, 1e-4);
                } else {
                    attenuation = 1.0 / max(dist * dist, 1e-4);
                }
                if (light.type == kLightTypeSpot) {
                    float spotCos = dot(toLight, -light.direction);
                    float spotFactor = saturate((spotCos - light.outerConeCos) /
                                                max(light.innerConeCos - light.outerConeCos, 1e-4));
                    attenuation *= spotFactor;
                }
            } else {
                continue;
            }

            float3 L = normalize(toLight);
            float3 H = normalize(V + L);
            float NdotL = saturate(dot(N, L));
            if (NdotL <= 0.0) continue;
            float NdotH = saturate(dot(N, H));
            float VdotH = saturate(dot(V, H));

            float3 F = fresnelSchlick(VdotH, F0);
            float  D = distributionGGX(NdotH, roughness);
            float  G = geometrySmith(NdotV, NdotL, roughness);
            float3 spec = (D * G) * F / max(4.0 * NdotL * NdotV, 1e-4);
            float3 kS = F;
            float3 kD = (1.0 - kS) * (1.0 - metallic);
            float3 diff = kD * baseColor.rgb / M_PI_F;
            direct += (diff + spec) * light.color * NdotL * attenuation;
        }
    }

    // --- IBL split-sum (Karis 2013) -----------------------------------------
    //
    // Diffuse term:  baseColor / π integrated against irradiance map.
    // Specular term: prefiltered cubemap sampled at LOD = roughness * (mips-1)
    //                multiplied by BRDF LUT (scale, bias). Fresnel uses
    //                NdotV (not VdotH) for the ambient lobe.
    //
    // When `specularMipCount` is 0 the caller hasn't bound a real environment;
    // we fall through to a small gray ambient so back-faces aren't pitch black.
    float3 ambient;
    if (frame.specularMipCount > 0.5) {
        float3 R = reflect(-V, N);
        float3 F_ibl = fresnelSchlick(NdotV, F0);
        float3 kS_ibl = F_ibl;
        float3 kD_ibl = (1.0 - kS_ibl) * (1.0 - metallic);

        float3 irradiance = diffuseEnvironment.sample(environmentSampler, N).rgb;
        float3 diffuseIBL = kD_ibl * baseColor.rgb * irradiance;

        float mipLevel = roughness * (frame.specularMipCount - 1.0);
        float3 prefiltered = specularEnvironment.sample(environmentSampler, R, level(mipLevel)).rgb;
        float2 envBRDF = brdfLUT.sample(environmentSampler, float2(NdotV, roughness)).rg;
        float3 specularIBL = prefiltered * (F_ibl * envBRDF.x + envBRDF.y);

        ambient = (diffuseIBL + specularIBL) * occlusion;
    } else {
        ambient = baseColor.rgb * 0.03 * occlusion;
    }

    float3 color = direct + ambient + emissive;
    color = pbrNeutralToneMap(color);

    float outAlpha = (material.flags & kFlagAlphaBlend) ? baseColor.a : 1.0;
    return float4(color, outAlpha);
}
