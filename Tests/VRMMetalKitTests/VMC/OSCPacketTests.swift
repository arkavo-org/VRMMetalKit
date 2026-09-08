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

import XCTest
@testable import VRMMetalKit

final class OSCPacketTests: XCTestCase {

    /// `/VMC/Ext/Blend/Val ,sf "Joy" 0.5` laid out by hand per OSC 1.0.
    private var handBuiltBlendValue: Data {
        var bytes: [UInt8] = []
        bytes += Array("/VMC/Ext/Blend/Val".utf8)   // 18 bytes
        bytes += [0, 0]                              // null + pad to 20
        bytes += Array(",sf".utf8) + [0]             // 4 bytes
        bytes += Array("Joy".utf8) + [0]             // 4 bytes
        bytes += [0x3F, 0x00, 0x00, 0x00]            // 0.5 big-endian
        return Data(bytes)
    }

    func testDecodesHandBuiltMessage() throws {
        let packet = try OSCPacket.decode(handBuiltBlendValue)
        XCTAssertEqual(packet, .message(OSCMessage("/VMC/Ext/Blend/Val", .string("Joy"), .float32(0.5))))
    }

    func testEncodeMatchesHandBuiltBytes() {
        let encoded = OSCMessage("/VMC/Ext/Blend/Val", .string("Joy"), .float32(0.5)).encode()
        XCTAssertEqual(encoded, handBuiltBlendValue)
        XCTAssertEqual(encoded.count % 4, 0)
    }

    func testDecodesHandBuiltBundleWithTwoElements() throws {
        let apply: [UInt8] = Array("/VMC/Ext/Blend/Apply".utf8) + [0, 0, 0, 0] + Array(",".utf8) + [0, 0, 0]
        XCTAssertEqual(apply.count % 4, 0)
        let first = [UInt8](handBuiltBlendValue)

        var bytes: [UInt8] = Array("#bundle".utf8) + [0]
        bytes += [0, 0, 0, 0, 0, 0, 0, 1]                      // time tag "immediately"
        bytes += [0, 0, 0, UInt8(first.count)] + first
        bytes += [0, 0, 0, UInt8(apply.count)] + apply

        let packet = try OSCPacket.decode(Data(bytes))
        guard case .bundle(let bundle) = packet else { return XCTFail("expected bundle") }
        XCTAssertEqual(bundle.timeTag, 1)
        XCTAssertEqual(bundle.elements.count, 2)
        XCTAssertEqual(packet.messages.map(\.address), ["/VMC/Ext/Blend/Val", "/VMC/Ext/Blend/Apply"])
        XCTAssertEqual(packet.messages[1].arguments, [])
    }

    func testMessageWithoutTypeTagsDecodesAsNoArguments() throws {
        let packet = try OSCPacket.decode(Data(Array("/VMC/Ext/Blend/Apply".utf8) + [0, 0, 0, 0]))
        XCTAssertEqual(packet, .message(OSCMessage(address: "/VMC/Ext/Blend/Apply")))
    }

    func testRoundTripAllArgumentTypes() throws {
        let message = OSCMessage(address: "/test/all", arguments: [
            .int32(-7), .float32(1.25), .string("héllo"), .blob(Data([1, 2, 3, 4, 5])),
            .int64(1 << 40), .double(2.5), .boolean(true), .boolean(false), .null, .impulse
        ])
        let decoded = try OSCPacket.decode(message.encode())
        XCTAssertEqual(decoded, .message(message))
        XCTAssertEqual(message.encode().count % 4, 0)
    }

    func testNestedBundleRoundTrip() throws {
        let inner = OSCBundle(timeTag: 42, elements: [.message(OSCMessage("/a", .int32(1)))])
        let outer = OSCBundle(elements: [.bundle(inner), .message(OSCMessage("/b", .float32(2)))])
        let decoded = try OSCPacket.decode(outer.encode())
        XCTAssertEqual(decoded, .bundle(outer))
        XCTAssertEqual(decoded.messages.map(\.address), ["/a", "/b"])
    }

    func testTruncatedFloatThrows() {
        var bytes = [UInt8](handBuiltBlendValue)
        bytes.removeLast(2)
        XCTAssertThrowsError(try OSCPacket.decode(Data(bytes))) { error in
            XCTAssertEqual(error as? OSCDecodingError, .truncated)
        }
    }

    func testAddressWithoutSlashThrows() {
        XCTAssertThrowsError(try OSCPacket.decode(Data(Array("VMC".utf8) + [0]))) { error in
            XCTAssertEqual(error as? OSCDecodingError, .malformedAddress("VMC"))
        }
    }

    func testUnknownTypeTagThrows() {
        let bytes = Array("/x".utf8) + [0, 0] + Array(",q".utf8) + [0, 0]
        XCTAssertThrowsError(try OSCPacket.decode(Data(bytes))) { error in
            XCTAssertEqual(error as? OSCDecodingError, .unsupportedTypeTag("q"))
        }
    }

    func testEmptyDataThrowsTruncated() {
        XCTAssertThrowsError(try OSCPacket.decode(Data())) { error in
            XCTAssertEqual(error as? OSCDecodingError, .truncated)
        }
    }
}
