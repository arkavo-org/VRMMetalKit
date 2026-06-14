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

@preconcurrency import Foundation
@preconcurrency import Metal

/// Decodes ``VRMMesh`` values for many glTF meshes concurrently.
///
/// Thin VRM-flavored convenience around ``GLTFParallelMeshLoader``: supplies
/// the per-mesh ``VRMMesh/load(from:document:device:bufferLoader:)`` decode
/// closure so the parallel orchestration lives in GLTFCore but the result
/// type stays VRM-aware. Future kits (e.g. a GLTFMetalKit PBR renderer) can
/// instantiate `GLTFParallelMeshLoader` directly with their own decoder.
public final class ParallelMeshLoader: @unchecked Sendable {
    private let inner: GLTFParallelMeshLoader<VRMMesh>

    /// Creates a loader bound to a parsed document and an existing ``BufferLoader``.
    ///
    /// - Parameters:
    ///   - device: Metal device for `MTLBuffer` allocation, or `nil` to skip GPU upload.
    ///   - document: The decoded ``GLTFDocument``.
    ///   - bufferLoader: ``BufferLoader`` used to resolve vertex and index accessors.
    public init(
        device: MTLDevice?,
        document: GLTFDocument,
        bufferLoader: BufferLoader,
        concurrencyLimiter: AsyncConcurrencyLimiter? = nil
    ) {
        self.inner = GLTFParallelMeshLoader<VRMMesh>(
            device: device,
            document: document,
            bufferLoader: bufferLoader,
            load: { _, gltfMesh, document, device, bufferLoader in
                // Per-mesh tasks never hold a limiter permit (only the leaf
                // primitive decode inside VRMMesh.load does), so the across-mesh ×
                // intra-mesh nesting cannot deadlock.
                try await VRMMesh.load(
                    from: gltfMesh,
                    document: document,
                    device: device,
                    bufferLoader: bufferLoader,
                    concurrencyLimiter: concurrencyLimiter
                )
            }
        )
    }

    /// Decodes the requested glTF meshes in parallel and returns the resulting ``VRMMesh`` map.
    ///
    /// - Parameters:
    ///   - indices: Mesh indices to load. Out-of-range indices are skipped silently.
    ///   - progressCallback: Invoked on the main actor as each mesh completes. Receives `(loaded, total)`.
    /// - Returns: Map from glTF mesh index to constructed ``VRMMesh``.
    public func loadMeshesParallel(
        indices: [Int],
        progressCallback: (@Sendable (Int, Int) -> Void)? = nil
    ) async -> [Int: VRMMesh] {
        await inner.loadMeshesParallel(indices: indices, progressCallback: progressCallback)
    }
}
