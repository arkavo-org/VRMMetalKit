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

// SEGMENT (parent→child span) COLLISION.
//
// The three shipped endpoint kernels (`SpringBoneCollision.metal`) each test
// a single bone's OWN position against a collider. A collider that sits
// entirely between two joints — clear of both endpoints, but overlapping the
// straight line connecting them — is invisible to that test: neither
// endpoint ever reports penetration, so cloth simply passes through it. The
// kernels below add a second, additive pass that tests the PARENT→CHILD
// segment itself (closest point / closest point pair), opt-in via
// `SpringBoneParams.segmentCollision` (gated on
// `VRMModel.fitClothCollisionToMesh`).
//
// Deliberately a NEW, separate translation unit: the three existing collide
// kernels stay textually untouched so the flag-off bit baseline
// (`SpringBoneBitBaselineTests`) has its best chance of surviving the
// metallib recompile.
//
// Struct copies below mirror `SpringBoneCollision.metal`'s (same layout
// contract as every other SpringBone shader file — each translation unit
// redeclares only the prefix of `SpringBoneParams` it actually reads).

struct SphereCollider {
    float3 center;
    float radius;
    uint groupMask;   // Bitmask of collision groups this collider belongs to (bit i = group i)
    uint inside;      // 0 = outside-collision (default), 1 = containment (joint pushed inside)
    float responseScale; // subsystem 4: per-partner push scale (1=full, 0=ghost)
};

struct CapsuleCollider {
    float3 p0;
    float3 p1;
    float radius;
    uint groupMask;   // Bitmask of collision groups this collider belongs to (bit i = group i)
    uint inside;      // 0 = outside-collision (default), 1 = containment (joint pushed inside)
    float responseScale; // subsystem 4: per-partner push scale (1=full, 0=ghost)
};

struct PlaneCollider {
    float3 point;     // Point on the plane
    float3 normal;    // Plane normal (normalized)
    uint groupMask;   // Bitmask of collision groups this collider belongs to (bit i = group i)
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
    uint settlingFrames;
    uint segmentCollision; // Segment (parent-child span) collision enable
};

struct BoneParams {
    float stiffness;
    float drag;
    float radius;
    uint parentIndex;
    float gravityPower;
    uint colliderGroupMask;
    float3 gravityDir;
    float angleLimit;
};

// POST-COLLISION VELOCITY CORRECTION — identical duplicate of the copy in
// `SpringBoneCollision.metal` (see that file for the full derivation). It is
// `static` there (internal linkage per translation unit), so it cannot be
// shared across files without either exporting it (a textual change to the
// three-kernels file we're avoiding) or duplicating it; duplicating keeps
// `SpringBoneCollision.metal` untouched below its struct definition.
static void applyVelocityCorrection(thread float3& prevPos,
                                    float3 newPos, float3 oldPos) {
    float3 correction = newPos - oldPos;
    float corrLen = length(correction);
    if (corrLen < 1e-7) return;
    float3 n = correction / corrLen;
    float vn = dot(newPos - prevPos, n);
    if (vn < 0.0) {
        prevPos += n * vn;
    }
}

// Closest point on segment ab to point p (Ericson §5.1.2). `t` is the
// barycentric parameter along ab (0 = a, 1 = b) — used to scale the
// child-side correction below.
static inline float3 closestPtSegmentPoint(float3 a, float3 b, float3 p, thread float& t) {
    float3 ab = b - a;
    float denom = dot(ab, ab);
    t = denom > 1e-12f ? clamp(dot(p - a, ab) / denom, 0.0f, 1.0f) : 0.0f;
    return a + t * ab;
}

// Closest points between segments p1q1 and p2q2 (Ericson §5.1.9). `s` is the
// barycentric parameter along p1q1 (our own parent→child segment; 0 = p1/parent,
// 1 = q1/child) — used to scale the child-side correction below.
static inline void closestPtSegmentSegment(float3 p1, float3 q1, float3 p2, float3 q2,
                                           thread float3& c1, thread float3& c2,
                                           thread float& s) {
    float3 d1 = q1 - p1, d2 = q2 - p2, r = p1 - p2;
    float a = dot(d1, d1), e = dot(d2, d2), f = dot(d2, r);
    float t = 0.0f;
    s = 0.0f;
    if (a <= 1e-12f && e <= 1e-12f) { c1 = p1; c2 = p2; return; }
    if (a <= 1e-12f) { t = clamp(f / e, 0.0f, 1.0f); }
    else {
        float c = dot(d1, r);
        if (e <= 1e-12f) { s = clamp(-c / a, 0.0f, 1.0f); }
        else {
            float b = dot(d1, d2), denom = a * e - b * b;
            s = denom > 1e-12f ? clamp((b * f - c * e) / denom, 0.0f, 1.0f) : 0.0f;
            t = (b * s + f) / e;
            if (t < 0.0f)      { t = 0.0f; s = clamp(-c / a, 0.0f, 1.0f); }
            else if (t > 1.0f) { t = 1.0f; s = clamp((b - c) / a, 0.0f, 1.0f); }
        }
    }
    c1 = p1 + d1 * s; c2 = p2 + d2 * t;
}

// One thread per bone: copy positions into the immutable snapshot the segment
// kernels read for the PARENT endpoint. The collide kernels read AND write
// bonePosCurr[id] per thread; a live read of bonePosCurr[parentIndex] would be
// their first unsynchronized cross-thread read and run-to-run nondeterministic
// (spec §4). One snapshot per substep, after integration and after the three
// existing endpoint collide dispatches, before all segment collide dispatches;
// staleness relative to this substep's own endpoint pushes is the chosen
// semantics (parent-side coverage of the endpoint pushes comes from the
// parent's own segment, tested next substep against the fresh snapshot).
kernel void springBoneSnapshotPositions(
    device const float3* bonePosCurr [[buffer(1)]],
    device float3* bonePosSnapshot   [[buffer(16)]],
    constant SpringBoneParams& globalParams [[buffer(3)]],
    uint id [[thread_position_in_grid]]
) {
    if (id >= globalParams.numBones) return;
    bonePosSnapshot[id] = bonePosCurr[id];
}

// Discrete segment push-out vs sphere colliders. Additive pass after the
// endpoint kernels; corrections stay single-writer (this thread writes only
// its own slot, `bonePosCurr[id]`). No swept branch here — CCD scoping
// (CLAUDE.md §4) is the endpoint kernels' job and is untouched.
//
// The correction is scaled by the barycentric `t` (spec §4 fallback): an
// un-scaled full push overshoots when the contact point sits near the PARENT
// end of the segment (t≈0) — the child, potentially far away, would be moved
// by the full penetration depth even though the actual contact geometry is
// close to the parent. A contact near the parent is exactly where the
// PARENT's own endpoint collision (the untouched per-joint kernel, which
// tests the parent's own position directly) already provides coverage, so
// scaling by t avoids double-correcting on top of that while still applying
// the full push when the contact is genuinely at the child end (t≈1).
kernel void springBoneCollideSegmentSpheres(
    device float3* bonePosCurr [[buffer(1)]],
    constant BoneParams* boneParams [[buffer(2)]],
    constant SphereCollider* sphereColliders [[buffer(5)]],
    constant SpringBoneParams& globalParams [[buffer(3)]],
    device float3* bonePosPrev [[buffer(0)]],
    device const float3* bonePosSnapshot [[buffer(16)]],
    uint id [[thread_position_in_grid]]
) {
    if (id >= globalParams.numBones || globalParams.numSpheres == 0) return;
    if (globalParams.segmentCollision == 0) return;
    uint parent = boneParams[id].parentIndex;
    if (parent == 0xFFFFFFFFu) return;   // roots are kinematic

    float radius = max(boneParams[id].radius, boneParams[parent].radius);
    uint mask = boneParams[id].colliderGroupMask;
    float3 childPos = bonePosCurr[id];
    float3 parentPos = bonePosSnapshot[parent];
    float3 oldPos = childPos;

    for (uint i = 0; i < globalParams.numSpheres; i++) {
        if ((sphereColliders[i].groupMask & mask) == 0) continue;
        if (sphereColliders[i].inside != 0) continue;   // containment: endpoint semantics only (spec)
        float t;
        float3 c = closestPtSegmentPoint(parentPos, childPos, sphereColliders[i].center, t);
        float3 delta = c - sphereColliders[i].center;
        float dist = length(delta);
        float minDist = sphereColliders[i].radius + radius;
        if (dist < minDist && dist > 1e-9f) {
            float3 push = (delta / dist) * (minDist - dist) * t;
            childPos += push;
        }
    }
    if (any(childPos != oldPos)) {
        bonePosCurr[id] = childPos;
        float3 prevPos = bonePosPrev[id];
        applyVelocityCorrection(prevPos, childPos, oldPos);
        bonePosPrev[id] = prevPos;
    }
}

// Discrete segment push-out vs capsule colliders. Mirrors the sphere kernel;
// the barycentric scale is `s` (the parameter along the parent→child segment
// returned by `closestPtSegmentSegment`) for the same small-t-overshoot
// reason documented above.
kernel void springBoneCollideSegmentCapsules(
    device float3* bonePosCurr [[buffer(1)]],
    constant BoneParams* boneParams [[buffer(2)]],
    constant CapsuleCollider* capsuleColliders [[buffer(6)]],
    constant SpringBoneParams& globalParams [[buffer(3)]],
    device float3* bonePosPrev [[buffer(0)]],
    device const float3* bonePosSnapshot [[buffer(16)]],
    uint id [[thread_position_in_grid]]
) {
    if (id >= globalParams.numBones || globalParams.numCapsules == 0) return;
    if (globalParams.segmentCollision == 0) return;
    uint parent = boneParams[id].parentIndex;
    if (parent == 0xFFFFFFFFu) return;

    float radius = max(boneParams[id].radius, boneParams[parent].radius);
    uint mask = boneParams[id].colliderGroupMask;
    float3 childPos = bonePosCurr[id];
    float3 parentPos = bonePosSnapshot[parent];
    float3 oldPos = childPos;

    for (uint i = 0; i < globalParams.numCapsules; i++) {
        if ((capsuleColliders[i].groupMask & mask) == 0) continue;
        if (capsuleColliders[i].inside != 0) continue;
        float3 c1, c2;
        float s;
        closestPtSegmentSegment(parentPos, childPos,
                                capsuleColliders[i].p0, capsuleColliders[i].p1, c1, c2, s);
        float3 delta = c1 - c2;
        float dist = length(delta);
        float minDist = capsuleColliders[i].radius + radius;
        if (dist < minDist && dist > 1e-9f) {
            float3 push = (delta / dist) * (minDist - dist) * s;
            childPos += push;
        }
    }
    if (any(childPos != oldPos)) {
        bonePosCurr[id] = childPos;
        float3 prevPos = bonePosPrev[id];
        applyVelocityCorrection(prevPos, childPos, oldPos);
        bonePosPrev[id] = prevPos;
    }
}

// Discrete segment push-out vs plane colliders. Unlike the sphere/capsule
// tests (a single closest point on the segment), a plane's half-space test is
// linear along the segment, so the worse (more penetrating) of the two
// endpoints — tested directly against the plane, using the snapshot for the
// parent — already gives the correct contact depth without a barycentric
// scale: pushing the child by that depth resolves the shallower-than-worst
// endpoint's penetration too, since the plane is flat between them.
kernel void springBoneCollideSegmentPlanes(
    device float3* bonePosCurr [[buffer(1)]],
    constant BoneParams* boneParams [[buffer(2)]],
    constant PlaneCollider* planeColliders [[buffer(7)]],
    constant SpringBoneParams& globalParams [[buffer(3)]],
    device float3* bonePosPrev [[buffer(0)]],
    device const float3* bonePosSnapshot [[buffer(16)]],
    uint id [[thread_position_in_grid]]
) {
    if (id >= globalParams.numBones || globalParams.numPlanes == 0) return;
    if (globalParams.segmentCollision == 0) return;
    uint parent = boneParams[id].parentIndex;
    if (parent == 0xFFFFFFFFu) return;

    float radius = max(boneParams[id].radius, boneParams[parent].radius);
    uint mask = boneParams[id].colliderGroupMask;
    float3 childPos = bonePosCurr[id];
    float3 parentPos = bonePosSnapshot[parent];
    float3 oldPos = childPos;

    for (uint i = 0; i < globalParams.numPlanes; i++) {
        if ((planeColliders[i].groupMask & mask) == 0) continue;
        float3 toChild = childPos - planeColliders[i].point;
        float childDist = dot(toChild, planeColliders[i].normal) - radius;
        float3 toParent = parentPos - planeColliders[i].point;
        float parentDist = dot(toParent, planeColliders[i].normal) - radius;
        float worstDist = min(childDist, parentDist);
        if (worstDist < 0.0f) {
            childPos += planeColliders[i].normal * (-worstDist);
        }
    }
    if (any(childPos != oldPos)) {
        bonePosCurr[id] = childPos;
        float3 prevPos = bonePosPrev[id];
        applyVelocityCorrection(prevPos, childPos, oldPos);
        bonePosPrev[id] = prevPos;
    }
}
