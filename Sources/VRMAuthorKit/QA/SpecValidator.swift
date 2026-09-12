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

public enum CheckStatus: String, Codable, Hashable, Sendable, CaseIterable {
    case pass, fail, incomplete, notApplicable
}

/// One QA check. `scenario` groups checks under a suite scenario id; `code`
/// carries the failure vocabulary. The result-envelope projection keeps only
/// id/status/message/reportHash.
public struct QACheck: Codable, Hashable, Sendable {
    public var scenario: String
    public var id: String
    public var status: CheckStatus
    public var message: String
    public var code: String?
    public var reportHash: String?

    public init(scenario: String, id: String, status: CheckStatus, message: String, code: String? = nil, reportHash: String? = nil) {
        self.scenario = scenario
        self.id = id
        self.status = status
        self.message = message
        self.code = code
        self.reportHash = reportHash
    }

    public var resultJSON: JSONValue {
        var o: [String: JSONValue] = ["id": .string(id), "status": .string(status.rawValue), "message": .string(message)]
        if let reportHash { o["reportHash"] = .string(reportHash) }
        return .object(o)
    }
}

/// Structural VRM 1.0 checks on a parsed GLB. Each check reports pass, fail or
/// incomplete; nothing here is a skip.
public enum SpecValidator {
    public static let scenarioStructure = "spec.structure"
    public static let scenarioHumanoid = "spec.humanoid"
    public static let scenarioExpressions = "spec.expressions"
    public static let scenarioSprings = "spec.springs"
    public static let scenarioMeta = "spec.meta"

    public static let mandatoryMetaFields = [
        "name", "version", "authors", "licenseUrl", "avatarPermission", "allowExcessivelyViolentUsage", "allowExcessivelySexualUsage",
        "commercialUsage", "allowPoliticalOrReligiousUsage", "allowAntisocialOrHateUsage", "creditNotation", "allowRedistribution", "modification",
    ]

    /// Parse failure yields a single failed structure check.
    public static func validate(data: Data) -> [QACheck] {
        do {
            return validate(try VRMReader.read(data))
        } catch let error as AuthorError {
            return [QACheck(scenario: scenarioStructure, id: "spec.structure.glb", status: .fail, message: error.message, code: error.code.rawValue)]
        } catch {
            return [QACheck(scenario: scenarioStructure, id: "spec.structure.glb", status: .fail, message: "\(error)", code: AuthorErrorCode.malformedGLB.rawValue)]
        }
    }

    public static func validate(_ document: VRMDocument) -> [QACheck] {
        var checks: [QACheck] = []
        checks.append(QACheck(scenario: scenarioStructure, id: "spec.structure.glb", status: .pass, message: "GLB header and chunk alignment are valid."))
        checks.append(assetCheck(document))
        checks.append(accessorCheck(document))
        checks.append(primitiveCheck(document))
        checks.append(extensionsCheck(document))
        checks.append(humanoidCheck(document))
        checks.append(expressionBindCheck(document))
        checks.append(blinkInertCheck(document))
        checks.append(springJointCheck(document))
        checks.append(colliderCheck(document))
        checks.append(metaCheck(document))
        checks.append(GeometryChecks.scale(document))
        return checks
    }

    static func check(_ scenario: String, _ id: String, _ problems: [String], ok: String, code: String = AuthorErrorCode.validationFailed.rawValue) -> QACheck {
        problems.isEmpty
            ? QACheck(scenario: scenario, id: id, status: .pass, message: ok)
            : QACheck(scenario: scenario, id: id, status: .fail, message: problems.joined(separator: " "), code: code)
    }

    static func assetCheck(_ d: VRMDocument) -> QACheck {
        var problems: [String] = []
        if d.json["asset"]?["version"]?.string != "2.0" { problems.append("asset.version must be \"2.0\".") }
        if (d.json["scenes"]?.array ?? []).isEmpty { problems.append("At least one scene is required.") }
        if d.nodes.isEmpty { problems.append("At least one node is required.") }
        return check(scenarioStructure, "spec.structure.asset", problems, ok: "glTF 2.0 asset with a scene and nodes.")
    }

    static func accessorCheck(_ d: VRMDocument) -> QACheck {
        var problems: [String] = []
        let buffers = d.json["buffers"]?.array ?? []
        let declared = buffers.first?["byteLength"]?.int ?? 0
        if buffers.count != 1 { problems.append("Exactly one buffer is expected, found \(buffers.count).") }
        if declared != d.bin.count { problems.append("buffers[0].byteLength \(declared) does not match the BIN chunk length \(d.bin.count).") }
        for (index, view) in d.bufferViews.enumerated() {
            let offset = view["byteOffset"]?.int ?? 0
            guard let length = view["byteLength"]?.int, view["buffer"]?.int == 0 else { problems.append("bufferViews[\(index)] is missing buffer/byteLength."); continue }
            if offset % 4 != 0 { problems.append("bufferViews[\(index)] byteOffset \(offset) is not 4-byte aligned.") }
            if offset + length > d.bin.count { problems.append("bufferViews[\(index)] overruns the BIN chunk.") }
        }
        for index in d.accessors.indices where d.accessorRange(index) == nil {
            problems.append("accessors[\(index)] is out of bounds of its bufferView or malformed.")
        }
        return check(scenarioStructure, "spec.structure.accessors", problems, ok: "\(d.accessors.count) accessors lie within their buffer views.")
    }

    static func primitiveCheck(_ d: VRMDocument) -> QACheck {
        var problems: [String] = []
        for (meshIndex, mesh) in d.meshes.enumerated() {
            let primitives = mesh["primitives"]?.array ?? []
            if primitives.isEmpty { problems.append("meshes[\(meshIndex)] has no primitives.") }
            let targetNames = mesh["extras"]?["targetNames"]?.array?.count
            for (primitiveIndex, primitive) in primitives.enumerated() {
                let label = "meshes[\(meshIndex)].primitives[\(primitiveIndex)]"
                guard let positionAccessor = primitive["attributes"]?["POSITION"]?.int, let position = d.accessorRange(positionAccessor) else {
                    problems.append("\(label) has no valid POSITION accessor."); continue
                }
                if position.type != .vec3 || position.componentType != .float { problems.append("\(label) POSITION must be float VEC3.") }
                if d.accessors[positionAccessor]["min"]?.array?.count != 3 || d.accessors[positionAccessor]["max"]?.array?.count != 3 {
                    problems.append("\(label) POSITION accessor needs min and max.")
                }
                for (name, value) in primitive["attributes"]?.object ?? [:] where name != "POSITION" {
                    guard let accessor = value.int, let range = d.accessorRange(accessor) else { problems.append("\(label) attribute \(name) is invalid."); continue }
                    if range.count != position.count { problems.append("\(label) attribute \(name) has \(range.count) elements, POSITION has \(position.count).") }
                    if name == "JOINTS_0", range.componentType != .unsignedShort && range.componentType != .unsignedByte { problems.append("\(label) JOINTS_0 must be unsigned byte/short.") }
                }
                if let indicesAccessor = primitive["indices"]?.int {
                    guard let indices = d.integers(accessor: indicesAccessor) else { problems.append("\(label) indices accessor is invalid."); continue }
                    if indices.count % 3 != 0 { problems.append("\(label) index count \(indices.count) is not a multiple of 3.") }
                    if let bad = indices.first(where: { Int($0) >= position.count }) { problems.append("\(label) index \(bad) exceeds vertex count \(position.count).") }
                } else {
                    problems.append("\(label) must be indexed.")
                }
                if let material = primitive["material"]?.int, material < 0 || material >= d.materials.count { problems.append("\(label) material \(material) is out of range.") }
                let targets = primitive["targets"]?.array ?? []
                if let targetNames, targets.count != targetNames { problems.append("\(label) has \(targets.count) morph targets but extras.targetNames lists \(targetNames).") }
                for (targetIndex, target) in targets.enumerated() {
                    guard let accessor = target["POSITION"]?.int, let range = d.accessorRange(accessor) else { problems.append("\(label).targets[\(targetIndex)] lacks POSITION."); continue }
                    if range.count != position.count { problems.append("\(label).targets[\(targetIndex)] has \(range.count) deltas for \(position.count) vertices.") }
                }
            }
        }
        for (skinIndex, skin) in (d.json["skins"]?.array ?? []).enumerated() {
            let joints = skin["joints"]?.array ?? []
            if joints.isEmpty { problems.append("skins[\(skinIndex)] has no joints.") }
            for joint in joints {
                if let j = joint.int, j < 0 || j >= d.nodes.count { problems.append("skins[\(skinIndex)] joint \(j) is out of range.") }
            }
            if let ibm = skin["inverseBindMatrices"]?.int {
                guard let range = d.accessorRange(ibm) else { problems.append("skins[\(skinIndex)] inverseBindMatrices accessor is invalid."); continue }
                if range.type != .mat4 || range.count != joints.count { problems.append("skins[\(skinIndex)] inverseBindMatrices must be MAT4 x \(joints.count).") }
            }
        }
        for (nodeIndex, node) in d.nodes.enumerated() {
            if let mesh = node["mesh"]?.int, mesh < 0 || mesh >= d.meshes.count { problems.append("nodes[\(nodeIndex)].mesh \(mesh) is out of range.") }
            if let skin = node["skin"]?.int, skin < 0 || skin >= (d.json["skins"]?.array?.count ?? 0) { problems.append("nodes[\(nodeIndex)].skin \(skin) is out of range.") }
            for child in node["children"]?.array ?? [] {
                if let c = child.int, c < 0 || c >= d.nodes.count || c == nodeIndex { problems.append("nodes[\(nodeIndex)] has an invalid child \(c).") }
            }
        }
        return check(scenarioStructure, "spec.structure.indices", problems, ok: "Primitive indices, attributes, skins and node references are in range.")
    }

    static func extensionsCheck(_ d: VRMDocument) -> QACheck {
        var problems: [String] = []
        let used = Set(d.extensionsUsed)
        if !used.contains(GLBWriter.vrmExtension) { problems.append("extensionsUsed must list VRMC_vrm.") }
        if d.vrm == nil { problems.append("extensions.VRMC_vrm is missing.") }
        if d.vrm?["specVersion"]?.string != "1.0" { problems.append("VRMC_vrm.specVersion must be \"1.0\".") }
        if d.springBone != nil, !used.contains(GLBWriter.springBoneExtension) { problems.append("VRMC_springBone is present but not listed in extensionsUsed.") }
        if used.contains(GLBWriter.springBoneExtension), d.springBone == nil { problems.append("extensionsUsed lists VRMC_springBone but the extension is absent.") }
        var materialExtensions = Set<String>()
        func collect(_ value: JSONValue) {
            switch value {
            case .object(let o):
                if let exts = o["extensions"]?.object { materialExtensions.formUnion(exts.keys) }
                for v in o.values { collect(v) }
            case .array(let a): for v in a { collect(v) }
            default: break
            }
        }
        for material in d.materials { collect(material) }
        for ext in materialExtensions.sorted() where !used.contains(ext) { problems.append("Material extension \(ext) is used but not listed in extensionsUsed.") }
        if !d.materials.isEmpty, !materialExtensions.contains(GLBWriter.mtoonExtension) { problems.append("No material carries VRMC_materials_mtoon.") }
        for required in d.json["extensionsRequired"]?.array?.compactMap({ $0.string }) ?? [] where !used.contains(required) {
            problems.append("extensionsRequired lists \(required) which is not in extensionsUsed.")
        }
        return check(scenarioStructure, "spec.structure.extensionsUsed", problems, ok: "extensionsUsed lists every extension in use: \(d.extensionsUsed.sorted().joined(separator: ", ")).")
    }

    static func humanoidCheck(_ d: VRMDocument) -> QACheck {
        var problems: [String] = []
        let bones = d.vrm?["humanoid"]?["humanBones"]?.object ?? [:]
        var usedNodes: [Int: String] = [:]
        for (name, ref) in bones {
            guard VRMHumanBone(rawValue: name) != nil else { problems.append("Unknown humanoid bone '\(name)'."); continue }
            guard let node = ref["node"]?.int, node >= 0, node < d.nodes.count else { problems.append("Humanoid bone \(name) has an invalid node."); continue }
            if let other = usedNodes[node] { problems.append("Humanoid bones \(other) and \(name) share node \(node).") }
            usedNodes[node] = name
        }
        for bone in VRMHumanBone.required where bones[bone.rawValue] == nil { problems.append("Required humanoid bone \(bone.rawValue) is missing.") }
        return check(scenarioHumanoid, "spec.humanoid.required", problems, ok: "All \(VRMHumanBone.required.count) required humanoid bones map to distinct nodes (\(bones.count) mapped).")
    }

    static func morphTargetCount(_ d: VRMDocument, node: Int) -> Int? {
        guard node >= 0, node < d.nodes.count, let mesh = d.nodes[node]["mesh"]?.int, mesh >= 0, mesh < d.meshes.count else { return nil }
        return d.meshes[mesh]["primitives"]?.array?.first?["targets"]?.array?.count ?? 0
    }

    static func allExpressions(_ d: VRMDocument) -> [(String, JSONValue)] {
        let expressions = d.vrm?["expressions"]
        var out: [(String, JSONValue)] = []
        for (name, e) in (expressions?["preset"]?.object ?? [:]).sorted(by: { $0.key < $1.key }) { out.append(("preset/\(name)", e)) }
        for (name, e) in (expressions?["custom"]?.object ?? [:]).sorted(by: { $0.key < $1.key }) { out.append(("custom/\(name)", e)) }
        return out
    }

    static func expressionBindCheck(_ d: VRMDocument) -> QACheck {
        var problems: [String] = []
        var bindCount = 0
        for (name, expression) in allExpressions(d) {
            if name.hasPrefix("preset/"), ExpressionPreset(rawValue: String(name.dropFirst(7))) == nil { problems.append("Unknown preset expression \(name).") }
            for (index, bind) in (expression["morphTargetBinds"]?.array ?? []).enumerated() {
                bindCount += 1
                guard let node = bind["node"]?.int, let targets = morphTargetCount(d, node: node) else { problems.append("\(name).morphTargetBinds[\(index)] references a node without a mesh."); continue }
                guard let target = bind["index"]?.int, target >= 0, target < targets else { problems.append("\(name).morphTargetBinds[\(index)] references morph target \(bind["index"]?.int ?? -1) of \(targets)."); continue }
                if let weight = bind["weight"]?.number, weight < 0 || weight > 1 { problems.append("\(name).morphTargetBinds[\(index)] weight out of [0,1].") }
            }
            for (index, bind) in (expression["materialColorBinds"]?.array ?? []).enumerated() {
                bindCount += 1
                if let material = bind["material"]?.int, material < 0 || material >= d.materials.count { problems.append("\(name).materialColorBinds[\(index)] material out of range.") }
                if let type = bind["type"]?.string, MaterialColorType(rawValue: type) == nil { problems.append("\(name).materialColorBinds[\(index)] has unknown type \(type).") }
            }
            for (index, bind) in (expression["textureTransformBinds"]?.array ?? []).enumerated() {
                bindCount += 1
                if let material = bind["material"]?.int, material < 0 || material >= d.materials.count { problems.append("\(name).textureTransformBinds[\(index)] material out of range.") }
            }
        }
        return check(scenarioExpressions, "spec.expressions.binds", problems, ok: "\(bindCount) expression binds reference existing nodes, morph targets and materials.")
    }

    /// A blink preset whose bound morph targets move no vertex is inert.
    static func blinkInertCheck(_ d: VRMDocument) -> QACheck {
        guard let blink = d.vrm?["expressions"]?["preset"]?["blink"] else {
            return QACheck(scenario: scenarioExpressions, id: "expression.blinkInert", status: .notApplicable, message: "No blink preset is defined.")
        }
        let binds = blink["morphTargetBinds"]?.array ?? []
        guard !binds.isEmpty else {
            return QACheck(scenario: scenarioExpressions, id: "expression.blinkInert", status: .fail, message: "blink has no morph target binds.", code: "EXPRESSION_INERT")
        }
        var moved = false
        for bind in binds {
            guard let node = bind["node"]?.int, let target = bind["index"]?.int, node >= 0, node < d.nodes.count,
                  let mesh = d.nodes[node]["mesh"]?.int, mesh >= 0, mesh < d.meshes.count else { continue }
            for primitive in d.meshes[mesh]["primitives"]?.array ?? [] {
                guard let accessor = primitive["targets"]?[target]?["POSITION"]?.int, let deltas = d.floats(accessor: accessor) else { continue }
                if deltas.contains(where: { $0 != 0 }) { moved = true }
            }
        }
        return moved
            ? QACheck(scenario: scenarioExpressions, id: "expression.blinkInert", status: .pass, message: "blink morph targets move vertices.")
            : QACheck(scenario: scenarioExpressions, id: "expression.blinkInert", status: .fail, message: "blink morph target deltas are all zero; eyelids cannot close.", code: "EXPRESSION_INERT")
    }

    static func springJointCheck(_ d: VRMDocument) -> QACheck {
        guard let sb = d.springBone else {
            return QACheck(scenario: scenarioSprings, id: "spec.springs.joints", status: .notApplicable, message: "No VRMC_springBone extension.")
        }
        var problems: [String] = []
        if sb["specVersion"]?.string != "1.0" { problems.append("VRMC_springBone.specVersion must be \"1.0\".") }
        let groupCount = sb["colliderGroups"]?.array?.count ?? 0
        let springs = sb["springs"]?.array ?? []
        for (index, spring) in springs.enumerated() {
            let joints = spring["joints"]?.array ?? []
            if joints.count < 2 { problems.append("springs[\(index)] needs a root joint and a terminal tail.") }
            var seen = Set<Int>()
            for (jointIndex, joint) in joints.enumerated() {
                guard let node = joint["node"]?.int, node >= 0, node < d.nodes.count else { problems.append("springs[\(index)].joints[\(jointIndex)] references a missing node."); continue }
                if !seen.insert(node).inserted { problems.append("springs[\(index)] repeats node \(node).") }
                for key in ["hitRadius", "stiffness", "gravityPower"] {
                    if let v = joint[key]?.number, v < 0 { problems.append("springs[\(index)].joints[\(jointIndex)].\(key) is negative.") }
                }
                if let drag = joint["dragForce"]?.number, drag < 0 || drag > 1 { problems.append("springs[\(index)].joints[\(jointIndex)].dragForce out of [0,1].") }
                if let dir = joint["gravityDir"]?.array, dir.count != 3 { problems.append("springs[\(index)].joints[\(jointIndex)].gravityDir needs 3 components.") }
            }
            if let center = spring["center"]?.int, center < 0 || center >= d.nodes.count { problems.append("springs[\(index)].center is out of range.") }
            for group in spring["colliderGroups"]?.array ?? [] {
                if let g = group.int, g < 0 || g >= groupCount { problems.append("springs[\(index)] references collider group \(g) of \(groupCount).") }
            }
        }
        return check(scenarioSprings, "spec.springs.joints", problems, ok: "\(springs.count) springs reference existing nodes and collider groups.")
    }

    static func colliderCheck(_ d: VRMDocument) -> QACheck {
        guard let sb = d.springBone else {
            return QACheck(scenario: scenarioSprings, id: "spec.springs.colliders", status: .notApplicable, message: "No VRMC_springBone extension.")
        }
        var problems: [String] = []
        let colliders = sb["colliders"]?.array ?? []
        func vector(_ v: JSONValue?, _ n: Int) -> Bool { v?.array?.count == n && (v?.array ?? []).allSatisfy { ($0.number ?? .nan).isFinite } }
        for (index, collider) in colliders.enumerated() {
            guard let node = collider["node"]?.int, node >= 0, node < d.nodes.count else { problems.append("colliders[\(index)] references a missing node."); continue }
            let shape = collider["shape"]?.object ?? [:]
            let sphere = shape["sphere"], capsule = shape["capsule"]
            guard (sphere == nil) != (capsule == nil) else { problems.append("colliders[\(index)] must have exactly one of sphere or capsule."); continue }
            let body = sphere ?? capsule!
            guard let radius = body["radius"]?.number, radius.isFinite, radius >= 0 else { problems.append("colliders[\(index)] radius must be a nonnegative finite metre value."); continue }
            if !vector(body["offset"], 3) { problems.append("colliders[\(index)] offset needs 3 finite components.") }
            if capsule != nil, !vector(body["tail"], 3) { problems.append("colliders[\(index)] capsule tail needs 3 finite components.") }
        }
        for (index, group) in (sb["colliderGroups"]?.array ?? []).enumerated() {
            for member in group["colliders"]?.array ?? [] {
                if let c = member.int, c < 0 || c >= colliders.count { problems.append("colliderGroups[\(index)] references collider \(c) of \(colliders.count).") }
            }
        }
        return check(scenarioSprings, "spec.springs.colliders", problems, ok: "\(colliders.count) colliders have valid shapes and nodes.")
    }

    static func metaCheck(_ d: VRMDocument) -> QACheck {
        var problems: [String] = []
        let meta = d.vrm?["meta"]?.object ?? [:]
        for field in mandatoryMetaFields {
            guard let value = meta[field] else { problems.append("meta.\(field) is missing."); continue }
            if let s = value.string, s.isEmpty { problems.append("meta.\(field) is empty.") }
            if field == "authors", (value.array ?? []).isEmpty { problems.append("meta.authors is empty.") }
        }
        if let a = meta["avatarPermission"]?.string, AvatarPermission(rawValue: a) == nil { problems.append("meta.avatarPermission has an unknown value.") }
        if let c = meta["commercialUsage"]?.string, CommercialUsage(rawValue: c) == nil { problems.append("meta.commercialUsage has an unknown value.") }
        if let c = meta["creditNotation"]?.string, CreditNotation(rawValue: c) == nil { problems.append("meta.creditNotation has an unknown value.") }
        if let m = meta["modification"]?.string, ModificationPermission(rawValue: m) == nil { problems.append("meta.modification has an unknown value.") }
        if let thumbnail = meta["thumbnailImage"]?.int, thumbnail < 0 || thumbnail >= (d.json["images"]?.array?.count ?? 0) { problems.append("meta.thumbnailImage is out of range.") }
        return check(scenarioMeta, "spec.meta.required", problems, ok: "All mandatory VRMC_vrm meta fields are present.")
    }
}
