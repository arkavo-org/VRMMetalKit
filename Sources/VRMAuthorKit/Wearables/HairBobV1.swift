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

/// The `bob-v1` hair preset: fixed clump layout around the scalp, tapered
/// ribbons that follow the head then hang under gravity, one spring chain per
/// clump and a head/body collider set.
public enum HairBobV1 {
    public static let presetId = "bob-v1"

    /// Layout constants, fixed by the preset; only `HairControls` vary per recipe.
    public struct LayoutParams: Sendable {
        public var ringAClumps = 24
        public var ringAElevationDeg: Float = 22
        public var ringAAzimuthRangeDeg: ClosedRange<Float> = 52...308
        public var ringBClumps = 9
        public var ringBElevationDeg: Float = 50
        public var bangAzimuthsDeg: [Float] = [-36, -24, -12, 0, 12, 24, 36]
        public var bangElevationDeg: Float = 32
        public var bangSectorDeg: Float = 50
        public var rotatingBones = 3
        public var sectionsPerBone = 4
        public var nodesPerClump: Int { rotatingBones + 1 }
        public var sectionsPerClump: Int { rotatingBones * sectionsPerBone + 1 }
        public var clumpCount: Int { ringAClumps + ringBClumps + bangAzimuthsDeg.count }
        public var baseWidthM: Float = 0.026
        public var tipWidthRatio: Float = 0.4
        public var bangLengthRatio: Float = 0.55
        /// Preset-level guide scale; bob grows lengthM 1x, long-v1 2x.
        public var lengthScale: Float = 1
        public var headClearanceM: Float = 0.006
        public var bangEdgeMarginM: Float = 0.002
        public var sweepAllowanceFactor: Float = 1.1
        public var eyeRadiusM: Float = 0.014
        public var gravityBlend: Float = 0.3
        public var baseTilt: Float = 0.35
        public var tiltStep: Float = 0.15
        public var maxTilt: Float = 4.0
        public var hitRadii: [Double] = [0.012, 0.010, 0.008, 0.006]
        public var stiffness: [Double] = [1.2, 0.9, 0.6, 0.4]
        public var gravityPower: Double = 0.05
        public var dragForce: Double = 0.4
        public var headColliderPaddingM: Float = 0.003
        public var chestColliderFallbackRadiusM: Float = 0.11

        /// The bob: chin-length locks.
        public static let bob = LayoutParams()
        /// Long: lower side roots, finer locks, one more rotating bone, guides
        /// grown 2x.
        public static let long = LayoutParams(ringAElevationDeg: 14, ringBClumps: 10, rotatingBones: 4, baseWidthM: 0.024,
                                              lengthScale: 2, hitRadii: [0.012, 0.010, 0.008, 0.007, 0.006], stiffness: [1.2, 0.9, 0.65, 0.45, 0.35])
    }

    /// The bob's constants, kept for callers that predate preset variants.
    public enum Layout {
        public static var bangAzimuthsDeg: [Float] { LayoutParams.bob.bangAzimuthsDeg }
        public static var bangLengthRatio: Float { LayoutParams.bob.bangLengthRatio }
        public static var clumpCount: Int { LayoutParams.bob.clumpCount }
        public static var eyeRadiusM: Float { LayoutParams.bob.eyeRadiusM }
        public static var headColliderPaddingM: Float { LayoutParams.bob.headColliderPaddingM }
        public static var nodesPerClump: Int { LayoutParams.bob.nodesPerClump }
        public static var sectionsPerBone: Int { LayoutParams.bob.sectionsPerBone }
        public static var sectionsPerClump: Int { LayoutParams.bob.sectionsPerClump }
    }

    public static let headColliderId = "collider:head"
    public static let neckColliderId = "collider:neck"
    public static let chestColliderId = "collider:chest"
    public static let headColliderGroupId = "colliderGroup:head"
    public static let bodyColliderGroupId = "colliderGroup:body"

    struct Build {
        var mesh: CompiledMesh
        var meshNode: CompiledNode
        var nodes: [CompiledNode]
        var skin: CompiledSkin
        var meshInstance: CompiledMeshInstance
        var springs: [SpringObject]
        var clumps: [HairClumpInfo]
        var warnings: [AuthorWarning]
    }

    struct RootTarget {
        var azimuthDeg: Float
        var elevationDeg: Float
        var isBang: Bool
    }

    static func rootTargets(_ P: LayoutParams) -> [RootTarget] {
        var targets: [RootTarget] = []
        let span = P.ringAAzimuthRangeDeg.upperBound - P.ringAAzimuthRangeDeg.lowerBound
        for k in 0..<P.ringAClumps {
            let az = P.ringAAzimuthRangeDeg.lowerBound + span * (Float(k) + 0.5) / Float(P.ringAClumps)
            targets.append(RootTarget(azimuthDeg: az, elevationDeg: P.ringAElevationDeg, isBang: false))
        }
        for k in 0..<P.ringBClumps {
            let az = 360 * (Float(k) + 0.5) / Float(P.ringBClumps)
            let folded = az > 180 ? az - 360 : az
            targets.append(RootTarget(azimuthDeg: az, elevationDeg: P.ringBElevationDeg, isBang: abs(folded) <= P.bangSectorDeg))
        }
        for az in P.bangAzimuthsDeg {
            targets.append(RootTarget(azimuthDeg: az, elevationDeg: P.bangElevationDeg, isBang: true))
        }
        return targets
    }

    static func direction(azimuthDeg: Float, elevationDeg: Float) -> SIMD3<Float> {
        let az = azimuthDeg * .pi / 180, el = elevationDeg * .pi / 180
        return SIMD3(sin(az) * cos(el), sin(el), cos(az) * cos(el))
    }

    /// Head sphere, neck capsule and chest capsule with the two groups every
    /// hair spring references. Authored colliders: discrete push-out only.
    static func colliders(host: WearableHost, P: LayoutParams) throws -> (colliders: [ColliderObject], groups: [ColliderGroupObject]) {
        let headWorld = try host.requireWorld(host.headNodeId)
        let neckWorld = try host.requireWorld(host.neckNodeId)
        let chestWorld = try host.requireWorld(host.chestNodeId)
        let headInv = headWorld.affineInverse()
        let neckInv = neckWorld.affineInverse()
        let chestInv = chestWorld.affineInverse()

        let headSphere = ColliderObject(id: headColliderId, node: host.headNodeId,
                                        shape: ColliderShape(sphere: SphereShape(offset: V3.doubles(headInv.transformPoint(host.headCentre)),
                                                                                 radius: Double(host.headRadius + P.headColliderPaddingM))))
        let neckRadius = Double(host.headRadius * 0.4)
        let neckCapsule = ColliderObject(id: neckColliderId, node: host.neckNodeId,
                                         shape: ColliderShape(capsule: CapsuleShape(offset: [0, 0, 0], radius: neckRadius,
                                                                                    tail: V3.doubles(neckInv.transformPoint(headWorld.translation)))))
        var chestRadius = P.chestColliderFallbackRadiusM
        let chestRegion = host.region(WearableRegion.chest)
        if !chestRegion.isEmpty {
            var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
            for i in chestRegion where i < host.bodyPositions.count {
                lo = pointwiseMin(lo, host.bodyPositions[i])
                hi = pointwiseMax(hi, host.bodyPositions[i])
            }
            let half = (hi - lo) * 0.5
            if half.x.isFinite, half.z.isFinite, min(half.x, half.z) > 0.01 { chestRadius = min(half.x, half.z) }
        }
        let chestCapsule = ColliderObject(id: chestColliderId, node: host.chestNodeId,
                                          shape: ColliderShape(capsule: CapsuleShape(offset: [0, 0, 0], radius: Double(chestRadius),
                                                                                     tail: V3.doubles(chestInv.transformPoint(neckWorld.translation)))))
        let groups = [
            ColliderGroupObject(id: headColliderGroupId, name: "head", colliders: [headColliderId]),
            ColliderGroupObject(id: bodyColliderGroupId, name: "body", colliders: [neckColliderId, chestColliderId]),
        ]
        return ([headSphere, neckCapsule, chestCapsule], groups)
    }

    static func params(for preset: String, objectId: String) -> LayoutParams {
        switch preset {
        case HairBobV1.presetId: return .bob
        case HairLongV1.presetId: return .long
        default: return .bob
        }
    }

    static func build(item: HairItem, host: WearableHost, materialId: String, colliderGroupIds: [String]) throws -> Build {
        guard item.preset == presetId || item.preset == HairLongV1.presetId else {
            throw AuthorError.invalidRequest("Unknown hair preset '\(item.preset)'.", path: "/preset", observed: .string(item.preset), required: .string("\(presetId)|\(HairLongV1.presetId)"))
        }
        let P = params(for: item.preset, objectId: "hair:\(item.id)")
        guard !host.scalpSamples.isEmpty else {
            throw AuthorError(code: .hostRegionMissing, objectId: "hair:\(item.id)", path: "/scalpSamples", observed: .number(0),
                              message: "The host template exposes no scalp samples; bob-v1 needs scalp attachment points.", suggestedCommands: ["build", "doctor"])
        }
        let headWorld = try host.requireWorld(host.headNodeId, objectId: "hair:\(item.id)")
        let headInv = headWorld.affineInverse()
        let controls = item.controls
        let face = faceProbe(host: host)

        var builder = MeshBuilder()
        var nodes: [CompiledNode] = []
        var jointIds: [String] = []
        var ibms: [SIMD16<Float>] = []
        var springs: [SpringObject] = []
        var clumps: [HairClumpInfo] = []
        var used = Set<Int>()

        for (clumpIndex, target) in rootTargets(P).enumerated() {
            let sampleIndex = nearestSample(host: host, target: host.headCentre + direction(azimuthDeg: target.azimuthDeg, elevationDeg: target.elevationDeg) * host.headRadius, used: used)
            used.insert(sampleIndex)
            let sample = host.scalpSamples[sampleIndex]
            let clumpTag = String(format: "c%02d", clumpIndex)
            let clumpId = "hair:\(item.id):\(clumpTag)"
            let nodeIds = (0..<P.nodesPerClump).map { "node:hair:\(item.id):\(clumpTag):j\($0)" }
            let jointBase = UInt16(jointIds.count)

            let strip = try generateClump(sample: sample, isBang: target.isBang, controls: controls, host: host, face: face, clumpId: clumpId, P: P)
            let vertexStart = builder.vertexCount
            let steps = P.sectionsPerClump - 1
            for i in 0..<P.sectionsPerClump {
                let u = Float(i) / Float(steps)
                let boneParam = u * Float(P.rotatingBones)
                let b = min(Int(boneParam.rounded(.down)), P.rotatingBones - 1)
                let f = min(max(boneParam - Float(b), 0), 1)
                let joints = SIMD4<UInt16>(jointBase + UInt16(b), jointBase + UInt16(b + 1), 0, 0)
                let weights = SIMD4<Float>(1 - f, f, 0, 0)
                let h = strip.halfWidths[i]
                let c = strip.centres[i], w = strip.widthDirs[i]
                // The ridge bulges away from the head so it can never reduce
                // face/head clearance below the strip edges' verified sweep.
                var n = strip.normals[i]
                if V3.dot(n, c - host.headCentre) < 0 { n = -n }
                // Arched 3-vertex cross-section: a raised centre ridge reads as
                // a rounded lock instead of a flat ribbon.
                builder.addVertex(c - w * h, normal: V3.normalize(n - w, fallback: n), uv: SIMD2(0, u), joints: joints, weights: weights)
                builder.addVertex(c + n * (h * 0.45), normal: n, uv: SIMD2(0.5, u), joints: joints, weights: weights)
                builder.addVertex(c + w * h, normal: V3.normalize(n + w, fallback: n), uv: SIMD2(1, u), joints: joints, weights: weights)
            }
            for i in 0..<steps {
                let l0 = UInt32(vertexStart + 3 * i), m0 = l0 + 1, r0 = l0 + 2
                let l1 = l0 + 3, m1 = l0 + 4, r1 = l0 + 5
                builder.addTriangle(l0, m0, m1)
                builder.addTriangle(l0, m1, l1)
                builder.addTriangle(m0, r0, r1)
                builder.addTriangle(m0, r1, m1)
            }

            var localCumulative = SIMD3<Float>.zero
            for j in 0..<P.nodesPerClump {
                let section = j * P.sectionsPerBone
                let world = strip.centres[section]
                let local: SIMD3<Float>
                if j == 0 {
                    local = headInv.transformPoint(world)
                } else {
                    local = headInv.transformDirection(world - strip.centres[section - P.sectionsPerBone])
                }
                localCumulative += local
                nodes.append(CompiledNode(id: nodeIds[j], name: "Hair_\(item.id)_\(clumpTag)_j\(j)", parentId: j == 0 ? host.headNodeId : nodeIds[j - 1], translation: local))
                jointIds.append(nodeIds[j])
                ibms.append((headWorld * Mat4(translation: localCumulative)).affineInverse().m)
            }

            let springId = "spring:hair:\(item.id):\(clumpTag)"
            let joints = (0..<P.nodesPerClump).map { j in
                SpringJoint(node: nodeIds[j], hitRadius: P.hitRadii[j], stiffness: P.stiffness[j], gravityPower: P.gravityPower,
                            gravityDir: [0, -1, 0], dragForce: P.dragForce)
            }
            springs.append(SpringObject(id: springId, name: "hair \(item.id) \(clumpTag)", joints: joints, colliderGroups: colliderGroupIds))

            let pivotSection = steps - P.sectionsPerBone
            clumps.append(HairClumpInfo(id: clumpId, hairItemId: item.id, isBang: target.isBang, rootSampleIndex: sampleIndex, rootPosition: sample.position,
                                        nodeIds: nodeIds, springId: springId, vertexStart: vertexStart, vertexCount: 3 * P.sectionsPerClump,
                                        clearanceVertexStart: vertexStart + 3 * P.sectionsPerBone,
                                        tipVertexStart: vertexStart + 3 * (pivotSection + 1), sweepPivot: strip.centres[pivotSection],
                                        sweepAxis: strip.widthDirs[pivotSection], sectionCentres: strip.centres))
        }

        let meshId = "mesh:hair:\(item.id)"
        let skinId = "skin:hair:\(item.id)"
        let meshNodeId = "node:hair:\(item.id)"
        let mesh = CompiledMesh(id: meshId, name: "Hair_\(item.id)", primitives: [builder.primitive(materialId: materialId, skinned: true)])
        let skin = CompiledSkin(id: skinId, jointNodeIds: jointIds, inverseBindMatrices: ibms)
        let meshNode = CompiledNode(id: meshNodeId, name: "Hair_\(item.id)")
        return Build(mesh: mesh, meshNode: meshNode, nodes: nodes, skin: skin, meshInstance: CompiledMeshInstance(nodeId: meshNodeId, meshId: meshId, skinId: skinId),
                     springs: springs, clumps: clumps, warnings: [])
    }

    static func nearestSample(host: WearableHost, target: SIMD3<Float>, used: Set<Int>) -> Int {
        var best = -1
        var bestD = Float.infinity
        for (i, s) in host.scalpSamples.enumerated() where !used.contains(i) {
            let d = V3.distance(s.position, target)
            if d < bestD { bestD = d; best = i }
        }
        if best < 0 {
            for (i, s) in host.scalpSamples.enumerated() {
                let d = V3.distance(s.position, target)
                if d < bestD { bestD = d; best = i }
            }
        }
        return best
    }

    static func faceProbe(host: WearableHost) -> SurfaceProbe? {
        let forehead = Set(host.region(WearableRegion.forehead))
        guard !forehead.isEmpty else { return nil }
        let probe = SurfaceProbe(positions: host.bodyPositions, normals: host.bodyNormals, indices: host.bodyTriangles) { a, b, c in
            forehead.contains(a) || forehead.contains(b) || forehead.contains(c)
        }
        return probe.isEmpty ? nil : probe
    }

    struct Strip {
        var centres: [SIMD3<Float>]
        var tangents: [SIMD3<Float>]
        var widthDirs: [SIMD3<Float>]
        var normals: [SIMD3<Float>]
        var halfWidths: [Float]
    }

    /// Minimum distance from `p` to the head sphere, the eye spheres and the
    /// forehead surface when present.
    static func faceClearance(_ p: SIMD3<Float>, host: WearableHost, face: SurfaceProbe?, P: LayoutParams) -> Float {
        var c = V3.distance(p, host.headCentre) - host.headRadius
        c = min(c, V3.distance(p, host.leftEyeCentre) - P.eyeRadiusM)
        c = min(c, V3.distance(p, host.rightEyeCentre) - P.eyeRadiusM)
        if let face, let d = face.signedDistance(to: p) { c = min(c, d) }
        return c
    }

    static func pushOut(_ p: SIMD3<Float>, required: Float, isBang: Bool, host: WearableHost, face: SurfaceProbe?, P: LayoutParams) -> SIMD3<Float> {
        var q = p
        for _ in 0..<2 {
            let rel = q - host.headCentre
            let d = V3.length(rel)
            if d < host.headRadius + required { q = host.headCentre + V3.normalize(rel, fallback: SIMD3(0, 0, 1)) * (host.headRadius + required) }
            guard isBang else { continue }
            for eye in [host.leftEyeCentre, host.rightEyeCentre] {
                let er = q - eye
                let ed = V3.length(er)
                if ed < P.eyeRadiusM + required { q = eye + V3.normalize(er, fallback: SIMD3(0, 0, 1)) * (P.eyeRadiusM + required) }
            }
            if let face, let hit = face.nearest(to: q), hit.distance < required {
                q += hit.normal * (required - hit.distance)
            }
        }
        return q
    }

    static func generateClump(sample: ScalpSample, isBang: Bool, controls: HairControls, host: WearableHost, face: SurfaceProbe?, clumpId: String, P: LayoutParams) throws -> Strip {
        let bangClearance = Float(controls.bangClearanceM)
        let tipBend = Float(controls.tipBendDeg) * .pi / 180
        var tilt = P.baseTilt
        var worst: Float = .infinity
        while tilt <= P.maxTilt + 1e-6 {
            let strip = traceStrip(sample: sample, isBang: isBang, controls: controls, tilt: tilt, host: host, face: face, P: P)
            guard isBang else { return strip }
            let clearance = sweepClearance(strip, tipBend: tipBend, host: host, face: face, P: P)
            worst = min(worst, clearance)
            if clearance >= bangClearance { return strip }
            tilt += P.tiltStep
        }
        throw AuthorError(code: .hairClearanceUnsatisfiable, objectId: clumpId, path: "/controls/bangClearanceM", observed: .number(Double(worst)),
                          required: .number(controls.bangClearanceM),
                          message: "Bang clump '\(clumpId)' cannot keep \(controls.bangClearanceM) m from the forehead and eyes across a ±\(controls.tipBendDeg)° tip sweep.",
                          suggestedCommands: ["control set", "recipe apply"])
    }

    /// Minimum face clearance over every strip vertex beyond the scalp-attached
    /// first bone, at rest and with the tip segment rotated by ±tipBend about
    /// the last rotating joint.
    static func sweepClearance(_ strip: Strip, tipBend: Float, host: WearableHost, face: SurfaceProbe?, P: LayoutParams) -> Float {
        let steps = P.sectionsPerClump - 1
        let pivotSection = steps - P.sectionsPerBone
        let pivot = strip.centres[pivotSection]
        let axis = strip.widthDirs[pivotSection]
        var worst: Float = .infinity
        for i in P.sectionsPerBone..<P.sectionsPerClump {
            let c = strip.centres[i], w = strip.widthDirs[i], h = strip.halfWidths[i]
            for v in [c - w * h, c + w * h] {
                worst = min(worst, faceClearance(v, host: host, face: face, P: P))
                guard i > pivotSection else { continue }
                for angle in [-tipBend, tipBend] {
                    worst = min(worst, faceClearance(V3.rotate(v, about: pivot, axis: axis, angle: angle), host: host, face: face, P: P))
                }
            }
        }
        return worst
    }

    static func traceStrip(sample: ScalpSample, isBang: Bool, controls: HairControls, tilt: Float, host: WearableHost, face: SurfaceProbe?, P: LayoutParams) -> Strip {
        let steps = P.sectionsPerClump - 1
        // Bangs keep their absolute bob length; only back/side locks take the preset's guide scale.
        let length = Float(controls.lengthM) * (isBang ? P.bangLengthRatio : P.lengthScale)
        let step = length / Float(steps)
        let widthScale = Float(controls.widthScale)
        let rootHalfWidth = 0.5 * P.baseWidthM * widthScale
        let edgeDip = host.headRadius - (max(host.headRadius * host.headRadius - rootHalfWidth * rootHalfWidth, 0)).squareRoot()
        let bangRequired = Float(controls.bangClearanceM) + edgeDip + P.bangEdgeMarginM
        let pivotSection = steps - P.sectionsPerBone
        let sweepSlope = sin(abs(Float(controls.tipBendDeg)) * .pi / 180) * P.sweepAllowanceFactor
        func required(section i: Int) -> Float {
            guard isBang else { return P.headClearanceM }
            if i <= P.sectionsPerBone {
                return P.headClearanceM + (bangRequired - P.headClearanceM) * Float(i) / Float(P.sectionsPerBone)
            }
            return bangRequired + (i > pivotSection ? Float(i - pivotSection) * step * sweepSlope : 0)
        }
        let down = SIMD3<Float>(0, -1, 0)
        let n0 = V3.normalize(sample.normal, fallback: V3.normalize(sample.position - host.headCentre))
        var tangentDown = V3.reject(down, from: n0)
        if V3.length(tangentDown) < 0.2 {
            let radial = SIMD3<Float>(sample.position.x - host.headCentre.x, 0, sample.position.z - host.headCentre.z)
            tangentDown = V3.normalize(radial, fallback: SIMD3(0, 0, 1))
        }
        tangentDown = V3.normalize(tangentDown)
        let tipBend = Float(controls.tipBendDeg) * .pi / 180

        var centres = [sample.position]
        var dir = V3.normalize(tangentDown + n0 * tilt)
        for i in 0..<steps {
            var cand = centres[i] + dir * step
            let need = required(section: i + 1)
            for _ in 0..<4 {
                cand = pushOut(cand, required: need, isBang: isBang, host: host, face: face, P: P)
                cand = centres[i] + V3.normalize(cand - centres[i], fallback: dir) * step
            }
            centres.append(cand)
            var next = V3.normalize(cand - centres[i], fallback: dir)
            next = V3.normalize(next * (1 - P.gravityBlend) + down * P.gravityBlend)
            if i + 1 >= steps - P.sectionsPerBone {
                let inward = V3.normalize(SIMD3(host.headCentre.x - cand.x, 0, host.headCentre.z - cand.z), fallback: SIMD3(0, 0, -1))
                let theta = tipBend / Float(P.sectionsPerBone)
                next = V3.normalize(next * cos(theta) + inward * sin(theta))
            }
            dir = next
        }

        var tangents: [SIMD3<Float>] = []
        var widthDirs: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var halfWidths: [Float] = []
        for i in 0...steps {
            let t = i < steps ? V3.normalize(centres[i + 1] - centres[i], fallback: down) : tangents[i - 1]
            var o = V3.reject(centres[i] - host.headCentre, from: t)
            if V3.length(o) < 1e-4 { o = V3.reject(n0, from: t) }
            o = V3.normalize(o, fallback: n0)
            let w = V3.normalize(V3.cross(t, o), fallback: SIMD3(1, 0, 0))
            let u = Float(i) / Float(steps)
            tangents.append(t)
            widthDirs.append(w)
            normals.append(V3.normalize(V3.cross(w, t), fallback: o))
            halfWidths.append(rootHalfWidth * (1 - (1 - P.tipWidthRatio) * u))
        }
        return Strip(centres: centres, tangents: tangents, widthDirs: widthDirs, normals: normals, halfWidths: halfWidths)
    }
}

/// The `long-v1` hair preset: the bob machinery with the long layout
/// (lower side roots, finer locks, one more rotating bone, 2x guides).
public enum HairLongV1 {
    public static let presetId = "long-v1"
}
