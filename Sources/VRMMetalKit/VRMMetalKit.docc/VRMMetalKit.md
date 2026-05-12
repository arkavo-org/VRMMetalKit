# ``VRMMetalKit``

High-performance loading, rendering, and animation of VRM 1.0 avatars on Apple platforms, built on Metal.

## Overview

VRMMetalKit is a Swift Package that loads VRM 1.0 (and 0.0 fallback) avatars, renders them with an MToon-compliant non-photorealistic pipeline, plays VRMA animations with humanoid retargeting, simulates SpringBone physics on the GPU, and drives expressions and body pose from ARKit.

Use VRMMetalKit when you need a self-contained, Metal-native avatar runtime on macOS 26+ or iOS 26+ — for example, a virtual presence app, an avatar-based recording tool, or a creator preview surface that must match VRM 1.0 spec behavior without depending on a web stack.

## Topics

### Essentials

- ``VRMMetalKit/VRMMetalKit``
- ``VRMModel``
- ``VRMSpecVersion``
- ``VRMConstants``
- ``VRMHumanoid``
- ``VRMHumanoidBone``
- ``VRMFirstPerson``
- ``VRMFirstPersonFlag``
- ``VRMLookAt``
- ``VRMExpressions``
- <doc:GettingStarted>

### Loading

- ``VRMLoadingOptions``
- ``VRMLoadingOptimization``
- ``VRMLoadingProgress``
- ``VRMLoadingPhase``
- ``GLTFParser``
- ``VRMExtensionParser``
- ``VRMNodeConstraint``
- ``BufferLoader``
- ``BufferPreloader``
- ``TextureLoader``
- ``ParallelMeshLoader``
- ``ParallelTextureLoader``
- ``ParallelMaterialLoader``
- <doc:LoadingVRMModels>

### Building

- ``VRMBuilder``
- ``SkeletonPreset``
- ``SkeletonDefinition``
- ``BoneData``
- ``GLTFDocumentBuilder``
- ``CharacterRecipe``
- ``MaterialConfig``
- ``AccessoryConfig``
- ``RecipeError``
- ``SkeletonPresetMapper``
- ``ExpressionMapper``

### glTF Internals

- ``GLTFDocument``
- ``GLTFAsset``
- ``GLTFScene``
- ``GLTFNode``
- ``GLTFMesh``
- ``GLTFMeshExtras``
- ``GLTFPrimitive``
- ``GLTFMorphTarget``
- ``GLTFMaterial``
- ``GLTFPBRMetallicRoughness``
- ``GLTFTextureInfo``
- ``GLTFNormalTextureInfo``
- ``GLTFOcclusionTextureInfo``
- ``GLTFKHRTextureTransform``
- ``GLTFTexture``
- ``GLTFImage``
- ``GLTFSampler``
- ``GLTFBuffer``
- ``GLTFBufferView``
- ``GLTFAccessor``
- ``GLTFSparse``
- ``GLTFSparseIndices``
- ``GLTFSparseValues``
- ``GLTFSkin``
- ``GLTFAnimation``
- ``GLTFAnimationChannel``
- ``GLTFAnimationTarget``
- ``GLTFAnimationSampler``
- ``AnyCodable``

### Rendering

- ``VRMRenderer``
- ``VRMRenderer/VRMCameraMode``
- ``VRMRenderer/LightNormalizationMode``
- ``VRMRenderer/DetailLevel``
- ``RendererConfig``
- ``VRMPipelineCache``
- ``PipelineCacheError``
- ``VRMMesh``
- ``VRMPrimitive``
- ``VRMVertex``
- ``VRMNode``
- ``VRMSkin``
- ``VRMTexture``
- ``SilhouetteRenderConfig``
- ``firstPersonAnnotation(for:in:)``
- ``firstPersonAnnotationLookup(in:)``
- ``shouldRenderPrimitive(annotation:cameraMode:)``
- ``processFirstPersonAutoFlags(model:device:)``
- <doc:RenderingAvatars>

### Materials

- ``VRMMaterial``
- ``VRMMaterial/PipelineCategory``
- ``VRMMToonMaterial``
- ``VRMOutlineWidthMode``
- ``VRMShadingShiftTexture``
- ``VRMMaterialColorBind``
- ``VRMMaterialColorType``
- ``VRMTextureTransformBind``
- ``MaterialReport``
- ``VRM0MaterialProperty``

#### Shader Wrappers

- ``MToonMaterialUniforms``
- ``MToonOutlineWidthMode``
- ``SpriteShader``
- ``SpriteInstanceCPU``
- ``SpriteUniformsCPU``
- ``SpriteQuadMesh``

### Animation

- <doc:AnimationAndRetargeting>

#### Animation Clips

- ``AnimationClip``
- ``JointTrack``
- ``MorphTrack``
- ``ExpressionTrack``
- ``NodeTrack``
- ``EulerAxis``

#### Animation Playback

- ``AnimationPlayer``
- ``VRMAnimationLoader``
- ``AnimationLibrary``
- ``VRMSkinningSystem``
- ``SkinnedShader``
- ``VRMAnimationState``
- ``VRMAnimationState/BoneTransform``
- ``VRMAnimationPresets``
- ``VRMMorphTargetSystem``
- ``VRMMorphTarget``
- ``ActiveMorph``
- ``MorphTargetShader``

#### Animation Layers

- ``AnimationLayer``
- ``AnimationLayerCompositor``
- ``AnimationBlendMode``
- ``AnimationContext``
- ``LayerOutput``
- ``ProceduralBoneTransform``
- ``ProceduralConversationState``
- ``ARLookAtLayer``
- ``ExpressionLayer``
- ``IdleBreathingLayer``

#### IK and Constraints

- ``IKLayer``
- ``IKLayer/Side``
- ``IKLayer/GroundingMode``
- ``TwoBoneIKSolver``
- ``TwoBoneIKSolver/SolveResult``
- ``ConstraintSolver``
- ``FootContactDetector``
- ``FootContactDetector/Config``
- ``FootContactDetector/FootState``

### Expressions and Gaze

- ``VRMExpressionController``
- ``VRMExpressionMixer``
- ``VRMLookAtController``
- ``VRMLookAtController/State``
- ``VRMLookAtTarget``
- ``VRMExpression``
- ``VRMExpressionPreset``
- ``VRMExpressionOverrideType``
- ``VRMMorphTargetBind``
- ``VRMLookAtType``
- ``VRMLookAtRangeMap``

### Physics

- ``VRMSpringBone``
- ``VRMSpring``
- ``VRMSpringJoint``
- ``VRMCollider``
- ``VRMColliderGroup``
- ``VRMColliderShape``
- ``VRMRenderer/resetSpringBone()``
- ``VRMRenderer/applySpringBoneForce(gravity:wind:duration:)``
- <doc:SpringBonePhysics>

#### GPU Buffers

- ``SpringBoneBuffers``
- ``SpringBoneGlobalParams``
- ``BoneParams``
- ``SphereCollider``
- ``CapsuleCollider``
- ``PlaneCollider``

### ARKit

#### Face Driving

- ``ARKitFaceDriver``
- ``DriverStatistics``
- ``SourcePriorityStrategy``
- ``ARKitToVRMMapper``
- ``BlendShapeFormula``
- ``PerfectSyncMapper``
- ``PerfectSyncCapability``
- ``PerfectSyncCapability/DetectionResult``

#### Body Driving

- ``ARKitBodyDriver``
- ``ARKitBodyDriver/Statistics``
- ``ARKitBodyDriver/SourcePriority``
- ``ARKitSkeletonMapper``
- ``ARKitCoordinateConverter``

#### Sources and Data Types

- ``ARMetadataSource``
- ``ARFaceSource``
- ``ARBodySource``
- ``ARCombinedSource``
- ``ARKitFaceBlendShapes``
- ``ARKitJoint``
- ``ARKitBodySkeleton``

#### Smoothing

- ``SmoothingFilter``
- ``SmoothingConfig``
- ``SkeletonSmoothingConfig``
- ``FilterManager``
- ``SkeletonFilterManager``

- <doc:ARKitIntegration>

### Performance

- ``PerformanceMetrics``
- ``PerformanceTracker``
- ``PerformanceTracker/StateChangeType``
- ``CharacterPrioritySystem``
- ``CharacterPrioritySystem/CharacterRole``
- ``CharacterPrioritySystem/CharacterState``
- ``CharacterPrioritySystem/RenderingDecision``
- ``CharacterPrioritySystem/PerformanceBudget``
- ``CharacterPrioritySystem/PriorityStatistics``
- ``SpriteCacheSystem``
- ``SpriteCacheSystem/CachedPose``
- ``SpriteCacheSystem/CacheStatistics``
- ``Frustum``
- ``AABBTransform``

### Utilities

- ``OrthographicCamera``
- ``OrthographicCamera/Preset``
- ``OrthographicCamera/Configuration``
- ``ZFightingThresholdCalculator``
- ``DepthBiasCalculator``

### Debug

- ``BoneTrajectoryDumper``
- ``BoneTrajectoryDumper/Sample``
- ``BoneTrajectoryDumper/Sink``
- ``BoneTrajectoryDumper/DumperError``

### Validation

- ``StrictLevel``
- ``RenderFilter``
- ``StrictValidator``
- ``ResourceIndices``
- ``MetalSizeConstants``
- <doc:StrictMode>

### Errors

- ``VRMError``
- ``StrictModeError``
- ``VRMRendererError``
- ``VRMSkinningError``
- ``VRMMaterialValidationError``
- ``VRMMorphTargetError``

### Metadata

- ``VRMMeta``
- ``VRMAvatarPermission``
- ``VRMCommercialUsage``
- ``VRMCreditNotation``
- ``VRMModifyPermission``

### Migration

- <doc:MigratingFromVRM0>
