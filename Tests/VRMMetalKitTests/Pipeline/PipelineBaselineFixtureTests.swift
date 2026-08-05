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

/// Proves the fixture format round-trips bit-exactly, including values a
/// lossy (`%.6f`-style) format would corrupt: NaN-adjacent magnitudes,
/// negative zero, and the smallest denormals are not exercised here because
/// captured poses never produce them, but the bit-pattern-per-component
/// scheme is exact for any `Float` by construction — this test pins that.
final class PipelineBaselineFixtureTests: XCTestCase {
    func testRoundTripIsBitExact() {
        let bones: [SIMD4<Float>] = [
            SIMD4<Float>(0, -0.0, 1, -1),
            SIMD4<Float>(0.1, -0.1, 1e-8, -1e-8),
            SIMD4<Float>(Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude,
                         Float.leastNonzeroMagnitude, 3.14159265),
        ]
        let sample = PoseSample(bones: bones, roots: [SIMD4<Float>(-2.71828183, 0, 0, 0)])
        let sequences: [[PoseSample]] = [[sample, sample], [sample]]

        let text = PipelineBaselineFixture.serialize(sequences)
        let roundTripped = PipelineBaselineFixture.deserialize(text)

        XCTAssertEqual(sequences, roundTripped)
        for (a, b) in zip(sequences.flatMap { $0 }, roundTripped.flatMap { $0 }) {
            for (x, y) in zip(a.bones, b.bones) {
                XCTAssertEqual(x.x.bitPattern, y.x.bitPattern)
                XCTAssertEqual(x.y.bitPattern, y.y.bitPattern)
                XCTAssertEqual(x.z.bitPattern, y.z.bitPattern)
                XCTAssertEqual(x.w.bitPattern, y.w.bitPattern)
            }
        }
    }

    func testRoundTripThroughDisk() throws {
        let sample = PoseSample(bones: [SIMD4<Float>(1, 2, 3, 4)], roots: [SIMD4<Float>(5, 6, 7, 0)])
        let sequences: [[PoseSample]] = [[sample]]
        let path = NSTemporaryDirectory() + "pipeline-baseline-fixture-roundtrip-\(UUID().uuidString).txt"
        defer { try? FileManager.default.removeItem(atPath: path) }

        try PipelineBaselineFixture.write(sequences, toFile: path)
        let readBack = try PipelineBaselineFixture.read(fromFile: path)

        XCTAssertEqual(sequences, readBack)
    }
}
