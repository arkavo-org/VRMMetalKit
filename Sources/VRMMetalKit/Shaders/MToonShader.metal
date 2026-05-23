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


#include <metal_stdlib>
using namespace metal;

#ifndef MTOON_USE_HALF_PRECISION
#define MTOON_USE_HALF_PRECISION 0
#endif

#if MTOON_USE_HALF_PRECISION
typedef half mtoon_float;
typedef half2 mtoon_float2;
typedef half3 mtoon_float3;
typedef half4 mtoon_float4;
#else
typedef float mtoon_float;
typedef float2 mtoon_float2;
typedef float3 mtoon_float3;
typedef float4 mtoon_float4;
#endif

// BRDF Lambert normalization constant: a perfectly diffuse surface
// reflects `albedo/π` per steradian under unit irradiance. Applied to
// MToon direct lighting only — matches three-vrm's `BRDF_Lambert` and
// UniVRM Built-in RP's implicit `/π`. Indirect/rim/matcap/emissive are
// stylistic additive terms (not Lambert BRDFs) and intentionally skip it.
constant float BRDF_LAMBERT_NORM = 1.0 / M_PI_F;

struct Uniforms {
 float4x4 modelMatrix;
 float4x4 viewMatrix;
 float4x4 projectionMatrix;
 float4x4 normalMatrix;
 // Light 0 (key light) - using float4 for Swift SIMD4 alignment
 float4 lightDirection;        // xyz = direction, w = unused
 float4 lightColor;            // xyz = color, w = pre-calculated intensity
 float4 ambientColor;          // xyz = color, w = unused
 // Light 1 (fill light)
 float4 light1Direction;       // xyz = direction, w = unused
 float4 light1Color;           // xyz = color, w = pre-calculated intensity
 // Light 2 (rim/back light)
 float4 light2Direction;       // xyz = direction, w = unused
 float4 light2Color;           // xyz = color, w = pre-calculated intensity
 // Other fields - packed into float4 for alignment
 float4 viewportSize;          // xy = size, zw = padding
 float4 nearFarPlane;          // x = near, y = far, zw = padding
 int debugUVs;                 // Debug flag: 1 = show UVs as colors, 0 = normal rendering
 float lightNormalizationFactor;  // Multi-light normalization factor
 int vrmVersion;              // 0 = VRM 0.x (Half-Lambert), 1 = VRM 1.0 (raw dot)
 float _padding3;
 int toonBands;                // Number of cel-shading bands
 float additiveDirectionalRimEnabled;  // 0 = off (legacy), >0.5 = enable additive directional rim
 float additiveDirectionalRimPower;    // Fresnel exponent for the additive rim (typical 4..12)
 uint cameraMode;             // 0 = third-person, 1 = first-person
};

// Use packed_float3 to match Swift's Float component layout (no 16-byte alignment)
// This ensures Metal struct size (192 bytes) matches Swift struct stride exactly
struct MToonMaterial {
 // Block 0: 16 bytes - Base material properties
 float4 baseColorFactor;                    // 16 bytes

 // Block 1: 16 bytes - Shade and basic factors (packed float3 + float)
 float shadeColorR;                         // 4 bytes
 float shadeColorG;                         // 4 bytes
 float shadeColorB;                         // 4 bytes
 float shadingToonyFactor;                  // 4 bytes

 // Block 2: 16 bytes - Material factors (float + packed float3)
 float shadingShiftFactor;                  // 4 bytes
 float emissiveR;                           // 4 bytes
 float emissiveG;                           // 4 bytes
 float emissiveB;                           // 4 bytes

 // Block 3: 16 bytes - PBR factors
 float metallicFactor;                      // 4 bytes
 float roughnessFactor;                     // 4 bytes
 float giEqualizationFactor;                   // 4 bytes
 float shadingShiftTextureScale;            // 4 bytes

 // Block 4: 16 bytes - MatCap properties (packed float3 + int)
 float matcapR;                             // 4 bytes
 float matcapG;                             // 4 bytes
 float matcapB;                             // 4 bytes
 int hasMatcapTexture;                      // 4 bytes

 // Block 5: 16 bytes - Rim lighting part 1 (packed float3 + float)
 float parametricRimColorR;                 // 4 bytes
 float parametricRimColorG;                 // 4 bytes
 float parametricRimColorB;                 // 4 bytes
 float parametricRimFresnelPowerFactor;     // 4 bytes

 // Block 6: 16 bytes - Rim lighting part 2
 float parametricRimLiftFactor;             // 4 bytes
 float rimLightingMixFactor;                // 4 bytes
 int hasRimMultiplyTexture;                 // 4 bytes
 float _padding1;                           // 4 bytes padding

 // Block 7: 16 bytes - Outline properties part 1 (float + packed float3)
 float outlineWidthFactor;                  // 4 bytes
 float outlineColorR;                       // 4 bytes
 float outlineColorG;                       // 4 bytes
 float outlineColorB;                       // 4 bytes

 // Block 8: 16 bytes - Outline properties part 2
 float outlineLightingMixFactor;            // 4 bytes
 float outlineMode;                         // 4 bytes (0: None, 1: World, 2: Screen)
 int hasOutlineWidthMultiplyTexture;        // 4 bytes
 float _padding2;                           // 4 bytes padding

 // Block 9: 16 bytes - UV Animation
 float uvAnimationScrollXSpeedFactor;       // 4 bytes
 float uvAnimationScrollYSpeedFactor;       // 4 bytes
 float uvAnimationRotationSpeedFactor;      // 4 bytes
 float time;                                // 4 bytes

 // Block 10: 16 bytes - Texture flags
 int hasUvAnimationMaskTexture;             // 4 bytes
 int hasBaseColorTexture;                   // 4 bytes
 int hasShadeMultiplyTexture;               // 4 bytes
 int hasShadingShiftTexture;                // 4 bytes

 // Block 11: 16 bytes - More texture flags and alpha
 int hasNormalTexture;                      // 4 bytes
 int hasEmissiveTexture;                    // 4 bytes
 uint32_t alphaMode;                        // 4 bytes (0: OPAQUE, 1: MASK, 2: BLEND)
 float alphaCutoff;                         // 4 bytes

 // Block 12: 16 bytes - Version flag and UV offset
 uint32_t vrmVersion;                       // 4 bytes (0 = VRM 0.0, 1 = VRM 1.0)
 float uvOffsetX;                           // 4 bytes - UV offset for texture remapping
 float uvOffsetY;                           // 4 bytes - UV offset for texture remapping
 float uvScale;                             // 4 bytes - UV scale for texture remapping

 // Block 13: 16 bytes - KHR_texture_transform (offset, rotation, scale X)
 float textureTransformOffsetX;             // 4 bytes
 float textureTransformOffsetY;             // 4 bytes
 float textureTransformRotation;            // 4 bytes
 float textureTransformScaleX;             // 4 bytes

 // Block 14: 16 bytes - KHR_texture_transform scale Y + normalScale + padding
 float textureTransformScaleY;             // 4 bytes
 float normalScale;                         // 4 bytes — glTF-core normalTextureInfo.scale (VMK#290)
 float _ttPad1;                             // 4 bytes padding
 float _ttPad2;                             // 4 bytes padding
};

struct VertexIn {
 float3 position [[attribute(0)]];
 float3 normal [[attribute(1)]];
 float2 texCoord [[attribute(2)]];
 float4 color [[attribute(3)]];
};

struct VertexOut {
 float4 position [[position]];
 float3 worldPosition;
 float3 worldNormal;
 float2 texCoord;
 float2 animatedTexCoord;
 float4 color;
 float3 viewDirection;
 float3 viewNormal; // For MatCap sampling
};

// KHR_texture_transform: apply static scale, rotation and offset to UV
// Must be applied BEFORE animateUV (transform is static; UV animation is dynamic on top)
static inline float2 applyTextureTransform(float2 uv, constant MToonMaterial& material) {
 float c = cos(material.textureTransformRotation);
 float s = sin(material.textureTransformRotation);
 float2 scaled = uv * float2(material.textureTransformScaleX, material.textureTransformScaleY);
 float2 rotated = float2(c * scaled.x - s * scaled.y, s * scaled.x + c * scaled.y);
 return rotated + float2(material.textureTransformOffsetX, material.textureTransformOffsetY);
}

// UV Animation utility function (rotation first, then scroll)
static inline float2 animateUV(float2 uv, constant MToonMaterial& material) {
 float2 result = uv;

 // UV rotation animation around center (0.5, 0.5) - FIRST
 if (material.uvAnimationRotationSpeedFactor != 0.0) {
 float angle = material.uvAnimationRotationSpeedFactor * material.time;
 float2 center = float2(0.5, 0.5);
 float2 translated = result - center;

 float cosAngle = cos(angle);
 float sinAngle = sin(angle);
 float2x2 rotationMatrix = float2x2(
     float2(cosAngle, -sinAngle),
     float2(sinAngle, cosAngle)
 );

 result = rotationMatrix * translated + center;
 }

 // UV scroll animation - SECOND
 result.x += material.uvAnimationScrollXSpeedFactor * material.time;
 result.y += material.uvAnimationScrollYSpeedFactor * material.time;

 return result;
}

// MatCap coordinate calculation
float2 calculateMatCapUV(float3 viewNormal) {
 // Convert view normal to UV coordinates for MatCap sampling
 return viewNormal.xy * 0.5 + 0.5;
}

static inline bool hasParametricRim(constant MToonMaterial& material) {
 return material.parametricRimColorR > 0.0 ||
        material.parametricRimColorG > 0.0 ||
        material.parametricRimColorB > 0.0;
}

static inline bool needsViewNormal(constant MToonMaterial& material, constant Uniforms& uniforms) {
 // Parametric rim no longer needs view-space normal (#226 — moved the
 // fresnel into world space to avoid the compound-matrix w-leak). MatCap
 // still samples in view space.
 return material.hasMatcapTexture > 0 || uniforms.debugUVs == 32;
}

static inline bool needsViewDirection(constant MToonMaterial& material, constant Uniforms& uniforms) {
 return hasParametricRim(material) || uniforms.debugUVs == 10;
}

// VRM 1.0 MToon spec uses linearstep for toon shading
// Creates sharp anime-style shadow boundaries (not smooth gradients)
static inline float linearstep(float a, float b, float t) {
 float range = b - a;
 // Guard against division by zero when toony=1.0 (range becomes 0)
 if (range <= 0.0001) {
     return t >= b ? 1.0 : 0.0;
 }
 return saturate((t - a) / range);
}

#if MTOON_USE_HALF_PRECISION
static inline half linearstep(half a, half b, half t) {
 half range = b - a;
 if (range <= 0.0001h) {
     return t >= b ? 1.0h : 0.0h;
 }
 return saturate((t - a) / range);
}
#endif

// Vertex shader with optional morphed positions buffer
// When morphs are active: morphed positions at buffer(20), original vertex at stage_in
// When no morphs: only original vertex at stage_in
vertex VertexOut mtoon_vertex(VertexIn in [[stage_in]],
                       constant Uniforms& uniforms [[buffer(1)]],
                       constant MToonMaterial& material [[buffer(8)]],
                       device const float3* morphedPositions [[buffer(20)]],
                       constant uint& hasMorphed [[buffer(22)]],
                       uint vertexID [[vertex_id]]) {
 VertexOut out;

 // Use morphed positions if available, otherwise use original
 float3 morphedPosition;
 // Use explicit flag to avoid relying on nullptr checks (Metal debug requires bound buffers)
 if (hasMorphed > 0) {
 // Positions from compute shader output
 morphedPosition = float3(morphedPositions[vertexID]);
 } else {
 // No morphs - use original position
 morphedPosition = in.position;
 }

 // Normals always from original (will add morphed normals in Phase B)
 float3 morphedNormal = normalize(in.normal);

 float4 worldPosition = uniforms.modelMatrix * float4(morphedPosition, 1.0);
 out.worldPosition = worldPosition.xyz;

 // Transform to clip space
 out.position = uniforms.projectionMatrix * uniforms.viewMatrix * worldPosition;

 // Transform normal to world space
 out.worldNormal = normalize((uniforms.normalMatrix * float4(morphedNormal, 0.0)).xyz);

 // KHR_texture_transform is a static affine on UVs (offset / rotation / scale).
 // The transform must apply to *every* texture lookup — base color, shading
 // shift, outline width multiplier, MToon's matcap and shade textures, etc. —
 // so we bake it into `texCoord` here in the vertex shader. Default uniforms
 // (offset=0, rotation=0, scale=1) make `applyTextureTransform` identity, so
 // assets without the extension are unaffected. UV animation composes on top
 // via `animatedTexCoord`. VMK#288.
 out.texCoord = applyTextureTransform(in.texCoord, material);
 out.animatedTexCoord = animateUV(out.texCoord, material);
 out.color = in.color;

 if (needsViewNormal(material, uniforms)) {
 // Transform normal to view space for MatCap/rim.
 out.viewNormal = normalize((uniforms.viewMatrix * uniforms.normalMatrix * float4(morphedNormal, 0.0)).xyz);
 } else {
 out.viewNormal = float3(0.0, 0.0, 1.0);
 }

 if (needsViewDirection(material, uniforms)) {
 // Calculate view direction - extract camera world position from view matrix
 // View matrix = [R | -R*t] where R is rotation, t is camera position
 // So cameraPos = -R^T * translation = -transpose(R) * viewMatrix[3].xyz
 float3x3 viewRotation = float3x3(uniforms.viewMatrix[0].xyz,
                                   uniforms.viewMatrix[1].xyz,
                                   uniforms.viewMatrix[2].xyz);
 float3 cameraPos = -(transpose(viewRotation) * uniforms.viewMatrix[3].xyz);
 out.viewDirection = normalize(cameraPos - out.worldPosition);
 } else {
 out.viewDirection = float3(0.0, 0.0, 1.0);
 }

 return out;
}

// Fragment shader with complete MToon 1.0 shading
// VERSION 2: Fixed white textures
fragment float4 mtoon_fragment_v2(VertexOut in [[stage_in]],
                        bool isFrontFace [[front_facing]],
                        constant MToonMaterial& material [[buffer(8)]],
                        constant Uniforms& uniforms [[buffer(1)]],
                        texture2d<float> baseColorTexture [[texture(0)]],
                        texture2d<float> shadeMultiplyTexture [[texture(1)]],
                        texture2d<float> shadingShiftTexture [[texture(2)]],
                        texture2d<float> normalTexture [[texture(3)]],
                        texture2d<float> emissiveTexture [[texture(4)]],
                        texture2d<float> matcapTexture [[texture(5)]],
                        texture2d<float> rimMultiplyTexture [[texture(6)]],
                        texture2d<float> uvAnimationMaskTexture [[texture(7)]],
                        sampler textureSampler [[sampler(0)]]) {

 // Debug modes are cold in production; keep the normal path to one branch.
 if (uniforms.debugUVs != 0) {
 if (uniforms.debugUVs == 1) {
 // UV debug - red/green gradient
 return float4(in.texCoord.x, in.texCoord.y, 0.0, 1.0);
 } else if (uniforms.debugUVs == 2) {
 // Show hasBaseColorTexture flag: red=0, green=1
 return float4(material.hasBaseColorTexture > 0 ? 0.0 : 1.0,
               material.hasBaseColorTexture > 0 ? 1.0 : 0.0, 0.0, 1.0);
 } else if (uniforms.debugUVs == 3) {
 // Show baseColorFactor directly
 return material.baseColorFactor;
 } else if (uniforms.debugUVs == 4) {
 // Show sampled texture RGB directly
 float4 texColor = baseColorTexture.sample(textureSampler, in.texCoord);
 return float4(texColor.rgb, 1.0);
 } else if (uniforms.debugUVs == 5) {
 // Show normal direction as color
 return float4(normalize(in.worldNormal) * 0.5 + 0.5, 1.0);
 } else if (uniforms.debugUVs == 6) {
 // Show light color
 return float4(uniforms.lightColor.xyz, 1.0);
 } else if (uniforms.debugUVs == 7) {
 // Show NdotL (diffuse lighting term)
 float3 normal = normalize(in.worldNormal);
 float NdotL = dot(normal, -uniforms.lightDirection.xyz);  // Negate for correct convention
 // Map from [-1,1] to [0,1] for visualization
 float mapped = NdotL * 0.5 + 0.5;
 return float4(mapped, mapped, mapped, 1.0);
 } else if (uniforms.debugUVs == 8) {
 // Show light direction
 return float4(uniforms.lightDirection.xyz * 0.5 + 0.5, 1.0);
 } else if (uniforms.debugUVs == 9) {
 // Show front/back face: RED = back face, GREEN = front face
 return float4(isFrontFace ? 0.0 : 1.0, isFrontFace ? 1.0 : 0.0, 0.0, 1.0);
 } else if (uniforms.debugUVs == 10) {
 // Show view direction (should point from vertex toward camera)
 return float4(normalize(in.viewDirection) * 0.5 + 0.5, 1.0);
 } else if (uniforms.debugUVs == 12) {
 // Show raw base color (texture * factor, no lighting) - debug black triangles
 float4 debugBaseColor = material.baseColorFactor;
 if (material.hasBaseColorTexture > 0) {
     debugBaseColor *= baseColorTexture.sample(textureSampler, in.texCoord);
 }
 return float4(debugBaseColor.rgb, 1.0);
 } else if (uniforms.debugUVs == 13) {
 // Show vertex color only
 return float4(in.color.rgb, 1.0);
 } else if (uniforms.debugUVs == 14) {
 // Debug mode 14: Output shadowStep as grayscale for sunburn diagnosis
 float3 normal = normalize(in.worldNormal);
 float rawNdotL = dot(normal, -uniforms.lightDirection.xyz);
 float NdotL = (uniforms.vrmVersion == 1) ? rawNdotL : rawNdotL * 0.5 + 0.5;
 float shadingShift = material.shadingShiftFactor;
 float toony = material.shadingToonyFactor;
 float shading = NdotL + shadingShift;
 float shadowStep = linearstep(-1.0 + toony, 1.0 - toony, shading);
 return float4(shadowStep, shadowStep, shadowStep, 1.0);
 } else if (uniforms.debugUVs == 24) {
// Debug mode 24: Show alpha mode (RED=OPAQUE, GREEN=MASK, BLUE=BLEND)
if (material.alphaMode == 0) return float4(1.0, 0.0, 0.0, 1.0);
if (material.alphaMode == 1) return float4(0.0, 1.0, 0.0, 1.0);
return float4(0.0, 0.0, 1.0, 1.0);
 } else if (uniforms.debugUVs == 25) {
// Debug mode 25: Raw texture RGBA channels: R=texR, G=texG, B=texAlpha (with MASK discard)
float4 texSample = float4(1.0);
if (material.hasBaseColorTexture > 0) {
    texSample = baseColorTexture.sample(textureSampler, in.texCoord);
}
float4 dbgBase25 = material.baseColorFactor * texSample;
if (material.alphaMode == 1 && dbgBase25.a < material.alphaCutoff) {
    discard_fragment();
}
return float4(texSample.r, texSample.g, texSample.a, 1.0);
 } else if (uniforms.debugUVs == 26) {
// Debug mode 26: Texture alpha WITH MASK discard (grayscale)
float4 dbgBase26 = material.baseColorFactor;
if (material.hasBaseColorTexture > 0) {
    dbgBase26 *= baseColorTexture.sample(textureSampler, in.texCoord);
}
if (material.alphaMode == 1 && dbgBase26.a < material.alphaCutoff) {
    discard_fragment();
}
return float4(dbgBase26.a, dbgBase26.a, dbgBase26.a, 1.0);
 } else if (uniforms.debugUVs == 27) {
// Debug mode 27: Shade color factor (identifies material by unique shade color)
float4 dbgBase27 = material.baseColorFactor;
if (material.hasBaseColorTexture > 0) {
    dbgBase27 *= baseColorTexture.sample(textureSampler, in.texCoord);
}
if (material.alphaMode == 1 && dbgBase27.a < material.alphaCutoff) {
    discard_fragment();
}
return float4(material.shadeColorR, material.shadeColorG, material.shadeColorB, 1.0);
 } else if (uniforms.debugUVs == 28) {
// Debug mode 28: Alpha mode with correct discard (RED=OPAQUE, GREEN=MASK, BLUE=BLEND)
float4 dbgBase28 = material.baseColorFactor;
if (material.hasBaseColorTexture > 0) {
    dbgBase28 *= baseColorTexture.sample(textureSampler, in.texCoord);
}
if (material.alphaMode == 1 && dbgBase28.a < material.alphaCutoff) {
    discard_fragment();
}
if (material.alphaMode == 0) return float4(1.0, 0.0, 0.0, 1.0);
if (material.alphaMode == 1) return float4(0.0, 1.0, 0.0, 1.0);
return float4(0.0, 0.0, 1.0, 1.0);
 } else if (uniforms.debugUVs == 30) {
// Debug 30: Base color texture RGB after MASK discard (no lighting)
float4 dbgBase30 = material.baseColorFactor;
if (material.hasBaseColorTexture > 0) {
    dbgBase30 *= baseColorTexture.sample(textureSampler, in.texCoord);
}
if (material.alphaMode == 1 && dbgBase30.a < material.alphaCutoff) {
    discard_fragment();
}
return float4(dbgBase30.rgb, 1.0);
 } else if (uniforms.debugUVs == 31) {
// Debug 31: Raw shade texture sample after MASK discard
float4 dbgBase31 = material.baseColorFactor;
if (material.hasBaseColorTexture > 0) {
    dbgBase31 *= baseColorTexture.sample(textureSampler, in.texCoord);
}
if (material.alphaMode == 1 && dbgBase31.a < material.alphaCutoff) {
    discard_fragment();
}
if (material.hasShadeMultiplyTexture > 0) {
    return float4(shadeMultiplyTexture.sample(textureSampler, in.texCoord).rgb, 1.0);
}
return float4(0.5, 0.5, 0.5, 1.0); // Gray = no shade texture
 } else if (uniforms.debugUVs == 33) {
// Debug 33: Shade color value (shadeColorR/G/B from material)
float3 sc = float3(material.shadeColorR, material.shadeColorG, material.shadeColorB);
return float4(sc, 1.0);
 } else if (uniforms.debugUVs == 34) {
// Debug 34: Show hasShadeMultiplyTexture (RED=has texture, BLACK=no texture)
if (material.hasShadeMultiplyTexture > 0) {
    return float4(1.0, 0.0, 0.0, 1.0);  // RED = has shade texture
} else {
    return float4(0.0, 0.0, 0.0, 1.0);  // BLACK = no shade texture
}
 } else if (uniforms.debugUVs == 32) {
// Debug 32: Matcap contribution after MASK discard
float4 dbgBase32 = material.baseColorFactor;
if (material.hasBaseColorTexture > 0) {
    dbgBase32 *= baseColorTexture.sample(textureSampler, in.texCoord);
}
if (material.alphaMode == 1 && dbgBase32.a < material.alphaCutoff) {
    discard_fragment();
}
if (material.hasMatcapTexture > 0) {
    float3 vn = normalize(in.viewNormal);
    float2 mcUV = vn.xy * 0.5 + 0.5;
    return float4(matcapTexture.sample(textureSampler, mcUV).rgb, 1.0);
}
return float4(0.0, 0.0, 0.0, 1.0); // Black = no matcap
 } else if (uniforms.debugUVs == 15) {
 // Debug mode 15: Visualize lightingFactor (the lit/shadow interpolation)
 // WHITE = fully lit (baseColor), BLACK = fully shadow (shadeColor)
 // This is identical to mode 14 but named for clarity in sunburn diagnosis
 float3 normal = normalize(in.worldNormal);
 float rawNdotL = dot(normal, -uniforms.lightDirection.xyz);
 float NdotL = (uniforms.vrmVersion == 1) ? rawNdotL : rawNdotL * 0.5 + 0.5;
 float shadingShift = material.shadingShiftFactor;
 float toony = material.shadingToonyFactor;
 float shading = NdotL + shadingShift;
 // VRM 0.x params are already converted to VRM 1.0 space by toMToonMaterial()
 float lightingFactor = linearstep(-1.0 + toony, 1.0 - toony, shading);
 return float4(lightingFactor, lightingFactor, lightingFactor, 1.0);
 } else if (uniforms.debugUVs == 16) {
 // Debug mode 16: Show raw NdotL as color
 // GREEN = positive NdotL (lit), RED = negative NdotL (shadow)
 // Intensity shows magnitude
 float3 normal = normalize(in.worldNormal);
 float NdotL = dot(normal, -uniforms.lightDirection.xyz);  // Negate for correct convention
 if (NdotL >= 0.0) {
     return float4(0.0, NdotL, 0.0, 1.0);  // Green = positive (correct for front-lit)
 } else {
     return float4(-NdotL, 0.0, 0.0, 1.0); // Red = negative (WRONG for front-lit)
 }
 }
 }

 // Choose UV coordinates (animated or static)
 float2 uv = in.texCoord;
 
 // Apply UV offset for face overlay materials (e.g., mouth -> shift to lip texture area)
 if (material.uvOffsetX != 0.0 || material.uvOffsetY != 0.0 || material.uvScale != 1.0) {
     uv = uv * material.uvScale + float2(material.uvOffsetX, material.uvOffsetY);
 }
 
 if (material.hasUvAnimationMaskTexture > 0) {
 float animationMask = uvAnimationMaskTexture.sample(textureSampler, in.texCoord).r;
 uv = mix(in.texCoord, in.animatedTexCoord, animationMask);
 } else if (material.uvAnimationScrollXSpeedFactor != 0.0 ||
        material.uvAnimationScrollYSpeedFactor != 0.0 ||
        material.uvAnimationRotationSpeedFactor != 0.0) {
 uv = in.animatedTexCoord;
 }

 // Sample base color
 mtoon_float4 baseColor = mtoon_float4(material.baseColorFactor);
 if (material.hasBaseColorTexture > 0) {
     mtoon_float4 texColor = mtoon_float4(baseColorTexture.sample(textureSampler, uv));

 #if 0  // DEBUG: Output raw texture value (before material factor multiplication) - DISABLED
 return float4(texColor.rgb, 1.0);
 #endif

     baseColor *= texColor;
 }

 // Force full opacity for OPAQUE mode materials
 // This fixes materials that were converted from MASK to OPAQUE
 if (material.alphaMode == 0) {
     baseColor.a = 1.0;
 }

 // Alpha test for MASK mode - do this early before expensive lighting calculations
 // We copy to an explicit float to guarantee single-precision comparison for crisp cutout edges
 float alphaVal = float(baseColor.a);
 if (material.alphaMode == 1 && alphaVal < material.alphaCutoff) {
     discard_fragment();
 }

 // Calculate shade color
 mtoon_float3 shadeColor = mtoon_float3(material.shadeColorR, material.shadeColorG, material.shadeColorB);
 if (material.hasShadeMultiplyTexture > 0) {
     mtoon_float3 shadeTexColor = mtoon_float3(shadeMultiplyTexture.sample(textureSampler, uv).rgb);
     shadeColor *= shadeTexColor;
 }
 // Note: When _ShadeTexture == _MainTex (VRM 0.0), we skip shadeMultiplyTexture
 // assignment in VRMTypes.swift. shadeColor uses shadeColorFactor directly.

 mtoon_float3 normal = mtoon_float3(normalize(in.worldNormal));
 mtoon_float3 viewNormal = mtoon_float3(in.viewNormal);

 bool normalWasFlipped = false;
 if (!isFrontFace) {
     normal = -normal;
     viewNormal = -viewNormal;
     normalWasFlipped = true;
 }

 if (material.hasNormalTexture > 0) {
     // Tangent-space normal map. Models without baked TANGENT vertex attributes
     // (which is most VRM 1.0 content — see validator
     // MESH_PRIMITIVE_GENERATED_TANGENT_SPACE) require synthesizing a TBN basis.
     // Christian Schüler's screen-space-derivative TBN (2010) builds the basis
     // per-fragment from worldPos and uv derivatives — no per-vertex tangents.
     mtoon_float3 nMap = mtoon_float3(normalTexture.sample(textureSampler, uv).xyz * 2.0 - 1.0);
     // glTF 2.0 normalTextureInfo.scale — `scaledNormal = normalize((sample
     // * 2.0 - 1.0) * vec3(scale, scale, 1.0))`. Defaults to 1.0 so existing
     // assets without an authored `scale` field are unaffected. VMK#290.
     nMap.xy *= mtoon_float(material.normalScale);
     nMap = mtoon_float3(normalize(float3(nMap)));

     float3 dp1 = dfdx(in.worldPosition);
     float3 dp2 = dfdy(in.worldPosition);
     float2 duv1 = dfdx(uv);
     float2 duv2 = dfdy(uv);

     float3 dp2perp = cross(dp2, float3(normal));
     float3 dp1perp = cross(float3(normal), dp1);
     float3 T = dp2perp * duv1.x + dp1perp * duv2.x;
     float3 B = dp2perp * duv1.y + dp1perp * duv2.y;

     float invmax = rsqrt(max(dot(T, T), dot(B, B)));
     float3x3 TBN = float3x3(T * invmax, B * invmax, float3(normal));

     normal = mtoon_float3(normalize(TBN * float3(nMap)));
 }

 // DEBUG: Show magenta where normal was flipped (enable with debugUVs=11)
 if (uniforms.debugUVs == 11 && normalWasFlipped) {
     return float4(1.0, 0.0, 1.0, 1.0);  // Magenta for flipped normals
 }

 // Shading shift calculation
 mtoon_float shadingShift = mtoon_float(material.shadingShiftFactor);
 if (material.hasShadingShiftTexture > 0) {
     mtoon_float shiftTexValue = mtoon_float(shadingShiftTexture.sample(textureSampler, uv).r);
     shadingShift += (shiftTexValue - 0.5) * mtoon_float(material.shadingShiftTextureScale);
 }

 // MToon toon shading with energy-conserving 3-point lighting
 mtoon_float toony = mtoon_float(material.shadingToonyFactor);

 // Use pre-calculated intensities from CPU (stored in lightColor.w)
 constexpr mtoon_float MIN_TOTAL_INTENSITY = 0.001;
 mtoon_float intensity0 = mtoon_float(uniforms.lightColor.w);
 mtoon_float intensity1 = mtoon_float(uniforms.light1Color.w);
 mtoon_float intensity2 = mtoon_float(uniforms.light2Color.w);
 mtoon_float totalIntensity = max(intensity0 + intensity1 + intensity2, MIN_TOTAL_INTENSITY);

 // Calculate weighted light contributions with version-aware shading formula.
 // VRM 1.0 (vrm-conformance #213): raw dot(N,L) in [-1,1] + linearstep,
 // matching the MToon 1.0 spec and three-vrm's implementation.
 // VRM 0.x: Half-Lambert remap (`NdotL * 0.5 + 0.5`) preserves the look of
 // legacy assets whose `shadingShiftFactor` was authored for [0,1] input.
 // `lighting{i}` is the pre-albedo radiance term captured alongside `lit{i}`
 // so the rim modulator can multiply by `directLight + indirectLight` per
 // MToon-1.0 (vrm-conformance #228, matches UniVRM's `directLightingFactor`).
 mtoon_float3 lit0 = mtoon_float3(0.0);
 mtoon_float3 lighting0 = mtoon_float3(0.0);
 if (intensity0 > 0.0) {
     // Light direction convention: negate because uniforms stores direction FROM light,
     // but NdotL calculation needs direction TO light.
     // VRM 1.0 uses raw dot(N,L) (spec); VRM 0.x uses Half-Lambert remap.
     mtoon_float rawNdotL = dot(normal, mtoon_float3(-uniforms.lightDirection.xyz));
     mtoon_float NdotL = (uniforms.vrmVersion == 1) ? rawNdotL : rawNdotL * 0.5 + 0.5;
     mtoon_float shading0 = NdotL + shadingShift;
     mtoon_float shadowStep = linearstep(mtoon_float(-1.0) + toony, mtoon_float(1.0) - toony, shading0);
     mtoon_float weight = intensity0 / totalIntensity;
     float3 safeLightColor = clamp(uniforms.lightColor.xyz, 0.0f, 65500.0f);
     lit0 = mix(shadeColor, baseColor.rgb, shadowStep) * mtoon_float3(safeLightColor) * weight;
     lighting0 = shadowStep * weight * mtoon_float3(safeLightColor);
 }

 mtoon_float3 lit1 = mtoon_float3(0.0);
 mtoon_float3 lighting1 = mtoon_float3(0.0);
 if (intensity1 > 0.0) {
     mtoon_float rawNdotL1 = dot(normal, mtoon_float3(-uniforms.light1Direction.xyz));
     mtoon_float NdotL1 = (uniforms.vrmVersion == 1) ? rawNdotL1 : rawNdotL1 * 0.5 + 0.5;
     mtoon_float shading1 = NdotL1 + shadingShift;
     mtoon_float shadowStep1 = linearstep(mtoon_float(-1.0) + toony, mtoon_float(1.0) - toony, shading1);
     mtoon_float weight1 = intensity1 / totalIntensity;
     float3 safeLight1Color = clamp(uniforms.light1Color.xyz, 0.0f, 65500.0f);
     lit1 = mix(shadeColor, baseColor.rgb, shadowStep1) * mtoon_float3(safeLight1Color) * weight1;
     lighting1 = shadowStep1 * weight1 * mtoon_float3(safeLight1Color);
 }

 mtoon_float3 lit2 = mtoon_float3(0.0);
 mtoon_float3 lighting2 = mtoon_float3(0.0);
 if (intensity2 > 0.0) {
     mtoon_float rawNdotL2 = dot(normal, mtoon_float3(-uniforms.light2Direction.xyz));
     mtoon_float NdotL2 = (uniforms.vrmVersion == 1) ? rawNdotL2 : rawNdotL2 * 0.5 + 0.5;
     mtoon_float shading2 = NdotL2 + shadingShift;
     mtoon_float shadowStep2 = linearstep(mtoon_float(-1.0) + toony, mtoon_float(1.0) - toony, shading2);
     mtoon_float weight2 = intensity2 / totalIntensity;
     float3 safeLight2Color = clamp(uniforms.light2Color.xyz, 0.0f, 65500.0f);
     lit2 = mix(shadeColor, baseColor.rgb, shadowStep2) * mtoon_float3(safeLight2Color) * weight2;
     lighting2 = shadowStep2 * weight2 * mtoon_float3(safeLight2Color);
 }

 // Accumulate weighted contributions (manual normalization factor allows artistic control).
 // Direct lighting uses BRDF_LAMBERT_NORM (1/π) to match three-vrm's
 // `BRDF_Lambert` + UniVRM's Built-in RP convention. Without it,
 // `mix(shade, base, shadowStep) * lightColor` reaches unit albedo at the
 // brightest point and ambient stacks on top, clamping to 1.0 across the
 // visible hemisphere and collapsing the soft Lambert gradient at low
 // `shadingToonyFactor` (vrm-conformance #205). `setLightNormalizationMode(.manual(f))`
 // multiplies on top — `.manual(1.0)` is now ~1/π × the pre-#205 brightness.
 mtoon_float3 litColor = (lit0 + lit1 + lit2) * mtoon_float(uniforms.lightNormalizationFactor) * mtoon_float(BRDF_LAMBERT_NORM);

 // Aggregate pre-albedo radiance for the rim modulator. No /π — UniVRM's
 // `directLightingFactor` doesn't apply the Lambert BRDF normalization to
 // the rim path (rim is a stylistic edge highlight, not a diffuse BRDF).
 mtoon_float3 directLight = (lighting0 + lighting1 + lighting2) * mtoon_float(uniforms.lightNormalizationFactor);

 // Indirect diffuse — KNOWN DEVIATION FROM MToon 1.0 SPEC.
 //
 // The spec defines giEqualizationFactor as a lerp between rawGi(normal)
 // and uniformedGi (the directional vs uniform indirect-illumination mix);
 // see docs/MTOON_GI_SPEC.md for the verbatim spec excerpt. A spec-correct
 // implementation requires IBL/SH infrastructure that this renderer does
 // not yet have.
 //
 // Without IBL, the spec lerp degenerates to a no-op (rawGi(n) ≡ uniformedGi
 // ≡ ambient). Rather than ship the no-op, we reinterpret the factor as a
 // lit-side / shade-side mix on the indirect *albedo*: at 1.0 indirect uses
 // baseColor, at 0.0 it uses shadeColor. This gives authors a visually
 // meaningful artistic knob today. When IBL lands, replace this block with
 // the spec lerp and remove this comment.
 // Indirect / emissive / matcap / rim are NOT scaled by BRDF_LAMBERT_NORM.
 // The /π normalization above applies only to the direct Lambert BRDF term;
 // these are additive stylistic contributions in MToon (and in the reference
 // three-vrm + UniVRM paths). Note: post-#205, indirect (≈ambient*giAlbedo)
 // is now comparable in magnitude to direct (≈albedo/π) on the lit side —
 // see docs/MTOON_GI_SPEC.md for the rationale.
 mtoon_float3 giAlbedo = mix(shadeColor, baseColor.rgb, mtoon_float(material.giEqualizationFactor));
 float3 safeAmbientColor = clamp(uniforms.ambientColor.xyz, 0.0f, 65500.0f);
 mtoon_float3 indirectDiffuse = mtoon_float3(safeAmbientColor) * giAlbedo;
 litColor += indirectDiffuse;

 // Indirect radiance for the rim modulator: raw ambient (no `giAlbedo`).
 // Rim is not subject to the body's giEqualization mix; it just sees the
 // scene's indirect radiance, mirroring UniVRM's `indirectLightingFactor`.
 mtoon_float3 indirectLight = mtoon_float3(safeAmbientColor);

 // Emissive
 mtoon_float3 emissive = mtoon_float3(material.emissiveR, material.emissiveG, material.emissiveB);
 if (material.hasEmissiveTexture > 0) {
     mtoon_float3 emissiveTexColor = mtoon_float3(emissiveTexture.sample(textureSampler, uv).rgb);
     emissive *= emissiveTexColor;
 }
 litColor += emissive;

 // MatCap (use flipped viewNormal for back faces)
 if (material.hasMatcapTexture > 0) {
     mtoon_float2 matcapUV = mtoon_float2(calculateMatCapUV(float3(viewNormal)));
     mtoon_float3 matcapColor = mtoon_float3(matcapTexture.sample(textureSampler, float2(matcapUV)).rgb);
     litColor += matcapColor * mtoon_float3(material.matcapR, material.matcapG, material.matcapB);
 }

 // Parametric rim lighting — fresnel computed in world space per MToon-1.0
 // spec (matches three-vrm + UniVRM Built-in RP). The previous view-space
 // implementation went through `viewMatrix * normalMatrix * float4(N, 0)`,
 // which carries a w-component leak: `normalMatrix = inverse(modelMatrix).transpose`
 // for a translated model has non-zero w entries in its rotation columns, so
 // the intermediate `normalMatrix * float4(N, 0)` returns a vec4 with non-zero
 // w, and `viewMatrix * …` then multiplies that w against viewMatrix's
 // translation column — corrupting xyz. The bug bit any realistic camera +
 // model translation combination; it was asymptomatic for tests at the origin
 // with identity view matrix, which is why VMK's own tests passed while the
 // conformance corpus rendered rim only at one specific normal direction
 // (vrm-conformance #226). `worldNormal` is the correctly-computed normal
 // from the vertex shader (single matrix multiply with explicit `.xyz`
 // extraction); `viewDirection` is already world-space. This block mirrors
 // the `additiveDirectionalRim` path's coordinate-space handling below.
 mtoon_float3 rimColor = mtoon_float3(0.0);
 mtoon_float3 parametricRimColorFactor = mtoon_float3(material.parametricRimColorR, material.parametricRimColorG, material.parametricRimColorB);
 if (any(parametricRimColorFactor > 0.0)) {
     float3 Nrim = normalize(in.worldNormal);
     if (!isFrontFace) Nrim = -Nrim;
     float3 Vrim = normalize(in.viewDirection);
     float NdotV = saturate(dot(Nrim, Vrim));
     float vf = 1.0f - NdotV;
     // Compute rimF in single-precision float to protect against FP16 underflow/subnormal precision issues near 1e-4.
     float rimF = pow(saturate(vf + material.parametricRimLiftFactor),
                      max(material.parametricRimFresnelPowerFactor, 1e-4f));

     rimColor = parametricRimColorFactor * mtoon_float(rimF);

     // Apply rim multiply texture for masking
     if (material.hasRimMultiplyTexture > 0) {
         mtoon_float rimMask = saturate(mtoon_float(rimMultiplyTexture.sample(textureSampler, uv).r));
         rimColor *= rimMask;
     }
 }

 // Apply rim lighting per MToon-1.0 spec — matches UniVRM and three-vrm:
 // at `rimLightingMixFactor`=0 rim is unaffected by scene light (unlit), at
 // 1.0 rim is modulated by direct+indirect radiance (lit) (vrm-conformance #228).
 if (any(rimColor > 0.0)) {
     mtoon_float3 rimLightingFactor = mix(mtoon_float3(1.0),
                                     directLight + indirectLight,
                                     saturate(mtoon_float(material.rimLightingMixFactor)));
 litColor += rimColor * rimLightingFactor;
 }

 // Additive directional rim — opt-in via uniforms.additiveDirectionalRimEnabled.
 // Computes `pow(1 - N·V, power) * max(0, N·L) * lightColor * intensity` for
 // each enabled scene light and adds the result on top of litColor, completely
 // independent of base albedo. Lets a fully crushed (base = 0) material still
 // show a warm directional edge — silhouette + rim aesthetic.
 if (uniforms.additiveDirectionalRimEnabled > 0.5) {
     mtoon_float3 Nworld = mtoon_float3(normalize(in.worldNormal));
     if (!isFrontFace) Nworld = -Nworld;
     mtoon_float3 Vworld = mtoon_float3(normalize(in.viewDirection));
     mtoon_float NdotV_world = saturate(dot(Nworld, Vworld));
     mtoon_float fresnel = pow(saturate(mtoon_float(1.0) - NdotV_world),
                          max(mtoon_float(uniforms.additiveDirectionalRimPower), mtoon_float(0.0001)));

     mtoon_float3 dirRim = mtoon_float3(0.0);
     if (intensity0 > 0.0) {
         mtoon_float NdotL = saturate(dot(Nworld, mtoon_float3(-uniforms.lightDirection.xyz)));
         dirRim += fresnel * NdotL * mtoon_float3(uniforms.lightColor.xyz) * intensity0;
     }
     if (intensity1 > 0.0) {
         mtoon_float NdotL = saturate(dot(Nworld, mtoon_float3(-uniforms.light1Direction.xyz)));
         dirRim += fresnel * NdotL * mtoon_float3(uniforms.light1Color.xyz) * intensity1;
     }
     if (intensity2 > 0.0) {
         mtoon_float NdotL = saturate(dot(Nworld, mtoon_float3(-uniforms.light2Direction.xyz)));
         dirRim += fresnel * NdotL * mtoon_float3(uniforms.light2Color.xyz) * intensity2;
     }
     litColor += dirRim;
 }

 // DEBUG 35: Final lit color before gamma/sRGB conversion
 if (uniforms.debugUVs == 35) {
     return float4(float3(litColor), 1.0);
 }

 #if 1  // ENABLED: Full MToon lighting for all materials (textured and non-textured)
 // Debug mode 9: Show litColor before saturation (scaled down to see overbright)
 if (uniforms.debugUVs == 9) {
     return float4(float3(litColor * 0.25), 1.0);  // Scale by 0.25 to see values > 1
 }

 // Minimum light floor to prevent completely black surfaces
 // This handles edge cases where NdotL is negative for all lights and ambient is zero
 mtoon_float3 minLight = baseColor.rgb * mtoon_float(0.08);  // 8% of base color as minimum
 litColor = max(litColor, minLight);

 // Final color output
 litColor = saturate(litColor);

 #if 0  // DEBUG: Output unlit baseColor to diagnose clipping (DISABLED - using raw texture debug instead)
 return float4(float3(baseColor.rgb) * 0.5, float(baseColor.a));
 #endif

 #if 0  // DEBUG: Visualize vertex attributes
 // Show joint indices and weights to verify skinning data
 return float4(float(in.joints[0]) / 255.0, in.weights[0], 0.0, 1.0);
 #endif

 // Use the alpha from baseColor which has been corrected for OPAQUE mode
 return float4(float3(litColor), float(baseColor.a));
 #endif
}

// Outline vertex shader with advanced features
vertex VertexOut mtoon_outline_vertex(VertexIn in [[stage_in]],
                               constant Uniforms& uniforms [[buffer(1)]],
                               constant MToonMaterial& material [[buffer(8)]],
                               texture2d<float> outlineWidthMultiplyTexture [[texture(0)]],
                               sampler textureSampler [[sampler(0)]]) {
 VertexOut out;

 // Calculate outline width
 //
 // VRMC_materials_mtoon-1.0 §outlineWidthMultiplyTexture: "The G
 // component of the texture is referred to." Sampling .r here would
 // pull the wrong channel and produce per-vertex modulation that
 // doesn't match the spec / three-vrm / UniVRM. VMK#289.
 float outlineWidth = material.outlineWidthFactor;
 if (material.hasOutlineWidthMultiplyTexture > 0) {
 float widthMultiplier = outlineWidthMultiplyTexture.sample(textureSampler, in.texCoord).g;
 outlineWidth *= widthMultiplier;
 }

 // Pre-calculate world normal and camera position for edge attenuation
 float3 worldNormal = normalize((uniforms.normalMatrix * float4(in.normal, 0.0)).xyz);
 float3x3 viewRotation = float3x3(uniforms.viewMatrix[0].xyz,
                                   uniforms.viewMatrix[1].xyz,
                                   uniforms.viewMatrix[2].xyz);
 float3 cameraPos = -(transpose(viewRotation) * uniforms.viewMatrix[3].xyz);
 float3 worldPos = (uniforms.modelMatrix * float4(in.position, 1.0)).xyz;

 // Calculate view direction
 float3 viewDir = normalize(cameraPos - worldPos);

 // Calculate final position with outline extrusion
 if (material.outlineMode == 1.0) {
 // World coordinates mode - extrude in world space
 float distanceScale = length(worldPos - cameraPos) * 0.01;

 worldPos += worldNormal * outlineWidth * distanceScale;
 out.worldPosition = worldPos;
 out.position = uniforms.projectionMatrix * uniforms.viewMatrix * float4(worldPos, 1.0);

 } else if (material.outlineMode == 2.0) {
 // Screen coordinates mode - extrude in screen space
 float4 worldPos4 = uniforms.modelMatrix * float4(in.position, 1.0);
 out.worldPosition = worldPos4.xyz;

 // Transform to clip space
 float4 clipPos = uniforms.projectionMatrix * uniforms.viewMatrix * worldPos4;

 // Calculate screen-space normal
 float3 viewNormal = normalize((uniforms.viewMatrix * uniforms.normalMatrix * float4(in.normal, 0.0)).xyz);
 float2 screenNormal = normalize(viewNormal.xy);

 // Convert outline width from pixels to NDC
 float2 pixelsToNDC = 2.0 / uniforms.viewportSize.xy;
 float2 offsetNDC = screenNormal * outlineWidth * pixelsToNDC;

 // Apply screen-space offset, scaled by clip.w for perspective-correct width
 clipPos.xy += offsetNDC * clipPos.w;
 out.position = clipPos;

 } else {
 // No outline (mode 0)
 float4 worldPos4 = uniforms.modelMatrix * float4(in.position, 1.0);
 out.worldPosition = worldPos4.xyz;
 out.position = uniforms.projectionMatrix * uniforms.viewMatrix * worldPos4;
 }

 out.worldNormal = worldNormal;
 out.viewNormal = normalize((uniforms.viewMatrix * uniforms.normalMatrix * float4(in.normal, 0.0)).xyz);
 // Same KHR_texture_transform fix as the main vertex shader. See comment
 // at the equivalent site above. VMK#288.
 out.texCoord = applyTextureTransform(in.texCoord, material);
 out.animatedTexCoord = animateUV(out.texCoord, material);
 out.color = in.color;

 // View direction already calculated above for edge attenuation
 out.viewDirection = viewDir;

 return out;
}

// Advanced outline fragment shader
fragment float4 mtoon_outline_fragment([[maybe_unused]] VertexOut in [[stage_in]],
                                constant MToonMaterial& material [[buffer(8)]],
                                constant Uniforms& uniforms [[buffer(1)]]) {
 float3 outlineColor = float3(material.outlineColorR, material.outlineColorG, material.outlineColorB);

 // Apply outline lighting mix
 if (material.outlineLightingMixFactor < 1.0) {
 float3 lightInfluence = uniforms.lightColor.xyz * uniforms.ambientColor.xyz;
 outlineColor = mix(outlineColor * lightInfluence, outlineColor, material.outlineLightingMixFactor);
 }

 return float4(outlineColor, 1.0);
}

// Debug fragment shaders for visualizing individual MToon components
fragment float4 mtoon_debug_nl(VertexOut in [[stage_in]],
                        [[maybe_unused]] constant MToonMaterial& material [[buffer(8)]],
                        constant Uniforms& uniforms [[buffer(1)]]) {
 float3 normal = normalize(in.worldNormal);
 float nl = saturate(dot(normal, -uniforms.lightDirection.xyz));  // Negate for correct convention
 return float4(nl, nl, nl, 1.0);
}

fragment float4 mtoon_debug_ramp(VertexOut in [[stage_in]],
                          constant MToonMaterial& material [[buffer(8)]],
                          constant Uniforms& uniforms [[buffer(1)]],
                          texture2d<float> shadingShiftTexture [[texture(2)]],
                          sampler textureSampler [[sampler(0)]]) {
 float3 normal = normalize(in.worldNormal);
 float nl = saturate(dot(normal, -uniforms.lightDirection.xyz));  // Negate for correct convention

 float shadingShift = material.shadingShiftFactor;
 if (material.hasShadingShiftTexture > 0) {
 float shiftTexValue = shadingShiftTexture.sample(textureSampler, in.texCoord).r;
 shadingShift += (shiftTexValue - 0.5) * material.shadingShiftTextureScale;
 }

 float shading = nl + shadingShift;
 float ramp = linearstep(-1.0 + material.shadingToonyFactor, 1.0 - material.shadingToonyFactor, shading);
 return float4(ramp, ramp, ramp, 1.0);
}

fragment float4 mtoon_debug_rim(VertexOut in [[stage_in]],
                         constant MToonMaterial& material [[buffer(8)]],
                         constant Uniforms& uniforms [[buffer(1)]]) {
 float3 rimColorFactor = float3(material.parametricRimColorR, material.parametricRimColorG, material.parametricRimColorB);
 if (any(rimColorFactor <= 0.0)) {
 return float4(0, 0, 0, 1);
 }

 float3 Nv = in.viewNormal;
 float3 Vv = normalize(in.viewDirection);  // Correct: use vertex shader's viewDirection
 float3 viewDirViewSpace = normalize((uniforms.viewMatrix * float4(Vv, 0.0)).xyz);
 float NdotV = saturate(dot(Nv, viewDirViewSpace));
 float vf = 1.0 - NdotV;
 float rimF = pow(saturate(vf + material.parametricRimLiftFactor),
                  material.parametricRimFresnelPowerFactor);
 return float4(rimF, rimF, rimF, 1.0);
}

fragment float4 mtoon_debug_matcap_uv(VertexOut in [[stage_in]]) {
 float2 matcapUV = calculateMatCapUV(in.viewNormal);
 return float4(matcapUV.x, matcapUV.y, 0.0, 1.0);
}

fragment float4 mtoon_debug_outline_width([[maybe_unused]] VertexOut in [[stage_in]],
                                   constant MToonMaterial& material [[buffer(8)]]) {
 float width = material.outlineWidthFactor * 10.0; // Scale for visibility
 return float4(width, width, width, 1.0);
}
