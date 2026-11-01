//
// Copyright 2026 Arkavo
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

// Declarations shared by MToonShader.metal and SkinnedShader.metal: the
// uniform and material layouts both files bind, the interpolator they hand to
// the shared fragment shaders, and the outline hull extrusion. Keeping one copy
// is what stops the skinned path from reading a stale material layout.

#ifndef VRMMETALKIT_MTOON_SHARED_H
#define VRMMETALKIT_MTOON_SHARED_H

#include <metal_stdlib>
using namespace metal;

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
 float useDualQuaternionSkinning;  // #197: >0.5 = DQS, else LBS
 int toonBands;                // Number of cel-shading bands
 float additiveDirectionalRimEnabled;  // 0 = off (legacy), >0.5 = enable additive directional rim
 float additiveDirectionalRimPower;    // Fresnel exponent for the additive rim (typical 4..12)
 uint cameraMode;             // 0 = third-person, 1 = first-person
 // Materialization spawn effect (VMK#materialize)
 float4 materializeParams;    // x = progress (>=1 off), y = style, z = min Y, w = max Y (world)
 float4 materializeColor;     // xyz = accent color, w = per-avatar seed
 float4 materializeOrigin;    // xyz = world focus point (radial styles), w = reserved
};

// Scalar fields only (no float3) so the Metal layout matches Swift's
// `MToonMaterialUniforms` stride exactly: 17 blocks x 16 bytes = 272 bytes.
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
 float metallicFactor;                      // 4 bytes; 0 unless RendererConfig.enableMaterialFinish
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
 float mergedOutline;                       // 4 bytes: >0.5 = instanced hull in this draw

 // Block 7: 16 bytes - Outline properties part 1 (float + packed float3)
 float outlineWidthFactor;                  // 4 bytes
 float outlineColorR;                       // 4 bytes
 float outlineColorG;                       // 4 bytes
 float outlineColorB;                       // 4 bytes

 // Block 8: 16 bytes - Outline properties part 2
 float outlineLightingMixFactor;            // 4 bytes
 float outlineMode;                         // 4 bytes (0: None, 1: World, 2: Screen)
 int hasOutlineWidthMultiplyTexture;        // 4 bytes
 int shadeUsesBaseColor;                    // 4 bytes (non-zero = reuse baseColor sample for shade)

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

 // Block 14: 16 bytes - KHR_texture_transform scale Y + normalScale + occlusion (VMK#293)
 float textureTransformScaleY;             // 4 bytes
 float normalScale;                         // 4 bytes — glTF-core normalTextureInfo.scale (VMK#290)
 float occlusionStrength;                   // 4 bytes — glTF-core occlusionTextureInfo.strength (VMK#293)
 int hasOcclusionTexture;                  // 4 bytes — occlusion texture binding flag (VMK#293)

 // Block 15: 16 bytes - Opt-in surface extensions (RendererConfig)
 float hairHighlightStrength;               // 4 bytes; 0 = no hair band on this material
 float hairHighlightSharpness;              // 4 bytes; 1...64, higher = narrower band
 float ssaoStrength;                        // 4 bytes; 0 = no crease AO
 float _extensionPad0;                      // 4 bytes padding

 // Block 16: 16 bytes - Outline minimum-width guard band
 float outlineMinPixels;                    // 4 bytes; 0 = authored width only
 float _extensionPad1;                      // 4 bytes padding
 float _extensionPad2;                      // 4 bytes padding
 float _extensionPad3;                      // 4 bytes padding
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
 uint instanceId;   // 0 = shaded surface, 1 = inverted-hull outline
};

static inline bool hasParametricRim(constant MToonMaterial& material) {
 return material.parametricRimColorR > 0.0 ||
        material.parametricRimColorG > 0.0 ||
        material.parametricRimColorB > 0.0;
}

static inline bool needsViewNormal(constant MToonMaterial& material, constant Uniforms& uniforms) {
 // MatCap samples in view space; the rim debug fragment reads it too.
 return material.hasMatcapTexture > 0 || hasParametricRim(material) ||
        uniforms.debugUVs == 32;
}

static inline bool needsViewDirection(constant MToonMaterial& material, constant Uniforms& uniforms) {
 // Spawn styles that fresnel against V; dummy interpolator is (0,0,1).
 // Fragment terms that need V for every material compute it from the
 // camera position instead (see mat_viewDir in MToonShader.metal).
 return hasParametricRim(material) || uniforms.debugUVs == 10
     || (uniforms.materializeParams.y > 0.5 && uniforms.materializeParams.x < 1.0);
}

// Unit screen-space direction of a world normal, or zero when the normal is
// parallel to the view axis (its projection has no direction there).
static inline float2 outlineScreenNormal(float3 worldNormal, constant Uniforms& uniforms) {
 float2 candidate = (uniforms.viewMatrix * float4(worldNormal, 0.0)).xy;
 float len = length(candidate);
 return len > 1e-5 ? candidate / len : float2(0.0);
}

// Minimum-width guard band shared by every hull path. `clipPos` is the
// unextruded clip position. When the authored width projects thinner than
// `material.outlineMinPixels`, the vertex is extruded in screen space by the
// minimum instead and the function returns true; otherwise it returns false
// and the caller runs its authored-width extrusion unchanged. The minimum is
// scaled by the width mask, so texels masked to zero stay outline-free, and a
// zero authored width never gains a line.
//
// World mode is distance-compensated (`factor * distance * 0.01`), so its
// projected width does not depend on camera distance.
static inline bool applyMToonOutlineGuardBand(
    thread float4& clipPos,
    float3 worldPos,
    float3 worldNormal,
    float widthFactor,
    float widthMask,
    constant Uniforms& uniforms,
    constant MToonMaterial& material
) {
 float minPixels = material.outlineMinPixels;
 if (minPixels <= 0.0 || widthFactor <= 0.0) { return false; }
 float authoredPixels;
 if (material.outlineMode == 1.0) {
     float3x3 viewRotation = float3x3(uniforms.viewMatrix[0].xyz,
                                      uniforms.viewMatrix[1].xyz,
                                      uniforms.viewMatrix[2].xyz);
     float3 cameraPos = -(transpose(viewRotation) * uniforms.viewMatrix[3].xyz);
     float worldWidth = widthFactor * length(worldPos - cameraPos) * 0.01;
     // projectionMatrix[1][1] is cot(fovy/2) for a perspective camera and
     // 2/height for an orthographic one; clip.w is the view depth or 1.
     authoredPixels = worldWidth * abs(uniforms.projectionMatrix[1][1])
         * uniforms.viewportSize.y * 0.5 / max(abs(clipPos.w), 1e-4);
 } else if (material.outlineMode == 2.0) {
     authoredPixels = widthFactor;
 } else {
     return false;
 }
 if (authoredPixels >= minPixels) { return false; }
 float2 pixelsToNDC = 2.0 / uniforms.viewportSize.xy;
 clipPos.xy += outlineScreenNormal(worldNormal, uniforms)
     * (minPixels * widthMask) * pixelsToNDC * clipPos.w;
 return true;
}

// Inverted-hull extrusion used by the merged color+outline draw
// (instance_id == 1) on both the rigid and skinned paths, and by the skinned
// dedicated outline pass.
static inline void applyMToonOutlineExtrusion(
    thread float3& worldPos,
    thread float4& clipPos,
    float3 worldNormal,
    float2 texCoord,
    constant Uniforms& uniforms,
    constant MToonMaterial& material,
    texture2d<float> outlineWidthMultiplyTexture,
    sampler textureSampler,
    bool hasMultiplyTexture
) {
 // VRMC_materials_mtoon-1.0 §outlineWidthMultiplyTexture: G channel.
 float widthMask = 1.0;
 if (hasMultiplyTexture) {
 widthMask = outlineWidthMultiplyTexture.sample(textureSampler, texCoord).g;
 }
 if (applyMToonOutlineGuardBand(clipPos, worldPos, worldNormal,
                                material.outlineWidthFactor, widthMask,
                                uniforms, material)) {
 return;
 }
 float outlineWidth = material.outlineWidthFactor * widthMask;
 float3x3 viewRotation = float3x3(uniforms.viewMatrix[0].xyz,
                                   uniforms.viewMatrix[1].xyz,
                                   uniforms.viewMatrix[2].xyz);
 float3 cameraPos = -(transpose(viewRotation) * uniforms.viewMatrix[3].xyz);
 if (material.outlineMode == 1.0) {
 float distanceScale = length(worldPos - cameraPos) * 0.01;
 worldPos += normalize(worldNormal) * outlineWidth * distanceScale;
 clipPos = uniforms.projectionMatrix * uniforms.viewMatrix * float4(worldPos, 1.0);
 } else if (material.outlineMode == 2.0) {
 float3 viewNormal = normalize((uniforms.viewMatrix * float4(worldNormal, 0.0)).xyz);
 float2 screenNormal = normalize(viewNormal.xy);
 float2 pixelsToNDC = 2.0 / uniforms.viewportSize.xy;
 clipPos.xy += screenNormal * outlineWidth * pixelsToNDC * clipPos.w;
 }
}

#endif
