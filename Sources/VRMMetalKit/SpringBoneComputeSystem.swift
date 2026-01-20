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


import Foundation
import Metal
import QuartzCore  // For CACurrentMediaTime
import simd

/// GPU-accelerated SpringBone physics system using XPBD (Extended Position-Based Dynamics)
///
/// ## Thread Safety (@unchecked Sendable)
///
/// This class is marked `@unchecked Sendable` because:
/// 1. **Metal types are not Sendable**: `MTLDevice`, `MTLCommandQueue`, `MTLBuffer`, and `MTLComputePipelineState`
///    do not conform to `Sendable`, but Metal's thread-safety guarantees allow concurrent access:
///    - Command buffer creation is thread-safe (Metal docs)
///    - Pipeline states are immutable after creation
///    - Buffers are only mutated via GPU commands, not direct CPU writes after initialization
///
/// 2. **NSLock protection for readback**: All CPU-side mutable state related to async GPU readback
///    (`latestPositionsSnapshot`, `simulationFrameCounter`, `latestCompletedFrame`, `lastAppliedFrame`)
///    is protected by `snapshotLock`.
///
/// 3. **Async snapshot pattern (PR #38)**: GPU completion handlers use `[weak self, weak buffers]` capture
///    to safely access GPU results without blocking. The `captureCompletedPositions()` method copies GPU
///    data into `latestPositionsSnapshot` under lock, then `writeBonesToNodes()` consumes it when ready.
///
/// 4. **Immutable after init**: `device`, `commandQueue`, and pipeline states are immutable.
///    Per-model state (`globalParamsBuffer`, `rootBoneIndices`, etc.) is logically associated with
///    the `VRMModel` and not shared across threads.
///
/// 5. **Frame versioning**: `simulationFrameCounter` prevents stale readback data from being applied.
///    Only the latest completed frame is used.
///
/// **Safety contract**: `update()` and `writeBonesToNodes()` may be called from any thread (typically
/// the main/render thread). GPU work is asynchronous and completion handlers are serialized per command buffer.
final class SpringBoneComputeSystem: @unchecked Sendable {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue

    private var kinematicPipeline: MTLComputePipelineState?
    private var predictPipeline: MTLComputePipelineState?
    private var distancePipeline: MTLComputePipelineState?
    private var collideSpheresPipeline: MTLComputePipelineState?
    private var collideCapsulesPipeline: MTLComputePipelineState?
    private var collidePlanesPipeline: MTLComputePipelineState?

    private var globalParamsBuffer: MTLBuffer?
    private var animatedRootPositionsBuffer: MTLBuffer?
    private var rootBoneIndicesBuffer: MTLBuffer?
    private var numRootBonesBuffer: MTLBuffer?
    private var rootBoneIndices: [UInt32] = []
    private var timeAccumulator: TimeInterval = 0
    private var lastUpdateTime: TimeInterval = 0

    // Store bind-pose direction for each bone (in parent's local space)
    // Direction from current node to child node (current→child)
    // - Used for ROTATION calculation in Swift
    // - Used for GPU STIFFNESS via bindDirections[parentIndex] (see shader)
    private var boneBindDirections: [SIMD3<Float>] = []

    // Store rest lengths on CPU for physics reset (mirrors GPU buffer)
    private var cpuRestLengths: [Float] = []

    // Store parent indices for each bone (for kinematic position calculation)
    private var cpuParentIndices: [Int] = []

    // Teleportation detection
    private var lastRootPositions: [SIMD3<Float>] = []
    private let teleportationThreshold: Float = 1.0  // 1 meter threshold (base, scaled by model size)

    // Interpolation state for smooth substep updates (prevents temporal aliasing / "hair explosion")
    private var previousRootPositions: [SIMD3<Float>] = []
    private var targetRootPositions: [SIMD3<Float>] = []
    private var frameSubstepCount: Int = 0
    private var currentSubstepIndex: Int = 0

    // World bind direction interpolation (prevents rotational explosions during fast turns)
    private var previousWorldBindDirections: [SIMD3<Float>] = []
    private var targetWorldBindDirections: [SIMD3<Float>] = []

    // Collider transform interpolation (prevents collision snapping during fast rotations)
    private var previousSphereColliders: [SphereCollider] = []
    private var targetSphereColliders: [SphereCollider] = []
    private var previousCapsuleColliders: [CapsuleCollider] = []
    private var targetCapsuleColliders: [CapsuleCollider] = []
    private var previousPlaneColliders: [PlaneCollider] = []
    private var targetPlaneColliders: [PlaneCollider] = []

    // Cached model scale for scale-aware thresholds
    private var cachedModelScale: Float = 1.0

    /// Flag to request physics state reset on next update (e.g., when returning to idle)
    var requestPhysicsReset = false

    // Readback + synchronization (protected by snapshotLock)
    private let snapshotLock = NSLock()
    private var latestPositionsSnapshot: [SIMD3<Float>] = []
    private var simulationFrameCounter: UInt64 = 0
    private var latestCompletedFrame: UInt64 = 0
    private var lastAppliedFrame: UInt64 = 0
    private var skippedReadbacks: Int = 0

    init(device: MTLDevice) throws {
        self.device = device
        self.commandQueue = device.makeCommandQueue()!


        // Load compute shaders from pre-compiled .metallib
        var library: MTLLibrary?

        // Attempt 1: Load from default library (if shaders were pre-compiled into app)
        library = device.makeDefaultLibrary()
        if let lib = library {
            let hasKinematic = lib.makeFunction(name: "springBoneKinematic") != nil
            let hasPredict = lib.makeFunction(name: "springBonePredict") != nil
            let hasDistance = lib.makeFunction(name: "springBoneDistance") != nil
            let hasCollide = lib.makeFunction(name: "springBoneCollideSpheres") != nil

            if hasKinematic && hasPredict && hasDistance && hasCollide {
                vrmLog("[SpringBone] ✅ Loaded from default library")
            } else {
                library = nil  // Missing functions, try .metallib
            }
        }

        // Attempt 2: Load from VRMMetalKitShaders.metallib in package resources
        if library == nil {
            guard let url = Bundle.module.url(forResource: "VRMMetalKitShaders", withExtension: "metallib") else {
                vrmLog("[SpringBone] ❌ VRMMetalKitShaders.metallib not found in package resources")
                throw SpringBoneError.failedToLoadShaders
            }

            do {
                library = try device.makeLibrary(URL: url)
                vrmLog("[SpringBone] ✅ Loaded from VRMMetalKitShaders.metallib (Bundle.module)")
            } catch {
                vrmLog("[SpringBone] ❌ Failed to load metallib: \(error)")
                throw SpringBoneError.failedToLoadShaders
            }
        }

        guard let library = library else {
            vrmLog("[SpringBone] ❌ Failed to load Metal library")
            throw SpringBoneError.failedToLoadShaders
        }

        guard let kinematicFunction = library.makeFunction(name: "springBoneKinematic"),
              let predictFunction = library.makeFunction(name: "springBonePredict"),
              let distanceFunction = library.makeFunction(name: "springBoneDistance"),
              let collideSpheresFunction = library.makeFunction(name: "springBoneCollideSpheres"),
              let collideCapsulesFunction = library.makeFunction(name: "springBoneCollideCapsules"),
              let collidePlanesFunction = library.makeFunction(name: "springBoneCollidePlanes") else {
            vrmLog("[SpringBone] ❌ Failed to find shader functions in library")
            throw SpringBoneError.failedToLoadShaders
        }

        kinematicPipeline = try device.makeComputePipelineState(function: kinematicFunction)
        predictPipeline = try device.makeComputePipelineState(function: predictFunction)
        distancePipeline = try device.makeComputePipelineState(function: distanceFunction)
        collideSpheresPipeline = try device.makeComputePipelineState(function: collideSpheresFunction)
        collideCapsulesPipeline = try device.makeComputePipelineState(function: collideCapsulesFunction)
        collidePlanesPipeline = try device.makeComputePipelineState(function: collidePlanesFunction)

        // Create global params buffer
        globalParamsBuffer = device.makeBuffer(length: MemoryLayout<SpringBoneGlobalParams>.stride, options: [.storageModeShared])
    }

    private var updateCounter = 0

    func update(model: VRMModel, deltaTime: TimeInterval) {
        guard let buffers = model.springBoneBuffers,
              let globalParams = model.springBoneGlobalParams,
              buffers.numBones > 0 else {
            return
        }

        // Fixed timestep accumulation
        timeAccumulator += deltaTime
        let fixedDeltaTime = 1.0 / VRMConstants.Physics.substepRateHz // Fixed update at configured rate
        let maxSubsteps = VRMConstants.Physics.maxSubstepsPerFrame

        // Calculate total substeps this frame BEFORE the loop (for interpolation)
        frameSubstepCount = min(Int(timeAccumulator / fixedDeltaTime), maxSubsteps)
        currentSubstepIndex = 0

        // Capture all target transforms where animation wants to go this frame
        // This is called ONCE per frame, not per substep
        // Captures: root positions, world bind directions, collider transforms
        if VRMConstants.Physics.enableRootInterpolation && frameSubstepCount > 0 {
            captureTargetTransforms(model: model)

            // Check for teleportation BEFORE entering substep loop
            checkTeleportationAndReset(model: model, buffers: buffers)
        }

        var stepsThisFrame = 0

        // Process fixed steps (clamped to avoid spiral-of-death)
        while timeAccumulator >= fixedDeltaTime && stepsThisFrame < maxSubsteps {
            timeAccumulator -= fixedDeltaTime
            stepsThisFrame += 1

            // Update global params with current time
            var params = globalParams
            params.windPhase += Float(fixedDeltaTime)

            // Decrement settling frames counter (allows bones to settle with gravity before inertia compensation)
            if params.settlingFrames > 0 {
                params.settlingFrames -= 1
                // Persist back to model so it carries across frames
                model.springBoneGlobalParams?.settlingFrames = params.settlingFrames
            }

            // Copy updated params to GPU
            globalParamsBuffer?.contents().copyMemory(from: &params, byteCount: MemoryLayout<SpringBoneGlobalParams>.stride)

            // Interpolate ALL transforms for this substep (smooth motion instead of teleportation)
            // Includes: root positions, world bind directions, collider transforms
            if VRMConstants.Physics.enableRootInterpolation && frameSubstepCount > 0 {
                // t goes from 1/N to N/N across substeps (reaches 1.0 on last substep)
                let t = Float(currentSubstepIndex + 1) / Float(frameSubstepCount)
                interpolateAllTransforms(t: t, buffers: buffers)
                currentSubstepIndex += 1
            } else {
                // Fallback: original behavior - update all at once
                updateAnimatedPositions(model: model, buffers: buffers)
            }

            // Execute XPBD pipeline
            executeXPBDStep(buffers: buffers, globalParams: params)

            // Debug: Log bone positions occasionally
            updateCounter += 1

            // DIAGNOSTIC DEBUG: Check for explosion/growing issues
            if updateCounter <= 10 || updateCounter % 60 == 0,
               let bonePosCurr = buffers.bonePosCurr,
               let bonePosPrev = buffers.bonePosPrev,
               let restLengthsBuffer = buffers.restLengths,
               let boneParamsBuffer = buffers.boneParams {
                let currPtr = bonePosCurr.contents().bindMemory(to: SIMD3<Float>.self, capacity: buffers.numBones)
                let prevPtr = bonePosPrev.contents().bindMemory(to: SIMD3<Float>.self, capacity: buffers.numBones)
                let restPtr = restLengthsBuffer.contents().bindMemory(to: Float.self, capacity: buffers.numBones)
                let paramsPtr = boneParamsBuffer.contents().bindMemory(to: BoneParams.self, capacity: buffers.numBones)

                // Check a non-root bone (index 1)
                let boneIndex = 1
                if boneIndex < buffers.numBones {
                    let curr = currPtr[boneIndex]
                    let prev = prevPtr[boneIndex]
                    let restLen = restPtr[boneIndex]
                    let boneParams = paramsPtr[boneIndex]
                    let parentIdx = Int(boneParams.parentIndex)

                    let velocity = curr - prev
                    var actualDist: Float = 0
                    if parentIdx < buffers.numBones && parentIdx != 0xFFFFFFFF {
                        let parentPos = currPtr[parentIdx]
                        actualDist = simd_length(curr - parentPos)
                    }

                    print("[PHYSICS \(updateCounter)] bone=\(boneIndex) parent=\(parentIdx)")
                    print("  pos=(\(String(format: "%.3f", curr.x)), \(String(format: "%.3f", curr.y)), \(String(format: "%.3f", curr.z)))")
                    print("  velocity=\(String(format: "%.4f", simd_length(velocity))) restLen=\(String(format: "%.4f", restLen)) actualDist=\(String(format: "%.4f", actualDist))")
                    print("  stiffness=\(String(format: "%.2f", boneParams.stiffness)) drag=\(String(format: "%.2f", boneParams.drag))")
                    print("  dtSub=\(String(format: "%.6f", params.dtSub)) settling=\(params.settlingFrames)")

                    // ALERT if exploding
                    if simd_length(velocity) > 0.5 || actualDist > restLen * 2 || curr.y.isNaN {
                        print("  ⚠️ EXPLOSION DETECTED! velocity=\(simd_length(velocity)) stretch=\(actualDist/restLen)")
                    }
                }
            }

            if updateCounter % VRMConstants.Performance.statusLogInterval == 0, let bonePosCurr = buffers.bonePosCurr {
                let ptr = bonePosCurr.contents().bindMemory(to: SIMD3<Float>.self, capacity: 3)
                let pos = Array(UnsafeBufferPointer(start: ptr, count: min(3, buffers.numBones)))
                vrmLog("[SpringBone] GPU update \(updateCounter): First 3 positions: \(pos)")
            }
        }

        if timeAccumulator >= fixedDeltaTime {
            // We've reached the per-frame cap; carry a single substep forward to avoid runaway accumulation
            let droppedSteps = Int(timeAccumulator / fixedDeltaTime)
            timeAccumulator = min(timeAccumulator, fixedDeltaTime)
            vrmLogPhysics("⚠️ [SpringBone] Hit max substeps (\(maxSubsteps)) this frame. Dropping \(droppedSteps) pending step(s) to stay real-time.")
        }

        // Commit all target transforms as previous for next frame's interpolation
        if VRMConstants.Physics.enableRootInterpolation && stepsThisFrame > 0 {
            commitAllTransforms()
        }

        lastUpdateTime = CACurrentMediaTime()
    }

    private func executeXPBDStep(buffers: SpringBoneBuffers, globalParams: SpringBoneGlobalParams) {
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let kinematicPipeline = kinematicPipeline,
              let predictPipeline = predictPipeline,
              let distancePipeline = distancePipeline,
              let collideSpheresPipeline = collideSpheresPipeline,
              let collideCapsulesPipeline = collideCapsulesPipeline,
              let collidePlanesPipeline = collidePlanesPipeline else {
            return
        }

        let numBones = buffers.numBones
        let threadgroupSize = MTLSize(width: 256, height: 1, depth: 1)
        let gridSize = MTLSize(width: numBones, height: 1, depth: 1) // Exact thread count for Metal

        // Create compute encoder
        guard let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
            return
        }

        // Set buffers
        computeEncoder.setBuffer(buffers.bonePosPrev, offset: 0, index: 0)
        computeEncoder.setBuffer(buffers.bonePosCurr, offset: 0, index: 1)
        computeEncoder.setBuffer(buffers.boneParams, offset: 0, index: 2)
        computeEncoder.setBuffer(globalParamsBuffer, offset: 0, index: 3)
        computeEncoder.setBuffer(buffers.restLengths, offset: 0, index: 4)

        if let sphereColliders = buffers.sphereColliders, globalParams.numSpheres > 0 {
            computeEncoder.setBuffer(sphereColliders, offset: 0, index: 5)
        }

        if let capsuleColliders = buffers.capsuleColliders, globalParams.numCapsules > 0 {
            computeEncoder.setBuffer(capsuleColliders, offset: 0, index: 6)
        }

        if let planeColliders = buffers.planeColliders, globalParams.numPlanes > 0 {
            computeEncoder.setBuffer(planeColliders, offset: 0, index: 7)
        }

        // Bind directions for stiffness spring force (return-to-bind-pose)
        // Note: When interpolation is enabled, these are DYNAMICALLY updated each substep
        // with world-space bind directions interpolated from parent bone rotations.
        // This prevents rotational snapping during fast character turns.
        if let bindDirections = buffers.bindDirections {
            computeEncoder.setBuffer(bindDirections, offset: 0, index: 11)
        }

        // First update kinematic root bones with animated positions
        // Note: Kinematic kernel uses buffer indices 8-10 to avoid conflicts with colliders (5-7)
        if !rootBoneIndices.isEmpty,
           let animatedRootPositionsBuffer = animatedRootPositionsBuffer,
           let rootBoneIndicesBuffer = rootBoneIndicesBuffer,
           let numRootBonesBuffer = numRootBonesBuffer {
            computeEncoder.setComputePipelineState(kinematicPipeline)
            computeEncoder.setBuffer(animatedRootPositionsBuffer, offset: 0, index: 8)
            computeEncoder.setBuffer(rootBoneIndicesBuffer, offset: 0, index: 9)
            computeEncoder.setBuffer(numRootBonesBuffer, offset: 0, index: 10)
            let rootGridSize = MTLSize(width: rootBoneIndices.count, height: 1, depth: 1)
            computeEncoder.dispatchThreads(rootGridSize, threadsPerThreadgroup: threadgroupSize)
        }

        // Execute predict kernel (step 1: predict new tip position)
        computeEncoder.setComputePipelineState(predictPipeline)
        computeEncoder.dispatchThreads(gridSize, threadsPerThreadgroup: threadgroupSize)

        // Distance constraint iterations (step 2: enforce bone length)
        // VRM spec: run distance constraint BEFORE collision, do not run it after
        let iterations = VRMConstants.Physics.constraintIterations
        for _ in 0..<iterations {
            computeEncoder.setComputePipelineState(distancePipeline)
            computeEncoder.dispatchThreads(gridSize, threadsPerThreadgroup: threadgroupSize)
        }

        // Collision resolution (step 3: push tips out of colliders)
        // VRM spec: collision runs AFTER distance constraint and is the FINAL step
        // This prevents distance constraint from pulling hair back into colliders
        if globalParams.numSpheres > 0 {
            computeEncoder.setComputePipelineState(collideSpheresPipeline)
            computeEncoder.dispatchThreads(gridSize, threadsPerThreadgroup: threadgroupSize)
        }

        if globalParams.numCapsules > 0 {
            computeEncoder.setComputePipelineState(collideCapsulesPipeline)
            computeEncoder.dispatchThreads(gridSize, threadsPerThreadgroup: threadgroupSize)
        }

        if globalParams.numPlanes > 0 {
            computeEncoder.setComputePipelineState(collidePlanesPipeline)
            computeEncoder.dispatchThreads(gridSize, threadsPerThreadgroup: threadgroupSize)
        }

        computeEncoder.endEncoding()

        simulationFrameCounter &+= 1
        let frameID = simulationFrameCounter

        commandBuffer.addCompletedHandler { [weak self, weak buffers = buffers] buffer in
            guard let self = self, let buffers = buffers else { return }

            // Check for GPU errors before reading back data
            if buffer.status == .error {
                if let error = buffer.error {
                    vrmLogPhysics("[SpringBone] GPU command buffer failed: \(error.localizedDescription)")
                }
                return
            }

            self.captureCompletedPositions(from: buffers, frameID: frameID)
        }

        commandBuffer.commit()
    }

    func populateSpringBoneData(model: VRMModel) throws {
        guard let springBone = model.springBone,
              let buffers = model.springBoneBuffers,
              let _ = model.device else {
            return
        }

        var boneParams: [BoneParams] = []
        var restLengths: [Float] = []
        var parentIndices: [Int] = []  // CPU-side parent indices for physics reset
        var sphereColliders: [SphereCollider] = []
        var capsuleColliders: [CapsuleCollider] = []
        var planeColliders: [PlaneCollider] = []
        boneBindDirections = [] // Reset bind directions (current→child)

        // Build collider-to-group index mapping
        // Each collider can belong to multiple groups, but we assign the first group index for GPU filtering
        var colliderToGroupIndex: [Int: UInt32] = [:]
        for (groupIndex, group) in springBone.colliderGroups.enumerated() {
            for colliderIndex in group.colliders {
                // Use first group if collider belongs to multiple groups
                if colliderToGroupIndex[colliderIndex] == nil {
                    colliderToGroupIndex[colliderIndex] = UInt32(groupIndex)
                }
            }
        }

        // Process spring chains to extract bone parameters
        var boneIndex = 0
        rootBoneIndices = []

        // Track chains with all-zero gravityPower for auto-fix
        var chainGravityPowers: [[Float]] = []

        for spring in springBone.springs {
            var jointIndexInChain = 0
            var chainGravityPower: [Float] = []

            // Build collision group mask for this spring chain
            // Each bit represents a collision group that this spring interacts with
            var colliderGroupMask: UInt32 = 0
            if spring.colliderGroups.isEmpty {
                // No groups specified - collide with all groups (backward compatible default)
                colliderGroupMask = 0xFFFFFFFF
            } else {
                for groupIndex in spring.colliderGroups {
                    if groupIndex < 32 {
                        colliderGroupMask |= (1 << groupIndex)
                    }
                }
            }

            for joint in spring.joints {
                chainGravityPower.append(joint.gravityPower)

                // First joint in each spring chain is a root
                let isRootBone = (jointIndexInChain == 0)

                if isRootBone {
                    rootBoneIndices.append(UInt32(boneIndex))
                }

                // Normalize gravity direction to ensure unit vector for GPU
                let normalizedGravityDir = simd_length(joint.gravityDir) > 0.001
                    ? simd_normalize(joint.gravityDir)
                    : SIMD3<Float>(0, -1, 0) // Default downward if zero vector

                // Calculate parent index (-1 for root bones)
                let parentIdx = (isRootBone || jointIndexInChain == 0) ? -1 : (boneIndex - 1)
                parentIndices.append(parentIdx)

                let params = BoneParams(
                    stiffness: joint.stiffness,
                    drag: joint.dragForce,
                    radius: joint.hitRadius,
                    // Only set parent for non-root bones within the same chain
                    parentIndex: parentIdx < 0 ? 0xFFFFFFFF : UInt32(parentIdx),
                    gravityPower: joint.gravityPower,
                    colliderGroupMask: colliderGroupMask,
                    gravityDir: normalizedGravityDir
                )
                boneParams.append(params)

                // Calculate rest length (distance to parent in bind pose)
                if jointIndexInChain > 0, let node = model.nodes[safe: joint.node],
                   let parentJoint = spring.joints[safe: jointIndexInChain - 1],
                   let parentNode = model.nodes[safe: parentJoint.node] {
                    let restLength = simd_distance(node.worldPosition, parentNode.worldPosition)
                    restLengths.append(restLength)
                } else {
                    restLengths.append(0.0) // Root bone has no rest length
                }

                // Store bind-pose direction for THIS bone (looking ahead to NEXT bone)
                // CRITICAL: Store in PARENT's local space, not current bone's local space
                guard let currentNode = model.nodes[safe: joint.node] else {
                    // Fallback for invalid node - try to get real direction from next joint if possible
                    if let nextJoint = spring.joints[safe: jointIndexInChain + 1],
                       let nextNode = model.nodes[safe: nextJoint.node],
                       jointIndexInChain > 0,
                       let prevJoint = spring.joints[safe: jointIndexInChain - 1],
                       let prevNode = model.nodes[safe: prevJoint.node] {
                        let bindDirWorld = simd_normalize(nextNode.worldPosition - prevNode.worldPosition)
                        boneBindDirections.append(bindDirWorld)
                    } else {
                        boneBindDirections.append(SIMD3<Float>(0, 1, 0)) // Ultimate fallback
                    }
                    boneIndex += 1
                    jointIndexInChain += 1
                    continue
                }

                // BIND DIRECTION: current → child
                // - Used for ROTATION calculation in Swift
                // - Used for GPU STIFFNESS via bindDirections[parentIndex] in shader
                if let nextJoint = spring.joints[safe: jointIndexInChain + 1],
                   let nextNode = model.nodes[safe: nextJoint.node] {
                    let bindDirWorld = simd_normalize(nextNode.worldPosition - currentNode.worldPosition)
                    if let parentNode = currentNode.parent {
                        let parentRot = extractRotation(from: parentNode.worldMatrix)
                        let parentRotInv = simd_conjugate(parentRot)
                        boneBindDirections.append(simd_act(parentRotInv, bindDirWorld))
                    } else {
                        boneBindDirections.append(bindDirWorld)
                    }
                } else {
                    // Last bone - no child, use downward
                    boneBindDirections.append(SIMD3<Float>(0, -1, 0))
                }

                boneIndex += 1
                jointIndexInChain += 1
            }

            chainGravityPowers.append(chainGravityPower)
        }

        // NOTE: Auto-fix for zero gravityPower removed - it was overriding intentional zero gravity
        // Real VRM files with broken physics should be fixed at the source or use a dedicated flag
        // to enable auto-fixing behavior rather than applying it unconditionally.

        // Process colliders with group index assignment
        for (colliderIndex, collider) in springBone.colliders.enumerated() {
            guard let colliderNode = model.nodes[safe: collider.node] else { continue }
            let groupIndex = colliderToGroupIndex[colliderIndex] ?? 0

            // Extract rotation from world matrix (upper 3x3) to transform local offsets
            let wm = colliderNode.worldMatrix
            let worldRotation = simd_float3x3(
                SIMD3<Float>(wm[0][0], wm[0][1], wm[0][2]),
                SIMD3<Float>(wm[1][0], wm[1][1], wm[1][2]),
                SIMD3<Float>(wm[2][0], wm[2][1], wm[2][2])
            )

            switch collider.shape {
            case .sphere(let offset, let radius):
                let worldOffset = worldRotation * offset
                let worldCenter = colliderNode.worldPosition + worldOffset
                sphereColliders.append(SphereCollider(center: worldCenter, radius: radius, groupIndex: groupIndex))

            case .capsule(let offset, let radius, let tail):
                let worldOffset = worldRotation * offset
                let worldTail = worldRotation * tail
                let worldP0 = colliderNode.worldPosition + worldOffset
                let worldP1 = worldP0 + worldTail
                capsuleColliders.append(CapsuleCollider(p0: worldP0, p1: worldP1, radius: radius, groupIndex: groupIndex))

            case .plane(let offset, let normal):
                let worldOffset = worldRotation * offset
                let worldNormal = worldRotation * normal
                let worldPoint = colliderNode.worldPosition + worldOffset
                let normalizedNormal = simd_length(worldNormal) > 0.001 ? simd_normalize(worldNormal) : SIMD3<Float>(0, 1, 0)
                planeColliders.append(PlaneCollider(point: worldPoint, normal: normalizedNormal, groupIndex: groupIndex))
            }
        }

        // Update buffers
        buffers.updateBoneParameters(boneParams)
        buffers.updateRestLengths(restLengths)

        // GPU needs WORLD directions for stiffness calculation
        // boneBindDirections stores current→child in parent's LOCAL space
        // Transform to world by applying the node's ACTUAL parent's rotation (not prev joint)
        var initialWorldBindDirections: [SIMD3<Float>] = []
        var boneIdx = 0
        for spring in springBone.springs {
            for joint in spring.joints {
                guard boneIdx < boneBindDirections.count,
                      let jointNode = model.nodes[safe: joint.node] else {
                    boneIdx += 1
                    continue
                }
                let localDir = boneBindDirections[boneIdx]
                // Transform by the node's actual parent (matches how we stored it)
                if let nodeParent = jointNode.parent {
                    let parentRot = extractRotation(from: nodeParent.worldMatrix)
                    let worldDir = simd_act(parentRot, localDir)
                    initialWorldBindDirections.append(simd_normalize(worldDir))
                } else {
                    // Root bone - local is world
                    initialWorldBindDirections.append(localDir)
                }
                boneIdx += 1
            }
        }
        buffers.updateBindDirections(initialWorldBindDirections)

        // Also initialize the interpolation targets with the same world directions
        targetWorldBindDirections = initialWorldBindDirections
        previousWorldBindDirections = initialWorldBindDirections

        // Store CPU-side copies for physics reset
        cpuRestLengths = restLengths
        cpuParentIndices = parentIndices

        if !sphereColliders.isEmpty {
            buffers.updateSphereColliders(sphereColliders)
        }

        if !capsuleColliders.isEmpty {
            buffers.updateCapsuleColliders(capsuleColliders)
        }

        if !planeColliders.isEmpty {
            buffers.updatePlaneColliders(planeColliders)
        }

        // Initialize bone positions from bind pose (node world positions)
        // Physics will naturally settle bones to their hanging position during settling period
        var initialPositions: [SIMD3<Float>] = []
        boneIndex = 0
        for spring in springBone.springs {
            for joint in spring.joints {
                if let node = model.nodes[safe: joint.node] {
                    initialPositions.append(node.worldPosition)
                } else {
                    initialPositions.append(.zero)
                }
                boneIndex += 1
            }
        }

        // Copy initial positions to both prev and curr buffers
        if let bonePosPrev = buffers.bonePosPrev,
           let bonePosCurr = buffers.bonePosCurr,
           !initialPositions.isEmpty {
            let prevPtr = bonePosPrev.contents().bindMemory(to: SIMD3<Float>.self, capacity: initialPositions.count)
            let currPtr = bonePosCurr.contents().bindMemory(to: SIMD3<Float>.self, capacity: initialPositions.count)
            for i in 0..<initialPositions.count {
                prevPtr[i] = initialPositions[i]
                currPtr[i] = initialPositions[i]
            }
        }

        // DEBUG: Log spring bone setup details
        print("[SpringBone DEBUG] === Spring Bone Setup ===")
        var debugBoneIndex = 0
        for (springIndex, spring) in springBone.springs.enumerated() {
            let springName = spring.name ?? ""
            // Recalculate mask for debug output
            var debugMask: UInt32 = 0
            if spring.colliderGroups.isEmpty {
                debugMask = 0xFFFFFFFF
            } else {
                for groupIdx in spring.colliderGroups {
                    if groupIdx < 32 { debugMask |= (1 << groupIdx) }
                }
            }
            print("[SpringBone DEBUG] Chain \(springIndex): '\(springName)' joints=\(spring.joints.count) colliderGroups=\(spring.colliderGroups) mask=0x\(String(debugMask, radix: 16))")

            for (jointIdx, joint) in spring.joints.enumerated() {
                let pos = initialPositions[safe: debugBoneIndex] ?? .zero
                let restLen = restLengths[safe: debugBoneIndex] ?? 0
                let params = boneParams[safe: debugBoneIndex]
                let parentIdx = parentIndices[safe: debugBoneIndex] ?? -1

                if jointIdx < 3 || spring.joints.count <= 5 {
                    let gravDir = params?.gravityDir ?? .zero
                    let bindDir = boneBindDirections[safe: debugBoneIndex] ?? .zero
                    print("  Joint \(jointIdx): node=\(joint.node) pos=(\(String(format: "%.3f", pos.x)), \(String(format: "%.3f", pos.y)), \(String(format: "%.3f", pos.z))) restLen=\(String(format: "%.4f", restLen)) parent=\(parentIdx) gravPow=\(params?.gravityPower ?? 0) gravDir=(\(String(format: "%.2f", gravDir.x)), \(String(format: "%.2f", gravDir.y)), \(String(format: "%.2f", gravDir.z))) bindDir=(\(String(format: "%.2f", bindDir.x)), \(String(format: "%.2f", bindDir.y)), \(String(format: "%.2f", bindDir.z))) stiff=\(params?.stiffness ?? 0)")
                }
                debugBoneIndex += 1
            }
        }
        print("[SpringBone DEBUG] Total bones: \(initialPositions.count), settling frames: \(model.springBoneGlobalParams?.settlingFrames ?? 0)")

        // DEBUG: Log collider setup
        print("[SpringBone DEBUG] === Colliders ===")
        print("[SpringBone DEBUG] Spheres: \(sphereColliders.count)")
        for (i, sphere) in sphereColliders.enumerated() {
            print("  Sphere \(i): center=(\(String(format: "%.3f", sphere.center.x)), \(String(format: "%.3f", sphere.center.y)), \(String(format: "%.3f", sphere.center.z))) radius=\(String(format: "%.3f", sphere.radius)) group=\(sphere.groupIndex)")
        }
        print("[SpringBone DEBUG] Capsules: \(capsuleColliders.count)")
        for (i, capsule) in capsuleColliders.enumerated() {
            print("  Capsule \(i): p0=(\(String(format: "%.3f", capsule.p0.x)), \(String(format: "%.3f", capsule.p0.y)), \(String(format: "%.3f", capsule.p0.z))) p1=(\(String(format: "%.3f", capsule.p1.x)), \(String(format: "%.3f", capsule.p1.y)), \(String(format: "%.3f", capsule.p1.z))) radius=\(String(format: "%.3f", capsule.radius)) group=\(capsule.groupIndex)")
        }
        print("[SpringBone DEBUG] Planes: \(planeColliders.count)")

        // Initialize buffers for root bone kinematic updates
        let numRootBones = rootBoneIndices.count
        if numRootBones > 0 {
            animatedRootPositionsBuffer = device.makeBuffer(length: MemoryLayout<SIMD3<Float>>.stride * numRootBones,
                                                           options: [.storageModeShared])
            rootBoneIndicesBuffer = device.makeBuffer(bytes: rootBoneIndices,
                                                     length: MemoryLayout<UInt32>.stride * numRootBones,
                                                     options: [.storageModeShared])
            var numRootBonesUInt = UInt32(numRootBones)
            numRootBonesBuffer = device.makeBuffer(bytes: &numRootBonesUInt,
                                                  length: MemoryLayout<UInt32>.stride,
                                                  options: [.storageModeShared])
        }

        snapshotLock.lock()
        latestPositionsSnapshot.removeAll(keepingCapacity: true)
        latestCompletedFrame = 0
        lastAppliedFrame = 0
        snapshotLock.unlock()
    }

    private func updateAnimatedPositions(model: VRMModel, buffers: SpringBoneBuffers) {
        guard let springBone = model.springBone,
              !rootBoneIndices.isEmpty,
              let animatedRootPositionsBuffer = animatedRootPositionsBuffer else {
            return
        }

        var animatedPositions: [SIMD3<Float>] = []
        var rootIndex = 0

        // Update root bone positions from animated transforms
        for spring in springBone.springs {
            if let firstJoint = spring.joints.first,
               let node = model.nodes[safe: firstJoint.node] {
                animatedPositions.append(node.worldPosition)
                rootIndex += 1
            }
        }

        // Teleportation detection: check if any root bone moved more than threshold
        let shouldResetPhysics = detectTeleportation(currentPositions: animatedPositions, buffers: buffers)
        if shouldResetPhysics {
            resetPhysicsState(model: model, buffers: buffers, animatedPositions: animatedPositions)
            vrmLog("⚠️ [SpringBone] Teleportation detected - physics state reset")
        }

        // Manual physics reset request (e.g., when returning to idle)
        if requestPhysicsReset {
            resetPhysicsState(model: model, buffers: buffers, animatedPositions: animatedPositions)
            requestPhysicsReset = false
        }

        // Update last root positions for next frame's teleportation check
        lastRootPositions = animatedPositions

        // Copy to GPU buffer
        if animatedPositions.count > 0 {
            animatedRootPositionsBuffer.contents().copyMemory(
                from: animatedPositions,
                byteCount: MemoryLayout<SIMD3<Float>>.stride * animatedPositions.count
            )
        }

        // Build collider-to-group index mapping for animated updates
        var colliderToGroupIndex: [Int: UInt32] = [:]
        for (groupIndex, group) in springBone.colliderGroups.enumerated() {
            for colliderIndex in group.colliders {
                if colliderToGroupIndex[colliderIndex] == nil {
                    colliderToGroupIndex[colliderIndex] = UInt32(groupIndex)
                }
            }
        }

        // Update collider positions (they can move with animation)
        var sphereColliders: [SphereCollider] = []
        var capsuleColliders: [CapsuleCollider] = []
        var planeColliders: [PlaneCollider] = []

        for (colliderIndex, collider) in springBone.colliders.enumerated() {
            guard let colliderNode = model.nodes[safe: collider.node] else { continue }
            let groupIndex = colliderToGroupIndex[colliderIndex] ?? 0

            // Extract rotation from world matrix (upper 3x3) to transform local offsets
            let wm = colliderNode.worldMatrix
            let worldRotation = simd_float3x3(
                SIMD3<Float>(wm[0][0], wm[0][1], wm[0][2]),
                SIMD3<Float>(wm[1][0], wm[1][1], wm[1][2]),
                SIMD3<Float>(wm[2][0], wm[2][1], wm[2][2])
            )

            // Debug: Log transformation details for first few frames
            if updateCounter < 5 {
                print("[Collider \(colliderIndex)] node=\(collider.node) '\(colliderNode.name ?? "")' nodePos=(\(String(format: "%.3f", colliderNode.worldPosition.x)), \(String(format: "%.3f", colliderNode.worldPosition.y)), \(String(format: "%.3f", colliderNode.worldPosition.z)))")
            }

            switch collider.shape {
            case .sphere(let offset, let radius):
                let worldOffset = worldRotation * offset
                let worldCenter = colliderNode.worldPosition + worldOffset
                if updateCounter < 5 {
                    print("  localOffset=(\(String(format: "%.3f", offset.x)), \(String(format: "%.3f", offset.y)), \(String(format: "%.3f", offset.z))) -> worldOffset=(\(String(format: "%.3f", worldOffset.x)), \(String(format: "%.3f", worldOffset.y)), \(String(format: "%.3f", worldOffset.z))) -> center=(\(String(format: "%.3f", worldCenter.x)), \(String(format: "%.3f", worldCenter.y)), \(String(format: "%.3f", worldCenter.z)))")
                }
                sphereColliders.append(SphereCollider(center: worldCenter, radius: radius, groupIndex: groupIndex))

            case .capsule(let offset, let radius, let tail):
                let worldOffset = worldRotation * offset
                let worldTail = worldRotation * tail
                let worldP0 = colliderNode.worldPosition + worldOffset
                let worldP1 = worldP0 + worldTail
                capsuleColliders.append(CapsuleCollider(p0: worldP0, p1: worldP1, radius: radius, groupIndex: groupIndex))

            case .plane(let offset, let normal):
                let worldOffset = worldRotation * offset
                let worldNormal = worldRotation * normal
                let worldPoint = colliderNode.worldPosition + worldOffset
                let normalizedNormal = simd_length(worldNormal) > 0.001 ? simd_normalize(worldNormal) : SIMD3<Float>(0, 1, 0)
                planeColliders.append(PlaneCollider(point: worldPoint, normal: normalizedNormal, groupIndex: groupIndex))
            }
        }

        // Debug: Log animated collider positions occasionally
        if updateCounter % 600 == 1 && !sphereColliders.isEmpty {
            print("[SpringBone DEBUG] === Animated Collider Positions (frame \(updateCounter)) ===")
            for (i, sphere) in sphereColliders.enumerated() {
                print("  Sphere \(i): center=(\(String(format: "%.3f", sphere.center.x)), \(String(format: "%.3f", sphere.center.y)), \(String(format: "%.3f", sphere.center.z))) group=\(sphere.groupIndex)")
            }
        }

        // Update collider buffers with animated positions
        if !sphereColliders.isEmpty {
            buffers.updateSphereColliders(sphereColliders)
        }

        if !capsuleColliders.isEmpty {
            buffers.updateCapsuleColliders(capsuleColliders)
        }

        if !planeColliders.isEmpty {
            buffers.updatePlaneColliders(planeColliders)
        }
    }

    /// Checks for teleportation and resets physics state if needed
    /// Called once per frame before entering substep loop
    private func checkTeleportationAndReset(model: VRMModel, buffers: SpringBoneBuffers) {
        // Check for teleportation using target positions
        let shouldResetPhysics = detectTeleportation(currentPositions: targetRootPositions, buffers: buffers)
        if shouldResetPhysics {
            resetPhysicsState(model: model, buffers: buffers, animatedPositions: targetRootPositions)
            // Also reset all interpolation state to prevent lerping from old positions
            resetInterpolationState()
            vrmLog("⚠️ [SpringBone] Teleportation detected - physics state reset")
        }

        // Manual physics reset request
        if requestPhysicsReset {
            resetPhysicsState(model: model, buffers: buffers, animatedPositions: targetRootPositions)
            resetInterpolationState()
            requestPhysicsReset = false
        }

        // Update last root positions for next frame's teleportation check
        lastRootPositions = targetRootPositions
    }

    /// Resets all interpolation state to current target (prevents lerping from stale data after teleport)
    private func resetInterpolationState() {
        previousRootPositions = targetRootPositions
        previousWorldBindDirections = targetWorldBindDirections
        previousSphereColliders = targetSphereColliders
        previousCapsuleColliders = targetCapsuleColliders
        previousPlaneColliders = targetPlaneColliders
    }

    private func captureCompletedPositions(from buffers: SpringBoneBuffers, frameID: UInt64) {
        guard let bonePosCurr = buffers.bonePosCurr,
              buffers.numBones > 0 else {
            return
        }

        let sourcePointer = bonePosCurr.contents().bindMemory(to: SIMD3<Float>.self, capacity: buffers.numBones)

        snapshotLock.lock()
        if latestPositionsSnapshot.count != buffers.numBones {
            latestPositionsSnapshot = Array(repeating: SIMD3<Float>(repeating: 0), count: buffers.numBones)
        }

        latestPositionsSnapshot.withUnsafeMutableBufferPointer { destination in
            guard let dst = destination.baseAddress else { return }
            dst.update(from: sourcePointer, count: buffers.numBones)
        }

        // NaN safety: filter out corrupted positions and replace with safe fallback
        // This prevents NaN from propagating to writeBonesToNodes
        var nanCount = 0
        for i in 0..<buffers.numBones {
            let pos = latestPositionsSnapshot[i]
            if pos.x.isNaN || pos.y.isNaN || pos.z.isNaN ||
               pos.x.isInfinite || pos.y.isInfinite || pos.z.isInfinite {
                // Replace with zero - writeBonesToNodes will skip this bone
                latestPositionsSnapshot[i] = SIMD3<Float>(repeating: Float.nan)
                nanCount += 1
            }
        }
        if nanCount > 0 {
            vrmLogPhysics("[SpringBone] ⚠️ Frame \(frameID): \(nanCount) bones had NaN/Inf positions")
        }

        latestCompletedFrame = frameID
        snapshotLock.unlock()
    }

    /// Read back GPU-computed bone positions and update VRMNode transforms
    func writeBonesToNodes(model: VRMModel) {
        guard let springBone = model.springBone,
              let buffers = model.springBoneBuffers else {
            vrmLog("[SpringBone] writeBonesToNodes: Missing required data")
            return
        }

        snapshotLock.lock()
        let readyFrame = latestCompletedFrame
        let positions = latestPositionsSnapshot
        let canApply = readyFrame > lastAppliedFrame && positions.count >= buffers.numBones && !positions.isEmpty
        if canApply {
            lastAppliedFrame = readyFrame
        }
        snapshotLock.unlock()

        guard canApply else {
            skippedReadbacks += 1
            if skippedReadbacks % VRMConstants.Performance.statusLogInterval == 0 {
                vrmLogPhysics("[SpringBone] ⚠️ Skipping readback (ready=\(readyFrame), applied=\(lastAppliedFrame))")
            }
            return
        }
        skippedReadbacks = 0

        // Check if positions have extreme values
        let maxMagnitude = positions.prefix(buffers.numBones).map { simd_length($0) }.max() ?? 0
        vrmLog("[SpringBone] Read \(positions.count) positions. Max magnitude: \(maxMagnitude)")

        // Map bone index to spring/joint for node updates
        var globalBoneIndex = 0
        for spring in springBone.springs {
            guard globalBoneIndex < positions.count else { break }

            // Build array of (node, position, globalIndex) tuples for this chain
            var nodePositions: [(VRMNode, SIMD3<Float>, Int)] = []
            for joint in spring.joints {
                guard let node = model.nodes[safe: joint.node],
                      globalBoneIndex < positions.count else { continue }

                nodePositions.append((node, positions[globalBoneIndex], globalBoneIndex))
                globalBoneIndex += 1
            }

            // Update node transforms based on GPU-computed positions
            if nodePositions.count >= 2 {
                updateNodeTransformsForChain(nodePositions: nodePositions)
            }
        }
    }

    private var rotationDiagCounter = 0

    private func updateNodeTransformsForChain(nodePositions: [(VRMNode, SIMD3<Float>, Int)]) {
        rotationDiagCounter += 1
        let shouldLog = rotationDiagCounter <= 5 || rotationDiagCounter % 60 == 0

        // Update bone rotations to point toward physics-simulated positions
        for i in 0..<nodePositions.count - 1 {
            let (currentNode, currentPos, globalIndex) = nodePositions[i]
            let (_, nextPos, _) = nodePositions[i + 1]

            // NaN guard: skip if positions are invalid
            if currentPos.x.isNaN || currentPos.y.isNaN || currentPos.z.isNaN ||
               nextPos.x.isNaN || nextPos.y.isNaN || nextPos.z.isNaN {
                continue
            }

            // Calculate direction vector from current bone to next bone
            let toNext = nextPos - currentPos
            let distance = length(toNext)

            if distance < 0.001 { continue }

            let targetDir = toNext / distance

            // VRM SpringBone Rotation Update (per three-vrm spec):
            // Use setFromUnitVectors(initialAxis, newLocalDirection) where BOTH are in bone's local space.
            // This computes ABSOLUTE rotation, not accumulated delta.

            // Get bind direction stored in PARENT's local space (at bind time)
            guard globalIndex < boneBindDirections.count else { continue }
            let bindDirInParentSpace = boneBindDirections[globalIndex]

            // NaN guard: skip if bind direction is invalid
            if bindDirInParentSpace.x.isNaN || bindDirInParentSpace.y.isNaN || bindDirInParentSpace.z.isNaN ||
               simd_length(bindDirInParentSpace) < 0.001 {
                continue
            }

            // Get parent's world rotation (CURRENT, after earlier bones in chain were updated)
            guard let parent = currentNode.parent else { continue }
            let parentRot = extractRotation(from: parent.worldMatrix)

            // NaN guard for parent rotation
            if parentRot.real.isNaN || parentRot.imag.x.isNaN ||
               parentRot.imag.y.isNaN || parentRot.imag.z.isNaN {
                vrmLogPhysics("[SpringBone] ⚠️ Parent rotation NaN, resetting node \(currentNode.name ?? "unnamed")")
                currentNode.localRotation = currentNode.initialRotation
                currentNode.updateLocalMatrix()
                currentNode.updateWorldTransform()
                continue
            }

            // Per three-vrm spec: compute swing rotation and apply ON TOP of initial rotation.
            // This preserves the bone's original twist/roll from bind pose.
            //
            // Step 1: Transform target direction to parent's local space
            let parentRotInv = simd_conjugate(parentRot)
            let targetDirParent = simd_act(parentRotInv, targetDir)

            // Step 2: Transform target direction to bone's REST frame (bind pose local space)
            // This tells us "where is the target relative to the bone's original orientation"
            let initialRotInv = simd_conjugate(currentNode.initialRotation)
            let targetDirRest = simd_act(initialRotInv, targetDirParent)

            // Step 3: Get bone's initial forward axis in its local space
            let initialAxis = simd_act(initialRotInv, bindDirInParentSpace)

            // Step 4: Calculate "swing" rotation needed to align initial axis with target
            //
            // SOFT DEADZONE: Instead of hard cutoff, smoothly blend physics influence.
            // - Deadzone: 0.001 (1mm) - below this, use initial rotation (sleep)
            // - Fade range: 0.005 (5mm) - smooth transition to full physics
            // This prevents both flutter (at rest) and popping (during transition)
            //
            // For unit vectors: distance ≈ 2*sin(θ/2) ≈ θ for small angles
            let initialAxisNorm = simd_normalize(initialAxis)
            let targetDirNorm = simd_normalize(targetDirRest)
            let displacement = simd_length(targetDirNorm - initialAxisNorm)

            let deadzone: Float = 0.001      // 1mm - sleep threshold
            let fadeRange: Float = 0.005     // 5mm - smooth transition range

            // Calculate blend weight: 0 at deadzone, 1 at deadzone+fadeRange
            let physicsWeight = min(max((displacement - deadzone) / fadeRange, 0.0), 1.0)

            var newRotation: simd_quatf
            let dotProduct = simd_dot(initialAxisNorm, targetDirNorm)

            if dotProduct > 0.9998 {  // ~1.15 degrees - numerical stability zone
                // Nearly parallel - use initial rotation to prevent swirl
                newRotation = currentNode.initialRotation
            } else {
                // Compute swing rotation and apply ON TOP of initial rotation
                let swingRotation = quaternionFromTo(from: initialAxis, to: targetDirRest)
                let physicsRotation = currentNode.initialRotation * swingRotation

                // Soft blend: slerp between initial (rest) and physics rotation
                if physicsWeight < 0.001 {
                    // In deadzone - sleep
                    newRotation = currentNode.initialRotation
                } else if physicsWeight > 0.999 {
                    // Full physics
                    newRotation = physicsRotation
                } else {
                    // Blend zone - smooth transition
                    newRotation = simd_slerp(currentNode.initialRotation, physicsRotation, physicsWeight)
                }
            }

            // NaN guard: skip if rotation is invalid
            if newRotation.real.isNaN || newRotation.imag.x.isNaN ||
               newRotation.imag.y.isNaN || newRotation.imag.z.isNaN {
                continue
            }

            // DIAGNOSTIC: Log rotation values
            if shouldLog && i == 0 {
                let newAngle = 2.0 * acos(min(abs(newRotation.real), 1.0)) * 180.0 / Float.pi
                print("[ROTATION \(rotationDiagCounter)] bone=\(globalIndex) dot=\(String(format: "%.4f", dotProduct)) disp=\(String(format: "%.4f", displacement)) weight=\(String(format: "%.2f", physicsWeight))")
                print("  newRotAngle=\(String(format: "%.2f", newAngle))° atRest=\(dotProduct > 0.9998) sleeping=\(physicsWeight < 0.001)")
            }

            // Final NaN/Inf guard before applying - reset to bind pose if calculation produced bad values
            // IMPORTANT: Check both isNaN AND isInfinite - Inf quaternions produce NaN matrices
            if newRotation.real.isNaN || newRotation.real.isInfinite ||
               newRotation.imag.x.isNaN || newRotation.imag.x.isInfinite ||
               newRotation.imag.y.isNaN || newRotation.imag.y.isInfinite ||
               newRotation.imag.z.isNaN || newRotation.imag.z.isInfinite {
                vrmLogPhysics("[SpringBone] ⚠️ Calculated rotation NaN/Inf, resetting node \(currentNode.name ?? "unnamed")")
                currentNode.localRotation = currentNode.initialRotation
                currentNode.updateLocalMatrix()
                currentNode.updateWorldTransform()
                continue
            }

            currentNode.localRotation = newRotation
            currentNode.updateLocalMatrix()
            currentNode.updateWorldTransform()
        }
    }

    private func quaternionFromTo(from: SIMD3<Float>, to: SIMD3<Float>) -> simd_quatf {
        // THREE.JS HALF-ANGLE FORMULATION (numerically stable)
        // Based on three.js Quaternion.setFromUnitVectors
        //
        // Why this is better than angle-axis:
        // 1. No acos() call - acos loses precision near 1.0, causing noise for small angles
        // 2. For small angles, w ≈ 2 and xyz ≈ 0, giving clean near-identity quaternions
        // 3. Cross product magnitude naturally scales with sin(θ), no separate axis normalization
        //
        // Formula: q = (cross(a,b), 1 + dot(a,b)).normalize()
        // This exploits the half-angle identity: q = (sin(θ/2)*axis, cos(θ/2))
        // where 1 + dot(a,b) = 1 + cos(θ) = 2*cos²(θ/2) ∝ cos(θ/2) after normalization

        // Input validation
        let fromLen = simd_length(from)
        let toLen = simd_length(to)
        if fromLen < 0.0001 || toLen < 0.0001 ||
           fromLen.isNaN || fromLen.isInfinite ||
           toLen.isNaN || toLen.isInfinite {
            return simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        }

        // Normalize inputs
        let vFrom = from / fromLen
        let vTo = to / toLen

        // r = 1 + dot(vFrom, vTo)
        var r = simd_dot(vFrom, vTo) + 1.0

        if r < 0.000001 {
            // Nearly anti-parallel (180° rotation)
            // Find perpendicular axis
            r = 0
            var qx: Float, qy: Float, qz: Float

            if abs(vFrom.x) > abs(vFrom.z) {
                // Perpendicular in XY plane
                qx = -vFrom.y
                qy = vFrom.x
                qz = 0
            } else {
                // Perpendicular in YZ plane
                qx = 0
                qy = -vFrom.z
                qz = vFrom.y
            }

            let q = simd_quatf(ix: qx, iy: qy, iz: qz, r: r)
            return simd_normalize(q)
        }

        // Cross product gives axis * sin(θ), r gives 1 + cos(θ)
        let crossVec = simd_cross(vFrom, vTo)
        let q = simd_quatf(ix: crossVec.x, iy: crossVec.y, iz: crossVec.z, r: r)
        return simd_normalize(q)
    }

    private func extractRotation(from matrix: float4x4) -> simd_quatf {
        let rotationMatrix = float3x3(
            SIMD3<Float>(matrix[0][0], matrix[0][1], matrix[0][2]),
            SIMD3<Float>(matrix[1][0], matrix[1][1], matrix[1][2]),
            SIMD3<Float>(matrix[2][0], matrix[2][1], matrix[2][2])
        )
        return simd_quatf(rotationMatrix)
    }

    private func clamp(_ value: Float, _ min: Float, _ max: Float) -> Float {
        return Swift.max(min, Swift.min(max, value))
    }

    // MARK: - Frame Interpolation State Capture

    /// Captures all target transforms from animation for this frame
    /// Called once at the start of the frame before substep loop
    /// Captures: root positions, world bind directions, collider transforms
    private func captureTargetTransforms(model: VRMModel) {
        guard let springBone = model.springBone else { return }

        // 1. Capture root positions
        targetRootPositions = []
        for spring in springBone.springs {
            if let firstJoint = spring.joints.first,
               let node = model.nodes[safe: firstJoint.node] {
                targetRootPositions.append(node.worldPosition)
            }
        }

        // First frame initialization
        if previousRootPositions.isEmpty || previousRootPositions.count != targetRootPositions.count {
            previousRootPositions = targetRootPositions
        }

        // 2. Capture world bind directions (transforms static bind dirs by current parent rotation)
        captureTargetWorldBindDirections(model: model, springBone: springBone)

        // 3. Capture collider transforms
        captureTargetColliderTransforms(model: model, springBone: springBone)

        // Cache model scale for scale-aware thresholds
        cachedModelScale = calculateModelScaleFromRestLengths()
    }

    /// Captures world-space bind directions based on current animated parent orientations
    private func captureTargetWorldBindDirections(model: VRMModel, springBone: VRMSpringBone) {
        targetWorldBindDirections = []

        var boneIndex = 0
        for spring in springBone.springs {
            for joint in spring.joints {
                guard boneIndex < boneBindDirections.count,
                      let jointNode = model.nodes[safe: joint.node] else {
                    boneIndex += 1
                    continue
                }

                let localBindDir = boneBindDirections[boneIndex]

                // Transform by the node's ACTUAL parent (matches how we stored it)
                if let nodeParent = jointNode.parent {
                    let parentRot = extractRotation(from: nodeParent.worldMatrix)
                    let worldBindDir = simd_act(parentRot, localBindDir)
                    targetWorldBindDirections.append(simd_normalize(worldBindDir))
                } else {
                    // Root bone - local is world
                    targetWorldBindDirections.append(localBindDir)
                }

                boneIndex += 1
            }
        }

        // First frame initialization
        if previousWorldBindDirections.isEmpty || previousWorldBindDirections.count != targetWorldBindDirections.count {
            previousWorldBindDirections = targetWorldBindDirections
        }
    }

    /// Captures collider transforms based on current animated node positions/orientations
    private func captureTargetColliderTransforms(model: VRMModel, springBone: VRMSpringBone) {
        // Build collider-to-group index mapping
        var colliderToGroupIndex: [Int: UInt32] = [:]
        for (groupIndex, group) in springBone.colliderGroups.enumerated() {
            for colliderIndex in group.colliders {
                if colliderToGroupIndex[colliderIndex] == nil {
                    colliderToGroupIndex[colliderIndex] = UInt32(groupIndex)
                }
            }
        }

        targetSphereColliders = []
        targetCapsuleColliders = []
        targetPlaneColliders = []

        for (colliderIndex, collider) in springBone.colliders.enumerated() {
            guard let colliderNode = model.nodes[safe: collider.node] else { continue }
            let groupIndex = colliderToGroupIndex[colliderIndex] ?? 0

            let wm = colliderNode.worldMatrix
            let worldRotation = simd_float3x3(
                SIMD3<Float>(wm[0][0], wm[0][1], wm[0][2]),
                SIMD3<Float>(wm[1][0], wm[1][1], wm[1][2]),
                SIMD3<Float>(wm[2][0], wm[2][1], wm[2][2])
            )

            switch collider.shape {
            case .sphere(let offset, let radius):
                let worldOffset = worldRotation * offset
                let worldCenter = colliderNode.worldPosition + worldOffset
                targetSphereColliders.append(SphereCollider(center: worldCenter, radius: radius, groupIndex: groupIndex))

            case .capsule(let offset, let radius, let tail):
                let worldOffset = worldRotation * offset
                let worldTail = worldRotation * tail
                let worldP0 = colliderNode.worldPosition + worldOffset
                let worldP1 = worldP0 + worldTail
                targetCapsuleColliders.append(CapsuleCollider(p0: worldP0, p1: worldP1, radius: radius, groupIndex: groupIndex))

            case .plane(let offset, let normal):
                let worldOffset = worldRotation * offset
                let worldNormal = worldRotation * normal
                let worldPoint = colliderNode.worldPosition + worldOffset
                let normalizedNormal = simd_length(worldNormal) > 0.001 ? simd_normalize(worldNormal) : SIMD3<Float>(0, 1, 0)
                targetPlaneColliders.append(PlaneCollider(point: worldPoint, normal: normalizedNormal, groupIndex: groupIndex))
            }
        }

        // First frame initialization
        if previousSphereColliders.isEmpty || previousSphereColliders.count != targetSphereColliders.count {
            previousSphereColliders = targetSphereColliders
        }
        if previousCapsuleColliders.isEmpty || previousCapsuleColliders.count != targetCapsuleColliders.count {
            previousCapsuleColliders = targetCapsuleColliders
        }
        if previousPlaneColliders.isEmpty || previousPlaneColliders.count != targetPlaneColliders.count {
            previousPlaneColliders = targetPlaneColliders
        }
    }

    /// Estimates model scale from bone rest lengths (proxy for overall model size)
    private func calculateModelScaleFromRestLengths() -> Float {
        // Use max non-zero rest length as a reasonable proxy for model scale
        // Typical VRM models have rest lengths of 0.05-0.15m for hair/cloth bones
        let nonZeroLengths = cpuRestLengths.filter { $0 > 0.001 }
        guard !nonZeroLengths.isEmpty else {
            return 1.0 // Default scale if no valid rest lengths
        }

        // Average rest length, normalized so that ~0.1m = 1.0 scale
        let avgLength = nonZeroLengths.reduce(0, +) / Float(nonZeroLengths.count)
        let normalizedScale = avgLength / 0.1  // 0.1m is typical bone length at scale 1.0

        return max(normalizedScale, VRMConstants.Physics.minScaleForThreshold)
    }

    // MARK: - Substep Interpolation Methods

    /// Interpolates all transforms for the current substep
    /// - Parameter t: Interpolation factor [0, 1] where 0 = previous frame, 1 = current frame target
    private func interpolateAllTransforms(t: Float, buffers: SpringBoneBuffers) {
        interpolateRootPositions(t: t)
        interpolateWorldBindDirections(t: t, buffers: buffers)
        interpolateColliders(t: t, buffers: buffers)
    }

    /// Interpolates root positions for the current substep
    private func interpolateRootPositions(t: Float) {
        guard previousRootPositions.count == targetRootPositions.count,
              let buffer = animatedRootPositionsBuffer,
              !previousRootPositions.isEmpty else { return }

        let ptr = buffer.contents().bindMemory(to: SIMD3<Float>.self, capacity: previousRootPositions.count)
        for i in 0..<previousRootPositions.count {
            // Linear interpolation: prev + t * (target - prev)
            ptr[i] = simd_mix(previousRootPositions[i], targetRootPositions[i], SIMD3<Float>(repeating: t))
        }
    }

    /// Interpolates world bind directions using normalized linear interpolation (nlerp)
    /// This prevents rotational snapping during fast character turns
    private func interpolateWorldBindDirections(t: Float, buffers: SpringBoneBuffers) {
        guard previousWorldBindDirections.count == targetWorldBindDirections.count,
              let bindDirectionsBuffer = buffers.bindDirections,
              !previousWorldBindDirections.isEmpty else { return }

        let ptr = bindDirectionsBuffer.contents().bindMemory(to: SIMD3<Float>.self, capacity: previousWorldBindDirections.count)
        for i in 0..<previousWorldBindDirections.count {
            // Normalized linear interpolation (nlerp) for direction vectors
            let interpolated = simd_mix(previousWorldBindDirections[i], targetWorldBindDirections[i], SIMD3<Float>(repeating: t))
            let len = simd_length(interpolated)
            ptr[i] = len > 0.001 ? interpolated / len : targetWorldBindDirections[i]
        }
    }

    /// Interpolates collider transforms for the current substep
    /// Prevents collision geometry from snapping during fast rotations
    private func interpolateColliders(t: Float, buffers: SpringBoneBuffers) {
        // Interpolate sphere colliders
        if previousSphereColliders.count == targetSphereColliders.count,
           let sphereBuffer = buffers.sphereColliders,
           !previousSphereColliders.isEmpty {
            let ptr = sphereBuffer.contents().bindMemory(to: SphereCollider.self, capacity: previousSphereColliders.count)
            for i in 0..<previousSphereColliders.count {
                let prev = previousSphereColliders[i]
                let target = targetSphereColliders[i]
                ptr[i] = SphereCollider(
                    center: simd_mix(prev.center, target.center, SIMD3<Float>(repeating: t)),
                    radius: prev.radius + t * (target.radius - prev.radius),
                    groupIndex: target.groupIndex
                )
            }
        }

        // Interpolate capsule colliders
        if previousCapsuleColliders.count == targetCapsuleColliders.count,
           let capsuleBuffer = buffers.capsuleColliders,
           !previousCapsuleColliders.isEmpty {
            let ptr = capsuleBuffer.contents().bindMemory(to: CapsuleCollider.self, capacity: previousCapsuleColliders.count)
            for i in 0..<previousCapsuleColliders.count {
                let prev = previousCapsuleColliders[i]
                let target = targetCapsuleColliders[i]
                ptr[i] = CapsuleCollider(
                    p0: simd_mix(prev.p0, target.p0, SIMD3<Float>(repeating: t)),
                    p1: simd_mix(prev.p1, target.p1, SIMD3<Float>(repeating: t)),
                    radius: prev.radius + t * (target.radius - prev.radius),
                    groupIndex: target.groupIndex
                )
            }
        }

        // Interpolate plane colliders
        if previousPlaneColliders.count == targetPlaneColliders.count,
           let planeBuffer = buffers.planeColliders,
           !previousPlaneColliders.isEmpty {
            let ptr = planeBuffer.contents().bindMemory(to: PlaneCollider.self, capacity: previousPlaneColliders.count)
            for i in 0..<previousPlaneColliders.count {
                let prev = previousPlaneColliders[i]
                let target = targetPlaneColliders[i]
                // nlerp for normal direction
                let interpolatedNormal = simd_mix(prev.normal, target.normal, SIMD3<Float>(repeating: t))
                let normalLen = simd_length(interpolatedNormal)
                ptr[i] = PlaneCollider(
                    point: simd_mix(prev.point, target.point, SIMD3<Float>(repeating: t)),
                    normal: normalLen > 0.001 ? interpolatedNormal / normalLen : target.normal,
                    groupIndex: target.groupIndex
                )
            }
        }
    }

    /// Stores current target transforms as previous for next frame's interpolation
    private func commitAllTransforms() {
        previousRootPositions = targetRootPositions
        previousWorldBindDirections = targetWorldBindDirections
        previousSphereColliders = targetSphereColliders
        previousCapsuleColliders = targetCapsuleColliders
        previousPlaneColliders = targetPlaneColliders
    }

    // MARK: - Teleportation Detection

    /// Detects if the model has teleported (moved more than threshold distance)
    /// This prevents physics explosion when character is repositioned instantly
    /// Uses scale-aware threshold to handle models of different sizes
    private func detectTeleportation(currentPositions: [SIMD3<Float>], buffers: SpringBoneBuffers) -> Bool {
        // Skip detection on first frame or if no previous positions
        guard !lastRootPositions.isEmpty,
              lastRootPositions.count == currentPositions.count else {
            return false
        }

        // Scale threshold by model size (tiny models have proportionally smaller thresholds)
        let scaledThreshold = teleportationThreshold * max(cachedModelScale, VRMConstants.Physics.minScaleForThreshold)

        // Check if any root bone moved more than the scaled threshold
        for i in 0..<currentPositions.count {
            let distance = simd_distance(currentPositions[i], lastRootPositions[i])
            if distance > scaledThreshold {
                return true
            }
        }

        return false
    }

    /// Resets physics state after teleportation to prevent spring explosion
    /// Calculates kinematic (rest) positions for all bones based on parent chain
    private func resetPhysicsState(model: VRMModel, buffers: SpringBoneBuffers, animatedPositions: [SIMD3<Float>]) {
        guard let bonePosPrev = buffers.bonePosPrev,
              let bonePosCurr = buffers.bonePosCurr,
              buffers.numBones > 0,
              cpuParentIndices.count == buffers.numBones,
              cpuRestLengths.count == buffers.numBones else {
            return
        }

        // Calculate kinematic positions: root bones from animation, children from parent + direction * length
        var kinematicPositions: [SIMD3<Float>] = Array(repeating: .zero, count: buffers.numBones)

        // Map root bone indices to their animated positions
        var rootPositionMap: [Int: SIMD3<Float>] = [:]
        for (i, rootIdx) in rootBoneIndices.enumerated() {
            if i < animatedPositions.count {
                rootPositionMap[Int(rootIdx)] = animatedPositions[i]
            }
        }

        // Process bones in order (parents before children due to chain structure)
        // Use gravity direction (downward) for child bones to make hair hang naturally
        let gravityDir = SIMD3<Float>(0, -1, 0)

        for i in 0..<buffers.numBones {
            let parentIdx = cpuParentIndices[i]

            if parentIdx < 0 {
                // Root bone - use animated position
                kinematicPositions[i] = rootPositionMap[i] ?? .zero
            } else {
                // Child bone - hang down from parent using gravity direction
                let parentPos = kinematicPositions[parentIdx]
                let restLength = cpuRestLengths[i]

                // Use gravity direction so hair hangs down naturally
                kinematicPositions[i] = parentPos + gravityDir * restLength
            }
        }

        // Reset both previous and current positions to kinematic (eliminates velocity)
        let prevPtr = bonePosPrev.contents().bindMemory(to: SIMD3<Float>.self, capacity: buffers.numBones)
        let currPtr = bonePosCurr.contents().bindMemory(to: SIMD3<Float>.self, capacity: buffers.numBones)
        for i in 0..<buffers.numBones {
            prevPtr[i] = kinematicPositions[i]
            currPtr[i] = kinematicPositions[i]
        }

        // Reset time accumulator to prevent multiple substeps after teleport
        timeAccumulator = 0

        // Reset settling period to allow bones to settle after teleport/reset
        model.springBoneGlobalParams?.settlingFrames = 120

        // Reset readback state
        snapshotLock.lock()
        latestPositionsSnapshot.removeAll(keepingCapacity: true)
        latestCompletedFrame = 0
        lastAppliedFrame = 0
        snapshotLock.unlock()
    }
}

enum SpringBoneError: Error {
    case failedToLoadShaders
    case invalidBoneData
    case bufferAllocationFailed
}
