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

public class TextureLoader {
    private let device: MTLDevice
    private let textureLoader: MTKTextureLoader
    private let bufferLoader: BufferLoader
    private let document: GLTFDocument
    private let baseURL: URL?

    public init(device: MTLDevice, bufferLoader: BufferLoader, document: GLTFDocument, baseURL: URL? = nil) {
        self.device = device
        self.textureLoader = MTKTextureLoader(device: device)
        self.bufferLoader = bufferLoader
        self.document = document
        self.baseURL = baseURL
    }

    public func loadTexture(at index: Int) async throws -> MTLTexture? {
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

        // Create texture from image data
        return try await createTexture(from: imageData, mimeType: image.mimeType, textureIndex: index)
    }

    private func loadImageFromBufferView(_ bufferViewIndex: Int, textureIndex: Int) throws -> Data {
        guard let bufferView = document.bufferViews?[safe: bufferViewIndex],
              let _ = document.buffers?[safe: bufferView.buffer] else {
            throw VRMError.missingBuffer(
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
            throw VRMError.missingBuffer(
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
            throw VRMError.invalidImageData(
                textureIndex: textureIndex,
                reason: "Data URI missing comma separator in '\(uri.prefix(50))...'",
                filePath: baseURL?.path
            )
        }

        let base64String = String(uri[uri.index(after: commaIndex)...])
        guard let data = Data(base64Encoded: base64String) else {
            throw VRMError.invalidImageData(
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
            throw VRMError.missingTexture(
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

        // Security check: Ensure the resolved path is within the base directory
        let basePath = baseURL.standardized.path
        let filePath = fileURL.standardized.path
        guard filePath.hasPrefix(basePath) else {
            vrmLog("[TextureLoader] Security: Refusing to load file outside base directory: \(uri)")
            throw VRMError.invalidPath(
                path: uri,
                reason: "texture[\(textureIndex)]: Path resolves outside base directory (security violation)",
                filePath: baseURL.path
            )
        }

        // Check if file exists
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            vrmLog("[TextureLoader] Warning: External image file not found: \(fileURL.path)")
            throw VRMError.missingTexture(
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
            throw VRMError.invalidImageData(
                textureIndex: textureIndex,
                reason: "Failed to read external image file '\(uri)': \(error.localizedDescription)",
                filePath: baseURL.path
            )
        }
    }

    private func createTexture(from imageData: Data, mimeType: String?, textureIndex: Int) async throws -> MTLTexture? {
        // Try using CGImage directly to avoid MTKTextureLoader async crash
        if let cgImage = createCGImage(from: imageData) {
            do {
                let texture = try createTexture(from: cgImage, textureIndex: textureIndex)
                return texture
            } catch {
                vrmLog("[TextureLoader] Failed to create texture from CGImage: \(error)")
            }
        }

        // Fallback to MTKTextureLoader if CGImage fails (but this might crash in async context)
        let options: [MTKTextureLoader.Option: Any] = [
            .textureUsage: MTLTextureUsage.shaderRead.rawValue,
            .textureStorageMode: MTLStorageMode.private.rawValue,
            .SRGB: false
        ]

        do {
            let texture = try await textureLoader.newTexture(data: imageData, options: options)
            return texture
        } catch {
            vrmLog("[TextureLoader] Failed to create texture: \(error)")
            throw VRMError.invalidImageData(
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

    private func createTexture(from cgImage: CGImage, textureIndex: Int) throws -> MTLTexture? {
        vrmLog("[TextureLoader] createTexture(from CGImage) called")

        // MTKTextureLoader seems to crash when called from background async context
        // Let's create the texture manually instead

        vrmLog("[TextureLoader] Getting image dimensions...")
        let width = cgImage.width
        let height = cgImage.height
        vrmLog("[TextureLoader] Image size: \(width)x\(height)")

        vrmLog("[TextureLoader] Creating texture descriptor...")
        // Use sRGB for color textures (most VRM textures are color maps)
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm_srgb,  // sRGB for proper color rendering
            width: width,
            height: height,
            mipmapped: false
        )
        textureDescriptor.usage = [.shaderRead]
        textureDescriptor.storageMode = .shared

        vrmLog("[TextureLoader] Creating Metal texture...")
        guard let texture = device.makeTexture(descriptor: textureDescriptor) else {
            vrmLog("[TextureLoader] Failed to create texture")
            return nil
        }
        vrmLog("[TextureLoader] Metal texture created")

        // Create a bitmap context and draw the image
        let bytesPerRow = width * 4
        vrmLog("[TextureLoader] Allocating bitmap data: \(height * bytesPerRow) bytes...")
        let bitmapData = malloc(height * bytesPerRow)
        defer { free(bitmapData) }

        guard let bitmapData = bitmapData else {
            vrmLog("[TextureLoader] Failed to allocate bitmap data")
            return nil
        }
        vrmLog("[TextureLoader] Bitmap data allocated")

        vrmLog("[TextureLoader] Creating CGContext...")
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
            vrmLog("[TextureLoader] Failed to create bitmap context")
            return nil
        }
        vrmLog("[TextureLoader] CGContext created")

        vrmLog("[TextureLoader] Drawing image to context...")
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        vrmLog("[TextureLoader] Image drawn")

        // Copy the data to the texture
        vrmLog("[TextureLoader] Replacing texture data...")
        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0,
            withBytes: bitmapData,
            bytesPerRow: bytesPerRow
        )
        vrmLog("[TextureLoader] Texture data replaced")

        vrmLog("[TextureLoader] Texture created successfully")
        return texture
    }

    public func createSampler(from gltfSampler: GLTFSampler?) -> MTLSamplerState? {
        let descriptor = MTLSamplerDescriptor()

        if let sampler = gltfSampler {
            // Min filter
            switch sampler.minFilter {
            case 9728: // NEAREST
                descriptor.minFilter = .nearest
                descriptor.mipFilter = .notMipmapped
            case 9729: // LINEAR
                descriptor.minFilter = .linear
                descriptor.mipFilter = .notMipmapped
            case 9984: // NEAREST_MIPMAP_NEAREST
                descriptor.minFilter = .nearest
                descriptor.mipFilter = .nearest
            case 9985: // LINEAR_MIPMAP_NEAREST
                descriptor.minFilter = .linear
                descriptor.mipFilter = .nearest
            case 9986: // NEAREST_MIPMAP_LINEAR
                descriptor.minFilter = .nearest
                descriptor.mipFilter = .linear
            case 9987: // LINEAR_MIPMAP_LINEAR
                descriptor.minFilter = .linear
                descriptor.mipFilter = .linear
            default:
                descriptor.minFilter = .linear
                descriptor.mipFilter = .linear
            }

            // Mag filter
            switch sampler.magFilter {
            case 9728: // NEAREST
                descriptor.magFilter = .nearest
            case 9729: // LINEAR
                descriptor.magFilter = .linear
            default:
                descriptor.magFilter = .linear
            }

            // Wrap S
            switch sampler.wrapS {
            case 33071: // CLAMP_TO_EDGE
                descriptor.sAddressMode = .clampToEdge
            case 33648: // MIRRORED_REPEAT
                descriptor.sAddressMode = .mirrorRepeat
            case 10497: // REPEAT
                descriptor.sAddressMode = .repeat
            default:
                descriptor.sAddressMode = .repeat
            }

            // Wrap T
            switch sampler.wrapT {
            case 33071: // CLAMP_TO_EDGE
                descriptor.tAddressMode = .clampToEdge
            case 33648: // MIRRORED_REPEAT
                descriptor.tAddressMode = .mirrorRepeat
            case 10497: // REPEAT
                descriptor.tAddressMode = .repeat
            default:
                descriptor.tAddressMode = .repeat
            }
        } else {
            // Default sampler settings
            descriptor.minFilter = .linear
            descriptor.magFilter = .linear
            descriptor.mipFilter = .linear
            descriptor.sAddressMode = .repeat
            descriptor.tAddressMode = .repeat
        }

        descriptor.maxAnisotropy = 16
        descriptor.normalizedCoordinates = true

        return device.makeSamplerState(descriptor: descriptor)
    }
}