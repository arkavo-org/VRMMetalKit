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

public class VRMExtensionParser {

    public init() {}

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
        } else {
            // If no version field but has VRM 0.0 structure, assume 0.0
            specVersion = .v0_0
        }

        // Parse meta (required)
        guard let metaDict = vrmDict["meta"] as? [String: Any] else {
            vrmLog("[VRMExtensionParser] Missing or invalid meta dictionary")
            throw VRMError.invalidJSON(
                context: "VRM extension 'meta' field",
                underlyingError: "Missing or not a dictionary. VRM models require metadata including name, version, author, etc.",
                filePath: filePath
            )
        }
        vrmLog("[VRMExtensionParser] Found meta with keys: \(metaDict.keys)")
        let meta = try parseMeta(metaDict)

        // Parse humanoid (required)
        guard let humanoidDict = vrmDict["humanoid"] as? [String: Any] else {
            vrmLog("[VRMExtensionParser] Missing or invalid humanoid dictionary")
            throw VRMError.invalidJSON(
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

    private func parseMeta(_ dict: [String: Any]) throws -> VRMMeta {
        // VRM 1.0 uses "licenseUrl", VRM 0.0 uses "otherLicenseUrl"
        let licenseUrl = (dict["licenseUrl"] as? String) ??
                        (dict["otherLicenseUrl"] as? String) ??
                        ""

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

        // Handle VRM 0.0 firstPersonBoneOffset
        if let offsetDict = dict["firstPersonBoneOffset"] as? [String: Any],
           let x = offsetDict["x"] as? Double,
           let y = offsetDict["y"] as? Double,
           let z = offsetDict["z"] as? Double {
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

        // VRM 0.0 uses xRange for input and yRange for output
        if let xRange = dict["xRange"] as? Double {
            rangeMap.inputMaxValue = Float(xRange)
        } else if let xRange = dict["xRange"] as? Float {
            rangeMap.inputMaxValue = xRange
        }

        if let yRange = dict["yRange"] as? Double {
            rangeMap.outputScale = Float(yRange)
        } else if let yRange = dict["yRange"] as? Float {
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

        if let offset = dict["offsetFromHeadBone"] as? [Float], offset.count == 3 {
            lookAt.offsetFromHeadBone = SIMD3<Float>(offset[0], offset[1], offset[2])
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

        if let inputMaxValue = dict["inputMaxValue"] as? Float {
            rangeMap.inputMaxValue = inputMaxValue
        }

        if let outputScale = dict["outputScale"] as? Float {
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
                      let index = bind["index"] as? Int,
                      let weight = bind["weight"] as? Float else {
                    continue
                }

                expression.morphTargetBinds.append(
                    VRMMorphTargetBind(node: node, index: index, weight: weight)
                )
            }
        }

        if let materialColorBinds = dict["materialColorBinds"] as? [[String: Any]] {
            for bind in materialColorBinds {
                guard let material = bind["material"] as? Int,
                      let typeStr = bind["type"] as? String,
                      let type = VRMMaterialColorType(rawValue: typeStr),
                      let targetValue = bind["targetValue"] as? [Float],
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
            for colliderDict in colliders {
                guard let node = colliderDict["node"] as? Int,
                      let shapeDict = colliderDict["shape"] as? [String: Any] else {
                    continue
                }

                if let shape = parseColliderShape(shapeDict) {
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
                        joint.hitRadius = jointDict["hitRadius"] as? Float ?? 0.0
                        joint.stiffness = jointDict["stiffness"] as? Float ?? 1.0
                        // Apply minimum gravityPower of 1.0 when model specifies 0
                        let rawGravityPower = jointDict["gravityPower"] as? Float ?? 0.0
                        joint.gravityPower = rawGravityPower > 0 ? rawGravityPower : 1.0
                        joint.dragForce = jointDict["dragForce"] as? Float ?? 0.4

                        if let gravityDir = jointDict["gravityDir"] as? [Float], gravityDir.count == 3 {
                            joint.gravityDir = SIMD3<Float>(gravityDir[0], gravityDir[1], gravityDir[2])
                        }

                        spring.joints.append(joint)
                    }
                }

                springBone.springs.append(spring)
            }
        }

        return springBone
    }

    private func parseColliderShape(_ dict: [String: Any]) -> VRMColliderShape? {
        if let sphereDict = dict["sphere"] as? [String: Any] {
            let offset = parseVector3(sphereDict["offset"]) ?? SIMD3<Float>(0, 0, 0)
            let radius = parseFloatValue(sphereDict["radius"]) ?? 0.0
            return .sphere(offset: offset, radius: radius)
        } else if let capsuleDict = dict["capsule"] as? [String: Any] {
            let offset = parseVector3(capsuleDict["offset"]) ?? SIMD3<Float>(0, 0, 0)
            let radius = parseFloatValue(capsuleDict["radius"]) ?? 0.0
            let tail = parseVector3(capsuleDict["tail"]) ?? SIMD3<Float>(0, 0, 0)
            return .capsule(offset: offset, radius: radius, tail: tail)
        }

        return nil
    }

    private func parseFloatValue(_ value: Any?) -> Float? {
        if let floatVal = value as? Float {
            return floatVal
        } else if let doubleVal = value as? Double {
            return Float(doubleVal)
        } else if let numVal = value as? NSNumber {
            return numVal.floatValue
        }
        return nil
    }

    private func parseVector3(_ value: Any?) -> SIMD3<Float>? {
        guard let array = value as? [Float], array.count == 3 else {
            return nil
        }
        return SIMD3<Float>(array[0], array[1], array[2])
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

                        // Apply minimum gravityPower of 1.0 when model specifies 0
                        // Many VRM 0.x models have gravityPower=0 but expect gravity to work
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

                        // Gravity direction
                        if let gravityDir = groupDict["gravityDir"] as? [String: Any] {
                            let x = gravityDir["x"] as? Float ?? 0
                            let y = gravityDir["y"] as? Float ?? -1
                            let z = gravityDir["z"] as? Float ?? 0
                            joint.gravityDir = SIMD3<Float>(x, y, z)
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

                        // VRM 0.0 collider format
                        let offset = parseVRM0Vector3(colliderDict["offset"]) ?? SIMD3<Float>(0, 0, 0)
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

        return springBone
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
}