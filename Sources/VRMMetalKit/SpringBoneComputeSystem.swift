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
import Synchronization

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
    var supportsNonUniformThreadgroups: Bool

    private var kinematicPipeline: MTLComputePipelineState?
    private var copyParentPositionsPipeline: MTLComputePipelineState?
    private var predictPipeline: MTLComputePipelineState?
    private var distancePipeline: MTLComputePipelineState?
    private var centerDeltaPipeline: MTLComputePipelineState?
    private var collideSpheresPipeline: MTLComputePipelineState?
    private var collideCapsulesPipeline: MTLComputePipelineState?
    private var collidePlanesPipeline: MTLComputePipelineState?

    /// Per-frame global params uploaded to the GPU each substep. `internal` (not
    /// `private`) so tests can inspect the actually-uploaded values (e.g. the
    /// substep `dtSub`, #316) — this is real GPU state, not a test-only shim.
    var globalParamsBuffer: MTLBuffer?
    private var animatedRootPositionsBuffer: MTLBuffer?
    /// Holds the previous frame's animated root positions so the kinematic
    /// kernel can write a clean velocity history into `bonePosPrev[root]`
    /// instead of reading from `bonePosCurr[root]` (which can be contaminated
    /// by collision pushes — Bug #4 in issue #138).
    private var animatedRootPositionsPrevBuffer: MTLBuffer?
    private var rootBoneIndicesBuffer: MTLBuffer?
    private var numRootBonesBuffer: MTLBuffer?
    private var rootBoneIndices: [UInt32] = []
    /// Collider-group index of the synthetic augmented colliders (issue #309),
    /// surfaced to the sphere-collision kernel so continuous (swept) collision
    /// (#313) is scoped to that group ONLY. Authored body colliders keep the
    /// discrete endpoint test, so stiff cloth chains are not deflected against
    /// them (see `SpringBoneCollision.metal`). Stored as the precomputed group
    /// BIT (uploaded verbatim to the shader, which ANDs it against each
    /// collider's `groupMask`): `0` = no synthetic group present → swept
    /// collision never engages.
    private var sweptColliderGroupMask: UInt32 = 0
    /// True when at least one bone participates in a skirt ring chord (#478).
    /// Gates the pre-capsule `copyParentPositions()` snapshot so non-skirted
    /// models pay zero extra dispatch overhead.
    private var hasRingNeighbors: Bool = false
    /// Connected components of non-empty chain indices coupled by skirt ring chords.
    /// Keeps ring neighbors waking and sleeping in lockstep on the async sleep path.
    private var ringChainComponents: [[Int]] = []
    /// Reserved collider-group index for cross-avatar FOREIGN colliders (design
    /// §7). Distinct from the synthetic group so foreign colliders stay OUT of
    /// the synthetic group's swept-CCD scoping (foreign contact is discrete).
    /// `colliderGroups.count + 1`, set at populate time; `0xFFFFFFFF` when the
    /// model has too many authored collider groups to safely reserve the slot
    /// (see the aliasing guard in `populateSpringBoneData`).
    private var foreignColliderGroupIndex: UInt32 = 0xFFFFFFFF
    /// Active foreign colliders written into the reserved tail THIS frame. Set by
    /// the injection sink; drives the per-frame kernel active count. Zero ⇒ the
    /// authored path is bit-identical (design §4.2, §8.1).
    var activeForeignSpheres: Int = 0
    var activeForeignCapsules: Int = 0
    /// This frame's foreign colliders, set by the coordinator each frame. The
    /// replace-or-clear contract is total over frames: every frame either
    /// replaces (non-empty) or clears (empty). Never accumulates (design §4.1).
    private var pendingForeignSnapshot: ForeignColliderSnapshot = ForeignColliderSnapshot()
    /// This frame's EXTERNAL colliders (rigid-body props, external physics), set by
    /// `setExternalColliders`. An independent second foreign source: unioned with
    /// `pendingForeignSnapshot` into the reserved tail so an avatar can feel both
    /// cross-avatar contact and props in the same frame, and props work standalone
    /// with no contact group. Same replace-or-clear contract.
    private var pendingExternalColliders: ForeignColliderSnapshot = ForeignColliderSnapshot()
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
    /// Internal (not private) so tests can see how many substeps the last frame ran.
    var frameSubstepCount: Int = 0
    private var lastFrameSubstepCount: Int = 1
    private var currentSubstepIndex: Int = 0

    /// Minimum alignment required for buffer offsets in Metal (typically 256 bytes for macOS x86/general safety)
    private static let kMetalBufferOffsetAlignment = 256
    
    /// Stride in bytes for each substep slot of `globalParamsBuffer`. The
    /// kernels bind it as `constant SpringBoneParams&`, so each slot must start
    /// on a 256-byte boundary (VMK#396).
    /// Internal (not private) so tests can locate a substep's slot.
    var globalParamsStride: Int {
        let raw = MemoryLayout<SpringBoneGlobalParams>.stride
        return (raw + Self.kMetalBufferOffsetAlignment - 1) & ~(Self.kMetalBufferOffsetAlignment - 1)
    }

    /// Stride in bytes for each substep of animated root positions, aligned to 256 bytes.
    private var alignedStepLength: Int {
        let raw = MemoryLayout<SIMD3<Float>>.stride * rootBoneIndices.count
        return (raw + Self.kMetalBufferOffsetAlignment - 1) & ~(Self.kMetalBufferOffsetAlignment - 1)
    }

    // World bind direction interpolation (prevents rotational explosions during fast turns)
    /// Internal (not private) so tests can recompute the expected per-substep
    /// interpolation and check it against the slot the GPU actually read.
    var previousWorldBindDirections: [SIMD3<Float>] = []
    var targetWorldBindDirections: [SIMD3<Float>] = []

    // Collider transform interpolation (prevents collision snapping during fast rotations)
    private var previousSphereColliders: [SphereCollider] = []
    private var targetSphereColliders: [SphereCollider] = []
    private var previousCapsuleColliders: [CapsuleCollider] = []
    private var targetCapsuleColliders: [CapsuleCollider] = []
    private var previousPlaneColliders: [PlaneCollider] = []
    private var targetPlaneColliders: [PlaneCollider] = []

    // Collider group mapping is static after load; rebuild only if the spring-bone
    // configuration changes (which is extremely rare at runtime).
    private var cachedColliderToGroupMask: [Int: UInt32]?
    private var cachedColliderGroupCount: Int = -1
    private var cachedColliderCount: Int = -1

    // Pre-resolved flat caches keyed by `VRMModel.springBoneRevision` and
    // `VRMNode.parentHierarchyRevision`. Because `VRMSpringBone` and all of its
    // nested collections/elements are value types, any mutation (including
    // same-count node reattachments, collider shape edits, or group membership
    // changes) bumps `model.springBoneRevision`; reparenting any `VRMNode` bumps
    // `VRMNode.parentHierarchyRevision`. `node.initialRotation` is checked live.
    private struct CachedBindDirEntry {
        let parent: VRMNode?
        let localBindDir: SIMD3<Float>
    }
    private struct CachedSphereEntry {
        let node: VRMNode
        let offset: SIMD3<Float>
        let radius: Float
        let groupMask: UInt32
        let inside: Bool
    }
    private struct CachedCapsuleEntry {
        let node: VRMNode
        let offset: SIMD3<Float>
        let tail: SIMD3<Float>
        let radius: Float
        let groupMask: UInt32
        let inside: Bool
    }
    private struct CachedPlaneEntry {
        let node: VRMNode
        let offset: SIMD3<Float>
        let normal: SIMD3<Float>
        let groupMask: UInt32
    }
    private struct CachedBoneInitialAxis {
        let initialRotation: simd_quatf
        let initialRotInv: simd_quatf
        let initialAxis: SIMD3<Float>
        let initialAxisNorm: SIMD3<Float>
        let isValid: Bool
    }
    private var cachedCacheModelID: ObjectIdentifier?
    private var cachedSpringBoneRevision: UInt64 = .max
    private var cachedParentHierarchyRevision: UInt64 = .max
    private var cachedRootNodes: [VRMNode] = []
    private var cachedBindDirEntries: [CachedBindDirEntry] = []
    private var cachedSphereColliders: [CachedSphereEntry] = []
    private var cachedCapsuleColliders: [CachedCapsuleEntry] = []
    private var cachedPlaneColliders: [CachedPlaneEntry] = []
    private var boneInitialAxes: [CachedBoneInitialAxis] = []

    // Reused scratch buffers for sleep/wake checks to avoid per-frame heap allocations.
    private var wakeMaskScratch: [Bool] = []
    private var wakeVelocitiesScratch: [Float] = []
    private var wakeMovedRootFlags: [Bool] = []

    // Cached model scale for scale-aware thresholds
    private var cachedModelScale: Float = 1.0

    // Reused buffer for writeBonesToNodes() chain walks; keeps capacity
    // across frames so springs don't each allocate their own tuple array.
    private var chainNodePositions: [(VRMNode, SIMD3<Float>, Int)] = []

    // MARK: - Sleep gate state
    /// Per-chain contiguous bone ranges derived from `rootBoneIndices`. Used to
    /// attribute motion to individual spring chains for per-chain sleep decisions.
    private var chainRanges: [Range<Int>] = []
    /// Per-chain collider-group masks (same bits written into `BoneParams`).
    internal private(set) var chainColliderMasks: [UInt32] = []
    /// Monotonically incremented on every layout rebuild under `snapshotLock` so
    /// in-flight async GPU completion handlers from an earlier layout are cleanly
    /// discarded even on the shared command-buffer path where `waitForPendingFrame()`
    /// is a no-op.
    internal private(set) var physicsLayoutGeneration: UInt64 = 0
    /// Currently active composed host + cosmetic SpringBone layout.
    internal private(set) var activeLayout: ComposedSpringBoneLayout?
    /// Layout last committed to GPU buffers by `populateSpringBoneData`; used by
    /// `captureDynamicRebuildSnapshot` so intermediate cache refreshes can never
    /// desynchronize snapshot capture from allocated buffers.
    private var committedLayout: ComposedSpringBoneLayout?
    /// Honest sleep/wake policy. Velocities come from completed GPU snapshots.
    private var sleepGate = SpringBoneSleepGate(chainCount: 0)
    /// Velocity threshold in units/sec below which a chain may fall asleep.
    /// Host-settable via ``VRMRenderer/springBoneSleepThreshold``. Zero disables
    /// velocity-based sleep (wake conditions still apply). Written from the
    /// renderer setter, read from `update`; not synchronized.
    var sleepThreshold: Float = 0.001
    /// Number of consecutive frames below threshold required before sleeping.
    /// Host-settable via ``VRMRenderer/springBoneSleepDelayFrames``. Same
    /// single-writer-thread contract as `sleepThreshold`.
    var sleepDelayFrames: Int = 5
    /// Number of bones currently considered asleep.
    public var sleepingBoneCount: Int { sleepGate.sleepingBoneCount }
    /// Test hook: per-chain asleep flags.
    var testChainAsleep: [Bool] { sleepGate.asleep }
    /// Test hook: runs every per-bone kernel as one dispatch per bone, in bone
    /// order, with only that bone awake. Each parent then finishes before its
    /// children start, which is an ordering a contended GPU can produce
    /// between SIMD groups of a single dispatch. Results must match the
    /// default single-dispatch path bit for bit.
    var testSerializeBoneDispatches = false
    /// Test hook: per-chain collider-group masks, same indexing as `testChainAsleep`.
    var testChainColliderMasks: [UInt32] { chainColliderMasks }
    /// Root/collider displacement from its wake anchor above which a sleeping
    /// chain is woken (`sleepThreshold` scaled by model size).
    var wakeMotionThreshold: Float {
        sleepThreshold * max(cachedModelScale, VRMConstants.Physics.minScaleForThreshold)
    }
    /// Test hook: per-chain root wake anchors, same indexing as `testChainAsleep`.
    var testRootWakeAnchors: [SIMD3<Float>] { previousRootPositionsForSleep }
    /// Test hook: authored sphere-collider wake anchors, in upload order.
    var testSphereWakeAnchors: [SphereCollider] { previousSphereCollidersForSleep }
    /// Per-bone chain index and per-chain sleep flag, bound at buffers 16/17.
    private var boneChainIndexBuffer: MTLBuffer?
    private var chainSleepBuffer: MTLBuffer?
    /// Test hook: reads the GPU-visible `chainSleepBuffer` back on the host.
    var testChainSleepBufferFlags: [UInt32] {
        guard let buffer = chainSleepBuffer else { return [] }
        let count = sleepGate.asleep.count
        guard count > 0 else { return [] }
        let pointer = buffer.contents().bindMemory(to: UInt32.self, capacity: count)
        return (0..<count).map { pointer[$0] }
    }
    /// Test hook: writes stale sleep=1 flags directly into `chainSleepBuffer`
    /// without touching CPU-side `sleepGate`, reproducing the state a prior
    /// async-path frame would have left behind — used to test that wake/warmup
    /// entry points propagate flags to the GPU buffer before kernels run.
    func testCorruptChainSleepBuffer() {
        guard let buffer = chainSleepBuffer else { return }
        let count = sleepGate.asleep.count
        guard count > 0 else { return }
        let pointer = buffer.contents().bindMemory(to: UInt32.self, capacity: count)
        for i in 0..<count { pointer[i] = 1 }
    }
    /// Wake anchors for motion detection: a sleeping chain's root, and every
    /// collider while any chain sleeps, keep the pose from when sleep began so
    /// sub-threshold motion accumulates.
    private var previousRootPositionsForSleep: [SIMD3<Float>] = []
    private var previousSphereCollidersForSleep: [SphereCollider] = []
    private var previousCapsuleCollidersForSleep: [CapsuleCollider] = []
    private var previousPlaneCollidersForSleep: [PlaneCollider] = []
    /// Previous-frame global params for wake-on-force-change detection.
    private var previousGlobalParamsForSleep: SpringBoneGlobalParams?
    private var previousQualityForSleep: VRMConstants.SpringBoneQuality?
    /// Previous-frame foreign (cross-avatar) collider set AS APPLIED (clamped to
    /// the reserved tail budget), for wake-on-foreign detection (F1). A moving or
    /// newly-appeared partner body wakes settled chains that the own-motion
    /// heuristics would otherwise leave asleep.
    private var previousForeignForSleep: ForeignColliderSnapshot = ForeignColliderSnapshot()
    /// Previous-frame external (prop) collider set AS APPLIED (clamped), for
    /// wake-on-external detection (the external-source counterpart to
    /// `previousForeignForSleep`).
    private var previousExternalForSleep: ForeignColliderSnapshot = ForeignColliderSnapshot()
    /// True when an explicit wake has been requested and not yet processed.
    private var forceWakePending: Bool = false
    /// What the last wake check saw cross the motion threshold. Drives which
    /// wake anchors `captureSleepSnapshots` refreshes after the substep loop.
    private struct WakeMotion {
        var refreshAll = false
        var roots: [Int] = []
        var spheres: [Int] = []
        var capsules: [Int] = []
        var planes: [Int] = []
        // The foreign/external sets diff as whole snapshots, not per index,
        // so their anchors carry a single moved flag each.
        var foreignMoved = false
        var externalMoved = false
    }
    private var lastWakeMotion = WakeMotion(refreshAll: true)

    // MARK: - Center-space simulation (VRMC_springBone-1.0 §5.1)
    // Each entry records the center node index, the contiguous bone-buffer range occupied
    // by that spring's joints, and the center's world matrix from the previous frame.
    // Each substep, we apply the rigid delta (prevCenter⁻¹ · currCenter) to bonePosCurr
    // and bonePosPrev for those bone indices so that joint positions "follow" the center
    // node rather than accumulating inertia from the avatar's locomotion.
    struct CenterSpringRecord {
        var centerNodeIndex: Int
        var centerNode: VRMNode?
        var centerNodeID: ObjectIdentifier?
        var boneStart: Int
        var boneCount: Int
    }
    var centerSpringRecords: [CenterSpringRecord] = []
    private var previousCenterWorldMatrices: [ObjectIdentifier: float4x4] = [:]
    /// Per-frame snapshot of each center node's *target* worldMatrix
    /// captured at the top of `update()`, consumed when the host
    /// pre-computes per-substep deltas into `centerDeltaBuffer` (VMK#295).
    private var targetCenterWorldMatrices: [ObjectIdentifier: float4x4] = [:]
    /// GPU-side per-(substep × record) center delta entries — see
    /// `springBoneApplyCenterDelta` (`SpringBoneCenterDelta.metal`). Filled
    /// once per frame at the top of `update()` and dispatched per substep
    /// in `executeXPBDStep`. Allocated lazily once `centerSpringRecords`
    /// is non-empty.
    private var centerDeltaBuffer: MTLBuffer?
    /// Reused per-frame cache of computed center deltas keyed by center node identity
    /// so springs sharing a center node (e.g. 68 springs all referencing root)
    /// invert the center matrix once per substep instead of once per spring (#222).
    private var centerDeltaScratch: [ObjectIdentifier: float4x4] = [:]

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

    /// Optional tracker used to attribute per-frame spring-bone CPU time to
    /// `springTargetCapture`, `springSubsteps`, and `springReadback`. Set by
    /// ``VRMRenderer`` each frame when a tracker is present; `nil` otherwise.
    weak var performanceTracker: PerformanceTracker?

    // Readback + synchronization (protected by snapshotLock)
    private let snapshotLock = NSLock()
    private var latestPositionsSnapshot: [SIMD3<Float>] = []
    /// Last completed `bonePosPrev` (GPU-done). Sleep velocities use this pair.
    private var latestPrevPositionsSnapshot: [SIMD3<Float>] = []
    /// Reusable destination for the most recent readback, touched only by the
    /// `writeBonesToNodes` caller. It copies `latestPositionsSnapshot` into this
    /// (reading the snapshot under `snapshotLock`) so it never holds a second
    /// reference to the producer's storage — handing one out would force a full
    /// COW copy on the completion handler's next update.
    private var writebackPositions: [SIMD3<Float>] = []
    /// Per-chain max velocities from the last completed command buffer.
    private var completedChainVelocities: [Float] = []
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
        self.commandQueue = MetalQueueFactory.makeCommandQueue(device: device)!
        self.supportsNonUniformThreadgroups = device.supportsFamily(.apple4) || device.supportsFamily(.mac2)

        // Load compute shaders from pre-compiled .metallib
        var library: MTLLibrary?

        // Attempt 1: Load from default library (if shaders were pre-compiled into app)
        library = device.makeDefaultLibrary()
        if let lib = library {
            let hasKinematic = lib.makeFunction(name: "springBoneKinematic") != nil
            let hasPredict = lib.makeFunction(name: "springBonePredict") != nil
            let hasDistance = lib.makeFunction(name: "springBoneDistance") != nil
            let hasCollide = lib.makeFunction(name: "springBoneCollideSpheres") != nil
            let hasCopyParents = lib.makeFunction(name: "springBoneCopyParentPositions") != nil

            if hasKinematic && hasPredict && hasDistance && hasCollide && hasCopyParents {
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
              let copyParentPositionsFunction = library.makeFunction(name: "springBoneCopyParentPositions"),
              let predictFunction = library.makeFunction(name: "springBonePredict"),
              let distanceFunction = library.makeFunction(name: "springBoneDistance"),
              let collideSpheresFunction = library.makeFunction(name: "springBoneCollideSpheres"),
              let collideCapsulesFunction = library.makeFunction(name: "springBoneCollideCapsules"),
              let collidePlanesFunction = library.makeFunction(name: "springBoneCollidePlanes"),
              let centerDeltaFunction = library.makeFunction(name: "springBoneApplyCenterDelta") else {
            vrmLog("[SpringBone] ❌ Failed to find shader functions in library")
            throw SpringBoneError.failedToLoadShaders
        }

        #if DEBUG
        let makePipeline: (any MTLFunction) throws -> any MTLComputePipelineState = { fn in
            let desc = MTLComputePipelineDescriptor()
            desc.computeFunction = fn
            desc.shaderValidation = .enabled
            return try device.makeComputePipelineState(descriptor: desc, options: [], reflection: nil)
        }
        kinematicPipeline = try makePipeline(kinematicFunction)
        copyParentPositionsPipeline = try makePipeline(copyParentPositionsFunction)
        predictPipeline = try makePipeline(predictFunction)
        distancePipeline = try makePipeline(distanceFunction)
        collideSpheresPipeline = try makePipeline(collideSpheresFunction)
        collideCapsulesPipeline = try makePipeline(collideCapsulesFunction)
        collidePlanesPipeline = try makePipeline(collidePlanesFunction)
        centerDeltaPipeline = try makePipeline(centerDeltaFunction)
        #else
        kinematicPipeline = try device.makeComputePipelineState(function: kinematicFunction)
        copyParentPositionsPipeline = try device.makeComputePipelineState(function: copyParentPositionsFunction)
        predictPipeline = try device.makeComputePipelineState(function: predictFunction)
        distancePipeline = try device.makeComputePipelineState(function: distanceFunction)
        collideSpheresPipeline = try device.makeComputePipelineState(function: collideSpheresFunction)
        collideCapsulesPipeline = try device.makeComputePipelineState(function: collideCapsulesFunction)
        collidePlanesPipeline = try device.makeComputePipelineState(function: collidePlanesFunction)
        centerDeltaPipeline = try device.makeComputePipelineState(function: centerDeltaFunction)
        #endif

        // Create global params buffer
        globalParamsBuffer = device.makeBuffer(length: globalParamsStride * VRMConstants.Physics.maxSubstepsPerFrame,
                                               options: [.storageModeShared])
        globalParamsBuffer?.label = "SpringBone GlobalParams"
    }

    private var updateCounter = 0

    /// Caller-controlled simulation quality. Drives substep rate, substep cap,
    /// and constraint-iteration count. Mirrored from `VRMRenderer.springBoneQuality`
    /// via a `didSet` on the renderer so callers only set it in one place.
    /// Defaults to `.ultra` to match the legacy global-constant behavior.
    var quality: VRMConstants.SpringBoneQuality = .ultra

    /// Sets this frame's foreign colliders. Replace-or-clear: pass an empty
    /// snapshot to clear (a departed partner leaves no ghost). Clamps to the
    /// reserved tail capacity and logs any drop — never silently truncates
    /// (design §4.1, §6).
    func setForeignColliders(_ snapshot: ForeignColliderSnapshot) {
        pendingForeignSnapshot = snapshot
    }

    /// Sets this frame's external colliders (rigid-body props, external physics).
    /// Same replace-or-clear contract as `setForeignColliders`, but an independent
    /// source: `writeForeignTail` unions this with the cross-avatar set, so props
    /// compose with a contact group rather than clobbering it (and work with no
    /// group at all). Public app entry point is `VRMRenderer.setExternalColliders`.
    func setExternalColliders(_ snapshot: ForeignColliderSnapshot) {
        pendingExternalColliders = snapshot
    }

    /// Writes the frame's foreign set into the reserved buffer tail ONCE per
    /// frame, tagged with the reserved foreign group index, and sets the active
    /// counts. Called before the substep loop; `interpolateColliders` only ever
    /// rewrites the [0, active) prefix, so the tail persists across the frame's
    /// substeps (design §4.2). `foreign`/`external` must be the clamped sets
    /// from `clampedForeignSets` — `update()` computes them once per frame so
    /// the wake check, this write, and the sleep snapshot all see the exact set
    /// that is applied.
    private func writeForeignTail(buffers: SpringBoneBuffers,
                                  foreign: ForeignColliderSnapshot,
                                  external: ForeignColliderSnapshot) {
        // No valid foreign group was reserved: `foreignColliderGroupIndex` is the
        // 0xFFFFFFFF sentinel (model has >=30 authored collider groups, so the
        // group-bit carve-out zeroed the bone-side foreign bit). Foreign colliders
        // cannot be safely tagged here — shifting `1 << foreignColliderGroupIndex`
        // on the sentinel is undefined (reduces to bit 31, aliasing an
        // authored/synthetic group). Drop them: that model simply receives no
        // cross-avatar contact, consistent with the zeroed foreign bit.
        guard foreignColliderGroupIndex != 0xFFFFFFFF else {
            activeForeignSpheres = 0
            activeForeignCapsules = 0
            return
        }
        var spheres = foreign.spheres
        spheres.append(contentsOf: external.spheres)
        var capsules = foreign.capsules
        capsules.append(contentsOf: external.capsules)

        // The tail is written once per frame while `interpolateColliders`
        // rewrites only the [0, active) prefix per substep, so the tail has to
        // land in every substep slot this frame will dispatch (VMK#396).
        //
        // Bounded to `frameSubstepCount` rather than the full slot count: the
        // substep loop dispatches exactly [0, frameSubstepCount) — the same
        // invariant `t = (currentSubstepIndex + 1) / frameSubstepCount` already
        // depends on — and this runs every frame, so slots above that are never
        // read before being rewritten. Broadcasting all 10 multiplied the tail
        // memcpy by up to 10x per frame in crowd/external-collider scenes.
        let slotsThisFrame = max(1, frameSubstepCount)
        if let buf = buffers.sphereColliders, !spheres.isEmpty {
            for slot in 0..<slotsThisFrame {
                let ptr = buf.contents().advanced(by: slot * buffers.sphereColliderStride)
                    .bindMemory(to: SphereCollider.self, capacity: buffers.sphereCapacity)
                for (i, s) in spheres.enumerated() {
                    // Re-tag the foreign group in place, preserving every other field
                    // (radius, inside, and the per-partner responseScale — subsystem 4).
                    var tagged = s
                    tagged.groupMask = 1 << foreignColliderGroupIndex
                    ptr[buffers.numSpheres + i] = tagged
                }
            }
        }
        if let buf = buffers.capsuleColliders, !capsules.isEmpty {
            for slot in 0..<slotsThisFrame {
                let ptr = buf.contents().advanced(by: slot * buffers.capsuleColliderStride)
                    .bindMemory(to: CapsuleCollider.self, capacity: buffers.capsuleCapacity)
                for (i, c) in capsules.enumerated() {
                    var tagged = c
                    tagged.groupMask = 1 << foreignColliderGroupIndex
                    ptr[buffers.numCapsules + i] = tagged
                }
            }
        }
        activeForeignSpheres = spheres.count
        activeForeignCapsules = capsules.count
    }

    /// Clamps the pending foreign/external sets to their reserved tail budgets,
    /// yielding the exact sets `writeForeignTail` applies this frame (design §6).
    /// The reserved tail carries a dedicated external (prop) budget on top of the
    /// cross-avatar crowd budget, so each source is clamped to its OWN slice — a
    /// full crowd never starves props and a flood of props never starves the
    /// crowd. Each budget is derived from the tail room so a model with no
    /// reserved tail (room == 0) clamps both sources to nothing. `update()`
    /// computes these ONCE per frame so the wake check and the sleep snapshot
    /// compare/store the APPLIED set: colliders beyond the budget must not wake
    /// a sleeping avatar they will never touch.
    private func clampedForeignSets(buffers: SpringBoneBuffers)
        -> (crowd: ForeignColliderSnapshot, external: ForeignColliderSnapshot) {
        let sphereRoom = max(buffers.sphereCapacity - buffers.numSpheres, 0)
        let capsuleRoom = max(buffers.capsuleCapacity - buffers.numCapsules, 0)
        let externalSphereBudget = min(VRMConstants.Physics.externalColliderSphereSlots, sphereRoom)
        let crowdSphereBudget = sphereRoom - externalSphereBudget
        let externalCapsuleBudget = min(VRMConstants.Physics.externalColliderCapsuleSlots, capsuleRoom)
        let crowdCapsuleBudget = capsuleRoom - externalCapsuleBudget
        return (ForeignColliderSnapshot(
                    spheres: clampForeign(pendingForeignSnapshot.spheres, to: crowdSphereBudget,
                                          label: "cross-avatar spheres"),
                    capsules: clampForeign(pendingForeignSnapshot.capsules, to: crowdCapsuleBudget,
                                           label: "cross-avatar capsules")),
                ForeignColliderSnapshot(
                    spheres: clampForeign(pendingExternalColliders.spheres, to: externalSphereBudget,
                                          label: "external spheres"),
                    capsules: clampForeign(pendingExternalColliders.capsules, to: externalCapsuleBudget,
                                           label: "external capsules")))
    }

    /// Clamps a foreign collider list to its reserved budget, logging any drop so
    /// overflow is never silent (design §6). Generic over sphere/capsule.
    private func clampForeign<T>(_ colliders: [T], to budget: Int, label: String) -> [T] {
        guard colliders.count > budget else { return colliders }
        vrmLogPhysics("⚠️ [SpringBone] Foreign \(label) \(colliders.count) exceed reserved budget \(budget); dropping \(colliders.count - budget).")
        return Array(colliders.prefix(budget))
    }

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

        // Capture all target transforms where animation wants to go this frame.
        // This is called ONCE per frame, not per substep.
        // Captures: root positions, world bind directions, collider transforms.
        // Always capture when interpolation is enabled so the sleep gate can
        // detect root/collider motion even on frames with zero substeps.
        performanceTracker?.beginPhase(.springTargetCapture)
        if VRMConstants.Physics.enableRootInterpolation {
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

        // Clamp the pending foreign/external sets to their reserved tail budgets
        // ONCE per frame: the wake check, the tail write, and the sleep snapshot
        // below all use the exact set that will be applied, so colliders beyond
        // the budget (never written) can't wake a sleeping avatar. Mirrors
        // `writeForeignTail`'s sentinel guard — with no reserved foreign group
        // the applied set is empty.
        let clampedForeign: ForeignColliderSnapshot
        let clampedExternal: ForeignColliderSnapshot
        if foreignColliderGroupIndex != 0xFFFFFFFF {
            (clampedForeign, clampedExternal) = clampedForeignSets(buffers: buffers)
        } else {
            clampedForeign = ForeignColliderSnapshot()
            clampedExternal = ForeignColliderSnapshot()
        }

        // Sleep gate: decide whether the XPBD pipeline can be skipped this frame.
        // Only enabled on the shared-command-buffer (async runtime) path; the
        // self-owned-buffer path is used for offline/conformance rendering where
        // bit-determinism matters, and reading GPU buffers on the CPU before
        // encoding each frame can perturb dispatch timing enough to break it.
        let sleepGateEnabled = commandBuffer != nil
        if sleepGateEnabled {
            snapshotLock.lock()
            if completedChainVelocities.count == chainRanges.count {
                if wakeVelocitiesScratch.count != completedChainVelocities.count {
                    wakeVelocitiesScratch = completedChainVelocities
                } else {
                    for i in 0..<completedChainVelocities.count {
                        wakeVelocitiesScratch[i] = completedChainVelocities[i]
                    }
                }
            } else {
                SpringBoneSleepGate.fillChainMaxVelocities(
                    into: &wakeVelocitiesScratch,
                    curr: [],
                    prev: [],
                    ranges: chainRanges,
                    invDt: 1
                )
            }
            snapshotLock.unlock()
            computeWakeMask(into: &wakeMaskScratch,
                            globalParams: globalParams,
                            foreign: clampedForeign,
                            external: clampedExternal)
            synchronizeRingSleepInputs()
            sleepGate.apply(velocities: wakeVelocitiesScratch,
                            wakeMask: wakeMaskScratch,
                            ranges: chainRanges,
                            threshold: sleepThreshold,
                            delay: sleepDelayFrames)
            uploadChainSleepFlags()
        } else {
            // Offline/sync path: keep everything awake and skip the heuristic
            // GPU reads used to decide sleep. The GPU-side chainSleepBuffer
            // still needs the wake propagated — a prior async-path frame on
            // this same system may have left stale sleep=1 flags there, which
            // would make every spring kernel early-out on those chains while
            // the CPU (sleepGate) believes them awake.
            wakeAllChains()
            lastWakeMotion.refreshAll = true
            lastWakeMotion.roots.removeAll(keepingCapacity: true)
            lastWakeMotion.spheres.removeAll(keepingCapacity: true)
            lastWakeMotion.capsules.removeAll(keepingCapacity: true)
            lastWakeMotion.planes.removeAll(keepingCapacity: true)
            lastWakeMotion.foreignMoved = false
            lastWakeMotion.externalMoved = false
        }

        let allChainsAsleep = sleepGateEnabled && sleepGate.allAsleep

        // Write this frame's foreign colliders into the reserved tail once. The
        // tail persists across substeps (interpolate only rewrites the prefix).
        writeForeignTail(buffers: buffers, foreign: clampedForeign, external: clampedExternal)
        performanceTracker?.endPhase(.springTargetCapture)

        var stepsThisFrame = 0

        // Process fixed steps (clamped to avoid spiral-of-death).
        // When every chain is asleep and no wake condition fired, skip the
        // substep loop entirely to avoid dispatching the XPBD pipeline.
        if allChainsAsleep {
            timeAccumulator = 0
        }

        performanceTracker?.beginPhase(.springSubsteps)
        while timeAccumulator >= fixedDeltaTime && stepsThisFrame < maxSubsteps {
            timeAccumulator -= fixedDeltaTime
            stepsThisFrame += 1

            // Update global params with current time
            var params = globalParams
            // #316: keep dtSub consistent with the active substep rate. dtSub is
            // seeded once at load to 1/120; without this, non-ultra quality
            // presets (60/90/30 Hz) run every dt-scaled term at 1/120 and
            // under-apply it. Affected (all read globalParams.dtSub): gravity,
            // wind, inertial force — AND drag (`dragFactor = 1 - drag*dtSub*60`,
            // SpringBonePredict.metal), so this is a damping/transient error too,
            // not only an equilibrium shift. The PBD stiffness blend and distance
            // constraint are dt-independent and unaffected. No-op at ultra
            // (fixedDeltaTime == 1/120), so the frozen AvatarSample_A regression
            // trajectory is preserved.
            params.dtSub = Float(fixedDeltaTime)
            params.windPhase += Float(fixedDeltaTime)

            // Per-frame kernel active count = active authored+synthetic + active
            // foreign. Zero foreign ⇒ equals the load-time value ⇒ bit-identical
            // (design §4.2). buffers.numSpheres/numCapsules is the active
            // authored+synthetic count (the reserved tail is beyond it).
            params.numSpheres = UInt32(buffers.numSpheres + activeForeignSpheres)
            params.numCapsules = UInt32(buffers.numCapsules + activeForeignCapsules)

            // Decrement settling frames counter (allows bones to settle with gravity before inertia compensation)
            if params.settlingFrames > 0 {
                params.settlingFrames -= 1
                // Persist back to model so it carries across frames
                model.springBoneGlobalParams?.settlingFrames = params.settlingFrames
            }

            // Copy updated params into THIS substep's slot. Writing a single
            // shared region would either race the in-flight previous substep
            // (self-committed path) or be overwritten before any substep runs
            // (shared-buffer path) — VMK#396.
            let currentSubstepIdx = stepsThisFrame - 1
            globalParamsBuffer?.contents()
                .advanced(by: currentSubstepIdx * globalParamsStride)
                .copyMemory(from: &params, byteCount: MemoryLayout<SpringBoneGlobalParams>.stride)

            // Interpolate ALL transforms for this substep (smooth motion instead of teleportation)
            // Includes: root positions, world bind directions, collider transforms
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
        performanceTracker?.endPhase(.springSubsteps)

        if timeAccumulator >= fixedDeltaTime {
            // We've reached the per-frame cap; carry a single substep forward to avoid runaway accumulation
            let droppedSteps = Int(timeAccumulator / fixedDeltaTime)
            timeAccumulator = min(timeAccumulator, fixedDeltaTime)
            vrmLogPhysics("⚠️ [SpringBone] Hit max substeps (\(maxSubsteps)) this frame. Dropping \(droppedSteps) pending step(s) to stay real-time.")
        }

        // Snapshot targets and params for next frame's wake-condition checks.
        // Must precede `commitAllTransforms`, which swaps the target arrays
        // with last frame's interpolation state.
        captureSleepSnapshots(model: model, globalParams: globalParams,
                              foreign: clampedForeign, external: clampedExternal)

        // Commit all target transforms as previous for next frame's interpolation.
        // Also commit when asleep so interpolation state stays current while the
        // simulation is skipped.
        if VRMConstants.Physics.enableRootInterpolation && (stepsThisFrame > 0 || allChainsAsleep) {
            commitAllTransforms()
        }

        // Update center world matrices for the next frame's delta computation.
        if stepsThisFrame > 0 || allChainsAsleep {
            commitCenterWorldMatrices(model: model)
        }

        if frameSubstepCount > 0 || allChainsAsleep {
            lastFrameSubstepCount = max(1, frameSubstepCount)
        }

        lastUpdateTime = CACurrentMediaTime()
    }

    /// Computes the number of whole threadgroups needed to cover `threadsPerGrid`.
    static func threadgroupGridSize(
        for threadsPerGrid: MTLSize,
        threadsPerThreadgroup: MTLSize
    ) -> MTLSize {
        MTLSize(
            width: (threadsPerGrid.width + threadsPerThreadgroup.width - 1) / threadsPerThreadgroup.width,
            height: (threadsPerGrid.height + threadsPerThreadgroup.height - 1) / threadsPerThreadgroup.height,
            depth: (threadsPerGrid.depth + threadsPerThreadgroup.depth - 1) / threadsPerThreadgroup.depth
        )
    }

    /// Dispatches compute work using non-uniform threadgroups when the device supports
    /// `.apple4` or `.mac2`, falling back to rounded-up whole threadgroups otherwise
    /// (e.g. on iOS/visionOS Simulator GPUs). Every SpringBone kernel guards on
    /// `id >= count`, so surplus tail lanes exit immediately.
    static func dispatchCompute(
        _ encoder: MTLComputeCommandEncoder,
        threadsPerGrid: MTLSize,
        threadsPerThreadgroup: MTLSize,
        supportsNonUniformThreadgroups: Bool
    ) {
        guard threadsPerGrid.width > 0, threadsPerGrid.height > 0, threadsPerGrid.depth > 0 else {
            return
        }
        if supportsNonUniformThreadgroups {
            encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
        } else {
            let threadgroups = threadgroupGridSize(
                for: threadsPerGrid,
                threadsPerThreadgroup: threadsPerThreadgroup
            )
            encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerThreadgroup)
        }
    }

    private func executeXPBDStep(buffers: SpringBoneBuffers,
                                  globalParams: SpringBoneGlobalParams,
                                  sharedCommandBuffer: MTLCommandBuffer? = nil,
                                  substepIndex: Int = 0,
                                  registerCompletedHandler: Bool = true) {
        guard let kinematicPipeline = kinematicPipeline,
              let copyParentPositionsPipeline = copyParentPositionsPipeline,
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
            #if DEBUG
            let cbDesc = MTLCommandBufferDescriptor()
            cbDesc.errorOptions = .encoderExecutionStatus
            guard let made = commandQueue.makeCommandBuffer(descriptor: cbDesc) else { return }
            #else
            guard let made = commandQueue.makeCommandBuffer() else { return }
            #endif
            made.label = "SpringBone Substep"
            commandBuffer = made
        }

        let numBones = buffers.numBones
        let threadgroupSize = MTLSize(width: 256, height: 1, depth: 1)
        let gridSize = MTLSize(width: numBones, height: 1, depth: 1)
        let useNonUniform = supportsNonUniformThreadgroups

        // Create compute encoder
        guard let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
            return
        }
        computeEncoder.label = "SpringBone Compute"

        let dispatch = { (grid: MTLSize) in
            Self.dispatchCompute(
                computeEncoder,
                threadsPerGrid: grid,
                threadsPerThreadgroup: threadgroupSize,
                supportsNonUniformThreadgroups: useNonUniform
            )
        }

        // Set buffers
        computeEncoder.setBuffer(boneChainIndexBuffer, offset: 0, index: 16)
        computeEncoder.setBuffer(chainSleepBuffer, offset: 0, index: 17)
        computeEncoder.setBuffer(buffers.bonePosPrev, offset: 0, index: 0)
        computeEncoder.setBuffer(buffers.bonePosCurr, offset: 0, index: 1)
        computeEncoder.setBuffer(buffers.boneParams, offset: 0, index: 2)
        computeEncoder.setBuffer(globalParamsBuffer, offset: substepIndex * globalParamsStride, index: 3)
        computeEncoder.setBuffer(buffers.restLengths, offset: 0, index: 4)
        computeEncoder.setBuffer(buffers.parentPosPrev, offset: 0, index: 18)
        computeEncoder.setBuffer(buffers.parentPosCurr, offset: 0, index: 19)
        if let collisionAux = buffers.collisionAux {
            computeEncoder.setBuffer(collisionAux, offset: 0, index: 20)
        }

        // Colliders and bindDirections are rewritten per substep, so each
        // dispatch must read its own slot (VMK#396).
        if let sphereColliders = buffers.sphereColliders, globalParams.numSpheres > 0 {
            computeEncoder.setBuffer(sphereColliders,
                                     offset: substepIndex * buffers.sphereColliderStride, index: 5)
        }

        if let capsuleColliders = buffers.capsuleColliders, globalParams.numCapsules > 0 {
            computeEncoder.setBuffer(capsuleColliders,
                                     offset: substepIndex * buffers.capsuleColliderStride, index: 6)
        }

        if let planeColliders = buffers.planeColliders, globalParams.numPlanes > 0 {
            computeEncoder.setBuffer(planeColliders, offset: 0, index: 7)
        }

        // Bind directions for stiffness spring force (return-to-bind-pose)
        // Note: When interpolation is enabled, these are DYNAMICALLY updated each substep
        // with world-space bind directions interpolated from parent bone rotations.
        // This prevents rotational snapping during fast character turns.
        if let bindDirections = buffers.bindDirections {
            computeEncoder.setBuffer(bindDirections,
                                     offset: substepIndex * buffers.bindDirectionsStride, index: 11)
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
            dispatch(rootGridSize)
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
            dispatch(recordGridSize)
            computeEncoder.memoryBarrier(scope: .buffers)
        }

        let serializeBones = testSerializeBoneDispatches
        let dispatchBones = { [boneChainIndexBuffer, chainSleepBuffer] in
            guard serializeBones else {
                dispatch(gridSize)
                computeEncoder.memoryBarrier(scope: .buffers)
                return
            }
            var boneAsOwnChain = (0..<numBones).map { UInt32($0) }
            computeEncoder.setBytes(&boneAsOwnChain, length: numBones * MemoryLayout<UInt32>.stride, index: 16)
            for bone in 0..<numBones {
                var asleep = [UInt32](repeating: 1, count: numBones)
                asleep[bone] = 0
                computeEncoder.setBytes(&asleep, length: numBones * MemoryLayout<UInt32>.stride, index: 17)
                dispatch(gridSize)
                computeEncoder.memoryBarrier(scope: .buffers)
            }
            computeEncoder.setBuffer(boneChainIndexBuffer, offset: 0, index: 16)
            computeEncoder.setBuffer(chainSleepBuffer, offset: 0, index: 17)
        }

        // Predict and distance read each joint's parent, which the parent's
        // own thread rewrites in the same dispatch. Freeze the parents first so
        // the result cannot depend on the order the GPU runs SIMD groups (#452).
        let copyParentPositions = {
            computeEncoder.setComputePipelineState(copyParentPositionsPipeline)
            dispatch(gridSize)
            computeEncoder.memoryBarrier(scope: .buffers)
        }

        // Execute predict kernel (step 1: predict new tip position)
        copyParentPositions()
        computeEncoder.setComputePipelineState(predictPipeline)
        dispatchBones()

        // Distance constraint iterations (step 2: enforce bone length)
        // VRM spec: run distance constraint BEFORE collision, do not run it after
        let iterations = quality.constraintIterations
        for _ in 0..<iterations {
            copyParentPositions()
            computeEncoder.setComputePipelineState(distancePipeline)
            dispatchBones()
        }

        // Collision resolution (step 3: push tips out of colliders)
        // VRM spec: collision runs AFTER distance constraint and is the FINAL step
        // This prevents distance constraint from pulling hair back into colliders
        if globalParams.numSpheres > 0 {
            computeEncoder.setComputePipelineState(collideSpheresPipeline)
            // Scope swept (continuous) collision to the synthetic group (#313).
            var sweptGroup = sweptColliderGroupMask
            computeEncoder.setBytes(&sweptGroup, length: MemoryLayout<UInt32>.size, index: 15)
            dispatchBones()
        }

        if globalParams.numCapsules > 0 {
            if hasRingNeighbors {
                // Freeze post-sphere positions into parentPosCurr so skirt ring
                // chord checks read an immutable snapshot with zero SIMD-group races (#452, #478).
                copyParentPositions()
            }
            computeEncoder.setComputePipelineState(collideCapsulesPipeline)
            // Scope swept (continuous) collision to the synthetic group (#313).
            var sweptGroupCaps = sweptColliderGroupMask
            computeEncoder.setBytes(&sweptGroupCaps, length: MemoryLayout<UInt32>.size, index: 15)
            dispatchBones()
        }

        if globalParams.numPlanes > 0 {
            computeEncoder.setComputePipelineState(collidePlanesPipeline)
            dispatchBones()
        }

        computeEncoder.endEncoding()

        simulationFrameCounter &+= 1
        let frameID = simulationFrameCounter

        let capturedBonePosCurr = buffers.bonePosCurr
        let capturedBonePosPrev = buffers.bonePosPrev
        let capturedNumBones = buffers.numBones
        let capturedRanges = chainRanges
        let capturedGeneration: UInt64 = {
            snapshotLock.lock()
            defer { snapshotLock.unlock() }
            return physicsLayoutGeneration
        }()

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
                        #if DEBUG
                        let nsError = error as NSError
                        if let encoderInfos = nsError.userInfo[MTLCommandBufferEncoderInfoErrorKey] as? [MTLCommandBufferEncoderInfo] {
                            for info in encoderInfos {
                                vrmLogPhysics("[SpringBone] ❌ Encoder '\(info.label)'")
                            }
                        }
                        #endif
                    }
                    return
                }

                self.captureCompletedPositions(bonePosCurr: capturedBonePosCurr,
                                               bonePosPrev: capturedBonePosPrev,
                                               numBones: capturedNumBones,
                                               frameID: frameID,
                                               generation: capturedGeneration,
                                               chainRangesSnapshot: capturedRanges)
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

    // MARK: - Sleep gate

    /// Force every spring-bone chain to wake on the next update.
    /// Callers should use this after teleporting the avatar or applying any
    /// other discontinuous change that should not be treated as rest.
    public func wakeAllBones() {
        forceWakePending = true
    }

    private func wakeAllChains() {
        forceWakePending = false
        sleepGate.wakeAll()
        uploadChainSleepFlags()
    }

    private func allocateSleepBuffers(numBones: Int, chainCount: Int) {
        boneChainIndexBuffer = nil
        chainSleepBuffer = nil
        guard numBones > 0, chainCount > 0 else { return }

        var indices = [UInt32](repeating: 0, count: numBones)
        for (chain, range) in chainRanges.enumerated() {
            for bone in range where bone < numBones {
                indices[bone] = UInt32(chain)
            }
        }
        let indexBytes = indices.count * MemoryLayout<UInt32>.stride
        if let buffer = device.makeBuffer(bytes: indices, length: indexBytes, options: [.storageModeShared]) {
            buffer.label = "SpringBone BoneChainIndex"
            boneChainIndexBuffer = buffer
        }
        let sleepBytes = chainCount * MemoryLayout<UInt32>.stride
        if let buffer = device.makeBuffer(length: sleepBytes, options: [.storageModeShared]) {
            buffer.label = "SpringBone ChainSleep"
            memset(buffer.contents(), 0, sleepBytes)
            chainSleepBuffer = buffer
        }
    }

    private func computeChainRanges(numBones: Int) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        for i in 0..<rootBoneIndices.count {
            let start = Int(rootBoneIndices[i])
            let end = (i + 1 < rootBoneIndices.count) ? Int(rootBoneIndices[i + 1]) : numBones
            ranges.append(start..<end)
        }
        return ranges
    }

    /// Builds a per-chain wake mask from completed-frame heuristics into `mask`.
    /// Global events (settling, quality, wind/force, explicit wake) wake every
    /// chain. Root and collider motion wake only the chains they actually affect.
    private func computeWakeMask(into mask: inout [Bool],
                                 globalParams: SpringBoneGlobalParams,
                                 foreign: ForeignColliderSnapshot,
                                 external: ForeignColliderSnapshot) {
        var globalWake = false
        if forceWakePending {
            forceWakePending = false
            globalWake = true
        }
        if globalParams.settlingFrames > 0 {
            globalWake = true
        }
        if let prevQuality = previousQualityForSleep, prevQuality != quality {
            globalWake = true
        }
        if let prev = previousGlobalParamsForSleep {
            if simd_distance_squared(prev.gravity, globalParams.gravity) > 0.001 * 0.001 ||
               abs(prev.windAmplitude - globalParams.windAmplitude) > 0.001 ||
               simd_distance_squared(prev.windDirection, globalParams.windDirection) > 0.01 * 0.01 ||
               simd_distance_squared(prev.externalVelocity, globalParams.externalVelocity) > 0.001 * 0.001 ||
               abs(prev.dragMultiplier - globalParams.dragMultiplier) > 0.001 {
                globalWake = true
            }
        }

        lastWakeMotion.refreshAll = globalWake
        lastWakeMotion.roots.removeAll(keepingCapacity: true)
        lastWakeMotion.spheres.removeAll(keepingCapacity: true)
        lastWakeMotion.capsules.removeAll(keepingCapacity: true)
        lastWakeMotion.planes.removeAll(keepingCapacity: true)
        lastWakeMotion.foreignMoved = false
        lastWakeMotion.externalMoved = false

        var combinedColliderMask: UInt32 = 0
        if !globalWake {
            let motionThreshold = wakeMotionThreshold
            let motionThresholdSq = motionThreshold * motionThreshold

            if !previousRootPositionsForSleep.isEmpty,
               previousRootPositionsForSleep.count == targetRootPositions.count {
                for i in 0..<targetRootPositions.count {
                    if simd_distance_squared(targetRootPositions[i], previousRootPositionsForSleep[i]) > motionThresholdSq {
                        lastWakeMotion.roots.append(i)
                    }
                }
            }

            combinedColliderMask |= scanMovedSpheres(
                previous: previousSphereCollidersForSleep,
                current: targetSphereColliders,
                threshold: motionThreshold,
                thresholdSq: motionThresholdSq,
                movedIndices: &lastWakeMotion.spheres)
            combinedColliderMask |= scanMovedCapsules(
                previous: previousCapsuleCollidersForSleep,
                current: targetCapsuleColliders,
                threshold: motionThreshold,
                thresholdSq: motionThresholdSq,
                movedIndices: &lastWakeMotion.capsules)
            combinedColliderMask |= scanMovedPlanes(
                previous: previousPlaneCollidersForSleep,
                current: targetPlaneColliders,
                thresholdSq: motionThresholdSq,
                movedIndices: &lastWakeMotion.planes)

            if foreignColliderGroupIndex != 0xFFFFFFFF {
                let foreignBit: UInt32 = 1 << foreignColliderGroupIndex
                if foreignCollidersChanged(previous: previousForeignForSleep,
                                           current: foreign,
                                           threshold: motionThreshold) {
                    combinedColliderMask |= foreignBit
                    lastWakeMotion.foreignMoved = true
                }
                if foreignCollidersChanged(previous: previousExternalForSleep,
                                           current: external,
                                           threshold: motionThreshold) {
                    combinedColliderMask |= foreignBit
                    lastWakeMotion.externalMoved = true
                }
            }
        }

        SpringBoneSleepGate.fillWakeMask(
            into: &mask,
            chainCount: chainRanges.count,
            globalWake: globalWake,
            movedRootIndices: lastWakeMotion.roots,
            combinedMovedColliderMask: combinedColliderMask,
            chainColliderMasks: chainColliderMasks
        )
    }

    /// Synchronizes sleep-gate inputs across each skirt ring connected component so
    /// coupled ring chains always wake and sleep in lockstep — preventing a sleeping
    /// neighbor from early-returning in `springBoneCollideCapsules` and halving
    /// two-ended mid-span chord projection.
    private func synchronizeRingSleepInputs() {
        guard !ringChainComponents.isEmpty else { return }
        let limit = min(sleepGate.asleep.count, min(wakeMaskScratch.count, wakeVelocitiesScratch.count))
        for component in ringChainComponents {
            var anyWake = false
            var anyAwake = false
            var anyAsleep = false
            var maxVel: Float = 0
            for c in component where c >= 0 && c < limit {
                if wakeMaskScratch[c] { anyWake = true }
                if sleepGate.asleep[c] {
                    anyAsleep = true
                } else {
                    anyAwake = true
                    if wakeVelocitiesScratch[c] > maxVel {
                        maxVel = wakeVelocitiesScratch[c]
                    }
                }
            }
            if anyWake || (anyAwake && anyAsleep) {
                for c in component where c >= 0 && c < limit {
                    wakeMaskScratch[c] = true
                }
            } else if anyAwake {
                for c in component where c >= 0 && c < limit {
                    wakeVelocitiesScratch[c] = maxVel
                }
            }
        }
    }

    /// Foreign (cross-avatar / external) colliders wake physics like authored
    /// colliders do: a changed count (partner/prop appears or leaves), a moved
    /// centre/endpoint, or a changed radius beyond `threshold` wakes settled chains
    /// (F1). Radius parity matters — a collider that grows or shrinks in place (a
    /// body part or prop scaling without translating) still changes the contact
    /// surface and must wake, matching `collidersMoved` for authored colliders. A
    /// changed `responseScale` (ghost→firm via `setContactResponseScale`) also
    /// wakes: the push strength changes even though no geometry moved (subsystem
    /// 4). A static, unchanging set does NOT wake — chains that already deflected
    /// against it may sleep, so sustained contact doesn't pin the whole crowd awake.
    private func foreignCollidersChanged(previous: ForeignColliderSnapshot,
                                         current: ForeignColliderSnapshot,
                                         threshold: Float) -> Bool {
        if previous.spheres.count != current.spheres.count { return true }
        if previous.capsules.count != current.capsules.count { return true }
        let thresholdSq = threshold * threshold
        for i in current.spheres.indices {
            if simd_distance_squared(previous.spheres[i].center, current.spheres[i].center) > thresholdSq ||
               abs(previous.spheres[i].radius - current.spheres[i].radius) > threshold ||
               previous.spheres[i].responseScale != current.spheres[i].responseScale { return true }
        }
        for i in current.capsules.indices {
            if simd_distance_squared(previous.capsules[i].p0, current.capsules[i].p0) > thresholdSq ||
               simd_distance_squared(previous.capsules[i].p1, current.capsules[i].p1) > thresholdSq ||
               abs(previous.capsules[i].radius - current.capsules[i].radius) > threshold ||
               previous.capsules[i].responseScale != current.capsules[i].responseScale { return true }
        }
        return false
    }

    /// Scans colliders whose current transform differs from their wake anchor by more
    /// than `threshold`, appending moved indices into `movedIndices` and returning
    /// the bitwise OR of their group masks.
    private func scanMovedSpheres(previous: [SphereCollider],
                                  current: [SphereCollider],
                                  threshold: Float,
                                  thresholdSq: Float,
                                  movedIndices: inout [Int]) -> UInt32 {
        if previous.count != current.count {
            return (previous.isEmpty && current.isEmpty) ? 0 : 0xFFFFFFFF
        }
        var combinedMask: UInt32 = 0
        for i in previous.indices {
            if simd_distance_squared(previous[i].center, current[i].center) > thresholdSq ||
               abs(previous[i].radius - current[i].radius) > threshold {
                movedIndices.append(i)
                combinedMask |= current[i].groupMask
            }
        }
        return combinedMask
    }

    private func scanMovedCapsules(previous: [CapsuleCollider],
                                   current: [CapsuleCollider],
                                   threshold: Float,
                                   thresholdSq: Float,
                                   movedIndices: inout [Int]) -> UInt32 {
        if previous.count != current.count {
            return (previous.isEmpty && current.isEmpty) ? 0 : 0xFFFFFFFF
        }
        var combinedMask: UInt32 = 0
        for i in previous.indices {
            if simd_distance_squared(previous[i].p0, current[i].p0) > thresholdSq ||
               simd_distance_squared(previous[i].p1, current[i].p1) > thresholdSq ||
               abs(previous[i].radius - current[i].radius) > threshold {
                movedIndices.append(i)
                combinedMask |= current[i].groupMask
            }
        }
        return combinedMask
    }

    private func scanMovedPlanes(previous: [PlaneCollider],
                                 current: [PlaneCollider],
                                 thresholdSq: Float,
                                 movedIndices: inout [Int]) -> UInt32 {
        if previous.count != current.count {
            return (previous.isEmpty && current.isEmpty) ? 0 : 0xFFFFFFFF
        }
        var combinedMask: UInt32 = 0
        let normalThresholdSq: Float = 0.01 * 0.01
        for i in previous.indices {
            if simd_distance_squared(previous[i].point, current[i].point) > thresholdSq ||
               simd_distance_squared(previous[i].normal, current[i].normal) > normalThresholdSq {
                movedIndices.append(i)
                combinedMask |= current[i].groupMask
            }
        }
        return combinedMask
    }

    private func uploadChainSleepFlags() {
        guard let buffer = chainSleepBuffer, !sleepGate.asleep.isEmpty else { return }
        let count = sleepGate.asleep.count
        let pointer = buffer.contents().bindMemory(to: UInt32.self, capacity: count)
        for i in 0..<count {
            pointer[i] = sleepGate.asleep[i] ? 1 : 0
        }
    }

    private func refreshAnchors<T>(_ anchors: inout [T], from current: [T], moved: [Int], refreshAll: Bool) {
        if refreshAll || anchors.count != current.count {
            anchors = current
            return
        }
        for i in moved where i < current.count {
            anchors[i] = current[i]
        }
    }

    private func captureSleepSnapshots(model: VRMModel, globalParams: SpringBoneGlobalParams,
                                       foreign: ForeignColliderSnapshot, external: ForeignColliderSnapshot) {
        // Wake anchors refresh when seen to cross the motion threshold, while
        // their chain is awake (roots), or while nothing sleeps (colliders).
        let motion = lastWakeMotion
        let asleep = sleepGate.asleep
        let anyAsleep = asleep.contains(true)
        if motion.refreshAll || !anyAsleep
            || previousRootPositionsForSleep.count != targetRootPositions.count {
            previousRootPositionsForSleep = targetRootPositions
        } else {
            let rootCount = targetRootPositions.count
            if wakeMovedRootFlags.count != rootCount {
                wakeMovedRootFlags = Array(repeating: false, count: rootCount)
            } else {
                for i in 0..<rootCount { wakeMovedRootFlags[i] = false }
            }
            for idx in motion.roots where idx >= 0 && idx < rootCount {
                wakeMovedRootFlags[idx] = true
            }
            for i in 0..<rootCount
            where !(i < asleep.count && asleep[i]) || wakeMovedRootFlags[i] {
                previousRootPositionsForSleep[i] = targetRootPositions[i]
            }
        }
        let refreshColliders = motion.refreshAll || !anyAsleep
        refreshAnchors(&previousSphereCollidersForSleep, from: targetSphereColliders,
                       moved: motion.spheres, refreshAll: refreshColliders)
        refreshAnchors(&previousCapsuleCollidersForSleep, from: targetCapsuleColliders,
                       moved: motion.capsules, refreshAll: refreshColliders)
        refreshAnchors(&previousPlaneCollidersForSleep, from: targetPlaneColliders,
                       moved: motion.planes, refreshAll: refreshColliders)
        previousGlobalParamsForSleep = globalParams
        previousQualityForSleep = quality
        // Foreign/external anchors follow the collider rule. The stored sets
        // are the CLAMPED ones (what `writeForeignTail` applied this frame), so
        // over-budget colliders that were never written can't trigger a wake.
        if refreshColliders || motion.foreignMoved {
            previousForeignForSleep = foreign
        }
        if refreshColliders || motion.externalMoved {
            previousExternalForSleep = external
        }
    }

    /// Transforms additive synthetic colliders (issue #309) into world space and
    /// appends them to the given destination arrays. They live in the reserved
    /// synthetic group (`groupMask` bit) so every spring collides with them.
    ///
    /// This is the single shared upload implementation behind `populateSpringBoneData`
    /// and `updateAnimatedPositions`. `rebuildTargetCaptureCaches` mirrors this exact
    /// synthetic shape handling (including `inside` variants and the `.plane` assertion)
    /// into the revision-invalidated `cachedSphereColliders`/`cachedCapsuleColliders`
    /// arrays used by `captureTargetColliderTransforms`.
    /// a `simd_float3x3` rotation extracted from the node's `worldMatrix`,
    /// `worldPosition + worldRotation * offset` for the world center, capsule
    /// `p1 = worldPosition + worldRotation * tail` (`tail` is a local position,
    /// not a vector from `offset`), and a `model.nodes[safe:]` bounds guard.
    /// All sphere/capsule shapes (including the `inside` containment variants)
    /// are handled so the uploaded count always matches the allocation count
    /// (`VRMModel.initializeSpringBoneGPUSystem` counts `insideSphere`/
    /// `insideCapsule` toward the sphere/capsule totals). A synthetic `.plane`
    /// is unsupported here and fails loud rather than silently desyncing that
    /// count.
    private func appendSyntheticColliders(
        _ synthetics: [VRMCollider],
        model: VRMModel,
        groupMask: UInt32,
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
                spheres.append(SphereCollider(center: worldCenter, radius: radius, groupMask: groupMask))

            case .insideSphere(let offset, let radius):
                let worldCenter = colliderNode.worldPosition + worldRotation * offset
                spheres.append(SphereCollider(center: worldCenter, radius: radius, groupMask: groupMask, inside: true))

            case .capsule(let offset, let radius, let tail):
                let worldP0 = colliderNode.worldPosition + worldRotation * offset
                let worldP1 = colliderNode.worldPosition + worldRotation * tail
                capsules.append(CapsuleCollider(p0: worldP0, p1: worldP1, radius: radius, groupMask: groupMask))

            case .insideCapsule(let offset, let radius, let tail):
                let worldP0 = colliderNode.worldPosition + worldRotation * offset
                let worldP1 = colliderNode.worldPosition + worldRotation * tail
                capsules.append(CapsuleCollider(p0: worldP0, p1: worldP1, radius: radius, groupMask: groupMask, inside: true))

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

    /// Pure world-space snapshot of this avatar's skeleton-derived body contact
    /// set (torso + upper arms + head + thigh capsules, plus up to 8 authored
    /// body colliders). Reuses the world-transform idiom of
    /// `appendSyntheticColliders` but mutates NOTHING — it does not read or write
    /// the interpolation mirror, so the coordinator can call it before this
    /// system's integrate without perturbing the subsequent frame (design §2.2).
    /// `groupMask` is left 0 (untagged); the receiving sink assigns the foreign
    /// group bit.
    func contactColliderSnapshot(model: VRMModel) -> ForeignColliderSnapshot {
        let local = SpringBoneContactColliderSet.synthesize(model: model)
        var spheres: [SphereCollider] = []
        var capsules: [CapsuleCollider] = []
        for collider in local {
            guard let node = model.nodes[safe: collider.node] else { continue }
            let wm = node.worldMatrix
            let rot = simd_float3x3(
                SIMD3<Float>(wm[0][0], wm[0][1], wm[0][2]),
                SIMD3<Float>(wm[1][0], wm[1][1], wm[1][2]),
                SIMD3<Float>(wm[2][0], wm[2][1], wm[2][2]))
            switch collider.shape {
            case .sphere(let offset, let radius):
                spheres.append(SphereCollider(center: node.worldPosition + rot * offset,
                                              radius: radius, groupMask: 0))
            case .capsule:
                if let c = SpringBoneContactColliderSet.worldCapsule(collider, model: model) {
                    capsules.append(c)
                }
            default:
                continue
            }
        }
        return ForeignColliderSnapshot(spheres: spheres, capsules: capsules)
    }

    /// This avatar's torso capsule in world space (design §3.1): the single
    /// contact capsule the postural yield leans away from and the contact-aware
    /// clamp measures separation against. Built from
    /// `SpringBoneContactColliderSet.torsoCollider` — the same source of truth as
    /// the first capsule `contactColliderSnapshot` emits — so a consumer never has
    /// to guess which capsule in the snapshot bag is the trunk. Pure: reads world
    /// matrices only, mutates nothing. `nil` when the model has no humanoid.
    func contactTorsoCapsule(model: VRMModel) -> CapsuleCollider? {
        SpringBoneContactColliderSet.worldTorsoCapsule(model: model)
    }

    // MARK: - Dynamic Rebuild Continuity Snapshot

    private struct PreservedChainState {
        let currPositions: [SIMD3<Float>]
        let prevPositions: [SIMD3<Float>]
        let isAsleep: Bool
        let sleepCounter: Int
        let previousRootPos: SIMD3<Float>?
        let lastRootPos: SIMD3<Float>?
        let previousBindDirs: [SIMD3<Float>]
    }

    private struct DynamicRebuildSnapshot {
        var chainsByKey: [[ObjectIdentifier]: PreservedChainState]
        var previousCenterWorldMatrices: [ObjectIdentifier: float4x4]
        var pendingForeignSnapshot: ForeignColliderSnapshot
        var pendingExternalColliders: ForeignColliderSnapshot
        var previousForeignForSleep: ForeignColliderSnapshot
        var previousExternalForSleep: ForeignColliderSnapshot
    }

    private static func bindPosition(of matrix: float4x4) -> SIMD3<Float> {
        SIMD3<Float>(matrix.columns.3.x, matrix.columns.3.y, matrix.columns.3.z)
    }

    /// Computes bind-pose rest length between `parentNode` and `node` using immutable
    /// `initialTranslation/Rotation/Scale` (immune to live animation), falling back to
    /// live `worldPosition` only when a synthetic test node has zero initial separation.
    private static func computeBindRestLength(parent: VRMNode, child: VRMNode) -> Float {
        let parentBindPos = bindPosition(of: VRMSkeletonRemapper.bindWorldMatrix(of: parent))
        let childBindPos = bindPosition(of: VRMSkeletonRemapper.bindWorldMatrix(of: child))
        let bindDist = simd_distance(childBindPos, parentBindPos)
        if bindDist > 1e-4 {
            return bindDist
        }
        return simd_distance(child.worldPosition, parent.worldPosition)
    }

    /// Computes immutable bind-pose local direction from `currentNode` to `nextNode` in
    /// `currentNode.parent`'s bind frame, falling back to live world matrices for
    /// synthetic test nodes with zero initial separation.
    private func computeBindLocalDirection(current: VRMNode, next: VRMNode) -> SIMD3<Float> {
        let curBindMat = VRMSkeletonRemapper.bindWorldMatrix(of: current)
        let nextBindMat = VRMSkeletonRemapper.bindWorldMatrix(of: next)
        let curBindPos = Self.bindPosition(of: curBindMat)
        let nextBindPos = Self.bindPosition(of: nextBindMat)
        let bindDelta = nextBindPos - curBindPos
        if simd_length(bindDelta) > 1e-4 {
            let bindDirWorld = simd_normalize(bindDelta)
            if let parentNode = current.parent {
                let parentBindMat = VRMSkeletonRemapper.bindWorldMatrix(of: parentNode)
                let parentRot = simd_normalize(extractRotation(from: parentBindMat))
                return simd_act(simd_conjugate(parentRot), bindDirWorld)
            }
            return bindDirWorld
        }
        let liveDelta = next.worldPosition - current.worldPosition
        let liveDir = simd_length(liveDelta) > 1e-4 ? simd_normalize(liveDelta) : SIMD3<Float>(0, -1, 0)
        if let parentNode = current.parent {
            let parentRot = simd_normalize(extractRotation(from: parentNode.worldMatrix))
            return simd_act(simd_conjugate(parentRot), liveDir)
        }
        return liveDir
    }

    /// Dynamically rebuilds the single-solver GPU buffers and simulation tables after
    /// attaching or detaching SpringBone cosmetics, preserving live momentum, sleep
    /// state, center-frame history, foreign/external colliders, and floor planes for
    /// all surviving chains while selectively warming up ONLY newly attached chains.
    func rebuildSpringBoneData(
        model: VRMModel,
        warmupNewChainSteps: Int = 15,
        limits: VRMLoaderLimits = .default
    ) throws {
        // Drain any self-owned pending GPU work first.
        waitForPendingFrame()

        guard let device = model.device ?? self.device as MTLDevice? else { return }

        // 1. Capture live state of surviving chains before reallocating buffers.
        let snapshot = captureDynamicRebuildSnapshot(model: model)

        // 2. Compose the unified host + attachment layout (enforcing <= 29 authored groups).
        let newLayout = try ComposedSpringBoneLayout.build(model: model)

        if newLayout.totalBones == 0 {
            // No chains remain (e.g. last physics cosmetic detached from a no-spring host).
            snapshotLock.lock()
            physicsLayoutGeneration &+= 1
            latestPositionsSnapshot.removeAll(keepingCapacity: true)
            latestPrevPositionsSnapshot.removeAll(keepingCapacity: true)
            completedChainVelocities.removeAll(keepingCapacity: true)
            latestCompletedFrame = 0
            lastAppliedFrame = 0
            snapshotLock.unlock()

            activeLayout = nil
            committedLayout = nil
            model.springBoneBuffers = nil
            chainRanges = []
            chainColliderMasks = []
            rootBoneIndices = []
            sleepGate = SpringBoneSleepGate(chainCount: 0)
            allocateSleepBuffers(numBones: 0, chainCount: 0)
            centerSpringRecords.removeAll(keepingCapacity: true)
            centerDeltaBuffer = nil
            cachedRootNodes.removeAll(keepingCapacity: true)
            cachedBindDirEntries.removeAll(keepingCapacity: true)
            cachedSphereColliders.removeAll(keepingCapacity: true)
            cachedCapsuleColliders.removeAll(keepingCapacity: true)
            cachedPlaneColliders.removeAll(keepingCapacity: true)
            return
        }

        // Enforce bone quota against limits.
        if newLayout.totalBones > limits.maxSpringBones {
            throw VRMError.limitExceeded(
                kind: "springBones",
                limit: limits.maxSpringBones,
                observed: newLayout.totalBones
            )
        }

        // 3. Allocate fresh GPU buffers sized for the composed layout.
        let counts = newLayout.colliderCounts()
        let reserve = model.reservesForeignColliderTail
        let foreignSphereSlots = reserve
            ? VRMConstants.Physics.maxContactPartners * VRMConstants.Physics.foreignSphereSlotsPerPartner
                + VRMConstants.Physics.externalColliderSphereSlots
            : 0
        let foreignCapsuleSlots = reserve
            ? VRMConstants.Physics.maxContactPartners * VRMConstants.Physics.foreignCapsuleSlotsPerPartner
                + VRMConstants.Physics.externalColliderCapsuleSlots
            : 0

        let authoredPlaneCount = counts.planes
        let floorPlaneCount = model.runtimeFloorPlanes.count
        let totalPlaneCount = max(authoredPlaneCount, floorPlaneCount)

        let freshBuffers = SpringBoneBuffers(device: device)
        try freshBuffers.allocateBuffers(
            numBones: newLayout.totalBones,
            numSpheres: counts.spheres,
            numCapsules: counts.capsules,
            numPlanes: totalPlaneCount,
            foreignSphereSlots: foreignSphereSlots,
            foreignCapsuleSlots: foreignCapsuleSlots,
            limits: limits
        )
        model.springBoneBuffers = freshBuffers

        // Preserve existing global parameters (gravity, wind, settlingFrames) if present.
        if var existingParams = model.springBoneGlobalParams {
            existingParams.numBones = UInt32(newLayout.totalBones)
            existingParams.numSpheres = UInt32(counts.spheres)
            existingParams.numCapsules = UInt32(counts.capsules)
            existingParams.numPlanes = UInt32(totalPlaneCount)
            model.springBoneGlobalParams = existingParams
        } else {
            model.springBoneGlobalParams = SpringBoneGlobalParams(
                gravity: VRMConstants.Physics.defaultGravity,
                dtSub: 1.0 / 120.0,
                windAmplitude: 0.0,
                windFrequency: 1.0,
                windPhase: 0.0,
                windDirection: SIMD3<Float>(1, 0, 0),
                substeps: 2,
                numBones: UInt32(newLayout.totalBones),
                numSpheres: UInt32(counts.spheres),
                numCapsules: UInt32(counts.capsules),
                numPlanes: UInt32(totalPlaneCount),
                settlingFrames: 0
            )
        }

        // 4. Populate composed layout, preserving surviving chains & selectively warming new ones.
        try populateSpringBoneData(
            model: model,
            layout: newLayout,
            preserving: snapshot,
            warmupNewChainSteps: warmupNewChainSteps
        )
    }

    private func captureDynamicRebuildSnapshot(model: VRMModel) -> DynamicRebuildSnapshot {
        var chainsByKey: [[ObjectIdentifier]: PreservedChainState] = [:]

        if let oldLayout = committedLayout,
           let oldBuffers = model.springBoneBuffers,
           oldBuffers.numBones == oldLayout.totalBones,
           oldLayout.totalBones > 0 {
            // Prefer the last completed snapshot (safe while a shared command buffer may still be in flight).
            var liveCurr: [SIMD3<Float>] = []
            var livePrev: [SIMD3<Float>] = []
            snapshotLock.lock()
            if latestCompletedFrame > 0,
               latestPositionsSnapshot.count == oldLayout.totalBones,
               latestPrevPositionsSnapshot.count == oldLayout.totalBones {
                liveCurr = latestPositionsSnapshot
                livePrev = latestPrevPositionsSnapshot
            }
            snapshotLock.unlock()

            if liveCurr.isEmpty,
               let currBuf = oldBuffers.bonePosCurr,
               let prevBuf = oldBuffers.bonePosPrev {
                let currPtr = currBuf.contents().bindMemory(to: SIMD3<Float>.self, capacity: oldLayout.totalBones)
                let prevPtr = prevBuf.contents().bindMemory(to: SIMD3<Float>.self, capacity: oldLayout.totalBones)
                liveCurr = Array(UnsafeBufferPointer(start: currPtr, count: oldLayout.totalBones))
                livePrev = Array(UnsafeBufferPointer(start: prevPtr, count: oldLayout.totalBones))
            }

            if liveCurr.count == oldLayout.totalBones && livePrev.count == oldLayout.totalBones {
                for (chainIdx, chain) in oldLayout.chains.enumerated() where chainIdx < chainRanges.count {
                    let range = chainRanges[chainIdx]
                    guard range.upperBound <= liveCurr.count else { continue }
                    let currSlice = Array(liveCurr[range])
                    let prevSlice = Array(livePrev[range])
                    let asleep = chainIdx < sleepGate.asleep.count ? sleepGate.asleep[chainIdx] : false
                    let counter = chainIdx < sleepGate.counters.count ? sleepGate.counters[chainIdx] : 0
                    let prevRoot = chainIdx < previousRootPositions.count ? previousRootPositions[chainIdx] : nil
                    let lastRoot = chainIdx < lastRootPositions.count ? lastRootPositions[chainIdx] : nil
                    let prevBindSlice: [SIMD3<Float>]
                    if range.upperBound <= previousWorldBindDirections.count {
                        prevBindSlice = Array(previousWorldBindDirections[range])
                    } else {
                        prevBindSlice = []
                    }
                    chainsByKey[chain.chainKey] = PreservedChainState(
                        currPositions: currSlice,
                        prevPositions: prevSlice,
                        isAsleep: asleep,
                        sleepCounter: counter,
                        previousRootPos: prevRoot,
                        lastRootPos: lastRoot,
                        previousBindDirs: prevBindSlice
                    )
                }
            }
        }

        return DynamicRebuildSnapshot(
            chainsByKey: chainsByKey,
            previousCenterWorldMatrices: previousCenterWorldMatrices,
            pendingForeignSnapshot: pendingForeignSnapshot,
            pendingExternalColliders: pendingExternalColliders,
            previousForeignForSleep: previousForeignForSleep,
            previousExternalForSleep: previousExternalForSleep
        )
    }

    func populateSpringBoneData(model: VRMModel) throws {
        guard model.hasAnySpringBoneLocked(),
              model.springBoneBuffers != nil,
              model.device != nil else {
            return
        }
        let layout = try ComposedSpringBoneLayout.build(model: model)
        try populateSpringBoneData(model: model, layout: layout, preserving: nil, warmupNewChainSteps: 0)
    }

    private func populateSpringBoneData(
        model: VRMModel,
        layout: ComposedSpringBoneLayout,
        preserving snapshot: DynamicRebuildSnapshot?,
        warmupNewChainSteps: Int
    ) throws {
        guard let buffers = model.springBoneBuffers else { return }

        // Advance layout generation immediately under snapshotLock so any in-flight
        // async GPU completion handler from a previous layout is cleanly discarded.
        snapshotLock.lock()
        physicsLayoutGeneration &+= 1
        latestPositionsSnapshot.removeAll(keepingCapacity: true)
        latestPrevPositionsSnapshot.removeAll(keepingCapacity: true)
        completedChainVelocities.removeAll(keepingCapacity: true)
        latestCompletedFrame = 0
        lastAppliedFrame = 0
        snapshotLock.unlock()

        activeLayout = layout
        committedLayout = layout

        var boneParams: [BoneParams] = []
        var restLengths: [Float] = []
        var parentIndices: [Int] = []
        var sphereColliders: [SphereCollider] = []
        var capsuleColliders: [CapsuleCollider] = []
        var planeColliders: [PlaneCollider] = []
        boneBindDirections = []

        if let snapshot {
            pendingForeignSnapshot = snapshot.pendingForeignSnapshot
            pendingExternalColliders = snapshot.pendingExternalColliders
            previousForeignForSleep = snapshot.previousForeignForSleep
            previousExternalForSleep = snapshot.previousExternalForSleep
        } else {
            pendingForeignSnapshot = ForeignColliderSnapshot()
            pendingExternalColliders = ForeignColliderSnapshot()
            previousForeignForSleep = ForeignColliderSnapshot()
            previousExternalForSleep = ForeignColliderSnapshot()
        }
        activeForeignSpheres = 0
        activeForeignCapsules = 0

        let syntheticGroupBit = layout.syntheticGroupBit
        sweptColliderGroupMask = syntheticGroupBit
        foreignColliderGroupIndex = layout.foreignColliderGroupIndex

        var boneIndex = 0
        rootBoneIndices = []
        chainColliderMasks = []

        for chain in layout.chains {
            guard !chain.jointNodes.isEmpty else { continue }
            chainColliderMasks.append(chain.colliderGroupMask)

            for jointIndexInChain in 0..<chain.jointNodes.count {
                let currentNode = chain.jointNodes[jointIndexInChain]
                let joint = chain.jointSettings[jointIndexInChain]
                let isRootBone = (jointIndexInChain == 0)

                if isRootBone {
                    rootBoneIndices.append(UInt32(boneIndex))
                }

                let normalizedGravityDir = simd_length(joint.gravityDir) > 0.001
                    ? simd_normalize(joint.gravityDir)
                    : SIMD3<Float>(0, -1, 0)

                let parentIdx = isRootBone ? -1 : (boneIndex - 1)
                parentIndices.append(parentIdx)

                let clamped = springBoneOverride.apply(
                    stiffness: joint.stiffness,
                    dragForce: joint.dragForce,
                    gravityPower: joint.gravityPower,
                    jointName: currentNode?.name
                )

                boneParams.append(BoneParams(
                    stiffness: clamped.stiffness,
                    drag: clamped.dragForce,
                    radius: joint.hitRadius,
                    parentIndex: parentIdx < 0 ? 0xFFFFFFFF : UInt32(parentIdx),
                    gravityPower: clamped.gravityPower,
                    colliderGroupMask: chain.colliderGroupMask,
                    gravityDir: normalizedGravityDir,
                    angleLimit: joint.angleLimit
                ))

                // Derive immutable bind-pose rest length (never live animated distance).
                if jointIndexInChain > 0,
                   let currentNode,
                   let parentNode = chain.jointNodes[jointIndexInChain - 1] {
                    restLengths.append(Self.computeBindRestLength(parent: parentNode, child: currentNode))
                } else {
                    restLengths.append(0.0)
                }

                // Derive immutable bind-pose local direction (current -> next in parent's bind frame).
                if let currentNode {
                    if jointIndexInChain + 1 < chain.jointNodes.count,
                       let nextNode = chain.jointNodes[jointIndexInChain + 1] {
                        boneBindDirections.append(computeBindLocalDirection(current: currentNode, next: nextNode))
                    } else {
                        boneBindDirections.append(SIMD3<Float>(0, -1, 0))
                    }
                } else if jointIndexInChain > 0,
                          jointIndexInChain + 1 < chain.jointNodes.count,
                          let prevNode = chain.jointNodes[jointIndexInChain - 1],
                          let nextNode = chain.jointNodes[jointIndexInChain + 1] {
                    let delta = nextNode.worldPosition - prevNode.worldPosition
                    boneBindDirections.append(simd_length(delta) > 1e-4 ? simd_normalize(delta) : SIMD3<Float>(0, 1, 0))
                } else {
                    boneBindDirections.append(SIMD3<Float>(0, 1, 0))
                }

                boneIndex += 1
            }
        }

        chainRanges = computeChainRanges(numBones: boneIndex)
        sleepGate = SpringBoneSleepGate(chainCount: chainRanges.count)
        allocateSleepBuffers(numBones: boneIndex, chainCount: chainRanges.count)

        // Build world-space colliders (authored host + attachment, then cached host synthetic).
        func appendCollider(_ collider: ComposedCollider) {
            let wm = collider.node.worldMatrix
            let worldRotation = simd_float3x3(
                SIMD3<Float>(wm[0][0], wm[0][1], wm[0][2]),
                SIMD3<Float>(wm[1][0], wm[1][1], wm[1][2]),
                SIMD3<Float>(wm[2][0], wm[2][1], wm[2][2])
            )
            let worldPos = collider.node.worldPosition

            switch collider.shape {
            case .sphere(let offset, let radius):
                sphereColliders.append(SphereCollider(
                    center: worldPos + worldRotation * offset,
                    radius: radius,
                    groupMask: collider.groupMask
                ))
            case .insideSphere(let offset, let radius):
                sphereColliders.append(SphereCollider(
                    center: worldPos + worldRotation * offset,
                    radius: radius,
                    groupMask: collider.groupMask,
                    inside: true
                ))
            case .capsule(let offset, let radius, let tail):
                capsuleColliders.append(CapsuleCollider(
                    p0: worldPos + worldRotation * offset,
                    p1: worldPos + worldRotation * tail,
                    radius: radius,
                    groupMask: collider.groupMask
                ))
            case .insideCapsule(let offset, let radius, let tail):
                capsuleColliders.append(CapsuleCollider(
                    p0: worldPos + worldRotation * offset,
                    p1: worldPos + worldRotation * tail,
                    radius: radius,
                    groupMask: collider.groupMask,
                    inside: true
                ))
            case .plane(let offset, let normal):
                let worldNormal = worldRotation * normal
                let normalizedNormal = simd_length(worldNormal) > 0.001 ? simd_normalize(worldNormal) : SIMD3<Float>(0, 1, 0)
                planeColliders.append(PlaneCollider(
                    point: worldPos + worldRotation * offset,
                    normal: normalizedNormal,
                    groupMask: collider.groupMask
                ))
            }
        }

        for collider in layout.authoredColliders {
            appendCollider(collider)
        }
        for collider in layout.syntheticColliders {
            appendCollider(collider)
        }

        buffers.updateBoneParameters(boneParams)

        // Skirt ring chord detection runs on host chains when base springBone exists;
        // pad aux entries with defaults for any attached cosmetic chains.
        let hostChainCount = layout.chains.prefix(while: { $0.sourceIsHost }).count
        let hostSyntheticEnabled = (0..<hostChainCount).map { (chainColliderMasks[$0] & syntheticGroupBit) != 0 }
        let ringDetection = SpringBoneSkirtRingDetector.buildCollisionAux(
            model: model,
            hasSyntheticColliders: layout.syntheticGroupBit != 0,
            chainSyntheticEnabled: hostSyntheticEnabled
        )
        var combinedAux = ringDetection.aux
        if combinedAux.count < boneIndex {
            combinedAux.append(contentsOf: repeatElement(SpringBoneCollisionAux(), count: boneIndex - combinedAux.count))
        } else if combinedAux.count > boneIndex {
            combinedAux = Array(combinedAux.prefix(boneIndex))
        }
        let auxUploaded = buffers.updateCollisionAux(combinedAux)
        hasRingNeighbors = auxUploaded && ringDetection.hasRingNeighbors
        ringChainComponents = hasRingNeighbors ? ringDetection.ringChainComponents : []

        buffers.updateRestLengths(restLengths)

        // Compute current world-space bind directions for stiffness.
        var initialWorldBindDirections: [SIMD3<Float>] = []
        initialWorldBindDirections.reserveCapacity(boneIndex)
        var bIdx = 0
        for chain in layout.chains {
            for jointNode in chain.jointNodes {
                guard bIdx < boneBindDirections.count else { break }
                defer { bIdx += 1 }
                let localDir = boneBindDirections[bIdx]
                if let jointNode, let nodeParent = jointNode.parent {
                    let parentRot = simd_normalize(extractRotation(from: nodeParent.worldMatrix))
                    let worldDir = simd_act(parentRot, localDir)
                    initialWorldBindDirections.append(simd_length(worldDir) > 1e-4 ? simd_normalize(worldDir) : localDir)
                } else {
                    initialWorldBindDirections.append(localDir)
                }
            }
        }
        buffers.updateBindDirections(initialWorldBindDirections)

        targetWorldBindDirections = initialWorldBindDirections
        previousWorldBindDirections = initialWorldBindDirections
        cpuRestLengths = restLengths
        cpuParentIndices = parentIndices
        cachedModelScale = calculateModelScaleFromRestLengths()

        if !sphereColliders.isEmpty {
            buffers.updateSphereColliders(sphereColliders)
        }
        if !capsuleColliders.isEmpty {
            buffers.updateCapsuleColliders(capsuleColliders)
        }
        if !planeColliders.isEmpty {
            buffers.updatePlaneColliders(planeColliders)
        } else if !model.runtimeFloorPlanes.isEmpty {
            buffers.setPlaneColliders(model.runtimeFloorPlanes)
            model.springBoneGlobalParams?.numPlanes = UInt32(model.runtimeFloorPlanes.count)
        }

        // Seed bone positions: preserve live curr/prev for surviving chains, seed kinematic
        // bind pose for new chains (zero velocity).
        var currPositions = [SIMD3<Float>](repeating: .zero, count: boneIndex)
        var prevPositions = [SIMD3<Float>](repeating: .zero, count: boneIndex)
        var restoredAsleep = [Bool](repeating: false, count: chainRanges.count)
        var restoredCounters = [Int](repeating: 0, count: chainRanges.count)
        var newChainIndices: [Int] = []
        var preservedLastRoots = [SIMD3<Float>](repeating: .zero, count: rootBoneIndices.count)
        var preservedPrevRoots = [SIMD3<Float>](repeating: .zero, count: rootBoneIndices.count)

        for (chainIdx, chain) in layout.chains.enumerated() where chainIdx < chainRanges.count {
            let range = chainRanges[chainIdx]
            let rootPos = chain.jointNodes[0]?.worldPosition ?? .zero

            if let saved = snapshot?.chainsByKey[chain.chainKey],
               !chain.chainKey.isEmpty,
               saved.currPositions.count == range.count,
               saved.prevPositions.count == range.count {
                // Surviving chain: restore exact live positions, momentum, sleep & interpolation history.
                for offset in 0..<range.count {
                    currPositions[range.lowerBound + offset] = saved.currPositions[offset]
                    prevPositions[range.lowerBound + offset] = saved.prevPositions[offset]
                }
                restoredAsleep[chainIdx] = saved.isAsleep
                restoredCounters[chainIdx] = saved.sleepCounter
                preservedLastRoots[chainIdx] = saved.lastRootPos ?? rootPos
                preservedPrevRoots[chainIdx] = saved.previousRootPos ?? rootPos
                if saved.previousBindDirs.count == range.count {
                    for offset in 0..<range.count {
                        previousWorldBindDirections[range.lowerBound + offset] = saved.previousBindDirs[offset]
                    }
                }
            } else {
                // New chain (or fresh load): seed along current pose with zero velocity.
                if snapshot != nil {
                    newChainIndices.append(chainIdx)
                    // Kinematic seed along world bind directions from current animated root.
                    currPositions[range.lowerBound] = rootPos
                    prevPositions[range.lowerBound] = rootPos
                    for offset in 1..<range.count {
                        let globalBone = range.lowerBound + offset
                        let parentBone = globalBone - 1
                        let dir = parentBone < initialWorldBindDirections.count
                            ? initialWorldBindDirections[parentBone]
                            : SIMD3<Float>(0, -1, 0)
                        let pos = currPositions[parentBone] + dir * restLengths[globalBone]
                        currPositions[globalBone] = pos
                        prevPositions[globalBone] = pos
                    }
                } else {
                    for offset in 0..<range.count {
                        let pos = chain.jointNodes[offset]?.worldPosition ?? .zero
                        currPositions[range.lowerBound + offset] = pos
                        prevPositions[range.lowerBound + offset] = pos
                    }
                }
                preservedLastRoots[chainIdx] = rootPos
                preservedPrevRoots[chainIdx] = rootPos
            }
        }

        if let bonePosPrev = buffers.bonePosPrev,
           let bonePosCurr = buffers.bonePosCurr,
           boneIndex > 0 {
            let prevPtr = bonePosPrev.contents().bindMemory(to: SIMD3<Float>.self, capacity: boneIndex)
            let currPtr = bonePosCurr.contents().bindMemory(to: SIMD3<Float>.self, capacity: boneIndex)
            for i in 0..<boneIndex {
                prevPtr[i] = prevPositions[i]
                currPtr[i] = currPositions[i]
            }
        }

        // Restore surviving chains' sleep state.
        sleepGate.restoreState(asleep: restoredAsleep, counters: restoredCounters, ranges: chainRanges)
        uploadChainSleepFlags()

        // Initialize kinematic root buffers.
        let numRootBones = rootBoneIndices.count
        if numRootBones > 0 {
            let singleStepLength = MemoryLayout<SIMD3<Float>>.stride * numRootBones
            let alignment = 256
            let alignedStep = (singleStepLength + alignment - 1) & ~(alignment - 1)
            let maxSubsteps = VRMConstants.Physics.maxSubstepsPerFrame
            let positionsLength = alignedStep * maxSubsteps

            animatedRootPositionsBuffer = device.makeBuffer(length: positionsLength, options: [.storageModeShared])
            animatedRootPositionsBuffer?.label = "SpringBone AnimatedRootPositions"
            animatedRootPositionsPrevBuffer = device.makeBuffer(length: singleStepLength, options: [.storageModeShared])
            animatedRootPositionsPrevBuffer?.label = "SpringBone AnimatedRootPositions Prev"
            rootBoneIndicesBuffer = device.makeBuffer(
                bytes: rootBoneIndices,
                length: MemoryLayout<UInt32>.stride * numRootBones,
                options: [.storageModeShared]
            )
            rootBoneIndicesBuffer?.label = "SpringBone RootBoneIndices"
            var numRootBonesUInt = UInt32(numRootBones)
            numRootBonesBuffer = device.makeBuffer(
                bytes: &numRootBonesUInt,
                length: MemoryLayout<UInt32>.stride,
                options: [.storageModeShared]
            )
            numRootBonesBuffer?.label = "SpringBone NumRootBones"

            let currentRootPositions = layout.chains.compactMap { $0.jointNodes.first.flatMap { $0 }?.worldPosition }
            if !currentRootPositions.isEmpty, currentRootPositions.count == numRootBones,
               let currBuf = animatedRootPositionsBuffer, let prevBuf = animatedRootPositionsPrevBuffer {
                for slot in 0..<maxSubsteps {
                    currBuf.contents().advanced(by: slot * alignedStep)
                        .copyMemory(from: currentRootPositions, byteCount: singleStepLength)
                }
                prevBuf.contents().copyMemory(from: preservedPrevRoots, byteCount: singleStepLength)
            }
            if snapshot != nil {
                lastRootPositions = preservedLastRoots
                previousRootPositions = preservedPrevRoots
                targetRootPositions = currentRootPositions
            } else {
                lastRootPositions = []
                previousRootPositions = []
                targetRootPositions = []
            }
        }

        // Build center-spring records keyed by ObjectIdentifier(centerNode), preserving
        // surviving center history from snapshot.
        centerSpringRecords.removeAll(keepingCapacity: true)
        previousCenterWorldMatrices.removeAll(keepingCapacity: true)
        targetCenterWorldMatrices.removeAll(keepingCapacity: true)
        var centerBoneIdx = 0
        for chain in layout.chains {
            let count = chain.jointNodes.count
            if let centerIndex = chain.centerNodeIndex {
                let centerNode = chain.centerNode
                let centerID = centerNode.map(ObjectIdentifier.init)
                centerSpringRecords.append(CenterSpringRecord(
                    centerNodeIndex: centerIndex,
                    centerNode: centerNode,
                    centerNodeID: centerID,
                    boneStart: centerBoneIdx,
                    boneCount: count
                ))
                if let centerNode, let centerID {
                    if let savedMatrix = snapshot?.previousCenterWorldMatrices[centerID] {
                        previousCenterWorldMatrices[centerID] = savedMatrix
                    } else {
                        previousCenterWorldMatrices[centerID] = centerNode.worldMatrix
                    }
                }
            }
            centerBoneIdx += count
        }

        let numRecords = centerSpringRecords.count
        if numRecords > 0 {
            let maxSubsteps = VRMConstants.Physics.maxSubstepsPerFrame
            let stride = MemoryLayout<CenterDeltaRecordGPU>.stride
            let totalBytes = stride * numRecords * maxSubsteps
            centerDeltaBuffer = device.makeBuffer(length: totalBytes, options: [.storageModeShared])
            centerDeltaBuffer?.label = "SpringBone CenterDelta"
            if let buffer = centerDeltaBuffer {
                memset(buffer.contents(), 0, totalBytes)
            }
        } else {
            centerDeltaBuffer = nil
        }

        // Pre-resolve flat per-frame capture caches from the composed layout.
        rebuildTargetCaptureCaches(model: model, layout: layout)

        // Selective GPU warmup ONLY on newly attached chains via chainSleepBuffer
        // (zero SpringBone shader changes; surviving chains stay frozen = 1).
        if snapshot != nil,
           warmupNewChainSteps > 0,
           !newChainIndices.isEmpty,
           let globalParams = model.springBoneGlobalParams,
           let sleepBuf = chainSleepBuffer {
            let newChainSet = Set(newChainIndices)
            let sleepPtr = sleepBuf.contents().bindMemory(to: UInt32.self, capacity: chainRanges.count)
            for c in 0..<chainRanges.count {
                sleepPtr[c] = newChainSet.contains(c) ? 0 : 1
            }

            // Prepare substep-0 poses, colliders, foreign tail, and identity center deltas.
            let (clampedForeign, clampedExternal): (ForeignColliderSnapshot, ForeignColliderSnapshot)
            if foreignColliderGroupIndex != 0xFFFFFFFF {
                (clampedForeign, clampedExternal) = clampedForeignSets(buffers: buffers)
            } else {
                clampedForeign = ForeignColliderSnapshot()
                clampedExternal = ForeignColliderSnapshot()
            }
            writeForeignTail(buffers: buffers, foreign: clampedForeign, external: clampedExternal)

            populateTargetColliderTransforms()
            if !targetSphereColliders.isEmpty { buffers.updateSphereColliders(targetSphereColliders) }
            if !targetCapsuleColliders.isEmpty { buffers.updateCapsuleColliders(targetCapsuleColliders) }
            if !targetPlaneColliders.isEmpty { buffers.updatePlaneColliders(targetPlaneColliders) }

            if !centerSpringRecords.isEmpty {
                let savedPrevCenters = previousCenterWorldMatrices
                captureTargetCenterWorldMatrices(model: model)
                for record in centerSpringRecords {
                    if let centerID = record.centerNodeID,
                       let target = targetCenterWorldMatrices[centerID] {
                        previousCenterWorldMatrices[centerID] = target
                    }
                }
                fillCenterDeltaBufferForFrame(substepCount: 1)
                previousCenterWorldMatrices = savedPrevCenters
            }

            var warmupParams = globalParams
            warmupParams.settlingFrames = 0
            warmupParams.numSpheres = UInt32(buffers.numSpheres + activeForeignSpheres)
            warmupParams.numCapsules = UInt32(buffers.numCapsules + activeForeignCapsules)
            globalParamsBuffer?.contents().copyMemory(
                from: &warmupParams,
                byteCount: MemoryLayout<SpringBoneGlobalParams>.stride
            )

            if let warmupCB = commandQueue.makeCommandBuffer() {
                warmupCB.label = "SpringBone Selective New-Chain Warmup"
                for _ in 0..<warmupNewChainSteps {
                    executeXPBDStep(
                        buffers: buffers,
                        globalParams: warmupParams,
                        sharedCommandBuffer: warmupCB,
                        substepIndex: 0,
                        registerCompletedHandler: false
                    )
                }
                warmupCB.commit()
                warmupCB.waitUntilCompleted()
            }

            // Zero velocity ONLY on newly attached chains; surviving chains are untouched.
            if let bonePosCurr = buffers.bonePosCurr,
               let bonePosPrev = buffers.bonePosPrev {
                let currPtr = bonePosCurr.contents().bindMemory(to: SIMD3<Float>.self, capacity: boneIndex)
                let prevPtr = bonePosPrev.contents().bindMemory(to: SIMD3<Float>.self, capacity: boneIndex)
                for c in newChainIndices where c < chainRanges.count {
                    for b in chainRanges[c] {
                        prevPtr[b] = currPtr[b]
                    }
                }
            }

            // Restore surviving chains' exact sleepGate flags into chainSleepBuffer.
            sleepGate.restoreState(asleep: restoredAsleep, counters: restoredCounters, ranges: chainRanges)
            uploadChainSleepFlags()
            _ = globalParams
        }

        // Seed snapshot for dynamic rebuilds so sleeping/surviving chains continue smoothly on the very next frame.
        if snapshot != nil,
           let bonePosCurr = buffers.bonePosCurr,
           let bonePosPrev = buffers.bonePosPrev,
           boneIndex > 0 {
            let currPtr = bonePosCurr.contents().bindMemory(to: SIMD3<Float>.self, capacity: boneIndex)
            let prevPtr = bonePosPrev.contents().bindMemory(to: SIMD3<Float>.self, capacity: boneIndex)
            let snapCurr = Array(UnsafeBufferPointer(start: currPtr, count: boneIndex))
            let snapPrev = Array(UnsafeBufferPointer(start: prevPtr, count: boneIndex))
            let invDt = quality.substepRateHz > 0 ? Float(quality.substepRateHz) : 1
            snapshotLock.lock()
            latestPositionsSnapshot = snapCurr
            latestPrevPositionsSnapshot = snapPrev
            SpringBoneSleepGate.fillChainMaxVelocities(
                into: &completedChainVelocities,
                curr: snapCurr,
                prev: snapPrev,
                ranges: chainRanges,
                invDt: invDt
            )
            latestCompletedFrame = 1
            lastAppliedFrame = 0
            snapshotLock.unlock()
        }
    }

    private func updateAnimatedPositions(model: VRMModel, buffers: SpringBoneBuffers, substepIndex: Int = 0) {
        guard !rootBoneIndices.isEmpty,
              let animatedRootPositionsBuffer = animatedRootPositionsBuffer else {
            return
        }

        ensureTargetCaptureCaches(model: model)

        // Update root bone positions from pre-resolved flat cache (zero per-call allocation).
        targetRootPositions.removeAll(keepingCapacity: true)
        for node in cachedRootNodes {
            targetRootPositions.append(node.worldPosition)
        }

        // Teleportation detection: check if any root bone moved more than threshold
        let shouldResetPhysics = detectTeleportation(currentPositions: targetRootPositions, buffers: buffers)
        if shouldResetPhysics {
            resetPhysicsState(model: model, buffers: buffers, animatedPositions: targetRootPositions)
            vrmLog("⚠️ [SpringBone] Teleportation detected - physics state reset")
        }

        // Manual physics reset request (e.g., when returning to idle)
        if requestPhysicsReset {
            resetPhysicsState(model: model, buffers: buffers, animatedPositions: targetRootPositions)
            requestPhysicsReset = false
        }

        // Update last root positions in place (preserving backing storage on both arrays)
        lastRootPositions.removeAll(keepingCapacity: true)
        lastRootPositions.append(contentsOf: targetRootPositions)

        // Copy to GPU buffer at the correct aligned offset for this substep
        if !targetRootPositions.isEmpty {
            assert(substepIndex < VRMConstants.Physics.maxSubstepsPerFrame, "substepIndex \(substepIndex) exceeds max allocated capacity")
            let singleStepLength = MemoryLayout<SIMD3<Float>>.stride * targetRootPositions.count
            let byteOffset = substepIndex * alignedStepLength

            let dest = animatedRootPositionsBuffer.contents().advanced(by: byteOffset)
            dest.copyMemory(
                from: targetRootPositions,
                byteCount: singleStepLength
            )
        }

        // Capture colliders via revision-cached flat tables (includes synthetic colliders
        // and runtime sphere radius overrides) without per-call dictionary/array rebuilds (#222),
        // leaving interpolation `previous*` history untouched for warmup / non-interpolated callers.
        populateTargetColliderTransforms()

        if !targetSphereColliders.isEmpty {
            buffers.updateSphereColliders(targetSphereColliders)
        }
        if !targetCapsuleColliders.isEmpty {
            buffers.updateCapsuleColliders(targetCapsuleColliders)
        }
        if !targetPlaneColliders.isEmpty {
            buffers.updatePlaneColliders(targetPlaneColliders)
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
            wakeAllChains()
            vrmLog("⚠️ [SpringBone] Teleportation detected - physics state reset")
        }

        // Manual physics reset request
        if requestPhysicsReset {
            resetPhysicsState(model: model, buffers: buffers, animatedPositions: targetRootPositions)
            resetInterpolationState()
            requestPhysicsReset = false
            wakeAllChains()
        }

        // Update last root positions in place (preserving backing storage on both arrays)
        lastRootPositions.removeAll(keepingCapacity: true)
        lastRootPositions.append(contentsOf: targetRootPositions)
    }

    /// Resets all interpolation state to current target (prevents lerping from stale data after teleport)
    private func resetInterpolationState() {
        previousRootPositions = targetRootPositions
        previousWorldBindDirections = targetWorldBindDirections
        previousSphereColliders = targetSphereColliders
        previousCapsuleColliders = targetCapsuleColliders
        previousPlaneColliders = targetPlaneColliders
    }

    private func captureCompletedPositions(bonePosCurr: MTLBuffer?,
                                           bonePosPrev: MTLBuffer? = nil,
                                           numBones: Int,
                                           frameID: UInt64,
                                           generation: UInt64,
                                           chainRangesSnapshot: [Range<Int>]) {
        guard let bonePosCurr = bonePosCurr, numBones > 0 else {
            return
        }

        let sourcePointer = bonePosCurr.contents().bindMemory(to: SIMD3<Float>.self, capacity: numBones)

        snapshotLock.lock()
        // Discard stale GPU completions from an earlier layout generation.
        guard generation == physicsLayoutGeneration else {
            snapshotLock.unlock()
            return
        }

        if latestPositionsSnapshot.count != numBones {
            latestPositionsSnapshot = Array(repeating: SIMD3<Float>(repeating: 0), count: numBones)
        }

        latestPositionsSnapshot.withUnsafeMutableBufferPointer { destination in
            guard let dst = destination.baseAddress else { return }
            dst.update(from: sourcePointer, count: numBones)
        }

        if let bonePosPrev {
            if latestPrevPositionsSnapshot.count != numBones {
                latestPrevPositionsSnapshot = Array(repeating: SIMD3<Float>(repeating: 0), count: numBones)
            }
            let prevPointer = bonePosPrev.contents().bindMemory(to: SIMD3<Float>.self, capacity: numBones)
            latestPrevPositionsSnapshot.withUnsafeMutableBufferPointer { destination in
                guard let dst = destination.baseAddress else { return }
                dst.update(from: prevPointer, count: numBones)
            }
            let invDt = quality.substepRateHz > 0 ? Float(quality.substepRateHz) : 1
            SpringBoneSleepGate.fillChainMaxVelocities(
                into: &completedChainVelocities,
                curr: latestPositionsSnapshot,
                prev: latestPrevPositionsSnapshot,
                ranges: chainRangesSnapshot,
                invDt: invDt
            )
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
        guard let layout = activeLayout,
              let buffers = model.springBoneBuffers else {
            vrmLog("[SpringBone] writeBonesToNodes: Missing required data")
            return
        }

        // When every chain is asleep the GPU positions are unchanged from the
        // previous applied frame, so skip the CPU readback and node writeback.
        if sleepGate.allAsleep {
            return
        }

        snapshotLock.lock()
        let readyFrame = latestCompletedFrame
        let canApply = readyFrame > lastAppliedFrame
            && latestPositionsSnapshot.count >= buffers.numBones
            && !latestPositionsSnapshot.isEmpty
        if canApply {
            lastAppliedFrame = readyFrame
            if writebackPositions.count != latestPositionsSnapshot.count {
                writebackPositions.removeAll(keepingCapacity: true)
                writebackPositions.append(contentsOf: latestPositionsSnapshot)
            } else {
                writebackPositions.withUnsafeMutableBufferPointer { dst in
                    latestPositionsSnapshot.withUnsafeBufferPointer { src in
                        if let base = dst.baseAddress, let source = src.baseAddress {
                            base.update(from: source, count: src.count)
                        }
                    }
                }
            }
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
        let positions = writebackPositions

        performanceTracker?.beginPhase(.springReadback)
        defer { performanceTracker?.endPhase(.springReadback) }

        var globalBoneIndex = 0
        chainNodePositions.reserveCapacity(32)
        for (chainIndex, chain) in layout.chains.enumerated() {
            guard !chain.jointNodes.isEmpty else { continue }
            guard globalBoneIndex < positions.count else { break }

            // Skip the CPU writeback for chains that are fully asleep; their
            // node transforms are unchanged from the previous frame.
            if chainIndex < sleepGate.asleep.count && sleepGate.asleep[chainIndex] {
                globalBoneIndex += chain.jointNodes.count
                continue
            }

            chainNodePositions.removeAll(keepingCapacity: true)
            for node in chain.jointNodes {
                guard globalBoneIndex < positions.count else { break }
                defer { globalBoneIndex += 1 }
                guard let node else { continue }
                chainNodePositions.append((node, positions[globalBoneIndex], globalBoneIndex))
            }

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
        let lastIndex = nodePositions.count - 1
        for i in 0..<lastIndex {
            let (currentNode, currentPos, globalIndex) = nodePositions[i]
            let (nextNode, nextPos, _) = nodePositions[i + 1]
            defer { propagateChainNode(currentNode, nextChainNode: nextNode) }

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

            // Get parent's world rotation (CURRENT, after earlier bones in chain were updated)
            guard let parent = currentNode.parent else { continue }
            let parentRot = extractRotation(from: parent.worldMatrix)

            // NaN guard for parent rotation
            if parentRot.real.isNaN || parentRot.imag.x.isNaN ||
               parentRot.imag.y.isNaN || parentRot.imag.z.isNaN {
                vrmLogPhysics("[SpringBone] ⚠️ Parent rotation NaN, resetting node \(currentNode.name ?? "unnamed")")
                currentNode.rotation = currentNode.initialRotation
                currentNode.updateLocalMatrix()
                continue
            }

            // Step 1: Transform target direction to parent's local space
            let parentRotInv = simd_conjugate(parentRot)
            let targetDirParent = simd_act(parentRotInv, targetDir)

            // Retrieve precomputed static initial axis and inverse initial rotation,
            // falling back to live calculation if `initialRotation` was mutated after setup.
            let initialRotInv: simd_quatf
            let initialAxis: SIMD3<Float>
            let initialAxisNorm: SIMD3<Float>
            let currentInitialRot = currentNode.initialRotation
            if globalIndex < boneInitialAxes.count,
               boneInitialAxes[globalIndex].isValid,
               boneInitialAxes[globalIndex].initialRotation == currentInitialRot {
                let cached = boneInitialAxes[globalIndex]
                initialRotInv = cached.initialRotInv
                initialAxis = cached.initialAxis
                initialAxisNorm = cached.initialAxisNorm
            } else {
                guard globalIndex < boneBindDirections.count else { continue }
                let bindDirInParentSpace = boneBindDirections[globalIndex]
                if bindDirInParentSpace.x.isNaN || bindDirInParentSpace.y.isNaN || bindDirInParentSpace.z.isNaN ||
                   simd_length(bindDirInParentSpace) < 0.001 {
                    continue
                }
                initialRotInv = simd_conjugate(currentInitialRot)
                initialAxis = simd_act(initialRotInv, bindDirInParentSpace)
                initialAxisNorm = simd_normalize(initialAxis)
            }

            // Step 2: Transform target direction to bone's REST frame (bind pose local space)
            let targetDirRest = simd_act(initialRotInv, targetDirParent)

            // Step 4: Calculate "swing" rotation needed to align initial axis with target
            //
            // SOFT DEADZONE: Instead of hard cutoff, smoothly blend physics influence.
            // - Deadzone: 0.001 (1mm) - below this, use initial rotation (sleep)
            // - Fade range: 0.005 (5mm) - smooth transition to full physics
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

            // Final NaN/Inf guard before applying - reset to bind pose if calculation produced bad values
            // IMPORTANT: Check both isNaN AND isInfinite - Inf quaternions produce NaN matrices
            if newRotation.real.isNaN || newRotation.real.isInfinite ||
               newRotation.imag.x.isNaN || newRotation.imag.x.isInfinite ||
               newRotation.imag.y.isNaN || newRotation.imag.y.isInfinite ||
               newRotation.imag.z.isNaN || newRotation.imag.z.isInfinite {
                vrmLogPhysics("[SpringBone] ⚠️ Calculated rotation NaN/Inf, resetting node \(currentNode.name ?? "unnamed")")
                currentNode.rotation = currentNode.initialRotation
                currentNode.updateLocalMatrix()
                continue
            }

            #if VRM_METALKIT_ENABLE_DEBUG_PHYSICS
            if shouldLog && i == 0 {
                let newAngle = 2.0 * acos(min(abs(newRotation.real), 1.0)) * 180.0 / Float.pi
                print("[ROTATION \(rotationDiagCounter)] bone=\(globalIndex) dot=\(String(format: "%.4f", dotProduct)) disp=\(String(format: "%.4f", displacement)) weight=\(String(format: "%.2f", physicsWeight))")
                print("  newRotAngle=\(String(format: "%.2f", newAngle))° atRest=\(dotProduct > 0.9998) sleeping=\(physicsWeight < 0.001)")
            }
            #endif

            currentNode.rotation = newRotation
            currentNode.updateLocalMatrix()
        }

        // Propagate the final tip node (and any of its descendants) once after the chain loop.
        if lastIndex >= 0 {
            nodePositions[lastIndex].0.updateWorldTransform()
        }
    }

    /// Updates `node`'s world transform in O(1) without recursively walking `nextChainNode`
    /// (which will be updated in the next iteration of the chain loop), while still
    /// propagating to any side-branch children so the entire subtree remains consistent.
    @inline(__always)
    private func propagateChainNode(_ node: VRMNode, nextChainNode: VRMNode) {
        if nextChainNode.parent === node {
            node.updateWorldTransformShallow()
            if node.children.count > 1 {
                for child in node.children where child !== nextChainNode {
                    child.updateWorldTransform()
                }
            }
        } else {
            // Non-contiguous chain topology (intermediate non-spring bone): fall back to full walk.
            node.updateWorldTransform()
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

    /// Ensures the pre-resolved flat caches match `model`'s current revisions.
    private func ensureTargetCaptureCaches(model: VRMModel) {
        let modelID = ObjectIdentifier(model)
        let parentRev = VRMNode.parentHierarchyRevision.load(ordering: .relaxed)
        if cachedCacheModelID == modelID &&
           cachedSpringBoneRevision == model.springBoneRevision &&
           cachedParentHierarchyRevision == parentRev {
            return
        }
        // Re-compose layout whenever springBoneRevision or model changed so in-place
        // collider shape/node mutations (e.g. collider reattachment or offset edits)
        // propagate into the flat collider tables immediately — ONLY if the rebuilt
        // layout matches the currently allocated GPU buffers. Structural add/remove
        // changes defer to rebuildSpringBoneData so activeLayout never desyncs.
        if cachedCacheModelID != modelID || cachedSpringBoneRevision != model.springBoneRevision || activeLayout == nil {
            if let buffers = model.springBoneBuffers,
               let rebuilt = try? ComposedSpringBoneLayout.build(model: model),
               rebuilt.totalBones == buffers.numBones,
               rebuilt.chains.count == chainRanges.count {
                let counts = rebuilt.colliderCounts()
                if counts.spheres == buffers.numSpheres && counts.capsules == buffers.numCapsules {
                    activeLayout = rebuilt
                }
            }
        }
        if let layout = activeLayout {
            rebuildTargetCaptureCaches(model: model, layout: layout, parentRev: parentRev)
        }
    }

    private func rebuildTargetCaptureCaches(
        model: VRMModel,
        layout: ComposedSpringBoneLayout,
        parentRev: UInt64? = nil
    ) {
        cachedCacheModelID = ObjectIdentifier(model)
        cachedSpringBoneRevision = model.springBoneRevision
        cachedParentHierarchyRevision = parentRev ?? VRMNode.parentHierarchyRevision.load(ordering: .relaxed)

        // 1. Flat root nodes
        cachedRootNodes.removeAll(keepingCapacity: true)
        cachedRootNodes.reserveCapacity(layout.chains.count)
        for chain in layout.chains {
            if let first = chain.jointNodes.first, let rootNode = first {
                cachedRootNodes.append(rootNode)
            }
        }

        // 2. Flat bind-direction entries & precomputed static bone initial axes
        cachedBindDirEntries.removeAll(keepingCapacity: true)
        cachedBindDirEntries.reserveCapacity(boneBindDirections.count)
        boneInitialAxes.removeAll(keepingCapacity: true)
        boneInitialAxes.reserveCapacity(boneBindDirections.count)

        var boneIndex = 0
        for chain in layout.chains {
            for jointNode in chain.jointNodes {
                defer { boneIndex += 1 }
                guard boneIndex < boneBindDirections.count else { continue }
                let localBindDir = boneBindDirections[boneIndex]
                if let jointNode {
                    cachedBindDirEntries.append(CachedBindDirEntry(parent: jointNode.parent, localBindDir: localBindDir))
                    let valid = !localBindDir.x.isNaN && !localBindDir.y.isNaN && !localBindDir.z.isNaN &&
                                simd_length(localBindDir) >= 0.001
                    let initRot = jointNode.initialRotation
                    let initRotInv = simd_conjugate(initRot)
                    let initAxis = valid ? simd_act(initRotInv, localBindDir) : SIMD3<Float>(0, -1, 0)
                    let initAxisNorm = valid ? simd_normalize(initAxis) : SIMD3<Float>(0, -1, 0)
                    boneInitialAxes.append(CachedBoneInitialAxis(
                        initialRotation: initRot,
                        initialRotInv: initRotInv,
                        initialAxis: initAxis,
                        initialAxisNorm: initAxisNorm,
                        isValid: valid
                    ))
                } else {
                    cachedBindDirEntries.append(CachedBindDirEntry(parent: nil, localBindDir: localBindDir))
                    let identity = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
                    boneInitialAxes.append(CachedBoneInitialAxis(
                        initialRotation: identity,
                        initialRotInv: identity,
                        initialAxis: SIMD3<Float>(0, -1, 0),
                        initialAxisNorm: SIMD3<Float>(0, -1, 0),
                        isValid: false
                    ))
                }
            }
        }

        // 3. Pre-partitioned flat collider arrays (authored host+attachment, then cached host synthetic)
        cachedColliderGroupCount = layout.totalAuthoredColliderGroups
        cachedColliderCount = layout.authoredColliders.count

        cachedSphereColliders.removeAll(keepingCapacity: true)
        cachedCapsuleColliders.removeAll(keepingCapacity: true)
        cachedPlaneColliders.removeAll(keepingCapacity: true)

        func appendCached(_ collider: ComposedCollider) {
            switch collider.shape {
            case .sphere(let offset, let radius):
                cachedSphereColliders.append(CachedSphereEntry(
                    node: collider.node, offset: offset, radius: radius, groupMask: collider.groupMask, inside: false))
            case .insideSphere(let offset, let radius):
                cachedSphereColliders.append(CachedSphereEntry(
                    node: collider.node, offset: offset, radius: radius, groupMask: collider.groupMask, inside: true))
            case .capsule(let offset, let radius, let tail):
                cachedCapsuleColliders.append(CachedCapsuleEntry(
                    node: collider.node, offset: offset, tail: tail, radius: radius, groupMask: collider.groupMask, inside: false))
            case .insideCapsule(let offset, let radius, let tail):
                cachedCapsuleColliders.append(CachedCapsuleEntry(
                    node: collider.node, offset: offset, tail: tail, radius: radius, groupMask: collider.groupMask, inside: true))
            case .plane(let offset, let normal):
                cachedPlaneColliders.append(CachedPlaneEntry(
                    node: collider.node, offset: offset, normal: normal, groupMask: collider.groupMask))
            }
        }

        for collider in layout.authoredColliders {
            appendCached(collider)
        }
        for collider in layout.syntheticColliders {
            appendCached(collider)
        }
    }

    /// Captures all target transforms from animation for this frame
    /// Called once at the start of the frame before substep loop
    /// Captures: root positions, world bind directions, collider transforms
    private func captureTargetTransforms(model: VRMModel) {
        ensureTargetCaptureCaches(model: model)

        // 1. Capture root positions
        targetRootPositions.removeAll(keepingCapacity: true)
        for node in cachedRootNodes {
            targetRootPositions.append(node.worldPosition)
        }

        // First frame initialization
        if previousRootPositions.isEmpty || previousRootPositions.count != targetRootPositions.count {
            previousRootPositions = targetRootPositions
        }

        // 2. Capture world bind directions (transforms static bind dirs by current parent rotation)
        captureTargetWorldBindDirections()

        // 3. Capture collider transforms
        captureTargetColliderTransforms()
    }

    /// Captures world-space bind directions based on current animated parent orientations
    private func captureTargetWorldBindDirections() {
        targetWorldBindDirections.removeAll(keepingCapacity: true)
        targetWorldBindDirections.reserveCapacity(cachedBindDirEntries.count)

        for entry in cachedBindDirEntries {
            if let nodeParent = entry.parent {
                let parentRot = extractRotation(from: nodeParent.worldMatrix)
                let worldBindDir = simd_act(parentRot, entry.localBindDir)
                targetWorldBindDirections.append(simd_normalize(worldBindDir))
            } else {
                targetWorldBindDirections.append(entry.localBindDir)
            }
        }

        // First frame initialization
        if previousWorldBindDirections.isEmpty || previousWorldBindDirections.count != targetWorldBindDirections.count {
            previousWorldBindDirections = targetWorldBindDirections
        }
    }

    /// Populates `target*Colliders` from revision-cached flat tables without mutating `previous*Colliders`.
    private func populateTargetColliderTransforms() {
        targetSphereColliders.removeAll(keepingCapacity: true)
        targetCapsuleColliders.removeAll(keepingCapacity: true)
        targetPlaneColliders.removeAll(keepingCapacity: true)

        targetSphereColliders.reserveCapacity(cachedSphereColliders.count)
        for entry in cachedSphereColliders {
            let wm = entry.node.worldMatrix
            let worldRotation = simd_float3x3(
                SIMD3<Float>(wm[0][0], wm[0][1], wm[0][2]),
                SIMD3<Float>(wm[1][0], wm[1][1], wm[1][2]),
                SIMD3<Float>(wm[2][0], wm[2][1], wm[2][2])
            )
            let worldPos = SIMD3<Float>(wm[3][0], wm[3][1], wm[3][2])
            let worldCenter = worldPos + worldRotation * entry.offset
            targetSphereColliders.append(SphereCollider(
                center: worldCenter, radius: entry.radius, groupMask: entry.groupMask, inside: entry.inside))
        }

        targetCapsuleColliders.reserveCapacity(cachedCapsuleColliders.count)
        for entry in cachedCapsuleColliders {
            let wm = entry.node.worldMatrix
            let worldRotation = simd_float3x3(
                SIMD3<Float>(wm[0][0], wm[0][1], wm[0][2]),
                SIMD3<Float>(wm[1][0], wm[1][1], wm[1][2]),
                SIMD3<Float>(wm[2][0], wm[2][1], wm[2][2])
            )
            let worldPos = SIMD3<Float>(wm[3][0], wm[3][1], wm[3][2])
            let worldP0 = worldPos + worldRotation * entry.offset
            let worldP1 = worldPos + worldRotation * entry.tail
            targetCapsuleColliders.append(CapsuleCollider(
                p0: worldP0, p1: worldP1, radius: entry.radius, groupMask: entry.groupMask, inside: entry.inside))
        }

        targetPlaneColliders.reserveCapacity(cachedPlaneColliders.count)
        for entry in cachedPlaneColliders {
            let wm = entry.node.worldMatrix
            let worldRotation = simd_float3x3(
                SIMD3<Float>(wm[0][0], wm[0][1], wm[0][2]),
                SIMD3<Float>(wm[1][0], wm[1][1], wm[1][2]),
                SIMD3<Float>(wm[2][0], wm[2][1], wm[2][2])
            )
            let worldPos = SIMD3<Float>(wm[3][0], wm[3][1], wm[3][2])
            let worldPoint = worldPos + worldRotation * entry.offset
            let worldNormal = worldRotation * entry.normal
            let normalizedNormal = simd_length(worldNormal) > 0.001 ? simd_normalize(worldNormal) : SIMD3<Float>(0, 1, 0)
            targetPlaneColliders.append(PlaneCollider(
                point: worldPoint, normal: normalizedNormal, groupMask: entry.groupMask))
        }

        // Apply runtime radius overrides (e.g., for hair clipping prevention)
        if !sphereColliderRadiusOverrides.isEmpty {
            for (index, overrideRadius) in sphereColliderRadiusOverrides {
                if index < targetSphereColliders.count {
                    targetSphereColliders[index].radius = overrideRadius
                }
            }
        }
    }

    /// Captures collider transforms based on current animated node positions/orientations
    private func captureTargetColliderTransforms() {
        populateTargetColliderTransforms()

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
    /// Internal (not private) so tests can drive one substep's interpolation
    /// directly and inspect the slot it wrote.
    func interpolateAllTransforms(t: Float, buffers: SpringBoneBuffers, substepIndex: Int) {
        interpolateRootPositions(t: t, substepIndex: substepIndex)
        interpolateWorldBindDirections(t: t, buffers: buffers, substepIndex: substepIndex)
        interpolateColliders(t: t, buffers: buffers, substepIndex: substepIndex)
    }

    /// Interpolates root positions for the current substep
    private func interpolateRootPositions(t: Float, substepIndex: Int) {
        guard previousRootPositions.count == targetRootPositions.count,
              let buffer = animatedRootPositionsBuffer,
              !previousRootPositions.isEmpty else { return }

        assert(substepIndex < VRMConstants.Physics.maxSubstepsPerFrame, "substepIndex \(substepIndex) exceeds max allocated capacity")
        let byteOffset = substepIndex * alignedStepLength
        let dest = buffer.contents().advanced(by: byteOffset)

        if t >= 1.0 - 1e-6 {
            dest.copyMemory(
                from: targetRootPositions,
                byteCount: MemoryLayout<SIMD3<Float>>.stride * targetRootPositions.count
            )
            return
        }

        let ptr = dest.bindMemory(to: SIMD3<Float>.self, capacity: previousRootPositions.count)
        let tv = SIMD3<Float>(repeating: t)
        for i in 0..<previousRootPositions.count {
            // Linear interpolation: prev + t * (target - prev)
            ptr[i] = simd_mix(previousRootPositions[i], targetRootPositions[i], tv)
        }
    }

    /// Interpolates world bind directions using normalized linear interpolation (nlerp)
    /// This prevents rotational snapping during fast character turns
    private func interpolateWorldBindDirections(t: Float, buffers: SpringBoneBuffers, substepIndex: Int) {
        guard previousWorldBindDirections.count == targetWorldBindDirections.count,
              let bindDirectionsBuffer = buffers.bindDirections,
              !previousWorldBindDirections.isEmpty else { return }

        let dest = bindDirectionsBuffer.contents()
            .advanced(by: substepIndex * buffers.bindDirectionsStride)
        if t >= 1.0 - 1e-6 {
            dest.copyMemory(
                from: targetWorldBindDirections,
                byteCount: MemoryLayout<SIMD3<Float>>.stride * targetWorldBindDirections.count
            )
            return
        }

        let ptr = dest.bindMemory(to: SIMD3<Float>.self, capacity: previousWorldBindDirections.count)
        let tv = SIMD3<Float>(repeating: t)
        for i in 0..<previousWorldBindDirections.count {
            // Normalized linear interpolation (nlerp) for direction vectors
            let interpolated = simd_mix(previousWorldBindDirections[i], targetWorldBindDirections[i], tv)
            let len = simd_length(interpolated)
            ptr[i] = len > 0.001 ? interpolated / len : targetWorldBindDirections[i]
        }
    }

    /// Interpolates collider transforms for the current substep
    /// Prevents collision geometry from snapping during fast rotations
    private func interpolateColliders(t: Float, buffers: SpringBoneBuffers, substepIndex: Int) {
        let isFinalTarget = t >= 1.0 - 1e-6
        let tv = SIMD3<Float>(repeating: t)

        // Interpolate sphere colliders
        if previousSphereColliders.count == targetSphereColliders.count,
           let sphereBuffer = buffers.sphereColliders,
           !previousSphereColliders.isEmpty {
            let dest = sphereBuffer.contents()
                .advanced(by: substepIndex * buffers.sphereColliderStride)
            if isFinalTarget {
                dest.copyMemory(
                    from: targetSphereColliders,
                    byteCount: MemoryLayout<SphereCollider>.stride * targetSphereColliders.count
                )
            } else {
                let ptr = dest.bindMemory(to: SphereCollider.self, capacity: previousSphereColliders.count)
                for i in 0..<previousSphereColliders.count {
                    let prev = previousSphereColliders[i]
                    let target = targetSphereColliders[i]
                    ptr[i] = SphereCollider(
                        center: simd_mix(prev.center, target.center, tv),
                        radius: prev.radius + t * (target.radius - prev.radius),
                        groupMask: target.groupMask,
                        inside: target.inside != 0
                    )
                }
            }
        }

        // Interpolate capsule colliders
        if previousCapsuleColliders.count == targetCapsuleColliders.count,
           let capsuleBuffer = buffers.capsuleColliders,
           !previousCapsuleColliders.isEmpty {
            let dest = capsuleBuffer.contents()
                .advanced(by: substepIndex * buffers.capsuleColliderStride)
            if isFinalTarget {
                dest.copyMemory(
                    from: targetCapsuleColliders,
                    byteCount: MemoryLayout<CapsuleCollider>.stride * targetCapsuleColliders.count
                )
            } else {
                let ptr = dest.bindMemory(to: CapsuleCollider.self, capacity: previousCapsuleColliders.count)
                for i in 0..<previousCapsuleColliders.count {
                    let prev = previousCapsuleColliders[i]
                    let target = targetCapsuleColliders[i]
                    ptr[i] = CapsuleCollider(
                        p0: simd_mix(prev.p0, target.p0, tv),
                        p1: simd_mix(prev.p1, target.p1, tv),
                        radius: prev.radius + t * (target.radius - prev.radius),
                        groupMask: target.groupMask,
                        inside: target.inside != 0
                    )
                }
            }
        }

        // Interpolate plane colliders
        if previousPlaneColliders.count == targetPlaneColliders.count,
           let planeBuffer = buffers.planeColliders,
           !previousPlaneColliders.isEmpty {
            if isFinalTarget {
                planeBuffer.contents().copyMemory(
                    from: targetPlaneColliders,
                    byteCount: MemoryLayout<PlaneCollider>.stride * targetPlaneColliders.count
                )
            } else {
                let ptr = planeBuffer.contents().bindMemory(to: PlaneCollider.self, capacity: previousPlaneColliders.count)
                for i in 0..<previousPlaneColliders.count {
                    let prev = previousPlaneColliders[i]
                    let target = targetPlaneColliders[i]
                    // nlerp for normal direction
                    let interpolatedNormal = simd_mix(prev.normal, target.normal, tv)
                    let normalLen = simd_length(interpolatedNormal)
                    ptr[i] = PlaneCollider(
                        point: simd_mix(prev.point, target.point, tv),
                        normal: normalLen > 0.001 ? interpolatedNormal / normalLen : target.normal,
                        groupMask: target.groupMask
                    )
                }
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
            if let centerNode = record.centerNode, let centerID = record.centerNodeID {
                targetCenterWorldMatrices[centerID] = centerNode.worldMatrix
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
            centerDeltaScratch.removeAll(keepingCapacity: true)
            for (i, record) in centerSpringRecords.enumerated() {
                let delta: float4x4
                if let centerID = record.centerNodeID {
                    if let cached = centerDeltaScratch[centerID] {
                        delta = cached
                    } else if let prevMatrix = previousCenterWorldMatrices[centerID],
                              let targetMatrix = targetCenterWorldMatrices[centerID] {
                        if prevMatrix == targetMatrix {
                            delta = matrix_identity_float4x4
                        } else {
                            let centerAtPrev = mixMatrices(prevMatrix, targetMatrix, tPrev)
                            let centerAtCurr = mixMatrices(prevMatrix, targetMatrix, tCurr)
                            delta = centerAtCurr * centerAtPrev.inverse
                        }
                        centerDeltaScratch[centerID] = delta
                    } else {
                        delta = matrix_identity_float4x4
                        centerDeltaScratch[centerID] = delta
                    }
                } else {
                    delta = matrix_identity_float4x4
                }
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
            if let centerNode = record.centerNode, let centerID = record.centerNodeID {
                previousCenterWorldMatrices[centerID] = centerNode.worldMatrix
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
        latestPrevPositionsSnapshot.removeAll(keepingCapacity: true)
        completedChainVelocities.removeAll(keepingCapacity: true)
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
        // Drain any pending self-owned frame before touching shared buffers so a
        // late completion handler cannot overwrite the settled warmup snapshot.
        waitForPendingFrame()

        guard let buffers = model.springBoneBuffers,
              var globalParams = model.springBoneGlobalParams,
              buffers.numBones > 0 else {
            return
        }

        // Keep warmup's sphere/capsule counts consistent-by-construction with
        // update()'s expression (buffers.numSpheres/numCapsules + active
        // foreign). Warmup is a load-time settling loop that normally runs
        // before any foreign injection (activeForeign* is 0 then, so this is
        // inert), but setting it here means the two physics entry points can
        // never diverge if warmup is ever invoked after a foreign injection.
        globalParams.numSpheres = UInt32(buffers.numSpheres + activeForeignSpheres)
        globalParams.numCapsules = UInt32(buffers.numCapsules + activeForeignCapsules)

        // Settle with the authored stiffness and drag. The interactive startup
        // ramp disables stiffness for its first 60 steps, letting collisions
        // push zero-gravity hair away from its rest pose throughout a 30-step
        // warmup. Freezing that pose would preserve the displacement forever.
        globalParams.settlingFrames = 0
        model.springBoneGlobalParams?.settlingFrames = 0

        // Warmup dispatches executeXPBDStep directly, bypassing update()
        // entirely — so it never reaches update()'s sleep-gate handling. A
        // prior async-path frame on this same system may have left stale
        // sleep=1 flags in chainSleepBuffer; without this, every spring
        // kernel below early-outs on those chains while warmup's CPU-side
        // state assumes all chains are being simulated.
        wakeAllChains()

        // Step 1: Capture current animated positions for root bones
        guard let layout = activeLayout else { return }

        var animatedPositions: [SIMD3<Float>] = []
        animatedPositions.reserveCapacity(layout.chains.count)
        for chain in layout.chains {
            if let first = chain.jointNodes.first, let rootNode = first {
                animatedPositions.append(rootNode.worldPosition)
            }
        }

        // Step 2: Reset physics state to current animated positions (zeros velocity)
        resetPhysicsState(model: model, buffers: buffers, animatedPositions: animatedPositions)

        // Step 3: Also reset interpolation state to match
        resetInterpolationState()

        // Step 3.5: Fill the substep-0 center-delta slice with identity deltas.
        if !centerSpringRecords.isEmpty {
            captureTargetCenterWorldMatrices(model: model)
            for record in centerSpringRecords {
                if let centerID = record.centerNodeID,
                   let target = targetCenterWorldMatrices[centerID] {
                    previousCenterWorldMatrices[centerID] = target
                }
            }
            fillCenterDeltaBufferForFrame(substepCount: 1)
        }

        // Integrate the fixed pose with the same stiffness and drag used after
        // warmup, so the published state settles toward their equilibrium.
        // Pose, colliders, and static warmup windPhase are constant across steps,
        // so upload slot 0 once and batch all warmup steps into a single command
        // buffer (eliminating per-step collider rebuilds and CPU↔GPU stalls while
        // preserving exact sequential encoder ordering on the GPU).
        var warmupSucceeded = true
        if steps > 0 {
            let warmupDeltaTime: TimeInterval = 1.0 / 60.0  // Simulate at 60fps
            updateAnimatedPositions(model: model, buffers: buffers, substepIndex: 0)

            var params = globalParams
            params.windPhase += Float(warmupDeltaTime)
            globalParamsBuffer?.contents().copyMemory(
                from: &params,
                byteCount: MemoryLayout<SpringBoneGlobalParams>.stride
            )

            #if DEBUG
            let cbDesc = MTLCommandBufferDescriptor()
            cbDesc.errorOptions = .encoderExecutionStatus
            let warmupCB = commandQueue.makeCommandBuffer(descriptor: cbDesc)
            #else
            let warmupCB = commandQueue.makeCommandBuffer()
            #endif
            warmupCB?.label = "SpringBone Warmup"

            if let warmupCB {
                for _ in 0..<steps {
                    executeXPBDStep(
                        buffers: buffers,
                        globalParams: params,
                        sharedCommandBuffer: warmupCB,
                        substepIndex: 0,
                        registerCompletedHandler: false
                    )
                }
                warmupCB.commit()
                warmupCB.waitUntilCompleted()
                if warmupCB.status == .error {
                    warmupSucceeded = false
                    if let error = warmupCB.error {
                        vrmLogPhysics("[SpringBone] Warmup GPU command buffer failed: \(error.localizedDescription)")
                    }
                }
            } else {
                for _ in 0..<steps {
                    executeXPBDStep(buffers: buffers, globalParams: params, substepIndex: 0)
                    waitForPendingFrame()
                }
            }
        }

        guard warmupSucceeded else {
            timeAccumulator = 0
            return
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

        // Publish collision/stiffness results even when gravity is zero.
        // Gravity on an unrelated chain must not decide whether these nodes
        // receive their settled pose.
        if !settledPositions.isEmpty {
            snapshotLock.lock()
            latestPositionsSnapshot = settledPositions
            latestPrevPositionsSnapshot = settledPositions
            completedChainVelocities = Array(repeating: 0, count: chainRanges.count)
            latestCompletedFrame = 1
            lastAppliedFrame = 0
            snapshotLock.unlock()
            writeBonesToNodes(model: model)
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
