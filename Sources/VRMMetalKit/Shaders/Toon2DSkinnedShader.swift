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


import Foundation
import Metal
import simd

/// Skinned Toon2D shader for VRM 2.5D rendering with bone animation
/// Implements cel-shaded/anime-style rendering with skeletal animation support
public class Toon2DSkinnedShader {
    public static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float4x4 modelMatrix;
        float4x4 viewMatrix;
        float4x4 projectionMatrix;
        float4x4 normalMatrix;
        // Light 0 (key light) - using float4 for Swift SIMD4 alignment
        float4 lightDirection;        // xyz = direction, w = padding
        float4 lightColor;            // xyz = color, w = padding
        float4 ambientColor;          // xyz = color, w = padding
        // Light 1 (fill light)
        float4 light1Direction;       // xyz = direction, w = padding
        float4 light1Color;           // xyz = color, w = padding
        // Light 2 (rim/back light)
        float4 light2Direction;       // xyz = direction, w = padding
        float4 light2Color;           // xyz = color, w = padding
        // Other fields - packed into float4 for alignment
        float4 viewportSize;          // xy = size, zw = padding
        float4 nearFarPlane;          // x = near, y = far, zw = padding
        int debugUVs;
        float lightNormalizationFactor;
        float _padding2;
        float _padding3;
        int toonBands;
        float _padding5;
        float _padding6;
        float _padding7;
    };

    struct Toon2DMaterial {
        // Block 0: Base material
        float4 baseColorFactor;

        // Block 1: Shade color
        float3 shadeColorFactor;
        float shadingToonyFactor;

        // Block 2: Emissive and outline
        float3 emissiveFactor;
        float outlineWidth;

        // Block 3: Outline color and mode
        float3 outlineColorFactor;
        float outlineMode;

        // Block 4: Rim lighting
        float3 rimColorFactor;
        float rimFresnelPower;

        // Block 5: Rim and texture flags
        float rimLiftFactor;
        int hasBaseColorTexture;
        int hasShadeMultiplyTexture;
        int hasEmissiveTexture;

        // Block 6: Alpha
        uint32_t alphaMode;
        float alphaCutoff;
        float _padding1;
        float _padding2;
    };

    struct VertexIn {
        float3 position [[attribute(0)]];
        float3 normal [[attribute(1)]];
        float2 texCoord [[attribute(2)]];
        float4 color [[attribute(3)]];
        ushort4 joints [[attribute(4)]];
        float4 weights [[attribute(5)]];
    };

    struct VertexOut {
        float4 position [[position]];
        float3 worldPosition;
        float3 worldNormal;
        float2 texCoord;
        float4 color;
        float depth;
    };

    // MARK: - Toon Shading Utilities (shared with non-skinned)

    float quantizeLighting(float nDotL, int bands) {
        if (bands <= 0) {
            return nDotL;
        }

        float clamped = saturate(nDotL);
        float bandSize = 1.0 / float(bands);
        float quantized = floor(clamped / bandSize) * bandSize;

        return quantized;
    }

    float3 applyCelShading(
        float3 baseColor,
        float3 shadeColor,
        float nDotL,
        int bands,
        float toonyFactor
    ) {
        float quantized = quantizeLighting(nDotL, bands);
        float shadeMix = 1.0 - quantized;
        shadeMix = pow(shadeMix, 1.0 / max(toonyFactor, 0.001));

        return mix(baseColor, shadeColor, shadeMix);
    }

    float3 applyQuantizedRim(
        float3 color,
        float3 rimColor,
        float3 normal,
        float3 viewDir,
        float fresnelPower,
        float liftFactor,
        int bands
    ) {
        float nDotV = saturate(dot(normal, viewDir));
        float fresnel = pow(1.0 - nDotV, fresnelPower);
        fresnel = saturate(fresnel + liftFactor);

        if (bands > 1) {
            float bandSize = 1.0 / float(bands);
            fresnel = floor(fresnel / bandSize) * bandSize;
        }

        return color + rimColor * fresnel;
    }

    // MARK: - Skinned Vertex Shader (Main)

    vertex VertexOut skinned_toon2d_vertex(
        VertexIn in [[stage_in]],
        constant Uniforms &uniforms [[buffer(1)]],
        constant Toon2DMaterial &material [[buffer(2)]],
        constant float4x4* jointMatrices [[buffer(3)]],
        device float3* morphedPositions [[buffer(20)]],
        constant uint& hasMorphed [[buffer(22)]],
        uint vertexID [[vertex_id]]
    ) {
        VertexOut out;

        // Use morphed positions if available
        float3 basePosition;
        if (hasMorphed > 0) {
            basePosition = float3(morphedPositions[vertexID]);
        } else {
            basePosition = in.position;
        }

        // Apply skeletal skinning
        float4x4 skinMatrix = float4x4(0.0);

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

        // Pass through texture coordinates and color
        out.texCoord = in.texCoord;
        out.color = in.color;

        // Calculate depth for outline width scaling
        out.depth = viewPosition.z;

        return out;
    }

    // MARK: - Fragment Shader (shared with non-skinned)

    fragment float4 skinned_toon2d_fragment(
        VertexOut in [[stage_in]],
        constant Uniforms &uniforms [[buffer(1)]],
        constant Toon2DMaterial &material [[buffer(2)]],
        texture2d<float> baseColorTexture [[texture(0)]],
        texture2d<float> shadeMultiplyTexture [[texture(1)]],
        texture2d<float> emissiveTexture [[texture(2)]]
    ) {
        constexpr sampler textureSampler(
            mag_filter::nearest,
            min_filter::nearest,
            mip_filter::none,
            address::repeat
        );

        // Sample base color
        float4 baseColor = material.baseColorFactor;
        if (material.hasBaseColorTexture != 0) {
            float4 texColor = baseColorTexture.sample(textureSampler, in.texCoord);
            baseColor *= texColor;
        }

        // Debug UV visualization
        if (uniforms.debugUVs != 0) {
            return float4(in.texCoord.x, in.texCoord.y, 0.0, 1.0);
        }

        // Alpha test for MASK mode
        if (material.alphaMode == 1) {
            if (baseColor.a < material.alphaCutoff) {
                discard_fragment();
            }
        }

        // Calculate lighting
        float3 normal = normalize(in.worldNormal);
        float3 lightDir = normalize(-uniforms.lightDirection);
        float nDotL = dot(normal, lightDir);

        // Shade color
        float3 shadeColor = material.shadeColorFactor;
        if (material.hasShadeMultiplyTexture != 0) {
            float3 shadeTex = shadeMultiplyTexture.sample(textureSampler, in.texCoord).rgb;
            shadeColor *= shadeTex;
        }

        // Apply cel shading
        float3 litColor = applyCelShading(
            baseColor.rgb,
            shadeColor,
            nDotL,
            uniforms.toonBands,
            material.shadingToonyFactor
        );

        // Apply quantized lighting
        float3 lightContribution = litColor * uniforms.lightColor;

        // Add ambient
        float3 ambient = baseColor.rgb * uniforms.ambientColor;

        float3 finalColor = lightContribution + ambient;

        // Optional rim lighting
        if (length(material.rimColorFactor) > 0.01) {
            float3 viewDir = normalize(-in.worldPosition);
            finalColor = applyQuantizedRim(
                finalColor,
                material.rimColorFactor,
                normal,
                viewDir,
                material.rimFresnelPower,
                material.rimLiftFactor,
                uniforms.toonBands
            );
        }

        // Add emissive
        float3 emissive = material.emissiveFactor;
        if (material.hasEmissiveTexture != 0) {
            float3 emissiveTex = emissiveTexture.sample(textureSampler, in.texCoord).rgb;
            emissive *= emissiveTex;
        }
        finalColor += emissive;

        // Posterize final color
        if (material.shadingToonyFactor > 0.5) {
            int colorSteps = uniforms.toonBands * 2;
            float stepSize = 1.0 / float(colorSteps);
            finalColor = floor(finalColor / stepSize) * stepSize;
        }

        return float4(finalColor, baseColor.a);
    }

    // MARK: - Skinned Outline Vertex Shader

    vertex VertexOut skinned_toon2d_outline_vertex(
        VertexIn in [[stage_in]],
        constant Uniforms &uniforms [[buffer(1)]],
        constant Toon2DMaterial &material [[buffer(2)]],
        constant float4x4* jointMatrices [[buffer(3)]],
        device float3* morphedPositions [[buffer(20)]],
        constant uint& hasMorphed [[buffer(22)]],
        uint vertexID [[vertex_id]]
    ) {
        VertexOut out;

        // Use morphed positions if available
        float3 basePosition;
        if (hasMorphed > 0) {
            basePosition = float3(morphedPositions[vertexID]);
        } else {
            basePosition = in.position;
        }

        // Apply skeletal skinning
        float4x4 skinMatrix = float4x4(0.0);

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
        float4 skinnedPosition = skinMatrix * float4(basePosition, 1.0);
        float3 skinnedNormal = normalize((skinMatrix * float4(in.normal, 0.0)).xyz);

        // Extrude along normal for outline
        float outlineWidth = material.outlineWidth;

        if (material.outlineMode == 1.0) {
            // World-space outline
            float3 extrudedPos = skinnedPosition.xyz + skinnedNormal * outlineWidth;
            float4 worldPosition = uniforms.modelMatrix * float4(extrudedPos, 1.0);
            float4 viewPosition = uniforms.viewMatrix * worldPosition;
            out.position = uniforms.projectionMatrix * viewPosition;
        } else if (material.outlineMode == 2.0) {
            // Screen-space outline
            float4 worldPosition = uniforms.modelMatrix * skinnedPosition;
            float4 viewPosition = uniforms.viewMatrix * worldPosition;

            // Transform normal to view space
            float3 viewNormal = normalize((uniforms.viewMatrix * uniforms.normalMatrix * float4(skinnedNormal, 0.0)).xyz);

            // Extrude in view space
            viewPosition.xy += viewNormal.xy * outlineWidth * 0.01 * abs(viewPosition.z);

            out.position = uniforms.projectionMatrix * viewPosition;
        } else {
            // No outline
            float4 worldPosition = uniforms.modelMatrix * skinnedPosition;
            float4 viewPosition = uniforms.viewMatrix * worldPosition;
            out.position = uniforms.projectionMatrix * viewPosition;
        }

        // Pass through (not used in outline fragment)
        out.worldPosition = float3(0.0);
        out.worldNormal = float3(0.0);
        out.texCoord = float2(0.0);
        out.color = float4(1.0);
        out.depth = 0.0;

        return out;
    }

    // MARK: - Outline Fragment Shader (shared with non-skinned)

    fragment float4 skinned_toon2d_outline_fragment(
        VertexOut in [[stage_in]],
        constant Uniforms &uniforms [[buffer(1)]],
        constant Toon2DMaterial &material [[buffer(2)]]
    ) {
        return float4(material.outlineColorFactor, 1.0);
    }

    """  // End of shader source

    // MARK: - Function Constants

    public static func makeFunctionConstants(material: Toon2DMaterialCPU) -> MTLFunctionConstantValues {
        let constants = MTLFunctionConstantValues()

        var hasBase = material.hasBaseColorTexture
        var hasShade = material.hasShadeMultiplyTexture
        var hasEmissive = material.hasEmissiveTexture

        constants.setConstantValue(&hasBase, type: .bool, withName: "hasBaseColorTexture")
        constants.setConstantValue(&hasShade, type: .bool, withName: "hasShadeMultiplyTexture")
        constants.setConstantValue(&hasEmissive, type: .bool, withName: "hasEmissiveTexture")

        return constants
    }
}
