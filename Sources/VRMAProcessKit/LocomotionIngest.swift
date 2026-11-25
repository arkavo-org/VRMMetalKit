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

/// The single-pass ingest pipeline from the locomotion spec §3:
/// normalize rest pose → measure → write extras → strip hips XZ →
/// strip non-humanoid (preserving expressions/lookAt) → strip constant eyes →
/// optional minimum arm abduction → loop-trim.
public enum LocomotionIngest {
    public enum Mode { case auto, idle, walk }
    /// Below this measured speed (m/s) a clip auto-classifies as idle.
    public static let idleThreshold: Float = 0.1

    public enum IngestError: Error, CustomStringConvertible {
        case walkClipMeasuresStationary(measured: Float)
        case strideOverrideMustBePositive(supplied: Float)
        case strideOverrideConflictsWithIdle
        case emptyAnimation(channelCount: Int, samplerCount: Int)

        public var description: String {
            switch self {
            case .strideOverrideMustBePositive(let v):
                return "stride override must be positive, got \(v)"
            case .strideOverrideConflictsWithIdle:
                return "a stride override is meaningless for an idle (idle is the explicit strideSpeed-0 entry) — drop --stride or use --walk"
            case .walkClipMeasuresStationary(let m):
                return "walk clip measures \(m) m/s hips travel — below the idle threshold (\(LocomotionIngest.idleThreshold)). An already-in-place walk needs an authored stride speed; re-run with --stride <m/s>."
            case .emptyAnimation(let channels, let samplers):
                return "VRMA contains 0 playable animation channels (channels=\(channels), samplers=\(samplers)) — aborting instead of emitting an empty clip."
            }
        }
    }

    /// `strideOverride` supplies an authored stride speed (m/s) for clips
    /// whose hips travel was already stripped at the source — the common
    /// shape for licensed in-place packs. Only meaningful with `.walk`;
    /// must be positive. Without it, `.walk` refuses near-stationary input.
    public static func process(
        glb: Data,
        mode: Mode,
        strideOverride: Float? = nil,
        stripConstantEyeChannels: Bool = true,
        normalizeRestPose: Bool = true,
        minArmAbductionDegrees: Float? = nil
    ) throws -> Data {
        var container = try GLBContainer(data: glb)
        try ensureNonEmptyAnimation(in: container)

        // Normalize rest pose before measuring so hipsRestHeight and meanHipsXZSpeed
        // operate in canonical Y-up VRM 1.0 coordinates.
        if normalizeRestPose {
            var preEditor = VRMAClipEditor(container: container)
            try preEditor.normalizeRestPose()
            container = preEditor.container
        }

        let inspector = try VRMAClipInspector(container: container)

        // Measure FIRST — the strip below erases exactly what we measure.
        let measured = try inspector.meanHipsXZSpeed()
        if let override = strideOverride {
            guard override > 0, override.isFinite else { throw IngestError.strideOverrideMustBePositive(supplied: override) }
            guard mode != .idle else { throw IngestError.strideOverrideConflictsWithIdle }
        }
        if mode == .walk, strideOverride == nil, measured < idleThreshold {
            throw IngestError.walkClipMeasuresStationary(measured: measured)
        }
        let isIdle = mode == .idle || (mode == .auto && strideOverride == nil && measured < idleThreshold)
        let meta = LocomotionExtras(
            strideSpeed: isIdle ? 0 : (strideOverride ?? measured),
            inPlace: true,
            sourceHipsHeight: try inspector.hipsRestHeight()
        )
        try meta.write(into: &container)

        var editor = VRMAClipEditor(container: container)
        try editor.stripHipsXZ()
        try editor.stripNonHumanoidChannels()
        if stripConstantEyeChannels {
            try editor.stripEyeChannels(onlyIfConstant: true)
        }
        if let minDeg = minArmAbductionDegrees {
            try editor.enforceMinimumArmAbduction(minDegrees: minDeg)
        }
        try editor.loopTrim()  // pose-similarity works for idle and walk alike
        container = editor.container
        return try container.serialize()
    }

    /// Hygiene-only pipeline for non-locomotion VRMA clips (gestures, emotes,
    /// facial/lookAt clips): preserves hips root motion and clip duration while
    /// stripping non-semantic tracks, stripping baked eye channels, normalizing
    /// rest pose to canonical identity, and optionally enforcing a minimum arm
    /// abduction floor.
    public static func processHygiene(
        glb: Data,
        stripNonHumanoid: Bool = true,
        stripEyeChannels: Bool = true,
        onlyConstantEyes: Bool = true,
        normalizeRestPose: Bool = true,
        minArmAbductionDegrees: Float? = nil
    ) throws -> Data {
        let container = try GLBContainer(data: glb)
        try ensureNonEmptyAnimation(in: container)

        var editor = VRMAClipEditor(container: container)
        if stripNonHumanoid {
            try editor.stripNonHumanoidChannels()
        }
        if stripEyeChannels {
            try editor.stripEyeChannels(onlyIfConstant: onlyConstantEyes)
        }
        if normalizeRestPose {
            try editor.normalizeRestPose()
        }
        if let minDeg = minArmAbductionDegrees {
            try editor.enforceMinimumArmAbduction(minDegrees: minDeg)
        }
        return try editor.container.serialize()
    }

    private static func ensureNonEmptyAnimation(in container: GLBContainer) throws {
        for issue in VRMAClipInspector.diagnose(container: container) {
            if case .noAnimation = issue {
                throw VRMAClipInspector.InspectError.noAnimation
            }
            if case .emptyAnimation(let channels, let samplers) = issue {
                throw IngestError.emptyAnimation(channelCount: channels, samplerCount: samplers)
            }
        }
    }
}
