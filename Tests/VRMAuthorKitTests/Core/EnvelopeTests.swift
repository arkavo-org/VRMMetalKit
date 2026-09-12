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

final class EnvelopeTests: XCTestCase {
    func testSucceededEnvelopeCarriesEveryCommonField() throws {
        let envelope = ResultEnvelope.succeeded(requestId: "r-1", revisionBefore: 3, revisionAfter: 4, result: ["ok": true])
        let json = try envelope.jsonValue()
        XCTAssertEqual(json["protocol"], "vrmauthor/1")
        XCTAssertEqual(json["requestId"], "r-1")
        XCTAssertEqual(json["status"], "succeeded")
        XCTAssertEqual(json["revisionBefore"], 3)
        XCTAssertEqual(json["revisionAfter"], 4)
        XCTAssertEqual(json["artifacts"], [])
        XCTAssertEqual(json["warnings"], [])
        XCTAssertEqual(json["errors"], [])
        XCTAssertEqual(json["result"]?["ok"], true)
        XCTAssertNil(json["plan"])
    }

    func testProjectFreeEnvelopeUsesNullRevisions() throws {
        let json = try ResultEnvelope.succeeded(requestId: nil, result: nil).jsonValue()
        XCTAssertEqual(json["revisionBefore"], .null)
        XCTAssertEqual(json["revisionAfter"], .null)
        XCTAssertEqual(json["requestId"], .null)
    }

    func testFailedEnvelopeSerializesStructuredErrors() throws {
        let error = AuthorError(code: .revisionConflict, objectId: "avatar:main", path: "/revision", observed: 17, required: 18,
                                message: "Stale writer.", suggestedCommands: ["project inspect"], artifact: nil)
        let envelope = ResultEnvelope.failed(requestId: "fit-004", revision: 18, errors: [error])
        let json = try envelope.jsonValue()
        XCTAssertEqual(json["status"], "failed")
        XCTAssertEqual(json["revisionBefore"], 18)
        XCTAssertEqual(json["revisionAfter"], 18)
        let first = try XCTUnwrap(json["errors"]?[0])
        XCTAssertEqual(first["code"], "REVISION_CONFLICT")
        XCTAssertEqual(first["objectId"], "avatar:main")
        XCTAssertEqual(first["path"], "/revision")
        XCTAssertEqual(first["observed"], 17)
        XCTAssertEqual(first["required"], 18)
        XCTAssertEqual(first["message"], "Stale writer.")
        XCTAssertEqual(first["suggestedCommands"], ["project inspect"])
        XCTAssertNil(first["artifact"])
    }

    func testArtifactRefAndPlanRoundTrip() throws {
        let artifact = ArtifactRef(path: "builds/abc/avatar.vrm", sha256: String(repeating: "a", count: 64), mediaType: "model/gltf-binary",
                                   sizeBytes: 1234, role: "draft-vrm", buildHash: String(repeating: "b", count: 64))
        let plan = Plan(planHash: String(repeating: "c", count: 64), baseRevision: 2,
                        edits: [PlanEdit(objectId: "hair:main", pointer: "/controls/lengthM", before: 0.18, after: 0.2)],
                        invalidations: ["hair:main/bones"], prerequisites: [], cost: ["cpuSeconds": 1])
        var envelope = ResultEnvelope.succeeded(requestId: "p", revisionBefore: 2, revisionAfter: 2, result: nil)
        envelope.artifacts = [artifact]
        envelope.plan = plan
        let data = try envelope.canonicalData()
        let decoded = try JSONDecoder().decode(ResultEnvelope.self, from: data)
        XCTAssertEqual(decoded, envelope)
        let json = try JSONValue.parse(data)
        XCTAssertEqual(json["artifacts"]?[0]?["buildHash"], .string(String(repeating: "b", count: 64)))
        XCTAssertEqual(json["plan"]?["edits"]?[0]?["pointer"], "/controls/lengthM")
    }

    func testEnvelopeEncodesDeterministically() throws {
        let envelope = ResultEnvelope.succeeded(requestId: "z", result: ["b": 1, "a": [1, 2]])
        XCTAssertEqual(try envelope.canonicalData(), try envelope.canonicalData())
        XCTAssertTrue(String(decoding: try envelope.canonicalData(), as: UTF8.self).hasPrefix(#"{"artifacts":[],"errors":[],"plan":null"#) == false)
        let text = String(decoding: try envelope.canonicalData(), as: UTF8.self)
        XCTAssertFalse(text.contains("\n"))
        XCTAssertTrue(text.contains(#""protocol":"vrmauthor/1""#))
    }

    func testAuthorErrorCodesAreExtensibleStrings() {
        let custom = AuthorErrorCode(rawValue: "GARMENT_PENETRATION")
        XCTAssertEqual(custom.exitCode, .gateFailed)
        XCTAssertEqual(AuthorErrorCode.invalidRequest.rawValue, "INVALID_REQUEST")
        XCTAssertEqual(AuthorErrorCode.unknownField.rawValue, "UNKNOWN_FIELD")
        XCTAssertEqual(AuthorErrorCode.conflictingArgument.rawValue, "CONFLICTING_ARGUMENT")
        XCTAssertEqual(AuthorErrorCode.missingCapability.rawValue, "MISSING_CAPABILITY")
        XCTAssertEqual(AuthorErrorCode.revisionConflict.rawValue, "REVISION_CONFLICT")
        XCTAssertEqual(AuthorErrorCode.requestIdReused.rawValue, "REQUEST_ID_REUSED")
        XCTAssertEqual(AuthorErrorCode.planHashMismatch.rawValue, "PLAN_HASH_MISMATCH")
        XCTAssertEqual(AuthorErrorCode.notImplemented.rawValue, "NOT_IMPLEMENTED")
        XCTAssertEqual(AuthorErrorCode.projectNotFound.rawValue, "PROJECT_NOT_FOUND")
        XCTAssertEqual(AuthorErrorCode.objectNotFound.rawValue, "OBJECT_NOT_FOUND")
        XCTAssertEqual(AuthorErrorCode.validationFailed.rawValue, "VALIDATION_FAILED")
        XCTAssertEqual(AuthorErrorCode.internalError.rawValue, "INTERNAL")
    }
}
