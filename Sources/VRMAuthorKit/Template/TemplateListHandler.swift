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

/// `template list`: installed packs and their installable items, with hashes
/// and control schemas, optionally filtered by category.
public enum TemplateListHandler {
    public static let names = ["template list"]

    public static let install: RegistryInstaller = { registry in
        registry.mustInstall(list, for: "template list")
    }

    /// Wearable presets every avatar pack can instantiate; listed as items of
    /// their host pack so agents discover them through the same call.
    static let wearablePresets: [(id: String, category: TemplateCategory, controls: [ControlDescriptor])] = [
        (HairBobV1.presetId, .hair, hairControls),
        (HairLongV1.presetId, .hair, hairControls),
        ("top-v1", .outfit, outfitControls(length: true)),
        ("bottom-v1", .outfit, outfitControls(length: true)),
        ("skirt-v1", .outfit, outfitControls(length: true)),
        ("footwear-v1", .outfit, outfitControls(length: false)),
        ("glasses-v1", .accessory, []),
        ("earring-v1", .accessory, []),
        ("cat-ears-v1", .accessory, []),
    ]

    static let hairControls: [ControlDescriptor] = [
        ControlDescriptor(key: "lengthM", unit: .metres, validRange: [0.12, 0.30], recommendedRange: [0.14, 0.26], defaultValue: 0.18, side: .none, mirrorKey: nil, affects: [.hair, .spring], dependencies: ["hair.springs"], description: "Calibrated guide extension and regenerated bone positions"),
        ControlDescriptor(key: "widthScale", unit: .ratio, validRange: [0.75, 1.25], recommendedRange: [0.9, 1.25], defaultValue: 1, side: .none, mirrorKey: nil, affects: [.hair], dependencies: [], description: "Clump width deformation"),
        ControlDescriptor(key: "tipBendDeg", unit: .degrees, validRange: [-20, 30], recommendedRange: [0, 20], defaultValue: 12, side: .none, mirrorKey: nil, affects: [.hair], dependencies: [], description: "Template tip bend"),
        ControlDescriptor(key: "bangClearanceM", unit: .metres, validRange: [0.002, 0.02], recommendedRange: [0.004, 0.01], defaultValue: 0.005, side: .none, mirrorKey: nil, affects: [.hair], dependencies: [], description: "Forehead/eye clearance within the calibrated guide basis"),
    ]

    static func outfitControls(length: Bool) -> [ControlDescriptor] {
        var controls = [ControlDescriptor(key: "fit", unit: .normalized, validRange: [-1, 1], recommendedRange: [-0.5, 0.5], defaultValue: 0, side: .none, mirrorKey: nil, affects: [.garment], dependencies: ["body.shape"], description: "Garment clearance offset within the fitted basis")]
        if length {
            controls.insert(ControlDescriptor(key: "length", unit: .normalized, validRange: [-1, 1], recommendedRange: [-0.5, 0.5], defaultValue: 0, side: .none, mirrorKey: nil, affects: [.garment], dependencies: [], description: "Covered extent along the limb axis"), at: 0)
        }
        return controls
    }

    static func list(_ context: OperationContext, _ request: JSONValue) throws -> ResultEnvelope {
        let requestId = request["requestId"]?.string
        let category = try request["category"]?.string.map { raw -> TemplateCategory in
            guard let c = TemplateCategory(rawValue: raw) else { throw AuthorError.invalidRequest("Unknown category '\(raw)'.", path: "/category") }
            return c
        }
        var packs: [JSONValue] = []
        var items: [JSONValue] = []
        for id in context.templates.ids {
            guard let pack = context.templates.pack(id: id) else { continue }
            if category == nil || category == pack.category {
                packs.append([
                    "id": .string(pack.id), "category": .string(pack.category.rawValue), "sha256": .string(pack.sha256),
                    "controls": try JSONValue.from(pack.controls), "controlSchema": .array(pack.controls.map(\.schema.json)),
                    "defaultsSha256": .string(try CanonicalJSON.sha256(try JSONValue.from(pack.defaults))),
                ])
            }
            let packItems = pack.items.map { (id: $0.id, category: $0.category, sha256: $0.sha256, controls: $0.controls) }
                + wearablePresets.map { (id: $0.id, category: $0.category, sha256: "", controls: $0.controls) }
            for item in packItems where category == nil || category == item.category {
                let controlsJSON = try JSONValue.from(item.controls)
                let sha = item.sha256.isEmpty ? try CanonicalJSON.sha256(["id": .string(item.id), "pack": .string(pack.id), "controls": controlsJSON]) : item.sha256
                items.append(["id": .string(item.id), "pack": .string(pack.id), "category": .string(item.category.rawValue), "sha256": .string(sha), "controls": controlsJSON])
            }
        }
        return .succeeded(requestId: requestId, result: ["packs": .array(packs), "items": .array(items)])
    }
}
