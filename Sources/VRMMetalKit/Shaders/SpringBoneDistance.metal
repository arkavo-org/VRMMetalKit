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

struct SpringBoneParams {
    float3 gravity;
    float dtSub;
    float windAmplitude;
    float windFrequency;
    float windPhase;
    float3 windDirection;
    uint substeps;
    uint numBones;
};

struct BoneParams {
    float stiffness;
    float drag;
    float radius;
    uint parentIndex;
    float gravityPower;       // Multiplier for global gravity (0.0 = no gravity, 1.0 = full)
    uint colliderGroupMask;   // Bitmask of collision groups this bone collides with
    float3 gravityDir;        // Direction vector (normalized, typically [0, -1, 0])
};

kernel void springBoneDistance(
    device float3* bonePosCurr [[buffer(1)]],
    constant BoneParams* boneParams [[buffer(2)]],
    constant float* restLengths [[buffer(4)]],
    constant SpringBoneParams& globalParams [[buffer(3)]],
    uint id [[thread_position_in_grid]]
) {
    if (id >= globalParams.numBones) return;

    uint parentIndex = boneParams[id].parentIndex;
    if (parentIndex == 0xFFFFFFFF) return; // Skip root bones

    // Distance constraint: only prevent over-stretching, allow compression for natural hanging
    float3 delta = bonePosCurr[id] - bonePosCurr[parentIndex];
    float currentLength = length(delta);
    float restLength = restLengths[id];

    // Only apply constraint when stretched beyond rest length
    // This allows hair/cloth to compress naturally under gravity
    const float epsilon = 1e-6;
    if (currentLength > restLength && currentLength > epsilon) {
        // XPBD constraint solving
        float constraint = currentLength - restLength;

        // Compliance α = 1/(stiffness * dt²)
        float alpha = 1.0 / (boneParams[id].stiffness * globalParams.dtSub * globalParams.dtSub);

        // For hierarchical chains, parent bones are kinematically driven (infinite mass)
        // Only move the child bone, not the parent
        float invMassSum = 1.0; // Only the child moves
        float lambda = -constraint / (invMassSum + alpha);

        float3 correction = (lambda / currentLength) * delta;

        // Apply correction only to child bone (current bone)
        // Parent maintains its position (driven by animation or its own parent constraint)
        bonePosCurr[id] += correction;
    }
}