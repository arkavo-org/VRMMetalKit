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

/// Error code vocabulary. A struct rather than an enum so later phases can add
/// codes in their own files (`extension AuthorErrorCode { static let ... }`).
/// Codes without an explicit exit mapping are completed evaluations with a
/// failed gate (exit 1).
public struct AuthorErrorCode: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }

    public static let invalidRequest: AuthorErrorCode = "INVALID_REQUEST"
    public static let unknownField: AuthorErrorCode = "UNKNOWN_FIELD"
    public static let conflictingArgument: AuthorErrorCode = "CONFLICTING_ARGUMENT"
    public static let objectNotFound: AuthorErrorCode = "OBJECT_NOT_FOUND"
    public static let missingCapability: AuthorErrorCode = "MISSING_CAPABILITY"
    public static let notImplemented: AuthorErrorCode = "NOT_IMPLEMENTED"
    public static let projectNotFound: AuthorErrorCode = "PROJECT_NOT_FOUND"
    public static let missingInput: AuthorErrorCode = "MISSING_INPUT"
    public static let missingCredential: AuthorErrorCode = "MISSING_CREDENTIAL"
    public static let revisionConflict: AuthorErrorCode = "REVISION_CONFLICT"
    public static let requestIdReused: AuthorErrorCode = "REQUEST_ID_REUSED"
    public static let planHashMismatch: AuthorErrorCode = "PLAN_HASH_MISMATCH"
    public static let validationFailed: AuthorErrorCode = "VALIDATION_FAILED"
    public static let gateFailed: AuthorErrorCode = "GATE_FAILED"
    public static let staleDependency: AuthorErrorCode = "STALE_DEPENDENCY"
    public static let internalError: AuthorErrorCode = "INTERNAL"
    public static let ioError: AuthorErrorCode = "IO_ERROR"

    public var exitCode: ExitCode {
        switch self {
        case .invalidRequest, .unknownField, .conflictingArgument, .objectNotFound: return .invalidRequest
        case .missingCapability, .notImplemented, .projectNotFound, .missingInput, .missingCredential: return .missingCapability
        case .revisionConflict, .requestIdReused, .planHashMismatch: return .conflict
        case .internalError, .ioError: return .internalError
        default: return .gateFailed
        }
    }
}

/// Structured, actionable failure as defined in commands.md and README §4.
public struct AuthorError: Error, Codable, Hashable, Sendable, LocalizedError {
    public var code: AuthorErrorCode
    public var objectId: String?
    public var path: String?
    public var observed: JSONValue?
    public var required: JSONValue?
    public var message: String
    public var suggestedCommands: [String]
    public var artifact: String?

    public init(code: AuthorErrorCode, objectId: String? = nil, path: String? = nil, observed: JSONValue? = nil,
                required: JSONValue? = nil, message: String, suggestedCommands: [String] = [], artifact: String? = nil) {
        self.code = code
        self.objectId = objectId
        self.path = path
        self.observed = observed
        self.required = required
        self.message = message
        self.suggestedCommands = suggestedCommands
        self.artifact = artifact
    }

    public var errorDescription: String? { "\(code.rawValue): \(message)" }

    public static func invalidRequest(_ message: String, path: String? = nil, observed: JSONValue? = nil, required: JSONValue? = nil) -> AuthorError {
        AuthorError(code: .invalidRequest, path: path, observed: observed, required: required, message: message, suggestedCommands: ["describe", "schema show"])
    }

    public static func unknownField(_ path: String, observed: JSONValue? = nil) -> AuthorError {
        AuthorError(code: .unknownField, path: path, observed: observed, message: "Unknown field \(path).", suggestedCommands: ["describe", "schema show"])
    }

    public static func notImplemented(_ operation: String) -> AuthorError {
        AuthorError(code: .notImplemented, path: nil, message: "Operation '\(operation)' is registered schema-only; no handler is installed in this build.",
                    suggestedCommands: ["capabilities", "describe \(operation)"])
    }

    public static func internalError(_ error: any Error) -> AuthorError {
        if let author = error as? AuthorError { return author }
        return AuthorError(code: .internalError, message: String(describing: error))
    }
}

public struct AuthorWarning: Codable, Hashable, Sendable {
    public var code: String
    public var message: String
    public var path: String?

    public init(code: String, message: String, path: String? = nil) {
        self.code = code
        self.message = message
        self.path = path
    }
}
