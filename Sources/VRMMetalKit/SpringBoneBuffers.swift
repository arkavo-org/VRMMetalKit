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
import simd

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
    var bindDirections: MTLBuffer?  // Bind pose directions for stiffness spring force
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
        bindDirections = device.makeBuffer(length: bonePosSize, options: [.storageModeShared])  // SIMD3<Float> per bone

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

    func updateBindDirections(_ directions: [SIMD3<Float>]) {
        guard directions.count == numBones else {
            vrmLogPhysics("⚠️ [SpringBoneBuffers] Bind direction count mismatch: expected \(numBones), got \(directions.count)")
            return
        }

        let ptr = bindDirections?.contents().bindMemory(to: SIMD3<Float>.self, capacity: numBones)
        for i in 0..<numBones {
            var dir = directions[i]
            // Validate: ensure no NaN and normalize if needed
            if dir.x.isNaN || dir.y.isNaN || dir.z.isNaN {
                dir = SIMD3<Float>(0, -1, 0) // Safe default
            }
            let len = simd_length(dir)
            if len < 0.001 {
                dir = SIMD3<Float>(0, -1, 0) // Safe default for zero-length
            } else if abs(len - 1.0) > 0.01 {
                dir = dir / len // Normalize
            }
            ptr?[i] = dir
        }
    }

    func updateSphereColliders(_ colliders: [SphereCollider]) {
        guard colliders.count == numSpheres else {
            vrmLogPhysics("⚠️ [SpringBoneBuffers] Sphere collider count mismatch: expected \(numSpheres), got \(colliders.count)")
            return
        }

        if let buffer = sphereColliders, numSpheres > 0 {
            buffer.contents().copyMemory(from: colliders, byteCount: MemoryLayout<SphereCollider>.stride * numSpheres)
        }
    }

    func updateCapsuleColliders(_ colliders: [CapsuleCollider]) {
        guard colliders.count == numCapsules else {
            vrmLogPhysics("⚠️ [SpringBoneBuffers] Capsule collider count mismatch: expected \(numCapsules), got \(colliders.count)")
            return
        }

        if let buffer = capsuleColliders, numCapsules > 0 {
            buffer.contents().copyMemory(from: colliders, byteCount: MemoryLayout<CapsuleCollider>.stride * numCapsules)
        }
    }

    func updatePlaneColliders(_ colliders: [PlaneCollider]) {
        guard colliders.count == numPlanes else {
            vrmLogPhysics("⚠️ [SpringBoneBuffers] Plane collider count mismatch: expected \(numPlanes), got \(colliders.count)")
            return
        }

        if let buffer = planeColliders, numPlanes > 0 {
            buffer.contents().copyMemory(from: colliders, byteCount: MemoryLayout<PlaneCollider>.stride * numPlanes)
        }
    }

    /// Set plane colliders with dynamic buffer allocation
    /// - Parameter colliders: Array of plane colliders (empty array to clear)
    public func setPlaneColliders(_ colliders: [PlaneCollider]) {
        let newCount = colliders.count

        // Reallocate buffer if count changed
        if newCount != numPlanes {
            numPlanes = newCount
            if newCount > 0 {
                let size = MemoryLayout<PlaneCollider>.stride * newCount
                planeColliders = device.makeBuffer(length: size, options: [.storageModeShared])
            } else {
                planeColliders = nil
            }
        }

        // Copy data to buffer
        guard newCount > 0, let buffer = planeColliders else { return }
        buffer.contents().copyMemory(from: colliders, byteCount: MemoryLayout<PlaneCollider>.stride * newCount)
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

/// Per-bone XPBD parameters uploaded to the SpringBone compute kernels.
///
/// Layout must match the `BoneParams` struct in the Metal shader source. One entry
/// per joint in the flattened bone array; see <doc:SpringBonePhysics> for the
/// pipeline that consumes these values.
public struct BoneParams {
    /// Spring stiffness (0…1). Higher values return the bone to its bind direction more strongly.
    public var stiffness: Float
    /// Damping coefficient (0…1) applied to per-substep velocity. Higher values settle faster.
    public var drag: Float
    /// Bone radius in metres used for collider response.
    public var radius: Float
    /// Index of this bone's parent in the flattened spring-bone array. Roots use `UInt32.max`.
    public var parentIndex: UInt32
    /// Multiplier for global gravity (0.0 = no gravity, 1.0 = full).
    public var gravityPower: Float
    /// Bitmask of collision groups this bone collides with (`0xFFFFFFFF` = all).
    public var colliderGroupMask: UInt32
    /// Per-bone gravity direction (normalized; typically `[0, -1, 0]`).
    public var gravityDir: SIMD3<Float>
    /// Maximum swing angle in radians from the bind direction (from
    /// `VRMC_springBone_extended_collider.angleLimit`). `0` = no limit.
    public var angleLimit: Float

    /// Creates per-bone XPBD parameters with optional gravity and collider-mask overrides.
    public init(stiffness: Float, drag: Float, radius: Float, parentIndex: UInt32,
                gravityPower: Float = 1.0, colliderGroupMask: UInt32 = 0xFFFFFFFF,
                gravityDir: SIMD3<Float> = SIMD3<Float>(0, -1, 0),
                angleLimit: Float = 0.0) {
        self.stiffness = stiffness
        self.drag = drag
        self.radius = radius
        self.parentIndex = parentIndex
        self.gravityPower = gravityPower
        self.colliderGroupMask = colliderGroupMask
        self.gravityDir = gravityDir
        self.angleLimit = angleLimit
    }
}

/// Sphere collider used by the SpringBone compute kernel.
///
/// Layout must match the `SphereCollider` struct in the Metal shader source.
public struct SphereCollider {
    /// Sphere centre in world space (metres).
    public var center: SIMD3<Float>
    /// Sphere radius in world space (metres).
    public var radius: Float
    /// Index of the collision group this collider belongs to.
    public var groupIndex: UInt32
    /// Collision mode. `0` = outside-collision (joints pushed out of the
    /// sphere — the default and base-spec behaviour). `1` = containment
    /// (joints pushed *inside* the sphere — from
    /// `VRMC_springBone_extended_collider.shape.sphere.inside = true`).
    public var inside: UInt32

    /// Creates an outside-collision sphere collider at the given centre and radius.
    public init(center: SIMD3<Float>, radius: Float, groupIndex: UInt32 = 0) {
        self.center = center
        self.radius = radius
        self.groupIndex = groupIndex
        self.inside = 0
    }

    /// Creates a sphere collider with an explicit collision mode (used by
    /// the `VRMC_springBone_extended_collider` parser to plumb through
    /// `inside = true` containment shapes).
    public init(center: SIMD3<Float>, radius: Float, groupIndex: UInt32, inside: Bool) {
        self.center = center
        self.radius = radius
        self.groupIndex = groupIndex
        self.inside = inside ? 1 : 0
    }
}

/// Capsule collider used by the SpringBone compute kernel.
///
/// A capsule is a swept sphere along the segment `p0`-`p1`. Layout must match
/// the `CapsuleCollider` struct in the Metal shader source.
public struct CapsuleCollider {
    /// First endpoint of the capsule's centre segment.
    public var p0: SIMD3<Float>
    /// Second endpoint of the capsule's centre segment.
    public var p1: SIMD3<Float>
    /// Sweep radius (metres).
    public var radius: Float
    /// Index of the collision group this collider belongs to.
    public var groupIndex: UInt32
    /// Collision mode. `0` = outside-collision (default). `1` = containment
    /// (joints pushed *inside* the capsule — from
    /// `VRMC_springBone_extended_collider.shape.capsule.inside = true`).
    public var inside: UInt32

    /// Creates an outside-collision capsule collider.
    public init(p0: SIMD3<Float>, p1: SIMD3<Float>, radius: Float, groupIndex: UInt32 = 0) {
        self.p0 = p0
        self.p1 = p1
        self.radius = radius
        self.groupIndex = groupIndex
        self.inside = 0
    }

    /// Creates a capsule collider with an explicit collision mode.
    public init(p0: SIMD3<Float>, p1: SIMD3<Float>, radius: Float, groupIndex: UInt32, inside: Bool) {
        self.p0 = p0
        self.p1 = p1
        self.radius = radius
        self.groupIndex = groupIndex
        self.inside = inside ? 1 : 0
    }
}

/// Infinite plane collider used by the SpringBone compute kernel.
///
/// Useful for floor planes detected by ARKit or a fixed ground constraint.
/// Layout must match the `PlaneCollider` struct in the Metal shader source.
public struct PlaneCollider {
    /// Point on the plane in world space.
    public var point: SIMD3<Float>
    /// Plane normal (normalized).
    public var normal: SIMD3<Float>
    /// Index of the collision group this collider belongs to.
    public var groupIndex: UInt32

    /// Creates a plane collider from a point on the plane and its normal.
    public init(point: SIMD3<Float>, normal: SIMD3<Float>, groupIndex: UInt32 = 0) {
        self.point = point
        self.normal = normal
        self.groupIndex = groupIndex
    }

    /// Create a floor plane collider from an ARKit plane anchor transform
    ///
    /// ARKit horizontal planes have their Y-axis pointing up (the plane normal).
    /// The transform's translation gives the plane's position in world space.
    ///
    /// - Parameters:
    ///   - transform: The ARPlaneAnchor's transform (simd_float4x4)
    ///   - groupIndex: Collision group for this plane (default 0)
    /// - Returns: A PlaneCollider configured for the detected floor
    ///
    /// ## Usage with ARKit
    /// ```swift
    /// func renderer(_ renderer: SCNSceneRenderer, didAdd node: SCNNode, for anchor: ARAnchor) {
    ///     guard let planeAnchor = anchor as? ARPlaneAnchor,
    ///           planeAnchor.alignment == .horizontal else { return }
    ///
    ///     let floorPlane = PlaneCollider(arkitTransform: planeAnchor.transform)
    ///     model.springBoneBuffers?.setPlaneColliders([floorPlane])
    /// }
    /// ```
    public init(arkitTransform transform: simd_float4x4, groupIndex: UInt32 = 0) {
        // Extract position from transform's translation column
        self.point = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)

        // For horizontal planes, the Y-axis (columns[1]) is the normal pointing up
        let rawNormal = SIMD3<Float>(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z)
        self.normal = simd_length(rawNormal) > 0.001 ? simd_normalize(rawNormal) : SIMD3<Float>(0, 1, 0)

        self.groupIndex = groupIndex
    }

    /// Create a simple floor plane at a specified Y height
    ///
    /// Convenience initializer for creating a horizontal floor plane.
    ///
    /// - Parameters:
    ///   - floorY: The Y coordinate of the floor in world space
    ///   - groupIndex: Collision group for this plane (default 0)
    ///
    /// ## Usage
    /// ```swift
    /// // Floor at Y = 0 (world origin)
    /// let floor = PlaneCollider(floorY: 0)
    ///
    /// // Floor at ARKit-detected height
    /// let floor = PlaneCollider(floorY: detectedFloorHeight)
    /// model.springBoneBuffers?.setPlaneColliders([floor])
    /// ```
    public init(floorY: Float, groupIndex: UInt32 = 0) {
        self.point = SIMD3<Float>(0, floorY, 0)
        self.normal = SIMD3<Float>(0, 1, 0)
        self.groupIndex = groupIndex
    }
}

/// Per-frame global parameters uploaded once per simulation step to the SpringBone kernel.
///
/// Field layout, alignment, and padding must match the `SpringBoneGlobalParams` struct in
/// the Metal shader source — comments record the byte offset of each field. See
/// <doc:SpringBonePhysics> for the simulation pipeline that consumes these values.
public struct SpringBoneGlobalParams {
    /// World-space gravity vector in m/s² (typically `[0, -9.8, 0]`). Byte offset 0.
    public var gravity: SIMD3<Float>
    /// Substep dt in seconds (typically `1.0 / (60 * substeps)`). Byte offset 16.
    public var dtSub: Float
    /// Wind amplitude in m/s. Byte offset 20.
    public var windAmplitude: Float
    /// Wind frequency in Hz. Byte offset 24.
    public var windFrequency: Float
    /// Wind phase in radians, advanced per frame on the CPU. Byte offset 28.
    public var windPhase: Float
    /// Wind direction (normalized). Byte offset 32.
    public var windDirection: SIMD3<Float>
    /// Number of XPBD substeps per simulation tick. Byte offset 48.
    public var substeps: UInt32
    /// Total flattened bone count. Byte offset 52.
    public var numBones: UInt32
    /// Sphere-collider count. Byte offset 56.
    public var numSpheres: UInt32
    /// Capsule-collider count. Byte offset 60.
    public var numCapsules: UInt32
    /// Plane-collider count. Byte offset 64.
    public var numPlanes: UInt32
    /// Frames remaining in the settling period; non-zero means the simulation is in startup damping. Byte offset 68.
    public var settlingFrames: UInt32
    /// Global drag multiplier (1.0 = normal, >1.0 = braking). Byte offset 72.
    public var dragMultiplier: Float
    private var _padding1: UInt32 = 0     // offset 76 - padding for float3 alignment
    /// Character root velocity in m/s, used to inject inertia into the simulation. Byte offset 80.
    public var externalVelocity: SIMD3<Float>

    /// Creates a global-params buffer payload for the SpringBone compute kernel.
    public init(gravity: SIMD3<Float>, dtSub: Float, windAmplitude: Float, windFrequency: Float,
         windPhase: Float, windDirection: SIMD3<Float>, substeps: UInt32,
         numBones: UInt32, numSpheres: UInt32, numCapsules: UInt32, numPlanes: UInt32 = 0,
         settlingFrames: UInt32 = 0, externalVelocity: SIMD3<Float> = .zero,
         dragMultiplier: Float = 1.0) {
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
        self.settlingFrames = settlingFrames
        self.dragMultiplier = dragMultiplier
        self.externalVelocity = externalVelocity
    }
}
