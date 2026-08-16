# VRMVisionHost

A minimal visionOS sample host that renders a VRM avatar into an **immersive
space** with Metal, through CompositorServices. Immersion is `.mixed`, so the
avatar composites over passthrough and shares the room with you rather than
replacing it — AR, not VR. There is no window.

![AvatarSample_U standing in the visionOS simulator's living room, composited over passthrough](docs/mixed-immersion.png)

*`AvatarSample_U` in the visionOS 26.5 simulator. The room is passthrough;
the avatar is VRMMetalKit rendering through CompositorServices.*

Progresses #399, which asks for a visionOS sample host. This provides the
host and a way to look at it by hand — it does not yet add the automated
render assertion that issue also wants.

## Running it

```bash
cd VisionHost
xcodegen generate
xcodebuild -project VRMVisionHost.xcodeproj -scheme VRMVisionHost \
  -destination 'platform=visionOS Simulator,name=Apple Vision Pro,OS=26.5' \
  -configuration Debug -derivedDataPath ./DerivedData build

xcrun simctl boot 'Apple Vision Pro'
xcrun simctl install booted DerivedData/Build/Products/Debug-xrsimulator/VRMVisionHost.app
xcrun simctl launch --console-pty booted org.arkavo.VRMVisionHost
xcrun simctl io booted screenshot /tmp/vision.png
```

The Xcode project, the generated `Info.plist`, and `DerivedData/` are all
build products and are gitignored — `xcodegen generate` recreates them.

To confirm the avatar is genuinely anchored in the room rather than pinned
to the viewer, move the simulator viewpoint between two screenshots (the
viewpoint controls sit at the bottom right of the simulator window). A
world-anchored avatar slides across the frame and changes aspect; a
head-locked one would not move.

## How it works

- **Immersive, not windowed.** The `Info.plist` declares
  `CPSceneSessionRoleImmersiveSpaceApplication` as the preferred scene
  session role, so the app opens straight into an `ImmersiveSpace`
  containing a `CompositorLayer`. No `WindowGroup` is ever created.
- **Mixed, not full.** The immersion style is `.mixed`, so passthrough stays
  visible behind the avatar. This works because the render pass clears
  colour to *transparent* black — an opaque clear would paint over
  passthrough and give back the fully immersive look.
- **Reverse-Z.** CompositorServices works in reverse-Z: the SDK documents
  `cp_drawable_get_depth_range` as returning "values in reverse-z ordering,
  with the value for the far plane in the vector's `x` property and the
  value for the near plane in the vector's `y`". The host therefore sets
  `VRMRenderer.useReverseZ` and clears depth to `0.0`. Without both, the
  depth test rejects every fragment and nothing appears.
- **One draw per view.** Each view supplies its own projection from
  `drawable.computeProjection(viewIndex:)` and a view matrix derived from
  the device anchor, and renders through
  `VRMRenderer.drawOffscreen(to:depth:commandBuffer:renderPassDescriptor:)`,
  which is documented for non-main-actor render loops. Attachments are
  selected via `view.textureMap`, so the code works under either the
  `layered` or `dedicated` layout.
- **Placement.** The avatar stands 1.5 m in front of the viewer. Floor
  height comes from the first tracked device pose rather than assuming the
  session origin is on the floor — in the simulator the origin is the head
  position, so assuming otherwise puts the viewer eye-to-eye with the
  avatar's shins.
- **Lighting is set explicitly.** VRMMetalKit does not supply default
  lights; a renderer with none draws the avatar black.

## Known limits

- Spring-bone physics is stepped inside the renderer's draw call, so the
  two per-frame view draws step it twice. The second step is harmless today
  only because the step uses a wall-clock delta and the second draw follows
  microseconds after the first. A host that needs exact physics pacing
  should not rely on that.
- No gesture input, no foveation, no MSAA (drawable textures are
  single-sampled).
- Only tested in the simulator. The floor-height derivation in particular
  assumes the device pose starts at eye height, which may differ on
  hardware.
