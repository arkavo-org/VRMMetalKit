# Getting Started with VRMMetalKit

Set up a Metal-backed VRM renderer in under twenty lines of Swift.

## Overview

This article walks through the minimum integration: adding the package, loading a VRM 1.0 avatar from disk, and drawing it into an `MTKView`. It's aimed at developers who already have a Metal-based app and want to drop in a VRM runtime without reaching for a higher-level engine.

VRMMetalKit targets **macOS 26+**, **iOS 26+**, and **visionOS 26+**, and is written in **Swift 6.2** with strict concurrency. The public surface is `Sendable`-aware. The `MTKView` entry points — ``VRMRenderer/draw(in:commandBuffer:renderPassDescriptor:)`` and ``VRMRenderer/drawOffscreenHeadless(to:depth:commandBuffer:renderPassDescriptor:)`` — are main-actor-bound, so keep that in mind when wiring the renderer into your view hierarchy. Once you have a basic frame on screen, see the sister articles linked at the bottom for animation, ARKit driving, physics, and validation.

### On visionOS

There is no `MTKView` in an immersive scene. The host owns CompositorServices (LayerRenderer, per-eye drawables, passthrough) and submits with ``VRMRenderer/encodeCompositorViews(commandBuffer:views:)``: morphs, SpringBone, and skin palettes run once, then each ``CompositorViewTarget`` rasters with its own matrices and attachments.

Set ``VRMRenderer/useReverseZ`` *and* clear the depth attachment to `0.0` (Metal defaults to `1.0`). CompositorServices projections map far→0; without both the depth test rejects every fragment. Clear color to *transparent* black so mixed immersion keeps passthrough.

``VRMRenderer/drawOffscreen(to:depth:commandBuffer:renderPassDescriptor:)`` is still valid as a per-eye fallback, but it double-steps physics and consumes two triple-buffer slots. Neither entry point is reentrant: one frame producer per renderer.

The host-owned pass descriptor is where device-quality choices live. The library stays a per-view rasterizer.

- **Foveation is required for full quality.** Set `LayerRenderer.Configuration.isFoveationEnabled = true`, `maxRenderQuality = LayerRenderer.RenderQuality(1.0)`, pass `[.foveationEnabled]` into `supportedLayouts`, and bind `pass.rasterizationRateMap = drawable.rasterizationRateMaps[viewIndex]` on every pass. A non-foveated drawable is locked to a soft system default that smears thin line art (MToon outlines, painted eye detail). Without the rate map, a foveated drawable rejects the pass.
- **MSAA is host-owned.** ``RendererConfig/sampleCount`` `= 4` only selects MSAA pipelines. On a compositor drawable the working recipe is memoryless 4× colour+depth targets that resolve into the drawable textures, with `depthResolveFilter = .min` under reverse-Z (keeps the farthest sample). `encodeCompositorViews` accepts that descriptor as-is.
- **Mixed vs full.** Transparent colour clear is correct for `.mixed` (passthrough). `.full` treats alpha < 1 and far-plane depth as “no content” and substitutes backdrop per foveation tile — visible as black, gaze-shifting blocks wherever glass blending or alpha-to-coverage leaves alpha < 1. Seal the pass with an alpha-only write of 1.0, then a depth-only write at a finite far depth masked by the depth test.
- **`UISceneInitialImmersionStyle`** must be declared in the Scene Manifest (`UIImmersionStyleMixed` for mixed). Without it the first open ignores the runtime `.immersionStyle`.

Dedicated `xros` and `xrsimulator` shader slices ship in the package. The in-repo [VisionHost](https://github.com/arkavo-org/VRMMetalKit/tree/main/VisionHost) sample renders an avatar into a mixed-immersion space over passthrough, with foveation enabled when the device supports it. Vision Pro hardware validation of `1.1.0` passed ([#87](https://github.com/arkavo-org/VRMMetalKit/issues/87)); remaining host notes and the sleep-gate A/B knobs are [#423](https://github.com/arkavo-org/VRMMetalKit/issues/423). Automated CI render assertion is [#399](https://github.com/arkavo-org/VRMMetalKit/issues/399). Crowded spatial scenes share the multi-avatar residency work in [issue #337](https://github.com/arkavo-org/VRMMetalKit/issues/337).

## Add the package

In Xcode, choose **File ▸ Add Package Dependencies…** and enter `https://github.com/arkavo-org/VRMMetalKit`. Pin to version **1.1.0** or later for visionOS; **1.0.0** remains the macOS/iOS floor.

For a `Package.swift`-based project, add the dependency directly:

```swift
.package(url: "https://github.com/arkavo-org/VRMMetalKit", from: "1.1.0")
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
