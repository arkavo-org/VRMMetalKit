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
//  ParallelMeshLoader.swift
//  VRMMetalKit
//
//  High-performance parallel mesh loading with optimization support.
//

@preconcurrency import Foundation
@preconcurrency import Metal

/// Decodes ``VRMMesh`` values for many glTF meshes concurrently.
///
/// ## Discussion
/// Mesh decoding includes per-primitive accessor reads (positions, normals,
/// UVs, joints, weights, indices), optional `MTLBuffer` uploads, and morph
/// target unpacking. With a real `MTLDevice` the uploads dominate, so
/// `ParallelMeshLoader` fans the work out across a `TaskGroup` to overlap
/// I/O with the next mesh's CPU-side decode.
///
/// `device` is optional: pass `nil` for CPU-only loading (offline analysis
/// or test fixtures), in which case the resulting ``VRMMesh`` values omit
/// `MTLBuffer`s.
///
/// The loader is `@unchecked Sendable`; result aggregation uses an internal
/// `NSLock`. Completion order is indeterminate; the returned map is keyed
/// by source mesh index.
public final class ParallelMeshLoader: @unchecked Sendable {
    private let device: MTLDevice?
    private let document: GLTFDocument
    private let bufferLoader: BufferLoader

    /// Creates a loader bound to a parsed document and an existing ``BufferLoader``.
    ///
    /// - Parameters:
    ///   - device: Metal device for `MTLBuffer` allocation, or `nil` to skip GPU upload.
    ///   - document: The decoded ``GLTFDocument``.
    ///   - bufferLoader: ``BufferLoader`` used to resolve vertex and index accessors.
    public init(
        device: MTLDevice?,
        document: GLTFDocument,
        bufferLoader: BufferLoader
    ) {
        self.device = device
        self.document = document
        self.bufferLoader = bufferLoader
    }

    /// Decodes the requested glTF meshes in parallel and returns the resulting ``VRMMesh`` map.
    ///
    /// Per-mesh failures are logged but do not abort the batch — failed
    /// entries simply do not appear in the result map.
    ///
    /// - Parameters:
    ///   - indices: Mesh indices to load. Out-of-range indices are skipped silently.
    ///   - progressCallback: Invoked on the main actor as each mesh completes. Receives `(loaded, total)`.
    /// - Returns: Map from glTF mesh index to constructed ``VRMMesh``.
    public func loadMeshesParallel(
        indices: [Int],
        progressCallback: (@Sendable (Int, Int) -> Void)? = nil
    ) async -> [Int: VRMMesh] {
        let results = UncheckedMeshDictionary()
        let totalCount = indices.count
        let progressBox = UncheckedProgressBox()
        
        // Process meshes concurrently using TaskGroup
        await withTaskGroup(of: Void.self) { group in
            for meshIndex in indices {
                let task: @Sendable () async -> Void = { [unowned self] in
                    guard let gltfMesh = self.document.meshes?[safe: meshIndex] else { return }
                    
                    do {
                        let mesh = try await VRMMesh.load(
                            from: gltfMesh,
                            document: self.document,
                            device: self.device,
                            bufferLoader: self.bufferLoader
                        )
                        results.set(mesh, for: meshIndex)
                    } catch {
                        vrmLog("[ParallelMeshLoader] Failed to load mesh \(meshIndex): \(error)")
                    }
                    
                    progressBox.increment()
                    let current = progressBox.countValue
                    await MainActor.run {
                        progressCallback?(current, totalCount)
                    }
                }
                group.addTask(operation: task)
            }
            
            await group.waitForAll()
        }
        
        return results.getAll()
    }
}

// MARK: - Unchecked Helper Types

/// Thread-safe dictionary for mesh results
private final class UncheckedMeshDictionary: @unchecked Sendable {
    private var dict: [Int: VRMMesh] = [:]
    private let lock = NSLock()
    
    func set(_ mesh: VRMMesh, for index: Int) {
        lock.lock()
        dict[index] = mesh
        lock.unlock()
    }
    
    func getAll() -> [Int: VRMMesh] {
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
