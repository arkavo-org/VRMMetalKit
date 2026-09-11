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

public struct SchemaViolation: Hashable, Sendable {
    public var pointer: String
    public var keyword: String
    public var message: String
    public var observed: JSONValue?
    public var required: JSONValue?

    public var authorError: AuthorError {
        let code: AuthorErrorCode = keyword == "additionalProperties" ? .unknownField : .invalidRequest
        return AuthorError(code: code, path: pointer.isEmpty ? "/" : pointer, observed: observed, required: required, message: message,
                           suggestedCommands: ["describe", "schema show"])
    }
}

/// JSON Schema draft 2020-12 subset used for every request, result and model
/// schema: type, properties, required, additionalProperties:false, items,
/// minItems/maxItems, enum, const, minimum/maximum, exclusiveMinimum/Maximum,
/// pattern, minLength, oneOf, description, default and the `x-unit` annotation.
public struct JSONSchema: Hashable, Sendable {
    public var json: JSONValue

    public init(json: JSONValue) { self.json = json }

    private init(_ fields: [String: JSONValue]) { self.json = .object(fields) }

    // MARK: Builders

    public static func object(properties: [String: JSONSchema], required: [String], additionalProperties: Bool = false, description: String? = nil) -> JSONSchema {
        var fields: [String: JSONValue] = ["type": "object", "additionalProperties": .bool(additionalProperties)]
        fields["properties"] = .object(properties.mapValues { $0.json })
        fields["required"] = JSONValue(required.sorted())
        if let description { fields["description"] = .string(description) }
        return JSONSchema(fields)
    }

    /// An object whose keys are free but whose values share one schema.
    public static func map(of values: JSONSchema, description: String? = nil) -> JSONSchema {
        var fields: [String: JSONValue] = ["type": "object", "additionalProperties": values.json]
        if let description { fields["description"] = .string(description) }
        return JSONSchema(fields)
    }

    public static func string(pattern: String? = nil, minLength: Int? = nil, description: String? = nil) -> JSONSchema {
        var fields: [String: JSONValue] = ["type": "string"]
        if let pattern { fields["pattern"] = .string(pattern) }
        if let minLength { fields["minLength"] = .number(Double(minLength)) }
        if let description { fields["description"] = .string(description) }
        return JSONSchema(fields)
    }

    public static func enumeration(_ values: [String], description: String? = nil) -> JSONSchema {
        var fields: [String: JSONValue] = ["type": "string", "enum": JSONValue(values)]
        if let description { fields["description"] = .string(description) }
        return JSONSchema(fields)
    }

    /// Every case of a string-backed enum, in declaration order.
    public static func enumeration<E: RawRepresentable & CaseIterable>(of type: E.Type, description: String? = nil) -> JSONSchema where E.RawValue == String {
        enumeration(E.allCases.map(\.rawValue), description: description)
    }

    public static func number(minimum: Double? = nil, maximum: Double? = nil, exclusiveMinimum: Double? = nil, exclusiveMaximum: Double? = nil, description: String? = nil) -> JSONSchema {
        var fields: [String: JSONValue] = ["type": "number"]
        if let minimum { fields["minimum"] = .number(minimum) }
        if let maximum { fields["maximum"] = .number(maximum) }
        if let exclusiveMinimum { fields["exclusiveMinimum"] = .number(exclusiveMinimum) }
        if let exclusiveMaximum { fields["exclusiveMaximum"] = .number(exclusiveMaximum) }
        if let description { fields["description"] = .string(description) }
        return JSONSchema(fields)
    }

    public static func integer(minimum: Int? = nil, maximum: Int? = nil, description: String? = nil) -> JSONSchema {
        var fields: [String: JSONValue] = ["type": "integer"]
        if let minimum { fields["minimum"] = .number(Double(minimum)) }
        if let maximum { fields["maximum"] = .number(Double(maximum)) }
        if let description { fields["description"] = .string(description) }
        return JSONSchema(fields)
    }

    public static func boolean(description: String? = nil) -> JSONSchema {
        var fields: [String: JSONValue] = ["type": "boolean"]
        if let description { fields["description"] = .string(description) }
        return JSONSchema(fields)
    }

    public static func array(of items: JSONSchema, minItems: Int? = nil, maxItems: Int? = nil, description: String? = nil) -> JSONSchema {
        var fields: [String: JSONValue] = ["type": "array", "items": items.json]
        if let minItems { fields["minItems"] = .number(Double(minItems)) }
        if let maxItems { fields["maxItems"] = .number(Double(maxItems)) }
        if let description { fields["description"] = .string(description) }
        return JSONSchema(fields)
    }

    public static func oneOf(_ alternatives: [JSONSchema], description: String? = nil) -> JSONSchema {
        var fields: [String: JSONValue] = ["oneOf": .array(alternatives.map { $0.json })]
        if let description { fields["description"] = .string(description) }
        return JSONSchema(fields)
    }

    public static func const(_ value: JSONValue, description: String? = nil) -> JSONSchema {
        var fields: [String: JSONValue] = ["const": value]
        if let description { fields["description"] = .string(description) }
        return JSONSchema(fields)
    }

    public static let null = JSONSchema(["type": "null"])

    public static func any(description: String? = nil) -> JSONSchema {
        var fields: [String: JSONValue] = [:]
        if let description { fields["description"] = .string(description) }
        return JSONSchema(fields)
    }

    /// Fixed-length numeric vector (V2/V3/V4).
    public static func vector(_ count: Int, minimum: Double? = nil, maximum: Double? = nil, description: String? = nil) -> JSONSchema {
        array(of: .number(minimum: minimum, maximum: maximum), minItems: count, maxItems: count, description: description)
    }

    // MARK: Modifiers

    public func with(_ key: String, _ value: JSONValue) -> JSONSchema {
        var fields = json.object ?? [:]
        fields[key] = value
        return JSONSchema(fields)
    }

    public func described(_ text: String) -> JSONSchema { with("description", .string(text)) }
    public func titled(_ text: String) -> JSONSchema { with("title", .string(text)) }
    public func unit(_ unit: String) -> JSONSchema { with("x-unit", .string(unit)) }
    public func defaulting(to value: JSONValue) -> JSONSchema { with("default", value) }
    public func recommended(minimum: Double, maximum: Double) -> JSONSchema {
        with("x-recommendedRange", [.number(minimum), .number(maximum)])
    }

    // MARK: Introspection

    public var properties: [String: JSONSchema] {
        (json["properties"]?.object ?? [:]).mapValues { JSONSchema(json: $0) }
    }

    public var requiredKeys: [String] { json["required"]?.array?.compactMap { $0.string } ?? [] }
    public var typeName: String? { json["type"]?.string }
    public var defaultValue: JSONValue? { json["default"] }
    public var unitName: String? { json["x-unit"]?.string }
    public var alternatives: [JSONSchema]? { json["oneOf"]?.array?.map { JSONSchema(json: $0) } }
    public var items: JSONSchema? { json["items"].map { JSONSchema(json: $0) } }

    /// sha256 of the canonical JSON. Schemas are built from finite literals, so serialization cannot fail.
    public var schemaHash: String {
        guard let hash = try? CanonicalJSON.sha256(json) else { preconditionFailure("schema contains a non-finite number") }
        return hash
    }

    /// RFC 6901 pointers of every leaf (a property that is not itself an object with properties).
    public func leafPointers(prefix: String = "") -> [String] {
        var out: [String] = []
        if let alternatives {
            for alt in alternatives { out += alt.leafPointers(prefix: prefix) }
            return Array(NSOrderedSet(array: out)) as? [String] ?? out
        }
        let props = properties
        if props.isEmpty {
            if !prefix.isEmpty { out.append(prefix) }
            return out
        }
        for key in props.keys.sorted() {
            out += props[key]!.leafPointers(prefix: prefix + "/" + JSONPointer.escape(key))
        }
        return out
    }

    /// Every pointer paired with its `x-unit` annotation.
    public func units(prefix: String = "") -> [String: String] {
        var out: [String: String] = [:]
        if let unitName, !prefix.isEmpty { out[prefix] = unitName }
        for (key, sub) in properties { out.merge(sub.units(prefix: prefix + "/" + JSONPointer.escape(key))) { a, _ in a } }
        if let items { out.merge(items.units(prefix: prefix + "/-")) { a, _ in a } }
        for alt in alternatives ?? [] { out.merge(alt.units(prefix: prefix)) { a, _ in a } }
        return out
    }

    // MARK: Validation

    public func validate(_ value: JSONValue, pointer: String = "") -> [SchemaViolation] {
        var violations: [SchemaViolation] = []
        func fail(_ keyword: String, _ message: String, observed: JSONValue? = nil, required: JSONValue? = nil) {
            violations.append(SchemaViolation(pointer: pointer, keyword: keyword, message: message, observed: observed, required: required))
        }
        if let type = json["type"]?.string {
            let ok: Bool
            switch type {
            case "object": ok = value.object != nil
            case "array": ok = value.array != nil
            case "string": ok = value.string != nil
            case "boolean": ok = value.bool != nil
            case "null": ok = value.isNull
            case "number": ok = value.number != nil
            case "integer": ok = value.int != nil
            default: ok = true
            }
            if !ok {
                fail("type", "Expected \(type) at \(pointer.isEmpty ? "/" : pointer), got \(value.typeName).", observed: value, required: .string(type))
                return violations
            }
        }
        if let allowed = json["enum"]?.array, !allowed.contains(value) {
            fail("enum", "Value at \(pointer.isEmpty ? "/" : pointer) is not one of the allowed values.", observed: value, required: .array(allowed))
        }
        if let const = json["const"], const != value {
            fail("const", "Value at \(pointer.isEmpty ? "/" : pointer) must equal the constant.", observed: value, required: const)
        }
        if let n = value.number {
            if let minimum = json["minimum"]?.number, n < minimum { fail("minimum", "Value \(n) is below the minimum \(minimum).", observed: value, required: .number(minimum)) }
            if let maximum = json["maximum"]?.number, n > maximum { fail("maximum", "Value \(n) exceeds the maximum \(maximum).", observed: value, required: .number(maximum)) }
            if let m = json["exclusiveMinimum"]?.number, n <= m { fail("exclusiveMinimum", "Value \(n) must exceed \(m).", observed: value, required: .number(m)) }
            if let m = json["exclusiveMaximum"]?.number, n >= m { fail("exclusiveMaximum", "Value \(n) must be below \(m).", observed: value, required: .number(m)) }
        }
        if let s = value.string {
            if let pattern = json["pattern"]?.string, s.range(of: pattern, options: .regularExpression) == nil {
                fail("pattern", "Value does not match pattern \(pattern).", observed: value, required: .string(pattern))
            }
            if let minLength = json["minLength"]?.int, s.count < minLength {
                fail("minLength", "String shorter than \(minLength).", observed: value, required: .number(Double(minLength)))
            }
        }
        if let o = value.object {
            let props = json["properties"]?.object ?? [:]
            for key in requiredKeys where o[key] == nil {
                fail("required", "Missing required property '\(key)'.", required: .string(key))
            }
            for (key, sub) in o {
                let childPointer = pointer + "/" + JSONPointer.escape(key)
                if let schema = props[key] {
                    violations += JSONSchema(json: schema).validate(sub, pointer: childPointer)
                } else if let additional = json["additionalProperties"] {
                    if additional == .bool(false) {
                        violations.append(SchemaViolation(pointer: childPointer, keyword: "additionalProperties", message: "Unknown field '\(key)'.", observed: sub, required: nil))
                    } else if additional.object != nil {
                        violations += JSONSchema(json: additional).validate(sub, pointer: childPointer)
                    }
                }
            }
        }
        if let a = value.array {
            if let minItems = json["minItems"]?.int, a.count < minItems { fail("minItems", "Array has \(a.count) items; at least \(minItems) required.", observed: .number(Double(a.count)), required: .number(Double(minItems))) }
            if let maxItems = json["maxItems"]?.int, a.count > maxItems { fail("maxItems", "Array has \(a.count) items; at most \(maxItems) allowed.", observed: .number(Double(a.count)), required: .number(Double(maxItems))) }
            if let items {
                for (index, element) in a.enumerated() { violations += items.validate(element, pointer: pointer + "/\(index)") }
            }
        }
        if let alternatives {
            let matching = alternatives.filter { $0.validate(value, pointer: pointer).isEmpty }.count
            if matching != 1 {
                fail("oneOf", matching == 0 ? "Value matches none of the \(alternatives.count) allowed forms." : "Value matches \(matching) of the allowed forms; exactly one is required.", observed: value)
            }
        }
        return violations
    }

    public func requestErrors(for value: JSONValue) -> [AuthorError] {
        validate(value).map { $0.authorError }
    }

    /// Fills schema `default` values for absent properties, recursively. For
    /// oneOf the first alternative that validates is used.
    public func applyingDefaults(to value: JSONValue) -> JSONValue {
        if let alternatives {
            if let match = alternatives.first(where: { $0.validate(value).isEmpty }) { return match.applyingDefaults(to: value) }
            return value
        }
        if var o = value.object, json["type"]?.string == "object" {
            for (key, sub) in properties {
                if let existing = o[key] {
                    o[key] = sub.applyingDefaults(to: existing)
                } else if let def = sub.defaultValue {
                    o[key] = def
                }
            }
            return .object(o)
        }
        if let a = value.array, let items {
            return .array(a.map { items.applyingDefaults(to: $0) })
        }
        return value
    }
}
