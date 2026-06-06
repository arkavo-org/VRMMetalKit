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
    uint groupIndex;  // Index of collision group this collider belongs to
    uint inside;      // 0 = outside-collision (default), 1 = containment (joint pushed inside)
};

struct CapsuleCollider {
    float3 p0;
    float3 p1;
    float radius;
    uint groupIndex;  // Index of collision group this collider belongs to
    uint inside;      // 0 = outside-collision (default), 1 = containment (joint pushed inside)
};

struct PlaneCollider {
    float3 point;     // Point on the plane
    float3 normal;    // Plane normal (normalized)
    uint groupIndex;  // Index of collision group this collider belongs to
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
    uint numPlanes;
    uint settlingFrames;  // Frames remaining in settling period
};

struct BoneParams {
    float stiffness;
    float drag;
    float radius;
    uint parentIndex;
    float gravityPower;       // Multiplier for global gravity (0.0 = no gravity, 1.0 = full)
    uint colliderGroupMask;   // Bitmask of collision groups this bone collides with
    float3 gravityDir;        // Direction vector (normalized, typically [0, -1, 0])
    float angleLimit;         // Max swing angle from bind dir (radians); 0 = no limit
};

// Sphere collision function with group filtering. Handles both the base
// "outside" collision (joint pushed out of the sphere) and the
// VRMC_springBone_extended_collider "inside" / containment collision
// (joint pushed back into the sphere when it tries to escape).
//
// CONTINUOUS COLLISION (#313): the joint's per-substep motion is the segment
// `prevPos → position`. Discrete collision tests only `position` (the substep
// END); a fast joint whose segment passes clean through an outside sphere lands
// OUTSIDE on the far side, so the endpoint test finds no penetration and the
// joint tunnels through. For outside spheres we therefore sweep the segment:
// if it ENTERS the inflated sphere (prev started outside, earliest entry t* in
// [0,1]) we clamp the joint to that entry surface. When the segment does not
// cleanly enter (e.g. prev already inside) we fall back to the discrete
// endpoint push-out, so shallow resting penetration behaves exactly as before.
float3 collideWithSphereFiltered(float3 prevPos, float3 position, float boneRadius,
                                  uint groupMask, uint sweptGroupIndex,
                                  constant SphereCollider* spheres, uint numSpheres) {
    float3 result = position;
    const float epsilon = 1e-6;

    for (uint i = 0; i < numSpheres; i++) {
        SphereCollider sphere = spheres[i];

        // Skip if bone doesn't collide with this group
        if (!(groupMask & (1u << sphere.groupIndex))) continue;

        if (sphere.inside != 0u) {
            // Containment: penetration when joint is escaping the sphere.
            // distance > radius - boneRadius means joint is past the inner
            // safe surface. Push it back toward the centre.
            float3 toCenter = result - sphere.center;
            float distance = length(toCenter);
            float penetration = distance + boneRadius - sphere.radius;
            if (penetration > 0.0 && distance > epsilon) {
                float3 inward = -toCenter / distance;  // toward centre
                result += inward * penetration;
            }
            continue;
        }

        // Outside collision (default). Inflated radius = sphere + bone.
        float R = sphere.radius + boneRadius;
        float3 toCenter = result - sphere.center;
        float distance = length(toCenter);

        if (distance < R) {
            // Endpoint rests INSIDE the sphere: discrete push-out along the
            // endpoint normal. Identical to the pre-CCD behaviour, so resting
            // and sliding contact (and the calibrated equilibrium) are
            // unchanged — the joint still slides tangentially along the
            // surface instead of being snapped back to its entry point.
            float penetration = R - distance;
            float3 outward = toCenter / max(distance, epsilon);
            result += outward * penetration;
        } else {
            // Endpoint is OUTSIDE — discrete collision would see nothing. Sweep
            // the segment prevPos → result and, only if it TUNNELED through
            // (started outside, earliest entry t* ∈ [0,1]), stop the joint at
            // the entry surface. Solve |prevPos + t·d - C|² = R².
            //
            // Scoped (#313): only the SYNTHETIC augmented-collider group gets
            // continuous collision. Authored body spheres keep the discrete
            // endpoint test — clamping fast cloth joints against them deflects
            // stiff chains into adjacent geometry (the arm-swing re-entry
            // regression). Synthetic colliders exist precisely to stop tunneling,
            // so swept response is wanted there and nowhere else.
            float3 d = result - prevPos;
            float3 m = prevPos - sphere.center;
            float a = dot(d, d);
            float c = dot(m, m) - R * R;
            if (sphere.groupIndex == sweptGroupIndex && a > epsilon && c > 0.0) {
                // Depth gate: only treat this as a tunnel worth clamping when
                // the joint CENTRE actually passes through the solid sphere
                // body (closest approach < sphere.radius), not merely grazes
                // the bone-inflated shell. A graze falls through to discrete
                // (a no-op here, endpoint is outside), so fast joints sliding
                // past nearby colliders are not snapped to the surface — that
                // spurious snap deflects stiff cloth chains into adjacent
                // geometry (the arm-swing re-entry regression, #313/#315).
                float tClose = clamp(-dot(m, d) / a, 0.0, 1.0);
                float3 closest = prevPos + tClose * d;
                float distClose = length(closest - sphere.center);
                if (distClose < sphere.radius) {
                    float b = 2.0 * dot(m, d);
                    float disc = b * b - 4.0 * a * c;
                    if (disc >= 0.0) {
                        float t = (-b - sqrt(disc)) / (2.0 * a);
                        if (t >= 0.0 && t <= 1.0) {
                            float3 contact = prevPos + t * d;
                            float3 toContact = contact - sphere.center;
                            float contactLen = length(toContact);
                            float3 n = (contactLen > epsilon) ? toContact / contactLen
                                                              : normalize(-d);
                            result = sphere.center + n * R;  // stop at entry surface
                        }
                    }
                }
            }
        }
    }

    return result;
}

// Capsule collision function with group filtering
float3 collideWithCapsuleFiltered(float3 position, float boneRadius, uint groupMask,
                                   constant CapsuleCollider* capsules, uint numCapsules) {
    float3 result = position;
    const float epsilon = 1e-6;

    for (uint i = 0; i < numCapsules; i++) {
        CapsuleCollider capsule = capsules[i];

        // Skip if bone doesn't collide with this group
        if (!(groupMask & (1u << capsule.groupIndex))) continue;

        // Find closest point on capsule segment
        float3 ab = capsule.p1 - capsule.p0;
        float ab_length_sq = dot(ab, ab);

        // Add epsilon check to prevent division by zero
        float t = (ab_length_sq > epsilon) ? dot(result - capsule.p0, ab) / ab_length_sq : 0.0;
        t = clamp(t, 0.0, 1.0);
        float3 closestPoint = capsule.p0 + t * ab;

        float3 toClosest = result - closestPoint;
        float distance = length(toClosest);

        if (capsule.inside != 0u) {
            // Containment: joint must stay inside the swept-sphere volume.
            float penetration = distance + boneRadius - capsule.radius;
            if (penetration > 0.0 && distance > epsilon) {
                float3 inward = -toClosest / distance;
                result += inward * penetration;
            }
        } else {
            // Outside collision (default).
            float penetration = capsule.radius + boneRadius - distance;
            if (penetration > 0.0) {
                float3 outward = toClosest / max(distance, epsilon);
                result += outward * penetration;
            }
        }
    }

    return result;
}

// Plane collision function with group filtering
float3 collideWithPlaneFiltered(float3 position, float boneRadius, uint groupMask,
                                 constant PlaneCollider* planes, uint numPlanes) {
    float3 result = position;

    for (uint i = 0; i < numPlanes; i++) {
        PlaneCollider plane = planes[i];

        // Skip if bone doesn't collide with this group
        if (!(groupMask & (1u << plane.groupIndex))) continue;

        // Distance from bone to plane (negative if below plane)
        float3 toPoint = result - plane.point;
        float distance = dot(toPoint, plane.normal) - boneRadius;

        if (distance < 0.0) {
            // Push bone out of plane
            result += plane.normal * (-distance);
        }
    }

    return result;
}

// POST-COLLISION VELOCITY CORRECTION (#313, PBD-without-CCD tunneling).
//
// Verlet velocity is implicit: v = bonePosCurr - bonePosPrev. The collision
// kernels push bonePosCurr OUT of a collider but never touch bonePosPrev, so a
// joint that drove fast INTO a collider keeps its full inward velocity after the
// push and tunnels straight back in on the next substep — the corrective impulse
// then overshoots. (`bonePosPrev[id]` was frozen earlier this substep by predict:
// `bonePosPrev[id] = oldCurr`, so v already encodes this substep's motion.)
//
// Fix: after a push moves curr→curr+correction (outward normal n =
// normalize(correction)), remove ONLY the INWARD normal component of the implicit
// velocity by translating prev along n. We want dot(curr - prevNew, n) >= 0:
//   prevNew = prev + n * min(0, dot(curr - prev, n))
// Tangential (sliding) velocity is preserved, so settled chains keep sliding
// along the collider and do not gain energy — this only bleeds the momentum that
// caused the tunnel. No-op when there was no push (correction ≈ 0) and when the
// joint is already moving outward, so resting/contained cloth is untouched.
static void applyVelocityCorrection(thread float3& prevPos,
                                    float3 newPos, float3 oldPos) {
    float3 correction = newPos - oldPos;
    float corrLen = length(correction);
    if (corrLen < 1e-7) return;
    float3 n = correction / corrLen;
    float vn = dot(newPos - prevPos, n);
    if (vn < 0.0) {
        // Inward residual velocity along the push normal — cancel it so the
        // joint does not carry momentum back into the collider next substep.
        prevPos += n * vn;
    }
}

kernel void springBoneCollideSpheres(
    device float3* bonePosCurr [[buffer(1)]],
    constant BoneParams* boneParams [[buffer(2)]],
    constant SphereCollider* sphereColliders [[buffer(5)]],
    constant SpringBoneParams& globalParams [[buffer(3)]],
    device float3* bonePosPrev [[buffer(0)]],
    constant uint& sweptGroupIndex [[buffer(15)]],
    uint id [[thread_position_in_grid]]
) {
    if (id >= globalParams.numBones || globalParams.numSpheres == 0) return;
    // Skip root bones — they are kinematic (driven by animation), and writing
    // collision pushes into bonePosCurr[root] corrupts the kinematic kernel's
    // velocity history on the next substep.
    if (boneParams[id].parentIndex == 0xFFFFFFFFu) return;

    float boneRadius = boneParams[id].radius;
    uint groupMask = boneParams[id].colliderGroupMask;
    float3 oldPos = bonePosCurr[id];
    float3 prevForSweep = bonePosPrev[id];
    float3 newPos = collideWithSphereFiltered(prevForSweep, oldPos, boneRadius, groupMask,
                                              sweptGroupIndex,
                                              sphereColliders, globalParams.numSpheres);
    bonePosCurr[id] = newPos;
    float3 prevPos = bonePosPrev[id];
    applyVelocityCorrection(prevPos, newPos, oldPos);
    bonePosPrev[id] = prevPos;
}

kernel void springBoneCollideCapsules(
    device float3* bonePosCurr [[buffer(1)]],
    constant BoneParams* boneParams [[buffer(2)]],
    constant CapsuleCollider* capsuleColliders [[buffer(6)]],
    constant SpringBoneParams& globalParams [[buffer(3)]],
    device float3* bonePosPrev [[buffer(0)]],
    uint id [[thread_position_in_grid]]
) {
    if (id >= globalParams.numBones || globalParams.numCapsules == 0) return;
    if (boneParams[id].parentIndex == 0xFFFFFFFFu) return;

    float boneRadius = boneParams[id].radius;
    uint groupMask = boneParams[id].colliderGroupMask;
    float3 oldPos = bonePosCurr[id];
    float3 newPos = collideWithCapsuleFiltered(oldPos, boneRadius, groupMask,
                                               capsuleColliders, globalParams.numCapsules);
    bonePosCurr[id] = newPos;
    float3 prevPos = bonePosPrev[id];
    applyVelocityCorrection(prevPos, newPos, oldPos);
    bonePosPrev[id] = prevPos;
}

kernel void springBoneCollidePlanes(
    device float3* bonePosCurr [[buffer(1)]],
    constant BoneParams* boneParams [[buffer(2)]],
    constant PlaneCollider* planeColliders [[buffer(7)]],
    constant SpringBoneParams& globalParams [[buffer(3)]],
    device float3* bonePosPrev [[buffer(0)]],
    uint id [[thread_position_in_grid]]
) {
    if (id >= globalParams.numBones || globalParams.numPlanes == 0) return;
    if (boneParams[id].parentIndex == 0xFFFFFFFFu) return;

    float boneRadius = boneParams[id].radius;
    uint groupMask = boneParams[id].colliderGroupMask;
    float3 oldPos = bonePosCurr[id];
    float3 newPos = collideWithPlaneFiltered(oldPos, boneRadius, groupMask,
                                             planeColliders, globalParams.numPlanes);
    bonePosCurr[id] = newPos;
    float3 prevPos = bonePosPrev[id];
    applyVelocityCorrection(prevPos, newPos, oldPos);
    bonePosPrev[id] = prevPos;
}
