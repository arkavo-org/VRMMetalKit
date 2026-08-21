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

import simd

/// Visual style of a materialization (spawn) effect. VMK#materialize.
///
/// Every style is one materialization field `m(pos, uv, view)` evaluated in
/// the MToon fragment ahead of shading: fragments discard where `m > t`
/// (progress), an emissive band lights where `t − m < ε`, and some styles add
/// a ghost shell where `m − t < δ` (unlit preview of the not-yet-landed
/// surface). Shell styles (tron, rain, blueprint, constellation) honour MASK
/// cutoff and BLEND / alpha-to-coverage; they do not force opaque coverage.
public enum VRMMaterializationStyle: Int32, CaseIterable, Sendable {
    /// Noise-threshold dissolve sweeping bottom-to-top with a glowing edge
    /// band (digital "braindance" build-up).
    case dissolve = 1
    /// Vertical sweep that fills surfaces in below a light line; above it the
    /// body renders as a fresnel hologram shell.
    case tron = 2
    /// Columnar dissolve with per-column offsets and sparse glyph streaks
    /// above the fill line (code-rain condensation).
    case rain = 3
    /// No discard — scanlines, brightness flicker, and horizontal slice
    /// tearing that stabilise as progress approaches 1.
    case glitch = 4
    /// Coarse world-space cells land in hash-shuffled order, each popping in
    /// with a one-frame white-hot flash before settling into shading.
    case voxel = 5
    /// Three stages: procedural plot-line wireframe glow only, faces flooding
    /// outward from the wires, then linework fading into the lit surface.
    case blueprint = 6
    /// Radial front expanding from `origin`; a bright liquid bead rides the
    /// edge, landed surface arrives as full fake-chrome mirror and anneals to
    /// MToon over a trailing window (T-1000).
    case chrome = 7
    /// Horizontal slabs revealed in hash-shuffled order; each arrival flashes
    /// its cross-section bright (venetian blinds snapping shut).
    case shutter = 8
    /// Triplanar hex tiles land in a radial wave from `origin`, edge-lit;
    /// borders linger as a glowing lattice before cooling into the surface.
    case hex = 9
    /// Stochastic per-pixel stipple: the whole body sputters in from noise at
    /// once, with a rolling hum bar and horizontal jitter that converge at
    /// signal lock.
    case signal = 10
    /// Cellular facets creep from seed points; the growth front glints with
    /// time-hashed sparkles and the interior clarifies from high-fresnel ice
    /// to final albedo.
    case frost = 11
    /// Voronoi feature points ignite first as stars, cell edges connect next
    /// as lines, then interiors fill per-cell — a wearable star chart.
    case constellation = 12

    /// Styles that discard fragments. When one of these is active the opaque
    /// depth prepass is skipped so stale depth from discarded pixels cannot
    /// occlude content drawn later into the same pass.
    public var usesDiscard: Bool { self != .glitch }
}

/// Progress-driven avatar spawn effect, applied per renderer. Set
/// ``VRMRenderer/materialization`` and advance ``progress`` each frame;
/// the effect is inert at `progress >= 1`. VMK#materialize.
public struct VRMMaterialization: Sendable, Equatable {
    /// 0 = not yet materialized, 1 = fully materialized. Values outside 0…1
    /// are clamped at upload.
    public var progress: Float
    public var style: VRMMaterializationStyle
    /// Accent colour for the edge glow / hologram shell / glyph streaks.
    public var color: SIMD3<Float>
    /// World-space vertical extent of the body, used to normalise the sweep.
    public var heightRange: ClosedRange<Float>
    /// Per-avatar seed so simultaneous spawns don't share noise patterns.
    public var seed: Float
    /// World-space focus point for radial styles (chrome flood, hex plating,
    /// frost seeds). nil centres it vertically inside `heightRange` at
    /// x = z = 0 — callers placing avatars away from the world origin should
    /// pass the body's own sternum instead.
    public var origin: SIMD3<Float>?

    public init(progress: Float,
                style: VRMMaterializationStyle,
                color: SIMD3<Float>? = nil,
                heightRange: ClosedRange<Float> = 0.0...1.7,
                seed: Float = 0,
                origin: SIMD3<Float>? = nil) {
        self.progress = progress
        self.style = style
        self.color = color ?? Self.defaultColor(for: style)
        self.heightRange = heightRange
        self.seed = seed
        self.origin = origin
    }

    public var clampedProgress: Float { min(max(progress, 0.0), 1.0) }

    /// The origin actually uploaded: explicit, or vertical midpoint fallback.
    public var resolvedOrigin: SIMD3<Float> {
        origin ?? SIMD3<Float>(0, (heightRange.lowerBound + heightRange.upperBound) * 0.5, 0)
    }

    /// Genre-default accent per style.
    public static func defaultColor(for style: VRMMaterializationStyle) -> SIMD3<Float> {
        switch style {
        case .dissolve:      return SIMD3<Float>(0.20, 0.95, 1.00)  // braindance cyan
        case .tron:          return SIMD3<Float>(0.10, 0.80, 1.00)  // tron cyan
        case .rain:          return SIMD3<Float>(0.15, 1.00, 0.35)  // matrix green
        case .glitch:        return SIMD3<Float>(0.55, 0.85, 1.00)  // hologram ice-blue
        case .voxel:         return SIMD3<Float>(1.00, 0.75, 0.30)  // white-hot ember
        case .blueprint:     return SIMD3<Float>(0.25, 0.55, 1.00)  // drafting blue
        case .chrome:        return SIMD3<Float>(0.95, 0.97, 1.00)  // liquid silver
        case .shutter:       return SIMD3<Float>(0.90, 0.95, 1.00)  // cut-plane white
        case .hex:           return SIMD3<Float>(0.15, 0.90, 0.85)  // shield teal
        case .signal:        return SIMD3<Float>(0.80, 0.75, 1.00)  // static violet
        case .frost:         return SIMD3<Float>(0.60, 0.85, 1.00)  // ice blue
        case .constellation: return SIMD3<Float>(0.75, 0.85, 1.00)  // starlight
        }
    }
}
