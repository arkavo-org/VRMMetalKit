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

public enum OutfitKind: String, Codable, Hashable, Sendable, CaseIterable { case top, bottom, footwear }

/// What an installed outfit preset declares: the body regions it shells, the
/// regions `length` can extend into or contract, the regions it hides, its
/// permitted layers and the control keys it honours.
public struct OutfitPresetDescriptor: Codable, Hashable, Sendable {
    public var id: String
    public var kind: OutfitKind
    public var coreRegions: [String]
    public var distalCoreRegions: [String]
    public var extensionRegions: [String]
    public var hiddenRegions: [String]
    public var permittedLayers: [Int]
    public var supportedControls: [String]

    public init(id: String, kind: OutfitKind, coreRegions: [String], distalCoreRegions: [String], extensionRegions: [String], hiddenRegions: [String],
                permittedLayers: [Int], supportedControls: [String]) {
        self.id = id
        self.kind = kind
        self.coreRegions = coreRegions
        self.distalCoreRegions = distalCoreRegions
        self.extensionRegions = extensionRegions
        self.hiddenRegions = hiddenRegions
        self.permittedLayers = permittedLayers
        self.supportedControls = supportedControls
    }
}

/// Offset-shell garments over host body regions.
public enum OutfitPresets {
    public static let baseClearanceM = 0.008
    public static let layerStepM = 0.003
    public static let fitStepM = 0.004
    public static let minClearanceM = 0.002
    public static let contractionRatio = 0.5

    public static let topV1 = OutfitPresetDescriptor(
        id: "top-v1", kind: .top,
        coreRegions: [WearableRegion.chest, WearableRegion.torso, WearableRegion.upperArmL, WearableRegion.upperArmR],
        distalCoreRegions: [WearableRegion.upperArmL, WearableRegion.upperArmR],
        extensionRegions: [WearableRegion.forearmL, WearableRegion.forearmR],
        hiddenRegions: [WearableRegion.chest, WearableRegion.torso, WearableRegion.upperArmL, WearableRegion.upperArmR],
        permittedLayers: Array(0...8), supportedControls: ["length", "fit"])

    public static let bottomV1 = OutfitPresetDescriptor(
        id: "bottom-v1", kind: .bottom,
        coreRegions: [WearableRegion.waist, WearableRegion.hips, WearableRegion.thighL, WearableRegion.thighR],
        distalCoreRegions: [WearableRegion.thighL, WearableRegion.thighR],
        extensionRegions: [WearableRegion.shinL, WearableRegion.shinR],
        hiddenRegions: [WearableRegion.waist, WearableRegion.hips, WearableRegion.thighL, WearableRegion.thighR],
        permittedLayers: Array(0...8), supportedControls: ["length", "fit"])

    public static let footwearV1 = OutfitPresetDescriptor(
        id: "footwear-v1", kind: .footwear,
        coreRegions: [WearableRegion.footL, WearableRegion.footR],
        distalCoreRegions: [], extensionRegions: [],
        hiddenRegions: [WearableRegion.footL, WearableRegion.footR],
        permittedLayers: [0, 1, 2], supportedControls: ["fit"])

    public static let all = [topV1, bottomV1, footwearV1]

    public static func descriptor(_ id: String) -> OutfitPresetDescriptor? { all.first { $0.id == id } }

    public static var permittedLayers: [String: [Int]] {
        var table: [String: [Int]] = [:]
        for d in all { table[d.id] = d.permittedLayers }
        return table
    }

    public static func offset(layer: Int, fit: Double) -> Double { baseClearanceM + layerStepM * Double(layer) + fitStepM * fit }

    /// Unknown presets, layers outside a preset's permitted set and two enabled
    /// garments of the same kind on the same layer are conflicts.
    public static func checkLayerCombination(_ outfits: [OutfitItem]) throws {
        var occupied: [String: String] = [:]
        for item in CompiledAvatar.sortedById(outfits.filter(\.enabled), \.id) {
            let objectId = "garment:\(item.id)"
            guard let d = descriptor(item.preset) else {
                throw AuthorError(code: .invalidRequest, objectId: objectId, path: "/preset", observed: .string(item.preset),
                                  required: .array(all.map { .string($0.id) }), message: "Unknown outfit preset '\(item.preset)'.",
                                  suggestedCommands: ["describe", "schema show OutfitItem"])
            }
            guard d.permittedLayers.contains(item.layer) else {
                throw AuthorError(code: .outfitLayerConflict, objectId: objectId, path: "/layer", observed: .number(Double(item.layer)),
                                  required: .array(d.permittedLayers.map { .number(Double($0)) }),
                                  message: "\(d.id) does not support layer \(item.layer); permitted layers are \(d.permittedLayers).",
                                  suggestedCommands: ["object set", "recipe apply"])
            }
            let key = "\(d.kind.rawValue)@\(item.layer)"
            if let other = occupied[key] {
                throw AuthorError(code: .outfitLayerConflict, objectId: objectId, path: "/layer", observed: .number(Double(item.layer)),
                                  message: "Garments '\(other)' and '\(item.id)' are both \(d.kind.rawValue) presets on layer \(item.layer); one \(d.kind.rawValue) per layer.",
                                  suggestedCommands: ["object set", "recipe apply"])
            }
            occupied[key] = item.id
        }
    }

    struct Build {
        var mesh: CompiledMesh
        var meshNode: CompiledNode
        var meshInstance: CompiledMeshInstance
        var info: GarmentInfo
        var warnings: [AuthorWarning]
    }

    static func limbAxis(region: String, indices: [Int], host: WearableHost) -> SIMD3<Float> {
        guard region.hasPrefix("upperArm") || region.hasPrefix("forearm") else { return SIMD3(0, -1, 0) }
        var mean: Float = 0
        for i in indices where i < host.bodyPositions.count { mean += host.bodyPositions[i].x }
        return SIMD3(mean >= 0 ? 1 : -1, 0, 0)
    }

    /// Normalised position of each region vertex along the region's limb axis.
    static func axialParams(region: String, indices: [Int], host: WearableHost) -> [Int: Float] {
        let axis = limbAxis(region: region, indices: indices, host: host)
        var projections: [(Int, Float)] = []
        var lo: Float = .infinity, hi: Float = -.infinity
        for i in indices where i < host.bodyPositions.count {
            let p = V3.dot(host.bodyPositions[i], axis)
            projections.append((i, p))
            lo = min(lo, p)
            hi = max(hi, p)
        }
        let span = hi - lo
        var out: [Int: Float] = [:]
        for (i, p) in projections { out[i] = span > 1e-6 ? (p - lo) / span : 0 }
        return out
    }

    static func build(item: OutfitItem, host: WearableHost, materialId: String, regionOfVertex: [Int: String]) throws -> Build {
        let objectId = "garment:\(item.id)"
        guard let d = descriptor(item.preset) else {
            throw AuthorError(code: .invalidRequest, objectId: objectId, path: "/preset", observed: .string(item.preset), message: "Unknown outfit preset '\(item.preset)'.",
                              suggestedCommands: ["describe"])
        }
        var warnings: [AuthorWarning] = []
        let length = d.supportedControls.contains("length") ? item.controls.length : 0
        if !d.supportedControls.contains("length"), item.controls.length != 0 {
            warnings.append(AuthorWarning(code: "CONTROL_UNSUPPORTED", message: "\(d.id) exposes fit only; length \(item.controls.length) on '\(item.id)' is ignored.",
                                          path: "/controls/length"))
        }

        var covered = Set<Int>()
        var coveredRegions: [String] = []
        for region in d.coreRegions {
            let indices = host.region(region)
            guard !indices.isEmpty else {
                throw AuthorError(code: .hostRegionMissing, objectId: objectId, path: "/preset", observed: .string(region),
                                  message: "\(d.id) needs host body region '\(region)', which the template does not expose.", suggestedCommands: ["doctor", "build"])
            }
            coveredRegions.append(region)
            if length < 0, d.distalCoreRegions.contains(region) {
                let params = axialParams(region: region, indices: indices, host: host)
                let keep = Float(1 - contractionRatio * abs(length))
                for i in indices where (params[i] ?? 0) <= keep + 1e-6 { covered.insert(i) }
            } else {
                for i in indices { covered.insert(i) }
            }
        }
        if length > 0 {
            for region in d.extensionRegions {
                let indices = host.region(region)
                guard !indices.isEmpty else { continue }
                let params = axialParams(region: region, indices: indices, host: host)
                var added = false
                for i in indices where (params[i] ?? 1) <= Float(length) + 1e-6 {
                    covered.insert(i)
                    added = true
                }
                if added { coveredRegions.append(region) }
            }
        }

        let offset = Float(offset(layer: item.layer, fit: item.controls.fit))
        let ordered = covered.sorted()
        var remap: [Int: UInt32] = [:]
        var builder = MeshBuilder()
        for i in ordered {
            guard i < host.bodyPositions.count, i < host.bodyNormals.count, i < host.bodyJoints.count, i < host.bodyWeights.count else { continue }
            let n = V3.normalize(host.bodyNormals[i])
            let uv = i < host.bodyUV0.count ? host.bodyUV0[i] : SIMD2<Float>(0, 0)
            remap[i] = builder.addVertex(host.bodyPositions[i] + n * offset, normal: n, uv: uv, joints: host.bodyJoints[i], weights: host.bodyWeights[i])
        }
        var t = 0
        while t + 2 < host.bodyTriangles.count {
            let a = Int(host.bodyTriangles[t]), b = Int(host.bodyTriangles[t + 1]), c = Int(host.bodyTriangles[t + 2])
            t += 3
            if let ra = remap[a], let rb = remap[b], let rc = remap[c] { builder.addTriangle(ra, rb, rc) }
        }
        guard !builder.indices.isEmpty else {
            throw AuthorError(code: .meshInvalid, objectId: objectId, path: "/controls/length", observed: .number(length),
                              message: "\(d.id) '\(item.id)' covers no complete body triangles with the requested length.", suggestedCommands: ["control set"])
        }

        let minClearance = try clearance(builder: builder, host: host, item: item, descriptor: d, regionOfVertex: regionOfVertex)

        let meshId = "mesh:garment:\(item.id)"
        let nodeId = "node:garment:\(item.id)"
        let mesh = CompiledMesh(id: meshId, name: "Garment_\(item.id)", primitives: [builder.primitive(materialId: materialId, skinned: true)])
        let info = GarmentInfo(id: item.id, preset: d.id, meshId: meshId, layer: item.layer, offsetM: Double(offset), minClearanceM: Double(minClearance),
                               coveredRegions: coveredRegions, hiddenRegions: d.hiddenRegions)
        return Build(mesh: mesh, meshNode: CompiledNode(id: nodeId, name: "Garment_\(item.id)"),
                     meshInstance: CompiledMeshInstance(nodeId: nodeId, meshId: meshId, skinId: host.bodySkin.id), info: info, warnings: warnings)
    }

    /// Minimum signed distance from any garment vertex to the nearest body
    /// surface; below `minClearanceM` is a penetration.
    static func clearance(builder: MeshBuilder, host: WearableHost, item: OutfitItem, descriptor d: OutfitPresetDescriptor, regionOfVertex: [Int: String]) throws -> Float {
        var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
        for p in builder.positions {
            lo = pointwiseMin(lo, p)
            hi = pointwiseMax(hi, p)
        }
        let pad: Float = 0.05
        lo -= SIMD3(repeating: pad)
        hi += SIMD3(repeating: pad)
        let positions = host.bodyPositions
        func inside(_ i: Int) -> Bool {
            let p = positions[i]
            return p.x >= lo.x && p.x <= hi.x && p.y >= lo.y && p.y <= hi.y && p.z >= lo.z && p.z <= hi.z
        }
        let probe = SurfaceProbe(positions: positions, normals: host.bodyNormals, indices: host.bodyTriangles) { a, b, c in inside(a) || inside(b) || inside(c) }
        var worst: Float = .infinity
        var worstHit: SurfaceProbe.Hit?
        for p in builder.positions {
            guard let hit = probe.nearest(to: p) else { continue }
            if hit.distance < worst {
                worst = hit.distance
                worstHit = hit
            }
        }
        guard worst.isFinite else { return .infinity }
        if worst < Float(minClearanceM) {
            var region = "body"
            if let hit = worstHit {
                let tri = probe.triangles[hit.triangle]
                let nearestVertex = [tri.x, tri.y, tri.z].min { V3.distance(positions[$0], hit.closest) < V3.distance(positions[$1], hit.closest) }
                region = nearestVertex.flatMap { regionOfVertex[$0] } ?? region
            }
            let observed = (Double(worst) * 10000).rounded() / 10000
            throw AuthorError(code: .garmentPenetration, objectId: "garment:\(item.id)", path: "/fit/minClearanceM", observed: .number(observed),
                              required: .number(minClearanceM),
                              message: "\(d.id) '\(item.id)' on layer \(item.layer) penetrates the body near \(region) at rest (minimum clearance \(observed) m).",
                              suggestedCommands: ["control set", "recipe apply", "qa run"])
        }
        return worst
    }
}
