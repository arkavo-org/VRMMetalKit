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

final class ExitCodeTests: XCTestCase {
    func testMappingPerCommandsContract() {
        XCTAssertEqual(ExitCode.success.rawValue, 0)
        XCTAssertEqual(ExitCode.gateFailed.rawValue, 1)
        XCTAssertEqual(ExitCode.invalidRequest.rawValue, 2)
        XCTAssertEqual(ExitCode.missingCapability.rawValue, 3)
        XCTAssertEqual(ExitCode.conflict.rawValue, 4)
        XCTAssertEqual(ExitCode.internalError.rawValue, 5)
    }

    func testErrorCodeToExitCode() {
        XCTAssertEqual(AuthorErrorCode.invalidRequest.exitCode, .invalidRequest)
        XCTAssertEqual(AuthorErrorCode.unknownField.exitCode, .invalidRequest)
        XCTAssertEqual(AuthorErrorCode.conflictingArgument.exitCode, .invalidRequest)
        XCTAssertEqual(AuthorErrorCode.objectNotFound.exitCode, .invalidRequest)
        XCTAssertEqual(AuthorErrorCode.missingCapability.exitCode, .missingCapability)
        XCTAssertEqual(AuthorErrorCode.notImplemented.exitCode, .missingCapability)
        XCTAssertEqual(AuthorErrorCode.projectNotFound.exitCode, .missingCapability)
        XCTAssertEqual(AuthorErrorCode.missingInput.exitCode, .missingCapability)
        XCTAssertEqual(AuthorErrorCode.missingCredential.exitCode, .missingCapability)
        XCTAssertEqual(AuthorErrorCode.revisionConflict.exitCode, .conflict)
        XCTAssertEqual(AuthorErrorCode.requestIdReused.exitCode, .conflict)
        XCTAssertEqual(AuthorErrorCode.planHashMismatch.exitCode, .conflict)
        XCTAssertEqual(AuthorErrorCode.validationFailed.exitCode, .gateFailed)
        XCTAssertEqual(AuthorErrorCode.gateFailed.exitCode, .gateFailed)
        XCTAssertEqual(AuthorErrorCode.internalError.exitCode, .internalError)
        XCTAssertEqual(AuthorErrorCode.ioError.exitCode, .internalError)
    }

    func testEnvelopeExitCodes() {
        XCTAssertEqual(ResultEnvelope.succeeded(requestId: nil, result: nil).exitCode, .success)
        var warned = ResultEnvelope.succeeded(requestId: nil, result: nil)
        warned.warnings = [AuthorWarning(code: "STYLE_SHOULD", message: "soft")]
        XCTAssertEqual(warned.exitCode, .success)
        XCTAssertEqual(ResultEnvelope.failed(requestId: nil, revision: nil, errors: []).exitCode, .gateFailed)
        XCTAssertEqual(ResultEnvelope.failed(requestId: nil, revision: nil, errors: [AuthorError(code: .invalidRequest, message: "x")]).exitCode, .invalidRequest)
        XCTAssertEqual(ResultEnvelope.failed(requestId: nil, revision: nil, errors: [AuthorError(code: .validationFailed, message: "x"), AuthorError(code: .internalError, message: "y")]).exitCode, .internalError)
        XCTAssertEqual(ResultEnvelope.failed(requestId: nil, revision: nil, errors: [AuthorError(code: .revisionConflict, message: "x"), AuthorError(code: .invalidRequest, message: "y")]).exitCode, .conflict)
        XCTAssertEqual(ResultEnvelope.incomplete(requestId: nil, revision: nil, errors: [], result: nil).exitCode, .missingCapability)
        XCTAssertEqual(ResultEnvelope.incomplete(requestId: nil, revision: nil, errors: [AuthorError(code: .missingCredential, message: "no signer")], result: nil).exitCode, .missingCapability)
    }

    func testMostSevereWinsAcrossMixedErrors() {
        XCTAssertEqual(ExitCode.mostSevere([.invalidRequest, .conflict, .gateFailed]), .conflict)
        XCTAssertEqual(ExitCode.mostSevere([]), .success)
        XCTAssertEqual(ExitCode.mostSevere([.missingCapability, .internalError]), .internalError)
    }
}
