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

// VRMC_springBone-1.0 §5.1 center-node rigid-follow kernel (VMK#295).
//
// One entry per (spring-with-center) per substep, identifying the
// contiguous bone-buffer range to shift and the 4×4 incremental
// world-space delta to apply. The host pre-computes all per-substep
// deltas at the top of `update()` into a single buffer indexed
// `[substep][record]`, so the per-substep dispatch reads its slice
// at a fixed offset — avoiding the CPU/GPU race the earlier
// CPU-shift attempt hit on the shared-command-buffer path.
struct CenterDeltaRecord {
    uint boneStart;
    uint boneCount;
    uint _pad0;
    uint _pad1;
    float4x4 delta;
};

// Apply each record's `delta` to every bone in `[boneStart,
// boneStart+boneCount)`, on both bonePosCurr and bonePosPrev. PBD's
// velocity-from-positions invariant requires the same delta on both
// so the apparent velocity is preserved (no phantom inertia from the
// rigid frame shift). One thread per record is sufficient — record
// counts are tiny (typically 1-8 per model) and per-record bone
// loops are short (4-16 joints per chain).
kernel void springBoneApplyCenterDelta(
    device float3* bonePosPrev [[buffer(0)]],
    device float3* bonePosCurr [[buffer(1)]],
    constant CenterDeltaRecord* records [[buffer(13)]],
    constant uint& numRecords [[buffer(14)]],
    uint id [[thread_position_in_grid]]
) {
    if (id >= numRecords) return;
    CenterDeltaRecord r = records[id];
    float4x4 d = r.delta;
    for (uint i = r.boneStart; i < r.boneStart + r.boneCount; i++) {
        float4 pc = float4(bonePosCurr[i], 1.0);
        float4 pp = float4(bonePosPrev[i], 1.0);
        pc = d * pc;
        pp = d * pp;
        bonePosCurr[i] = float3(pc.xyz);
        bonePosPrev[i] = float3(pp.xyz);
    }
}
