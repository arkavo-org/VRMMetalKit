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

// SCAFFOLDING — Phase 3a step 1.
// Real PBR (Lambert + GGX direct + IBL split-sum + Khronos PBR Neutral
// tonemap) lands in Phase 3a step 2. KHR_materials_unlit fragment variant
// in step 4. Skinning + morph variants in Phase 3b.

#include <metal_stdlib>
using namespace metal;

struct GLTFVertexIn {
    float3 position  [[attribute(0)]];
};

struct GLTFVertexOut {
    float4 position [[position]];
};

vertex GLTFVertexOut gltf_pbr_vertex(GLTFVertexIn in [[stage_in]]) {
    GLTFVertexOut out;
    out.position = float4(in.position, 1.0);
    return out;
}

fragment float4 gltf_pbr_fragment(GLTFVertexOut in [[stage_in]]) {
    // Reference `in` so -Wunused-parameter passes under the Makefile's -Werror policy.
    return float4(0.5, 0.5, 0.5, in.position.w);
}
