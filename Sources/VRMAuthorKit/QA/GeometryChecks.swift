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

/// Geometry-level checks: unit sanity and no-op edit detection.
public enum GeometryChecks {
    public static let minimumHeightMetres: Double = 0.5
    public static let maximumHeightMetres: Double = 3.0

    /// Node translations are folded in along the parent chain (rotation and
    /// scale are ignored); the avatar's vertical extent must read as metres.
    public static func scale(_ d: VRMDocument) -> QACheck {
        var lo = SIMD3<Double>(repeating: .infinity)
        var hi = SIMD3<Double>(repeating: -.infinity)
        var parents: [Int: Int] = [:]
        for (index, node) in d.nodes.enumerated() {
            for child in node["children"]?.array ?? [] { if let c = child.int { parents[c] = index } }
        }
        func worldOffset(_ node: Int) -> SIMD3<Double> {
            var offset = SIMD3<Double>.zero
            var cursor: Int? = node
            var guardCount = 0
            while let n = cursor, guardCount < d.nodes.count {
                if let t = d.nodes[n]["translation"]?.array, t.count == 3 {
                    offset += SIMD3(t[0].number ?? 0, t[1].number ?? 0, t[2].number ?? 0)
                }
                cursor = parents[n]
                guardCount += 1
            }
            return offset
        }
        var vertices = 0
        for (index, node) in d.nodes.enumerated() {
            guard let mesh = node["mesh"]?.int, mesh >= 0, mesh < d.meshes.count else { continue }
            let offset = node["skin"] == nil ? worldOffset(index) : .zero
            for primitive in d.meshes[mesh]["primitives"]?.array ?? [] {
                guard let accessor = primitive["attributes"]?["POSITION"]?.int, let values = d.floats(accessor: accessor) else { continue }
                var i = 0
                while i + 2 < values.count {
                    let p = SIMD3(Double(values[i]), Double(values[i + 1]), Double(values[i + 2])) + offset
                    lo = pointwiseMin(lo, p)
                    hi = pointwiseMax(hi, p)
                    i += 3
                    vertices += 1
                }
            }
        }
        guard vertices > 0 else {
            return QACheck(scenario: SpecValidator.scenarioStructure, id: "spec.scale", status: .fail, message: "No mesh vertices found.", code: "SCALE_INVALID")
        }
        let height = hi.y - lo.y
        let message = String(format: "Vertical extent %.3f m (y %.3f to %.3f) over %d vertices.", height, lo.y, hi.y, vertices)
        if height < minimumHeightMetres || height > maximumHeightMetres || !height.isFinite {
            return QACheck(scenario: SpecValidator.scenarioStructure, id: "spec.scale", status: .fail,
                           message: message + String(format: " Expected %.1f–%.1f m; check that the export is in metres.", minimumHeightMetres, maximumHeightMetres), code: "SCALE_INVALID")
        }
        return QACheck(scenario: SpecValidator.scenarioStructure, id: "spec.scale", status: .pass, message: message)
    }

    /// Concatenated bytes of every POSITION and morph POSITION accessor in mesh order.
    public static func geometryBytes(_ d: VRMDocument) -> Data {
        var out = Data()
        for mesh in d.meshes {
            for primitive in mesh["primitives"]?.array ?? [] {
                if let accessor = primitive["attributes"]?["POSITION"]?.int, let bytes = d.bytes(accessor: accessor) { out.append(bytes) }
                for target in primitive["targets"]?.array ?? [] {
                    if let accessor = target["POSITION"]?.int, let bytes = d.bytes(accessor: accessor) { out.append(bytes) }
                }
            }
        }
        return out
    }

    /// An edit that claims to change geometry inputs but leaves every vertex
    /// and morph delta byte-identical to the baseline is a no-op edit.
    public static func noOpEdit(baseline: VRMDocument, candidate: VRMDocument, geometryInputsChanged: Bool) -> QACheck {
        let same = geometryBytes(baseline) == geometryBytes(candidate)
        if same, geometryInputsChanged {
            return QACheck(scenario: SpecValidator.scenarioStructure, id: "spec.identityEdit", status: .fail,
                           message: "Geometry inputs changed since the baseline build \(baseline.sha256.prefix(12)) but no vertex or morph delta moved.", code: AuthorErrorCode.noOpEdit.rawValue)
        }
        if same {
            return QACheck(scenario: SpecValidator.scenarioStructure, id: "spec.identityEdit", status: .pass, message: "Geometry is unchanged and no geometry input changed.")
        }
        return QACheck(scenario: SpecValidator.scenarioStructure, id: "spec.identityEdit", status: .pass, message: "Geometry differs from the baseline build.")
    }
}
