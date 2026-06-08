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

/// VRM specification version detected for a loaded model.
///
/// VRM 0.0 (Unity left-handed) and VRM 1.0 (glTF right-handed) are both
/// loadable; ``VRMModel`` converts 0.0 content on the fly. 1.1 is reserved
/// for future spec additions.
public enum VRMSpecVersion: String {
    /// VRM 0.0 — Unity-era left-handed format. Loaded with on-the-fly conversion to 1.0 semantics.
    case v0_0 = "0.0"
    /// VRM 1.0 — current glTF-based specification. Default target format.
    case v1_0 = "1.0"
    /// VRM 1.1 — reserved for forward-compatible spec extensions.
    case v1_1 = "1.1"
}

// MARK: - Humanoid Bones

/// Standard humanoid bones defined by the VRM 1.0 humanoid spec.
///
/// The case set mirrors the VRM 1.0 humanoid bone vocabulary plus the
/// VRM 0.0 twist-bone names that VRMMetalKit synthesizes during loading.
/// ``isRequired`` indicates which bones VRM mandates for a valid avatar.
/// Spec: <https://github.com/vrm-c/vrm-specification/blob/master/specification/VRMC_vrm-1.0/humanoid.md>
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

    /// Returns `true` when this bone is required by the VRM humanoid spec for a valid avatar.
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

/// Standard VRM 1.0 expression preset identifiers.
///
/// The case set mirrors the VRM 1.0 expression preset vocabulary, organized
/// into emotion (happy/angry/…), viseme (aa/ih/…), blink and look-direction
/// presets. ``custom`` denotes any non-preset expression defined by the
/// model creator and stored under ``VRMExpressions/custom``.
/// Spec: <https://github.com/vrm-c/vrm-specification/blob/master/specification/VRMC_vrm-1.0/expressions.md>
public enum VRMExpressionPreset: String, CaseIterable, Sendable {
    /// Emotion preset — happy.
    case happy
    /// Emotion preset — angry.
    case angry
    /// Emotion preset — sad.
    case sad
    /// Emotion preset — relaxed.
    case relaxed
    /// Emotion preset — surprised.
    case surprised

    /// Viseme preset — "aa" mouth shape.
    case aa
    /// Viseme preset — "ih" mouth shape.
    case ih
    /// Viseme preset — "ou" mouth shape.
    case ou
    /// Viseme preset — "ee" mouth shape.
    case ee
    /// Viseme preset — "oh" mouth shape.
    case oh

    /// Both eyes blink simultaneously.
    case blink
    /// Left eye blinks only.
    case blinkLeft
    /// Right eye blinks only.
    case blinkRight
    /// Look-direction preset — upward gaze.
    case lookUp
    /// Look-direction preset — downward gaze.
    case lookDown
    /// Look-direction preset — leftward gaze.
    case lookLeft
    /// Look-direction preset — rightward gaze.
    case lookRight

    /// Neutral baseline expression with all morphs at rest.
    case neutral
    /// User-defined expression that is not covered by any preset above.
    case custom
}

/// A single VRM expression definition combining morph, material-color, and texture-transform bindings.
///
/// Maps the VRM 1.0 `expressions.preset` and `expressions.custom` entries
/// — see <https://github.com/vrm-c/vrm-specification/blob/master/specification/VRMC_vrm-1.0/expressions.md>.
/// `overrideBlink`, `overrideLookAt`, and `overrideMouth` control how this
/// expression interacts with auto-blink, look-at, and lip-sync drivers.
public struct VRMExpression {
    /// Custom expression name; `nil` for preset-only expressions.
    public var name: String?
    /// Preset identifier, or `nil` for pure custom expressions.
    public var preset: VRMExpressionPreset?
    /// Morph-target weights this expression applies.
    public var morphTargetBinds: [VRMMorphTargetBind] = []
    /// Material-color overrides this expression applies.
    public var materialColorBinds: [VRMMaterialColorBind] = []
    /// Texture-transform overrides this expression applies.
    public var textureTransformBinds: [VRMTextureTransformBind] = []
    /// When `true`, the expression weight is treated as a binary on/off rather than a continuous blend.
    public var isBinary: Bool = false
    /// How this expression interacts with the auto-blink driver.
    public var overrideBlink: VRMExpressionOverrideType = .none
    /// How this expression interacts with the look-at driver.
    public var overrideLookAt: VRMExpressionOverrideType = .none
    /// How this expression interacts with mouth (viseme) drivers.
    public var overrideMouth: VRMExpressionOverrideType = .none

    /// Creates an expression with an optional custom name and preset identifier.
    public init(name: String? = nil, preset: VRMExpressionPreset? = nil) {
        self.name = name
        self.preset = preset
    }
}

/// A morph-target weight bound to a node/mesh by an expression. Mirrors VRM 1.0 `expression.morphTargetBinds`.
public struct VRMMorphTargetBind {
    /// Authored binding index as it appears in the source file: a glTF **node**
    /// index for VRM 1.0, a **mesh** index for VRM 0.x. Preserved verbatim so
    /// serialization round-trips the original value.
    public var node: Int
    /// Resolved **mesh** index the morph weight is keyed by (what the renderer
    /// and ``VRMExpressionController`` use). For VRM 0.x this equals ``node``;
    /// for VRM 1.0 the loader resolves `node → nodes[node].mesh`.
    public var meshIndex: Int
    /// Morph-target index within the mesh.
    public var index: Int
    /// Weight applied when this expression is fully active (typically `0.0...1.0`).
    public var weight: Float

    /// Creates a morph-target binding. `meshIndex` defaults to `node` (correct
    /// for VRM 0.x, where the authored index is already a mesh index); the VRM
    /// 1.0 loader overrides it with the resolved mesh index.
    public init(node: Int, index: Int, weight: Float, meshIndex: Int? = nil) {
        self.node = node
        self.index = index
        self.weight = weight
        self.meshIndex = meshIndex ?? node
    }
}

/// A material-color override bound to a material by an expression. Mirrors VRM 1.0 `expression.materialColorBinds`.
public struct VRMMaterialColorBind {
    /// Material index in the glTF document.
    public var material: Int
    /// Which color channel of the material this bind targets.
    public var type: VRMMaterialColorType
    /// Linear-space RGBA target value reached at full expression weight.
    public var targetValue: SIMD4<Float>

    /// Creates a material-color override binding.
    public init(material: Int, type: VRMMaterialColorType, targetValue: SIMD4<Float>) {
        self.material = material
        self.type = type
        self.targetValue = targetValue
    }
}

/// Material color channels addressable by ``VRMMaterialColorBind``. Maps to VRM 1.0 expression color targets.
public enum VRMMaterialColorType: String {
    /// PBR base color / albedo.
    case color
    /// Emission color.
    case emissionColor
    /// MToon shade (shadow-side) color.
    case shadeColor
    /// MToon matcap color factor.
    case matcapColor
    /// MToon parametric rim color.
    case rimColor
    /// MToon outline color.
    case outlineColor
}

/// A UV transform override bound to a material by an expression. Mirrors VRM 1.0 `expression.textureTransformBinds`.
public struct VRMTextureTransformBind {
    /// Material index in the glTF document.
    public var material: Int
    /// UV scale override at full expression weight, or `nil` to leave unchanged.
    public var scale: SIMD2<Float>?
    /// UV offset override at full expression weight, or `nil` to leave unchanged.
    public var offset: SIMD2<Float>?

    /// Creates a UV transform binding.
    public init(material: Int, scale: SIMD2<Float>? = nil, offset: SIMD2<Float>? = nil) {
        self.material = material
        self.scale = scale
        self.offset = offset
    }
}

/// How an expression interacts with automatic blink, look-at, and mouth drivers. Mirrors VRM 1.0 `override*` fields.
public enum VRMExpressionOverrideType: String {
    /// No interaction — the auto-driver continues to apply.
    case none
    /// Suppress the auto-driver while this expression is active.
    case block
    /// Blend the expression with the auto-driver value (driver scaled down by expression weight).
    case blend
}

// MARK: - LookAt Types

/// Method used to drive an avatar's eye gaze. Mirrors VRM 1.0 `lookAt.type`.
public enum VRMLookAtType: String {
    /// Eye gaze is driven by rotating the eye bones.
    case bone
    /// Eye gaze is driven by blending the ``VRMExpressionPreset/lookUp``, ``VRMExpressionPreset/lookDown``, ``VRMExpressionPreset/lookLeft``, and ``VRMExpressionPreset/lookRight`` expressions.
    case expression
}

/// Piecewise-linear mapping from a yaw/pitch angle (degrees) to an eye-bone rotation or expression weight.
///
/// Defined by the VRM 1.0 look-at spec: input in `0...inputMaxValue` maps
/// linearly to output in `0...outputScale`. Values above `inputMaxValue`
/// are clamped to `outputScale`.
public struct VRMLookAtRangeMap {
    /// Maximum input angle in degrees beyond which the output is clamped.
    public var inputMaxValue: Float
    /// Output value reached when the input equals ``inputMaxValue``.
    public var outputScale: Float

    /// Creates a range map. Defaults match the VRM 1.0 reference: 90° input fully drives the gaze.
    public init(inputMaxValue: Float = 90.0, outputScale: Float = 1.0) {
        self.inputMaxValue = inputMaxValue
        self.outputScale = outputScale
    }
}

// MARK: - First Person

/// First-person visibility flag for a mesh annotation. Mirrors VRM 1.0 `firstPerson.meshAnnotations[].type`.
public enum VRMFirstPersonFlag: String {
    /// Automatically hide if the mesh is parented to the head, otherwise show.
    case auto
    /// Visible in both first-person and third-person views.
    case both
    /// Visible only in first-person view (e.g. eyelashes).
    case firstPersonOnly
    /// Visible only in third-person view (e.g. head mesh occluding the first-person camera).
    case thirdPersonOnly
}

// MARK: - Meta Information

/// VRM 1.0 metadata: author identity, distribution rights, and usage permissions.
///
/// Applications that publish, share, or transform VRM models are expected
/// to honor these fields. Spec:
/// <https://github.com/vrm-c/vrm-specification/blob/master/specification/VRMC_vrm-1.0/meta.md>
public struct VRMMeta {
    /// Display title of the avatar.
    public var name: String?
    /// Avatar version string supplied by the creator.
    public var version: String?
    /// Authors / creator credits.
    public var authors: [String] = []
    /// Copyright statement.
    public var copyrightInformation: String?
    /// Contact information for the creator.
    public var contactInformation: String?
    /// External reference URLs (portfolios, project pages).
    public var references: [String] = []
    /// Acknowledgment of third-party assets bundled with this avatar.
    public var thirdPartyLicenses: String?
    /// Index into ``VRMModel/textures`` for the thumbnail image, if present.
    public var thumbnailImage: Int?
    /// Required license URL — points to the canonical license document.
    public var licenseUrl: String
    /// Who may impersonate / wear this avatar.
    public var avatarPermission: VRMAvatarPermission?
    /// Allowed commercial usage tier.
    public var commercialUsage: VRMCommercialUsage?
    /// Whether end users must visibly credit the creator.
    public var creditNotation: VRMCreditNotation?
    /// Whether redistribution of the unmodified asset is allowed.
    public var allowRedistribution: Bool?
    /// Whether and how the asset may be modified.
    public var modify: VRMModifyPermission?
    /// Additional license URL for asset-specific terms.
    public var otherLicenseUrl: String?
    /// Author opt-in for excessively violent usage.
    public var allowExcessivelyViolentUsage: Bool?
    /// Author opt-in for excessively sexual usage.
    public var allowExcessivelySexualUsage: Bool?
    /// Author opt-in for political or religious usage.
    public var allowPoliticalOrReligiousUsage: Bool?
    /// Author opt-in for antisocial or hate-related usage.
    public var allowAntisocialOrHateUsage: Bool?

    /// Returns ``allowExcessivelyViolentUsage`` defaulting to `false` when the author left it unset.
    public var allowExcessivelyViolentUsageOrDefault: Bool { allowExcessivelyViolentUsage ?? false }
    /// Returns ``allowExcessivelySexualUsage`` defaulting to `false` when the author left it unset.
    public var allowExcessivelySexualUsageOrDefault: Bool { allowExcessivelySexualUsage ?? false }
    /// Returns ``allowPoliticalOrReligiousUsage`` defaulting to `false` when the author left it unset.
    public var allowPoliticalOrReligiousUsageOrDefault: Bool { allowPoliticalOrReligiousUsage ?? false }
    /// Returns ``allowAntisocialOrHateUsage`` defaulting to `false` when the author left it unset.
    public var allowAntisocialOrHateUsageOrDefault: Bool { allowAntisocialOrHateUsage ?? false }

    /// Creates a `VRMMeta` with the spec-required ``licenseUrl``.
    public init(licenseUrl: String) {
        self.licenseUrl = licenseUrl
    }
}

/// Who is permitted to wear / impersonate this avatar. Mirrors VRM 1.0 `meta.avatarPermission`.
public enum VRMAvatarPermission: String {
    /// Only the original author may use the avatar.
    case onlyAuthor
    /// Only persons separately licensed by the author may use the avatar.
    case onlySeparatelyLicensedPerson
    /// Anyone may use the avatar.
    case everyone
}

/// Allowed commercial-usage tier for an avatar. Mirrors VRM 1.0 `meta.commercialUsage`.
public enum VRMCommercialUsage: String {
    /// Personal, non-profit use only.
    case personalNonProfit
    /// Personal use including profit-making activity.
    case personalProfit
    /// Use by corporate / legal entities permitted.
    case corporation
}

/// Whether the avatar requires visible creator credit. Mirrors VRM 1.0 `meta.creditNotation`.
public enum VRMCreditNotation: String {
    /// Users must visibly credit the creator.
    case required
    /// Crediting the creator is optional.
    case unnecessary
}

/// Whether and how the asset may be modified. Mirrors VRM 1.0 `meta.modify`.
public enum VRMModifyPermission: String {
    /// Modification is forbidden.
    case prohibited
    /// Modification is allowed but redistribution of the modified asset is not.
    case allowModification
    /// Both modification and redistribution of the modified asset are allowed.
    case allowModificationRedistribution
}

// MARK: - VRM 0.x Material Properties

/// VRM 0.x MToon material property bag, indexed by Unity shader property names.
///
/// VRM 0.x stores MToon parameters in a document-level `materialProperties`
/// array keyed by Unity property names (`_MainTex`, `_ShadeColor`, …). Use
/// ``toMToonMaterial()`` to convert to the VRM 1.0 ``VRMMToonMaterial``
/// structure that the renderer consumes.
public struct VRM0MaterialProperty {
    /// Material display name.
    public var name: String?
    /// Unity shader identifier (e.g. `"VRM/MToon"`).
    public var shader: String?
    /// Unity render-queue override.
    public var renderQueue: Int?

    /// Float-valued material parameters keyed by Unity property name.
    public var floatProperties: [String: Float] = [:]

    /// Vector-valued material parameters keyed by Unity property name.
    public var vectorProperties: [String: [Float]] = [:]

    /// Texture indices keyed by Unity property name.
    public var textureProperties: [String: Int] = [:]

    /// Unity shader keyword flags.
    public var keywordMap: [String: Bool] = [:]
    /// Unity shader tag values.
    public var tagMap: [String: String] = [:]

    /// Creates an empty VRM 0.x material property bag.
    public init() {}

    /// Helper to convert sRGB color value to linear (gamma decoding)
    private func sRGBToLinear(_ value: Float) -> Float {
        // Standard sRGB to linear conversion
        return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    /// Converts these VRM 0.x material properties into a VRM 1.0 ``VRMMToonMaterial``.
    ///
    /// Mirrors the three-vrm `VRMMaterialsV0CompatPlugin` transformations:
    /// applies sRGB→linear conversion for colors, the toony/shift interdependent
    /// remap, outline-width cm→normalized scaling, and the Y-axis flip for
    /// UV-animation scroll. `_IndirectLightIntensity` is deliberately dropped
    /// (semantics differ from MToon 1.0 `giEqualizationFactor`).
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

        // VRM 0.x -> VRM 1.0 shading transformation (from three-vrm).
        // The shader consumes VRM 1.0-style raw-NdotL ramp parameters for both
        // source versions; do not apply Half-Lambert again in MSL after this.
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

        // Shade texture from texture properties. Bind unconditionally — Unity
        // MToon and three-vrm's V0CompatPlugin always multiply shadeColorFactor
        // by the shade texture, including the common VRM 0.x case of
        // `_ShadeTexture == _MainTex`. Skipping that case leaves the shadow side
        // using the bare factor (typically `[1,1,1]` white), washing out
        // dark-textured materials like hair.
        if let shadeTexIndex = textureProperties["_ShadeTexture"] {
            mtoon.shadeMultiplyTexture = shadeTexIndex
        }

        // VRM 0.x's `_IndirectLightIntensity` is an intensity scalar, semantically
        // different from MToon 1.0's `giEqualizationFactor` (a directional-mix
        // factor; see docs/MTOON_GI_SPEC.md). We intentionally do not auto-convert;
        // VRM 0.x models inherit the spec default (0.9) on load. Authored 0.x intent
        // can be re-applied at the application layer if needed. Logging here so
        // developers can detect when authored values are being dropped.
        if let dropped = floatProperties["_IndirectLightIntensity"] {
            vrmLog("[VRMMToonMaterial] Dropping VRM 0.x `_IndirectLightIntensity = \(dropped)` — semantics differ from MToon 1.0 `giEqualizationFactor`; field inherits spec default 0.9. Re-apply at app layer if needed.")
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

/// MToon 1.0 non-photorealistic material parameters as defined by the `VRMC_materials_mtoon` extension.
///
/// Linear-space color factors, normalized outline width, and texture indices
/// into ``VRMModel/textures``. Defaults match the three-vrm reference
/// implementation. Spec:
/// <https://github.com/vrm-c/vrm-specification/blob/master/specification/VRMC_materials_mtoon-1.0/README.md>
public struct VRMMToonMaterial {
    /// Linear-space shade (shadow-side) color factor.
    public var shadeColorFactor: SIMD3<Float> = [0.0, 0.0, 0.0]
    /// Optional texture index multiplying ``shadeColorFactor`` per-pixel.
    public var shadeMultiplyTexture: Int?
    /// Toon shading shift along the raw-NdotL axis; negative values widen the lit area.
    /// VRM 0.x inputs are converted to this VRM 1.0 parameter space on load.
    public var shadingShiftFactor: Float = 0.0
    /// Optional texture providing a per-pixel shading-shift override.
    public var shadingShiftTexture: VRMShadingShiftTexture?
    /// Toon shading hardness in `0...1`; higher values produce sharper toon edges.
    public var shadingToonyFactor: Float = 0.9
    /// Global-illumination equalization factor.
    public var giEqualizationFactor: Float = 0.9
    /// Linear-space matcap factor; white by default so a matcap texture multiplies cleanly.
    public var matcapFactor: SIMD3<Float> = [1.0, 1.0, 1.0]
    /// Optional matcap texture index (additive).
    public var matcapTexture: Int?
    /// Linear-space parametric rim color; black disables rim lighting.
    public var parametricRimColorFactor: SIMD3<Float> = [0.0, 0.0, 0.0]
    /// Fresnel exponent for parametric rim; higher values produce narrower rim edges.
    public var parametricRimFresnelPowerFactor: Float = 5.0
    /// Constant lift added to the rim term, brightening it uniformly.
    public var parametricRimLiftFactor: Float = 0.0
    /// Optional texture index multiplying the rim term.
    public var rimMultiplyTexture: Int?
    /// Mix factor between unlit rim and lit-scene contribution.
    public var rimLightingMixFactor: Float = 1.0
    /// Outline width interpretation (world or screen space). See ``VRMOutlineWidthMode``.
    public var outlineWidthMode: VRMOutlineWidthMode = .none
    /// Outline width in normalized units (mode-dependent).
    public var outlineWidthFactor: Float = 0.0
    /// Optional linear R8 mask texture modulating outline width per-pixel.
    public var outlineWidthMultiplyTexture: Int?
    /// Linear-space outline color factor.
    public var outlineColorFactor: SIMD3<Float> = [0.0, 0.0, 0.0]
    /// Mix factor between flat outline color and scene-lit outline color.
    public var outlineLightingMixFactor: Float = 1.0
    /// Optional linear R8 mask texture gating UV animation per-pixel.
    public var uvAnimationMaskTexture: Int?
    /// UV scroll speed along the X axis.
    public var uvAnimationScrollXSpeedFactor: Float = 0.0
    /// UV scroll speed along the Y axis.
    public var uvAnimationScrollYSpeedFactor: Float = 0.0
    /// UV rotation speed in revolutions per second.
    public var uvAnimationRotationSpeedFactor: Float = 0.0
    /// Optional `KHR_texture_transform` applied to all texture lookups.
    public var textureTransform: GLTFKHRTextureTransform?

    /// Creates an MToon material with spec-default values.
    public init() {}
}

/// MToon shading-shift texture reference. Provides a per-pixel override on top of ``VRMMToonMaterial/shadingShiftFactor``.
public struct VRMShadingShiftTexture {
    /// Index into ``VRMModel/textures``.
    public var index: Int
    /// Optional UV channel selector (`TEXCOORD_n`).
    public var texCoord: Int?
    /// Optional per-texel scale factor applied to the sampled shift.
    public var scale: Float?

    /// Creates a shading-shift texture reference.
    public init(index: Int, texCoord: Int? = nil, scale: Float? = nil) {
        self.index = index
        self.texCoord = texCoord
        self.scale = scale
    }
}

/// MToon outline width interpretation. Mirrors VRM 1.0 `mtoon.outlineWidthMode`.
public enum VRMOutlineWidthMode: String {
    /// Outline rendering disabled.
    case none
    /// Outline width is measured in world-space units (meters).
    case worldCoordinates
    /// Outline width is measured in screen-space units (pixels), scaled by ``VRMMToonMaterial/outlineWidthFactor``.
    case screenCoordinates
}

// MARK: - SpringBone Types

/// Top-level spring-bone configuration for an avatar.
///
/// Aggregates colliders, collider groups, and spring chains. Mirrors the
/// VRM 1.0 `VRMC_springBone` extension. Simulation is executed on the GPU
/// at fixed substeps; see ``VRMConstants/Physics``.
public struct VRMSpringBone {
    /// Source spec version string (e.g. `"1.0"`).
    public var specVersion: String = "1.0"
    /// All colliders referenced by this avatar.
    public var colliders: [VRMCollider] = []
    /// Procedurally synthesized colliders (issue #309). Additive to `colliders`;
    /// authored `colliders` is never mutated. Populated at load time when
    /// `VRMLoadingOptions.augmentSpringBoneColliders` is true, and consumed by
    /// both buffer allocation and collider upload.
    public var syntheticColliders: [VRMCollider] = []
    /// Named collections of colliders, referenced by ``VRMSpring/colliderGroups``.
    public var colliderGroups: [VRMColliderGroup] = []
    /// Spring chains driving hair, clothing, and accessories.
    public var springs: [VRMSpring] = []

    /// Creates an empty spring-bone configuration.
    public init() {}
}

/// A collider attached to a node, used to prevent spring chains from penetrating geometry.
public struct VRMCollider {
    /// Node index the collider is parented to.
    public var node: Int
    /// Local-space shape and dimensions.
    public var shape: VRMColliderShape

    /// Creates a node-anchored collider.
    public init(node: Int, shape: VRMColliderShape) {
        self.node = node
        self.shape = shape
    }
}

/// Geometric shape of a spring-bone collider in the parent node's local frame.
public enum VRMColliderShape {
    /// Sphere collider centered at `offset` with `radius`. Joints are pushed
    /// outside this sphere.
    case sphere(offset: SIMD3<Float>, radius: Float)
    /// Capsule from `offset` to `tail` with hemispherical caps of `radius`.
    /// Joints are pushed outside this capsule.
    case capsule(offset: SIMD3<Float>, radius: Float, tail: SIMD3<Float>)
    /// Infinite plane at `offset` with surface normal `normal`. Joints are
    /// pushed to the positive-normal side. Promoted from VMK-only to the spec
    /// via `VRMC_springBone_extended_collider-1.0`.
    case plane(offset: SIMD3<Float>, normal: SIMD3<Float>)
    /// Inverted sphere (containment collider) — joints are pushed *inside*
    /// the volume. From `VRMC_springBone_extended_collider-1.0.shape.sphere`
    /// with `inside: true`.
    case insideSphere(offset: SIMD3<Float>, radius: Float)
    /// Inverted capsule (containment collider) — joints are pushed *inside*
    /// the volume. From `VRMC_springBone_extended_collider-1.0.shape.capsule`
    /// with `inside: true`.
    case insideCapsule(offset: SIMD3<Float>, radius: Float, tail: SIMD3<Float>)
}

/// Named collection of colliders referenced by index from one or more springs.
public struct VRMColliderGroup {
    /// Optional display name for debugging.
    public var name: String?
    /// Indices into ``VRMSpringBone/colliders``.
    public var colliders: [Int] = []

    /// Creates a collider group.
    public init(name: String? = nil, colliders: [Int] = []) {
        self.name = name
        self.colliders = colliders
    }
}

/// A single spring chain: an ordered list of joints with optional collider groups and a center node.
public struct VRMSpring {
    /// Optional display name for debugging.
    public var name: String?
    /// Joints in parent-to-child order.
    public var joints: [VRMSpringJoint] = []
    /// Indices into ``VRMSpringBone/colliderGroups`` evaluated against this chain.
    public var colliderGroups: [Int] = []
    /// Optional node whose transform serves as the inertia-compensation reference (typically the hips).
    public var center: Int?

    /// Creates a spring chain.
    public init(name: String? = nil) {
        self.name = name
    }
}

/// Per-joint parameters of a spring chain. Mirrors VRM 1.0 `VRMC_springBone.joints`.
public struct VRMSpringJoint {
    /// Node index this joint drives.
    public var node: Int
    /// Collision radius for this joint.
    public var hitRadius: Float = 0.0
    /// Restoring-force stiffness in `0...1`; higher values keep the joint near its rest pose.
    public var stiffness: Float = 1.0
    /// Strength of the per-joint gravity term.
    public var gravityPower: Float = 0.0
    /// Direction of the per-joint gravity term in world space.
    public var gravityDir: SIMD3<Float> = [0, -1, 0]
    /// Linear damping in `0...1`; higher values dampen joint motion more aggressively.
    public var dragForce: Float = 0.4
    /// Maximum swing angle from the joint's bind direction, stored in **radians**.
    /// Sourced from `VRMC_springBone_extended_collider.angleLimit`, which the
    /// loader interprets as degrees in the file (per conformance-fixture
    /// convention; the 1.0 spec does not pin a unit) and converts on parse.
    /// `0` (default) means no limit — the joint swings freely.
    public var angleLimit: Float = 0.0

    /// Creates a spring-bone joint bound to the given node.
    public init(node: Int) {
        self.node = node
    }
}
