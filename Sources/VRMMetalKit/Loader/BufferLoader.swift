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
import simd

/// Reads typed arrays out of a glTF document's accessors, buffer views, and binary chunk.
///
/// ## Discussion
/// A `BufferLoader` is the low-level adapter between the parsed
/// ``GLTFDocument`` and Swift-native typed arrays (``loadAccessor(_:type:)``,
/// ``loadAccessorAsFloat(_:)``, ``loadAccessorAsUInt32(_:)``,
/// ``loadAccessorAsMatrix4x4(_:)``). It resolves three buffer storage
/// locations transparently:
///
/// - The GLB binary chunk supplied at construction.
/// - `data:` URIs embedded in the glTF JSON.
/// - External files relative to the model's `baseURL` (with symlink-resolved
///   path-traversal protection — files outside `baseURL` are rejected).
///
/// The accessor decoders honour every facet of the [glTF 2.0
/// Accessor](https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html#accessors)
/// spec needed by VRM avatars: signed and unsigned component types, the
/// `bufferView.byteStride` for interleaved attributes, the combined
/// `bufferView.byteOffset + accessor.byteOffset`, and
/// [sparse-accessor overrides](https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html#sparse-accessors).
/// Unknown component types or accessor types throw
/// ``VRMError/invalidAccessor(accessorIndex:reason:context:filePath:)``
/// rather than silently misreading bytes.
///
/// `BufferLoader` is `@unchecked Sendable`; the cached preloaded-data map is
/// installed once via ``setPreloadedData(_:)`` from the load pipeline and is
/// not mutated thereafter.
public class BufferLoader: @unchecked Sendable {
    private let document: GLTFDocument
    private let binaryData: Data?
    private let baseURL: URL?

    /// Preloaded buffer data (optional optimization)
    private var preloadedData: [Int: Data]?

    /// The file path for error reporting
    internal var filePath: String? {
        return baseURL?.path
    }

    /// Creates a loader bound to a parsed glTF document and its optional GLB binary chunk.
    ///
    /// - Parameters:
    ///   - document: The decoded ``GLTFDocument``.
    ///   - binaryData: The raw `BIN` chunk from a GLB file, or `nil` for `.gltf` JSON files whose buffers live in external `.bin` files or `data:` URIs.
    ///   - baseURL: Directory used to resolve relative buffer URIs. External buffer reads are rejected if they would resolve outside this directory.
    ///   - preloadedData: Optional map of buffer index to in-memory `Data`, typically supplied by ``BufferPreloader`` to skip filesystem I/O.
    public init(document: GLTFDocument, binaryData: Data?, baseURL: URL? = nil, preloadedData: [Int: Data]? = nil) {
        self.document = document
        self.binaryData = binaryData
        self.baseURL = baseURL
        self.preloadedData = preloadedData
    }

    /// Installs a preloaded buffer index map, bypassing on-demand `data:` URI decoding and file reads.
    ///
    /// Used by the loading pipeline after ``BufferPreloader/preloadAllBuffers(binaryData:progressCallback:)`` resolves every buffer in parallel.
    public func setPreloadedData(_ data: [Int: Data]) {
        self.preloadedData = data
    }

    // MARK: - Accessor Loading

    /// Decodes a glTF accessor into a flat array of `T` scalars, applying any sparse overrides.
    ///
    /// Component conversion is best-effort: out-of-range or non-representable
    /// values fall back to `0`. For floats specifically, prefer
    /// ``loadAccessorAsFloat(_:)`` which handles normalized integer
    /// conversion explicitly.
    ///
    /// - Parameters:
    ///   - accessorIndex: Zero-based index into `GLTFDocument.accessors`.
    ///   - type: Numeric type to decode into (typically `Float.self` or `UInt32.self`).
    /// - Returns: `count * componentsPerElement` scalars, in element-major order.
    /// - Throws: ``VRMError/invalidAccessor(accessorIndex:reason:context:filePath:)`` when the accessor index, componentType, or accessor type is unrecognised; ``VRMError/missingBuffer(bufferIndex:requiredBy:expectedSize:filePath:)`` when the backing buffer cannot be resolved.
    public func loadAccessor<T>(_ accessorIndex: Int, type: T.Type) throws -> [T] where T: Numeric {
        guard let accessor = document.accessors?[safe: accessorIndex] else {
            throw VRMError.invalidAccessor(
                accessorIndex: accessorIndex,
                reason: "Accessor not found in document",
                context: "loadAccessor<\(T.self)>",
                filePath: filePath
            )
        }
        try validateAccessor(accessor, accessorIndex: accessorIndex, context: "loadAccessor<\(T.self)>")

        let components = componentCount(for: accessor.type)
        let componentSize = bytesPerComponent(accessor.componentType)
        var result: [T]

        if let bufferViewIndex = accessor.bufferView {
            let (data, bufferView) = try loadBufferView(bufferViewIndex)

            // CRITICAL FIX: Apply BOTH the bufferView offset AND accessor offset
            let bufferViewOffset = bufferView.byteOffset ?? 0
            let accessorOffset = accessor.byteOffset ?? 0
            let combinedOffset = bufferViewOffset + accessorOffset

            let stride = bufferView.byteStride ?? bytesPerElement(componentType: accessor.componentType, accessorType: accessor.type)

            result = []
            for i in 0..<accessor.count {
                let elementOffset = combinedOffset + (i * stride)
                for j in 0..<components {
                    let componentOffset = elementOffset + (j * componentSize)
                    let value = extractComponent(from: data, at: componentOffset, componentType: accessor.componentType, as: T.self)
                    result.append(value)
                }
            }
        } else {
            // Zero-filled base (sparse or truly empty accessor)
            result = Array(repeating: T.zero, count: accessor.count * components)
        }

        // Apply sparse overrides if present
        if let sparse = accessor.sparse {
            try applySparseOverrides(sparse: sparse, into: &result, componentType: accessor.componentType, components: components, componentSize: componentSize) { data, offset, ct in
                self.extractComponent(from: data, at: offset, componentType: ct, as: T.self)
            }
        }

        return result
    }

    /// Decodes a glTF accessor into a flat `Float` array, normalising integer component types per the spec.
    ///
    /// `UNSIGNED_BYTE` is mapped to `[0, 1]`, `BYTE` to `[-1, 1]`,
    /// `UNSIGNED_SHORT` to `[0, 1]`, `SHORT` to `[-1, 1]`, and `FLOAT` is
    /// passed through unchanged. This matches the
    /// [glTF accessor normalization](https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html#accessor-data-types)
    /// rules.
    ///
    /// - Parameter accessorIndex: Zero-based index into `GLTFDocument.accessors`.
    /// - Throws: ``VRMError/invalidAccessor(accessorIndex:reason:context:filePath:)`` for unknown component/accessor types; ``VRMError/missingBuffer(bufferIndex:requiredBy:expectedSize:filePath:)`` if the buffer cannot be resolved.
    public func loadAccessorAsFloat(_ accessorIndex: Int) throws -> [Float] {
        guard let accessor = document.accessors?[safe: accessorIndex] else {
            throw VRMError.invalidAccessor(
                accessorIndex: accessorIndex,
                reason: "Accessor not found in document",
                context: "loadAccessorAsFloat",
                filePath: filePath
            )
        }
        try validateAccessor(accessor, accessorIndex: accessorIndex, context: "loadAccessorAsFloat")

        let components = componentCount(for: accessor.type)
        let componentSize = bytesPerComponent(accessor.componentType)
        var result: [Float]

        if let bufferViewIndex = accessor.bufferView {
            let (data, bufferView) = try loadBufferView(bufferViewIndex)

            // CRITICAL FIX: Apply BOTH the bufferView offset AND accessor offset
            let bufferViewOffset = bufferView.byteOffset ?? 0
            let accessorOffset = accessor.byteOffset ?? 0
            let combinedOffset = bufferViewOffset + accessorOffset

            let stride = bufferView.byteStride ?? bytesPerElement(componentType: accessor.componentType, accessorType: accessor.type)

            result = []
            for i in 0..<accessor.count {
                let elementOffset = combinedOffset + (i * stride)
                for j in 0..<components {
                    let componentOffset = elementOffset + (j * componentSize)
                    let value = extractFloatComponent(from: data, at: componentOffset, componentType: accessor.componentType)
                    result.append(value)
                }
            }
        } else {
            result = Array(repeating: 0, count: accessor.count * components)
        }

        if let sparse = accessor.sparse {
            try applySparseOverrides(sparse: sparse, into: &result, componentType: accessor.componentType, components: components, componentSize: componentSize) { data, offset, ct in
                self.extractFloatComponent(from: data, at: offset, componentType: ct)
            }
        }

        return result
    }

    /// Decodes a glTF accessor into a flat `UInt32` array. Use for index buffers and joint indices.
    ///
    /// Accepts `UNSIGNED_BYTE`, `UNSIGNED_SHORT`, `UNSIGNED_INT`, and `FLOAT` component types.
    ///
    /// - Parameter accessorIndex: Zero-based index into `GLTFDocument.accessors`.
    /// - Throws: ``VRMError/invalidAccessor(accessorIndex:reason:context:filePath:)`` for unknown component/accessor types; ``VRMError/missingBuffer(bufferIndex:requiredBy:expectedSize:filePath:)`` if the buffer cannot be resolved.
    public func loadAccessorAsUInt32(_ accessorIndex: Int) throws -> [UInt32] {
        guard let accessor = document.accessors?[safe: accessorIndex] else {
            throw VRMError.invalidAccessor(
                accessorIndex: accessorIndex,
                reason: "Accessor not found in document",
                context: "loadAccessorAsUInt32",
                filePath: filePath
            )
        }
        try validateAccessor(accessor, accessorIndex: accessorIndex, context: "loadAccessorAsUInt32")

        let components = componentCount(for: accessor.type)
        let componentSize = bytesPerComponent(accessor.componentType)
        var result: [UInt32]

        if let bufferViewIndex = accessor.bufferView {
            let (data, bufferView) = try loadBufferView(bufferViewIndex)

            // CRITICAL FIX: Apply BOTH the bufferView offset AND accessor offset
            let bufferViewOffset = bufferView.byteOffset ?? 0
            let accessorOffset = accessor.byteOffset ?? 0
            let combinedOffset = bufferViewOffset + accessorOffset

            // CRITICAL FIX: Use the bufferView's byteStride for interleaved vertex attributes.
            let stride = bufferView.byteStride ?? bytesPerElement(componentType: accessor.componentType, accessorType: accessor.type)

            result = []
            for i in 0..<accessor.count {
                let elementOffset = combinedOffset + (i * stride)
                for j in 0..<components {
                    let componentOffset = elementOffset + (j * componentSize)
                    let value = extractUIntComponent(from: data, at: componentOffset, componentType: accessor.componentType)
                    result.append(value)
                }
            }
        } else {
            result = Array(repeating: 0, count: accessor.count * components)
        }

        if let sparse = accessor.sparse {
            try applySparseOverrides(sparse: sparse, into: &result, componentType: accessor.componentType, components: components, componentSize: componentSize) { data, offset, ct in
                self.extractUIntComponent(from: data, at: offset, componentType: ct)
            }
        }

        return result
    }

    /// Decodes a `MAT4` accessor into an array of `simd_float4x4`, preserving glTF column-major order.
    ///
    /// Used by ``VRMSkin`` to load inverse bind matrices. The accessor's
    /// `type` field must be `"MAT4"`; any other type raises
    /// ``VRMError/invalidAccessor(accessorIndex:reason:context:filePath:)``.
    ///
    /// - Parameter accessorIndex: Zero-based index into `GLTFDocument.accessors`.
    public func loadAccessorAsMatrix4x4(_ accessorIndex: Int) throws -> [float4x4] {
        guard let accessor = document.accessors?[safe: accessorIndex] else {
            throw VRMError.invalidAccessor(
                accessorIndex: accessorIndex,
                reason: "Accessor not found in document",
                context: "loadAccessorAsMatrix4x4",
                filePath: filePath
            )
        }

        // MAT4 type should have 16 components per element
        guard accessor.type == "MAT4" else {
            throw VRMError.invalidAccessor(
                accessorIndex: accessorIndex,
                reason: "Expected MAT4 type but got '\(accessor.type)'",
                context: "loadAccessorAsMatrix4x4 requires MAT4 accessor type",
                filePath: filePath
            )
        }

        let floatData = try loadAccessorAsFloat(accessorIndex)
        var matrices: [float4x4] = []

        // Each matrix has 16 floats
        for i in stride(from: 0, to: floatData.count, by: 16) {
            guard i + 15 < floatData.count else { break }

            // GLTF stores matrices in column-major order
            // Load as-is without transpose - the matrices are correct as stored
            let matrix = float4x4(
                SIMD4<Float>(floatData[i], floatData[i+1], floatData[i+2], floatData[i+3]),
                SIMD4<Float>(floatData[i+4], floatData[i+5], floatData[i+6], floatData[i+7]),
                SIMD4<Float>(floatData[i+8], floatData[i+9], floatData[i+10], floatData[i+11]),
                SIMD4<Float>(floatData[i+12], floatData[i+13], floatData[i+14], floatData[i+15])
            )
            matrices.append(matrix)
        }

        return matrices
    }

    // MARK: - Sparse Accessor Support

    /// Apply glTF sparse accessor overrides onto a pre-filled base buffer.
    ///
    /// Spec (glTF 2.0 §5.1.7): The sparse object describes a subset of the accessor elements
    /// that differ from their initialization value. Each override consists of:
    /// - An index (read from `sparse.indices`) identifying which element to override.
    /// - A value (read from `sparse.values`) that replaces the element in the base data.
    ///
    /// - Parameters:
    ///   - sparse: The `GLTFSparse` descriptor from the accessor.
    ///   - result: The base buffer to mutate in place (zero-filled or bufferView-backed).
    ///   - componentType: The accessor's componentType (determines value byte width).
    ///   - components: Number of scalar components per element (1 for SCALAR, 3 for VEC3, etc.).
    ///   - componentSize: Bytes per scalar component.
    ///   - extractor: Closure that reads a single scalar component from raw data at a given byte offset.
    private func applySparseOverrides<T>(
        sparse: GLTFSparse,
        into result: inout [T],
        componentType: Int,
        components: Int,
        componentSize: Int,
        extractor: (Data, Int, Int) -> T
    ) throws {
        // Read sparse indices
        let (indicesData, indicesBV) = try loadBufferView(sparse.indices.bufferView)
        let indicesBVOffset = indicesBV.byteOffset ?? 0
        let indicesByteOffset = (sparse.indices.byteOffset ?? 0) + indicesBVOffset
        let indicesComponentType = sparse.indices.componentType
        let indexSize = bytesPerComponent(indicesComponentType)

        // Read sparse values
        let (valuesData, valuesBV) = try loadBufferView(sparse.values.bufferView)
        let valuesBVOffset = valuesBV.byteOffset ?? 0
        let valuesByteOffset = (sparse.values.byteOffset ?? 0) + valuesBVOffset
        let elementSize = componentSize * components

        for i in 0..<sparse.count {
            // Read the destination index
            let indexByteOffset = indicesByteOffset + i * indexSize
            let destIndex: Int
            switch indicesComponentType {
            case 5121: // UNSIGNED_BYTE
                guard indexByteOffset + 1 <= indicesData.count else { continue }
                destIndex = Int(indicesData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: indexByteOffset, as: UInt8.self) })
            case 5123: // UNSIGNED_SHORT
                guard indexByteOffset + 2 <= indicesData.count else { continue }
                destIndex = Int(indicesData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: indexByteOffset, as: UInt16.self) })
            case 5125: // UNSIGNED_INT
                guard indexByteOffset + 4 <= indicesData.count else { continue }
                destIndex = Int(indicesData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: indexByteOffset, as: UInt32.self) })
            default:
                continue
            }

            // Write the override value into the base buffer
            let valueByteOffset = valuesByteOffset + i * elementSize
            let resultBase = destIndex * components
            guard resultBase + components <= result.count else { continue }
            for j in 0..<components {
                let componentByteOffset = valueByteOffset + j * componentSize
                result[resultBase + j] = extractor(valuesData, componentByteOffset, componentType)
            }
        }
    }

    // MARK: - Buffer Data Access

    /// Returns the raw bytes for a glTF buffer, consulting preloaded data, the GLB binary chunk, `data:` URIs, and external files in that order.
    ///
    /// - Parameter bufferIndex: Zero-based index into `GLTFDocument.buffers`.
    /// - Throws: ``VRMError/missingBuffer(bufferIndex:requiredBy:expectedSize:filePath:)`` if the buffer cannot be resolved; ``VRMError/invalidPath(path:reason:filePath:)`` for path-traversal attempts or missing external files.
    public func getBufferData(bufferIndex: Int) throws -> Data {
        // Check preloaded data first (optimization)
        if let preloaded = preloadedData?[bufferIndex] {
            return preloaded
        }
        
        guard let buffer = document.buffers?[safe: bufferIndex] else {
            throw VRMError.missingBuffer(
                bufferIndex: bufferIndex,
                requiredBy: "getBufferData",
                expectedSize: nil,
                filePath: filePath
            )
        }

        if bufferIndex == 0, let binaryData = self.binaryData {
            // First buffer is the binary chunk
            return binaryData
        } else if let uri = buffer.uri {
            // Data URI or external file
            if uri.hasPrefix("data:") {
                return try loadDataURI(uri)
            } else {
                // External file
                return try loadExternalBuffer(uri)
            }
        } else {
            throw VRMError.missingBuffer(
                bufferIndex: bufferIndex,
                requiredBy: "getBufferData",
                expectedSize: buffer.byteLength,
                filePath: filePath
            )
        }
    }

    // MARK: - Buffer View Loading

    /// Creates an `MTLBuffer` containing the byte slice referenced by a glTF buffer view.
    ///
    /// The buffer is allocated with `.storageModeShared`. The bufferView's
    /// `byteOffset` is applied to the source data; the returned buffer's own
    /// offset is zero.
    ///
    /// - Parameters:
    ///   - bufferViewIndex: Zero-based index into `GLTFDocument.bufferViews`.
    ///   - device: Metal device used for allocation.
    /// - Returns: An `MTLBuffer` sized to `bufferView.byteLength`, or `nil` if `device.makeBuffer(...)` fails.
    /// - Throws: ``VRMError/invalidAccessor(accessorIndex:reason:context:filePath:)`` if the bufferView is missing; ``VRMError/missingBuffer(bufferIndex:requiredBy:expectedSize:filePath:)`` if the underlying buffer cannot be resolved.
    public func createMTLBuffer(for bufferViewIndex: Int, device: MTLDevice) throws -> MTLBuffer? {
        let (fullData, bufferView) = try loadBufferView(bufferViewIndex)

        // For creating an MTLBuffer, we need just the bufferView's slice
        let offset = bufferView.byteOffset ?? 0
        let length = bufferView.byteLength

        guard offset + length <= fullData.count else {
            throw VRMError.missingBuffer(
                bufferIndex: bufferView.buffer,
                requiredBy: "createMTLBuffer for bufferView \(bufferViewIndex)",
                expectedSize: offset + length,
                filePath: filePath
            )
        }

        let slicedData = fullData.subdata(in: offset..<(offset + length))
        return device.makeBuffer(bytes: slicedData.withUnsafeBytes { $0.baseAddress! },
                                length: slicedData.count,
                                options: .storageModeShared)
    }

    // Returns the entire buffer data and the bufferView for offset calculation
    private func loadBufferView(_ bufferViewIndex: Int) throws -> (data: Data, bufferView: GLTFBufferView) {
        guard let bufferView = document.bufferViews?[safe: bufferViewIndex] else {
            throw VRMError.invalidAccessor(
                accessorIndex: bufferViewIndex,
                reason: "BufferView not found in document",
                context: "loadBufferView",
                filePath: filePath
            )
        }

        guard let buffer = document.buffers?[safe: bufferView.buffer] else {
            throw VRMError.missingBuffer(
                bufferIndex: bufferView.buffer,
                requiredBy: "loadBufferView \(bufferViewIndex)",
                expectedSize: bufferView.byteLength,
                filePath: filePath
            )
        }

        let data: Data

        if bufferView.buffer == 0, let binaryData = self.binaryData {
            // First buffer is typically the binary chunk in GLB
            data = binaryData
        } else if let uri = buffer.uri {
            // External buffer or data URI
            if uri.hasPrefix("data:") {
                // Data URI
                data = try loadDataURI(uri)
            } else {
                // External file
                data = try loadExternalBuffer(uri)
            }
        } else {
            throw VRMError.missingBuffer(
                bufferIndex: bufferView.buffer,
                requiredBy: "loadBufferView \(bufferViewIndex)",
                expectedSize: buffer.byteLength,
                filePath: filePath
            )
        }

        // Return the entire buffer data and the bufferView
        // The accessor loading functions will apply the combined offset
        return (data, bufferView)
    }

    private func loadDataURI(_ uri: String) throws -> Data {
        guard let commaIndex = uri.firstIndex(of: ",") else {
            throw VRMError.invalidJSON(
                context: "loadDataURI: Invalid data URI format",
                underlyingError: "Missing comma separator in data URI",
                filePath: filePath
            )
        }

        let base64String = String(uri[uri.index(after: commaIndex)...])
        guard let data = Data(base64Encoded: base64String) else {
            throw VRMError.invalidJSON(
                context: "loadDataURI: Failed to decode base64 data",
                underlyingError: "Invalid base64 encoding in data URI",
                filePath: filePath
            )
        }

        return data
    }

    private func loadExternalBuffer(_ uri: String) throws -> Data {
        guard let baseURL = baseURL else {
            vrmLog("[BufferLoader] Warning: Cannot load external file without base URL: \(uri)")
            throw VRMError.invalidPath(
                path: uri,
                reason: "Cannot load external buffer without base URL",
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
        let resolvedFilePath = fileURL.standardized.resolvingSymlinksInPath().path
        guard resolvedFilePath.hasPrefix(basePath) else {
            vrmLog("[BufferLoader] Security: Refusing to load file outside base directory: \(uri)")
            throw VRMError.invalidPath(
                path: uri,
                reason: "Security: Path resolves outside base directory (attempted path traversal)",
                filePath: filePath
            )
        }

        // Check if file exists
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            vrmLog("[BufferLoader] Warning: External buffer file not found: \(fileURL.path)")
            throw VRMError.invalidPath(
                path: uri,
                reason: "External buffer file not found at resolved path: \(fileURL.path)",
                filePath: filePath
            )
        }

        // Load the buffer data
        do {
            let data = try Data(contentsOf: fileURL)
            vrmLog("[BufferLoader] Loaded external buffer: \(uri) (\(data.count) bytes)")
            return data
        } catch {
            vrmLog("[BufferLoader] Error loading external buffer: \(error)")
            throw VRMError.invalidPath(
                path: uri,
                reason: "Failed to load external buffer: \(error.localizedDescription)",
                filePath: filePath
            )
        }
    }

    // MARK: - Component Extraction

    private func extractComponent<T: Numeric>(from data: Data, at offset: Int, componentType: Int, as type: T.Type) -> T {
        // CRITICAL: Check that we have enough bytes for the entire type, not just the offset
        switch componentType {
        case 5120: // BYTE (1 byte)
            guard offset + MemoryLayout<Int8>.size <= data.count else { return 0 as! T }
            let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: Int8.self) }
            return T(exactly: value) ?? (0 as! T)
        case 5121: // UNSIGNED_BYTE (1 byte)
            guard offset + MemoryLayout<UInt8>.size <= data.count else { return 0 as! T }
            let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt8.self) }
            return T(exactly: value) ?? (0 as! T)
        case 5122: // SHORT (2 bytes)
            guard offset + MemoryLayout<Int16>.size <= data.count else { return 0 as! T }
            let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: Int16.self) }
            return T(exactly: value) ?? (0 as! T)
        case 5123: // UNSIGNED_SHORT (2 bytes)
            guard offset + MemoryLayout<UInt16>.size <= data.count else { return 0 as! T }
            let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self) }
            return T(exactly: value) ?? (0 as! T)
        case 5125: // UNSIGNED_INT (4 bytes)
            guard offset + MemoryLayout<UInt32>.size <= data.count else { return 0 as! T }
            let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
            return T(exactly: value) ?? (0 as! T)
        case 5126: // FLOAT (4 bytes)
            guard offset + MemoryLayout<Float>.size <= data.count else { return 0 as! T }
            let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: Float.self) }
            if T.self == Float.self {
                return value as! T
            }
            return T(exactly: Int(value)) ?? (0 as! T)
        default:
            return 0 as! T
        }
    }

    private func extractFloatComponent(from data: Data, at offset: Int, componentType: Int) -> Float {
        // CRITICAL: Check bounds AND use safe loadUnaligned to avoid alignment crashes
        switch componentType {
        case 5120: // BYTE (1 byte)
            guard offset + MemoryLayout<Int8>.size <= data.count else { return 0 }
            let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: Int8.self) }
            return Float(value) / 127.0 // Normalize
        case 5121: // UNSIGNED_BYTE (1 byte)
            guard offset + MemoryLayout<UInt8>.size <= data.count else { return 0 }
            let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt8.self) }
            return Float(value) / 255.0 // Normalize
        case 5122: // SHORT (2 bytes)
            guard offset + MemoryLayout<Int16>.size <= data.count else { return 0 }
            let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: Int16.self) }
            return Float(value) / 32767.0 // Normalize
        case 5123: // UNSIGNED_SHORT (2 bytes)
            guard offset + MemoryLayout<UInt16>.size <= data.count else { return 0 }
            let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self) }
            return Float(value) / 65535.0 // Normalize
        case 5125: // UNSIGNED_INT (4 bytes)
            guard offset + MemoryLayout<UInt32>.size <= data.count else { return 0 }
            let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
            return Float(value)
        case 5126: // FLOAT (4 bytes)
            guard offset + MemoryLayout<Float>.size <= data.count else { return 0 }
            return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: Float.self) }
        default:
            return 0
        }
    }

    private func extractUIntComponent(from data: Data, at offset: Int, componentType: Int) -> UInt32 {
        // CRITICAL: Check bounds AND use safe loadUnaligned to avoid alignment crashes
        switch componentType {
        case 5121: // UNSIGNED_BYTE (1 byte)
            guard offset + MemoryLayout<UInt8>.size <= data.count else { return 0 }
            let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt8.self) }
            return UInt32(value)
        case 5123: // UNSIGNED_SHORT (2 bytes)
            guard offset + MemoryLayout<UInt16>.size <= data.count else { return 0 }
            let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self) }
            return UInt32(value)
        case 5125: // UNSIGNED_INT (4 bytes)
            guard offset + MemoryLayout<UInt32>.size <= data.count else { return 0 }
            return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
        case 5126: // FLOAT (4 bytes)
            guard offset + MemoryLayout<Float>.size <= data.count else { return 0 }
            let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: Float.self) }
            return UInt32(value)
        default:
            return 0
        }
    }

    // MARK: - Helper Functions

    private func componentCount(for type: String) -> Int {
        switch type {
        case "SCALAR": return 1
        case "VEC2": return 2
        case "VEC3": return 3
        case "VEC4": return 4
        case "MAT2": return 4
        case "MAT3": return 9
        case "MAT4": return 16
        default: return 1
        }
    }

    private func bytesPerComponent(_ componentType: Int) -> Int {
        switch componentType {
        case 5120, 5121: return 1 // BYTE, UNSIGNED_BYTE
        case 5122, 5123: return 2 // SHORT, UNSIGNED_SHORT
        case 5125, 5126: return 4 // UNSIGNED_INT, FLOAT
        default: return 4
        }
    }

    private func bytesPerElement(componentType: Int, accessorType: String) -> Int {
        return bytesPerComponent(componentType) * componentCount(for: accessorType)
    }

    /// Validates that the accessor's componentType and type are known glTF values.
    /// Rejects with `VRMError.invalidAccessor` rather than silently misreading bytes
    /// (which previously caused either zeroed garbage data or a forced-cast crash in
    /// `extractComponent` when `T` was not `Float`).
    private func validateAccessor(_ accessor: GLTFAccessor, accessorIndex: Int, context: String) throws {
        switch accessor.componentType {
        case 5120, 5121, 5122, 5123, 5125, 5126:
            break
        default:
            throw VRMError.invalidAccessor(
                accessorIndex: accessorIndex,
                reason: "Unknown componentType \(accessor.componentType); expected 5120 (BYTE), 5121 (UBYTE), 5122 (SHORT), 5123 (USHORT), 5125 (UINT), or 5126 (FLOAT)",
                context: context,
                filePath: filePath
            )
        }
        switch accessor.type {
        case "SCALAR", "VEC2", "VEC3", "VEC4", "MAT2", "MAT3", "MAT4":
            break
        default:
            throw VRMError.invalidAccessor(
                accessorIndex: accessorIndex,
                reason: "Unknown accessor type '\(accessor.type)'; expected SCALAR, VEC2, VEC3, VEC4, MAT2, MAT3, or MAT4",
                context: context,
                filePath: filePath
            )
        }
    }
}

// MARK: - Array Safe Access

extension Array {
    subscript(safe index: Int) -> Element? {
        return index >= 0 && index < count ? self[index] : nil
    }
}