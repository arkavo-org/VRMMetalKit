//
// Copyright 2025 Arkavo
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

/// One argument of an Open Sound Control 1.0 message.
public enum OSCArgument: Sendable, Equatable {
    case int32(Int32)
    case float32(Float)
    case string(String)
    case blob(Data)
    case int64(Int64)
    case double(Double)
    case boolean(Bool)
    case null
    case impulse

    /// Numeric value as `Float` for int32/float32/int64/double arguments, otherwise `nil`.
    public var floatValue: Float? {
        switch self {
        case .int32(let v): return Float(v)
        case .float32(let v): return v
        case .int64(let v): return Float(v)
        case .double(let v): return Float(v)
        default: return nil
        }
    }

    /// Integer value for int32/int64 arguments (float arguments are truncated), otherwise `nil`.
    public var intValue: Int? {
        switch self {
        case .int32(let v): return Int(v)
        case .int64(let v): return Int(v)
        case .float32(let v): return Int(v)
        case .double(let v): return Int(v)
        default: return nil
        }
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
}

/// An OSC message: an address pattern plus typed arguments.
public struct OSCMessage: Sendable, Equatable {
    public var address: String
    public var arguments: [OSCArgument]

    public init(address: String, arguments: [OSCArgument] = []) {
        self.address = address
        self.arguments = arguments
    }

    public init(_ address: String, _ arguments: OSCArgument...) {
        self.init(address: address, arguments: arguments)
    }

    /// Encodes the message per OSC 1.0: padded address, padded type-tag string, then arguments.
    public func encode() -> Data {
        var data = Data()
        OSCCodec.appendString(address, to: &data)
        var tags = ","
        for argument in arguments {
            switch argument {
            case .int32: tags.append("i")
            case .float32: tags.append("f")
            case .string: tags.append("s")
            case .blob: tags.append("b")
            case .int64: tags.append("h")
            case .double: tags.append("d")
            case .boolean(let b): tags.append(b ? "T" : "F")
            case .null: tags.append("N")
            case .impulse: tags.append("I")
            }
        }
        OSCCodec.appendString(tags, to: &data)
        for argument in arguments {
            switch argument {
            case .int32(let v): OSCCodec.appendBigEndian(UInt32(bitPattern: v), to: &data)
            case .float32(let v): OSCCodec.appendBigEndian(v.bitPattern, to: &data)
            case .string(let s): OSCCodec.appendString(s, to: &data)
            case .blob(let b):
                OSCCodec.appendBigEndian(UInt32(b.count), to: &data)
                data.append(b)
                OSCCodec.pad(&data)
            case .int64(let v): OSCCodec.appendBigEndian(UInt64(bitPattern: v), to: &data)
            case .double(let v): OSCCodec.appendBigEndian(v.bitPattern, to: &data)
            case .boolean, .null, .impulse: break
            }
        }
        return data
    }
}

/// An OSC bundle: a time tag plus nested packets.
public struct OSCBundle: Sendable, Equatable {
    /// NTP time tag; `1` means "immediately".
    public var timeTag: UInt64
    public var elements: [OSCPacket]

    public init(timeTag: UInt64 = 1, elements: [OSCPacket]) {
        self.timeTag = timeTag
        self.elements = elements
    }

    public func encode() -> Data {
        var data = Data()
        OSCCodec.appendString("#bundle", to: &data)
        OSCCodec.appendBigEndian(timeTag, to: &data)
        for element in elements {
            let encoded = element.encode()
            OSCCodec.appendBigEndian(UInt32(encoded.count), to: &data)
            data.append(encoded)
        }
        return data
    }
}

/// A decoded OSC datagram: either a single message or a bundle.
public indirect enum OSCPacket: Sendable, Equatable {
    case message(OSCMessage)
    case bundle(OSCBundle)

    /// Every message in the packet, bundles flattened in order.
    public var messages: [OSCMessage] {
        switch self {
        case .message(let m): return [m]
        case .bundle(let b): return b.elements.flatMap(\.messages)
        }
    }

    public func encode() -> Data {
        switch self {
        case .message(let m): return m.encode()
        case .bundle(let b): return b.encode()
        }
    }

    /// Decodes one datagram.
    public static func decode(_ data: Data) throws -> OSCPacket {
        var reader = OSCReader(data: data)
        return try decode(&reader)
    }

    private static func decode(_ reader: inout OSCReader) throws -> OSCPacket {
        guard let first = reader.peekByte() else { throw OSCDecodingError.truncated }
        if first == UInt8(ascii: "#") {
            let marker = try reader.readString()
            guard marker == "#bundle" else { throw OSCDecodingError.malformedBundle }
            let timeTag: UInt64 = try reader.readBigEndian()
            var elements: [OSCPacket] = []
            while reader.remaining > 0 {
                let size = Int(try reader.readBigEndian() as UInt32)
                guard size <= reader.remaining else { throw OSCDecodingError.truncated }
                var sub = OSCReader(data: reader.readBytes(size))
                elements.append(try decode(&sub))
            }
            return .bundle(OSCBundle(timeTag: timeTag, elements: elements))
        }

        let address = try reader.readString()
        guard address.hasPrefix("/") else { throw OSCDecodingError.malformedAddress(address) }
        var arguments: [OSCArgument] = []
        if reader.remaining > 0 {
            let tags = try reader.readString()
            guard tags.hasPrefix(",") else { throw OSCDecodingError.malformedTypeTags(tags) }
            for tag in tags.dropFirst() {
                switch tag {
                case "i": arguments.append(.int32(Int32(bitPattern: try reader.readBigEndian())))
                case "f": arguments.append(.float32(Float(bitPattern: try reader.readBigEndian())))
                case "s", "S": arguments.append(.string(try reader.readString()))
                case "b":
                    let size = Int(try reader.readBigEndian() as UInt32)
                    guard size <= reader.remaining else { throw OSCDecodingError.truncated }
                    let bytes = reader.readBytes(size)
                    reader.skipPadding(after: size)
                    arguments.append(.blob(bytes))
                case "h": arguments.append(.int64(Int64(bitPattern: try reader.readBigEndian())))
                case "d": arguments.append(.double(Double(bitPattern: try reader.readBigEndian())))
                case "T": arguments.append(.boolean(true))
                case "F": arguments.append(.boolean(false))
                case "N": arguments.append(.null)
                case "I": arguments.append(.impulse)
                default: throw OSCDecodingError.unsupportedTypeTag(tag)
                }
            }
        }
        return .message(OSCMessage(address: address, arguments: arguments))
    }
}

public enum OSCDecodingError: Error, Equatable, LocalizedError {
    case truncated
    case malformedAddress(String)
    case malformedTypeTags(String)
    case malformedBundle
    case unsupportedTypeTag(Character)

    public var errorDescription: String? {
        switch self {
        case .truncated:
            return "OSC packet ended before a complete value was read. Check that the sender pads strings and blobs to 4 bytes (OSC 1.0 §1). Spec: https://opensoundcontrol.stanford.edu/spec-1_0.html"
        case .malformedAddress(let a):
            return "OSC address '\(a)' must start with '/'. Spec: https://opensoundcontrol.stanford.edu/spec-1_0.html"
        case .malformedTypeTags(let t):
            return "OSC type-tag string '\(t)' must start with ','. Spec: https://opensoundcontrol.stanford.edu/spec-1_0.html"
        case .malformedBundle:
            return "OSC bundle must begin with '#bundle'. Spec: https://opensoundcontrol.stanford.edu/spec-1_0.html"
        case .unsupportedTypeTag(let c):
            return "OSC type tag '\(c)' is not supported (supported: i f s b h d T F N I). Spec: https://opensoundcontrol.stanford.edu/spec-1_0.html"
        }
    }
}

// MARK: - Codec helpers

enum OSCCodec {
    static func pad(_ data: inout Data) {
        let remainder = data.count % 4
        if remainder != 0 {
            data.append(contentsOf: [UInt8](repeating: 0, count: 4 - remainder))
        }
    }

    static func appendString(_ s: String, to data: inout Data) {
        data.append(contentsOf: Array(s.utf8))
        data.append(0)
        pad(&data)
    }

    static func appendBigEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var be = value.bigEndian
        withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
    }
}

struct OSCReader {
    private let bytes: [UInt8]
    private var cursor = 0

    init(data: Data) {
        bytes = [UInt8](data)
    }

    var remaining: Int { bytes.count - cursor }

    func peekByte() -> UInt8? {
        cursor < bytes.count ? bytes[cursor] : nil
    }

    mutating func readBytes(_ count: Int) -> Data {
        let slice = Data(bytes[cursor..<cursor + count])
        cursor += count
        return slice
    }

    mutating func skipPadding(after size: Int) {
        let remainder = size % 4
        if remainder != 0 {
            cursor = min(bytes.count, cursor + 4 - remainder)
        }
    }

    mutating func readString() throws -> String {
        guard let end = bytes[cursor...].firstIndex(of: 0) else { throw OSCDecodingError.truncated }
        let s = String(decoding: bytes[cursor..<end], as: UTF8.self)
        let consumed = end - cursor + 1
        cursor = end + 1
        skipPadding(after: consumed)
        return s
    }

    mutating func readBigEndian<T: FixedWidthInteger>() throws -> T {
        let size = MemoryLayout<T>.size
        guard remaining >= size else { throw OSCDecodingError.truncated }
        var value: T = 0
        for i in 0..<size {
            value = (value << 8) | T(bytes[cursor + i])
        }
        cursor += size
        return value
    }
}
