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

// MARK: - VRM 1.0 Core Types

public enum VRMSpecVersion: String {
    case v0_0 = "0.0"
    case v1_0 = "1.0"
    case v1_1 = "1.1"
}

// MARK: - Humanoid Bones

public enum VRMHumanoidBone: String, CaseIterable, Sendable {
    // Required Torso
    case hips
    case spine
    case head

    // Optional Torso
    case chest
    case upperChest
    case neck

    // Required Arms
    case leftUpperArm
    case leftLowerArm
    case leftHand
    case rightUpperArm
    case rightLowerArm
    case rightHand

    // Optional Arms
    case leftShoulder
    case rightShoulder

    // Required Legs
    case leftUpperLeg
    case leftLowerLeg
    case leftFoot
    case rightUpperLeg
    case rightLowerLeg
    case rightFoot

    // Optional Legs
    case leftToes
    case rightToes

    // Twist Bones (VRM 0.0/1.0)
    case leftUpperArmTwist
    case rightUpperArmTwist
    case leftLowerArmTwist
    case rightLowerArmTwist
    case leftUpperLegTwist
    case rightUpperLegTwist
    case leftLowerLegTwist
    case rightLowerLegTwist

    // Optional Head
    case leftEye
    case rightEye
    case jaw

    // Fingers
    case leftThumbMetacarpal
    case leftThumbProximal
    case leftThumbDistal
    case leftIndexProximal
    case leftIndexIntermediate
    case leftIndexDistal
    case leftMiddleProximal
    case leftMiddleIntermediate
    case leftMiddleDistal
    case leftRingProximal
    case leftRingIntermediate
    case leftRingDistal
    case leftLittleProximal
    case leftLittleIntermediate
    case leftLittleDistal

    case rightThumbMetacarpal
    case rightThumbProximal
    case rightThumbDistal
    case rightIndexProximal
    case rightIndexIntermediate
    case rightIndexDistal
    case rightMiddleProximal
    case rightMiddleIntermediate
    case rightMiddleDistal
    case rightRingProximal
    case rightRingIntermediate
    case rightRingDistal
    case rightLittleProximal
    case rightLittleIntermediate
    case rightLittleDistal

    public var isRequired: Bool {
        switch self {
        case .hips, .spine, .head,
             .leftUpperArm, .leftLowerArm, .leftHand,
             .rightUpperArm, .rightLowerArm, .rightHand,
             .leftUpperLeg, .leftLowerLeg, .leftFoot,
             .rightUpperLeg, .rightLowerLeg, .rightFoot:
            return true
        default:
            return false
        }
    }
}

// MARK: - Expression Types

public enum VRMExpressionPreset: String, CaseIterable, Sendable {
    case happy
    case angry
    case sad
    case relaxed
    case surprised

    case aa
    case ih
    case ou
    case ee
    case oh

    case blink
    case blinkLeft
    case blinkRight
    case lookUp
    case lookDown
    case lookLeft
    case lookRight

    case neutral
    case custom  // VRM 1.0 spec: User-defined expressions not covered by standard presets
}

public struct VRMExpression {
    public var name: String?
    public var preset: VRMExpressionPreset?
    public var morphTargetBinds: [VRMMorphTargetBind] = []
    public var materialColorBinds: [VRMMaterialColorBind] = []
    public var textureTransformBinds: [VRMTextureTransformBind] = []
    public var isBinary: Bool = false
    public var overrideBlink: VRMExpressionOverrideType = .none
    public var overrideLookAt: VRMExpressionOverrideType = .none
    public var overrideMouth: VRMExpressionOverrideType = .none

    public init(name: String? = nil, preset: VRMExpressionPreset? = nil) {
        self.name = name
        self.preset = preset
    }
}

public struct VRMMorphTargetBind {
    public var node: Int
    public var index: Int
    public var weight: Float

    public init(node: Int, index: Int, weight: Float) {
        self.node = node
        self.index = index
        self.weight = weight
    }
}

public struct VRMMaterialColorBind {
    public var material: Int
    public var type: VRMMaterialColorType
    public var targetValue: SIMD4<Float>

    public init(material: Int, type: VRMMaterialColorType, targetValue: SIMD4<Float>) {
        self.material = material
        self.type = type
        self.targetValue = targetValue
    }
}

public enum VRMMaterialColorType: String {
    case color
    case emissionColor
    case shadeColor
    case matcapColor
    case rimColor
    case outlineColor
}

public struct VRMTextureTransformBind {
    public var material: Int
    public var scale: SIMD2<Float>?
    public var offset: SIMD2<Float>?

    public init(material: Int, scale: SIMD2<Float>? = nil, offset: SIMD2<Float>? = nil) {
        self.material = material
        self.scale = scale
        self.offset = offset
    }
}

public enum VRMExpressionOverrideType: String {
    case none
    case block
    case blend
}

// MARK: - LookAt Types

public enum VRMLookAtType: String {
    case bone
    case expression
}

public struct VRMLookAtRangeMap {
    public var inputMaxValue: Float
    public var outputScale: Float

    public init(inputMaxValue: Float = 90.0, outputScale: Float = 1.0) {
        self.inputMaxValue = inputMaxValue
        self.outputScale = outputScale
    }
}

// MARK: - First Person

public enum VRMFirstPersonFlag: String {
    case auto
    case both
    case firstPersonOnly
    case thirdPersonOnly
}

// MARK: - Meta Information

public struct VRMMeta {
    public var name: String?
    public var version: String?
    public var authors: [String] = []
    public var copyrightInformation: String?
    public var contactInformation: String?
    public var references: [String] = []
    public var thirdPartyLicenses: String?
    public var thumbnailImage: Int?
    public var licenseUrl: String
    public var avatarPermission: VRMAvatarPermission?
    public var commercialUsage: VRMCommercialUsage?
    public var creditNotation: VRMCreditNotation?
    public var allowRedistribution: Bool?
    public var modify: VRMModifyPermission?
    public var otherLicenseUrl: String?

    public init(licenseUrl: String) {
        self.licenseUrl = licenseUrl
    }
}

public enum VRMAvatarPermission: String {
    case onlyAuthor
    case onlySeparatelyLicensedPerson
    case everyone
}

public enum VRMCommercialUsage: String {
    case personalNonProfit
    case personalProfit
    case corporation
}

public enum VRMCreditNotation: String {
    case required
    case unnecessary
}

public enum VRMModifyPermission: String {
    case prohibited
    case allowModification
    case allowModificationRedistribution
}

// MARK: - VRM 0.x Material Properties

/// VRM 0.x stores MToon properties in materialProperties array at document level
public struct VRM0MaterialProperty {
    public var name: String?
    public var shader: String?
    public var renderQueue: Int?

    // Float properties (Unity shader property names)
    public var floatProperties: [String: Float] = [:]

    // Vector properties (Unity shader property names)
    public var vectorProperties: [String: [Float]] = [:]

    // Texture properties (Unity shader property names -> texture index)
    public var textureProperties: [String: Int] = [:]

    // Keyword flags
    public var keywordMap: [String: Bool] = [:]
    public var tagMap: [String: String] = [:]

    public init() {}

    /// Helper to convert sRGB color value to linear (gamma decoding)
    private func sRGBToLinear(_ value: Float) -> Float {
        // Standard sRGB to linear conversion
        return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    /// Convert VRM 0.x material properties to VRM 1.0 MToon structure
    /// Based on three-vrm VRMMaterialsV0CompatPlugin transformations
    public func toMToonMaterial() -> VRMMToonMaterial {
        var mtoon = VRMMToonMaterial()

        // Shade color from _ShadeColor vector property (sRGB to Linear conversion)
        if let shadeColor = vectorProperties["_ShadeColor"], shadeColor.count >= 3 {
            mtoon.shadeColorFactor = SIMD3<Float>(
                sRGBToLinear(shadeColor[0]),
                sRGBToLinear(shadeColor[1]),
                sRGBToLinear(shadeColor[2])
            )
        }

        // VRM 0.x -> VRM 1.0 shading transformation (from three-vrm)
        // These properties are interdependent:
        // shadingToonyFactor = lerp(shadeToony, 1.0, 0.5 + 0.5 * shadeShift)
        // shadingShiftFactor = -shadeShift - (1.0 - shadingToonyFactor)
        let shadeToony = floatProperties["_ShadeToony"] ?? 0.9
        let shadeShift = floatProperties["_ShadeShift"] ?? 0.0

        // Apply the VRM 0.x -> 1.0 transformation
        let lerpFactor = 0.5 + 0.5 * shadeShift
        let shadingToonyFactor = shadeToony * (1.0 - lerpFactor) + 1.0 * lerpFactor
        let shadingShiftFactor = -shadeShift - (1.0 - shadingToonyFactor)

        mtoon.shadingToonyFactor = shadingToonyFactor
        mtoon.shadingShiftFactor = shadingShiftFactor

        // Shade texture from texture properties
        if let shadeTexIndex = textureProperties["_ShadeTexture"] {
            mtoon.shadeMultiplyTexture = shadeTexIndex
        }

        // Global illumination: giEqualizationFactor = 1.0 - giIntensityFactor
        if let giIntensity = floatProperties["_IndirectLightIntensity"] {
            mtoon.giIntensityFactor = giIntensity
        }

        // Matcap/Sphere Add texture
        if let matcapIndex = textureProperties["_SphereAdd"] {
            mtoon.matcapTexture = matcapIndex
            mtoon.matcapFactor = SIMD3<Float>(1.0, 1.0, 1.0)  // White when texture exists
        }

        // Rim lighting (sRGB to Linear for color)
        if let rimColor = vectorProperties["_RimColor"], rimColor.count >= 3 {
            mtoon.parametricRimColorFactor = SIMD3<Float>(
                sRGBToLinear(rimColor[0]),
                sRGBToLinear(rimColor[1]),
                sRGBToLinear(rimColor[2])
            )
        }
        if let rimTexIndex = textureProperties["_RimTexture"] {
            mtoon.rimMultiplyTexture = rimTexIndex
        }
        if let rimPower = floatProperties["_RimFresnelPower"] {
            mtoon.parametricRimFresnelPowerFactor = rimPower
        }
        if let rimLift = floatProperties["_RimLift"] {
            mtoon.parametricRimLiftFactor = rimLift
        }
        if let rimMix = floatProperties["_RimLightingMix"] {
            mtoon.rimLightingMixFactor = rimMix
        }

        // Outline properties (width needs 0.01 multiplier for cm to normalized conversion)
        if let outlineWidth = floatProperties["_OutlineWidth"] {
            mtoon.outlineWidthFactor = outlineWidth * 0.01  // cm to normalized units
        }
        if let outlineTexIndex = textureProperties["_OutlineWidthTexture"] {
            mtoon.outlineWidthMultiplyTexture = outlineTexIndex
        }
        if let outlineMode = floatProperties["_OutlineWidthMode"] {
            switch Int(outlineMode) {
            case 1: mtoon.outlineWidthMode = .worldCoordinates
            case 2: mtoon.outlineWidthMode = .screenCoordinates
            default: mtoon.outlineWidthMode = .none
            }
        }
        if let outlineColor = vectorProperties["_OutlineColor"], outlineColor.count >= 3 {
            mtoon.outlineColorFactor = SIMD3<Float>(
                sRGBToLinear(outlineColor[0]),
                sRGBToLinear(outlineColor[1]),
                sRGBToLinear(outlineColor[2])
            )
        }
        // Outline lighting mix depends on color mode
        let outlineColorMode = floatProperties["_OutlineColorMode"] ?? 0.0
        if Int(outlineColorMode) == 1 {
            // Mixed mode: default to 1.0 if not specified
            mtoon.outlineLightingMixFactor = floatProperties["_OutlineLightingMix"] ?? 1.0
        } else {
            mtoon.outlineLightingMixFactor = floatProperties["_OutlineLightingMix"] ?? 0.0
        }

        // UV Animation (note: Y scroll is negated for V0->V1 conversion)
        if let uvMaskIndex = textureProperties["_UvAnimMaskTexture"] {
            mtoon.uvAnimationMaskTexture = uvMaskIndex
        }
        if let uvScrollX = floatProperties["_UvAnimScrollX"] {
            mtoon.uvAnimationScrollXSpeedFactor = uvScrollX
        }
        if let uvScrollY = floatProperties["_UvAnimScrollY"] {
            mtoon.uvAnimationScrollYSpeedFactor = -uvScrollY  // Negated for V0->V1
        }
        if let uvRotation = floatProperties["_UvAnimRotation"] {
            mtoon.uvAnimationRotationSpeedFactor = uvRotation
        }

        return mtoon
    }
}

// MARK: - Material Types

public struct VRMMToonMaterial {
    public var shadeColorFactor: SIMD3<Float> = [0.0, 0.0, 0.0]
    public var shadeMultiplyTexture: Int?
    public var shadingShiftFactor: Float = 0.0
    public var shadingShiftTexture: VRMShadingShiftTexture?
    public var shadingToonyFactor: Float = 0.9
    public var giIntensityFactor: Float = 0.05
    public var matcapFactor: SIMD3<Float> = [1.0, 1.0, 1.0]  // White default for texture multiplication
    public var matcapTexture: Int?
    public var parametricRimColorFactor: SIMD3<Float> = [0.0, 0.0, 0.0]  // Rim should start disabled
    public var parametricRimFresnelPowerFactor: Float = 5.0  // Higher = narrower rim edge
    public var parametricRimLiftFactor: Float = 0.0
    public var rimMultiplyTexture: Int?
    public var rimLightingMixFactor: Float = 0.0
    public var outlineWidthMode: VRMOutlineWidthMode = .none
    public var outlineWidthFactor: Float = 0.0
    public var outlineWidthMultiplyTexture: Int?
    public var outlineColorFactor: SIMD3<Float> = [0.0, 0.0, 0.0]  // Black default (matches three-vrm)
    public var outlineLightingMixFactor: Float = 1.0
    public var uvAnimationMaskTexture: Int?
    public var uvAnimationScrollXSpeedFactor: Float = 0.0
    public var uvAnimationScrollYSpeedFactor: Float = 0.0
    public var uvAnimationRotationSpeedFactor: Float = 0.0

    public init() {}
}

public struct VRMShadingShiftTexture {
    public var index: Int
    public var texCoord: Int?
    public var scale: Float?

    public init(index: Int, texCoord: Int? = nil, scale: Float? = nil) {
        self.index = index
        self.texCoord = texCoord
        self.scale = scale
    }
}

public enum VRMOutlineWidthMode: String {
    case none
    case worldCoordinates
    case screenCoordinates
}

// MARK: - SpringBone Types

public struct VRMSpringBone {
    public var specVersion: String = "1.0"
    public var colliders: [VRMCollider] = []
    public var colliderGroups: [VRMColliderGroup] = []
    public var springs: [VRMSpring] = []

    public init() {}
}

public struct VRMCollider {
    public var node: Int
    public var shape: VRMColliderShape

    public init(node: Int, shape: VRMColliderShape) {
        self.node = node
        self.shape = shape
    }
}

public enum VRMColliderShape {
    case sphere(offset: SIMD3<Float>, radius: Float)
    case capsule(offset: SIMD3<Float>, radius: Float, tail: SIMD3<Float>)
    case plane(offset: SIMD3<Float>, normal: SIMD3<Float>)
}

public struct VRMColliderGroup {
    public var name: String?
    public var colliders: [Int] = []

    public init(name: String? = nil, colliders: [Int] = []) {
        self.name = name
        self.colliders = colliders
    }
}

public struct VRMSpring {
    public var name: String?
    public var joints: [VRMSpringJoint] = []
    public var colliderGroups: [Int] = []
    public var center: Int?

    public init(name: String? = nil) {
        self.name = name
    }
}

public struct VRMSpringJoint {
    public var node: Int
    public var hitRadius: Float = 0.0
    public var stiffness: Float = 1.0
    public var gravityPower: Float = 0.0
    public var gravityDir: SIMD3<Float> = [0, -1, 0]
    public var dragForce: Float = 0.4

    public init(node: Int) {
        self.node = node
    }
}