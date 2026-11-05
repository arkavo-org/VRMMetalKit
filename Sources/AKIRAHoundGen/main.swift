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
import GLTFCore

enum HoundGenError: Error, LocalizedError {
    case validationFailed(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .validationFailed(let detail): return "Validation failed: \(detail)"
        case .writeFailed(let detail): return "Write failed: \(detail)"
        }
    }
}

// MARK: - Validation

/// Composes a node's local TRS into a matrix (TRS only — the generator never
/// emits `matrix`).
func localMatrix(_ node: GLTFNode) -> simd_float4x4 {
    let t = node.translation ?? [0, 0, 0]
    let r = node.rotation ?? [0, 0, 0, 1]
    let s = node.scale ?? [1, 1, 1]
    let translation = simd_float4x4(columns: (
        SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(t[0], t[1], t[2], 1)
    ))
    let rotation = simd_float4x4(simd_quatf(ix: r[0], iy: r[1], iz: r[2], r: r[3]))
    let scale = simd_float4x4(diagonal: SIMD4(s[0], s[1], s[2], 1))
    return translation * rotation * scale
}

/// Re-parses the emitted GLB and asserts structure, hierarchy, and bounds.
func validate(data: Data, filePath: String, expectedVertices: Int, expectedTriangles: Int) throws {
    let parser = GLTFParser()
    let (document, binaryData) = try parser.parse(data: data, filePath: filePath)

    guard let nodes = document.nodes else { throw HoundGenError.validationFailed("no nodes") }
    guard let meshes = document.meshes else { throw HoundGenError.validationFailed("no meshes") }
    guard let accessors = document.accessors else { throw HoundGenError.validationFailed("no accessors") }
    guard binaryData != nil else { throw HoundGenError.validationFailed("no BIN chunk") }

    var indexByName: [String: Int] = [:]
    for (i, node) in nodes.enumerated() {
        if let name = node.name { indexByName[name] = i }
    }
    func nodeIndex(_ name: String) throws -> Int {
        guard let i = indexByName[name] else { throw HoundGenError.validationFailed("missing node '\(name)'") }
        return i
    }
    func childNames(_ name: String) throws -> Set<String> {
        let node = nodes[try nodeIndex(name)]
        var names = Set<String>()
        for child in node.children ?? [] {
            if let childName = nodes[child].name { names.insert(childName) }
        }
        return names
    }

    // 1. Expected node names.
    var expectedNames = ["HOUND_Root", "Body", "Chassis", "Nose_Cowl", "Headlight",
                         "Cowl_Slit_L", "Cowl_Slit_R", "Spine_Fairing", "Seat_Pan",
                         "Strip_Flank_L", "Strip_Flank_R", "Tail_Bar", "Seat_Mount"]
    for prefix in ["FL", "FR", "RL", "RR"] {
        for part in ["Hip", "Upper", "Knee", "KneeStrip", "Lower", "Ankle", "Paw", "Wheel", "FootPad"] {
            expectedNames.append("Leg_\(prefix)_\(part)")
        }
    }
    for name in expectedNames { _ = try nodeIndex(name) }

    // 2. Hierarchy.
    guard try childNames("HOUND_Root") == ["Body"] else {
        throw HoundGenError.validationFailed("HOUND_Root must have exactly one child: Body")
    }
    let bodyChildren = try childNames("Body")
    for name in ["Chassis", "Nose_Cowl", "Headlight", "Cowl_Slit_L", "Cowl_Slit_R",
                 "Spine_Fairing", "Seat_Pan", "Strip_Flank_L",
                 "Strip_Flank_R", "Tail_Bar", "Seat_Mount",
                 "Leg_FL_Hip", "Leg_FR_Hip", "Leg_RL_Hip", "Leg_RR_Hip"] where !bodyChildren.contains(name) {
        throw HoundGenError.validationFailed("Body is missing child '\(name)'")
    }
    for prefix in ["FL", "FR", "RL", "RR"] {
        let hip = try childNames("Leg_\(prefix)_Hip")
        guard hip.contains("Leg_\(prefix)_Upper"), hip.contains("Leg_\(prefix)_Knee") else {
            throw HoundGenError.validationFailed("Leg_\(prefix)_Hip children wrong: \(hip)")
        }
        let knee = try childNames("Leg_\(prefix)_Knee")
        guard knee.contains("Leg_\(prefix)_KneeStrip"), knee.contains("Leg_\(prefix)_Lower"),
              knee.contains("Leg_\(prefix)_Ankle"), knee.contains("Leg_\(prefix)_Wheel") else {
            throw HoundGenError.validationFailed("Leg_\(prefix)_Knee children wrong: \(knee)")
        }
        guard try childNames("Leg_\(prefix)_Ankle").contains("Leg_\(prefix)_Paw") else {
            throw HoundGenError.validationFailed("Leg_\(prefix)_Ankle missing Paw")
        }
        guard try childNames("Leg_\(prefix)_Paw") == ["Leg_\(prefix)_FootPad"] else {
            throw HoundGenError.validationFailed("Leg_\(prefix)_Paw must have exactly one child: FootPad")
        }

        // Rest-pose contract: the wheel rides at the knee, so cumulative
        // hip × knee × wheel rotation is identity (wheel frame body-axis-
        // aligned → clean local-X wheel roll with no wobble).
        func rotation(_ name: String) throws -> [Float] { nodes[try nodeIndex(name)].rotation ?? [0, 0, 0, 1] }
        var q = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        for joint in ["Hip", "Knee", "Wheel"] {
            let r = try rotation("Leg_\(prefix)_\(joint)")
            q = q * simd_quatf(ix: r[0], iy: r[1], iz: r[2], r: r[3])
        }
        let identityError = simd_length(q.vector - SIMD4<Float>(0, 0, 0, 1))
        guard identityError < 1e-5 else {
            throw HoundGenError.validationFailed("Leg_\(prefix) wheel cumulative rotation not identity (err \(identityError))")
        }
    }

    // 3. Scene roots and mesh references.
    guard document.scene == 0,
          let sceneNodes = document.scenes?.first?.nodes,
          sceneNodes == [try nodeIndex("HOUND_Root")] else {
        throw HoundGenError.validationFailed("scene 0 roots must be [HOUND_Root]")
    }
    for node in nodes {
        if let mesh = node.mesh {
            guard mesh >= 0, mesh < meshes.count else {
                throw HoundGenError.validationFailed("node '\(node.name ?? "?")' has invalid mesh index \(mesh)")
            }
        }
    }

    // 4. World-space bounds from POSITION accessor min/max corners.
    var worldMin = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
    var worldMax = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
    /// Lowest world-space Y among non-wheel meshes — in the tucked rest pose
    /// only the four wheels may touch the ground plane.
    var nonWheelMinY = Float.greatestFiniteMagnitude
    func walk(_ nodeIndex: Int, parentWorld: simd_float4x4) throws {
        let node = nodes[nodeIndex]
        let world = parentWorld * localMatrix(node)
        let isWheel = node.name?.hasSuffix("_Wheel") ?? false
        if let meshIndex = node.mesh {
            for primitive in meshes[meshIndex].primitives {
                guard let positionAccessor = primitive.attributes["POSITION"] else {
                    throw HoundGenError.validationFailed("primitive without POSITION")
                }
                let accessor = accessors[positionAccessor]
                guard let min = accessor.min, let max = accessor.max, min.count == 3, max.count == 3 else {
                    throw HoundGenError.validationFailed("POSITION accessor \(positionAccessor) missing min/max")
                }
                for cx in [min[0], max[0]] {
                    for cy in [min[1], max[1]] {
                        for cz in [min[2], max[2]] {
                            let w = world * SIMD4(cx, cy, cz, 1)
                            let p = SIMD3(w.x, w.y, w.z)
                            worldMin = simd_min(worldMin, p)
                            worldMax = simd_max(worldMax, p)
                            if !isWheel { nonWheelMinY = Swift.min(nonWheelMinY, p.y) }
                        }
                    }
                }
            }
        }
        for child in node.children ?? [] { try walk(child, parentWorld: world) }
    }
    try walk(try nodeIndex("HOUND_Root"), parentWorld: simd_float4x4(1))

    let extent = worldMax - worldMin
    guard extent.z > 2.8, extent.z < 3.5 else {
        throw HoundGenError.validationFailed(String(format: "length %.2fm out of range", extent.z))
    }
    guard extent.y > 0.9, extent.y < 1.2 else {
        throw HoundGenError.validationFailed(String(format: "height %.2fm out of range", extent.y))
    }
    guard extent.x > 0.5, extent.x < 1.0 else {
        throw HoundGenError.validationFailed(String(format: "width %.2fm out of range", extent.x))
    }
    guard worldMin.y > -0.02, worldMin.y < 0.02 else {
        throw HoundGenError.validationFailed(String(format: "wheels should touch y=0, minY=%.3f", worldMin.y))
    }
    guard nonWheelMinY > 0.005 else {
        throw HoundGenError.validationFailed(String(format: "only wheels may touch the ground, non-wheel minY=%.3f", nonWheelMinY))
    }

    // 5. Summary.
    print("✅ Validation passed")
    print("   Nodes:      \(nodes.count)")
    print("   Meshes:     \(meshes.count)")
    print("   Vertices:   \(expectedVertices)")
    print("   Triangles:  \(expectedTriangles)")
    print(String(format: "   Bounds:     %.2f × %.2f × %.2f m (x × y × z)", extent.x, extent.y, extent.z))
    print("   File size:  \(data.count) bytes")
}

// MARK: - CLI

let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AKIRA_Hound.glb"

do {
    let (container, builder) = buildHoundAsset()
    let glbData = try container.serialize()
    try validate(data: glbData, filePath: outputPath,
                 expectedVertices: builder.totalVertices, expectedTriangles: builder.totalTriangles)
    let url = URL(fileURLWithPath: outputPath)
    do {
        try glbData.write(to: url, options: .atomic)
    } catch {
        throw HoundGenError.writeFailed(error.localizedDescription)
    }
    print("✅ Wrote \(outputPath)")
} catch {
    FileHandle.standardError.write(Data("❌ \(error.localizedDescription)\n".utf8))
    exit(1)
}
