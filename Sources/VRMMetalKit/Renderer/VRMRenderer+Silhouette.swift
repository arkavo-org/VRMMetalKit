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

/// Configuration for the renderer's stylised silhouette mode. Every parameter
/// has a sensible default; callers typically override one or two for their
/// scene composition.
public struct SilhouetteRenderConfig: Sendable {

    // MARK: Lighting

    /// Direction-of-travel of the rim light. The MToon shader negates this
    /// vector when computing `N·L`, so for a source at world (+X) — screen-
    /// right under the standard camera — store (-X, 0, ±Z). Default: strictly
    /// lateral from screen-right with a small +Z bias to catch the front
    /// profile. Y must stay near zero; any Y component lights the top
    /// horizontal surfaces (bow tops, shoulders), which reads as "top-lit"
    /// rather than the intended side-rim aesthetic.
    public var rimLightDirection: SIMD3<Float> = SIMD3<Float>(-1.0, 0.0, 0.2)

    /// Linear-RGB color of the rim. Default: warm ember (~#F28C4D). Stored
    /// pre-clamped — combined with `rimLightIntensity` it must stay ≤ 1.0
    /// in every channel or the rim renders as pale yellow / white once the
    /// rasterizer clamps. See `rimLightIntensity`.
    public var rimLightColor: SIMD3<Float> = SIMD3<Float>(0.95, 0.55, 0.30)

    /// Rim brightness multiplier. The shader output is `color * intensity *
    /// fresnel * NdotL` and is clamped to [0,1] per channel before display,
    /// so `color * intensity` must stay ≤ 1.0 in every channel to preserve
    /// hue at the rim peak. With the default warm ember (`max channel 0.95`)
    /// the safe ceiling is ~1.05 — any higher and the red channel saturates
    /// to white. Use `rimFresnelPower` for edge sharpness, not intensity.
    public var rimLightIntensity: Float = 1.0

    /// Fresnel exponent for the additive rim (`pow(1 - N·V, p)`). Higher =
    /// narrower edge clamped to grazing angles. Typical 8..16.
    public var rimFresnelPower: Float = 14.0

    // MARK: Materials

    /// Emissive multiplier for eye materials. The iris/sclera texture is
    /// sampled, multiplied by this scalar, and added to the lit pass. The
    /// rasterizer then clamps to [0,1] per channel. Useful values:
    ///   - 1.0: iris glows at the texture's authored brightness — usually
    ///          subtle and reads as "lit eyes" rather than "luminous eyes."
    ///   - 2.5: brighter iris colours saturate, sclera blows out to white,
    ///          giving the "hologram / ghost in the machine" host aesthetic
    ///          where the eyes act as a bright focal point against the
    ///          crushed body. Default.
    ///   - 4.0+: hard-saturated white iris cores; iris hue only survives
    ///          where the source texture is darkest. Use sparingly.
    public var eyeEmissiveScale: Float = 2.5

    /// Predicate returning `true` for material names that should self-
    /// illuminate (eye sclera/iris/pupil) instead of being crushed to black.
    /// Default catches the standard VRoid naming convention; pass your own
    /// for models that use a different scheme.
    public var isEyeMaterial: @Sendable (String?) -> Bool = SilhouetteRenderConfig.defaultIsEyeMaterial

    /// Eye-material name predicate covering VRoid (English) and native VRM
    /// (Japanese) naming conventions, with eyebrow/eyelash/eyeliner excluded.
    /// English tokens: `eye / iris / sclera / pupil / highlight / eyeball`.
    /// Japanese tokens: `瞳 (pupil) / 白目 (sclera) / ハイライト (highlight)`.
    /// English match is case-insensitive; Japanese match is exact.
    ///
    /// Exclusion runs first: `lash / brow / line` always returns `false`.
    /// This catches eyebrows, eyelashes, eyeliner, and any name containing
    /// "outline" — they need to be part of the body crush.
    ///
    /// Note on `highlight`: included by design so VRoid exporters that name
    /// the iris-highlight decal as bare `Highlight` (no `Eye` prefix) still
    /// self-illuminate. If a model uses the literal name `Highlight` for a
    /// non-eye material, override `SilhouetteRenderConfig.isEyeMaterial`
    /// with a custom predicate. See `SilhouetteRenderConfigTests`.
    public static let defaultIsEyeMaterial: @Sendable (String?) -> Bool = { name in
        guard let raw = name else { return false }
        let lower = raw.lowercased()
        for excluded in ["lash", "brow", "line"] where lower.contains(excluded) {
            return false
        }
        for token in ["eye", "iris", "sclera", "pupil", "highlight", "eyeball"]
            where lower.contains(token) {
            return true
        }
        for token in ["瞳", "白目", "ハイライト"] where raw.contains(token) {
            return true
        }
        return false
    }

    /// Creates a configuration with the default warm side-rim lighting and VRoid eye-material heuristic.
    public init() {}
}

extension VRMRenderer {

    /// Configure the renderer for stylised silhouette rendering: pure-black
    /// body albedo with a single warm directional rim from `config.rimLight*`,
    /// eye materials re-routed through emissive so they self-illuminate at
    /// the iris's own colour. Idempotent — safe to call before or after
    /// `loadModel`. Any subsequent gameplay-style scene reset would need to
    /// undo each step manually (see comments below).
    ///
    /// Effects on the renderer:
    /// - `disableAutoMaterialOverrides = true`
    /// - `additiveDirectionalRimEnabled = true`
    /// - `additiveDirectionalRimPower = config.rimFresnelPower`
    /// - Light 0 disabled; Light 1 set to the rim; Light 2 disabled
    /// - Ambient zeroed
    ///
    /// Effects on the model's materials:
    /// - Outline (MToon inverted-hull) zeroed on every material
    /// - For names matching `config.isEyeMaterial`:
    ///     - `baseColorTexture` (when present) re-routed to `emissiveTexture`,
    ///       so the iris pattern self-emits at `eyeEmissiveScale`. Without a
    ///       texture, falls back to writing the literal albedo factor scaled.
    ///     - `baseColorFactor.rgb` and `shadeColorFactor` collapse to black.
    /// - For all other materials:
    ///     - `baseColorFactor.rgb` = 0, `shadeColorFactor` = 0,
    ///       `emissiveFactor` = 0, `matcapFactor` = 0, `giEqualizationFactor` = 0
    ///     - MToon's parametric rim disabled (the additive directional rim
    ///       takes over via the shader path).
    public func applySilhouetteMode(model: VRMModel,
                                    config: SilhouetteRenderConfig = SilhouetteRenderConfig()) {
        // Renderer flags
        self.disableAutoMaterialOverrides = true
        self.additiveDirectionalRimEnabled = true
        self.additiveDirectionalRimPower = config.rimFresnelPower

        // Lighting: single warm directional rim, nothing else.
        self.disableLight(0)
        self.setLight(1,
                      direction: config.rimLightDirection,
                      color: config.rimLightColor,
                      intensity: config.rimLightIntensity)
        self.disableLight(2)
        self.setAmbientColor(SIMD3<Float>(0, 0, 0))

        // Material overrides
        for material in model.materials {
            // 1. Kill MToon's inverted-hull outline on every material —
            //    independent of base color, so it survives the crush below
            //    and would otherwise pop as bright artifacts.
            if var mtoon = material.mtoon {
                mtoon.outlineWidthMode = .none
                mtoon.outlineWidthFactor = 0
                mtoon.outlineColorFactor = SIMD3<Float>(0, 0, 0)
                mtoon.outlineLightingMixFactor = 0
                material.mtoon = mtoon
            }

            if config.isEyeMaterial(material.name) {
                applyEyeOverride(to: material, config: config)
            } else {
                applyBlackBodyOverride(to: material)
            }
        }
    }

    private func applyEyeOverride(to material: VRMMaterial, config: SilhouetteRenderConfig) {
        // Route the iris pattern through the emissive sampler so the eye
        // self-illuminates at full original colour. VRoid models typically
        // store the iris hue in `baseColorTexture` with `baseColorFactor =
        // (1,1,1)`, so emitting the texture * white-factor preserves the
        // pattern. Textureless fallback uses the literal albedo factor.
        if let baseTex = material.baseColorTexture {
            material.emissiveTexture = baseTex
            material.emissiveFactor = SIMD3<Float>(repeating: config.eyeEmissiveScale)
        } else {
            let rgb = SIMD3<Float>(material.baseColorFactor.x,
                                   material.baseColorFactor.y,
                                   material.baseColorFactor.z)
            material.emissiveFactor = rgb * config.eyeEmissiveScale
            material.emissiveTexture = nil
        }
        // Lit + shade pass contributes nothing — only emissive shows.
        material.baseColorFactor = SIMD4<Float>(0, 0, 0, material.baseColorFactor.w)
        if var mtoon = material.mtoon {
            mtoon.shadeColorFactor = SIMD3<Float>(0, 0, 0)
            mtoon.giEqualizationFactor = 0
            mtoon.parametricRimColorFactor = SIMD3<Float>(0, 0, 0)
            mtoon.parametricRimLiftFactor = 0
            mtoon.matcapFactor = SIMD3<Float>(0, 0, 0)
            material.mtoon = mtoon
        }
    }

    private func applyBlackBodyOverride(to material: VRMMaterial) {
        // Pure-black base + shade. Visible warmth comes solely from the
        // additive directional rim shader path (driven by the renderer's
        // scene lights, independent of base albedo).
        material.baseColorFactor = SIMD4<Float>(0, 0, 0, material.baseColorFactor.w)
        material.emissiveFactor = SIMD3<Float>(0, 0, 0)
        if var mtoon = material.mtoon {
            mtoon.shadeColorFactor = SIMD3<Float>(0, 0, 0)
            mtoon.giEqualizationFactor = 0
            mtoon.parametricRimColorFactor = SIMD3<Float>(0, 0, 0)
            mtoon.parametricRimLiftFactor = 0
            mtoon.matcapFactor = SIMD3<Float>(0, 0, 0)
            material.mtoon = mtoon
        }
    }
}
