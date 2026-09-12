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

/// Rigid accessories: geometry is authored in the attachment node's local
/// frame, `AccessoryItem.transform` is baked in, and the mesh is skinned 100%
/// to the attachment node through a one-joint skin.
public enum AccessoryPresets {
    public enum Glasses {
        public static let lensHalfWidthM: Float = 0.013
        public static let lensHalfHeightM: Float = 0.010
        public static let lensForwardM: Float = 0.010
        public static let barHalfThicknessM: Float = 0.0015
        public static let templeLengthM: Float = 0.10
    }

    public enum Earring {
        public static let hookHalfExtentsM = SIMD3<Float>(0.001, 0.003, 0.001)
        public static let dropRadiusM: Float = 0.004
        public static let dropTopY: Float = -0.006
        public static let dropEquatorY: Float = -0.015
        public static let dropBottomY: Float = -0.026
        public static let dropSides = 6
    }

    /// Two tapered ear prisms, authored in the head node's local frame,
    /// centred above the ears; the recipe transform places and tilts them.
    public enum CatEars {
        public static let baseHalfWidthM: Float = 0.032
        public static let baseHalfDepthM: Float = 0.014
        public static let heightM: Float = 0.062
        public static let spacingM: Float = 0.052
        public static let sides = 8
        public static let innerSetbackM: Float = 0.004
    }

    struct Build {
        var mesh: CompiledMesh
        var meshNode: CompiledNode
        var skin: CompiledSkin
        var meshInstance: CompiledMeshInstance
        var warnings: [AuthorWarning]
    }

    static func build(item: AccessoryItem, host: WearableHost, materialIds: [String]) throws -> Build {
        let objectId = "accessory:\(item.id)"
        guard host.attachmentNodeIds.contains(item.attachment) else {
            throw AuthorError(code: .attachmentNotFound, objectId: objectId, path: "/attachment", observed: .string(item.attachment),
                              required: .array(host.attachmentNodeIds.map { .string($0) }),
                              message: "Accessory '\(item.id)' attaches to '\(item.attachment)', which is not a declared attachment node.",
                              suggestedCommands: ["object list --kind node", "object set"])
        }
        let attachWorld = try host.requireWorld(item.attachment, objectId: objectId)
        let attachInv = attachWorld.affineInverse()
        let xf = item.transform
        let t = SIMD3<Float>(Float(xf.translation[0]), Float(xf.translation[1]), Float(xf.translation[2]))
        let q = SIMD4<Float>(Float(xf.rotation[0]), Float(xf.rotation[1]), Float(xf.rotation[2]), Float(xf.rotation[3]))
        let s = SIMD3<Float>(Float(xf.scale[0]), Float(xf.scale[1]), Float(xf.scale[2]))
        let toWorld: (SIMD3<Float>) -> SIMD3<Float> = { p in attachWorld.transformPoint(V3.rotate(p * s, by: q) + t) }
        let normalToWorld: (SIMD3<Float>) -> SIMD3<Float> = { n in V3.normalize(attachWorld.transformDirection(V3.rotate(n / s, by: q))) }

        var primitives: [CompiledPrimitive] = []
        switch item.preset {
        case .glassesV1:
            let eyeL = attachInv.transformPoint(host.leftEyeCentre)
            let eyeR = attachInv.transformPoint(host.rightEyeCentre)
            let forward = HairBobV1.Layout.eyeRadiusM + Glasses.lensForwardM
            let lensL = eyeL + SIMD3(0, 0, forward)
            let lensR = eyeR + SIMD3(0, 0, forward)
            let hw = Glasses.lensHalfWidthM, hh = Glasses.lensHalfHeightM, bt = Glasses.barHalfThicknessM

            var frame = MeshBuilder()
            for lens in [lensL, lensR] {
                frame.addBox(centre: lens + SIMD3(0, hh + bt, 0), halfExtents: SIMD3(hw + bt, bt, bt), transform: toWorld, normalTransform: normalToWorld)
                frame.addBox(centre: lens - SIMD3(0, hh + bt, 0), halfExtents: SIMD3(hw + bt, bt, bt), transform: toWorld, normalTransform: normalToWorld)
                let outer: Float = lens.x >= 0 ? 1 : -1
                frame.addBox(centre: lens + SIMD3(outer * (hw + bt), 0, 0), halfExtents: SIMD3(bt, hh + bt, bt), transform: toWorld, normalTransform: normalToWorld)
                frame.addBox(centre: lens - SIMD3(outer * (hw + bt), 0, 0), halfExtents: SIMD3(bt, hh + bt, bt), transform: toWorld, normalTransform: normalToWorld)
                frame.addBox(centre: lens + SIMD3(outer * (hw + bt), hh, -Glasses.templeLengthM / 2), halfExtents: SIMD3(bt, bt, Glasses.templeLengthM / 2),
                             transform: toWorld, normalTransform: normalToWorld)
            }
            let mid = (lensL + lensR) / 2
            let bridgeHalf = max(abs(lensL.x - lensR.x) / 2 - hw - 2 * bt, bt)
            frame.addBox(centre: mid, halfExtents: SIMD3(bridgeHalf, bt, bt), transform: toWorld, normalTransform: normalToWorld)
            primitives.append(frame.primitive(materialId: materialIds[0], skinned: true))

            var lenses = MeshBuilder()
            for lens in [lensL, lensR] {
                let n = normalToWorld(SIMD3(0, 0, 1))
                let base = UInt32(lenses.vertexCount)
                let corners = [lens + SIMD3(-hw, -hh, 0), lens + SIMD3(hw, -hh, 0), lens + SIMD3(hw, hh, 0), lens + SIMD3(-hw, hh, 0)]
                let uvs: [SIMD2<Float>] = [SIMD2(0, 1), SIMD2(1, 1), SIMD2(1, 0), SIMD2(0, 0)]
                for (i, c) in corners.enumerated() {
                    lenses.addVertex(toWorld(c), normal: n, uv: uvs[i], joints: SIMD4(0, 0, 0, 0), weights: SIMD4(1, 0, 0, 0))
                }
                lenses.addQuad(base, base + 1, base + 2, base + 3)
            }
            primitives.append(lenses.primitive(materialId: materialIds.count > 1 ? materialIds[1] : materialIds[0], skinned: true))

        case .earringV1:
            var drop = MeshBuilder()
            drop.addBox(centre: SIMD3(0, -Earring.hookHalfExtentsM.y, 0), halfExtents: Earring.hookHalfExtentsM, transform: toWorld, normalTransform: normalToWorld)
            let top = SIMD3<Float>(0, Earring.dropTopY, 0)
            let bottom = SIMD3<Float>(0, Earring.dropBottomY, 0)
            var ring: [SIMD3<Float>] = []
            for k in 0..<Earring.dropSides {
                let a = 2 * Float.pi * Float(k) / Float(Earring.dropSides)
                ring.append(SIMD3(Earring.dropRadiusM * cos(a), Earring.dropEquatorY, Earring.dropRadiusM * sin(a)))
            }
            func face(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) {
                let n = normalToWorld(V3.normalize(V3.cross(b - a, c - a)))
                let base = UInt32(drop.vertexCount)
                for p in [a, b, c] { drop.addVertex(toWorld(p), normal: n, uv: SIMD2(0.5, p.y < Earring.dropEquatorY ? 1 : 0), joints: SIMD4(0, 0, 0, 0), weights: SIMD4(1, 0, 0, 0)) }
                drop.addTriangle(base, base + 1, base + 2)
            }
            for k in 0..<Earring.dropSides {
                let a = ring[k], b = ring[(k + 1) % Earring.dropSides]
                face(top, b, a)
                face(bottom, a, b)
            }
            primitives.append(drop.primitive(materialId: materialIds[0], skinned: true))

        case .catEarsV1:
            // Two tapered ear prisms seated on the crown: bases follow the
            // head sphere, tips flare slightly outward and forward. An
            // inner-ear triangle sits proud of the front face.
            var outer = MeshBuilder()
            var inner = MeshBuilder()
            for sign: Float in [1, -1] {
                let worldNormal = V3.normalize(SIMD3<Float>(sign * 0.45, 0.89, 0.08))
                let worldBase = host.headCentre + worldNormal * (host.headRadius - 0.004)
                let base = attachInv.transformPoint(worldBase)
                let up = V3.normalize(attachInv.transformDirection(worldNormal))
                let across = V3.normalize(V3.cross(up, SIMD3<Float>(0, 0, 1)), fallback: SIMD3<Float>(1, 0, 0))
                let depth = V3.normalize(V3.cross(across, up), fallback: SIMD3<Float>(0, 0, 1))
                let apex = base + up * CatEars.heightM + across * (sign * 0.012)
                var ring: [SIMD3<Float>] = []
                for k in 0..<CatEars.sides {
                    let a = 2 * Float.pi * Float(k) / Float(CatEars.sides)
                    ring.append(base + across * (CatEars.baseHalfWidthM * cos(a)) + depth * (CatEars.baseHalfDepthM * sin(a)))
                }
                for k in 0..<CatEars.sides {
                    let a = ring[k], b = ring[(k + 1) % CatEars.sides]
                    let nSide = normalToWorld(V3.normalize(V3.cross(b - a, apex - a), fallback: up))
                    let s0 = UInt32(outer.vertexCount)
                    for p in [a, b, apex] { outer.addVertex(toWorld(p), normal: nSide, uv: SIMD2(0.5, 0.5), joints: SIMD4(0, 0, 0, 0), weights: SIMD4(1, 0, 0, 0)) }
                    outer.addTriangle(s0, s0 + 1, s0 + 2)
                    let nCap = normalToWorld(-up)
                    let c0 = UInt32(outer.vertexCount)
                    for p in [base, b, a] { outer.addVertex(toWorld(p), normal: nCap, uv: SIMD2(0.5, 0.5), joints: SIMD4(0, 0, 0, 0), weights: SIMD4(1, 0, 0, 0)) }
                    outer.addTriangle(c0, c0 + 1, c0 + 2)
                }
                let front = depth
                let i0 = UInt32(inner.vertexCount)
                let ia = base + up * (CatEars.heightM * 0.16) + front * (CatEars.baseHalfDepthM * 0.75 + CatEars.innerSetbackM) - across * (CatEars.baseHalfWidthM * 0.52)
                let ib = base + up * (CatEars.heightM * 0.16) + front * (CatEars.baseHalfDepthM * 0.75 + CatEars.innerSetbackM) + across * (CatEars.baseHalfWidthM * 0.52)
                let ic = base + up * (CatEars.heightM * 0.58) + front * (CatEars.baseHalfDepthM * 0.35 + CatEars.innerSetbackM) + across * (sign * 0.006)
                let nInner = normalToWorld(front)
                for p in [ia, ib, ic] { inner.addVertex(toWorld(p), normal: nInner, uv: SIMD2(0.5, 0.5), joints: SIMD4(0, 0, 0, 0), weights: SIMD4(1, 0, 0, 0)) }
                inner.addTriangle(i0, i0 + 1, i0 + 2)
            }
            primitives.append(outer.primitive(materialId: materialIds[0], skinned: true))
            if materialIds.count > 1 {
                primitives.append(inner.primitive(materialId: materialIds[1], skinned: true))
            } else {
                primitives.append(inner.primitive(materialId: materialIds[0], skinned: true))
            }
        }

        let meshId = "mesh:accessory:\(item.id)"
        let nodeId = "node:accessory:\(item.id)"
        let skinId = "skin:accessory:\(item.id)"
        let mesh = CompiledMesh(id: meshId, name: "Accessory_\(item.id)", primitives: primitives)
        let skin = CompiledSkin(id: skinId, jointNodeIds: [item.attachment], inverseBindMatrices: [attachInv.m])
        return Build(mesh: mesh, meshNode: CompiledNode(id: nodeId, name: "Accessory_\(item.id)", parentId: item.attachment), skin: skin,
                     meshInstance: CompiledMeshInstance(nodeId: nodeId, meshId: meshId, skinId: skinId), warnings: [])
    }
}
