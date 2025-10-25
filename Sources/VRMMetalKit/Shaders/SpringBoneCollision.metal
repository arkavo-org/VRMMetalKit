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

struct SphereCollider {
    float3 center;
    float radius;
};

struct CapsuleCollider {
    float3 p0;
    float3 p1;
    float radius;
};

struct SpringBoneParams {
    float3 gravity;
    float dtSub;
    float windAmplitude;
    float windFrequency;
    float windPhase;
    float3 windDirection;
    uint substeps;
    uint numBones;
    uint numSpheres;
    uint numCapsules;
};

struct BoneParams {
    float stiffness;
    float drag;
    float radius;
    uint parentIndex;
};

// Sphere collision function
float3 collideWithSphere(float3 position, float boneRadius, constant SphereCollider* spheres, uint numSpheres) {
    float3 result = position;

    for (uint i = 0; i < numSpheres; i++) {
        SphereCollider sphere = spheres[i];
        float3 toCenter = position - sphere.center;
        float distance = length(toCenter);
        float penetration = sphere.radius + boneRadius - distance;

        if (penetration > 0.0) {
            float3 normal = toCenter / max(distance, 1e-6);
            result += normal * penetration;
        }
    }

    return result;
}

// Capsule collision function
float3 collideWithCapsule(float3 position, float boneRadius, constant CapsuleCollider* capsules, uint numCapsules) {
    float3 result = position;
    const float epsilon = 1e-6;

    for (uint i = 0; i < numCapsules; i++) {
        CapsuleCollider capsule = capsules[i];

        // Find closest point on capsule segment
        float3 ab = capsule.p1 - capsule.p0;
        float ab_length_sq = dot(ab, ab);

        // Add epsilon check to prevent division by zero
        float t = (ab_length_sq > epsilon) ? dot(position - capsule.p0, ab) / ab_length_sq : 0.0;
        t = clamp(t, 0.0, 1.0);
        float3 closestPoint = capsule.p0 + t * ab;

        float3 toClosest = position - closestPoint;
        float distance = length(toClosest);
        float penetration = capsule.radius + boneRadius - distance;

        if (penetration > 0.0) {
            float3 normal = toClosest / max(distance, epsilon);
            result += normal * penetration;
        }
    }

    return result;
}

kernel void springBoneCollideSpheres(
    device float3* bonePosCurr [[buffer(1)]],
    constant BoneParams* boneParams [[buffer(2)]],
    constant SphereCollider* sphereColliders [[buffer(5)]],
    constant SpringBoneParams& globalParams [[buffer(3)]],
    uint id [[thread_position_in_grid]]
) {
    if (id >= globalParams.numBones || globalParams.numSpheres == 0) return;

    float boneRadius = boneParams[id].radius;
    bonePosCurr[id] = collideWithSphere(bonePosCurr[id], boneRadius, sphereColliders, globalParams.numSpheres);
}

kernel void springBoneCollideCapsules(
    device float3* bonePosCurr [[buffer(1)]],
    constant BoneParams* boneParams [[buffer(2)]],
    constant CapsuleCollider* capsuleColliders [[buffer(6)]],
    constant SpringBoneParams& globalParams [[buffer(3)]],
    uint id [[thread_position_in_grid]]
) {
    if (id >= globalParams.numBones || globalParams.numCapsules == 0) return;

    float boneRadius = boneParams[id].radius;
    bonePosCurr[id] = collideWithCapsule(bonePosCurr[id], boneRadius, capsuleColliders, globalParams.numCapsules);
}