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

kernel void springBonePredict(
    device float3* bonePosPrev [[buffer(0)]],
    device float3* bonePosCurr [[buffer(1)]],
    constant BoneParams* boneParams [[buffer(2)]],
    constant SpringBoneParams& globalParams [[buffer(3)]],
    constant float* restLengths [[buffer(4)]],
    constant float3* bindDirections [[buffer(11)]],
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

    // CRITICAL: Calculate velocity BEFORE saving previous position
    // This is the core of Verlet integration - velocity is implicit in position difference
    float3 velocity = bonePosCurr[id] - bonePosPrev[id];

    // INERTIA COMPENSATION: When parent moves UP, child should maintain its WORLD position
    // momentarily due to inertia. Without compensation, constraint corrections from the
    // previous frame become velocity this frame - when parent moves up, constraint pulls
    // child up, and that becomes upward velocity.
    //
    // DIRECTION-AWARE: Only compensate for UPWARD parent movement (fighting gravity).
    // During descent/landing, let hair float naturally - compensating downward movement
    // would create upward force and make hair shoot up on landing.
    //
    // We scale the compensation based on movement magnitude:
    // - Small movements (idle breathing/sway): minimal compensation, hair follows gently
    // - Large movements (jumps): full compensation, hair trails behind with inertia
    float3 parentDelta = bonePosCurr[parentIndex] - bonePosPrev[parentIndex];

    // Only compensate for upward Y movement - no lateral compensation
    // Lateral compensation can push bangs into the face during head tilts
    float3 compensatedDelta = float3(
        0.0,                      // No X compensation
        max(0.0, parentDelta.y),  // Only upward movement
        0.0                       // No Z compensation
    );

    float parentSpeed = length(compensatedDelta);
    float compensationFactor = smoothstep(0.002, 0.02, parentSpeed);
    velocity = velocity - compensatedDelta * compensationFactor;

    // Now save current position as previous for next frame
    bonePosPrev[id] = bonePosCurr[id];

    // Calculate wind force with time-based oscillation
    float time = globalParams.windPhase;
    float3 windForce = globalParams.windAmplitude *
                      globalParams.windDirection *
                      sin(globalParams.windFrequency * time);

    // Verlet integration with drag and external forces
    float dragFactor = 1.0 - boneParams[id].drag;

    // Apply per-joint gravity: use gravityDir as direction, gravityPower as magnitude
    // gravityDir is the direction gravity pulls (typically [0, -1, 0] for downward)
    // gravityPower scales the effect (0.0 = no gravity, 1.0 = full gravity)
    float gravityMagnitude = length(globalParams.gravity);  // Usually 9.8
    float3 effectiveGravity = boneParams[id].gravityDir * gravityMagnitude * boneParams[id].gravityPower;

    // Verlet integration: position += velocity * drag + acceleration * dt²
    // Drag is the velocity damping factor (0.0 = no drag, full velocity; 1.0 = full drag, no velocity)
    float3 newPos = bonePosCurr[id] + velocity * dragFactor +
                    (effectiveGravity + windForce) *
                    globalParams.dtSub * globalParams.dtSub;

    // Stiffness spring force: pulls bone toward its bind pose direction from parent
    // This makes hair return to its styled position after being disturbed
    float3 parentPos = bonePosCurr[parentIndex];
    float3 bindDir = bindDirections[id];
    float restLength = restLengths[id];

    // Safety: only apply stiffness if data is valid (no NaN propagation)
    float bindDirLen = length(bindDir);
    bool stiffnessValid = !isnan(parentPos.x) && !isnan(parentPos.y) && !isnan(parentPos.z)
                       && bindDirLen > 0.001 && restLength > 0.0;

    if (stiffnessValid) {
        // Normalize bindDir if needed
        float3 safeBindDir = bindDir / bindDirLen;
        float3 targetPos = parentPos + safeBindDir * restLength;

        float stiffness = boneParams[id].stiffness;
        float3 toTarget = targetPos - newPos;
        float distToTarget = length(toTarget);

        // Only apply stiffness when significantly displaced from target
        if (distToTarget > 0.001 && stiffness > 0.0) {
            float3 targetDir = toTarget / distToTarget;
            float pullStrength = stiffness * globalParams.dtSub * 0.5;
            newPos = newPos + targetDir * min(distToTarget, pullStrength * distToTarget);
        }
    }

    // Clamp step size to prevent explosion
    const float MAX_STEP = 2.0;
    float3 displacement = newPos - bonePosCurr[id];
    float stepSize = length(displacement);
    if (stepSize > MAX_STEP) {
        displacement = (displacement / stepSize) * MAX_STEP;
        newPos = bonePosCurr[id] + displacement;
    }

    // Final NaN safety check - if result is NaN, keep previous position
    if (isnan(newPos.x) || isnan(newPos.y) || isnan(newPos.z)) {
        newPos = bonePosCurr[id];
    }

    bonePosCurr[id] = newPos;
}