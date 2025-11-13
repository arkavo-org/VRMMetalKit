#include <metal_stdlib>
using namespace metal;

struct Uniforms {
 float4x4 modelMatrix;
 float4x4 viewMatrix;
 float4x4 projectionMatrix;
 float4x4 normalMatrix;
 float3 lightDirection;
 float3 lightColor;
 float3 ambientColor;
 float2 viewportSize;          // For screen-space outline calculation
 float nearPlane;              // Camera near plane
 float farPlane;               // Camera far plane
 int debugUVs;                 // Debug flag: 1 = show UVs as colors, 0 = normal rendering
 float _padding1;              // Align to 16 bytes
 float _padding2;
 float _padding3;
};

struct MToonMaterial {
 // Block 0: 16 bytes - Base material properties
 float4 baseColorFactor;                    // 16 bytes

 // Block 1: 16 bytes - Shade and basic factors
 float3 shadeColorFactor;                   // 12 bytes
 float shadingToonyFactor;                  // 4 bytes

 // Block 2: 16 bytes - Material factors
 float shadingShiftFactor;                  // 4 bytes
 float3 emissiveFactor;                     // 12 bytes

 // Block 3: 16 bytes - PBR factors
 float metallicFactor;                      // 4 bytes
 float roughnessFactor;                     // 4 bytes
 float giIntensityFactor;                   // 4 bytes
 float shadingShiftTextureScale;            // 4 bytes

 // Block 4: 16 bytes - MatCap properties
 float3 matcapFactor;                       // 12 bytes
 int hasMatcapTexture;                      // 4 bytes

 // Block 5: 16 bytes - Rim lighting part 1
 float3 parametricRimColorFactor;           // 12 bytes
 float parametricRimFresnelPowerFactor;     // 4 bytes

 // Block 6: 16 bytes - Rim lighting part 2
 float parametricRimLiftFactor;             // 4 bytes
 float rimLightingMixFactor;                // 4 bytes
 int hasRimMultiplyTexture;                 // 4 bytes
 float _padding1;                           // 4 bytes padding

 // Block 7: 16 bytes - Outline properties part 1
 float outlineWidthFactor;                  // 4 bytes
 float3 outlineColorFactor;                 // 12 bytes

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

// Vertex shader with optional morphed positions buffer
// When morphs are active: morphed positions at buffer(20), original vertex at stage_in
// When no morphs: only original vertex at stage_in
vertex VertexOut mtoon_vertex(VertexIn in [[stage_in]],
                       constant Uniforms& uniforms [[buffer(1)]],
                       constant MToonMaterial& material [[buffer(8)]],
                       device float3* morphedPositions [[buffer(20)]],
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

 // Transform normal to view space for MatCap
 out.viewNormal = normalize((uniforms.viewMatrix * uniforms.normalMatrix * float4(morphedNormal, 0.0)).xyz);

 out.texCoord = in.texCoord;
 out.animatedTexCoord = animateUV(in.texCoord, material);
 out.color = in.color;

 // Calculate view direction
 float3 cameraPos = -uniforms.viewMatrix[3].xyz;
 out.viewDirection = normalize(cameraPos - out.worldPosition);

 return out;
}

// Fragment shader with complete MToon 1.0 shading
// VERSION 2: Fixed white textures
fragment float4 mtoon_fragment_v2(VertexOut in [[stage_in]],
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

 // 🎯 UV DEBUG MODE: DISABLED IN PRODUCTION
 // CRITICAL: This debug code is completely disabled to prevent UV color output
 /*
 if (uniforms.debugUVs > 0) {
 return float4(in.texCoord.x, in.texCoord.y, 0.0, 1.0);
 }
 */

 // Choose UV coordinates (animated or static)
 float2 uv = in.texCoord;
 if (material.hasUvAnimationMaskTexture > 0) {
 float animationMask = uvAnimationMaskTexture.sample(textureSampler, in.texCoord).r;
 uv = mix(in.texCoord, in.animatedTexCoord, animationMask);
 } else if (material.uvAnimationScrollXSpeedFactor != 0.0 ||
        material.uvAnimationScrollYSpeedFactor != 0.0 ||
        material.uvAnimationRotationSpeedFactor != 0.0) {
 uv = in.animatedTexCoord;
 }

 // Sample base color
 float4 baseColor = material.baseColorFactor;
 if (material.hasBaseColorTexture > 0) {
 float4 texColor = baseColorTexture.sample(textureSampler, uv);
 baseColor *= texColor;
 }

 // Force full opacity for OPAQUE mode materials
 // This fixes materials that were converted from MASK to OPAQUE
 if (material.alphaMode == 0) {
 baseColor.a = 1.0;
 }

 // Alpha test for MASK mode - do this early before expensive lighting calculations
 if (material.alphaMode == 1 && baseColor.a < material.alphaCutoff) {
 discard_fragment();
 }

 // Calculate shade color
 float3 shadeColor = material.shadeColorFactor;
 if (material.hasShadeMultiplyTexture > 0) {
 float3 shadeTexColor = shadeMultiplyTexture.sample(textureSampler, uv).rgb;
 shadeColor *= shadeTexColor;
 }

 // Normal mapping
 float3 normal = normalize(in.worldNormal);
 if (material.hasNormalTexture > 0) {
 float3 normalMapSample = normalTexture.sample(textureSampler, uv).xyz;
 normalMapSample = normalMapSample * 2.0 - 1.0;
 // TODO: Proper tangent space transformation
 normal = normalize(normal + normalMapSample * 0.3);
 }

 // Shading shift calculation
 float shadingShift = material.shadingShiftFactor;
 if (material.hasShadingShiftTexture > 0) {
 float shiftTexValue = shadingShiftTexture.sample(textureSampler, uv).r;
 shadingShift += (shiftTexValue - 0.5) * material.shadingShiftTextureScale;
 }

 // MToon toon shading
 float NdotL = dot(normal, uniforms.lightDirection);
 float toony = material.shadingToonyFactor;

 float shadowStep = smoothstep(shadingShift - toony * 0.5,
                          shadingShift + toony * 0.5,
                          NdotL);

 // Mix lit and shade colors
 float3 litColor = mix(shadeColor, baseColor.rgb, shadowStep);

 // Apply lighting
 litColor *= uniforms.lightColor;

 // Global illumination equalization - mix toward balanced lighting
 float3 giColor = uniforms.ambientColor * baseColor.rgb;
 litColor = mix(litColor, (litColor + giColor) * 0.5, material.giIntensityFactor);

 // Emissive
 float3 emissive = material.emissiveFactor;
 if (material.hasEmissiveTexture > 0) {
 float3 emissiveTexColor = emissiveTexture.sample(textureSampler, uv).rgb;
 emissive *= emissiveTexColor;
 }
 litColor += emissive;

 // MatCap
 if (material.hasMatcapTexture > 0) {
 float2 matcapUV = calculateMatCapUV(in.viewNormal);
 float3 matcapColor = matcapTexture.sample(textureSampler, matcapUV).rgb;
 litColor += matcapColor * material.matcapFactor;
 }

 // Parametric rim lighting - using view-space normal for consistent calculation
 float3 rimColor = float3(0.0);
 if (any(material.parametricRimColorFactor > 0.0)) {
 // Use view-space normal and view direction for proper fresnel
 float3 Nv = in.viewNormal;  // Already in view space
 float3 Vv = normalize(-in.worldPosition); // View direction in world space

 float vf = 1.0 - saturate(dot(Nv, normalize((uniforms.viewMatrix * float4(Vv, 0.0)).xyz)));
 float rimF = pow(vf, material.parametricRimFresnelPowerFactor);
 rimF = saturate(rimF + material.parametricRimLiftFactor);

 rimColor = material.parametricRimColorFactor * rimF;

 // Apply rim multiply texture for masking
 if (material.hasRimMultiplyTexture > 0) {
     float rimMask = saturate(rimMultiplyTexture.sample(textureSampler, uv).r);
     rimColor *= rimMask;
 }
 }

 // Apply rim lighting mix - blend between lit and unlit rim
 if (any(rimColor > 0.0)) {
 float3 rimLit = rimColor * uniforms.lightColor;  // Lit rim
 float3 rimUnlit = rimColor;                       // Unlit rim
 rimColor = mix(rimLit, rimUnlit, material.rimLightingMixFactor);

 // Mix rim into the final color instead of additive
 litColor = mix(litColor, litColor + rimColor, material.rimLightingMixFactor);
 }


 // TEMPORARY DEBUG: Test if lighting is washing out textures
 if (material.hasBaseColorTexture > 0) {
 // For textured materials, return simple textured result for now
 float4 texColor = baseColorTexture.sample(textureSampler, uv);
 return float4(texColor.rgb * material.baseColorFactor.rgb, baseColor.a);
 }

 #if 1  // ENABLED: Full MToon lighting for non-textured materials
 // Final color output
 litColor = saturate(litColor);

 #if 0  // DEBUG: Visualize vertex attributes
 // Show joint indices and weights to verify skinning data
 return float4(float(in.joints[0]) / 255.0, in.weights[0], 0.0, 1.0);
 #endif

 // Use the alpha from baseColor which has been corrected for OPAQUE mode
 return float4(litColor, baseColor.a);
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
 float outlineWidth = material.outlineWidthFactor;
 if (material.hasOutlineWidthMultiplyTexture > 0) {
 float widthMultiplier = outlineWidthMultiplyTexture.sample(textureSampler, in.texCoord).r;
 outlineWidth *= widthMultiplier;
 }

 // Calculate final position with outline extrusion
 if (material.outlineMode == 1.0) {
 // World coordinates mode - extrude in world space
 float3 worldNormal = normalize((uniforms.normalMatrix * float4(in.normal, 0.0)).xyz);
 float3 worldPos = (uniforms.modelMatrix * float4(in.position, 1.0)).xyz;

 // Scale outline width by distance from camera for consistent visual thickness
 float3 cameraPos = -uniforms.viewMatrix[3].xyz;
 float distanceScale = length(worldPos - cameraPos) * 0.01; // Adjust multiplier as needed

 worldPos += worldNormal * outlineWidth * distanceScale;
 out.worldPosition = worldPos;
 out.position = uniforms.projectionMatrix * uniforms.viewMatrix * float4(worldPos, 1.0);

 } else if (material.outlineMode == 2.0) {
 // Screen coordinates mode - extrude in screen space
 float4 worldPos = uniforms.modelMatrix * float4(in.position, 1.0);
 out.worldPosition = worldPos.xyz;

 // Transform to clip space
 float4 clipPos = uniforms.projectionMatrix * uniforms.viewMatrix * worldPos;

 // Calculate screen-space normal
 float3 viewNormal = normalize((uniforms.viewMatrix * uniforms.normalMatrix * float4(in.normal, 0.0)).xyz);
 float2 screenNormal = normalize(viewNormal.xy);

 // Convert outline width from pixels to NDC
 float2 pixelsToNDC = 2.0 / uniforms.viewportSize;
 float2 offsetNDC = screenNormal * outlineWidth * pixelsToNDC;

 // Apply screen-space offset, scaled by clip.w for perspective-correct width
 clipPos.xy += offsetNDC * clipPos.w;
 out.position = clipPos;

 } else {
 // No outline (mode 0)
 float4 worldPos = uniforms.modelMatrix * float4(in.position, 1.0);
 out.worldPosition = worldPos.xyz;
 out.position = uniforms.projectionMatrix * uniforms.viewMatrix * worldPos;
 }

 out.worldNormal = normalize((uniforms.normalMatrix * float4(in.normal, 0.0)).xyz);
 out.viewNormal = normalize((uniforms.viewMatrix * uniforms.normalMatrix * float4(in.normal, 0.0)).xyz);
 out.texCoord = in.texCoord;
 out.animatedTexCoord = animateUV(in.texCoord, material);
 out.color = in.color;

 float3 cameraPos = -uniforms.viewMatrix[3].xyz;
 out.viewDirection = normalize(cameraPos - out.worldPosition);

 return out;
}

// Advanced outline fragment shader
fragment float4 mtoon_outline_fragment(VertexOut in [[stage_in]],
                                constant MToonMaterial& material [[buffer(8)]],
                                constant Uniforms& uniforms [[buffer(1)]]) {
 float3 outlineColor = material.outlineColorFactor;

 // Apply outline lighting mix
 if (material.outlineLightingMixFactor < 1.0) {
 float3 lightInfluence = uniforms.lightColor * uniforms.ambientColor;
 outlineColor = mix(outlineColor * lightInfluence, outlineColor, material.outlineLightingMixFactor);
 }

 return float4(outlineColor, 1.0);
}

// Debug fragment shaders for visualizing individual MToon components
fragment float4 mtoon_debug_nl(VertexOut in [[stage_in]],
                        constant MToonMaterial& material [[buffer(8)]],
                        constant Uniforms& uniforms [[buffer(1)]]) {
 float3 normal = normalize(in.worldNormal);
 float nl = saturate(dot(normal, uniforms.lightDirection));
 return float4(nl, nl, nl, 1.0);
}

fragment float4 mtoon_debug_ramp(VertexOut in [[stage_in]],
                          constant MToonMaterial& material [[buffer(8)]],
                          constant Uniforms& uniforms [[buffer(1)]],
                          texture2d<float> shadingShiftTexture [[texture(2)]],
                          sampler textureSampler [[sampler(0)]]) {
 float3 normal = normalize(in.worldNormal);
 float nl = saturate(dot(normal, uniforms.lightDirection));

 float shadingShift = material.shadingShiftFactor;
 if (material.hasShadingShiftTexture > 0) {
 float shiftTexValue = shadingShiftTexture.sample(textureSampler, in.texCoord).r;
 shadingShift += (shiftTexValue - 0.5) * material.shadingShiftTextureScale;
 }

 float ramp = smoothstep(shadingShift - material.shadingToonyFactor * 0.5,
                    shadingShift + material.shadingToonyFactor * 0.5,
                    nl);
 return float4(ramp, ramp, ramp, 1.0);
}

fragment float4 mtoon_debug_rim(VertexOut in [[stage_in]],
                         constant MToonMaterial& material [[buffer(8)]],
                         constant Uniforms& uniforms [[buffer(1)]]) {
 if (any(material.parametricRimColorFactor <= 0.0)) {
 return float4(0, 0, 0, 1);
 }

 float3 Nv = in.viewNormal;
 float3 Vv = normalize(-in.worldPosition);
 float vf = 1.0 - saturate(dot(Nv, normalize((uniforms.viewMatrix * float4(Vv, 0.0)).xyz)));
 float rimF = pow(vf, material.parametricRimFresnelPowerFactor);
 rimF = saturate(rimF + material.parametricRimLiftFactor);
 return float4(rimF, rimF, rimF, 1.0);
}

fragment float4 mtoon_debug_matcap_uv(VertexOut in [[stage_in]]) {
 float2 matcapUV = calculateMatCapUV(in.viewNormal);
 return float4(matcapUV.x, matcapUV.y, 0.0, 1.0);
}

fragment float4 mtoon_debug_outline_width(VertexOut in [[stage_in]],
                                   constant MToonMaterial& material [[buffer(8)]]) {
 float width = material.outlineWidthFactor * 10.0; // Scale for visibility
 return float4(width, width, width, 1.0);
}
