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

/// Template-authored rasters that the role defaults cannot express: the hair
/// strip texture driven by the recipe's `HairTexture`, the face texture with
/// its scalp underlay, and the meta thumbnail. All are deterministic in
/// (inputs, seed).
enum NativeAnimeTextures {
    static let version = "native-anime-textures/1"
    static let hairImageSize = 512
    static let thumbnailSize = 256

    /// Root→tip gradient along V (V = 0 at the scalp), per-strand luminance
    /// bands along U and a soft highlight band at a third of the length.
    static func hairRaster(texture: HairTexture, seed: UInt64) -> RasterImage {
        var prng = SplitMix64(seed: seed ^ SplitMix64.fnv1a("hair") ^ SplitMix64.fnv1a(version))
        let base = rgb(texture.baseColour)
        let root = rgb(texture.rootColour)
        let tip = rgb(texture.tipColour)
        let bands = 48
        let phases: [Float] = (0..<bands).map { _ in prng.nextUnit() * 2 * Float.pi }
        let gains: [Float] = (0..<bands).map { _ in 0.9 + 0.2 * prng.nextUnit() }
        let size = hairImageSize
        var image = RasterImage(width: size, height: size)
        let highlightCentre: Float = 0.3
        let highlightHalfWidth = max(Float(texture.highlightWidth), 0.001) * 0.5
        let highlightOpacity = Float(texture.highlightOpacity)
        for y in 0..<size {
            for x in 0..<size {
                let uv = image.uv(x: x, y: y)
                let u = Float(uv.x), v = Float(uv.y)
                let rootMix = 1 - smoothstep(0, 0.35, v)
                let tipMix = smoothstep(0.6, 1, v)
                var c = base * (1 - rootMix) + root * rootMix
                c = c * (1 - tipMix) + tip * tipMix
                let band = min(Int(u * Float(bands)), bands - 1)
                let strand = 0.5 + 0.5 * sin(v * 2 * Float.pi * 28 + phases[band])
                c *= gains[band] * (0.92 + 0.16 * strand)
                let h = 1 - smoothstep(0, highlightHalfWidth, abs(v - highlightCentre))
                let lift = h * highlightOpacity
                c = c * (1 - lift) + SIMD3<Float>(1, 1, 1) * lift
                image[x, y] = SIMD4(min(c.x, 1), min(c.y, 1), min(c.z, 1), 1)
            }
        }
        return image
    }

    /// Flat portrait icon: a warm background, a hair-coloured cap over a
    /// skin-coloured face disc and two dark eye dots.
    static func thumbnailRaster(hair: HairTexture?, skin: SIMD3<Float>) -> RasterImage {
        let size = thumbnailSize
        var image = RasterImage(width: size, height: size)
        let background = SIMD3<Float>(0.82, 0.86, 0.92)
        let hairColour = hair.map { rgb($0.baseColour) } ?? MaterialRoleDefaults.baseColour(for: .hair)
        let eye = SIMD3<Float>(0.05, 0.05, 0.08)
        let faceCentre = SIMD2<Float>(0.5, 0.56), faceRadius: Float = 0.26
        let capCentre = SIMD2<Float>(0.5, 0.44), capRadius: Float = 0.31
        let eyeOffset = SIMD2<Float>(0.09, 0.02), eyeRadius: Float = 0.035
        for y in 0..<size {
            for x in 0..<size {
                let uv = image.uv(x: x, y: y)
                let p = SIMD2<Float>(Float(uv.x), Float(uv.y))
                var c = background
                if distance(p, capCentre) <= capRadius { c = hairColour }
                if distance(p, faceCentre) <= faceRadius, p.y >= capCentre.y - 0.02 { c = skin }
                for sign: Float in [-1, 1] where distance(p, faceCentre + SIMD2(sign * eyeOffset.x, eyeOffset.y)) <= eyeRadius { c = eye }
                image[x, y] = SIMD4(c.x, c.y, c.z, 1)
            }
        }
        return image
    }

    /// The face-skin role raster with the head shell's scalp and nape
    /// triangles painted in the hair base colour, so the crown reads as a hair
    /// cap between the bob strips. Triangles are rasterised in UV space with a
    /// one-texel bleed.
    static func faceRaster(head: CompiledPrimitive, scalp: Set<Int>, hair: HairTexture?, seed: UInt64) -> RasterImage {
        let size = MaterialRoleDefaults.imageSize(for: .faceSkin)
        var image = MaterialRoleDefaults.raster(for: .faceSkin, width: size, height: size, seed: seed)
        guard let hair, !scalp.isEmpty else { return image }
        let colour = rgb(hair.baseColour)
        let paint = SIMD4<Float>(colour.x, colour.y, colour.z, 1)
        let bleed: Float = 1.0 / Float(size)
        var t = 0
        while t + 2 < head.indices.count {
            let a = Int(head.indices[t]), b = Int(head.indices[t + 1]), c = Int(head.indices[t + 2])
            t += 3
            guard scalp.contains(a), scalp.contains(b), scalp.contains(c), a < head.uv0.count, b < head.uv0.count, c < head.uv0.count else { continue }
            fill(&image, head.uv0[a], head.uv0[b], head.uv0[c], bleed: bleed, colour: paint)
        }
        return image
    }

    static func fill(_ image: inout RasterImage, _ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>, bleed: Float, colour: SIMD4<Float>) {
        let w = Float(image.width), h = Float(image.height)
        let minX = max(Int((min(a.x, b.x, c.x) - bleed) * w), 0), maxX = min(Int((max(a.x, b.x, c.x) + bleed) * w) + 1, image.width - 1)
        let minY = max(Int((min(a.y, b.y, c.y) - bleed) * h), 0), maxY = min(Int((max(a.y, b.y, c.y) + bleed) * h) + 1, image.height - 1)
        guard minX <= maxX, minY <= maxY else { return }
        func edge(_ p: SIMD2<Float>, _ q: SIMD2<Float>, _ r: SIMD2<Float>) -> Float { (q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x) }
        let area = edge(a, b, c)
        guard abs(area) > 1e-12 else { return }
        let sign: Float = area > 0 ? 1 : -1
        let scale = 1 / abs(area)
        for y in minY...maxY {
            for x in minX...maxX {
                let uv = image.uv(x: x, y: y)
                let p = SIMD2<Float>(Float(uv.x), Float(uv.y))
                let e0 = edge(a, b, p) * sign * scale, e1 = edge(b, c, p) * sign * scale, e2 = edge(c, a, p) * sign * scale
                let tolerance = bleed * 2 / (abs(area).squareRoot() + 1e-6)
                if e0 >= -tolerance, e1 >= -tolerance, e2 >= -tolerance { image[x, y] = colour }
            }
        }
    }

    static func rgb(_ colour: Colour) -> SIMD3<Float> {
        let c = ColourTransfer.linearRGBA(colour)
        return SIMD3(c.x, c.y, c.z)
    }

    static func smoothstep(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
        if edge1 == edge0 { return x < edge0 ? 0 : 1 }
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    static func distance(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
        let d = a - b
        return (d.x * d.x + d.y * d.y).squareRoot()
    }
}
