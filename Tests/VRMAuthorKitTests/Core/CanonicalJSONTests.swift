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
import XCTest
@testable import VRMAuthorKit

final class CanonicalJSONTests: XCTestCase {
    private func canon(_ text: String) throws -> String {
        let value = try JSONValue.parse(Data(text.utf8))
        return try CanonicalJSON.string(value)
    }

    func testNumberFormatsFollowECMAScript() throws {
        let cases: [(String, String)] = [
            ("1", "1"), ("1.0", "1"), ("-0", "0"), ("-0.0", "0"), ("0.1", "0.1"),
            ("1e-6", "0.000001"), ("1e-7", "1e-7"), ("1e20", "100000000000000000000"),
            ("1e21", "1e+21"), ("1.5e300", "1.5e+300"), ("5e-324", "5e-324"),
            ("9007199254740992", "9007199254740992"), ("1.2345678901234568e20", "123456789012345680000"),
            ("0.000001", "0.000001"), ("-1.25", "-1.25"), ("2.5e-10", "2.5e-10"),
            ("1E2", "100"), ("333333333.33333334", "333333333.3333333"), ("1e24", "1e+24"),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(try canon(input), expected, "input \(input)")
        }
        XCTAssertEqual(try CanonicalJSON.formatNumber(1.2345678901234568e20), "123456789012345680000")
        XCTAssertEqual(try CanonicalJSON.formatNumber(-0.0), "0")
        XCTAssertEqual(try CanonicalJSON.formatNumber(Double.greatestFiniteMagnitude), "1.7976931348623157e+308")
        XCTAssertEqual(try CanonicalJSON.formatNumber(Double(Float(0.1))), "0.10000000149011612")
    }

    func testRFC8785KeyOrderingUsesUTF16CodeUnits() throws {
        let text = #"{"\u20ac":"Euro Sign","\r":"Carriage Return","\ufb33":"Hebrew Letter Dalet With Dagesh","1":"One","\ud83d\ude00":"Emoji: Grinning Face","\u0080":"Control","\u00f6":"Latin Small Letter O With Diaeresis"}"#
        let expected = #"{"\r":"Carriage Return","1":"One","\#u{80}":"Control","ö":"Latin Small Letter O With Diaeresis","€":"Euro Sign","😀":"Emoji: Grinning Face","דּ":"Hebrew Letter Dalet With Dagesh"}"#
        XCTAssertEqual(try canon(text), expected)
    }

    func testRFC8785SampleDocument() throws {
        let text = """
        {
          "numbers": [333333333.33333329, 1E30, 4.50, 2e-3, 0.000000000000000000000000001],
          "string": "\\u20ac$\\u000F\\u000aA'\\u0042\\u0022\\u005c\\\\\\"\\/",
          "literals": [null, true, false]
        }
        """
        let expected = #"{"literals":[null,true,false],"numbers":[333333333.3333333,1e+30,4.5,0.002,1e-27],"string":"€$\u000f\nA'B\"\\\\\"/"}"#
        XCTAssertEqual(try canon(text), expected)
    }

    func testStringEscapes() throws {
        let value = JSONValue.string("a\u{08}\u{0C}\n\r\t\"\\\u{01}\u{1F}\u{7F}\u{2028}/")
        XCTAssertEqual(try CanonicalJSON.string(value), #""a\b\f\n\r\t\"\\\u0001\u001f\#u{7F}\#u{2028}/""#)
    }

    func testNonFiniteRejected() {
        XCTAssertThrowsError(try CanonicalJSON.data(.number(.nan)))
        XCTAssertThrowsError(try CanonicalJSON.data(.number(.infinity)))
        XCTAssertThrowsError(try CanonicalJSON.data(.array([.number(-.infinity)])))
    }

    func testNoInsignificantWhitespaceAndNestedStructures() throws {
        XCTAssertEqual(try canon(" { \"b\" : [ 1 , { \"z\" : null , \"a\" : [] } ] , \"a\" : {} } "), #"{"a":{},"b":[1,{"a":[],"z":null}]}"#)
    }

    func testSHA256HexOfCanonicalBytes() throws {
        XCTAssertEqual(SHA256Hex.hex(Data()), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(SHA256Hex.hex(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(try CanonicalJSON.sha256(.object(["a": .number(1)])), SHA256Hex.hex(Data(#"{"a":1}"#.utf8)))
    }

    func testParserRejectsDuplicateKeys() {
        XCTAssertThrowsError(try JSONValue.parse(Data(#"{"a":1,"a":2}"#.utf8)))
        XCTAssertThrowsError(try JSONValue.parse(Data(#"{"a":{"b":1,"b":1}}"#.utf8)))
    }

    func testParserRejectsIntegersBeyond53Bits() throws {
        XCTAssertThrowsError(try JSONValue.parse(Data("9007199254740993".utf8)))
        XCTAssertThrowsError(try JSONValue.parse(Data("-9007199254740993".utf8)))
        XCTAssertThrowsError(try JSONValue.parse(Data("18446744073709551616".utf8)))
        XCTAssertEqual(try JSONValue.parse(Data("9007199254740991".utf8)), .number(9007199254740991))
        XCTAssertEqual(try JSONValue.parse(Data("9007199254740992".utf8)), .number(9007199254740992))
        XCTAssertThrowsError(try JSONValue.parse(Data("1e400".utf8)))
    }

    func testParserRejectsMalformedDocuments() {
        for text in ["", "{", "[1,]", "{\"a\":}", "tru", "01", "1.", ".5", "\"\\x\"", "\"unterminated", "{\"a\":1} extra", "NaN", "Infinity", "-", "+1"] {
            XCTAssertThrowsError(try JSONValue.parse(Data(text.utf8)), "input \(text)")
        }
    }

    func testParserRoundTripsUnicodeAndSurrogates() throws {
        let parsed = try JSONValue.parse(Data(#"["\ud83d\ude00", "\u00e9", "é", "\\", "\/"]"#.utf8))
        XCTAssertEqual(parsed, .array([.string("😀"), .string("é"), .string("é"), .string("\\"), .string("/")]))
        XCTAssertThrowsError(try JSONValue.parse(Data(#"["\ud83d"]"#.utf8)))
        XCTAssertThrowsError(try JSONValue.parse(Data(#"["\ude00"]"#.utf8)))
    }

    func testJSONValueAccessorsAndSubscripts() throws {
        let value = try JSONValue.parse(Data(#"{"a":[1,2.5,"x",true,null],"b":{"c":"d"}}"#.utf8))
        XCTAssertEqual(value["a"]?[1]?.number, 2.5)
        XCTAssertEqual(value["a"]?[0]?.int, 1)
        XCTAssertNil(value["a"]?[1]?.int)
        XCTAssertEqual(value["a"]?[2]?.string, "x")
        XCTAssertEqual(value["a"]?[3]?.bool, true)
        XCTAssertEqual(value["a"]?[4], .null)
        XCTAssertNil(value["a"]?[5])
        XCTAssertNil(value["zzz"])
        XCTAssertEqual(value["b"]?.object?["c"], .string("d"))
        XCTAssertEqual(value["a"]?.array?.count, 5)
        XCTAssertTrue(value["a"]?[4]?.isNull ?? false)
    }

    func testCodableBridgeAndLiterals() throws {
        let literal: JSONValue = ["k": [1, "two", true, nil, 2.5], "n": 3]
        let data = try JSONEncoder().encode(literal)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(decoded, literal)
        XCTAssertEqual(try CanonicalJSON.string(decoded), #"{"k":[1,"two",true,null,2.5],"n":3}"#)
    }

    func testCanonicalOutputIsIdempotentAndStableAcrossOrderings() throws {
        let a = try canon(#"{"b":1,"a":{"d":[1,2],"c":"x"}}"#)
        let b = try canon(#"{"a":{"c":"x","d":[1,2]},"b":1.0}"#)
        XCTAssertEqual(a, b)
        XCTAssertEqual(try canon(a), a)
    }
}
