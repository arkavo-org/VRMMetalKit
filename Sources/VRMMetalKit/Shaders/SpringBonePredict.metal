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

kernel void springBonePredict(
    device float3* bonePosPrev [[buffer(0)]],
    device float3* bonePosCurr [[buffer(1)]],
    constant BoneParams* boneParams [[buffer(2)]],
    constant SpringBoneParams& globalParams [[buffer(3)]],
    uint id [[thread_position_in_grid]]
) {
    if (id >= globalParams.numBones) return;

    // Skip prediction for root bones - they are kinematically driven
    uint parentIndex = boneParams[id].parentIndex;
    if (parentIndex == 0xFFFFFFFF) {
        // Root bones maintain their animated position
        // Their position was already set by the kinematic kernel
        return;
    }

    // Save current position as previous
    bonePosPrev[id] = bonePosCurr[id];

    // Calculate wind force with time-based oscillation
    float time = globalParams.windPhase;
    float3 windForce = globalParams.windAmplitude *
                      globalParams.windDirection *
                      sin(globalParams.windFrequency * time);

    // Verlet integration with drag and external forces
    float3 velocity = bonePosCurr[id] - bonePosPrev[id];
    float dragFactor = 1.0 - boneParams[id].drag;

    float3 newPos = bonePosCurr[id] + velocity * dragFactor +
                    (globalParams.gravity + windForce) *
                    globalParams.dtSub * globalParams.dtSub;

    // Clamp step size to prevent explosion (not world position)
    // This prevents physics instability regardless of character's world position
    const float MAX_STEP = 2.0;  // Max 2 meters per substep
    float3 displacement = newPos - bonePosCurr[id];
    float stepSize = length(displacement);
    if (stepSize > MAX_STEP) {
        displacement = (displacement / stepSize) * MAX_STEP;
        newPos = bonePosCurr[id] + displacement;
    }

    bonePosCurr[id] = newPos;
}