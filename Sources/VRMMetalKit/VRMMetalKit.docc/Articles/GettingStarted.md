# Getting Started with VRMMetalKit

Set up a Metal-backed VRM renderer in under twenty lines of Swift.

## Overview

This article walks through the minimum integration: adding the package, loading a VRM 1.0 avatar from disk, and drawing it into an `MTKView`. It's aimed at developers who already have a Metal-based app and want to drop in a VRM runtime without reaching for a higher-level engine.

VRMMetalKit targets **macOS 26+** and **iOS 26+** and is written in **Swift 6.2** with strict concurrency. The public surface is `Sendable`-aware, but the renderer itself is main-actor-bound — keep that in mind when wiring it into your view hierarchy. Once you have a basic frame on screen, see the sister articles linked at the bottom for animation, ARKit driving, physics, and validation.

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

Set `view.delegate = AvatarRenderer()` on an `MTKView` with a depth attachment and call `await renderer.load(modelURL:)` once you have a file URL. The renderer ships with a default 3-point lighting rig, so the avatar is visible without further configuration.

## Next steps

- <doc:LoadingVRMModels> — VRM file format details and untrusted-input handling
- <doc:RenderingAvatars> — ``RendererConfig`` tuning, MSAA, outlines
- <doc:AnimationAndRetargeting> — playing `.vrma` clips with humanoid retargeting
- <doc:ARKitIntegration> — face and body driving from ARKit
- <doc:SpringBonePhysics> — hair and cloth physics on the GPU
- <doc:StrictMode> — runtime validation for renderer bindings
- <doc:MigratingFromVRM0> — handling 0.x files alongside 1.0

## Topics

### Essential types

- ``VRMMetalKit/VRMMetalKit``
- ``VRMModel``
- ``VRMRenderer``
- ``RendererConfig``
