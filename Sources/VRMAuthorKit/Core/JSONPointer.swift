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

/// RFC 6901 JSON Pointer.
public struct JSONPointer: Hashable, Sendable, CustomStringConvertible {
    public let tokens: [String]

    public init(tokens: [String]) { self.tokens = tokens }

    public init(_ text: String) throws {
        if text.isEmpty { tokens = []; return }
        guard text.hasPrefix("/") else { throw AuthorError.invalidRequest("JSON pointer must start with '/'.", path: text, observed: .string(text)) }
        var out: [String] = []
        for raw in text.dropFirst().split(separator: "/", omittingEmptySubsequences: false) {
            let token = String(raw)
            if token.contains("~") {
                var t = ""
                var iterator = token.makeIterator()
                while let c = iterator.next() {
                    if c == "~" {
                        guard let next = iterator.next(), next == "0" || next == "1" else {
                            throw AuthorError.invalidRequest("Invalid '~' escape in JSON pointer.", path: text, observed: .string(text))
                        }
                        t.append(next == "0" ? "~" : "/")
                    } else {
                        t.append(c)
                    }
                }
                out.append(t)
            } else {
                out.append(token)
            }
        }
        tokens = out
    }

    public static func escape(_ token: String) -> String {
        token.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
    }

    public var description: String { tokens.map { "/" + JSONPointer.escape($0) }.joined() }

    public var isRoot: Bool { tokens.isEmpty }
    public var parent: JSONPointer? { tokens.isEmpty ? nil : JSONPointer(tokens: Array(tokens.dropLast())) }
    public func appending(_ token: String) -> JSONPointer { JSONPointer(tokens: tokens + [token]) }

    /// True when `other` is this pointer or a descendant of it.
    public func covers(_ other: JSONPointer) -> Bool {
        other.tokens.count >= tokens.count && Array(other.tokens.prefix(tokens.count)) == tokens
    }

    public func get(in value: JSONValue) -> JSONValue? {
        var current = value
        for token in tokens {
            if let o = current.object {
                guard let next = o[token] else { return nil }
                current = next
            } else if let a = current.array {
                guard let index = Int(token), index >= 0, index < a.count, token == String(index) else { return nil }
                current = a[index]
            } else {
                return nil
            }
        }
        return current
    }

    /// Sets the value, creating intermediate objects for missing object keys.
    /// Array indices must exist or be `-` (append).
    public func set(in value: inout JSONValue, to newValue: JSONValue) throws {
        value = try JSONPointer.set(value, tokens[...], newValue, path: "")
    }

    private static func set(_ value: JSONValue, _ tokens: ArraySlice<String>, _ newValue: JSONValue, path: String) throws -> JSONValue {
        guard let token = tokens.first else { return newValue }
        let rest = tokens.dropFirst()
        let childPath = path + "/" + escape(token)
        if var o = value.object {
            o[token] = try set(o[token] ?? .object([:]), rest, newValue, path: childPath)
            return .object(o)
        }
        if var a = value.array {
            if token == "-" {
                guard rest.isEmpty else { throw AuthorError.invalidRequest("Cannot descend through '-' in JSON pointer.", path: childPath) }
                a.append(newValue)
                return .array(a)
            }
            guard let index = Int(token), index >= 0, index < a.count, token == String(index) else {
                throw AuthorError.invalidRequest("Array index out of range in JSON pointer.", path: childPath, observed: .string(token))
            }
            a[index] = try set(a[index], rest, newValue, path: childPath)
            return .array(a)
        }
        if value.isNull {
            return try set(.object([:]), tokens, newValue, path: path)
        }
        throw AuthorError.invalidRequest("Cannot set a child of a scalar value.", path: childPath, observed: value)
    }
}
