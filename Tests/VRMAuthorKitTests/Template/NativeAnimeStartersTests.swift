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

import XCTest
@testable import VRMAuthorKit

final class NativeAnimeStartersTests: XCTestCase {
    private let registry = TemplateRegistry.standard()

    func testEveryOverridePointerResolvesInTheDefaultRecipe() throws {
        let pack = try XCTUnwrap(registry.pack(id: NativeAnimeV1Pack.packId))
        let defaults = try pack.defaults.jsonValue()
        for base in NativeAnimeStarterBase.allCases {
            for override in NativeAnimeStarters.overrides(for: base) {
                let pointer = try JSONPointer(override.pointer)
                XCTAssertNotNil(pointer.get(in: defaults), "\(base): \(override.pointer) does not exist in the default recipe")
            }
        }
    }

    func testStartersValidateAndDifferOnlyByOverrides() throws {
        let pack = try XCTUnwrap(registry.pack(id: NativeAnimeV1Pack.packId))
        for base in NativeAnimeStarterBase.allCases {
            let recipe = try NativeAnimeStarters.starterRecipe(base: base, registry: registry)
            XCTAssertNoThrow(try recipe.validate())
            XCTAssertEqual(recipe.seed, 42)
            XCTAssertEqual(recipe.name, base.rawValue)
            XCTAssertEqual(recipe.template.sha256, pack.sha256)
            let json = try recipe.jsonValue()
            for override in NativeAnimeStarters.overrides(for: base) {
                XCTAssertEqual(try JSONPointer(override.pointer).get(in: json), override.value, "\(base): \(override.pointer)")
            }
            XCTAssertEqual(recipe.hair.first?.id, "hair.main")
            XCTAssertEqual(recipe.outfits.map(\.id), ["outfit.top", "outfit.bottom", "outfit.footwear"])
        }
        let female = try NativeAnimeStarters.starterRecipe(base: .female, registry: registry)
        let male = try NativeAnimeStarters.starterRecipe(base: .male, registry: registry)
        XCTAssertEqual(female.outfits[1].preset, "skirt-v1")
        XCTAssertEqual(male.outfits[1].preset, "bottom-v1")
        XCTAssertEqual(female.body["body.heightM"], 1.60)
        XCTAssertEqual(male.body["body.heightM"], 1.74)
        XCTAssertEqual(male.hair[0].controls.lengthM, 0.13)
    }

    func testOverridesStayInsidePublishedControlRanges() throws {
        let pack = try XCTUnwrap(registry.pack(id: NativeAnimeV1Pack.packId))
        for base in NativeAnimeStarterBase.allCases {
            let recipe = try NativeAnimeStarters.starterRecipe(base: base, registry: registry)
            for (key, value) in recipe.body.merging(recipe.face, uniquingKeysWith: { a, _ in a }) {
                let descriptor = try XCTUnwrap(pack.control(key), key)
                XCTAssertTrue(descriptor.accepts(value), "\(base): \(key)=\(value) outside \(descriptor.validRange)")
            }
        }
    }

    func testStartersCompile() throws {
        for base in NativeAnimeStarterBase.allCases {
            let recipe = try NativeAnimeStarters.starterRecipe(base: base, registry: registry)
            let pack = try XCTUnwrap(registry.pack(id: recipe.template.id))
            XCTAssertNoThrow(try pack.compile(recipe, seed: recipe.seed), "\(base)")
        }
    }

    func testUnknownPackIsMissingCapability() {
        XCTAssertThrowsError(try NativeAnimeStarters.starterRecipe(base: .female, registry: TemplateRegistry(packs: []))) { error in
            XCTAssertEqual((error as? AuthorError)?.code, .missingCapability)
        }
    }
}
