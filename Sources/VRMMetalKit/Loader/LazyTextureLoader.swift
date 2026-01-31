//
//  LazyTextureLoader.swift
//  VRMMetalKit
//
//  Lazy texture loading - loads textures on first use instead of at startup.
//

@preconcurrency import Foundation
@preconcurrency import Metal

/// Manages lazy texture loading for VRM models.
///
/// Instead of loading all textures at model load time, textures are loaded
/// on first access. This significantly improves initial load time for models
/// with many textures where not all are immediately visible.
public actor LazyTextureLoader {
    private let device: MTLDevice
    private let bufferLoader: BufferLoader
    private let document: GLTFDocument
    private let baseURL: URL?
    
    /// Texture cache for loaded textures
    private var textureCache: [Int: MTLTexture] = [:]
    
    /// Track which textures are currently loading
    private var loadingTasks: [Int: Task<MTLTexture?, Error>] = [:]
    
    /// Indices of normal map textures (need linear format)
    private let normalMapIndices: Set<Int>
    
    /// Placeholder texture (1x1 transparent)
    private var placeholderTexture: MTLTexture?
    
    public init(
        device: MTLDevice,
        bufferLoader: BufferLoader,
        document: GLTFDocument,
        baseURL: URL?,
        normalMapIndices: Set<Int>
    ) {
        self.device = device
        self.bufferLoader = bufferLoader
        self.document = document
        self.baseURL = baseURL
        self.normalMapIndices = normalMapIndices
    }
    
    /// Get a texture, loading it lazily if needed.
    ///
    /// If the texture is already loaded, returns it immediately.
    /// If loading is in progress, waits for it to complete.
    /// Otherwise, starts loading and returns a placeholder.
    public func getTexture(at index: Int) async -> MTLTexture? {
        // Return cached texture if available
        if let cached = textureCache[index] {
            return cached
        }
        
        // If already loading, wait for it
        if let task = loadingTasks[index] {
            do {
                return try await task.value
            } catch {
                return nil
            }
        }
        
        // Start loading in background
        let task = Task<MTLTexture?, Error> {
            defer { 
                Task { await self.loadingTaskCompleted(for: index) }
            }
            return try await loadTexture(at: index)
        }
        
        loadingTasks[index] = task
        
        // Return placeholder for immediate use
        return getPlaceholderTexture()
    }
    
    /// Preload specific textures.
    ///
    /// Call this for textures that should be loaded immediately
    /// rather than lazily.
    public func preloadTextures(indices: [Int]) async {
        await withTaskGroup(of: Void.self) { group in
            for index in indices {
                group.addTask {
                    _ = await self.getTexture(at: index)
                }
            }
        }
    }
    
    /// Check if a texture is loaded.
    public func isTextureLoaded(at index: Int) -> Bool {
        return textureCache[index] != nil
    }
    
    /// Get loading progress.
    public func getLoadingProgress() -> (loaded: Int, total: Int) {
        let total = document.textures?.count ?? 0
        let loaded = textureCache.count
        return (loaded, total)
    }
    
    // MARK: - Private
    
    private func loadingTaskCompleted(for index: Int) {
        loadingTasks.removeValue(forKey: index)
    }
    
    private func loadTexture(at index: Int) async throws -> MTLTexture? {
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
        
        let isNormalMap = normalMapIndices.contains(index)
        let texture = try await createTexture(from: imageData, textureIndex: index, sRGB: !isNormalMap)
        
        if let texture = texture {
            textureCache[index] = texture
        }
        
        return texture
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
        
        let bufferData = try bufferLoader.getBufferData(bufferIndex: bufferView.buffer)
        let offset = bufferView.byteOffset ?? 0
        let length = bufferView.byteLength
        
        guard offset + length <= bufferData.count else {
            throw VRMError.missingBuffer(
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
            throw VRMError.invalidImageData(
                textureIndex: textureIndex,
                reason: "Data URI missing comma separator",
                filePath: baseURL?.path
            )
        }
        
        let base64String = String(uri[uri.index(after: commaIndex)...])
        guard let data = Data(base64Encoded: base64String) else {
            throw VRMError.invalidImageData(
                textureIndex: textureIndex,
                reason: "Failed to decode base64 data",
                filePath: baseURL?.path
            )
        }
        
        return data
    }
    
    private func loadImageFromExternalFile(_ uri: String, textureIndex: Int) throws -> Data {
        guard let baseURL = baseURL else {
            throw VRMError.missingTexture(
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
            throw VRMError.invalidPath(
                path: uri,
                reason: "Path resolves outside base directory",
                filePath: baseURL.path
            )
        }
        
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw VRMError.missingTexture(
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
            throw VRMError.invalidImageData(
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
        
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        
        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0,
            withBytes: bitmapData,
            bytesPerRow: bytesPerRow
        )
        
        return texture
    }
    
    private func getPlaceholderTexture() -> MTLTexture? {
        if let placeholder = placeholderTexture {
            return placeholder
        }
        
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: 1,
            height: 1,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            return nil
        }
        
        // White pixel with full alpha
        var pixel: UInt32 = 0xFFFFFFFF
        texture.replace(
            region: MTLRegionMake2D(0, 0, 1, 1),
            mipmapLevel: 0,
            withBytes: &pixel,
            bytesPerRow: 4
        )
        
        placeholderTexture = texture
        return texture
    }
}
