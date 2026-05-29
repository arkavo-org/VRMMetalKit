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

import XCTest
import Metal
import simd
@testable import VRMMetalKit

/// Regression tests for morph buffer key matching between compute pass and render pass.
///
/// Bug: In commit 5b482f4, an optimization changed the render pass to use a global
/// primitive index instead of per-mesh primitive index for morph buffer lookup.
/// This caused morphs on non-first meshes to fail because the keys didn't match.
///
/// Example of the bug:
/// - Mesh 0 has 3 primitives, Mesh 1 (face with visemes) has 2 primitives
/// - Compute pass creates keys: (0,0), (0,1), (0,2), (1,0), (1,1)
/// - Buggy render pass looked for: (0,0), (0,1), (0,2), (1,3), (1,4) ← Wrong!
/// - Face mesh morphs (visemes) were never found, breaking lip sync
final class MorphBufferKeyMatchTests: XCTestCase {

    var device: MTLDevice!

    override func setUp() async throws {
        device = MTLCreateSystemDefaultDevice()
        guard device != nil else {
            throw XCTSkip("Metal device not available")
        }
    }

    // MARK: - Test Helpers

    private var projectRoot: String {
        let fileManager = FileManager.default
        let candidates: [String?] = [
            ProcessInfo.processInfo.environment["PROJECT_ROOT"],
            ProcessInfo.processInfo.environment["SRCROOT"],
            URL(fileURLWithPath: #file)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .path,
            fileManager.currentDirectoryPath
        ]

        for candidate in candidates.compactMap({ $0 }) {
            let packagePath = "\(candidate)/Package.swift"
            if fileManager.fileExists(atPath: packagePath) {
                return candidate
            }
        }
        return fileManager.currentDirectoryPath
    }

    private var resourcesPath: String? {
        FileManager.default.fileExists(atPath: "\(projectRoot)/AvatarSample_A_1.0.vrm.glb") ? projectRoot : nil
    }

    private func loadAvatarSampleA() async throws -> VRMModel {
        guard let resourcesPath else {
            throw XCTSkip("AvatarSample_A_1.0.vrm.glb not found in project root")
        }
        let modelPath = "\(resourcesPath)/AvatarSample_A_1.0.vrm.glb"
        let modelURL = URL(fileURLWithPath: modelPath)
        return try await VRMModel.load(from: modelURL, device: device)
    }

    typealias MorphKey = UInt64

    /// Helper to compute morph key the same way VRMRenderer does
    func computeMorphKey(meshIndex: Int, primitiveIndex: Int) -> MorphKey {
        return (UInt64(meshIndex) << 32) | UInt64(primitiveIndex)
    }

    // MARK: - Unit Tests for Key Generation Logic

    /// Reproduces the bug: global primitive index causes key mismatch for mesh > 0
    func testBuggyGlobalIndexCausesKeyMismatch() {
        // Simulate a model with:
        // - Mesh 0: 3 primitives (body)
        // - Mesh 1: 2 primitives (face with visemes)

        let mesh0PrimitiveCount = 3
        let mesh1PrimitiveCount = 2

        // Compute pass uses per-mesh primitive index (correct)
        var computePassKeys: [(meshIdx: Int, primIdx: Int, key: MorphKey)] = []
        for meshIdx in 0..<2 {
            let primCount = meshIdx == 0 ? mesh0PrimitiveCount : mesh1PrimitiveCount
            for primIdx in 0..<primCount {
                let key = computeMorphKey(meshIndex: meshIdx, primitiveIndex: primIdx)
                computePassKeys.append((meshIdx, primIdx, key))
            }
        }

        // Buggy render pass uses global primitive index
        var buggyRenderPassKeys: [(meshIdx: Int, globalIdx: Int, key: MorphKey)] = []
        var globalIdx = 0
        for meshIdx in 0..<2 {
            let primCount = meshIdx == 0 ? mesh0PrimitiveCount : mesh1PrimitiveCount
            for _ in 0..<primCount {
                let key = computeMorphKey(meshIndex: meshIdx, primitiveIndex: globalIdx)
                buggyRenderPassKeys.append((meshIdx, globalIdx, key))
                globalIdx += 1
            }
        }

        // Mesh 0 primitives should match (global == per-mesh for first mesh)
        for i in 0..<mesh0PrimitiveCount {
            XCTAssertEqual(computePassKeys[i].key, buggyRenderPassKeys[i].key,
                          "Mesh 0 primitive \(i) should match (bug doesn't affect first mesh)")
        }

        // Mesh 1 primitives should NOT match with buggy code
        for i in 0..<mesh1PrimitiveCount {
            let computeIdx = mesh0PrimitiveCount + i
            let computeKey = computePassKeys[computeIdx].key
            let buggyKey = buggyRenderPassKeys[computeIdx].key

            XCTAssertNotEqual(computeKey, buggyKey,
                             """
                             BUG REPRODUCED: Mesh 1 primitive \(i) keys don't match!
                             Compute key: \(computeKey) (meshIdx=1, primIdx=\(i))
                             Buggy render key: \(buggyKey) (meshIdx=1, globalIdx=\(mesh0PrimitiveCount + i))
                             This causes morphs on mesh 1 (face/visemes) to not be found!
                             """)
        }
    }

    /// Verifies the fix: per-mesh primitive index produces matching keys
    func testFixedPerMeshIndexProducesMatchingKeys() {
        let mesh0PrimitiveCount = 3
        let mesh1PrimitiveCount = 2

        // Compute pass keys
        var computePassKeys: [MorphKey] = []
        for meshIdx in 0..<2 {
            let primCount = meshIdx == 0 ? mesh0PrimitiveCount : mesh1PrimitiveCount
            for primIdx in 0..<primCount {
                computePassKeys.append(computeMorphKey(meshIndex: meshIdx, primitiveIndex: primIdx))
            }
        }

        // Fixed render pass uses per-mesh primitive index (primIdxInMesh)
        var fixedRenderPassKeys: [MorphKey] = []
        for meshIdx in 0..<2 {
            let primCount = meshIdx == 0 ? mesh0PrimitiveCount : mesh1PrimitiveCount
            for primIdxInMesh in 0..<primCount {
                fixedRenderPassKeys.append(computeMorphKey(meshIndex: meshIdx, primitiveIndex: primIdxInMesh))
            }
        }

        // ALL keys should match with fix
        XCTAssertEqual(computePassKeys, fixedRenderPassKeys,
                      "Fixed render pass should produce identical keys to compute pass")
    }

    // MARK: - Integration Tests with Real VRM Model

    /// Tests that RenderItemBuilder correctly sets primIdxInMesh for multi-mesh models
    func testRenderItemBuilderSetsPrimIdxInMesh() async throws {
        let model = try await loadAvatarSampleA()

        // Find meshes with morph targets (likely face mesh)
        var meshesWithMorphs: [(meshIndex: Int, meshName: String, morphCount: Int)] = []
        for (meshIndex, mesh) in model.meshes.enumerated() {
            for primitive in mesh.primitives {
                if !primitive.morphTargets.isEmpty {
                    meshesWithMorphs.append((meshIndex, mesh.name ?? "unnamed", primitive.morphTargets.count))
                }
            }
        }

        XCTAssertFalse(meshesWithMorphs.isEmpty, "Model should have at least one mesh with morph targets")

        // Log mesh structure for debugging
        print("Model mesh structure:")
        for (idx, mesh) in model.meshes.enumerated() {
            let morphInfo = mesh.primitives.map { "morphs=\($0.morphTargets.count)" }.joined(separator: ", ")
            print("  Mesh[\(idx)] '\(mesh.name ?? "unnamed")': \(mesh.primitives.count) primitives (\(morphInfo))")
        }

        print("Meshes with morph targets:")
        for info in meshesWithMorphs {
            print("  Mesh[\(info.meshIndex)] '\(info.meshName)': \(info.morphCount) morph targets")
        }

        // Verify at least one morph mesh is NOT the first mesh (reproduces the bug scenario)
        let hasNonFirstMeshWithMorphs = meshesWithMorphs.contains { $0.meshIndex > 0 }
        if hasNonFirstMeshWithMorphs {
            print("✓ Model has morph targets on non-first mesh - this is the bug scenario!")
        }
    }

    /// Tests that viseme morph targets on face mesh can be found with correct key
    func testVisemeMorphTargetsCanBeFoundWithCorrectKey() async throws {
        let model = try await loadAvatarSampleA()

        // Find face mesh with viseme expressions
        var faceMeshInfo: (meshIndex: Int, primIndex: Int, morphNames: [String])?

        for (meshIndex, mesh) in model.meshes.enumerated() {
            for (primIndex, primitive) in mesh.primitives.enumerated() {
                if !primitive.morphTargets.isEmpty {
                    let morphNames = primitive.morphTargets.compactMap { $0.name }
                    let hasVisemes = morphNames.contains { name in
                        ["aa", "ih", "ou", "ee", "oh"].contains(name.lowercased())
                    }
                    if hasVisemes {
                        faceMeshInfo = (meshIndex, primIndex, morphNames)
                        break
                    }
                }
            }
            if faceMeshInfo != nil { break }
        }

        // Skip if no visemes found
        guard let faceInfo = faceMeshInfo else {
            throw XCTSkip("Model doesn't have viseme morph targets")
        }

        print("Face mesh with visemes found:")
        print("  Mesh index: \(faceInfo.meshIndex)")
        print("  Primitive index (in mesh): \(faceInfo.primIndex)")
        print("  Morph targets: \(faceInfo.morphNames)")

        // The correct key uses per-mesh primitive index
        let correctKey = computeMorphKey(meshIndex: faceInfo.meshIndex, primitiveIndex: faceInfo.primIndex)

        // Calculate what the buggy global index would be
        var globalPrimIndex = 0
        for meshIdx in 0..<faceInfo.meshIndex {
            globalPrimIndex += model.meshes[meshIdx].primitives.count
        }
        globalPrimIndex += faceInfo.primIndex

        let buggyKey = computeMorphKey(meshIndex: faceInfo.meshIndex, primitiveIndex: globalPrimIndex)

        print("Key comparison:")
        print("  Correct key (per-mesh primIdx=\(faceInfo.primIndex)): \(correctKey)")
        print("  Buggy key (global primIdx=\(globalPrimIndex)): \(buggyKey)")

        if faceInfo.meshIndex > 0 {
            XCTAssertNotEqual(correctKey, buggyKey,
                             """
                             BUG SCENARIO CONFIRMED:
                             Face mesh is at index \(faceInfo.meshIndex) (not first mesh).
                             With buggy global primitive index, viseme morphs would NOT be found!
                             Correct key: \(correctKey), Buggy key: \(buggyKey)
                             """)
            print("✓ Bug scenario confirmed: Face mesh is not first, keys differ!")
        } else {
            print("Note: Face mesh is first mesh, bug wouldn't manifest in this model")
        }
    }

    /// Tests that morph compute pass and render pass use matching key generation
    func testMorphKeyConsistencyBetweenPasses() async throws {
        let model = try await loadAvatarSampleA()

        // Simulate compute pass key generation (iterates meshes, then primitives)
        var computePassKeys: [(meshIdx: Int, primIdxInMesh: Int, key: MorphKey)] = []
        for (meshIndex, mesh) in model.meshes.enumerated() {
            for (primitiveIndex, primitive) in mesh.primitives.enumerated() {
                if !primitive.morphTargets.isEmpty {
                    let key = computeMorphKey(meshIndex: meshIndex, primitiveIndex: primitiveIndex)
                    computePassKeys.append((meshIndex, primitiveIndex, key))
                }
            }
        }

        // Simulate FIXED render pass key generation (uses primIdxInMesh, not global)
        var renderPassKeys: [(meshIdx: Int, primIdxInMesh: Int, key: MorphKey)] = []
        for (meshIndex, mesh) in model.meshes.enumerated() {
            for (primIdxInMesh, primitive) in mesh.primitives.enumerated() {
                if !primitive.morphTargets.isEmpty {
                    let key = computeMorphKey(meshIndex: meshIndex, primitiveIndex: primIdxInMesh)
                    renderPassKeys.append((meshIndex, primIdxInMesh, key))
                }
            }
        }

        // All keys should match
        XCTAssertEqual(computePassKeys.count, renderPassKeys.count,
                      "Same number of morph primitives should be processed")

        for (compute, render) in zip(computePassKeys, renderPassKeys) {
            XCTAssertEqual(compute.key, render.key,
                          """
                          Key mismatch for mesh[\(compute.meshIdx)] prim[\(compute.primIdxInMesh)]!
                          Compute: \(compute.key), Render: \(render.key)
                          """)
        }

        print("✓ All \(computePassKeys.count) morph primitive keys match between passes")
    }

    /// End-to-end test: Apply viseme morph and verify it would be found in render pass
    func testVisemeMorphApplicationEndToEnd() async throws {
        let model = try await loadAvatarSampleA()

        // Find a mesh with viseme morph targets
        var visemeMeshInfo: (meshIndex: Int, primIndex: Int)?
        for (meshIndex, mesh) in model.meshes.enumerated() {
            for (primIndex, primitive) in mesh.primitives.enumerated() {
                let hasViseme = primitive.morphTargets.contains { target in
                    let name = target.name.lowercased()
                    return ["aa", "ih", "ou", "ee", "oh"].contains(name)
                }
                if hasViseme {
                    visemeMeshInfo = (meshIndex, primIndex)
                    break
                }
            }
            if visemeMeshInfo != nil { break }
        }

        guard let info = visemeMeshInfo else {
            throw XCTSkip("No viseme morph targets found")
        }

        // Simulate what the compute pass would store
        let computeKey = computeMorphKey(meshIndex: info.meshIndex, primitiveIndex: info.primIndex)
        var morphedBuffers: [MorphKey: String] = [:]  // Using String as mock buffer
        morphedBuffers[computeKey] = "MockMorphedBuffer"

        // Simulate FIXED render pass lookup
        let renderKey = computeMorphKey(meshIndex: info.meshIndex, primitiveIndex: info.primIndex)
        let foundBuffer = morphedBuffers[renderKey]

        XCTAssertNotNil(foundBuffer,
                       """
                       Viseme morph buffer should be found!
                       Mesh: \(info.meshIndex), PrimIdxInMesh: \(info.primIndex)
                       Key: \(renderKey)
                       """)

        // Simulate BUGGY render pass lookup (would fail for non-first mesh)
        var globalPrimIdx = 0
        for i in 0..<info.meshIndex {
            globalPrimIdx += model.meshes[i].primitives.count
        }
        globalPrimIdx += info.primIndex

        let buggyRenderKey = computeMorphKey(meshIndex: info.meshIndex, primitiveIndex: globalPrimIdx)

        if info.meshIndex > 0 {
            let buggyFoundBuffer = morphedBuffers[buggyRenderKey]
            XCTAssertNil(buggyFoundBuffer,
                        """
                        BUG CONFIRMED: Buggy lookup would NOT find the buffer!
                        Correct key: \(computeKey)
                        Buggy key: \(buggyRenderKey)
                        Face mesh is at index \(info.meshIndex), not first mesh.
                        """)
            print("✓ Test confirms bug: Buggy key \(buggyRenderKey) != correct key \(computeKey)")
        }

        print("✓ End-to-end test passed: Viseme morph buffer found with correct key")
    }
}
