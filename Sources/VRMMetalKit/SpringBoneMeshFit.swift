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

/// Unified, mesh-name-agnostic skinned-mesh collider fitter (#377, #478).
///
/// Scans all skinned meshes in a single zero-allocation pass over their split GPU
/// vertex/attribute buffers, deduplicating primitives that share identical
/// `POSITION`/`JOINTS_0`/`WEIGHTS_0` accessors (common in VRoid Studio exports).
/// Classifies vertices strictly by humanoid/spring joint weight rather than mesh
/// name so non-VRoid naming conventions (`Garment_outfit.*`, `Accessory_*`, etc.)
/// are covered alongside VRoid `"Body"` meshes.
enum SpringBoneMeshFit {

    struct FittedColliders {
        var breasts: [VRMCollider] = []
        var shoulders: [VRMCollider] = []
        var torso: [VRMCollider] = []
        var hands: [VRMCollider] = []
    }

    struct BreastFit {
        let anchor: Int
        let centroidWorld: SIMD3<Float>
        let radius: Float
    }

    private struct MeshSkinPair: Hashable {
        let meshIndex: Int
        let skinIndex: Int
    }

    private struct AccessorTriple: Hashable {
        let position: Int
        let joints: Int
        let weights: Int
    }

    private static let leftFingerBones: [VRMHumanoidBone] = [
        .leftThumbMetacarpal, .leftThumbProximal, .leftThumbDistal,
        .leftIndexProximal, .leftIndexIntermediate, .leftIndexDistal,
        .leftMiddleProximal, .leftMiddleIntermediate, .leftMiddleDistal,
        .leftRingProximal, .leftRingIntermediate, .leftRingDistal,
        .leftLittleProximal, .leftLittleIntermediate, .leftLittleDistal,
    ]

    private static let rightFingerBones: [VRMHumanoidBone] = [
        .rightThumbMetacarpal, .rightThumbProximal, .rightThumbDistal,
        .rightIndexProximal, .rightIndexIntermediate, .rightIndexDistal,
        .rightMiddleProximal, .rightMiddleIntermediate, .rightMiddleDistal,
        .rightRingProximal, .rightRingIntermediate, .rightRingDistal,
        .rightLittleProximal, .rightLittleIntermediate, .rightLittleDistal,
    ]

    private static let handExcludedSubstrings: [String] = [
        "sleeve", "skirt", "cloth", "cuff", "ribbon", "cape",
        "hair", "prop", "weapon", "item", "accessory", "bag", "sword", "staff",
    ]

    /// Computes all mesh-fitted synthetic colliders (breasts, shoulders, upper torso,
    /// and adaptive 2/3-capsule hand paddles) in a single scan over all skinned meshes.
    static func computeAll(model: VRMModel) -> FittedColliders {
        var out = FittedColliders()
        guard let humanoid = model.humanoid else { return out }

        let scan = scanAllRegions(
            model: model,
            humanoid: humanoid,
            includeBreasts: true,
            includeShoulders: true,
            includeTorso: true,
            includeHands: true
        )

        out.breasts = buildBreastColliders(
            from: scan.bustSides,
            verticesBySide: scan.bustVertices,
            humanoid: humanoid,
            model: model,
            radiusPercentile: 1.0,
            radiusScale: 1.0
        )
        out.shoulders = buildShoulderColliders(
            from: scan.shoulderSides,
            verticesBySide: scan.shoulderVertices,
            model: model,
            radiusPercentile: 0.95,
            radiusScale: 1.0
        )
        out.torso = buildTorsoCollider(
            spineNode: scan.torsoSpineNode,
            superiorNode: scan.torsoSuperiorNode,
            dists: scan.torsoDists,
            model: model,
            radiusPercentile: 0.90,
            radiusScale: 1.0
        )
        out.hands = buildHandColliders(
            leftVerts: scan.leftHandVertices,
            rightVerts: scan.rightHandVertices,
            humanoid: humanoid,
            model: model
        )
        return out
    }

    static func computeBreastFits(model: VRMModel, radiusPercentile: Float) -> [BreastFit] {
        let scan = scanAllRegions(
            model: model,
            humanoid: model.humanoid,
            includeBreasts: true,
            includeShoulders: false,
            includeTorso: false,
            includeHands: false
        )
        return finalizeBreastFits(
            sides: scan.bustSides,
            verticesBySide: scan.bustVertices,
            model: model,
            radiusPercentile: radiusPercentile
        )
    }

    static func computeShoulderColliders(
        model: VRMModel,
        radiusPercentile: Float = 0.95,
        radiusScale: Float = 1.0
    ) -> [VRMCollider] {
        guard let humanoid = model.humanoid else { return [] }
        let scan = scanAllRegions(
            model: model,
            humanoid: humanoid,
            includeBreasts: false,
            includeShoulders: true,
            includeTorso: false,
            includeHands: false
        )
        return buildShoulderColliders(
            from: scan.shoulderSides,
            verticesBySide: scan.shoulderVertices,
            model: model,
            radiusPercentile: radiusPercentile,
            radiusScale: radiusScale
        )
    }

    static func computeTorsoCollider(
        model: VRMModel,
        radiusPercentile: Float = 0.90,
        radiusScale: Float = 1.0
    ) -> [VRMCollider] {
        guard let humanoid = model.humanoid else { return [] }
        let scan = scanAllRegions(
            model: model,
            humanoid: humanoid,
            includeBreasts: false,
            includeShoulders: false,
            includeTorso: true,
            includeHands: false
        )
        return buildTorsoCollider(
            spineNode: scan.torsoSpineNode,
            superiorNode: scan.torsoSuperiorNode,
            dists: scan.torsoDists,
            model: model,
            radiusPercentile: radiusPercentile,
            radiusScale: radiusScale
        )
    }

    /// Computes adaptive 2/3-capsule hand paddle colliders for left and right hands,
    /// scanning all skinned meshes for vertices weighted to the hand and finger bones
    /// and falling back to bone-derived dimensions when unskinned.
    static func computeHandColliders(model: VRMModel) -> [VRMCollider] {
        guard let humanoid = model.humanoid else { return [] }
        let scan = scanAllRegions(
            model: model,
            humanoid: humanoid,
            includeBreasts: false,
            includeShoulders: false,
            includeTorso: false,
            includeHands: true
        )
        return buildHandColliders(
            leftVerts: scan.leftHandVertices,
            rightVerts: scan.rightHandVertices,
            humanoid: humanoid,
            model: model
        )
    }

    // MARK: - Single-Pass Mesh Scanner

    private struct BustSideSpec {
        let anchor: Int
        let bustNodes: Set<Int>
    }

    private struct ShoulderSideSpec {
        let upperNode: Int
        let upperOrigin: SIMD3<Float>
        let armLen: Float
        let lateralDir: SIMD3<Float>?
        let regionNodes: Set<Int>
    }

    private struct ScanResult {
        var bustSides: [BustSideSpec] = []
        var bustVertices: [[SIMD3<Float>]] = []
        var shoulderSides: [ShoulderSideSpec] = []
        var shoulderVertices: [[SIMD3<Float>]] = []
        var torsoSpineNode: Int?
        var torsoSuperiorNode: Int?
        var torsoDists: [Float] = []
        var leftHandVertices: [SIMD3<Float>] = []
        var rightHandVertices: [SIMD3<Float>] = []
    }

    private static func scanAllRegions(
        model: VRMModel,
        humanoid: VRMHumanoid?,
        includeBreasts: Bool,
        includeShoulders: Bool,
        includeTorso: Bool,
        includeHands: Bool
    ) -> ScanResult {
        var result = ScanResult()

        if includeBreasts, let springBone = model.springBone {
            for spring in springBone.springs where (spring.name ?? "").lowercased().contains("bust") {
                let nodeIndices = spring.joints.map(\.node)
                guard let anchor = nodeIndices.first else { continue }
                result.bustSides.append(BustSideSpec(anchor: anchor, bustNodes: Set(nodeIndices)))
            }
            result.bustVertices = Array(repeating: [], count: result.bustSides.count)
        }

        if includeShoulders, let humanoid {
            let sides: [(VRMHumanoidBone, VRMHumanoidBone, VRMHumanoidBone)] = [
                (.leftShoulder, .leftUpperArm, .leftLowerArm),
                (.rightShoulder, .rightUpperArm, .rightLowerArm),
            ]
            for (shoulderBone, upperBone, lowerBone) in sides {
                guard let upperNode = humanoid.getBoneNode(upperBone),
                      upperNode >= 0, upperNode < model.nodes.count else { continue }
                let upperOrigin = model.nodes[upperNode].worldPosition
                var armLen: Float = 0.2
                if let lowerNode = humanoid.getBoneNode(lowerBone),
                   lowerNode >= 0, lowerNode < model.nodes.count {
                    let l = simd_length(model.nodes[lowerNode].worldPosition - upperOrigin)
                    if l > 1e-3 { armLen = l }
                }
                var lateralDir: SIMD3<Float>?
                if let shoulderNode = humanoid.getBoneNode(shoulderBone),
                   shoulderNode >= 0, shoulderNode < model.nodes.count {
                    let d = upperOrigin - model.nodes[shoulderNode].worldPosition
                    if simd_length(d) > 1e-4 { lateralDir = simd_normalize(d) }
                }
                let regionNodes = Set([shoulderBone, upperBone].compactMap { humanoid.getBoneNode($0) })
                result.shoulderSides.append(ShoulderSideSpec(
                    upperNode: upperNode,
                    upperOrigin: upperOrigin,
                    armLen: armLen,
                    lateralDir: lateralDir,
                    regionNodes: regionNodes
                ))
            }
            result.shoulderVertices = Array(repeating: [], count: result.shoulderSides.count)
        }

        var torsoNodes = Set<Int>()
        var torsoP0 = SIMD3<Float>.zero
        var torsoAxis = SIMD3<Float>.zero
        var torsoAxisLenSq: Float = 0
        if includeTorso, let humanoid,
           let spineNode = humanoid.getBoneNode(.spine),
           spineNode >= 0, spineNode < model.nodes.count,
           let superiorNode = humanoid.getBoneNode(.upperChest) ?? humanoid.getBoneNode(.chest),
           superiorNode >= 0, superiorNode < model.nodes.count {
            let p0 = model.nodes[spineNode].worldPosition
            let p1 = model.nodes[superiorNode].worldPosition
            let axis = p1 - p0
            let axisLenSq = simd_length_squared(axis)
            if axisLenSq > 1e-6 {
                result.torsoSpineNode = spineNode
                result.torsoSuperiorNode = superiorNode
                torsoP0 = p0
                torsoAxis = axis
                torsoAxisLenSq = axisLenSq
                torsoNodes = Set([VRMHumanoidBone.spine, .chest, .upperChest].compactMap { humanoid.getBoneNode($0) })
            }
        }

        var leftHandNodes = Set<Int>()
        var rightHandNodes = Set<Int>()
        if includeHands, let humanoid {
            let springJointNodes = allSpringJointNodes(model: model)
            if let lh = humanoid.getBoneNode(.leftHand), lh >= 0, lh < model.nodes.count {
                leftHandNodes = collectHandNodes(
                    handNode: lh,
                    fingerBones: leftFingerBones,
                    humanoid: humanoid,
                    model: model,
                    springJointNodes: springJointNodes
                )
            }
            if let rh = humanoid.getBoneNode(.rightHand), rh >= 0, rh < model.nodes.count {
                rightHandNodes = collectHandNodes(
                    handNode: rh,
                    fingerBones: rightFingerBones,
                    humanoid: humanoid,
                    model: model,
                    springJointNodes: springJointNodes
                )
            }
        }

        let wantBreasts = !result.bustSides.isEmpty
        let wantShoulders = !result.shoulderSides.isEmpty
        let wantTorso = !torsoNodes.isEmpty
        let wantHands = !leftHandNodes.isEmpty || !rightHandNodes.isEmpty
        guard wantBreasts || wantShoulders || wantTorso || wantHands else { return result }

        // Scan every unique (mesh, skin) pair in the model — never filter by mesh name.
        var seenPairs = Set<MeshSkinPair>()
        for node in model.nodes {
            guard let meshIndex = node.mesh, meshIndex >= 0, meshIndex < model.meshes.count,
                  let skinIndex = node.skin, skinIndex >= 0, skinIndex < model.skins.count else { continue }
            guard seenPairs.insert(MeshSkinPair(meshIndex: meshIndex, skinIndex: skinIndex)).inserted else { continue }

            let skin = model.skins[skinIndex]
            let jointCount = skin.joints.count
            guard jointCount > 0, skin.inverseBindMatrices.count == jointCount else { continue }

            // Build O(1) slot-lookup tables for this skin.
            var bustSlotToSide = [Int8](repeating: -1, count: jointCount)
            var shoulderSlotToSide = [Int8](repeating: -1, count: jointCount)
            var isTorsoSlot = [Bool](repeating: false, count: jointCount)
            var handSlotToSide = [Int8](repeating: -1, count: jointCount)

            var anyMatch = false
            for slot in 0..<jointCount {
                let jointNodeIndex = skin.joints[slot].index
                if wantBreasts {
                    for (sideIdx, side) in result.bustSides.enumerated() where side.bustNodes.contains(jointNodeIndex) {
                        bustSlotToSide[slot] = Int8(sideIdx)
                        anyMatch = true
                        break
                    }
                }
                if wantShoulders {
                    for (sideIdx, side) in result.shoulderSides.enumerated() where side.regionNodes.contains(jointNodeIndex) {
                        shoulderSlotToSide[slot] = Int8(sideIdx)
                        anyMatch = true
                        break
                    }
                }
                if wantTorso && torsoNodes.contains(jointNodeIndex) {
                    isTorsoSlot[slot] = true
                    anyMatch = true
                }
                if wantHands {
                    if leftHandNodes.contains(jointNodeIndex) {
                        handSlotToSide[slot] = 0
                        anyMatch = true
                    } else if rightHandNodes.contains(jointNodeIndex) {
                        handSlotToSide[slot] = 1
                        anyMatch = true
                    }
                }
            }
            guard anyMatch else { continue }

            let skinMatrices = (0..<jointCount).map { i in
                skin.joints[i].worldMatrix * skin.inverseBindMatrices[i]
            }

            let mesh = model.meshes[meshIndex]
            var seenAccessors = Set<AccessorTriple>()
            for primitive in mesh.primitives {
                guard primitive.vertexCount > 0, let posBuf = primitive.vertexBuffer else { continue }
                if let pa = primitive.positionAccessorIndex,
                   let ja = primitive.jointsAccessorIndex,
                   let wa = primitive.weightsAccessorIndex {
                    guard seenAccessors.insert(AccessorTriple(position: pa, joints: ja, weights: wa)).inserted else {
                        continue
                    }
                }

                let vCount = primitive.vertexCount
                if let attrBuf = primitive.attributeBuffer {
                    let posPtr = posBuf.contents().bindMemory(to: VRMPositionVertex.self, capacity: vCount)
                    let attrPtr = attrBuf.contents().bindMemory(to: VRMAttributeVertex.self, capacity: vCount)
                    for i in 0..<vCount {
                        let joints = attrPtr[i].joints
                        let weights = attrPtr[i].weights
                        classifyAndAccumulate(
                            position: posPtr[i].position,
                            joints: joints,
                            weights: weights,
                            jointCount: jointCount,
                            skinMatrices: skinMatrices,
                            bustSlotToSide: bustSlotToSide,
                            shoulderSlotToSide: shoulderSlotToSide,
                            isTorsoSlot: isTorsoSlot,
                            handSlotToSide: handSlotToSide,
                            wantBreasts: wantBreasts,
                            wantShoulders: wantShoulders,
                            wantTorso: wantTorso,
                            wantHands: wantHands,
                            torsoP0: torsoP0,
                            torsoAxis: torsoAxis,
                            torsoAxisLenSq: torsoAxisLenSq,
                            result: &result
                        )
                    }
                } else {
                    let vPtr = posBuf.contents().bindMemory(to: VRMVertex.self, capacity: vCount)
                    for i in 0..<vCount {
                        let v = vPtr[i]
                        classifyAndAccumulate(
                            position: v.position,
                            joints: v.joints,
                            weights: v.weights,
                            jointCount: jointCount,
                            skinMatrices: skinMatrices,
                            bustSlotToSide: bustSlotToSide,
                            shoulderSlotToSide: shoulderSlotToSide,
                            isTorsoSlot: isTorsoSlot,
                            handSlotToSide: handSlotToSide,
                            wantBreasts: wantBreasts,
                            wantShoulders: wantShoulders,
                            wantTorso: wantTorso,
                            wantHands: wantHands,
                            torsoP0: torsoP0,
                            torsoAxis: torsoAxis,
                            torsoAxisLenSq: torsoAxisLenSq,
                            result: &result
                        )
                    }
                }
            }
        }

        return result
    }

    @inline(__always)
    private static func classifyAndAccumulate(
        position: SIMD3<Float>,
        joints: SIMD4<UInt32>,
        weights: SIMD4<Float>,
        jointCount: Int,
        skinMatrices: [float4x4],
        bustSlotToSide: [Int8],
        shoulderSlotToSide: [Int8],
        isTorsoSlot: [Bool],
        handSlotToSide: [Int8],
        wantBreasts: Bool,
        wantShoulders: Bool,
        wantTorso: Bool,
        wantHands: Bool,
        torsoP0: SIMD3<Float>,
        torsoAxis: SIMD3<Float>,
        torsoAxisLenSq: Float,
        result: inout ScanResult
    ) {
        let j0 = Int(joints.x), j1 = Int(joints.y), j2 = Int(joints.z), j3 = Int(joints.w)
        let w0 = weights.x, w1 = weights.y, w2 = weights.z, w3 = weights.w

        // Dominant single joint (used by breast, shoulder, torso — preserves #377 semantics).
        var domSlot = -1
        var domW: Float = 0
        if w0 > domW { domW = w0; domSlot = j0 }
        if w1 > domW { domW = w1; domSlot = j1 }
        if w2 > domW { domW = w2; domSlot = j2 }
        if w3 > domW { domW = w3; domSlot = j3 }

        let domValid = domSlot >= 0 && domSlot < jointCount && domW > 0.5
        let bustSide: Int8 = (wantBreasts && domValid) ? bustSlotToSide[domSlot] : -1
        let shoulderSide: Int8 = (wantShoulders && domValid) ? shoulderSlotToSide[domSlot] : -1
        let torsoHit: Bool = (wantTorso && domValid) ? isTorsoSlot[domSlot] : false

        // Summed hand+finger weights capture blended palm/knuckle vertices cleanly.
        var leftHandW: Float = 0
        var rightHandW: Float = 0
        if wantHands {
            if j0 >= 0 && j0 < jointCount {
                let s = handSlotToSide[j0]
                if s == 0 { leftHandW += w0 } else if s == 1 { rightHandW += w0 }
            }
            if j1 >= 0 && j1 < jointCount {
                let s = handSlotToSide[j1]
                if s == 0 { leftHandW += w1 } else if s == 1 { rightHandW += w1 }
            }
            if j2 >= 0 && j2 < jointCount {
                let s = handSlotToSide[j2]
                if s == 0 { leftHandW += w2 } else if s == 1 { rightHandW += w2 }
            }
            if j3 >= 0 && j3 < jointCount {
                let s = handSlotToSide[j3]
                if s == 0 { leftHandW += w3 } else if s == 1 { rightHandW += w3 }
            }
        }
        let leftHandHit = leftHandW > 0.5
        let rightHandHit = rightHandW > 0.5

        // Fast skip: ~70% of vertices belong to legs/skirt/head/etc.
        guard bustSide >= 0 || shoulderSide >= 0 || torsoHit || leftHandHit || rightHandHit else {
            return
        }

        let wp = skinVertex(position, j0, j1, j2, j3, w0, w1, w2, w3, skinMatrices)
        guard wp.x.isFinite && wp.y.isFinite && wp.z.isFinite else { return }

        if bustSide >= 0 {
            result.bustVertices[Int(bustSide)].append(wp)
        }
        if shoulderSide >= 0 {
            let side = result.shoulderSides[Int(shoulderSide)]
            let rel = wp - side.upperOrigin
            if simd_length(rel) < side.armLen * 0.5 {
                if let dir = side.lateralDir {
                    if simd_dot(rel, dir) >= 0 {
                        result.shoulderVertices[Int(shoulderSide)].append(wp)
                    }
                } else {
                    result.shoulderVertices[Int(shoulderSide)].append(wp)
                }
            }
        }
        if torsoHit {
            let t = max(0, min(1, simd_dot(wp - torsoP0, torsoAxis) / torsoAxisLenSq))
            result.torsoDists.append(simd_length(wp - (torsoP0 + t * torsoAxis)))
        }
        if leftHandHit {
            result.leftHandVertices.append(wp)
        }
        if rightHandHit {
            result.rightHandVertices.append(wp)
        }
    }

    @inline(__always)
    private static func skinVertex(
        _ position: SIMD3<Float>,
        _ j0: Int, _ j1: Int, _ j2: Int, _ j3: Int,
        _ w0: Float, _ w1: Float, _ w2: Float, _ w3: Float,
        _ skinMatrices: [float4x4]
    ) -> SIMD3<Float> {
        let wsum = max(w0 + w1 + w2 + w3, 1e-6)
        let n = skinMatrices.count
        var m = float4x4(0)
        let nw0 = w0 / wsum
        if nw0 > 0 && j0 >= 0 && j0 < n { m += skinMatrices[j0] * nw0 }
        let nw1 = w1 / wsum
        if nw1 > 0 && j1 >= 0 && j1 < n { m += skinMatrices[j1] * nw1 }
        let nw2 = w2 / wsum
        if nw2 > 0 && j2 >= 0 && j2 < n { m += skinMatrices[j2] * nw2 }
        let nw3 = w3 / wsum
        if nw3 > 0 && j3 >= 0 && j3 < n { m += skinMatrices[j3] * nw3 }
        let p = m * SIMD4<Float>(position, 1)
        return SIMD3<Float>(p.x, p.y, p.z)
    }

    // MARK: - Hand Node Collection

    private static func allSpringJointNodes(model: VRMModel) -> Set<Int> {
        guard let springs = model.springBone?.springs else { return [] }
        var nodes = Set<Int>()
        for spring in springs {
            for joint in spring.joints {
                nodes.insert(joint.node)
            }
        }
        return nodes
    }

    private static func collectHandNodes(
        handNode: Int,
        fingerBones: [VRMHumanoidBone],
        humanoid: VRMHumanoid,
        model: VRMModel,
        springJointNodes: Set<Int>
    ) -> Set<Int> {
        var result = Set<Int>([handNode])
        for bone in fingerBones {
            if let idx = humanoid.getBoneNode(bone), idx >= 0, idx < model.nodes.count {
                result.insert(idx)
            }
        }
        // Also walk non-springbone descendants (e.g. non-humanoid finger bones),
        // stopping before any SpringBone chain (like VRoid `TipSleeve`) or prop node.
        var stack = [handNode]
        var visited = Set<Int>([handNode])
        while let current = stack.popLast() {
            guard current >= 0, current < model.nodes.count else { continue }
            for child in model.nodes[current].children {
                let childIdx = child.index
                guard visited.insert(childIdx).inserted else { continue }
                if springJointNodes.contains(childIdx) { continue }
                let lowerName = (child.name ?? "").lowercased()
                if handExcludedSubstrings.contains(where: { lowerName.contains($0) }) { continue }
                result.insert(childIdx)
                stack.append(childIdx)
            }
        }
        return result
    }

    // MARK: - Region Builders (Breast / Shoulder / Torso)

    private static func finalizeBreastFits(
        sides: [BustSideSpec],
        verticesBySide: [[SIMD3<Float>]],
        model: VRMModel,
        radiusPercentile: Float
    ) -> [BreastFit] {
        var out: [BreastFit] = []
        for (s, side) in sides.enumerated() {
            let verts = verticesBySide[s]
            guard verts.count >= 8, side.anchor >= 0, side.anchor < model.nodes.count else { continue }
            var sum = SIMD3<Double>.zero
            for v in verts { sum += SIMD3<Double>(Double(v.x), Double(v.y), Double(v.z)) }
            let mean = sum / Double(verts.count)
            let centroid = SIMD3<Float>(Float(mean.x), Float(mean.y), Float(mean.z))
            let dists = verts.map { simd_length($0 - centroid) }.sorted()
            let pIdx = min(dists.count - 1, max(0, Int((Float(dists.count - 1) * radiusPercentile).rounded())))
            let radius = dists[pIdx]
            guard radius.isFinite, radius > 1e-4 else { continue }
            out.append(BreastFit(anchor: side.anchor, centroidWorld: centroid, radius: radius))
        }
        return out
    }

    private static func buildBreastColliders(
        from sides: [BustSideSpec],
        verticesBySide: [[SIMD3<Float>]],
        humanoid: VRMHumanoid,
        model: VRMModel,
        radiusPercentile: Float,
        radiusScale: Float
    ) -> [VRMCollider] {
        let superiorBone = humanoid.getBoneNode(.upperChest)
            ?? humanoid.getBoneNode(.chest) ?? humanoid.getBoneNode(.spine)
        guard let superiorNode = superiorBone, superiorNode >= 0, superiorNode < model.nodes.count else { return [] }
        let superiorWorld = model.nodes[superiorNode].worldPosition

        var out: [VRMCollider] = []
        for fit in finalizeBreastFits(sides: sides, verticesBySide: verticesBySide, model: model, radiusPercentile: radiusPercentile) {
            let invAnchor = simd_inverse(model.nodes[fit.anchor].worldMatrix)
            let p0 = fit.centroidWorld
            let p1 = SIMD3<Float>(fit.centroidWorld.x, superiorWorld.y, fit.centroidWorld.z)
            let o0 = invAnchor * SIMD4<Float>(p0, 1)
            let o1 = invAnchor * SIMD4<Float>(p1, 1)
            let offset = SIMD3<Float>(o0.x, o0.y, o0.z)
            let tail = SIMD3<Float>(o1.x, o1.y, o1.z)
            let radius = fit.radius * radiusScale
            guard offset.x.isFinite, tail.x.isFinite, radius.isFinite, radius > 1e-4 else { continue }
            out.append(VRMCollider(node: fit.anchor, shape: .capsule(offset: offset, radius: radius, tail: tail)))
        }
        return out
    }

    private static func buildShoulderColliders(
        from sides: [ShoulderSideSpec],
        verticesBySide: [[SIMD3<Float>]],
        model: VRMModel,
        radiusPercentile: Float,
        radiusScale: Float
    ) -> [VRMCollider] {
        var out: [VRMCollider] = []
        for (s, side) in sides.enumerated() {
            let verts = verticesBySide[s]
            guard verts.count >= 8 else { continue }
            var sum = SIMD3<Double>.zero
            for v in verts { sum += SIMD3<Double>(Double(v.x), Double(v.y), Double(v.z)) }
            let mean = sum / Double(verts.count)
            let centroid = SIMD3<Float>(Float(mean.x), Float(mean.y), Float(mean.z))
            let dists = verts.map { simd_length($0 - centroid) }.sorted()
            let pIdx = min(dists.count - 1, max(0, Int((Float(dists.count - 1) * radiusPercentile).rounded())))
            let radius = dists[pIdx] * radiusScale
            guard radius.isFinite, radius > 1e-4 else { continue }
            let localC = simd_inverse(model.nodes[side.upperNode].worldMatrix) * SIMD4<Float>(centroid, 1)
            guard localC.x.isFinite, localC.y.isFinite, localC.z.isFinite else { continue }
            out.append(VRMCollider(
                node: side.upperNode,
                shape: .sphere(offset: SIMD3<Float>(localC.x, localC.y, localC.z), radius: radius)
            ))
        }
        return out
    }

    private static func buildTorsoCollider(
        spineNode: Int?,
        superiorNode: Int?,
        dists: [Float],
        model: VRMModel,
        radiusPercentile: Float,
        radiusScale: Float
    ) -> [VRMCollider] {
        guard let spineNode, let superiorNode, dists.count >= 16 else { return [] }
        let sorted = dists.sorted()
        let pIdx = min(sorted.count - 1, max(0, Int((Float(sorted.count - 1) * radiusPercentile).rounded())))
        let radius = sorted[pIdx] * radiusScale
        guard radius.isFinite, radius > 1e-4 else { return [] }
        let p0 = model.nodes[spineNode].worldPosition
        let p1 = model.nodes[superiorNode].worldPosition
        let inv = simd_inverse(model.nodes[spineNode].worldMatrix)
        let o0 = inv * SIMD4<Float>(p0, 1)
        let o1 = inv * SIMD4<Float>(p1, 1)
        let offset = SIMD3<Float>(o0.x, o0.y, o0.z)
        let tail = SIMD3<Float>(o1.x, o1.y, o1.z)
        guard offset.x.isFinite, tail.x.isFinite else { return [] }
        return [VRMCollider(node: spineNode, shape: .capsule(offset: offset, radius: radius, tail: tail))]
    }

    // MARK: - Adaptive 2/3-Capsule Hand Paddle Fitter (#478)

    private struct HandPaddleSpec {
        let uReach: SIMD3<Float>
        let uBreadth: SIMD3<Float>
        let uThickness: SIMD3<Float>
        let reachMin: Float
        let reachMax: Float
        let breadth: Float
        let breadthCenter: Float
        let thickness: Float
        let thicknessCenter: Float
    }

    private static func buildHandColliders(
        leftVerts: [SIMD3<Float>],
        rightVerts: [SIMD3<Float>],
        humanoid: VRMHumanoid,
        model: VRMModel
    ) -> [VRMCollider] {
        var out: [VRMCollider] = []
        out.append(contentsOf: fitHandPaddle(
            handBone: .leftHand,
            lowerArmBone: .leftLowerArm,
            fingerBones: leftFingerBones,
            middleBones: [.leftMiddleDistal, .leftMiddleIntermediate, .leftMiddleProximal],
            indexProximal: .leftIndexProximal,
            littleProximal: .leftLittleProximal,
            verticesWorld: leftVerts,
            humanoid: humanoid,
            model: model
        ))
        out.append(contentsOf: fitHandPaddle(
            handBone: .rightHand,
            lowerArmBone: .rightLowerArm,
            fingerBones: rightFingerBones,
            middleBones: [.rightMiddleDistal, .rightMiddleIntermediate, .rightMiddleProximal],
            indexProximal: .rightIndexProximal,
            littleProximal: .rightLittleProximal,
            verticesWorld: rightVerts,
            humanoid: humanoid,
            model: model
        ))
        return out
    }

    private static func fitHandPaddle(
        handBone: VRMHumanoidBone,
        lowerArmBone: VRMHumanoidBone,
        fingerBones: [VRMHumanoidBone],
        middleBones: [VRMHumanoidBone],
        indexProximal: VRMHumanoidBone,
        littleProximal: VRMHumanoidBone,
        verticesWorld: [SIMD3<Float>],
        humanoid: VRMHumanoid,
        model: VRMModel
    ) -> [VRMCollider] {
        guard let handNode = humanoid.getBoneNode(handBone),
              handNode >= 0, handNode < model.nodes.count else { return [] }

        let handMatrix = model.nodes[handNode].worldMatrix
        let handRot = SpringBoneBoneGeometry.upperLeft3x3(handMatrix)
        guard abs(simd_determinant(handRot)) > 1e-6 else { return [] }
        let invHandRot = simd_inverse(handRot)
        let handPos = model.nodes[handNode].worldPosition

        var forearmDir: SIMD3<Float>?
        var forearmLen: Float = 0
        if let lowerArmNode = humanoid.getBoneNode(lowerArmBone),
           lowerArmNode >= 0, lowerArmNode < model.nodes.count {
            let seg = handPos - model.nodes[lowerArmNode].worldPosition
            let len = simd_length(seg)
            if len > 1e-4 {
                forearmLen = len
                forearmDir = seg / len
            }
        }

        let spec = measureHandFromMesh(
            handPos: handPos,
            forearmDir: forearmDir,
            forearmLen: forearmLen,
            middleBones: middleBones,
            verticesWorld: verticesWorld,
            humanoid: humanoid,
            model: model
        ) ?? measureHandFromBones(
            handPos: handPos,
            forearmDir: forearmDir,
            forearmLen: forearmLen,
            fingerBones: fingerBones,
            middleBones: middleBones,
            indexProximal: indexProximal,
            littleProximal: littleProximal,
            humanoid: humanoid,
            model: model
        )
        guard let spec else { return [] }

        let aspect = spec.breadth / max(spec.thickness, 1e-4)
        let useThreeCapsules = aspect > 3.8
        let radius: Float
        if useThreeCapsules {
            radius = max(0.55 * spec.thickness, 0.18 * spec.breadth)
        } else {
            radius = max(0.55 * spec.thickness, 0.27 * spec.breadth)
        }
        guard radius.isFinite, radius > 1e-4 else { return [] }

        let halfSpan = max(0.0, spec.breadth * 0.5 - radius)
        let lateralOffsets: [Float]
        if halfSpan < 1e-4 {
            lateralOffsets = [0.0]
        } else if useThreeCapsules {
            lateralOffsets = [-halfSpan, 0.0, halfSpan]
        } else {
            lateralOffsets = [-halfSpan, halfSpan]
        }

        // Inset endpoints by `radius` so the hemispherical capsule endcaps kiss
        // [reachMin, reachMax] instead of protruding past the fingertips by +radius.
        let reachMid = 0.5 * (spec.reachMin + spec.reachMax)
        let p0Reach = min(spec.reachMin + radius, reachMid)
        let p1Reach = max(spec.reachMax - radius, reachMid)

        var capsules: [VRMCollider] = []
        capsules.reserveCapacity(lateralOffsets.count)
        for lat in lateralOffsets {
            let crossOffset = spec.uBreadth * (spec.breadthCenter + lat)
                + spec.uThickness * spec.thicknessCenter
            let p0WorldRel = crossOffset + spec.uReach * p0Reach
            let p1WorldRel = crossOffset + spec.uReach * p1Reach
            let offsetLocal = invHandRot * p0WorldRel
            let tailLocal = invHandRot * p1WorldRel
            guard offsetLocal.x.isFinite && offsetLocal.y.isFinite && offsetLocal.z.isFinite,
                  tailLocal.x.isFinite && tailLocal.y.isFinite && tailLocal.z.isFinite else {
                continue
            }
            capsules.append(VRMCollider(
                node: handNode,
                shape: .capsule(offset: offsetLocal, radius: radius, tail: tailLocal)
            ))
        }
        return capsules
    }

    private static func measureHandFromMesh(
        handPos: SIMD3<Float>,
        forearmDir: SIMD3<Float>?,
        forearmLen: Float,
        middleBones: [VRMHumanoidBone],
        verticesWorld: [SIMD3<Float>],
        humanoid: VRMHumanoid,
        model: VRMModel
    ) -> HandPaddleSpec? {
        guard verticesWorld.count >= 8 else { return nil }

        // Reach axis: prefer forearm direction (stable even when fingers curl in
        // rest pose, e.g. AvatarSample_K), falling back to middle finger or centroid.
        var uReach: SIMD3<Float>?
        if let forearmDir {
            uReach = forearmDir
        } else {
            for bone in middleBones {
                if let idx = humanoid.getBoneNode(bone), idx >= 0, idx < model.nodes.count {
                    let d = model.nodes[idx].worldPosition - handPos
                    if simd_length(d) > 1e-4 {
                        uReach = simd_normalize(d)
                        break
                    }
                }
            }
        }
        if uReach == nil {
            let centroid = verticesWorld.reduce(SIMD3<Float>(repeating: 0), +) / Float(verticesWorld.count)
            let d = centroid - handPos
            guard simd_length(d) > 1e-4 else { return nil }
            uReach = simd_normalize(d)
        }
        var reachAxis = uReach!

        var rels = [SIMD3<Float>]()
        rels.reserveCapacity(verticesWorld.count)
        for wp in verticesWorld {
            rels.append(wp - handPos)
        }

        // Flip reach axis if vertices predominantly lie in the negative half-space.
        var reachVals = rels.map { simd_dot($0, reachAxis) }
        reachVals.sort()
        if percentile(reachVals, 0.5) < 0 {
            reachAxis = -reachAxis
            reachVals = rels.map { simd_dot($0, reachAxis) }.sorted()
        }

        // Build an orthonormal basis (e1, e2) perpendicular to reachAxis and run
        // closed-form 2D PCA to locate the palm's breadth and thickness axes.
        let ref: SIMD3<Float> = abs(reachAxis.y) < 0.9 ? SIMD3<Float>(0, 1, 0) : SIMD3<Float>(0, 0, 1)
        let e1 = simd_normalize(simd_cross(ref, reachAxis))
        let e2 = simd_cross(reachAxis, e1)

        var mean1: Float = 0
        var mean2: Float = 0
        for r in rels {
            mean1 += simd_dot(r, e1)
            mean2 += simd_dot(r, e2)
        }
        let invN = 1.0 / Float(rels.count)
        mean1 *= invN
        mean2 *= invN

        var cxx: Float = 0
        var cyy: Float = 0
        var cxy: Float = 0
        for r in rels {
            let d1 = simd_dot(r, e1) - mean1
            let d2 = simd_dot(r, e2) - mean2
            cxx += d1 * d1
            cyy += d2 * d2
            cxy += d1 * d2
        }
        let theta = 0.5 * atan2(2.0 * cxy, cxx - cyy)
        let cosT = cos(theta)
        let sinT = sin(theta)
        var uBreadth = simd_normalize(cosT * e1 + sinT * e2)
        var uThickness = simd_normalize(-sinT * e1 + cosT * e2)

        let bVals = rels.map { simd_dot($0, uBreadth) }.sorted()
        let tVals = rels.map { simd_dot($0, uThickness) }.sorted()
        var bLo = percentile(bVals, 0.02)
        var bHi = percentile(bVals, 0.98)
        var tLo = percentile(tVals, 0.02)
        var tHi = percentile(tVals, 0.98)
        if (bHi - bLo) < (tHi - tLo) {
            swap(&uBreadth, &uThickness)
            swap(&bLo, &tLo)
            swap(&bHi, &tHi)
        }

        let reachMin = max(0.0, percentile(reachVals, 0.02))
        let reachMax = percentile(reachVals, 0.99)
        let reach = reachMax - reachMin
        let breadth = bHi - bLo
        let thickness = tHi - tLo

        guard reach > 0.01, breadth > 0.01, thickness > 0.003 else { return nil }

        // Guard against malformed assets that skin large props/weapons directly to the hand bone.
        if forearmLen > 0.02 {
            if reach > forearmLen * 1.8 || breadth > forearmLen * 1.5 || thickness > forearmLen * 1.2 {
                return nil
            }
        }

        return HandPaddleSpec(
            uReach: reachAxis,
            uBreadth: uBreadth,
            uThickness: uThickness,
            reachMin: reachMin,
            reachMax: reachMax,
            breadth: breadth,
            breadthCenter: 0.5 * (bLo + bHi),
            thickness: thickness,
            thicknessCenter: 0.5 * (tLo + tHi)
        )
    }

    private static func measureHandFromBones(
        handPos: SIMD3<Float>,
        forearmDir: SIMD3<Float>?,
        forearmLen: Float,
        fingerBones: [VRMHumanoidBone],
        middleBones: [VRMHumanoidBone],
        indexProximal: VRMHumanoidBone,
        littleProximal: VRMHumanoidBone,
        humanoid: VRMHumanoid,
        model: VRMModel
    ) -> HandPaddleSpec? {
        var fingerPositions: [SIMD3<Float>] = []
        for bone in fingerBones {
            if let idx = humanoid.getBoneNode(bone), idx >= 0, idx < model.nodes.count {
                fingerPositions.append(model.nodes[idx].worldPosition - handPos)
            }
        }

        var uReach: SIMD3<Float>?
        for bone in middleBones {
            if let idx = humanoid.getBoneNode(bone), idx >= 0, idx < model.nodes.count {
                let d = model.nodes[idx].worldPosition - handPos
                if simd_length(d) > 1e-4 {
                    uReach = simd_normalize(d)
                    break
                }
            }
        }
        if uReach == nil { uReach = forearmDir }
        guard let reachAxis = uReach else { return nil }

        if fingerPositions.count >= 2 {
            var maxReach: Float = 0
            for p in fingerPositions {
                maxReach = max(maxReach, simd_dot(p, reachAxis))
            }
            guard maxReach > 0.01 else { return nil }
            let reachMax = maxReach * 1.18

            var breadthAxis: SIMD3<Float>?
            if let iIdx = humanoid.getBoneNode(indexProximal), iIdx >= 0, iIdx < model.nodes.count,
               let lIdx = humanoid.getBoneNode(littleProximal), lIdx >= 0, lIdx < model.nodes.count {
                let span = model.nodes[lIdx].worldPosition - model.nodes[iIdx].worldPosition
                let ortho = span - simd_dot(span, reachAxis) * reachAxis
                if simd_length(ortho) > 1e-4 {
                    breadthAxis = simd_normalize(ortho)
                }
            }
            let uBreadth: SIMD3<Float>
            if let breadthAxis {
                uBreadth = breadthAxis
            } else {
                let ref: SIMD3<Float> = abs(reachAxis.z) < 0.9 ? SIMD3<Float>(0, 0, 1) : SIMD3<Float>(0, 1, 0)
                uBreadth = simd_normalize(simd_cross(ref, reachAxis))
            }
            let uThickness = simd_normalize(simd_cross(reachAxis, uBreadth))

            var minB = Float.greatestFiniteMagnitude
            var maxB = -Float.greatestFiniteMagnitude
            for p in fingerPositions {
                let b = simd_dot(p, uBreadth)
                minB = min(minB, b)
                maxB = max(maxB, b)
            }
            let boneSpan = max(0, maxB - minB)
            let breadth = max(boneSpan * 1.35, 0.48 * reachMax)
            let thickness = 0.25 * breadth

            return HandPaddleSpec(
                uReach: reachAxis,
                uBreadth: uBreadth,
                uThickness: uThickness,
                reachMin: 0.0,
                reachMax: reachMax,
                breadth: breadth,
                breadthCenter: 0.5 * (minB + maxB),
                thickness: thickness,
                thicknessCenter: 0.0
            )
        }

        // Last-resort bone-only fallback when neither mesh nor finger bones exist.
        guard forearmLen > 0.02 else { return nil }
        let ref: SIMD3<Float> = abs(reachAxis.y) < 0.9 ? SIMD3<Float>(0, 1, 0) : SIMD3<Float>(0, 0, 1)
        let uBreadth = simd_normalize(simd_cross(ref, reachAxis))
        let uThickness = simd_normalize(simd_cross(reachAxis, uBreadth))
        return HandPaddleSpec(
            uReach: reachAxis,
            uBreadth: uBreadth,
            uThickness: uThickness,
            reachMin: 0.0,
            reachMax: 0.60 * forearmLen,
            breadth: 0.36 * forearmLen,
            breadthCenter: 0.0,
            thickness: 0.10 * forearmLen,
            thicknessCenter: 0.0
        )
    }

    @inline(__always)
    private static func percentile(_ sorted: [Float], _ p: Float) -> Float {
        guard !sorted.isEmpty else { return 0 }
        let idx = min(sorted.count - 1, max(0, Int(Float(sorted.count - 1) * p)))
        return sorted[idx]
    }
}
