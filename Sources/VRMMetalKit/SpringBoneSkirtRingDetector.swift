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
import Metal
import simd

/// Detects cloth-sheet chord neighbors and computes per-bone auxiliary collision
/// data (`ringLeft`, `ringRight`, `syntheticRadius`) for the SpringBone compute
/// path (#478).
///
/// Completely name- and language-agnostic (zero string matching):
/// 1. **Primary path (skinned-mesh topology):** Scans skinned mesh primitives
///    (reusing shared `(JOINTS_0, WEIGHTS_0)` accessors) to find SpringBone chains
///    stitched together by actual cloth triangles or cross-chain vertex blends.
///    Naturally discovers closed skirts, multi-layer dresses, open-front coats
///    (zero triangles bridge an open slit), capes, cloaks, aprons, kimono, and
///    ribbons regardless of bone naming or language, while ignoring unskinned
///    template chains and independent appendages (pigtails, braids, antennae).
/// 2. **Fallback path (bone-only rigs without skinned meshes):** Clusters
///    downward-hanging trunk chains geometrically by root-height band and radial
///    azimuth with a `< 110°` open-front guard.
/// 3. **Humanoid topology exclusions:** Excludes arm/hand descendants (enforcing
///    ADR-007 for stiff sleeves) and head/neck descendants (preserving calibrated
///    hair equilibria), plus chains with synthetic collisions disabled (e.g. bust).
///
/// Pure read-only analysis — never mutates `model`.
enum SpringBoneSkirtRingDetector {

    static let noNeighbor: UInt32 = 0xFFFFFFFF

    /// Maximum angular span between adjacent radial chains in the bone-only
    /// geometric fallback (110°). Wider openings (e.g. open-front coats) do not
    /// bridge across the gap.
    static let maxAngularSpanRadians: Float = 110.0 * .pi / 180.0

    /// Minimum triangle/blend edges bridging two distinct SpringBone chains to
    /// treat them as stitched by a real cloth sheet.
    private static let minMeshEdgesForSheet: Int = 2

    /// Maximum vertical difference when pairing unequal-length adjacent chains.
    private static let maxUnequalChainYDelta: Float = 0.12

    /// Maximum root-height spread within a single radial band in the bone-only
    /// geometric fallback.
    private static let maxGeometricBandYSpread: Float = 0.18

    /// Sanity bounds on rest-pose chord length between adjacent cloth joints (metres).
    private static let minChordLength: Float = 1e-3
    private static let maxChordLength: Float = 0.60

    struct DetectionResult {
        var aux: [SpringBoneCollisionAux]
        var hasRingNeighbors: Bool
        /// Number of connected cloth sheets / rings detected (>= 2 linked chains each).
        var ringCount: Int
        var linkedBoneCount: Int
        var inheritedHemRadiusCount: Int
        /// Connected components of non-empty chain indices linked by cloth chords
        /// (each component has >= 2 chains). Used by the async sleep gate so coupled
        /// cloth chains wake and sleep in lockstep.
        var ringChainComponents: [[Int]]
    }

    private struct MeshSkinPair: Hashable {
        let meshIndex: Int
        let skinIndex: Int
    }

    private struct JointWeightAccessorKey: Hashable {
        let joints: Int
        let weights: Int
    }

    private struct ChainPair: Hashable {
        let a: Int
        let b: Int
        init(_ x: Int, _ y: Int) {
            if x <= y { a = x; b = y } else { a = y; b = x }
        }
    }

    private struct ChainMeta {
        let springIndex: Int
        let chainIndex: Int
        let boneStart: Int
        let jointCount: Int
        let eligibleForSheet: Bool
        let lowerBodyAncestor: Bool
        let hangsDownward: Bool
        let rootPos: SIMD3<Float>
        let jointWorldPositions: [SIMD3<Float>]
    }

    private struct GeometricCandidate {
        let chainIndex: Int
        let springIndex: Int
        let boneStart: Int
        let jointCount: Int
        let azimuth: Float
        let radialDist: Float
        let height: Float
        let jointWorldPositions: [SIMD3<Float>]
    }

    /// Humanoid bones whose descendants are excluded from cloth-sheet chords and
    /// terminal-radius inheritance:
    /// - Head/neck/face: preserves calibrated hair/head-accessory equilibria.
    /// - UpperArm/LowerArm/Hand/Fingers: enforces ADR-007 (excludes stiff sleeves).
    /// Note: `leftShoulder`/`rightShoulder` are intentionally NOT excluded so
    /// shoulder-anchored capes/cloaks remain eligible.
    private static let excludedAncestorBones: [VRMHumanoidBone] = [
        .head, .neck, .leftEye, .rightEye, .jaw,
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

    /// Lower-body trunk humanoid bones whose non-arm, non-head hanging spring
    /// chains receive terminal VRM 1.0 `hitRadius` inheritance for synthetic
    /// collisions even when they are standalone panels/ribbons/tails.
    private static let lowerBodyAncestorBones: [VRMHumanoidBone] = [
        .hips, .spine,
        .leftUpperLeg, .rightUpperLeg,
        .leftLowerLeg, .rightLowerLeg,
    ]

    static func buildCollisionAux(
        model: VRMModel,
        hasSyntheticColliders: Bool,
        chainSyntheticEnabled: [Bool]? = nil
    ) -> DetectionResult {
        guard let springBone = model.springBone else {
            return DetectionResult(
                aux: [],
                hasRingNeighbors: false,
                ringCount: 0,
                linkedBoneCount: 0,
                inheritedHemRadiusCount: 0,
                ringChainComponents: []
            )
        }

        let allHumanoidNodes = humanoidNodeSet(model: model, bones: Array(VRMHumanoidBone.allCases))
        let excludedNodes = humanoidNodeSet(model: model, bones: excludedAncestorBones)
        let lowerBodyNodes = humanoidNodeSet(model: model, bones: lowerBodyAncestorBones)
        let hasHumanoid = model.humanoid != nil

        // 1. Collect per-chain metadata and initialize aux entries in exact
        //    populateSpringBoneData order (skipping empty springs).
        var aux: [SpringBoneCollisionAux] = []
        var chains: [ChainMeta] = []
        var nonEmptySprings: [VRMSpring] = []
        var boneIndex = 0
        var chainIndex = 0

        for (springIndex, spring) in springBone.springs.enumerated() {
            guard !spring.joints.isEmpty else { continue }
            let currentChainIndex = chainIndex
            chainIndex += 1
            nonEmptySprings.append(spring)

            let boneStart = boneIndex
            let jointCount = spring.joints.count
            let rootNode = model.nodes[safe: spring.joints[0].node]
            let rootPos = rootNode?.worldPosition ?? .zero
            let jointPositions: [SIMD3<Float>] = spring.joints.map { joint in
                model.nodes[safe: joint.node]?.worldPosition ?? rootPos
            }

            let syntheticEnabled: Bool
            if let mask = chainSyntheticEnabled, currentChainIndex < mask.count {
                syntheticEnabled = mask[currentChainIndex]
            } else {
                // Mirror SpringBoneComputeSystem's bust exclusion when called standalone.
                syntheticEnabled = !(spring.name ?? "").lowercased().contains("bust")
            }

            let excludedByAncestor = descendsFrom(node: rootNode, in: excludedNodes)
            let isLowerBody = nearestHumanoidAncestorIn(
                node: rootNode,
                humanoidNodes: allHumanoidNodes,
                targets: lowerBodyNodes
            )

            let tipPos = jointPositions.last ?? rootPos
            let dy = tipPos.y - rootPos.y
            let span = simd_distance(tipPos, rootPos)
            let hangsDownward = (dy < -0.03) && (span > 1e-4) && (dy / span < -0.45)

            let eligibleForSheet = hasSyntheticColliders
                && syntheticEnabled
                && jointCount >= 2
                && !excludedByAncestor

            chains.append(ChainMeta(
                springIndex: springIndex,
                chainIndex: currentChainIndex,
                boneStart: boneStart,
                jointCount: jointCount,
                eligibleForSheet: eligibleForSheet,
                lowerBodyAncestor: isLowerBody,
                hangsDownward: hangsDownward,
                rootPos: rootPos,
                jointWorldPositions: jointPositions
            ))

            for joint in spring.joints {
                aux.append(SpringBoneCollisionAux(
                    ringLeft: noNeighbor,
                    ringRight: noNeighbor,
                    syntheticRadius: joint.hitRadius,
                    flags: 0
                ))
                boneIndex += 1
            }
        }

        guard hasSyntheticColliders else {
            return DetectionResult(
                aux: aux,
                hasRingNeighbors: false,
                ringCount: 0,
                linkedBoneCount: 0,
                inheritedHemRadiusCount: 0,
                ringChainComponents: []
            )
        }

        // Compute hips reference for consistent left/right azimuth ordering.
        let centerRef: SIMD3<Float> = {
            if let hipsIdx = model.humanoid?.getBoneNode(.hips),
               let hipsNode = model.nodes[safe: hipsIdx] {
                return hipsNode.worldPosition
            }
            let eligible = chains.filter(\.eligibleForSheet)
            guard !eligible.isEmpty else { return .zero }
            let sum = eligible.reduce(SIMD3<Float>.zero) { $0 + $1.rootPos }
            return sum / Float(eligible.count)
        }()

        // 2. Detect cloth-sheet chain adjacency:
        //    - Primary: skinned-mesh triangle & cross-chain blend connectivity.
        //    - Fallback: pure geometric radial curtain detection when no skinned
        //      meshes are present on the model.
        let (hasSkinnedMeshes, meshEdges) = scanSkinnedMeshChainConnectivity(
            model: model,
            springs: nonEmptySprings,
            chains: chains
        )

        var chainAdj: [Int: Set<Int>] = [:]
        var totalLinks = 0
        if hasSkinnedMeshes {
            totalLinks = linkMeshConnectedChains(
                meshEdges: meshEdges,
                chains: chains,
                centerRef: centerRef,
                aux: &aux,
                chainAdj: &chainAdj
            )
        } else {
            totalLinks = linkGeometricFallbackRings(
                chains: chains,
                centerRef: centerRef,
                aux: &aux,
                chainAdj: &chainAdj
            )
        }

        // 3. VRM 1.0 terminal joint hitRadius inheritance for synthetic collisions:
        //    Applies to every eligible chain that either participates in a detected
        //    cloth sheet (skirts, dresses, coats, capes, cloaks, aprons, kimono) or
        //    hangs from the lower-body trunk (hips/spine/legs: sashes, ribbons, tails)
        //    or hangs downward on a non-humanoid rig. Never touches head/hair or arms.
        var inheritedHemCount = 0
        let linkedChainSet = Set(chainAdj.keys)
        for chain in chains where chain.eligibleForSheet {
            let isTerminalEligible = linkedChainSet.contains(chain.chainIndex)
                || (chain.lowerBodyAncestor && chain.hangsDownward)
                || (!hasHumanoid && chain.hangsDownward)
            guard isTerminalEligible else { continue }

            let spring = nonEmptySprings[chain.chainIndex]
            let lastJointIdx = chain.jointCount - 1
            let lastBoneIdx = chain.boneStart + lastJointIdx
            guard lastBoneIdx < aux.count, aux[lastBoneIdx].syntheticRadius <= 0 else { continue }
            for back in stride(from: lastJointIdx - 1, through: 0, by: -1) {
                if spring.joints[back].hitRadius > 0 {
                    aux[lastBoneIdx].syntheticRadius = spring.joints[back].hitRadius
                    inheritedHemCount += 1
                    break
                }
            }
        }

        var linkedBones = 0
        for i in 0..<aux.count {
            if aux[i].ringLeft != noNeighbor || aux[i].ringRight != noNeighbor {
                aux[i].flags |= 1
                linkedBones += 1
            }
        }

        let components = connectedChainComponents(adjacency: chainAdj)

        return DetectionResult(
            aux: aux,
            hasRingNeighbors: totalLinks > 0,
            ringCount: components.count,
            linkedBoneCount: linkedBones,
            inheritedHemRadiusCount: inheritedHemCount,
            ringChainComponents: components
        )
    }

    // MARK: - Primary Path: Skinned-Mesh Cloth Connectivity

    /// Scans all unique `(mesh, skin)` pairs directly from their GPU buffers to count
    /// mesh triangles and cross-chain blended vertices connecting distinct eligible
    /// SpringBone chains. Deduplicates vertex-weight decoding across primitives that
    /// share `(JOINTS_0, WEIGHTS_0)` accessors.
    private static func scanSkinnedMeshChainConnectivity(
        model: VRMModel,
        springs: [VRMSpring],
        chains: [ChainMeta]
    ) -> (hasSkinnedMeshes: Bool, edges: [ChainPair: Int]) {
        var nodeToChain: [Int: Int] = [:]
        for chain in chains where chain.eligibleForSheet {
            for joint in springs[chain.chainIndex].joints {
                if nodeToChain[joint.node] == nil {
                    nodeToChain[joint.node] = chain.chainIndex
                }
            }
        }

        var hasSkinnedMeshes = false
        var edges: [ChainPair: Int] = [:]
        var seenPairs = Set<MeshSkinPair>()

        for node in model.nodes {
            guard let meshIndex = node.mesh, meshIndex >= 0, meshIndex < model.meshes.count,
                  let skinIndex = node.skin, skinIndex >= 0, skinIndex < model.skins.count else { continue }
            guard seenPairs.insert(MeshSkinPair(meshIndex: meshIndex, skinIndex: skinIndex)).inserted else { continue }

            let mesh = model.meshes[meshIndex]
            let skin = model.skins[skinIndex]
            let jointCount = skin.joints.count
            guard jointCount > 0 else { continue }

            // Check whether this mesh actually carries skinned vertices.
            let meshHasSkinnedPrim = mesh.primitives.contains { $0.vertexCount > 0 && $0.vertexBuffer != nil }
            if meshHasSkinnedPrim { hasSkinnedMeshes = true }
            guard !nodeToChain.isEmpty else { continue }

            var slotToChain = [Int32](repeating: -1, count: jointCount)
            var anyEligibleSlot = false
            for slot in 0..<jointCount {
                if let cIdx = nodeToChain[skin.joints[slot].index] {
                    slotToChain[slot] = Int32(cIdx)
                    anyEligibleSlot = true
                }
            }
            guard anyEligibleSlot else { continue }

            var cachedDomByAccessor: [JointWeightAccessorKey: [Int32]] = [:]

            for primitive in mesh.primitives {
                let vCount = primitive.vertexCount
                guard vCount > 0, let posBuf = primitive.vertexBuffer else { continue }

                let domChains: [Int32]
                if let ja = primitive.jointsAccessorIndex, let wa = primitive.weightsAccessorIndex {
                    let key = JointWeightAccessorKey(joints: ja, weights: wa)
                    if let cached = cachedDomByAccessor[key], cached.count == vCount {
                        domChains = cached
                    } else {
                        let computed = buildDominantChainPerVertex(
                            primitive: primitive,
                            posBuf: posBuf,
                            vCount: vCount,
                            slotToChain: slotToChain,
                            blendEdges: &edges
                        )
                        cachedDomByAccessor[key] = computed
                        domChains = computed
                    }
                } else {
                    domChains = buildDominantChainPerVertex(
                        primitive: primitive,
                        posBuf: posBuf,
                        vCount: vCount,
                        slotToChain: slotToChain,
                        blendEdges: &edges
                    )
                }

                accumulateTriangleChainEdges(
                    primitive: primitive,
                    domChains: domChains,
                    edges: &edges
                )
            }
        }

        return (hasSkinnedMeshes, edges)
    }

    private static func buildDominantChainPerVertex(
        primitive: VRMPrimitive,
        posBuf: MTLBuffer,
        vCount: Int,
        slotToChain: [Int32],
        blendEdges: inout [ChainPair: Int]
    ) -> [Int32] {
        var dom = [Int32](repeating: -1, count: vCount)
        let jointCount = slotToChain.count

        @inline(__always)
        func processVertex(_ idx: Int, joints: SIMD4<UInt32>, weights: SIMD4<Float>) {
            let j0 = Int(joints.x), j1 = Int(joints.y), j2 = Int(joints.z), j3 = Int(joints.w)
            let w0 = weights.x, w1 = weights.y, w2 = weights.z, w3 = weights.w
            let c0: Int32 = (w0 > 0.05 && j0 >= 0 && j0 < jointCount) ? slotToChain[j0] : -1
            let c1: Int32 = (w1 > 0.05 && j1 >= 0 && j1 < jointCount) ? slotToChain[j1] : -1
            let c2: Int32 = (w2 > 0.05 && j2 >= 0 && j2 < jointCount) ? slotToChain[j2] : -1
            let c3: Int32 = (w3 > 0.05 && j3 >= 0 && j3 < jointCount) ? slotToChain[j3] : -1
            if c0 < 0 && c1 < 0 && c2 < 0 && c3 < 0 { return }

            // Sum weights per distinct chain across the 4 lanes to find dominant chain
            // and record genuine cross-chain skinning blends (> 0.10 on both chains).
            var bestChain: Int32 = -1
            var bestWeight: Float = 0

            @inline(__always)
            func totalWeight(for target: Int32) -> Float {
                var sum: Float = 0
                if c0 == target { sum += w0 }
                if c1 == target { sum += w1 }
                if c2 == target { sum += w2 }
                if c3 == target { sum += w3 }
                return sum
            }

            if c0 >= 0 {
                let tw = totalWeight(for: c0)
                if tw > bestWeight { bestWeight = tw; bestChain = c0 }
            }
            if c1 >= 0 && c1 != c0 {
                let tw = totalWeight(for: c1)
                if tw > bestWeight { bestWeight = tw; bestChain = c1 }
            }
            if c2 >= 0 && c2 != c0 && c2 != c1 {
                let tw = totalWeight(for: c2)
                if tw > bestWeight { bestWeight = tw; bestChain = c2 }
            }
            if c3 >= 0 && c3 != c0 && c3 != c1 && c3 != c2 {
                let tw = totalWeight(for: c3)
                if tw > bestWeight { bestWeight = tw; bestChain = c3 }
            }

            dom[idx] = bestChain

            // Record cross-chain skinning blend edges between distinct chains.
            if c0 >= 0 && c1 >= 0 && c0 != c1 && w0 > 0.10 && w1 > 0.10 {
                blendEdges[ChainPair(Int(c0), Int(c1)), default: 0] += 1
            }
            if c0 >= 0 && c2 >= 0 && c0 != c2 && w0 > 0.10 && w2 > 0.10 {
                blendEdges[ChainPair(Int(c0), Int(c2)), default: 0] += 1
            }
            if c0 >= 0 && c3 >= 0 && c0 != c3 && w0 > 0.10 && w3 > 0.10 {
                blendEdges[ChainPair(Int(c0), Int(c3)), default: 0] += 1
            }
            if c1 >= 0 && c2 >= 0 && c1 != c2 && w1 > 0.10 && w2 > 0.10 {
                blendEdges[ChainPair(Int(c1), Int(c2)), default: 0] += 1
            }
            if c1 >= 0 && c3 >= 0 && c1 != c3 && w1 > 0.10 && w3 > 0.10 {
                blendEdges[ChainPair(Int(c1), Int(c3)), default: 0] += 1
            }
            if c2 >= 0 && c3 >= 0 && c2 != c3 && w2 > 0.10 && w3 > 0.10 {
                blendEdges[ChainPair(Int(c2), Int(c3)), default: 0] += 1
            }
        }

        if let attrBuf = primitive.attributeBuffer {
            guard attrBuf.length >= vCount * MemoryLayout<VRMAttributeVertex>.stride else { return dom }
            let attrPtr = attrBuf.contents().bindMemory(to: VRMAttributeVertex.self, capacity: vCount)
            for i in 0..<vCount {
                processVertex(i, joints: attrPtr[i].joints, weights: attrPtr[i].weights)
            }
        } else {
            guard posBuf.length >= vCount * MemoryLayout<VRMVertex>.stride else { return dom }
            let vPtr = posBuf.contents().bindMemory(to: VRMVertex.self, capacity: vCount)
            for i in 0..<vCount {
                processVertex(i, joints: vPtr[i].joints, weights: vPtr[i].weights)
            }
        }
        return dom
    }

    private static func accumulateTriangleChainEdges(
        primitive: VRMPrimitive,
        domChains: [Int32],
        edges: inout [ChainPair: Int]
    ) {
        let vCount = domChains.count
        guard vCount >= 3 else { return }

        @inline(__always)
        func recordTriangle(_ i0: Int, _ i1: Int, _ i2: Int) {
            guard i0 < vCount && i1 < vCount && i2 < vCount else { return }
            let c0 = domChains[i0]
            let c1 = domChains[i1]
            let c2 = domChains[i2]
            if c0 < 0 && c1 < 0 && c2 < 0 { return }
            if c0 >= 0 && c1 >= 0 && c0 != c1 {
                edges[ChainPair(Int(c0), Int(c1)), default: 0] += 1
            }
            if c1 >= 0 && c2 >= 0 && c1 != c2 {
                edges[ChainPair(Int(c1), Int(c2)), default: 0] += 1
            }
            if c2 >= 0 && c0 >= 0 && c2 != c0 {
                edges[ChainPair(Int(c2), Int(c0)), default: 0] += 1
            }
        }

        if let idxBuf = primitive.indexBuffer, primitive.indexCount >= 3 {
            let offset = primitive.indexBufferOffset
            let count = primitive.indexCount
            if primitive.indexType == .uint16 {
                guard offset >= 0, offset + count * MemoryLayout<UInt16>.stride <= idxBuf.length else { return }
                let ptr = idxBuf.contents().advanced(by: offset).bindMemory(to: UInt16.self, capacity: count)
                if primitive.primitiveType == .triangle {
                    var t = 0
                    while t + 2 < count {
                        recordTriangle(Int(ptr[t]), Int(ptr[t + 1]), Int(ptr[t + 2]))
                        t += 3
                    }
                } else if primitive.primitiveType == .triangleStrip {
                    for t in 0..<(count - 2) {
                        recordTriangle(Int(ptr[t]), Int(ptr[t + 1]), Int(ptr[t + 2]))
                    }
                }
            } else {
                guard offset >= 0, offset + count * MemoryLayout<UInt32>.stride <= idxBuf.length else { return }
                let ptr = idxBuf.contents().advanced(by: offset).bindMemory(to: UInt32.self, capacity: count)
                if primitive.primitiveType == .triangle {
                    var t = 0
                    while t + 2 < count {
                        recordTriangle(Int(ptr[t]), Int(ptr[t + 1]), Int(ptr[t + 2]))
                        t += 3
                    }
                } else if primitive.primitiveType == .triangleStrip {
                    for t in 0..<(count - 2) {
                        recordTriangle(Int(ptr[t]), Int(ptr[t + 1]), Int(ptr[t + 2]))
                    }
                }
            }
        } else {
            if primitive.primitiveType == .triangle {
                var t = 0
                while t + 2 < vCount {
                    recordTriangle(t, t + 1, t + 2)
                    t += 3
                }
            } else if primitive.primitiveType == .triangleStrip {
                for t in 0..<(vCount - 2) {
                    recordTriangle(t, t + 1, t + 2)
                }
            }
        }
    }

    /// Selects up to 2 sheet neighbors (`ringLeft`, `ringRight`) per chain from the
    /// mesh-connectivity graph and wires per-joint chord links (skipping roots).
    private static func linkMeshConnectedChains(
        meshEdges: [ChainPair: Int],
        chains: [ChainMeta],
        centerRef: SIMD3<Float>,
        aux: inout [SpringBoneCollisionAux],
        chainAdj: inout [Int: Set<Int>]
    ) -> Int {
        // Build weighted neighbor list per chain, filtering weak/invalid pairs.
        var weightedNeighbors: [Int: [(nb: Int, weight: Int)]] = [:]
        for (pair, weight) in meshEdges where weight >= minMeshEdgesForSheet {
            let cA = chains[pair.a]
            let cB = chains[pair.b]
            guard cA.eligibleForSheet && cB.eligibleForSheet else { continue }
            let rootDist = simd_distance(cA.rootPos, cB.rootPos)
            guard rootDist > minChordLength && rootDist < maxChordLength else { continue }
            weightedNeighbors[pair.a, default: []].append((pair.b, weight))
            weightedNeighbors[pair.b, default: []].append((pair.a, weight))
        }
        guard !weightedNeighbors.isEmpty else { return 0 }

        // Select up to 2 best neighbors per chain (deterministic; prefers opposite
        // sides when degree > 2 so a seam/corner doesn't double-link one side).
        var selectedNeighbors: [Int: [Int]] = [:]
        for (cIdx, rawList) in weightedNeighbors {
            let rootA = chains[cIdx].rootPos
            let sorted = rawList.sorted { lhs, rhs in
                if lhs.weight != rhs.weight { return lhs.weight > rhs.weight }
                let dL = simd_distance(rootA, chains[lhs.nb].rootPos)
                let dR = simd_distance(rootA, chains[rhs.nb].rootPos)
                if dL != dR { return dL < dR }
                return lhs.nb < rhs.nb
            }
            if sorted.count <= 2 {
                selectedNeighbors[cIdx] = sorted.map(\.nb)
            } else {
                let first = sorted[0].nb
                let dir1 = simd_normalize(chains[first].rootPos - rootA)
                var second = sorted[1].nb
                for cand in sorted.dropFirst() {
                    let dir2 = simd_normalize(chains[cand.nb].rootPos - rootA)
                    if simd_dot(dir1, dir2) < 0.5 {
                        second = cand.nb
                        break
                    }
                }
                selectedNeighbors[cIdx] = [first, second]
            }
        }

        // Order each chain's chosen neighbors into (left, right) consistently by
        // azimuth around centerRef and wire non-root joint chords.
        var totalLinks = 0
        let totalBones = aux.count
        for cIdx in selectedNeighbors.keys.sorted() {
            guard let nbs = selectedNeighbors[cIdx], !nbs.isEmpty else { continue }
            let chainA = chains[cIdx]
            let relA = chainA.rootPos - centerRef
            let azA = atan2(relA.x, relA.z)

            let orderedNbs: [Int]
            if nbs.count == 2 {
                let rel0 = chains[nbs[0]].rootPos - centerRef
                let rel1 = chains[nbs[1]].rootPos - centerRef
                var d0 = atan2(rel0.x, rel0.z) - azA
                if d0 < 0 { d0 += 2.0 * .pi }
                var d1 = atan2(rel1.x, rel1.z) - azA
                if d1 < 0 { d1 += 2.0 * .pi }
                orderedNbs = (d0 <= d1) ? [nbs[1], nbs[0]] : [nbs[0], nbs[1]]
            } else {
                orderedNbs = nbs
            }

            for (slot, nbIdx) in orderedNbs.enumerated() {
                let chainB = chains[nbIdx]
                var linked = false
                if chainA.jointCount == chainB.jointCount {
                    for j in 1..<chainA.jointCount {
                        let dist = simd_distance(chainA.jointWorldPositions[j], chainB.jointWorldPositions[j])
                        guard dist > minChordLength, dist < maxChordLength else { continue }
                        let idxA = chainA.boneStart + j
                        let idxB = chainB.boneStart + j
                        guard idxA < totalBones, idxB < totalBones, idxA != idxB else { continue }
                        if slot == 0 {
                            aux[idxA].ringLeft = UInt32(idxB)
                        } else {
                            aux[idxA].ringRight = UInt32(idxB)
                        }
                        totalLinks += 1
                        linked = true
                    }
                } else {
                    for ja in 1..<chainA.jointCount {
                        let pA = chainA.jointWorldPositions[ja]
                        if let jb = bestHeightMatchIndex(target: pA, in: chainB.jointWorldPositions) {
                            let idxA = chainA.boneStart + ja
                            let idxB = chainB.boneStart + jb
                            if idxA < totalBones, idxB < totalBones, idxA != idxB {
                                if slot == 0 {
                                    aux[idxA].ringLeft = UInt32(idxB)
                                } else {
                                    aux[idxA].ringRight = UInt32(idxB)
                                }
                                totalLinks += 1
                                linked = true
                            }
                        }
                    }
                }
                if linked && cIdx != nbIdx {
                    chainAdj[cIdx, default: []].insert(nbIdx)
                    chainAdj[nbIdx, default: []].insert(cIdx)
                }
            }
        }
        return totalLinks
    }

    // MARK: - Fallback Path: Pure Geometric Radial Curtain Detection (Bone-Only Rigs)

    /// Used ONLY when a model has no skinned mesh primitives (e.g. procedural rigs).
    /// Clusters downward-hanging eligible chains purely by root height band and
    /// radial azimuth (zero string matching).
    private static func linkGeometricFallbackRings(
        chains: [ChainMeta],
        centerRef: SIMD3<Float>,
        aux: inout [SpringBoneCollisionAux],
        chainAdj: inout [Int: Set<Int>]
    ) -> Int {
        var candidates: [GeometricCandidate] = []
        for chain in chains where chain.eligibleForSheet && chain.hangsDownward {
            let rel = chain.rootPos - centerRef
            candidates.append(GeometricCandidate(
                chainIndex: chain.chainIndex,
                springIndex: chain.springIndex,
                boneStart: chain.boneStart,
                jointCount: chain.jointCount,
                azimuth: atan2(rel.x, rel.z),
                radialDist: hypot(rel.x, rel.z),
                height: rel.y,
                jointWorldPositions: chain.jointWorldPositions
            ))
        }
        guard candidates.count >= 3 else { return 0 }

        // Cluster by root-height bands so upper-body capes and lower-body skirts
        // never mix, without inspecting any names.
        let byHeight = candidates.sorted {
            if $0.height != $1.height { return $0.height < $1.height }
            return $0.springIndex < $1.springIndex
        }
        var heightBands: [[GeometricCandidate]] = []
        for c in byHeight {
            if var last = heightBands.last, let first = last.first,
               (c.height - first.height) <= maxGeometricBandYSpread {
                last.append(c)
                heightBands[heightBands.count - 1] = last
            } else {
                heightBands.append([c])
            }
        }

        var rings: [[GeometricCandidate]] = []
        for band in heightBands where band.count >= 3 {
            rings.append(contentsOf: splitCoincidentAzimuthLayers(band))
        }

        var totalLinks = 0
        let totalBones = aux.count
        for ring in rings where ring.count >= 3 {
            let sorted = ring.sorted {
                if $0.azimuth != $1.azimuth { return $0.azimuth < $1.azimuth }
                return $0.springIndex < $1.springIndex
            }
            for i in 0..<sorted.count {
                let chainA = sorted[i]
                var nextOffset = 1
                var selectedPair: (chain: GeometricCandidate, dAz: Float)? = nil
                while nextOffset < sorted.count {
                    let cand = sorted[(i + nextOffset) % sorted.count]
                    var dAz = cand.azimuth - chainA.azimuth
                    if dAz < 0 { dAz += 2.0 * .pi }
                    if dAz > 1e-4 {
                        selectedPair = (cand, dAz)
                        break
                    }
                    nextOffset += 1
                }
                guard let (chainB, dAz) = selectedPair, dAz < maxAngularSpanRadians else { continue }

                var linked = false
                if chainA.jointCount == chainB.jointCount {
                    for j in 1..<chainA.jointCount {
                        let dist = simd_distance(chainA.jointWorldPositions[j], chainB.jointWorldPositions[j])
                        guard dist > minChordLength, dist < maxChordLength else { continue }
                        let idxA = chainA.boneStart + j
                        let idxB = chainB.boneStart + j
                        guard idxA < totalBones, idxB < totalBones, idxA != idxB else { continue }
                        aux[idxA].ringRight = UInt32(idxB)
                        aux[idxB].ringLeft = UInt32(idxA)
                        totalLinks += 1
                        linked = true
                    }
                } else {
                    for ja in 1..<chainA.jointCount {
                        let pA = chainA.jointWorldPositions[ja]
                        if let jb = bestHeightMatchIndex(target: pA, in: chainB.jointWorldPositions) {
                            let idxA = chainA.boneStart + ja
                            let idxB = chainB.boneStart + jb
                            if idxA < totalBones, idxB < totalBones, idxA != idxB {
                                aux[idxA].ringRight = UInt32(idxB)
                                totalLinks += 1
                                linked = true
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
                                totalLinks += 1
                                linked = true
                            }
                        }
                    }
                }
                if linked && chainA.chainIndex != chainB.chainIndex {
                    chainAdj[chainA.chainIndex, default: []].insert(chainB.chainIndex)
                    chainAdj[chainB.chainIndex, default: []].insert(chainA.chainIndex)
                }
            }
        }
        return totalLinks
    }

    // MARK: - Helpers

    private static func humanoidNodeSet(model: VRMModel, bones: [VRMHumanoidBone]) -> Set<Int> {
        guard let humanoid = model.humanoid else { return [] }
        var set = Set<Int>()
        for bone in bones {
            if let idx = humanoid.getBoneNode(bone), idx >= 0, idx < model.nodes.count {
                set.insert(idx)
            }
        }
        return set
    }

    private static func descendsFrom(node: VRMNode?, in targetNodes: Set<Int>) -> Bool {
        guard !targetNodes.isEmpty else { return false }
        var cur = node
        var depth = 0
        while let n = cur, depth < 64 {
            if targetNodes.contains(n.index) { return true }
            cur = n.parent
            depth += 1
        }
        return false
    }

    /// Walks up from `node` until the nearest mapped humanoid bone and returns
    /// whether that bone is in `targets`. Prevents upper-torso descendants
    /// (`chest`/`upperChest`/`shoulders`) from matching `.hips`/`.spine`.
    private static func nearestHumanoidAncestorIn(
        node: VRMNode?,
        humanoidNodes: Set<Int>,
        targets: Set<Int>
    ) -> Bool {
        guard !humanoidNodes.isEmpty, !targets.isEmpty else { return false }
        var cur = node
        var depth = 0
        while let n = cur, depth < 64 {
            if humanoidNodes.contains(n.index) {
                return targets.contains(n.index)
            }
            cur = n.parent
            depth += 1
        }
        return false
    }

    private static func connectedChainComponents(adjacency: [Int: Set<Int>]) -> [[Int]] {
        guard !adjacency.isEmpty else { return [] }
        var visited = Set<Int>()
        var components: [[Int]] = []
        for start in adjacency.keys.sorted() where visited.insert(start).inserted {
            var stack = [start]
            var comp: [Int] = []
            while let cur = stack.popLast() {
                comp.append(cur)
                if let neighbors = adjacency[cur] {
                    for nb in neighbors where visited.insert(nb).inserted {
                        stack.append(nb)
                    }
                }
            }
            if comp.count >= 2 {
                comp.sort()
                components.append(comp)
            }
        }
        return components
    }

    /// Splits a height band that contains multiple concentric unsuffixed rings sharing
    /// nearly identical azimuths (< 8° apart) into separate layers using a strict weak
    /// ordering over quantized `(radialDistMm, heightMm, springIndex)`.
    private static func splitCoincidentAzimuthLayers(_ bucket: [GeometricCandidate]) -> [[GeometricCandidate]] {
        guard bucket.count >= 4 else { return [bucket] }
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

        var clusters: [[GeometricCandidate]] = []
        for c in sorted {
            if var last = clusters.last, let first = last.first, abs(c.azimuth - first.azimuth) < minAzimuthGap {
                last.append(c)
                clusters[clusters.count - 1] = last
            } else {
                clusters.append([c])
            }
        }
        if clusters.count >= 2,
           let first = clusters[0].first,
           let last = clusters[clusters.count - 1].first {
            let wrapGap = (first.azimuth + 2.0 * .pi) - last.azimuth
            if wrapGap < minAzimuthGap {
                clusters[0].append(contentsOf: clusters.removeLast())
            }
        }

        let maxLayers = clusters.map(\.count).max() ?? 1
        var layers = Array(repeating: [GeometricCandidate](), count: maxLayers)
        for cluster in clusters {
            let ordered = cluster.sorted { a, b in
                let rA = Int((a.radialDist * 1000.0).rounded())
                let rB = Int((b.radialDist * 1000.0).rounded())
                if rA != rB { return rA < rB }
                let hA = Int((a.height * 1000.0).rounded())
                let hB = Int((b.height * 1000.0).rounded())
                if hA != hB { return hA < hB }
                return a.springIndex < b.springIndex
            }
            for (layerIdx, chain) in ordered.enumerated() {
                layers[layerIdx].append(chain)
            }
        }
        return layers.filter { $0.count >= 3 }
    }

    /// Matches a non-root joint height against non-root joints (`1..<positions.count`)
    /// on an adjacent unequal-length chain so kinematic roots (index 0) are never linked.
    private static func bestHeightMatchIndex(target: SIMD3<Float>, in positions: [SIMD3<Float>]) -> Int? {
        guard positions.count > 1 else { return nil }
        var bestIdx: Int?
        var bestDy = maxUnequalChainYDelta
        for idx in 1..<positions.count {
            let pos = positions[idx]
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
