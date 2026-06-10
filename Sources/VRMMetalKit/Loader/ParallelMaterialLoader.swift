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
//  ParallelMaterialLoader.swift
//  VRMMetalKit
//
//  High-performance parallel material processing.
//

@preconcurrency import Foundation

/// Materializes ``VRMMaterial`` values for many glTF materials concurrently.
///
/// ## Discussion
/// Material construction is CPU-bound (parameter copying, VRM-0/1 extension
/// disambiguation, texture-binding wiring) and scales linearly with material
/// count. `ParallelMaterialLoader` fans out one `Task` per requested
/// material index via `withTaskGroup`, so wall-clock time approaches
/// `(max material time) / availableCores`.
///
/// No Metal device is required — materials hold *references* to already-loaded
/// ``VRMTexture`` values rather than constructing GPU resources. Run
/// ``ParallelTextureLoader/loadTexturesParallel(indices:normalMapIndices:progressCallback:)``
/// first.
///
/// The class is `@unchecked Sendable`. Tasks are dispatched in input order,
/// but completion order is indeterminate. The returned `[Int: VRMMaterial]` is
/// keyed by source index.
public final class ParallelMaterialLoader: @unchecked Sendable {
    private let document: GLTFDocument
    private let textures: [VRMTexture]
    private let vrm0MaterialProperties: [VRM0MaterialProperty]
    private let vrmVersion: VRMSpecVersion

    /// Creates a loader bound to a parsed document and its already-loaded textures.
    ///
    /// - Parameters:
    ///   - document: The decoded ``GLTFDocument``.
    ///   - textures: Loaded textures, indexed parallel to `document.textures`.
    ///   - vrm0MaterialProperties: VRM 0.x per-material override block. Empty for VRM 1.0.
    ///   - vrmVersion: Source VRM specification version; controls MToon disambiguation.
    public init(
        document: GLTFDocument,
        textures: [VRMTexture],
        vrm0MaterialProperties: [VRM0MaterialProperty],
        vrmVersion: VRMSpecVersion
    ) {
        self.document = document
        self.textures = textures
        self.vrm0MaterialProperties = vrm0MaterialProperties
        self.vrmVersion = vrmVersion
    }

    /// Builds ``VRMMaterial`` values for the requested glTF material indices in parallel.
    ///
    /// - Parameters:
    ///   - indices: Material indices to process. Out-of-range indices are skipped silently.
    ///   - progressCallback: Invoked on the main actor as each material completes. Receives `(loaded, total)`.
    /// - Returns: Map from glTF material index to constructed ``VRMMaterial``.
    public func loadMaterialsParallel(
        indices: [Int],
        progressCallback: (@Sendable (Int, Int) -> Void)? = nil
    ) async -> [Int: VRMMaterial] {
        let totalCount = indices.count
        var results: [Int: VRMMaterial] = [:]
        var loaded = 0

        await withTaskGroup(of: (Int, VRMMaterial?).self) { group in
            for materialIndex in indices {
                group.addTask { [unowned self] in
                    guard let gltfMaterial = self.document.materials?[safe: materialIndex] else {
                        return (materialIndex, nil)
                    }
                    let vrm0Prop = materialIndex < self.vrm0MaterialProperties.count
                        ? self.vrm0MaterialProperties[materialIndex]
                        : nil
                    let material = VRMMaterial(
                        from: gltfMaterial,
                        textures: self.textures,
                        vrm0MaterialProperty: vrm0Prop,
                        vrmVersion: self.vrmVersion
                    )
                    return (materialIndex, material)
                }
            }

            for await (index, material) in group {
                loaded += 1
                if let material {
                    results[index] = material
                }
                await MainActor.run {
                    progressCallback?(loaded, totalCount)
                }
            }
        }

        return results
    }
}

