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
import simd

/// Semantic UV regions on an avatar's face atlas used to place reusable makeup decals
/// consistently across VRoid-lineage and `VRMAuthorKit` (`native-anime-v1`) avatars.
public enum VRMFaceLandmarkRegion: String, CaseIterable, Codable, Hashable, Sendable {
    case fullFace
    case lips
    case leftEye
    case rightEye
    case leftBrow
    case rightBrow
    case leftCheek
    case rightCheek
    case nose
    case forehead
}

/// Normalized UV rectangle `[minU, maxU] x [minV, maxV]` in `[0, 1]^2` texture space.
public struct VRMUVRect: Codable, Equatable, Hashable, Sendable {
    public var minU: Float
    public var minV: Float
    public var maxU: Float
    public var maxV: Float

    /// Full `[0, 1]^2` texture atlas rectangle.
    public static let full = VRMUVRect(minU: 0, minV: 0, maxU: 1, maxV: 1)

    public init(minU: Float, minV: Float, maxU: Float, maxV: Float) {
        self.minU = minU
        self.minV = minV
        self.maxU = maxU
        self.maxV = maxV
    }

    public var sizeU: Float { max(0, maxU - minU) }
    public var sizeV: Float { max(0, maxV - minV) }
    public var origin: SIMD2<Float> { SIMD2<Float>(minU, minV) }
    public var size: SIMD2<Float> { SIMD2<Float>(sizeU, sizeV) }

    /// Returns `true` when all bounds are finite, lie inside `[0, 1]`, and span non-zero area.
    public var isValid: Bool {
        minU.isFinite && minV.isFinite && maxU.isFinite && maxV.isFinite
            && minU >= 0 && minV >= 0 && maxU <= 1 && maxV <= 1
            && maxU > minU && maxV > minV
    }
}

/// Face UV landmark metadata defined by the `ARKAVO_vrm_cosmetics` (`schemaVersion: "0.1"`)
/// glTF root extension (with fallback to `extras.vrmFaceLandmarks`).
///
/// Maps semantic ``VRMFaceLandmarkRegion`` keys to normalized UV rectangles so a single
/// makeup decal asset fits any VRoid-lineage or `VRMAuthorKit` (`native-anime-v1`) avatar.
public struct VRMFaceLandmarks: Codable, Equatable, Sendable {
    /// glTF root extension key for cosmetics metadata.
    public static let extensionName = "ARKAVO_vrm_cosmetics"
    /// glTF root `extras` fallback key.
    public static let extrasKey = "vrmFaceLandmarks"
    /// Current frozen schema version for `ARKAVO_vrm_cosmetics`.
    public static let currentSchemaVersion = "0.1"

    /// Canonical face material names used by `VRMAuthorKit` (`native-anime-v1`) and VRoid exports.
    public static let defaultFaceMaterialNames: [String] = [
        "Face_00_SKIN",
        "FaceBrow_00",
        "EyeIris_00",
        "EyeHighlight_00",
        "EyeWhite_00",
        "Eyeline_00",
    ]

    /// Schema version string (currently `"0.1"`).
    public var schemaVersion: String
    /// Material names on this avatar associated with the face atlas.
    public var faceMaterialNames: [String]
    /// Mapping from semantic landmark regions to normalized UV rectangles.
    public var regions: [VRMFaceLandmarkRegion: VRMUVRect]

    public init(
        schemaVersion: String = VRMFaceLandmarks.currentSchemaVersion,
        faceMaterialNames: [String] = VRMFaceLandmarks.defaultFaceMaterialNames,
        regions: [VRMFaceLandmarkRegion: VRMUVRect]
    ) {
        self.schemaVersion = schemaVersion
        self.faceMaterialNames = faceMaterialNames
        self.regions = regions
    }

    /// Returns the UV rectangle for `region`, if defined and valid.
    public func rect(for region: VRMFaceLandmarkRegion) -> VRMUVRect? {
        guard let rect = regions[region], rect.isValid else { return nil }
        return rect
    }

    /// Default landmark preset calibrated to the standard VRoid Studio / `native-anime-v1`
    /// face UV layout (`(0, 0)` top-left, `(1, 1)` bottom-right; avatar left is `U > 0.5`).
    public static let vroidDefault = VRMFaceLandmarks(
        schemaVersion: currentSchemaVersion,
        faceMaterialNames: defaultFaceMaterialNames,
        regions: [
            .fullFace:   VRMUVRect(minU: 0.00, minV: 0.00, maxU: 1.00, maxV: 1.00),
            .forehead:   VRMUVRect(minU: 0.26, minV: 0.22, maxU: 0.74, maxV: 0.41),
            .leftBrow:   VRMUVRect(minU: 0.56, minV: 0.40, maxU: 0.76, maxV: 0.48),
            .rightBrow:  VRMUVRect(minU: 0.24, minV: 0.40, maxU: 0.44, maxV: 0.48),
            .leftEye:    VRMUVRect(minU: 0.55, minV: 0.46, maxU: 0.78, maxV: 0.61),
            .rightEye:   VRMUVRect(minU: 0.22, minV: 0.46, maxU: 0.45, maxV: 0.61),
            .leftCheek:  VRMUVRect(minU: 0.57, minV: 0.58, maxU: 0.75, maxV: 0.72),
            .rightCheek: VRMUVRect(minU: 0.25, minV: 0.58, maxU: 0.43, maxV: 0.72),
            .nose:       VRMUVRect(minU: 0.45, minV: 0.60, maxU: 0.55, maxV: 0.70),
            .lips:       VRMUVRect(minU: 0.42, minV: 0.72, maxU: 0.58, maxV: 0.80),
        ]
    )

    /// Parses face landmarks from a glTF document's root `extensions["ARKAVO_vrm_cosmetics"]`,
    /// falling back to `extras["vrmFaceLandmarks"]`.
    public static func parse(from document: GLTFDocument) -> VRMFaceLandmarks? {
        if let ext = document.extensions?[extensionName] as? [String: Any] {
            return parseExtensionDictionary(ext)
        }
        if let extras = document.extras?[extrasKey] as? [String: Any] {
            return parseLandmarksPayload(extras, defaultSchemaVersion: currentSchemaVersion)
        }
        return nil
    }

    internal static func parseExtensionDictionary(_ dict: [String: Any]) -> VRMFaceLandmarks? {
        let schemaVersion = (dict["schemaVersion"] as? String) ?? currentSchemaVersion
        let materialNames = (dict["faceMaterialNames"] as? [String]) ?? defaultFaceMaterialNames

        let rawRegions: [String: Any]?
        if let nested = dict["faceLandmarks"] as? [String: Any] {
            if let innerRegions = nested["regions"] as? [String: Any] {
                rawRegions = innerRegions
            } else {
                rawRegions = nested
            }
        } else if let regions = dict["regions"] as? [String: Any] {
            rawRegions = regions
        } else {
            rawRegions = nil
        }

        guard let rawRegions else { return nil }
        let parsed = parseRegionMap(rawRegions)
        guard !parsed.isEmpty else { return nil }
        return VRMFaceLandmarks(
            schemaVersion: schemaVersion,
            faceMaterialNames: materialNames,
            regions: parsed
        )
    }

    internal static func parseLandmarksPayload(
        _ dict: [String: Any],
        defaultSchemaVersion: String
    ) -> VRMFaceLandmarks? {
        let schemaVersion = (dict["schemaVersion"] as? String) ?? defaultSchemaVersion
        let materialNames = (dict["faceMaterialNames"] as? [String]) ?? defaultFaceMaterialNames
        let regionSource = (dict["regions"] as? [String: Any]) ?? dict
        let parsed = parseRegionMap(regionSource)
        guard !parsed.isEmpty else { return nil }
        return VRMFaceLandmarks(
            schemaVersion: schemaVersion,
            faceMaterialNames: materialNames,
            regions: parsed
        )
    }

    private static func parseRegionMap(_ dict: [String: Any]) -> [VRMFaceLandmarkRegion: VRMUVRect] {
        var result: [VRMFaceLandmarkRegion: VRMUVRect] = [:]
        for (key, value) in dict {
            guard let region = VRMFaceLandmarkRegion(rawValue: key),
                  let rect = parseUVRect(value),
                  rect.isValid else {
                continue
            }
            result[region] = rect
        }
        return result
    }

    private static func parseUVRect(_ value: Any) -> VRMUVRect? {
        if let dict = value as? [String: Any],
           let minU = floatValue(dict["minU"]),
           let minV = floatValue(dict["minV"]),
           let maxU = floatValue(dict["maxU"]),
           let maxV = floatValue(dict["maxV"]) {
            return VRMUVRect(minU: minU, minV: minV, maxU: maxU, maxV: maxV)
        }
        if let array = value as? [Any], array.count >= 4,
           let minU = floatValue(array[0]),
           let minV = floatValue(array[1]),
           let maxU = floatValue(array[2]),
           let maxV = floatValue(array[3]) {
            return VRMUVRect(minU: minU, minV: minV, maxU: maxU, maxV: maxV)
        }
        return nil
    }

    private static func floatValue(_ value: Any?) -> Float? {
        if let f = value as? Float { return f }
        if let d = value as? Double { return Float(d) }
        if let i = value as? Int { return Float(i) }
        if let n = value as? NSNumber { return n.floatValue }
        return nil
    }
}
