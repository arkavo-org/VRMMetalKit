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

// IBL prefiltering compute kernels.
//
// Step 3 added the BRDF LUT (`gltf_ibl_brdf_lut`).
// Step 4-final adds: procedural sky source cubemap, GGX-importance-sampled
// specular prefilter (per-mip), cosine-weighted diffuse irradiance. Together
// they replace the 1×1 gray fallback with a real environment generated on
// the GPU — no asset-shipping required, but real HDR can substitute in
// once a .ktx2 / .hdr loader exists.
//
// References:
//   - Karis 2013, "Real Shading in Unreal Engine 4" (split-sum approximation)
//   - Khronos glTF Sample Renderer (`glTF-Sample-Renderer/source/Renderer/shaders/ibl_filtering.frag`)
//   - LearnOpenGL "IBL: Specular IBL" (https://learnopengl.com/PBR/IBL/Specular-IBL)

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

// MARK: - Cubemap helpers
//
// Map a (face, u, v) coordinate where (u, v) ∈ [0, 1] to a world-space
// direction. Convention matches Metal's cubemap sampling:
//   face 0 = +X, 1 = -X, 2 = +Y, 3 = -Y, 4 = +Z, 5 = -Z

static float3 cubemapDirection(uint face, float2 uv) {
    float2 t = uv * 2.0 - 1.0;
    float3 dir;
    if (face == 0u)      dir = float3( 1.0, -t.y, -t.x);
    else if (face == 1u) dir = float3(-1.0, -t.y,  t.x);
    else if (face == 2u) dir = float3( t.x,  1.0,  t.y);
    else if (face == 3u) dir = float3( t.x, -1.0, -t.y);
    else if (face == 4u) dir = float3( t.x, -t.y,  1.0);
    else                 dir = float3(-t.x, -t.y, -1.0);
    return normalize(dir);
}

// MARK: - Procedural sky kernel
//
// Generates a simple gradient sky with a sun disk, written into a cubemap.
// Output `outCube` must be a cubemap with `.shaderWrite` usage. The kernel
// writes the full mip 0 of all six faces — dispatch grid is
// (faceSize, faceSize, 6).

struct GLTFSkyParams {
    float3 sunDirection;     // World-space direction the sun light travels.
    float _pad0;
    float3 sunColor;         // Linear RGB pre-multiplied by intensity.
    float sunAngularRadius;  // Half-angle of the sun disk, radians.
    float3 zenithColor;      // Sky tint straight up.
    float _pad1;
    float3 horizonColor;     // Sky tint at the horizon.
    float _pad2;
    float3 groundColor;      // Below the horizon (y < 0).
    float _pad3;
};

kernel void gltf_ibl_procedural_sky(
    texturecube<float, access::write> outCube [[texture(0)]],
    constant GLTFSkyParams& params [[buffer(0)]],
    uint3 gid [[thread_position_in_grid]]
) {
    uint size = outCube.get_width();
    if (gid.x >= size || gid.y >= size || gid.z >= 6u) return;

    float2 uv = (float2(gid.xy) + 0.5) / float(size);
    float3 dir = cubemapDirection(gid.z, uv);

    float3 color;
    if (dir.y >= 0.0) {
        float t = clamp(dir.y, 0.0, 1.0);
        // Smooth horizon → zenith blend; pow biases more sky toward the top.
        color = mix(params.horizonColor, params.zenithColor, pow(t, 0.6));
    } else {
        color = params.groundColor;
    }

    // Sun disk — soft falloff over a small angular radius.
    float sunCos = dot(dir, -normalize(params.sunDirection));
    float cosLimit = cos(params.sunAngularRadius);
    float sunMask = smoothstep(cosLimit, 1.0, sunCos);
    color += params.sunColor * sunMask;

    outCube.write(float4(color, 1.0), uint2(gid.xy), gid.z);
}

// MARK: - Specular prefilter (single mip)
//
// One dispatch per output mip level; the caller picks `roughness` to match
// the mip (mip 0 = 0.0, mip N-1 = 1.0). Output texture must be a cubemap
// with shaderWrite usage on the target mip slice. Source cubemap is
// sampled at mip 0 (full resolution).
//
// We use the split-sum approximation: importance-sample H around the
// surface normal N (with N == V for IBL), reflect to get L, sample the
// source environment at L, weight by NdotL.

constant uint kPrefilterSampleCount = 512u;

struct GLTFPrefilterParams {
    float roughness;
    uint mipLevel;
    uint _pad0;
    uint _pad1;
};

kernel void gltf_ibl_specular_prefilter(
    texturecube<float, access::sample> source [[texture(0)]],
    texturecube<float, access::write>  outCube [[texture(1)]],
    sampler envSampler [[sampler(0)]],
    constant GLTFPrefilterParams& params [[buffer(0)]],
    uint3 gid [[thread_position_in_grid]]
) {
    uint size = outCube.get_width();
    // Account for mip level: at higher mips the output texture face size is smaller.
    uint faceSize = max(size >> params.mipLevel, 1u);
    if (gid.x >= faceSize || gid.y >= faceSize || gid.z >= 6u) return;

    float2 uv = (float2(gid.xy) + 0.5) / float(faceSize);
    float3 N = cubemapDirection(gid.z, uv);
    float3 V = N;  // Split-sum IBL: view = normal

    // Build a tangent frame around N.
    float3 up = abs(N.y) < 0.999 ? float3(0.0, 1.0, 0.0) : float3(1.0, 0.0, 0.0);
    float3 tangentX = normalize(cross(up, N));
    float3 tangentY = cross(N, tangentX);

    float3 sumColor = float3(0.0);
    float  sumWeight = 0.0;

    for (uint i = 0u; i < kPrefilterSampleCount; ++i) {
        float2 Xi = hammersley(i, kPrefilterSampleCount);
        float3 Ht = importanceSampleGGX(Xi, params.roughness);
        // Tangent → world.
        float3 H = normalize(Ht.x * tangentX + Ht.y * tangentY + Ht.z * N);
        float3 L = normalize(2.0 * dot(V, H) * H - V);
        float NdotL = saturate(dot(N, L));
        if (NdotL > 0.0) {
            float3 envSample = source.sample(envSampler, L, level(0.0)).rgb;
            sumColor += envSample * NdotL;
            sumWeight += NdotL;
        }
    }

    float3 result = sumColor / max(sumWeight, 1e-3);
    // Write to the requested mip slice via `mip-aware` write — Metal
    // exposes this via the texture descriptor's mipmapLevelCount; the
    // caller binds a per-mip output view so `gid` indexes into that mip.
    outCube.write(float4(result, 1.0), uint2(gid.xy), gid.z);
}

// MARK: - Diffuse irradiance
//
// Cosine-weighted integration of the source environment, generating a
// pre-convolved cubemap that the fragment samples with the surface
// normal to get the diffuse ambient term in one tap.

constant float kIrradianceSampleDelta = 0.025;

// MARK: - Equirectangular → cubemap
//
// Projects an equirectangular HDR panorama (loaded from a .hdr file) into
// a cubemap. For each output cubemap texel, compute its world-space
// direction, then convert to (phi, theta) → equirectangular UV, and
// sample the source texture.

kernel void gltf_ibl_equirect_to_cube(
    texture2d<float, access::sample> source [[texture(0)]],
    texturecube<float, access::write> outCube [[texture(1)]],
    sampler envSampler [[sampler(0)]],
    uint3 gid [[thread_position_in_grid]]
) {
    uint size = outCube.get_width();
    if (gid.x >= size || gid.y >= size || gid.z >= 6u) return;

    float2 uv = (float2(gid.xy) + 0.5) / float(size);
    float3 dir = cubemapDirection(gid.z, uv);

    // Equirectangular mapping: phi = atan2(x, z), theta = acos(y).
    // UV.x = phi / (2π) + 0.5, UV.y = 1 - theta / π.
    float phi = atan2(dir.z, dir.x);
    float theta = acos(clamp(dir.y, -1.0, 1.0));
    float2 envUV = float2(phi / (2.0 * M_PI_F) + 0.5, theta / M_PI_F);
    // Flip Y so the .hdr (which usually has +Y up at row 0) lands oriented correctly.
    envUV.y = 1.0 - envUV.y;

    float3 color = source.sample(envSampler, envUV, level(0.0)).rgb;
    outCube.write(float4(color, 1.0), uint2(gid.xy), gid.z);
}

kernel void gltf_ibl_diffuse_irradiance(
    texturecube<float, access::sample> source [[texture(0)]],
    texturecube<float, access::write>  outCube [[texture(1)]],
    sampler envSampler [[sampler(0)]],
    uint3 gid [[thread_position_in_grid]]
) {
    uint size = outCube.get_width();
    if (gid.x >= size || gid.y >= size || gid.z >= 6u) return;

    float2 uv = (float2(gid.xy) + 0.5) / float(size);
    float3 N = cubemapDirection(gid.z, uv);

    float3 up = abs(N.y) < 0.999 ? float3(0.0, 1.0, 0.0) : float3(1.0, 0.0, 0.0);
    float3 right = normalize(cross(up, N));
    up = cross(N, right);

    float3 sum = float3(0.0);
    float sampleCount = 0.0;

    for (float phi = 0.0; phi < 2.0 * M_PI_F; phi += kIrradianceSampleDelta) {
        for (float theta = 0.0; theta < 0.5 * M_PI_F; theta += kIrradianceSampleDelta) {
            float3 tangentSample = float3(sin(theta) * cos(phi), sin(theta) * sin(phi), cos(theta));
            float3 sampleVec = tangentSample.x * right + tangentSample.y * up + tangentSample.z * N;
            sum += source.sample(envSampler, sampleVec, level(0.0)).rgb * cos(theta) * sin(theta);
            sampleCount += 1.0;
        }
    }

    sum = M_PI_F * sum * (1.0 / sampleCount);
    outCube.write(float4(sum, 1.0), uint2(gid.xy), gid.z);
}
