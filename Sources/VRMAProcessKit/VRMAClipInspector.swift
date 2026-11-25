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

/// Read-side helpers over a VRMA GLBContainer: locate the hips channel via
/// the VRMC_vrm_animation humanBones map, resolve expression/lookAt nodes,
/// inspect rest-pose hierarchy, and decode sampler float data.
public struct VRMAClipInspector {
    let container: GLBContainer
    public let hipsNode: Int
    public let humanBoneNodes: Set<Int>
    public let humanBoneNodeByName: [String: Int]
    public let expressionNodes: Set<Int>
    public let lookAtNode: Int?

    /// All node indices with VRMC_vrm_animation semantic roles:
    /// `humanBones`, `expressions` (`preset` + `custom`), and `lookAt`.
    public var semanticNodes: Set<Int> {
        var result = humanBoneNodes.union(expressionNodes)
        if let lookAtNode {
            result.insert(lookAtNode)
        }
        return result
    }

    /// Node indices representing eyes (`leftEye` / `rightEye` in `humanBones`,
    /// plus unmapped VRoid eye nodes such as `J_Adj_L_FaceEye` / `J_Adj_R_FaceEye`).
    public var eyeNodes: Set<Int> {
        var result = Set<Int>()
        if let left = humanBoneNodeByName["leftEye"] { result.insert(left) }
        if let right = humanBoneNodeByName["rightEye"] { result.insert(right) }
        let nonEyeSemantic = humanBoneNodes.subtracting(result)
            .union(expressionNodes)
            .union(lookAtNode.map { [$0] } ?? [])
        if let nodes = container.json["nodes"] as? [[String: Any]] {
            for (idx, node) in nodes.enumerated() where !nonEyeSemantic.contains(idx) {
                guard let name = node["name"] as? String else { continue }
                let norm = name.lowercased()
                    .replacingOccurrences(of: "_", with: "")
                    .replacingOccurrences(of: ".", with: "")
                if norm.contains("faceeye") || norm == "lefteye" || norm == "righteye" {
                    result.insert(idx)
                }
            }
        }
        return result
    }

    public enum InspectError: Error { case noAnimation, noHumanoidMap, noHipsTranslation, badAccessor, malformedNodes }

    /// Diagnostic issues reported by ``diagnose(container:)`` / ``diagnose()``.
    public enum ClipIssue: Equatable, Sendable, CustomStringConvertible {
        case noAnimation
        case emptyAnimation(channelCount: Int, samplerCount: Int)
        case zeroDuration(rawDuration: Float)
        case nonIdentityRestPose(nodeCount: Int)
        case bakedEyeChannels(count: Int, allConstant: Bool)
        case nonSemanticChannels(count: Int)

        public var description: String {
            switch self {
            case .noAnimation:
                return "GLB contains no animations"
            case .emptyAnimation(let channels, let samplers):
                return "animation has 0 playable channels (channels=\(channels), samplers=\(samplers))"
            case .zeroDuration(let rawDuration):
                return "animation has non-positive duration (\(rawDuration)s)"
            case .nonIdentityRestPose(let nodeCount):
                return "\(nodeCount) humanoid/ancestor node(s) have non-identity rest rotations"
            case .bakedEyeChannels(let count, let allConstant):
                return "\(count) baked eye channel(s) present (allConstant=\(allConstant))"
            case .nonSemanticChannels(let count):
                return "\(count) non-humanoid/non-expression/non-lookAt channel(s) present"
            }
        }
    }

    internal struct NodeRestTransform {
        var translation: SIMD3<Double>
        var rotation: simd_quatd
        var scale: SIMD3<Double>
    }

    internal static let identityRotationEpsilon: Double = 1e-8

    public init(container: GLBContainer) throws {
        self.container = container
        guard let ext = container.json["extensions"] as? [String: Any],
              let vrma = ext["VRMC_vrm_animation"] as? [String: Any],
              let humanoid = vrma["humanoid"] as? [String: Any],
              let bones = humanoid["humanBones"] as? [String: Any]
        else { throw InspectError.noHumanoidMap }
        var nodes = Set<Int>()
        var byName: [String: Int] = [:]
        var hips: Int?
        for (name, v) in bones {
            guard let d = v as? [String: Any], let n = Self.intValue(from: d["node"]) else { continue }
            nodes.insert(n)
            byName[name] = n
            if name == "hips" { hips = n }
        }
        guard let h = hips else { throw InspectError.noHumanoidMap }
        self.hipsNode = h
        self.humanBoneNodes = nodes
        self.humanBoneNodeByName = byName

        var exprNodes = Set<Int>()
        if let expressions = vrma["expressions"] as? [String: Any] {
            for sectionKey in ["preset", "custom"] {
                if let section = expressions[sectionKey] as? [String: Any] {
                    for (_, v) in section {
                        if let d = v as? [String: Any], let n = Self.intValue(from: d["node"]) {
                            exprNodes.insert(n)
                        }
                    }
                }
            }
        }
        self.expressionNodes = exprNodes

        if let lookAt = vrma["lookAt"] as? [String: Any],
           let n = Self.intValue(from: lookAt["node"]) {
            self.lookAtNode = n
        } else {
            self.lookAtNode = nil
        }
    }

    func animation0() throws -> [String: Any] {
        guard let anims = container.json["animations"] as? [[String: Any]], let a = anims.first
        else { throw InspectError.noAnimation }
        return a
    }

    /// Decodes the float array backing accessor `index`.
    /// Throws `badAccessor` if componentType is not 5126 (Float), type is not SCALAR/VEC3/VEC4,
    /// any index is out of range, or the byte range exceeds the bin buffer.
    public func floats(accessor index: Int) throws -> [Float] {
        try Self.floats(accessor: index, in: container)
    }

    internal static func floats(accessor index: Int, in container: GLBContainer) throws -> [Float] {
        guard let accessors = container.json["accessors"] as? [[String: Any]],
              index >= 0, index < accessors.count,
              let bvIndex = accessors[index]["bufferView"] as? Int,
              bvIndex >= 0,
              let count = accessors[index]["count"] as? Int,
              let componentType = accessors[index]["componentType"] as? Int,
              let type = accessors[index]["type"] as? String,
              let bvs = container.json["bufferViews"] as? [[String: Any]],
              bvIndex < bvs.count
        else { throw InspectError.badAccessor }
        // componentType 5126 (Float32) and a recognised vector width are required; any other type throws.
        guard componentType == 5126,
              let comps = ["SCALAR": 1, "VEC3": 3, "VEC4": 4][type]
        else { throw InspectError.badAccessor }
        let byteOffset = (bvs[bvIndex]["byteOffset"] as? Int ?? 0) + (accessors[index]["byteOffset"] as? Int ?? 0)
        // Overflow-safe bounds math: hostile accessor counts must throw, not trap.
        let (n, nOverflow) = count.multipliedReportingOverflow(by: comps)
        guard !nOverflow, n >= 0 else { throw InspectError.badAccessor }
        let (nBytes, bOverflow) = n.multipliedReportingOverflow(by: 4)
        guard !bOverflow else { throw InspectError.badAccessor }
        let (end, eOverflow) = byteOffset.addingReportingOverflow(nBytes)
        guard !eOverflow, byteOffset >= 0, end <= container.bin.count else { throw InspectError.badAccessor }
        return container.bin.withUnsafeBytes { raw in
            (0..<n).map { raw.loadUnaligned(fromByteOffset: byteOffset + $0 * 4, as: Float.self) }
        }
    }

    /// (input accessor, output accessor) of the hips translation channel.
    public func hipsTranslationSampler() throws -> (input: Int, output: Int) {
        let anim = try animation0()
        guard let channels = anim["channels"] as? [[String: Any]],
              let samplers = anim["samplers"] as? [[String: Any]]
        else { throw InspectError.noAnimation }
        for ch in channels {
            guard let target = ch["target"] as? [String: Any],
                  target["node"] as? Int == hipsNode,
                  target["path"] as? String == "translation",
                  let si = ch["sampler"] as? Int, si >= 0, si < samplers.count,
                  let input = samplers[si]["input"] as? Int, input >= 0,
                  let output = samplers[si]["output"] as? Int, output >= 0
            else { continue }
            return (input, output)
        }
        throw InspectError.noHipsTranslation
    }

    /// Mean ground speed of the hips over the clip: total XZ path length / duration.
    public func meanHipsXZSpeed() throws -> Float {
        let (inputAcc, outputAcc) = try hipsTranslationSampler()
        let times = try floats(accessor: inputAcc)
        let xyz = try floats(accessor: outputAcc)
        guard times.count >= 2, xyz.count == times.count * 3 else { throw InspectError.badAccessor }
        var path: Float = 0
        for i in 1..<times.count {
            let dx = xyz[i * 3] - xyz[(i - 1) * 3]
            let dz = xyz[i * 3 + 2] - xyz[(i - 1) * 3 + 2]
            path += (dx * dx + dz * dz).squareRoot()
        }
        let duration = times.last! - times.first!
        return duration > 0 ? path / duration : 0
    }

    /// Rest hips world height from the node hierarchy (sum of ancestor Y translations).
    /// Throws `malformedNodes` if a cycle is detected in the parent chain.
    public func hipsRestHeight() throws -> Float {
        guard let nodes = container.json["nodes"] as? [[String: Any]] else { throw InspectError.badAccessor }
        let parent = buildParentMap(nodes: nodes)
        var y: Float = 0
        var cur: Int? = hipsNode
        var visited = Set<Int>()
        while let c = cur {
            // Out-of-range or repeated node indices indicate a malformed hierarchy.
            guard c >= 0, c < nodes.count else { throw InspectError.malformedNodes }
            guard visited.insert(c).inserted else { throw InspectError.malformedNodes }
            if let t = nodes[c]["translation"] as? [Any], t.count == 3 {
                y += Float((t[1] as? NSNumber)?.doubleValue ?? 0)
            }
            cur = parent[c]
        }
        return y
    }

    /// Maximum keyframe timestamp across all channel-referenced samplers in `animations[0]`,
    /// or `0` if the animation has no channels or keyframes.
    public func duration() throws -> Float {
        let anim = try animation0()
        return Self.computeDuration(animation: anim, in: container)
    }

    /// Runs non-throwing hygiene and emptiness diagnostics on any VRMA container,
    /// including aborted captures with empty animations or zero duration.
    public static func diagnose(container: GLBContainer) -> [ClipIssue] {
        var issues: [ClipIssue] = []
        guard let anims = container.json["animations"] as? [[String: Any]], let anim = anims.first else {
            return [.noAnimation]
        }
        let channels = anim["channels"] as? [[String: Any]] ?? []
        let samplers = anim["samplers"] as? [[String: Any]] ?? []
        if channels.isEmpty {
            issues.append(.emptyAnimation(channelCount: 0, samplerCount: samplers.count))
        }
        let rawDuration = computeDuration(animation: anim, in: container)
        if rawDuration <= 0 {
            issues.append(.zeroDuration(rawDuration: rawDuration))
        }

        if let inspector = try? VRMAClipInspector(container: container) {
            let semNodes = inspector.semanticNodes
            var nonSemCount = 0
            for ch in channels {
                if let target = ch["target"] as? [String: Any], let node = target["node"] as? Int {
                    if !semNodes.contains(node) { nonSemCount += 1 }
                } else {
                    nonSemCount += 1
                }
            }
            if nonSemCount > 0 {
                issues.append(.nonSemanticChannels(count: nonSemCount))
            }

            let eyes = inspector.eyeNodes
            if !eyes.isEmpty {
                var eyeCount = 0
                var allConst = true
                for ch in channels {
                    guard let target = ch["target"] as? [String: Any],
                          let node = target["node"] as? Int,
                          eyes.contains(node) else { continue }
                    eyeCount += 1
                    let isConst = (try? inspector.isChannelConstant(ch, samplers: samplers)) ?? false
                    if !isConst { allConst = false }
                }
                if eyeCount > 0 {
                    issues.append(.bakedEyeChannels(count: eyeCount, allConstant: allConst))
                }
            }

            if let rest = try? inspector.restTransforms() {
                let normalizedSet = inspector.humanoidAndAncestorNodes(parentMap: rest.parent)
                var nonIdCount = 0
                for idx in normalizedSet where idx >= 0 && idx < rest.local.count {
                    if 1.0 - abs(rest.local[idx].rotation.real) > identityRotationEpsilon {
                        nonIdCount += 1
                    }
                }
                if nonIdCount > 0 {
                    issues.append(.nonIdentityRestPose(nodeCount: nonIdCount))
                }
            }
        }
        return issues
    }

    /// Runs hygiene and emptiness diagnostics on this inspector's container.
    public func diagnose() -> [ClipIssue] {
        Self.diagnose(container: container)
    }

    // MARK: - Internal Helpers

    internal func buildParentMap(nodes: [[String: Any]]) -> [Int: Int] {
        var parent: [Int: Int] = [:]
        for (i, n) in nodes.enumerated() {
            for c in (n["children"] as? [Int]) ?? [] {
                guard c >= 0, c < nodes.count else { continue }
                parent[c] = i
            }
        }
        return parent
    }

    internal func humanoidAndAncestorNodes(parentMap: [Int: Int]) -> Set<Int> {
        var result = Set<Int>()
        for node in humanBoneNodes {
            var cur: Int? = node
            var visited = Set<Int>()
            while let c = cur, visited.insert(c).inserted {
                result.insert(c)
                cur = parentMap[c]
            }
        }
        return result
    }

    internal func restTransforms() throws -> (local: [NodeRestTransform], worldRotation: [simd_quatd], parent: [Int: Int]) {
        guard let nodes = container.json["nodes"] as? [[String: Any]] else {
            throw InspectError.badAccessor
        }
        let parent = buildParentMap(nodes: nodes)
        var local: [NodeRestTransform] = []
        local.reserveCapacity(nodes.count)
        for node in nodes {
            local.append(Self.parseNodeRestTransform(node))
        }

        var worldRot: [simd_quatd] = Array(
            repeating: simd_quatd(ix: 0, iy: 0, iz: 0, r: 1),
            count: nodes.count
        )
        for i in 0..<nodes.count {
            var chain: [Int] = []
            var cur: Int? = i
            var visited = Set<Int>()
            while let c = cur {
                guard c >= 0, c < nodes.count else { throw InspectError.malformedNodes }
                guard visited.insert(c).inserted else { throw InspectError.malformedNodes }
                chain.append(c)
                cur = parent[c]
            }
            var w = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
            for idx in chain.reversed() {
                w = simd_normalize(w * local[idx].rotation)
            }
            worldRot[i] = w
        }
        return (local, worldRot, parent)
    }

    internal func isChannelConstant(_ channel: [String: Any], samplers: [[String: Any]]) throws -> Bool {
        guard let target = channel["target"] as? [String: Any],
              let path = target["path"] as? String,
              let si = channel["sampler"] as? Int, si >= 0, si < samplers.count,
              let outputAcc = samplers[si]["output"] as? Int,
              let inputAcc = samplers[si]["input"] as? Int,
              let accessors = container.json["accessors"] as? [[String: Any]],
              inputAcc >= 0, inputAcc < accessors.count,
              let keyCount = accessors[inputAcc]["count"] as? Int
        else { throw InspectError.badAccessor }

        if keyCount <= 1 { return true }

        let vals = try floats(accessor: outputAcc)
        let interp = (samplers[si]["interpolation"] as? String ?? "LINEAR").uppercased()
        let isCubic = interp == "CUBICSPLINE"

        if path == "rotation" {
            let stride = isCubic ? 12 : 4
            let valOffset = isCubic ? 4 : 0
            guard vals.count == keyCount * stride else { throw InspectError.badAccessor }
            let q0 = simd_normalize(simd_quatf(
                ix: vals[valOffset],
                iy: vals[valOffset + 1],
                iz: vals[valOffset + 2],
                r: vals[valOffset + 3]
            ))
            for k in 0..<keyCount {
                let base = k * stride
                if isCubic {
                    for t in 0..<4 {
                        if abs(vals[base + t]) > 1e-5 || abs(vals[base + 8 + t]) > 1e-5 {
                            return false
                        }
                    }
                }
                if k > 0 {
                    let qk = simd_normalize(simd_quatf(
                        ix: vals[base + valOffset],
                        iy: vals[base + valOffset + 1],
                        iz: vals[base + valOffset + 2],
                        r: vals[base + valOffset + 3]
                    ))
                    let dot = abs(simd_dot(q0.vector, qk.vector))
                    if 1.0 - dot > 1e-6 {
                        return false
                    }
                }
            }
            return true
        } else if path == "translation" || path == "scale" {
            let stride = isCubic ? 9 : 3
            let valOffset = isCubic ? 3 : 0
            guard vals.count == keyCount * stride else { throw InspectError.badAccessor }
            let v0 = SIMD3<Float>(vals[valOffset], vals[valOffset + 1], vals[valOffset + 2])
            for k in 0..<keyCount {
                let base = k * stride
                if isCubic {
                    for t in 0..<3 {
                        if abs(vals[base + t]) > 1e-5 || abs(vals[base + 6 + t]) > 1e-5 {
                            return false
                        }
                    }
                }
                if k > 0 {
                    let vk = SIMD3<Float>(vals[base + valOffset], vals[base + valOffset + 1], vals[base + valOffset + 2])
                    if simd_length(vk - v0) > 1e-5 {
                        return false
                    }
                }
            }
            return true
        }
        return false
    }

    private static func computeDuration(animation: [String: Any], in container: GLBContainer) -> Float {
        let channels = animation["channels"] as? [[String: Any]] ?? []
        let samplers = animation["samplers"] as? [[String: Any]] ?? []
        var maxTime: Float = 0
        var seenInputs = Set<Int>()
        for ch in channels {
            guard let si = ch["sampler"] as? Int, si >= 0, si < samplers.count,
                  let inputAcc = samplers[si]["input"] as? Int,
                  seenInputs.insert(inputAcc).inserted else { continue }
            if let times = try? floats(accessor: inputAcc, in: container), let last = times.last {
                maxTime = max(maxTime, last)
            }
        }
        return maxTime
    }

    private static func parseNodeRestTransform(_ node: [String: Any]) -> NodeRestTransform {
        if let mAny = node["matrix"] as? [Any], mAny.count == 16 {
            let m = mAny.map { ($0 as? NSNumber)?.doubleValue ?? 0 }
            let t = SIMD3<Double>(m[12], m[13], m[14])
            var c0 = SIMD3<Double>(m[0], m[1], m[2])
            var c1 = SIMD3<Double>(m[4], m[5], m[6])
            var c2 = SIMD3<Double>(m[8], m[9], m[10])
            var sx = simd_length(c0)
            var sy = simd_length(c1)
            var sz = simd_length(c2)
            if sx > 1e-12 { c0 /= sx } else { sx = 1 }
            if sy > 1e-12 { c1 /= sy } else { sy = 1 }
            if sz > 1e-12 { c2 /= sz } else { sz = 1 }
            var rotMat = simd_double3x3(columns: (c0, c1, c2))
            if simd_determinant(rotMat) < 0 {
                sx = -sx
                rotMat.columns.0 = -rotMat.columns.0
            }
            return NodeRestTransform(
                translation: t,
                rotation: simd_normalize(simd_quatd(rotMat)),
                scale: SIMD3<Double>(sx, sy, sz)
            )
        }

        let t: SIMD3<Double>
        if let tAny = node["translation"] as? [Any], tAny.count == 3 {
            t = SIMD3<Double>(
                (tAny[0] as? NSNumber)?.doubleValue ?? 0,
                (tAny[1] as? NSNumber)?.doubleValue ?? 0,
                (tAny[2] as? NSNumber)?.doubleValue ?? 0
            )
        } else {
            t = SIMD3<Double>(repeating: 0)
        }

        let r: simd_quatd
        if let rAny = node["rotation"] as? [Any], rAny.count == 4 {
            let q = simd_quatd(
                ix: (rAny[0] as? NSNumber)?.doubleValue ?? 0,
                iy: (rAny[1] as? NSNumber)?.doubleValue ?? 0,
                iz: (rAny[2] as? NSNumber)?.doubleValue ?? 0,
                r: (rAny[3] as? NSNumber)?.doubleValue ?? 1
            )
            r = simd_length(q.vector) > 1e-12 ? simd_normalize(q) : simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
        } else {
            r = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
        }

        let s: SIMD3<Double>
        if let sAny = node["scale"] as? [Any], sAny.count == 3 {
            s = SIMD3<Double>(
                (sAny[0] as? NSNumber)?.doubleValue ?? 1,
                (sAny[1] as? NSNumber)?.doubleValue ?? 1,
                (sAny[2] as? NSNumber)?.doubleValue ?? 1
            )
        } else {
            s = SIMD3<Double>(repeating: 1)
        }

        return NodeRestTransform(translation: t, rotation: r, scale: s)
    }

    private static func intValue(from any: Any?) -> Int? {
        if let int = any as? Int { return int }
        if let num = any as? NSNumber { return num.intValue }
        if let str = any as? String { return Int(str) }
        return nil
    }
}
