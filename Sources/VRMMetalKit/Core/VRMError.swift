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
        }
    }
}
