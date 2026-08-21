//
// Copyright 2026 Arkavo
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

import ARKit
import CompositorServices
import Metal
import QuartzCore
import VRMMetalKit
import simd

/// Drives a `VRMRenderer` from a CompositorServices frame loop.
///
/// ## Depth direction
/// CompositorServices hands back reverse-Z projections — the SDK documents
/// `cp_drawable_get_depth_range` as returning "values in reverse-z ordering,
/// with the value for the far plane in the vector's `x` property and the
/// value for the near plane in the vector's `y`". So the renderer runs with
/// ``VRMRenderer/useReverseZ`` set and every pass clears depth to `0.0`
/// (the far plane under that mapping) rather than `1.0`.
///
/// ## Threading
/// The loop runs on its own thread, never the main actor, and submits through
/// ``VRMRenderer/encodeCompositorViews(commandBuffer:views:)`` (simulate once,
/// raster per eye). ``VRMRenderer/drawOffscreen(to:depth:commandBuffer:renderPassDescriptor:)``
/// remains the single-view primitive those views are encoded with.
/// All mutable state is confined to the single render thread started by
/// ``start()``, which is why the unchecked conformance is safe — the same
/// reasoning `VRMRenderer` itself is declared under.
final class ImmersiveRenderer: @unchecked Sendable {

    private let layerRenderer: LayerRenderer
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let arSession = ARKitSession()
    private let worldTracking = WorldTrackingProvider()

    private var renderer: VRMRenderer?
    private var model: VRMModel?
    private var director: AvatarDirector?
    private var lastDirectorTime: CFTimeInterval = 0
    private var frameIndex = 0
    private let benchCompositor = VisionOSGPUBench.isRequested
    private let compositorGPU = GPUTimeBox()
    private var compositorEncode: [Double] = []
    private var compositorMeasured = 0
    private var compositorDumped = false
    private var loggedDrawable = false
    private var headLookYaw: Float = 0
    private var headLookPitch: Float = 0
    /// Floor height taken from the first tracked device pose, so the avatar
    /// stands at the viewer's feet rather than at whatever the session
    /// origin happens to be.
    private var floorY: Float?

    /// Where the avatar stands, in immersive-space coordinates. The origin
    /// is at the viewer's feet with -Z forward, and a VRM 1.0 model faces
    /// +Z, so an avatar placed down -Z faces the viewer without any yaw.
    private let avatarPosition = SIMD3<Float>(0, 0, -1.5)

    /// Distance from the floor to a standing viewer's eyes, used to derive a
    /// floor height from the device pose.
    private static let assumedEyeHeight: Float = 1.5

    init(layerRenderer: LayerRenderer) {
        self.layerRenderer = layerRenderer
        self.device = layerRenderer.device
        guard let queue = device.makeCommandQueue() else {
            fatalError("[VisionHost] Metal command queue allocation failed")
        }
        self.commandQueue = queue
    }

    /// Starts world tracking, loads the avatar, then hands the frame loop to a
    /// dedicated thread. The load is awaited here rather than bridged into the
    /// render thread with a semaphore, so no cooperative-pool thread is ever
    /// blocked and the loop starts with a renderer already in hand.
    func start() {
        Task { [self] in
            do {
                try await arSession.run([worldTracking])
            } catch {
                NSLog("[VisionHost] World tracking unavailable: \(error) — rendering from a fixed viewpoint")
            }

            let prepared: VRMRenderer
            do {
                prepared = try await loadAvatar()
            } catch {
                NSLog("[VisionHost] Avatar load failed: \(error)")
                return
            }
            Thread { self.run(prepared) }.start()
        }
    }

    private func run(_ prepared: VRMRenderer) {
        renderer = prepared

        while true {
            switch layerRenderer.state {
            case .paused:
                layerRenderer.waitUntilRunning()
            case .invalidated:
                NSLog("[VisionHost] Layer invalidated — exiting render loop")
                return
            case .running:
                renderFrame()
            @unknown default:
                return
            }
        }
    }

    // MARK: - Setup

    private func loadAvatar() async throws -> VRMRenderer {
        // Xcode's resource processing has been seen to spell a `.vrm.glb`
        // resource either way, so both forms are tried and both are named in
        // the error — a bundle-naming change should say what it looked for.
        let candidates = [("AvatarSample_U_1.0", "vrm.glb"), ("AvatarSample_U_1.0.vrm", "glb")]
        guard let url = candidates.lazy
            .compactMap({ Bundle.main.url(forResource: $0.0, withExtension: $0.1) })
            .first else {
            throw HostError.avatarMissing(candidates.map { "\($0.0).\($0.1)" })
        }

        // The GPU bench mutates spring-bone rest state. Give it its own
        // model so the live avatar does not inherit a posed or exploded rig.
        if VisionOSGPUBench.isRequested {
            let benchModel = try await VRMModel.load(from: url, device: device)
            applyDefaultSpringGravity(to: benchModel)
            VisionOSGPUBench.run(device: device, model: benchModel)
        }

        let model = try await VRMModel.load(from: url, device: device)
        applyDefaultSpringGravity(to: model)

        NSLog("[VisionHost] Metal device: \(device.name) registry=\(device.registryID)")

        let renderer = VRMRenderer(device: device, config: RendererConfig(strict: .off))
        renderer.useReverseZ = true
        // AvatarSample hair authors gravityPower = 0; bind direction is
        // straight up. Physics + the app-layer ExternalForce above is what
        // drapes it. LookAt is created disabled inside loadModel.
        renderer.enableSpringBone = true
        renderer.loadModel(model)
        if let lookAt = renderer.lookAtController {
            lookAt.enabled = true
            lookAt.target = .user
            lookAt.saccadeEnabled = false
        }
        self.model = model
        let director = AvatarDirector(model: model)
        self.director = director

        // Lighting is an app-layer responsibility — a renderer with no lights
        // set draws the avatar black, which reads like a depth bug.
        renderer.setLight(0, direction: SIMD3<Float>(-0.2, 0.5, -0.85),
                          color: SIMD3<Float>(1.0, 1.0, 1.0), intensity: 1.0)
        renderer.disableLight(1)
        renderer.setLight(2, direction: SIMD3<Float>(0.0, 0.2, 1.0),
                          color: SIMD3<Float>(1.0, 1.0, 1.0), intensity: 0.3)
        renderer.setAmbientColor(SIMD3<Float>(0.04, 0.04, 0.04))
        renderer.setLightNormalizationMode(.radiometric)

        NSLog("[VisionHost] Avatar ready — reverse-Z, spring gravity, lookAt.userEyes, \(director.clipCount) clips, layout \(layerRenderer.configuration.layout)")
        return renderer
    }

    // MARK: - Frame loop

    private func renderFrame() {
        guard let frame = layerRenderer.queryNextFrame() else { return }

        frame.startUpdate()
        let now = CACurrentMediaTime()
        let dt: Float
        if lastDirectorTime == 0 {
            dt = Float(1.0 / VisionOSStereoLayout.cadenceHz)
        } else {
            dt = min(Float(now - lastDirectorTime), 1.0 / 15.0)
        }
        lastDirectorTime = now
        if let director, let model, let renderer {
            director.update(deltaTime: dt, model: model, expressions: renderer.expressionController)
        }
        frame.endUpdate()

        guard let timing = frame.predictTiming() else { return }
        LayerRenderer.Clock().wait(until: timing.optimalInputTime)

        frame.startSubmission()
        defer { frame.endSubmission() }

        let drawables = frame.queryDrawables()
        guard !drawables.isEmpty, let renderer else { return }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        let encodeStart = benchCompositor ? CACurrentMediaTime() : 0
        if benchCompositor && !compositorDumped {
            commandBuffer.addCompletedHandler { [compositorGPU] buffer in
                let gpu = (buffer.gpuEndTime - buffer.gpuStartTime) * 1000
                if buffer.gpuStartTime.isFinite, buffer.gpuEndTime.isFinite, gpu >= 0, gpu < 10_000 {
                    compositorGPU.append(gpu)
                }
            }
        }

        // Every drawable the frame hands back is presented. Today's layouts
        // return exactly one, but a configuration that returns a drawable per
        // eye would otherwise leave the second eye black.
        for drawable in drawables {

        let sinceEpoch = LayerRenderer.Clock.Instant.epoch
            .duration(to: drawable.frameTiming.trackableAnchorTime)
        let anchorTime = Double(sinceEpoch.components.seconds)
            + Double(sinceEpoch.components.attoseconds) * 1e-18
        let anchor = worldTracking.queryDeviceAnchor(atTimestamp: anchorTime)
        if let anchor {
            drawable.deviceAnchor = anchor
        }
        if let anchor, floorY == nil {
            let eye = anchor.originFromAnchorTransform.columns.3
            floorY = eye.y - Self.assumedEyeHeight
            NSLog("[VisionHost] device at (\(eye.x), \(eye.y), \(eye.z)) — placing avatar feet at y=\(floorY!)")
        }
        frameIndex &+= 1

        // With no device anchor the viewer would sit at the floor origin,
        // eye-to-eye with the avatar's shins. Fall back to a seated eye
        // height so the framing is sensible without tracking.
        let originFromDevice = drawable.deviceAnchor?.originFromAnchorTransform
            ?? matrix_identity_float4x4
        let originFromAvatar = translation(
            SIMD3<Float>(avatarPosition.x, floorY ?? avatarPosition.y, avatarPosition.z))

        var views: [CompositorViewTarget] = []
        views.reserveCapacity(drawable.views.count)
        for viewIndex in drawable.views.indices {
            let view = drawable.views[viewIndex]
            let map = view.textureMap
            let color = drawable.colorTextures[map.textureIndex]
            let depth = drawable.depthTextures[map.textureIndex]
            let originFromView = originFromDevice * view.transform
            if !loggedDrawable {
                NSLog("[VisionHost] drawable \(color.width)x\(color.height) views=\(drawable.views.count) layout=\(layerRenderer.configuration.layout) slice=\(map.sliceIndex)")
                loggedDrawable = true
            }
            views.append(CompositorViewTarget(
                colorTexture: color,
                depthTexture: depth,
                renderPassDescriptor: passDescriptor(color: color, depth: depth, slice: map.sliceIndex),
                viewMatrix: originFromView.inverse * originFromAvatar,
                projectionMatrix: drawable.computeProjection(viewIndex: viewIndex)))
        }
        // Wearer-eye midpoint in avatar space, then turn the head toward
        // it. Avatar U's authored eye range is only ~8–12°, so eyes-only
        // look-at still reads as "staring forward" once the avatar is off
        // to one side.
        let userInAvatar = userEyeMidpoint(inAvatarSpace: views)
        if let model, let userInAvatar {
            turnHead(toward: userInAvatar, model: model, deltaTime: dt)
        }
        aimLookAt(atUserInAvatar: userInAvatar, renderer: renderer)
        // Preferred submit: morphs / SpringBone / inflight slot once, then
        // one raster per eye. Per-eye `drawOffscreen` is still valid but
        // double-steps physics and burns two triple-buffer slots.
        renderer.encodeCompositorViews(commandBuffer: commandBuffer, views: views)

            drawable.encodePresent(commandBuffer: commandBuffer)
        }

        commandBuffer.commit()

        if benchCompositor && !compositorDumped {
            compositorEncode.append((CACurrentMediaTime() - encodeStart) * 1000)
            compositorMeasured += 1
            let warmup = 30
            let measure = Int(ProcessInfo.processInfo.environment["VRM_VISIONOS_BENCH_FRAMES"] ?? "") ?? 80
            if compositorMeasured == warmup + measure {
                commandBuffer.waitUntilCompleted()
                dumpCompositorBench()
            }
        }
    }

    private func dumpCompositorBench() {
        compositorDumped = true
        let gpu = compositorGPU.snapshot()
        let encode = compositorEncode.suffix(compositorEncode.count >= 30 ? compositorEncode.count - 30 : 0)
        func median(_ xs: ArraySlice<Double>) -> Double {
            let s = xs.sorted()
            return s.isEmpty ? 0 : s[s.count / 2]
        }
        func p95(_ xs: ArraySlice<Double>) -> Double {
            let s = xs.sorted()
            guard !s.isEmpty else { return 0 }
            return s[min(s.count - 1, Int((Double(s.count) * 0.95).rounded(.down)))]
        }
        let gpuSlice = gpu.suffix(gpu.count >= 30 ? gpu.count - 30 : 0)
        NSLog("""
        [VisionOSGPUBench] compositor sample — \(device.name)
          encode median \(String(format: "%.3f", median(encode))) ms  p95 \(String(format: "%.3f", p95(encode))) ms
          gpu    median \(String(format: "%.3f", median(gpuSlice))) ms  p95 \(String(format: "%.3f", p95(gpuSlice))) ms
          frames \(encode.count)
        """)
    }

    /// Midpoint of compositor view origins, in avatar space (the same
    /// space as `VRMNode.worldMatrix`).
    private func userEyeMidpoint(inAvatarSpace views: [CompositorViewTarget]) -> SIMD3<Float>? {
        guard !views.isEmpty else { return nil }
        var sum = SIMD3<Float>.zero
        for view in views {
            let inv = view.viewMatrix.inverse
            sum += SIMD3<Float>(inv.columns.3.x, inv.columns.3.y, inv.columns.3.z)
        }
        return sum / Float(views.count)
    }

    /// Yaws / pitches the head toward the wearer. Clamped so a side view
    /// still looks like eye contact; blended over ~8 Hz so it does not
    /// fight the playlist with pops.
    private func turnHead(toward userInAvatar: SIMD3<Float>, model: VRMModel, deltaTime: Float) {
        guard let headIndex = model.humanoid?.getBoneNode(.head),
              headIndex >= 0, headIndex < model.nodes.count else { return }
        let head = model.nodes[headIndex]
        let parentWorld = head.parent?.worldMatrix ?? matrix_identity_float4x4
        let userInParent4 = parentWorld.inverse * SIMD4<Float>(userInAvatar, 1)
        let toUser = SIMD3<Float>(userInParent4.x, userInParent4.y, userInParent4.z) - head.translation
        let distance = simd_length(toUser)
        guard distance > 0.05 else { return }

        let desiredYaw = atan2(toUser.x, toUser.z)
        let desiredPitch = atan2(toUser.y, hypot(toUser.x, toUser.z))
        let maxYaw: Float = 0.9
        let maxPitch: Float = 0.35
        let targetYaw = simd_clamp(desiredYaw, -maxYaw, maxYaw)
        let targetPitch = simd_clamp(desiredPitch, -maxPitch, maxPitch)

        let follow = 1 - exp(-max(deltaTime, 1e-4) * 8)
        headLookYaw += (targetYaw - headLookYaw) * follow
        headLookPitch += (targetPitch - headLookPitch) * follow

        let yawQ = simd_quatf(angle: headLookYaw, axis: SIMD3<Float>(0, 1, 0))
        let pitchQ = simd_quatf(angle: -headLookPitch, axis: SIMD3<Float>(1, 0, 0))
        head.rotation = yawQ * pitchQ * head.initialRotation
        head.updateLocalMatrix()
        model.updateNodeTransforms()
    }

    /// Sets look-at to the wearer's eye midpoint. Uses
    /// ``VRMLookAtTarget/user`` so ``VRMRenderer`` cannot overwrite it
    /// with the first-eye camera extracted from `viewMatrix`.
    private func aimLookAt(atUserInAvatar user: SIMD3<Float>?, renderer: VRMRenderer) {
        guard let lookAt = renderer.lookAtController, let user else { return }
        lookAt.enabled = true
        lookAt.smoothing = 0.05
        lookAt.userPosition = user
        lookAt.cameraPosition = user
        lookAt.target = .user
    }

    /// Clears depth to `0.0` — the far plane under the compositor's reverse-Z
    /// range. Clearing to `1.0` here would put every fragment behind the far
    /// plane and the avatar would never appear.
    private func passDescriptor(color: MTLTexture, depth: MTLTexture, slice: Int) -> MTLRenderPassDescriptor {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = color
        descriptor.colorAttachments[0].slice = slice
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.depthAttachment.texture = depth
        descriptor.depthAttachment.slice = slice
        descriptor.depthAttachment.loadAction = .clear
        descriptor.depthAttachment.clearDepth = 0.0
        descriptor.depthAttachment.storeAction = .store
        return descriptor
    }

    // MARK: - Helpers

    private enum HostError: Error, LocalizedError {
        case avatarMissing([String])

        var errorDescription: String? {
            guard case .avatarMissing(let tried) = self else { return nil }
            return "AvatarSample_U_1.0.vrm.glb is not in the app bundle (looked for \(tried.joined(separator: ", "))). It is committed at the repository root; check that VisionHost/project.yml still references it and re-run `xcodegen generate`."
        }
    }

}

private func translation(_ t: SIMD3<Float>) -> matrix_float4x4 {
    var m = matrix_identity_float4x4
    m.columns.3 = SIMD4<Float>(t.x, t.y, t.z, 1)
    return m
}

/// App-layer `ExternalForce` (VRMC_springBone-1.0). AvatarSample joints
/// author `gravityPower = 0`, so hair otherwise settles along the bind
/// direction — a high ponytail, straight up. Matches VRMVideoRenderer.
private let defaultSpringGravityMagnitude: Float = 2.0

private func applyDefaultSpringGravity(to model: VRMModel) {
    let maxAuthored = (model.springBone?.springs ?? [])
        .flatMap { $0.joints }.map(\.gravityPower).max() ?? 0
    guard maxAuthored < 0.001 else { return }
    model.springBoneGlobalParams?.gravity = SIMD3<Float>(0, -defaultSpringGravityMagnitude, 0)
}
