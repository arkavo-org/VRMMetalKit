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
@preconcurrency import Metal
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
    private var centerDeltaPipeline: MTLComputePipelineState?
    private var collideSpheresPipeline: MTLComputePipelineState?
    private var collideCapsulesPipeline: MTLComputePipelineState?
    private var collidePlanesPipeline: MTLComputePipelineState?

    private var globalParamsBuffer: MTLBuffer?
    private var animatedRootPositionsBuffer: MTLBuffer?
    /// Holds the previous frame's animated root positions so the kinematic
    /// kernel can write a clean velocity history into `bonePosPrev[root]`
    /// instead of reading from `bonePosCurr[root]` (which can be contaminated
    /// by collision pushes — Bug #4 in issue #138).
    private var animatedRootPositionsPrevBuffer: MTLBuffer?
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
    private var lastFrameSubstepCount: Int = 1
    private var currentSubstepIndex: Int = 0

    /// Minimum alignment required for buffer offsets in Metal (typically 256 bytes for macOS x86/general safety)
    private static let kMetalBufferOffsetAlignment = 256
    
    /// Stride in bytes for each substep of animated root positions, aligned to 256 bytes.
    private var alignedStepLength: Int {
        let raw = MemoryLayout<SIMD3<Float>>.stride * rootBoneIndices.count
        return (raw + Self.kMetalBufferOffsetAlignment - 1) & ~(Self.kMetalBufferOffsetAlignment - 1)
    }

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

    // Reused buffer for writeBonesToNodes() chain walks; keeps capacity
    // across frames so springs don't each allocate their own tuple array.
    private var chainNodePositions: [(VRMNode, SIMD3<Float>, Int)] = []

    // MARK: - Center-space simulation (VRMC_springBone-1.0 §5.1)
    // Each entry records the center node index, the contiguous bone-buffer range occupied
    // by that spring's joints, and the center's world matrix from the previous frame.
    // Each substep, we apply the rigid delta (prevCenter⁻¹ · currCenter) to bonePosCurr
    // and bonePosPrev for those bone indices so that joint positions "follow" the center
    // node rather than accumulating inertia from the avatar's locomotion.
    struct CenterSpringRecord {
        var centerNodeIndex: Int
        var boneStart: Int
        var boneCount: Int
    }
    var centerSpringRecords: [CenterSpringRecord] = []
    private var previousCenterWorldMatrices: [Int: float4x4] = [:]
    /// Per-frame snapshot of each center node's *target* worldMatrix
    /// captured at the top of `update()`, consumed when the host
    /// pre-computes per-substep deltas into `centerDeltaBuffer` (VMK#295).
    private var targetCenterWorldMatrices: [Int: float4x4] = [:]
    /// GPU-side per-(substep × record) center delta entries — see
    /// `springBoneApplyCenterDelta` (`SpringBoneCenterDelta.metal`). Filled
    /// once per frame at the top of `update()` and dispatched per substep
    /// in `executeXPBDStep`. Allocated lazily once `centerSpringRecords`
    /// is non-empty.
    private var centerDeltaBuffer: MTLBuffer?

    /// 80-byte mirror of the `CenterDeltaRecord` struct in
    /// `SpringBoneCenterDelta.metal` (4 × uint header + 4×4 float matrix).
    /// Stride must match the Metal struct exactly so the per-substep
    /// `setBuffer(offset:)` math lands on the right entry.
    private struct CenterDeltaRecordGPU {
        var boneStart: UInt32
        var boneCount: UInt32
        var _pad0: UInt32 = 0
        var _pad1: UInt32 = 0
        var delta: float4x4
    }

    /// Flag to request physics state reset on next update (e.g., when returning to idle)
    var requestPhysicsReset = false

    /// Runtime clamps applied to authored spring-bone joint parameters before they
    /// are uploaded to the GPU. Default is `.passthrough` (no-op).
    var springBoneOverride: VRMSpringBoneOverride = .passthrough

    // MARK: - Runtime Collider Radius Overrides

    /// Runtime overrides for sphere collider radii (index -> radius)
    /// Used to dynamically adjust collision boundaries, e.g., to prevent hair clipping
    private var sphereColliderRadiusOverrides: [Int: Float] = [:]

    /// Sets a runtime radius override for a sphere collider
    /// - Parameters:
    ///   - index: The index of the sphere collider (0-based)
    ///   - radius: The new radius value
    func setSphereColliderRadius(index: Int, radius: Float) {
        sphereColliderRadiusOverrides[index] = radius
    }

    /// Clears a sphere collider radius override, reverting to the original value
    /// - Parameter index: The index of the sphere collider
    func clearSphereColliderRadiusOverride(index: Int) {
        sphereColliderRadiusOverrides.removeValue(forKey: index)
    }

    /// Clears all sphere collider radius overrides
    func clearAllColliderRadiusOverrides() {
        sphereColliderRadiusOverrides.removeAll()
    }

    // Readback + synchronization (protected by snapshotLock)
    private let snapshotLock = NSLock()
    private var latestPositionsSnapshot: [SIMD3<Float>] = []
    private var simulationFrameCounter: UInt64 = 0
    private var latestCompletedFrame: UInt64 = 0
    private var lastAppliedFrame: UInt64 = 0
    private var skippedReadbacks: Int = 0

    /// Most-recently-committed self-owned command buffer (only populated when
    /// `update(...)` is called with `commandBuffer: nil`). Held weakly via an
    /// instance ref so `waitForPendingFrame()` can block on it.
    private var pendingSelfOwnedCommandBuffer: MTLCommandBuffer?

    /// Signaled by the snapshot-capture completion handler so
    /// `waitForPendingFrame()` can block until the snapshot is actually
    /// populated — `MTLCommandBuffer.waitUntilCompleted` only waits for the
    /// GPU, not for completion handlers that run on a separate queue.
    private var pendingSnapshotSemaphore: DispatchSemaphore?

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

        // Attempt 2: Load the platform-appropriate metallib slice via the shared loader.
        if library == nil {
            do {
                library = try VRMShaderLibraryLoader.loadBundledLibrary(device: device)
                vrmLog("[SpringBone] ✅ Loaded from \(VRMShaderLibraryLoader.bundledLibraryName).metallib (Bundle.module)")
            } catch {
                vrmLog("[SpringBone] ❌ \(error.localizedDescription)")
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
              let collidePlanesFunction = library.makeFunction(name: "springBoneCollidePlanes"),
              let centerDeltaFunction = library.makeFunction(name: "springBoneApplyCenterDelta") else {
            vrmLog("[SpringBone] ❌ Failed to find shader functions in library")
            throw SpringBoneError.failedToLoadShaders
        }

        kinematicPipeline = try device.makeComputePipelineState(function: kinematicFunction)
        predictPipeline = try device.makeComputePipelineState(function: predictFunction)
        distancePipeline = try device.makeComputePipelineState(function: distanceFunction)
        collideSpheresPipeline = try device.makeComputePipelineState(function: collideSpheresFunction)
        collideCapsulesPipeline = try device.makeComputePipelineState(function: collideCapsulesFunction)
        collidePlanesPipeline = try device.makeComputePipelineState(function: collidePlanesFunction)
        centerDeltaPipeline = try device.makeComputePipelineState(function: centerDeltaFunction)

        // Create global params buffer
        globalParamsBuffer = device.makeBuffer(length: MemoryLayout<SpringBoneGlobalParams>.stride, options: [.storageModeShared])
    }

    private var updateCounter = 0

    /// Caller-controlled simulation quality. Drives substep rate, substep cap,
    /// and constraint-iteration count. Mirrored from `VRMRenderer.springBoneQuality`
    /// via a `didSet` on the renderer so callers only set it in one place.
    /// Defaults to `.ultra` to match the legacy global-constant behavior.
    var quality: VRMConstants.SpringBoneQuality = .ultra

    /// Run spring-bone simulation. If `commandBuffer` is non-nil, all substep compute
    /// passes are encoded into it (no internal `makeCommandBuffer`/`commit`) — caller
    /// owns the buffer's lifecycle. If `nil`, the legacy path is used (one fresh
    /// command buffer per substep, committed immediately) for backward compatibility.
    ///
    /// The shared-buffer path eliminates the per-substep `commandQueue.makeCommandBuffer`
    /// + `commit` overhead the audit identified as the renderer's #2 GPU bottleneck.
    func update(model: VRMModel, deltaTime: TimeInterval, commandBuffer: MTLCommandBuffer? = nil) {
        guard let buffers = model.springBoneBuffers,
              let globalParams = model.springBoneGlobalParams,
              buffers.numBones > 0 else {
            return
        }

        let rateHz = quality.substepRateHz
        guard rateHz > 0 else { return }  // .off

        // #283: On the self-committed path the previous update()'s per-substep
        // command buffers read `animatedRootPositionsBuffer` and
        // `animatedRootPositionsPrevBuffer` on the GPU. The frame-boundary prev
        // copy and the per-substep pose writes below are about to overwrite
        // both. The #278 aligned-offset segments de-conflict substeps *within*
        // a frame, but the same slots are reused every frame, so nothing
        // otherwise orders frame N's GPU reads before frame N+1's host writes.
        // Drain the previous self-committed frame here — without it the
        // kinematic kernel races the host and the animated simulation diverges
        // from the synchronised result and is non-deterministic run-to-run.
        // The shared-buffer path (commandBuffer != nil) is unaffected: its
        // caller owns command-buffer lifecycle and frame-boundary sync.
        if commandBuffer == nil {
            waitForPendingFrame()
        }

        // Fixed timestep accumulation
        timeAccumulator += deltaTime
        let fixedDeltaTime = 1.0 / rateHz
        let maxSubsteps = quality.maxSubstepsPerFrame

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

        // Snapshot the previous frame's animated root positions BEFORE we
        // overwrite animatedRootPositionsBuffer with this frame's pose. The
        // kinematic kernel reads previousPos from this buffer so velocity is
        // measured against last frame's animated target — independent of any
        // collision pushes that may have touched bonePosCurr (Bug #4).
        //
        // PERFORMANCE NOTE: On unified memory architectures (.storageModeShared), this is
        // a CPU-side memcpy of the final pose. To ensure no CPU-GPU data race against any
        // in-flight GPU read of the previous frame's prev buffer, callers must synchronize
        // at frame boundaries (i.e. wait for frame N to complete before encoding frame N+1).
        if frameSubstepCount > 0,
           let curr = animatedRootPositionsBuffer,
           let prev = animatedRootPositionsPrevBuffer {
            let singleStepLength = MemoryLayout<SIMD3<Float>>.stride * rootBoneIndices.count
            let prevStepCount = max(1, lastFrameSubstepCount)
            let lastSubstepIndex = prevStepCount - 1
            let byteOffset = lastSubstepIndex * alignedStepLength
            
            prev.contents().copyMemory(from: curr.contents().advanced(by: byteOffset), byteCount: singleStepLength)
        }

        // VRMC_springBone-1.0 §5.1 center-node rigid follow (VMK#295):
        // pre-compute every substep's incremental world-space delta on
        // the host and pack into `centerDeltaBuffer`. The GPU then
        // dispatches `springBoneApplyCenterDelta` per substep inside
        // `executeXPBDStep` (between kinematic and predict) with a fixed
        // offset into the buffer. Pre-filling once per frame avoids the
        // CPU/GPU race the earlier in-loop CPU-shift attempt hit on
        // the shared-command-buffer path: CPU writes between substep
        // encodings would coalesce against the GPU's first observation
        // of shared memory, leaving the joint partially-shifted and the
        // distance constraint fighting the apparent stretch.
        if frameSubstepCount > 0 && !centerSpringRecords.isEmpty {
            captureTargetCenterWorldMatrices(model: model)
            fillCenterDeltaBufferForFrame(substepCount: frameSubstepCount)
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
            let currentSubstepIdx = stepsThisFrame - 1
            if VRMConstants.Physics.enableRootInterpolation && frameSubstepCount > 0 {
                // t goes from 1/N to N/N across substeps (reaches 1.0 on last substep)
                let t = Float(currentSubstepIndex + 1) / Float(frameSubstepCount)
                interpolateAllTransforms(t: t, buffers: buffers, substepIndex: currentSubstepIdx)
                currentSubstepIndex += 1
            } else {
                // Fallback: original behavior - update all at once
                updateAnimatedPositions(model: model, buffers: buffers, substepIndex: currentSubstepIdx)
            }

            // Determine if this is the last substep of the frame
            let isLastSubstep = (timeAccumulator < fixedDeltaTime) || (stepsThisFrame >= maxSubsteps)

            // Execute XPBD pipeline
            executeXPBDStep(buffers: buffers, globalParams: params, sharedCommandBuffer: commandBuffer, substepIndex: currentSubstepIdx, registerCompletedHandler: isLastSubstep)

            // Debug: Log bone positions occasionally
            updateCounter += 1

            #if VRM_METALKIT_ENABLE_DEBUG_PHYSICS
            if updateCounter <= 10 || updateCounter % 60 == 0,
               let bonePosCurr = buffers.bonePosCurr,
               let bonePosPrev = buffers.bonePosPrev,
               let restLengthsBuffer = buffers.restLengths,
               let boneParamsBuffer = buffers.boneParams {
                let currPtr = bonePosCurr.contents().bindMemory(to: SIMD3<Float>.self, capacity: buffers.numBones)
                let prevPtr = bonePosPrev.contents().bindMemory(to: SIMD3<Float>.self, capacity: buffers.numBones)
                let restPtr = restLengthsBuffer.contents().bindMemory(to: Float.self, capacity: buffers.numBones)
                let paramsPtr = boneParamsBuffer.contents().bindMemory(to: BoneParams.self, capacity: buffers.numBones)

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

                    if simd_length(velocity) > 0.5 || actualDist > restLen * 2 || curr.y.isNaN {
                        print("  ⚠️ EXPLOSION DETECTED! velocity=\(simd_length(velocity)) stretch=\(actualDist/restLen)")
                    }
                }
            }
            #endif

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

        // Update center world matrices for the next frame's delta computation
        if stepsThisFrame > 0 {
            commitCenterWorldMatrices(model: model)
        }

        if frameSubstepCount > 0 {
            lastFrameSubstepCount = frameSubstepCount
        }
        lastUpdateTime = CACurrentMediaTime()
    }

    private func executeXPBDStep(buffers: SpringBoneBuffers,
                                  globalParams: SpringBoneGlobalParams,
                                  sharedCommandBuffer: MTLCommandBuffer? = nil,
                                  substepIndex: Int = 0,
                                  registerCompletedHandler: Bool = true) {
        guard let kinematicPipeline = kinematicPipeline,
              let predictPipeline = predictPipeline,
              let distancePipeline = distancePipeline,
              let collideSpheresPipeline = collideSpheresPipeline,
              let collideCapsulesPipeline = collideCapsulesPipeline,
              let collidePlanesPipeline = collidePlanesPipeline else {
            return
        }
        // If a host-owned buffer was passed in, encode into it (no commit).
        // Otherwise fall back to legacy per-substep buffer with own commit.
        let usingSharedBuffer = sharedCommandBuffer != nil
        let commandBuffer: MTLCommandBuffer
        if let shared = sharedCommandBuffer {
            commandBuffer = shared
        } else {
            guard let made = commandQueue.makeCommandBuffer() else { return }
            commandBuffer = made
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

        // First update kinematic root bones with animated positions.
        // Kinematic kernel uses buffer indices 8-10, 12 to avoid conflicts with
        // colliders (5-7) and bindDirections (11). Index 12 is the previous-
        // frame animated-position mirror used to write a clean velocity
        // history into bonePosPrev[root] (Bug #4 fix).
        if !rootBoneIndices.isEmpty,
           let animatedRootPositionsBuffer = animatedRootPositionsBuffer,
           let animatedRootPositionsPrevBuffer = animatedRootPositionsPrevBuffer,
           let rootBoneIndicesBuffer = rootBoneIndicesBuffer,
           let numRootBonesBuffer = numRootBonesBuffer {
            computeEncoder.setComputePipelineState(kinematicPipeline)

            assert(substepIndex < VRMConstants.Physics.maxSubstepsPerFrame, "substepIndex \(substepIndex) exceeds max allocated capacity")
            let byteOffset = substepIndex * alignedStepLength

            computeEncoder.setBuffer(animatedRootPositionsBuffer, offset: byteOffset, index: 8)
            computeEncoder.setBuffer(rootBoneIndicesBuffer, offset: 0, index: 9)
            computeEncoder.setBuffer(numRootBonesBuffer, offset: 0, index: 10)
            computeEncoder.setBuffer(animatedRootPositionsPrevBuffer, offset: 0, index: 12)
            let rootGridSize = MTLSize(width: rootBoneIndices.count, height: 1, depth: 1)
            computeEncoder.dispatchThreads(rootGridSize, threadsPerThreadgroup: threadgroupSize)
            computeEncoder.memoryBarrier(scope: .buffers)
        }

        // VRMC_springBone-1.0 §5.1 center-frame rigid follow (VMK#295):
        // apply this substep's pre-computed delta to bonePosCurr +
        // bonePosPrev for each spring-with-center. Lives between
        // kinematic and predict so kinematic has anchored the root to
        // the substep's interpolated animated position, and predict can
        // then read a consistent layout (root + chain bones shifted by
        // the same incremental fraction of the frame's center delta).
        if !centerSpringRecords.isEmpty,
           let centerDeltaPipeline = centerDeltaPipeline,
           let centerDeltaBuffer = centerDeltaBuffer {
            let recordCount = centerSpringRecords.count
            let recordStride = MemoryLayout<CenterDeltaRecordGPU>.stride
            let substepByteOffset = substepIndex * recordCount * recordStride
            computeEncoder.setComputePipelineState(centerDeltaPipeline)
            computeEncoder.setBuffer(centerDeltaBuffer, offset: substepByteOffset, index: 13)
            var numRecordsU32 = UInt32(recordCount)
            computeEncoder.setBytes(&numRecordsU32, length: MemoryLayout<UInt32>.size, index: 14)
            let recordGridSize = MTLSize(width: recordCount, height: 1, depth: 1)
            computeEncoder.dispatchThreads(recordGridSize, threadsPerThreadgroup: threadgroupSize)
            computeEncoder.memoryBarrier(scope: .buffers)
        }

        // Execute predict kernel (step 1: predict new tip position)
        computeEncoder.setComputePipelineState(predictPipeline)
        computeEncoder.dispatchThreads(gridSize, threadsPerThreadgroup: threadgroupSize)
        computeEncoder.memoryBarrier(scope: .buffers)

        // Distance constraint iterations (step 2: enforce bone length)
        // VRM spec: run distance constraint BEFORE collision, do not run it after
        let iterations = quality.constraintIterations
        for _ in 0..<iterations {
            computeEncoder.setComputePipelineState(distancePipeline)
            computeEncoder.dispatchThreads(gridSize, threadsPerThreadgroup: threadgroupSize)
            computeEncoder.memoryBarrier(scope: .buffers)
        }

        // Collision resolution (step 3: push tips out of colliders)
        // VRM spec: collision runs AFTER distance constraint and is the FINAL step
        // This prevents distance constraint from pulling hair back into colliders
        if globalParams.numSpheres > 0 {
            computeEncoder.setComputePipelineState(collideSpheresPipeline)
            computeEncoder.dispatchThreads(gridSize, threadsPerThreadgroup: threadgroupSize)
            computeEncoder.memoryBarrier(scope: .buffers)
        }

        if globalParams.numCapsules > 0 {
            computeEncoder.setComputePipelineState(collideCapsulesPipeline)
            computeEncoder.dispatchThreads(gridSize, threadsPerThreadgroup: threadgroupSize)
            computeEncoder.memoryBarrier(scope: .buffers)
        }

        if globalParams.numPlanes > 0 {
            computeEncoder.setComputePipelineState(collidePlanesPipeline)
            computeEncoder.dispatchThreads(gridSize, threadsPerThreadgroup: threadgroupSize)
            computeEncoder.memoryBarrier(scope: .buffers)
        }

        computeEncoder.endEncoding()

        simulationFrameCounter &+= 1
        let frameID = simulationFrameCounter

        let capturedBonePosCurr = buffers.bonePosCurr
        let capturedNumBones = buffers.numBones

        // For self-owned command buffers, allocate a semaphore so callers can
        // block on the snapshot actually being captured (the handler runs on
        // Metal's own queue after the GPU completes — waitUntilCompleted
        // alone does NOT guarantee the snapshot is populated).
        let shouldRegister = registerCompletedHandler || !usingSharedBuffer
        let snapshotSemaphore: DispatchSemaphore? = (usingSharedBuffer || !shouldRegister) ? nil : DispatchSemaphore(value: 0)
        if let sem = snapshotSemaphore {
            pendingSnapshotSemaphore = sem
        }
        
        if shouldRegister {
            commandBuffer.addCompletedHandler { [weak self] buffer in
                defer { snapshotSemaphore?.signal() }
                guard let self = self else { return }

                // Check for GPU errors before reading back data
                if buffer.status == .error {
                    if let error = buffer.error {
                        vrmLogPhysics("[SpringBone] GPU command buffer failed: \(error.localizedDescription)")
                    }
                    return
                }

                self.captureCompletedPositions(bonePosCurr: capturedBonePosCurr, numBones: capturedNumBones, frameID: frameID)
            }
        }

        // Only commit when we own the buffer. Caller commits the shared buffer.
        if !usingSharedBuffer {
            pendingSelfOwnedCommandBuffer = commandBuffer
            commandBuffer.commit()
        }
    }

    /// Blocks until the most recently `update(...)`-committed self-owned
    /// command buffer completes AND its snapshot capture handler has finished.
    /// No-op when the caller supplied a shared `commandBuffer:` to update —
    /// in that case the caller commits and waits themselves.
    /// Use from the renderer when `RendererConfig.synchronousSpringBone` is
    /// set so `writeBonesToNodes` consumes the current-frame snapshot.
    func waitForPendingFrame() {
        guard let cb = pendingSelfOwnedCommandBuffer else { return }
        cb.waitUntilCompleted()
        // Then wait for the snapshot-capture completion handler — it runs on
        // Metal's own dispatch queue, so it may not have finished even though
        // the GPU is done.
        pendingSnapshotSemaphore?.wait()
        pendingSelfOwnedCommandBuffer = nil
        pendingSnapshotSemaphore = nil
    }

    /// Transforms additive synthetic colliders (issue #309) into world space and
    /// appends them to the given destination arrays. They live in the reserved
    /// synthetic group (`groupIndex`) so every spring collides with them.
    ///
    /// This is the single shared implementation behind the three synthetic-upload
    /// passes (`populateSpringBoneData`, `updateAnimatedPositions`, and
    /// `captureTargetColliderTransforms`). It mirrors the authored upload idiom:
    /// a `simd_float3x3` rotation extracted from the node's `worldMatrix`,
    /// `worldPosition + worldRotation * offset` for the world center, capsule
    /// `p1 = p0 + worldRotation * tail`, and a `model.nodes[safe:]` bounds guard.
    /// All sphere/capsule shapes (including the `inside` containment variants)
    /// are handled so the uploaded count always matches the allocation count
    /// (`VRMModel.initializeSpringBoneGPUSystem` counts `insideSphere`/
    /// `insideCapsule` toward the sphere/capsule totals). A synthetic `.plane`
    /// is unsupported here and fails loud rather than silently desyncing that
    /// count.
    private func appendSyntheticColliders(
        _ synthetics: [VRMCollider],
        model: VRMModel,
        groupIndex: UInt32,
        spheres: inout [SphereCollider],
        capsules: inout [CapsuleCollider]
    ) {
        for collider in synthetics {
            guard let colliderNode = model.nodes[safe: collider.node] else { continue }

            let wm = colliderNode.worldMatrix
            let worldRotation = simd_float3x3(
                SIMD3<Float>(wm[0][0], wm[0][1], wm[0][2]),
                SIMD3<Float>(wm[1][0], wm[1][1], wm[1][2]),
                SIMD3<Float>(wm[2][0], wm[2][1], wm[2][2])
            )

            switch collider.shape {
            case .sphere(let offset, let radius):
                let worldCenter = colliderNode.worldPosition + worldRotation * offset
                spheres.append(SphereCollider(center: worldCenter, radius: radius, groupIndex: groupIndex))

            case .insideSphere(let offset, let radius):
                let worldCenter = colliderNode.worldPosition + worldRotation * offset
                spheres.append(SphereCollider(center: worldCenter, radius: radius, groupIndex: groupIndex, inside: true))

            case .capsule(let offset, let radius, let tail):
                let worldP0 = colliderNode.worldPosition + worldRotation * offset
                let worldP1 = worldP0 + worldRotation * tail
                capsules.append(CapsuleCollider(p0: worldP0, p1: worldP1, radius: radius, groupIndex: groupIndex))

            case .insideCapsule(let offset, let radius, let tail):
                let worldP0 = colliderNode.worldPosition + worldRotation * offset
                let worldP1 = worldP0 + worldRotation * tail
                capsules.append(CapsuleCollider(p0: worldP0, p1: worldP1, radius: radius, groupIndex: groupIndex, inside: true))

            case .plane:
                // Synthetic planes have no buffer here; allocation counts planes
                // separately, so silently dropping one would NOT desync the
                // sphere/capsule contract — but the augmentor must never emit a
                // plane it expects to take effect. Fail loud in debug.
                assertionFailure("appendSyntheticColliders received a synthetic .plane; planes are not supported on the synthetic upload path")
                continue
            }
        }
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
                // Use first group if collider belongs to multiple groups.
                // Clamp to 31 so the shader's `1u << groupIndex` is well-defined
                // (UB at >=32). Bone masks are already truncated to <32.
                if colliderToGroupIndex[colliderIndex] == nil {
                    colliderToGroupIndex[colliderIndex] = UInt32(min(groupIndex, 31))
                }
            }
        }

        // Synthetic colliders (issue #309) live in a reserved group bit so EVERY
        // spring collides with them, regardless of authored group membership.
        // Clamp to 31 so the shader's `1u << groupIndex` stays well-defined. Only
        // reserve the bit when synthetic colliders actually exist — otherwise the
        // reserved bit could alias an authored group's clamped bit (models with
        // >=32 groups all clamp to 31) and leak authored colliders through the
        // spring filter.
        let syntheticGroupIndex = UInt32(min(springBone.colliderGroups.count, 31))
        let hasSyntheticColliders = !springBone.syntheticColliders.isEmpty
        let syntheticGroupBit: UInt32 = hasSyntheticColliders ? (1 << syntheticGroupIndex) : 0

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
            // Always collide with synthetic colliders (issue #309). Harmless when
            // the mask is already the 0xFFFFFFFF all-groups default.
            colliderGroupMask |= syntheticGroupBit

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

                let jointName = model.nodes[safe: joint.node]?.name
                let clamped = springBoneOverride.apply(
                    stiffness: joint.stiffness,
                    dragForce: joint.dragForce,
                    gravityPower: joint.gravityPower,
                    jointName: jointName
                )

                let params = BoneParams(
                    stiffness: clamped.stiffness,
                    drag: clamped.dragForce,
                    radius: joint.hitRadius,
                    // Only set parent for non-root bones within the same chain
                    parentIndex: parentIdx < 0 ? 0xFFFFFFFF : UInt32(parentIdx),
                    gravityPower: clamped.gravityPower,
                    colliderGroupMask: colliderGroupMask,
                    gravityDir: normalizedGravityDir,
                    angleLimit: joint.angleLimit
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

            case .insideSphere(let offset, let radius):
                let worldOffset = worldRotation * offset
                let worldCenter = colliderNode.worldPosition + worldOffset
                sphereColliders.append(SphereCollider(center: worldCenter, radius: radius, groupIndex: groupIndex, inside: true))

            case .capsule(let offset, let radius, let tail):
                let worldOffset = worldRotation * offset
                let worldTail = worldRotation * tail
                let worldP0 = colliderNode.worldPosition + worldOffset
                let worldP1 = worldP0 + worldTail
                capsuleColliders.append(CapsuleCollider(p0: worldP0, p1: worldP1, radius: radius, groupIndex: groupIndex))

            case .insideCapsule(let offset, let radius, let tail):
                let worldOffset = worldRotation * offset
                let worldTail = worldRotation * tail
                let worldP0 = colliderNode.worldPosition + worldOffset
                let worldP1 = worldP0 + worldTail
                capsuleColliders.append(CapsuleCollider(p0: worldP0, p1: worldP1, radius: radius, groupIndex: groupIndex, inside: true))

            case .plane(let offset, let normal):
                let worldOffset = worldRotation * offset
                let worldNormal = worldRotation * normal
                let worldPoint = colliderNode.worldPosition + worldOffset
                let normalizedNormal = simd_length(worldNormal) > 0.001 ? simd_normalize(worldNormal) : SIMD3<Float>(0, 1, 0)
                planeColliders.append(PlaneCollider(point: worldPoint, normal: normalizedNormal, groupIndex: groupIndex))
            }
        }

        // Append synthetic colliders (issue #309) via the shared helper. They
        // live in the reserved synthetic group so every spring collides with them.
        appendSyntheticColliders(
            springBone.syntheticColliders, model: model, groupIndex: syntheticGroupIndex,
            spheres: &sphereColliders, capsules: &capsuleColliders)

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
                // Every joint contributes exactly one entry so the count
                // matches numBones — otherwise SpringBoneBuffers.updateBindDirections
                // rejects the update and the GPU buffer stays uninitialised.
                guard boneIdx < boneBindDirections.count else { break }
                defer { boneIdx += 1 }

                let localDir = boneBindDirections[boneIdx]
                if let jointNode = model.nodes[safe: joint.node],
                   let nodeParent = jointNode.parent {
                    let parentRot = extractRotation(from: nodeParent.worldMatrix)
                    let worldDir = simd_act(parentRot, localDir)
                    initialWorldBindDirections.append(simd_normalize(worldDir))
                } else {
                    // Missing node or chain root: fall back to the bone's
                    // own local direction (already a sensible non-zero unit
                    // vector populated by the first pass).
                    initialWorldBindDirections.append(localDir)
                }
            }
        }
        buffers.updateBindDirections(initialWorldBindDirections)

        // Also initialize the interpolation targets with the same world directions
        targetWorldBindDirections = initialWorldBindDirections
        previousWorldBindDirections = initialWorldBindDirections

        // Store CPU-side copies for physics reset
        cpuRestLengths = restLengths
        cpuParentIndices = parentIndices

        // cpuRestLengths is immutable after setup, so the scale derived from
        // it is constant for the model's lifetime — compute once here.
        cachedModelScale = calculateModelScaleFromRestLengths()

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

        #if VRM_METALKIT_ENABLE_DEBUG_PHYSICS
        print("[SpringBone DEBUG] === Spring Bone Setup ===")
        var debugBoneIndex = 0
        for (springIndex, spring) in springBone.springs.enumerated() {
            let springName = spring.name ?? ""
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
        #endif

        // Initialize buffers for root bone kinematic updates
        let numRootBones = rootBoneIndices.count
        if numRootBones > 0 {
            let singleStepLength = MemoryLayout<SIMD3<Float>>.stride * numRootBones
            // Round up to nearest 256 bytes for Metal offset alignment requirements
            let alignment = 256
            let alignedStepLength = (singleStepLength + alignment - 1) & ~(alignment - 1)
            
            let maxSubsteps = VRMConstants.Physics.maxSubstepsPerFrame
            let positionsLength = alignedStepLength * maxSubsteps
            
            animatedRootPositionsBuffer = device.makeBuffer(length: positionsLength,
                                                           options: [.storageModeShared])
            // Mirror buffer holding the previous frame's animated positions —
            // copied from animatedRootPositionsBuffer at frame boundaries (see
            // update()). The kinematic kernel reads previousPos from here so
            // velocity history isn't tied to bonePosCurr.
            animatedRootPositionsPrevBuffer = device.makeBuffer(length: singleStepLength,
                                                                options: [.storageModeShared])
            rootBoneIndicesBuffer = device.makeBuffer(bytes: rootBoneIndices,
                                                     length: MemoryLayout<UInt32>.stride * numRootBones,
                                                     options: [.storageModeShared])
            var numRootBonesUInt = UInt32(numRootBones)
            numRootBonesBuffer = device.makeBuffer(bytes: &numRootBonesUInt,
                                                  length: MemoryLayout<UInt32>.stride,
                                                  options: [.storageModeShared])
            
            // Seed the initial root positions to prevent first-frame phantom inertia
            var initialRootPositions: [SIMD3<Float>] = []
            for rootIdx in rootBoneIndices {
                if Int(rootIdx) < initialPositions.count {
                    initialRootPositions.append(initialPositions[Int(rootIdx)])
                }
            }
            if !initialRootPositions.isEmpty {
                animatedRootPositionsBuffer?.contents().copyMemory(from: initialRootPositions, byteCount: singleStepLength)
                animatedRootPositionsPrevBuffer?.contents().copyMemory(from: initialRootPositions, byteCount: singleStepLength)
            }
        }

        // Build center-spring records so update() can apply center-frame deltas.
        centerSpringRecords.removeAll(keepingCapacity: true)
        previousCenterWorldMatrices.removeAll(keepingCapacity: true)
        targetCenterWorldMatrices.removeAll(keepingCapacity: true)
        var centerBoneIdx = 0
        for spring in springBone.springs {
            let count = spring.joints.count
            if let centerIndex = spring.center {
                centerSpringRecords.append(CenterSpringRecord(
                    centerNodeIndex: centerIndex,
                    boneStart: centerBoneIdx,
                    boneCount: count
                ))
                if let centerNode = model.nodes[safe: centerIndex] {
                    previousCenterWorldMatrices[centerIndex] = centerNode.worldMatrix
                }
            }
            centerBoneIdx += count
        }

        // Allocate the GPU center-delta buffer sized for `maxSubsteps ×
        // numCenterRecords` entries so the host can pre-fill all
        // per-substep deltas at the top of `update()` and each substep's
        // dispatch reads its slice at a fixed offset (VMK#295).
        let numRecords = centerSpringRecords.count
        if numRecords > 0 {
            let maxSubsteps = VRMConstants.Physics.maxSubstepsPerFrame
            let stride = MemoryLayout<CenterDeltaRecordGPU>.stride
            let totalBytes = stride * numRecords * maxSubsteps
            centerDeltaBuffer = device.makeBuffer(length: totalBytes,
                                                   options: [.storageModeShared])
        } else {
            centerDeltaBuffer = nil
        }

        snapshotLock.lock()
        latestPositionsSnapshot.removeAll(keepingCapacity: true)
        latestCompletedFrame = 0
        lastAppliedFrame = 0
        snapshotLock.unlock()
    }

    private func updateAnimatedPositions(model: VRMModel, buffers: SpringBoneBuffers, substepIndex: Int = 0) {
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

        // Copy to GPU buffer at the correct aligned offset for this substep
        if animatedPositions.count > 0 {
            assert(substepIndex < VRMConstants.Physics.maxSubstepsPerFrame, "substepIndex \(substepIndex) exceeds max allocated capacity")
            let singleStepLength = MemoryLayout<SIMD3<Float>>.stride * animatedPositions.count
            let byteOffset = substepIndex * alignedStepLength
            
            let dest = animatedRootPositionsBuffer.contents().advanced(by: byteOffset)
            dest.copyMemory(
                from: animatedPositions,
                byteCount: singleStepLength
            )
        }

        // Build collider-to-group index mapping for animated updates.
        // Clamp to 31 so the shader's `1u << groupIndex` is well-defined.
        var colliderToGroupIndex: [Int: UInt32] = [:]
        for (groupIndex, group) in springBone.colliderGroups.enumerated() {
            for colliderIndex in group.colliders {
                if colliderToGroupIndex[colliderIndex] == nil {
                    colliderToGroupIndex[colliderIndex] = UInt32(min(groupIndex, 31))
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

            #if VRM_METALKIT_ENABLE_DEBUG_PHYSICS
            if updateCounter < 5 {
                print("[Collider \(colliderIndex)] node=\(collider.node) '\(colliderNode.name ?? "")' nodePos=(\(String(format: "%.3f", colliderNode.worldPosition.x)), \(String(format: "%.3f", colliderNode.worldPosition.y)), \(String(format: "%.3f", colliderNode.worldPosition.z)))")
            }
            #endif

            switch collider.shape {
            case .sphere(let offset, let radius):
                let worldOffset = worldRotation * offset
                let worldCenter = colliderNode.worldPosition + worldOffset
                #if VRM_METALKIT_ENABLE_DEBUG_PHYSICS
                if updateCounter < 5 {
                    print("  localOffset=(\(String(format: "%.3f", offset.x)), \(String(format: "%.3f", offset.y)), \(String(format: "%.3f", offset.z))) -> worldOffset=(\(String(format: "%.3f", worldOffset.x)), \(String(format: "%.3f", worldOffset.y)), \(String(format: "%.3f", worldOffset.z))) -> center=(\(String(format: "%.3f", worldCenter.x)), \(String(format: "%.3f", worldCenter.y)), \(String(format: "%.3f", worldCenter.z)))")
                }
                #endif
                sphereColliders.append(SphereCollider(center: worldCenter, radius: radius, groupIndex: groupIndex))

            case .insideSphere(let offset, let radius):
                let worldOffset = worldRotation * offset
                let worldCenter = colliderNode.worldPosition + worldOffset
                sphereColliders.append(SphereCollider(center: worldCenter, radius: radius, groupIndex: groupIndex, inside: true))

            case .capsule(let offset, let radius, let tail):
                let worldOffset = worldRotation * offset
                let worldTail = worldRotation * tail
                let worldP0 = colliderNode.worldPosition + worldOffset
                let worldP1 = worldP0 + worldTail
                capsuleColliders.append(CapsuleCollider(p0: worldP0, p1: worldP1, radius: radius, groupIndex: groupIndex))

            case .insideCapsule(let offset, let radius, let tail):
                let worldOffset = worldRotation * offset
                let worldTail = worldRotation * tail
                let worldP0 = colliderNode.worldPosition + worldOffset
                let worldP1 = worldP0 + worldTail
                capsuleColliders.append(CapsuleCollider(p0: worldP0, p1: worldP1, radius: radius, groupIndex: groupIndex, inside: true))

            case .plane(let offset, let normal):
                let worldOffset = worldRotation * offset
                let worldNormal = worldRotation * normal
                let worldPoint = colliderNode.worldPosition + worldOffset
                let normalizedNormal = simd_length(worldNormal) > 0.001 ? simd_normalize(worldNormal) : SIMD3<Float>(0, 1, 0)
                planeColliders.append(PlaneCollider(point: worldPoint, normal: normalizedNormal, groupIndex: groupIndex))
            }
        }

        // Append synthetic colliders (issue #309) via the shared helper.
        let syntheticGroupIndex = UInt32(min(springBone.colliderGroups.count, 31))
        appendSyntheticColliders(
            springBone.syntheticColliders, model: model, groupIndex: syntheticGroupIndex,
            spheres: &sphereColliders, capsules: &capsuleColliders)

        #if VRM_METALKIT_ENABLE_DEBUG_PHYSICS
        if updateCounter % 600 == 1 && !sphereColliders.isEmpty {
            print("[SpringBone DEBUG] === Animated Collider Positions (frame \(updateCounter)) ===")
            for (i, sphere) in sphereColliders.enumerated() {
                print("  Sphere \(i): center=(\(String(format: "%.3f", sphere.center.x)), \(String(format: "%.3f", sphere.center.y)), \(String(format: "%.3f", sphere.center.z))) group=\(sphere.groupIndex)")
            }
        }
        #endif

        // Apply runtime radius overrides (e.g., for hair clipping prevention)
        for (index, overrideRadius) in sphereColliderRadiusOverrides {
            if index < sphereColliders.count {
                sphereColliders[index].radius = overrideRadius
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

    private func captureCompletedPositions(bonePosCurr: MTLBuffer?, numBones: Int, frameID: UInt64) {
        guard let bonePosCurr = bonePosCurr, numBones > 0 else {
            return
        }

        let sourcePointer = bonePosCurr.contents().bindMemory(to: SIMD3<Float>.self, capacity: numBones)

        snapshotLock.lock()
        if latestPositionsSnapshot.count != numBones {
            latestPositionsSnapshot = Array(repeating: SIMD3<Float>(repeating: 0), count: numBones)
        }

        latestPositionsSnapshot.withUnsafeMutableBufferPointer { destination in
            guard let dst = destination.baseAddress else { return }
            dst.update(from: sourcePointer, count: numBones)
        }

        // NaN safety: filter out corrupted positions and replace with safe fallback
        // This prevents NaN from propagating to writeBonesToNodes
        var nanCount = 0
        for i in 0..<numBones {
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

        // Map bone index to spring/joint for node updates. Reuse a single
        // nodePositions buffer across all springs instead of allocating per
        // spring per frame; springs typically hold 5-30 joints.
        var globalBoneIndex = 0
        chainNodePositions.reserveCapacity(32)
        for spring in springBone.springs {
            guard globalBoneIndex < positions.count else { break }

            chainNodePositions.removeAll(keepingCapacity: true)
            for joint in spring.joints {
                // Every joint occupies one slot in the GPU positions array,
                // including joints whose node is missing. Advance the global
                // index unconditionally so downstream joints stay aligned with
                // their physics outputs.
                guard globalBoneIndex < positions.count else { break }
                defer { globalBoneIndex += 1 }
                guard let node = model.nodes[safe: joint.node] else { continue }
                chainNodePositions.append((node, positions[globalBoneIndex], globalBoneIndex))
            }

            // Update node transforms based on GPU-computed positions
            if chainNodePositions.count >= 2 {
                updateNodeTransformsForChain(nodePositions: chainNodePositions)
            }
        }
    }

    #if VRM_METALKIT_ENABLE_DEBUG_PHYSICS
    private var rotationDiagCounter = 0
    #endif

    private func updateNodeTransformsForChain(nodePositions: [(VRMNode, SIMD3<Float>, Int)]) {
        #if VRM_METALKIT_ENABLE_DEBUG_PHYSICS
        rotationDiagCounter += 1
        let shouldLog = rotationDiagCounter <= 5 || rotationDiagCounter % 60 == 0
        #endif

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

            #if VRM_METALKIT_ENABLE_DEBUG_PHYSICS
            if shouldLog && i == 0 {
                let newAngle = 2.0 * acos(min(abs(newRotation.real), 1.0)) * 180.0 / Float.pi
                print("[ROTATION \(rotationDiagCounter)] bone=\(globalIndex) dot=\(String(format: "%.4f", dotProduct)) disp=\(String(format: "%.4f", displacement)) weight=\(String(format: "%.2f", physicsWeight))")
                print("  newRotAngle=\(String(format: "%.2f", newAngle))° atRest=\(dotProduct > 0.9998) sleeping=\(physicsWeight < 0.001)")
            }
            #endif

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
        targetRootPositions.removeAll(keepingCapacity: true)
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
    }

    /// Captures world-space bind directions based on current animated parent orientations
    private func captureTargetWorldBindDirections(model: VRMModel, springBone: VRMSpringBone) {
        targetWorldBindDirections.removeAll(keepingCapacity: true)

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
        // Build collider-to-group index mapping. Clamp to 31 so the shader's
        // `1u << groupIndex` is well-defined (UB at >=32).
        var colliderToGroupIndex: [Int: UInt32] = [:]
        for (groupIndex, group) in springBone.colliderGroups.enumerated() {
            for colliderIndex in group.colliders {
                if colliderToGroupIndex[colliderIndex] == nil {
                    colliderToGroupIndex[colliderIndex] = UInt32(min(groupIndex, 31))
                }
            }
        }

        targetSphereColliders.removeAll(keepingCapacity: true)
        targetCapsuleColliders.removeAll(keepingCapacity: true)
        targetPlaneColliders.removeAll(keepingCapacity: true)

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

            case .insideSphere(let offset, let radius):
                let worldOffset = worldRotation * offset
                let worldCenter = colliderNode.worldPosition + worldOffset
                targetSphereColliders.append(SphereCollider(center: worldCenter, radius: radius, groupIndex: groupIndex, inside: true))

            case .capsule(let offset, let radius, let tail):
                let worldOffset = worldRotation * offset
                let worldTail = worldRotation * tail
                let worldP0 = colliderNode.worldPosition + worldOffset
                let worldP1 = worldP0 + worldTail
                targetCapsuleColliders.append(CapsuleCollider(p0: worldP0, p1: worldP1, radius: radius, groupIndex: groupIndex))

            case .insideCapsule(let offset, let radius, let tail):
                let worldOffset = worldRotation * offset
                let worldTail = worldRotation * tail
                let worldP0 = colliderNode.worldPosition + worldOffset
                let worldP1 = worldP0 + worldTail
                targetCapsuleColliders.append(CapsuleCollider(p0: worldP0, p1: worldP1, radius: radius, groupIndex: groupIndex, inside: true))

            case .plane(let offset, let normal):
                let worldOffset = worldRotation * offset
                let worldNormal = worldRotation * normal
                let worldPoint = colliderNode.worldPosition + worldOffset
                let normalizedNormal = simd_length(worldNormal) > 0.001 ? simd_normalize(worldNormal) : SIMD3<Float>(0, 1, 0)
                targetPlaneColliders.append(PlaneCollider(point: worldPoint, normal: normalizedNormal, groupIndex: groupIndex))
            }
        }

        // Append synthetic colliders (issue #309) via the shared helper.
        let syntheticGroupIndex = UInt32(min(springBone.colliderGroups.count, 31))
        appendSyntheticColliders(
            springBone.syntheticColliders, model: model, groupIndex: syntheticGroupIndex,
            spheres: &targetSphereColliders, capsules: &targetCapsuleColliders)

        // Apply runtime radius overrides (e.g., for hair clipping prevention)
        for (index, overrideRadius) in sphereColliderRadiusOverrides {
            if index < targetSphereColliders.count {
                targetSphereColliders[index].radius = overrideRadius
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
    /// - Parameters:
    ///   - t: Interpolation factor [0, 1] where 0 = previous frame, 1 = current frame target
    ///   - buffers: The spring bone buffers holding the GPU structures
    ///   - substepIndex: Current substep index of the frame
    private func interpolateAllTransforms(t: Float, buffers: SpringBoneBuffers, substepIndex: Int) {
        interpolateRootPositions(t: t, substepIndex: substepIndex)
        interpolateWorldBindDirections(t: t, buffers: buffers)
        interpolateColliders(t: t, buffers: buffers)
    }

    /// Interpolates root positions for the current substep
    private func interpolateRootPositions(t: Float, substepIndex: Int) {
        guard previousRootPositions.count == targetRootPositions.count,
              let buffer = animatedRootPositionsBuffer,
              !previousRootPositions.isEmpty else { return }

        assert(substepIndex < VRMConstants.Physics.maxSubstepsPerFrame, "substepIndex \(substepIndex) exceeds max allocated capacity")
        let byteOffset = substepIndex * alignedStepLength
        
        let dest = buffer.contents().advanced(by: byteOffset)
        let ptr = dest.bindMemory(to: SIMD3<Float>.self, capacity: previousRootPositions.count)
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
                    groupIndex: target.groupIndex,
                    inside: target.inside != 0
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
                    groupIndex: target.groupIndex,
                    inside: target.inside != 0
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

    /// Stores current target transforms as previous for next frame's interpolation.
    /// Uses swap instead of assignment so both arrays retain their backing storage
    /// across frames; the next capture overwrites in place via removeAll+append.
    private func commitAllTransforms() {
        swap(&previousRootPositions, &targetRootPositions)
        swap(&previousWorldBindDirections, &targetWorldBindDirections)
        swap(&previousSphereColliders, &targetSphereColliders)
        swap(&previousCapsuleColliders, &targetCapsuleColliders)
        swap(&previousPlaneColliders, &targetPlaneColliders)
    }

    // MARK: - Center-space Simulation Helpers

    /// Snapshots each center node's current `worldMatrix` into
    /// `targetCenterWorldMatrices` at the top of the frame, before the
    /// substep loop. Together with `previousCenterWorldMatrices` this
    /// gives `fillCenterDeltaBufferForFrame` the endpoint matrices it
    /// interpolates between to compute per-substep incremental deltas.
    private func captureTargetCenterWorldMatrices(model: VRMModel) {
        for record in centerSpringRecords {
            if let centerNode = model.nodes[safe: record.centerNodeIndex] {
                targetCenterWorldMatrices[record.centerNodeIndex] = centerNode.worldMatrix
            }
        }
    }

    /// Pre-computes every substep's incremental center-frame delta and
    /// packs them into `centerDeltaBuffer` for the GPU kernel. Layout is
    /// `[substep0_record0, substep0_record1, ..., substepN_recordM]`;
    /// each substep's slice has byte offset
    /// `substepIndex × numRecords × stride`.
    ///
    /// Per-substep delta: linearly interpolate `prev → target` to get
    /// the center's pose at `tPrev = i/N` and `tCurr = (i+1)/N`, then
    /// `delta = centerAt(tCurr) × inverse(centerAt(tPrev))`. Summed
    /// across substeps the kernel produces the same cumulative motion
    /// as the previous single-shot approach (`target × prev⁻¹` at
    /// `tCurr=1`), but the per-substep apply runs in GPU order in the
    /// same command buffer as the kinematic/predict/distance kernels,
    /// so the chain layout stays consistent across each substep.
    ///
    /// Linear matrix interpolation is exact for pure translation (the
    /// common locomotion case). For rotation it introduces per-substep
    /// non-orthonormality on the order of `θ²/8`, negligible at the
    /// typical 1/120 s substep cadence.
    private func fillCenterDeltaBufferForFrame(substepCount: Int) {
        guard !centerSpringRecords.isEmpty,
              let buffer = centerDeltaBuffer else { return }

        let stride = MemoryLayout<CenterDeltaRecordGPU>.stride
        let numRecords = centerSpringRecords.count
        let ptr = buffer.contents().bindMemory(
            to: CenterDeltaRecordGPU.self,
            capacity: numRecords * VRMConstants.Physics.maxSubstepsPerFrame
        )

        for s in 0..<substepCount {
            let tPrev = Float(s) / Float(substepCount)
            let tCurr = Float(s + 1) / Float(substepCount)
            for (i, record) in centerSpringRecords.enumerated() {
                guard let prevMatrix = previousCenterWorldMatrices[record.centerNodeIndex],
                      let targetMatrix = targetCenterWorldMatrices[record.centerNodeIndex] else {
                    // Center node missing — write identity so the kernel
                    // becomes a no-op for this entry.
                    let slot = s * numRecords + i
                    ptr[slot] = CenterDeltaRecordGPU(
                        boneStart: UInt32(record.boneStart),
                        boneCount: UInt32(record.boneCount),
                        delta: matrix_identity_float4x4
                    )
                    continue
                }
                let centerAtPrev = mixMatrices(prevMatrix, targetMatrix, tPrev)
                let centerAtCurr = mixMatrices(prevMatrix, targetMatrix, tCurr)
                let delta = centerAtCurr * centerAtPrev.inverse
                let slot = s * numRecords + i
                ptr[slot] = CenterDeltaRecordGPU(
                    boneStart: UInt32(record.boneStart),
                    boneCount: UInt32(record.boneCount),
                    delta: delta
                )
            }
        }
        _ = stride  // silence unused if optimizer drops it
    }

    /// Component-wise linear interpolation of two 4×4 matrices. Exact
    /// for translation; first-order for rotation.
    private func mixMatrices(_ a: float4x4, _ b: float4x4, _ t: Float) -> float4x4 {
        float4x4(
            mix(a.columns.0, b.columns.0, t: t),
            mix(a.columns.1, b.columns.1, t: t),
            mix(a.columns.2, b.columns.2, t: t),
            mix(a.columns.3, b.columns.3, t: t)
        )
    }

    /// Records the current frame's center node world matrices for use next frame.
    private func commitCenterWorldMatrices(model: VRMModel) {
        for record in centerSpringRecords {
            if let centerNode = model.nodes[safe: record.centerNodeIndex] {
                previousCenterWorldMatrices[record.centerNodeIndex] = centerNode.worldMatrix
            }
        }
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

        // Process bones in order (parents before children due to chain structure).
        // Seed each child along its **authored bind direction in world space**
        // rather than a hardcoded world `-Y`. The previous behavior teleported
        // every chain joint to "hang straight down from parent," which on
        // assets that author `gravityPower = 0` (e.g. AvatarSample_A_1.0's
        // `Bust`, `Hair`, `Hood`) leaves the chains stuck in the world-down
        // seed pose rather than the asset's intended rest pose. The integrator
        // respects `gravityPower = 0`; the kinematic seed has to match it
        // (vrm-conformance VMK#233).
        //
        // Use `targetWorldBindDirections` (the same buffer the GPU stiffness
        // target reads — see `SpringBonePredict.metal:185-201` and
        // `captureTargetWorldBindDirections` above), NOT the raw CPU-side
        // `boneBindDirections`. The CPU array holds *parent-local* directions;
        // using it as if it were world space introduces a rotation error equal
        // to the parent's bind-time world rotation, which leaves the seed in a
        // wrong world position. The stiffness target then pulls back to the
        // *correct* world position, producing visibly erratic settling on any
        // chain whose parent rotation isn't identity at bind (every real
        // humanoid asset). The world-transformed slot matches the stiffness
        // target so seed and target converge to the same position.
        //
        // Indexing: `targetWorldBindDirections[N]` follows the same convention
        // as `boneBindDirections[N]` — direction from bone N to bone N+1
        // (current→child) — so the direction from parent to current bone is at
        // `targetWorldBindDirections[parentIdx]`. The issue body's `[i]` is
        // off-by-one; the semantically correct substitution is `[parentIdx]`,
        // matching the shader's existing usage.
        //
        // For procedural spring-bone test corpora (vertical chains with
        // authored bind = (0, -1, 0) and identity parent rotations) this is
        // a no-op against the previous hardcoded gravity seed.
        for i in 0..<buffers.numBones {
            let parentIdx = cpuParentIndices[i]

            if parentIdx < 0 {
                // Root bone - use animated position
                kinematicPositions[i] = rootPositionMap[i] ?? .zero
            } else {
                let parentPos = kinematicPositions[parentIdx]
                let restLength = cpuRestLengths[i]

                // Pull the world-space bind direction from the same buffer the
                // GPU stiffness target reads. Fall back through previousWorld
                // (last frame's value, also world-space) and finally world `-Y`
                // so a setup race never produces NaN seed positions.
                let seedDir: SIMD3<Float>
                if parentIdx < targetWorldBindDirections.count {
                    let d = targetWorldBindDirections[parentIdx]
                    let len = simd_length(d)
                    seedDir = len > 0.001 ? d / len : SIMD3<Float>(0, -1, 0)
                } else if parentIdx < previousWorldBindDirections.count {
                    let d = previousWorldBindDirections[parentIdx]
                    let len = simd_length(d)
                    seedDir = len > 0.001 ? d / len : SIMD3<Float>(0, -1, 0)
                } else {
                    seedDir = SIMD3<Float>(0, -1, 0)
                }
                kinematicPositions[i] = parentPos + seedDir * restLength
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

        // NOTE: Do NOT reset settlingFrames here - that's only for initial load
        // The reset already kills velocity by setting prev=curr, which is sufficient
        // Re-triggering settling would reduce stiffness/drag and cause extended jiggle

        // Reset readback state
        snapshotLock.lock()
        latestPositionsSnapshot.removeAll(keepingCapacity: true)
        latestCompletedFrame = 0
        lastAppliedFrame = 0
        snapshotLock.unlock()
    }

    // MARK: - Physics Warmup (Initial Load Stabilization)

    /// Warms up the physics system to prevent initial bounce/oscillation.
    ///
    /// This should be called after loading the model and before the first render frame.
    /// It forces bone positions to match the current animated pose with zero velocity,
    /// then runs silent physics steps to let the system settle.
    ///
    /// - Parameters:
    ///   - model: The VRM model to warm up
    ///   - steps: Number of physics steps to run silently (default: 30, ~0.5s at 60fps)
    func warmupPhysics(model: VRMModel, steps: Int = 30) {
        guard let buffers = model.springBoneBuffers,
              var globalParams = model.springBoneGlobalParams,
              buffers.numBones > 0 else {
            return
        }

        // Step 1: Capture current animated positions for root bones
        guard let springBone = model.springBone else { return }

        var animatedPositions: [SIMD3<Float>] = []
        for spring in springBone.springs {
            if let firstJoint = spring.joints.first,
               let node = model.nodes[safe: firstJoint.node] {
                animatedPositions.append(node.worldPosition)
            }
        }

        // Step 2: Reset physics state to current animated positions (zeros velocity)
        resetPhysicsState(model: model, buffers: buffers, animatedPositions: animatedPositions)

        // Step 3: Also reset interpolation state to match
        resetInterpolationState()

        // Step 4: Run silent physics steps to let bones settle into natural hanging positions.
        // This happens BEFORE the first render, so there's no visual bounce.
        //
        // Decrement `settlingFrames` per step so the warmup *consumes* the
        // settling period. Previously the counter only decremented during
        // the animated update path, which meant short post-warmup animations
        // (e.g. a 0.25 s swing) ran with `settlingFrames` still >60 — the
        // `1 - smoothstep(0, 60, frames)` scale zeroed every joint's
        // stiffness and the conformance harness saw all stiffness sweep
        // values collapse to the same gravity-only trajectory (VMK#240).
        // Warmup is exactly when settling *should* finish: the bones are
        // explicitly being settled to their hanging pose.
        let warmupDeltaTime: TimeInterval = 1.0 / 60.0  // Simulate at 60fps
        for _ in 0..<steps {
            // Update animated positions (colliders, bind directions, etc.)
            updateAnimatedPositions(model: model, buffers: buffers, substepIndex: 0)

            // Run one physics step
            var params = globalParams
            params.windPhase += Float(warmupDeltaTime)
            if params.settlingFrames > 0 {
                params.settlingFrames -= 1
                model.springBoneGlobalParams?.settlingFrames = params.settlingFrames
                globalParams.settlingFrames = params.settlingFrames
            }

            // Copy params to GPU
            globalParamsBuffer?.contents().copyMemory(from: &params, byteCount: MemoryLayout<SpringBoneGlobalParams>.stride)

            // Execute XPBD pipeline
            executeXPBDStep(buffers: buffers, globalParams: params, substepIndex: 0)
        }

        // VMK#292 (regression of VMK#240): force `settlingFrames` to 0 at
        // the end of warmup so the post-warmup animation runs with the
        // stiffness contribution fully engaged. Per-step decrement above
        // only drains by `steps`; with the default `steps = 30` against
        // an initial counter of 120 the loop leaves `settlingFrames = 90`,
        // and a typical 0.25 s swing decrements another 30 (1/60-s frames
        // at the 1/120-s fixed substep). That puts the swing inside the
        // `1 - smoothstep(0, 60, frames)` band where stiffness is scaled
        // to ~0 — the entire stiffness sweep collapses to the rest
        // trajectory. Warmup is exactly when settling *should* finish,
        // so close the gap unconditionally.
        if globalParams.settlingFrames > 0 {
            globalParams.settlingFrames = 0
            model.springBoneGlobalParams?.settlingFrames = 0
            globalParamsBuffer?.contents().copyMemory(
                from: &globalParams,
                byteCount: MemoryLayout<SpringBoneGlobalParams>.stride
            )
        }

        // Wait for all GPU work to complete before proceeding
        // This ensures warmup physics is fully computed before first render
        if let finalCommandBuffer = commandQueue.makeCommandBuffer() {
            finalCommandBuffer.commit()
            finalCommandBuffer.waitUntilCompleted()
        }

        // Step 5: Final reset to zero velocity at settled positions
        // Read back the settled positions and use them as the new "rest" state
        var settledPositions: [SIMD3<Float>] = []
        if let bonePosCurr = buffers.bonePosCurr,
           let bonePosPrev = buffers.bonePosPrev {
            let currPtr = bonePosCurr.contents().bindMemory(to: SIMD3<Float>.self, capacity: buffers.numBones)
            let prevPtr = bonePosPrev.contents().bindMemory(to: SIMD3<Float>.self, capacity: buffers.numBones)

            // Set prev = curr to eliminate any residual velocity
            settledPositions.reserveCapacity(buffers.numBones)
            for i in 0..<buffers.numBones {
                prevPtr[i] = currPtr[i]
                settledPositions.append(currPtr[i])
            }
        }

        // VMK#233: Apply settled positions to nodes so the first render frame
        // shows the settled state, not the load-time rest pose. Without this,
        // writeBonesToNodes() skips on frame 1 because the async snapshot
        // hasn't completed yet, causing a one-frame lag.
        //
        // Skip the apply when every joint in the model has gravityPower == 0
        // and there are no external forces during warmup (wind/characterVelocity
        // are zero by construction here). In that case the integrator produces
        // no movement and applying the snapshot only introduces a tiny readback
        // divergence vs three-vrm's full-reload reset path on broken assets
        // like AvatarSample_A_1.0 where authors set gravityPower=0 throughout.
        if !settledPositions.isEmpty {
            var anyGravity = false
            outer: for spring in springBone.springs {
                for joint in spring.joints {
                    let jointName = model.nodes[safe: joint.node]?.name
                    let effective = springBoneOverride.apply(
                        stiffness: joint.stiffness,
                        dragForce: joint.dragForce,
                        gravityPower: joint.gravityPower,
                        jointName: jointName
                    )
                    if effective.gravityPower > 0 {
                        anyGravity = true
                        break outer
                    }
                }
            }
            if anyGravity {
                snapshotLock.lock()
                latestPositionsSnapshot = settledPositions
                latestCompletedFrame = 1
                lastAppliedFrame = 0
                snapshotLock.unlock()
                writeBonesToNodes(model: model)
            }
        }

        // Reset time accumulator
        timeAccumulator = 0

        vrmLog("[SpringBone] Physics warmup complete (\(steps) steps)")
    }
}

enum SpringBoneError: Error {
    case failedToLoadShaders
    case invalidBoneData
    case bufferAllocationFailed
}
