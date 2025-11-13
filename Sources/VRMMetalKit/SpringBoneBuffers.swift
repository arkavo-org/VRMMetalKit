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

public final class SpringBoneBuffers: @unchecked Sendable {
    let device: MTLDevice

    // SoA buffers for SpringBone data
    var bonePosPrev: MTLBuffer?
    var bonePosCurr: MTLBuffer?
    var boneParams: MTLBuffer?
    var restLengths: MTLBuffer?
    var sphereColliders: MTLBuffer?
    var capsuleColliders: MTLBuffer?

    var numBones: Int = 0
    var numSpheres: Int = 0
    var numCapsules: Int = 0

    init(device: MTLDevice) {
        self.device = device
    }

    func allocateBuffers(numBones: Int, numSpheres: Int, numCapsules: Int) {
        self.numBones = numBones
        self.numSpheres = numSpheres
        self.numCapsules = numCapsules

        // Allocate SoA buffers with proper alignment
        let bonePosSize = MemoryLayout<SIMD3<Float>>.stride * numBones
        let boneParamsSize = MemoryLayout<BoneParams>.stride * numBones
        let restLengthSize = MemoryLayout<Float>.stride * numBones
        let sphereColliderSize = MemoryLayout<SphereCollider>.stride * numSpheres
        let capsuleColliderSize = MemoryLayout<CapsuleCollider>.stride * numCapsules

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

    public init(stiffness: Float, drag: Float, radius: Float, parentIndex: UInt32) {
        self.stiffness = stiffness
        self.drag = drag
        self.radius = radius
        self.parentIndex = parentIndex
    }
}

public struct SphereCollider {
    public var center: SIMD3<Float>
    public var radius: Float

    public init(center: SIMD3<Float>, radius: Float) {
        self.center = center
        self.radius = radius
    }
}

public struct CapsuleCollider {
    public var p0: SIMD3<Float>
    public var p1: SIMD3<Float>
    public var radius: Float

    public init(p0: SIMD3<Float>, p1: SIMD3<Float>, radius: Float) {
        self.p0 = p0
        self.p1 = p1
        self.radius = radius
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

    public init(gravity: SIMD3<Float>, dtSub: Float, windAmplitude: Float, windFrequency: Float,
         windPhase: Float, windDirection: SIMD3<Float>, substeps: UInt32,
         numBones: UInt32, numSpheres: UInt32, numCapsules: UInt32) {
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
    }
}
