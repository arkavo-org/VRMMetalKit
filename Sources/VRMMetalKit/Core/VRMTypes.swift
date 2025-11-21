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
    public var parametricRimFresnelPowerFactor: Float = 1.0
    public var parametricRimLiftFactor: Float = 0.0
    public var rimMultiplyTexture: Int?
    public var rimLightingMixFactor: Float = 0.0
    public var outlineWidthMode: VRMOutlineWidthMode = .none
    public var outlineWidthFactor: Float = 0.0
    public var outlineWidthMultiplyTexture: Int?
    public var outlineColorFactor: SIMD3<Float> = [1.0, 1.0, 1.0]  // White default for texture multiplication
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