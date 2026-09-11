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

final class SchemaHashStabilityTests: XCTestCase {
    func testExactlyThirtyFiveOperationsInAllowlistOrder() {
        let registry = Registry.v1()
        XCTAssertEqual(registry.operations.count, 35)
        XCTAssertEqual(Registry.v1Names.count, 35)
        XCTAssertEqual(registry.names, Registry.v1Names)
        XCTAssertEqual(Set(registry.operations.keys), Set(Registry.v1Names))
    }

    func testRequestAndResultSchemaHashesAreStableAcrossBuilds() throws {
        let first = Registry.v1()
        let second = Registry.v1()
        for name in Registry.v1Names {
            let a = first.operation(named: name)!
            let b = second.operation(named: name)!
            XCTAssertEqual(a.schemaHash, b.schemaHash, name)
            XCTAssertEqual(a.resultSchemaHash, b.resultSchemaHash, name)
            XCTAssertEqual(a.schemaHash.count, 64)
            XCTAssertEqual(a.schemaHash, try CanonicalJSON.sha256(a.requestSchema.json))
        }
        let hashes = Set(first.ordered.map(\.schemaHash))
        let bodies = Set(try first.ordered.map { try CanonicalJSON.string($0.requestSchema.json) })
        XCTAssertEqual(hashes.count, bodies.count, "hash equality must coincide with schema equality")
        XCTAssertEqual(first.operation(named: "version")?.schemaHash, first.operation(named: "doctor")?.schemaHash, "argument-free operations share one request schema")
        XCTAssertEqual(hashes.count, 34)
    }

    func testCommonFieldsAttachedPerKind() {
        let registry = Registry.v1()
        for op in registry.ordered {
            let props = op.requestSchema.properties
            let required = Set(op.requestSchema.requiredKeys)
            XCTAssertNotNil(props["format"], op.name)
            XCTAssertNotNil(props["logLevel"], op.name)
            XCTAssertNotNil(props["requestId"], op.name)
            XCTAssertEqual(op.requestSchema.json["additionalProperties"], false, op.name)
            switch op.kind {
            case .projectFree:
                XCTAssertNil(props["expectedRevision"], op.name)
                if op.name != "serve", op.name != "style lint" { XCTAssertNil(props["project"], op.name) }
            case .read:
                XCTAssertTrue(required.contains("project"), op.name)
                XCTAssertNil(props["expectedRevision"], op.name)
                XCTAssertNotNil(props["threads"], op.name)
            case .mutation:
                XCTAssertTrue(required.contains("project"), op.name)
                XCTAssertNotNil(props["expectedRevision"], op.name)
                XCTAssertNotNil(props["dryRun"], op.name)
                XCTAssertNotNil(props["expectedPlanHash"], op.name)
            }
        }
        for name in ["recipe export", "build", "qa plan", "qa run", "export vrm", "export verify", "deliver"] {
            let op = registry.operation(named: name)!
            XCTAssertTrue(op.requestSchema.requiredKeys.contains("out"), name)
            XCTAssertNotNil(op.requestSchema.properties["replace"], name)
        }
    }

    func testRequiredEvidenceMirrorsCommandsTable() {
        let registry = Registry.v1()
        let visual = ["control set", "recipe apply", "material shading", "build", "export vrm"]
        for op in registry.ordered {
            if visual.contains(op.name) {
                XCTAssertEqual(op.requiredEvidence, .visuallyValidated, op.name)
            } else if op.name == "style lint" {
                XCTAssertEqual(op.requiredEvidence, .corpusValidated)
            } else {
                XCTAssertEqual(op.requiredEvidence, .fixtureTested, op.name)
            }
        }
    }

    func testRpcMethodMapping() {
        let registry = Registry.v1()
        XCTAssertEqual(registry.operation(named: "recipe apply")?.rpcMethod, "recipe.apply")
        XCTAssertEqual(registry.operation(named: "version")?.rpcMethod, "version")
        XCTAssertEqual(registry.operation(rpcMethod: "schema.show")?.name, "schema show")
    }

    func testInstallRejectsUnknownAndDuplicateHandlers() {
        var registry = Registry.v1()
        XCTAssertThrowsError(try registry.install(handler: { _, r in .succeeded(requestId: r["requestId"]?.string, result: nil) }, for: "nope"))
        XCTAssertThrowsError(try registry.install(handler: { _, r in .succeeded(requestId: r["requestId"]?.string, result: nil) }, for: "version"))
        XCTAssertNoThrow(try registry.install(handler: { _, r in .succeeded(requestId: r["requestId"]?.string, result: ["ok": true]) }, for: "build"))
        XCTAssertTrue(registry.operation(named: "build")!.isRunnable)
    }

    func testSchemaOnlyRegistryHasNoHandlers() {
        XCTAssertTrue(Registry.v1SchemaOnly().ordered.allSatisfy { !$0.isRunnable })
        XCTAssertEqual(Registry.v1().ordered.filter(\.isRunnable).map(\.name).sorted(), (DiscoveryHandlers.names + ProjectHandlers.names).sorted())
    }

    func testDispatchOrderUnknownThenHandlerThenSchema() {
        let registry = Registry.v1()
        let context = OperationContext(cwd: URL(fileURLWithPath: NSTemporaryDirectory()), registry: registry)
        XCTAssertEqual(registry.invoke("nope", request: [:], context: context).exitCode, .invalidRequest)
        let missing = registry.invoke("build", request: [:], context: context)
        XCTAssertEqual(missing.exitCode, .missingCapability)
        XCTAssertEqual(missing.errors.first?.code, .notImplemented)
        let invalid = registry.invoke("schema show", request: ["bogus": 1], context: context)
        XCTAssertEqual(invalid.exitCode, .invalidRequest)
        XCTAssertEqual(Set(invalid.errors.map { $0.code }), [.invalidRequest, .unknownField])
        XCTAssertEqual(registry.invoke("version", request: ["requestId": "r"], context: context).requestId, "r")
    }

    func testHandlerThrownErrorsMapToStructuredEnvelopes() throws {
        var registry = Registry.v1SchemaOnly()
        try registry.install(handler: { _, _ in
            throw ModelValidationError(errors: [AuthorError.unknownField("/recipe/extra"), AuthorError.invalidRequest("bad range", path: "/recipe/seed")])
        }, for: "history restore")
        try registry.install(handler: { _, _ in throw AuthorError(code: .revisionConflict, message: "stale") }, for: "control set")
        try registry.install(handler: { _, _ in throw CocoaError(.fileNoSuchFile) }, for: "object set")
        let context = OperationContext(cwd: URL(fileURLWithPath: NSTemporaryDirectory()), registry: registry)
        let validation = registry.invoke("history restore", request: ["project": "p", "revision": 0, "requestId": "v"], context: context)
        XCTAssertEqual(validation.exitCode, .invalidRequest)
        XCTAssertEqual(validation.errors.count, 2)
        XCTAssertEqual(validation.errors.map { $0.code }, [.unknownField, .invalidRequest])
        XCTAssertEqual(validation.requestId, "v")
        XCTAssertEqual(registry.invoke("control set", request: ["project": "p", "edit": ["object": "a", "values": ["k": 1]]], context: context).exitCode, .conflict)
        let internalError = registry.invoke("object set", request: ["project": "p", "edit": ["id": "a", "values": ["/k": 1]]], context: context)
        XCTAssertEqual(internalError.exitCode, .internalError)
        XCTAssertEqual(internalError.errors.first?.code, .internalError)
    }

    func testModelSchemasAreHashStableAndDistinct() {
        let a = ModelSchemas.byName.mapValues(\.schemaHash)
        let b = ModelSchemas.byName.mapValues(\.schemaHash)
        XCTAssertEqual(a, b)
        XCTAssertTrue(a.keys.contains("Material"))
        XCTAssertTrue(a.keys.contains("Recipe"))
        XCTAssertEqual(a["Layer"], a["TextureLayer"])
    }
}
