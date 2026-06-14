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

//
//  ParallelTextureLoader.swift
//  VRMMetalKit
//
//  High-performance parallel texture loading with optimization support.
//

@preconcurrency import Foundation
@preconcurrency import Metal
@preconcurrency import MetalKit

/// Decodes and uploads many glTF textures to `MTLTexture` concurrently.
///
/// ## Discussion
/// Texture loading combines `CGImageSource` decode (PNG, JPEG, HEIC, and
/// other formats registered by ImageIO),
/// premultiplied-alpha-aware CPU-side blit, and a single
/// `MTLTexture.replace(...)` upload per image. The image-decode step is the
/// dominant cost; running it across a `TaskGroup` reduces wall-clock time
/// roughly linearly with core count.
///
/// Linear-vs-sRGB upload format is driven by the caller. Failure to flag a
/// linear texture (normal, metallic-roughness, occlusion, mask) produces
/// visibly wrong shading after a gamma curve is applied twice. For glTF
/// PBR pipelines, callers should pass *every* non-color slot (normal, MR,
/// occlusion) via ``loadTexturesParallel(indices:linearTextureIndices:progressCallback:)``;
/// the older ``loadTexturesParallel(indices:normalMapIndices:progressCallback:)``
/// is preserved for VRM/MToon callers but only covers normal maps.
///
/// The loader is `@unchecked Sendable`. Completion order is indeterminate;
/// the returned map is keyed by source texture index. A Metal device is required.
public final class ParallelTextureLoader: @unchecked Sendable {
    private let device: MTLDevice
    private let textureLoader: MTKTextureLoader
    private let bufferLoader: BufferLoader
    private let document: GLTFDocument
    private let baseURL: URL?

    private let maxConcurrentLoads: Int

    /// Creates a loader bound to a Metal device, parsed document, and buffer loader.
    ///
    /// - Parameters:
    ///   - device: Metal device for `MTLTexture` allocation.
    ///   - bufferLoader: ``BufferLoader`` used to resolve embedded image bytes.
    ///   - document: The decoded ``GLTFDocument``.
    ///   - baseURL: Directory used to resolve relative image URIs. External-file reads outside this directory are rejected.
    ///   - maxConcurrentLoads: Reserved for future use; currently advisory only.
    public init(
        device: MTLDevice,
        bufferLoader: BufferLoader,
        document: GLTFDocument,
        baseURL: URL? = nil,
        maxConcurrentLoads: Int = 4
    ) {
        self.device = device
        self.textureLoader = MTKTextureLoader(device: device)
        self.bufferLoader = bufferLoader
        self.document = document
        self.baseURL = baseURL
        self.maxConcurrentLoads = maxConcurrentLoads
    }

    /// Decodes and uploads the requested glTF textures in parallel.
    ///
    /// VRM/MToon variant — only flags normal maps as linear. PBR consumers
    /// should use ``loadTexturesParallel(indices:linearTextureIndices:progressCallback:)``
    /// instead, which accepts the full set of linear-data slots
    /// (normal + metallic-roughness + occlusion).
    ///
    /// - Parameters:
    ///   - indices: Texture indices to load. Out-of-range indices are skipped silently.
    ///   - normalMapIndices: Indices that must be uploaded as linear (not sRGB). All indices not in this set default to sRGB.
    ///   - progressCallback: Invoked on the main actor as each texture completes. Receives `(loaded, total)`.
    /// - Returns: Map from glTF texture index to allocated `MTLTexture`. Failed loads are omitted.
    public func loadTexturesParallel(
        indices: [Int],
        normalMapIndices: Set<Int>,
        progressCallback: (@Sendable (Int, Int) -> Void)? = nil
    ) async -> [Int: MTLTexture] {
        await loadTexturesParallel(
            indices: indices,
            linearTextureIndices: normalMapIndices,
            progressCallback: progressCallback
        )
    }

    /// Decodes and uploads the requested glTF textures in parallel, with explicit
    /// per-texture color-space control.
    ///
    /// glTF 2.0 mandates these slots be linear: normal, metallic-roughness,
    /// occlusion, and any other data textures (masks, channel-packed maps).
    /// Color textures (baseColor, emissive) are sRGB. Callers must pass every
    /// linear-data texture index here; everything not listed defaults to sRGB.
    ///
    /// - Parameters:
    ///   - indices: Texture indices to load. Out-of-range indices are skipped silently.
    ///   - linearTextureIndices: Indices that must be uploaded as linear (`.rgba8Unorm`). Everything else defaults to sRGB (`.rgba8Unorm_srgb`).
    ///   - progressCallback: Invoked on the main actor as each texture completes. Receives `(loaded, total)`.
    /// - Returns: Map from glTF texture index to allocated `MTLTexture`. Failed loads are omitted.
    public func loadTexturesParallel(
        indices: [Int],
        linearTextureIndices: Set<Int>,
        progressCallback: (@Sendable (Int, Int) -> Void)? = nil
    ) async -> [Int: MTLTexture] {
        let totalCount = indices.count
        var results: [Int: MTLTexture] = [:]
        var loaded = 0

        await withTaskGroup(of: (Int, MTLTexture?).self) { group in
            for textureIndex in indices {
                group.addTask { [unowned self] in
                    let isLinear = linearTextureIndices.contains(textureIndex)
                    let texture = try? await self.loadTexture(at: textureIndex, sRGB: !isLinear)
                    return (textureIndex, texture)
                }
            }

            // Coalesce progress hops to the main actor instead of one per texture.
            let reporter = CoalescedProgressReporter(total: totalCount, callback: progressCallback)
            for await (index, texture) in group {
                loaded += 1
                if let texture {
                    results[index] = texture
                }
                await reporter.reportIfNeeded(completed: loaded)
            }
        }

        return results
    }
    
    private func loadTexture(at index: Int, sRGB: Bool = true) async throws -> MTLTexture? {
        guard let gltfTexture = document.textures?[safe: index],
              let sourceIndex = gltfTexture.source,
              let images = document.images,
              sourceIndex < images.count else {
            return nil
        }
        
        let image = images[sourceIndex]
        
        let imageData: Data
        if let bufferViewIndex = image.bufferView {
            imageData = try loadImageFromBufferView(bufferViewIndex, textureIndex: index)
        } else if let uri = image.uri {
            if uri.hasPrefix("data:") {
                imageData = try loadImageFromDataURI(uri, textureIndex: index)
            } else {
                imageData = try loadImageFromExternalFile(uri, textureIndex: index)
            }
        } else {
            return nil
        }
        
        return try await createTexture(from: imageData, textureIndex: index, sRGB: sRGB)
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
        
        let bufferData = try bufferLoader.getBufferData(bufferIndex: bufferView.buffer)
        let offset = bufferView.byteOffset ?? 0
        let length = bufferView.byteLength
        
        guard offset + length <= bufferData.count else {
            throw GLTFError.missingBuffer(
                bufferIndex: bufferView.buffer,
                requiredBy: "texture[\(textureIndex)] buffer data validation",
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
                reason: "Data URI missing comma separator",
                filePath: baseURL?.path
            )
        }
        
        let base64String = String(uri[uri.index(after: commaIndex)...])
        guard let data = Data(base64Encoded: base64String) else {
            throw GLTFError.invalidImageData(
                textureIndex: textureIndex,
                reason: "Failed to decode base64 data",
                filePath: baseURL?.path
            )
        }
        
        return data
    }
    
    private func loadImageFromExternalFile(_ uri: String, textureIndex: Int) throws -> Data {
        guard let baseURL = baseURL else {
            throw GLTFError.missingTexture(
                textureIndex: textureIndex,
                materialName: nil,
                uri: uri,
                filePath: nil
            )
        }
        
        let fileURL = uri.hasPrefix("/") ? URL(fileURLWithPath: uri) : baseURL.appendingPathComponent(uri)
        
        let basePath = baseURL.standardized.path
        let filePath = fileURL.standardized.path
        guard filePath.hasPrefix(basePath) else {
            throw GLTFError.invalidPath(
                path: uri,
                reason: "Path resolves outside base directory",
                filePath: baseURL.path
            )
        }
        
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw GLTFError.missingTexture(
                textureIndex: textureIndex,
                materialName: nil,
                uri: uri,
                filePath: baseURL.path
            )
        }
        
        return try Data(contentsOf: fileURL)
    }
    
    private func createTexture(from imageData: Data, textureIndex: Int, sRGB: Bool) async throws -> MTLTexture? {
        guard let imageSource = CGImageSourceCreateWithData(imageData as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            throw GLTFError.invalidImageData(
                textureIndex: textureIndex,
                reason: "Failed to decode image data",
                filePath: baseURL?.path
            )
        }
        
        let width = cgImage.width
        let height = cgImage.height
        let pixelFormat: MTLPixelFormat = sRGB ? .rgba8Unorm_srgb : .rgba8Unorm
        
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        textureDescriptor.usage = [.shaderRead]
        textureDescriptor.storageMode = .shared
        
        guard let texture = device.makeTexture(descriptor: textureDescriptor) else {
            return nil
        }
        
        let bytesPerRow = width * 4
        guard let bitmapData = malloc(height * bytesPerRow) else {
            return nil
        }
        defer { free(bitmapData) }
        
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: bitmapData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        
        context.setBlendMode(.copy)
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        
        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0,
            withBytes: bitmapData,
            bytesPerRow: bytesPerRow
        )
        
        return texture
    }
}

