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

/// Wire type for requests, results and schemas. Numbers are IEEE-754 doubles;
/// integer literals beyond 53 bits are rejected at parse time.
public indirect enum JSONValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public static let maxExactInteger: Double = 9_007_199_254_740_992

    public var isNull: Bool { if case .null = self { return true } else { return false } }
    public var bool: Bool? { if case .bool(let v) = self { return v } else { return nil } }
    public var number: Double? { if case .number(let v) = self { return v } else { return nil } }
    public var string: String? { if case .string(let v) = self { return v } else { return nil } }
    public var array: [JSONValue]? { if case .array(let v) = self { return v } else { return nil } }
    public var object: [String: JSONValue]? { if case .object(let v) = self { return v } else { return nil } }

    /// Integral numbers only; a fractional value yields nil.
    public var int: Int? {
        guard case .number(let v) = self, v.isFinite, v == v.rounded(.towardZero), abs(v) <= JSONValue.maxExactInteger else { return nil }
        return Int(v)
    }

    public subscript(key: String) -> JSONValue? {
        guard case .object(let o) = self else { return nil }
        return o[key]
    }

    public subscript(index: Int) -> JSONValue? {
        guard case .array(let a) = self, index >= 0, index < a.count else { return nil }
        return a[index]
    }

    public var typeName: String {
        switch self {
        case .null: return "null"
        case .bool: return "boolean"
        case .number: return "number"
        case .string: return "string"
        case .array: return "array"
        case .object: return "object"
        }
    }

    public func merging(_ other: [String: JSONValue]) -> JSONValue {
        var o = object ?? [:]
        for (k, v) in other { o[k] = v }
        return .object(o)
    }

    public init(_ strings: [String]) { self = .array(strings.map { .string($0) }) }
    public init(_ doubles: [Double]) { self = .array(doubles.map { .number($0) }) }
}

extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        var o: [String: JSONValue] = [:]
        for (k, v) in elements { o[k] = v }
        self = .object(o)
    }
}

extension JSONValue: Codable {
    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let d = try? c.decode(Double.self) { self = .number(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "unsupported JSON value")
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

public struct JSONParseError: Error, CustomStringConvertible, Sendable, Equatable {
    public let offset: Int
    public let reason: String
    public var description: String { "JSON parse error at byte \(offset): \(reason)" }
}

extension JSONValue {
    /// Strict RFC 8259 parser: rejects duplicate keys, integer literals beyond 53 bits,
    /// non-finite results, lone surrogates and trailing content.
    public static func parse(_ data: Data) throws -> JSONValue {
        var parser = JSONParser(bytes: Array(data))
        return try parser.parseDocument()
    }

    public static func parse(_ text: String) throws -> JSONValue {
        try parse(Data(text.utf8))
    }

    /// Encodes any Encodable model through JSONEncoder and re-parses it into a JSONValue.
    public static func from<T: Encodable>(_ model: T) throws -> JSONValue {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try parse(try encoder.encode(model))
    }

    /// Decodes a model from this value through canonical bytes.
    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: try CanonicalJSON.data(self))
    }
}

private struct JSONParser {
    let bytes: [UInt8]
    var i = 0
    var depth = 0

    init(bytes: [UInt8]) { self.bytes = bytes }

    mutating func parseDocument() throws -> JSONValue {
        skipWhitespace()
        let v = try parseValue()
        skipWhitespace()
        guard i == bytes.count else { throw error("trailing content") }
        return v
    }

    func error(_ reason: String) -> JSONParseError { JSONParseError(offset: i, reason: reason) }

    mutating func skipWhitespace() {
        while i < bytes.count, bytes[i] == 0x20 || bytes[i] == 0x09 || bytes[i] == 0x0A || bytes[i] == 0x0D { i += 1 }
    }

    mutating func parseValue() throws -> JSONValue {
        guard i < bytes.count else { throw error("unexpected end of input") }
        switch bytes[i] {
        case UInt8(ascii: "{"): return try parseObject()
        case UInt8(ascii: "["): return try parseArray()
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"): try expectLiteral("true"); return .bool(true)
        case UInt8(ascii: "f"): try expectLiteral("false"); return .bool(false)
        case UInt8(ascii: "n"): try expectLiteral("null"); return .null
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return .number(try parseNumber())
        default: throw error("unexpected byte \(bytes[i])")
        }
    }

    mutating func expectLiteral(_ literal: String) throws {
        let lit = Array(literal.utf8)
        guard i + lit.count <= bytes.count, Array(bytes[i..<i + lit.count]) == lit else { throw error("invalid literal") }
        i += lit.count
    }

    mutating func parseObject() throws -> JSONValue {
        depth += 1
        guard depth <= 512 else { throw error("nesting too deep") }
        defer { depth -= 1 }
        i += 1
        var result: [String: JSONValue] = [:]
        var seen: [[UInt16]] = []
        skipWhitespace()
        if i < bytes.count, bytes[i] == UInt8(ascii: "}") { i += 1; return .object(result) }
        while true {
            skipWhitespace()
            guard i < bytes.count, bytes[i] == UInt8(ascii: "\"") else { throw error("expected object key") }
            let key = try parseString()
            let units = Array(key.utf16)
            if seen.contains(units) { throw error("duplicate key \"\(key)\"") }
            seen.append(units)
            skipWhitespace()
            guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else { throw error("expected ':'") }
            i += 1
            skipWhitespace()
            result[key] = try parseValue()
            skipWhitespace()
            guard i < bytes.count else { throw error("unterminated object") }
            if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
            if bytes[i] == UInt8(ascii: "}") { i += 1; return .object(result) }
            throw error("expected ',' or '}'")
        }
    }

    mutating func parseArray() throws -> JSONValue {
        depth += 1
        guard depth <= 512 else { throw error("nesting too deep") }
        defer { depth -= 1 }
        i += 1
        var result: [JSONValue] = []
        skipWhitespace()
        if i < bytes.count, bytes[i] == UInt8(ascii: "]") { i += 1; return .array(result) }
        while true {
            skipWhitespace()
            result.append(try parseValue())
            skipWhitespace()
            guard i < bytes.count else { throw error("unterminated array") }
            if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
            if bytes[i] == UInt8(ascii: "]") { i += 1; return .array(result) }
            throw error("expected ',' or ']'")
        }
    }

    mutating func parseHex4() throws -> UInt16 {
        guard i + 4 <= bytes.count else { throw error("truncated \\u escape") }
        var v: UInt16 = 0
        for _ in 0..<4 {
            let b = bytes[i]
            let d: UInt16
            switch b {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): d = UInt16(b - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"): d = UInt16(b - UInt8(ascii: "a") + 10)
            case UInt8(ascii: "A")...UInt8(ascii: "F"): d = UInt16(b - UInt8(ascii: "A") + 10)
            default: throw error("invalid hex digit in \\u escape")
            }
            v = v << 4 | d
            i += 1
        }
        return v
    }

    mutating func parseString() throws -> String {
        i += 1
        var utf8: [UInt8] = []
        while true {
            guard i < bytes.count else { throw error("unterminated string") }
            let b = bytes[i]
            if b == UInt8(ascii: "\"") { i += 1; break }
            if b < 0x20 { throw error("control character in string") }
            if b == UInt8(ascii: "\\") {
                i += 1
                guard i < bytes.count else { throw error("unterminated escape") }
                let e = bytes[i]
                i += 1
                switch e {
                case UInt8(ascii: "\""): utf8.append(0x22)
                case UInt8(ascii: "\\"): utf8.append(0x5C)
                case UInt8(ascii: "/"): utf8.append(0x2F)
                case UInt8(ascii: "b"): utf8.append(0x08)
                case UInt8(ascii: "f"): utf8.append(0x0C)
                case UInt8(ascii: "n"): utf8.append(0x0A)
                case UInt8(ascii: "r"): utf8.append(0x0D)
                case UInt8(ascii: "t"): utf8.append(0x09)
                case UInt8(ascii: "u"):
                    let hi = try parseHex4()
                    var scalarValue = UInt32(hi)
                    if (0xD800...0xDBFF).contains(hi) {
                        guard i + 6 <= bytes.count, bytes[i] == UInt8(ascii: "\\"), bytes[i + 1] == UInt8(ascii: "u") else { throw error("lone high surrogate") }
                        i += 2
                        let lo = try parseHex4()
                        guard (0xDC00...0xDFFF).contains(lo) else { throw error("invalid low surrogate") }
                        scalarValue = 0x10000 + ((UInt32(hi) - 0xD800) << 10) + (UInt32(lo) - 0xDC00)
                    } else if (0xDC00...0xDFFF).contains(hi) {
                        throw error("lone low surrogate")
                    }
                    guard let scalar = Unicode.Scalar(scalarValue) else { throw error("invalid scalar") }
                    utf8.append(contentsOf: Array(String(Character(scalar)).utf8))
                default: throw error("invalid escape")
                }
                continue
            }
            utf8.append(b)
            i += 1
        }
        guard let s = String(validating: utf8, as: UTF8.self) else { throw error("invalid UTF-8") }
        return s
    }

    mutating func parseNumber() throws -> Double {
        let start = i
        if bytes[i] == UInt8(ascii: "-") { i += 1 }
        guard i < bytes.count else { throw error("truncated number") }
        if bytes[i] == UInt8(ascii: "0") {
            i += 1
        } else if (UInt8(ascii: "1")...UInt8(ascii: "9")).contains(bytes[i]) {
            while i < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[i]) { i += 1 }
        } else {
            throw error("invalid number")
        }
        var isInteger = true
        if i < bytes.count, bytes[i] == UInt8(ascii: ".") {
            isInteger = false
            i += 1
            let fracStart = i
            while i < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[i]) { i += 1 }
            guard i > fracStart else { throw error("invalid fraction") }
        }
        if i < bytes.count, bytes[i] == UInt8(ascii: "e") || bytes[i] == UInt8(ascii: "E") {
            isInteger = false
            i += 1
            if i < bytes.count, bytes[i] == UInt8(ascii: "+") || bytes[i] == UInt8(ascii: "-") { i += 1 }
            let expStart = i
            while i < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[i]) { i += 1 }
            guard i > expStart else { throw error("invalid exponent") }
        }
        let text = String(decoding: bytes[start..<i], as: UTF8.self)
        guard let value = Double(text), value.isFinite else { throw error("number out of range: \(text)") }
        if isInteger {
            let magnitudeText = text.hasPrefix("-") ? String(text.dropFirst()) : text
            let limit = "9007199254740992"
            if magnitudeText.count > limit.count || (magnitudeText.count == limit.count && magnitudeText > limit) {
                throw error("integer exceeds 53 bits of precision: \(text)")
            }
        }
        return value
    }
}
