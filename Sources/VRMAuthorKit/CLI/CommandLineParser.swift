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

public struct ParsedInvocation: Sendable {
    public var operation: Operation
    public var request: JSONValue
}

/// `vrm-author <command words> [--project PATH] [--request PATH|-] [--flag value]...`
/// Kebab-case flags become camelCase keys; a key present in both `--request`
/// JSON and a flag is CONFLICTING_ARGUMENT; an unknown flag is UNKNOWN_FIELD.
public enum CommandLineParser {
    public static func camelCase(_ flag: String) -> String {
        var out = ""
        var upper = false
        for c in flag {
            if c == "-" { upper = true; continue }
            out.append(upper ? Character(c.uppercased()) : c)
            upper = false
        }
        return out
    }

    public static func kebabCase(_ key: String) -> String {
        var out = ""
        for c in key {
            if c.isUppercase { out.append("-"); out.append(contentsOf: c.lowercased()) } else { out.append(c) }
        }
        return out
    }

    public static func parse(_ arguments: [String], registry: Registry, stdin: StandardInputProvider, cwd: URL) throws -> ParsedInvocation {
        var words: [String] = []
        var index = 0
        while index < arguments.count, !arguments[index].hasPrefix("--") {
            words.append(arguments[index])
            index += 1
        }
        guard !words.isEmpty else {
            throw AuthorError(code: .invalidRequest, path: "/command", message: "No command given.", suggestedCommands: ["describe"])
        }
        guard let (operation, remaining) = registry.match(words: words), remaining.isEmpty else {
            throw AuthorError(code: .invalidRequest, path: "/command", observed: .string(words.joined(separator: " ")),
                              message: "Unknown command '\(words.joined(separator: " "))'.", suggestedCommands: ["describe"])
        }
        let properties = operation.requestSchema.properties

        var fromFlags: [String: JSONValue] = [:]
        var requestFile: String?
        while index < arguments.count {
            let token = arguments[index]
            index += 1
            guard token.hasPrefix("--"), token.count > 2 else {
                throw AuthorError(code: .invalidRequest, path: "/argv", observed: .string(token), message: "Unexpected argument '\(token)'; flags start with '--'.", suggestedCommands: ["describe \(operation.name)"])
            }
            var flag = String(token.dropFirst(2))
            var inlineValue: String?
            if let eq = flag.firstIndex(of: "=") {
                inlineValue = String(flag[flag.index(after: eq)...])
                flag = String(flag[..<eq])
            }
            let key = camelCase(flag)
            if key == "request" {
                guard requestFile == nil else { throw AuthorError(code: .conflictingArgument, path: "/request", message: "--request given twice.") }
                guard let value = inlineValue ?? (index < arguments.count ? arguments[index] : nil) else {
                    throw AuthorError.invalidRequest("--request needs a path or '-'.", path: "/request")
                }
                if inlineValue == nil { index += 1 }
                requestFile = value
                continue
            }
            guard let schema = properties[key] else {
                throw AuthorError(code: .unknownField, path: "/" + key, observed: .string(token), message: "Unknown flag '--\(flag)' for '\(operation.name)'.",
                                  suggestedCommands: ["describe \(operation.name)"])
            }
            guard fromFlags[key] == nil else {
                throw AuthorError(code: .conflictingArgument, path: "/" + key, message: "Flag '--\(flag)' given more than once.")
            }
            let isBoolean = schema.typeName == "boolean" || schema.json["const"]?.bool != nil
            var raw: String?
            if let inlineValue {
                raw = inlineValue
            } else if index < arguments.count, !(isBoolean && !["true", "false"].contains(arguments[index])) , !(arguments[index].hasPrefix("--") && isBoolean) {
                raw = arguments[index]
                index += 1
            }
            if raw == nil, isBoolean { raw = "true" }
            guard let text = raw else { throw AuthorError.invalidRequest("Flag '--\(flag)' needs a value.", path: "/" + key) }
            fromFlags[key] = try convert(text, schema: schema, key: key, flag: flag)
        }

        var request: [String: JSONValue] = [:]
        if let requestFile {
            let data: Data
            if requestFile == "-" {
                data = stdin()
            } else {
                let url = URL(fileURLWithPath: requestFile, relativeTo: cwd)
                guard let loaded = try? Data(contentsOf: url) else {
                    throw AuthorError(code: .missingInput, path: "/request", observed: .string(requestFile), message: "Cannot read request file '\(requestFile)'.")
                }
                data = loaded
            }
            let parsed: JSONValue
            do { parsed = try JSONValue.parse(data) } catch { throw AuthorError.invalidRequest("Request JSON is invalid: \(error)", path: "/request") }
            guard let object = parsed.object else { throw AuthorError.invalidRequest("Request JSON must be an object.", path: "/request", observed: .string(parsed.typeName)) }
            request = object
        }
        for (key, value) in fromFlags {
            guard request[key] == nil else {
                throw AuthorError(code: .conflictingArgument, path: "/" + key, message: "'\(key)' was supplied both in --request JSON and as --\(kebabCase(key)).",
                                  suggestedCommands: ["describe \(operation.name)"])
            }
            request[key] = value
        }
        return ParsedInvocation(operation: operation, request: .object(request))
    }

    static func convert(_ text: String, schema: JSONSchema, key: String, flag: String) throws -> JSONValue {
        switch schema.typeName {
        case "string":
            return .string(text)
        case "number", "integer":
            guard let n = Double(text), n.isFinite else { throw AuthorError.invalidRequest("Flag '--\(flag)' needs a finite number.", path: "/" + key, observed: .string(text)) }
            if schema.typeName == "integer", n != n.rounded() { throw AuthorError.invalidRequest("Flag '--\(flag)' needs an integer.", path: "/" + key, observed: .string(text)) }
            return .number(n)
        case "boolean":
            switch text {
            case "true": return .bool(true)
            case "false": return .bool(false)
            default: throw AuthorError.invalidRequest("Flag '--\(flag)' needs true or false.", path: "/" + key, observed: .string(text))
            }
        default:
            if let const = schema.json["const"], const.bool != nil {
                return text == "true" ? .bool(true) : .bool(false)
            }
            if let parsed = try? JSONValue.parse(Data(text.utf8)) { return parsed }
            return .string(text)
        }
    }
}
