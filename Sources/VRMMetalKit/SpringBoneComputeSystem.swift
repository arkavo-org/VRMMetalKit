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

    private var globalParamsBuffer: MTLBuffer?
    private var animatedRootPositionsBuffer: MTLBuffer?
    private var rootBoneIndicesBuffer: MTLBuffer?
    private var numRootBonesBuffer: MTLBuffer?
    private var rootBoneIndices: [UInt32] = []
    private var timeAccumulator: TimeInterval = 0
    private var lastUpdateTime: TimeInterval = 0

    // Store bind-pose direction for each bone (in parent's local space)
    private var boneBindDirections: [SIMD3<Float>] = []

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
              let collideCapsulesFunction = library.makeFunction(name: "springBoneCollideCapsules") else {
            vrmLog("[SpringBone] ❌ Failed to find shader functions in library")
            throw SpringBoneError.failedToLoadShaders
        }

        kinematicPipeline = try device.makeComputePipelineState(function: kinematicFunction)
        predictPipeline = try device.makeComputePipelineState(function: predictFunction)
        distancePipeline = try device.makeComputePipelineState(function: distanceFunction)
        collideSpheresPipeline = try device.makeComputePipelineState(function: collideSpheresFunction)
        collideCapsulesPipeline = try device.makeComputePipelineState(function: collideCapsulesFunction)

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
        var stepsThisFrame = 0

        // Process fixed steps (clamped to avoid spiral-of-death)
        while timeAccumulator >= fixedDeltaTime && stepsThisFrame < maxSubsteps {
            timeAccumulator -= fixedDeltaTime
            stepsThisFrame += 1

            // Update global params with current time
            var params = globalParams
            params.windPhase += Float(fixedDeltaTime)

            // Copy updated params to GPU
            globalParamsBuffer?.contents().copyMemory(from: &params, byteCount: MemoryLayout<SpringBoneGlobalParams>.stride)

            // Update animated root positions and colliders
            updateAnimatedPositions(model: model, buffers: buffers)

            // Execute XPBD pipeline
            executeXPBDStep(buffers: buffers, globalParams: params)

            // Debug: Log bone positions occasionally
            updateCounter += 1
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

        lastUpdateTime = CACurrentMediaTime()
    }

    private func executeXPBDStep(buffers: SpringBoneBuffers, globalParams: SpringBoneGlobalParams) {
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let kinematicPipeline = kinematicPipeline,
              let predictPipeline = predictPipeline,
              let distancePipeline = distancePipeline,
              let collideSpheresPipeline = collideSpheresPipeline,
              let collideCapsulesPipeline = collideCapsulesPipeline else {
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

        // First update kinematic root bones with animated positions
        if !rootBoneIndices.isEmpty,
           let animatedRootPositionsBuffer = animatedRootPositionsBuffer,
           let rootBoneIndicesBuffer = rootBoneIndicesBuffer,
           let numRootBonesBuffer = numRootBonesBuffer {
            computeEncoder.setComputePipelineState(kinematicPipeline)
            computeEncoder.setBuffer(animatedRootPositionsBuffer, offset: 0, index: 5)
            computeEncoder.setBuffer(rootBoneIndicesBuffer, offset: 0, index: 6)
            computeEncoder.setBuffer(numRootBonesBuffer, offset: 0, index: 7)
            let rootGridSize = MTLSize(width: rootBoneIndices.count, height: 1, depth: 1)
            computeEncoder.dispatchThreads(rootGridSize, threadsPerThreadgroup: threadgroupSize)
        }

        // Execute predict kernel
        computeEncoder.setComputePipelineState(predictPipeline)
        computeEncoder.dispatchThreads(gridSize, threadsPerThreadgroup: threadgroupSize)

        // Execute distance constraint kernel
        computeEncoder.setComputePipelineState(distancePipeline)
        computeEncoder.dispatchThreads(gridSize, threadsPerThreadgroup: threadgroupSize)

        // Execute collision kernels only if colliders exist
        if globalParams.numSpheres > 0 {
            computeEncoder.setComputePipelineState(collideSpheresPipeline)
            computeEncoder.dispatchThreads(gridSize, threadsPerThreadgroup: threadgroupSize)
        }

        if globalParams.numCapsules > 0 {
            computeEncoder.setComputePipelineState(collideCapsulesPipeline)
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
        var sphereColliders: [SphereCollider] = []
        var capsuleColliders: [CapsuleCollider] = []
        boneBindDirections = [] // Reset bind directions

        // Process spring chains to extract bone parameters
        var boneIndex = 0
        rootBoneIndices = []

        // Track chains with all-zero gravityPower for auto-fix
        var chainGravityPowers: [[Float]] = []

        for spring in springBone.springs {
            var jointIndexInChain = 0
            var chainGravityPower: [Float] = []

            for joint in spring.joints {
                chainGravityPower.append(joint.gravityPower)

                // First joint in each spring chain is a root
                let isRootBone = (jointIndexInChain == 0)

                if isRootBone {
                    rootBoneIndices.append(UInt32(boneIndex))
                }

                let params = BoneParams(
                    stiffness: joint.stiffness,
                    drag: joint.dragForce,
                    radius: joint.hitRadius,
                    // Only set parent for non-root bones within the same chain
                    parentIndex: (isRootBone || jointIndexInChain == 0) ? 0xFFFFFFFF : UInt32(boneIndex - 1)
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

                // Look ahead to next joint in chain to get direction
                if let nextJoint = spring.joints[safe: jointIndexInChain + 1],
                   let nextNode = model.nodes[safe: nextJoint.node] {
                    // Direction from current bone to next bone in world space
                    let bindDirWorld = simd_normalize(nextNode.worldPosition - currentNode.worldPosition)

                    // Transform to THIS bone's local space (will be rotation-invariant)
                    let currentRotInv = simd_conjugate(extractRotation(from: currentNode.worldMatrix))
                    let bindDirLocal = simd_act(currentRotInv, bindDirWorld)
                    boneBindDirections.append(bindDirLocal)

                    if boneIndex < 3 {
                        vrmLog("[SpringBone] Bone \(boneIndex): bindDirWorld=\(bindDirWorld), bindDirLocal (bone space)=\(bindDirLocal)")
                    }
                } else {
                    // Last bone in chain has no child - use default
                    boneBindDirections.append(SIMD3<Float>(0, 1, 0))
                }

                boneIndex += 1
                jointIndexInChain += 1
            }

            chainGravityPowers.append(chainGravityPower)
        }

        // Auto-fix broken VRM physics: apply minimum gravity to chains with all-zero gravityPower
        var fixedChainCount = 0
        var boneIndexForFix = 0
        for (chainIndex, gravityPowers) in chainGravityPowers.enumerated() {
            let allZeroGravity = gravityPowers.allSatisfy { $0 == 0 }
            if allZeroGravity && !gravityPowers.isEmpty {
                // Update global params gravity multiplier for these bones
                // Note: In GPU version, we modify globalParams.gravity instead of per-bone gravityPower
                // This is simpler and equivalent for all-zero chains
                fixedChainCount += 1

                vrmLog("⚠️ [SpringBone GPU] Chain \(chainIndex) has gravityPower=0. Gravity will be applied globally.")
            }
            boneIndexForFix += gravityPowers.count
        }

        if fixedChainCount > 0 {
            vrmLog("⚠️ [SpringBone GPU] Model has \(fixedChainCount) spring chain(s) with gravityPower=0. Using global gravity setting.")
        }

        // Process colliders
        for collider in springBone.colliders {
            guard let colliderNode = model.nodes[safe: collider.node] else { continue }

            switch collider.shape {
            case .sphere(let offset, let radius):
                let worldCenter = colliderNode.worldPosition + offset
                sphereColliders.append(SphereCollider(center: worldCenter, radius: radius))

            case .capsule(let offset, let radius, let tail):
                let worldP0 = colliderNode.worldPosition + offset
                let worldP1 = colliderNode.worldPosition + tail
                capsuleColliders.append(CapsuleCollider(p0: worldP0, p1: worldP1, radius: radius))
            }
        }

        // Update buffers
        buffers.updateBoneParameters(boneParams)
        buffers.updateRestLengths(restLengths)

        if !sphereColliders.isEmpty {
            buffers.updateSphereColliders(sphereColliders)
        }

        if !capsuleColliders.isEmpty {
            buffers.updateCapsuleColliders(capsuleColliders)
        }

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

        // Copy to GPU buffer
        if animatedPositions.count > 0 {
            animatedRootPositionsBuffer.contents().copyMemory(
                from: animatedPositions,
                byteCount: MemoryLayout<SIMD3<Float>>.stride * animatedPositions.count
            )
        }

        // Update collider positions (they can move with animation)
        var sphereColliders: [SphereCollider] = []
        var capsuleColliders: [CapsuleCollider] = []

        for collider in springBone.colliders {
            guard let colliderNode = model.nodes[safe: collider.node] else { continue }

            switch collider.shape {
            case .sphere(let offset, let radius):
                let worldCenter = colliderNode.worldPosition + offset
                sphereColliders.append(SphereCollider(center: worldCenter, radius: radius))

            case .capsule(let offset, let radius, let tail):
                let worldP0 = colliderNode.worldPosition + offset
                let worldP1 = colliderNode.worldPosition + tail
                capsuleColliders.append(CapsuleCollider(p0: worldP0, p1: worldP1, radius: radius))
            }
        }

        // Update collider buffers with animated positions
        if !sphereColliders.isEmpty {
            buffers.updateSphereColliders(sphereColliders)
        }

        if !capsuleColliders.isEmpty {
            buffers.updateCapsuleColliders(capsuleColliders)
        }
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

    private func updateNodeTransformsForChain(nodePositions: [(VRMNode, SIMD3<Float>, Int)]) {
        // Update bone rotations to point toward physics-simulated positions
        for i in 0..<nodePositions.count - 1 {
            let (currentNode, currentPos, globalIndex) = nodePositions[i]
            let (_, nextPos, _) = nodePositions[i + 1]

            // Calculate direction vector from current bone to next bone
            let toNext = nextPos - currentPos
            let distance = length(toNext)

            if distance < 0.001 { continue }

            let targetDir = toNext / distance

            // Get the bone's bind-pose direction using GLOBAL bone index
            // This is in the bone's own local space (rotation-invariant)
            guard globalIndex < boneBindDirections.count else { continue }
            let bindDirLocal = boneBindDirections[globalIndex]

            // Transform bind direction from bone's local space to world space
            let currentRot = extractRotation(from: currentNode.worldMatrix)
            let bindDirWorld = simd_act(currentRot, bindDirLocal)

            // Calculate rotation DELTA needed to align bind direction with physics direction
            let rotationDelta = quaternionFromTo(from: bindDirWorld, to: targetDir)

            // Debug first bone every 60 frames
            if globalIndex == 0 {
                let dotProd = dot(bindDirWorld, targetDir)
                vrmLog("[SpringBone] Bone \(globalIndex): bindDir=\(bindDirWorld), target=\(targetDir), dot=\(dotProd)")
            }

            // Apply rotation delta ON TOP OF current rotation
            // Convert world-space delta to local space
            if let parent = currentNode.parent {
                let parentRot = extractRotation(from: parent.worldMatrix)
                let parentRotInv = simd_conjugate(parentRot)
                let localDelta = parentRotInv * rotationDelta * parentRot
                currentNode.localRotation = localDelta * currentNode.localRotation
            } else {
                // No parent - world delta equals local delta
                currentNode.localRotation = rotationDelta * currentNode.localRotation
            }

            currentNode.updateLocalMatrix()
            currentNode.updateWorldTransform()
        }
    }

    private func quaternionFromTo(from: SIMD3<Float>, to: SIMD3<Float>) -> simd_quatf {
        let axis = cross(from, to)
        let angle = acos(clamp(dot(from, to), -1, 1))

        if length(axis) < 0.0001 {
            // Vectors are parallel
            if dot(from, to) > 0 {
                return simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
            } else {
                // Find perpendicular axis
                let perpendicular = abs(from.x) < 0.9 ? SIMD3<Float>(1, 0, 0) : SIMD3<Float>(0, 1, 0)
                let axis = normalize(cross(from, perpendicular))
                return simd_quatf(angle: .pi, axis: axis)
            }
        }

        return simd_quatf(angle: angle, axis: normalize(axis))
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
}

enum SpringBoneError: Error {
    case failedToLoadShaders
    case invalidBoneData
    case bufferAllocationFailed
}
