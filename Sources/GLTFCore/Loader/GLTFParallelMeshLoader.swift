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

/// Generic parallel mesh loader for glTF documents.
///
/// Fans per-mesh decoding out across a `TaskGroup`. The actual decode step is
/// supplied by the caller via the `load` closure, so each kit (VRMMetalKit,
/// future GLTFMetalKit) plugs in its own runtime mesh type without copying the
/// orchestration boilerplate.
///
/// `device` is optional: pass `nil` for CPU-only loading. Completion order is
/// indeterminate; the returned map is keyed by source mesh index.
public final class GLTFParallelMeshLoader<Mesh: Sendable>: @unchecked Sendable {
    public typealias LoadFunction = @Sendable (Int, GLTFMesh, GLTFDocument, MTLDevice?, BufferLoader) async throws -> Mesh

    private let device: MTLDevice?
    private let document: GLTFDocument
    private let bufferLoader: BufferLoader
    private let load: LoadFunction

    /// Creates a loader bound to a parsed document, an existing ``BufferLoader``, and a per-mesh decoder.
    ///
    /// - Parameters:
    ///   - device: Metal device for `MTLBuffer` allocation, or `nil` to skip GPU upload.
    ///   - document: The decoded ``GLTFDocument``.
    ///   - bufferLoader: ``BufferLoader`` used to resolve vertex and index accessors.
    ///   - load: Per-mesh decode closure. Receives `(meshIndex, gltfMesh, document, device, bufferLoader)` and returns the kit-specific runtime mesh.
    public init(
        device: MTLDevice?,
        document: GLTFDocument,
        bufferLoader: BufferLoader,
        load: @escaping LoadFunction
    ) {
        self.device = device
        self.document = document
        self.bufferLoader = bufferLoader
        self.load = load
    }

    /// Decodes the requested glTF meshes in parallel.
    ///
    /// Per-mesh failures are logged via ``vrmLog(_:level:category:function:line:)`` but do not abort the batch — failed entries simply do not appear in the result map.
    ///
    /// - Parameters:
    ///   - indices: Mesh indices to load. Out-of-range indices are skipped silently.
    ///   - progressCallback: Invoked on the main actor as each mesh completes. Receives `(loaded, total)`.
    /// - Returns: Map from glTF mesh index to the loaded `Mesh`.
    public func loadMeshesParallel(
        indices: [Int],
        progressCallback: (@Sendable (Int, Int) -> Void)? = nil
    ) async -> [Int: Mesh] {
        let totalCount = indices.count
        var results: [Int: Mesh] = [:]
        var loaded = 0

        await withTaskGroup(of: (Int, Mesh?).self) { group in
            for meshIndex in indices {
                group.addTask { [weak self] in
                    guard let self,
                          let gltfMesh = self.document.meshes?[safe: meshIndex] else {
                        return (meshIndex, nil)
                    }
                    do {
                        let mesh = try await self.load(meshIndex, gltfMesh, self.document, self.device, self.bufferLoader)
                        return (meshIndex, mesh)
                    } catch {
                        vrmLog("[GLTFParallelMeshLoader] Failed to load mesh \(meshIndex): \(error)")
                        return (meshIndex, nil)
                    }
                }
            }

            // Coalesce progress hops to the main actor instead of one per mesh.
            let reporter = CoalescedProgressReporter(total: totalCount, callback: progressCallback)
            for await (index, mesh) in group {
                loaded += 1
                if let mesh {
                    results[index] = mesh
                }
                await reporter.reportIfNeeded(completed: loaded)
            }
        }

        return results
    }
}

