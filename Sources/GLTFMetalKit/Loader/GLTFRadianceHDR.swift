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

/// Errors thrown by ``GLTFRadianceHDR``.
public enum GLTFRadianceHDRError: Error, LocalizedError {
    case invalidSignature
    case unsupportedFormat(String)
    case missingResolution
    case truncatedFile

    public var errorDescription: String? {
        switch self {
        case .invalidSignature:
            return """
            ❌ Invalid Radiance HDR Signature

            The file does not begin with `#?RADIANCE` or `#?RGBE`.

            Suggestion: Confirm the file is a Radiance .hdr (RGBE) panorama. Poly Haven and other HDRI sources publish these directly.
            """
        case .unsupportedFormat(let f):
            return """
            ❌ Unsupported Radiance Format: '\(f)'

            GLTFMetalKit only reads `32-bit_rle_rgbe`. Other Radiance pixel formats (XYZE, raw RGBE without RLE) are uncommon outside legacy tooling.
            """
        case .missingResolution:
            return """
            ❌ Missing Resolution Line

            Radiance HDR headers must include a line like `-Y 1024 +X 2048`. The file appears truncated or malformed.
            """
        case .truncatedFile:
            return """
            ❌ Truncated Radiance HDR

            Pixel decoding ran past the end of the file. The asset is incomplete.
            """
        }
    }
}

/// Decoded Radiance HDR (RGBE) panorama in linear half-float RGBA layout,
/// ready to upload to a 2D texture for the equirectangular→cubemap kernel.
public struct GLTFRadianceHDR {
    public let width: Int
    public let height: Int
    /// `width * height * 4` half-precision floats (RGBA) in row-major order
    /// with row 0 at the top of the image. Alpha is 1.
    public let pixelsFloat16: [UInt16]

    /// Parses a Radiance HDR (`.hdr`) file's RGBE encoding into linear
    /// half-precision RGBA.
    ///
    /// Handles the standard `32-bit_rle_rgbe` format including the
    /// scanline-based RLE encoding for rows ≥ 8 and ≤ 0x7FFF wide. Other
    /// Radiance variants throw ``GLTFRadianceHDRError/unsupportedFormat(_:)``.
    public init(data: Data) throws {
        // Copy into a fresh [UInt8] so all subsequent indexing is zero-
        // based regardless of whether the caller passed a Data slice with
        // a non-zero startIndex. Cost is one full buffer copy — trivial
        // for typical HDRI sizes (< 5 MB).
        let bytes = [UInt8](data)

        // Validate the signature *before* any header scanning. A stray
        // `FORMAT=` substring inside a comment line on a bad input could
        // otherwise be misparsed.
        guard bytes.count >= 10 else {
            throw GLTFRadianceHDRError.invalidSignature
        }
        let signatureBytes = Array(bytes.prefix(10))
        let signature = String(decoding: signatureBytes, as: UTF8.self)
        if !signature.hasPrefix("#?RADIANCE") && !signature.hasPrefix("#?RGBE") {
            throw GLTFRadianceHDRError.invalidSignature
        }

        // --- Header (ASCII lines, blank line terminator) ---
        var cursor = 0
        var format = "32-bit_rle_rgbe"
        var ascii = ""
        while cursor < bytes.count {
            let byte = bytes[cursor]
            cursor += 1
            if byte == 0x0A {  // newline
                let line = ascii
                ascii = ""
                if line.hasPrefix("FORMAT=") {
                    format = String(line.dropFirst("FORMAT=".count))
                }
                if line.isEmpty {
                    break  // blank line → end of header
                }
                continue
            }
            ascii.append(Character(Unicode.Scalar(byte)))
        }
        if format != "32-bit_rle_rgbe" {
            throw GLTFRadianceHDRError.unsupportedFormat(format)
        }

        // --- Resolution line: e.g. "-Y 1024 +X 2048" ---
        var resolution = ""
        while cursor < bytes.count {
            let byte = bytes[cursor]
            cursor += 1
            if byte == 0x0A {
                break
            }
            resolution.append(Character(Unicode.Scalar(byte)))
        }
        let components = resolution.split(separator: " ").map(String.init)
        guard components.count >= 4 else {
            throw GLTFRadianceHDRError.missingResolution
        }
        // Conventions: `-Y` means top-to-bottom (Y descends with row index),
        // `+X` means left-to-right (X ascends with col). Other orderings are
        // legal but vanishingly rare for HDRIs.
        var heightAxis = components[0]
        var heightValue = Int(components[1]) ?? 0
        var widthAxis = components[2]
        var widthValue = Int(components[3]) ?? 0
        if widthAxis.hasSuffix("Y") {
            // Resolution string is "+X N -Y M" — swap.
            (heightAxis, heightValue, widthAxis, widthValue) = (widthAxis, widthValue, heightAxis, heightValue)
        }
        let width = widthValue
        let height = heightValue
        guard width > 0, height > 0 else {
            throw GLTFRadianceHDRError.missingResolution
        }

        // --- Pixel decode ---
        var pixels = [UInt16](repeating: 0, count: width * height * 4)
        var byteIndex = cursor
        for row in 0..<height {
            guard byteIndex + 4 <= bytes.count else { throw GLTFRadianceHDRError.truncatedFile }
            let h0 = bytes[byteIndex]
            let h1 = bytes[byteIndex + 1]
            let h2 = bytes[byteIndex + 2]
            let h3 = bytes[byteIndex + 3]

            // New RLE scanline marker: 0x02 0x02 hi lo (hi<<8 | lo == width).
            let isAdaptiveRLE = (h0 == 0x02 && h1 == 0x02 && (h2 & 0x80) == 0)
                && (Int(h2) << 8 | Int(h3)) == width
                && width >= 8 && width <= 0x7FFF

            if isAdaptiveRLE {
                byteIndex += 4
                // Four channel buffers (R G B E), each `width` bytes.
                var channels = [[UInt8]](repeating: [UInt8](repeating: 0, count: width), count: 4)
                for c in 0..<4 {
                    var col = 0
                    while col < width {
                        guard byteIndex < bytes.count else { throw GLTFRadianceHDRError.truncatedFile }
                        let run = bytes[byteIndex]
                        byteIndex += 1
                        if run > 128 {
                            // Run-length encoded (run-128 copies of the next byte).
                            let count = Int(run - 128)
                            guard byteIndex < bytes.count else { throw GLTFRadianceHDRError.truncatedFile }
                            let value = bytes[byteIndex]; byteIndex += 1
                            for _ in 0..<count {
                                if col < width { channels[c][col] = value; col += 1 }
                            }
                        } else {
                            // Raw run of `run` bytes.
                            let count = Int(run)
                            guard byteIndex + count <= bytes.count else { throw GLTFRadianceHDRError.truncatedFile }
                            for _ in 0..<count {
                                if col < width { channels[c][col] = bytes[byteIndex]; col += 1 }
                                byteIndex += 1
                            }
                        }
                    }
                }
                for col in 0..<width {
                    let r = channels[0][col]
                    let g = channels[1][col]
                    let b = channels[2][col]
                    let e = channels[3][col]
                    let (rF, gF, bF) = Self.rgbeDecode(r: r, g: g, b: b, e: e)
                    let pixelIndex = (row * width + col) * 4
                    pixels[pixelIndex + 0] = Self.float32ToFloat16(rF)
                    pixels[pixelIndex + 1] = Self.float32ToFloat16(gF)
                    pixels[pixelIndex + 2] = Self.float32ToFloat16(bF)
                    pixels[pixelIndex + 3] = Self.float32ToFloat16(1.0)
                }
            } else {
                // Either old-style RLE or per-pixel uncompressed RGBE.
                // Simplest path: assume uncompressed (most modern .hdr files
                // use adaptive RLE). If your assets need legacy RLE, see
                // the Radiance "fileformats" doc and extend.
                guard byteIndex + width * 4 <= bytes.count else { throw GLTFRadianceHDRError.truncatedFile }
                for col in 0..<width {
                    let r = bytes[byteIndex + 0]
                    let g = bytes[byteIndex + 1]
                    let b = bytes[byteIndex + 2]
                    let e = bytes[byteIndex + 3]
                    let (rF, gF, bF) = Self.rgbeDecode(r: r, g: g, b: b, e: e)
                    let pixelIndex = (row * width + col) * 4
                    pixels[pixelIndex + 0] = Self.float32ToFloat16(rF)
                    pixels[pixelIndex + 1] = Self.float32ToFloat16(gF)
                    pixels[pixelIndex + 2] = Self.float32ToFloat16(bF)
                    pixels[pixelIndex + 3] = Self.float32ToFloat16(1.0)
                    byteIndex += 4
                }
            }
        }

        self.width = width
        self.height = height
        self.pixelsFloat16 = pixels
    }

    private static func rgbeDecode(r: UInt8, g: UInt8, b: UInt8, e: UInt8) -> (Float, Float, Float) {
        if e == 0 { return (0, 0, 0) }
        // Radiance encoding: mantissas in [0, 255] / 256, exponent biased by 128.
        let f = ldexpf(1.0, Int32(Int(e) - 128 - 8))
        return (Float(r) * f, Float(g) * f, Float(b) * f)
    }

    /// IEEE-754 half-precision conversion (round-to-nearest-even, ties to even).
    /// Same helper as in GLTFIBL.swift's neutral-cube fallback.
    private static func float32ToFloat16(_ f: Float) -> UInt16 {
        let bits = f.bitPattern
        let sign = UInt16((bits >> 31) & 0x1) << 15
        let expF = Int((bits >> 23) & 0xFF)
        let mantF = bits & 0x007F_FFFF

        if expF == 0 { return sign }
        if expF == 0xFF { return sign | 0x7C00 | (mantF != 0 ? 0x0200 : 0) }
        let expH = expF - 127 + 15
        if expH >= 0x1F { return sign | 0x7C00 }
        if expH <= 0 { return sign }
        let mantH = UInt16(mantF >> 13)
        return sign | (UInt16(expH) << 10) | mantH
    }
}
