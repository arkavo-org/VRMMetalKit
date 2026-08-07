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
import Metal

/// Uploads a CG-decoded RGBA bitmap as a Metal texture with straight
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
/// The fix: unpremultiply before upload so the straight-alpha contract the
/// pipelines assume actually holds.
enum TextureUploader {

    /// Creates a texture from premultiplied RGBA8888 bitmap data,
    /// unpremultiplying it on the way in.
    ///
    /// - Parameters:
    ///   - premultipliedData: Bitmap as decoded by `CGContext` with
    ///     `.premultipliedLast` (RGBA, 4 bytes per pixel, tightly packed rows).
    ///   - width: Bitmap width in pixels.
    ///   - height: Bitmap height in pixels.
    ///   - pixelFormat: `.rgba8Unorm` or `.rgba8Unorm_srgb`.
    ///   - device: Device to allocate on.
    /// - Returns: A texture holding the straight-alpha image, or `nil` on
    ///   allocation failure.
    static func makeTexture(premultipliedData: UnsafeMutableRawPointer,
                            width: Int, height: Int,
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

        var premul = vImage_Buffer(data: premultipliedData,
                                   height: vImagePixelCount(height),
                                   width: vImagePixelCount(width),
                                   rowBytes: width * 4)
        guard let scratch = malloc(height * width * 4) else { return nil }
        defer { free(scratch) }
        var straight = vImage_Buffer(data: scratch,
                                     height: premul.height,
                                     width: premul.width,
                                     rowBytes: width * 4)
        vImageUnpremultiplyData_RGBA8888(&premul, &straight, vImage_Flags(kvImageNoFlags))
        texture.replace(region: MTLRegionMake2D(0, 0, width, height),
                        mipmapLevel: 0,
                        withBytes: scratch,
                        bytesPerRow: width * 4)
        return texture
    }
}
