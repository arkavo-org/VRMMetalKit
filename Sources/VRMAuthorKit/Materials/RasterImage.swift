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

/// sRGB transfer functions (IEC 61966-2-1), evaluated in Double.
public enum ColourTransfer {
    public static func srgbToLinear(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    public static func linearToSrgb(_ c: Double) -> Double {
        c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
    }

    /// 8-bit sRGB triple → linear RGB.
    public static func linear(srgb8 r: Int, _ g: Int, _ b: Int) -> SIMD3<Float> {
        SIMD3(Float(srgbToLinear(Double(r) / 255)), Float(srgbToLinear(Double(g) / 255)), Float(srgbToLinear(Double(b) / 255)))
    }

    /// Converts a `Colour` to linear RGBA (alpha is never transfer-coded).
    public static func linearRGBA(_ colour: Colour) -> SIMD4<Float> {
        let c = colour.rgba
        switch colour.space {
        case .linear: return SIMD4(Float(c[0]), Float(c[1]), Float(c[2]), Float(c[3]))
        case .srgb: return SIMD4(Float(srgbToLinear(c[0])), Float(srgbToLinear(c[1])), Float(srgbToLinear(c[2])), Float(c[3]))
        }
    }

    public static func byte(_ value: Float) -> UInt8 {
        let clamped = min(max(Double(value), 0), 1)
        return UInt8((clamped * 255).rounded())
    }
}

/// Linear, unpremultiplied float RGBA raster in row-major order (y down).
public struct RasterImage: Hashable, Sendable {
    public var width: Int
    public var height: Int
    public var pixels: [SIMD4<Float>]

    public init(width: Int, height: Int, pixels: [SIMD4<Float>]) {
        precondition(pixels.count == width * height)
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public init(width: Int, height: Int, fill: SIMD4<Float> = SIMD4(0, 0, 0, 0)) {
        self.init(width: width, height: height, pixels: Array(repeating: fill, count: width * height))
    }

    public subscript(x: Int, y: Int) -> SIMD4<Float> {
        get { pixels[y * width + x] }
        set { pixels[y * width + x] = newValue }
    }

    /// UV of a pixel centre; v runs down with rows (row 0 is v ≈ 0).
    public func uv(x: Int, y: Int) -> SIMD2<Double> {
        SIMD2((Double(x) + 0.5) / Double(width), (Double(y) + 0.5) / Double(height))
    }

    /// Nearest-neighbour sample with REPEAT wrapping on both axes.
    public func sample(_ uv: SIMD2<Double>) -> SIMD4<Float> {
        let fu = uv.x - floor(uv.x)
        let fv = uv.y - floor(uv.y)
        let x = min(Int(fu * Double(width)), width - 1)
        let y = min(Int(fv * Double(height)), height - 1)
        return pixels[y * width + x]
    }

    /// 8-bit RGBA bytes. RGB is sRGB-encoded only for `srgb` colour images;
    /// normal maps and masks and linear images are stored as-is. Alpha is linear.
    public func rgba8(colourSpace: ColourSpace, usage: ImageUsage) -> [UInt8] {
        let encode = colourSpace == .srgb && usage != .normal
        var out: [UInt8] = []
        out.reserveCapacity(pixels.count * 4)
        for p in pixels {
            if encode {
                out.append(ColourTransfer.byte(Float(ColourTransfer.linearToSrgb(Double(p.x)))))
                out.append(ColourTransfer.byte(Float(ColourTransfer.linearToSrgb(Double(p.y)))))
                out.append(ColourTransfer.byte(Float(ColourTransfer.linearToSrgb(Double(p.z)))))
            } else {
                out.append(ColourTransfer.byte(p.x))
                out.append(ColourTransfer.byte(p.y))
                out.append(ColourTransfer.byte(p.z))
            }
            out.append(ColourTransfer.byte(p.w))
        }
        return out
    }

    public func png(colourSpace: ColourSpace, usage: ImageUsage) throws -> Data {
        try PNGEncoder.encode(width: width, height: height, rgba: rgba8(colourSpace: colourSpace, usage: usage))
    }
}

/// Composites `TextureLayer`s into one `ImageSpec` target in linear,
/// unpremultiplied colour. Array order composites; solid layers use their
/// colour, image layers sample a source through the layer UV transform,
/// masks sample in the target's own UV space (red channel).
public enum TextureCompositor {
    public static let version = "composite/1"

    public typealias SourceResolver = (String) -> RasterImage?

    public static func composite(spec: ImageSpec, layers: [TextureLayer], base: RasterImage?, sources: SourceResolver) throws -> RasterImage {
        var target = base.map { resized($0, width: spec.width, height: spec.height) } ?? RasterImage(width: spec.width, height: spec.height)
        for layer in layers where layer.enabled && layer.targetImage == spec.id {
            try layer.validate()
            try apply(layer, to: &target, sources: sources)
        }
        return target
    }

    static func resized(_ image: RasterImage, width: Int, height: Int) -> RasterImage {
        if image.width == width, image.height == height { return image }
        var out = RasterImage(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width { out[x, y] = image.sample(out.uv(x: x, y: y)) }
        }
        return out
    }

    /// Layer UV transform: uv' = R(θ) · (uv ⊙ scale) + offset, rotation
    /// clockwise-positive in UV space as in KHR_texture_transform.
    public static func transformUV(_ uv: SIMD2<Double>, layer: TextureLayer) -> SIMD2<Double> {
        let radians = layer.uvRotationDeg * Double.pi / 180
        var c = cos(radians)
        var s = sin(radians)
        if abs(c) < 1e-9 { c = 0 }
        if abs(s) < 1e-9 { s = 0 }
        let su = uv.x * layer.uvScale[0]
        let sv = uv.y * layer.uvScale[1]
        return SIMD2(c * su + s * sv + layer.uvOffset[0], -s * su + c * sv + layer.uvOffset[1])
    }

    static func apply(_ layer: TextureLayer, to target: inout RasterImage, sources: SourceResolver) throws {
        let solid: SIMD4<Float>? = layer.kind == .solid ? layer.colour.map { ColourTransfer.linearRGBA($0) } : nil
        var image: RasterImage?
        if layer.kind == .image {
            guard let id = layer.image, let source = sources(id) else {
                throw AuthorError(code: .validationFailed, objectId: layer.id, path: "/image", observed: layer.image.map { .string($0) },
                                  message: "Layer '\(layer.id)' references image '\(layer.image ?? "")' which is not an available raster source.", suggestedCommands: ["object list"])
            }
            image = source
        }
        var mask: RasterImage?
        if let maskId = layer.mask {
            guard let source = sources(maskId) else {
                throw AuthorError(code: .validationFailed, objectId: layer.id, path: "/mask", observed: .string(maskId),
                                  message: "Layer '\(layer.id)' references mask '\(maskId)' which is not an available raster source.", suggestedCommands: ["object list"])
            }
            mask = source
        }
        let opacity = Float(layer.opacity)
        for y in 0..<target.height {
            for x in 0..<target.width {
                let uv = target.uv(x: x, y: y)
                let src: SIMD4<Float> = solid ?? image!.sample(transformUV(uv, layer: layer))
                let coverage = mask.map { $0.sample(uv).x } ?? 1
                target[x, y] = blend(destination: target[x, y], source: src, alpha: src.w * opacity * coverage, mode: layer.blend)
            }
        }
    }

    /// Separable blend then unpremultiplied "over" (W3C compositing):
    /// cs = (1 − αd)·Cs + αd·B(Cd, Cs); αo = αs + αd(1 − αs);
    /// Co = (αs·cs + αd(1 − αs)·Cd) / αo.
    public static func blend(destination d: SIMD4<Float>, source s: SIMD4<Float>, alpha: Float, mode: BlendMode) -> SIMD4<Float> {
        let ad = d.w
        let cs = SIMD3(s.x, s.y, s.z)
        let cd = SIMD3(d.x, d.y, d.z)
        let mixed: SIMD3<Float>
        switch mode {
        case .normal: mixed = cs
        case .multiply: mixed = cd * cs
        case .screen: mixed = cd + cs - cd * cs
        }
        let blended = (1 - ad) * cs + ad * mixed
        let ao = alpha + ad * (1 - alpha)
        guard ao > 0 else { return SIMD4(0, 0, 0, 0) }
        let co = (alpha * blended + ad * (1 - alpha) * cd) / ao
        return SIMD4(co.x, co.y, co.z, ao)
    }
}
