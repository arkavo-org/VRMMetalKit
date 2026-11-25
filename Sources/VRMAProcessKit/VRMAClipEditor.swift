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

/// Errors thrown by ``VRMAClipEditor`` write passes.
public enum EditError: Error, CustomStringConvertible {
    case unalignedKeyframes
    case invalidParameter(String)

    public var description: String {
        switch self {
        case .unalignedKeyframes:
            return "animation channels carry genuinely different keyframe timelines — resample to a shared timeline before trimming"
        case .invalidParameter(let detail):
            return "invalid edit parameter: \(detail)"
        }
    }
}

/// Write-side glb surgery for VRMA ingest and hygiene passes. All edits are
/// minimal: unchanged accessors stay untouched and rewritten tracks are
/// appended as new bufferViews/accessors (or edited in-place for `stripHipsXZ`).
public struct VRMAClipEditor {
    public var container: GLBContainer

    public init(container: GLBContainer) { self.container = container }

    /// Rebase the hips translation track's X and Z to their first-frame
    /// values (in-place float writes in the bin chunk; same byte length).
    /// Y (bob) and all rotation tracks are untouched.
    public mutating func stripHipsXZ() throws {
        let inspector = try VRMAClipInspector(container: container)
        let (_, outputAcc) = try inspector.hipsTranslationSampler()
        guard let accessors = container.json["accessors"] as? [[String: Any]],
              outputAcc >= 0, outputAcc < accessors.count,
              let count = accessors[outputAcc]["count"] as? Int,
              let bvIndex = accessors[outputAcc]["bufferView"] as? Int,
              let bvs = container.json["bufferViews"] as? [[String: Any]],
              bvIndex >= 0, bvIndex < bvs.count
        else { throw VRMAClipInspector.InspectError.badAccessor }
        let base = (bvs[bvIndex]["byteOffset"] as? Int ?? 0) + (accessors[outputAcc]["byteOffset"] as? Int ?? 0)
        // count >= 1: the first-frame reads at base/base+8 must be in range.
        // float32 VEC3 required — the write path enforces the same accessor
        // shape the read path (floats(accessor:)) does, so a malformed hips
        // accessor throws instead of being silently stomped.
        // base % 4 == 0: storeBytes(of:toByteOffset:as:) requires Float
        // alignment (glTF guarantees it for float accessors).
        // Overflow-safe: base + count * 12 must not trap on hostile counts.
        let (stride12, s12Overflow) = count.multipliedReportingOverflow(by: 12)
        guard !s12Overflow else { throw VRMAClipInspector.InspectError.badAccessor }
        let (endOff, endOverflow) = base.addingReportingOverflow(stride12)
        guard base >= 0, count >= 1,
              accessors[outputAcc]["componentType"] as? Int == 5126,
              accessors[outputAcc]["type"] as? String == "VEC3",
              base % 4 == 0,
              !endOverflow, endOff <= container.bin.count
        else { throw VRMAClipInspector.InspectError.badAccessor }
        var bin = container.bin
        let x0 = bin.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: base, as: Float.self) }
        let z0 = bin.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: base + 8, as: Float.self) }
        bin.withUnsafeMutableBytes { raw in
            for i in 0..<count {
                raw.storeBytes(of: x0, toByteOffset: base + i * 12, as: Float.self)
                raw.storeBytes(of: z0, toByteOffset: base + i * 12 + 8, as: Float.self)
            }
        }
        container.bin = bin
    }

    /// Drops animation channels whose target node is not a VRMC_vrm_animation
    /// semantic node (preserves `humanBones`, `expressions.preset`,
    /// `expressions.custom`, and `lookAt.node`; drops baked hair/bust/accessory
    /// tracks). Orphaned samplers/accessors are left in place — valid glTF,
    /// zero risk to untouched data. Returns the number of channels dropped.
    @discardableResult
    public mutating func stripNonHumanoidChannels() throws -> Int {
        let inspector = try VRMAClipInspector(container: container)
        guard var anims = container.json["animations"] as? [[String: Any]], !anims.isEmpty,
              let channels = anims[0]["channels"] as? [[String: Any]]
        else { throw VRMAClipInspector.InspectError.noAnimation }
        let keptNodes = inspector.semanticNodes
        let kept = channels.filter { ch in
            guard let target = ch["target"] as? [String: Any], let node = target["node"] as? Int
            else { return false }
            return keptNodes.contains(node)
        }
        let dropped = channels.count - kept.count
        anims[0]["channels"] = kept
        container.json["animations"] = anims
        return dropped
    }

    /// Drops baked `leftEye` / `rightEye` channels (including unmapped VRoid
    /// `J_Adj_*_FaceEye` tracks) that would otherwise stomp `VRMLookAtController`.
    ///
    /// - Parameter onlyIfConstant: When `true` (default), drops an eye channel only
    ///   when all keyframes are constant (e.g. constant-identity tracks emitted by
    ///   `bvh2vrma-converter`). When `false`, drops all eye channels unconditionally.
    /// - Returns: The number of eye channels dropped.
    @discardableResult
    public mutating func stripEyeChannels(onlyIfConstant: Bool = true) throws -> Int {
        let inspector = try VRMAClipInspector(container: container)
        guard var anims = container.json["animations"] as? [[String: Any]], !anims.isEmpty,
              let channels = anims[0]["channels"] as? [[String: Any]],
              let samplers = anims[0]["samplers"] as? [[String: Any]]
        else { throw VRMAClipInspector.InspectError.noAnimation }

        let eyes = inspector.eyeNodes
        guard !eyes.isEmpty else { return 0 }

        var kept: [[String: Any]] = []
        kept.reserveCapacity(channels.count)
        var dropped = 0

        for ch in channels {
            guard let target = ch["target"] as? [String: Any],
                  let node = target["node"] as? Int,
                  eyes.contains(node) else {
                kept.append(ch)
                continue
            }
            let shouldDrop = !onlyIfConstant ? true : try inspector.isChannelConstant(ch, samplers: samplers)
            if shouldDrop {
                dropped += 1
            } else {
                kept.append(ch)
            }
        }

        if dropped > 0 {
            anims[0]["channels"] = kept
            container.json["animations"] = anims
        }
        return dropped
    }

    /// Bakes non-identity humanoid (and ancestor) rest rotations into canonical
    /// VRM 1.0 identity rest pose via `W_A · L_A⁻¹ · Q(t) · W_A⁻¹`, updating child
    /// node rest translations into the new parent frame and enforcing consecutive
    /// quaternion hemisphere continuity.
    ///
    /// Produces `< 0.00001°` equivalence against `VRMAnimationLoader`'s runtime
    /// pose normalization while making the asset portable across viewers that assume
    /// canonical identity rest rotations.
    ///
    /// - Returns: The number of humanoid/ancestor nodes whose non-identity rest
    ///   rotation was baked into identity (0 if already normalized).
    @discardableResult
    public mutating func normalizeRestPose() throws -> Int {
        let inspector = try VRMAClipInspector(container: container)
        let rest = try inspector.restTransforms()
        let normalizedNodes = inspector.humanoidAndAncestorNodes(parentMap: rest.parent)

        var nonIdentityCount = 0
        for idx in normalizedNodes where idx >= 0 && idx < rest.local.count {
            if 1.0 - abs(rest.local[idx].rotation.real) > VRMAClipInspector.identityRotationEpsilon {
                nonIdentityCount += 1
            }
        }
        guard nonIdentityCount > 0 else { return 0 }

        guard var nodes = container.json["nodes"] as? [[String: Any]],
              var accessors = container.json["accessors"] as? [[String: Any]],
              var bufferViews = container.json["bufferViews"] as? [[String: Any]]
        else { throw VRMAClipInspector.InspectError.badAccessor }

        var bin = container.bin

        // 1. Rewrite animation channels for affected nodes.
        if var anims = container.json["animations"] as? [[String: Any]], !anims.isEmpty,
           var channels = anims[0]["channels"] as? [[String: Any]],
           var samplers = anims[0]["samplers"] as? [[String: Any]] {
            var samplerUseCounts: [Int: Int] = [:]
            for ch in channels {
                if let si = ch["sampler"] as? Int {
                    samplerUseCounts[si, default: 0] += 1
                }
            }

            for ci in 0..<channels.count {
                guard let target = channels[ci]["target"] as? [String: Any],
                      let node = target["node"] as? Int,
                      let path = target["path"] as? String,
                      let si = channels[ci]["sampler"] as? Int,
                      si >= 0, si < samplers.count,
                      let outputAcc = samplers[si]["output"] as? Int,
                      outputAcc >= 0, outputAcc < accessors.count,
                      let accCount = accessors[outputAcc]["count"] as? Int
                else { continue }

                let interp = (samplers[si]["interpolation"] as? String ?? "LINEAR").uppercased()
                let isCubic = interp == "CUBICSPLINE"

                if path == "rotation", normalizedNodes.contains(node), node >= 0, node < rest.local.count {
                    let localRot = rest.local[node].rotation
                    let worldRot = rest.worldRotation[node]
                    let localIsId = (1.0 - abs(localRot.real)) <= VRMAClipInspector.identityRotationEpsilon
                    let worldIsId = (1.0 - abs(worldRot.real)) <= VRMAClipInspector.identityRotationEpsilon
                    if localIsId && worldIsId { continue }

                    let vals = try inspector.floats(accessor: outputAcc)
                    let u = simd_normalize(worldRot * simd_inverse(localRot))
                    let v = simd_inverse(worldRot)

                    var outFloats: [Float] = []
                    outFloats.reserveCapacity(vals.count)

                    if isCubic {
                        guard vals.count == accCount * 4, accCount % 3 == 0 else {
                            throw VRMAClipInspector.InspectError.badAccessor
                        }
                        let keyCount = accCount / 3
                        var prevVal: simd_quatd?
                        for k in 0..<keyCount {
                            let base = k * 12
                            let inT = u * simd_quatd(ix: Double(vals[base]), iy: Double(vals[base + 1]), iz: Double(vals[base + 2]), r: Double(vals[base + 3])) * v
                            let rawVal = simd_normalize(simd_quatd(ix: Double(vals[base + 4]), iy: Double(vals[base + 5]), iz: Double(vals[base + 6]), r: Double(vals[base + 7])))
                            var val = simd_normalize(u * rawVal * v)
                            let outT = u * simd_quatd(ix: Double(vals[base + 8]), iy: Double(vals[base + 9]), iz: Double(vals[base + 10]), r: Double(vals[base + 11])) * v

                            var finalInT = inT
                            var finalOutT = outT
                            if let prev = prevVal, simd_dot(val.vector, prev.vector) < 0 {
                                val = -val
                                finalInT = -finalInT
                                finalOutT = -finalOutT
                            }
                            prevVal = val
                            Self.appendQuat(finalInT, to: &outFloats)
                            Self.appendQuat(val, to: &outFloats)
                            Self.appendQuat(finalOutT, to: &outFloats)
                        }
                    } else {
                        guard vals.count == accCount * 4 else {
                            throw VRMAClipInspector.InspectError.badAccessor
                        }
                        var prev: simd_quatd?
                        for k in 0..<accCount {
                            let base = k * 4
                            let raw = simd_normalize(simd_quatd(
                                ix: Double(vals[base]),
                                iy: Double(vals[base + 1]),
                                iz: Double(vals[base + 2]),
                                r: Double(vals[base + 3])
                            ))
                            var q = simd_normalize(u * raw * v)
                            if let p = prev, simd_dot(q.vector, p.vector) < 0 {
                                q = -q
                            }
                            prev = q
                            Self.appendQuat(q, to: &outFloats)
                        }
                    }

                    let newAcc = Self.appendFloatAccessor(
                        floats: outFloats,
                        type: "VEC4",
                        count: accCount,
                        bin: &bin,
                        bufferViews: &bufferViews,
                        accessors: &accessors
                    )
                    Self.repointSamplerOutput(
                        channelIndex: ci,
                        newOutputAccessor: newAcc,
                        channels: &channels,
                        samplers: &samplers,
                        samplerUseCounts: &samplerUseCounts
                    )
                } else if path == "translation",
                          !inspector.expressionNodes.contains(node),
                          inspector.lookAtNode != node,
                          let parentIdx = rest.parent[node],
                          normalizedNodes.contains(parentIdx),
                          parentIdx >= 0, parentIdx < rest.worldRotation.count {
                    let parentW = rest.worldRotation[parentIdx]
                    if 1.0 - abs(parentW.real) <= VRMAClipInspector.identityRotationEpsilon { continue }

                    let vals = try inspector.floats(accessor: outputAcc)
                    guard vals.count == accCount * 3 else {
                        throw VRMAClipInspector.InspectError.badAccessor
                    }
                    var outFloats: [Float] = []
                    outFloats.reserveCapacity(vals.count)
                    for k in 0..<accCount {
                        let base = k * 3
                        let v = SIMD3<Double>(Double(vals[base]), Double(vals[base + 1]), Double(vals[base + 2]))
                        let r = parentW.act(v)
                        outFloats.append(Float(r.x))
                        outFloats.append(Float(r.y))
                        outFloats.append(Float(r.z))
                    }

                    let newAcc = Self.appendFloatAccessor(
                        floats: outFloats,
                        type: "VEC3",
                        count: accCount,
                        bin: &bin,
                        bufferViews: &bufferViews,
                        accessors: &accessors
                    )
                    Self.repointSamplerOutput(
                        channelIndex: ci,
                        newOutputAccessor: newAcc,
                        channels: &channels,
                        samplers: &samplers,
                        samplerUseCounts: &samplerUseCounts
                    )
                }
            }

            anims[0]["channels"] = channels
            anims[0]["samplers"] = samplers
            container.json["animations"] = anims
        }

        // 2. Update node rest transforms in JSON.
        for i in 0..<nodes.count {
            let isNormalized = normalizedNodes.contains(i)
            let parentIdx = rest.parent[i]
            let parentNormalized = parentIdx.map { normalizedNodes.contains($0) } ?? false
            let parentW = parentIdx.map { rest.worldRotation[$0] } ?? simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
            let parentRotChanged = parentNormalized && (1.0 - abs(parentW.real) > VRMAClipInspector.identityRotationEpsilon)
            let isExprOrLookAt = inspector.expressionNodes.contains(i) || inspector.lookAtNode == i

            if isNormalized {
                let hadMatrix = nodes[i]["matrix"] != nil
                if hadMatrix {
                    nodes[i].removeValue(forKey: "matrix")
                    let s = rest.local[i].scale
                    if simd_length(s - SIMD3<Double>(repeating: 1)) > 1e-6 {
                        nodes[i]["scale"] = [Float(s.x), Float(s.y), Float(s.z)]
                    }
                }
                nodes[i].removeValue(forKey: "rotation")
                if !isExprOrLookAt && (parentRotChanged || hadMatrix) {
                    let tNew = parentRotChanged ? parentW.act(rest.local[i].translation) : rest.local[i].translation
                    if nodes[i]["translation"] != nil || hadMatrix || simd_length(tNew) > 1e-7 {
                        nodes[i]["translation"] = [Float(tNew.x), Float(tNew.y), Float(tNew.z)]
                    }
                }
            } else if parentRotChanged && !isExprOrLookAt {
                let hadMatrix = nodes[i]["matrix"] != nil
                if hadMatrix {
                    nodes[i].removeValue(forKey: "matrix")
                    let s = rest.local[i].scale
                    if simd_length(s - SIMD3<Double>(repeating: 1)) > 1e-6 {
                        nodes[i]["scale"] = [Float(s.x), Float(s.y), Float(s.z)]
                    }
                }
                let tNew = parentW.act(rest.local[i].translation)
                if nodes[i]["translation"] != nil || hadMatrix || simd_length(tNew) > 1e-7 {
                    nodes[i]["translation"] = [Float(tNew.x), Float(tNew.y), Float(tNew.z)]
                }
                let rNew = simd_normalize(parentW * rest.local[i].rotation)
                if 1.0 - abs(rNew.real) > VRMAClipInspector.identityRotationEpsilon {
                    nodes[i]["rotation"] = [Float(rNew.imag.x), Float(rNew.imag.y), Float(rNew.imag.z), Float(rNew.real)]
                } else {
                    nodes[i].removeValue(forKey: "rotation")
                }
            }
        }

        container.json["nodes"] = nodes
        container.json["accessors"] = accessors
        container.json["bufferViews"] = bufferViews
        if var buffers = container.json["buffers"] as? [[String: Any]], !buffers.isEmpty {
            buffers[0]["byteLength"] = bin.count
            container.json["buffers"] = buffers
        }
        container.bin = bin
        return nonIdentityCount
    }

    /// Enforces a smooth C¹ outward abduction floor on downward-hanging
    /// `leftUpperArm` and `rightUpperArm` rotation tracks so narrow mocap
    /// idles/walks clear slim body silhouettes without disturbing raised gestures.
    ///
    /// Because the adjustment is a pure, stateless C¹ function of each keyframe's
    /// arm orientation, loop-continuous input clips remain loop-continuous.
    ///
    /// - Parameter minDegrees: Minimum outward coronal abduction angle in degrees,
    ///   measured from straight down (`(0, -1, 0)`). Must be finite and in `[0, 90)`.
    /// - Returns: Number of upper-arm rotation channels modified (`0`, `1`, or `2`).
    @discardableResult
    public mutating func enforceMinimumArmAbduction(minDegrees: Float) throws -> Int {
        guard minDegrees.isFinite, minDegrees >= 0, minDegrees < 90 else {
            throw EditError.invalidParameter("minDegrees must be finite and in [0, 90), got \(minDegrees)")
        }
        guard minDegrees > 0 else { return 0 }

        let inspector = try VRMAClipInspector(container: container)
        let rest = try inspector.restTransforms()

        guard var anims = container.json["animations"] as? [[String: Any]], !anims.isEmpty,
              var channels = anims[0]["channels"] as? [[String: Any]],
              var samplers = anims[0]["samplers"] as? [[String: Any]]
        else { throw VRMAClipInspector.InspectError.noAnimation }

        guard var accessors = container.json["accessors"] as? [[String: Any]],
              var bufferViews = container.json["bufferViews"] as? [[String: Any]]
        else { throw VRMAClipInspector.InspectError.badAccessor }

        let minRad = Double(minDegrees) * .pi / 180.0
        // Transition half-width for the piecewise-quadratic C¹ smooth-max floor.
        let beta = min(6.0 * .pi / 180.0, 0.5 * minRad)

        var samplerUseCounts: [Int: Int] = [:]
        for ch in channels {
            if let si = ch["sampler"] as? Int {
                samplerUseCounts[si, default: 0] += 1
            }
        }

        let armTargets: [(node: Int, outwardSign: Double)] = [
            inspector.humanBoneNodeByName["leftUpperArm"].map { ($0, 1.0) },
            inspector.humanBoneNodeByName["rightUpperArm"].map { ($0, -1.0) },
        ].compactMap { $0 }

        guard !armTargets.isEmpty else { return 0 }

        var bin = container.bin
        var modifiedChannels = 0

        for (armNode, outwardSign) in armTargets {
            guard armNode >= 0, armNode < rest.local.count else { continue }
            let localRot = rest.local[armNode].rotation
            let worldRot = rest.worldRotation[armNode]
            let u = simd_normalize(worldRot * simd_inverse(localRot))
            let v = simd_inverse(worldRot)
            let invU = simd_inverse(u)

            for ci in 0..<channels.count {
                guard let target = channels[ci]["target"] as? [String: Any],
                      target["node"] as? Int == armNode,
                      target["path"] as? String == "rotation",
                      let si = channels[ci]["sampler"] as? Int,
                      si >= 0, si < samplers.count,
                      let outputAcc = samplers[si]["output"] as? Int,
                      outputAcc >= 0, outputAcc < accessors.count,
                      let accCount = accessors[outputAcc]["count"] as? Int
                else { continue }

                let interp = (samplers[si]["interpolation"] as? String ?? "LINEAR").uppercased()
                let isCubic = interp == "CUBICSPLINE"
                let vals = try inspector.floats(accessor: outputAcc)

                var anyKeyAdjusted = false
                var outFloats: [Float] = []
                outFloats.reserveCapacity(vals.count)

                func abductionDelta(for rawQ: simd_quatd) -> simd_quatd? {
                    let qNorm = simd_normalize(u * rawQ * v)
                    let dir = qNorm.act(SIMD3<Double>(outwardSign, 0, 0))
                    // C¹ smoothstep downward-hanging gate:
                    //   dir.y <= -0.5 -> 1.0 (full floor for hanging arms)
                    //   dir.y >= -0.1 -> 0.0 (zero disturbance for horizontal/raised gestures)
                    let wDown: Double
                    if dir.y >= -0.1 {
                        return nil
                    } else if dir.y <= -0.5 {
                        wDown = 1.0
                    } else {
                        let t = (-0.1 - dir.y) / 0.4
                        wDown = t * t * (3.0 - 2.0 * t)
                    }

                    let alpha = atan2(outwardSign * dir.x, max(-dir.y, 1e-9))
                    let deficit = minRad - alpha
                    let deltaAlpha: Double
                    if deficit <= -beta {
                        return nil
                    } else if deficit >= beta {
                        deltaAlpha = deficit
                    } else {
                        let s = deficit + beta
                        deltaAlpha = (s * s) / (4.0 * beta)
                    }

                    let deltaTheta = wDown * deltaAlpha
                    guard deltaTheta > 1e-9 else { return nil }
                    let rAbd = simd_quatd(angle: outwardSign * deltaTheta, axis: SIMD3<Double>(0, 0, 1))
                    // Transform back into the channel's rest frame: L_A · W_A⁻¹ · R_abd · W_A · L_A⁻¹.
                    return simd_normalize(invU * rAbd * u)
                }

                if isCubic {
                    guard vals.count == accCount * 4, accCount % 3 == 0 else {
                        throw VRMAClipInspector.InspectError.badAccessor
                    }
                    let keyCount = accCount / 3
                    var prevVal: simd_quatd?
                    for k in 0..<keyCount {
                        let base = k * 12
                        var inT = simd_quatd(ix: Double(vals[base]), iy: Double(vals[base + 1]), iz: Double(vals[base + 2]), r: Double(vals[base + 3]))
                        var val = simd_normalize(simd_quatd(ix: Double(vals[base + 4]), iy: Double(vals[base + 5]), iz: Double(vals[base + 6]), r: Double(vals[base + 7])))
                        var outT = simd_quatd(ix: Double(vals[base + 8]), iy: Double(vals[base + 9]), iz: Double(vals[base + 10]), r: Double(vals[base + 11]))

                        if let leftMul = abductionDelta(for: val) {
                            anyKeyAdjusted = true
                            inT = leftMul * inT
                            val = simd_normalize(leftMul * val)
                            outT = leftMul * outT
                        }
                        if let prev = prevVal, simd_dot(val.vector, prev.vector) < 0 {
                            inT = -inT
                            val = -val
                            outT = -outT
                        }
                        prevVal = val
                        Self.appendQuat(inT, to: &outFloats)
                        Self.appendQuat(val, to: &outFloats)
                        Self.appendQuat(outT, to: &outFloats)
                    }
                } else {
                    guard vals.count == accCount * 4 else {
                        throw VRMAClipInspector.InspectError.badAccessor
                    }
                    var prev: simd_quatd?
                    for k in 0..<accCount {
                        let base = k * 4
                        var q = simd_normalize(simd_quatd(
                            ix: Double(vals[base]),
                            iy: Double(vals[base + 1]),
                            iz: Double(vals[base + 2]),
                            r: Double(vals[base + 3])
                        ))
                        if let leftMul = abductionDelta(for: q) {
                            anyKeyAdjusted = true
                            q = simd_normalize(leftMul * q)
                        }
                        if let p = prev, simd_dot(q.vector, p.vector) < 0 {
                            q = -q
                        }
                        prev = q
                        Self.appendQuat(q, to: &outFloats)
                    }
                }

                if anyKeyAdjusted {
                    let newAcc = Self.appendFloatAccessor(
                        floats: outFloats,
                        type: "VEC4",
                        count: accCount,
                        bin: &bin,
                        bufferViews: &bufferViews,
                        accessors: &accessors
                    )
                    Self.repointSamplerOutput(
                        channelIndex: ci,
                        newOutputAccessor: newAcc,
                        channels: &channels,
                        samplers: &samplers,
                        samplerUseCounts: &samplerUseCounts
                    )
                    modifiedChannels += 1
                }
            }
        }

        if modifiedChannels > 0 {
            anims[0]["channels"] = channels
            anims[0]["samplers"] = samplers
            container.json["animations"] = anims
            container.json["accessors"] = accessors
            container.json["bufferViews"] = bufferViews
            if var buffers = container.json["buffers"] as? [[String: Any]], !buffers.isEmpty {
                buffers[0]["byteLength"] = bin.count
                container.json["buffers"] = buffers
            }
            container.bin = bin
        }
        return modifiedChannels
    }

    /// Pose-similarity loop trim. Works for walk and idle alike (locomotion
    /// spec §3): finds the (start, end) key pair with minimal summed
    /// quaternion distance across all kept rotation channels, subject to
    /// end-start >= 60% of the source key count, then rewrites only the
    /// channel-referenced samplers to the [start...end] window with times
    /// rebased to zero. Orphaned samplers are left untouched.
    /// Trimmed data is APPENDED as new bufferViews/accessors and samplers
    /// are repointed — existing bytes stay untouched.
    ///
    /// Timelines may live in distinct accessors as long as their values are
    /// identical (the common exporter pattern); genuinely divergent timelines
    /// throw unalignedKeyframes. When values match, all kept samplers' "input"
    /// is repointed to ONE shared new canonical accessor (not 91 identical copies).
    public mutating func loopTrim() throws {
        let inspector = try VRMAClipInspector(container: container)
        guard var anims = container.json["animations"] as? [[String: Any]], !anims.isEmpty,
              let channels = anims[0]["channels"] as? [[String: Any]],
              var samplers = anims[0]["samplers"] as? [[String: Any]]
        else { throw VRMAClipInspector.InspectError.noAnimation }

        // Every kept channel is sliced on the same [s...e] key window, so ALL of
        // them — rotations and the hips translation alike — must share one keyframe
        // timeline. Exporters commonly emit N distinct accessor objects that are
        // byte-identical (one per channel), so we first collect distinct accessor
        // indices and then verify their VALUES are elementwise equal before accepting.
        var channelInputs: [Int] = []
        for ch in channels {
            guard let si = ch["sampler"] as? Int, si >= 0, si < samplers.count,
                  let input = samplers[si]["input"] as? Int else { continue }
            channelInputs.append(input)
        }
        let distinctInputs = Array(Set(channelInputs))
        if distinctInputs.count > 1 {
            // Decode the first and compare every other accessor elementwise.
            let canonical = try inspector.floats(accessor: distinctInputs[0])
            for i in 1..<distinctInputs.count {
                let other = try inspector.floats(accessor: distinctInputs[i])
                guard other.count == canonical.count,
                      zip(other, canonical).allSatisfy({ $0 == $1 })
                else { throw EditError.unalignedKeyframes }
            }
        }
        // All timelines are value-identical; use the first distinct input as the
        // canonical accessor index for slicing.
        let canonicalInputIndex = distinctInputs.first

        guard let accessors0 = container.json["accessors"] as? [[String: Any]] else {
            throw VRMAClipInspector.InspectError.badAccessor
        }
        guard let bufferViews0 = container.json["bufferViews"] as? [[String: Any]] else {
            throw VRMAClipInspector.InspectError.badAccessor
        }

        // Collect rotation outputs for the seam metric.
        var rotationOutputs: [[Float]] = []
        for ch in channels {
            guard let target = ch["target"] as? [String: Any],
                  target["path"] as? String == "rotation",
                  let si = ch["sampler"] as? Int, si >= 0, si < samplers.count,
                  let out = samplers[si]["output"] as? Int else { continue }
            let q = try inspector.floats(accessor: out)
            rotationOutputs.append(q)
        }

        // keyCount comes from the canonical input accessor — the one timeline
        // every channel was just validated against (by value).
        guard let canonicalInput = canonicalInputIndex else {
            return  // no channels at all, nothing to trim
        }
        let keyCount: Int
        guard canonicalInput >= 0, canonicalInput < accessors0.count,
              let kc = accessors0[canonicalInput]["count"] as? Int
        else { throw VRMAClipInspector.InspectError.badAccessor }
        keyCount = kc
        guard !rotationOutputs.isEmpty else { return }  // no rotation channels, nothing to trim

        guard keyCount > 4 else { return }  // nothing meaningful to trim

        // Each rotation output must be exactly one quat per key.
        for q in rotationOutputs {
            guard q.count == keyCount * 4 else { throw VRMAClipInspector.InspectError.badAccessor }
        }

        // Hips Y joins the seam metric: idle rotations are near-flat, so
        // without the bob term the seam lands arbitrarily and pops vertically.
        var hipsY: [Float] = []
        if let (_, hipsOutputAcc) = try? inspector.hipsTranslationSampler() {
            let hipsVals = try inspector.floats(accessor: hipsOutputAcc)
            // VEC3 interleaved: x, y, z — hipsY is index 1, 4, 7, ...
            if hipsVals.count == keyCount * 3 {
                hipsY = stride(from: 1, to: hipsVals.count, by: 3).map { hipsVals[$0] }
            } else if !hipsVals.isEmpty {
                // count mismatch — throw rather than use corrupt data
                throw VRMAClipInspector.InspectError.badAccessor
            }
        }
        // Bob samples must align with the shared timeline.
        if !hipsY.isEmpty {
            guard hipsY.count == keyCount else { throw VRMAClipInspector.InspectError.badAccessor }
        }

        let wY: Float = 1.5  // ~1 cm of bob ≈ a few degrees of joint mismatch on the 1-|dot| scale
        func poseDistance(_ a: Int, _ b: Int) -> Float {
            var d: Float = 0
            for q in rotationOutputs {
                var dot: Float = 0
                for k in 0..<4 { dot += q[a * 4 + k] * q[b * 4 + k] }
                d += 1 - min(1, abs(dot))
            }
            // ~1 cm of bob mismatch weighs like a few degrees of joint error.
            if !hipsY.isEmpty {
                d += wY * abs(hipsY[a] - hipsY[b])
            }
            return d
        }
        let minSpan = Int(Float(keyCount) * 0.6)
        var best = (s: 0, e: keyCount - 1, d: Float.greatestFiniteMagnitude)
        for s in 0..<(keyCount - minSpan) {
            for e in (s + minSpan)..<keyCount {
                let d = poseDistance(s, e)
                if d < best.d { best = (s, e, d) }
            }
        }

        // Rewrite only channel-referenced samplers to [best.s ... best.e] via appended views.
        // All kept samplers share ONE sliced input accessor (the canonical timeline);
        // outputs are still sliced per-accessor as each channel has its own data.
        var accessors = accessors0
        var bufferViews = bufferViews0
        var bin = container.bin

        let usedSamplers = Set(channels.compactMap { $0["sampler"] as? Int })

        var rewritten: [String: Int] = [:]

        let compsByType: [String: Int] = ["SCALAR": 1, "VEC3": 3, "VEC4": 4]

        func sliced(_ accessorIndex: Int, comps: Int, rebase: Bool) throws -> Int {
            // rebase only ever true for SCALAR inputs (comps==1)
            precondition(!rebase || comps == 1)
            let key = "\(accessorIndex)/\(comps)/\(rebase)"
            if let existing = rewritten[key] { return existing }
            let vals = try inspector.floats(accessor: accessorIndex)
            guard vals.count == keyCount * comps else { throw VRMAClipInspector.InspectError.badAccessor }
            let t0 = rebase ? vals[best.s] : 0
            var slice: [Float] = []
            slice.reserveCapacity((best.e - best.s + 1) * comps)
            for i in best.s...best.e {
                for c in 0..<comps { slice.append(vals[i * comps + c] - (rebase && c == 0 ? t0 : 0)) }
            }
            while bin.count % 4 != 0 { bin.append(0) }
            let off = bin.count
            slice.withUnsafeBytes { bin.append(contentsOf: $0) }
            bufferViews.append(["buffer": 0, "byteOffset": off, "byteLength": slice.count * 4])
            var acc: [String: Any] = [
                "bufferView": bufferViews.count - 1, "componentType": 5126,
                "count": best.e - best.s + 1,
                "type": comps == 1 ? "SCALAR" : (comps == 3 ? "VEC3" : "VEC4"),
            ]
            if comps == 1 { acc["min"] = [0]; acc["max"] = [slice.last!] }
            accessors.append(acc)
            rewritten[key] = accessors.count - 1
            return accessors.count - 1
        }

        // Slice the canonical input ONCE; every kept sampler repoints to it.
        let sharedInputNew = try sliced(canonicalInput, comps: 1, rebase: true)

        for (i, s) in samplers.enumerated() {
            guard usedSamplers.contains(i) else { continue }
            guard let output = s["output"] as? Int else { continue }
            guard output >= 0, output < accessors.count,
                  let typeStr = accessors[output]["type"] as? String,
                  let outComps = compsByType[typeStr]
            else { throw VRMAClipInspector.InspectError.badAccessor }
            samplers[i]["input"] = sharedInputNew
            samplers[i]["output"] = try sliced(output, comps: outComps, rebase: false)
        }
        anims[0]["samplers"] = samplers
        container.json["animations"] = anims
        container.json["accessors"] = accessors
        container.json["bufferViews"] = bufferViews
        if var buffers = container.json["buffers"] as? [[String: Any]], !buffers.isEmpty {
            buffers[0]["byteLength"] = bin.count
            container.json["buffers"] = buffers
        }
        container.bin = bin
    }

    // MARK: - Private Binary Helpers

    private static func appendQuat(_ q: simd_quatd, to out: inout [Float]) {
        out.append(Float(q.imag.x))
        out.append(Float(q.imag.y))
        out.append(Float(q.imag.z))
        out.append(Float(q.real))
    }

    private static func appendFloatAccessor(
        floats: [Float],
        type: String,
        count: Int,
        bin: inout Data,
        bufferViews: inout [[String: Any]],
        accessors: inout [[String: Any]]
    ) -> Int {
        while bin.count % 4 != 0 { bin.append(0) }
        let off = bin.count
        floats.withUnsafeBytes { bin.append(contentsOf: $0) }
        bufferViews.append([
            "buffer": 0,
            "byteOffset": off,
            "byteLength": floats.count * 4,
        ])
        accessors.append([
            "bufferView": bufferViews.count - 1,
            "componentType": 5126,
            "count": count,
            "type": type,
        ])
        return accessors.count - 1
    }

    private static func repointSamplerOutput(
        channelIndex: Int,
        newOutputAccessor: Int,
        channels: inout [[String: Any]],
        samplers: inout [[String: Any]],
        samplerUseCounts: inout [Int: Int]
    ) {
        guard let si = channels[channelIndex]["sampler"] as? Int, si >= 0, si < samplers.count else { return }
        if (samplerUseCounts[si] ?? 1) > 1 {
            var cloned = samplers[si]
            cloned["output"] = newOutputAccessor
            let newIndex = samplers.count
            samplers.append(cloned)
            channels[channelIndex]["sampler"] = newIndex
            samplerUseCounts[si] = (samplerUseCounts[si] ?? 1) - 1
            samplerUseCounts[newIndex] = 1
        } else {
            samplers[si]["output"] = newOutputAccessor
        }
    }
}
