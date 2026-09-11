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
@testable import VRMMetalKit

final class PerformanceTrackerTests: XCTestCase {

    /// Pins the contract that PerformanceTracker.generateMetrics() returns
    /// counters AVERAGED PER FRAME, not cumulative totals. Callers (e.g.
    /// VRMBenchmark) rely on this and would double-divide if it ever changed.
    func testCountersAreAveragedPerFrame() {
        let tracker = PerformanceTracker()
        let frames = 10
        let drawsPerFrame = 19
        let trianglesPerFrame = 31712
        let verticesPerFrame = 80169
        let texturesPerFrame = 19
        let pipelineChangesPerFrame = 0

        for _ in 0..<frames {
            tracker.beginFrame()
            for _ in 0..<drawsPerFrame {
                tracker.recordDrawCall(
                    triangles: trianglesPerFrame / drawsPerFrame,
                    vertices: verticesPerFrame / drawsPerFrame)
                tracker.recordStateChange(type: .texture)
            }
            for _ in 0..<pipelineChangesPerFrame {
                tracker.recordStateChange(type: .pipeline)
            }
            tracker.endFrame()
        }

        let metrics = tracker.generateMetrics()

        XCTAssertEqual(metrics.drawCalls, drawsPerFrame,
            "drawCalls should be per-frame average, not cumulative total")
        XCTAssertEqual(metrics.textureBindings, texturesPerFrame,
            "textureBindings should be per-frame average, not cumulative total")
        XCTAssertEqual(metrics.pipelineChanges, pipelineChangesPerFrame)

        // Triangle/vertex counts are summed per-draw then averaged per-frame,
        // so integer-truncated (drawsPerFrame * (totalPerFrame / drawsPerFrame)).
        let expectedTris = (trianglesPerFrame / drawsPerFrame) * drawsPerFrame
        let expectedVerts = (verticesPerFrame / drawsPerFrame) * drawsPerFrame
        XCTAssertEqual(metrics.triangleCount, expectedTris)
        XCTAssertEqual(metrics.vertexCount, expectedVerts)

        // Sanity: totals would be drawsPerFrame * frames if not averaged.
        XCTAssertNotEqual(metrics.drawCalls, drawsPerFrame * frames,
            "drawCalls is the cumulative total — semantics regressed")
    }

    /// Empty trackers should not crash and should report zeros.
    func testEmptyTrackerReportsZeros() {
        let tracker = PerformanceTracker()
        let metrics = tracker.generateMetrics()
        XCTAssertEqual(metrics.drawCalls, 0)
        XCTAssertEqual(metrics.triangleCount, 0)
        XCTAssertEqual(metrics.vertexCount, 0)
        XCTAssertEqual(metrics.fps, 0)
    }

    /// reset() should clear accumulated counters so the next generateMetrics()
    /// reports zeros, not stale averages.
    func testResetClearsAccumulators() {
        let tracker = PerformanceTracker()
        tracker.beginFrame()
        tracker.recordDrawCall(triangles: 100, vertices: 300)
        tracker.endFrame()
        tracker.reset()
        let metrics = tracker.generateMetrics()
        XCTAssertEqual(metrics.drawCalls, 0)
        XCTAssertEqual(metrics.triangleCount, 0)
    }

    /// Outside a frame, each begin/endPhase pair records one sample, retained
    /// so VRMBenchmark can build a full distribution (not just the average) per
    /// sub-phase. An empty phase yields an empty array, not a crash.
    func testPhaseSamplesAccumulatePerCall() {
        let tracker = PerformanceTracker()
        XCTAssertTrue(tracker.samples(for: .morphSetup).isEmpty,
            "a phase that never ran should report no samples")

        for _ in 0..<5 {
            tracker.beginPhase(.morphSetup)
            tracker.endPhase(.morphSetup)
        }
        XCTAssertEqual(tracker.samples(for: .morphSetup).count, 5,
            "one sample per begin/endPhase pair")
        XCTAssertTrue(tracker.samples(for: .springBone).isEmpty,
            "phases are tracked independently")
    }

    /// generateMetrics() drains the running averages but must NOT drain the
    /// sample windows — VRMBenchmark reads samples AFTER calling generateMetrics()
    /// and would otherwise lose the sub-phase distributions. reset() clears both.
    func testPhaseSamplesSurviveGenerateMetricsButNotReset() {
        let tracker = PerformanceTracker()
        for _ in 0..<3 {
            tracker.beginPhase(.commandEncode)
            tracker.endPhase(.commandEncode)
        }
        _ = tracker.generateMetrics()
        XCTAssertEqual(tracker.samples(for: .commandEncode).count, 3,
            "generateMetrics() must not drain phase sample windows")

        tracker.reset()
        XCTAssertTrue(tracker.samples(for: .commandEncode).isEmpty,
            "reset() should clear phase sample windows")
    }

    /// Every hotspot phase added for the allocation-review work must be
    /// independently sampleable AND mapped onto its own `PerformanceMetrics`
    /// field. A phase that records samples but never reaches a metric would be
    /// invisible to both the human report and the JSON gate.
    func testHotspotPhasesMapToMetricsFields() {
        let tracker = PerformanceTracker()

        // Each entry pairs a phase with the metric field it must populate.
        let mappings: [(phase: PerformanceTracker.Phase, metric: (PerformanceMetrics) -> Double)] = [
            (.morphActiveSet,      { $0.morphActiveSetMs }),
            (.springTargetCapture, { $0.springTargetCaptureMs }),
            (.springSubsteps,      { $0.springSubstepsMs }),
            (.springReadback,      { $0.springReadbackMs }),
            (.skinPalette,         { $0.skinPaletteMs }),
            (.transformUpdate,     { $0.transformUpdateMs }),
            (.depthPrepass,        { $0.depthPrepassMs }),
            (.outlinePass,         { $0.outlinePassMs }),
        ]

        for (phase, _) in mappings {
            tracker.beginPhase(phase)
            Thread.sleep(forTimeInterval: 0.001)
            tracker.endPhase(phase)
        }

        let metrics = tracker.generateMetrics()

        for (phase, metric) in mappings {
            XCTAssertEqual(tracker.samples(for: phase).count, 1,
                "\(phase) should record exactly one sample")
            XCTAssertGreaterThan(metric(metrics), 0,
                "\(phase) should map to a non-zero metric field")
        }

        // Phases that never ran stay at zero and readable.
        XCTAssertEqual(metrics.morphSetupMs, 0)
        XCTAssertEqual(metrics.springBoneMs, 0)
    }

    /// Phase.allCases must list every hotspot phase; VRMBenchmark derives its
    /// sub-phase report from it (minus `.total`), so a missing case would drop
    /// that phase from both the human report and the persisted `stats`.
    func testAllCasesCoversHotspotPhases() {
        let expected: Set<String> = [
            "morphSetup", "morphActiveSet", "springBone", "springTargetCapture",
            "springSubsteps", "springReadback", "skinPalette", "transformUpdate",
            "renderItemBuild", "depthPrepass", "outlinePass", "commandEncode", "total",
        ]
        let names = Set(PerformanceTracker.Phase.allCases.map { "\($0)" })
        XCTAssertEqual(names, expected)
    }

    /// The hotspot metric fields must survive `PerformanceMetrics`' custom
    /// Codable round-trip (encode coerces non-finite values, decode tolerates
    /// absent fields), so a field missing from either side is caught here.
    func testHotspotMetricsJSONRoundTrip() throws {
        var metrics = PerformanceMetrics()
        metrics.morphActiveSetMs = 0.11
        metrics.springTargetCaptureMs = 0.22
        metrics.springSubstepsMs = 0.33
        metrics.springReadbackMs = 0.44
        metrics.skinPaletteMs = 0.55
        metrics.transformUpdateMs = 0.66
        metrics.depthPrepassMs = 0.77
        metrics.outlinePassMs = 0.88

        let data = try JSONEncoder().encode(metrics)
        let decoded = try JSONDecoder().decode(PerformanceMetrics.self, from: data)

        XCTAssertEqual(decoded.morphActiveSetMs, 0.11, accuracy: 1e-9)
        XCTAssertEqual(decoded.springTargetCaptureMs, 0.22, accuracy: 1e-9)
        XCTAssertEqual(decoded.springSubstepsMs, 0.33, accuracy: 1e-9)
        XCTAssertEqual(decoded.springReadbackMs, 0.44, accuracy: 1e-9)
        XCTAssertEqual(decoded.skinPaletteMs, 0.55, accuracy: 1e-9)
        XCTAssertEqual(decoded.transformUpdateMs, 0.66, accuracy: 1e-9)
        XCTAssertEqual(decoded.depthPrepassMs, 0.77, accuracy: 1e-9)
        XCTAssertEqual(decoded.outlinePassMs, 0.88, accuracy: 1e-9)
    }

    /// A phase begun several times inside one frame (the renderer walks
    /// `.transformUpdate` twice when spring bone is on, and `.morphActiveSet`
    /// once per primitive) must collapse to ONE per-frame sample equal to the
    /// sum of its intervals, so the benchmark's percentiles compare frames.
    func testPhaseCallsWithinFrameCollapseToOneSample() {
        let tracker = PerformanceTracker()
        var clock: CFTimeInterval = 0
        tracker.now = { clock }

        tracker.beginFrame()
        tracker.beginPhase(.transformUpdate)
        clock += 0.002
        tracker.endPhase(.transformUpdate)
        clock += 0.001
        tracker.beginPhase(.transformUpdate)
        clock += 0.003
        tracker.endPhase(.transformUpdate)
        XCTAssertTrue(tracker.samples(for: .transformUpdate).isEmpty,
            "samples are emitted at endFrame, not per call")
        tracker.endFrame()

        let samples = tracker.samples(for: .transformUpdate)
        XCTAssertEqual(samples.count, 1, "one sample per frame per phase")
        XCTAssertEqual(samples.first ?? 0, 5.0, accuracy: 1e-9,
            "the frame sample is the sum of the phase's intervals")

        let metrics = tracker.generateMetrics()
        XCTAssertEqual(metrics.transformUpdateMs, 5.0, accuracy: 1e-9,
            "the per-frame average is the frame total, not the per-call mean")
    }

    /// Without an open frame there is nothing to accumulate into, so each
    /// begin/endPhase pair still flushes one sample immediately.
    func testPhaseOutsideFrameFlushesPerCall() {
        let tracker = PerformanceTracker()
        var clock: CFTimeInterval = 0
        tracker.now = { clock }

        for _ in 0..<2 {
            tracker.beginPhase(.morphActiveSet)
            clock += 0.001
            tracker.endPhase(.morphActiveSet)
        }
        let samples = tracker.samples(for: .morphActiveSet)
        XCTAssertEqual(samples.count, 2)
        for sample in samples {
            XCTAssertEqual(sample, 1.0, accuracy: 1e-9)
        }
    }

    /// A phase that ran in one frame but not the next contributes no sample
    /// for the idle frame — the pending frame total must not carry over.
    func testPhaseIdleInFrameEmitsNoSample() {
        let tracker = PerformanceTracker()
        var clock: CFTimeInterval = 0
        tracker.now = { clock }

        tracker.beginFrame()
        tracker.beginPhase(.springBone)
        clock += 0.004
        tracker.endPhase(.springBone)
        tracker.endFrame()

        tracker.beginFrame()
        clock += 0.016
        tracker.endFrame()

        let samples = tracker.samples(for: .springBone)
        XCTAssertEqual(samples.count, 1, "the idle frame must not emit a sample")
        XCTAssertEqual(samples.first ?? 0, 4.0, accuracy: 1e-9)
        XCTAssertEqual(tracker.samples(for: .total).count, 2,
            "the frame total is still recorded for both frames")
    }
}
