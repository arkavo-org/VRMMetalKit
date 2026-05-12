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

import Foundation

/// Diagnostic snapshot of a model's materials: per-material details plus a coarse summary.
///
/// Produced by ``VRMRenderer/generateMaterialReport()``. Codable so it can be
/// dumped to JSON for offline inspection (e.g. by the VRMRender CLI tool).
public struct MaterialReport: Codable {
    /// Human-readable model name (currently a placeholder string).
    public let modelName: String
    /// One entry per material in the loaded model.
    public let materials: [MaterialInfo]
    /// Aggregate counts across all materials.
    public let summary: Summary

    /// Per-material diagnostic record.
    public struct MaterialInfo: Codable {
        /// Material index in the loaded model.
        public let index: Int
        /// Material name (or `"Material_<index>"` when unnamed).
        public let name: String
        /// Alpha mode string as carried by ``VRMMaterial/alphaMode``.
        public let alphaMode: String
        /// Alpha cutoff threshold for `MASK` materials.
        public let alphaCutoff: Float
        /// Base color factor as `[r, g, b, a]`.
        public let baseColorFactor: [Float]
        /// Whether the material binds a base color texture.
        public let hasBaseTexture: Bool
        /// Base color texture size as `[width, height]`; `nil` when absent.
        public let textureSize: [Int]?
        /// Whether back-face culling is disabled.
        public let doubleSided: Bool
        /// MToon shade color as `[r, g, b]`, when MToon is configured.
        public let mtoonShadeColor: [Float]?
        /// Heuristic: `true` when alpha looks suspicious (alpha near 0, or OPAQUE with alpha < 1).
        public let hasAlphaIssue: Bool
    }

    /// Aggregate counts across the report.
    public struct Summary: Codable {
        /// Total materials in the model.
        public let totalMaterials: Int
        /// Number of `OPAQUE` materials.
        public let opaqueCount: Int
        /// Number of `MASK` materials.
        public let maskCount: Int
        /// Number of `BLEND` materials.
        public let blendCount: Int
        /// Number of materials flagged with ``MaterialInfo/hasAlphaIssue``.
        public let suspiciousAlphaCount: Int
    }
}

// MARK: - VRMRenderer Material Report Generation

extension VRMRenderer {
    /// Builds a ``MaterialReport`` for the currently loaded model.
    ///
    /// Returns `nil` if no model is loaded. Used by tooling and tests to spot
    /// authoring problems (suspicious alpha values, missing textures).
    public func generateMaterialReport() -> MaterialReport? {
        guard let model = model else {
            vrmLog("[VRMRenderer] No model loaded for material report")
            return nil
        }

        var materialInfos: [MaterialReport.MaterialInfo] = []
        var opaqueCount = 0
        var maskCount = 0
        var blendCount = 0
        var suspiciousAlphaCount = 0

        for (index, material) in model.materials.enumerated() {
            // Count alpha modes
            switch material.alphaMode.lowercased() {
            case "opaque":
                opaqueCount += 1
            case "mask":
                maskCount += 1
            case "blend":
                blendCount += 1
            default:
                opaqueCount += 1
            }

            // Check for suspicious alpha values
            let hasAlphaIssue = material.baseColorFactor.w < 0.01 ||
                               (material.alphaMode.lowercased() == "opaque" && material.baseColorFactor.w < 1.0)
            if hasAlphaIssue {
                suspiciousAlphaCount += 1
            }

            // Get texture size if available
            var textureSize: [Int]? = nil
            if let baseTexture = material.baseColorTexture,
               let mtlTexture = baseTexture.mtlTexture {
                textureSize = [mtlTexture.width, mtlTexture.height]
            }

            // Get MToon shade color if available
            var mtoonShadeColor: [Float]? = nil
            if let mtoon = material.mtoon {
                mtoonShadeColor = [
                    mtoon.shadeColorFactor.x,
                    mtoon.shadeColorFactor.y,
                    mtoon.shadeColorFactor.z
                ]
            }

            let info = MaterialReport.MaterialInfo(
                index: index,
                name: material.name ?? "Material_\(index)",
                alphaMode: material.alphaMode,
                alphaCutoff: material.alphaCutoff,
                baseColorFactor: [
                    material.baseColorFactor.x,
                    material.baseColorFactor.y,
                    material.baseColorFactor.z,
                    material.baseColorFactor.w
                ],
                hasBaseTexture: material.baseColorTexture != nil,
                textureSize: textureSize,
                doubleSided: material.doubleSided,
                mtoonShadeColor: mtoonShadeColor,
                hasAlphaIssue: hasAlphaIssue
            )

            materialInfos.append(info)
        }

        let summary = MaterialReport.Summary(
            totalMaterials: model.materials.count,
            opaqueCount: opaqueCount,
            maskCount: maskCount,
            blendCount: blendCount,
            suspiciousAlphaCount: suspiciousAlphaCount
        )

        return MaterialReport(
            modelName: "VRM Model",
            materials: materialInfos,
            summary: summary
        )
    }
}
