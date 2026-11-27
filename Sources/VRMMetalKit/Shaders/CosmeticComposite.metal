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

#include <metal_stdlib>
using namespace metal;

struct CosmeticBaseCopyParams {
    float4 solidColor;
    float4 baseMultiplier;
    uint32_t hasBaseTexture;
    uint32_t decodeBaseSRGB;
    uint32_t pad0;
    uint32_t pad1;
};

struct CosmeticLayerParams {
    float4 tint;
    float2 rectMin;
    float2 rectSize;
    float2 uvOffset;
    float2 uvScale;
    float uvRotation;
    float opacity;
    uint32_t blendMode;
    uint32_t decodeLayerSRGB;
    float finishMetallic;
    float finishRoughness;
    uint32_t hasFinish;
    uint32_t pad0;
};

struct CosmeticFinalizeParams {
    uint32_t encodeSRGB;
    uint32_t pad0;
    uint32_t pad1;
    uint32_t pad2;
};

static inline float3 cosmeticSRGBToLinear(float3 c) {
    float3 low = c / 12.92f;
    float3 high = pow(max((c + 0.055f) / 1.055f, float3(0.0f)), float3(2.4f));
    return select(high, low, c <= 0.04045f);
}

static inline float3 cosmeticLinearToSRGB(float3 c) {
    float3 clamped = saturate(c);
    float3 low = clamped * 12.92f;
    float3 high = 1.055f * pow(max(clamped, float3(0.0f)), float3(1.0f / 2.4f)) - 0.055f;
    return select(high, low, clamped <= 0.0031308f);
}

static inline bool computeLayerSampleUV(
    uint2 gid,
    uint2 dims,
    constant CosmeticLayerParams& params,
    thread float2& outSampleUV
) {
    float2 dstUV = (float2(gid) + 0.5f) / float2(dims);
    float2 rectSize = max(params.rectSize, float2(1e-6f));
    float2 localUV = (dstUV - params.rectMin) / rectSize;

    // Strict landmark/region bounds clip before UV transform
    float2 centered = localUV - float2(0.5f) - params.uvOffset;
    float c = cos(-params.uvRotation);
    float s = sin(-params.uvRotation);
    float2 rotated = float2(c * centered.x - s * centered.y, s * centered.x + c * centered.y);
    float2 uvScale = max(params.uvScale, float2(1e-6f));
    float2 sampleUV = rotated / uvScale + float2(0.5f);

    if (sampleUV.x < 0.0f || sampleUV.x > 1.0f || sampleUV.y < 0.0f || sampleUV.y > 1.0f) {
        return false;
    }
    outSampleUV = sampleUV;
    return true;
}

/// Initializes a linear float16 working canvas either by sampling `baseTexture`
/// (supporting compressed/BC7/sRGB/resized sources) or filling with `solidColor`.
kernel void cosmetic_copy_base(
    texture2d<float, access::sample> baseTexture [[texture(0)]],
    texture2d<float, access::write> outCanvas [[texture(1)]],
    constant CosmeticBaseCopyParams& params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint width = outCanvas.get_width();
    uint height = outCanvas.get_height();
    if (gid.x >= width || gid.y >= height) { return; }

    float4 color = params.solidColor;
    if (params.hasBaseTexture != 0u) {
        constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
        float2 uv = (float2(gid) + 0.5f) / float2(width, height);
        color = baseTexture.sample(linearSampler, uv);
        if (params.decodeBaseSRGB != 0u) {
            color.rgb = cosmeticSRGBToLinear(color.rgb);
        }
        color *= params.baseMultiplier;
    }
    outCanvas.write(color, gid);
}

/// Composites one cosmetic layer onto the linear working canvas.
/// Blend modes: 0=normal, 1=multiply, 2=screen, 3=overlay, 4=additive, 5=eraseAlpha.
kernel void cosmetic_composite_layer(
    texture2d<float, access::read> srcCanvas [[texture(0)]],
    texture2d<float, access::sample> layerTexture [[texture(1)]],
    texture2d<float, access::write> dstCanvas [[texture(2)]],
    constant CosmeticLayerParams& params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint width = dstCanvas.get_width();
    uint height = dstCanvas.get_height();
    if (gid.x >= width || gid.y >= height) { return; }

    float4 dst = srcCanvas.read(gid);

    float2 sampleUV;
    if (!computeLayerSampleUV(gid, uint2(width, height), params, sampleUV)) {
        dstCanvas.write(dst, gid);
        return;
    }

    constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    float4 layerSample = layerTexture.sample(linearSampler, sampleUV);
    if (params.decodeLayerSRGB != 0u) {
        layerSample.rgb = cosmeticSRGBToLinear(layerSample.rgb);
    }

    float3 srcRGB = layerSample.rgb * params.tint.rgb;
    float srcA = saturate(layerSample.a * params.tint.a * params.opacity);

    if (srcA <= 1e-6f) {
        dstCanvas.write(dst, gid);
        return;
    }

    float3 outRGB = dst.rgb;
    float outA = dst.a;

    switch (params.blendMode) {
        case 0u: { // normal (Porter-Duff source-over)
            outA = srcA + dst.a * (1.0f - srcA);
            outRGB = outA > 1e-6f
                ? (srcRGB * srcA + dst.rgb * dst.a * (1.0f - srcA)) / outA
                : float3(0.0f);
            break;
        }
        case 1u: { // multiply
            outRGB = mix(dst.rgb, dst.rgb * srcRGB, srcA);
            outA = dst.a;
            break;
        }
        case 2u: { // screen
            float3 scr = 1.0f - (1.0f - saturate(dst.rgb)) * (1.0f - saturate(srcRGB));
            outRGB = mix(dst.rgb, scr, srcA);
            outA = max(dst.a, srcA);
            break;
        }
        case 3u: { // overlay
            float3 d = saturate(dst.rgb);
            float3 s = saturate(srcRGB);
            float3 ov;
            ov.r = d.r < 0.5f ? (2.0f * d.r * s.r) : (1.0f - 2.0f * (1.0f - d.r) * (1.0f - s.r));
            ov.g = d.g < 0.5f ? (2.0f * d.g * s.g) : (1.0f - 2.0f * (1.0f - d.g) * (1.0f - s.g));
            ov.b = d.b < 0.5f ? (2.0f * d.b * s.b) : (1.0f - 2.0f * (1.0f - d.b) * (1.0f - s.b));
            outRGB = mix(dst.rgb, ov, srcA);
            outA = dst.a;
            break;
        }
        case 4u: { // additive
            outRGB = dst.rgb + srcRGB * srcA;
            outA = max(dst.a, srcA);
            break;
        }
        case 5u: { // eraseAlpha
            outRGB = dst.rgb;
            outA = dst.a * (1.0f - srcA);
            break;
        }
        default: {
            break;
        }
    }

    dstCanvas.write(float4(outRGB, saturate(outA)), gid);
}

/// Composites one cosmetic layer's finish override onto a glTF metallic/roughness
/// canvas (G = roughness, B = metallic).
kernel void cosmetic_composite_finish(
    texture2d<float, access::read> srcCanvas [[texture(0)]],
    texture2d<float, access::sample> layerTexture [[texture(1)]],
    texture2d<float, access::write> dstCanvas [[texture(2)]],
    constant CosmeticLayerParams& params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint width = dstCanvas.get_width();
    uint height = dstCanvas.get_height();
    if (gid.x >= width || gid.y >= height) { return; }

    float4 dst = srcCanvas.read(gid);

    float2 sampleUV;
    if (!computeLayerSampleUV(gid, uint2(width, height), params, sampleUV)) {
        dstCanvas.write(dst, gid);
        return;
    }

    constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    float4 layerSample = layerTexture.sample(linearSampler, sampleUV);
    float srcA = saturate(layerSample.a * params.tint.a * params.opacity);

    if (srcA <= 1e-6f) {
        dstCanvas.write(dst, gid);
        return;
    }

    if (params.blendMode == 5u) {
        // eraseAlpha restores matte finish (G=1 roughness, B=0 metallic)
        dst.g = mix(dst.g, 1.0f, srcA);
        dst.b = mix(dst.b, 0.0f, srcA);
    } else if (params.hasFinish != 0u) {
        dst.g = mix(dst.g, saturate(params.finishRoughness), srcA);
        dst.b = mix(dst.b, saturate(params.finishMetallic), srcA);
    }

    dstCanvas.write(dst, gid);
}

/// Writes the linear working canvas into the final 8-bit storage view,
/// encoding linear RGB to sRGB when targeting an `_srgb` output texture.
kernel void cosmetic_finalize_output(
    texture2d<float, access::read> srcCanvas [[texture(0)]],
    texture2d<float, access::write> outTexture [[texture(1)]],
    constant CosmeticFinalizeParams& params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint width = outTexture.get_width();
    uint height = outTexture.get_height();
    if (gid.x >= width || gid.y >= height) { return; }

    float4 c = srcCanvas.read(gid);
    float3 rgb = (params.encodeSRGB != 0u) ? cosmeticLinearToSRGB(c.rgb) : saturate(c.rgb);
    outTexture.write(float4(rgb, saturate(c.a)), gid);
}
