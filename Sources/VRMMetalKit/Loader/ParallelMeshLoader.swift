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

/// High-performance parallel mesh loader.
/// Loads multiple meshes concurrently using TaskGroup for significant speedup.
public final class ParallelMeshLoader: @unchecked Sendable {
    private let device: MTLDevice?
    private let document: GLTFDocument
    private let bufferLoader: BufferLoader
    
    public init(
        device: MTLDevice?,
        document: GLTFDocument,
        bufferLoader: BufferLoader
    ) {
        self.device = device
        self.document = document
        self.bufferLoader = bufferLoader
    }
    
    /// Load all meshes in parallel using TaskGroup.
    ///
    /// This is significantly faster than sequential loading for models with many meshes.
    /// - Parameters:
    ///   - indices: Mesh indices to load
    ///   - progressCallback: Called periodically with progress updates
    /// - Returns: Array of loaded meshes (nil for failed loads)
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
