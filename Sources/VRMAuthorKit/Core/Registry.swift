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

public struct RegistryError: Error, CustomStringConvertible, Sendable, Equatable {
    public let description: String
}

/// The v1 operation table. Schemas live in Registry+Schemas.swift; handlers are
/// installed by the installers listed in Registry+Installers.swift.
public struct Registry: Sendable {
    public private(set) var operations: [String: Operation]

    public init(operations: [Operation]) {
        var table: [String: Operation] = [:]
        for op in operations { table[op.name] = op }
        self.operations = table
    }

    /// The 35 v1 command names from commands.md, in allowlist order.
    public static let v1Names: [String] = [
        "version", "describe", "capabilities", "doctor", "schema show", "serve",
        "project init", "project inspect", "history list", "history restore",
        "template list", "recipe export", "recipe apply",
        "control list", "control describe", "control set",
        "object list", "object get", "object set",
        "asset import", "asset inspect",
        "style attach", "style lint", "material shading",
        "build", "qa plan", "qa run",
        "inspection record", "inspection verify",
        "provenance inspect", "provenance resolve", "provenance verify",
        "export vrm", "export verify", "deliver",
    ]

    /// The complete v1 registry with every installer applied.
    public static func v1() -> Registry {
        var registry = Registry(operations: Registry.v1Operations())
        for installer in Registry.installers { installer(&registry) }
        return registry
    }

    /// The v1 registry with schemas only (no handlers).
    public static func v1SchemaOnly() -> Registry {
        Registry(operations: Registry.v1Operations())
    }

    public var names: [String] { Registry.v1Names.filter { operations[$0] != nil } + operations.keys.filter { !Registry.v1Names.contains($0) }.sorted() }
    public var ordered: [Operation] { names.compactMap { operations[$0] } }

    public func operation(named name: String) -> Operation? { operations[name] }
    public func operation(rpcMethod: String) -> Operation? { operations.values.first { $0.rpcMethod == rpcMethod } }

    /// Longest command-word match at the head of `words`; returns the operation and the remaining words.
    public func match(words: [String]) -> (Operation, [String])? {
        for length in stride(from: min(words.count, 3), through: 1, by: -1) {
            let candidate = words.prefix(length).joined(separator: " ")
            if let op = operations[candidate] { return (op, Array(words.dropFirst(length))) }
        }
        return nil
    }

    public mutating func install(handler: @escaping OperationHandler, for name: String) throws {
        guard var op = operations[name] else { throw RegistryError(description: "install(handler:for:): unknown operation '\(name)'") }
        guard op.handler == nil else { throw RegistryError(description: "install(handler:for:): operation '\(name)' already has a handler") }
        op.handler = handler
        operations[name] = op
    }

    public mutating func register(_ operation: Operation) throws {
        guard operations[operation.name] == nil else { throw RegistryError(description: "register: operation '\(operation.name)' already registered") }
        operations[operation.name] = operation
    }

    /// Dispatch order: unknown operation → INVALID_REQUEST (2); no handler →
    /// NOT_IMPLEMENTED (3); schema violations → 2; handler errors → envelope.
    public func invoke(_ name: String, request: JSONValue, context: OperationContext) -> ResultEnvelope {
        let requestId = request["requestId"]?.string
        guard let op = operations[name] else {
            return .failed(requestId: requestId, revision: nil, errors: [
                AuthorError(code: .invalidRequest, path: "/command", observed: .string(name), message: "Unknown command '\(name)'.", suggestedCommands: ["describe"]),
            ])
        }
        guard let handler = op.handler else {
            return .failed(requestId: requestId, revision: nil, errors: [AuthorError.notImplemented(name)])
        }
        let violations = op.requestSchema.requestErrors(for: request)
        if !violations.isEmpty {
            return .failed(requestId: requestId, revision: nil, errors: violations)
        }
        let filled = op.requestSchema.applyingDefaults(to: request)
        do {
            return try handler(context, filled)
        } catch let error as AuthorError {
            return .failed(requestId: requestId, revision: nil, errors: [error])
        } catch let error as ModelValidationError {
            return .failed(requestId: requestId, revision: nil, errors: error.errors)
        } catch {
            return .failed(requestId: requestId, revision: nil, errors: [AuthorError.internalError(error)])
        }
    }
}
