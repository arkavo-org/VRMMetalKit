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
import Metal
import MetalKit
import CoreGraphics
import ImageIO

/// Sequential single-texture loader: decodes a glTF texture and uploads it to an `MTLTexture`.
///
/// ## Discussion
/// `TextureLoader` is the per-texture sibling of ``ParallelTextureLoader``.
/// Use it when you only need one texture at a time (lazy re-loads,
/// substituting a single asset, test fixtures); use ``ParallelTextureLoader``
/// when loading an entire VRM.
///
/// Supported encodings are whatever `CGImageSource` accepts — in practice
/// PNG, JPEG, HEIC, and other formats registered by ImageIO. Images are
/// decoded into 8-bit-per-channel RGBA and uploaded with
/// `.storageModeShared`; alpha is preserved via `CGContext.setBlendMode(.copy)`.
///
/// Image data is resolved in the same order as ``BufferLoader``: embedded
/// buffer view first, then `data:` URI, then external file (subject to
/// path-traversal checks against `baseURL`). The companion
/// ``createSampler(from:)`` method maps a ``GLTFSampler`` to an
/// `MTLSamplerState`.
public class TextureLoader {
    private let device: MTLDevice
    private let textureLoader: MTKTextureLoader
    private let bufferLoader: BufferLoader
    private let document: GLTFDocument
    private let baseURL: URL?

    /// When `true`, sRGB color textures are re-encoded as BC7 at load
    /// (``VRMLoadingOptimization/aggressiveTextureCompression``). Linear
    /// maps are never compressed.
    public var compressColorTextures: Bool = false

    /// Creates a loader bound to a Metal device, parsed document, and an existing ``BufferLoader``.
    ///
    /// - Parameters:
    ///   - device: Metal device for `MTLTexture` allocation.
    ///   - bufferLoader: ``BufferLoader`` used to resolve embedded image bytes.
    ///   - document: The decoded ``GLTFDocument``.
    ///   - baseURL: Directory used to resolve relative image URIs. External-file reads outside this directory are rejected.
    public init(device: MTLDevice, bufferLoader: BufferLoader, document: GLTFDocument, baseURL: URL? = nil) {
        self.device = device
        self.textureLoader = MTKTextureLoader(device: device)
        self.bufferLoader = bufferLoader
        self.document = document
        self.baseURL = baseURL
    }

    /// Decodes a single glTF texture and uploads it to an `MTLTexture`.
    ///
    /// - Parameters:
    ///   - index: Texture index in ``GLTFDocument/textures``.
    ///   - sRGB: Treat the texture as sRGB color (default). Pass `false` for linear data such as normal, AO, metallic-roughness, or mask textures.
    /// - Returns: The decoded `MTLTexture`, or `nil` if the texture or its source image cannot be resolved.
    /// - Throws: ``GLTFError/missingBuffer(bufferIndex:requiredBy:expectedSize:filePath:)``, ``GLTFError/missingTexture(textureIndex:materialName:uri:filePath:)``, ``GLTFError/invalidImageData(textureIndex:reason:filePath:)``, or ``GLTFError/invalidPath(path:reason:filePath:)`` per the failure mode.
    public func loadTexture(at index: Int, sRGB: Bool = true) async throws -> MTLTexture? {
        guard let gltfTexture = document.textures?[safe: index] else {
            vrmLog("[TextureLoader] Warning: No texture at index \(index)")
            return nil
        }

        guard let sourceIndex = gltfTexture.source else {
            vrmLog("[TextureLoader] Warning: Texture \(index) has no source")
            return nil
        }

        guard let images = document.images, sourceIndex < images.count else {
            vrmLog("[TextureLoader] Error: Source index \(sourceIndex) out of bounds for images array (count: \(document.images?.count ?? 0))")
            return nil
        }

        let image = images[sourceIndex]

        // Load image data
        let imageData: Data

        if let bufferViewIndex = image.bufferView {
            // Image is embedded in buffer
            imageData = try loadImageFromBufferView(bufferViewIndex, textureIndex: index)
        } else if let uri = image.uri {
            if uri.hasPrefix("data:") {
                // Data URI
                imageData = try loadImageFromDataURI(uri, textureIndex: index)
            } else {
                // External file
                imageData = try loadImageFromExternalFile(uri, textureIndex: index)
            }
        } else {
            return nil
        }

        // Whether to build a mip chain is the sampler's call.
        let sampler = gltfTexture.sampler.flatMap { document.samplers?[safe: $0] }
        let mipmapped = TextureLoader.samplerRequestsMipmaps(sampler)

        // Create texture from image data
        return try await createTexture(from: imageData, mimeType: image.mimeType, textureIndex: index,
                                       sRGB: sRGB, mipmapped: mipmapped,
                                       alphaIsCoverage: Self.textureAlphaIsCoverage(index, in: document))
    }

    /// Whether a texture's alpha channel is coverage — i.e. whether the mip
    /// chain should weight RGB by alpha (see ``TextureMipUploader``).
    ///
    /// True iff some material binds the texture as `baseColorTexture` with
    /// `alphaMode` `MASK` or `BLEND` — the only slot where glTF gives alpha
    /// coverage semantics. `OPAQUE` base color ignores alpha by spec, and
    /// metallic-roughness / occlusion / normal / emissive carry data (or
    /// nothing) in alpha, so weighting by it would bias or erase real
    /// channels. Materials that don't state `alphaMode` are `OPAQUE`
    /// (spec default). A texture nobody binds as base color — including
    /// extension-only slots such as MToon's shade/matcap/rim maps — filters
    /// independently. (VRoid often binds one image as both base color and
    /// MToon shade; it is then weighted, which is harmless: the shade map's
    /// alpha is unused and the two are sampled at the same UVs, where the
    /// base color's alpha already governs visibility.) Only the glTF
    /// `alphaMode` is consulted — a VRM 0.x material that states its
    /// transparency solely in `materialProperties` degrades to independent
    /// filtering, i.e. GPU-mipgen behavior, never data loss.
    public static func textureAlphaIsCoverage(_ index: Int, in document: GLTFDocument) -> Bool {
        for material in document.materials ?? [] {
            guard material.pbrMetallicRoughness?.baseColorTexture?.index == index else { continue }
            switch material.alphaMode {
            case "MASK", "BLEND":
                return true
            default:
                continue
            }
        }
        return false
    }

    /// Whether a glTF sampler asks for a mip chain.
    ///
    /// `minFilter` `9984`–`9987` (`*_MIPMAP_*`) requests one; `9728` NEAREST
    /// and `9729` LINEAR explicitly decline one. An absent sampler or absent
    /// `minFilter` leaves the choice to the runtime (per the glTF spec) —
    /// default to mipmapping, matching ``createSampler(from:)``'s existing
    /// trilinear default for the same cases, so a chain always backs the
    /// sampler state we build; three.js's GLTFLoader defaults an undefined
    /// `minFilter` the same way (LinearMipmapLinear). This is a deliberate
    /// runtime default, not reference parity: UniVRM v0.131.2 deserializes
    /// an omitted `minFilter` to NEAREST (no mips), and a texture with no
    /// `sampler` field uses `samplers[0]` if the array exists (its
    /// non-nullable int defaults to 0) and Bilinear+mips only when it
    /// doesn't.
    public static func samplerRequestsMipmaps(_ sampler: GLTFSampler?) -> Bool {
        switch sampler?.minFilter {
        case 9728, 9729:
            return false
        default:
            return true
        }
    }

    private func loadImageFromBufferView(_ bufferViewIndex: Int, textureIndex: Int) throws -> Data {
        guard let bufferView = document.bufferViews?[safe: bufferViewIndex],
              let _ = document.buffers?[safe: bufferView.buffer] else {
            throw GLTFError.missingBuffer(
                bufferIndex: bufferViewIndex,
                requiredBy: "texture[\(textureIndex)] loading from bufferView",
                expectedSize: nil,
                filePath: baseURL?.path
            )
        }

        // Get binary data from buffer loader
        let bufferData = try bufferLoader.getBufferData(bufferIndex: bufferView.buffer)

        let offset = bufferView.byteOffset ?? 0
        let length = bufferView.byteLength

        guard offset + length <= bufferData.count else {
            throw GLTFError.missingBuffer(
                bufferIndex: bufferView.buffer,
                requiredBy: "texture[\(textureIndex)] buffer data validation (offset: \(offset), length: \(length), available: \(bufferData.count))",
                expectedSize: offset + length,
                filePath: baseURL?.path
            )
        }

        return bufferData.subdata(in: offset..<(offset + length))
    }

    private func loadImageFromDataURI(_ uri: String, textureIndex: Int) throws -> Data {
        guard let commaIndex = uri.firstIndex(of: ",") else {
            throw GLTFError.invalidImageData(
                textureIndex: textureIndex,
                reason: "Data URI missing comma separator in '\(uri.prefix(50))...'",
                filePath: baseURL?.path
            )
        }

        let base64String = String(uri[uri.index(after: commaIndex)...])
        guard let data = Data(base64Encoded: base64String) else {
            throw GLTFError.invalidImageData(
                textureIndex: textureIndex,
                reason: "Failed to decode base64 data from URI",
                filePath: baseURL?.path
            )
        }

        return data
    }

    private func loadImageFromExternalFile(_ uri: String, textureIndex: Int) throws -> Data {
        guard let baseURL = baseURL else {
            vrmLog("[TextureLoader] Warning: Cannot load external file without base URL: \(uri)")
            throw GLTFError.missingTexture(
                textureIndex: textureIndex,
                materialName: nil,
                uri: uri,
                filePath: nil
            )
        }

        // Resolve the URI relative to the base URL
        let fileURL: URL
        if uri.hasPrefix("/") {
            // Absolute path (not recommended for portability)
            fileURL = URL(fileURLWithPath: uri)
        } else {
            // Relative path
            fileURL = baseURL.appendingPathComponent(uri)
        }

        // Security check: Ensure the resolved path is within the base directory.
        // `resolvingSymlinksInPath()` follows symlinks so a link inside the base
        // directory cannot redirect reads to an arbitrary file outside it.
        let basePath = baseURL.standardized.resolvingSymlinksInPath().path
        let filePath = fileURL.standardized.resolvingSymlinksInPath().path
        guard filePath.hasPrefix(basePath) else {
            vrmLog("[TextureLoader] Security: Refusing to load file outside base directory: \(uri)")
            throw GLTFError.invalidPath(
                path: uri,
                reason: "texture[\(textureIndex)]: Path resolves outside base directory (security violation)",
                filePath: baseURL.path
            )
        }

        // Check if file exists
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            vrmLog("[TextureLoader] Warning: External image file not found: \(fileURL.path)")
            throw GLTFError.missingTexture(
                textureIndex: textureIndex,
                materialName: nil,
                uri: uri,
                filePath: baseURL.path
            )
        }

        // Load the image data
        do {
            let data = try Data(contentsOf: fileURL)
            vrmLog("[TextureLoader] Loaded external image: \(uri) (\(data.count) bytes)")
            return data
        } catch {
            vrmLog("[TextureLoader] Error loading external image: \(error)")
            throw GLTFError.invalidImageData(
                textureIndex: textureIndex,
                reason: "Failed to read external image file '\(uri)': \(error.localizedDescription)",
                filePath: baseURL.path
            )
        }
    }

    private func createTexture(from imageData: Data, mimeType: String?, textureIndex: Int, sRGB: Bool, mipmapped: Bool, alphaIsCoverage: Bool) async throws -> MTLTexture? {
        // Try using CGImage directly to avoid MTKTextureLoader async crash
        if let cgImage = createCGImage(from: imageData) {
            do {
                let texture = try createTexture(from: cgImage, textureIndex: textureIndex, sRGB: sRGB,
                                                mipmapped: mipmapped, alphaIsCoverage: alphaIsCoverage)
                return texture
            } catch {
                vrmLog("[TextureLoader] Failed to create texture from CGImage: \(error)")
            }
        }

        // Fallback to MTKTextureLoader if CGImage fails (but this might crash in async context)
        let options: [MTKTextureLoader.Option: Any] = [
            .textureUsage: MTLTextureUsage.shaderRead.rawValue,
            .textureStorageMode: MTLStorageMode.private.rawValue,
            .SRGB: sRGB
        ]

        do {
            let texture = try await textureLoader.newTexture(data: imageData, options: options)
            if compressColorTextures && sRGB,
               let compressed = TextureBlockCompressor.compress(texture, device: device) {
                return compressed
            }
            return texture
        } catch {
            vrmLog("[TextureLoader] Failed to create texture: \(error)")
            throw GLTFError.invalidImageData(
                textureIndex: textureIndex,
                reason: "Failed to create Metal texture from image data (mimeType: \(mimeType ?? "unknown")): \(error.localizedDescription)",
                filePath: baseURL?.path
            )
        }
    }

    private func createCGImage(from data: Data) -> CGImage? {
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            return nil
        }
        return cgImage
    }

    private func createTexture(from cgImage: CGImage, textureIndex: Int, sRGB: Bool, mipmapped: Bool, alphaIsCoverage: Bool) throws -> MTLTexture? {
        vrmLog("[TextureLoader] createTexture(from CGImage) called, sRGB=\(sRGB), mipmapped=\(mipmapped), alphaIsCoverage=\(alphaIsCoverage)")

        // MTKTextureLoader seems to crash when called from background async context
        // Let's create the texture manually instead

        vrmLog("[TextureLoader] Getting image dimensions...")
        let width = cgImage.width
        let height = cgImage.height
        vrmLog("[TextureLoader] Image size: \(width)x\(height)")

        let pixelFormat: MTLPixelFormat = sRGB ? .rgba8Unorm_srgb : .rgba8Unorm

        // Decodes straight-alpha (the pipelines blend with straight-alpha
        // factors); the sampler decides whether a mip chain is built and the
        // material's use of the texture whether alpha weights it. See
        // TextureUploader / TextureMipUploader.
        vrmLog("[TextureLoader] Uploading texture...")
        guard let texture = TextureUploader.makeTexture(
            cgImage: cgImage,
            pixelFormat: pixelFormat,
            device: device,
            mipmapped: mipmapped,
            alphaIsCoverage: alphaIsCoverage,
            blockCompress: compressColorTextures && sRGB
        ) else {
            vrmLog("[TextureLoader] Failed to create texture")
            return nil
        }

        vrmLog("[TextureLoader] Texture created successfully")
        return texture
    }

    /// Builds an `MTLSamplerState` from an optional ``GLTFSampler``, falling back to a sensible default when `nil`.
    ///
    /// Maps glTF magFilter/minFilter constants (`9728` NEAREST, `9729`
    /// LINEAR, plus mipmap variants) and wrap modes (`33071` CLAMP_TO_EDGE,
    /// `33648` MIRRORED_REPEAT, `10497` REPEAT) onto their Metal
    /// equivalents. Default sampling is bilinear with mipmaps and repeat
    /// wrap on both axes. Max anisotropy is always 16.
    ///
    /// Allocates a fresh state per call. Renderers that need one state per
    /// texture should go through ``GLTFSamplerCache`` instead, which shares
    /// states between samplers that resolve to the same descriptor.
    ///
    /// - Parameter gltfSampler: Source sampler, or `nil` to request defaults.
    /// - Returns: The configured `MTLSamplerState`, or `nil` if Metal allocation fails.
    public func createSampler(from gltfSampler: GLTFSampler?) -> MTLSamplerState? {
        device.makeSamplerState(descriptor: GLTFSamplerCache.descriptor(for: gltfSampler))
    }
}