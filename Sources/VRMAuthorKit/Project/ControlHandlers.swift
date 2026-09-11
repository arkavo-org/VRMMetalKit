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

/// Which control descriptors apply to an object and where their values live.
/// Avatar controls come from the template pack; item controls come from the
/// pack's installed items, falling back to the contract-fixed hair/outfit
/// descriptors from parameters.md.
public enum ControlCatalog {
    public static let hairDescriptors: [ControlDescriptor] = [
        ControlDescriptor(key: "lengthM", unit: .metres, validRange: [0.12, 0.30], recommendedRange: [0.14, 0.26], defaultValue: 0.18, affects: [.hair, .spring],
                          description: "Calibrated guide extension and regenerated bone positions"),
        ControlDescriptor(key: "widthScale", unit: .ratio, validRange: [0.75, 1.25], recommendedRange: [0.85, 1.15], defaultValue: 1, affects: [.hair],
                          description: "Clump width deformation"),
        ControlDescriptor(key: "tipBendDeg", unit: .degrees, validRange: [-20, 30], recommendedRange: [0, 20], defaultValue: 12, affects: [.hair],
                          description: "Template tip bend"),
        ControlDescriptor(key: "bangClearanceM", unit: .metres, validRange: [0.002, 0.02], recommendedRange: [0.003, 0.01], defaultValue: 0.005, affects: [.hair],
                          dependencies: ["face.head.depth", "face.brow.left.height", "face.brow.right.height"], description: "Forehead/eye clearance within the calibrated guide basis"),
    ]

    public static let outfitDescriptors: [ControlDescriptor] = [
        ControlDescriptor(key: "length", unit: .normalized, validRange: [-1, 1], recommendedRange: [-0.6, 0.6], defaultValue: 0, affects: [.garment],
                          dependencies: ["body.heightM", "body.proportion.torsoLength", "body.proportion.legLength"], description: "Garment length blend"),
        ControlDescriptor(key: "fit", unit: .normalized, validRange: [-1, 1], recommendedRange: [-0.6, 0.6], defaultValue: 0, affects: [.garment],
                          dependencies: ["body.shape.chest", "body.shape.waist", "body.shape.hip", "body.proportion.shoulderWidth"], description: "Garment fit blend over precomputed body correspondences"),
    ]

    public static func descriptors(for object: ProjectObject, pack: any TemplatePack) -> [ControlDescriptor] {
        switch object.kind {
        case .avatar: return pack.controls
        case .hair, .garment:
            let preset = object.fields["preset"]?.string
            if let item = pack.items.first(where: { $0.id == preset && !$0.controls.isEmpty }) { return item.controls }
            return object.kind == .hair ? hairDescriptors : outfitDescriptors
        default: return []
        }
    }

    public static func pointer(for key: String, kind: ObjectKind) throws -> JSONPointer {
        switch kind {
        case .avatar:
            let section = key.hasPrefix("body.") ? "body" : key.hasPrefix("face.") ? "face" : nil
            guard let section else { throw AuthorError(code: .unknownField, path: "/values/\(JSONPointer.escape(key))", observed: .string(key), message: "Avatar control keys start with 'body.' or 'face.'.", suggestedCommands: ["control list"]) }
            return JSONPointer(tokens: [section, key])
        case .hair, .garment: return JSONPointer(tokens: ["controls", key])
        default: throw AuthorError(code: .unknownField, observed: .string(key), message: "\(kind.rawValue) objects have no numeric controls; use object set.", suggestedCommands: ["object get"])
        }
    }

    public static func currentValue(of key: String, in object: ProjectObject) -> Double? {
        guard let pointer = try? pointer(for: key, kind: object.kind) else { return nil }
        return pointer.get(in: .object(object.fields))?.number
    }

    /// Validity check: unknown key → UNKNOWN_FIELD (exit 2); non-number →
    /// INVALID_REQUEST; outside the validity range → VALIDATION_FAILED, never clamped.
    @discardableResult
    public static func check(key: String, value: JSONValue, descriptors: [ControlDescriptor], objectId: String, path: String) throws -> ControlDescriptor {
        guard let descriptor = descriptors.first(where: { $0.key == key }) else {
            throw AuthorError(code: .unknownField, objectId: objectId, path: path, observed: .string(key), required: JSONValue(descriptors.map(\.key)),
                              message: "Unknown control key '\(key)' for '\(objectId)'.", suggestedCommands: ["control list --object \(objectId)"])
        }
        guard let number = value.number, number.isFinite else {
            throw AuthorError(code: .invalidRequest, objectId: objectId, path: path, observed: value, required: "number",
                              message: "Control '\(key)' takes a finite number in \(descriptor.unit.rawValue).", suggestedCommands: ["control describe --key \(key) --object \(objectId)"])
        }
        guard descriptor.accepts(number) else {
            throw AuthorError(code: .validationFailed, objectId: objectId, path: path, observed: .number(number), required: JSONValue(descriptor.validRange),
                              message: "Control '\(key)' = \(number) is outside the validity range [\(descriptor.validRange[0]), \(descriptor.validRange[1])] \(descriptor.unit.rawValue); values are rejected, never clamped.",
                              suggestedCommands: ["control describe --key \(key) --object \(objectId)"])
        }
        return descriptor
    }

    public static func outsideRecommended(_ descriptor: ControlDescriptor, _ value: Double) -> Bool {
        descriptor.recommendedRange.count == 2 && (value < descriptor.recommendedRange[0] || value > descriptor.recommendedRange[1])
    }

    public static func describe(_ descriptor: ControlDescriptor, object: ProjectObject?, template: TemplateRef?) throws -> JSONValue {
        var endpoints: [String: JSONValue] = [
            "min": .number(descriptor.validRange.first ?? 0), "max": .number(descriptor.validRange.last ?? 0), "default": .number(descriptor.defaultValue),
            "recommendedMin": .number(descriptor.recommendedRange.first ?? descriptor.validRange.first ?? 0),
            "recommendedMax": .number(descriptor.recommendedRange.last ?? descriptor.validRange.last ?? 0),
        ]
        if let object, let current = currentValue(of: descriptor.key, in: object) { endpoints["current"] = .number(current) }
        var provenance: [String: JSONValue] = ["source": "template"]
        if let template { provenance["templateId"] = .string(template.id); provenance["templateSha256"] = .string(template.sha256) }
        if let preset = object?.fields["preset"]?.string { provenance["preset"] = .string(preset) }
        return ["descriptor": try JSONValue.from(descriptor), "endpoints": .object(endpoints), "provenance": .object(provenance)]
    }
}

/// Handlers for control list/describe/set.
public enum ControlHandlers {
    public static let names = ["control list", "control describe", "control set"]

    static func install(_ registry: inout Registry) {
        registry.mustInstall(controlList, for: "control list")
        registry.mustInstall(controlDescribe, for: "control describe")
        registry.mustInstall(controlSet, for: "control set")
    }

    static func object(_ id: String, in state: ProjectState) throws -> ProjectObject {
        guard let object = state.object(id: id) else {
            throw AuthorError(code: .objectNotFound, objectId: id, message: "No object with id '\(id)'.", suggestedCommands: ["object list"])
        }
        return object
    }

    static func controlList(_ context: OperationContext, _ request: JSONValue) throws -> ResultEnvelope {
        try ProjectAccess.read(context, request) { _, state in
            let pack = try ProjectAccess.pack(context, template: state.template)
            let descriptors: [ControlDescriptor]
            if let id = request["object"]?.string {
                descriptors = ControlCatalog.descriptors(for: try object(id, in: state), pack: pack)
            } else {
                descriptors = pack.controls
            }
            return ["controls": .array(try descriptors.map { try JSONValue.from($0) })]
        }
    }

    static func controlDescribe(_ context: OperationContext, _ request: JSONValue) throws -> ResultEnvelope {
        try ProjectAccess.read(context, request) { _, state in
            guard let key = request["key"]?.string, let id = request["object"]?.string else { throw AuthorError.invalidRequest("key and object are required.", path: "/key") }
            let pack = try ProjectAccess.pack(context, template: state.template)
            let target = try object(id, in: state)
            let descriptors = ControlCatalog.descriptors(for: target, pack: pack)
            guard let descriptor = descriptors.first(where: { $0.key == key }) else {
                throw AuthorError(code: .unknownField, objectId: id, path: "/key", observed: .string(key), required: JSONValue(descriptors.map(\.key)),
                                  message: "Unknown control key '\(key)' for '\(id)'.", suggestedCommands: ["control list --object \(id)"])
            }
            return try ControlCatalog.describe(descriptor, object: target, template: state.template)
        }
    }

    static func controlSet(_ context: OperationContext, _ request: JSONValue) throws -> ResultEnvelope {
        ProjectAccess.mutation(context, request, operation: "control set") { _, tx in
            guard let editJSON = request["edit"] else { throw AuthorError.invalidRequest("edit is required.", path: "/edit") }
            let edit = try ControlEdit.decode(editJSON)
            let pack = try ProjectAccess.pack(context, template: tx.state.template)
            let target = try tx.object(id: edit.object)
            let descriptors = ControlCatalog.descriptors(for: target, pack: pack)
            guard !descriptors.isEmpty else {
                throw AuthorError(code: .unknownField, objectId: edit.object, message: "\(target.kind.rawValue) '\(edit.object)' exposes no controls; use object set.", suggestedCommands: ["object get --id \(edit.object)"])
            }
            var affected: Set<ObjectKind> = []
            var changed = false
            for (key, value) in edit.values.sorted(by: { $0.key < $1.key }) {
                let path = "/values/\(JSONPointer.escape(key))"
                let descriptor = try ControlCatalog.check(key: key, value: value, descriptors: descriptors, objectId: edit.object, path: path)
                let number = value.number ?? 0
                if ControlCatalog.outsideRecommended(descriptor, number) {
                    tx.warnings.append(AuthorWarning(code: "OUTSIDE_RECOMMENDED_RANGE", message: "'\(key)' = \(number) is outside the recommended range [\(descriptor.recommendedRange[0]), \(descriptor.recommendedRange[1])].", path: path))
                }
                let pointer = try ControlCatalog.pointer(for: key, kind: target.kind)
                if ControlCatalog.currentValue(of: key, in: try tx.object(id: edit.object)) != number {
                    try tx.set(objectId: edit.object, pointer: pointer, value: .number(number))
                    changed = true
                    affected.formUnion(descriptor.affects)
                }
            }
            let after = try tx.object(id: edit.object)
            try ObjectValidation.validate(after, state: tx.state, context: context)
            if changed {
                for node in DependencyNode.invalidations(objectId: edit.object, kind: after.kind) { tx.invalidate(node) }
                for id in tx.state.objectIds {
                    guard id != edit.object, let other = tx.state.object(id: id), affected.contains(other.kind) else { continue }
                    for node in DependencyNode.invalidations(objectId: id, kind: other.kind) { tx.invalidate(node) }
                }
                tx.invalidate(DependencyNode.qa)
            } else {
                tx.warnings.append(AuthorWarning(code: "NO_OP", message: "Every control already had the requested value; nothing changed.", path: "/values"))
            }
            try ProjectObjects.syncRecipe(&tx)
            return ["invalidations": JSONValue(tx.invalidations)]
        }
    }
}
