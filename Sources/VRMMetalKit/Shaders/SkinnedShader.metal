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

constant float WEIGHT_THRESHOLD = 0.001;

// --- #197 Dual-quaternion skinning (opt-in, quality-above-reference) ----------
// LBS linearly blends joint MATRICES, which loses volume at high-deformation
// joints (the deltoid/armpit "candy-wrapper" collapse). DQS blends the joints'
// dual quaternions instead, preserving rigidity. Assumes RIGID joints (no
// non-uniform scale) — VRM skeletons are rigid; non-uniform scale corrupts the
// quaternion extraction (documented DQS caveat). Default-off: LBS is the
// glTF-standard reference behaviour, so DQS is a deliberate divergence.

// Unit rotation quaternion (xyzw) from a joint matrix's rotation block
// (Metal is column-major: m[col][row]). Columns are normalized to drop any
// uniform scale.
static inline float4 dqsQuatFromMatrix(float4x4 m) {
    float3 c0 = normalize(m[0].xyz), c1 = normalize(m[1].xyz), c2 = normalize(m[2].xyz);
    float tr = c0.x + c1.y + c2.z;
    float4 q;
    if (tr > 0.0) {
        float s = sqrt(tr + 1.0) * 2.0;
        q = float4((c1.z - c2.y)/s, (c2.x - c0.z)/s, (c0.y - c1.x)/s, 0.25*s);
    } else if (c0.x > c1.y && c0.x > c2.z) {
        float s = sqrt(1.0 + c0.x - c1.y - c2.z) * 2.0;
        q = float4(0.25*s, (c1.x + c0.y)/s, (c2.x + c0.z)/s, (c1.z - c2.y)/s);
    } else if (c1.y > c2.z) {
        float s = sqrt(1.0 + c1.y - c0.x - c2.z) * 2.0;
        q = float4((c1.x + c0.y)/s, 0.25*s, (c2.y + c1.z)/s, (c2.x - c0.z)/s);
    } else {
        float s = sqrt(1.0 + c2.z - c0.x - c1.y) * 2.0;
        q = float4((c2.x + c0.z)/s, (c2.y + c1.z)/s, 0.25*s, (c0.y - c1.x)/s);
    }
    return normalize(q);
}

// Hamilton quaternion product (xyzw).
static inline float4 dqsQuatMul(float4 a, float4 b) {
    return float4(a.w*b.xyz + b.w*a.xyz + cross(a.xyz, b.xyz),
                  a.w*b.w - dot(a.xyz, b.xyz));
}

// Rotate a vector by a unit quaternion (xyzw).
static inline float3 dqsQuatRotate(float4 q, float3 v) {
    return v + 2.0 * cross(q.xyz, cross(q.xyz, v) + q.w * v);
}

// Skin a point + normal by the weighted DQS blend of up to 4 joints.
static inline void dqsSkin(float4x4 m0, float4x4 m1, float4x4 m2, float4x4 m3,
                           float4 w, thread float3& pos, thread float3& nrm) {
    float4 q0 = dqsQuatFromMatrix(m0);
    float4 qr = float4(0.0), qd = float4(0.0);
    float4x4 mats[4] = { m0, m1, m2, m3 };
    for (uint i = 0; i < 4; ++i) {
        if (w[i] <= 0.0) { continue; }
        float4 qj = dqsQuatFromMatrix(mats[i]);
        if (dot(qj, q0) < 0.0) { qj = -qj; }              // antipodality: same hemisphere
        float4 qdj = 0.5 * dqsQuatMul(float4(mats[i][3].xyz, 0.0), qj);
        qr += w[i] * qj;
        qd += w[i] * qdj;
    }
    float n = length(qr);
    if (n < 1e-8) { return; }                              // caller keeps base pos/nrm
    qr /= n; qd /= n;
    float3 t = 2.0 * dqsQuatMul(qd, float4(-qr.xyz, qr.w)).xyz;
    pos = dqsQuatRotate(qr, pos) + t;
    nrm = dqsQuatRotate(qr, nrm);
}

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
 int debugUVs;
 float lightNormalizationFactor;
 float _padding2;
 float useDualQuaternionSkinning;  // #197: >0.5 = DQS, else LBS
 int toonBands;
 float additiveDirectionalRimEnabled;
 float additiveDirectionalRimPower;
 uint cameraMode;
};

// Use packed floats to match Swift struct layout (192 bytes total)
// Note: Metal's float3 has 16-byte alignment which causes padding
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
 uint32_t alphaMode;                        // 4 bytes
 float alphaCutoff;                         // 4 bytes

 // Block 12: 16 bytes - Version flag and UV offset
 uint32_t vrmVersion;                       // 4 bytes (0 = VRM 0.0, 1 = VRM 1.0)
 float uvOffsetX;                           // 4 bytes
 float uvOffsetY;                           // 4 bytes
 float uvScale;                             // 4 bytes

 // Block 13: 16 bytes - KHR_texture_transform (offset, rotation, scale X)
 float textureTransformOffsetX;             // 4 bytes
 float textureTransformOffsetY;             // 4 bytes
 float textureTransformRotation;            // 4 bytes
 float textureTransformScaleX;             // 4 bytes

 // Block 14: 16 bytes - KHR_texture_transform scale Y + padding
 float textureTransformScaleY;             // 4 bytes
 float _ttPad0;                             // 4 bytes padding
 float _ttPad1;                             // 4 bytes padding
 float _ttPad2;                             // 4 bytes padding
};

struct VertexIn {
 float3 position [[attribute(0)]];
 float3 normal [[attribute(1)]];
 float2 texCoord [[attribute(2)]];
 float4 color [[attribute(3)]];
 uint4 joints [[attribute(4)]];  // Changed to uint4 to match VRMVertex.joints (SIMD4<UInt32>)
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

static inline bool hasParametricRim(constant MToonMaterial& material) {
 return material.parametricRimColorR > 0.0 ||
        material.parametricRimColorG > 0.0 ||
        material.parametricRimColorB > 0.0;
}

static inline bool needsViewNormal(constant MToonMaterial& material, constant Uniforms& uniforms) {
 return material.hasMatcapTexture > 0 || hasParametricRim(material) ||
        uniforms.debugUVs == 32;
}

static inline bool needsViewDirection(constant MToonMaterial& material, constant Uniforms& uniforms) {
 return hasParametricRim(material) || uniforms.debugUVs == 10;
}

// Skinned vertex shader with MToon support
vertex VertexOut skinned_mtoon_vertex(VertexIn in [[stage_in]],
                               constant Uniforms& uniforms [[buffer(1)]],
                               constant MToonMaterial& material [[buffer(8)]],
                               constant float4x4* jointMatrices [[buffer(25)]],
                               device const float3* morphedPositions [[buffer(20)]],
                               constant uint& hasMorphed [[buffer(22)]],
                               device const uint8_t* firstPersonHiddenFlags [[buffer(26)]],
                               uint vertexID [[vertex_id]]) {
 VertexOut out;

 // Use morphed positions if available, otherwise use original
 float3 basePosition;
 if (hasMorphed > 0) {
 // Positions from compute shader output (after morph target application)
 basePosition = float3(morphedPositions[vertexID]);
 } else {
 // No morphs - use original position
 basePosition = in.position;
 }

 // Store RAW weights for threshold check (before normalization)
 // This prevents accessing garbage joint indices that have zero/tiny weights
 float4 rawWeights = in.weights;

 // Normalize weights to ensure they sum to 1.0 (prevents partial transforms)
 float4 weights = rawWeights;
 float weightSum = dot(weights, float4(1.0));
 if (weightSum > 1e-6) {
 weights = weights / weightSum;
 } else {
 weights = float4(1.0, 0.0, 0.0, 0.0); // Fallback to first joint
 }

 // Apply skeletal skinning with normalized weights
 // CRITICAL: Use RAW weights for threshold check to avoid accessing garbage joint indices
 float threshold = WEIGHT_THRESHOLD;

 // Safe buffer limit: clamp to 255 to prevent reading garbage memory
 // This allows valid indices (0-90+) while blocking garbage indices (65535, etc.)
 uint maxJoint = 255;
 uint4 safeJoints = min(in.joints, uint4(maxJoint));

 // Threshold-gate the (normalized) weights: zero out any joint whose RAW weight
 // is below threshold so neither path blends a garbage joint index.
 float4 gatedWeights = float4(
     rawWeights[0] > threshold ? weights[0] : 0.0,
     rawWeights[1] > threshold ? weights[1] : 0.0,
     rawWeights[2] > threshold ? weights[2] : 0.0,
     rawWeights[3] > threshold ? weights[3] : 0.0);

 float4 skinnedPosition;
 float3 skinnedNormal;
 if (uniforms.useDualQuaternionSkinning > 0.5) {
 // #197 DQS — volume-preserving blend (opt-in, quality-above-reference).
 float3 dqPos = basePosition;
 float3 dqNrm = in.normal;
 dqsSkin(jointMatrices[safeJoints[0]], jointMatrices[safeJoints[1]],
         jointMatrices[safeJoints[2]], jointMatrices[safeJoints[3]],
         gatedWeights, dqPos, dqNrm);
 skinnedPosition = float4(dqPos, 1.0);
 skinnedNormal = dqNrm;
 } else {
 // LBS — default, glTF-standard reference behaviour.
 float4x4 skinMatrix = float4x4(0.0);
 skinMatrix += jointMatrices[safeJoints[0]] * gatedWeights[0];
 skinMatrix += jointMatrices[safeJoints[1]] * gatedWeights[1];
 skinMatrix += jointMatrices[safeJoints[2]] * gatedWeights[2];
 skinMatrix += jointMatrices[safeJoints[3]] * gatedWeights[3];
 // Fallback: if skinMatrix is zero (no weights passed threshold), use first joint
 if (skinMatrix[0][0] == 0.0 && skinMatrix[1][1] == 0.0 && skinMatrix[2][2] == 0.0) {
 skinMatrix = jointMatrices[safeJoints[0]];
 }
 skinnedPosition = skinMatrix * float4(basePosition, 1.0);
 skinnedNormal = (skinMatrix * float4(in.normal, 0.0)).xyz;
 }

 // SANITY CHECK: Detect NaN/Inf or extreme skinned positions and fall back to original
 // This catches cases where joint indices point to garbage memory or matrix is corrupted
 bool posHasNaN = any(isnan(skinnedPosition.xyz)) || any(isinf(skinnedPosition.xyz));
 bool posHasExtreme = length(skinnedPosition.xyz) > 50.0;  // Reasonable limit for humanoid (within 50 units of origin)
 bool normalHasNaN = any(isnan(skinnedNormal)) || any(isinf(skinnedNormal));
 if (posHasNaN || posHasExtreme || normalHasNaN) {
 // Fall back to original position (no skinning)
 skinnedPosition = float4(basePosition, 1.0);
 skinnedNormal = in.normal;
 }
 skinnedNormal = normalize(skinnedNormal);

 // Transform to world space
 float4 worldPos = uniforms.modelMatrix * skinnedPosition;
 out.worldPosition = worldPos.xyz;

 // Transform normal to world space
 out.worldNormal = normalize((uniforms.normalMatrix * float4(skinnedNormal, 0.0)).xyz);

 // Transform to clip space
 float4 viewPosition = uniforms.viewMatrix * worldPos;
 out.position = uniforms.projectionMatrix * viewPosition;

 if (needsViewDirection(material, uniforms)) {
 // Calculate view direction (from vertex to camera)
 // Extract camera world position from view matrix: cameraPos = -R^T * translation
 float3x3 viewRotation = float3x3(uniforms.viewMatrix[0].xyz,
                                   uniforms.viewMatrix[1].xyz,
                                   uniforms.viewMatrix[2].xyz);
 float3 cameraWorldPos = -(transpose(viewRotation) * uniforms.viewMatrix[3].xyz);
 out.viewDirection = normalize(cameraWorldPos - out.worldPosition);
 } else {
 out.viewDirection = float3(0.0, 0.0, 1.0);
 }

 if (needsViewNormal(material, uniforms)) {
 // Calculate view-space normal for MatCap/rim
 out.viewNormal = normalize((uniforms.viewMatrix * float4(out.worldNormal, 0.0)).xyz);
 } else {
 out.viewNormal = float3(0.0, 0.0, 1.0);
 }

 // Pass through texture coordinates and vertex color
 out.texCoord = in.texCoord;
 out.animatedTexCoord = in.texCoord;  // Will be animated in fragment shader if needed
 out.color = in.color;

 // First-person head-bone culling: degenerate the position so the triangle is clipped.
 if (uniforms.cameraMode == 1u && firstPersonHiddenFlags[vertexID] != 0u) {
     out.position = float4(0.0, 0.0, -2.0, 0.0); // w=0 → clipped by homogeneous divide
 }

 return out;
}

// Simplified skinned vertex shader for debugging
vertex VertexOut skinned_vertex(VertexIn in [[stage_in]],
                         constant Uniforms& uniforms [[buffer(1)]],
                         constant float4x4* jointMatrices [[buffer(25)]],
                         [[maybe_unused]] uint vertexID [[vertex_id]]) {
 VertexOut out;

 // Store RAW weights for threshold check
 float4 rawWeights = in.weights;

 // Normalize weights to ensure they sum to 1.0 (prevents partial transforms)
 float4 weights = rawWeights;
 float weightSum = dot(weights, float4(1.0));
 if (weightSum > 1e-6) {
 weights = weights / weightSum;
 } else {
 weights = float4(1.0, 0.0, 0.0, 0.0); // Fallback to first joint
 }

 // Apply skeletal skinning - use RAW weights for threshold check
 float4x4 skinMatrix = float4x4(0.0);
 float threshold = WEIGHT_THRESHOLD;

 // Safe buffer limit: clamp to 255 to prevent reading garbage memory
 uint maxJoint = 255;
 uint4 safeJoints = min(in.joints, uint4(maxJoint));

 if (rawWeights[0] > threshold) {
 skinMatrix += jointMatrices[safeJoints[0]] * weights[0];
 }
 if (rawWeights[1] > threshold) {
 skinMatrix += jointMatrices[safeJoints[1]] * weights[1];
 }
 if (rawWeights[2] > threshold) {
 skinMatrix += jointMatrices[safeJoints[2]] * weights[2];
 }
 if (rawWeights[3] > threshold) {
 skinMatrix += jointMatrices[safeJoints[3]] * weights[3];
 }

 // Fallback: if skinMatrix is zero, use first joint
 if (skinMatrix[0][0] == 0.0 && skinMatrix[1][1] == 0.0 && skinMatrix[2][2] == 0.0) {
 skinMatrix = jointMatrices[safeJoints[0]];
 }

 // Apply skinning to position and normal
 float4 skinnedPosition = skinMatrix * float4(in.position, 1.0);
 float3 skinnedNormal = (skinMatrix * float4(in.normal, 0.0)).xyz;

 // SANITY CHECK: Detect NaN/Inf or extreme skinned positions and fall back to original
 bool posHasNaN = any(isnan(skinnedPosition.xyz)) || any(isinf(skinnedPosition.xyz));
 bool posHasExtreme = length(skinnedPosition.xyz) > 50.0;
 bool normalHasNaN = any(isnan(skinnedNormal)) || any(isinf(skinnedNormal));
 if (posHasNaN || posHasExtreme || normalHasNaN) {
 skinnedPosition = float4(in.position, 1.0);
 skinnedNormal = in.normal;
 }
 skinnedNormal = normalize(skinnedNormal);

 // Transform to world space
 float4 worldPos = uniforms.modelMatrix * skinnedPosition;
 out.worldPosition = worldPos.xyz;

 // Transform normal to world space
 out.worldNormal = normalize((uniforms.normalMatrix * float4(skinnedNormal, 0.0)).xyz);

 // Transform to clip space
 float4 viewPosition = uniforms.viewMatrix * worldPos;
 out.position = uniforms.projectionMatrix * viewPosition;

 // Calculate view direction - extract camera world position from view matrix
 float3x3 viewRotation = float3x3(uniforms.viewMatrix[0].xyz,
                                   uniforms.viewMatrix[1].xyz,
                                   uniforms.viewMatrix[2].xyz);
 float3 cameraWorldPos = -(transpose(viewRotation) * uniforms.viewMatrix[3].xyz);
 out.viewDirection = normalize(cameraWorldPos - out.worldPosition);

 // Calculate view-space normal for MatCap
 out.viewNormal = normalize((uniforms.viewMatrix * float4(out.worldNormal, 0.0)).xyz);

 // Pass through texture coordinates and vertex color
 out.texCoord = in.texCoord;
 out.animatedTexCoord = in.texCoord;
 out.color = in.color;

 return out;
}

// Skinned MToon outline vertex shader (inverted hull technique)
vertex VertexOut skinned_mtoon_outline_vertex(VertexIn in [[stage_in]],
                                              constant Uniforms& uniforms [[buffer(1)]],
                                              constant MToonMaterial& material [[buffer(8)]],
                                              constant float4x4* jointMatrices [[buffer(25)]]) {
 VertexOut out;

 // Store RAW weights for threshold check
 float4 rawWeights = in.weights;

 // Normalize weights to ensure they sum to 1.0 (prevents partial transforms)
 float4 weights = rawWeights;
 float weightSum = dot(weights, float4(1.0));
 if (weightSum > 1e-6) {
 weights = weights / weightSum;
 } else {
 weights = float4(1.0, 0.0, 0.0, 0.0); // Fallback to first joint
 }

 // Apply skeletal skinning - use RAW weights for threshold check
 float threshold = WEIGHT_THRESHOLD;

 // Safe buffer limit: clamp to 255 to prevent reading garbage memory
 uint maxJoint = 255;
 uint4 safeJoints = min(in.joints, uint4(maxJoint));

 float4 gatedWeights = float4(
     rawWeights[0] > threshold ? weights[0] : 0.0,
     rawWeights[1] > threshold ? weights[1] : 0.0,
     rawWeights[2] > threshold ? weights[2] : 0.0,
     rawWeights[3] > threshold ? weights[3] : 0.0);

 // Skin the outline hull with the SAME path as the body (#197) so the
 // inverted-hull outline tracks the DQS-skinned surface instead of an LBS one.
 float4 skinnedPosition;
 float3 skinnedNormal;
 if (uniforms.useDualQuaternionSkinning > 0.5) {
 float3 dqPos = in.position;
 float3 dqNrm = in.normal;
 dqsSkin(jointMatrices[safeJoints[0]], jointMatrices[safeJoints[1]],
         jointMatrices[safeJoints[2]], jointMatrices[safeJoints[3]],
         gatedWeights, dqPos, dqNrm);
 skinnedPosition = float4(dqPos, 1.0);
 skinnedNormal = dqNrm;
 } else {
 float4x4 skinMatrix = float4x4(0.0);
 skinMatrix += jointMatrices[safeJoints[0]] * gatedWeights[0];
 skinMatrix += jointMatrices[safeJoints[1]] * gatedWeights[1];
 skinMatrix += jointMatrices[safeJoints[2]] * gatedWeights[2];
 skinMatrix += jointMatrices[safeJoints[3]] * gatedWeights[3];
 if (skinMatrix[0][0] == 0.0 && skinMatrix[1][1] == 0.0 && skinMatrix[2][2] == 0.0) {
 skinMatrix = jointMatrices[safeJoints[0]];
 }
 skinnedPosition = skinMatrix * float4(in.position, 1.0);
 skinnedNormal = (skinMatrix * float4(in.normal, 0.0)).xyz;
 }

 // SANITY CHECK: Detect NaN/Inf or extreme skinned positions and fall back to original
 bool posHasNaN = any(isnan(skinnedPosition.xyz)) || any(isinf(skinnedPosition.xyz));
 bool posHasExtreme = length(skinnedPosition.xyz) > 50.0;
 bool normalHasNaN = any(isnan(skinnedNormal)) || any(isinf(skinnedNormal));
 if (posHasNaN || posHasExtreme || normalHasNaN) {
 skinnedPosition = float4(in.position, 1.0);
 skinnedNormal = in.normal;
 }
 skinnedNormal = normalize(skinnedNormal);

 // Transform to world space
 float4 worldPos = uniforms.modelMatrix * skinnedPosition;
 float3 worldNormal = normalize((uniforms.normalMatrix * float4(skinnedNormal, 0.0)).xyz);

 // Get outline width from material
 float outlineWidth = material.outlineWidthFactor;

 // Extract camera world position from view matrix: cameraPos = -R^T * translation
 // Done once at the start for use in both outline modes and view direction
 float3x3 viewRotation = float3x3(uniforms.viewMatrix[0].xyz,
                                   uniforms.viewMatrix[1].xyz,
                                   uniforms.viewMatrix[2].xyz);
 float3 cameraWorldPos = -(transpose(viewRotation) * uniforms.viewMatrix[3].xyz);

 // Calculate view direction
 float3 viewDir = normalize(cameraWorldPos - worldPos.xyz);

 // Apply outline extrusion along normal
 // outlineMode: 0=none, 1=worldCoordinates, 2=screenCoordinates
 // Must match MToonShader.metal for visual consistency
 if (material.outlineMode == 1) {
  // World coordinates: width scales with camera distance (matches non-skinned)
  float distanceScale = length(worldPos.xyz - cameraWorldPos) * 0.01;
  worldPos.xyz += worldNormal * outlineWidth * distanceScale;
 } else if (material.outlineMode == 2) {
  // Screen coordinates: fixed pixel width (matches non-skinned NDC approach)
  float4 clipPos = uniforms.projectionMatrix * uniforms.viewMatrix * worldPos;
  float3 viewNormal = normalize((uniforms.viewMatrix * float4(worldNormal, 0.0)).xyz);
  float2 screenNormal = normalize(viewNormal.xy);
  float2 pixelsToNDC = 2.0 / uniforms.viewportSize.xy;
  float2 offsetNDC = screenNormal * outlineWidth * pixelsToNDC;
  clipPos.xy += offsetNDC * clipPos.w;
  out.position = clipPos;
  out.worldPosition = worldPos.xyz;
  out.worldNormal = worldNormal;
  out.viewDirection = viewDir;
  out.viewNormal = normalize((uniforms.viewMatrix * float4(out.worldNormal, 0.0)).xyz);
  out.texCoord = in.texCoord;
  out.animatedTexCoord = in.texCoord;
  out.color = in.color;
  return out;
 }

 out.worldPosition = worldPos.xyz;
 out.worldNormal = worldNormal;

 // Transform to clip space
 float4 viewPosition = uniforms.viewMatrix * worldPos;
 out.position = uniforms.projectionMatrix * viewPosition;

 // Calculate view direction and view normal
 out.viewDirection = normalize(cameraWorldPos - out.worldPosition);
 out.viewNormal = normalize((uniforms.viewMatrix * float4(out.worldNormal, 0.0)).xyz);

 // Pass through texture coordinates and vertex color
 out.texCoord = in.texCoord;
 out.animatedTexCoord = in.texCoord;
 out.color = in.color;

 return out;
}
