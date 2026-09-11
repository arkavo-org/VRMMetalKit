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
import XCTest
@testable import VRMAuthorKit

final class NativeAnimeGeometryTests: XCTestCase {
    private let pack = NativeAnimeFixture.pack

    private static func triangleArea(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> Double {
        let ab = SIMD3<Double>(b - a), ac = SIMD3<Double>(c - a)
        let n = SIMD3<Double>(ab.y * ac.z - ab.z * ac.y, ab.z * ac.x - ab.x * ac.z, ab.x * ac.y - ab.y * ac.x)
        return 0.5 * (n.x * n.x + n.y * n.y + n.z * n.z).squareRoot()
    }

    static func assertValid(_ avatar: CompiledAvatar, file: StaticString = #filePath, line: UInt = #line) {
        for mesh in avatar.meshes {
            for (pi, p) in mesh.primitives.enumerated() {
                let tag = "\(mesh.id)#\(pi)"
                let n = p.positions.count
                XCTAssertGreaterThan(n, 0, tag, file: file, line: line)
                XCTAssertEqual(p.normals.count, n, tag, file: file, line: line)
                XCTAssertEqual(p.uv0.count, n, tag, file: file, line: line)
                XCTAssertEqual(p.joints0?.count, n, tag, file: file, line: line)
                XCTAssertEqual(p.weights0?.count, n, tag, file: file, line: line)
                XCTAssertEqual(p.indices.count % 3, 0, tag, file: file, line: line)
                for v in p.positions { XCTAssertTrue(v.x.isFinite && v.y.isFinite && v.z.isFinite, tag, file: file, line: line) }
                for uv in p.uv0 { XCTAssertTrue(uv.x.isFinite && uv.y.isFinite, tag, file: file, line: line) }
                for nrm in p.normals {
                    let len = (nrm.x * nrm.x + nrm.y * nrm.y + nrm.z * nrm.z).squareRoot()
                    XCTAssertEqual(Double(len), 1, accuracy: 1e-3, tag, file: file, line: line)
                }
                var degenerate = 0
                for t in stride(from: 0, to: p.indices.count, by: 3) {
                    let i = Int(p.indices[t]), j = Int(p.indices[t + 1]), k = Int(p.indices[t + 2])
                    XCTAssertTrue(i < n && j < n && k < n, tag, file: file, line: line)
                    XCTAssertTrue(i != j && j != k && i != k, tag, file: file, line: line)
                    if triangleArea(p.positions[i], p.positions[j], p.positions[k]) <= 1e-10 { degenerate += 1 }
                }
                XCTAssertEqual(degenerate, 0, "\(tag) degenerate triangles", file: file, line: line)
                for m in p.morphTargets {
                    XCTAssertEqual(m.positionDeltas.count, n, "\(tag) morph \(m.name)", file: file, line: line)
                    for d in m.positionDeltas { XCTAssertTrue(d.x.isFinite && d.y.isFinite && d.z.isFinite, tag, file: file, line: line) }
                }
            }
        }
    }

    func testDefaultMeshIsValidAndWithinTriangleBudget() throws {
        let (avatar, _) = try NativeAnimeFixture.compiled()
        Self.assertValid(avatar)
        func tris(_ id: String) -> Int { avatar.meshes.first { $0.id == id }!.primitives.reduce(0) { $0 + $1.indices.count / 3 } }
        let bodyHead = tris("mesh.body") + tris("mesh.head")
        XCTAssertGreaterThanOrEqual(bodyHead, 4000, "body+head triangles \(bodyHead)")
        XCTAssertLessThanOrEqual(bodyHead, 8000, "body+head triangles \(bodyHead)")
        XCTAssertEqual(avatar.meshes.first { $0.id == "mesh.head" }!.primitives.count, HeadPrimitive.allCases.count)
        XCTAssertEqual(avatar.meshes.first { $0.id == "mesh.eyeL" }!.primitives.count, EyePrimitive.allCases.count)
    }

    func testStatureAndGroundContact() throws {
        for height in [1.2, 1.65, 2.0] {
            let (avatar, attachments) = try NativeAnimeFixture.compiled { $0.body["body.heightM"] = height }
            var minY = Float.greatestFiniteMagnitude, maxY = -Float.greatestFiniteMagnitude
            for mesh in avatar.meshes { for p in mesh.primitives { for v in p.positions { minY = min(minY, v.y); maxY = max(maxY, v.y) } } }
            XCTAssertEqual(Double(minY), 0, accuracy: 0.002, "height \(height)")
            XCTAssertEqual(Double(maxY), height, accuracy: 0.01, "height \(height)")
            XCTAssertEqual(Double(attachments.headHeightM), height / 6.3, accuracy: 1e-6)
        }
    }

    func testHeadCountReproportionsAtFixedHeight() throws {
        let (small, sa) = try NativeAnimeFixture.compiled { $0.body["body.headCount"] = 4.5 }
        let (large, la) = try NativeAnimeFixture.compiled { $0.body["body.headCount"] = 8 }
        XCTAssertGreaterThan(sa.headHeightM, la.headHeightM)
        XCTAssertEqual(Double(sa.headHeightM), 1.65 / 4.5, accuracy: 1e-6)
        XCTAssertEqual(Double(la.headHeightM), 1.65 / 8, accuracy: 1e-6)
        for avatar in [small, large] {
            var maxY = -Float.greatestFiniteMagnitude
            for mesh in avatar.meshes { for p in mesh.primitives { for v in p.positions { maxY = max(maxY, v.y) } } }
            XCTAssertEqual(Double(maxY), 1.65, accuracy: 0.01)
        }
        XCTAssertLessThan(sa.jointWorldPositions[.head]!.y, la.jointWorldPositions[.head]!.y)
    }

    /// Every control at its endpoints displaces at least one vertex by more than
    /// 1 mm inside its declared regions and nothing outside them.
    func testEveryControlMovesItsRegionsAndNothingElse() throws {
        let (baseline, attachments) = try NativeAnimeFixture.compiled()
        var allowed: [String: [String: Set<Int>]] = [:]
        func meshKey(_ mesh: String, _ prim: Int) -> String { "\(mesh)#\(prim)" }
        for (region, refs) in attachments.regions {
            for ref in refs { allowed[region, default: [:]][meshKey(ref.meshId, ref.primitiveIndex), default: []].formUnion(ref.indices) }
        }
        for d in pack.controls {
            let regions = attachments.controlRegions[d.key]!
            let endpoints = d.validRange[0] == 0 ? [0.0, 1.0] : [-1.0, 1.0]
            for value in endpoints {
                let (variant, _) = try NativeAnimeFixture.compiled { r in
                    if d.key.hasPrefix("body.") {
                        r.body[d.key] = d.key == "body.heightM" ? (value < 0 ? 1.4 : 1.9) : d.key == "body.headCount" ? (value < 0 ? 5 : 7.5) : value
                    } else {
                        r.face[d.key] = value
                    }
                }
                Self.assertValid(variant)
                var maxMove = 0.0
                var leaked = 0
                for (mi, mesh) in variant.meshes.enumerated() {
                    for (pi, p) in mesh.primitives.enumerated() {
                        let base = baseline.meshes[mi].primitives[pi]
                        XCTAssertEqual(p.positions.count, base.positions.count, "\(d.key) \(mesh.id)#\(pi) topology changed")
                        let key = meshKey(mesh.id, pi)
                        var permitted = Set<Int>()
                        if regions.contains("*") {
                            permitted = Set(0..<p.positions.count)
                        } else {
                            for r in regions { permitted.formUnion(allowed[r]?[key] ?? []) }
                        }
                        for i in 0..<p.positions.count {
                            let delta = SIMD3<Double>(p.positions[i] - base.positions[i])
                            let dist = (delta.x * delta.x + delta.y * delta.y + delta.z * delta.z).squareRoot()
                            if permitted.contains(i) {
                                maxMove = max(maxMove, dist)
                            } else if dist > 1e-6 {
                                leaked += 1
                            }
                        }
                    }
                }
                XCTAssertGreaterThan(maxMove, 0.001, "\(d.key)=\(value) moved \(maxMove * 1000) mm")
                XCTAssertEqual(leaked, 0, "\(d.key)=\(value) displaced \(leaked) vertices outside \(regions)")
            }
        }
    }

    func testSemanticRegionsArePresentOnEveryMesh() throws {
        let (avatar, attachments) = try NativeAnimeFixture.compiled()
        let expectedHead = ["scalp", "nape", "forehead", "face", "jaw", "chin", "eyeSocketL", "eyeSocketR", "eyelidUpperL", "eyelidUpperR", "eyelidLowerL",
                            "eyelidLowerR", "lipsUpper", "lipsLower", "innerMouth", "earL", "earR", "nose", "browL", "browR"]
        for name in expectedHead {
            XCTAssertTrue(attachments.regions[name]?.contains { $0.meshId == "mesh.head" && !$0.indices.isEmpty } == true, name)
        }
        for name in NativeAnimeControls.bodyRegions {
            XCTAssertTrue(attachments.regions[name]?.contains { $0.meshId == "mesh.body" && !$0.indices.isEmpty } == true, name)
        }
        for (eye, globe) in [("mesh.eyeL", "globeL"), ("mesh.eyeR", "globeR")] {
            for name in [globe, "iris", "pupil", "highlight"] {
                XCTAssertTrue(attachments.regions[name]?.contains { $0.meshId == eye && !$0.indices.isEmpty } == true, "\(eye) \(name)")
            }
            let mesh = avatar.meshes.first { $0.id == eye }!
            let total = mesh.primitives.reduce(0) { $0 + $1.positions.count }
            let tagged = attachments.regions[globe]!.filter { $0.meshId == eye }.reduce(0) { $0 + $1.indices.count }
            XCTAssertEqual(tagged, total, "\(globe) covers every vertex of \(eye)")
        }
        for (name, refs) in attachments.regions {
            for ref in refs {
                let prim = avatar.meshes.first { $0.id == ref.meshId }!.primitives[ref.primitiveIndex]
                XCTAssertEqual(ref.indices, ref.indices.sorted(), name)
                XCTAssertEqual(Set(ref.indices).count, ref.indices.count, name)
                for i in ref.indices { XCTAssertLessThan(i, prim.positions.count, name) }
            }
        }
        let bodyPrim = avatar.meshes[0].primitives[0]
        var covered = Set<Int>()
        for name in NativeAnimeControls.bodyRegions { covered.formUnion(attachments.indices(of: name, mesh: "mesh.body")) }
        XCTAssertEqual(covered.count, bodyPrim.positions.count, "every body vertex belongs to a region")
        XCTAssertFalse(attachments.scalpSamples.isEmpty)
        for s in attachments.scalpSamples {
            let len = (s.normal.x * s.normal.x + s.normal.y * s.normal.y + s.normal.z * s.normal.z).squareRoot()
            XCTAssertEqual(Double(len), 1, accuracy: 1e-3)
            XCTAssertGreaterThan(s.position.y, attachments.headCenter.y - attachments.headRadii.y * 0.4)
            XCTAssertTrue(s.position.z < 0 || s.position.y > attachments.headCenter.y + attachments.headRadii.y * 0.4, "scalp is top or back")
        }
        for key in ["head", "earLeft", "earRight", "glasses", "hips", "chest", "neck", "leftHand", "rightHand"] {
            let nodeId = attachments.attachmentNodes[key]
            XCTAssertNotNil(nodeId, key)
            XCTAssertTrue(avatar.nodes.contains { $0.id == nodeId }, key)
        }
    }

    func testEyesAreSpacedGlobesFacingForward() throws {
        let (avatar, attachments) = try NativeAnimeFixture.compiled()
        XCTAssertEqual(attachments.eyes.count, 2)
        let left = attachments.eyes.first { $0.side == "left" }!
        let right = attachments.eyes.first { $0.side == "right" }!
        XCTAssertGreaterThan(left.center.x, 0)
        XCTAssertLessThan(right.center.x, 0)
        XCTAssertEqual(left.center.y, right.center.y)
        XCTAssertGreaterThan(left.center.x - right.center.x, 2.2 * left.globeRadius, "globes must not intersect")
        XCTAssertEqual(left.irisUVRadius, 0.25)
        XCTAssertEqual(left.pupilUVRadius, 0.10)
        XCTAssertGreaterThan(left.irisAngleRadians, left.pupilAngleRadians)
        for eye in [left, right] {
            let node = avatar.nodes.first { $0.id == eye.boneNodeId }!
            XCTAssertEqual(node.humanoidBone, eye.side == "left" ? .leftEye : .rightEye)
            let mesh = avatar.meshes.first { $0.id == eye.meshId }!
            var maxZ = -Float.greatestFiniteMagnitude
            for p in mesh.primitives { for v in p.positions { maxZ = max(maxZ, v.z) } }
            XCTAssertEqual(Double(maxZ), Double(eye.center.z + eye.globeRadius), accuracy: 0.001)
            let headShell = avatar.meshes.first { $0.id == "mesh.head" }!.primitives[0]
            let socket = attachments.indices(of: eye.side == "left" ? "eyeSocketL" : "eyeSocketR", mesh: "mesh.head")
                .filter { abs(headShell.positions[$0].x - eye.center.x) < eye.lidRadius && abs(headShell.positions[$0].y - eye.center.y) < eye.lidRadius }
            XCTAssertFalse(socket.isEmpty)
            let shellZ = socket.map { headShell.positions[$0].z }.max()!
            XCTAssertGreaterThan(maxZ, shellZ, "globe front must be proud of the socket")
            let irisPrim = mesh.primitives[EyePrimitive.iris.rawValue]
            for uv in irisPrim.uv0 {
                let r = ((Double(uv.x) - 0.5) * (Double(uv.x) - 0.5) + (Double(uv.y) - 0.5) * (Double(uv.y) - 0.5)).squareRoot()
                XCTAssertLessThanOrEqual(r, 0.25 + 1e-5)
            }
        }
        let (bigIris, _) = try NativeAnimeFixture.compiled { $0.face["face.iris.left.size"] = 1 }
        let baseIris = NativeAnimeFixture.primitive(avatar, mesh: "mesh.eyeL", primitive: EyePrimitive.iris.rawValue)
        let grownIris = NativeAnimeFixture.primitive(bigIris, mesh: "mesh.eyeL", primitive: EyePrimitive.iris.rawValue)
        XCTAssertEqual(baseIris.uv0, grownIris.uv0, "iris UV region is static; geometry scales")
        XCTAssertNotEqual(baseIris.positions, grownIris.positions)
    }
}
