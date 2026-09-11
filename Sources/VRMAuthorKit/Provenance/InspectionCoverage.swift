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

public struct InspectionCoverageReport: Codable, Hashable, Sendable {
    public var artifactHash: String
    public var records: [String]
    public var passCount: Int
    public var failCount: Int
    public var uncertainCount: Int
    public var unreadable: [String]

    public var isCovered: Bool { passCount >= 1 && failCount == 0 && uncertainCount == 0 }

    public var json: JSONValue {
        ["artifactHash": .string(artifactHash), "records": JSONValue(records), "pass": .number(Double(passCount)), "fail": .number(Double(failCount)),
         "uncertain": .number(Double(uncertainCount)), "unreadable": JSONValue(unreadable), "covered": .bool(isCovered)]
    }
}

/// Answers whether inspection records cover the exact artifact bytes.
public protocol InspectionCoverage: Sendable {
    func coverage(for artifactHash: String, in store: ProjectStore) throws -> InspectionCoverageReport
}

/// Reads `reports/inspections/<artifactHash>/*.json` (each an `Inspection`)
/// and counts verdicts bound to that hash; records naming another hash are
/// ignored, unreadable files are listed.
public struct DefaultInspectionCoverage: InspectionCoverage {
    public init() {}

    public static func directory(for artifactHash: String, in store: ProjectStore) -> URL {
        store.reportsDirectory.appendingPathComponent("inspections").appendingPathComponent(artifactHash)
    }

    public func coverage(for artifactHash: String, in store: ProjectStore) throws -> InspectionCoverageReport {
        let dir = DefaultInspectionCoverage.directory(for: artifactHash, in: store)
        var report = InspectionCoverageReport(artifactHash: artifactHash, records: [], passCount: 0, failCount: 0, uncertainCount: 0, unreadable: [])
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".json") && !$0.contains(ProjectStore.tempInfix) }.sorted()
        for name in names {
            let url = dir.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url), let json = try? JSONValue.parse(data), let inspection = try? json.decode(Inspection.self) else {
                report.unreadable.append(name)
                continue
            }
            guard inspection.artifactHash == artifactHash else { continue }
            report.records.append(name)
            switch inspection.verdict {
            case .pass: report.passCount += 1
            case .fail: report.failCount += 1
            case .uncertain: report.uncertainCount += 1
            }
        }
        return report
    }
}
