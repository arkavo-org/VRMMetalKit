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

final class JSONSchemaTests: XCTestCase {
    private let schema = JSONSchema.object(
        properties: [
            "name": .string().described("Display name"),
            "count": .integer(minimum: 1, maximum: 10).defaulting(to: 3),
            "ratio": .number(minimum: -1, maximum: 1).unit("normalized"),
            "mode": .enumeration(["a", "b"]).defaulting(to: "a"),
            "tags": .array(of: .string(), minItems: 1),
            "shape": .oneOf([
                .object(properties: ["sphere": .object(properties: ["radius": .number(minimum: 0)], required: ["radius"])], required: ["sphere"]),
                .object(properties: ["capsule": .object(properties: ["radius": .number(minimum: 0), "tail": .array(of: .number(), minItems: 3, maxItems: 3)], required: ["radius", "tail"])], required: ["capsule"]),
            ]),
            "version": .const("1.0"),
            "flag": .boolean().defaulting(to: false),
        ],
        required: ["name", "version"]
    )

    func testBuilderEmitsDraft2020Subset() throws {
        let json = schema.json
        XCTAssertEqual(json["type"], "object")
        XCTAssertEqual(json["additionalProperties"], false)
        XCTAssertEqual(json["required"], ["name", "version"])
        XCTAssertEqual(json["properties"]?["count"]?["type"], "integer")
        XCTAssertEqual(json["properties"]?["count"]?["minimum"], 1)
        XCTAssertEqual(json["properties"]?["count"]?["default"], 3)
        XCTAssertEqual(json["properties"]?["ratio"]?["x-unit"], "normalized")
        XCTAssertEqual(json["properties"]?["mode"]?["enum"], ["a", "b"])
        XCTAssertEqual(json["properties"]?["tags"]?["items"]?["type"], "string")
        XCTAssertEqual(json["properties"]?["version"]?["const"], "1.0")
        XCTAssertEqual(json["properties"]?["shape"]?["oneOf"]?.array?.count, 2)
        XCTAssertEqual(json["properties"]?["name"]?["description"], "Display name")
    }

    func testSchemaHashIsStableAndSensitive() {
        let again = JSONSchema.object(properties: ["name": .string().described("Display name")], required: ["name"])
        XCTAssertEqual(again.schemaHash, JSONSchema.object(properties: ["name": .string().described("Display name")], required: ["name"]).schemaHash)
        XCTAssertNotEqual(again.schemaHash, JSONSchema.object(properties: ["name": .string()], required: ["name"]).schemaHash)
        XCTAssertEqual(schema.schemaHash.count, 64)
        XCTAssertEqual(JSONSchema.object(properties: [:], required: ["b", "a"]).schemaHash, JSONSchema.object(properties: [:], required: ["a", "b"]).schemaHash)
    }

    func testValidInstancePasses() {
        let ok: JSONValue = ["name": "x", "version": "1.0", "count": 5, "ratio": 0.5, "mode": "b", "tags": ["t"], "shape": ["sphere": ["radius": 0.1]], "flag": true]
        XCTAssertEqual(schema.validate(ok), [])
    }

    func testViolationsCarryPointersAndKeywords() {
        let bad: JSONValue = ["name": 1, "count": 11, "ratio": 2, "mode": "z", "tags": [], "extra": 1, "shape": ["sphere": ["radius": -1]], "version": "2.0"]
        let violations = schema.validate(bad)
        let byPointer = Dictionary(grouping: violations, by: { $0.pointer })
        XCTAssertEqual(byPointer["/name"]?.first?.keyword, "type")
        XCTAssertEqual(byPointer["/count"]?.first?.keyword, "maximum")
        XCTAssertEqual(byPointer["/ratio"]?.first?.keyword, "maximum")
        XCTAssertEqual(byPointer["/mode"]?.first?.keyword, "enum")
        XCTAssertEqual(byPointer["/tags"]?.first?.keyword, "minItems")
        XCTAssertEqual(byPointer["/extra"]?.first?.keyword, "additionalProperties")
        XCTAssertEqual(byPointer["/shape"]?.first?.keyword, "oneOf")
        XCTAssertEqual(byPointer["/version"]?.first?.keyword, "const")
        XCTAssertEqual(schema.validate(["version": "1.0"]).first?.keyword, "required")
        XCTAssertEqual(schema.validate(["version": "1.0"]).first?.pointer, "")
        XCTAssertEqual(byPointer["/extra"]?.first?.authorError.code, .unknownField)
        XCTAssertEqual(byPointer["/count"]?.first?.authorError.code, .invalidRequest)
        XCTAssertEqual(byPointer["/count"]?.first?.authorError.observed, 11)
        XCTAssertEqual(byPointer["/count"]?.first?.authorError.required, 10)
    }

    func testIntegerRejectsFractionsAndOneOfRejectsAmbiguity() {
        XCTAssertEqual(schema.validate(["name": "x", "version": "1.0", "count": 2.5]).first?.keyword, "type")
        let ambiguous = JSONSchema.oneOf([.number(), .number(minimum: 0)])
        XCTAssertEqual(ambiguous.validate(1).first?.keyword, "oneOf")
        XCTAssertEqual(ambiguous.validate(-1), [])
        XCTAssertEqual(JSONSchema.string(pattern: "^[a-z]+$").validate("abc"), [])
        XCTAssertEqual(JSONSchema.string(pattern: "^[a-z]+$").validate("ABC").first?.keyword, "pattern")
    }

    func testApplyingDefaultsFillsMissingPropertiesRecursively() throws {
        let filled = schema.applyingDefaults(to: ["name": "x", "version": "1.0", "shape": ["capsule": ["radius": 0, "tail": [0, 0, 1]]]])
        XCTAssertEqual(filled["count"], 3)
        XCTAssertEqual(filled["mode"], "a")
        XCTAssertEqual(filled["flag"], false)
        XCTAssertNil(filled["tags"])
        XCTAssertEqual(filled["name"], "x")
        let nested = JSONSchema.object(properties: ["inner": .object(properties: ["v": .number().defaulting(to: 7)], required: [])], required: [])
        XCTAssertEqual(nested.applyingDefaults(to: ["inner": [:]])["inner"]?["v"], 7)
        XCTAssertNil(nested.applyingDefaults(to: [:])["inner"])
        let arrays = JSONSchema.array(of: .object(properties: ["v": .number().defaulting(to: 1)], required: []))
        XCTAssertEqual(arrays.applyingDefaults(to: [[:], ["v": 2]]), [["v": 1], ["v": 2]])
    }

    func testLeafPointersEnumerateEveryLeaf() {
        let leaves = schema.leafPointers()
        XCTAssertTrue(leaves.contains("/name"))
        XCTAssertTrue(leaves.contains("/shape/sphere/radius"))
        XCTAssertTrue(leaves.contains("/shape/capsule/tail"))
        XCTAssertTrue(leaves.contains("/tags"))
        XCTAssertFalse(leaves.contains("/shape"))
    }

    func testValidateAsRequestMapsToAuthorErrors() {
        let errors = schema.requestErrors(for: ["version": "1.0", "bogus": true])
        XCTAssertEqual(Set(errors.map { $0.code }), [.invalidRequest, .unknownField])
        XCTAssertTrue(errors.contains { $0.path == "/bogus" })
    }
}
