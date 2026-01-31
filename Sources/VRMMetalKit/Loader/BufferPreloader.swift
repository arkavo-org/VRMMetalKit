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
//  BufferPreloader.swift
//  VRMMetalKit
//
//  Preloads all buffer data in parallel for faster I/O during model loading.
//

@preconcurrency import Foundation

/// Preloads all buffer data in parallel at the start of loading.
/// This eliminates I/O bottlenecks during mesh and texture decoding.
public final class BufferPreloader: @unchecked Sendable {
    private let document: GLTFDocument
    private let baseURL: URL?
    
    /// Preloaded buffer data indexed by buffer index
    private var preloadedData: [Int: Data] = [:]
    
    public init(document: GLTFDocument, baseURL: URL?) {
        self.document = document
        self.baseURL = baseURL
    }
    
    /// Preload all buffers in parallel.
    ///
    /// This should be called at the start of model loading to ensure all
    /// buffer data is in memory before mesh/texture decoding begins.
    /// - Parameters:
    ///   - binaryData: The GLB binary chunk data (if loading from GLB)
    ///   - progressCallback: Called periodically with progress updates
    /// - Returns: Dictionary of preloaded buffer data
    public func preloadAllBuffers(
        binaryData: Data?,
        progressCallback: (@Sendable (Int, Int) -> Void)? = nil
    ) async -> [Int: Data] {
        guard let buffers = document.buffers else {
            return [:]
        }
        
        let totalCount = buffers.count
        let progressBox = UncheckedProgressBox()
        let results = UncheckedBufferDictionary()
        
        // Convert buffers to arrays for safe iteration
        let bufferURIs: [String?] = buffers.map { $0.uri }
        
        await withTaskGroup(of: Void.self) { group in
            for (index, _) in buffers.enumerated() {
                group.addTask {
                    do {
                        let data = try await self.loadBuffer(
                            bufferURI: bufferURIs[index],
                            index: index,
                            binaryData: binaryData
                        )
                        if let data = data {
                            results.set(data, for: index)
                        }
                    } catch {
                        vrmLog("[BufferPreloader] Failed to load buffer \(index): \(error)")
                    }
                    
                    progressBox.increment()
                    let current = progressBox.countValue
                    await MainActor.run {
                        progressCallback?(current, totalCount)
                    }
                }
            }
            
            await group.waitForAll()
        }
        
        preloadedData = results.getAll()
        return preloadedData
    }
    
    /// Get preloaded buffer data.
    public func getBufferData(index: Int) -> Data? {
        return preloadedData[index]
    }
    
    private func loadBuffer(bufferURI: String?, index: Int, binaryData: Data?) async throws -> Data? {
        // If we have binary data (GLB) and this is buffer 0, use it directly
        if index == 0, let binaryData = binaryData {
            return binaryData
        }
        
        // Otherwise, load from URI
        guard let uri = bufferURI else {
            // No URI means it's the GLB buffer (buffer 0), which we already handled
            if index == 0 {
                return binaryData
            }
            return nil
        }
        
        // Handle data URIs
        if uri.hasPrefix("data:") {
            return try loadDataURI(uri, bufferIndex: index)
        }
        
        // Handle external files
        return try loadExternalFile(uri, bufferIndex: index)
    }
    
    private func loadDataURI(_ uri: String, bufferIndex: Int) throws -> Data {
        guard let commaIndex = uri.firstIndex(of: ",") else {
            throw VRMError.invalidPath(
                path: uri,
                reason: "Data URI missing comma separator",
                filePath: baseURL?.path
            )
        }
        
        let base64String = String(uri[uri.index(after: commaIndex)...])
        guard let data = Data(base64Encoded: base64String) else {
            throw VRMError.invalidPath(
                path: uri,
                reason: "Failed to decode base64 data",
                filePath: baseURL?.path
            )
        }
        
        return data
    }
    
    private func loadExternalFile(_ uri: String, bufferIndex: Int) throws -> Data {
        guard let baseURL = baseURL else {
            throw VRMError.missingBuffer(
                bufferIndex: bufferIndex,
                requiredBy: "buffer loading (no base URL)",
                expectedSize: nil,
                filePath: nil
            )
        }
        
        let fileURL = uri.hasPrefix("/") ? URL(fileURLWithPath: uri) : baseURL.appendingPathComponent(uri)
        
        // Security check
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
            throw VRMError.missingBuffer(
                bufferIndex: bufferIndex,
                requiredBy: "external buffer file not found",
                expectedSize: nil,
                filePath: baseURL.path
            )
        }
        
        return try Data(contentsOf: fileURL)
    }
}

// MARK: - Helper Types

/// Thread-safe dictionary for buffer results
private final class UncheckedBufferDictionary: @unchecked Sendable {
    private var dict: [Int: Data] = [:]
    private let lock = NSLock()
    
    func set(_ data: Data, for index: Int) {
        lock.lock()
        dict[index] = data
        lock.unlock()
    }
    
    func getAll() -> [Int: Data] {
        lock.lock()
        defer { lock.unlock() }
        return dict
    }
}

/// Thread-safe progress counter
private final class UncheckedProgressBox: @unchecked Sendable {
    private var count: Int = 0
    private let lock = NSLock()
    
    var countValue: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
    
    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}
