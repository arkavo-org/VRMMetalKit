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

/// Every request-facing model: schema-validated, defaults applied from the
/// schema, decoded through synthesized Codable, then semantically validated.
public protocol AuthorModel: Codable, Hashable, Sendable {
    static var modelName: String { get }
    static var schema: JSONSchema { get }
    func validate() throws
}

public struct ModelValidationError: Error, CustomStringConvertible, Sendable {
    public let errors: [AuthorError]
    public init(errors: [AuthorError]) { self.errors = errors }
    public var description: String { errors.map { $0.errorDescription ?? $0.message }.joined(separator: "; ") }
}

extension AuthorModel {
    public static func decode(_ json: JSONValue) throws -> Self {
        let violations = Self.schema.validate(json)
        if !violations.isEmpty { throw ModelValidationError(errors: violations.map { $0.authorError }) }
        let filled = Self.schema.applyingDefaults(to: json)
        let model: Self
        do {
            model = try JSONDecoder().decode(Self.self, from: try CanonicalJSON.data(filled))
        } catch {
            throw ModelValidationError(errors: [AuthorError.invalidRequest("\(Self.modelName) could not be decoded: \(error)")])
        }
        try model.validate()
        return model
    }

    public static func decode(_ data: Data) throws -> Self { try decode(try JSONValue.parse(data)) }

    public func jsonValue() throws -> JSONValue { try JSONValue.from(self) }
    public func validate() throws {}
}

enum ModelCheck {
    static func finite(_ values: [Double], _ path: String) throws {
        for (i, v) in values.enumerated() where !v.isFinite {
            throw AuthorError.invalidRequest("Non-finite value at \(path)/\(i).", path: "\(path)/\(i)")
        }
    }

    static func finite(_ value: Double, _ path: String) throws {
        guard value.isFinite else { throw AuthorError.invalidRequest("Non-finite value at \(path).", path: path) }
    }

    static func count(_ values: [Double], _ n: Int, _ path: String) throws {
        guard values.count == n else {
            throw AuthorError.invalidRequest("Expected exactly \(n) elements at \(path).", path: path, observed: .number(Double(values.count)), required: .number(Double(n)))
        }
        try finite(values, path)
    }

    static func range(_ value: Double, _ lo: Double, _ hi: Double, _ path: String) throws {
        try finite(value, path)
        guard value >= lo, value <= hi else {
            throw AuthorError.invalidRequest("Value at \(path) must be within [\(lo), \(hi)].", path: path, observed: .number(value), required: [.number(lo), .number(hi)])
        }
    }

    static func uniqueIds(_ ids: [String], _ path: String) throws {
        var seen = Set<String>()
        for id in ids {
            guard seen.insert(id).inserted else { throw AuthorError.invalidRequest("Duplicate id '\(id)' at \(path).", path: path, observed: .string(id)) }
        }
    }
}

extension JSONSchema {
    static let id = JSONSchema.string(minLength: 1, description: "Stable project identifier")
    static let hash = JSONSchema.string(pattern: "^[0-9a-f]{64}$", description: "Lowercase SHA-256 hex")
    static let path = JSONSchema.string(minLength: 1, description: "Filesystem path")
    static let bipolar = JSONSchema.number(minimum: -1, maximum: 1).unit("normalized").defaulting(to: 0)
    static let unit = JSONSchema.number(minimum: 0, maximum: 1).unit("normalized")
    static let idList = JSONSchema.array(of: .id)
}
