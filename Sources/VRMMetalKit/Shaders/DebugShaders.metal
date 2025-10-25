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

// Debug vertex input structure - MUST match VRMVertex layout!
struct DebugVertexIn {
    float3 position [[attribute(0)]];
    float3 normal   [[attribute(1)]];
    float2 uv0      [[attribute(2)]];
    float4 color    [[attribute(3)]];  // Must include even if not used

    // Skinning inputs (for later phases)
    uint4  joints   [[attribute(4)]];  // Note: attribute indices shifted!
    float4 weights  [[attribute(5)]];
};

// Debug vertex output structure
struct DebugVertexOut {
    float4 positionCS [[position]];
    float3 positionWS;
    float3 normal;
    float2 uv0;
    float  depth;
};

// Simple uniforms for debug rendering
struct DebugUniforms {
    float4x4 modelMatrix;
    float4x4 viewMatrix;
    float4x4 projectionMatrix;
    float4x4 modelViewProjectionMatrix;
};

// PHASE 1: Minimal unlit vertex shader - just MVP transform
vertex DebugVertexOut debug_unlit_vertex(DebugVertexIn in [[stage_in]],
                                         constant DebugUniforms& uniforms [[buffer(1)]]) {
    DebugVertexOut out;

    // Simple MVP transform
    float4 worldPos = uniforms.modelMatrix * float4(in.position, 1.0);
    out.positionCS = uniforms.projectionMatrix * uniforms.viewMatrix * worldPos;
    out.positionWS = worldPos.xyz;
    out.normal = in.normal;
    out.uv0 = in.uv0;
    out.depth = out.positionCS.z / out.positionCS.w;

    return out;
}

// PHASE 1: Minimal unlit fragment shader - solid magenta
fragment float4 debug_unlit_fragment(DebugVertexOut in [[stage_in]]) {
    return float4(1.0, 0.0, 1.0, 1.0); // Magenta
}

// PHASE 2: Depth visualization fragment shader
fragment float4 debug_depth_fragment(DebugVertexOut in [[stage_in]]) {
    float depth = (in.depth * 0.5 + 0.5); // Normalize depth to 0-1
    return float4(depth, depth, depth, 1.0);
}

// PHASE 3: Texture sampling fragment shader
fragment float4 debug_texture_fragment(DebugVertexOut in [[stage_in]],
                                       texture2d<float> baseColorTexture [[texture(0)]],
                                       sampler baseColorSampler [[sampler(0)]]) {
    float4 color = baseColorTexture.sample(baseColorSampler, in.uv0);
    return float4(color.rgb, 1.0);
}

// PHASE: Alpha probe - visualize alpha channel values
fragment float4 debug_alpha_probe_fragment(DebugVertexOut in [[stage_in]],
                                           texture2d<float> baseColorTexture [[texture(0)]],
                                           sampler baseColorSampler [[sampler(0)]],
                                           constant float4& baseColorFactor [[buffer(0)]]) {
    // Sample texture and apply base color factor
    float4 texColor = baseColorTexture.sample(baseColorSampler, in.uv0);
    float4 finalColor = texColor * baseColorFactor;

    // Return alpha as grayscale
    float alpha = finalColor.a;
    return float4(alpha, alpha, alpha, 1.0);
}

// PHASE 4/5: Skinned vertex shader (identity or real skinning)
vertex DebugVertexOut debug_skinned_vertex(DebugVertexIn in [[stage_in]],
                                           constant DebugUniforms& uniforms [[buffer(1)]],
                                           constant float4x4* jointMatrices [[buffer(2)]]) {
    DebugVertexOut out;

    // Apply real skinning with joint matrices
    // Normalize weights (important for correct skinning!)
    float weightSum = in.weights.x + in.weights.y + in.weights.z + in.weights.w;
    float4 normalizedWeights = in.weights / max(weightSum, 0.00001);

    // Calculate skinning matrix from joint transforms
    float4x4 skinMatrix =
        normalizedWeights.x * jointMatrices[in.joints.x] +
        normalizedWeights.y * jointMatrices[in.joints.y] +
        normalizedWeights.z * jointMatrices[in.joints.z] +
        normalizedWeights.w * jointMatrices[in.joints.w];

    float4 skinnedPos = skinMatrix * float4(in.position, 1.0);
    float4 worldPos = uniforms.modelMatrix * skinnedPos;

    out.positionCS = uniforms.projectionMatrix * uniforms.viewMatrix * worldPos;
    out.positionWS = worldPos.xyz;
    out.normal = in.normal;  // TODO: Also transform normal with skinMatrix
    out.uv0 = in.uv0;
    out.depth = out.positionCS.z / out.positionCS.w;

    return out;
}

// PHASE: Joints/Weights probe - visualize skinning inputs
struct JointsWeightsVertexOut {
    float4 position [[position]];
    float4 debug0;  // Joint indices as colors
    float4 debug1;  // Weight values
    float2 uv0;
};

vertex JointsWeightsVertexOut debug_joints_weights_vertex(DebugVertexIn in [[stage_in]],
                                                          constant DebugUniforms& uniforms [[buffer(1)]]) {
    JointsWeightsVertexOut out;

    // Transform position
    float4 worldPos = uniforms.modelMatrix * float4(in.position, 1.0);
    float4 viewPos = uniforms.viewMatrix * worldPos;
    out.position = uniforms.projectionMatrix * viewPos;
    out.uv0 = in.uv0;

    // Encode joint indices as colors (normalized by 255)
    uint4 j = in.joints;
    out.debug0 = float4(j.x/255.0, j.y/255.0, j.z/255.0, 1.0);

    // Store raw weights
    float4 w = in.weights;
    out.debug1 = w;

    // Flash red if weights don't sum to ~1.0
    float weightSum = dot(w, float4(1.0));
    if (abs(weightSum - 1.0) > 0.02) {
        out.debug0 = float4(1.0, 0.0, 0.0, 1.0);  // Red = bad weights
    }

    return out;
}

fragment float4 debug_joints_fragment(JointsWeightsVertexOut in [[stage_in]]) {
    // Display joint indices as colors
    return in.debug0;
}

fragment float4 debug_weights_fragment(JointsWeightsVertexOut in [[stage_in]]) {
    // Display weights as grayscale (use first weight for intensity)
    float intensity = in.debug1.x;
    return float4(intensity, intensity, intensity, 1.0);
}

// PHASE: Clip-space position visualization
// Maps clip-space positions to RGB colors to diagnose vertex transformation issues
struct ClipSpaceVertexOut {
    float4 positionCS [[position]];
    float3 clipColor;  // Clip space position as color
};

vertex ClipSpaceVertexOut debug_clip_space_vertex(DebugVertexIn in [[stage_in]],
                                                  constant DebugUniforms& uniforms [[buffer(1)]]) {
    ClipSpaceVertexOut out;

    // Transform to clip space
    float4 worldPos = uniforms.modelMatrix * float4(in.position, 1.0);
    out.positionCS = uniforms.projectionMatrix * uniforms.viewMatrix * worldPos;

    // Map clip space position to color
    // Clip space is [-w, w] for x,y,z before perspective divide
    // After divide by w, NDC is [-1, 1]
    float3 ndc = out.positionCS.xyz / out.positionCS.w;

    // Map NDC [-1, 1] to color [0, 1]
    // x: red, y: green, z: blue
    out.clipColor = ndc * 0.5 + 0.5;

    return out;
}

fragment float4 debug_clip_space_fragment(ClipSpaceVertexOut in [[stage_in]]) {
    // Output the clip-space position as color
    // If vertices are correctly transformed, we should see a gradient
    // Black = clip space minimum (-1,-1,-1)
    // White = clip space maximum (1,1,1)
    // Center of screen should be ~(0.5, 0.5, z) = purple/cyan colors
    return float4(in.clipColor, 1.0);
}