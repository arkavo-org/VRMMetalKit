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
/// The loop runs on its own thread, never the main actor, and draws through
/// ``VRMRenderer/drawOffscreen(to:depth:commandBuffer:renderPassDescriptor:)``
/// which is documented for exactly this use.
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
    private var frameIndex = 0
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

        let model = try await VRMModel.load(from: url, device: device)

        let renderer = VRMRenderer(device: device, config: RendererConfig(strict: .off))
        renderer.useReverseZ = true
        renderer.loadModel(model)

        // Lighting is an app-layer responsibility — a renderer with no lights
        // set draws the avatar black, which reads like a depth bug.
        renderer.setLight(0, direction: SIMD3<Float>(-0.2, 0.5, -0.85),
                          color: SIMD3<Float>(1.0, 1.0, 1.0), intensity: 1.0)
        renderer.disableLight(1)
        renderer.setLight(2, direction: SIMD3<Float>(0.0, 0.2, 1.0),
                          color: SIMD3<Float>(1.0, 1.0, 1.0), intensity: 0.3)
        renderer.setAmbientColor(SIMD3<Float>(0.04, 0.04, 0.04))
        renderer.setLightNormalizationMode(.radiometric)

        NSLog("[VisionHost] Avatar ready — reverse-Z enabled, layout \(layerRenderer.configuration.layout)")
        return renderer
    }

    // MARK: - Frame loop

    private func renderFrame() {
        guard let frame = layerRenderer.queryNextFrame() else { return }

        frame.startUpdate()
        frame.endUpdate()

        guard let timing = frame.predictTiming() else { return }
        LayerRenderer.Clock().wait(until: timing.optimalInputTime)

        frame.startSubmission()
        defer { frame.endSubmission() }

        let drawables = frame.queryDrawables()
        guard !drawables.isEmpty, let renderer else { return }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }

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

        for viewIndex in drawable.views.indices {
            let view = drawable.views[viewIndex]
            let map = view.textureMap
            let color = drawable.colorTextures[map.textureIndex]
            let depth = drawable.depthTextures[map.textureIndex]

            let originFromView = originFromDevice * view.transform
            renderer.viewMatrix = originFromView.inverse * originFromAvatar
            renderer.projectionMatrix = drawable.computeProjection(viewIndex: viewIndex)

            renderer.drawOffscreen(
                to: color,
                depth: depth,
                commandBuffer: commandBuffer,
                renderPassDescriptor: passDescriptor(color: color, depth: depth, slice: map.sliceIndex))
        }

            drawable.encodePresent(commandBuffer: commandBuffer)
        }

        commandBuffer.commit()
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
