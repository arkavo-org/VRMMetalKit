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

final class OSCPacketHostileInputTests: XCTestCase {
    private func message(_ address: String, tags: String, payload: [UInt8]) -> Data {
        var bytes = Array(address.utf8) + [0]
        while bytes.count % 4 != 0 { bytes.append(0) }
        bytes += Array(tags.utf8) + [0]
        while bytes.count % 4 != 0 { bytes.append(0) }
        return Data(bytes + payload)
    }

    private func nestedBundles(depth: Int) -> Data {
        var inner = OSCBundle(elements: []).encode()
        for _ in 0..<depth {
            var wrapped = Data()
            OSCCodec.appendString("#bundle", to: &wrapped)
            OSCCodec.appendBigEndian(UInt64(1), to: &wrapped)
            OSCCodec.appendBigEndian(UInt32(inner.count), to: &wrapped)
            wrapped.append(inner)
            inner = wrapped
        }
        return inner
    }

    func testNaNFloatIntValueIsNilNotTrap() throws {
        let packet = try OSCPacket.decode(message("/VMC/Ext/OK", tags: ",f", payload: [0x7F, 0xC0, 0x00, 0x00]))
        let arg = try XCTUnwrap(packet.messages.first?.arguments.first)
        XCTAssertNil(arg.intValue)
        XCTAssertNil(OSCArgument.float32(.infinity).intValue)
        XCTAssertNil(OSCArgument.double(1e30).intValue)
        XCTAssertEqual(OSCArgument.float32(3.9).intValue, 3)
        XCTAssertEqual(OSCArgument.float32(-3.9).intValue, -3)

        let driver = VMCDriver()
        driver.receive(packet)
        XCTAssertEqual(driver.ignoredMessageCount, 1, "NaN status must be ignored, not applied")
    }

    func testBundleNestingAtLimitDecodes() throws {
        let packet = try OSCPacket.decode(nestedBundles(depth: OSCPacket.maxBundleDepth - 1))
        XCTAssertTrue(packet.messages.isEmpty)
    }

    func testBundleNestingPastLimitIsRejected() {
        XCTAssertThrowsError(try OSCPacket.decode(nestedBundles(depth: OSCPacket.maxBundleDepth + 1))) { error in
            XCTAssertEqual(error as? OSCDecodingError, .bundleTooDeep(OSCPacket.maxBundleDepth))
        }
        XCTAssertThrowsError(try OSCPacket.decode(nestedBundles(depth: 3000)))
    }

    func testMessagesFlattenDeepValueWithoutRecursion() {
        var packet = OSCPacket.message(OSCMessage("/leaf"))
        for _ in 0..<2_000 {
            packet = .bundle(OSCBundle(elements: [packet]))
        }
        XCTAssertEqual(packet.messages.map(\.address), ["/leaf"])
    }
}
