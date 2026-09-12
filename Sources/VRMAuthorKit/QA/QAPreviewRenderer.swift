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

public enum QAPreviewMode: String, CaseIterable, Sendable {
    case key, all, paths

    public var scenarioIds: [String] {
        switch self {
        case .key: return ["visual.front", "expression.happy"]
        case .all: return QAPins.renderScenarios().filter { $0.kind == "visual" || $0.kind == "expression" }.map(\.id)
        case .paths: return []
        }
    }
}

public struct QAPreview: Sendable {
    public var scenarioId: String
    public var path: String
    public var sha256: String
    public var width: Int
    public var height: Int
    public var pngBase64: String
}

/// A second rasterisation of locked QA scenarios at a small size, for an
/// agent to look at. Previews are views: their bytes and hashes never enter a
/// QA report, evidence file, inspection binding or acceptance pack.
public enum QAPreviewRenderer {
    public static let mimeType = "image/png"

    public static func render(mode: QAPreviewMode, size: Int, file: URL, data: Data, outputDirectory: URL, render: (any RenderAdapter)?, context: OperationContext) throws -> [QAPreview] {
        guard let render, mode != .paths else { return [] }
        let wanted = mode.scenarioIds
        var previews: [QAPreview] = []
        for scenario in QAPins.renderScenarios() where wanted.contains(scenario.id) {
            let sized = RenderScenario(id: scenario.id, kind: scenario.kind,
                                       configuration: scenario.configuration.merging(["width": .number(Double(size)), "height": .number(Double(size))]))
            let directory = outputDirectory.appendingPathComponent("preview").appendingPathComponent(scenario.id)
            guard let artifacts = try render.render(scenario: sized, file: file, data: data, outputDirectory: directory, context: context),
                  let png = artifacts.first(where: { $0.mediaType == mimeType }) else { continue }
            let bytes = try Data(contentsOf: URL(fileURLWithPath: png.path))
            previews.append(QAPreview(scenarioId: scenario.id, path: png.path, sha256: SHA256Hex.hex(bytes), width: size, height: size, pngBase64: bytes.base64EncodedString()))
        }
        return previews
    }

    public static func imageBlock(_ preview: QAPreview) -> JSONValue {
        ["type": "image", "data": .string(preview.pngBase64), "mimeType": .string(mimeType)]
    }

    public static func json(_ preview: QAPreview) -> JSONValue {
        ["scenarioId": .string(preview.scenarioId), "path": .string(preview.path), "sha256": .string(preview.sha256),
         "width": .number(Double(preview.width)), "height": .number(Double(preview.height)), "evidence": false]
    }
}
