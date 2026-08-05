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

/// C1's gate: the stage extraction is pure code motion, proven over N-frame
/// sequences rather than single frames. Evolving state — counterbalance decay,
/// the shove offset, the contact latch — diverges only over time, so a
/// single-frame identity check can pass while the trajectory forks.
///
/// The gate compares against a fixture committed BEFORE the extraction
/// (`Tests/VRMMetalKitTests/Fixtures/PipelineBaseline/`), not against a second
/// same-process run of the current code: two runs of identical post-refactor
/// code agreeing with each other proves determinism, not that the refactor
/// preserved behaviour. Byte-identity against a pre-refactor baseline is the
/// only thing that proves that.
///
/// Matrix: {stagger-off, stagger-on-pre-contact, stagger-on-post-contact}
/// × {single-avatar, crowd}. Each cell records a 60-frame sequence and compares
/// it against the committed baseline captured before extraction.
final class StageExtractionGateTests: XCTestCase {

    @MainActor private func avatar(_ device: MTLDevice, index: Int, count: Int) async throws
        -> CrowdFrameStepper.Avatar {
        let path = getTestVRM10ModelPath(); try requireFixture(path, hint: testVRM10Filename)
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device,
            options: VRMLoadingOptions(augmentSpringBoneColliders: false))
        var config = RendererConfig(); config.synchronousSpringBone = true
        let r = VRMRenderer(device: device, config: config)
        r.loadModel(model)
        for root in model.nodes where root.parent == nil {
            root.rotation = CrowdPlacement.facing(avatarIndex: index, avatarCount: count)
        }
        model.updateNodeTransforms()
        return CrowdFrameStepper.Avatar(renderer: r, model: model, player: AnimationPlayer(), index: index)
    }

    /// Constant half-separation: zero scripted root motion, so contact state is
    /// controlled purely by the separation value.
    private func holdDriver(halfSep: Float) -> CrowdMotionDriver {
        CrowdMotionDriver(startSep: halfSep, holdSep: halfSep,
                          approachStart: 0.0, approachEnd: 0.01, holdEnd: 1.0, partEnd: 1.0)
    }

    /// One matrix cell: builds a stepper, runs 60 frames, returns each avatar's sequence.
    @MainActor private func runCell(device: MTLDevice, avatarCount: Int,
                                    stagger: StaggerShoveParams?, halfSep: Float)
        async throws -> [[PoseSample]] {
        var built: [CrowdFrameStepper.Avatar] = []
        for i in 0..<avatarCount {
            built.append(try await avatar(device, index: i, count: avatarCount))
        }
        let stepper = CrowdFrameStepper(avatars: built, driver: holdDriver(halfSep: halfSep),
                                        group: nil, fps: 60,
                                        postural: PosturalContactParams(),
                                        stagger: stagger,
                                        armCounterbalance: ArmCounterbalanceParams())
        return try captureSequence(frames: 60,
                                   step: { f in stepper.step(frameTime: Float(f) / 60.0) },
                                   models: built.map { $0.model })
    }

    private static let cells: [(String, Int, StaggerShoveParams?, Float)] = [
        ("stagger-off/single",           1, nil,                     1.0),
        ("stagger-off/crowd",            2, nil,                     1.0),
        ("stagger-on-pre-contact/single", 1, StaggerShoveParams(),   1.0),
        ("stagger-on-pre-contact/crowd",  2, StaggerShoveParams(),   1.0),
        ("stagger-on-post-contact/single", 1, StaggerShoveParams(),  0.12),
        ("stagger-on-post-contact/crowd",  2, StaggerShoveParams(),  0.12),
    ]

    private func fixturePath(for label: String) -> String {
        let slug = label.replacingOccurrences(of: "/", with: "_")
        return "\(getProjectRoot())/Tests/VRMMetalKitTests/Fixtures/PipelineBaseline/\(slug).txt"
    }

    /// Runs the full 3×2 matrix and asserts every cell is byte-identical to the
    /// committed pre-extraction baseline. This is the real C1 gate: it catches
    /// any drift the refactor introduced, because determinism against a fixed
    /// prior baseline is exactly what code motion must preserve.
    @MainActor func testMatrixMatchesCommittedBaseline() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }

        for (label, count, stagger, halfSep) in Self.cells {
            let path = fixturePath(for: label)
            guard FileManager.default.fileExists(atPath: path) else {
                XCTFail("missing committed baseline fixture for \(label) at \(path)")
                continue
            }
            let baseline = try PipelineBaselineFixture.read(fromFile: path)
            let current = try await runCell(device: device, avatarCount: count, stagger: stagger, halfSep: halfSep)
            assertSequencesIdentical(baseline, current, label)
        }
    }

    /// The post-contact cells must actually reach contact, else the matrix's
    /// third regime is vacuous and the gate silently tests nothing.
    @MainActor func testPostContactCellReachesContact() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let a = try await avatar(device, index: 0, count: 2)
        let b = try await avatar(device, index: 1, count: 2)
        let stepper = CrowdFrameStepper(avatars: [a, b], driver: holdDriver(halfSep: 0.12),
                                        group: nil, fps: 60, stagger: StaggerShoveParams())
        for f in 0..<60 { stepper.step(frameTime: Float(f) / 60.0) }
        let solver = try XCTUnwrap(stepper.staggerSolver(forAvatar: 0))
        XCTAssertNotEqual(solver.offset, .zero,
                          "half-separation 0.12 must drive the shove off zero, else the post-contact regime is untested")
    }

    /// Regenerates the committed baseline fixtures from the currently checked
    /// out sources. Opt-in and skipped by default: this must only ever be run
    /// against unmodified, pre-extraction sources (Phase A of the C1 task).
    /// Running it after the extraction would silently destroy the only
    /// evidence the gate produces by baking the post-refactor output back in
    /// as the "baseline" it is supposed to be checked against.
    @MainActor func testGenerateBaselineFixtures() async throws {
        guard ProcessInfo.processInfo.environment["PIPELINE_BASELINE_GENERATE"] == "1" else {
            throw XCTSkip("baseline generation is opt-in; set PIPELINE_BASELINE_GENERATE=1 to run it")
        }
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }

        let dir = "\(getProjectRoot())/Tests/VRMMetalKitTests/Fixtures/PipelineBaseline"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for (label, count, stagger, halfSep) in Self.cells {
            let sequences = try await runCell(device: device, avatarCount: count, stagger: stagger, halfSep: halfSep)
            try PipelineBaselineFixture.write(sequences, toFile: fixturePath(for: label))
        }
    }
}
