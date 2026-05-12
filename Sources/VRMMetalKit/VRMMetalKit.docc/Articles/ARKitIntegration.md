# ARKit Integration

Drive a ``VRMModel`` from `ARFaceAnchor` and `ARBodyAnchor` data using the face and body drivers.

## Overview

VRMMetalKit's ARKit support is split into two independent drivers. ``ARKitFaceDriver`` consumes an ``ARKitFaceBlendShapes`` snapshot and writes weights into a ``VRMExpressionController``. ``ARKitBodyDriver`` consumes an ``ARKitBodySkeleton`` and writes parent-relative local rotations into your model's ``VRMNode`` array. Neither driver owns an `ARSession` — you feed them the data, they retarget it. That separation lets you drive a VRM from a live `ARSessionDelegate`, a recorded file, or a remote iPhone over Wi-Fi without changing the renderer-side wiring.

Smoothing is a separate concern, configured per-driver via ``SmoothingConfig`` (face) and ``SkeletonSmoothingConfig`` (body). Both drivers also reject stale data: if the snapshot's `timestamp` is older than 150 ms the update is skipped, which keeps a dropped frame from latching a frozen pose.

## Driving facial expression

After loading the model, call ``ARKitFaceDriver/initializeForModel(_:)`` once to detect Perfect Sync — if the VRM ships custom expressions named after ARKit blend shapes, the driver routes the full 52-shape signal through them; otherwise the default ``ARKitToVRMMapper`` produces the 18 standard VRM keys (5 emotion, 5 viseme, 3 blink, 4 look, neutral). No input shape is silently dropped; unmapped shapes still contribute to the neutral weight.

```swift
import ARKit
import VRMMetalKit

let faceDriver = ARKitFaceDriver(smoothing: .default)
faceDriver.initializeForModel(model)            // model: VRMModel

// In ARSessionDelegate:
func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
    guard let face = anchors.compactMap({ $0 as? ARFaceAnchor }).first else { return }

    var shapes: [String: Float] = [:]
    for (key, value) in face.blendShapes {
        shapes[key.rawValue] = value.floatValue
    }
    let snapshot = ARKitFaceBlendShapes(
        timestamp: CACurrentMediaTime(),
        shapes: shapes,
        headTransform: face.transform
    )
    faceDriver.update(blendShapes: snapshot, controller: expressionController)
}
```

## Driving body pose

`ARSkeleton3D` exposes joint transforms in two spaces: `jointModelTransforms` (anchor-relative) and `jointLocalTransforms` (parent-relative). The body driver expects **world space**, so compose `anchor.transform * jointModelTransform` before populating the dictionary. Passing anchor-relative transforms directly will rotate the avatar relative to the room instead of relative to the camera, which is almost never what you want.

```swift
let bodyDriver = ARKitBodyDriver(smoothing: .default)

func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
    guard let body = anchors.compactMap({ $0 as? ARBodyAnchor }).first else { return }
    let skeleton3D = body.skeleton

    var joints: [ARKitJoint: simd_float4x4] = [:]
    for jointName in skeleton3D.definition.jointNames {
        guard let mapped = ARKitJoint(rawValue: jointName),
              let model = skeleton3D.modelTransform(for: .init(rawValue: jointName)) else { continue }
        joints[mapped] = body.transform * model        // compose to world space
    }

    let snapshot = ARKitBodySkeleton(
        timestamp: CACurrentMediaTime(),
        joints: joints,
        isTracked: true
    )
    bodyDriver.update(skeleton: snapshot, nodes: model.nodes, humanoid: model.humanoid)
}
```

The driver does parent-relative local rotation, A-pose-to-T-pose offsets, left-side mirroring (via ``ARKitCoordinateConverter``), SLERP smoothing, and NaN rejection. It does **not** use Graham-Schmidt orthogonalization.

## Smoothing

Filter selection lives on ``SmoothingConfig`` (face, per-expression) and ``SkeletonSmoothingConfig`` (body, separate position/rotation/scale filters). Pick ``SmoothingFilter/none`` for impulse-like signals such as blinks, ``SmoothingFilter/ema(alpha:)`` for low-cost smoothing of continuous signals (the default — alpha around 0.3 for face, 0.2 for body rotation), and ``SmoothingFilter/kalman(processNoise:measurementNoise:)`` when you have time to tune Q/R against captured data. Per-case selection is documented on the ``SmoothingFilter`` symbol page.

## Coordinate handedness

``ARKitCoordinateConverter`` handles the right-handed-Y-up (ARKit) to left-handed-Y-up (VRM) conversion plus left-side mirroring. Most callers never touch it directly; the body driver invokes it internally. If you are debugging a mirror artifact on a single limb, see ``ARKitCoordinateConverter/leftSideJoints``.

## Topics

### Face driving

- ``ARKitFaceDriver``
- ``ARKitToVRMMapper``
- ``PerfectSyncCapability``
- ``PerfectSyncMapper``
- ``ARKitFaceBlendShapes``

### Body driving

- ``ARKitBodyDriver``
- ``ARKitBodySkeleton``
- ``ARKitJoint``
- ``ARKitCoordinateConverter``

### Smoothing

- ``SmoothingFilter``
- ``SmoothingConfig``
- ``SkeletonSmoothingConfig``
