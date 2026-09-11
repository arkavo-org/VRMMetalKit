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

final class NativeAnimeMorphTests: XCTestCase {
    private func length(_ v: SIMD3<Float>) -> Double { (Double(v.x) * Double(v.x) + Double(v.y) * Double(v.y) + Double(v.z) * Double(v.z)).squareRoot() }

    private func maxDelta(_ prim: CompiledPrimitive, _ name: String) -> Double {
        NativeAnimeFixture.morph(prim, name).map(length).max() ?? 0
    }

    func testHeadPrimitivesShareTheMorphListAndBodyHasNone() throws {
        let (avatar, _) = try NativeAnimeFixture.compiled()
        let head = avatar.meshes.first { $0.id == "mesh.head" }!
        for p in head.primitives {
            XCTAssertEqual(p.morphTargets.map(\.name), NativeAnimeMorphNames.all)
            for m in p.morphTargets { XCTAssertEqual(m.positionDeltas.count, p.positions.count, m.name) }
        }
        XCTAssertFalse(NativeAnimeMorphNames.all.contains("neutral"))
        for mesh in avatar.meshes where mesh.id != "mesh.head" {
            for p in mesh.primitives { XCTAssertEqual(p.morphTargets, [], mesh.id) }
        }
    }

    func testBlinkClosesEachLidOverItsGlobe() throws {
        let (avatar, attachments) = try NativeAnimeFixture.compiled()
        let head = avatar.meshes.first { $0.id == "mesh.head" }!
        func edge(_ key: String, morph: String?) -> [SIMD3<Float>] {
            let ref = attachments.lidEdges[key]!
            let prim = head.primitives[ref.primitiveIndex]
            let deltas = morph.map { NativeAnimeFixture.morph(prim, $0) }
            return ref.indices.map { prim.positions[$0] + (deltas?[$0] ?? .zero) }
        }
        for (side, expectedClosed, expectedOpen) in [("L", "blinkLeft", "blinkRight"), ("R", "blinkRight", "blinkLeft")] {
            let upperRest = edge("upper\(side)", morph: nil), lowerRest = edge("lower\(side)", morph: nil)
            XCTAssertEqual(upperRest.count, lowerRest.count)
            XCTAssertEqual(upperRest.count, NativeAnimeHeadBuilder.lidColumns)
            let restGap = zip(upperRest, lowerRest).map { length($0 - $1) }.max()!
            XCTAssertGreaterThan(restGap, 0.008, "eye \(side) opening at rest \(restGap * 1000) mm")
            for morph in ["blink", expectedClosed] {
                let closed = zip(edge("upper\(side)", morph: morph), edge("lower\(side)", morph: morph)).map { length($0 - $1) }.max()!
                XCTAssertLessThan(closed, 0.001, "\(morph) leaves eye \(side) open by \(closed * 1000) mm")
            }
            let untouched = zip(edge("upper\(side)", morph: expectedOpen), upperRest).map { length($0 - $1) }.max()!
            XCTAssertEqual(untouched, 0, "\(expectedOpen) must not move eye \(side)")
            let lowerMoved = zip(edge("lower\(side)", morph: "blink"), lowerRest).map { length($0 - $1) }.max()!
            XCTAssertEqual(lowerMoved, 0, "blink descends the upper lid; the lower lid stays")
        }
        let eyeL = avatar.meshes.first { $0.id == "mesh.eyeL" }!
        let globe = attachments.eyes.first { $0.side == "left" }!
        let ref = attachments.lidEdges["upperL"]!
        let prim = head.primitives[ref.primitiveIndex]
        let blink = NativeAnimeFixture.morph(prim, "blink")
        for i in ref.indices {
            let p = prim.positions[i] + blink[i]
            XCTAssertGreaterThanOrEqual(length(p - globe.center), Double(globe.globeRadius) - 1e-4, "closed lid stays outside the globe")
        }
        XCTAssertFalse(eyeL.primitives[0].positions.isEmpty)
    }

    func testVisemesAreDistinctMouthOpenings() throws {
        let (avatar, attachments) = try NativeAnimeFixture.compiled()
        let head = avatar.meshes.first { $0.id == "mesh.head" }!
        let mouth = head.primitives[HeadPrimitive.mouth.rawValue]
        let lower = attachments.indices(of: "lipsLower", mesh: "mesh.head", primitive: HeadPrimitive.mouth.rawValue)
        for name in NativeAnimeMorphNames.visemes {
            let deltas = NativeAnimeFixture.morph(mouth, name)
            let drop = lower.map { -Double(deltas[$0].y) }.max()!
            XCTAssertGreaterThan(drop, 0.002, "\(name) opens the lower lip by \(drop * 1000) mm")
            let skinDeltas = NativeAnimeFixture.morph(head.primitives[HeadPrimitive.skin.rawValue], name)
            let jawDrop = skinDeltas.map { -Double($0.y) }.max()!
            XCTAssertGreaterThan(jawDrop, 0.0015, "\(name) drops the jaw")
            let innerDeltas = NativeAnimeFixture.morph(mouth, name)
            let cavity = attachments.indices(of: "innerMouth", mesh: "mesh.head", primitive: HeadPrimitive.mouth.rawValue)
            XCTAssertGreaterThan(cavity.map { length(innerDeltas[$0]) }.max()!, 0.0005, "\(name) opens the cavity")
        }
        let names = NativeAnimeMorphNames.visemes
        for i in 0..<names.count {
            for j in (i + 1)..<names.count {
                let a = NativeAnimeFixture.morph(mouth, names[i]), b = NativeAnimeFixture.morph(mouth, names[j])
                let diff = zip(a, b).map { length($0 - $1) }.max()!
                XCTAssertGreaterThan(diff, 0.002, "\(names[i]) vs \(names[j]) differ by only \(diff * 1000) mm")
            }
        }
        let aa = NativeAnimeFixture.morph(mouth, "aa"), ee = NativeAnimeFixture.morph(mouth, "ee"), ou = NativeAnimeFixture.morph(mouth, "ou")
        let corners = attachments.indices(of: "lipsUpper", mesh: "mesh.head", primitive: HeadPrimitive.mouth.rawValue)
            .filter { attachments.indices(of: "lipsLower", mesh: "mesh.head", primitive: HeadPrimitive.mouth.rawValue).contains($0) }
        XCTAssertEqual(corners.count, 4, "two corner columns on the outer and inner loops")
        let outerCorner = corners.max { abs(mouth.positions[$0].x) < abs(mouth.positions[$1].x) }!
        let sign = Double(mouth.positions[outerCorner].x).sign == .minus ? -1.0 : 1.0
        XCTAssertGreaterThan(Double(ee[outerCorner].x) * sign, 0, "ee widens the mouth")
        XCTAssertLessThan(Double(ou[outerCorner].x) * sign, 0, "ou narrows the mouth")
        XCTAssertGreaterThan(lower.map { -Double(aa[$0].y) }.max()!, lower.map { -Double(ee[$0].y) }.max()!, "aa opens wider than ee")
        XCTAssertGreaterThan(ou.map { Double($0.z) }.max()!, 0.001, "ou pouts forward")
    }

    func testEmotionsAreNonZeroAndPairwiseDistinct() throws {
        let (avatar, _) = try NativeAnimeFixture.compiled()
        let head = avatar.meshes.first { $0.id == "mesh.head" }!
        var signatures: [String: [SIMD3<Float>]] = [:]
        for name in NativeAnimeMorphNames.emotions {
            var all: [SIMD3<Float>] = []
            for p in head.primitives { all += NativeAnimeFixture.morph(p, name) }
            XCTAssertGreaterThan(all.map(length).max()!, 0.002, "\(name) is visible")
            signatures[name] = all
            XCTAssertGreaterThan(maxDelta(head.primitives[HeadPrimitive.brow.rawValue], name), 0, "\(name) moves the brows")
            XCTAssertGreaterThan(maxDelta(head.primitives[HeadPrimitive.mouth.rawValue], name), 0, "\(name) moves the mouth")
        }
        let names = NativeAnimeMorphNames.emotions
        for i in 0..<names.count {
            for j in (i + 1)..<names.count {
                let diff = zip(signatures[names[i]]!, signatures[names[j]]!).map { length($0 - $1) }.max()!
                XCTAssertGreaterThan(diff, 0.002, "\(names[i]) vs \(names[j])")
            }
        }
        let brow = head.primitives[HeadPrimitive.brow.rawValue]
        let angry = NativeAnimeFixture.morph(brow, "angry"), surprised = NativeAnimeFixture.morph(brow, "surprised"), sad = NativeAnimeFixture.morph(brow, "sad")
        XCTAssertLessThan(angry.map { Double($0.y) }.min()!, -0.003, "angry lowers the inner brow")
        XCTAssertGreaterThan(surprised.map { Double($0.y) }.min()!, 0.005, "surprised raises the whole brow")
        XCTAssertGreaterThan(sad.map { Double($0.y) }.max()!, 0.003, "sad raises the inner brow")
        let lash = head.primitives[HeadPrimitive.eyelash.rawValue]
        XCTAssertGreaterThan(maxDelta(lash, "relaxed"), 0.002, "relaxed half-closes the lids")
        XCTAssertGreaterThan(maxDelta(head.primitives[HeadPrimitive.eyeline.rawValue], "happy"), 0.001, "happy raises the lower lids")
    }

    func testExpressionPresetsBindHeadMorphsWithSpecFlags() throws {
        let (avatar, _) = try NativeAnimeFixture.compiled()
        let byPreset = Dictionary(uniqueKeysWithValues: avatar.expressions.map { ($0.preset!, $0) })
        XCTAssertEqual(byPreset.count, 14)
        let head = avatar.meshes.first { $0.id == "mesh.head" }!
        let morphNames = Set(head.primitives[0].morphTargets.map(\.name))
        for (preset, e) in byPreset {
            XCTAssertFalse(e.isBinary, preset.rawValue)
            XCTAssertNil(e.name)
            XCTAssertEqual(e.materialColorBinds, [])
            XCTAssertEqual(e.textureTransformBinds, [])
            if preset == .neutral {
                XCTAssertEqual(e.morphTargetBinds, [])
                continue
            }
            XCTAssertEqual(e.morphTargetBinds, [MorphTargetBind(mesh: "mesh.head", target: preset.rawValue, weight: 1)], preset.rawValue)
            XCTAssertTrue(morphNames.contains(preset.rawValue), preset.rawValue)
        }
        for preset: ExpressionPreset in [.aa, .ih, .ou, .ee, .oh] {
            XCTAssertEqual(byPreset[preset]!.overrideBlink, .none)
            XCTAssertEqual(byPreset[preset]!.overrideMouth, .none)
        }
        for preset: ExpressionPreset in [.happy, .angry, .sad, .relaxed, .surprised] { XCTAssertEqual(byPreset[preset]!.overrideMouth, .none) }
        for preset: ExpressionPreset in [.blink, .blinkLeft, .blinkRight] { XCTAssertFalse(byPreset[preset]!.isBinary) }
        for e in avatar.expressions { XCTAssertNoThrow(try e.validate()) }
    }

    func testMorphsSurviveShapeControls() throws {
        let (avatar, attachments) = try NativeAnimeFixture.compiled { r in
            r.face["face.eye.left.height"] = 1
            r.face["face.eye.right.width"] = -1
            r.face["face.eye.left.tilt"] = 1
            r.face["face.mouth.width"] = 1
            r.face["face.chin.length"] = 1
            r.body["body.heightM"] = 1.9
        }
        let head = avatar.meshes.first { $0.id == "mesh.head" }!
        for key in ["L", "R"] {
            let upper = attachments.lidEdges["upper\(key)"]!, lower = attachments.lidEdges["lower\(key)"]!
            let up = head.primitives[upper.primitiveIndex], lo = head.primitives[lower.primitiveIndex]
            let blinkUp = NativeAnimeFixture.morph(up, "blink"), blinkLo = NativeAnimeFixture.morph(lo, "blink")
            let closed = zip(upper.indices, lower.indices).map { length((up.positions[$0] + blinkUp[$0]) - (lo.positions[$1] + blinkLo[$1])) }.max()!
            XCTAssertLessThan(closed, 0.001, "eye \(key) still closes with shape controls applied")
        }
        NativeAnimeGeometryTests.assertValid(avatar)
    }
}
