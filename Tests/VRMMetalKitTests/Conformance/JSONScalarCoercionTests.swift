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

    // MARK: - parseVector3 property tests (VMK#236)

    /// Coverage matrix for the vec3 coercion contract: the same
    /// `AnyCodable` Int-before-Double pathology that hit the scalar
    /// reader also surfaces at the vec3 level — spec-compliant collider
    /// offsets like `[0.02, -0.10, 0.0]` decode to `[Double, Double, Int]`
    /// and the homogeneous-only fallbacks silently miss them, leaving every
    /// spring-bone collider at `(0, 0, 0)` (VMK#236).

    func testParseVector3AcceptsHomogeneousDoubleArray() {
        let parser = VRMExtensionParser()
        let v = parser.parseVector3([1.0, 2.0, 3.0])
        XCTAssertEqual(v, SIMD3<Float>(1, 2, 3))
    }

    func testParseVector3AcceptsHomogeneousFloatArray() {
        let parser = VRMExtensionParser()
        let v = parser.parseVector3([Float(1), Float(2), Float(3)])
        XCTAssertEqual(v, SIMD3<Float>(1, 2, 3))
    }

    func testParseVector3AcceptsMixedAnyCodableArray() {
        let parser = VRMExtensionParser()
        // The spec-typical collider-offset shape from AnyCodable.
        let mixed: [Any] = [Double(0.02), Double(-0.10), Int(0)]
        let v = parser.parseVector3(mixed)
        XCTAssertNotNil(v, "Mixed numeric Any-array must coerce per-element (VMK#236 root cause).")
        XCTAssertEqual(v?.x ?? 0, 0.02, accuracy: 1e-6)
        XCTAssertEqual(v?.y ?? 0, -0.10, accuracy: 1e-6)
        XCTAssertEqual(v?.z ?? 0, 0.0, accuracy: 1e-6)
    }

    func testParseVector3AcceptsAllIntegerAnyCodableArray() {
        let parser = VRMExtensionParser()
        // E.g. a plane normal authored as `[0, 1, 0]`.
        let allInt: [Any] = [Int(0), Int(1), Int(0)]
        let v = parser.parseVector3(allInt)
        XCTAssertEqual(v, SIMD3<Float>(0, 1, 0))
    }

    func testParseVector3RejectsWrongLength() {
        let parser = VRMExtensionParser()
        XCTAssertNil(parser.parseVector3([1.0, 2.0]))
        XCTAssertNil(parser.parseVector3([1.0, 2.0, 3.0, 4.0]))
    }

    func testParseVector3RejectsNonNumericElement() {
        let parser = VRMExtensionParser()
        let bogus: [Any] = [1.0, "two", 3.0]
        XCTAssertNil(parser.parseVector3(bogus),
            "A non-numeric element must fail closed — silently dropping it would re-introduce the VMK#236 silent-degradation pattern.")
    }

    func testParseVector3ReturnsNilForNonArray() {
        let parser = VRMExtensionParser()
        XCTAssertNil(parser.parseVector3(nil))
        XCTAssertNil(parser.parseVector3("x,y,z"))
        XCTAssertNil(parser.parseVector3(Double(1.0)))
    }
}
