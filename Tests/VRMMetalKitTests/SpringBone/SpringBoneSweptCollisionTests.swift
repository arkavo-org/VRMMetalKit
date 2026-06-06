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

/// Continuous-collision (CCD / swept) guard for the SpringBone sphere kernel (#313).
///
/// The discrete collision kernel tests only the substep END position
/// (`bonePosCurr`) against the static collider. A joint whose per-substep
/// motion `prev → curr` passes clean through a collider lands OUTSIDE on the
/// far side, so the endpoint test finds no penetration and the joint tunnels
/// straight through. These tests dispatch the real `springBoneCollideSpheres`
/// kernel against a hand-built tunneling segment — they are RED for discrete
/// collision and GREEN once the kernel sweeps the `prev → curr` segment.
final class SpringBoneSweptCollisionTests: XCTestCase {

    private var device: MTLDevice!
    private var commandQueue: MTLCommandQueue!
    private var collideSpheresPipeline: MTLComputePipelineState!
    private var collideCapsulesPipeline: MTLComputePipelineState!

    override func setUpWithError() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        guard let queue = device.makeCommandQueue() else {
            throw XCTSkip("Could not create Metal command queue")
        }
        self.device = device
        self.commandQueue = queue

        let library = try VRMShaderLibraryLoader.loadBundledLibrary(device: device)
        guard let sphereFn = library.makeFunction(name: "springBoneCollideSpheres"),
              let capsuleFn = library.makeFunction(name: "springBoneCollideCapsules") else {
            throw XCTSkip("springBone collision kernels not found in shader library")
        }
        self.collideSpheresPipeline = try device.makeComputePipelineState(function: sphereFn)
        self.collideCapsulesPipeline = try device.makeComputePipelineState(function: capsuleFn)
    }

    /// Dispatch the sphere-collision kernel once over `prev`/`curr` and return the
    /// resolved current positions. Bone 0 is a kinematic root (skipped by the
    /// kernel); the bone under test is index 1 with parent 0.
    private func runSphereCollision(
        prev: [SIMD3<Float>],
        curr: [SIMD3<Float>],
        boneRadius: Float,
        sphere: SphereCollider,
        sweptGroupIndex: UInt32? = nil
    ) throws -> [SIMD3<Float>] {
        let numBones = prev.count
        precondition(curr.count == numBones)

        let prevBuf = device.makeBuffer(bytes: prev,
                                        length: MemoryLayout<SIMD3<Float>>.stride * numBones,
                                        options: .storageModeShared)!
        let currBuf = device.makeBuffer(bytes: curr,
                                        length: MemoryLayout<SIMD3<Float>>.stride * numBones,
                                        options: .storageModeShared)!

        var boneParams: [BoneParams] = []
        for i in 0..<numBones {
            boneParams.append(BoneParams(
                stiffness: 0.5,
                drag: 0.4,
                radius: boneRadius,
                parentIndex: i == 0 ? UInt32.max : UInt32(i - 1),
                gravityPower: 0.0,
                colliderGroupMask: 0xFFFFFFFF))
        }
        let boneParamsBuf = device.makeBuffer(bytes: boneParams,
                                              length: MemoryLayout<BoneParams>.stride * numBones,
                                              options: .storageModeShared)!

        var globalParams = SpringBoneGlobalParams(
            gravity: SIMD3<Float>(0, -9.8, 0),
            dtSub: Float(1.0 / 120.0),
            windAmplitude: 0, windFrequency: 0, windPhase: 0,
            windDirection: SIMD3<Float>(1, 0, 0),
            substeps: 1,
            numBones: UInt32(numBones),
            numSpheres: 1,
            numCapsules: 0,
            numPlanes: 0)
        let globalParamsBuf = device.makeBuffer(bytes: &globalParams,
                                                length: MemoryLayout<SpringBoneGlobalParams>.stride,
                                                options: .storageModeShared)!

        var spheres = [sphere]
        let sphereBuf = device.makeBuffer(bytes: &spheres,
                                          length: MemoryLayout<SphereCollider>.stride,
                                          options: .storageModeShared)!

        // Swept (continuous) collision is scoped to the synthetic collider group
        // (#313). Default the test's swept group to the sphere's own group so the
        // swept path engages; callers override to exercise the scoping guard.
        var sweptGroup = sweptGroupIndex ?? sphere.groupIndex

        guard let cb = commandQueue.makeCommandBuffer(),
              let enc = cb.makeComputeCommandEncoder() else {
            throw XCTSkip("Could not create command buffer/encoder")
        }
        enc.setComputePipelineState(collideSpheresPipeline)
        enc.setBuffer(prevBuf, offset: 0, index: 0)
        enc.setBuffer(currBuf, offset: 0, index: 1)
        enc.setBuffer(boneParamsBuf, offset: 0, index: 2)
        enc.setBuffer(globalParamsBuf, offset: 0, index: 3)
        enc.setBuffer(sphereBuf, offset: 0, index: 5)
        enc.setBytes(&sweptGroup, length: MemoryLayout<UInt32>.size, index: 15)
        enc.dispatchThreads(MTLSize(width: numBones, height: 1, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()

        let ptr = currBuf.contents().bindMemory(to: SIMD3<Float>.self, capacity: numBones)
        return Array(UnsafeBufferPointer(start: ptr, count: numBones))
    }

    /// Dispatch the capsule-collision kernel once over `prev`/`curr` and return
    /// the resolved current positions. Mirrors `runSphereCollision`.
    private func runCapsuleCollision(
        prev: [SIMD3<Float>],
        curr: [SIMD3<Float>],
        boneRadius: Float,
        capsule: CapsuleCollider,
        sweptGroupIndex: UInt32? = nil
    ) throws -> [SIMD3<Float>] {
        let numBones = prev.count
        precondition(curr.count == numBones)

        let prevBuf = device.makeBuffer(bytes: prev,
                                        length: MemoryLayout<SIMD3<Float>>.stride * numBones,
                                        options: .storageModeShared)!
        let currBuf = device.makeBuffer(bytes: curr,
                                        length: MemoryLayout<SIMD3<Float>>.stride * numBones,
                                        options: .storageModeShared)!

        var boneParams: [BoneParams] = []
        for i in 0..<numBones {
            boneParams.append(BoneParams(
                stiffness: 0.5, drag: 0.4, radius: boneRadius,
                parentIndex: i == 0 ? UInt32.max : UInt32(i - 1),
                gravityPower: 0.0, colliderGroupMask: 0xFFFFFFFF))
        }
        let boneParamsBuf = device.makeBuffer(bytes: boneParams,
                                              length: MemoryLayout<BoneParams>.stride * numBones,
                                              options: .storageModeShared)!

        var globalParams = SpringBoneGlobalParams(
            gravity: SIMD3<Float>(0, -9.8, 0), dtSub: Float(1.0 / 120.0),
            windAmplitude: 0, windFrequency: 0, windPhase: 0,
            windDirection: SIMD3<Float>(1, 0, 0), substeps: 1,
            numBones: UInt32(numBones), numSpheres: 0, numCapsules: 1, numPlanes: 0)
        let globalParamsBuf = device.makeBuffer(bytes: &globalParams,
                                                length: MemoryLayout<SpringBoneGlobalParams>.stride,
                                                options: .storageModeShared)!

        var capsules = [capsule]
        let capsuleBuf = device.makeBuffer(bytes: &capsules,
                                           length: MemoryLayout<CapsuleCollider>.stride,
                                           options: .storageModeShared)!

        var sweptGroup = sweptGroupIndex ?? capsule.groupIndex

        guard let cb = commandQueue.makeCommandBuffer(),
              let enc = cb.makeComputeCommandEncoder() else {
            throw XCTSkip("Could not create command buffer/encoder")
        }
        enc.setComputePipelineState(collideCapsulesPipeline)
        enc.setBuffer(prevBuf, offset: 0, index: 0)
        enc.setBuffer(currBuf, offset: 0, index: 1)
        enc.setBuffer(boneParamsBuf, offset: 0, index: 2)
        enc.setBuffer(globalParamsBuf, offset: 0, index: 3)
        enc.setBuffer(capsuleBuf, offset: 0, index: 6)
        enc.setBytes(&sweptGroup, length: MemoryLayout<UInt32>.size, index: 15)
        enc.dispatchThreads(MTLSize(width: numBones, height: 1, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()

        let ptr = currBuf.contents().bindMemory(to: SIMD3<Float>.self, capacity: numBones)
        return Array(UnsafeBufferPointer(start: ptr, count: numBones))
    }

    // MARK: - Capsule swept collision

    /// A joint sweeps bottom→top straight through the middle of a capsule (axis
    /// along x) in a single substep. Discrete collision sees only the far-side
    /// endpoint (outside the capsule) and lets it pass; swept collision must stop
    /// it at the entry surface on the near side.
    func testFastSegmentThroughCapsuleIsCaughtOnEntrySide() throws {
        let boneRadius: Float = 0.02
        let capsule = CapsuleCollider(p0: SIMD3<Float>(-0.3, 0, 0),
                                      p1: SIMD3<Float>(0.3, 0, 0), radius: 0.2)
        // Path crosses perpendicular through the cylinder body, -y → +y.
        let prev = [SIMD3<Float>(0, 1, 0), SIMD3<Float>(0, -0.5, 0)]
        let curr = [SIMD3<Float>(0, 1, 0), SIMD3<Float>(0, 0.5, 0)]

        let result = try runCapsuleCollision(prev: prev, curr: curr,
                                             boneRadius: boneRadius, capsule: capsule)

        let bone = result[1]
        XCTAssertLessThan(bone.y, 0.0,
            "Swept capsule collision must catch the tunneling joint on the entry (-y) side; got y=\(bone.y). Discrete leaves it at +0.5 (tunneled through).")
        XCTAssertEqual(bone.y, -(capsule.radius + boneRadius), accuracy: 0.04,
            "Joint should rest at the capsule's entry surface (y≈-0.22), not pass through it.")
    }

    /// Shallow capsule penetration (endpoint inside) must still be pushed out by
    /// the discrete path, exactly as before — unchanged on every group.
    func testShallowCapsulePenetrationStillPushedOut() throws {
        let boneRadius: Float = 0.02
        let capsule = CapsuleCollider(p0: SIMD3<Float>(-0.3, 0, 0),
                                      p1: SIMD3<Float>(0.3, 0, 0), radius: 0.2)
        let prev = [SIMD3<Float>(0, 1, 0), SIMD3<Float>(0, -0.25, 0)]
        let curr = [SIMD3<Float>(0, 1, 0), SIMD3<Float>(0, -0.15, 0)]

        let result = try runCapsuleCollision(prev: prev, curr: curr,
                                             boneRadius: boneRadius, capsule: capsule)

        let bone = result[1]
        XCTAssertEqual(bone.y, -(capsule.radius + boneRadius), accuracy: 0.01,
            "Shallow penetration should be pushed out to the capsule surface (y≈-0.22).")
        XCTAssertLessThan(bone.y, 0.0, "Push-out must stay on the entry (-y) side.")
    }

    /// Scoping guard: a joint tunneling through a capsule in a non-synthetic
    /// group must be left to the discrete endpoint test (passes through).
    func testTunnelingThroughNonSweptGroupCapsuleNotCaught() throws {
        let boneRadius: Float = 0.02
        let capsule = CapsuleCollider(p0: SIMD3<Float>(-0.3, 0, 0),
                                      p1: SIMD3<Float>(0.3, 0, 0), radius: 0.2, groupIndex: 0)
        let prev = [SIMD3<Float>(0, 1, 0), SIMD3<Float>(0, -0.5, 0)]
        let curr = [SIMD3<Float>(0, 1, 0), SIMD3<Float>(0, 0.5, 0)]

        let result = try runCapsuleCollision(prev: prev, curr: curr,
                                             boneRadius: boneRadius, capsule: capsule,
                                             sweptGroupIndex: 7)  // no match → discrete only

        let bone = result[1]
        XCTAssertEqual(bone.y, 0.5, accuracy: 1e-5,
            "Non-synthetic group must use discrete collision; the tunneling joint passes through (y stays +0.5).")
    }

    /// A path that never reaches the capsule must be left untouched.
    func testCapsuleSegmentMissIsUntouched() throws {
        let boneRadius: Float = 0.02
        let capsule = CapsuleCollider(p0: SIMD3<Float>(-0.3, 0, 0),
                                      p1: SIMD3<Float>(0.3, 0, 0), radius: 0.2)
        // A path well above the capsule — closest approach ~0.8, no contact.
        let prev = [SIMD3<Float>(0, 2, 0), SIMD3<Float>(-0.5, 1.0, 0)]
        let curr = [SIMD3<Float>(0, 2, 0), SIMD3<Float>(0.5, 1.0, 0)]

        let result = try runCapsuleCollision(prev: prev, curr: curr,
                                             boneRadius: boneRadius, capsule: capsule)

        let bone = result[1]
        XCTAssertEqual(bone.x, 0.5, accuracy: 1e-5, "Non-colliding path untouched (x).")
        XCTAssertEqual(bone.y, 1.0, accuracy: 1e-5, "Non-colliding path untouched (y).")
    }

    /// A joint sweeps left→right straight through a sphere in a single substep.
    /// Discrete collision sees only the far-side endpoint (outside the sphere)
    /// and lets it pass; swept collision must stop it at the entry surface.
    func testFastSegmentThroughSphereIsCaughtOnEntrySide() throws {
        let boneRadius: Float = 0.02
        let sphere = SphereCollider(center: SIMD3<Float>(0, 0, 0), radius: 0.2)
        // prev on the -x side (outside), curr on the +x side (outside): the
        // segment passes clean through the sphere centre.
        let prev = [SIMD3<Float>(0, 1, 0), SIMD3<Float>(-0.5, 0, 0)]
        let curr = [SIMD3<Float>(0, 1, 0), SIMD3<Float>(0.5, 0, 0)]

        let result = try runSphereCollision(prev: prev, curr: curr,
                                            boneRadius: boneRadius, sphere: sphere)

        let bone = result[1]
        // Tunneling guard: the bone must NOT end up on the far (+x) side. The
        // entry surface is at x = -(radius + boneRadius) = -0.22.
        XCTAssertLessThan(bone.x, 0.0,
            "Swept collision must catch the tunneling joint on the entry (-x) side; got x=\(bone.x). Discrete collision leaves it at +0.5 (tunneled through).")
        XCTAssertEqual(bone.x, -(sphere.radius + boneRadius), accuracy: 0.04,
            "Joint should rest at the sphere's entry surface, not pass through it.")
        // And it must not be left penetrating the sphere either.
        let dist = simd_length(bone - sphere.center)
        XCTAssertGreaterThanOrEqual(dist, sphere.radius + boneRadius - 0.02,
            "Resolved joint should sit on/outside the sphere surface.")
    }

    /// Regression guard: a joint that genuinely ends inside the sphere (no
    /// tunneling — a slow, shallow penetration) must still be pushed out along
    /// the outward normal exactly as discrete collision already does.
    func testShallowPenetrationStillPushedOut() throws {
        let boneRadius: Float = 0.02
        let sphere = SphereCollider(center: SIMD3<Float>(0, 0, 0), radius: 0.2)
        // prev just outside on +x, curr just inside on +x: a normal shallow hit.
        let prev = [SIMD3<Float>(0, 1, 0), SIMD3<Float>(0.23, 0, 0)]
        let curr = [SIMD3<Float>(0, 1, 0), SIMD3<Float>(0.15, 0, 0)]

        let result = try runSphereCollision(prev: prev, curr: curr,
                                            boneRadius: boneRadius, sphere: sphere)

        let bone = result[1]
        let dist = simd_length(bone - sphere.center)
        XCTAssertEqual(dist, sphere.radius + boneRadius, accuracy: 0.01,
            "Shallow penetration should be pushed out to the sphere surface (x≈+0.22).")
        XCTAssertGreaterThan(bone.x, 0.0,
            "Push-out must stay on the entry (+x) side, not flip the joint across the sphere.")
    }

    /// Scoping guard: swept collision must engage ONLY for the synthetic
    /// collider group. A joint tunneling through a sphere in a DIFFERENT group
    /// (an authored body collider) must be left to the discrete endpoint test —
    /// i.e. it passes through, because clamping authored spheres deflects stiff
    /// cloth chains (the arm-swing re-entry regression, #313/#315).
    func testTunnelingThroughNonSweptGroupIsNotCaught() throws {
        let boneRadius: Float = 0.02
        // Sphere in group 0; swept group set to a non-matching index.
        let sphere = SphereCollider(center: SIMD3<Float>(0, 0, 0), radius: 0.2, groupIndex: 0)
        let prev = [SIMD3<Float>(0, 1, 0), SIMD3<Float>(-0.5, 0, 0)]
        let curr = [SIMD3<Float>(0, 1, 0), SIMD3<Float>(0.5, 0, 0)]

        let result = try runSphereCollision(prev: prev, curr: curr,
                                            boneRadius: boneRadius, sphere: sphere,
                                            sweptGroupIndex: 7)  // no match → discrete only

        let bone = result[1]
        XCTAssertEqual(bone.x, 0.5, accuracy: 1e-5,
            "Non-synthetic group must use discrete collision; the tunneling joint passes through (x stays +0.5).")
    }

    /// A segment that never reaches the sphere must be left untouched (no false
    /// catch from an over-eager sweep).
    func testSegmentMissingSphereIsUntouched() throws {
        let boneRadius: Float = 0.02
        let sphere = SphereCollider(center: SIMD3<Float>(0, 0, 0), radius: 0.2)
        // A segment well above the sphere — closest approach ~1.0, no contact.
        let prev = [SIMD3<Float>(0, 2, 0), SIMD3<Float>(-0.5, 1.0, 0)]
        let curr = [SIMD3<Float>(0, 2, 0), SIMD3<Float>(0.5, 1.0, 0)]

        let result = try runSphereCollision(prev: prev, curr: curr,
                                            boneRadius: boneRadius, sphere: sphere)

        let bone = result[1]
        XCTAssertEqual(bone.x, 0.5, accuracy: 1e-5, "Non-colliding segment must be untouched (x).")
        XCTAssertEqual(bone.y, 1.0, accuracy: 1e-5, "Non-colliding segment must be untouched (y).")
    }
}
