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
import Metal
import VRMAuthorKit
import VRMMetalKit

/// `--check-import`: the authoring-v1 `vrmmetalkit` consumer. Loads the file
/// with VRMMetalKit's loader and reports what it read.
enum ConsumerImportCheck {
    static let consumerId = ScenarioRenderer.rendererId

    static func report(fileURL: URL) async throws -> JSONValue {
        let data = try Data(contentsOf: fileURL)
        let model: VRMModel
        do {
            model = try await VRMModel.load(from: data, filePath: fileURL.path, device: nil)
        } catch {
            guard let device = MTLCreateSystemDefaultDevice() else { throw error }
            model = try await VRMModel.load(from: data, filePath: fileURL.path, device: device)
        }
        return report(model, filePath: fileURL.path)
    }

    static func report(_ model: VRMModel, filePath: String) -> JSONValue {
        var warnings: [String] = []
        var requiredBonesPresent = false
        if let humanoid = model.humanoid {
            do { try humanoid.validate(filePath: filePath); requiredBonesPresent = true } catch { warnings.append("\(error)") }
        } else {
            warnings.append("VRMMetalKit read no humanoid from \(filePath).")
        }
        let presetNames = (model.expressions?.preset.keys.map(\.rawValue) ?? []).sorted()
        let customNames = (model.expressions?.custom.keys.map { $0 } ?? []).sorted()
        return [
            "consumer": .string(consumerId),
            "version": .string(VRMMetalKit.version),
            "humanoidBones": .number(Double(model.humanoid?.humanBones.count ?? 0)),
            "requiredBonesPresent": .bool(requiredBonesPresent),
            "expressions": .number(Double(presetNames.count + customNames.count)),
            "expressionNames": JSONValue(presetNames + customNames),
            "springs": .number(Double(model.springBone?.springs.count ?? 0)),
            "colliders": .number(Double(model.springBone?.colliders.count ?? 0)),
            "colliderGroups": .number(Double(model.springBone?.colliderGroups.count ?? 0)),
            "meshes": .number(Double(model.meshes.count)),
            "materials": .number(Double(model.materials.count)),
            "images": .number(Double(model.gltf.images?.count ?? 0)),
            "metaName": model.meta.name.map { .string($0) } ?? .null,
            "warnings": JSONValue(warnings),
        ]
    }
}
