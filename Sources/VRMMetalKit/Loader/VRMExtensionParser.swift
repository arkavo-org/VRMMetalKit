//
// Copyright 2025 Arkavo
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
import simd

/// VRM node constraint definition for roll, aim, and rotation constraints.
///
/// Used to distribute rotation from a source bone to a target bone (e.g., twist bones).
/// VRM 1.0 stores these in VRMC_node_constraint extension.
/// VRM 0.0 requires synthesizing constraints from humanoid bone definitions.
public struct VRMNodeConstraint: Sendable {
    /// The type of constraint to apply
    public enum ConstraintType: Sendable {
        /// Roll constraint: transfers rotation around a specific axis from source to target
        /// - Parameters:
        ///   - sourceNode: Index of the source node to read rotation from
        ///   - axis: The axis to transfer rotation around (in local space)
        ///   - weight: How much of the rotation to transfer (0.0 to 1.0, typically 0.5)
        case roll(sourceNode: Int, axis: SIMD3<Float>, weight: Float)

        /// Aim constraint: orients target to point at source
        case aim(sourceNode: Int, aimAxis: SIMD3<Float>, weight: Float)

        /// Rotation constraint: copies full rotation from source to target
        case rotation(sourceNode: Int, weight: Float)
    }

    /// The node index that this constraint affects
    public let targetNode: Int

    /// The type and parameters of the constraint
    public let constraint: ConstraintType

    /// Creates a constraint affecting `targetNode` with the given configured `constraint` type.
    public init(targetNode: Int, constraint: ConstraintType) {
        self.targetNode = targetNode
        self.constraint = constraint
    }
}

/// Parses the `VRMC_vrm` (1.0) and `VRM` (0.x) glTF extensions into a ``VRMModel``.
///
/// ## Discussion
/// This is the point in the pipeline that picks a VRM spec version and
/// fans out parsing across the VRM subsystems — humanoid, meta,
/// expressions, first-person, look-at, MToon, spring bones, and node
/// constraints. The picked spec drives downstream coordinate-system
/// handling and material conversion.
///
/// ### Version disambiguation
/// `parseVRMExtension(...)` inspects the extension dictionary's `specVersion`
/// (VRM 1.0) and `version` (VRM 0.x) keys:
///
/// - If `specVersion` exists and parses to a known ``VRMSpecVersion``, that
///   wins.
/// - If `specVersion` exists but is unknown, parsing proceeds as VRM 0.0
///   best-effort with a warning logged.
/// - If only `version` exists, its raw value is parsed through
///   ``VRMSpecVersion``; unrecognised strings fall back to VRM 0.0.
/// - If neither is present, the model is treated as VRM 0.0.
///
/// Beyond version detection, the parser is tolerant of missing optional
/// blocks (`firstPerson`, `lookAt`, `expressions`, `secondaryAnimation`,
/// `materialProperties`) and throws only when the *required* `meta` or
/// `humanoid` block is missing or malformed.
///
/// See <doc:MigratingFromVRM0> for an overview of the 0.x → 1.0 differences
/// this type bridges.
public class VRMExtensionParser {

    /// Creates an empty parser. Reuse across multiple models is safe; the parser holds no per-load state.
    public init() {}

    /// Parses a VRM extension payload (`VRMC_vrm` or legacy `VRM`) into a populated ``VRMModel``.
    ///
    /// The returned model has `humanoid`, `meta`, and any optional blocks
    /// present in the source filled in. Geometry, materials, textures, and
    /// GPU resources are populated later by the rest of the load pipeline.
    ///
    /// - Parameters:
    ///   - extension: The raw extension value pulled from
    ///     ``GLTFDocument/extensions`` under the `VRMC_vrm` or `VRM` key.
    ///     Must decode to a `[String: Any]` dictionary.
    ///   - document: The parsed ``GLTFDocument``, used to resolve node and mesh references.
    ///   - filePath: Optional source path used to enrich error messages.
    /// - Returns: A ``VRMModel`` with spec version, meta, humanoid, and all parseable VRM subsystems populated.
    /// - Throws:
    ///   - ``VRMError/missingVRMExtension(filePath:suggestion:)`` if the extension is not a dictionary.
    ///   - ``GLTFError/invalidJSON(context:underlyingError:filePath:)`` if `meta` or `humanoid` is missing or malformed.
    public func parseVRMExtension(_ extension: Any, document: GLTFDocument, filePath: String? = nil) throws -> VRMModel {
        guard let vrmDict = `extension` as? [String: Any] else {
            throw VRMError.missingVRMExtension(
                filePath: filePath,
                suggestion: "The VRM extension is not a valid dictionary object. Ensure your model was exported with proper VRM extension data."
            )
        }

        // Parse spec version (VRM 1.0 uses "specVersion", VRM 0.0 uses "version")
        let versionKey = vrmDict["specVersion"] != nil ? "specVersion" : "version"
        let versionStr = vrmDict[versionKey] as? String

        // For VRM 0.0, we'll assume version "0.0" if it has the old structure
        let specVersion: VRMSpecVersion
        if let versionStr = versionStr {
            specVersion = VRMSpecVersion(rawValue: versionStr) ?? .v0_0
            // Warn on unrecognized VRMC_vrm specVersion for forward-compatibility awareness.
            // The VRM 0.0 "version" field is a different concept; only warn for VRMC_vrm specVersion.
            if vrmDict["specVersion"] != nil, specVersion == .v0_0, versionStr != "0.0" {
                vrmLog("[VRMExtensionParser] WARNING: Unrecognized VRMC_vrm specVersion '\(versionStr)'. Expected '1.0'. Proceeding with best-effort parsing.")
            }
        } else {
            // If no version field but has VRM 0.0 structure, assume 0.0
            specVersion = .v0_0
        }

        // Parse meta (required)
        guard let metaDict = vrmDict["meta"] as? [String: Any] else {
            vrmLog("[VRMExtensionParser] Missing or invalid meta dictionary")
            throw GLTFError.invalidJSON(
                context: "VRM extension 'meta' field",
                underlyingError: "Missing or not a dictionary. VRM models require metadata including name, version, author, etc.",
                filePath: filePath
            )
        }
        vrmLog("[VRMExtensionParser] Found meta with keys: \(metaDict.keys)")
        let meta = try parseMeta(metaDict, specVersion: specVersion)

        // Parse humanoid (required)
        guard let humanoidDict = vrmDict["humanoid"] as? [String: Any] else {
            vrmLog("[VRMExtensionParser] Missing or invalid humanoid dictionary")
            throw GLTFError.invalidJSON(
                context: "VRM extension 'humanoid' field",
                underlyingError: "Missing or not a dictionary. VRM models require humanoid bone mappings.",
                filePath: filePath
            )
        }
        vrmLog("[VRMExtensionParser] Found humanoid with keys: \(humanoidDict.keys)")
        let humanoid = try parseHumanoid(humanoidDict)

        // Create model
        let model = VRMModel(
            specVersion: specVersion,
            meta: meta,
            humanoid: humanoid,
            gltf: document
        )

        // Parse optional components
        if let firstPersonDict = vrmDict["firstPerson"] as? [String: Any] {
            model.firstPerson = try parseFirstPerson(firstPersonDict)
        }

        // VRM 1.0 has separate lookAt, VRM 0.0 has lookAt data in firstPerson
        if let lookAtDict = vrmDict["lookAt"] as? [String: Any] {
            model.lookAt = try parseLookAt(lookAtDict)
        } else if let firstPersonDict = vrmDict["firstPerson"] as? [String: Any] {
            // VRM 0.0 embeds lookAt data in firstPerson
            model.lookAt = try parseLookAtFromFirstPerson(firstPersonDict)
        }

        // VRM 1.0 uses "expressions", VRM 0.0 uses "blendShapeMaster"
        if let expressionsDict = vrmDict["expressions"] as? [String: Any] {
            model.expressions = try parseExpressions(expressionsDict)
        } else if let blendShapeMaster = vrmDict["blendShapeMaster"] as? [String: Any] {
            // Parse VRM 0.0 blendShapeMaster
            model.expressions = try parseBlendShapeMaster(blendShapeMaster)
        }

        // Parse SpringBone extension if present
        // VRM 1.0 uses VRMC_springBone extension
        if let springBoneExt = document.extensions?["VRMC_springBone"] as? [String: Any] {
            model.springBone = try parseSpringBone(springBoneExt)
        }
        // VRM 0.0 uses secondaryAnimation in the main VRM extension
        else if let secondaryAnimation = vrmDict["secondaryAnimation"] as? [String: Any] {
            model.springBone = parseSecondaryAnimation(secondaryAnimation)
        }

        // Parse VRM 0.x materialProperties (MToon data at document level)
        if let materialProperties = vrmDict["materialProperties"] as? [[String: Any]] {
            vrmLog("[VRMExtensionParser] Found \(materialProperties.count) VRM 0.x material properties")
            model.vrm0MaterialProperties = parseMaterialProperties(materialProperties)
        }

        // Parse or synthesize node constraints (for twist bones)
        let isVRM0 = specVersion == .v0_0
        model.nodeConstraints = parseOrSynthesizeConstraints(gltf: document, humanoid: humanoid, isVRM0: isVRM0)
        if !model.nodeConstraints.isEmpty {
            vrmLog("[VRMExtensionParser] Loaded \(model.nodeConstraints.count) node constraints")
        }

        return model
    }

    // MARK: - VRM 0.x Material Properties Parsing

    private func parseMaterialProperties(_ properties: [[String: Any]]) -> [VRM0MaterialProperty] {
        var result: [VRM0MaterialProperty] = []

        for (index, propDict) in properties.enumerated() {
            var prop = VRM0MaterialProperty()

            prop.name = propDict["name"] as? String
            prop.shader = propDict["shader"] as? String
            prop.renderQueue = propDict["renderQueue"] as? Int

            // Parse float properties
            if let floatProps = propDict["floatProperties"] as? [String: Any] {
                for (key, value) in floatProps {
                    if let floatValue = value as? Double {
                        prop.floatProperties[key] = Float(floatValue)
                    } else if let floatValue = value as? Float {
                        prop.floatProperties[key] = floatValue
                    } else if let intValue = value as? Int {
                        prop.floatProperties[key] = Float(intValue)
                    }
                }
            }

            // Parse vector properties
            if let vectorProps = propDict["vectorProperties"] as? [String: Any] {
                for (key, value) in vectorProps {
                    if let arrayValue = value as? [Double] {
                        prop.vectorProperties[key] = arrayValue.map { Float($0) }
                    } else if let arrayValue = value as? [Float] {
                        prop.vectorProperties[key] = arrayValue
                    } else if let arrayValue = value as? [Int] {
                        prop.vectorProperties[key] = arrayValue.map { Float($0) }
                    } else if let arr = value as? [Any] {
                        // AnyCodable path: a VRM 0.x color literal like
                        // `_Color: [1, 0, 0, 1.0]` arrives as
                        // `[Int, Int, Int, Double]`. Per-element coerce so
                        // the homogeneous-only fallbacks above don't drop
                        // it — same VMK#236 bug class for VRM 0.x.
                        let parsed = arr.compactMap { parseFloatValue($0) }
                        if parsed.count == arr.count {
                            prop.vectorProperties[key] = parsed
                        }
                    }
                }
            }

            // Parse texture properties
            if let textureProps = propDict["textureProperties"] as? [String: Any] {
                for (key, value) in textureProps {
                    if let intValue = value as? Int {
                        prop.textureProperties[key] = intValue
                    }
                }
            }

            // Parse keyword map
            if let keywordMap = propDict["keywordMap"] as? [String: Bool] {
                prop.keywordMap = keywordMap
            }

            // Parse tag map
            if let tagMap = propDict["tagMap"] as? [String: String] {
                prop.tagMap = tagMap
            }

            // Log important values for debugging
            if let shadeColor = prop.vectorProperties["_ShadeColor"] {
                vrmLog("[VRMExtensionParser] Material[\(index)] '\(prop.name ?? "unnamed")' shadeColor=\(shadeColor)")
            }
            if let shadeToony = prop.floatProperties["_ShadeToony"] {
                vrmLog("[VRMExtensionParser] Material[\(index)] '\(prop.name ?? "unnamed")' shadeToony=\(shadeToony)")
            }

            result.append(prop)
        }

        return result
    }

    private func parseMeta(_ dict: [String: Any], specVersion: VRMSpecVersion) throws -> VRMMeta {
        // VRM 1.0 uses "licenseUrl", VRM 0.0 uses "otherLicenseUrl"
        let licenseUrlValue = dict["licenseUrl"] as? String
        let otherLicenseUrlValue = dict["otherLicenseUrl"] as? String

        let licenseUrl: String
        if specVersion != .v0_0 {
            // VRM 1.0+: licenseUrl is REQUIRED and must be non-empty
            guard let url = licenseUrlValue, !url.isEmpty else {
                throw VRMError.invalidMeta(
                    "licenseUrl is required by the VRM 1.0 spec (VRMC_vrm §meta) but is missing or empty. Add a valid license URL to the model's meta block."
                )
            }
            licenseUrl = url
        } else {
            // VRM 0.0: tolerant — fall back to otherLicenseUrl or empty string
            licenseUrl = licenseUrlValue ?? otherLicenseUrlValue ?? ""
        }

        var meta = VRMMeta(licenseUrl: licenseUrl)

        // VRM 1.0 uses "name", VRM 0.0 uses "title"
        meta.name = (dict["name"] as? String) ?? (dict["title"] as? String)
        meta.version = dict["version"] as? String
        // VRM 1.0 uses "authors" array, VRM 0.0 uses "author" string
        if let authors = dict["authors"] as? [String] {
            meta.authors = authors
        } else if let author = dict["author"] as? String {
            meta.authors = [author]
        } else {
            meta.authors = []
        }
        meta.copyrightInformation = dict["copyrightInformation"] as? String
        meta.contactInformation = dict["contactInformation"] as? String
        meta.references = dict["references"] as? [String] ?? []
        meta.thirdPartyLicenses = dict["thirdPartyLicenses"] as? String
        meta.thumbnailImage = dict["thumbnailImage"] as? Int

        if let avatarPermissionStr = dict["avatarPermission"] as? String {
            meta.avatarPermission = VRMAvatarPermission(rawValue: avatarPermissionStr)
        }

        if let commercialUsageStr = dict["commercialUsage"] as? String {
            meta.commercialUsage = VRMCommercialUsage(rawValue: commercialUsageStr)
        }

        if let creditNotationStr = dict["creditNotation"] as? String {
            meta.creditNotation = VRMCreditNotation(rawValue: creditNotationStr)
        }

        meta.allowRedistribution = dict["allowRedistribution"] as? Bool

        if let modifyStr = dict["modify"] as? String {
            meta.modify = VRMModifyPermission(rawValue: modifyStr)
        }

        meta.otherLicenseUrl = dict["otherLicenseUrl"] as? String
        meta.allowExcessivelyViolentUsage = dict["allowExcessivelyViolentUsage"] as? Bool
        meta.allowExcessivelySexualUsage = dict["allowExcessivelySexualUsage"] as? Bool
        meta.allowPoliticalOrReligiousUsage = dict["allowPoliticalOrReligiousUsage"] as? Bool
        meta.allowAntisocialOrHateUsage = dict["allowAntisocialOrHateUsage"] as? Bool

        return meta
    }

    private func parseHumanoid(_ dict: [String: Any]) throws -> VRMHumanoid {
        let humanoid = VRMHumanoid()

        // VRM 1.0 uses a dictionary, VRM 0.0 uses an array
        if let humanBonesDict = dict["humanBones"] as? [String: Any] {
            // VRM 1.0 format
            for (boneName, boneData) in humanBonesDict {
                guard let bone = VRMHumanoidBone(rawValue: boneName),
                      let boneDict = boneData as? [String: Any],
                      let nodeIndex = boneDict["node"] as? Int else {
                    continue
                }

                humanoid.humanBones[bone] = VRMHumanoid.VRMHumanBone(node: nodeIndex)
            }
        } else if let humanBonesArray = dict["humanBones"] as? [[String: Any]] {
            // VRM 0.0 format - array of bone objects
            for boneData in humanBonesArray {
                guard let boneName = boneData["bone"] as? String,
                      let bone = VRMHumanoidBone(rawValue: boneName),
                      let nodeIndex = boneData["node"] as? Int else {
                    continue
                }

                humanoid.humanBones[bone] = VRMHumanoid.VRMHumanBone(node: nodeIndex)
            }
        }

        try humanoid.validate()

        return humanoid
    }

    private func parseFirstPerson(_ dict: [String: Any]) throws -> VRMFirstPerson {
        let firstPerson = VRMFirstPerson()

        // Handle VRM 0.0 firstPersonBone
        if let firstPersonBone = dict["firstPersonBone"] as? Int {
            // Store as the bone index for first person view
            // This needs to be mapped to actual usage in the renderer
            vrmLog("[VRMExtensionParser] Found firstPersonBone: \(firstPersonBone)")
        }

        // Handle VRM 0.0 firstPersonBoneOffset. Use `parseFloatValue` so
        // whole-number components (e.g. `"x": 0`) decoded as `Int` by
        // AnyCodable don't silently fall through.
        if let offsetDict = dict["firstPersonBoneOffset"] as? [String: Any],
           let x = parseFloatValue(offsetDict["x"]),
           let y = parseFloatValue(offsetDict["y"]),
           let z = parseFloatValue(offsetDict["z"]) {
            vrmLog("[VRMExtensionParser] Found firstPersonBoneOffset: (\(x), \(y), \(z))")
        }

        if let meshAnnotations = dict["meshAnnotations"] as? [[String: Any]] {
            for annotation in meshAnnotations {
                // VRM 0.0 uses "mesh" instead of "node" for some annotations
                let nodeOrMesh = annotation["node"] as? Int ?? annotation["mesh"] as? Int
                guard let node = nodeOrMesh,
                      let typeStr = annotation["firstPersonFlag"] as? String ?? annotation["type"] as? String else {
                    continue
                }

                // Map VRM 0.0 flag names to VRM 1.0 if needed
                let type = VRMFirstPersonFlag(rawValue: typeStr) ?? .auto

                firstPerson.meshAnnotations.append(
                    VRMFirstPerson.VRMMeshAnnotation(node: node, type: type)
                )
            }
        }

        return firstPerson
    }

    private func parseLookAtFromFirstPerson(_ dict: [String: Any]) throws -> VRMLookAt {
        let lookAt = VRMLookAt()

        // VRM 0.0 stores lookAt type as lookAtTypeName in firstPerson
        if let typeName = dict["lookAtTypeName"] as? String {
            lookAt.type = VRMLookAtType(rawValue: typeName.lowercased()) ?? .bone
        }

        // Parse VRM 0.0 lookAt curve mappings
        if let horizontalInner = dict["lookAtHorizontalInner"] as? [String: Any] {
            lookAt.rangeMapHorizontalInner = parseVRM0LookAtCurve(horizontalInner)
        }

        if let horizontalOuter = dict["lookAtHorizontalOuter"] as? [String: Any] {
            lookAt.rangeMapHorizontalOuter = parseVRM0LookAtCurve(horizontalOuter)
        }

        if let verticalDown = dict["lookAtVerticalDown"] as? [String: Any] {
            lookAt.rangeMapVerticalDown = parseVRM0LookAtCurve(verticalDown)
        }

        if let verticalUp = dict["lookAtVerticalUp"] as? [String: Any] {
            lookAt.rangeMapVerticalUp = parseVRM0LookAtCurve(verticalUp)
        }

        return lookAt
    }

    private func parseVRM0LookAtCurve(_ dict: [String: Any]) -> VRMLookAtRangeMap {
        var rangeMap = VRMLookAtRangeMap()

        // VRM 0.0 uses xRange for input and yRange for output.
        if let xRange = parseFloatValue(dict["xRange"]) {
            rangeMap.inputMaxValue = xRange
        }
        if let yRange = parseFloatValue(dict["yRange"]) {
            rangeMap.outputScale = yRange
        }

        return rangeMap
    }

    private func parseLookAt(_ dict: [String: Any]) throws -> VRMLookAt {
        let lookAt = VRMLookAt()

        if let typeStr = dict["type"] as? String,
           let type = VRMLookAtType(rawValue: typeStr) {
            lookAt.type = type
        }

        // Parse offsetFromHeadBone via the canonical vec3 coercion so
        // whole-number components (e.g. `[0.0, 0.06, 0.0]`) survive
        // AnyCodable's Int-before-Double decoder. See VMK#236 for the
        // bug class.
        if let offset = parseVector3(dict["offsetFromHeadBone"]) {
            lookAt.offsetFromHeadBone = offset
        }

        if let rangeMap = dict["rangeMapHorizontalInner"] as? [String: Any] {
            lookAt.rangeMapHorizontalInner = parseRangeMap(rangeMap)
        }

        if let rangeMap = dict["rangeMapHorizontalOuter"] as? [String: Any] {
            lookAt.rangeMapHorizontalOuter = parseRangeMap(rangeMap)
        }

        if let rangeMap = dict["rangeMapVerticalDown"] as? [String: Any] {
            lookAt.rangeMapVerticalDown = parseRangeMap(rangeMap)
        }

        if let rangeMap = dict["rangeMapVerticalUp"] as? [String: Any] {
            lookAt.rangeMapVerticalUp = parseRangeMap(rangeMap)
        }

        return lookAt
    }

    private func parseRangeMap(_ dict: [String: Any]) -> VRMLookAtRangeMap {
        var rangeMap = VRMLookAtRangeMap()

        if let inputMaxValue = parseFloatValue(dict["inputMaxValue"]) {
            rangeMap.inputMaxValue = inputMaxValue
        }
        if let outputScale = parseFloatValue(dict["outputScale"]) {
            rangeMap.outputScale = outputScale
        }

        return rangeMap
    }

    private func parseBlendShapeMaster(_ dict: [String: Any]) throws -> VRMExpressions {
        let expressions = VRMExpressions()

        // VRM 0.0 uses blendShapeGroups array
        if let blendShapeGroups = dict["blendShapeGroups"] as? [[String: Any]] {
            for group in blendShapeGroups {
                guard let name = group["name"] as? String else { continue }

                // Map VRM 0.0 presetName to VRM 1.0 expression preset
                let presetName = group["presetName"] as? String ?? name

                // Create expression from VRM 0.0 blendshape group
                var expression = VRMExpression(name: name)

                // Parse binds (morph target bindings)
                if let binds = group["binds"] as? [[String: Any]] {
                    vrmLog("[VRMExtensionParser] Found \(binds.count) binds for \(presetName)")
                    for bind in binds {
                        // Parse weight with null handling
                        var weightValue: Float? = nil
                        let weightField = bind["weight"]

                        // Check for null/NSNull first
                        if weightField == nil || weightField is NSNull {
                            // Skip entries with null weights - they are invalid
                            vrmLog("[VRMExtensionParser] Skipping bind for \(presetName) - null weight")
                            continue
                        }

                        // Try Float, Double, and Int for weight (VRM 0.0 often uses Int)
                        if let weight = weightField as? Float {
                            weightValue = weight
                        } else if let weight = weightField as? Double {
                            weightValue = Float(weight)
                        } else if let weight = weightField as? Int {
                            weightValue = Float(weight)
                        }

                        if let mesh = bind["mesh"] as? Int,
                           let index = bind["index"] as? Int,
                           let weight = weightValue {
                            vrmLog("[VRMExtensionParser] Adding morph bind for \(presetName): mesh=\(mesh), morphIndex=\(index), weight=\(weight)")
                            expression.morphTargetBinds.append(
                                VRMMorphTargetBind(
                                    node: mesh,
                                    index: index,
                                    weight: weight / 100.0  // VRM 0.0 uses 0-100, VRM 1.0 uses 0-1
                                )
                            )
                        } else {
                            vrmLog("[VRMExtensionParser] Failed to parse bind for \(presetName): mesh=\(String(describing: bind["mesh"])), index=\(String(describing: bind["index"])), weight=\(String(describing: weightField))")
                        }
                    }
                } else {
                    vrmLog("[VRMExtensionParser] No binds found for \(presetName)")
                }

                // Try to map to preset
                if let preset = mapVRM0PresetToVRM1(presetName) {
                    expressions.preset[preset] = expression
                } else {
                    // Store as custom expression
                    expressions.custom[name] = expression
                }
            }
        }

        return expressions
    }

    private func mapVRM0PresetToVRM1(_ presetName: String) -> VRMExpressionPreset? {
        // Map VRM 0.0 preset names to VRM 1.0
        switch presetName.lowercased() {
        case "neutral": return .neutral
        case "joy", "happy": return .happy
        case "angry": return .angry
        case "sorrow", "sad": return .sad
        case "fun", "relaxed": return .relaxed
        case "surprised": return .surprised
        case "blink": return .blink
        case "blink_l": return .blinkLeft
        case "blink_r": return .blinkRight
        case "a": return .aa
        case "i": return .ih
        case "u": return .ou
        case "e": return .ee
        case "o": return .oh
        default: return nil
        }
    }

    private func parseExpressions(_ dict: [String: Any]) throws -> VRMExpressions {
        let expressions = VRMExpressions()

        if let presetDict = dict["preset"] as? [String: Any] {
            for (presetName, expressionData) in presetDict {
                guard let preset = VRMExpressionPreset(rawValue: presetName),
                      let expressionDict = expressionData as? [String: Any] else {
                    continue
                }

                expressions.preset[preset] = try parseExpression(expressionDict, name: presetName)
            }
        }

        if let customDict = dict["custom"] as? [String: Any] {
            for (customName, expressionData) in customDict {
                guard let expressionDict = expressionData as? [String: Any] else {
                    continue
                }

                expressions.custom[customName] = try parseExpression(expressionDict, name: customName)
            }
        }

        return expressions
    }

    private func parseExpression(_ dict: [String: Any], name: String) throws -> VRMExpression {
        var expression = VRMExpression(name: name)

        expression.isBinary = dict["isBinary"] as? Bool ?? false

        if let morphTargetBinds = dict["morphTargetBinds"] as? [[String: Any]] {
            for bind in morphTargetBinds {
                guard let node = bind["node"] as? Int,
                      let index = bind["index"] as? Int else {
                    continue
                }
                // VMK#236 bug class: `JSONSerialization` decodes JSON
                // numbers as `Double` (or `Int` for whole-number literals
                // like `1` / `0`); `as? Float` succeeds only on the rare
                // case where the bridge lands on `Float` directly, so
                // almost every weight silently failed and the bind was
                // dropped. Loaded VRM 1.0 expressions ended up registered
                // but empty, making `setExpressionWeight(...)` a no-op
                // (visemes never deformed the mesh, blink/emotion presets
                // dead too). Same Float/Double/Int trichotomy the VRM 0.x
                // morph-bind path above already handles.
                let weight: Float
                if let f = bind["weight"] as? Float { weight = f }
                else if let d = bind["weight"] as? Double { weight = Float(d) }
                else if let i = bind["weight"] as? Int { weight = Float(i) }
                else { continue }

                expression.morphTargetBinds.append(
                    VRMMorphTargetBind(node: node, index: index, weight: weight)
                )
            }
        }

        if let materialColorBinds = dict["materialColorBinds"] as? [[String: Any]] {
            for bind in materialColorBinds {
                // `JSONSerialization` decodes JSON number arrays as `[Double]`;
                // test fixtures sometimes pass `[Float]`. `AnyCodable` is a
                // third case — whole-number elements arrive as `Int`, so a
                // spec-typical RGBA like `[1.0, 0.0, 0.0, 1.0]` becomes a
                // heterogeneous `[Int, Int, Int, Int]` or `[Double, Int, Int, Double]`
                // depending on which components carry decimals (VMK#236
                // bug class). Per-element coercion via parseFloatValue
                // catches all three forms.
                let targetFloats: [Float]?
                if let arr = bind["targetValue"] as? [Double] {
                    targetFloats = arr.map(Float.init)
                } else if let arr = bind["targetValue"] as? [Float] {
                    targetFloats = arr
                } else if let arr = bind["targetValue"] as? [Any] {
                    let parsed = arr.compactMap { parseFloatValue($0) }
                    targetFloats = parsed.count == arr.count ? parsed : nil
                } else {
                    targetFloats = nil
                }
                guard let material = bind["material"] as? Int,
                      let typeStr = bind["type"] as? String,
                      let type = VRMMaterialColorType(rawValue: typeStr),
                      let targetValue = targetFloats,
                      targetValue.count == 4 else {
                    continue
                }

                expression.materialColorBinds.append(
                    VRMMaterialColorBind(
                        material: material,
                        type: type,
                        targetValue: SIMD4<Float>(targetValue[0], targetValue[1], targetValue[2], targetValue[3])
                    )
                )
            }
        }

        if let overrideBlinkStr = dict["overrideBlink"] as? String {
            expression.overrideBlink = VRMExpressionOverrideType(rawValue: overrideBlinkStr) ?? .none
        }

        if let overrideLookAtStr = dict["overrideLookAt"] as? String {
            expression.overrideLookAt = VRMExpressionOverrideType(rawValue: overrideLookAtStr) ?? .none
        }

        if let overrideMouthStr = dict["overrideMouth"] as? String {
            expression.overrideMouth = VRMExpressionOverrideType(rawValue: overrideMouthStr) ?? .none
        }

        return expression
    }

    private func parseSpringBone(_ dict: [String: Any]) throws -> VRMSpringBone {
        var springBone = VRMSpringBone()

        if let specVersion = dict["specVersion"] as? String {
            springBone.specVersion = specVersion
        }

        if let colliders = dict["colliders"] as? [[String: Any]] {
            for (colliderIndex, colliderDict) in colliders.enumerated() {
                guard let node = colliderDict["node"] as? Int else { continue }
                if let shape = parseColliderEntryShape(colliderDict, colliderIndex: colliderIndex, node: node) {
                    springBone.colliders.append(VRMCollider(node: node, shape: shape))
                }
            }
        }

        if let colliderGroups = dict["colliderGroups"] as? [[String: Any]] {
            for groupDict in colliderGroups {
                var group = VRMColliderGroup()
                group.name = groupDict["name"] as? String
                group.colliders = groupDict["colliders"] as? [Int] ?? []
                springBone.colliderGroups.append(group)
            }
        }

        if let springs = dict["springs"] as? [[String: Any]] {
            for springDict in springs {
                var spring = VRMSpring(name: springDict["name"] as? String)
                spring.colliderGroups = springDict["colliderGroups"] as? [Int] ?? []
                spring.center = springDict["center"] as? Int

                if let joints = springDict["joints"] as? [[String: Any]] {
                    for jointDict in joints {
                        guard let node = jointDict["node"] as? Int else { continue }

                        var joint = VRMSpringJoint(node: node)
                        joint.hitRadius = parseFloatValue(jointDict["hitRadius"]) ?? 0.0
                        joint.stiffness = parseFloatValue(jointDict["stiffness"]) ?? 1.0
                        joint.gravityPower = parseFloatValue(jointDict["gravityPower"]) ?? 0.0
                        joint.dragForce = parseFloatValue(jointDict["dragForce"]) ?? 0.4

                        if let gravityDir = jointDict["gravityDir"] as? [Any] {
                            let floats = gravityDir.compactMap { parseFloatValue($0) }
                            if floats.count == 3 {
                                joint.gravityDir = SIMD3<Float>(floats[0], floats[1], floats[2])
                            }
                        }

                        // VRMC_springBone_extended_collider per-joint
                        // angleLimit. The published 1.0 spec does not define
                        // a unit; conformance fixtures author whole-number
                        // degrees (e.g. `60`) which would be ~3400° if read
                        // as radians, so we treat the file value as degrees
                        // and convert to radians for internal use. Default
                        // 0 = no limit.
                        if let jointExt = (jointDict["extensions"] as? [String: Any])?["VRMC_springBone_extended_collider"] as? [String: Any],
                           let angleLimitDegrees = parseFloatValue(jointExt["angleLimit"]) {
                            joint.angleLimit = max(0, angleLimitDegrees) * .pi / 180.0
                        }

                        spring.joints.append(joint)
                    }
                }

                springBone.springs.append(spring)
            }
        }

        validateSpringJointUniqueness(&springBone)
        return springBone
    }

    /// Pick the shape for one entry in `springs[].colliders[]`, honouring
    /// the VRMC_springBone_extended_collider 1.0 precedence rule:
    /// **spec-aware loaders prefer the extension's shape over the base
    /// `shape`**. The spec calls out the base `shape` as a deliberately
    /// degraded fallback for legacy loaders — the spec's own examples show
    /// authors using `radius: 1000` spheres to approximate planes and
    /// `radius: 0` spheres at `[0, -10000, 0]` as inert filler for inverted
    /// shapes. Reading the base first would silently downgrade those
    /// assets to the legacy approximation.
    ///
    /// Order tried, first match wins:
    /// 1. `extensions.VRMC_springBone_extended_collider.shape` — spec
    ///    extension. Returns `nil` for inverted shapes that VMK#237 phase 2
    ///    doesn't ship yet, which falls through to the base.
    /// 2. `shape` — base VRMC_springBone-1.0 sphere / capsule / plane.
    private func parseColliderEntryShape(
        _ colliderDict: [String: Any],
        colliderIndex: Int,
        node: Int
    ) -> VRMColliderShape? {
        if let extColl = (colliderDict["extensions"] as? [String: Any])?["VRMC_springBone_extended_collider"] as? [String: Any] {
            // Spec MUST: `specVersion` field on the extension. Warn on
            // mismatch for forward-compat; still try to parse (a future
            // spec rev might add fields we ignore, not break ones we read).
            if let specVersion = extColl["specVersion"] as? String, specVersion != "1.0" {
                vrmLog("[VRMExtensionParser] WARNING: Collider \(colliderIndex) (node \(node)) " +
                       "VRMC_springBone_extended_collider specVersion '\(specVersion)' is not '1.0' — " +
                       "proceeding with best-effort parsing.")
            }
            if let extShapeDict = extColl["shape"] as? [String: Any],
               let extShape = parseExtendedColliderShape(extShapeDict, colliderIndex: colliderIndex, node: node) {
                return extShape
            }
            // Extension present but unusable — leave a forensic trail so the
            // next "extension didn't behave" report points here.
            vrmLog("[VRMExtensionParser] WARNING: Collider \(colliderIndex) (node \(node)) " +
                   "has a VRMC_springBone_extended_collider entry but no readable shape; " +
                   "falling back to the entry's base `shape` if present.")
        }
        if let shapeDict = colliderDict["shape"] as? [String: Any],
           let baseShape = parseColliderShape(shapeDict) {
            return baseShape
        }
        return nil
    }

    /// Parse a `VRMC_springBone_extended_collider.shape` dict. The
    /// extension promotes VMK's existing (originally non-spec) `plane`
    /// collider to the spec, and introduces `insideSphere` / `insideCapsule`
    /// (containment shapes — bone must stay *inside* the volume).
    ///
    /// Spec: <https://github.com/vrm-c/vrm-specification/blob/master/specification/VRMC_springBone_extended_collider-1.0/README.md>
    ///
    /// - Returns: A ``VRMColliderShape`` mapped to the corresponding base
    ///   or inverted case. Returns `nil` (and logs a warning) when the
    ///   shape kind is unrecognised.
    private func parseExtendedColliderShape(
        _ dict: [String: Any],
        colliderIndex: Int,
        node: Int
    ) -> VRMColliderShape? {
        if let planeDict = dict["plane"] as? [String: Any] {
            let offset = parseVector3(planeDict["offset"]) ?? SIMD3<Float>(0, 0, 0)
            // Spec default for extension plane normal is `[0, 0, 1]` (not VMK's
            // legacy `[0, 1, 0]` from the originally non-spec base plane).
            let rawNormal = parseVector3(planeDict["normal"]) ?? SIMD3<Float>(0, 0, 1)
            // Spec MUST: normalize at parse time. Authors sometimes ship
            // non-unit normals (especially when copying values from a
            // direction vector); collision math assumes unit length.
            let len = simd_length(rawNormal)
            let normal = len > 1e-6 ? rawNormal / len : SIMD3<Float>(0, 0, 1)
            return .plane(offset: offset, normal: normal)
        }
        if let sphereDict = dict["sphere"] as? [String: Any] {
            let (offset, radius) = parseSphereBody(sphereDict)
            let inside = (sphereDict["inside"] as? Bool) ?? false
            return inside
                ? .insideSphere(offset: offset, radius: radius)
                : .sphere(offset: offset, radius: radius)
        }
        if let capsuleDict = dict["capsule"] as? [String: Any] {
            let (offset, radius, tail) = parseCapsuleBody(capsuleDict)
            let inside = (capsuleDict["inside"] as? Bool) ?? false
            return inside
                ? .insideCapsule(offset: offset, radius: radius, tail: tail)
                : .capsule(offset: offset, radius: radius, tail: tail)
        }
        let keys = dict.keys.joined(separator: ", ")
        vrmLog("[VRMExtensionParser] WARNING: Collider \(colliderIndex) (node \(node)) " +
               "uses VRMC_springBone_extended_collider with an unrecognised shape kind " +
               "(\(keys)); collider skipped.")
        return nil
    }

    /// Shared `{offset, radius}` extraction used by both the base
    /// `parseColliderShape` and the extension's non-inverted sphere path.
    private func parseSphereBody(_ dict: [String: Any]) -> (offset: SIMD3<Float>, radius: Float) {
        let offset = parseVector3(dict["offset"]) ?? SIMD3<Float>(0, 0, 0)
        let radius = parseFloatValue(dict["radius"]) ?? 0.0
        return (offset, radius)
    }

    /// Shared `{offset, radius, tail}` extraction used by both the base
    /// `parseColliderShape` and the extension's non-inverted capsule path.
    private func parseCapsuleBody(_ dict: [String: Any]) -> (offset: SIMD3<Float>, radius: Float, tail: SIMD3<Float>) {
        let offset = parseVector3(dict["offset"]) ?? SIMD3<Float>(0, 0, 0)
        let radius = parseFloatValue(dict["radius"]) ?? 0.0
        let tail = parseVector3(dict["tail"]) ?? SIMD3<Float>(0, 0, 0)
        return (offset, radius, tail)
    }

    private func parseColliderShape(_ dict: [String: Any]) -> VRMColliderShape? {
        if let sphereDict = dict["sphere"] as? [String: Any] {
            let (offset, radius) = parseSphereBody(sphereDict)
            return .sphere(offset: offset, radius: radius)
        } else if let capsuleDict = dict["capsule"] as? [String: Any] {
            let (offset, radius, tail) = parseCapsuleBody(capsuleDict)
            return .capsule(offset: offset, radius: radius, tail: tail)
        } else if let planeDict = dict["plane"] as? [String: Any] {
            #if VRM_METALKIT_ENABLE_LOGS
            print("[VRMMetalKit] WARNING: VRMMetalKit-specific 'plane' collider in use. This is non-spec and not portable.")
            #endif
            let offset = parseVector3(planeDict["offset"]) ?? SIMD3<Float>(0, 0, 0)
            let normal = parseVector3(planeDict["normal"]) ?? SIMD3<Float>(0, 1, 0)
            return .plane(offset: offset, normal: normal)
        }

        return nil
    }

    /// Coerce a JSON scalar to `Float`, accepting whichever numeric type the
    /// decoder produced. Critical: ``AnyCodable`` (used by `GLTFParser` for
    /// extension dictionaries) tries `Int` *before* `Double`, so JSON
    /// whole-number literals like `1.0`, `-1`, `0` arrive as raw `Int` —
    /// without the explicit `Int` branch, every `as? Double` cast on a
    /// whole-number factor silently returns `nil` and the field falls back
    /// to its default. This is the root cause class of VMK#238 / VMK#239 in
    /// MToon parsing (scalar level) and **VMK#236** in spring-bone collider
    /// offsets (vector level, see ``parseVector3(_:)``); the explicit `Int`
    /// branch here keeps the bug from re-appearing in VRM 0.x lookAt range
    /// maps, firstPersonBoneOffset, and similar extension scalars.
    ///
    /// Internal rather than private so the regression test for this exact
    /// numeric-coercion contract can pin down all four branches without
    /// going through end-to-end VRM loading.
    func parseFloatValue(_ value: Any?) -> Float? {
        if let floatVal = value as? Float {
            return floatVal
        } else if let doubleVal = value as? Double {
            return Float(doubleVal)
        } else if let intVal = value as? Int {
            return Float(intVal)
        } else if let numVal = value as? NSNumber {
            return numVal.floatValue
        }
        return nil
    }

    /// Internal rather than private so the regression test for this exact
    /// vec3 coercion contract can pin down all branches (Double-array,
    /// Float-array, mixed-Any-array, length mismatch, non-numeric element)
    /// without going through end-to-end VRM loading. Mirror of
    /// ``parseFloatValue(_:)``'s testability rationale.
    func parseVector3(_ value: Any?) -> SIMD3<Float>? {
        // `JSONSerialization` decodes JSON number arrays as `[Double]` on
        // Apple platforms; test harnesses sometimes construct `[Float]` arrays
        // directly. The `AnyCodable` path (used for GLTFDocument.extensions)
        // is the third case: it stores whole-number elements as `Int` and
        // fractional ones as `Double`, so a spec-typical offset like
        // `[0.02, -0.10, 0.0]` arrives as `[Double, Double, Int]`. Without
        // per-element coercion the `as? [Double]` cast fails on the mixed
        // array, every collider offset / capsule tail / plane normal
        // collapses to `(0, 0, 0)`, and hair clips through the head/face
        // (and the chain falls straight through every author-placed
        // collider during settle — VMK#236).
        if let array = value as? [Double], array.count == 3 {
            return SIMD3<Float>(Float(array[0]), Float(array[1]), Float(array[2]))
        }
        if let array = value as? [Float], array.count == 3 {
            return SIMD3<Float>(array[0], array[1], array[2])
        }
        if let array = value as? [Any], array.count == 3,
           let x = parseFloatValue(array[0]),
           let y = parseFloatValue(array[1]),
           let z = parseFloatValue(array[2]) {
            return SIMD3<Float>(x, y, z)
        }
        return nil
    }

    // MARK: - VRM 0.0 Secondary Animation Support

    private func parseSecondaryAnimation(_ dict: [String: Any]) -> VRMSpringBone {
        var springBone = VRMSpringBone()
        springBone.specVersion = "0.0"  // Mark as VRM 0.0 format

        // VRM 0.0 uses boneGroups for spring chains
        if let boneGroups = dict["boneGroups"] as? [[String: Any]] {
            for groupDict in boneGroups {
                var spring = VRMSpring(name: groupDict["comment"] as? String)

                // Center bone
                if let center = groupDict["center"] as? Int {
                    spring.center = center
                }

                // Bones array becomes joints
                if let bones = groupDict["bones"] as? [Int] {
                    for boneIndex in bones {
                        var joint = VRMSpringJoint(node: boneIndex)

                        // VRM 0.0 physics parameters - handle both correct and typo versions
                        // JSON numbers may come as Double or NSNumber, so try multiple casts
                        if let stiffFloat = groupDict["stiffness"] as? Float {
                            joint.stiffness = stiffFloat
                        } else if let stiffDouble = groupDict["stiffness"] as? Double {
                            joint.stiffness = Float(stiffDouble)
                        } else if let stiffNum = groupDict["stiffness"] as? NSNumber {
                            joint.stiffness = stiffNum.floatValue
                        } else if let stiffFloat = groupDict["stiffiness"] as? Float {  // Legacy typo
                            joint.stiffness = stiffFloat
                        } else if let stiffDouble = groupDict["stiffiness"] as? Double {
                            joint.stiffness = Float(stiffDouble)
                        } else {
                            joint.stiffness = 1.0  // Default only if not found at all
                        }

                        // VRM 0.x quirk: many real-world models export gravityPower=0 (or omit it)
                        // but clearly expect gravity to work (hair falls, skirts swing). The VRM 0.x
                        // spec did not define a meaningful default, so authors relied on runtime
                        // behavior that defaulted to gravity-on. Forcing 0→1.0 preserves that
                        // real-world behavior for VRM 0.x only; VRM 1.0 respects explicit 0.0.
                        //
                        // ⚠️ LOAD-BEARING: this 0→1.0 substitution is paired with the
                        // INERTIA COMPENSATION block inside the `springBonePredict`
                        // Metal kernel. AvatarSample_A's hair tuning
                        // (`stiffness=0.85, gravityPower=0, dragForce=0.4`) is
                        // calibrated against THIS combination; touching either side
                        // in isolation visibly breaks the model. Intent is the
                        // VRM 0.x author tuning — not the test — but the local
                        // characterization gate `SpringBoneRegressionTests` freezes
                        // the resulting trajectory and will trip on any drift. If a
                        // change here is intentional (e.g. matching three-vrm
                        // post-conformance), regenerate the baseline alongside it.
                        // See #162 for the equilibrium analysis.
                        let rawGravityPower: Float
                        if let gpFloat = groupDict["gravityPower"] as? Float {
                            rawGravityPower = gpFloat
                        } else if let gpDouble = groupDict["gravityPower"] as? Double {
                            rawGravityPower = Float(gpDouble)
                        } else if let gpNum = groupDict["gravityPower"] as? NSNumber {
                            rawGravityPower = gpNum.floatValue
                        } else {
                            rawGravityPower = 0.0
                        }
                        joint.gravityPower = rawGravityPower > 0 ? rawGravityPower : 1.0

                        if let dragFloat = groupDict["dragForce"] as? Float {
                            joint.dragForce = dragFloat
                        } else if let dragDouble = groupDict["dragForce"] as? Double {
                            joint.dragForce = Float(dragDouble)
                        } else if let dragNum = groupDict["dragForce"] as? NSNumber {
                            joint.dragForce = dragNum.floatValue
                        } else {
                            joint.dragForce = 0.4
                        }

                        if let hitFloat = groupDict["hitRadius"] as? Float {
                            joint.hitRadius = hitFloat
                        } else if let hitDouble = groupDict["hitRadius"] as? Double {
                            joint.hitRadius = Float(hitDouble)
                        } else if let hitNum = groupDict["hitRadius"] as? NSNumber {
                            joint.hitRadius = hitNum.floatValue
                        } else {
                            joint.hitRadius = 0.0
                        }

                        // Gravity direction.
                        // VRM 0.x `gravityDir` is a world-space vector authored in
                        // the original Unity/-Z-forward frame.  The node hierarchy
                        // is conjugated by `Ry180` at load time (see
                        // `VRMModel.buildNodeHierarchy`), so any non-default
                        // gravity (e.g. `(0.3, -0.95, 0)` to pull hair forward)
                        // would otherwise point the wrong way after conversion.
                        // The default `(0, -1, 0)` is Ry180-invariant, so common
                        // assets are unaffected; this flip matches three-vrm's
                        // VRM0 → VRM1 converter for stylized gravity directions.
                        if let gravityDir = groupDict["gravityDir"] as? [String: Any] {
                            let x = gravityDir["x"] as? Float ?? 0
                            let y = gravityDir["y"] as? Float ?? -1
                            let z = gravityDir["z"] as? Float ?? 0
                            joint.gravityDir = SIMD3<Float>(-x, y, -z)
                        }

                        spring.joints.append(joint)
                    }
                }

                // Collider groups (VRM 0.0 uses indices directly)
                if let colliderGroups = groupDict["colliderGroups"] as? [Int] {
                    spring.colliderGroups = colliderGroups
                }

                springBone.springs.append(spring)
            }
        }

        // VRM 0.0 collider groups
        if let colliderGroups = dict["colliderGroups"] as? [[String: Any]] {
            for (index, groupDict) in colliderGroups.enumerated() {
                var group = VRMColliderGroup(name: "colliderGroup_\(index)")

                // VRM 0.0 stores colliders inline in each group
                if let colliders = groupDict["colliders"] as? [[String: Any]] {
                    for colliderDict in colliders {
                        // Note: VRM 0.0 stores node at group level, not collider level
                        let node: Int
                        if let groupNode = groupDict["node"] as? Int {
                            node = groupNode
                        } else if let colliderNode = colliderDict["node"] as? Int {
                            node = colliderNode
                        } else {
                            continue
                        }

                        // VRM 0.0 collider format.
                        // VRM 0.0 (Unity) uses a left-handed -Z forward system; VRM 1.0 / glTF uses +Z forward.
                        // The node hierarchy is conjugated by `Ry180` at load time
                        // (see `VRMModel.buildNodeHierarchy`), so the parent's local frame is
                        // now rotated in world.  To keep the collider at the same world
                        // position, the offset (expressed in the parent's local frame) must
                        // be rotated too: `offset_new = Ry180·offset_old = (-x, y, -z)`.
                        let rawOffset = parseVRM0Vector3(colliderDict["offset"]) ?? SIMD3<Float>(0, 0, 0)
                        let offset = SIMD3<Float>(-rawOffset.x, rawOffset.y, -rawOffset.z)
                        let radius = parseFloatValue(colliderDict["radius"]) ?? 0.0

                        // VRM 0.0 only supports spheres in most implementations
                        let shape = VRMColliderShape.sphere(offset: offset, radius: radius)
                        let collider = VRMCollider(node: node, shape: shape)

                        // Add to global colliders list
                        let colliderIndex = springBone.colliders.count
                        springBone.colliders.append(collider)
                        group.colliders.append(colliderIndex)
                    }
                }

                springBone.colliderGroups.append(group)
            }
        }

        validateSpringJointUniqueness(&springBone)
        return springBone
    }

    /// VRMC_springBone-1.0 spec: the same node MUST NOT appear in multiple springs or
    /// twice within one spring. Duplicate joints produce undefined simulation behaviour.
    /// Within-spring duplicates are removed first (more dangerous — degenerate edges).
    /// Cross-spring duplicates are removed from later springs.
    /// Violations are logged under VRM_METALKIT_ENABLE_LOGS.
    private func validateSpringJointUniqueness(_ springBone: inout VRMSpringBone) {
        var seenNodesGlobal = Set<Int>()
        var springWasModified = [Bool](repeating: false, count: springBone.springs.count)

        for springIndex in springBone.springs.indices {
            let originalCount = springBone.springs[springIndex].joints.count
            var seenNodesInSpring = Set<Int>()
            var dedupedJoints: [VRMSpringJoint] = []

            for joint in springBone.springs[springIndex].joints {
                if seenNodesInSpring.contains(joint.node) {
                    #if VRM_METALKIT_ENABLE_LOGS
                    print("[VRMMetalKit] WARNING: Spring '\(springBone.springs[springIndex].name ?? "\(springIndex)")' contains duplicate node \(joint.node) within the same spring chain — dropping duplicate joint.")
                    #endif
                    continue
                }
                seenNodesInSpring.insert(joint.node)

                if seenNodesGlobal.contains(joint.node) {
                    #if VRM_METALKIT_ENABLE_LOGS
                    print("[VRMMetalKit] WARNING: Node \(joint.node) appears in multiple springs — dropping from spring '\(springBone.springs[springIndex].name ?? "\(springIndex)")'. VRMC_springBone-1.0 §4.1 requires unique node membership.")
                    #endif
                    continue
                }
                seenNodesGlobal.insert(joint.node)
                dedupedJoints.append(joint)
            }

            if dedupedJoints.count != originalCount {
                springWasModified[springIndex] = true
            }
            springBone.springs[springIndex].joints = dedupedJoints
        }

        // Drop springs that were modified by deduplication and ended up with fewer than 2 joints.
        // Springs that originally had fewer than 2 joints are left as-is (not our validation concern).
        for i in springBone.springs.indices.reversed()
        where springWasModified[i] && springBone.springs[i].joints.count < 2 {
            #if VRM_METALKIT_ENABLE_LOGS
            print("[VRMMetalKit] WARNING: Spring '\(springBone.springs[i].name ?? "unnamed")' has fewer than 2 unique joints after deduplication — dropping spring.")
            #endif
            springBone.springs.remove(at: i)
        }
    }

    private func parseVRM0Vector3(_ value: Any?) -> SIMD3<Float>? {
        if let dict = value as? [String: Any] {
            let x = dict["x"] as? Float ?? 0
            let y = dict["y"] as? Float ?? 0
            let z = dict["z"] as? Float ?? 0
            return SIMD3<Float>(x, y, z)
        }
        return nil
    }

    // MARK: - Node Constraint Parsing

    /// Returns node constraints for the model, parsing `VRMC_node_constraint` on VRM 1.0 and synthesizing twist constraints from humanoid bones otherwise.
    ///
    /// VRM 1.0 explicitly stores per-node constraints in
    /// `VRMC_node_constraint`. VRM 0.x does not — twist distribution there
    /// is handled implicitly by the runtime, so this method synthesizes
    /// matching constraints from the humanoid bone definitions (upper-arm
    /// → lower-arm, upper-leg → lower-leg, …) whenever no explicit
    /// constraints are present.
    ///
    /// - Parameters:
    ///   - gltf: Parsed glTF document whose node `extensions` are inspected.
    ///   - humanoid: Resolved humanoid bone mapping. When `nil`, no
    ///     synthesis happens.
    ///   - isVRM0: Whether to skip the VRM 1.0 explicit-parse step.
    /// - Returns: Concatenation of explicit (VRM 1.0) and synthesized (VRM 0.x) constraints.
    public func parseOrSynthesizeConstraints(gltf: GLTFDocument, humanoid: VRMHumanoid?, isVRM0: Bool) -> [VRMNodeConstraint] {
        var constraints: [VRMNodeConstraint] = []

        // VRM 1.0: Parse VRMC_node_constraint from node extensions
        if !isVRM0 {
            constraints.append(contentsOf: parseVRM1Constraints(gltf: gltf))
        }

        // VRM 0.0 (or VRM 1.0 without explicit constraints): Synthesize from humanoid
        if let humanoid = humanoid, constraints.isEmpty {
            constraints.append(contentsOf: synthesizeTwistConstraints(humanoid: humanoid))
        }

        return constraints
    }

    /// Parse VRM 1.0 VRMC_node_constraint extensions from nodes.
    private func parseVRM1Constraints(gltf: GLTFDocument) -> [VRMNodeConstraint] {
        var constraints: [VRMNodeConstraint] = []

        guard let nodes = gltf.nodes else { return constraints }

        for (nodeIndex, node) in nodes.enumerated() {
            guard let extensions = node.extensions,
                  let constraintAnyCodable = extensions["VRMC_node_constraint"],
                  let constraintExt = constraintAnyCodable.value as? [String: Any],
                  let constraintDict = constraintExt["constraint"] as? [String: Any] else {
                continue
            }

            // Parse roll constraint
            if let rollDict = constraintDict["roll"] as? [String: Any],
               let sourceNode = rollDict["source"] as? Int {
                let rollAxis = parseRollAxis(rollDict["rollAxis"] as? String)
                let weight = parseFloatValue(rollDict["weight"]) ?? 1.0

                let constraint = VRMNodeConstraint(
                    targetNode: nodeIndex,
                    constraint: .roll(sourceNode: sourceNode, axis: rollAxis, weight: weight)
                )
                constraints.append(constraint)
                vrmLog("[VRMExtensionParser] Parsed roll constraint: node \(nodeIndex) <- source \(sourceNode), axis=\(rollAxis), weight=\(weight)")
            }

            // Parse aim constraint
            if let aimDict = constraintDict["aim"] as? [String: Any],
               let sourceNode = aimDict["source"] as? Int {
                let aimAxis = parseAimAxis(aimDict["aimAxis"] as? String)
                let weight = parseFloatValue(aimDict["weight"]) ?? 1.0

                let constraint = VRMNodeConstraint(
                    targetNode: nodeIndex,
                    constraint: .aim(sourceNode: sourceNode, aimAxis: aimAxis, weight: weight)
                )
                constraints.append(constraint)
                vrmLog("[VRMExtensionParser] Parsed aim constraint: node \(nodeIndex) <- source \(sourceNode)")
            }

            // Parse rotation constraint
            if let rotationDict = constraintDict["rotation"] as? [String: Any],
               let sourceNode = rotationDict["source"] as? Int {
                let weight = parseFloatValue(rotationDict["weight"]) ?? 1.0

                let constraint = VRMNodeConstraint(
                    targetNode: nodeIndex,
                    constraint: .rotation(sourceNode: sourceNode, weight: weight)
                )
                constraints.append(constraint)
                vrmLog("[VRMExtensionParser] Parsed rotation constraint: node \(nodeIndex) <- source \(sourceNode)")
            }
        }

        return constraints
    }

    /// Parse roll axis from string (VRM 1.0 spec uses "X", "Y", "Z").
    private func parseRollAxis(_ axisString: String?) -> SIMD3<Float> {
        switch axisString?.uppercased() {
        case "X": return SIMD3<Float>(1, 0, 0)
        case "Y": return SIMD3<Float>(0, 1, 0)
        case "Z": return SIMD3<Float>(0, 0, 1)
        default: return SIMD3<Float>(1, 0, 0)
        }
    }

    /// Parse aim axis from string.
    private func parseAimAxis(_ axisString: String?) -> SIMD3<Float> {
        switch axisString?.uppercased() {
        case "POSITIVEX": return SIMD3<Float>(1, 0, 0)
        case "NEGATIVEX": return SIMD3<Float>(-1, 0, 0)
        case "POSITIVEY": return SIMD3<Float>(0, 1, 0)
        case "NEGATIVEY": return SIMD3<Float>(0, -1, 0)
        case "POSITIVEZ": return SIMD3<Float>(0, 0, 1)
        case "NEGATIVEZ": return SIMD3<Float>(0, 0, -1)
        default: return SIMD3<Float>(0, 0, 1)
        }
    }

    /// Synthesize twist constraints for VRM 0.0 models.
    ///
    /// VRM 0.0 has no explicit constraint extension. If the model has twist bones
    /// defined in the humanoid, we automatically create roll constraints with 50% weight.
    private func synthesizeTwistConstraints(humanoid: VRMHumanoid) -> [VRMNodeConstraint] {
        var constraints: [VRMNodeConstraint] = []

        // VRM 0.0 (Unity) uses a right-handed -Z forward system; VRM 1.0 / glTF uses +Z forward.
        // The model root is rotated 180° around Y to compensate, which maps local +X → local -X.
        // Arm twist axes that were +X in VRM 0.0 space become -X in VRM 1.0 space.
        // Y-aligned axes (legs) are unaffected by a Y rotation and keep their sign.
        let twistPairs: [(parent: VRMHumanoidBone, twist: VRMHumanoidBone, axis: SIMD3<Float>)] = [
            // Upper arm twist bones: VRM 0.0 +X → VRM 1.0 -X
            (.leftUpperArm, .leftUpperArmTwist, SIMD3<Float>(-1, 0, 0)),
            (.rightUpperArm, .rightUpperArmTwist, SIMD3<Float>(-1, 0, 0)),
            // Lower arm twist bones: VRM 0.0 +X → VRM 1.0 -X
            (.leftLowerArm, .leftLowerArmTwist, SIMD3<Float>(-1, 0, 0)),
            (.rightLowerArm, .rightLowerArmTwist, SIMD3<Float>(-1, 0, 0)),
            // Upper leg twist bones: Y axis is unchanged by 180° Y rotation
            (.leftUpperLeg, .leftUpperLegTwist, SIMD3<Float>(0, 1, 0)),
            (.rightUpperLeg, .rightUpperLegTwist, SIMD3<Float>(0, 1, 0)),
            // Lower leg twist bones: Y axis is unchanged by 180° Y rotation
            (.leftLowerLeg, .leftLowerLegTwist, SIMD3<Float>(0, 1, 0)),
            (.rightLowerLeg, .rightLowerLegTwist, SIMD3<Float>(0, 1, 0)),
        ]

        for (parentBone, twistBone, axis) in twistPairs {
            if let parentNode = humanoid.getBoneNode(parentBone),
               let twistNode = humanoid.getBoneNode(twistBone) {
                let constraint = VRMNodeConstraint(
                    targetNode: twistNode,
                    constraint: .roll(sourceNode: parentNode, axis: axis, weight: 0.5)
                )
                constraints.append(constraint)
                vrmLog("[VRMExtensionParser] Synthesized twist constraint: \(twistBone) <- \(parentBone), weight=0.5")
            }
        }

        if !constraints.isEmpty {
            vrmLog("[VRMExtensionParser] Synthesized \(constraints.count) twist constraints for VRM 0.0")
        }

        return constraints
    }
}