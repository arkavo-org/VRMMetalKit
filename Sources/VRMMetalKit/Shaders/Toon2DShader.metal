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
 int toonBands;                // Number of cel-shading bands (1-5)
 int isOrthographic;           // 1 = orthographic projection, 0 = perspective
 float _padding1;              // Align to 16 bytes
};

struct Toon2DMaterial {
 // Block 0: 16 bytes - Base material properties
 float4 baseColorFactor;                    // 16 bytes

 // Block 1: 16 bytes - Shade color and toony factor
 float3 shadeColorFactor;                   // 12 bytes
 float shadingToonyFactor;                  // 4 bytes (0.0-1.0, higher = more banded)

 // Block 2: 16 bytes - Emissive and outline
 float3 emissiveFactor;                     // 12 bytes
 float outlineWidth;                        // 4 bytes (world-space or screen-space)

 // Block 3: 16 bytes - Outline color and mode
 float3 outlineColorFactor;                 // 12 bytes
 float outlineMode;                         // 4 bytes (0: None, 1: World, 2: Screen)

 // Block 4: 16 bytes - Rim lighting (quantized)
 float3 rimColorFactor;                     // 12 bytes
 float rimFresnelPower;                     // 4 bytes

 // Block 5: 16 bytes - Rim and texture flags
 float rimLiftFactor;                       // 4 bytes
 int hasBaseColorTexture;                   // 4 bytes
 int hasShadeMultiplyTexture;               // 4 bytes
 int hasEmissiveTexture;                    // 4 bytes

 // Block 6: 16 bytes - Alpha and padding
 uint32_t alphaMode;                        // 4 bytes (0: OPAQUE, 1: MASK, 2: BLEND)
 float alphaCutoff;                         // 4 bytes
 float _padding1;                           // 4 bytes
 float _padding2;                           // 4 bytes
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
 float4 color;
 float depth;                  // For outline width calculation
};

// MARK: - Toon Shading Utilities

/// Quantize lighting to discrete bands
float quantizeLighting(float nDotL, int bands) {
 if (bands <= 0) {
 return nDotL;  // No quantization
 }

 // Clamp and normalize
 float clamped = saturate(nDotL);

 // Quantize to bands
 float bandSize = 1.0 / float(bands);
 float quantized = floor(clamped / bandSize) * bandSize;

 return quantized;
}

/// Apply cel-shaded lighting
float3 applyCelShading(
 float3 baseColor,
 float3 shadeColor,
 float nDotL,
 int bands,
 float toonyFactor
) {
 // Quantize lighting
 float quantized = quantizeLighting(nDotL, bands);

 // Mix between base and shade color based on quantized lighting
 // toonyFactor controls how sharp the transition is
 float shadeMix = 1.0 - quantized;
 shadeMix = pow(shadeMix, 1.0 / max(toonyFactor, 0.001));

 return mix(baseColor, shadeColor, shadeMix);
}

/// Quantized rim lighting (stepped Fresnel)
float3 applyQuantizedRim(
 float3 color,
 float3 rimColor,
 float3 normal,
 float3 viewDir,
 float fresnelPower,
 float liftFactor,
 int bands
) {
 // Fresnel term
 float nDotV = saturate(dot(normal, viewDir));
 float fresnel = pow(1.0 - nDotV, fresnelPower);

 // Apply lift
 fresnel = saturate(fresnel + liftFactor);

 // Quantize rim to bands
 if (bands > 1) {
 float bandSize = 1.0 / float(bands);
 fresnel = floor(fresnel / bandSize) * bandSize;
 }

 // Add rim lighting
 return color + rimColor * fresnel;
}

// MARK: - Vertex Shader (Main)

vertex VertexOut vertex_main(
 VertexIn in [[stage_in]],
 constant Uniforms &uniforms [[buffer(1)]],
 constant Toon2DMaterial &material [[buffer(2)]]
) {
 VertexOut out;

 // Transform position
 float4 worldPosition = uniforms.modelMatrix * float4(in.position, 1.0);
 float4 viewPosition = uniforms.viewMatrix * worldPosition;
 out.position = uniforms.projectionMatrix * viewPosition;

 out.worldPosition = worldPosition.xyz;

 // Transform normal
 float3 worldNormal = normalize((uniforms.normalMatrix * float4(in.normal, 0.0)).xyz);
 out.worldNormal = worldNormal;

 // Pass through texture coordinates and color
 out.texCoord = in.texCoord;
 out.color = in.color;

 // Calculate depth for outline width scaling
 out.depth = viewPosition.z;

 return out;
}

// MARK: - Fragment Shader (Main)

fragment float4 fragment_main(
 VertexOut in [[stage_in]],
 constant Uniforms &uniforms [[buffer(1)]],
 constant Toon2DMaterial &material [[buffer(2)]],
 texture2d<float> baseColorTexture [[texture(0)]],
 texture2d<float> shadeMultiplyTexture [[texture(1)]],
 texture2d<float> emissiveTexture [[texture(2)]]
) {
 constexpr sampler textureSampler(
 mag_filter::nearest,     // Nearest for crisp 2D look
 min_filter::nearest,
 mip_filter::none,        // No mipmapping for flat look
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
 if (material.alphaMode == 1) {  // MASK
 if (baseColor.a < material.alphaCutoff) {
     discard_fragment();
 }
 }

 // Calculate lighting
 float3 normal = normalize(in.worldNormal);
 float3 lightDir = normalize(-uniforms.lightDirection);
 float nDotL = dot(normal, lightDir);

 // Shade color (can be modulated by texture)
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

 // Apply quantized lighting from directional light
 float3 lightContribution = litColor * uniforms.lightColor;

 // Add ambient (unquantized for fill)
 float3 ambient = baseColor.rgb * uniforms.ambientColor;

 float3 finalColor = lightContribution + ambient;

 // Optional: Quantized rim lighting
 if (length(material.rimColorFactor) > 0.01) {
 float3 viewDir = normalize(-in.worldPosition);  // Camera assumed at origin
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

 // Add emissive (unquantized, always full brightness)
 float3 emissive = material.emissiveFactor;
 if (material.hasEmissiveTexture != 0) {
 float3 emissiveTex = emissiveTexture.sample(textureSampler, in.texCoord).rgb;
 emissive *= emissiveTex;
 }
 finalColor += emissive;

 // Posterize final color (optional, controlled by toonyFactor)
 // Higher toonyFactor = more posterization
 if (material.shadingToonyFactor > 0.5) {
 int colorSteps = uniforms.toonBands * 2;  // More granular than lighting
 float stepSize = 1.0 / float(colorSteps);
 finalColor = floor(finalColor / stepSize) * stepSize;
 }

 return float4(finalColor, baseColor.a);
}

// MARK: - Outline Vertex Shader (Inverted Hull)

vertex VertexOut outline_vertex(
 VertexIn in [[stage_in]],
 constant Uniforms &uniforms [[buffer(1)]],
 constant Toon2DMaterial &material [[buffer(2)]]
) {
 VertexOut out;

 // Extrude vertex along normal for outline
 float outlineWidth = material.outlineWidth;

 // Scale by mode
 if (material.outlineMode == 1.0) {
 // World-space: constant thickness regardless of distance
 float3 extrudedPos = in.position + in.normal * outlineWidth;
 float4 worldPosition = uniforms.modelMatrix * float4(extrudedPos, 1.0);
 float4 viewPosition = uniforms.viewMatrix * worldPosition;
 out.position = uniforms.projectionMatrix * viewPosition;
 } else if (material.outlineMode == 2.0) {
 // Screen-space: thickness scales with distance
 float4 worldPosition = uniforms.modelMatrix * float4(in.position, 1.0);
 float4 viewPosition = uniforms.viewMatrix * worldPosition;

 // Transform normal to view space
 float3 viewNormal = normalize((uniforms.viewMatrix * uniforms.normalMatrix * float4(in.normal, 0.0)).xyz);

 // Extrude in view space
 viewPosition.xy += viewNormal.xy * outlineWidth * 0.01 * abs(viewPosition.z);

 out.position = uniforms.projectionMatrix * viewPosition;
 } else {
 // No outline
 float4 worldPosition = uniforms.modelMatrix * float4(in.position, 1.0);
 float4 viewPosition = uniforms.viewMatrix * worldPosition;
 out.position = uniforms.projectionMatrix * viewPosition;
 }

 // Pass through (not used in outline fragment shader, but required for struct)
 out.worldPosition = float3(0.0);
 out.worldNormal = float3(0.0);
 out.texCoord = float2(0.0);
 out.color = float4(1.0);
 out.depth = 0.0;

 return out;
}

// MARK: - Outline Fragment Shader

fragment float4 outline_fragment(
 VertexOut in [[stage_in]],
 constant Uniforms &uniforms [[buffer(1)]],
 constant Toon2DMaterial &material [[buffer(2)]]
) {
 // Solid outline color
 return float4(material.outlineColorFactor, 1.0);
}

