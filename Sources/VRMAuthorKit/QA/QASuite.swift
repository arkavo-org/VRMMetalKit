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

/// Pinned QA oracles and the locked v1 scenario packs.
public enum QAPins {
    /// The fallback style a QA plan grades against when the project has no
    /// attached style: `style attach` and template packs that bind their own
    /// profile both take precedence, so a second style needs no change here.
    public static let defaultProfilePath = "docs/style/profiles/vroid-lineage-anime.json"
    public static let defaultProfileSha256 = "7eeb1f41bada650d39b7c32a31c273bbd889cca22d390164b8a7dd9b1f9c1f35"
    public static let styleLinterSha256 = "01679f040546fa76b6c4b8f6c84244388201ad04f0f449157c5ec634716b5881"
    public static let consumerVRMMetalKit = "vrmmetalkit"
    public static let harnessSessionValue = "harness"
    public static let sessionEnvironmentKey = "VRM_AUTHOR_SESSION"

    public static let specStyleScenarios = ["spec.structure", "spec.humanoid", "spec.expressions", "spec.springs", "style.lint"]
    public static let authoringScenarios = specStyleScenarios + [
        "visual.front", "visual.threeQuarter", "visual.profile", "expression.blink", "expression.aa", "expression.happy", "motion.idle",
    ]

    public static func requiredScenarios(_ suite: QASuite) -> [String] {
        suite == .specStyle ? specStyleScenarios : authoringScenarios
    }

    public static func consumers(_ suite: QASuite) -> [String] {
        suite == .specStyle ? [] : [consumerVRMMetalKit]
    }

    /// Locked thresholds for both suites.
    public static let thresholds: JSONValue = [
        "scale": ["minHeightM": .number(GeometryChecks.minimumHeightMetres), "maxHeightM": .number(GeometryChecks.maximumHeightMetres)],
        "motion.idle": ["maxTipPenetrationM": 0.005, "maxJointVelocityMps": 4, "timestepS": 0.008333333333333333, "durationS": 4],
        "visual": ["minCoverageRatio": 0.05, "maxBackgroundRatio": 0.98],
        "expression": ["minVertexDisplacementM": 0.0005],
    ]

    public static let sharedRender: JSONValue = [
        "width": 1024, "height": 1024, "projection": "perspective", "fovDegrees": 30, "up": [0, 1, 0], "background": [0.5, 0.5, 0.5, 1],
        "exposureEV": 0, "light": ["type": "directional", "direction": [-0.3, -1, -0.5], "colour": [1, 1, 1], "intensity": 1], "pose": "rest",
    ]

    public static func renderScenarios() -> [RenderScenario] {
        func view(_ id: String, position: [Double], target: [Double], expression: [String: JSONValue] = [:]) -> RenderScenario {
            RenderScenario(id: id, kind: id.hasPrefix("visual") ? "visual" : "expression",
                           configuration: sharedRender.merging(["camera": ["position": JSONValue(position), "target": JSONValue(target)], "expressionWeights": .object(expression), "frameTimesS": [0]]))
        }
        return [
            view("visual.front", position: [0, 0.95, 3.4], target: [0, 0.9, 0]),
            view("visual.threeQuarter", position: [2.4, 0.95, 2.4], target: [0, 0.9, 0]),
            view("visual.profile", position: [3.4, 0.95, 0], target: [0, 0.9, 0]),
            view("expression.blink", position: [0, 1.45, 0.9], target: [0, 1.45, 0], expression: ["blink": 1]),
            view("expression.aa", position: [0, 1.45, 0.9], target: [0, 1.45, 0], expression: ["aa": 1]),
            view("expression.happy", position: [0, 1.45, 0.9], target: [0, 1.45, 0], expression: ["happy": 1]),
            RenderScenario(id: "motion.idle", kind: "motion", configuration: sharedRender.merging([
                "camera": ["position": [0, 0.95, 3.4], "target": [0, 0.9, 0]], "timestepS": 0.008333333333333333, "durationS": 4,
                "inputAnimationHashes": [], "colliderOverlay": true, "metrics": ["tipPenetration", "jointVelocity"],
            ])),
        ]
    }
}

/// A QA plan binding file, revision, oracles, scenarios, renderer and consumers.
public struct QAPlan: Codable, Hashable, Sendable {
    public var planVersion: Int
    public var suite: QASuite
    public var file: Blob
    public var projectId: String?
    public var revision: Int?
    public var buildHash: String?
    public var profile: Blob
    public var styleLinterSha256: String
    public var thresholdsHash: String
    public var thresholds: JSONValue
    public var requiredScenarios: [String]
    public var renderer: JSONValue
    public var renderScenarios: [RenderScenario]
    public var consumers: [String]
    public var generator: String
    public var planHash: String

    public static func make(suite: QASuite, file: Blob, projectId: String?, revision: Int?, buildHash: String?, profile: Blob, linterSha256: String, renderer: String) throws -> QAPlan {
        var plan = QAPlan(planVersion: 1, suite: suite, file: file, projectId: projectId, revision: revision, buildHash: buildHash, profile: profile,
                          styleLinterSha256: linterSha256, thresholdsHash: try CanonicalJSON.sha256(QAPins.thresholds), thresholds: QAPins.thresholds,
                          requiredScenarios: QAPins.requiredScenarios(suite),
                          renderer: ["identity": .string(renderer), "backend": .string(BuildSupport.backend), "shared": QAPins.sharedRender],
                          renderScenarios: suite == .authoringV1 ? QAPins.renderScenarios() : [], consumers: QAPins.consumers(suite),
                          generator: GLBWriter.generator, planHash: "")
        plan.planHash = try CanonicalJSON.sha256(try JSONValue.from(plan))
        return plan
    }

    public func canonicalData() throws -> Data { try CanonicalJSON.encode(self) }

    public static func load(_ url: URL) throws -> QAPlan {
        let plan = try JSONValue.parse(try Data(contentsOf: url)).decode(QAPlan.self)
        var unhashed = plan
        unhashed.planHash = ""
        guard try CanonicalJSON.sha256(try JSONValue.from(unhashed)) == plan.planHash else {
            throw AuthorError(code: .validationFailed, path: url.path, message: "QA plan planHash does not match its contents.", suggestedCommands: ["qa plan"])
        }
        return plan
    }
}

public struct QAScenarioResult: Codable, Hashable, Sendable {
    public var id: String
    public var required: Bool
    public var status: CheckStatus
    public var checks: [String]
}

public struct QARequiredArtifact: Codable, Hashable, Sendable {
    public var scenarioId: String
    public var path: String?
    public var sha256: String?
    public var mediaType: String?
}

/// findings.json written by `qa run` and `export verify`.
public struct QAReport: Codable, Hashable, Sendable {
    public var reportVersion: Int
    public var suite: QASuite
    public var operation: String
    public var file: Blob
    public var planHash: String
    public var projectId: String?
    public var revision: Int?
    public var buildHash: String?
    public var verdict: CheckStatus
    public var scenarios: [QAScenarioResult]
    public var checks: [QACheck]
    public var requiredArtifacts: [QARequiredArtifact]
    public var evidence: [ArtifactRef]
    public var consumers: [ConsumerImportReport]
    public var generator: String

    public static func load(_ url: URL) throws -> QAReport {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AuthorError(code: .missingInput, path: url.path, message: "QA report not found at \(url.path).", suggestedCommands: ["qa run"])
        }
        do { return try JSONValue.parse(try Data(contentsOf: url)).decode(QAReport.self) } catch let error as AuthorError { throw error } catch {
            throw AuthorError(code: .validationFailed, path: url.path, message: "QA report is not a findings.json: \(error)", suggestedCommands: ["qa run"])
        }
    }
}
