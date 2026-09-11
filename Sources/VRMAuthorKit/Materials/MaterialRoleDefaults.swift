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

/// SplitMix64: the versioned PRNG behind every procedural default texture.
public struct SplitMix64: Sendable {
    public static let version = "splitmix64/1"
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1) with 24 bits of precision.
    public mutating func nextUnit() -> Float {
        Float(next() >> 40) / Float(1 << 24)
    }

    public static func fnv1a(_ text: String) -> UInt64 {
        var h: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in text.utf8 {
            h ^= UInt64(byte)
            h &*= 0x0000_0100_0000_01B3
        }
        return h
    }
}

/// Per-role pack defaults: image IDs, sizes, base colours, procedural detail
/// and the glTF/MToon factor sets that satisfy the pinned style profile.
public enum MaterialRoleDefaults {
    public static let version = "role-defaults/1"
    public static let imageIdPrefix = "image:"
    public static let outlineWidthMetres = 0.0005
    public static let outlineColour: [Double] = [0.06, 0.009, 0.014]

    public static func imageId(for role: MaterialRole) -> String { imageIdPrefix + role.rawValue }

    public static func role(forImageId id: String) -> MaterialRole? {
        guard id.hasPrefix(imageIdPrefix) else { return nil }
        return MaterialRole(rawValue: String(id.dropFirst(imageIdPrefix.count)))
    }

    public static func imageSize(for role: MaterialRole) -> Int {
        switch role {
        case .iris, .eyeWhite, .eyeHighlight: return 256
        default: return 512
        }
    }

    public static func imageSpec(for role: MaterialRole) -> ImageSpec {
        let size = imageSize(for: role)
        return ImageSpec(id: imageId(for: role), width: size, height: size, colourSpace: .srgb, usage: .colour)
    }

    /// Linear base colour (decoded from an 8-bit sRGB intent).
    public static func baseColour(for role: MaterialRole) -> SIMD3<Float> {
        switch role {
        case .faceSkin, .bodySkin: return ColourTransfer.linear(srgb8: 255, 226, 208)
        case .hair, .brow: return ColourTransfer.linear(srgb8: 92, 64, 51)
        case .cloth: return ColourTransfer.linear(srgb8: 70, 90, 140)
        case .accessory: return ColourTransfer.linear(srgb8: 200, 190, 180)
        case .iris: return ColourTransfer.linear(srgb8: 60, 110, 160)
        case .eyeWhite: return ColourTransfer.linear(srgb8: 250, 250, 250)
        case .eyeHighlight: return SIMD3(1, 1, 1)
        case .eyeline, .eyelash: return ColourTransfer.linear(srgb8: 40, 28, 30)
        case .mouth: return ColourTransfer.linear(srgb8: 200, 90, 100)
        case .other: return ColourTransfer.linear(srgb8: 128, 128, 128)
        }
    }

    // MARK: Procedural rasters

    public static func raster(for role: MaterialRole, width: Int, height: Int, seed: UInt64) -> RasterImage {
        var prng = SplitMix64(seed: seed ^ SplitMix64.fnv1a(role.rawValue) ^ SplitMix64.fnv1a(version))
        let base = baseColour(for: role)
        var image = RasterImage(width: width, height: height)
        let strandPhases: [Float] = (0..<64).map { _ in prng.nextUnit() * 2 * Float.pi }
        for y in 0..<height {
            for x in 0..<width {
                let uv = image.uv(x: x, y: y)
                let u = Float(uv.x), v = Float(uv.y)
                image[x, y] = pixel(role: role, u: u, v: v, base: base, prng: &prng, strandPhases: strandPhases)
            }
        }
        return image
    }

    static func pixel(role: MaterialRole, u: Float, v: Float, base: SIMD3<Float>, prng: inout SplitMix64, strandPhases: [Float]) -> SIMD4<Float> {
        func opaque(_ c: SIMD3<Float>) -> SIMD4<Float> { SIMD4(c.x, c.y, c.z, 1) }
        let clear = SIMD4<Float>(0, 0, 0, 0)
        let du = u - 0.5, dv = v - 0.5
        let r = (du * du + dv * dv).squareRoot()
        switch role {
        case .faceSkin, .bodySkin, .accessory, .other:
            return opaque(base)
        case .hair:
            let band = min(Int(u * 64), 63)
            let strand = 0.5 + 0.5 * sin(v * 2 * Float.pi * 40 + strandPhases[band])
            return opaque(base * (0.85 + 0.3 * strand))
        case .cloth:
            let noise = prng.nextUnit()
            return opaque(base * (0.95 + 0.1 * noise))
        case .iris:
            guard r <= 0.48 else { return clear }
            let t = r / 0.48
            var c = base * (0.55 + 0.45 * (1 - t))
            if r <= 0.16 { c = SIMD3(repeating: 0.01) }
            let hu = u - 0.36, hv = v - 0.34
            if (hu * hu + hv * hv).squareRoot() <= 0.07 { c = SIMD3(1, 1, 1) }
            return opaque(c)
        case .eyeWhite:
            return opaque(base * (1 - 0.15 * r * r))
        case .eyeHighlight:
            let e = (du / 0.3) * (du / 0.3) + (dv / 0.2) * (dv / 0.2)
            return e <= 1 ? opaque(base) : clear
        case .eyeline:
            let arc = 0.5 + 0.15 * (2 * u - 1) * (2 * u - 1)
            return abs(v - arc) <= 0.03 ? opaque(base) : clear
        case .eyelash:
            let arc = 0.5 + 0.15 * (2 * u - 1) * (2 * u - 1)
            if abs(v - arc) <= 0.03 { return opaque(base) }
            for k in 0..<5 {
                let uk = 0.15 + 0.175 * Float(k)
                if abs(u - uk) < 0.02, v >= arc, v <= arc + 0.18 { return opaque(base) }
            }
            return clear
        case .brow:
            let arc = 0.5 + 0.1 * (2 * u - 1) * (2 * u - 1)
            let taper = 1 - pow(abs(2 * u - 1), 4)
            return abs(v - arc) <= 0.04 * taper ? opaque(base) : clear
        case .mouth:
            let c = abs(v - 0.5) <= 0.02 ? base * 0.5 : base
            return opaque(c)
        }
    }

    // MARK: Factor defaults

    public static func alphaMode(for role: MaterialRole) -> String {
        switch role {
        case .faceSkin, .bodySkin, .cloth, .eyeWhite, .other: return "OPAQUE"
        case .hair, .accessory, .mouth: return "MASK"
        case .iris, .eyeHighlight, .eyeline, .eyelash, .brow: return "BLEND"
        }
    }

    public static func doubleSided(for role: MaterialRole) -> Bool {
        switch role {
        case .cloth, .hair, .accessory, .eyeHighlight, .eyeline, .eyelash, .brow: return true
        default: return false
        }
    }

    public static func renderQueueOffset(for role: MaterialRole) -> Int {
        switch role {
        case .iris, .eyeline: return -3
        case .eyeHighlight: return -2
        case .brow: return -1
        default: return 0
        }
    }

    public static func shadeColour(for role: MaterialRole) -> [Double] {
        switch role {
        case .faceSkin, .bodySkin, .mouth: return [0.97, 0.81, 0.77]
        case .hair: return [0.72, 0.62, 0.66]
        case .cloth, .accessory: return [0.78, 0.74, 0.82]
        case .other: return [0.8, 0.8, 0.8]
        case .iris, .eyeWhite, .eyeHighlight, .eyeline, .eyelash, .brow: return [1, 1, 1]
        }
    }

    /// (shadingToonyFactor, shadingShiftFactor): face region shadow_end −0.8,
    /// body/cloth two-tone with width 0.2, hair softer with width 0.4.
    public static func shading(for role: MaterialRole) -> (toony: Double, shift: Double) {
        switch role {
        case .faceSkin, .iris, .eyeWhite, .eyeHighlight, .eyeline, .eyelash, .brow, .mouth: return (0.95, 0.75)
        case .hair: return (0.8, 0)
        case .bodySkin, .cloth, .accessory, .other: return (0.9, 0)
        }
    }

    public static func outlineWidthMode(for role: MaterialRole) -> String {
        switch role {
        case .faceSkin, .bodySkin, .cloth, .hair, .accessory: return "worldCoordinates"
        default: return "none"
        }
    }

    public static func gltf(for role: MaterialRole) -> JSONValue {
        let image = JSONValue.string(imageId(for: role))
        return [
            "pbrMetallicRoughness": [
                "baseColorFactor": [1, 1, 1, 1],
                "baseColorTexture": ["imageId": image, "texCoord": 0],
                "metallicFactor": 0,
                "roughnessFactor": 0.9,
            ],
            "emissiveFactor": [0, 0, 0],
            "alphaMode": .string(alphaMode(for: role)),
            "alphaCutoff": 0.5,
            "doubleSided": .bool(doubleSided(for: role)),
        ]
    }

    public static func mtoon(for role: MaterialRole) -> JSONValue {
        let image = JSONValue.string(imageId(for: role))
        let (toony, shift) = shading(for: role)
        let mode = outlineWidthMode(for: role)
        return [
            "specVersion": .string(MaterialSchemas.mtoonSpecVersion),
            "transparentWithZWrite": false,
            "renderQueueOffsetNumber": .number(Double(renderQueueOffset(for: role))),
            "shadeColorFactor": JSONValue(shadeColour(for: role)),
            "shadeMultiplyTexture": ["imageId": image, "texCoord": 0],
            "shadingShiftFactor": .number(shift),
            "shadingToonyFactor": .number(toony),
            "giEqualizationFactor": 0.9,
            "matcapFactor": [1, 1, 1],
            "parametricRimColorFactor": [0, 0, 0],
            "rimLightingMixFactor": 1,
            "parametricRimFresnelPowerFactor": 5,
            "parametricRimLiftFactor": 0,
            "outlineWidthMode": .string(mode),
            "outlineWidthFactor": .number(mode == "none" ? 0 : outlineWidthMetres),
            "outlineColorFactor": JSONValue(outlineColour),
            "outlineLightingMixFactor": 1,
            "uvAnimationScrollXSpeedFactor": 0,
            "uvAnimationScrollYSpeedFactor": 0,
            "uvAnimationRotationSpeedFactor": 0,
        ]
    }

    public static func material(id: String, role: MaterialRole) -> MaterialObject {
        MaterialObject(id: id, role: role, gltf: gltf(for: role), mtoon: mtoon(for: role))
    }
}
