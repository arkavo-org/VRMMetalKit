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


import Metal

/// GPU buffer storage for SpringBone physics simulation state
///
/// ## Thread Safety (@unchecked Sendable)
///
/// This class is marked `@unchecked Sendable` because:
/// 1. **Metal types are not Sendable**: `MTLDevice` and `MTLBuffer` do not conform to `Sendable`,
///    but Metal's guarantees allow safe concurrent access:
///    - `MTLDevice` is thread-safe for buffer creation (Metal docs)
///    - `MTLBuffer` instances are thread-safe for GPU command encoding
///
/// 2. **GPU-owned mutable state**: All `var` buffer properties (`bonePosPrev`, `bonePosCurr`, etc.)
///    are mutated exclusively by GPU compute shaders after initialization. CPU-side code only reads
///    via async completion handlers in `SpringBoneComputeSystem.captureCompletedPositions()`.
///
/// 3. **Initialization phase**: Buffer allocation happens once in `allocateBuffers()` before any
///    concurrent access. Subsequent access is read-only from CPU or GPU-write-only.
///
/// 4. **SoA (Structure of Arrays) layout**: Buffers store physics state in GPU-friendly format
///    for parallel compute shader processing. Each buffer is independent and accessed via compute
///    encoder setBuffer() calls, which Metal serializes internally.
///
/// **Safety contract**: After initialization, buffers are effectively immutable from CPU perspective.
/// GPU writes are synchronized via command buffer completion handlers.
public final class SpringBoneBuffers: @unchecked Sendable {
    let device: MTLDevice

    // SoA buffers for SpringBone data (GPU-owned after allocation)
    var bonePosPrev: MTLBuffer?
    var bonePosCurr: MTLBuffer?
    var boneParams: MTLBuffer?
    var restLengths: MTLBuffer?
    var sphereColliders: MTLBuffer?
    var capsuleColliders: MTLBuffer?
    var planeColliders: MTLBuffer?

    var numBones: Int = 0
    var numSpheres: Int = 0
    var numCapsules: Int = 0
    var numPlanes: Int = 0

    init(device: MTLDevice) {
        self.device = device
    }

    func allocateBuffers(numBones: Int, numSpheres: Int, numCapsules: Int, numPlanes: Int = 0) {
        self.numBones = numBones
        self.numSpheres = numSpheres
        self.numCapsules = numCapsules
        self.numPlanes = numPlanes

        // Allocate SoA buffers with proper alignment
        let bonePosSize = MemoryLayout<SIMD3<Float>>.stride * numBones
        let boneParamsSize = MemoryLayout<BoneParams>.stride * numBones
        let restLengthSize = MemoryLayout<Float>.stride * numBones
        let sphereColliderSize = MemoryLayout<SphereCollider>.stride * numSpheres
        let capsuleColliderSize = MemoryLayout<CapsuleCollider>.stride * numCapsules
        let planeColliderSize = MemoryLayout<PlaneCollider>.stride * numPlanes

        bonePosPrev = device.makeBuffer(length: bonePosSize, options: [.storageModeShared])
        bonePosCurr = device.makeBuffer(length: bonePosSize, options: [.storageModeShared])
        boneParams = device.makeBuffer(length: boneParamsSize, options: [.storageModeShared])
        restLengths = device.makeBuffer(length: restLengthSize, options: [.storageModeShared])

        if numSpheres > 0 {
            sphereColliders = device.makeBuffer(length: sphereColliderSize, options: [.storageModeShared])
        }

        if numCapsules > 0 {
            capsuleColliders = device.makeBuffer(length: capsuleColliderSize, options: [.storageModeShared])
        }

        if numPlanes > 0 {
            planeColliders = device.makeBuffer(length: planeColliderSize, options: [.storageModeShared])
        }
    }

    func updateBoneParameters(_ parameters: [BoneParams]) {
        guard parameters.count == numBones else {
            vrmLogPhysics("⚠️ [SpringBoneBuffers] Parameter count mismatch: expected \(numBones), got \(parameters.count)")
            return
        }

        let ptr = boneParams?.contents().bindMemory(to: BoneParams.self, capacity: numBones)
        for i in 0..<numBones {
            ptr?[i] = parameters[i]
        }
    }

    func updateRestLengths(_ lengths: [Float]) {
        guard lengths.count == numBones else {
            vrmLogPhysics("⚠️ [SpringBoneBuffers] Rest length count mismatch: expected \(numBones), got \(lengths.count)")
            return
        }

        let ptr = restLengths?.contents().bindMemory(to: Float.self, capacity: numBones)
        for i in 0..<numBones {
            ptr?[i] = lengths[i]
        }
    }

    func updateSphereColliders(_ colliders: [SphereCollider]) {
        guard colliders.count == numSpheres else {
            vrmLogPhysics("⚠️ [SpringBoneBuffers] Sphere collider count mismatch: expected \(numSpheres), got \(colliders.count)")
            return
        }

        let ptr = sphereColliders?.contents().bindMemory(to: SphereCollider.self, capacity: numSpheres)
        for i in 0..<numSpheres {
            ptr?[i] = colliders[i]
        }
    }

    func updateCapsuleColliders(_ colliders: [CapsuleCollider]) {
        guard colliders.count == numCapsules else {
            vrmLogPhysics("⚠️ [SpringBoneBuffers] Capsule collider count mismatch: expected \(numCapsules), got \(colliders.count)")
            return
        }

        let ptr = capsuleColliders?.contents().bindMemory(to: CapsuleCollider.self, capacity: numCapsules)
        for i in 0..<numCapsules {
            ptr?[i] = colliders[i]
        }
    }

    func updatePlaneColliders(_ colliders: [PlaneCollider]) {
        guard colliders.count == numPlanes else {
            vrmLogPhysics("⚠️ [SpringBoneBuffers] Plane collider count mismatch: expected \(numPlanes), got \(colliders.count)")
            return
        }

        let ptr = planeColliders?.contents().bindMemory(to: PlaneCollider.self, capacity: numPlanes)
        for i in 0..<numPlanes {
            ptr?[i] = colliders[i]
        }
    }

    func getCurrentPositions() -> [SIMD3<Float>] {
        guard let buffer = bonePosCurr, numBones > 0 else {
            return []
        }

        let ptr = buffer.contents().bindMemory(to: SIMD3<Float>.self, capacity: numBones)
        return Array(UnsafeBufferPointer(start: ptr, count: numBones))
    }
}

// Data structures matching Metal shaders
public struct BoneParams {
    public var stiffness: Float
    public var drag: Float
    public var radius: Float
    public var parentIndex: UInt32
    public var gravityPower: Float      // Multiplier for global gravity (0.0 = no gravity, 1.0 = full)
    public var colliderGroupMask: UInt32 // Bitmask of collision groups this bone collides with (0xFFFFFFFF = all)
    public var gravityDir: SIMD3<Float> // Direction vector (normalized, typically [0, -1, 0])

    public init(stiffness: Float, drag: Float, radius: Float, parentIndex: UInt32,
                gravityPower: Float = 1.0, colliderGroupMask: UInt32 = 0xFFFFFFFF,
                gravityDir: SIMD3<Float> = SIMD3<Float>(0, -1, 0)) {
        self.stiffness = stiffness
        self.drag = drag
        self.radius = radius
        self.parentIndex = parentIndex
        self.gravityPower = gravityPower
        self.colliderGroupMask = colliderGroupMask
        self.gravityDir = gravityDir
    }
}

public struct SphereCollider {
    public var center: SIMD3<Float>
    public var radius: Float
    public var groupIndex: UInt32  // Index of the collision group this collider belongs to

    public init(center: SIMD3<Float>, radius: Float, groupIndex: UInt32 = 0) {
        self.center = center
        self.radius = radius
        self.groupIndex = groupIndex
    }
}

public struct CapsuleCollider {
    public var p0: SIMD3<Float>
    public var p1: SIMD3<Float>
    public var radius: Float
    public var groupIndex: UInt32  // Index of the collision group this collider belongs to

    public init(p0: SIMD3<Float>, p1: SIMD3<Float>, radius: Float, groupIndex: UInt32 = 0) {
        self.p0 = p0
        self.p1 = p1
        self.radius = radius
        self.groupIndex = groupIndex
    }
}

public struct PlaneCollider {
    public var point: SIMD3<Float>   // Point on the plane
    public var normal: SIMD3<Float>  // Plane normal (normalized)
    public var groupIndex: UInt32    // Index of the collision group this collider belongs to

    public init(point: SIMD3<Float>, normal: SIMD3<Float>, groupIndex: UInt32 = 0) {
        self.point = point
        self.normal = normal
        self.groupIndex = groupIndex
    }
}

public struct SpringBoneGlobalParams {
    public var gravity: SIMD3<Float>
    public var dtSub: Float
    public var windAmplitude: Float
    public var windFrequency: Float
    public var windPhase: Float
    public var windDirection: SIMD3<Float>
    public var substeps: UInt32
    public var numBones: UInt32
    public var numSpheres: UInt32
    public var numCapsules: UInt32
    public var numPlanes: UInt32

    public init(gravity: SIMD3<Float>, dtSub: Float, windAmplitude: Float, windFrequency: Float,
         windPhase: Float, windDirection: SIMD3<Float>, substeps: UInt32,
         numBones: UInt32, numSpheres: UInt32, numCapsules: UInt32, numPlanes: UInt32 = 0) {
        self.gravity = gravity
        self.dtSub = dtSub
        self.windAmplitude = windAmplitude
        self.windFrequency = windFrequency
        self.windPhase = windPhase
        self.windDirection = windDirection
        self.substeps = substeps
        self.numBones = numBones
        self.numSpheres = numSpheres
        self.numCapsules = numCapsules
        self.numPlanes = numPlanes
    }
}
