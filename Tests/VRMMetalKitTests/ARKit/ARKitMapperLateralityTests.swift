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

import XCTest
@testable import VRMMetalKit

/// ARKit blend shapes are face-relative ("left" is the user's left) and VRM
/// `lookLeft` / `blinkLeft` are the model's own left. By default the mapper
/// keeps laterality (the avatar stands in for the user, as when recording or
/// streaming); `mirrorLateral` swaps every left/right pair for self-view
/// apps that show the user their avatar like a mirror.
final class ARKitMapperLateralityTests: XCTestCase {
    /// User looks to their own left: ARKit reports eyeLookOutLeft + eyeLookInRight.
    private let userLooksLeft = ARKitFaceBlendShapes(timestamp: 0, shapes: [
        ARKitFaceBlendShapes.eyeLookOutLeft: 1, ARKitFaceBlendShapes.eyeLookInRight: 1,
    ])
    private let userBlinksLeft = ARKitFaceBlendShapes(timestamp: 0, shapes: [ARKitFaceBlendShapes.eyeBlinkLeft: 1])

    func testDefaultKeepsLaterality() {
        let mapper = ARKitToVRMMapper.default
        let look = mapper.evaluate(userLooksLeft)
        XCTAssertEqual(look["lookLeft"] ?? 0, 1, accuracy: 1e-5, "user's leftward gaze drives lookLeft")
        XCTAssertEqual(look["lookRight"] ?? 0, 0, accuracy: 1e-5)
        let blink = mapper.evaluate(userBlinksLeft)
        XCTAssertEqual(blink["blinkLeft"] ?? 0, 1, accuracy: 1e-5)
        XCTAssertEqual(blink["blinkRight"] ?? 0, 0, accuracy: 1e-5)
    }

    func testMirrorLateralSwapsEveryPair() {
        var mapper = ARKitToVRMMapper.default
        mapper.mirrorLateral = true
        let look = mapper.evaluate(userLooksLeft)
        XCTAssertEqual(look["lookRight"] ?? 0, 1, accuracy: 1e-5, "mirrored: user's leftward gaze drives lookRight")
        XCTAssertEqual(look["lookLeft"] ?? 0, 0, accuracy: 1e-5)
        let blink = mapper.evaluate(userBlinksLeft)
        XCTAssertEqual(blink["blinkRight"] ?? 0, 1, accuracy: 1e-5, "mirrored: blinks swap too")
        XCTAssertEqual(blink["blinkLeft"] ?? 0, 0, accuracy: 1e-5)
        XCTAssertEqual(mapper.evaluate(userBlinksLeft, expression: "blinkRight"), 1, accuracy: 1e-5)
    }

    func testMirrorLeavesSymmetricExpressionsAlone() {
        var mapper = ARKitToVRMMapper.default
        mapper.mirrorLateral = true
        let shapes = ARKitFaceBlendShapes(timestamp: 0, shapes: [
            ARKitFaceBlendShapes.eyeLookUpLeft: 1, ARKitFaceBlendShapes.eyeLookUpRight: 1, ARKitFaceBlendShapes.jawOpen: 1,
        ])
        let result = mapper.evaluate(shapes)
        XCTAssertEqual(result["lookUp"] ?? 0, 1, accuracy: 1e-5)
        XCTAssertEqual(result["aa"] ?? 0, ARKitToVRMMapper.default.evaluate(shapes)["aa"] ?? -1, accuracy: 1e-5)
    }
}
