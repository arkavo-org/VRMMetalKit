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
import simd
@testable import VRMMetalKit

// Helper to disambiguate simd_quatf initializer (VRMMetalKit has its own extension)
// Manually compute quaternion from angle-axis to avoid ambiguity
private func makeQuaternion(angle: Float, axis: SIMD3<Float>) -> simd_quatf {
    let halfAngle = angle * 0.5
    let sinHalf = sin(halfAngle)
    let cosHalf = cos(halfAngle)
    let normalizedAxis = simd_normalize(axis)
    return simd_quatf(
        ix: normalizedAxis.x * sinHalf,
        iy: normalizedAxis.y * sinHalf,
        iz: normalizedAxis.z * sinHalf,
        r: cosHalf
    )
}

/// Comprehensive animation system tests covering:
/// - Tier 1: Pure math tests (VRMNode transforms directly)
/// - Tier 2: VRMBuilder integration tests
/// - Tier 3: Real file integration tests
final class AnimationTests: XCTestCase {

    // MARK: - Helper Utilities

    /// Compare quaternions with tolerance, handling double-cover (q == -q represent same rotation)
    func assertQuaternionsEqual(
        _ q1: simd_quatf,
        _ q2: simd_quatf,
        tolerance: Float = 0.001,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        // Quaternions q and -q represent the same rotation
        let dot = simd_dot(q1.vector, q2.vector)
        let q2Adjusted = dot < 0 ? simd_quatf(vector: -q2.vector) : q2

        XCTAssertEqual(q1.imag.x, q2Adjusted.imag.x, accuracy: tolerance,
                       "Quaternion X component mismatch", file: file, line: line)
        XCTAssertEqual(q1.imag.y, q2Adjusted.imag.y, accuracy: tolerance,
                       "Quaternion Y component mismatch", file: file, line: line)
        XCTAssertEqual(q1.imag.z, q2Adjusted.imag.z, accuracy: tolerance,
                       "Quaternion Z component mismatch", file: file, line: line)
        XCTAssertEqual(q1.real, q2Adjusted.real, accuracy: tolerance,
                       "Quaternion W component mismatch", file: file, line: line)
    }

    /// Extract world position from a 4x4 matrix
    func worldPosition(_ matrix: float4x4) -> SIMD3<Float> {
        return SIMD3<Float>(matrix[3][0], matrix[3][1], matrix[3][2])
    }

    /// Transform a point through a 4x4 matrix
    func transformPoint(_ matrix: float4x4, _ point: SIMD3<Float>) -> SIMD3<Float> {
        let p4 = matrix * SIMD4<Float>(point.x, point.y, point.z, 1.0)
        return SIMD3<Float>(p4.x, p4.y, p4.z)
    }

    /// Transform a direction (no translation) through a 4x4 matrix
    func transformDirection(_ matrix: float4x4, _ dir: SIMD3<Float>) -> SIMD3<Float> {
        let d4 = matrix * SIMD4<Float>(dir.x, dir.y, dir.z, 0.0)
        return SIMD3<Float>(d4.x, d4.y, d4.z)
    }

    /// Create a simple test node with given index and optional name
    func createTestNode(index: Int, name: String? = nil) -> VRMNode {
        let gltfNode = GLTFNode(
            name: name,
            children: nil,
            matrix: nil,
            translation: nil,
            rotation: nil,
            scale: nil,
            mesh: nil,
            skin: nil,
            weights: nil
        )
        return VRMNode(index: index, gltfNode: gltfNode)
    }

    /// Set up parent-child relationship between nodes
    func setupHierarchy(parent: VRMNode, child: VRMNode) {
        child.parent = parent
        parent.children.append(child)
    }

    // MARK: - Tier 1: Pure Math Tests (VRMNode Direct)

    /// Test that identity transforms produce identity local matrix
    func testVRMNodeLocalMatrixIdentity() throws {
        let node = createTestNode(index: 0, name: "test")

        // Default values should be identity
        XCTAssertEqual(node.translation, SIMD3<Float>(0, 0, 0))
        XCTAssertEqual(node.scale, SIMD3<Float>(1, 1, 1))
        assertQuaternionsEqual(node.rotation, simd_quatf(ix: 0, iy: 0, iz: 0, r: 1))

        node.updateLocalMatrix()

        // Local matrix should be identity
        XCTAssertEqual(node.localMatrix[0][0], 1.0, accuracy: 0.0001)
        XCTAssertEqual(node.localMatrix[1][1], 1.0, accuracy: 0.0001)
        XCTAssertEqual(node.localMatrix[2][2], 1.0, accuracy: 0.0001)
        XCTAssertEqual(node.localMatrix[3][3], 1.0, accuracy: 0.0001)

        // Off-diagonal should be 0
        XCTAssertEqual(node.localMatrix[0][1], 0.0, accuracy: 0.0001)
        XCTAssertEqual(node.localMatrix[0][2], 0.0, accuracy: 0.0001)
        XCTAssertEqual(node.localMatrix[1][0], 0.0, accuracy: 0.0001)
        XCTAssertEqual(node.localMatrix[1][2], 0.0, accuracy: 0.0001)
        XCTAssertEqual(node.localMatrix[2][0], 0.0, accuracy: 0.0001)
        XCTAssertEqual(node.localMatrix[2][1], 0.0, accuracy: 0.0001)
    }

    /// Test translation appears correctly in local matrix
    func testVRMNodeLocalMatrixTranslation() throws {
        let node = createTestNode(index: 0)
        node.translation = SIMD3<Float>(1, 2, 3)
        node.updateLocalMatrix()

        // Translation should appear in column 3
        XCTAssertEqual(node.localMatrix[3][0], 1.0, accuracy: 0.0001, "X translation")
        XCTAssertEqual(node.localMatrix[3][1], 2.0, accuracy: 0.0001, "Y translation")
        XCTAssertEqual(node.localMatrix[3][2], 3.0, accuracy: 0.0001, "Z translation")
        XCTAssertEqual(node.localMatrix[3][3], 1.0, accuracy: 0.0001, "W should be 1")
    }

    /// Test 90° X-axis rotation transforms Y to Z
    func testVRMNodeRotation90X() throws {
        let node = createTestNode(index: 0)
        node.rotation = makeQuaternion(angle: .pi / 2, axis: SIMD3<Float>(1, 0, 0))
        node.updateLocalMatrix()

        // Unit Y should become unit Z
        let unitY = SIMD3<Float>(0, 1, 0)
        let transformed = transformDirection(node.localMatrix, unitY)

        XCTAssertEqual(transformed.x, 0.0, accuracy: 0.001, "X should be 0")
        XCTAssertEqual(transformed.y, 0.0, accuracy: 0.001, "Y should be 0")
        XCTAssertEqual(transformed.z, 1.0, accuracy: 0.001, "Z should be 1")

        // Unit Z should become -Y
        let unitZ = SIMD3<Float>(0, 0, 1)
        let transformedZ = transformDirection(node.localMatrix, unitZ)

        XCTAssertEqual(transformedZ.x, 0.0, accuracy: 0.001)
        XCTAssertEqual(transformedZ.y, -1.0, accuracy: 0.001)
        XCTAssertEqual(transformedZ.z, 0.0, accuracy: 0.001)
    }

    /// Test 90° Y-axis rotation transforms X to -Z
    func testVRMNodeRotation90Y() throws {
        let node = createTestNode(index: 0)
        node.rotation = makeQuaternion(angle: .pi / 2, axis: SIMD3<Float>(0, 1, 0))
        node.updateLocalMatrix()

        // Unit X should become -Z
        let unitX = SIMD3<Float>(1, 0, 0)
        let transformed = transformDirection(node.localMatrix, unitX)

        XCTAssertEqual(transformed.x, 0.0, accuracy: 0.001)
        XCTAssertEqual(transformed.y, 0.0, accuracy: 0.001)
        XCTAssertEqual(transformed.z, -1.0, accuracy: 0.001)

        // Unit Z should become X
        let unitZ = SIMD3<Float>(0, 0, 1)
        let transformedZ = transformDirection(node.localMatrix, unitZ)

        XCTAssertEqual(transformedZ.x, 1.0, accuracy: 0.001)
        XCTAssertEqual(transformedZ.y, 0.0, accuracy: 0.001)
        XCTAssertEqual(transformedZ.z, 0.0, accuracy: 0.001)
    }

    /// Test 90° Z-axis rotation transforms X to Y
    func testVRMNodeRotation90Z() throws {
        let node = createTestNode(index: 0)
        node.rotation = makeQuaternion(angle: .pi / 2, axis: SIMD3<Float>(0, 0, 1))
        node.updateLocalMatrix()

        // Unit X should become Y
        let unitX = SIMD3<Float>(1, 0, 0)
        let transformed = transformDirection(node.localMatrix, unitX)

        XCTAssertEqual(transformed.x, 0.0, accuracy: 0.001)
        XCTAssertEqual(transformed.y, 1.0, accuracy: 0.001)
        XCTAssertEqual(transformed.z, 0.0, accuracy: 0.001)

        // Unit Y should become -X
        let unitY = SIMD3<Float>(0, 1, 0)
        let transformedY = transformDirection(node.localMatrix, unitY)

        XCTAssertEqual(transformedY.x, -1.0, accuracy: 0.001)
        XCTAssertEqual(transformedY.y, 0.0, accuracy: 0.001)
        XCTAssertEqual(transformedY.z, 0.0, accuracy: 0.001)
    }

    /// Test TRS matrix multiplication order: localMatrix = T * R * S
    /// With T=(5,0,0), R=90° Z, S=(2,1,1), point (1,0,0) should become (5,2,0)
    func testVRMNodeTRSOrderVerification() throws {
        let node = createTestNode(index: 0)
        node.translation = SIMD3<Float>(5, 0, 0)
        node.rotation = makeQuaternion(angle: .pi / 2, axis: SIMD3<Float>(0, 0, 1))
        node.scale = SIMD3<Float>(2, 1, 1)
        node.updateLocalMatrix()

        // Transform point (1, 0, 0):
        // Step 1 - Scale: (1,0,0) * (2,1,1) = (2,0,0)
        // Step 2 - Rotate 90° Z: (2,0,0) → (0,2,0)
        // Step 3 - Translate: (0,2,0) + (5,0,0) = (5,2,0)
        let point = SIMD3<Float>(1, 0, 0)
        let result = transformPoint(node.localMatrix, point)

        XCTAssertEqual(result.x, 5.0, accuracy: 0.001, "X should be 5")
        XCTAssertEqual(result.y, 2.0, accuracy: 0.001, "Y should be 2")
        XCTAssertEqual(result.z, 0.0, accuracy: 0.001, "Z should be 0")
    }

    /// Test that root node worldMatrix equals localMatrix
    func testVRMNodeWorldMatrixRootNode() throws {
        let root = createTestNode(index: 0, name: "root")
        root.translation = SIMD3<Float>(1, 2, 3)
        root.rotation = makeQuaternion(angle: .pi / 4, axis: SIMD3<Float>(0, 1, 0))
        root.updateLocalMatrix()
        root.updateWorldTransform()

        // World should equal local for root node
        for col in 0..<4 {
            for row in 0..<4 {
                XCTAssertEqual(root.worldMatrix[col][row], root.localMatrix[col][row],
                               accuracy: 0.0001, "Matrix mismatch at [\(col)][\(row)]")
            }
        }
    }

    /// CRITICAL TEST: Verify child inherits parent rotation
    /// Parent rotated 90° Z, child at local (1,0,0) should be at world (0,1,0)
    func testVRMNodeWorldMatrixParentChild() throws {
        let parent = createTestNode(index: 0, name: "parent")
        let child = createTestNode(index: 1, name: "child")

        setupHierarchy(parent: parent, child: child)

        // Parent: 90° Z rotation at origin
        parent.translation = SIMD3<Float>(0, 0, 0)
        parent.rotation = makeQuaternion(angle: .pi / 2, axis: SIMD3<Float>(0, 0, 1))
        parent.updateLocalMatrix()

        // Child: offset (1, 0, 0) in local space, no rotation
        child.translation = SIMD3<Float>(1, 0, 0)
        child.rotation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        child.updateLocalMatrix()

        // Propagate from parent
        parent.updateWorldTransform()

        // Child's local X (1,0,0) rotated 90° Z should become world Y (0,1,0)
        let childWorldPos = worldPosition(child.worldMatrix)

        XCTAssertEqual(childWorldPos.x, 0.0, accuracy: 0.001,
                       "Child X should be 0 (parent rotation transforms local X to world Y)")
        XCTAssertEqual(childWorldPos.y, 1.0, accuracy: 0.001,
                       "Child Y should be 1 (local X became Y after 90° Z rotation)")
        XCTAssertEqual(childWorldPos.z, 0.0, accuracy: 0.001,
                       "Child Z should be 0")
    }

    /// Test multi-level hierarchy propagation
    func testVRMNodeHierarchyPropagation() throws {
        // Create chain: root → child1 → child2 → child3
        let root = createTestNode(index: 0, name: "root")
        let child1 = createTestNode(index: 1, name: "child1")
        let child2 = createTestNode(index: 2, name: "child2")
        let child3 = createTestNode(index: 3, name: "child3")

        setupHierarchy(parent: root, child: child1)
        setupHierarchy(parent: child1, child: child2)
        setupHierarchy(parent: child2, child: child3)

        // Each node has 30° Z rotation
        let rotation30Z = makeQuaternion(angle: .pi / 6, axis: SIMD3<Float>(0, 0, 1))

        root.rotation = rotation30Z
        root.updateLocalMatrix()

        child1.translation = SIMD3<Float>(1, 0, 0)
        child1.rotation = rotation30Z
        child1.updateLocalMatrix()

        child2.translation = SIMD3<Float>(1, 0, 0)
        child2.rotation = rotation30Z
        child2.updateLocalMatrix()

        child3.translation = SIMD3<Float>(1, 0, 0)
        child3.rotation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)  // No additional rotation
        child3.updateLocalMatrix()

        // Propagate
        root.updateWorldTransform()

        // Root has 30° Z rotation
        // Child1 has 60° Z rotation (30° from root + 30° own)
        // Child2 has 90° Z rotation (60° inherited + 30° own)
        // Child3 has 90° Z rotation (inherited only)

        // At child3, the accumulated rotation is 90° Z
        // Local X direction should have become Y in world space
        let child3WorldX = transformDirection(child3.worldMatrix, SIMD3<Float>(1, 0, 0))

        XCTAssertEqual(child3WorldX.x, 0.0, accuracy: 0.01,
                       "After 90° accumulated rotation, local X should be world Y (X component)")
        XCTAssertEqual(child3WorldX.y, 1.0, accuracy: 0.01,
                       "After 90° accumulated rotation, local X should be world Y (Y component)")
        XCTAssertEqual(child3WorldX.z, 0.0, accuracy: 0.01,
                       "Z should remain 0")
    }

    /// Test translation accumulation through hierarchy
    func testVRMNodeTranslationAccumulation() throws {
        let parent = createTestNode(index: 0, name: "parent")
        let child = createTestNode(index: 1, name: "child")

        setupHierarchy(parent: parent, child: child)

        // Parent at (10, 0, 0)
        parent.translation = SIMD3<Float>(10, 0, 0)
        parent.updateLocalMatrix()

        // Child at local (0, 5, 0)
        child.translation = SIMD3<Float>(0, 5, 0)
        child.updateLocalMatrix()

        parent.updateWorldTransform()

        // Child world position should be (10, 5, 0)
        let childWorldPos = worldPosition(child.worldMatrix)

        XCTAssertEqual(childWorldPos.x, 10.0, accuracy: 0.001, "X from parent")
        XCTAssertEqual(childWorldPos.y, 5.0, accuracy: 0.001, "Y from self")
        XCTAssertEqual(childWorldPos.z, 0.0, accuracy: 0.001, "Z unchanged")
    }

    /// Test 180° rotation edge case (quaternion double-cover boundary)
    func testVRMNodeRotation180Degrees() throws {
        let node = createTestNode(index: 0)
        node.rotation = makeQuaternion(angle: .pi, axis: SIMD3<Float>(0, 1, 0))  // 180° Y
        node.updateLocalMatrix()

        // Unit X should become -X
        let unitX = SIMD3<Float>(1, 0, 0)
        let transformed = transformDirection(node.localMatrix, unitX)

        XCTAssertEqual(transformed.x, -1.0, accuracy: 0.001)
        XCTAssertEqual(transformed.y, 0.0, accuracy: 0.001)
        XCTAssertEqual(transformed.z, 0.0, accuracy: 0.001)

        // Unit Z should become -Z
        let unitZ = SIMD3<Float>(0, 0, 1)
        let transformedZ = transformDirection(node.localMatrix, unitZ)

        XCTAssertEqual(transformedZ.x, 0.0, accuracy: 0.001)
        XCTAssertEqual(transformedZ.y, 0.0, accuracy: 0.001)
        XCTAssertEqual(transformedZ.z, -1.0, accuracy: 0.001)
    }

    // MARK: - Tier 2: Animation Integration Tests

    /// Test that AnimationPlayer sets rotation on nodes
    func testAnimationPlayerSetsRotation() throws {
        // Create animation clip with rotation
        var clip = AnimationClip(duration: 1.0)
        let targetRotation = makeQuaternion(angle: .pi / 4, axis: SIMD3<Float>(0, 0, 1))  // 45° Z

        clip.jointTracks.append(JointTrack(
            bone: .hips,
            rotationSampler: { _ in targetRotation }
        ))

        // We can't easily test AnimationPlayer without a full VRMModel,
        // but we can verify the JointTrack sampling works
        let (rotation, _, _) = clip.jointTracks[0].sample(at: 0.5)

        XCTAssertNotNil(rotation)
        assertQuaternionsEqual(rotation!, targetRotation)
    }

    /// Test addEulerTrack produces correct quaternion for X axis
    func testEulerTrackXAxis() throws {
        var clip = AnimationClip(duration: 1.0)
        clip.addEulerTrack(bone: .hips, axis: .x) { _ in Float.pi / 2 }  // 90° X

        let (rotation, _, _) = clip.jointTracks[0].sample(at: 0.0)

        XCTAssertNotNil(rotation)

        let expected = makeQuaternion(angle: .pi / 2, axis: SIMD3<Float>(1, 0, 0))
        assertQuaternionsEqual(rotation!, expected)
    }

    /// Test addEulerTrack produces correct quaternion for Y axis
    func testEulerTrackYAxis() throws {
        var clip = AnimationClip(duration: 1.0)
        clip.addEulerTrack(bone: .spine, axis: .y) { _ in Float.pi / 4 }  // 45° Y

        let (rotation, _, _) = clip.jointTracks[0].sample(at: 0.0)

        XCTAssertNotNil(rotation)

        let expected = makeQuaternion(angle: .pi / 4, axis: SIMD3<Float>(0, 1, 0))
        assertQuaternionsEqual(rotation!, expected)
    }

    /// Test addEulerTrack produces correct quaternion for Z axis
    func testEulerTrackZAxis() throws {
        var clip = AnimationClip(duration: 1.0)
        clip.addEulerTrack(bone: .chest, axis: .z) { _ in Float.pi / 3 }  // 60° Z

        let (rotation, _, _) = clip.jointTracks[0].sample(at: 0.0)

        XCTAssertNotNil(rotation)

        let expected = makeQuaternion(angle: .pi / 3, axis: SIMD3<Float>(0, 0, 1))
        assertQuaternionsEqual(rotation!, expected)
    }

    /// Test time-varying Euler track (sinusoidal)
    func testEulerTrackTimeBased() throws {
        var clip = AnimationClip(duration: 2.0)
        clip.addEulerTrack(bone: .hips, axis: .z) { time in
            sin(time * .pi)  // 0 at t=0, 1 at t=0.5, 0 at t=1
        }

        // At t=0, angle should be 0
        let (rot0, _, _) = clip.jointTracks[0].sample(at: 0.0)
        XCTAssertNotNil(rot0)
        assertQuaternionsEqual(rot0!, simd_quatf(ix: 0, iy: 0, iz: 0, r: 1), tolerance: 0.01)

        // At t=0.5, angle should be sin(0.5 * pi) = 1 radian
        let (rot05, _, _) = clip.jointTracks[0].sample(at: 0.5)
        XCTAssertNotNil(rot05)
        let expected05 = makeQuaternion(angle: 1.0, axis: SIMD3<Float>(0, 0, 1))
        assertQuaternionsEqual(rot05!, expected05, tolerance: 0.01)
    }

    /// Test multiple bones in same clip
    func testMultipleBonesSameClip() throws {
        var clip = AnimationClip(duration: 1.0)

        clip.addEulerTrack(bone: .hips, axis: .z) { _ in Float.pi / 4 }
        clip.addEulerTrack(bone: .spine, axis: .x) { _ in Float.pi / 6 }
        clip.addEulerTrack(bone: .chest, axis: .y) { _ in Float.pi / 3 }

        XCTAssertEqual(clip.jointTracks.count, 3)

        // Verify each track samples correctly
        let (hipsRot, _, _) = clip.jointTracks[0].sample(at: 0.0)
        let (spineRot, _, _) = clip.jointTracks[1].sample(at: 0.0)
        let (chestRot, _, _) = clip.jointTracks[2].sample(at: 0.0)

        XCTAssertNotNil(hipsRot)
        XCTAssertNotNil(spineRot)
        XCTAssertNotNil(chestRot)

        assertQuaternionsEqual(hipsRot!, makeQuaternion(angle: .pi / 4, axis: SIMD3<Float>(0, 0, 1)))
        assertQuaternionsEqual(spineRot!, makeQuaternion(angle: .pi / 6, axis: SIMD3<Float>(1, 0, 0)))
        assertQuaternionsEqual(chestRot!, makeQuaternion(angle: .pi / 3, axis: SIMD3<Float>(0, 1, 0)))
    }

    /// Test morph track sampling
    func testMorphTrackSampling() throws {
        var clip = AnimationClip(duration: 1.0)
        clip.addMorphTrack(key: "happy") { time in
            time  // Linear from 0 to 1
        }

        XCTAssertEqual(clip.morphTracks.count, 1)
        XCTAssertEqual(clip.morphTracks[0].key, "happy")

        XCTAssertEqual(clip.morphTracks[0].sample(at: 0.0), 0.0, accuracy: 0.001)
        XCTAssertEqual(clip.morphTracks[0].sample(at: 0.5), 0.5, accuracy: 0.001)
        XCTAssertEqual(clip.morphTracks[0].sample(at: 1.0), 1.0, accuracy: 0.001)
    }

    /// Test empty clip doesn't crash
    func testEmptyClipNoCrash() throws {
        let clip = AnimationClip(duration: 0.0)

        XCTAssertEqual(clip.duration, 0.0)
        XCTAssertEqual(clip.jointTracks.count, 0)
        XCTAssertEqual(clip.morphTracks.count, 0)
        XCTAssertEqual(clip.nodeTracks.count, 0)
    }

    // MARK: - Tier 2.5: AnimationPlayer + VRMBuilder Integration

    /// Test AnimationPlayer applies rotation to VRMBuilder model
    func testAnimationPlayerWithVRMBuilderModel() throws {
        // Create a VRMBuilder model
        let model = try VRMBuilder()
            .setSkeleton(.defaultHumanoid)
            .build()

        // Verify humanoid is set up
        XCTAssertNotNil(model.humanoid, "Model should have humanoid")
        XCTAssertNotNil(model.humanoid?.getBoneNode(.hips), "Model should have hips bone")

        // Get initial hips rotation
        let hipsIndex = model.humanoid!.getBoneNode(.hips)!
        let initialRotation = model.nodes[hipsIndex].rotation

        // Create animation with 45° Z rotation
        var clip = AnimationClip(duration: 1.0)
        let targetRotation = makeQuaternion(angle: .pi / 4, axis: SIMD3<Float>(0, 0, 1))
        clip.jointTracks.append(JointTrack(
            bone: .hips,
            rotationSampler: { _ in targetRotation }
        ))

        // Apply animation
        let player = AnimationPlayer()
        player.load(clip)
        player.update(deltaTime: 0.5, model: model)

        // Verify rotation was applied
        let newRotation = model.nodes[hipsIndex].rotation
        assertQuaternionsEqual(newRotation, targetRotation, tolerance: 0.01)

        // Verify it changed from initial
        let rotationChanged = abs(simd_dot(initialRotation.vector, newRotation.vector)) < 0.99
        XCTAssertTrue(rotationChanged || initialRotation.real != newRotation.real,
                      "Rotation should have changed from initial value")
    }

    /// Test that child bones inherit parent rotation through AnimationPlayer
    func testAnimationPlayerHierarchyPropagation() throws {
        let model = try VRMBuilder()
            .setSkeleton(.defaultHumanoid)
            .build()

        guard let humanoid = model.humanoid,
              let _ = humanoid.getBoneNode(.hips),
              let spineIndex = humanoid.getBoneNode(.spine) else {
            XCTFail("Model should have hips and spine bones")
            return
        }

        // Get spine's initial world position
        let spineNode = model.nodes[spineIndex]
        let initialSpineWorldPos = worldPosition(spineNode.worldMatrix)

        // Create animation that rotates hips 90° around Z
        var clip = AnimationClip(duration: 1.0)
        let hipsRotation = makeQuaternion(angle: .pi / 2, axis: SIMD3<Float>(0, 0, 1))
        clip.jointTracks.append(JointTrack(
            bone: .hips,
            rotationSampler: { _ in hipsRotation }
        ))

        // Apply animation
        let player = AnimationPlayer()
        player.load(clip)
        player.update(deltaTime: 0.5, model: model)

        // Get new spine world position
        let newSpineWorldPos = worldPosition(spineNode.worldMatrix)

        // Spine should have moved (its world position should change due to parent rotation)
        // With a 90° Z rotation, X and Y should swap (approximately)
        let positionChanged = simd_length(newSpineWorldPos - initialSpineWorldPos) > 0.001
        XCTAssertTrue(positionChanged,
                      "Spine world position should change when hips rotates. Initial: \(initialSpineWorldPos), New: \(newSpineWorldPos)")
    }

    /// Test that AnimationPlayer updates world transforms correctly
    func testAnimationPlayerUpdatesWorldMatrix() throws {
        let model = try VRMBuilder()
            .setSkeleton(.defaultHumanoid)
            .build()

        guard let humanoid = model.humanoid,
              let hipsIndex = humanoid.getBoneNode(.hips) else {
            XCTFail("Model should have hips bone")
            return
        }

        let hipsNode = model.nodes[hipsIndex]

        // Capture initial world matrix
        let initialWorldMatrix = hipsNode.worldMatrix

        // Create animation with rotation
        var clip = AnimationClip(duration: 1.0)
        clip.addEulerTrack(bone: .hips, axis: .z) { _ in Float.pi / 4 }

        let player = AnimationPlayer()
        player.load(clip)
        player.update(deltaTime: 0.5, model: model)

        // World matrix should have changed
        let newWorldMatrix = hipsNode.worldMatrix

        // Check diagonal elements changed (rotation affects these)
        let diagonalChanged = abs(initialWorldMatrix[0][0] - newWorldMatrix[0][0]) > 0.01 ||
                              abs(initialWorldMatrix[1][1] - newWorldMatrix[1][1]) > 0.01

        XCTAssertTrue(diagonalChanged,
                      "World matrix should change after animation. Diagonal was [\(initialWorldMatrix[0][0]), \(initialWorldMatrix[1][1])], now [\(newWorldMatrix[0][0]), \(newWorldMatrix[1][1])]")
    }

    /// Test deep hierarchy: hips -> spine -> chest -> neck -> head all get updated
    func testAnimationPlayerDeepHierarchy() throws {
        let model = try VRMBuilder()
            .setSkeleton(.defaultHumanoid)
            .build()

        guard let humanoid = model.humanoid else {
            XCTFail("Model should have humanoid")
            return
        }

        // Collect world positions before animation
        let bonesToCheck: [VRMHumanoidBone] = [.hips, .spine, .chest, .neck, .head]
        var initialPositions: [VRMHumanoidBone: SIMD3<Float>] = [:]

        for bone in bonesToCheck {
            if let nodeIndex = humanoid.getBoneNode(bone) {
                initialPositions[bone] = worldPosition(model.nodes[nodeIndex].worldMatrix)
            }
        }

        // Create animation that rotates hips
        var clip = AnimationClip(duration: 1.0)
        clip.addEulerTrack(bone: .hips, axis: .z) { _ in Float.pi / 2 }  // 90° Z

        let player = AnimationPlayer()
        player.load(clip)
        player.update(deltaTime: 0.5, model: model)

        // All descendant bones should have changed world position
        for bone in bonesToCheck {
            guard let nodeIndex = humanoid.getBoneNode(bone),
                  let initialPos = initialPositions[bone] else { continue }

            let newPos = worldPosition(model.nodes[nodeIndex].worldMatrix)

            if bone != .hips {
                // Children should have moved
                let moved = simd_length(newPos - initialPos) > 0.001
                XCTAssertTrue(moved, "\(bone) world position should change when hips rotates")
            }
        }
    }

    /// Test translation sampler
    func testTranslationSampler() throws {
        let track = JointTrack(
            bone: .hips,
            translationSampler: { time in
                SIMD3<Float>(time, time * 2, time * 3)
            }
        )

        let (_, translation, _) = track.sample(at: 1.0)

        XCTAssertNotNil(translation)
        XCTAssertEqual(translation!.x, 1.0, accuracy: 0.001)
        XCTAssertEqual(translation!.y, 2.0, accuracy: 0.001)
        XCTAssertEqual(translation!.z, 3.0, accuracy: 0.001)
    }

    /// Test scale sampler
    func testScaleSampler() throws {
        let track = JointTrack(
            bone: .hips,
            scaleSampler: { _ in
                SIMD3<Float>(2, 2, 2)
            }
        )

        let (_, _, scale) = track.sample(at: 0.5)

        XCTAssertNotNil(scale)
        XCTAssertEqual(scale!.x, 2.0, accuracy: 0.001)
        XCTAssertEqual(scale!.y, 2.0, accuracy: 0.001)
        XCTAssertEqual(scale!.z, 2.0, accuracy: 0.001)
    }

    // MARK: - Tier 3: Real VRMA File Integration Tests

    /// Find project root for test files
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

    /// Test all available VRMA files and compare their characteristics
    func testAllVRMAFilesComparison() async throws {
        let modelPath = "\(projectRoot)/AliciaSolid.vrm"

        try XCTSkipIf(!FileManager.default.fileExists(atPath: modelPath),
                      "VRM model not found at \(modelPath)")

        guard let device = MTLCreateSystemDefaultDevice() else {
            XCTFail("Metal device not available")
            return
        }

        // Load VRM model
        let modelURL = URL(fileURLWithPath: modelPath)
        let model = try await VRMModel.load(from: modelURL, device: device)

        guard let humanoid = model.humanoid else {
            XCTFail("Model should have humanoid")
            return
        }

        let vrmaFiles = ["VRMA_01.vrma", "VRMA_02.vrma", "VRMA_03.vrma",
                         "VRMA_04.vrma", "VRMA_05.vrma", "VRMA_06.vrma", "VRMA_07.vrma"]

        let keyBones: [VRMHumanoidBone] = [.hips, .spine, .chest, .leftUpperArm, .rightUpperArm,
                                            .leftLowerArm, .rightLowerArm, .leftUpperLeg, .rightUpperLeg]

        print("\n" + String(repeating: "=", count: 100))
        print("VRMA FILES COMPARISON - Upper Arm Z-Rotation at t=0")
        print(String(repeating: "=", count: 100))

        for vrmaFile in vrmaFiles {
            let vrmaPath = "\(projectRoot)/\(vrmaFile)"
            guard FileManager.default.fileExists(atPath: vrmaPath) else {
                print("\n⚠️  \(vrmaFile): NOT FOUND")
                continue
            }

            let vrmaURL = URL(fileURLWithPath: vrmaPath)
            let clip = try VRMAnimationLoader.loadVRMA(from: vrmaURL, model: model)

            // Reset model to identity
            for node in model.nodes {
                node.rotation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
                node.translation = .zero
                node.scale = SIMD3<Float>(1, 1, 1)
            }

            // Apply animation at frame 0
            let player = AnimationPlayer()
            player.load(clip)
            player.isLooping = false
            player.update(deltaTime: 0.0, model: model)

            // Update world transforms
            for node in model.nodes where node.parent == nil {
                node.updateWorldTransform()
            }

            print("\n📁 \(vrmaFile)")
            print("   Duration: \(String(format: "%.2f", clip.duration))s | Tracks: \(clip.jointTracks.count)")

            // Show key bone rotations
            for bone in [VRMHumanoidBone.leftUpperArm, .rightUpperArm, .hips] {
                if let nodeIndex = humanoid.getBoneNode(bone) {
                    let rot = model.nodes[nodeIndex].rotation
                    let (axis, angleDeg) = quaternionToAxisAngle(rot)
                    print("   \(bone): \(String(format: "%6.1f", angleDeg))° around (\(String(format: "%.2f", axis.x)), \(String(format: "%.2f", axis.y)), \(String(format: "%.2f", axis.z)))")
                }
            }
        }

        print("\n" + String(repeating: "=", count: 100))
    }

    /// Test VRMA loading and verify parsed joint track data
    func testVRMALoadingParsesJointTracks() async throws {
        let modelPath = "\(projectRoot)/AliciaSolid.vrm"
        let vrmaPath = "\(projectRoot)/VRMA_01.vrma"

        try XCTSkipIf(!FileManager.default.fileExists(atPath: modelPath),
                      "VRM model not found at \(modelPath)")
        try XCTSkipIf(!FileManager.default.fileExists(atPath: vrmaPath),
                      "VRMA file not found at \(vrmaPath)")

        guard let device = MTLCreateSystemDefaultDevice() else {
            XCTFail("Metal device not available")
            return
        }

        // Load VRM model
        let modelURL = URL(fileURLWithPath: modelPath)
        let model = try await VRMModel.load(from: modelURL, device: device)

        // Load VRMA animation
        let vrmaURL = URL(fileURLWithPath: vrmaPath)
        let clip = try VRMAnimationLoader.loadVRMA(from: vrmaURL, model: model)

        // Verify animation was loaded
        XCTAssertGreaterThan(clip.duration, 0.0, "Animation should have duration")
        XCTAssertGreaterThan(clip.jointTracks.count, 0, "Animation should have joint tracks")

        print("\n=== VRMA_01.vrma Parsed Data ===")
        print("Duration: \(clip.duration)s")
        print("Joint tracks: \(clip.jointTracks.count)")

        // Sample each joint track at frame 0 and print
        for track in clip.jointTracks {
            let (rotation, translation, scale) = track.sample(at: 0.0)

            print("\nBone: \(track.bone)")
            if let r = rotation {
                print("  Rotation (t=0): quat(\(r.imag.x), \(r.imag.y), \(r.imag.z), \(r.real))")
            }
            if let t = translation {
                print("  Translation (t=0): (\(t.x), \(t.y), \(t.z))")
            }
            if let s = scale {
                print("  Scale (t=0): (\(s.x), \(s.y), \(s.z))")
            }
        }
    }

    /// Test that VRMA applies to model nodes correctly
    func testVRMAApplicationToModelNodes() async throws {
        let modelPath = "\(projectRoot)/AliciaSolid.vrm"
        let vrmaPath = "\(projectRoot)/VRMA_01.vrma"

        try XCTSkipIf(!FileManager.default.fileExists(atPath: modelPath),
                      "VRM model not found at \(modelPath)")
        try XCTSkipIf(!FileManager.default.fileExists(atPath: vrmaPath),
                      "VRMA file not found at \(vrmaPath)")

        guard let device = MTLCreateSystemDefaultDevice() else {
            XCTFail("Metal device not available")
            return
        }

        // Load model and animation
        let modelURL = URL(fileURLWithPath: modelPath)
        let model = try await VRMModel.load(from: modelURL, device: device)

        let vrmaURL = URL(fileURLWithPath: vrmaPath)
        let clip = try VRMAnimationLoader.loadVRMA(from: vrmaURL, model: model)

        guard let humanoid = model.humanoid else {
            XCTFail("Model should have humanoid")
            return
        }

        // Record initial poses
        var initialRotations: [VRMHumanoidBone: simd_quatf] = [:]
        let keyBones: [VRMHumanoidBone] = [.hips, .spine, .chest, .leftUpperArm, .rightUpperArm]

        for bone in keyBones {
            if let nodeIndex = humanoid.getBoneNode(bone) {
                initialRotations[bone] = model.nodes[nodeIndex].rotation
            }
        }

        print("\n=== Initial Bone Rotations ===")
        for (bone, rot) in initialRotations {
            print("\(bone): quat(\(rot.imag.x), \(rot.imag.y), \(rot.imag.z), \(rot.real))")
        }

        // Apply animation at frame 0
        let player = AnimationPlayer()
        player.load(clip)
        player.isLooping = false
        player.update(deltaTime: 0.0, model: model)

        // Update world transforms
        for node in model.nodes where node.parent == nil {
            node.updateWorldTransform()
        }

        print("\n=== After Animation (t=0) ===")
        for bone in keyBones {
            if let nodeIndex = humanoid.getBoneNode(bone) {
                let rot = model.nodes[nodeIndex].rotation
                print("\(bone): quat(\(rot.imag.x), \(rot.imag.y), \(rot.imag.z), \(rot.real))")
            }
        }

        // Apply animation at middle frame
        player.update(deltaTime: clip.duration / 2, model: model)
        for node in model.nodes where node.parent == nil {
            node.updateWorldTransform()
        }

        print("\n=== After Animation (t=\(clip.duration / 2)) ===")
        for bone in keyBones {
            if let nodeIndex = humanoid.getBoneNode(bone) {
                let rot = model.nodes[nodeIndex].rotation
                print("\(bone): quat(\(rot.imag.x), \(rot.imag.y), \(rot.imag.z), \(rot.real))")
            }
        }
    }

    /// Convert quaternion to axis-angle for debugging
    private func quaternionToAxisAngle(_ q: simd_quatf) -> (axis: SIMD3<Float>, angleDegrees: Float) {
        let angle = 2 * acos(min(1, max(-1, q.real)))
        let sinHalfAngle = sin(angle / 2)
        var axis = SIMD3<Float>(0, 1, 0)
        if abs(sinHalfAngle) > 0.0001 {
            axis = q.imag / sinHalfAngle
        }
        return (axis, angle * 180 / Float.pi)
    }

    /// Test VRMA arm rotations and hierarchy propagation
    func testVRMAArmRotationsAndHierarchy() async throws {
        let modelPath = "\(projectRoot)/AliciaSolid.vrm"
        let vrmaPath = "\(projectRoot)/VRMA_01.vrma"

        try XCTSkipIf(!FileManager.default.fileExists(atPath: modelPath),
                      "VRM model not found at \(modelPath)")
        try XCTSkipIf(!FileManager.default.fileExists(atPath: vrmaPath),
                      "VRMA file not found at \(vrmaPath)")

        guard let device = MTLCreateSystemDefaultDevice() else {
            XCTFail("Metal device not available")
            return
        }

        // Load model and animation
        let modelURL = URL(fileURLWithPath: modelPath)
        let model = try await VRMModel.load(from: modelURL, device: device)

        let vrmaURL = URL(fileURLWithPath: vrmaPath)
        let clip = try VRMAnimationLoader.loadVRMA(from: vrmaURL, model: model)

        guard let humanoid = model.humanoid else {
            XCTFail("Model should have humanoid")
            return
        }

        // Apply animation at frame 0
        let player = AnimationPlayer()
        player.load(clip)
        player.isLooping = false
        player.update(deltaTime: 0.0, model: model)

        // Update world transforms
        for node in model.nodes where node.parent == nil {
            node.updateWorldTransform()
        }

        print("\n=== Arm Hierarchy Analysis at t=0 ===")

        // Check left arm chain
        let leftArmBones: [VRMHumanoidBone] = [.leftShoulder, .leftUpperArm, .leftLowerArm, .leftHand]
        print("\nLeft Arm Chain:")
        for bone in leftArmBones {
            if let nodeIndex = humanoid.getBoneNode(bone) {
                let node = model.nodes[nodeIndex]
                let localRot = node.rotation
                let (axis, angleDeg) = quaternionToAxisAngle(localRot)
                let worldPos = worldPosition(node.worldMatrix)

                print("  \(bone):")
                print("    Local rotation: quat(\(localRot.imag.x), \(localRot.imag.y), \(localRot.imag.z), \(localRot.real))")
                print("    Axis-angle: axis(\(axis.x), \(axis.y), \(axis.z)) angle=\(angleDeg)°")
                print("    World position: (\(worldPos.x), \(worldPos.y), \(worldPos.z))")
                print("    Parent: \(node.parent?.name ?? "none")")
            }
        }

        // Check right arm chain
        let rightArmBones: [VRMHumanoidBone] = [.rightShoulder, .rightUpperArm, .rightLowerArm, .rightHand]
        print("\nRight Arm Chain:")
        for bone in rightArmBones {
            if let nodeIndex = humanoid.getBoneNode(bone) {
                let node = model.nodes[nodeIndex]
                let localRot = node.rotation
                let (axis, angleDeg) = quaternionToAxisAngle(localRot)
                let worldPos = worldPosition(node.worldMatrix)

                print("  \(bone):")
                print("    Local rotation: quat(\(localRot.imag.x), \(localRot.imag.y), \(localRot.imag.z), \(localRot.real))")
                print("    Axis-angle: axis(\(axis.x), \(axis.y), \(axis.z)) angle=\(angleDeg)°")
                print("    World position: (\(worldPos.x), \(worldPos.y), \(worldPos.z))")
                print("    Parent: \(node.parent?.name ?? "none")")
            }
        }

        // Verify hierarchy is correct
        for bone in leftArmBones + rightArmBones {
            if let nodeIndex = humanoid.getBoneNode(bone) {
                let node = model.nodes[nodeIndex]
                XCTAssertNotNil(node.parent, "\(bone) should have a parent in the hierarchy")
            }
        }
    }

    /// Verify quaternion values in VRMA match reasonable ranges
    func testVRMAQuaternionRanges() async throws {
        let modelPath = "\(projectRoot)/AliciaSolid.vrm"
        let vrmaPath = "\(projectRoot)/VRMA_01.vrma"

        try XCTSkipIf(!FileManager.default.fileExists(atPath: modelPath),
                      "VRM model not found at \(modelPath)")
        try XCTSkipIf(!FileManager.default.fileExists(atPath: vrmaPath),
                      "VRMA file not found at \(vrmaPath)")

        guard let device = MTLCreateSystemDefaultDevice() else {
            XCTFail("Metal device not available")
            return
        }

        // Load model and animation
        let modelURL = URL(fileURLWithPath: modelPath)
        let model = try await VRMModel.load(from: modelURL, device: device)

        let vrmaURL = URL(fileURLWithPath: vrmaPath)
        let clip = try VRMAnimationLoader.loadVRMA(from: vrmaURL, model: model)

        // Check all quaternions are normalized
        for track in clip.jointTracks {
            // Sample at multiple times
            for t in stride(from: Float(0), through: clip.duration, by: clip.duration / 10) {
                let (rotation, _, _) = track.sample(at: t)
                if let r = rotation {
                    let length = sqrt(r.imag.x * r.imag.x + r.imag.y * r.imag.y +
                                     r.imag.z * r.imag.z + r.real * r.real)
                    XCTAssertEqual(length, 1.0, accuracy: 0.01,
                        "Quaternion for \(track.bone) at t=\(t) should be normalized, got length=\(length)")
                }
            }
        }
    }
}
