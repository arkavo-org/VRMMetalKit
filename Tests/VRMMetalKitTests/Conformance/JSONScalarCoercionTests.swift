//
// Copyright 2025 Arkavo
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//

import XCTest
@testable import VRMMetalKit

/// PR #254 review follow-up: lock in that VRMExtensionParser's
/// `parseFloatValue(_:)` handles every numeric type the JSON pipeline can
/// produce — `Int`, `Double`, `Float`, and `NSNumber`. The original
/// VMK#238/#239 root cause was that an `as? Double` cast silently failed
/// when AnyCodable stored a JSON whole-number literal as `Int`. The same
/// pattern existed at several other sites (`xRange`, `yRange`,
/// `inputMaxValue`, `outputScale`, `firstPersonBoneOffset.{x,y,z}`); this
/// test pins down the canonical reader so the bug class can't return.
final class JSONScalarCoercionTests: XCTestCase {

    func testParseFloatValueAcceptsIntFromAnyCodable() {
        let parser = VRMExtensionParser()
        // AnyCodable decodes JSON `1` and JSON `1.0` both as raw Swift Int.
        // Without the explicit Int branch the cast silently failed.
        XCTAssertEqual(parser.parseFloatValue(Int(1)), 1.0)
        XCTAssertEqual(parser.parseFloatValue(Int(0)), 0.0)
        XCTAssertEqual(parser.parseFloatValue(Int(-1)), -1.0)
    }

    func testParseFloatValueAcceptsDouble() {
        let parser = VRMExtensionParser()
        XCTAssertEqual(parser.parseFloatValue(Double(0.5)), 0.5)
        XCTAssertEqual(parser.parseFloatValue(Double(-2.25)), -2.25)
    }

    func testParseFloatValueAcceptsFloat() {
        let parser = VRMExtensionParser()
        XCTAssertEqual(parser.parseFloatValue(Float(3.14)), 3.14)
    }

    func testParseFloatValueAcceptsNSNumber() {
        let parser = VRMExtensionParser()
        // JSONSerialization (used for VRM 0.0 `floatProperties` etc.) emits
        // NSNumber, not Int/Double directly. Catch this path too.
        let n: NSNumber = 42
        XCTAssertEqual(parser.parseFloatValue(n), 42.0)
    }

    func testParseFloatValueReturnsNilForNonNumeric() {
        let parser = VRMExtensionParser()
        XCTAssertNil(parser.parseFloatValue(nil))
        XCTAssertNil(parser.parseFloatValue("0.5"))
        XCTAssertNil(parser.parseFloatValue([1.0, 2.0]))
    }
}
