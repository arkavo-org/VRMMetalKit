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

/// Bone-derived proportion metrics of the pack default and both starters,
/// checked against the corpus envelope recorded in the pinned profile's rule
/// provenance rather than against the (deliberately loose) rule ranges.
final class NativeAnimeProportionTests: XCTestCase {
    struct Envelope { var min: Double; var max: Double }

    static func envelopes() throws -> [String: Envelope] {
        let url = MaterialsTestSupport.repoRoot.appendingPathComponent(StyleToolchain.profileRelativePath)
        let profile = try JSONValue.parse(try Data(contentsOf: url))
        var out: [String: Envelope] = [:]
        for rule in profile["rules"]?.array ?? [] {
            guard let metric = rule["metric"]?.string, let lo = rule["provenance"]?["min"]?.number, let hi = rule["provenance"]?["max"]?.number else { continue }
            out[metric] = Envelope(min: lo, max: hi)
        }
        return out
    }

    static func metrics(_ layout: NativeAnimeLayout) -> [String: Double] {
        let H = layout.height
        func d(_ a: VRMHumanBone, _ b: VRMHumanBone) -> Double { NAMath.length(layout.joint(a) - layout.joint(b)) }
        return [
            "proportions.shoulder_width_ratio": d(.leftUpperArm, .rightUpperArm) / H,
            "proportions.arm_span_height_ratio": d(.leftHand, .rightHand) / H,
            "proportions.hips_height_ratio": layout.joint(.hips).y / H,
            "proportions.upper_leg_height_ratio": layout.joint(.leftUpperLeg).y / H,
            "proportions.lower_upper_arm_ratio": d(.leftLowerArm, .leftHand) / d(.leftUpperArm, .leftLowerArm),
            "proportions.lower_upper_leg_ratio": d(.leftLowerLeg, .leftFoot) / d(.leftUpperLeg, .leftLowerLeg),
            "proportions.eye_height_ratio": layout.joint(.leftEye).y / H,
        ]
    }

    func testDefaultAndStartersSitInsideTheCorpusEnvelope() throws {
        let envelopes = try Self.envelopes()
        XCTAssertGreaterThanOrEqual(envelopes.count, 12)
        let registry = TemplateRegistry.standard()
        var recipes = [("default", NativeAnimeFixture.pack.defaults)]
        for base in NativeAnimeStarterBase.allCases { recipes.append((base.rawValue, try NativeAnimeStarters.starterRecipe(base: base, registry: registry))) }
        for (name, recipe) in recipes {
            let layout = NativeAnimeLayout(controls: try NativeAnimeControlSet(body: recipe.body, face: recipe.face))
            for (metric, value) in Self.metrics(layout) {
                let env = try XCTUnwrap(envelopes[metric], metric)
                XCTAssertGreaterThanOrEqual(value, env.min, "\(name) \(metric) = \(value) below corpus min \(env.min)")
                XCTAssertLessThanOrEqual(value, env.max, "\(name) \(metric) = \(value) above corpus max \(env.max)")
            }
        }
    }
}
