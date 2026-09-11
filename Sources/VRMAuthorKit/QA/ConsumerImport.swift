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

/// Re-parses exported bytes with `VRMReader` and `SpecValidator`. It is the
/// CLI default and deliberately does not carry the `vrmmetalkit` consumer id.
public struct SelfReimportConsumer: ConsumerImporter {
    public init() {}

    public var id: String { "self-reimport" }
    public var version: String { ToolInfo.current.version }

    public func importVRM(_ data: Data) throws -> ConsumerImportReport {
        let document = try VRMReader.read(data)
        let failures = SpecValidator.validate(document).filter { $0.status == .fail }
        if let first = failures.first {
            throw AuthorError(code: .validationFailed, path: first.id, message: failures.map(\.message).joined(separator: " "), suggestedCommands: ["qa run"])
        }
        return ConsumerImportReport(
            consumer: id, version: version,
            humanoidBones: document.vrm?["humanoid"]?["humanBones"]?.object?.count ?? 0,
            expressions: (document.vrm?["expressions"]?["preset"]?.object?.count ?? 0) + (document.vrm?["expressions"]?["custom"]?.object?.count ?? 0),
            springs: document.springBone?["springs"]?.array?.count ?? 0,
            colliders: document.springBone?["colliders"]?.array?.count ?? 0,
            colliderGroups: document.springBone?["colliderGroups"]?.array?.count ?? 0,
            meshes: document.meshes.count, materials: document.materials.count)
    }
}
