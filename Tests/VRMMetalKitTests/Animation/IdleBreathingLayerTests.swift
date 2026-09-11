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
import simd
@testable import VRMMetalKit

/// The idle layer's output is applied as a local delta on top of the
/// normalized VRM rest pose (identity rotations, T-pose). In that frame the
/// left upper arm points along +X and the right upper arm along -X, so the
/// "arms down" rotation must carry both bone directions below the horizontal.
final class IdleBreathingLayerTests: XCTestCase {
    private func evaluated() -> LayerOutput {
        let layer = IdleBreathingLayer()
        layer.microMovementEnabled = false
        layer.update(deltaTime: 1.0 / 60.0, context: AnimationContext())
        return layer.evaluate()
    }

    func testUpperArmsRotateDownFromTPose() {
        let output = evaluated()
        let left = output.bones[.leftUpperArm]!.rotation.act(SIMD3<Float>(1, 0, 0))
        let right = output.bones[.rightUpperArm]!.rotation.act(SIMD3<Float>(-1, 0, 0))
        XCTAssertLessThan(left.y, -0.5, "left arm should hang below horizontal, got \(left)")
        XCTAssertLessThan(right.y, -0.5, "right arm should hang below horizontal, got \(right)")
        XCTAssertEqual(left.y, right.y, accuracy: 1e-5, "arms should droop symmetrically")
    }

    func testElbowsBendForward() {
        let output = evaluated()
        let left = output.bones[.leftLowerArm]!.rotation.act(SIMD3<Float>(1, 0, 0))
        let right = output.bones[.rightLowerArm]!.rotation.act(SIMD3<Float>(-1, 0, 0))
        XCTAssertGreaterThan(left.z, 0.1, "left forearm should bend toward +Z (front), got \(left)")
        XCTAssertGreaterThan(right.z, 0.1, "right forearm should bend toward +Z (front), got \(right)")
    }
}
