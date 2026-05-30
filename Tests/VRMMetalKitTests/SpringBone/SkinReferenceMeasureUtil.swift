//
// Copyright 2025 Arkavo
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//

import XCTest
import Metal
import simd
@testable import VRMMetalKit

/// One-off measurement utility (#309) used to AUTHOR the skin-reference oracle
/// radii from AvatarSample_A's actual mesh. It is NOT part of the regression
/// suite: it skips unless `VRM309_MEASURE_ORACLE=1` is set in the environment,
/// so it never runs on CI and never gates other work.
///
/// Run it with:
///   VRM309_MEASURE_ORACLE=1 swift test \
///     --filter SkinReferenceMeasureUtilTests --disable-sandbox
///
/// It prints, for each limb segment, the perpendicular-distance percentiles of
/// the mesh skin around the bone axis; the 70th percentile becomes the tight
/// capsule radius baked into `avatar_a_skin_reference.json`.
final class SkinReferenceMeasureUtilTests: XCTestCase {

    func testMeasureSkinReferenceRadii() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["VRM309_MEASURE_ORACLE"] == "1",
            "Set VRM309_MEASURE_ORACLE=1 to author oracle radii (utility, not a guard).")

        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device")
        }

        let path = getTestVRM10ModelPath()
        try requireFixture(path, hint: testVRM10Filename)
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device)

        // Object-space (bind/rest-pose) positions of every mesh vertex. At load
        // with an identity model matrix and a VRM authored in A/T-pose, these
        // share the bone world-position frame closely enough to fit tight skin
        // capsules. We do not skin here — the oracle is a rest-pose trace.
        // Print the per-material vertex inventory so we can see which meshes are
        // skin/body vs clothing/hair. Clothing (skirt, sleeves) and hair inflate
        // limb radii if mixed in, so legs are measured against body-ish materials.
        Self.printMaterialInventory(model: model)

        let allVerts = Self.allMeshPositions(model: model, bodyOnly: false)
        let bodyVerts = Self.allMeshPositions(model: model, bodyOnly: true)
        XCTAssertGreaterThan(allVerts.count, 0, "No mesh vertices read back")
        print("[oracle] allVerts=\(allVerts.count) bodyVerts=\(bodyVerts.count)")
        // Arms use all geometry (sleeves hug the arm closely on this avatar);
        // legs use body-only geometry to exclude the skirt.
        let verts = allVerts

        // Integrity fingerprint for Task 2.
        var lo = verts[0], hi = verts[0]
        for v in verts { lo = simd_min(lo, v); hi = simd_max(hi, v) }
        print("[oracle] integrity vertexCount=\(verts.count) bboxMinY=\(lo.y) bboxMaxY=\(hi.y)")
        print("[oracle] bbox=\(lo) .. \(hi)")

        guard let humanoid = model.humanoid else {
            XCTFail("Model has no humanoid"); return
        }
        func worldPos(_ bone: VRMHumanoidBone) -> SIMD3<Float>? {
            guard let n = humanoid.getBoneNode(bone), n >= 0, n < model.nodes.count else { return nil }
            return model.nodes[n].worldPosition
        }

        // Limb segments to trace. `bodyOnly` excludes clothing/hair geometry so
        // skirt and loose garments don't inflate the leg radii.
        let segments: [(String, VRMHumanoidBone, VRMHumanoidBone, Bool)] = [
            ("leftUpperArm", .leftUpperArm, .leftLowerArm, false),
            ("leftLowerArm", .leftLowerArm, .leftHand, false),
            ("rightUpperArm", .rightUpperArm, .rightLowerArm, false),
            ("rightLowerArm", .rightLowerArm, .rightHand, false),
            ("leftUpperLeg", .leftUpperLeg, .leftLowerLeg, true),
            ("leftLowerLeg", .leftLowerLeg, .leftFoot, true),
            ("rightUpperLeg", .rightUpperLeg, .rightLowerLeg, true),
            ("rightLowerLeg", .rightLowerLeg, .rightFoot, true),
        ]

        for (name, fromBone, toBone, bodyOnly) in segments {
            guard let a = worldPos(fromBone), let b = worldPos(toBone) else {
                print("[oracle] \(name): MISSING bone(s), skipped")
                continue
            }
            print(String(format: "[oracle] %@ a=(%.3f,%.3f,%.3f) b=(%.3f,%.3f,%.3f)",
                         name, a.x, a.y, a.z, b.x, b.y, b.z))
            let ab = b - a
            let abLenSq = simd_dot(ab, ab)
            guard abLenSq > 1e-9 else { print("[oracle] \(name): degenerate segment"); continue }

            let source = bodyOnly && !bodyVerts.isEmpty ? bodyVerts : verts
            // Collect perpendicular distances for the mid-section [0.15, 0.85],
            // gated to a tight local radius so the opposite limb / torso never
            // leaks in. We report several percentiles; the 60th is taken as the
            // tight skin trace (penetration tests want a snug, not loose, fit).
            let segLen = sqrt(abLenSq)
            // Legs sit only ~0.14m apart on this avatar, so a segLen-scaled gate
            // (0.16m) would pull in the opposite leg and the crotch. Cap the
            // capture radius hard so each measurement sees only its own limb.
            let captureRadius = min(segLen * 0.45, 0.07)
            var perps: [Float] = []
            perps.reserveCapacity(2048)
            for v in source {
                let t = simd_dot(v - a, ab) / abLenSq
                if t < 0.15 || t > 0.85 { continue }
                let closest = a + t * ab
                let d = simd_length(v - closest)
                if d <= captureRadius { perps.append(d) }
            }
            guard perps.count > 32 else {
                print("[oracle] \(name): too few samples (\(perps.count))"); continue
            }
            perps.sort()
            func pct(_ p: Float) -> Float { perps[min(perps.count - 1, Int(p * Float(perps.count)))] }
            let p50 = pct(0.50), p60 = pct(0.60), p70 = pct(0.70), p90 = pct(0.90)
            print(String(
                format: "[oracle] %@ bodyOnly=%@ segLen=%.4f n=%d  p50=%.4f  p60=%.4f  p70=%.4f  p90=%.4f",
                name, bodyOnly ? "Y" : "N", segLen, perps.count, p50, p60, p70, p90))
        }

        // Head: brow capsule + skull sphere in head-local space.
        if let headNodeIdx = humanoid.getBoneNode(.head),
           headNodeIdx >= 0, headNodeIdx < model.nodes.count {
            let headWorld = model.nodes[headNodeIdx].worldPosition
            let headInv = simd_inverse(model.nodes[headNodeIdx].worldMatrix)
            // Head-local FACE/SKIN vertices only (exclude hair shells) near the
            // head origin, so the skull sphere traces the actual head surface.
            var local: [SIMD3<Float>] = []
            for v in (bodyVerts.isEmpty ? verts : bodyVerts) {
                if simd_length(v - headWorld) > 0.25 { continue }
                local.append((headInv * SIMD4<Float>(v, 1)).xyz)
            }
            if !local.isEmpty {
                var hlo = local[0], hhi = local[0]
                for p in local { hlo = simd_min(hlo, p); hhi = simd_max(hhi, p) }
                // Skull sphere: center it at the cranium (upper-mid head) and take
                // the radius as the lateral (X/Z) extent of the skull cap, which
                // is what a hair joint actually has to clear.
                let skullCenter = SIMD3<Float>(0, hhi.y - 0.085, 0)
                var radii: [Float] = []
                for p in local where p.y >= skullCenter.y - 0.04 {
                    radii.append(sqrt(p.x * p.x + p.z * p.z))
                }
                radii.sort()
                let skullR = radii.isEmpty ? 0 : radii[Int(0.7 * Float(max(1, radii.count)))]
                // Brow capsule radius: forward (+Z) face spread at mid height.
                var browR: [Float] = []
                for p in local where abs(p.y) < 0.06 && p.z > 0 { browR.append(p.z) }
                browR.sort()
                let browRadius = browR.isEmpty ? 0 : browR[Int(0.7 * Float(max(1, browR.count)))]
                print("[oracle] head local bbox=\(hlo) .. \(hhi) n=\(local.count)")
                print(String(
                    format: "[oracle] head skullCenterY=%.4f skullSphereR=%.4f browCapsuleR=%.4f",
                    skullCenter.y, skullR, browRadius))
            }
        }
    }

    /// Heuristic: is this material part of the body/skin (vs clothing/hair/face
    /// accessories)? Used to keep the skirt out of the leg radius measurement.
    static func isBodyMaterial(_ name: String?) -> Bool {
        guard let n = name?.lowercased() else { return false }
        if n.contains("hair") || n.contains("cloth") || n.contains("skirt")
            || n.contains("dress") || n.contains("outline") { return false }
        return n.contains("body") || n.contains("skin") || n.contains("face")
    }

    /// Reads back object-space positions from every primitive's interleaved
    /// `vertexBuffer` (VRMVertex layout). When `bodyOnly` is true, only
    /// primitives whose material reads as body/skin are included. Returns an
    /// empty array if buffers are missing (e.g. model loaded without a device).
    static func allMeshPositions(model: VRMModel, bodyOnly: Bool) -> [SIMD3<Float>] {
        var out: [SIMD3<Float>] = []
        let stride = MemoryLayout<VRMVertex>.stride
        for mesh in model.meshes {
            for prim in mesh.primitives {
                guard let buf = prim.vertexBuffer, prim.vertexCount > 0 else { continue }
                if bodyOnly {
                    let matName = prim.materialIndex.flatMap { model.materials[safe: $0]?.name }
                    if !isBodyMaterial(matName) { continue }
                }
                let raw = buf.contents()
                for i in 0..<prim.vertexCount {
                    let p = raw.advanced(by: i * stride)
                        .assumingMemoryBound(to: VRMVertex.self).pointee.position
                    out.append(p)
                }
            }
        }
        return out
    }

    /// Prints each primitive's material name + vertex count + body classification.
    static func printMaterialInventory(model: VRMModel) {
        for (mi, mesh) in model.meshes.enumerated() {
            for (pi, prim) in mesh.primitives.enumerated() {
                let matName = prim.materialIndex.flatMap { model.materials[safe: $0]?.name } ?? "<none>"
                print(String(
                    format: "[oracle] mesh[%d].prim[%d] mat='%@' verts=%d body=%@",
                    mi, pi, matName, prim.vertexCount,
                    isBodyMaterial(matName) ? "Y" : "N"))
            }
        }
    }
}
