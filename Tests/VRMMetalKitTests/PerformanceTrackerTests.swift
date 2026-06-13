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

    /// Each begin/endPhase pair records one per-call sample, retained so
    /// VRMBenchmark can build a full distribution (not just the average) per
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
}
