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
 float2 viewportSize;
 float nearPlane;
 float farPlane;
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

 // Block 11: 16 bytes - More texture flags
 int hasNormalTexture;                      // 4 bytes
 int hasEmissiveTexture;                    // 4 bytes
 int _padding3;                             // 4 bytes padding
 int _padding4;                             // 4 bytes padding
};

struct VertexIn {
 float3 position [[attribute(0)]];
 float3 normal [[attribute(1)]];
 float2 texCoord [[attribute(2)]];
 float4 color [[attribute(3)]];
 ushort4 joints [[attribute(4)]];
 float4 weights [[attribute(5)]];
};

// Must match MToonShader's VertexOut exactly for fragment shader compatibility
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
float2 animateUV(float2 uv, constant MToonMaterial& material) {
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

// Skinned vertex shader with MToon support
vertex VertexOut skinned_mtoon_vertex(VertexIn in [[stage_in]],
                               constant Uniforms& uniforms [[buffer(1)]],
                               constant MToonMaterial& material [[buffer(2)]],
                               constant float4x4* jointMatrices [[buffer(3)]],
                               device float3* morphedPositions [[buffer(20)]],
                               constant uint& hasMorphed [[buffer(22)]],
                               uint vertexID [[vertex_id]]) {
 VertexOut out;

 // 🔍 SHADER PROBE: Debug first vertex to see what GPU reads
 if (vertexID == 0) {
 // This will cause a visible artifact if joints/weights are wrong
 // Expected: joints.x in [0..30], weights.x in [0..1]
 // If we see huge values, the vertex descriptor is wrong
 // Output as color for visibility
 }

 // Use morphed positions if available, otherwise use original
 float3 basePosition;
 if (hasMorphed > 0) {
 // Positions from compute shader output (after morph target application)
 basePosition = float3(morphedPositions[vertexID]);
 } else {
 // No morphs - use original position
 basePosition = in.position;
 }

 // Apply skeletal skinning
 float4x4 skinMatrix = float4x4(0.0);

 // Accumulate weighted joint transforms
 if (in.weights[0] > 0.0) {
 skinMatrix += jointMatrices[in.joints[0]] * in.weights[0];
 }
 if (in.weights[1] > 0.0) {
 skinMatrix += jointMatrices[in.joints[1]] * in.weights[1];
 }
 if (in.weights[2] > 0.0) {
 skinMatrix += jointMatrices[in.joints[2]] * in.weights[2];
 }
 if (in.weights[3] > 0.0) {
 skinMatrix += jointMatrices[in.joints[3]] * in.weights[3];
 }

 // Apply skinning to position and normal (using morphed base position if available)
 float4 skinnedPosition = skinMatrix * float4(basePosition, 1.0);
 float3 skinnedNormal = normalize((skinMatrix * float4(in.normal, 0.0)).xyz);

 // Transform to world space
 float4 worldPos = uniforms.modelMatrix * skinnedPosition;
 out.worldPosition = worldPos.xyz;

 // Transform normal to world space
 out.worldNormal = normalize((uniforms.normalMatrix * float4(skinnedNormal, 0.0)).xyz);

 // Transform to clip space
 float4 viewPosition = uniforms.viewMatrix * worldPos;
 out.position = uniforms.projectionMatrix * viewPosition;

 // Calculate view direction (from vertex to camera)
 // Camera position is at origin in view space
 float3 cameraWorldPos = -uniforms.viewMatrix[3].xyz;
 out.viewDirection = normalize(cameraWorldPos - out.worldPosition);

 // Calculate view-space normal for MatCap
 out.viewNormal = normalize((uniforms.viewMatrix * float4(out.worldNormal, 0.0)).xyz);

 // Pass through texture coordinates and vertex color
 out.texCoord = in.texCoord;
 out.animatedTexCoord = in.texCoord;  // Will be animated in fragment shader if needed
 out.color = in.color;

 return out;
}

// Simplified skinned vertex shader for debugging
vertex VertexOut skinned_vertex(VertexIn in [[stage_in]],
                         constant Uniforms& uniforms [[buffer(1)]],
                         constant float4x4* jointMatrices [[buffer(3)]],
                         uint vertexID [[vertex_id]]) {
 VertexOut out;

 // Apply skeletal skinning
 float4x4 skinMatrix = float4x4(0.0);

 // Accumulate weighted joint transforms
 if (in.weights[0] > 0.0) {
 skinMatrix += jointMatrices[in.joints[0]] * in.weights[0];
 }
 if (in.weights[1] > 0.0) {
 skinMatrix += jointMatrices[in.joints[1]] * in.weights[1];
 }
 if (in.weights[2] > 0.0) {
 skinMatrix += jointMatrices[in.joints[2]] * in.weights[2];
 }
 if (in.weights[3] > 0.0) {
 skinMatrix += jointMatrices[in.joints[3]] * in.weights[3];
 }

 // Apply skinning to position and normal
 float4 skinnedPosition = skinMatrix * float4(in.position, 1.0);
 float3 skinnedNormal = normalize((skinMatrix * float4(in.normal, 0.0)).xyz);

 // Transform to world space
 float4 worldPos = uniforms.modelMatrix * skinnedPosition;
 out.worldPosition = worldPos.xyz;

 // Transform normal to world space
 out.worldNormal = normalize((uniforms.normalMatrix * float4(skinnedNormal, 0.0)).xyz);

 // Transform to clip space
 float4 viewPosition = uniforms.viewMatrix * worldPos;
 out.position = uniforms.projectionMatrix * viewPosition;

 // Calculate view direction
 float3 cameraWorldPos = -uniforms.viewMatrix[3].xyz;
 out.viewDirection = normalize(cameraWorldPos - out.worldPosition);

 // Calculate view-space normal for MatCap
 out.viewNormal = normalize((uniforms.viewMatrix * float4(out.worldNormal, 0.0)).xyz);

 // Pass through texture coordinates and vertex color
 out.texCoord = in.texCoord;
 out.animatedTexCoord = in.texCoord;
 out.color = in.color;

 return out;
}
