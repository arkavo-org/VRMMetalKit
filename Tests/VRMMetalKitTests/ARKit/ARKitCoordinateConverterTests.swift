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

final class ARKitCoordinateConverterTests: XCTestCase {
    /// The root rotation correction is a 180° turn about Y, which maps
    /// (x, y, z) to (-x, y, -z). The translation must follow the same map or
    /// lateral hips motion ends up mirrored relative to the rotated body.
    func testHipsTranslationFollowsRootRotationCorrection() {
        var transform = matrix_identity_float4x4
        transform.columns.3 = SIMD4<Float>(-1, 0.9, 2, 1)

        let converted = ARKitCoordinateConverter.convertHipsTranslation(from: transform)

        XCTAssertEqual(converted.x, 1, accuracy: 1e-6, "lateral axis must flip with the Ry180 root correction")
        XCTAssertEqual(converted.y, 0.9, accuracy: 1e-6)
        XCTAssertEqual(converted.z, -2, accuracy: 1e-6)
    }

    /// A child joint whose parent transform is absent from the frame cannot
    /// produce a local rotation. The documented contract (and the driver's
    /// guard) is to skip the joint, not to overwrite it with identity.
    func testMissingParentTransformReturnsNil() {
        let skeleton = ARKitBodySkeleton(
            timestamp: 0,
            joints: [.leftLowerArm: matrix_identity_float4x4],
            isTracked: true)

        let rotation = ARKitCoordinateConverter.computeVRMRotation(
            joint: .leftLowerArm,
            childTransform: matrix_identity_float4x4,
            skeleton: skeleton)

        XCTAssertNil(rotation, "joint with a missing parent must be skipped, got \(String(describing: rotation))")
    }
}
