# ``VRMMetalKit``

High-performance loading, rendering, and animation of VRM 1.0 avatars on Apple platforms, built on Metal.

## Overview

VRMMetalKit is a Swift Package that loads VRM 1.0 (and 0.0 fallback) avatars, renders them with an MToon-compliant non-photorealistic pipeline, plays VRMA animations with humanoid retargeting, simulates SpringBone physics on the GPU, and drives expressions and body pose from ARKit.

Use VRMMetalKit when you need a self-contained, Metal-native avatar runtime on macOS 26+ or iOS 26+ — for example, a virtual presence app, an avatar-based recording tool, or a creator preview surface that must match VRM 1.0 spec behavior without depending on a web stack.

## Topics

### Essentials

- ``VRMMetalKit/VRMMetalKit``
- ``VRMModel``
- <doc:GettingStarted>

### Loading

- ``VRMLoadingOptions``
- <doc:LoadingVRMModels>

### Rendering

- ``VRMRenderer``
- ``RendererConfig``
- ``VRMPipelineCache``
- ``VRMMesh``
- ``VRMPrimitive``
- <doc:RenderingAvatars>

### Materials

- ``VRMMToonMaterial``
- ``VRMOutlineWidthMode``
- ``VRMShadingShiftTexture``
- ``MaterialReport``
- ``VRM0MaterialProperty``

### Animation

- ``AnimationPlayer``
- ``VRMAnimationLoader``
- ``AnimationLibrary``
- ``VRMSkinningSystem``
- ``VRMMorphTargetSystem``
- ``IKLayer``
- ``TwoBoneIKSolver``
- ``ConstraintSolver``
- ``FootContactDetector``
- ``AnimationLayerCompositor``
- <doc:AnimationAndRetargeting>

### Expressions and Gaze

- ``VRMLookAtController``
- ``VRMExpression``
- ``VRMExpressionPreset``

### Physics

- ``VRMSpringBone``
- ``VRMSpring``
- ``VRMSpringJoint``
- ``VRMCollider``
- ``VRMColliderGroup``
- ``VRMColliderShape``
- <doc:SpringBonePhysics>

### ARKit

- ``ARKitFaceDriver``
- ``ARKitBodyDriver``
- ``ARKitToVRMMapper``
- ``PerfectSyncMapper``
- ``PerfectSyncCapability``
- ``ARKitCoordinateConverter``
- ``SmoothingFilter``
- <doc:ARKitIntegration>

### Performance

- ``PerformanceMetrics``
- ``CharacterPrioritySystem``
- ``SpriteCacheSystem``

### Validation

- ``StrictLevel``
- ``RenderFilter``
- <doc:StrictMode>

### Errors

- ``VRMRendererError``

### Migration

- <doc:MigratingFromVRM0>
