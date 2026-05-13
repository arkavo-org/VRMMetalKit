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

import Foundation

// MARK: - Report

/// Machine-readable snapshot of a single `VRMBenchmark` run.
///
/// Written by `VRMBenchmark --json` and consumed by `VRMBenchmark --baseline`
/// for regression gating. Decodes from JSON with a schema version field so a
/// future incompatible change can be detected at load time.
public struct BenchmarkReport: Codable, Equatable, Sendable {
    /// Schema version emitted by the current code path. Bump when fields are
    /// renamed, removed, or have semantics that older consumers cannot infer.
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let timestamp: Date
    public let label: String
    public let input: Input
    public let config: Config
    public let system: System
    /// Per-phase frame-time statistics keyed by phase name
    /// (`render`, `animation`, `encode`, `wait`, `load`, `transforms`).
    public let stats: [String: FrameStatsSnapshot]

    public struct Input: Codable, Equatable, Sendable {
        public let vrm: String?
        public let vrma: String?
        public let frames: Int
        public let warmup: Int

        public init(vrm: String?, vrma: String?, frames: Int, warmup: Int) {
            self.vrm = vrm
            self.vrma = vrma
            self.frames = frames
            self.warmup = warmup
        }
    }

    public struct Config: Codable, Equatable, Sendable {
        public let mode: String
        public let width: Int
        public let height: Int
        public let sampleCount: Int
        public let loading: String
        public let springBoneQuality: String?
        public let lighting: String?

        public init(mode: String, width: Int, height: Int, sampleCount: Int,
                    loading: String, springBoneQuality: String?, lighting: String?) {
            self.mode = mode
            self.width = width
            self.height = height
            self.sampleCount = sampleCount
            self.loading = loading
            self.springBoneQuality = springBoneQuality
            self.lighting = lighting
        }
    }

    public struct System: Codable, Equatable, Sendable {
        public let os: String
        public let host: String

        public init(os: String, host: String) {
            self.os = os
            self.host = host
        }
    }

    public struct FrameStatsSnapshot: Codable, Equatable, Sendable {
        public let count: Int
        public let minMs: Double
        public let medianMs: Double
        public let meanMs: Double
        public let p95Ms: Double
        public let p99Ms: Double
        public let maxMs: Double
        public let stddevMs: Double

        public init(count: Int, minMs: Double, medianMs: Double, meanMs: Double,
                    p95Ms: Double, p99Ms: Double, maxMs: Double, stddevMs: Double) {
            self.count = count
            self.minMs = minMs
            self.medianMs = medianMs
            self.meanMs = meanMs
            self.p95Ms = p95Ms
            self.p99Ms = p99Ms
            self.maxMs = maxMs
            self.stddevMs = stddevMs
        }
    }

    public init(timestamp: Date, label: String, input: Input, config: Config,
                system: System, stats: [String: FrameStatsSnapshot]) {
        self.schemaVersion = Self.currentSchemaVersion
        self.timestamp = timestamp
        self.label = label
        self.input = input
        self.config = config
        self.system = system
        self.stats = stats
    }

    /// Encodes the report as pretty JSON with sorted keys and ISO-8601 timestamps.
    public func encodeJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    /// Decodes a report from JSON bytes. Throws ``BenchmarkReportError`` on
    /// schema-version mismatch so callers can surface a clear message.
    public static func decode(from data: Data) throws -> BenchmarkReport {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let report = try decoder.decode(BenchmarkReport.self, from: data)
        guard report.schemaVersion == currentSchemaVersion else {
            throw BenchmarkReportError.unsupportedSchema(
                got: report.schemaVersion, supported: currentSchemaVersion)
        }
        return report
    }
}

public enum BenchmarkReportError: Error, LocalizedError {
    case unsupportedSchema(got: Int, supported: Int)

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let got, let supported):
            return "Unsupported benchmark report schema version \(got); this build understands v\(supported). Regenerate the baseline."
        }
    }
}

// MARK: - Comparator

/// Result of comparing two reports for regression-gate purposes.
public struct BenchmarkComparison: Equatable, Sendable {
    /// Regression thresholds expressed as percentages above baseline.
    public struct Threshold: Equatable, Sendable {
        /// Allowed median regression in percent (e.g. `10.0` = baseline + 10 %).
        public let medianPercent: Double
        /// Allowed p95 regression in percent (e.g. `15.0`).
        public let p95Percent: Double

        public init(medianPercent: Double, p95Percent: Double) {
            self.medianPercent = medianPercent
            self.p95Percent = p95Percent
        }

        public static let `default` = Threshold(medianPercent: 10.0, p95Percent: 15.0)
    }

    /// Per-metric comparison row.
    public struct StatDelta: Equatable, Sendable {
        public let metricName: String        // e.g. "render.median"
        public let baselineMs: Double
        public let currentMs: Double
        public let deltaPercent: Double      // signed; positive = slower than baseline
        public let limitPercent: Double      // gate threshold for this metric
        public let passed: Bool
    }

    public let deltas: [StatDelta]

    public var passed: Bool { deltas.allSatisfy(\.passed) }

    /// Compares the median and p95 of every phase present in BOTH reports.
    /// Phases in only one report are skipped (and recorded in ``skippedPhases``).
    public static func compare(
        baseline: BenchmarkReport,
        current: BenchmarkReport,
        threshold: Threshold = .default
    ) -> BenchmarkComparison {
        var deltas: [StatDelta] = []
        let commonPhases = Set(baseline.stats.keys).intersection(current.stats.keys).sorted()
        for phase in commonPhases {
            guard let base = baseline.stats[phase], let cur = current.stats[phase] else { continue }
            deltas.append(makeDelta(metric: "\(phase).median",
                                    base: base.medianMs, current: cur.medianMs,
                                    limit: threshold.medianPercent))
            deltas.append(makeDelta(metric: "\(phase).p95",
                                    base: base.p95Ms, current: cur.p95Ms,
                                    limit: threshold.p95Percent))
        }
        return BenchmarkComparison(deltas: deltas)
    }

    private static func makeDelta(metric: String, base: Double, current: Double, limit: Double) -> StatDelta {
        let delta = base > 0 ? ((current - base) / base) * 100.0 : 0.0
        return StatDelta(metricName: metric, baselineMs: base, currentMs: current,
                         deltaPercent: delta, limitPercent: limit, passed: delta <= limit)
    }

    /// Renders the comparison as a fixed-width table for human consumption.
    /// Each row is `metric  baseline  current  delta  gate`.
    public func renderTable() -> String {
        func pad(_ s: String, to width: Int, align: PadAlign = .left) -> String {
            if s.count >= width { return s }
            let padding = String(repeating: " ", count: width - s.count)
            switch align {
            case .left:  return s + padding
            case .right: return padding + s
            }
        }
        var lines: [String] = []
        lines.append(
            pad("metric", to: 22) + " " +
            pad("baseline", to: 12, align: .right) + " " +
            pad("current", to: 12, align: .right) + " " +
            pad("delta", to: 9, align: .right) + " " +
            "gate")
        lines.append(String(repeating: "-", count: 72))
        for d in deltas {
            let status = d.passed ? "ok" : "FAIL"
            let baselineStr = String(format: "%.3f ms", d.baselineMs)
            let currentStr  = String(format: "%.3f ms", d.currentMs)
            let deltaStr    = String(format: "%+.1f%%", d.deltaPercent)
            let gateStr     = "\(status) (<=+\(String(format: "%.1f", d.limitPercent))%)"
            lines.append(
                pad(d.metricName, to: 22) + " " +
                pad(baselineStr, to: 12, align: .right) + " " +
                pad(currentStr,  to: 12, align: .right) + " " +
                pad(deltaStr,    to: 9,  align: .right) + " " +
                gateStr)
        }
        return lines.joined(separator: "\n")
    }

    private enum PadAlign { case left, right }
}
