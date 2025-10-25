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
};

// Updates root bone positions from animated transforms
kernel void springBoneKinematic(
    device float3* bonePosCurr [[buffer(1)]],
    device float3* bonePosPrev [[buffer(0)]],
    constant float3* animatedRootPositions [[buffer(5)]], // New buffer for animated positions
    constant uint* rootBoneIndices [[buffer(6)]], // Indices of root bones
    constant uint& numRootBones [[buffer(7)]],
    uint id [[thread_position_in_grid]]
) {
    if (id >= numRootBones) return;

    uint boneIndex = rootBoneIndices[id];
    float3 animatedPos = animatedRootPositions[id];

    // Store previous position for velocity calculation
    float3 previousPos = bonePosCurr[boneIndex];

    // Update current position to match animated transform
    bonePosCurr[boneIndex] = animatedPos;

    // Update previous position to maintain velocity
    // This ensures smooth transitions when the animation moves
    bonePosPrev[boneIndex] = previousPos;
}