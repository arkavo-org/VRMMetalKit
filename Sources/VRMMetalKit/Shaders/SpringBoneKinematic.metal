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
    float3 gravity;       // offset 0
    float dtSub;          // offset 16 (after float3 padding)
    float windAmplitude;  // offset 20
    float windFrequency;  // offset 24
    float windPhase;      // offset 28
    float3 windDirection; // offset 32
    uint substeps;        // offset 48
    uint numBones;        // offset 52
    uint numSpheres;      // offset 56
    uint numCapsules;     // offset 60
    uint numPlanes;       // offset 64
    uint settlingFrames;  // offset 68 - frames remaining in settling period
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

// Updates root bone positions from animated transforms.
// Buffer indices: 8 = animatedRootPositions, 9 = rootBoneIndices,
// 10 = numRootBones, 12 = animatedRootPositionsPrev (this-frame's previous
// animated pose, populated by the host before the substep loop).
//
// Bug #4 fix: bonePosPrev[root] used to come from bonePosCurr[boneIndex],
// which can be polluted by collision pushes (or any other write into
// bonePosCurr) — that contaminated the kinematic velocity history. We now
// read previousPos from a dedicated mirror buffer that is only updated at
// frame boundaries, so velocity = curr - prev is always relative to the
// last frame's animated target, regardless of what else touches
// bonePosCurr in between.
kernel void springBoneKinematic(
    device float3* bonePosCurr [[buffer(1)]],
    device float3* bonePosPrev [[buffer(0)]],
    constant float3* animatedRootPositions [[buffer(8)]],
    constant uint* rootBoneIndices [[buffer(9)]],
    constant uint& numRootBones [[buffer(10)]],
    constant float3* animatedRootPositionsPrev [[buffer(12)]],
    uint id [[thread_position_in_grid]]
) {
    if (id >= numRootBones) return;

    uint boneIndex = rootBoneIndices[id];
    float3 animatedPos = animatedRootPositions[id];
    float3 previousAnimatedPos = animatedRootPositionsPrev[id];

    // Drive root forward kinematically and pin its velocity history to the
    // previous frame's animated pose.
    bonePosCurr[boneIndex] = animatedPos;
    bonePosPrev[boneIndex] = previousAnimatedPos;
}