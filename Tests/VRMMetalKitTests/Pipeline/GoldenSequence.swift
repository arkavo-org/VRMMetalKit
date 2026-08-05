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

    func testAssertSequencesIdenticalDetectsDivergenceAtKnownIndex() {
        let sample = PoseSample(bones: [SIMD4<Float>(0, 0, 0, 1)], roots: [SIMD4<Float>(0, 0, 0, 0)])
        var perturbedBones = sample.bones
        perturbedBones[0] = SIMD4<Float>(0.1, 0, 0, 1)
        let perturbed = PoseSample(bones: perturbedBones, roots: sample.roots)

        let seqA = [[sample, sample], [sample, sample]]
        var seqB = [[sample, sample], [sample, sample]]
        seqB[1][1] = perturbed

        XCTExpectFailure("diverged at model 1, frame 1")
        assertSequencesIdentical(seqA, seqB, "test divergence detection")
    }

    func testAssertSequencesIdenticalDetectsDifferentModelCount() {
        let sample = PoseSample(bones: [SIMD4<Float>(0, 0, 0, 1)], roots: [SIMD4<Float>(0, 0, 0, 0)])
        let seqA = [[sample]]
        let seqB = [[sample], [sample]]

        XCTExpectFailure("model count")
        assertSequencesIdentical(seqA, seqB, "model count mismatch")
    }

    func testAssertSequencesIdenticalDetectsDifferentFrameCount() {
        let sample = PoseSample(bones: [SIMD4<Float>(0, 0, 0, 1)], roots: [SIMD4<Float>(0, 0, 0, 0)])
        let seqA = [[sample, sample]]
        let seqB = [[sample]]

        XCTExpectFailure("frame count")
        assertSequencesIdentical(seqA, seqB, "frame count mismatch")
    }

    func testAssertSequencesIdenticalPassesForIdenticalSequences() {
        let sample = PoseSample(bones: [SIMD4<Float>(0, 0, 0, 1)], roots: [SIMD4<Float>(0, 0, 0, 0)])
        let seqA = [[sample, sample], [sample, sample]]
        let seqB = [[sample, sample], [sample, sample]]

        assertSequencesIdentical(seqA, seqB, "identical sequences")
    }

    @MainActor func testCapturePoseReadsKnownBoneRotation() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }

        let path = getTestVRM10ModelPath()
        try requireFixture(path, hint: testVRM10Filename)
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device,
            options: VRMLoadingOptions(augmentSpringBoneColliders: false))
        model.updateNodeTransforms()

        let humanoid = try XCTUnwrap(model.humanoid)
        let boneIdx = try XCTUnwrap(humanoid.getBoneNode(.chest))
        let knownRotation = simd_quatf(ix: 0.1, iy: 0.2, iz: 0.3, r: 0.9)
        model.nodes[boneIdx].rotation = knownRotation
        model.nodes[boneIdx].updateLocalMatrix()
        model.updateNodeTransforms()

        let sample = try capturePose(model)
        let chestIndex = VRMHumanoidBone.allCases.firstIndex(of: .chest)!
        let captured = sample.bones[chestIndex]
        let expected = knownRotation.vector
        let distance = simd_distance(captured, expected)
        XCTAssertLessThan(distance, 0.0001, "captured bone rotation matches written value")
    }

    @MainActor func testCaptureSequenceReturnsCorrectFrameCountAndOrder() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }

        let path = getTestVRM10ModelPath()
        try requireFixture(path, hint: testVRM10Filename)
        let model1 = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device,
            options: VRMLoadingOptions(augmentSpringBoneColliders: false))
        let model2 = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device,
            options: VRMLoadingOptions(augmentSpringBoneColliders: false))

        model1.updateNodeTransforms()
        model2.updateNodeTransforms()

        let humanoid = try XCTUnwrap(model1.humanoid)
        let boneIdx = try XCTUnwrap(humanoid.getBoneNode(.chest))

        var frameCount = 0
        let sequences = try captureSequence(frames: 5, step: { frameIndex in
            frameCount = frameIndex + 1
            let rotation = simd_quatf(ix: Float(frameIndex) * 0.1, iy: 0, iz: 0, r: 0.99)
            model1.nodes[boneIdx].rotation = rotation
            model1.nodes[boneIdx].updateLocalMatrix()
            model1.updateNodeTransforms()
        }, models: [model1, model2])

        XCTAssertEqual(sequences.count, 2, "sequence count matches model count")
        XCTAssertEqual(sequences[0].count, 5, "model 0 has 5 frames")
        XCTAssertEqual(sequences[1].count, 5, "model 1 has 5 frames")
        XCTAssertEqual(frameCount, 5, "step called 5 times")

        let chestIndex = VRMHumanoidBone.allCases.firstIndex(of: .chest)!
        XCTAssertNotEqual(sequences[0][0].bones[chestIndex], sequences[0][4].bones[chestIndex],
                          "model 1 frames show different rotations")
    }
}
