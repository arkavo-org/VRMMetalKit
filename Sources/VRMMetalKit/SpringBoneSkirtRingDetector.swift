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

import Foundation
import simd

/// Detects radial skirt rings and computes per-bone auxiliary collision data
/// (skirt ring neighbor indices + VRM 1.0 terminal cloth `hitRadius` inheritance)
/// for the SpringBone compute path (#478).
///
/// Pure value logic — no Metal, never mutates `model`.
enum SpringBoneSkirtRingDetector {

    static let noNeighbor: UInt32 = 0xFFFFFFFF

    /// Maximum angular span between adjacent radial chains in a skirt ring
    /// (110°). Wider openings (e.g. open-front coat-skirts) do not bridge across
    /// the front gap.
    static let maxAngularSpanRadians: Float = 110.0 * .pi / 180.0

    /// Maximum vertical difference when pairing unequal-length adjacent chains
    /// (e.g. VRoid 4-joint `CoatSkirtSide1` vs 3-joint `CoatSkirtFront`/`Back`).
    private static let maxUnequalChainYDelta: Float = 0.12

    /// Sanity bounds on rest-pose chord length between adjacent skirt joints (metres).
    private static let minChordLength: Float = 1e-3
    private static let maxChordLength: Float = 0.60

    struct DetectionResult {
        var aux: [SpringBoneCollisionAux]
        var hasRingNeighbors: Bool
        var ringCount: Int
        var linkedBoneCount: Int
        var inheritedHemRadiusCount: Int
    }

    private struct ChainCandidate {
        let springIndex: Int
        let boneStart: Int
        let jointCount: Int
        let category: String
        let layerSuffix: String?
        let azimuth: Float
        let radialDist: Float
        let height: Float
        let jointWorldPositions: [SIMD3<Float>]
    }

    /// Excluded substrings for both skirt ring detection and cloth terminal-radius
    /// inheritance. Strictly excludes stiff `Sleeve` chains (ADR-007), `Hair`, and `Bust`.
    private static let excludedSubstrings: [String] = [
        "sleeve", "hair", "bust", "breast", "ribbon", "hood", "tie", "ear", "tail", "wing",
    ]

    private static let skirtRingKeywords: [String] = [
        "skirt", "dress", "hakama", "apron",
    ]

    private static let clothHemKeywords: [String] = [
        "skirt", "dress", "hakama", "apron", "coat", "cloak", "cape", "cloth",
    ]

    private static let upperBodyExcludedBones: [VRMHumanoidBone] = [
        .head, .neck, .leftEye, .rightEye, .jaw,
        .leftShoulder, .rightShoulder,
        .leftUpperArm, .rightUpperArm,
        .leftLowerArm, .rightLowerArm,
        .leftHand, .rightHand,
        .leftThumbMetacarpal, .leftThumbProximal, .leftThumbDistal,
        .leftIndexProximal, .leftIndexIntermediate, .leftIndexDistal,
        .leftMiddleProximal, .leftMiddleIntermediate, .leftMiddleDistal,
        .leftRingProximal, .leftRingIntermediate, .leftRingDistal,
        .leftLittleProximal, .leftLittleIntermediate, .leftLittleDistal,
        .rightThumbMetacarpal, .rightThumbProximal, .rightThumbDistal,
        .rightIndexProximal, .rightIndexIntermediate, .rightIndexDistal,
        .rightMiddleProximal, .rightMiddleIntermediate, .rightMiddleDistal,
        .rightRingProximal, .rightRingIntermediate, .rightRingDistal,
        .rightLittleProximal, .rightLittleIntermediate, .rightLittleDistal,
    ]

    static func buildCollisionAux(
        model: VRMModel,
        hasSyntheticColliders: Bool
    ) -> DetectionResult {
        guard let springBone = model.springBone else {
            return DetectionResult(
                aux: [],
                hasRingNeighbors: false,
                ringCount: 0,
                linkedBoneCount: 0,
                inheritedHemRadiusCount: 0
            )
        }

        let upperExcludedNodes = upperBodyExcludedNodeSet(model: model)

        // Flatten bones in exact populateSpringBoneData order (skipping empty springs).
        var aux: [SpringBoneCollisionAux] = []
        var candidates: [ChainCandidate] = []
        var inheritedHemCount = 0

        // Compute hips reference for azimuth sorting (fallback to candidate root centroid).
        let hipsWorldPos: SIMD3<Float>? = {
            guard let hipsIdx = model.humanoid?.getBoneNode(.hips),
                  let hipsNode = model.nodes[safe: hipsIdx] else { return nil }
            return hipsNode.worldPosition
        }()

        var rawCandidateMeta: [(
            springIndex: Int,
            boneStart: Int,
            jointCount: Int,
            category: String,
            layerSuffix: String?,
            rootPos: SIMD3<Float>,
            jointPositions: [SIMD3<Float>]
        )] = []

        var boneIndex = 0
        for (springIndex, spring) in springBone.springs.enumerated() {
            guard !spring.joints.isEmpty else { continue }
            let boneStart = boneIndex
            let jointCount = spring.joints.count

            let springName = (spring.name ?? "").lowercased()
            let rootNode = model.nodes[safe: spring.joints[0].node]
            let rootNodeName = (rootNode?.name ?? "").lowercased()
            let combined = springName + " " + rootNodeName

            let excludedByName = excludedSubstrings.contains { combined.contains($0) }
            let excludedByAncestor = descendsFromExcluded(node: rootNode, excludedNodes: upperExcludedNodes)
            let isSkirtRingEligible = hasSyntheticColliders
                && jointCount >= 2
                && !excludedByName
                && !excludedByAncestor
                && skirtRingKeywords.contains { combined.contains($0) }
            let isClothHemEligible = hasSyntheticColliders
                && jointCount >= 2
                && !excludedByName
                && !excludedByAncestor
                && (isSkirtRingEligible || clothHemKeywords.contains { combined.contains($0) })

            for (jIdx, joint) in spring.joints.enumerated() {
                var synthRadius = joint.hitRadius
                if isClothHemEligible && jIdx == jointCount - 1 && synthRadius <= 0 {
                    // Inherit nearest positive ancestor joint hitRadius for synthetic-group
                    // collision when a VRM 1.0 terminal cloth joint omits hitRadius (#478).
                    for back in stride(from: jIdx - 1, through: 0, by: -1) {
                        if spring.joints[back].hitRadius > 0 {
                            synthRadius = spring.joints[back].hitRadius
                            inheritedHemCount += 1
                            break
                        }
                    }
                }
                aux.append(SpringBoneCollisionAux(
                    ringLeft: noNeighbor,
                    ringRight: noNeighbor,
                    syntheticRadius: synthRadius,
                    flags: 0
                ))
                boneIndex += 1
            }

            if isSkirtRingEligible, let rootNode {
                let jointPositions: [SIMD3<Float>] = spring.joints.map { joint in
                    model.nodes[safe: joint.node]?.worldPosition ?? rootNode.worldPosition
                }
                let category: String
                if rootNodeName.contains("coatskirt") {
                    category = "coatskirt"
                } else if !springName.isEmpty {
                    category = springName
                } else {
                    category = "skirt"
                }
                let suffix = extractTrailingLayerSuffix(from: rootNode.name ?? "")
                rawCandidateMeta.append((
                    springIndex: springIndex,
                    boneStart: boneStart,
                    jointCount: jointCount,
                    category: category,
                    layerSuffix: suffix,
                    rootPos: rootNode.worldPosition,
                    jointPositions: jointPositions
                ))
            }
        }

        guard hasSyntheticColliders, rawCandidateMeta.count >= 3 else {
            return DetectionResult(
                aux: aux,
                hasRingNeighbors: false,
                ringCount: 0,
                linkedBoneCount: 0,
                inheritedHemRadiusCount: inheritedHemCount
            )
        }

        let centerRef: SIMD3<Float>
        if let hipsWorldPos {
            centerRef = hipsWorldPos
        } else {
            let sum = rawCandidateMeta.reduce(SIMD3<Float>.zero) { $0 + $1.rootPos }
            centerRef = sum / Float(rawCandidateMeta.count)
        }

        candidates.reserveCapacity(rawCandidateMeta.count)
        for meta in rawCandidateMeta {
            let rel = meta.rootPos - centerRef
            let az = atan2(rel.x, rel.z)
            let rad = hypot(rel.x, rel.z)
            candidates.append(ChainCandidate(
                springIndex: meta.springIndex,
                boneStart: meta.boneStart,
                jointCount: meta.jointCount,
                category: meta.category,
                layerSuffix: meta.layerSuffix,
                azimuth: az,
                radialDist: rad,
                height: rel.y,
                jointWorldPositions: meta.jointPositions
            ))
        }

        let rings = partitionIntoRings(candidates: candidates)
        var ringCount = 0
        var totalLinks = 0
        let totalBones = aux.count

        for ring in rings where ring.count >= 3 {
            let sorted = ring.sorted {
                if $0.azimuth != $1.azimuth { return $0.azimuth < $1.azimuth }
                return $0.springIndex < $1.springIndex
            }
            var linksInRing = 0
            for i in 0..<sorted.count {
                let chainA = sorted[i]
                let chainB = sorted[(i + 1) % sorted.count]
                var dAz = chainB.azimuth - chainA.azimuth
                if dAz <= 0 { dAz += 2.0 * .pi }
                guard dAz < maxAngularSpanRadians else { continue }

                if chainA.jointCount == chainB.jointCount {
                    for j in 1..<chainA.jointCount {
                        let dist = simd_distance(chainA.jointWorldPositions[j], chainB.jointWorldPositions[j])
                        guard dist > minChordLength, dist < maxChordLength else { continue }
                        let idxA = chainA.boneStart + j
                        let idxB = chainB.boneStart + j
                        guard idxA < totalBones, idxB < totalBones, idxA != idxB else { continue }
                        aux[idxA].ringRight = UInt32(idxB)
                        aux[idxB].ringLeft = UInt32(idxA)
                        linksInRing += 1
                    }
                } else {
                    // Unequal chain lengths (e.g. 4-joint CoatSkirtSide1 vs 3-joint
                    // CoatSkirtFront/Back): match each non-root joint to the closest
                    // vertical-height joint on the adjacent chain.
                    for ja in 1..<chainA.jointCount {
                        let pA = chainA.jointWorldPositions[ja]
                        if let jb = bestHeightMatchIndex(target: pA, in: chainB.jointWorldPositions) {
                            let idxA = chainA.boneStart + ja
                            let idxB = chainB.boneStart + jb
                            if idxA < totalBones, idxB < totalBones, idxA != idxB {
                                aux[idxA].ringRight = UInt32(idxB)
                                linksInRing += 1
                            }
                        }
                    }
                    for jb in 1..<chainB.jointCount {
                        let pB = chainB.jointWorldPositions[jb]
                        if let ja = bestHeightMatchIndex(target: pB, in: chainA.jointWorldPositions) {
                            let idxA = chainA.boneStart + ja
                            let idxB = chainB.boneStart + jb
                            if idxA < totalBones, idxB < totalBones, idxA != idxB {
                                aux[idxB].ringLeft = UInt32(idxA)
                                linksInRing += 1
                            }
                        }
                    }
                }
            }
            if linksInRing > 0 {
                ringCount += 1
                totalLinks += linksInRing
            }
        }

        var linkedBones = 0
        for i in 0..<aux.count {
            if aux[i].ringLeft != noNeighbor || aux[i].ringRight != noNeighbor {
                aux[i].flags |= 1
                linkedBones += 1
            }
        }

        return DetectionResult(
            aux: aux,
            hasRingNeighbors: totalLinks > 0,
            ringCount: ringCount,
            linkedBoneCount: linkedBones,
            inheritedHemRadiusCount: inheritedHemCount
        )
    }

    // MARK: - Helpers

    private static func upperBodyExcludedNodeSet(model: VRMModel) -> Set<Int> {
        guard let humanoid = model.humanoid else { return [] }
        var set = Set<Int>()
        for bone in upperBodyExcludedBones {
            if let idx = humanoid.getBoneNode(bone), idx >= 0, idx < model.nodes.count {
                set.insert(idx)
            }
        }
        return set
    }

    private static func descendsFromExcluded(node: VRMNode?, excludedNodes: Set<Int>) -> Bool {
        guard !excludedNodes.isEmpty else { return false }
        var cur = node
        var depth = 0
        while let n = cur, depth < 64 {
            if excludedNodes.contains(n.index) { return true }
            cur = n.parent
            depth += 1
        }
        return false
    }

    /// Extracts a trailing numeric layer suffix such as `_01` or `.002` from a node name.
    static func extractTrailingLayerSuffix(from name: String) -> String? {
        guard !name.isEmpty else { return nil }
        let scalars = Array(name.unicodeScalars)
        var i = scalars.count - 1
        while i >= 0 && scalars[i] >= "0" && scalars[i] <= "9" {
            i -= 1
        }
        let digitCount = (scalars.count - 1) - i
        guard digitCount > 0, i >= 0 else { return nil }
        let sep = scalars[i]
        guard sep == "_" || sep == "." else { return nil }
        return String(String.UnicodeScalarView(scalars[i...]))
    }

    private static func partitionIntoRings(candidates: [ChainCandidate]) -> [[ChainCandidate]] {
        var byCategory: [String: [ChainCandidate]] = [:]
        var categoryOrder: [String] = []
        for c in candidates {
            if byCategory[c.category] == nil {
                categoryOrder.append(c.category)
            }
            byCategory[c.category, default: []].append(c)
        }

        var rings: [[ChainCandidate]] = []
        for category in categoryOrder {
            guard let group = byCategory[category], group.count >= 3 else { continue }

            // Detect VRoid multi-layer convention: a trailing layer suffix (`_01`, `_02`, ...)
            // shared by >= 3 chains per layer. Single-layer skirts numbered `Skirt_01..Skirt_06`
            // have count == 1 per suffix and stay unified in a single ring.
            var suffixCounts: [String: Int] = [:]
            for c in group {
                if let s = c.layerSuffix {
                    suffixCounts[s, default: 0] += 1
                }
            }
            let multiLayerSuffixes = Set(suffixCounts.filter { $0.value >= 3 }.keys)

            var buckets: [[ChainCandidate]] = []
            if !multiLayerSuffixes.isEmpty {
                var bySuffix: [String: [ChainCandidate]] = [:]
                var suffixOrder: [String] = []
                var remainder: [ChainCandidate] = []
                for c in group {
                    if let s = c.layerSuffix, multiLayerSuffixes.contains(s) {
                        if bySuffix[s] == nil { suffixOrder.append(s) }
                        bySuffix[s, default: []].append(c)
                    } else {
                        remainder.append(c)
                    }
                }
                for s in suffixOrder {
                    if let b = bySuffix[s] { buckets.append(b) }
                }
                if remainder.count >= 3 { buckets.append(remainder) }
            } else {
                buckets.append(group)
            }

            for bucket in buckets {
                rings.append(contentsOf: splitCoincidentAzimuthLayers(bucket))
            }
        }
        return rings
    }

    /// Splits a bucket that contains multiple concentric unsuffixed rings sharing
    /// nearly identical azimuths (< 8° apart) into separate layers so chains never
    /// link to a coincident chain on an inner/outer layer.
    private static func splitCoincidentAzimuthLayers(_ bucket: [ChainCandidate]) -> [[ChainCandidate]] {
        guard bucket.count >= 6 else { return [bucket] }
        let sorted = bucket.sorted {
            if $0.azimuth != $1.azimuth { return $0.azimuth < $1.azimuth }
            return $0.springIndex < $1.springIndex
        }
        let minAzimuthGap: Float = 8.0 * .pi / 180.0
        var hasOverlap = false
        for i in 0..<sorted.count {
            let a = sorted[i]
            let b = sorted[(i + 1) % sorted.count]
            var dAz = b.azimuth - a.azimuth
            if dAz < 0 { dAz += 2.0 * .pi }
            if dAz < minAzimuthGap {
                hasOverlap = true
                break
            }
        }
        guard hasOverlap else { return [sorted] }

        // Group chains within 8° azimuth clusters, sort each cluster by
        // (radialDist, height, springIndex), and assign slot k to layer k.
        var clusters: [[ChainCandidate]] = []
        for c in sorted {
            if var last = clusters.last, let first = last.first, abs(c.azimuth - first.azimuth) < minAzimuthGap {
                last.append(c)
                clusters[clusters.count - 1] = last
            } else {
                clusters.append([c])
            }
        }
        // Check wrap-around between last and first cluster.
        if clusters.count >= 2,
           let first = clusters[0].first,
           let last = clusters[clusters.count - 1].first {
            let wrapGap = (first.azimuth + 2.0 * .pi) - last.azimuth
            if wrapGap < minAzimuthGap {
                clusters[0].append(contentsOf: clusters.removeLast())
            }
        }

        let maxLayers = clusters.map(\.count).max() ?? 1
        var layers = Array(repeating: [ChainCandidate](), count: maxLayers)
        for cluster in clusters {
            let ordered = cluster.sorted {
                if abs($0.radialDist - $1.radialDist) > 1e-3 { return $0.radialDist < $1.radialDist }
                if abs($0.height - $1.height) > 1e-3 { return $0.height < $1.height }
                return $0.springIndex < $1.springIndex
            }
            for (layerIdx, chain) in ordered.enumerated() {
                layers[layerIdx].append(chain)
            }
        }
        return layers.filter { $0.count >= 3 }
    }

    private static func bestHeightMatchIndex(target: SIMD3<Float>, in positions: [SIMD3<Float>]) -> Int? {
        var bestIdx: Int?
        var bestDy = maxUnequalChainYDelta
        for (idx, pos) in positions.enumerated() {
            let dy = abs(target.y - pos.y)
            guard dy < bestDy else { continue }
            let chordLen = simd_distance(target, pos)
            guard chordLen > minChordLength, chordLen < maxChordLength else { continue }
            bestDy = dy
            bestIdx = idx
        }
        return bestIdx
    }
}
