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

/// Errors specific to VRM extension handling on top of glTF 2.0.
///
/// glTF-spec errors (invalid JSON, missing buffer, accessor, texture, mesh
/// problems, etc.) are surfaced as ``GLTFError`` from `GLTFCore`. This enum
/// covers VRM extension layer failures only.
public enum VRMError: Error {
    /// The file does not contain a `VRMC_vrm` (1.0) or `VRM` (0.0) extension.
    case missingVRMExtension(filePath: String?, suggestion: String)

    /// A humanoid bone required by the VRM spec is absent from the humanoid mapping.
    case missingRequiredBone(bone: VRMHumanoidBone, availableBones: [String], filePath: String?)

    /// The VRM meta block fails validation (e.g. missing required `licenseUrl` on 1.0).
    case invalidMeta(String)

    /// A document resource exceeded a configured ``VRMLoaderLimits`` quota.
    case limitExceeded(kind: String, limit: Int, observed: Int)

    /// A VRMA animation file parsed structurally but contains zero playable tracks.
    case emptyAnimation(filePath: String?, channelCount: Int, samplerCount: Int, duration: Float)

    /// Rigid attachment was called with a skinned cosmetic asset without opting into rigidification.
    case unsupportedSkinnedAttachment(assetName: String?, skinCount: Int)

    /// The requested humanoid anchor bone does not exist on the target avatar.
    case anchorBoneNotFound(bone: VRMHumanoidBone)

    /// Combined host and cosmetic SpringBone authored collider groups exceed the 32-bit mask budget.
    case colliderGroupLimitExceeded(limit: Int, observed: Int)

    /// A live mutation performed through ``VRMModelEditor`` received invalid indices, counts, or device state.
    case invalidEdit(String)
}

extension VRMError: LocalizedError {
    /// Returns a multi-line, LLM-friendly description: what went wrong, where, a suggested fix, and a spec URL.
    public var errorDescription: String? {
        switch self {
        case .missingVRMExtension(let filePath, let suggestion):
            let fileInfo = filePath.map { " in file '\($0)'" } ?? ""
            return """
            ❌ Missing VRM Extension

            The file\(fileInfo) does not contain a valid VRMC_vrm extension. This is required for VRM 1.0 models.

            Suggestion: \(suggestion)

            VRM Spec: https://github.com/vrm-c/vrm-specification/blob/master/specification/VRMC_vrm-1.0/
            """

        case .missingRequiredBone(let bone, let availableBones, let filePath):
            let fileInfo = filePath.map { " in file '\($0)'" } ?? ""
            let bonesListStr = availableBones.isEmpty ? "(none)" : availableBones.joined(separator: ", ")
            return """
            ❌ Missing Required Humanoid Bone: '\(bone.rawValue)'

            The VRM model\(fileInfo) is missing the required humanoid bone '\(bone.rawValue)'.
            Available bones: \(bonesListStr)

            Suggestion: Ensure your 3D model has a bone for '\(bone.rawValue)' and that it's properly mapped in the VRM humanoid configuration. Common bone names include: Hips, Spine, Chest, Neck, Head, LeftUpperArm, RightUpperArm, etc.

            VRM Spec: https://github.com/vrm-c/vrm-specification/blob/master/specification/VRMC_vrm-1.0/humanoid.md
            """

        case .invalidMeta(let reason):
            return """
            ❌ Invalid VRM Meta

            Reason: \(reason)

            Suggestion: Ensure the VRM model's meta block includes all required fields. For VRM 1.0, 'licenseUrl' is required by the VRMC_vrm spec.

            VRM Spec: https://github.com/vrm-c/vrm-specification/blob/master/specification/VRMC_vrm-1.0/meta.md
            """

        case .limitExceeded(let kind, let limit, let observed):
            return """
            ❌ VRM Loader Limit Exceeded: '\(kind)'

            Observed \(kind): \(observed)
            Configured limit: \(limit)

            Suggestion: Reject untrusted files that exceed memory or structural quotas, or pass a higher `VRMLoaderLimits` (such as `.permissive` or a custom value) to `VRMModel.load` / `VRMAnimationLoader.loadVRMA` if this file is trusted.

            VRM Spec: https://github.com/vrm-c/vrm-specification/blob/master/specification/VRMC_vrm-1.0/README.md
            """

        case .emptyAnimation(let filePath, let channelCount, let samplerCount, let duration):
            let fileInfo = filePath.map { " in file '\($0)'" } ?? ""
            return """
            ❌ Empty VRMA Animation\(fileInfo)

            The VRMA file parsed as valid glTF but contains 0 playable tracks (channels: \(channelCount), samplers: \(samplerCount), duration: \(duration)s).

            Suggestion: Re-export the animation from the capture or authoring tool and verify that at least one humanoid bone, expression, or lookAt channel has non-empty keyframes.

            VRM Spec: https://github.com/vrm-c/vrm-specification/blob/master/specification/VRMC_vrm_animation-1.0/README.md
            """

        case .unsupportedSkinnedAttachment(let assetName, let skinCount):
            let label = assetName ?? "unnamed cosmetic asset"
            return """
            ❌ Skinned Cosmetic Passed to Rigid Attach

            Asset '\(label)' contains \(skinCount) skin(s) and cannot be attached rigidly via `attach(_:to:options:)` by default.

            Suggestion: Call `attachSkinned(_:options:)` to remap the garment onto the avatar's skeleton, or pass `VRMAttachmentOptions(rigidifySkinnedMeshes: true)` to explicitly strip skinning attributes and attach it rigidly.

            VRM Spec: https://github.com/vrm-c/vrm-specification/blob/master/specification/VRMC_vrm-1.0/humanoid.md
            """

        case .anchorBoneNotFound(let bone):
            return """
            ❌ Anchor Humanoid Bone Not Found: '\(bone.rawValue)'

            The target VRMModel has no valid node mapped to humanoid bone '\(bone.rawValue)'.

            Suggestion: Verify the avatar's `humanoid` mapping includes '\(bone.rawValue)', or attach directly to an explicit scene node via `attach(_:toNode:options:)`.

            VRM Spec: https://github.com/vrm-c/vrm-specification/blob/master/specification/VRMC_vrm-1.0/humanoid.md
            """

        case .colliderGroupLimitExceeded(let limit, let observed):
            return """
            ❌ SpringBone Collider Group Budget Exceeded

            Combined host and attached cosmetic authored collider groups (\(observed)) exceed the maximum supported count (\(limit)) within the 32-bit GPU collider group bitmask (slots 30–31 are reserved for cross-avatar foreign colliders and host synthetic swept-CCD colliders).

            Suggestion: Merge redundant collider groups in the cosmetic asset or detach unused physics accessories before attaching new ones.

            VRM Spec: https://github.com/vrm-c/vrm-specification/blob/master/specification/VRMC_springBone-1.0/README.md
            """

        case .invalidEdit(let reason):
            return """
            ❌ Invalid Live Model Edit

            Reason: \(reason)

            Suggestion: Verify mesh/primitive/node/skin indices, vertex count parity, and Metal device availability before mutating a VRMModel via `edit(_:)`.

            VRM Spec: https://github.com/vrm-c/vrm-specification/blob/master/specification/VRMC_vrm-1.0/README.md
            """
        }
    }
}
