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

#ifndef DualQuaternionSkinning_h
#define DualQuaternionSkinning_h

#include <metal_stdlib>
using namespace metal;

// Dual quaternion struct - must match Swift DualQuaternion exactly
// Total: 32 bytes, 16-byte aligned
struct DualQuaternion {
    float4 real;  // Rotation quaternion (x, y, z, w) - 16 bytes
    float4 dual;  // Translation encoding (x, y, z, w) - 16 bytes
};

// MARK: - Quaternion Math Utilities

// Quaternion multiplication: a * b
inline float4 quat_multiply(float4 a, float4 b) {
    return float4(
        a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,  // x
        a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,  // y
        a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,  // z
        a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z   // w
    );
}

// Quaternion conjugate
inline float4 quat_conjugate(float4 q) {
    return float4(-q.xyz, q.w);
}

// Rotate vector by unit quaternion
// Formula: v' = q * v * q^-1 (optimized)
inline float3 quat_rotate(float4 q, float3 v) {
    float3 t = 2.0 * cross(q.xyz, v);
    return v + q.w * t + cross(q.xyz, t);
}

// MARK: - Dual Quaternion Operations

// Identity dual quaternion
constant DualQuaternion DQ_IDENTITY = {
    float4(0.0, 0.0, 0.0, 1.0),  // real: identity rotation
    float4(0.0, 0.0, 0.0, 0.0)   // dual: no translation
};

// Blend multiple dual quaternions with antipodality handling
// This is the core of DQS - proper blending is critical
inline DualQuaternion dq_blend(device const DualQuaternion* dqs,
                                uint4 joints,
                                float4 weights) {
    DualQuaternion result;
    result.real = float4(0.0);
    result.dual = float4(0.0);

    // Use first joint's real part as reference for antipodality
    float4 reference = dqs[joints[0]].real;

    // Blend all four joints
    for (int i = 0; i < 4; i++) {
        float w = weights[i];
        if (w <= 0.0) continue;

        DualQuaternion dq = dqs[joints[i]];

        // ANTIPODALITY CHECK: Ensure same hemisphere as reference
        // Quaternions q and -q represent the same rotation
        // We must negate the quaternion (not the weight) to stay in same hemisphere
        if (dot(reference, dq.real) < 0.0) {
            dq.real = -dq.real;
            dq.dual = -dq.dual;
        }

        result.real += w * dq.real;
        result.dual += w * dq.dual;
    }

    // Normalize the blended dual quaternion
    float norm = length(result.real);
    if (norm > 1e-6) {
        result.real /= norm;
        result.dual /= norm;
    } else {
        // Fallback to identity if degenerate
        return DQ_IDENTITY;
    }

    return result;
}

// Extract translation from dual quaternion
// Formula: t = 2 * dual * conjugate(real)
inline float3 dq_get_translation(DualQuaternion dq) {
    float4 t_quat = 2.0 * quat_multiply(dq.dual, quat_conjugate(dq.real));
    return t_quat.xyz;
}

// Transform a point by dual quaternion
// Equivalent to rotation followed by translation
inline float3 dq_transform_point(DualQuaternion dq, float3 point) {
    // Rotate the point
    float3 rotated = quat_rotate(dq.real, point);

    // Add translation
    float3 translation = dq_get_translation(dq);

    // Return the transformed point (balloon test scaling removed)
    return rotated + translation;
}

// Transform a normal/direction by dual quaternion (rotation only)
inline float3 dq_transform_normal(DualQuaternion dq, float3 normal) {
    return quat_rotate(dq.real, normal);
}

// MARK: - Safe Dual Quaternion Blending with Bounds Checking

// Blend with safe joint index clamping (same safety as LBS)
inline DualQuaternion dq_blend_safe(device const DualQuaternion* dqs,
                                     uint4 joints,
                                     float4 rawWeights,
                                     uint maxJoint) {
    // Clamp joint indices to prevent out-of-bounds access
    uint4 safeJoints = min(joints, uint4(maxJoint));

    // Normalize weights
    float4 weights = rawWeights;
    float weightSum = dot(weights, float4(1.0));
    if (weightSum > 1e-6) {
        weights = weights / weightSum;
    } else {
        weights = float4(1.0, 0.0, 0.0, 0.0);
    }

    DualQuaternion result;
    result.real = float4(0.0);
    result.dual = float4(0.0);

    // Reference for antipodality
    float4 reference = dqs[safeJoints[0]].real;

    // Weight threshold to skip negligible contributions
    float threshold = 0.001;

    bool anyContribution = false;

    if (rawWeights[0] > threshold) {
        DualQuaternion dq = dqs[safeJoints[0]];
        float w = weights[0];
        result.real += w * dq.real;
        result.dual += w * dq.dual;
        anyContribution = true;
    }

    if (rawWeights[1] > threshold) {
        DualQuaternion dq = dqs[safeJoints[1]];
        float w = weights[1];
        if (dot(reference, dq.real) < 0.0) {
            dq.real = -dq.real;
            dq.dual = -dq.dual;
        }
        result.real += w * dq.real;
        result.dual += w * dq.dual;
        anyContribution = true;
    }

    if (rawWeights[2] > threshold) {
        DualQuaternion dq = dqs[safeJoints[2]];
        float w = weights[2];
        if (dot(reference, dq.real) < 0.0) {
            dq.real = -dq.real;
            dq.dual = -dq.dual;
        }
        result.real += w * dq.real;
        result.dual += w * dq.dual;
        anyContribution = true;
    }

    if (rawWeights[3] > threshold) {
        DualQuaternion dq = dqs[safeJoints[3]];
        float w = weights[3];
        if (dot(reference, dq.real) < 0.0) {
            dq.real = -dq.real;
            dq.dual = -dq.dual;
        }
        result.real += w * dq.real;
        result.dual += w * dq.dual;
        anyContribution = true;
    }

    // Fallback if no contributions
    if (!anyContribution) {
        return dqs[safeJoints[0]];
    }

    // Normalize
    float norm = length(result.real);
    if (norm > 1e-6) {
        result.real /= norm;
        result.dual /= norm;
    } else {
        return DQ_IDENTITY;
    }

    return result;
}

#endif /* DualQuaternionSkinning_h */
