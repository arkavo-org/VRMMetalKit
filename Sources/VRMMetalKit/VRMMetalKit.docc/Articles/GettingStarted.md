# Getting Started with VRMMetalKit

Set up a Metal-backed VRM renderer in under twenty lines of Swift.

## Overview

This article walks through the minimum integration: adding the package, loading a VRM 1.0 avatar from disk, and drawing it into an `MTKView`. It's aimed at developers who already have a Metal-based app and want to drop in a VRM runtime without reaching for a higher-level engine.

VRMMetalKit targets **macOS 26+**, **iOS 26+**, and **visionOS 26+**, and is written in **Swift 6.2** with strict concurrency. The public surface is `Sendable`-aware. The `MTKView` entry points — ``VRMRenderer/draw(in:commandBuffer:renderPassDescriptor:)`` and ``VRMRenderer/drawOffscreenHeadless(to:depth:commandBuffer:renderPassDescriptor:)`` — are main-actor-bound, so keep that in mind when wiring the renderer into your view hierarchy. Once you have a basic frame on screen, see the sister articles linked at the bottom for animation, ARKit driving, physics, and validation.

### On visionOS

There is no `MTKView` in an immersive scene. The host owns CompositorServices (LayerRenderer, per-eye drawables, passthrough) and submits with ``VRMRenderer/encodeCompositorViews(commandBuffer:views:)``: morphs, SpringBone, and skin palettes run once, then each ``CompositorViewTarget`` rasters with its own matrices and attachments.

Set ``VRMRenderer/useReverseZ``. CompositorServices projections map far→0; without reverse-Z the depth test rejects every fragment. Clear color to *transparent* black so mixed immersion keeps passthrough.

``VRMRenderer/drawOffscreen(to:depth:commandBuffer:renderPassDescriptor:)`` is still valid as a per-eye fallback, but it double-steps physics and consumes two triple-buffer slots. Neither entry point is reentrant: one frame producer per renderer.

Dedicated `xros` and `xrsimulator` shader slices ship in the package. The in-repo [VisionHost](https://github.com/arkavo-org/VRMMetalKit/tree/main/VisionHost) sample renders an avatar into a mixed-immersion space over passthrough. Remaining coverage gaps — an automated CI render assertion, device (not only simulator) validation — are tracked in [issue #87](https://github.com/arkavo-org/VRMMetalKit/issues/87) and [issue #399](https://github.com/arkavo-org/VRMMetalKit/issues/399). Crowded spatial scenes share the multi-avatar residency work in [issue #337](https://github.com/arkavo-org/VRMMetalKit/issues/337).

## Add the package

In Xcode, choose **File ▸ Add Package Dependencies…** and enter `https://github.com/arkavo-org/VRMMetalKit`. Pin to version **1.0.0** or later.

For a `Package.swift`-based project, add the dependency directly:

```swift
.package(url: "https://github.com/arkavo-org/VRMMetalKit", from: "1.0.0")
```

Then add `"VRMMetalKit"` to the `dependencies` of any target that needs it.

## Load and render a model

The example below uses ``VRMMetalKit/loadModel(from:device:)-(URL,_)`` to read a `.vrm` file off disk, hands the resulting ``VRMModel`` to a freshly created ``VRMRenderer``, and drives that renderer from an `MTKViewDelegate`. The class is `@MainActor` because ``VRMRenderer/draw(in:commandBuffer:renderPassDescriptor:)`` must be called from the main actor.

```swift
import VRMMetalKit
import Metal
import MetalKit

@MainActor
final class AvatarRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let renderer: VRMRenderer

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw RenderSetupError.noDevice
        }
        self.device = device
        self.commandQueue = device.makeCommandQueue()!
        self.renderer = VRMRenderer(device: device)
    }

    func load(modelURL: URL) async throws {
        let model = try await VRMMetalKit.loadModel(from: modelURL, device: device)
        renderer.loadModel(model)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard
            let drawable = view.currentDrawable,
            let descriptor = view.currentRenderPassDescriptor,
            let commandBuffer = commandQueue.makeCommandBuffer()
        else { return }

        renderer.draw(in: view, commandBuffer: commandBuffer, renderPassDescriptor: descriptor)
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

enum RenderSetupError: Error { case noDevice }
```

Set the `MTKView`'s delegate to your `AvatarRenderer` instance (with a depth attachment on the view) and call `await avatarRenderer.load(modelURL:)` once you have a file URL. The renderer ships with a default 3-point lighting rig, so the avatar is visible without further configuration.

## Next steps

- <doc:LoadingVRMModels> — VRM file format details and untrusted-input handling
- <doc:RenderingAvatars> — ``RendererConfig`` tuning, MSAA, outlines
- <doc:AnimationAndRetargeting> — playing `.vrma` clips with humanoid retargeting
- <doc:ARKitIntegration> — face and body driving from ARKit
- <doc:SpringBonePhysics> — hair and cloth physics on the GPU
- <doc:StrictMode> — runtime validation for renderer bindings
- <doc:MigratingFromVRM0> — handling 0.x files alongside 1.0
- [visionOS / VisionHost](https://github.com/arkavo-org/VRMMetalKit/tree/main/VisionHost) — mixed-immersion CompositorServices sample

## Topics

### Essential types

- ``VRMMetalKit/VRMMetalKit``
- ``VRMModel``
- ``VRMRenderer``
- ``RendererConfig``
