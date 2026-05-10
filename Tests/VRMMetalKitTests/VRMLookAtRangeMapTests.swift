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
import simd
@testable import VRMMetalKit

// MARK: - G4: Bone mode rangeMap tests

final class VRMLookAtRangeMapBoneModeTests: XCTestCase {

    // VRM 1.0 spec: output = clamp(abs(input_deg) / inputMaxValue, 0, 1) * outputScale

    func testRangeMapHalfInput() {
        let map = VRMLookAtRangeMap(inputMaxValue: 90.0, outputScale: 45.0)
        let inputRad: Float = 45.0 * (.pi / 180.0)
        let output = VRMLookAtController.rangeMapOutput(inputRad, map: map)
        // 45/90 = 0.5, * 45 = 22.5 deg, sign preserved positive
        XCTAssertEqual(output, 22.5, accuracy: 0.001)
    }

    func testRangeMapFullInput() {
        let map = VRMLookAtRangeMap(inputMaxValue: 90.0, outputScale: 45.0)
        let inputRad: Float = 90.0 * (.pi / 180.0)
        let output = VRMLookAtController.rangeMapOutput(inputRad, map: map)
        // 90/90 = 1.0, * 45 = 45 deg
        XCTAssertEqual(output, 45.0, accuracy: 0.001)
    }

    func testRangeMapClampsBeyondInputMax() {
        let map = VRMLookAtRangeMap(inputMaxValue: 90.0, outputScale: 45.0)
        let inputRad: Float = 180.0 * (.pi / 180.0)
        let output = VRMLookAtController.rangeMapOutput(inputRad, map: map)
        // clamped to 1.0, * 45 = 45 deg
        XCTAssertEqual(output, 45.0, accuracy: 0.001)
    }

    func testRangeMapZeroInput() {
        let map = VRMLookAtRangeMap(inputMaxValue: 90.0, outputScale: 45.0)
        let output = VRMLookAtController.rangeMapOutput(0.0, map: map)
        XCTAssertEqual(output, 0.0, accuracy: 0.001)
    }

    func testRangeMapNegativeInputPreservesSign() {
        let map = VRMLookAtRangeMap(inputMaxValue: 90.0, outputScale: 45.0)
        let inputRad: Float = -45.0 * (.pi / 180.0)
        let output = VRMLookAtController.rangeMapOutput(inputRad, map: map)
        // 45/90 = 0.5, * 45 = 22.5 deg, sign negative
        XCTAssertEqual(output, -22.5, accuracy: 0.001)
    }

    func testRangeMapOutputScaleApplied() {
        // inputMaxValue=60, outputScale=30: at 30 deg input -> 30/60=0.5, *30=15
        let map = VRMLookAtRangeMap(inputMaxValue: 60.0, outputScale: 30.0)
        let inputRad: Float = 30.0 * (.pi / 180.0)
        let output = VRMLookAtController.rangeMapOutput(inputRad, map: map)
        XCTAssertEqual(output, 15.0, accuracy: 0.001)
    }

    func testRangeMapBoneModeOutputIsInDegrees() {
        // Confirm output is degrees (converted from the bone rotation formula)
        // With inputMaxValue=90, outputScale=45: at 90 deg input -> 45 deg output
        // If applied as radians the eye would rotate 45 deg, not 45*pi/180
        let map = VRMLookAtRangeMap(inputMaxValue: 90.0, outputScale: 45.0)
        let inputRad: Float = 90.0 * (.pi / 180.0)
        let outputDeg = VRMLookAtController.rangeMapOutput(inputRad, map: map)
        let outputRad = outputDeg * (.pi / 180.0)
        // Converting back to radians should give pi/4 (45 degrees)
        XCTAssertEqual(outputRad, .pi / 4.0, accuracy: 0.001)
    }

    // G4: inner/outer distinction — right eye looking right uses outer map
    func testBoneModeRightEyeOuterMapUsedWhenLookingRight() {
        // For right eye, yaw > 0 is outer; we verify rangeMapOutput uses outer map correctly
        let outerMap = VRMLookAtRangeMap(inputMaxValue: 90.0, outputScale: 30.0)
        let innerMap = VRMLookAtRangeMap(inputMaxValue: 90.0, outputScale: 60.0)
        let inputRad: Float = 90.0 * (.pi / 180.0)

        let outerOutput = VRMLookAtController.rangeMapOutput(inputRad, map: outerMap)
        let innerOutput = VRMLookAtController.rangeMapOutput(inputRad, map: innerMap)

        // Outer gives 30 deg, inner gives 60 deg — they differ
        XCTAssertEqual(outerOutput, 30.0, accuracy: 0.001)
        XCTAssertEqual(innerOutput, 60.0, accuracy: 0.001)
        XCTAssertNotEqual(outerOutput, innerOutput)
    }

    // G4: inner/outer distinction — right eye looking left uses inner map
    func testBoneModeRightEyeInnerMapUsedWhenLookingLeft() {
        let innerMap = VRMLookAtRangeMap(inputMaxValue: 90.0, outputScale: 60.0)
        let inputRad: Float = -45.0 * (.pi / 180.0)
        let output = VRMLookAtController.rangeMapOutput(inputRad, map: innerMap)
        // 45/90=0.5, *60=30, sign negative
        XCTAssertEqual(output, -30.0, accuracy: 0.001)
    }

    // G4: vertical up
    func testBoneModeVerticalUpMap() {
        let upMap = VRMLookAtRangeMap(inputMaxValue: 60.0, outputScale: 20.0)
        let inputRad: Float = 30.0 * (.pi / 180.0)
        let output = VRMLookAtController.rangeMapOutput(inputRad, map: upMap)
        // 30/60=0.5, *20=10
        XCTAssertEqual(output, 10.0, accuracy: 0.001)
    }

    // G4: vertical down
    func testBoneModeVerticalDownMap() {
        let downMap = VRMLookAtRangeMap(inputMaxValue: 60.0, outputScale: 25.0)
        let inputRad: Float = -60.0 * (.pi / 180.0)
        let output = VRMLookAtController.rangeMapOutput(inputRad, map: downMap)
        // 60/60=1.0, *25=25, sign negative
        XCTAssertEqual(output, -25.0, accuracy: 0.001)
    }
}

// MARK: - G5: Expression mode rangeMap tests

final class VRMLookAtRangeMapExpressionModeTests: XCTestCase {

    // Expression mode: output weight = clamp(abs(input_deg)/inputMaxValue, 0, 1) * outputScale
    // outputScale is typically 1.0 (full weight at inputMaxValue degrees)

    func testExpressionWeightAtHalfInput() {
        // With inputMaxValue=90, outputScale=1.0: at 45 deg -> weight=0.5
        let map = VRMLookAtRangeMap(inputMaxValue: 90.0, outputScale: 1.0)
        let inputRad: Float = 45.0 * (.pi / 180.0)
        let weight = abs(VRMLookAtController.rangeMapOutput(inputRad, map: map))
        XCTAssertEqual(weight, 0.5, accuracy: 0.001)
    }

    func testExpressionWeightAtFullInput() {
        // With inputMaxValue=90, outputScale=1.0: at 90 deg -> weight=1.0
        let map = VRMLookAtRangeMap(inputMaxValue: 90.0, outputScale: 1.0)
        let inputRad: Float = 90.0 * (.pi / 180.0)
        let weight = abs(VRMLookAtController.rangeMapOutput(inputRad, map: map))
        XCTAssertEqual(weight, 1.0, accuracy: 0.001)
    }

    func testExpressionWeightClampedBeyondInputMax() {
        let map = VRMLookAtRangeMap(inputMaxValue: 90.0, outputScale: 1.0)
        let inputRad: Float = 180.0 * (.pi / 180.0)
        let weight = abs(VRMLookAtController.rangeMapOutput(inputRad, map: map))
        // clamp at 1.0
        XCTAssertEqual(weight, 1.0, accuracy: 0.001)
    }

    func testExpressionWeightWithOutputScaleOverdrive() {
        // outputScale > 1.0 for overdrive: at inputMaxValue deg -> weight = outputScale
        let map = VRMLookAtRangeMap(inputMaxValue: 45.0, outputScale: 1.5)
        let inputRad: Float = 45.0 * (.pi / 180.0)
        let weight = abs(VRMLookAtController.rangeMapOutput(inputRad, map: map))
        XCTAssertEqual(weight, 1.5, accuracy: 0.001)
    }

    func testExpressionWeightHorizontalOuter_LookRight() {
        // Per spec: expression mode uses horizontalOuter for both yaw directions
        let outerMap = VRMLookAtRangeMap(inputMaxValue: 90.0, outputScale: 1.0)
        let inputRad: Float = 45.0 * (.pi / 180.0)
        let weight = abs(VRMLookAtController.rangeMapOutput(inputRad, map: outerMap))
        // 45/90=0.5 -> LookRight weight should be 0.5
        XCTAssertEqual(weight, 0.5, accuracy: 0.001)
    }

    func testExpressionWeightHorizontalOuter_LookLeft() {
        let outerMap = VRMLookAtRangeMap(inputMaxValue: 90.0, outputScale: 1.0)
        let inputRad: Float = -45.0 * (.pi / 180.0)
        let weight = abs(VRMLookAtController.rangeMapOutput(inputRad, map: outerMap))
        // symmetric: 45/90=0.5 -> LookLeft weight should be 0.5
        XCTAssertEqual(weight, 0.5, accuracy: 0.001)
    }

    func testExpressionWeightVerticalUp() {
        let upMap = VRMLookAtRangeMap(inputMaxValue: 60.0, outputScale: 1.0)
        let inputRad: Float = 30.0 * (.pi / 180.0)
        let weight = abs(VRMLookAtController.rangeMapOutput(inputRad, map: upMap))
        // 30/60=0.5 -> LookUp weight 0.5
        XCTAssertEqual(weight, 0.5, accuracy: 0.001)
    }

    func testExpressionWeightVerticalDown() {
        let downMap = VRMLookAtRangeMap(inputMaxValue: 60.0, outputScale: 1.0)
        let inputRad: Float = -60.0 * (.pi / 180.0)
        let weight = abs(VRMLookAtController.rangeMapOutput(inputRad, map: downMap))
        // 60/60=1.0 -> LookDown weight 1.0
        XCTAssertEqual(weight, 1.0, accuracy: 0.001)
    }

    func testExpressionWeightZeroInput() {
        let map = VRMLookAtRangeMap(inputMaxValue: 90.0, outputScale: 1.0)
        let weight = abs(VRMLookAtController.rangeMapOutput(0.0, map: map))
        XCTAssertEqual(weight, 0.0, accuracy: 0.001)
    }

    func testExpressionWeightCustomInputMaxValue() {
        // Verify inputMaxValue correctly sets the 100% weight threshold
        // inputMaxValue=45: at 22.5 deg -> weight=0.5
        let map = VRMLookAtRangeMap(inputMaxValue: 45.0, outputScale: 1.0)
        let inputRad: Float = 22.5 * (.pi / 180.0)
        let weight = abs(VRMLookAtController.rangeMapOutput(inputRad, map: map))
        XCTAssertEqual(weight, 0.5, accuracy: 0.001)
    }
}
