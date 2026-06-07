//
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
//

import XCTest
@testable import VRMMetalKit

/// Coverage for the `BenchmarkReport` JSON envelope and the `BenchmarkComparison`
/// gate logic. These types back the `VRMBenchmark --json` / `--baseline` flow
/// added for issue #156 (Benchmark CI regression gate).
final class BenchmarkReportTests: XCTestCase {

    // MARK: - Fixtures

    private func makeStats(median: Double, p95: Double) -> BenchmarkReport.FrameStatsSnapshot {
        BenchmarkReport.FrameStatsSnapshot(
            count: 500,
            minMs: median * 0.5,
            medianMs: median,
            meanMs: median * 1.05,
            p95Ms: p95,
            p99Ms: p95 * 1.5,
            maxMs: p95 * 2.0,
            stddevMs: median * 0.2)
    }

    private func makeReport(label: String, render: (Double, Double), encode: (Double, Double))
        -> BenchmarkReport
    {
        BenchmarkReport(
            timestamp: Date(timeIntervalSince1970: 1_715_558_400), // deterministic
            label: label,
            input: .init(vrm: "/tmp/a.vrm", vrma: nil, frames: 500, warmup: 30),
            config: .init(mode: "render", width: 1024, height: 1024, sampleCount: 1,
                          loading: "default", springBoneQuality: "ultra", lighting: "standard"),
            system: .init(os: "macOS", host: "ci-host"),
            stats: [
                "render": makeStats(median: render.0, p95: render.1),
                "encode": makeStats(median: encode.0, p95: encode.1),
            ])
    }

    // MARK: - JSON round-trip

    func testJSONRoundTripPreservesValues() throws {
        let report = makeReport(label: "test", render: (1.50, 3.10), encode: (1.10, 2.60))
        let data = try report.encodeJSON()
        let decoded = try BenchmarkReport.decode(from: data)
        XCTAssertEqual(decoded, report)
    }

    func testJSONIsPrettyAndKeysSorted() throws {
        let report = makeReport(label: "fmt", render: (1.0, 2.0), encode: (0.5, 1.0))
        let data = try report.encodeJSON()
        let str = String(data: data, encoding: .utf8) ?? ""
        // Pretty-printed → contains newlines and indentation.
        XCTAssertTrue(str.contains("\n  "), "JSON should be pretty-printed")
        // Sorted keys → "config" appears before "input" appears before "stats".
        let configIdx = str.range(of: "\"config\"")?.lowerBound
        let inputIdx  = str.range(of: "\"input\"")?.lowerBound
        let statsIdx  = str.range(of: "\"stats\"")?.lowerBound
        XCTAssertNotNil(configIdx); XCTAssertNotNil(inputIdx); XCTAssertNotNil(statsIdx)
        XCTAssertLessThan(configIdx!, inputIdx!)
        XCTAssertLessThan(inputIdx!,  statsIdx!)
    }

    func testDecodeRejectsUnsupportedSchemaVersion() throws {
        let report = makeReport(label: "v9", render: (1.0, 2.0), encode: (0.5, 1.0))
        var data = try report.encodeJSON()
        let str = String(data: data, encoding: .utf8)!
        let bumped = str.replacingOccurrences(
            of: "\"schemaVersion\" : 1",
            with: "\"schemaVersion\" : 999")
        data = bumped.data(using: .utf8)!
        XCTAssertThrowsError(try BenchmarkReport.decode(from: data)) { error in
            guard case BenchmarkReportError.unsupportedSchema(let got, let supported) = error else {
                return XCTFail("expected unsupportedSchema, got \(error)")
            }
            XCTAssertEqual(got, 999)
            XCTAssertEqual(supported, BenchmarkReport.currentSchemaVersion)
        }
    }

    // MARK: - Comparator: pass cases

    func testComparisonPassesWhenWithinThreshold() {
        // Baseline: render median 1.5 / p95 3.0. Current: 1.6 (+6.7 %) / 3.2 (+6.7 %).
        // Thresholds (default): median 10 %, p95 15 %. Both pass.
        let base    = makeReport(label: "base",    render: (1.5, 3.0), encode: (1.0, 2.0))
        let current = makeReport(label: "current", render: (1.6, 3.2), encode: (1.0, 2.0))

        let comparison = BenchmarkComparison.compare(baseline: base, current: current)
        XCTAssertTrue(comparison.passed)
        XCTAssertEqual(comparison.deltas.count, 4) // 2 phases × {median, p95}
        for delta in comparison.deltas {
            XCTAssertTrue(delta.passed, "\(delta.metricName) should pass")
        }
    }

    func testImprovementHasNegativeDeltaAndPasses() {
        // Faster current run → negative delta.
        let base    = makeReport(label: "base",    render: (2.0, 4.0), encode: (1.0, 2.0))
        let current = makeReport(label: "current", render: (1.5, 3.0), encode: (0.8, 1.6))

        let comparison = BenchmarkComparison.compare(baseline: base, current: current)
        XCTAssertTrue(comparison.passed)
        let renderMedian = comparison.deltas.first { $0.metricName == "render.median" }
        XCTAssertNotNil(renderMedian)
        XCTAssertEqual(renderMedian!.deltaPercent, -25.0, accuracy: 1e-6)
    }

    // MARK: - Comparator: fail cases

    func testMedianRegressionPastThresholdFails() {
        // Baseline median 1.5, current 1.8 → +20 %; default threshold 10 % → FAIL.
        let base    = makeReport(label: "base",    render: (1.5, 3.0), encode: (1.0, 2.0))
        let current = makeReport(label: "current", render: (1.8, 3.0), encode: (1.0, 2.0))

        let comparison = BenchmarkComparison.compare(baseline: base, current: current)
        XCTAssertFalse(comparison.passed)
        let renderMedian = comparison.deltas.first { $0.metricName == "render.median" }
        XCTAssertNotNil(renderMedian)
        XCTAssertFalse(renderMedian!.passed)
        XCTAssertEqual(renderMedian!.deltaPercent, 20.0, accuracy: 1e-6)
    }

    func testP95RegressionPastThresholdFails() {
        let base    = makeReport(label: "base",    render: (1.5, 3.0), encode: (1.0, 2.0))
        let current = makeReport(label: "current", render: (1.5, 3.6), encode: (1.0, 2.0)) // +20 % p95
        let comparison = BenchmarkComparison.compare(baseline: base, current: current)
        XCTAssertFalse(comparison.passed)
        let renderP95 = comparison.deltas.first { $0.metricName == "render.p95" }
        XCTAssertNotNil(renderP95)
        XCTAssertFalse(renderP95!.passed)
    }

    func testCustomThresholdIsRespected() {
        // With a relaxed 25 % median threshold, the same +20 % regression passes.
        let base    = makeReport(label: "base",    render: (1.5, 3.0), encode: (1.0, 2.0))
        let current = makeReport(label: "current", render: (1.8, 3.0), encode: (1.0, 2.0))
        let lenient = BenchmarkComparison.Threshold(medianPercent: 25.0, p95Percent: 25.0)
        let comparison = BenchmarkComparison.compare(baseline: base, current: current, threshold: lenient)
        XCTAssertTrue(comparison.passed)
    }

    // MARK: - Comparator: edge cases

    func testPhasesOnlyInOneReportAreSkipped() {
        let base = makeReport(label: "base", render: (1.5, 3.0), encode: (1.0, 2.0))
        let currentExtra = BenchmarkReport(
            timestamp: Date(),
            label: "current",
            input: .init(vrm: nil, vrma: nil, frames: 100, warmup: 10),
            config: .init(mode: "render", width: 1024, height: 1024, sampleCount: 1,
                          loading: "default", springBoneQuality: nil, lighting: nil),
            system: .init(os: "macOS", host: "x"),
            stats: ["render": makeStats(median: 1.5, p95: 3.0)]) // no "encode"
        let comparison = BenchmarkComparison.compare(baseline: base, current: currentExtra)
        // Only the shared "render" phase compared → 2 deltas, not 4.
        XCTAssertEqual(comparison.deltas.count, 2)
        XCTAssertTrue(comparison.passed)
    }

    // MARK: - Comparator: phase-restricted gating (issue #156 CI gate)

    func testGatedPhasesRestrictsComparisonToNamedPhases() {
        // encode regresses +50 % (noisy sub-phase), render is flat.
        // Gating only "render" must PASS despite the encode blow-up.
        let base    = makeReport(label: "base",    render: (1.5, 3.0), encode: (1.0, 2.0))
        let current = makeReport(label: "current", render: (1.5, 3.0), encode: (1.5, 3.0))

        // Sanity: gating everything (default) FAILS because encode regressed.
        XCTAssertFalse(BenchmarkComparison.compare(baseline: base, current: current).passed)

        // Restricting to render only → just render.{median,p95} are gated.
        let renderOnly = BenchmarkComparison.compare(
            baseline: base, current: current, gatedPhases: ["render"])
        XCTAssertTrue(renderOnly.passed)
        XCTAssertEqual(renderOnly.deltas.count, 2)
        XCTAssertTrue(renderOnly.deltas.allSatisfy { $0.metricName.hasPrefix("render.") })
    }

    func testGatedPhasesNilGatesAllCommonPhases() {
        let base    = makeReport(label: "base",    render: (1.5, 3.0), encode: (1.0, 2.0))
        let current = makeReport(label: "current", render: (1.5, 3.0), encode: (1.0, 2.0))
        // nil (default) keeps the existing behavior: every common phase gated.
        let all = BenchmarkComparison.compare(baseline: base, current: current, gatedPhases: nil)
        XCTAssertEqual(all.deltas.count, 4)
    }

    func testGatedPhasesUnknownNameProducesNoDeltas() {
        let base    = makeReport(label: "base",    render: (1.5, 3.0), encode: (1.0, 2.0))
        let current = makeReport(label: "current", render: (9.9, 9.9), encode: (9.9, 9.9))
        // A phase name absent from both reports → no metrics gated. The pure
        // comparator yields empty deltas (and `passed` is vacuously true); the
        // CLI (`finalizeReport`) treats empty deltas as a gate ERROR so a
        // typo'd --gate-phase can't silently pass every regression.
        let none = BenchmarkComparison.compare(
            baseline: base, current: current, gatedPhases: ["does-not-exist"])
        XCTAssertTrue(none.deltas.isEmpty,
                      "unknown phase must gate nothing — caller is responsible for treating this as an error")
    }

    func testZeroBaselineDoesNotDivideByZero() {
        // A baseline median of 0 ms (degenerate) should not crash the comparator.
        let base = BenchmarkReport(
            timestamp: Date(),
            label: "base",
            input: .init(vrm: nil, vrma: nil, frames: 100, warmup: 10),
            config: .init(mode: "render", width: 1024, height: 1024, sampleCount: 1,
                          loading: "default", springBoneQuality: nil, lighting: nil),
            system: .init(os: "macOS", host: "x"),
            stats: ["render": makeStats(median: 0.0, p95: 0.0)])
        let current = makeReport(label: "current", render: (0.0, 0.0), encode: (1.0, 2.0))
        let comparison = BenchmarkComparison.compare(baseline: base, current: current)
        XCTAssertTrue(comparison.passed) // 0 delta when baseline is 0
        for delta in comparison.deltas {
            XCTAssertEqual(delta.deltaPercent, 0.0)
        }
    }

    func testRenderTableContainsExpectedColumns() {
        let base    = makeReport(label: "base",    render: (1.5, 3.0), encode: (1.0, 2.0))
        let current = makeReport(label: "current", render: (1.8, 3.0), encode: (1.0, 2.0))
        let table = BenchmarkComparison.compare(baseline: base, current: current).renderTable()
        XCTAssertTrue(table.contains("metric"))
        XCTAssertTrue(table.contains("baseline"))
        XCTAssertTrue(table.contains("current"))
        XCTAssertTrue(table.contains("delta"))
        XCTAssertTrue(table.contains("render.median"))
        XCTAssertTrue(table.contains("FAIL"))
    }
}
