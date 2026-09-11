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
@testable import VRMAuthorKit

/// Cylinder-limbed body plus a sphere head, with named regions and a rig whose
/// world transforms are pure translations. Limbs stop short of the torso so
/// open cylinder ends never sit inside another part; the thigh gap is 32 mm so
/// a bottom garment at layer 8 / fit +1 (36 mm offset) penetrates the opposite
/// thigh while defaults clear comfortably.
struct SyntheticHost: WearableHost {
    static let headCentreValue = SIMD3<Float>(0, 1.50, 0)
    static let headRadiusValue: Float = 0.09
    static let eyeHeight: Float = 1.52
    static let eyeForward: Float = 0.075
    static let eyeSpacing: Float = 0.03
    static let torsoRadius: Float = 0.13
    static let armRadius: Float = 0.04
    static let thighX: Float = 0.071
    static let legRadius: Float = 0.055
    static let segments = 24

    let headNodeId = "node:head"
    let neckNodeId = "node:neck"
    let chestNodeId = "node:chest"
    let hipsNodeId = "node:hips"
    let leftEarNodeId = "node:earL"
    let rightEarNodeId = "node:earR"

    var scalpSamples: [ScalpSample] = []
    var bodyPositions: [SIMD3<Float>] = []
    var bodyNormals: [SIMD3<Float>] = []
    var bodyUV0: [SIMD2<Float>] = []
    var bodyJoints: [SIMD4<UInt16>] = []
    var bodyWeights: [SIMD4<Float>] = []
    var bodyTriangles: [UInt32] = []
    var bodySkin: CompiledSkin
    var regions: [String: [Int]] = [:]
    var worlds: [String: SIMD3<Float>] = [:]
    var nodes: [CompiledNode] = []

    let headCentre = SyntheticHost.headCentreValue
    let headRadius = SyntheticHost.headRadiusValue
    let leftEyeCentre = SIMD3<Float>(SyntheticHost.eyeSpacing, SyntheticHost.eyeHeight, SyntheticHost.eyeForward)
    let rightEyeCentre = SIMD3<Float>(-SyntheticHost.eyeSpacing, SyntheticHost.eyeHeight, SyntheticHost.eyeForward)

    func region(_ name: String) -> [Int] { regions[name] ?? [] }

    func worldMatrix(ofNode id: String) -> SIMD16<Float>? {
        guard let t = worlds[id] else { return nil }
        return SIMD16(1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, t.x, t.y, t.z, 1)
    }

    static let jointOrder = ["node:hips", "node:chest", "node:neck", "node:head", "node:upperArmL", "node:forearmL", "node:upperArmR", "node:forearmR",
                             "node:thighL", "node:shinL", "node:footL", "node:thighR", "node:shinR", "node:footR"]

    init() {
        let rig: [(String, String?, SIMD3<Float>)] = [
            ("node:hips", nil, SIMD3(0, 0.90, 0)),
            ("node:chest", "node:hips", SIMD3(0, 1.20, 0)),
            ("node:neck", "node:chest", SIMD3(0, 1.40, 0)),
            ("node:head", "node:neck", SIMD3(0, 1.45, 0)),
            ("node:earL", "node:head", SIMD3(0.09, 1.50, 0)),
            ("node:earR", "node:head", SIMD3(-0.09, 1.50, 0)),
            ("node:upperArmL", "node:chest", SIMD3(0.20, 1.35, 0)),
            ("node:forearmL", "node:upperArmL", SIMD3(0.36, 1.35, 0)),
            ("node:upperArmR", "node:chest", SIMD3(-0.20, 1.35, 0)),
            ("node:forearmR", "node:upperArmR", SIMD3(-0.36, 1.35, 0)),
            ("node:thighL", "node:hips", SIMD3(SyntheticHost.thighX, 0.85, 0)),
            ("node:shinL", "node:thighL", SIMD3(SyntheticHost.thighX, 0.45, 0)),
            ("node:footL", "node:shinL", SIMD3(SyntheticHost.thighX, 0.05, 0)),
            ("node:thighR", "node:hips", SIMD3(-SyntheticHost.thighX, 0.85, 0)),
            ("node:shinR", "node:thighR", SIMD3(-SyntheticHost.thighX, 0.45, 0)),
            ("node:footR", "node:shinR", SIMD3(-SyntheticHost.thighX, 0.05, 0)),
        ]
        var parentWorld: [String: SIMD3<Float>] = [:]
        for (id, parent, world) in rig {
            worlds[id] = world
            let local = parent.flatMap { parentWorld[$0] }.map { world - $0 } ?? world
            nodes.append(CompiledNode(id: id, name: id, parentId: parent, translation: local))
            parentWorld[id] = world
        }
        bodySkin = CompiledSkin(id: "skin:body", jointNodeIds: SyntheticHost.jointOrder, inverseBindMatrices: SyntheticHost.jointOrder.map { id in
            let t = parentWorld[id]!
            return SIMD16(1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, -t.x, -t.y, -t.z, 1)
        })

        addCylinder(axis: SIMD3(0, 1, 0), radius: SyntheticHost.torsoRadius, centre: SIMD3(0, 0, 0), from: 0.85, to: 1.40, ringStep: 0.05) { y in
            switch y {
            case ..<0.925: return ("hips", "node:hips")
            case ..<1.025: return ("waist", "node:hips")
            case ..<1.175: return ("torso", "node:chest")
            default: return ("chest", "node:chest")
            }
        }
        for side: Float in [1, -1] {
            let s = side > 0 ? "L" : "R"
            addCylinder(axis: SIMD3(side, 0, 0), radius: SyntheticHost.armRadius, centre: SIMD3(0, 1.35, 0), from: 0.20, to: 0.60, ringStep: 0.04) { x in
                x < 0.35 ? ("upperArm\(s)", "node:upperArm\(s)") : ("forearm\(s)", "node:forearm\(s)")
            }
            addCylinder(axis: SIMD3(0, 1, 0), radius: SyntheticHost.legRadius, centre: SIMD3(side * SyntheticHost.thighX, 0, 0), from: 0.0, to: 0.80, ringStep: 0.05) { y in
                switch y {
                case ..<0.075: return ("foot\(s)", "node:foot\(s)")
                case ..<0.425: return ("shin\(s)", "node:shin\(s)")
                default: return ("thigh\(s)", "node:thigh\(s)")
                }
            }
        }
        addHeadSphere(stacks: 16, slices: 24)
        scalpSamples = SyntheticHost.fibonacciScalp(count: 300, centre: headCentre, radius: headRadius, minElevationDeg: 12)
    }

    private mutating func addVertex(_ p: SIMD3<Float>, _ n: SIMD3<Float>, uv: SIMD2<Float>, region: String, joint: String) -> UInt32 {
        bodyPositions.append(p)
        bodyNormals.append(n)
        bodyUV0.append(uv)
        bodyJoints.append(SIMD4(UInt16(SyntheticHost.jointOrder.firstIndex(of: joint)!), 0, 0, 0))
        bodyWeights.append(SIMD4(1, 0, 0, 0))
        let index = bodyPositions.count - 1
        regions[region, default: []].append(index)
        return UInt32(index)
    }

    /// Open cylinder along `axis` through `centre`, parameterised by the axial
    /// coordinate; `classify` maps that coordinate to (region, joint).
    private mutating func addCylinder(axis: SIMD3<Float>, radius: Float, centre: SIMD3<Float>, from a: Float, to b: Float, ringStep: Float,
                                      classify: (Float) -> (String, String)) {
        let ringCount = Int(((b - a) / ringStep).rounded()) + 1
        let u = abs(axis.y) > 0.5 ? SIMD3<Float>(1, 0, 0) : SIMD3<Float>(0, 1, 0)
        let v = V3.cross(axis, u)
        var rings: [[UInt32]] = []
        for r in 0..<ringCount {
            let t = a + (b - a) * Float(r) / Float(ringCount - 1)
            let (region, joint) = classify(t)
            var ring: [UInt32] = []
            for k in 0..<SyntheticHost.segments {
                let ang = 2 * Float.pi * Float(k) / Float(SyntheticHost.segments)
                let n = u * cos(ang) + v * sin(ang)
                let p = centre + axis * t + n * radius
                ring.append(addVertex(p, n, uv: SIMD2(Float(k) / Float(SyntheticHost.segments), Float(r) / Float(ringCount - 1)), region: region, joint: joint))
            }
            rings.append(ring)
        }
        for r in 0..<(ringCount - 1) {
            for k in 0..<SyntheticHost.segments {
                let k1 = (k + 1) % SyntheticHost.segments
                bodyTriangles += [rings[r][k], rings[r][k1], rings[r + 1][k1]]
                bodyTriangles += [rings[r][k], rings[r + 1][k1], rings[r + 1][k]]
            }
        }
    }

    private mutating func addHeadSphere(stacks: Int, slices: Int) {
        let c = headCentre, r = headRadius
        func classify(_ n: SIMD3<Float>) -> String {
            let y = n.y, z = n.z, x = n.x
            if y > 0.25 { return "scalp" }
            if z > 0.6, y >= -0.05, y <= 0.6 { return "forehead" }
            if abs(z) < 0.25, abs(y) < 0.25 { return x > 0 ? "earL" : "earR" }
            return "face"
        }
        let top = addVertex(c + SIMD3(0, r, 0), SIMD3(0, 1, 0), uv: SIMD2(0.5, 0), region: "scalp", joint: "node:head")
        var rings: [[UInt32]] = []
        for s in 1..<stacks {
            let phi = Float.pi * Float(s) / Float(stacks)
            var ring: [UInt32] = []
            for k in 0..<slices {
                let theta = 2 * Float.pi * Float(k) / Float(slices)
                let n = SIMD3<Float>(sin(phi) * sin(theta), cos(phi), sin(phi) * cos(theta))
                ring.append(addVertex(c + n * r, n, uv: SIMD2(Float(k) / Float(slices), Float(s) / Float(stacks)), region: classify(n), joint: "node:head"))
            }
            rings.append(ring)
        }
        let bottom = addVertex(c - SIMD3(0, r, 0), SIMD3(0, -1, 0), uv: SIMD2(0.5, 1), region: "face", joint: "node:head")
        for k in 0..<slices {
            let k1 = (k + 1) % slices
            bodyTriangles += [top, rings[0][k], rings[0][k1]]
            bodyTriangles += [bottom, rings[rings.count - 1][k1], rings[rings.count - 1][k]]
        }
        for s in 0..<(rings.count - 1) {
            for k in 0..<slices {
                let k1 = (k + 1) % slices
                bodyTriangles += [rings[s][k], rings[s + 1][k], rings[s + 1][k1]]
                bodyTriangles += [rings[s][k], rings[s + 1][k1], rings[s][k1]]
            }
        }
    }

    static func fibonacciScalp(count: Int, centre: SIMD3<Float>, radius: Float, minElevationDeg: Float) -> [ScalpSample] {
        var samples: [ScalpSample] = []
        let golden = Float.pi * (3 - Float(5).squareRoot())
        let minY = sin(minElevationDeg * .pi / 180)
        let total = Int(Float(count) / ((1 - minY) / 2))
        for i in 0..<total {
            let y = 1 - 2 * (Float(i) + 0.5) / Float(total)
            guard y >= minY else { continue }
            let rr = (1 - y * y).squareRoot()
            let theta = golden * Float(i)
            let n = SIMD3<Float>(rr * sin(theta), y, rr * cos(theta))
            samples.append(ScalpSample(position: centre + n * radius, normal: n))
        }
        return samples
    }

    /// Distance from `p` to the analytic face model the host exposes.
    func faceClearance(_ p: SIMD3<Float>) -> Float {
        let head = V3.distance(p, headCentre) - headRadius
        let eyes = min(V3.distance(p, leftEyeCentre), V3.distance(p, rightEyeCentre)) - HairBobV1.Layout.eyeRadiusM
        return min(head, eyes)
    }
}

enum Fixtures {
    static let hairTexture = HairTexture(baseColour: Colour(rgba: [0.3, 0.2, 0.1, 1]), rootColour: Colour(rgba: [0.2, 0.1, 0.05, 1]), tipColour: Colour(rgba: [0.5, 0.35, 0.2, 1]))

    static func hair(_ id: String = "bob", controls: HairControls = HairControls()) -> HairItem {
        HairItem(id: id, preset: "bob-v1", controls: controls, texture: hairTexture)
    }

    static let materials: [String: MaterialRole] = ["material:hairA": .hair, "material:shirt": .cloth, "material:pants": .cloth, "material:shoes": .cloth,
                                                    "material:frame": .accessory, "material:lens": .accessory, "material:gold": .accessory]

    static func top(_ id: String = "shirt", layer: Int = 0, length: Double = 0, fit: Double = 0, enabled: Bool = true) -> OutfitItem {
        OutfitItem(id: id, preset: "top-v1", enabled: enabled, layer: layer, controls: OutfitControls(length: length, fit: fit), materialIds: ["material:shirt"])
    }

    static func bottom(_ id: String = "pants", layer: Int = 0, length: Double = 0, fit: Double = 0) -> OutfitItem {
        OutfitItem(id: id, preset: "bottom-v1", layer: layer, controls: OutfitControls(length: length, fit: fit), materialIds: ["material:pants"])
    }

    static func footwear(_ id: String = "shoes", layer: Int = 0, fit: Double = 0) -> OutfitItem {
        OutfitItem(id: id, preset: "footwear-v1", layer: layer, controls: OutfitControls(length: 0, fit: fit), materialIds: ["material:shoes"])
    }

    static func glasses(_ id: String = "specs", transform: Transform = .identity) -> AccessoryItem {
        AccessoryItem(id: id, preset: .glassesV1, attachment: "node:head", transform: transform, materialIds: ["material:frame", "material:lens"])
    }

    static func earring(_ id: String, attachment: String) -> AccessoryItem {
        AccessoryItem(id: id, preset: .earringV1, attachment: attachment, materialIds: ["material:gold"])
    }
}
