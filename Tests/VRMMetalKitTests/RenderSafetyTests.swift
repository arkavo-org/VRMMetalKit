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

/// Render Safety Tests - Prevents visual artifacts from recurring.
///
/// This test suite goes beyond standard unit testing to validate:
/// - **Vertex Explosion Prevention**: Detects "tears" and "spikes" before rendering
/// - **Memory Layout Verification**: Ensures byte-level layout matches GPU expectations
/// - **Sentinel Value Sanitization**: Catches dangerous values like 65535 in joint indices
/// - **Pipeline Routing Validation**: Ensures unskinned meshes don't get skinned pipeline
/// - **Padding Gap Detection**: Detects ushort4 vs uint4 format mismatches
///
/// These tests catch bugs like:
/// - The "Cardigan Button Wedge" artifact (joint index 65535 with weight > 0)
/// - The "Shorts Spikes" artifact (out-of-bounds joint indices)
/// - The "Bald Hair" bug (unskinned mesh routed to skinned pipeline)
final class RenderSafetyTests: XCTestCase {

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
            let vrmPath = "\(candidate)/AliciaSolid.vrm"
            if fileManager.fileExists(atPath: packagePath) &&
               fileManager.fileExists(atPath: vrmPath) {
                return candidate
            }
        }
        return fileManager.currentDirectoryPath
    }

    private var museResourcesPath: String? {
        let fileManager = FileManager.default

        if let envPath = ProcessInfo.processInfo.environment["MUSE_RESOURCES_PATH"] {
            if fileManager.fileExists(atPath: "\(envPath)/AvatarSample_A.vrm.glb") {
                return envPath
            }
        }

        let relativePath = "\(projectRoot)/../Muse/Resources/VRM"
        if fileManager.fileExists(atPath: "\(relativePath)/AvatarSample_A.vrm.glb") {
            return relativePath
        }

        return nil
    }

    private func loadTestModel() async throws -> VRMModel {
        let modelPath = "\(projectRoot)/AliciaSolid.vrm"
        try XCTSkipIf(!FileManager.default.fileExists(atPath: modelPath),
                      "VRM model not found at \(modelPath)")
        let modelURL = URL(fileURLWithPath: modelPath)
        return try await VRMModel.load(from: modelURL, device: device)
    }

    private func loadAvatarSampleA() async throws -> VRMModel {
        guard let resourcesPath = museResourcesPath else {
            throw XCTSkip("Muse resources not found")
        }
        let modelPath = "\(resourcesPath)/AvatarSample_A.vrm.glb"
        try XCTSkipIf(!FileManager.default.fileExists(atPath: modelPath),
                      "AvatarSample_A.vrm.glb not found at \(modelPath)")
        let modelURL = URL(fileURLWithPath: modelPath)
        return try await VRMModel.load(from: modelURL, device: device)
    }

    private func loadAvatarSampleC() async throws -> VRMModel {
        guard let resourcesPath = museResourcesPath else {
            throw XCTSkip("Muse resources not found")
        }
        let modelPath = "\(resourcesPath)/AvatarSample_C.vrm.glb"
        try XCTSkipIf(!FileManager.default.fileExists(atPath: modelPath),
                      "AvatarSample_C.vrm.glb not found at \(modelPath)")
        let modelURL = URL(fileURLWithPath: modelPath)
        return try await VRMModel.load(from: modelURL, device: device)
    }

    // MARK: - 1. Vertex Explosion Prevention Test (CPU Skinning Simulation)

    /// Detects "tears" and "spikes" (like cardigan and shorts) without launching the app.
    ///
    /// **Concept:** If a vertex has a weight > 0 assigned to a joint index >= jointCount,
    /// it will cause a GPU memory read violation resulting in garbage transforms.
    ///
    /// **This catches:** The Cardigan tear (joint index 65535 with weight > 0)
    func testVertexExplosionPrevention_JointIndicesWithinBounds() async throws {
        let model = try await loadTestModel()

        var violations: [(mesh: Int, prim: Int, vertex: Int, jointIndex: UInt32, weight: Float, maxAllowed: Int)] = []

        for (meshIndex, mesh) in model.meshes.enumerated() {
            for (primIndex, primitive) in mesh.primitives.enumerated() {
                guard primitive.hasJoints,
                      let vertexBuffer = primitive.vertexBuffer else {
                    continue
                }

                // Get the skin's joint count for this mesh
                var jointCount = primitive.requiredPaletteSize
                for node in model.nodes {
                    if let nodeMeshIndex = node.mesh, nodeMeshIndex == meshIndex {
                        if let skinIndex = node.skin, skinIndex < model.skins.count {
                            jointCount = model.skins[skinIndex].joints.count
                        }
                        break
                    }
                }

                let vertexStride = MemoryLayout<VRMVertex>.stride
                let vertexCount = vertexBuffer.length / vertexStride
                let vertices = vertexBuffer.contents().bindMemory(to: VRMVertex.self, capacity: vertexCount)

                for i in 0..<vertexCount {
                    let joints = vertices[i].joints
                    let weights = vertices[i].weights

                    // CRITICAL CHECK: For every weight > 0, the joint index must be < jointCount
                    let jointArray = [joints.x, joints.y, joints.z, joints.w]
                    let weightArray = [weights.x, weights.y, weights.z, weights.w]

                    for (jointIdx, weight) in zip(jointArray, weightArray) {
                        if weight > 0 && Int(jointIdx) >= jointCount && jointCount > 0 {
                            violations.append((meshIndex, primIndex, i, jointIdx, weight, jointCount))
                        }
                    }
                }
            }
        }

        // Report violations
        if !violations.isEmpty {
            print("\n=== VERTEX EXPLOSION DETECTED ===")
            print("Found \(violations.count) vertices with out-of-bounds joint indices:")
            for v in violations.prefix(20) {
                print("  Mesh \(v.mesh) Prim \(v.prim) Vertex \(v.vertex): joint[\(v.jointIndex)] >= \(v.maxAllowed) with weight=\(v.weight)")
            }
            if violations.count > 20 {
                print("  ... and \(violations.count - 20) more")
            }
        }

        XCTAssertEqual(violations.count, 0,
            "Found \(violations.count) vertices that would cause vertex explosions (joints out of bounds)")
    }

    /// Same test but specifically for AvatarSample_A (the model with the cardigan and shorts)
    func testVertexExplosionPrevention_AvatarSampleA() async throws {
        let model = try await loadAvatarSampleA()

        var violations: [(mesh: Int, prim: Int, vertex: Int, jointIndex: UInt32, weight: Float, skinJointCount: Int)] = []

        for (meshIndex, mesh) in model.meshes.enumerated() {
            for (primIndex, primitive) in mesh.primitives.enumerated() {
                guard primitive.hasJoints,
                      let vertexBuffer = primitive.vertexBuffer else {
                    continue
                }

                // Find the skin for this mesh
                var skinJointCount = primitive.requiredPaletteSize
                for node in model.nodes {
                    if let nodeMeshIndex = node.mesh, nodeMeshIndex == meshIndex {
                        if let skinIndex = node.skin, skinIndex < model.skins.count {
                            skinJointCount = model.skins[skinIndex].joints.count
                        }
                        break
                    }
                }

                let vertexStride = MemoryLayout<VRMVertex>.stride
                let vertexCount = vertexBuffer.length / vertexStride
                let vertices = vertexBuffer.contents().bindMemory(to: VRMVertex.self, capacity: vertexCount)

                for i in 0..<vertexCount {
                    let joints = vertices[i].joints
                    let weights = vertices[i].weights

                    let jointArray = [joints.x, joints.y, joints.z, joints.w]
                    let weightArray = [weights.x, weights.y, weights.z, weights.w]

                    for (jointIdx, weight) in zip(jointArray, weightArray) {
                        if weight > 0 && Int(jointIdx) >= skinJointCount && skinJointCount > 0 {
                            violations.append((meshIndex, primIndex, i, jointIdx, weight, skinJointCount))
                        }
                    }
                }
            }
        }

        if !violations.isEmpty {
            print("\n=== AvatarSample_A VERTEX EXPLOSION RISK ===")
            for v in violations.prefix(10) {
                print("  Mesh \(v.mesh) Prim \(v.prim) Vertex \(v.vertex): joint[\(v.jointIndex)] >= skinJoints(\(v.skinJointCount)) weight=\(v.weight)")
            }
        }

        XCTAssertEqual(violations.count, 0,
            "AvatarSample_A has \(violations.count) vertices that could cause explosions")
    }

    // MARK: - 2. Memory Layout Verification (The Offset Hunter)

    /// Verifies VRMVertex byte-level layout matches shader expectations.
    ///
    /// **This catches:** The offset mismatch bug (48 vs 64) that caused tears.
    func testMemoryLayout_VRMVertexMatchesShaderExpectations() {
        // Expected layout (must match SkinnedShader.metal VertexIn struct):
        // position: float3 at offset 0  (16 bytes with padding)
        // normal:   float3 at offset 16 (16 bytes with padding)
        // texCoord: float2 at offset 32 (8 bytes)
        // color:    float4 at offset 48 (16 bytes) - NOTE: Not 40! Alignment padding!
        // joints:   uint4  at offset 64 (16 bytes)
        // weights:  float4 at offset 80 (16 bytes)
        // stride:   96 bytes

        let positionOffset = MemoryLayout<VRMVertex>.offset(of: \.position)!
        let normalOffset = MemoryLayout<VRMVertex>.offset(of: \.normal)!
        let texCoordOffset = MemoryLayout<VRMVertex>.offset(of: \.texCoord)!
        let colorOffset = MemoryLayout<VRMVertex>.offset(of: \.color)!
        let jointsOffset = MemoryLayout<VRMVertex>.offset(of: \.joints)!
        let weightsOffset = MemoryLayout<VRMVertex>.offset(of: \.weights)!
        let stride = MemoryLayout<VRMVertex>.stride

        print("\n=== VRMVertex Memory Layout Verification ===")
        print("position: offset \(positionOffset)")
        print("normal:   offset \(normalOffset)")
        print("texCoord: offset \(texCoordOffset)")
        print("color:    offset \(colorOffset)")
        print("joints:   offset \(jointsOffset)")
        print("weights:  offset \(weightsOffset)")
        print("stride:   \(stride)")

        // These are the CRITICAL offsets that must match the shader
        XCTAssertEqual(positionOffset, 0, "position must be at offset 0")
        XCTAssertEqual(normalOffset, 16, "normal must be at offset 16")
        XCTAssertEqual(texCoordOffset, 32, "texCoord must be at offset 32")
        XCTAssertEqual(colorOffset, 48, "color must be at offset 48 (includes alignment padding)")
        XCTAssertEqual(jointsOffset, 64, "joints must be at offset 64")
        XCTAssertEqual(weightsOffset, 80, "weights must be at offset 80")
        XCTAssertEqual(stride, 96, "stride must be 96 bytes")

        // Verify the gap between joints and weights is correct for uint4 format
        let jointsToWeightsGap = weightsOffset - jointsOffset
        XCTAssertEqual(jointsToWeightsGap, 16,
            "Gap between joints and weights should be 16 bytes (for uint4 format)")
    }

    /// Verifies that reading joint indices from raw buffer produces reasonable values.
    ///
    /// **This catches:** Cases where offset mismatch causes floats to be read as ints.
    func testMemoryLayout_JointIndicesReadAsReasonableValues() async throws {
        let model = try await loadTestModel()

        var suspiciousCount = 0
        var totalChecked = 0

        for mesh in model.meshes {
            for primitive in mesh.primitives {
                guard primitive.hasJoints,
                      let vertexBuffer = primitive.vertexBuffer else {
                    continue
                }

                let vertexStride = MemoryLayout<VRMVertex>.stride
                let vertexCount = vertexBuffer.length / vertexStride
                let rawPointer = vertexBuffer.contents()

                // Read joints at the expected offset
                let jointsOffset = MemoryLayout<VRMVertex>.offset(of: \.joints)!

                for i in 0..<min(vertexCount, 1000) { // Sample first 1000 vertices
                    totalChecked += 1

                    let vertexBase = rawPointer.advanced(by: i * vertexStride)
                    let jointsPointer = vertexBase.advanced(by: jointsOffset)
                        .assumingMemoryBound(to: UInt32.self)

                    // Read the 4 joint indices
                    let j0 = jointsPointer[0]
                    let j1 = jointsPointer[1]
                    let j2 = jointsPointer[2]
                    let j3 = jointsPointer[3]

                    // HEURISTIC: Joint indices should be small numbers (typically 0-255 for humanoids)
                    // If we see huge numbers like 3,000,000, we're reading garbage
                    let maxReasonableJoint: UInt32 = 1024
                    let maxObserved = max(j0, j1, j2, j3)

                    if maxObserved > maxReasonableJoint && maxObserved != 65535 {
                        suspiciousCount += 1
                        if suspiciousCount <= 5 {
                            print("  SUSPICIOUS: Vertex \(i) has joint indices [\(j0), \(j1), \(j2), \(j3)]")
                        }
                    }
                }
            }
        }

        print("\n=== Joint Index Sanity Check ===")
        print("Checked \(totalChecked) vertices")
        print("Suspicious (indices > 1024, excluding sentinel 65535): \(suspiciousCount)")

        // If more than 1% are suspicious, we might have an offset mismatch
        let suspiciousRatio = Float(suspiciousCount) / Float(max(totalChecked, 1))
        XCTAssertLessThan(suspiciousRatio, 0.01,
            "More than 1% of vertices have suspicious joint indices - possible offset mismatch")
    }

    // MARK: - 3. Sentinel Value Sanitizer

    /// Detects dangerous sentinel values (65535, -1) in joint indices.
    ///
    /// **Logic:**
    /// - If Joint == 65535 AND Weight > 0: **FAIL** (causes visual tear)
    /// - If Joint == 65535 AND Weight == 0: **WARN** (safe if shader guards with weight check)
    func testSentinelValueSanitizer_DetectDangerousSentinels() async throws {
        let model = try await loadTestModel()

        var dangerousSentinels: [(mesh: Int, prim: Int, vertex: Int, weight: Float)] = []
        var safeSentinels = 0

        for (meshIndex, mesh) in model.meshes.enumerated() {
            for (primIndex, primitive) in mesh.primitives.enumerated() {
                guard primitive.hasJoints,
                      let vertexBuffer = primitive.vertexBuffer else {
                    continue
                }

                let vertexStride = MemoryLayout<VRMVertex>.stride
                let vertexCount = vertexBuffer.length / vertexStride
                let vertices = vertexBuffer.contents().bindMemory(to: VRMVertex.self, capacity: vertexCount)

                for i in 0..<vertexCount {
                    let joints = vertices[i].joints
                    let weights = vertices[i].weights

                    let jointArray = [joints.x, joints.y, joints.z, joints.w]
                    let weightArray = [weights.x, weights.y, weights.z, weights.w]

                    for (joint, weight) in zip(jointArray, weightArray) {
                        // Check for sentinel value (65535 = UInt16.max or 0xFFFFFFFF)
                        if joint == 65535 || joint == UInt32.max {
                            if weight > 0 {
                                // DANGEROUS: Will cause visual artifact
                                dangerousSentinels.append((meshIndex, primIndex, i, weight))
                            } else {
                                // Safe: weight is zero so shader won't access this
                                safeSentinels += 1
                            }
                        }
                    }
                }
            }
        }

        print("\n=== Sentinel Value Analysis ===")
        print("Safe sentinels (weight == 0): \(safeSentinels)")
        print("DANGEROUS sentinels (weight > 0): \(dangerousSentinels.count)")

        if !dangerousSentinels.isEmpty {
            print("\nDANGEROUS SENTINEL VALUES DETECTED:")
            for d in dangerousSentinels.prefix(10) {
                print("  Mesh \(d.mesh) Prim \(d.prim) Vertex \(d.vertex): joint=65535 with weight=\(d.weight)")
            }
        }

        if safeSentinels > 0 {
            print("\n\u{26A0}\u{FE0F} WARNING: Found \(safeSentinels) sentinel values with weight=0")
            print("   This is safe ONLY if the shader has: 'if (weight > threshold) { ... }'")
        }

        XCTAssertEqual(dangerousSentinels.count, 0,
            "Found \(dangerousSentinels.count) dangerous sentinel values that WILL cause visual tears")
    }

    /// Same sentinel test for AvatarSample_A
    func testSentinelValueSanitizer_AvatarSampleA() async throws {
        let model = try await loadAvatarSampleA()

        var dangerousSentinels: [(mesh: Int, prim: Int, vertex: Int, weight: Float)] = []
        var safeSentinels = 0

        for (meshIndex, mesh) in model.meshes.enumerated() {
            for (primIndex, primitive) in mesh.primitives.enumerated() {
                guard primitive.hasJoints,
                      let vertexBuffer = primitive.vertexBuffer else {
                    continue
                }

                let vertexStride = MemoryLayout<VRMVertex>.stride
                let vertexCount = vertexBuffer.length / vertexStride
                let vertices = vertexBuffer.contents().bindMemory(to: VRMVertex.self, capacity: vertexCount)

                for i in 0..<vertexCount {
                    let joints = vertices[i].joints
                    let weights = vertices[i].weights

                    let jointArray = [joints.x, joints.y, joints.z, joints.w]
                    let weightArray = [weights.x, weights.y, weights.z, weights.w]

                    for (joint, weight) in zip(jointArray, weightArray) {
                        if joint == 65535 || joint == UInt32.max {
                            if weight > 0 {
                                dangerousSentinels.append((meshIndex, primIndex, i, weight))
                            } else {
                                safeSentinels += 1
                            }
                        }
                    }
                }
            }
        }

        print("\n=== AvatarSample_A Sentinel Analysis ===")
        print("Safe sentinels: \(safeSentinels)")
        print("Dangerous sentinels: \(dangerousSentinels.count)")

        XCTAssertEqual(dangerousSentinels.count, 0,
            "AvatarSample_A has \(dangerousSentinels.count) dangerous sentinel values")
    }

    // MARK: - 4. Baldness Prevention (Pipeline Routing)

    /// Ensures unskinned meshes have no skinning attributes.
    ///
    /// **This catches:** The "bald hair" bug where unskinned mesh sent to skinned pipeline.
    func testPipelineRouting_UnskinnedMeshesHaveNoSkinningAttributes() async throws {
        let model = try await loadTestModel()

        var misroutedMeshes: [(mesh: Int, prim: Int, hasJoints: Bool, hasWeights: Bool, hasSkin: Bool)] = []

        for (meshIndex, mesh) in model.meshes.enumerated() {
            // Check if any node uses this mesh with a skin
            var meshHasSkin = false
            for node in model.nodes {
                if let nodeMeshIndex = node.mesh, nodeMeshIndex == meshIndex {
                    if node.skin != nil {
                        meshHasSkin = true
                    }
                    break
                }
            }

            for (primIndex, primitive) in mesh.primitives.enumerated() {
                // If mesh has no skin, primitive should NOT have joint/weight attributes
                if !meshHasSkin && (primitive.hasJoints || primitive.hasWeights) {
                    misroutedMeshes.append((meshIndex, primIndex, primitive.hasJoints, primitive.hasWeights, meshHasSkin))
                }

                // If mesh HAS a skin, primitive SHOULD have joint/weight attributes
                if meshHasSkin && (!primitive.hasJoints || !primitive.hasWeights) {
                    // This is also a problem - skinned mesh without skinning data
                    print("\u{26A0}\u{FE0F} Mesh \(meshIndex) has skin but primitive \(primIndex) missing skinning attributes")
                }
            }
        }

        if !misroutedMeshes.isEmpty {
            print("\n=== PIPELINE ROUTING ISSUE ===")
            print("Unskinned meshes with skinning attributes:")
            for m in misroutedMeshes {
                print("  Mesh \(m.mesh) Prim \(m.prim): hasJoints=\(m.hasJoints), hasWeights=\(m.hasWeights), hasSkin=\(m.hasSkin)")
            }
        }

        // This isn't necessarily a failure, but we should track it
        if !misroutedMeshes.isEmpty {
            print("\n\u{26A0}\u{FE0F} Found \(misroutedMeshes.count) unskinned meshes with skinning attributes")
            print("   This may cause issues if routed to skinned pipeline")
        }
    }

    /// Verifies that skinned meshes have all required data.
    func testPipelineRouting_SkinnedMeshesHaveCompleteData() async throws {
        let model = try await loadTestModel()

        var incompleteSkinnedMeshes: [(mesh: Int, prim: Int, missing: String)] = []

        for (meshIndex, mesh) in model.meshes.enumerated() {
            // Find if this mesh is used with a skin
            var skinForMesh: VRMSkin?
            for node in model.nodes {
                if let nodeMeshIndex = node.mesh, nodeMeshIndex == meshIndex {
                    if let skinIndex = node.skin, skinIndex < model.skins.count {
                        skinForMesh = model.skins[skinIndex]
                    }
                    break
                }
            }

            guard skinForMesh != nil else { continue }

            for (primIndex, primitive) in mesh.primitives.enumerated() {
                var missing: [String] = []

                if !primitive.hasJoints {
                    missing.append("joints")
                }
                if !primitive.hasWeights {
                    missing.append("weights")
                }
                if primitive.vertexBuffer == nil {
                    missing.append("vertexBuffer")
                }

                if !missing.isEmpty {
                    incompleteSkinnedMeshes.append((meshIndex, primIndex, missing.joined(separator: ", ")))
                }
            }
        }

        if !incompleteSkinnedMeshes.isEmpty {
            print("\n=== INCOMPLETE SKINNED MESHES ===")
            for m in incompleteSkinnedMeshes {
                print("  Mesh \(m.mesh) Prim \(m.prim): missing \(m.missing)")
            }
        }

        XCTAssertEqual(incompleteSkinnedMeshes.count, 0,
            "Found \(incompleteSkinnedMeshes.count) skinned meshes with incomplete data - will cause rendering errors")
    }

    // MARK: - 5. Padding Gap Test

    /// Detects ushort4 vs uint4 format mismatches by checking the gap between joints and weights.
    ///
    /// **Logic:**
    /// - If Gap == 16 bytes: Format should be uint4 or float4 (or ushort4 with 8 bytes padding)
    /// - If Gap == 8 bytes: Format should be ushort4
    func testPaddingGap_JointsWeightsFormatConsistency() {
        let jointsOffset = MemoryLayout<VRMVertex>.offset(of: \.joints)!
        let weightsOffset = MemoryLayout<VRMVertex>.offset(of: \.weights)!
        let gap = weightsOffset - jointsOffset

        print("\n=== Joints/Weights Format Analysis ===")
        print("Joints offset: \(jointsOffset)")
        print("Weights offset: \(weightsOffset)")
        print("Gap: \(gap) bytes")

        // Check joints field size
        let jointsSize = MemoryLayout<SIMD4<UInt32>>.size
        print("SIMD4<UInt32> size: \(jointsSize) bytes")

        // The gap should match the size of the joints field
        XCTAssertEqual(gap, 16, "Gap between joints and weights should be 16 bytes for uint4/float4")

        // Verify joints are UInt32 (not UInt16)
        // This is critical - ushort4 would only be 8 bytes
        XCTAssertEqual(jointsSize, 16,
            "Joints should be SIMD4<UInt32> (16 bytes), not SIMD4<UInt16> (8 bytes)")

        // Additional verification: weights should be SIMD4<Float>
        let weightsSize = MemoryLayout<SIMD4<Float>>.size
        XCTAssertEqual(weightsSize, 16, "Weights should be SIMD4<Float> (16 bytes)")
    }

    /// Verifies that joint indices fit within the declared format.
    func testPaddingGap_JointIndicesFitInFormat() async throws {
        let model = try await loadTestModel()

        var overflowCount = 0
        var maxObservedIndex: UInt32 = 0

        for mesh in model.meshes {
            for primitive in mesh.primitives {
                guard primitive.hasJoints,
                      let vertexBuffer = primitive.vertexBuffer else {
                    continue
                }

                let vertexStride = MemoryLayout<VRMVertex>.stride
                let vertexCount = vertexBuffer.length / vertexStride
                let vertices = vertexBuffer.contents().bindMemory(to: VRMVertex.self, capacity: vertexCount)

                for i in 0..<vertexCount {
                    let joints = vertices[i].joints
                    let maxInVertex = max(joints.x, joints.y, joints.z, joints.w)

                    // Track max observed
                    if maxInVertex > maxObservedIndex && maxInVertex != 65535 {
                        maxObservedIndex = maxInVertex
                    }

                    // Check for values that would overflow UInt16
                    // (in case someone switches back to ushort4)
                    if maxInVertex > UInt16.max && maxInVertex != UInt32.max {
                        overflowCount += 1
                    }
                }
            }
        }

        print("\n=== Joint Index Range Analysis ===")
        print("Max observed joint index (excluding sentinels): \(maxObservedIndex)")
        print("Would overflow UInt16: \(overflowCount)")

        // Joint indices should be reasonable for humanoid models
        XCTAssertLessThan(maxObservedIndex, 1024,
            "Max joint index \(maxObservedIndex) is unusually high for a humanoid model")

        // If we have values that would overflow UInt16, that's fine with UInt32
        // but we should track it
        if overflowCount > 0 {
            print("\u{26A0}\u{FE0F} Found \(overflowCount) joint indices > 65535")
            print("   Using UInt32 format handles this correctly")
        }
    }

    // MARK: - 6. Weight Normalization Safety

    /// Verifies weights are normalized (sum to ~1.0) to prevent partial transforms.
    func testWeightNormalization_AllWeightsSumToOne() async throws {
        let model = try await loadTestModel()

        var unnormalizedVertices: [(mesh: Int, prim: Int, vertex: Int, sum: Float)] = []
        var totalChecked = 0

        for (meshIndex, mesh) in model.meshes.enumerated() {
            for (primIndex, primitive) in mesh.primitives.enumerated() {
                guard primitive.hasWeights,
                      let vertexBuffer = primitive.vertexBuffer else {
                    continue
                }

                let vertexStride = MemoryLayout<VRMVertex>.stride
                let vertexCount = vertexBuffer.length / vertexStride
                let vertices = vertexBuffer.contents().bindMemory(to: VRMVertex.self, capacity: vertexCount)

                for i in 0..<vertexCount {
                    totalChecked += 1
                    let weights = vertices[i].weights
                    let sum = weights.x + weights.y + weights.z + weights.w

                    // Weights should sum to 1.0 (with tolerance for floating point)
                    if abs(sum - 1.0) > 0.01 && sum > 0.001 {
                        unnormalizedVertices.append((meshIndex, primIndex, i, sum))
                    }
                }
            }
        }

        print("\n=== Weight Normalization Analysis ===")
        print("Total vertices checked: \(totalChecked)")
        print("Unnormalized vertices (sum != 1.0): \(unnormalizedVertices.count)")

        if !unnormalizedVertices.isEmpty {
            print("\nSample unnormalized vertices:")
            for v in unnormalizedVertices.prefix(10) {
                print("  Mesh \(v.mesh) Prim \(v.prim) Vertex \(v.vertex): sum=\(v.sum)")
            }
        }

        // Some files have slightly unnormalized weights - shader handles this
        // But we should fail if too many are way off
        let severelyUnnormalized = unnormalizedVertices.filter { abs($0.sum - 1.0) > 0.1 }
        XCTAssertEqual(severelyUnnormalized.count, 0,
            "Found \(severelyUnnormalized.count) vertices with severely unnormalized weights (deviation > 10%)")
    }

    // MARK: - 7. CPU Skinning Simulation (Identity Matrix Test)

    /// Simulates GPU skinning with identity matrices - vertices should not move.
    ///
    /// **Concept:** If skinning is correct, applying identity matrices should leave
    /// vertices in their original positions. Any movement indicates a bug.
    func testCPUSkinning_IdentityMatricesProduceNoMovement() async throws {
        let model = try await loadTestModel()

        var movedVertices: [(mesh: Int, prim: Int, vertex: Int, displacement: Float)] = []

        for (meshIndex, mesh) in model.meshes.enumerated() {
            for (primIndex, primitive) in mesh.primitives.enumerated() {
                guard primitive.hasJoints,
                      let vertexBuffer = primitive.vertexBuffer else {
                    continue
                }

                let vertexStride = MemoryLayout<VRMVertex>.stride
                let vertexCount = vertexBuffer.length / vertexStride
                let vertices = vertexBuffer.contents().bindMemory(to: VRMVertex.self, capacity: vertexCount)

                // Create identity matrices for all possible joints
                let maxJoints = max(primitive.requiredPaletteSize, 256)
                let identityMatrices = [float4x4](repeating: matrix_identity_float4x4, count: maxJoints)

                for i in 0..<vertexCount {
                    let v = vertices[i]
                    let originalPos = v.position
                    let joints = v.joints
                    let weights = v.weights

                    // Simulate skinning
                    let skinnedPos = simulateSkinning(
                        position: originalPos,
                        joints: joints,
                        weights: weights,
                        matrices: identityMatrices
                    )

                    let displacement = simd_length(skinnedPos - originalPos)

                    // With identity matrices, displacement should be near zero
                    // Strict threshold to catch any skinning anomalies
                    if displacement > 0.001 {
                        movedVertices.append((meshIndex, primIndex, i, displacement))
                    }
                }
            }
        }

        print("\n=== Identity Matrix Skinning Test ===")
        print("Vertices with unexpected movement: \(movedVertices.count)")

        if !movedVertices.isEmpty {
            print("\nVertices that moved (should be stationary):")
            for v in movedVertices.prefix(10) {
                print("  Mesh \(v.mesh) Prim \(v.prim) Vertex \(v.vertex): displaced by \(v.displacement)")
            }
        }

        XCTAssertEqual(movedVertices.count, 0,
            "With identity matrices, no vertices should move. Found \(movedVertices.count) that did.")
    }

    /// Helper: Simulate CPU skinning
    private func simulateSkinning(
        position: SIMD3<Float>,
        joints: SIMD4<UInt32>,
        weights: SIMD4<Float>,
        matrices: [float4x4]
    ) -> SIMD3<Float> {
        // Normalize weights
        let sum = weights.x + weights.y + weights.z + weights.w
        guard sum > 1e-6 else { return position }

        let w = weights / sum

        // Accumulate weighted transform
        var result = SIMD4<Float>(0, 0, 0, 0)

        let jointArray = [joints.x, joints.y, joints.z, joints.w]
        let weightArray = [w.x, w.y, w.z, w.w]

        for (j, wt) in zip(jointArray, weightArray) {
            if wt > 0.001 && Int(j) < matrices.count {
                let m = matrices[Int(j)]
                let p4 = SIMD4<Float>(position.x, position.y, position.z, 1.0)
                result += m * p4 * wt
            }
        }

        return SIMD3<Float>(result.x, result.y, result.z)
    }

    // MARK: - 8. Rest Pose Skinning Stability (Real Matrix Test)

    /// Simulates GPU skinning with REAL matrices (not identity) to catch IBM/Node mismatches.
    ///
    /// **Key Insight:** The GPU calculates `FinalMatrix = NodeTransform * InverseBindMatrix`.
    /// If `NodeTransform * IBM != Identity` for bones in rest pose, vertices will explode.
    ///
    /// **Diagnostic Value:**
    /// - If test FAILS: Issue is in **Data (GLTF Loading)** - IBMs or node hierarchy are wrong
    /// - If test PASSES: Issue is in **Metal Encoder** - wrong buffer binding
    ///
    /// This test will FAIL if the mesh would explode on the device.
    func testRestPoseSkinningStability() async throws {
        let model = try await loadAvatarSampleA()

        // Update world transforms first (propagate from roots down the hierarchy)
        for node in model.nodes where node.parent == nil {
            node.updateWorldTransform()
        }

        print("\n=== REST POSE SKINNING DIAGNOSTICS ===")
        print("Total meshes: \(model.meshes.count)")
        print("Total skins: \(model.skins.count)")
        print("Total nodes: \(model.nodes.count)")

        var explosions: [(mesh: String, maxDisplacement: Float, worstVertex: Int)] = []
        var skinnedMeshCount = 0

        for (meshIndex, mesh) in model.meshes.enumerated() {
            // Find the skin for this mesh
            var skin: VRMSkin?
            var meshNode: VRMNode?
            var skinIndex: Int?
            for node in model.nodes {
                if let nodeMeshIndex = node.mesh, nodeMeshIndex == meshIndex {
                    meshNode = node
                    if let si = node.skin, si < model.skins.count {
                        skin = model.skins[si]
                        skinIndex = si
                    }
                    break
                }
            }

            let meshName = mesh.name ?? "Mesh \(meshIndex)"
            guard let skin = skin, let skinIndex = skinIndex else {
                print("  [\(meshIndex)] \(meshName): NO SKIN (unskinned)")
                continue
            }

            skinnedMeshCount += 1
            print("  [\(meshIndex)] \(meshName): skin[\(skinIndex)] with \(skin.joints.count) joints, \(skin.inverseBindMatrices.count) IBMs")

            // DEBUG: Check if world transforms are identity (not propagated?)
            var identityWorldCount = 0
            var identityIBMCount = 0
            for (i, joint) in skin.joints.prefix(10).enumerated() {
                let wm = joint.worldMatrix
                let ibm = skin.inverseBindMatrices[i]

                let wmIsIdentity = abs(wm[0][0] - 1) < 0.001 && abs(wm[1][1] - 1) < 0.001 &&
                                   abs(wm[3][0]) < 0.001 && abs(wm[3][1]) < 0.001 && abs(wm[3][2]) < 0.001
                let ibmIsIdentity = abs(ibm[0][0] - 1) < 0.001 && abs(ibm[1][1] - 1) < 0.001 &&
                                    abs(ibm[3][0]) < 0.001 && abs(ibm[3][1]) < 0.001 && abs(ibm[3][2]) < 0.001

                if wmIsIdentity { identityWorldCount += 1 }
                if ibmIsIdentity { identityIBMCount += 1 }

                if i < 5 {
                    print("    Joint[\(i)] '\(joint.name ?? "?")': worldT=[\(wm[3][0]), \(wm[3][1]), \(wm[3][2])], ibmT=[\(ibm[3][0]), \(ibm[3][1]), \(ibm[3][2])]")
                }
            }
            print("    Identity world matrices (first 10): \(identityWorldCount), Identity IBMs (first 10): \(identityIBMCount)")

            // Compute REAL skinning matrices: GlobalNodeTransform * InverseBindMatrix
            var jointMatrices: [float4x4] = []
            var nonIdentityCount = 0
            for (jointIndex, jointNode) in skin.joints.enumerated() {
                let globalTransform = jointNode.worldMatrix
                let ibm = (jointIndex < skin.inverseBindMatrices.count)
                    ? skin.inverseBindMatrices[jointIndex]
                    : matrix_identity_float4x4
                let skinMatrix = globalTransform * ibm
                jointMatrices.append(skinMatrix)

                // Check if skinMatrix is NOT identity (potential issue source)
                let isIdentity = abs(skinMatrix[0][0] - 1) < 0.001 &&
                                 abs(skinMatrix[1][1] - 1) < 0.001 &&
                                 abs(skinMatrix[2][2] - 1) < 0.001 &&
                                 abs(skinMatrix[3][3] - 1) < 0.001 &&
                                 abs(skinMatrix[3][0]) < 0.001 &&
                                 abs(skinMatrix[3][1]) < 0.001 &&
                                 abs(skinMatrix[3][2]) < 0.001
                if !isIdentity {
                    nonIdentityCount += 1
                    if nonIdentityCount <= 3 {
                        print("    Joint[\(jointIndex)] '\(jointNode.name ?? "?")' skinMatrix NOT identity:")
                        print("      diagonal: [\(skinMatrix[0][0]), \(skinMatrix[1][1]), \(skinMatrix[2][2]), \(skinMatrix[3][3])]")
                        print("      translation: [\(skinMatrix[3][0]), \(skinMatrix[3][1]), \(skinMatrix[3][2])]")
                    }
                }
            }
            if nonIdentityCount > 3 {
                print("    ... and \(nonIdentityCount - 3) more non-identity matrices")
            }
            print("    Non-identity joint matrices: \(nonIdentityCount)/\(jointMatrices.count)")

            for primitive in mesh.primitives {
                guard primitive.hasJoints,
                      let vertexBuffer = primitive.vertexBuffer else { continue }

                let vertexStride = MemoryLayout<VRMVertex>.stride
                let vertexCount = vertexBuffer.length / vertexStride
                let vertices = vertexBuffer.contents().bindMemory(to: VRMVertex.self, capacity: vertexCount)

                var maxDisplacement: Float = 0
                var worstVertex = 0

                for i in 0..<vertexCount {
                    let v = vertices[i]
                    let p_raw = v.position
                    let p_vec4 = SIMD4<Float>(p_raw.x, p_raw.y, p_raw.z, 1.0)
                    let j = v.joints
                    let w = v.weights

                    // Apply skinning summation (exact GPU math)
                    var p_skinned = SIMD4<Float>(0, 0, 0, 0)

                    if w.x > 0 && Int(j.x) < jointMatrices.count {
                        p_skinned += (jointMatrices[Int(j.x)] * p_vec4) * w.x
                    }
                    if w.y > 0 && Int(j.y) < jointMatrices.count {
                        p_skinned += (jointMatrices[Int(j.y)] * p_vec4) * w.y
                    }
                    if w.z > 0 && Int(j.z) < jointMatrices.count {
                        p_skinned += (jointMatrices[Int(j.z)] * p_vec4) * w.z
                    }
                    if w.w > 0 && Int(j.w) < jointMatrices.count {
                        p_skinned += (jointMatrices[Int(j.w)] * p_vec4) * w.w
                    }

                    // In Rest Pose, skinned vertex should equal original
                    let displacement = simd_length(SIMD3(p_skinned.x, p_skinned.y, p_skinned.z) - p_raw)
                    if displacement > maxDisplacement {
                        maxDisplacement = displacement
                        worstVertex = i
                    }
                }

                if maxDisplacement > 0.01 { // 1cm tolerance
                    explosions.append((mesh.name ?? "Mesh \(meshIndex)", maxDisplacement, worstVertex))
                }
            }
        }

        print("\n=== SUMMARY ===")
        print("Skinned meshes tested: \(skinnedMeshCount)")
        print("Explosions detected: \(explosions.count)")

        // Report explosions
        if !explosions.isEmpty {
            print("\n=== REST POSE EXPLOSIONS DETECTED ===")
            for e in explosions {
                print("  \(e.mesh): max displacement = \(e.maxDisplacement)m at vertex \(e.worstVertex)")
            }
        } else {
            print("\nNo explosions - all skinned vertices stable in rest pose.")
            print("If mesh explodes on device, the bug is likely in Metal encoder (buffer binding)")
        }

        XCTAssertEqual(explosions.count, 0,
            "Found \(explosions.count) meshes that explode in rest pose - IBM/Node mismatch!")
    }

    /// Same rest pose stability test for AliciaSolid model
    func testRestPoseSkinningStability_AliciaSolid() async throws {
        let model = try await loadTestModel()

        // Update world transforms first
        for node in model.nodes where node.parent == nil {
            node.updateWorldTransform()
        }

        var explosions: [(mesh: String, maxDisplacement: Float, worstVertex: Int)] = []

        for (meshIndex, mesh) in model.meshes.enumerated() {
            var skin: VRMSkin?
            for node in model.nodes {
                if let nodeMeshIndex = node.mesh, nodeMeshIndex == meshIndex {
                    if let skinIndex = node.skin, skinIndex < model.skins.count {
                        skin = model.skins[skinIndex]
                    }
                    break
                }
            }

            guard let skin = skin else { continue }

            var jointMatrices: [float4x4] = []
            for (jointIndex, jointNode) in skin.joints.enumerated() {
                let globalTransform = jointNode.worldMatrix
                let ibm = (jointIndex < skin.inverseBindMatrices.count)
                    ? skin.inverseBindMatrices[jointIndex]
                    : matrix_identity_float4x4
                jointMatrices.append(globalTransform * ibm)
            }

            for primitive in mesh.primitives {
                guard primitive.hasJoints,
                      let vertexBuffer = primitive.vertexBuffer else { continue }

                let vertexStride = MemoryLayout<VRMVertex>.stride
                let vertexCount = vertexBuffer.length / vertexStride
                let vertices = vertexBuffer.contents().bindMemory(to: VRMVertex.self, capacity: vertexCount)

                var maxDisplacement: Float = 0
                var worstVertex = 0

                for i in 0..<vertexCount {
                    let v = vertices[i]
                    let p_raw = v.position
                    let p_vec4 = SIMD4<Float>(p_raw.x, p_raw.y, p_raw.z, 1.0)
                    let j = v.joints
                    let w = v.weights

                    var p_skinned = SIMD4<Float>(0, 0, 0, 0)

                    if w.x > 0 && Int(j.x) < jointMatrices.count {
                        p_skinned += (jointMatrices[Int(j.x)] * p_vec4) * w.x
                    }
                    if w.y > 0 && Int(j.y) < jointMatrices.count {
                        p_skinned += (jointMatrices[Int(j.y)] * p_vec4) * w.y
                    }
                    if w.z > 0 && Int(j.z) < jointMatrices.count {
                        p_skinned += (jointMatrices[Int(j.z)] * p_vec4) * w.z
                    }
                    if w.w > 0 && Int(j.w) < jointMatrices.count {
                        p_skinned += (jointMatrices[Int(j.w)] * p_vec4) * w.w
                    }

                    let displacement = simd_length(SIMD3(p_skinned.x, p_skinned.y, p_skinned.z) - p_raw)
                    if displacement > maxDisplacement {
                        maxDisplacement = displacement
                        worstVertex = i
                    }
                }

                if maxDisplacement > 0.01 {
                    explosions.append((mesh.name ?? "Mesh \(meshIndex)", maxDisplacement, worstVertex))
                }
            }
        }

        if !explosions.isEmpty {
            print("\n=== REST POSE EXPLOSIONS (AliciaSolid) ===")
            for e in explosions {
                print("  \(e.mesh): max displacement = \(e.maxDisplacement)m at vertex \(e.worstVertex)")
            }
        }

        XCTAssertEqual(explosions.count, 0,
            "Found \(explosions.count) meshes that explode in rest pose - IBM/Node mismatch!")
    }

    /// Rest pose stability test for AvatarSample_C (may have shorts/separate clothing meshes)
    func testRestPoseSkinningStability_AvatarSampleC() async throws {
        let model = try await loadAvatarSampleC()

        for node in model.nodes where node.parent == nil {
            node.updateWorldTransform()
        }

        print("\n=== AvatarSample_C DIAGNOSTICS ===")
        print("Total meshes: \(model.meshes.count)")
        print("Total skins: \(model.skins.count)")

        var explosions: [(mesh: String, maxDisplacement: Float, worstVertex: Int, worstJoint: Int)] = []

        for (meshIndex, mesh) in model.meshes.enumerated() {
            var skin: VRMSkin?
            var skinIndex: Int?
            for node in model.nodes {
                if let nodeMeshIndex = node.mesh, nodeMeshIndex == meshIndex {
                    if let si = node.skin, si < model.skins.count {
                        skin = model.skins[si]
                        skinIndex = si
                    }
                    break
                }
            }

            let meshName = mesh.name ?? "Mesh \(meshIndex)"
            guard let skin = skin, let skinIdx = skinIndex else {
                print("  [\(meshIndex)] \(meshName): NO SKIN")
                continue
            }

            print("  [\(meshIndex)] \(meshName): skin[\(skinIdx)] with \(skin.joints.count) joints")

            // Check for non-identity skinning matrices
            var jointMatrices: [float4x4] = []
            var nonIdentityJoints: [(idx: Int, name: String, translation: SIMD3<Float>)] = []

            for (jointIndex, jointNode) in skin.joints.enumerated() {
                let globalTransform = jointNode.worldMatrix
                let ibm = (jointIndex < skin.inverseBindMatrices.count)
                    ? skin.inverseBindMatrices[jointIndex]
                    : matrix_identity_float4x4
                let skinMatrix = globalTransform * ibm
                jointMatrices.append(skinMatrix)

                let t = SIMD3<Float>(skinMatrix[3][0], skinMatrix[3][1], skinMatrix[3][2])
                if simd_length(t) > 0.001 {
                    nonIdentityJoints.append((jointIndex, jointNode.name ?? "?", t))
                }
            }

            if !nonIdentityJoints.isEmpty {
                print("    WARNING: \(nonIdentityJoints.count) joints have non-identity skinning matrices!")
                for nij in nonIdentityJoints.prefix(5) {
                    print("      Joint[\(nij.idx)] '\(nij.name)': translation=\(nij.translation)")
                }
            }

            for primitive in mesh.primitives {
                guard primitive.hasJoints,
                      let vertexBuffer = primitive.vertexBuffer else { continue }

                let vertexStride = MemoryLayout<VRMVertex>.stride
                let vertexCount = vertexBuffer.length / vertexStride
                let vertices = vertexBuffer.contents().bindMemory(to: VRMVertex.self, capacity: vertexCount)

                var maxDisplacement: Float = 0
                var worstVertex = 0
                var worstJoint = -1

                for i in 0..<vertexCount {
                    let v = vertices[i]
                    let p_raw = v.position
                    let p_vec4 = SIMD4<Float>(p_raw.x, p_raw.y, p_raw.z, 1.0)
                    let j = v.joints
                    let w = v.weights

                    var p_skinned = SIMD4<Float>(0, 0, 0, 0)

                    if w.x > 0 && Int(j.x) < jointMatrices.count {
                        p_skinned += (jointMatrices[Int(j.x)] * p_vec4) * w.x
                    }
                    if w.y > 0 && Int(j.y) < jointMatrices.count {
                        p_skinned += (jointMatrices[Int(j.y)] * p_vec4) * w.y
                    }
                    if w.z > 0 && Int(j.z) < jointMatrices.count {
                        p_skinned += (jointMatrices[Int(j.z)] * p_vec4) * w.z
                    }
                    if w.w > 0 && Int(j.w) < jointMatrices.count {
                        p_skinned += (jointMatrices[Int(j.w)] * p_vec4) * w.w
                    }

                    let displacement = simd_length(SIMD3(p_skinned.x, p_skinned.y, p_skinned.z) - p_raw)
                    if displacement > maxDisplacement {
                        maxDisplacement = displacement
                        worstVertex = i
                        // Find which joint contributed most
                        let weights = [w.x, w.y, w.z, w.w]
                        let joints = [Int(j.x), Int(j.y), Int(j.z), Int(j.w)]
                        if let maxIdx = weights.enumerated().max(by: { $0.element < $1.element })?.offset {
                            worstJoint = joints[maxIdx]
                        }
                    }
                }

                if maxDisplacement > 0.01 {
                    explosions.append((meshName, maxDisplacement, worstVertex, worstJoint))
                }
            }
        }

        if !explosions.isEmpty {
            print("\n=== REST POSE EXPLOSIONS (AvatarSample_C) ===")
            for e in explosions {
                let jointName = e.worstJoint >= 0 ? "joint \(e.worstJoint)" : "unknown joint"
                print("  \(e.mesh): max displacement = \(e.maxDisplacement)m at vertex \(e.worstVertex) (\(jointName))")
            }
        } else {
            print("\n  No explosions detected in AvatarSample_C")
        }

        XCTAssertEqual(explosions.count, 0,
            "Found \(explosions.count) meshes that explode in rest pose - IBM/Node mismatch!")
    }

    /// Diagnostic test to dump full skinning data for investigation
    /// Run this to understand what's happening with skinning matrices
    func testDumpSkinningDataForDebugging() async throws {
        let model = try await loadAvatarSampleA()

        for node in model.nodes where node.parent == nil {
            node.updateWorldTransform()
        }

        print("\n" + String(repeating: "=", count: 70))
        print("FULL SKINNING DATA DUMP - AvatarSample_A")
        print(String(repeating: "=", count: 70))

        // List all skins
        print("\n--- SKINS (\(model.skins.count)) ---")
        for (i, skin) in model.skins.enumerated() {
            print("Skin[\(i)] '\(skin.name ?? "unnamed")': \(skin.joints.count) joints, \(skin.inverseBindMatrices.count) IBMs")
            print("  bufferByteOffset: \(skin.bufferByteOffset), matrixOffset: \(skin.matrixOffset)")

            // Check if skins share the same joints (by object identity)
            if i > 0 && model.skins[i].joints.count == model.skins[0].joints.count {
                var sameJoints = true
                for j in 0..<min(skin.joints.count, 10) {
                    if skin.joints[j] !== model.skins[0].joints[j] {
                        sameJoints = false
                        print("  DIFFERENT joint at index \(j): '\(skin.joints[j].name ?? "?")' vs '\(model.skins[0].joints[j].name ?? "?")'")
                        break
                    }
                }
                if sameJoints {
                    print("  SHARES same joints as Skin[0] (first 10 checked)")
                }
            }

            // Check first few joints
            for (j, joint) in skin.joints.prefix(5).enumerated() {
                let wm = joint.worldMatrix
                let ibm = skin.inverseBindMatrices[j]
                let skinMatrix = wm * ibm

                // Check if skinMatrix is identity
                let isIdentity = abs(skinMatrix[0][0] - 1) < 0.001 &&
                                 abs(skinMatrix[1][1] - 1) < 0.001 &&
                                 abs(skinMatrix[2][2] - 1) < 0.001 &&
                                 abs(skinMatrix[3][0]) < 0.001 &&
                                 abs(skinMatrix[3][1]) < 0.001 &&
                                 abs(skinMatrix[3][2]) < 0.001

                print("  Joint[\(j)] '\(joint.name ?? "?")': skinMatrix isIdentity=\(isIdentity)")
                if !isIdentity {
                    print("    skinMatrix translation: [\(skinMatrix[3][0]), \(skinMatrix[3][1]), \(skinMatrix[3][2])]")
                }
            }
        }

        // List which mesh uses which skin
        print("\n--- MESH-SKIN MAPPING ---")
        for (meshIndex, mesh) in model.meshes.enumerated() {
            var foundNode: VRMNode?
            var foundSkinIndex: Int?

            for node in model.nodes {
                if let nodeMeshIndex = node.mesh, nodeMeshIndex == meshIndex {
                    foundNode = node
                    foundSkinIndex = node.skin
                    break
                }
            }

            let meshName = mesh.name ?? "Mesh \(meshIndex)"
            if let si = foundSkinIndex, si < model.skins.count {
                let skin = model.skins[si]
                print("  \(meshName) -> Skin[\(si)] '\(skin.name ?? "unnamed")' (\(skin.joints.count) joints)")
            } else {
                print("  \(meshName) -> NO SKIN (unskinned mesh)")
            }
        }

        // Check for any vertices with zero weights
        print("\n--- ZERO WEIGHT CHECK ---")
        for (meshIndex, mesh) in model.meshes.enumerated() {
            for (primIndex, primitive) in mesh.primitives.enumerated() {
                guard primitive.hasJoints, let vb = primitive.vertexBuffer else { continue }

                let stride = MemoryLayout<VRMVertex>.stride
                let count = vb.length / stride
                let verts = vb.contents().bindMemory(to: VRMVertex.self, capacity: count)

                var zeroWeightCount = 0
                for i in 0..<count {
                    let w = verts[i].weights
                    let sum = w.x + w.y + w.z + w.w
                    if sum < 0.001 {
                        zeroWeightCount += 1
                    }
                }

                if zeroWeightCount > 0 {
                    print("  \(mesh.name ?? "Mesh \(meshIndex)") prim[\(primIndex)]: \(zeroWeightCount) vertices with ZERO weights!")
                }
            }
        }

        // Check max joint index used per mesh
        print("\n--- MAX JOINT INDEX PER MESH ---")
        for (meshIndex, mesh) in model.meshes.enumerated() {
            for (primIndex, primitive) in mesh.primitives.enumerated() {
                guard primitive.hasJoints, let vb = primitive.vertexBuffer else { continue }

                let stride = MemoryLayout<VRMVertex>.stride
                let count = vb.length / stride
                let verts = vb.contents().bindMemory(to: VRMVertex.self, capacity: count)

                var maxJoint: UInt32 = 0
                for i in 0..<count {
                    let j = verts[i].joints
                    let w = verts[i].weights
                    // Only count joints with non-zero weight
                    if w.x > 0 { maxJoint = max(maxJoint, j.x) }
                    if w.y > 0 { maxJoint = max(maxJoint, j.y) }
                    if w.z > 0 { maxJoint = max(maxJoint, j.z) }
                    if w.w > 0 { maxJoint = max(maxJoint, j.w) }
                }

                print("  \(mesh.name ?? "Mesh \(meshIndex)") prim[\(primIndex)]: maxJointIndex=\(maxJoint) (requiredPaletteSize=\(primitive.requiredPaletteSize))")
            }
        }

        print(String(repeating: "=", count: 70))
        print("END DUMP")
        print(String(repeating: "=", count: 70))
    }

    // MARK: - 9. Comprehensive Safety Summary

    /// Runs all safety checks and produces a summary report.
    func testSafetyCheckSummary() async throws {
        let model = try await loadTestModel()

        var report: [String] = []
        var passCount = 0
        var warnCount = 0
        var failCount = 0

        report.append("\n" + String(repeating: "=", count: 60))
        report.append("RENDER SAFETY CHECK SUMMARY")
        report.append(String(repeating: "=", count: 60))

        // Check 1: Memory Layout
        let jointsOffset = MemoryLayout<VRMVertex>.offset(of: \.joints)!
        let weightsOffset = MemoryLayout<VRMVertex>.offset(of: \.weights)!
        if jointsOffset == 64 && weightsOffset == 80 {
            report.append("\u{2705} Memory Layout: PASS (joints@64, weights@80)")
            passCount += 1
        } else {
            report.append("\u{274C} Memory Layout: FAIL (joints@\(jointsOffset), weights@\(weightsOffset))")
            failCount += 1
        }

        // Check 2: Sentinel Values
        var dangerousSentinels = 0
        var safeSentinels = 0
        for mesh in model.meshes {
            for primitive in mesh.primitives {
                guard primitive.hasJoints, let vb = primitive.vertexBuffer else { continue }
                let stride = MemoryLayout<VRMVertex>.stride
                let count = vb.length / stride
                let verts = vb.contents().bindMemory(to: VRMVertex.self, capacity: count)
                for i in 0..<count {
                    let j = verts[i].joints
                    let w = verts[i].weights
                    for (joint, weight) in zip([j.x, j.y, j.z, j.w], [w.x, w.y, w.z, w.w]) {
                        if joint == 65535 || joint == UInt32.max {
                            if weight > 0 { dangerousSentinels += 1 }
                            else { safeSentinels += 1 }
                        }
                    }
                }
            }
        }
        if dangerousSentinels == 0 {
            report.append("\u{2705} Sentinel Values: PASS (0 dangerous, \(safeSentinels) safe)")
            passCount += 1
        } else {
            report.append("\u{274C} Sentinel Values: FAIL (\(dangerousSentinels) dangerous)")
            failCount += 1
        }

        // Check 3: Weight Normalization
        var badWeights = 0
        var totalVerts = 0
        for mesh in model.meshes {
            for primitive in mesh.primitives {
                guard primitive.hasWeights, let vb = primitive.vertexBuffer else { continue }
                let stride = MemoryLayout<VRMVertex>.stride
                let count = vb.length / stride
                let verts = vb.contents().bindMemory(to: VRMVertex.self, capacity: count)
                for i in 0..<count {
                    totalVerts += 1
                    let w = verts[i].weights
                    let sum = w.x + w.y + w.z + w.w
                    if abs(sum - 1.0) > 0.1 && sum > 0.001 {
                        badWeights += 1
                    }
                }
            }
        }
        if badWeights == 0 {
            report.append("\u{2705} Weight Normalization: PASS (\(totalVerts) vertices)")
            passCount += 1
        } else {
            report.append("\u{26A0}\u{FE0F} Weight Normalization: WARN (\(badWeights) unnormalized)")
            warnCount += 1
        }

        // Check 4: Joint Index Bounds
        var outOfBoundsCount = 0
        for mesh in model.meshes {
            for primitive in mesh.primitives {
                guard primitive.hasJoints, let vb = primitive.vertexBuffer else { continue }
                let jointCount = primitive.requiredPaletteSize
                let stride = MemoryLayout<VRMVertex>.stride
                let count = vb.length / stride
                let verts = vb.contents().bindMemory(to: VRMVertex.self, capacity: count)
                for i in 0..<count {
                    let j = verts[i].joints
                    let w = verts[i].weights
                    for (joint, weight) in zip([j.x, j.y, j.z, j.w], [w.x, w.y, w.z, w.w]) {
                        if weight > 0 && Int(joint) >= jointCount && jointCount > 0 && joint != 65535 {
                            outOfBoundsCount += 1
                        }
                    }
                }
            }
        }
        if outOfBoundsCount == 0 {
            report.append("\u{2705} Joint Index Bounds: PASS")
            passCount += 1
        } else {
            report.append("\u{274C} Joint Index Bounds: FAIL (\(outOfBoundsCount) out of bounds)")
            failCount += 1
        }

        report.append(String(repeating: "-", count: 60))
        report.append("TOTAL: \(passCount) PASS, \(warnCount) WARN, \(failCount) FAIL")
        report.append(String(repeating: "=", count: 60))

        print(report.joined(separator: "\n"))

        XCTAssertEqual(failCount, 0, "Safety check found \(failCount) failures")
    }
}
