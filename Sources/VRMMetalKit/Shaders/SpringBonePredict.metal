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
    uint settlingFrames;  // offset 68 - frames remaining in settling period (skip inertia compensation when > 0)
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

    // EARLY NaN DETECTION: If current position is already corrupted, reset immediately
    float3 currPos = bonePosCurr[id];
    float3 prevPos = bonePosPrev[id];
    float restLength = restLengths[id];

    if (isnan(currPos.x) || isnan(currPos.y) || isnan(currPos.z) ||
        isinf(currPos.x) || isinf(currPos.y) || isinf(currPos.z)) {
        // Current position is corrupted - reset to hanging position below parent
        float3 parentPos = bonePosCurr[parentIndex];
        float safeRestLen = max(restLength, 0.01);
        float3 resetPos = parentPos + float3(0.0, -safeRestLen, 0.0);
        bonePosCurr[id] = resetPos;
        bonePosPrev[id] = resetPos;
        return;
    }

    if (isnan(prevPos.x) || isnan(prevPos.y) || isnan(prevPos.z) ||
        isinf(prevPos.x) || isinf(prevPos.y) || isinf(prevPos.z)) {
        // Previous position is corrupted - set to current to zero velocity
        bonePosPrev[id] = currPos;
        prevPos = currPos;
    }

    // CRITICAL: Calculate velocity BEFORE saving previous position
    // This is the core of Verlet integration - velocity is implicit in position difference
    float3 velocity = bonePosCurr[id] - bonePosPrev[id];

    // VELOCITY CLAMPING: Prevent velocity from growing unbounded
    // Max velocity of 1.0 m/frame at 120Hz = 120 m/s, more than enough for any realistic motion
    const float MAX_VELOCITY = 1.0;
    float velocityMag = length(velocity);
    if (velocityMag > MAX_VELOCITY) {
        velocity = (velocity / velocityMag) * MAX_VELOCITY;
    }

    // NaN check on velocity - reset to zero if invalid
    if (isnan(velocity.x) || isnan(velocity.y) || isnan(velocity.z)) {
        velocity = float3(0.0);
    }

    // INERTIA COMPENSATION: When parent moves UP, child should maintain its WORLD position
    // momentarily due to inertia. Without compensation, constraint corrections from the
    // previous frame become velocity this frame - when parent moves up, constraint pulls
    // child up, and that becomes upward velocity.
    //
    // SETTLING PERIOD: Skip compensation during initial frames to let bones settle naturally
    // with gravity. Otherwise compensation fights the settling and bones stay in bind pose.
    //
    // DIRECTION-AWARE: Only compensate for UPWARD parent movement (fighting gravity).
    // During descent/landing, let hair float naturally - compensating downward movement
    // would create upward force and make hair shoot up on landing.
    //
    // We scale the compensation based on movement magnitude:
    // - Small movements (idle breathing/sway): minimal compensation, hair follows gently
    // - Large movements (jumps): full compensation, hair trails behind with inertia
    if (globalParams.settlingFrames == 0) {
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
    }

    // Now save current position as previous for next frame
    bonePosPrev[id] = bonePosCurr[id];

    // Calculate wind force with time-based oscillation
    float time = globalParams.windPhase;
    float3 windForce = globalParams.windAmplitude *
                      globalParams.windDirection *
                      sin(globalParams.windFrequency * time);

    // Verlet integration with drag and external forces
    float baseDrag = boneParams[id].drag;

    // SETTLING BOOST: During settling period, reduce drag and boost gravity
    // This allows bones to quickly fall to their natural hanging position
    // Use smoothstep to gradually phase out the boost over last 30 frames (avoid abrupt "bounce")
    float settlingFrames = float(globalParams.settlingFrames);
    float settlingFactor = smoothstep(0.0, 30.0, settlingFrames);  // Gradual transition
    float dragFactor = 1.0 - baseDrag * (1.0 - settlingFactor * 0.8);  // 80% less drag during settling
    float gravityBoost = 1.0 + settlingFactor * 4.0;  // 5x gravity during settling

    // Apply per-joint gravity: use gravityDir as direction, gravityPower as magnitude
    // gravityDir is the direction gravity pulls (typically [0, -1, 0] for downward)
    // gravityPower scales the effect (0.0 = no gravity, 1.0 = full gravity)
    float gravityMagnitude = length(globalParams.gravity) * gravityBoost;
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
    // restLength already declared at top of function

    // Safety: only apply stiffness if data is valid (no NaN propagation)
    float bindDirLen = length(bindDir);
    bool stiffnessValid = !isnan(parentPos.x) && !isnan(parentPos.y) && !isnan(parentPos.z)
                       && bindDirLen > 0.001 && restLength > 0.0;

    if (stiffnessValid) {
        // Normalize bindDir if needed
        float3 safeBindDir = bindDir / bindDirLen;
        float3 targetPos = parentPos + safeBindDir * restLength;

        float stiffness = boneParams[id].stiffness;

        // SETTLING: Completely disable stiffness during settling period
        // Even 5% stiffness accumulates over time and prevents natural hanging
        // Only enable stiffness AFTER settling is complete (settlingFrames == 0)
        if (globalParams.settlingFrames > 0) {
            stiffness = 0.0;
        }

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

    // POSITION BOUNDS CHECK: Detect if bone has drifted impossibly far
    // If more than 10m from parent, something is wrong - reset to stable position
    float3 toParent = newPos - bonePosCurr[parentIndex];
    float distFromParent = length(toParent);
    if (distFromParent > 10.0) {
        // Reset to rest position below parent
        float safeRestLen = max(restLength, 0.01);
        newPos = bonePosCurr[parentIndex] + float3(0.0, -safeRestLen, 0.0);
    }

    // Final NaN safety check - if result is NaN, reset to stable position
    if (isnan(newPos.x) || isnan(newPos.y) || isnan(newPos.z) ||
        isinf(newPos.x) || isinf(newPos.y) || isinf(newPos.z)) {
        // Reset to rest position hanging below parent
        float3 parentPos = bonePosCurr[parentIndex];
        if (isnan(parentPos.x) || isnan(parentPos.y) || isnan(parentPos.z)) {
            // Parent is also bad - use previous position as last resort
            newPos = bonePosPrev[id];
        } else {
            // Reset to hanging position below parent
            float safeRestLen = max(restLength, 0.01);
            newPos = parentPos + float3(0.0, -safeRestLen, 0.0);
        }
        // Also reset previous position to prevent velocity spike next frame
        bonePosPrev[id] = newPos;
    }

    bonePosCurr[id] = newPos;
}