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

import Accelerate
import CoreGraphics
import Metal

/// Decodes a `CGImage` into a Metal texture holding straight
/// (non-premultiplied) alpha.
///
/// The quality bug this fixes is **double alpha multiplication**:
/// `CGContext` decodes with premultiplied alpha, and uploading those bytes
/// directly while the blend pipelines use `.sourceAlpha` factors multiplies
/// partial-alpha texels by alpha twice (rgb·a²). Alpha-blended art (mouths,
/// brows) darkens toward black at every soft edge — invisible up close where
/// interiors dominate, but a heavy dark border once the art shrinks to a few
/// screen pixels.
///
/// PNG stores unassociated (straight) alpha by spec and the pipelines
/// consume straight alpha, so the decode is the only place the two can
/// disagree. ``makeTexture(cgImage:pixelFormat:device:)`` therefore decodes
/// straight in the first place, via `vImageBuffer_InitWithCGImage` into an
/// unpremultiplied format. Going through a `CGBitmapContext` instead — which
/// cannot represent unpremultiplied 8-bit RGBA — premultiplies and quantizes
/// to 8 bits, and unpremultiplying afterwards only approximates the inverse:
/// error grows as 1/alpha, and texels at alpha 0 lose their color outright.
enum TextureUploader {

    /// Decodes `cgImage` and uploads it as a straight-alpha texture.
    ///
    /// - Parameters:
    ///   - cgImage: Decoded image, typically from `CGImageSource`.
    ///   - pixelFormat: `.rgba8Unorm` or `.rgba8Unorm_srgb`.
    ///   - device: Device to allocate on.
    /// - Returns: A texture holding the straight-alpha image, or `nil` if
    ///   both the straight decode and the premultiplied fallback fail.
    static func makeTexture(cgImage: CGImage,
                            pixelFormat: MTLPixelFormat,
                            device: MTLDevice) -> MTLTexture? {
        if let texture = makeTextureFromStraightDecode(cgImage: cgImage,
                                                       pixelFormat: pixelFormat,
                                                       device: device) {
            return texture
        }
        vrmLog("[TextureUploader] Straight decode unavailable for this image; falling back to premultiplied context")
        return makeTextureFromPremultipliedContext(cgImage: cgImage,
                                                   pixelFormat: pixelFormat,
                                                   device: device)
    }

    /// Decodes directly into unpremultiplied RGBA8888, so the stored bytes
    /// are the bytes the source image holds.
    private static func makeTextureFromStraightDecode(cgImage: CGImage,
                                                      pixelFormat: MTLPixelFormat,
                                                      device: MTLDevice) -> MTLTexture? {
        guard var format = vImage_CGImageFormat(
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            colorSpace: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue
                | CGBitmapInfo.byteOrder32Big.rawValue),
            renderingIntent: .defaultIntent
        ) else { return nil }

        var buffer = vImage_Buffer()
        let status = vImageBuffer_InitWithCGImage(&buffer, &format, nil, cgImage,
                                                  vImage_Flags(kvImageNoFlags))
        guard status == kvImageNoError, let data = buffer.data else { return nil }
        defer { free(data) }

        return makeTexture(bytes: data,
                           width: Int(buffer.width),
                           height: Int(buffer.height),
                           bytesPerRow: buffer.rowBytes,
                           pixelFormat: pixelFormat,
                           device: device)
    }

    /// Draws into a premultiplied bitmap context and unpremultiplies, for
    /// images `vImageBuffer_InitWithCGImage` cannot convert.
    private static func makeTextureFromPremultipliedContext(cgImage: CGImage,
                                                            pixelFormat: MTLPixelFormat,
                                                            device: MTLDevice) -> MTLTexture? {
        let width = cgImage.width
        let height = cgImage.height
        let bytesPerRow = width * 4
        guard let bitmapData = malloc(height * bytesPerRow) else { return nil }
        defer { free(bitmapData) }

        // `.copy` blend mode: source-over compositing destroys alpha=0 pixels.
        guard let context = CGContext(
            data: bitmapData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setBlendMode(.copy)
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        return makeTexture(bitmapData: bitmapData,
                           width: width, height: height,
                           pixelFormat: pixelFormat,
                           device: device)
    }

    /// Unpremultiplies `bitmapData` in place and uploads it.
    ///
    /// - Parameters:
    ///   - bitmapData: Bitmap as decoded by `CGContext` with
    ///     `.premultipliedLast` (RGBA, 4 bytes per pixel, tightly packed rows).
    ///     Unpremultiplied in place; on return it holds straight alpha.
    ///   - width: Bitmap width in pixels.
    ///   - height: Bitmap height in pixels.
    ///   - pixelFormat: `.rgba8Unorm` or `.rgba8Unorm_srgb`.
    ///   - device: Device to allocate on.
    /// - Returns: A texture holding the straight-alpha image, or `nil` on
    ///   allocation or unpremultiply failure.
    static func makeTexture(bitmapData: UnsafeMutableRawPointer,
                            width: Int, height: Int,
                            pixelFormat: MTLPixelFormat,
                            device: MTLDevice) -> MTLTexture? {
        // vImageUnpremultiplyData_RGBA8888 operates in place when source and
        // destination share `data` and `rowBytes`.
        var buffer = vImage_Buffer(data: bitmapData,
                                   height: vImagePixelCount(height),
                                   width: vImagePixelCount(width),
                                   rowBytes: width * 4)
        let status = vImageUnpremultiplyData_RGBA8888(&buffer, &buffer, vImage_Flags(kvImageNoFlags))
        guard status == kvImageNoError else { return nil }

        return makeTexture(bytes: bitmapData,
                           width: width, height: height,
                           bytesPerRow: width * 4,
                           pixelFormat: pixelFormat,
                           device: device)
    }

    private static func makeTexture(bytes: UnsafeMutableRawPointer,
                                    width: Int, height: Int,
                                    bytesPerRow: Int,
                                    pixelFormat: MTLPixelFormat,
                                    device: MTLDevice) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }

        texture.replace(region: MTLRegionMake2D(0, 0, width, height),
                        mipmapLevel: 0,
                        withBytes: bytes,
                        bytesPerRow: bytesPerRow)

        #if DEBUG
        let first = bytes.assumingMemoryBound(to: UInt8.self)
        vrmLog("[TextureUploader] First uploaded pixel RGBA: (\(first[0]), \(first[1]), \(first[2]), \(first[3]))")
        #endif

        return texture
    }
}
