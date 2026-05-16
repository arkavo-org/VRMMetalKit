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

// IBL prefiltering compute kernels — Phase 3a step 3.
//
// This pass provides the BRDF LUT generation. The LUT is view-independent
// for a given BRDF, so each `GLTFRenderer` generates it once at init time
// and caches the result on the device — there is no need to ship a baked
// texture as a resource.
//
// References:
//   - Karis 2013, "Real Shading in Unreal Engine 4" (split-sum approximation)
//   - Khronos glTF Sample Renderer (`glTF-Sample-Renderer/source/Renderer/shaders/ibl_filtering.frag`)

#include <metal_stdlib>
using namespace metal;

// MARK: - Hammersley low-discrepancy sequence (2D)

static float radicalInverse_VdC(uint bits) {
    bits = (bits << 16u) | (bits >> 16u);
    bits = ((bits & 0x55555555u) << 1u) | ((bits & 0xAAAAAAAAu) >> 1u);
    bits = ((bits & 0x33333333u) << 2u) | ((bits & 0xCCCCCCCCu) >> 2u);
    bits = ((bits & 0x0F0F0F0Fu) << 4u) | ((bits & 0xF0F0F0F0u) >> 4u);
    bits = ((bits & 0x00FF00FFu) << 8u) | ((bits & 0xFF00FF00u) >> 8u);
    return float(bits) * 2.3283064365386963e-10;
}

static float2 hammersley(uint i, uint N) {
    return float2(float(i) / float(N), radicalInverse_VdC(i));
}

// MARK: - GGX importance sampling

static float3 importanceSampleGGX(float2 Xi, float roughness) {
    float a = roughness * roughness;
    float phi = 2.0 * M_PI_F * Xi.x;
    float cosTheta = sqrt((1.0 - Xi.y) / (1.0 + (a * a - 1.0) * Xi.y));
    float sinTheta = sqrt(max(0.0, 1.0 - cosTheta * cosTheta));
    return float3(cos(phi) * sinTheta, sin(phi) * sinTheta, cosTheta);
}

// IBL geometry term — Smith with k = a² / 2 (no +1 step; the split-sum
// integral cancels NdotV in the denominator).
static float geometrySchlickGGX_IBL(float NdotV, float roughness) {
    float a = roughness;
    float k = (a * a) / 2.0;
    return NdotV / (NdotV * (1.0 - k) + k);
}

static float geometrySmith_IBL(float NdotV, float NdotL, float roughness) {
    return geometrySchlickGGX_IBL(NdotV, roughness) * geometrySchlickGGX_IBL(NdotL, roughness);
}

// MARK: - BRDF LUT kernel
//
// Integrates the GGX BRDF over the hemisphere for (NdotV, roughness),
// returning (scale, bias) per Karis 2013:
//   ∫ BRDF * NdotL = F0 * scale + bias
//
// Output texture must be RG16Float (or RGBA16Float — only .rg is written).
// Caller dispatches threadgroups covering width × height; each thread fills
// one texel.

constant uint kBRDFSampleCount = 1024u;

kernel void gltf_ibl_brdf_lut(
    texture2d<float, access::write> outLUT [[texture(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint width  = outLUT.get_width();
    uint height = outLUT.get_height();
    if (gid.x >= width || gid.y >= height) return;

    // Map texel center → (NdotV, roughness) in [0, 1].
    float NdotV     = (float(gid.x) + 0.5) / float(width);
    float roughness = (float(gid.y) + 0.5) / float(height);

    // V in tangent space — only NdotV matters (rotational symmetry).
    // N is implicit (0, 0, 1); H.z is NdotH and L.z is NdotL.
    float3 V = float3(sqrt(1.0 - NdotV * NdotV), 0.0, NdotV);

    float A = 0.0;
    float B = 0.0;

    for (uint i = 0u; i < kBRDFSampleCount; ++i) {
        float2 Xi = hammersley(i, kBRDFSampleCount);
        float3 H  = importanceSampleGGX(Xi, roughness);
        float3 L  = normalize(2.0 * dot(V, H) * H - V);

        float NdotL = max(L.z, 0.0);
        float NdotH = max(H.z, 0.0);
        float VdotH = max(dot(V, H), 0.0);

        if (NdotL > 0.0) {
            float G = geometrySmith_IBL(NdotV, NdotL, roughness);
            float G_Vis = (G * VdotH) / (NdotH * NdotV);
            float Fc = pow(1.0 - VdotH, 5.0);
            A += (1.0 - Fc) * G_Vis;
            B += Fc * G_Vis;
        }
    }

    A /= float(kBRDFSampleCount);
    B /= float(kBRDFSampleCount);

    outLUT.write(float4(A, B, 0.0, 1.0), gid);
}
