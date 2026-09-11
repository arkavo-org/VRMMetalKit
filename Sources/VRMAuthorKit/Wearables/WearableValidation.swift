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

/// Structural checks on spring chains and generated meshes, shared by the
/// wearable compiler and by object editing.
public enum WearableValidation {
    /// VRMC_springBone prohibits overlapping chains: a node may appear in at
    /// most one spring's joint list.
    public static func noOverlappingChains(_ springs: [SpringObject]) throws {
        var owner: [String: String] = [:]
        for spring in springs {
            for joint in spring.joints {
                if let other = owner[joint.node], other != spring.id {
                    throw AuthorError(code: .springChainOverlap, objectId: spring.id, path: "/joints", observed: .string(joint.node),
                                      message: "Node '\(joint.node)' is a joint of both spring '\(other)' and spring '\(spring.id)'; VRMC_springBone chains must not overlap.",
                                      suggestedCommands: ["object get \(other)", "object set"])
                }
                owner[joint.node] = spring.id
            }
        }
    }

    /// Every spring ends in a terminal tail node that exists in the rig, and
    /// each joint's node descends from the previous joint's node.
    public static func terminalTailPresent(_ springs: [SpringObject], nodes: [CompiledNode]) throws {
        var parents: [String: String?] = [:]
        for node in nodes { parents[node.id] = node.parentId }
        try terminalTailPresent(springs, parentByNodeId: parents)
    }

    public static func terminalTailPresent(_ springs: [SpringObject], parentByNodeId: [String: String?]) throws {
        for spring in springs {
            guard spring.joints.count >= 2, let tail = spring.joints.last else {
                throw AuthorError(code: .springTailMissing, objectId: spring.id, path: "/joints", observed: .number(Double(spring.joints.count)), required: 2,
                                  message: "Spring '\(spring.id)' needs a root joint and a terminal tail joint; the last joint is not evaluated as a rotating segment.",
                                  suggestedCommands: ["object set"])
            }
            guard parentByNodeId[tail.node] != nil else {
                throw AuthorError(code: .springTailMissing, objectId: spring.id, path: "/joints/\(spring.joints.count - 1)/node", observed: .string(tail.node),
                                  message: "Terminal tail node '\(tail.node)' of spring '\(spring.id)' does not exist in the rig.",
                                  suggestedCommands: ["object list --kind node", "object set"])
            }
            for i in 1..<spring.joints.count {
                let prev = spring.joints[i - 1].node
                let cur = spring.joints[i].node
                guard descends(cur, from: prev, parents: parentByNodeId) else {
                    throw AuthorError(code: .springTailMissing, objectId: spring.id, path: "/joints/\(i)/node", observed: .string(cur), required: .string(prev),
                                      message: "Joint '\(cur)' of spring '\(spring.id)' is not a descendant of the previous joint '\(prev)'; joints must be ordered root to tip along one node chain.",
                                      suggestedCommands: ["object get \(spring.id)", "object set"])
                }
            }
        }
    }

    private static func descends(_ node: String, from ancestor: String, parents: [String: String?]) -> Bool {
        var cursor: String? = parents[node] ?? nil
        var steps = 0
        while let c = cursor, steps < 4096 {
            if c == ancestor { return true }
            cursor = parents[c] ?? nil
            steps += 1
        }
        return false
    }

    /// Runs `SpringObject.validate`, chain-overlap and terminal-tail checks.
    public static func validateSprings(_ springs: [SpringObject], nodes: [CompiledNode]) throws {
        for s in springs { try s.validate() }
        try noOverlappingChains(springs)
        try terminalTailPresent(springs, nodes: nodes)
    }

    /// Finite attributes, matching stream lengths, in-range indices and no
    /// degenerate triangles.
    public static func validateMesh(_ mesh: CompiledMesh) throws {
        for (pi, prim) in mesh.primitives.enumerated() {
            let path = "/meshes/\(mesh.id)/primitives/\(pi)"
            let n = prim.positions.count
            func fail(_ what: String, _ observed: JSONValue? = nil) -> AuthorError {
                AuthorError(code: .meshInvalid, objectId: mesh.id, path: path, observed: observed, message: "Mesh '\(mesh.id)' primitive \(pi): \(what)",
                            suggestedCommands: ["build", "qa run"])
            }
            guard n > 0 else { throw fail("has no vertices.") }
            guard prim.normals.count == n, prim.uv0.count == n else { throw fail("normal/uv stream lengths do not match positions.", .number(Double(n))) }
            if let j = prim.joints0, j.count != n { throw fail("joints0 length does not match positions.") }
            if let w = prim.weights0, w.count != n { throw fail("weights0 length does not match positions.") }
            for (i, p) in prim.positions.enumerated() where !V3.isFinite(p) { throw fail("non-finite position at vertex \(i).") }
            for (i, nrm) in prim.normals.enumerated() where !V3.isFinite(nrm) { throw fail("non-finite normal at vertex \(i).") }
            for (i, uv) in prim.uv0.enumerated() where !(uv.x.isFinite && uv.y.isFinite) { throw fail("non-finite uv at vertex \(i).") }
            if let w = prim.weights0 {
                for (i, ww) in w.enumerated() {
                    guard ww.x.isFinite, ww.y.isFinite, ww.z.isFinite, ww.w.isFinite, abs(ww.sum() - 1) < 1e-3 else { throw fail("skin weights at vertex \(i) do not sum to 1.") }
                }
            }
            guard prim.indices.count % 3 == 0, !prim.indices.isEmpty else { throw fail("index count is not a multiple of 3.", .number(Double(prim.indices.count))) }
            var t = 0
            while t < prim.indices.count {
                let a = Int(prim.indices[t]), b = Int(prim.indices[t + 1]), c = Int(prim.indices[t + 2])
                guard a < n, b < n, c < n else { throw fail("index out of range in triangle \(t / 3).", .number(Double(max(a, b, c)))) }
                guard a != b, b != c, a != c else { throw fail("triangle \(t / 3) repeats a vertex index.") }
                let area = V3.length(V3.cross(prim.positions[b] - prim.positions[a], prim.positions[c] - prim.positions[a]))
                guard area > 1e-12 else { throw fail("triangle \(t / 3) is degenerate.", .number(Double(area))) }
                t += 3
            }
            for m in prim.morphTargets where m.positionDeltas.count != n { throw fail("morph '\(m.name)' delta count does not match positions.") }
        }
    }
}
