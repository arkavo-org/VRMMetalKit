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

public struct CanonicalJSONError: Error, CustomStringConvertible, Sendable, Equatable {
    public let reason: String
    public var description: String { "canonical JSON error: \(reason)" }
}

/// RFC 8785 (JCS) serializer: keys sorted by UTF-16 code units, ECMAScript
/// shortest round-trip number formatting, negative zero normalized, no
/// insignificant whitespace, non-finite numbers rejected.
public enum CanonicalJSON {
    public static func data(_ value: JSONValue) throws -> Data {
        var out = ""
        try write(value, into: &out)
        return Data(out.utf8)
    }

    public static func string(_ value: JSONValue) throws -> String {
        var out = ""
        try write(value, into: &out)
        return out
    }

    public static func sha256(_ value: JSONValue) throws -> String {
        SHA256Hex.hex(try data(value))
    }

    /// Canonical bytes of any Encodable, without the JSONValue round-trip at the call site.
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        try data(try JSONValue.from(value))
    }

    private static func write(_ value: JSONValue, into out: inout String) throws {
        switch value {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .number(let d): out += try formatNumber(d)
        case .string(let s): writeString(s, into: &out)
        case .array(let a):
            out += "["
            for (index, element) in a.enumerated() {
                if index > 0 { out += "," }
                try write(element, into: &out)
            }
            out += "]"
        case .object(let o):
            out += "{"
            let keys = o.keys.sorted { lhs, rhs in
                let l = Array(lhs.utf16), r = Array(rhs.utf16)
                return l.lexicographicallyPrecedes(r)
            }
            for (index, key) in keys.enumerated() {
                if index > 0 { out += "," }
                writeString(key, into: &out)
                out += ":"
                try write(o[key]!, into: &out)
            }
            out += "}"
        }
    }

    private static func writeString(_ s: String, into out: inout String) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    let hex = String(scalar.value, radix: 16)
                    out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }

    /// ECMAScript Number::toString applied to the shortest round-trip digits.
    public static func formatNumber(_ value: Double) throws -> String {
        guard value.isFinite else { throw CanonicalJSONError(reason: "non-finite number \(value)") }
        if value == 0 { return "0" }
        let negative = value < 0
        let magnitude = abs(value)
        let (digits, exponent) = shortestDigits(magnitude)
        let k = digits.count
        let n = exponent
        var body: String
        if k <= n && n <= 21 {
            body = digits + String(repeating: "0", count: n - k)
        } else if 0 < n && n <= 21 {
            let idx = digits.index(digits.startIndex, offsetBy: n)
            body = String(digits[..<idx]) + "." + String(digits[idx...])
        } else if -6 < n && n <= 0 {
            body = "0." + String(repeating: "0", count: -n) + digits
        } else {
            let e = n - 1
            let sign = e < 0 ? "-" : "+"
            if k == 1 {
                body = digits + "e" + sign + String(abs(e))
            } else {
                let idx = digits.index(after: digits.startIndex)
                body = String(digits[..<idx]) + "." + String(digits[idx...]) + "e" + sign + String(abs(e))
            }
        }
        return negative ? "-" + body : body
    }

    /// Returns (significant digits without leading/trailing zeros, n) where the value equals 0.d1d2... × 10^n.
    private static func shortestDigits(_ magnitude: Double) -> (String, Int) {
        let description = magnitude.description
        var mantissa = description
        var exp10 = 0
        if let eIndex = description.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            mantissa = String(description[..<eIndex])
            exp10 = Int(description[description.index(after: eIndex)...])!
        }
        var intPart = mantissa
        var fracPart = ""
        if let dot = mantissa.firstIndex(of: ".") {
            intPart = String(mantissa[..<dot])
            fracPart = String(mantissa[mantissa.index(after: dot)...])
        }
        var digits = intPart + fracPart
        var n = intPart.count + exp10
        while digits.hasPrefix("0") {
            digits.removeFirst()
            n -= 1
        }
        while digits.hasSuffix("0") { digits.removeLast() }
        return (digits, n)
    }
}
