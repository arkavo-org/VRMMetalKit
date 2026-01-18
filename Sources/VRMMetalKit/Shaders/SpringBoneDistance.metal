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

    float3 delta = bonePosCurr[id] - bonePosCurr[parentIndex];
    float currentLength = length(delta);
    float restLength = restLengths[id];

    const float epsilon = 1e-6;
    if (currentLength > epsilon && restLength > epsilon) {
        float error = currentLength - restLength;
        float3 direction = delta / currentLength;

        // DISTANCE CONSTRAINT: Prevent excessive stretching
        // This is independent of stiffness (stiffness is for bind pose return)
        //
        // Only correct STRETCH (error > 0), not compression.
        // This allows gravity to pull bones down naturally while preventing
        // the chain from stretching infinitely (which happens when stiffness=0).
        //
        // Allow small amount of stretch (5% tolerance) for natural physics,
        // then apply full correction for anything beyond.
        float stretchTolerance = restLength * 0.05;

        if (error > stretchTolerance) {
            // Correct stretch beyond tolerance - move bone back toward parent
            float correctionAmount = error - stretchTolerance;
            float3 correction = direction * correctionAmount;
            bonePosCurr[id] = bonePosCurr[id] - correction;
        }
        // Compression (error < 0) is allowed - this is how gravity pulls bones down
    } else if (restLength > epsilon && currentLength < epsilon) {
        // If bone collapsed to parent position, push it out by rest length
        bonePosCurr[id] = bonePosCurr[parentIndex] + float3(0, -restLength, 0);
    }
}