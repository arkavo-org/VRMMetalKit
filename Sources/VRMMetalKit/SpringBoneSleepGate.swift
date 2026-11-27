//
// Copyright 2026 Arkavo
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

import simd

/// Per-chain SpringBone sleep / wake policy.
///
/// Velocities must come from a **completed** GPU snapshot (or an equivalent
/// host-side pair of positions). Callers must not sample in-flight
/// `bonePosCurr` / `bonePosPrev`. The sync/offline path leaves this gate
/// unused so simulation stays bit-deterministic.
public struct SpringBoneSleepGate: Equatable, Sendable {
    /// `true` when that chain is currently asleep.
    public private(set) var asleep: [Bool]
    /// Consecutive below-threshold frames for each chain.
    public private(set) var counters: [Int]
    /// Bones belonging to currently sleeping chains.
    public private(set) var sleepingBoneCount: Int

    /// Creates a gate for `chainCount` chains, all awake.
    public init(chainCount: Int) {
        asleep = Array(repeating: false, count: chainCount)
        counters = Array(repeating: 0, count: chainCount)
        sleepingBoneCount = 0
    }

    /// Max |curr − prev| · `invDt` per chain. Empty or short snapshots
    /// return `greatestFiniteMagnitude` so the chain stays awake.
    public static func chainMaxVelocities(
        curr: [SIMD3<Float>],
        prev: [SIMD3<Float>],
        ranges: [Range<Int>],
        invDt: Float
    ) -> [Float] {
        guard curr.count == prev.count, !curr.isEmpty else {
            return Array(repeating: Float.greatestFiniteMagnitude, count: ranges.count)
        }
        var out: [Float] = []
        out.reserveCapacity(ranges.count)
        fillChainMaxVelocities(into: &out, curr: curr, prev: prev, ranges: ranges, invDt: invDt)
        return out
    }

    internal static func fillChainMaxVelocities(
        into out: inout [Float],
        curr: [SIMD3<Float>],
        prev: [SIMD3<Float>],
        ranges: [Range<Int>],
        invDt: Float
    ) {
        out.removeAll(keepingCapacity: true)
        guard curr.count == prev.count, !curr.isEmpty else {
            for _ in 0..<ranges.count {
                out.append(Float.greatestFiniteMagnitude)
            }
            return
        }
        let count = curr.count
        for range in ranges {
            var maxDistSq: Float = 0
            let upper = min(range.upperBound, count)
            if range.lowerBound < upper {
                for i in range.lowerBound..<upper {
                    let d = curr[i] - prev[i]
                    let distSq = simd_length_squared(d)
                    if distSq > maxDistSq { maxDistSq = distSq }
                }
            }
            out.append(sqrt(maxDistSq) * invDt)
        }
    }

    /// Per-chain wake bits. `globalWake` (settling, quality, wind, force,
    /// explicit) wakes everyone. Otherwise a chain wakes if its root moved
    /// or its collider-group mask intersects a moved collider.
    public static func wakeMask(
        chainCount: Int,
        globalWake: Bool,
        movedRootIndices: [Int],
        movedColliderMasks: [UInt32],
        chainColliderMasks: [UInt32]
    ) -> [Bool] {
        var combinedMask: UInt32 = 0
        for m in movedColliderMasks { combinedMask |= m }
        var mask = Array(repeating: false, count: chainCount)
        fillWakeMask(
            into: &mask,
            chainCount: chainCount,
            globalWake: globalWake,
            movedRootIndices: movedRootIndices,
            combinedMovedColliderMask: combinedMask,
            chainColliderMasks: chainColliderMasks
        )
        return mask
    }

    internal static func fillWakeMask(
        into mask: inout [Bool],
        chainCount: Int,
        globalWake: Bool,
        movedRootIndices: [Int],
        combinedMovedColliderMask: UInt32,
        chainColliderMasks: [UInt32]
    ) {
        if mask.count != chainCount {
            mask = Array(repeating: globalWake, count: chainCount)
        } else {
            for i in 0..<chainCount {
                mask[i] = globalWake
            }
        }
        if globalWake { return }
        for index in movedRootIndices where index >= 0 && index < chainCount {
            mask[index] = true
        }
        guard combinedMovedColliderMask != 0 else { return }
        let maskLimit = min(chainCount, chainColliderMasks.count)
        for chain in 0..<maskLimit {
            if (combinedMovedColliderMask & chainColliderMasks[chain]) != 0 {
                mask[chain] = true
            }
        }
    }

    /// Advances sleep counters. A `true` wake bit forces that chain awake.
    /// Sleeping chains stay asleep unless woken — velocity is not rechecked.
    public mutating func apply(
        velocities: [Float],
        wakeMask: [Bool],
        ranges: [Range<Int>],
        threshold: Float,
        delay: Int
    ) {
        let n = min(asleep.count, min(velocities.count, wakeMask.count))
        var boneCount = 0
        for i in 0..<n {
            if wakeMask[i] {
                asleep[i] = false
                counters[i] = 0
                continue
            }
            if asleep[i] {
                boneCount += i < ranges.count ? ranges[i].count : 0
                continue
            }
            if velocities[i] < threshold {
                counters[i] += 1
                if counters[i] >= delay {
                    asleep[i] = true
                    boneCount += i < ranges.count ? ranges[i].count : 0
                }
            } else {
                counters[i] = 0
            }
        }
        sleepingBoneCount = boneCount
    }

    /// Forces every chain awake and clears settle counters.
    public mutating func wakeAll() {
        for i in asleep.indices {
            asleep[i] = false
        }
        for i in counters.indices {
            counters[i] = 0
        }
        sleepingBoneCount = 0
    }

    /// Restores explicit per-chain sleep flags and counters (used to preserve
    /// surviving chains' sleep state across dynamic SpringBone layout rebuilds).
    internal mutating func restoreState(asleep newAsleep: [Bool], counters newCounters: [Int], ranges: [Range<Int>]) {
        guard newAsleep.count == asleep.count, newCounters.count == counters.count else { return }
        asleep = newAsleep
        counters = newCounters
        var boneCount = 0
        for i in asleep.indices where asleep[i] {
            if i < ranges.count {
                boneCount += ranges[i].count
            }
        }
        sleepingBoneCount = boneCount
    }

    /// `true` when there is at least one chain and every chain is asleep.
    public var allAsleep: Bool {
        !asleep.isEmpty && asleep.allSatisfy { $0 }
    }
}
