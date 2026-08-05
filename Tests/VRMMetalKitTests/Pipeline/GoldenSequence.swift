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
import Metal
import simd
@testable import VRMMetalKit

/// One frame of an avatar's committed pose: every humanoid bone's rotation plus
/// every scene-root translation. Wider than `StaggerShoveIntegrationTests`'
/// leg-and-root capture because a stage refactor can perturb bones no single
/// feature writes.
struct PoseSample: Equatable {
    let bones: [SIMD4<Float>]
    let roots: [SIMD4<Float>]
}

/// Captures `model`'s full humanoid pose. Bones are sampled in
/// `VRMHumanoidBone.allCases` order; absent bones contribute the identity
/// quaternion so the sample length is rig-independent.
@MainActor func capturePose(_ model: VRMModel) throws -> PoseSample {
    let humanoid = try XCTUnwrap(model.humanoid)
    var bones: [SIMD4<Float>] = []
    for bone in VRMHumanoidBone.allCases {
        if let idx = humanoid.getBoneNode(bone), idx < model.nodes.count {
            bones.append(model.nodes[idx].rotation.vector)
        } else {
            bones.append(SIMD4<Float>(0, 0, 0, 1))
        }
    }
    var roots: [SIMD4<Float>] = []
    for root in model.nodes where root.parent == nil {
        roots.append(SIMD4<Float>(root.translation, 0))
    }
    return PoseSample(bones: bones, roots: roots)
}

/// Runs `step(frameIndex)` `frames` times, capturing every model's pose after
/// each call. Returns one sequence per model, in `models` order.
@MainActor func captureSequence(frames: Int, step: (Int) -> Void,
                                models: [VRMModel]) throws -> [[PoseSample]] {
    var out: [[PoseSample]] = Array(repeating: [], count: models.count)
    for f in 0..<frames {
        step(f)
        for (i, m) in models.enumerated() {
            out[i].append(try capturePose(m))
        }
    }
    return out
}

/// Byte-identity across every model, every frame. Reports the first divergence
/// with its model and frame index — a trajectory fork usually starts one frame
/// before it is visible, so the index matters.
func assertSequencesIdentical(_ a: [[PoseSample]], _ b: [[PoseSample]], _ label: String,
                              file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(a.count, b.count, "\(label): model count", file: file, line: line)
    for (m, (seqA, seqB)) in zip(a, b).enumerated() {
        XCTAssertEqual(seqA.count, seqB.count, "\(label): frame count, model \(m)", file: file, line: line)
        for (f, (sa, sb)) in zip(seqA, seqB).enumerated() where sa != sb {
            XCTFail("\(label): diverged at model \(m), frame \(f)", file: file, line: line)
            return
        }
    }
}

/// Proves the helper detects the divergence class it exists to catch: a single
/// perturbed bone in one frame of one model.
final class GoldenSequenceTests: XCTestCase {
    func testDetectsSingleBoneDivergence() {
        let base = PoseSample(bones: [SIMD4<Float>(0, 0, 0, 1)], roots: [SIMD4<Float>(0, 0, 0, 0)])
        var perturbedBones = base.bones
        perturbedBones[0] = SIMD4<Float>(0, 0, 0.001, 1)
        let perturbed = PoseSample(bones: perturbedBones, roots: base.roots)
        XCTAssertNotEqual(base, perturbed)
    }

    func testIdenticalSamplesCompareEqual() {
        let a = PoseSample(bones: [SIMD4<Float>(1, 2, 3, 4)], roots: [SIMD4<Float>(5, 6, 7, 0)])
        let b = PoseSample(bones: [SIMD4<Float>(1, 2, 3, 4)], roots: [SIMD4<Float>(5, 6, 7, 0)])
        XCTAssertEqual(a, b)
    }
}
