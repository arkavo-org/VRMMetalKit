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

/// Reads every glTF buffer into memory up front, in parallel, to eliminate I/O stalls during mesh and texture decoding.
///
/// ## Discussion
/// The default ``BufferLoader`` resolves buffers lazily on first reference,
/// which serializes filesystem I/O behind the mesh/texture decode path. For
/// avatars with several external `.bin` files and dozens of image files, that
/// becomes the dominant cost.
///
/// `BufferPreloader` fans out one `Task` per `GLTFDocument.buffers` entry,
/// resolves `data:` URIs and external files concurrently, and returns the
/// `[bufferIndex: Data]` map that
/// ``BufferLoader/setPreloadedData(_:)`` consumes. The first buffer in a GLB
/// is mapped directly to the provided binary chunk; subsequent buffers come
/// from URIs.
///
/// External-file reads are checked against the supplied `baseURL`: any URI
/// that resolves outside the base directory (whether via `..` segments or an
/// absolute path) throws ``GLTFError/invalidPath(path:reason:filePath:)``.
/// Absolute paths whose resolved location is still under `baseURL` are
/// allowed, though relative paths are recommended for portability.
public final class BufferPreloader: @unchecked Sendable {
    private let document: GLTFDocument
    private let baseURL: URL?

    /// Preloaded buffer data indexed by buffer index
    private var preloadedData: [Int: Data] = [:]

    /// Creates a preloader bound to a parsed glTF document.
    ///
    /// - Parameters:
    ///   - document: The decoded ``GLTFDocument``.
    ///   - baseURL: Directory used to resolve relative buffer URIs. External buffer reads are rejected if they would resolve outside this directory.
    public init(document: GLTFDocument, baseURL: URL?) {
        self.document = document
        self.baseURL = baseURL
    }

    /// Loads every buffer in `document.buffers` concurrently and returns the resulting `[bufferIndex: Data]` map.
    ///
    /// Failures for individual buffers are logged but do not abort the
    /// preload — missing entries simply fall back to lazy loading in
    /// ``BufferLoader``.
    ///
    /// - Parameters:
    ///   - binaryData: GLB binary chunk, used for buffer 0 when present.
    ///   - progressCallback: Invoked on the main actor as each buffer completes. Receives `(loaded, total)`.
    /// - Returns: Map from buffer index to resolved bytes. Missing entries indicate per-buffer load failures.
    public func preloadAllBuffers(
        binaryData: Data?,
        progressCallback: (@Sendable (Int, Int) -> Void)? = nil
    ) async -> [Int: Data] {
        guard let buffers = document.buffers else {
            return [:]
        }
        
        let totalCount = buffers.count
        let bufferURIs: [String?] = buffers.map { $0.uri }
        var results: [Int: Data] = [:]
        var loaded = 0

        await withTaskGroup(of: (Int, Data?).self) { group in
            for (index, _) in buffers.enumerated() {
                group.addTask {
                    do {
                        let data = try await self.loadBuffer(
                            bufferURI: bufferURIs[index],
                            index: index,
                            binaryData: binaryData
                        )
                        return (index, data)
                    } catch {
                        vrmLog("[BufferPreloader] Failed to load buffer \(index): \(error)")
                        return (index, nil)
                    }
                }
            }

            for await (index, data) in group {
                loaded += 1
                if let data {
                    results[index] = data
                }
                await MainActor.run {
                    progressCallback?(loaded, totalCount)
                }
            }
        }

        preloadedData = results
        return preloadedData
    }
    
    /// Returns the previously-resolved bytes for the given buffer index, or `nil` if preloading failed or hasn't run.
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
            throw GLTFError.invalidPath(
                path: uri,
                reason: "Data URI missing comma separator",
                filePath: baseURL?.path
            )
        }
        
        let base64String = String(uri[uri.index(after: commaIndex)...])
        guard let data = Data(base64Encoded: base64String) else {
            throw GLTFError.invalidPath(
                path: uri,
                reason: "Failed to decode base64 data",
                filePath: baseURL?.path
            )
        }
        
        return data
    }
    
    private func loadExternalFile(_ uri: String, bufferIndex: Int) throws -> Data {
        guard let baseURL = baseURL else {
            throw GLTFError.missingBuffer(
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
            throw GLTFError.invalidPath(
                path: uri,
                reason: "Path resolves outside base directory",
                filePath: baseURL.path
            )
        }
        
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw GLTFError.missingBuffer(
                bufferIndex: bufferIndex,
                requiredBy: "external buffer file not found",
                expectedSize: nil,
                filePath: baseURL.path
            )
        }
        
        return try Data(contentsOf: fileURL)
    }
}

