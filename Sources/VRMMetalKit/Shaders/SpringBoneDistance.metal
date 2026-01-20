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
    constant float3* bindDirections [[buffer(11)]],
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

        // DISTANCE CONSTRAINT: Maintain bone length within tolerance
        // This is independent of stiffness (stiffness is for bind pose return)
        //
        // Allow small amount of flex (5% tolerance) for natural physics,
        // then apply correction for anything beyond.
        float tolerance = restLength * 0.05;

        if (error > tolerance) {
            // STRETCH correction: bone is too far from parent, pull it back
            // Use current direction (reliable when stretched)
            float3 direction = delta / currentLength;
            float correctionAmount = error - tolerance;
            float3 correction = direction * correctionAmount;
            bonePosCurr[id] = bonePosCurr[id] - correction;
        } else if (error < -tolerance) {
            // COMPRESSION correction: bone is too close to parent, push it out
            //
            // CRITICAL FIX: When chain is collapsed (currentLength < 50% of restLength),
            // the delta direction becomes unreliable (may point wrong way).
            // Use bind direction as push direction instead.
            //
            // This ensures hair extends in the correct direction even when collapsed.
            float3 direction;
            if (currentLength < restLength * 0.5) {
                // Chain is severely collapsed - use bind direction
                float3 bindDir = bindDirections[id];
                float bindLen = length(bindDir);
                direction = (bindLen > 0.001) ? (bindDir / bindLen) : float3(0, -1, 0);
            } else {
                // Normal compression - use current direction
                direction = delta / currentLength;
            }

            // Full strength correction for compression (was 50%, too weak)
            float correctionAmount = -error - tolerance;
            float3 correction = direction * correctionAmount;
            bonePosCurr[id] = bonePosCurr[id] + correction;
        }
    } else if (restLength > epsilon && currentLength < epsilon) {
        // If bone fully collapsed to parent position, use bind direction to push out
        float3 bindDir = bindDirections[id];
        float bindLen = length(bindDir);
        float3 pushDir = (bindLen > 0.001) ? (bindDir / bindLen) : float3(0, -1, 0);
        bonePosCurr[id] = bonePosCurr[parentIndex] + pushDir * restLength;
    }
}