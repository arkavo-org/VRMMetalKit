# Changelog

All notable changes to VRMMetalKit are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0-rc.1] - 2026-06-14

First release candidate for the 1.0 stable API. Based on the validated `0.21.0` release.

### Added

- Full VRM 1.0 (VRMC_vrm) support with VRM 0.0 fallback.
- VRMA animation loader with rest-pose retargeting and humanoid bone mapping.
- `AnimationPlayer` with looping, speed control, and root-motion support.
- GPU SpringBone XPBD physics simulation at 120 Hz with sphere/capsule colliders.
- SpringBone collider augmentation for systemic clipping reduction (enabled by default; opt-out via `VRMLoadingOptions.augmentSpringBoneColliders`).
- MToon NPR shader with matcap, rim, outline, and `giEqualizationFactor` artistic proxy.
- ARKit face and body tracking integration.
- StrictMode validation with three severity levels.
- Performance metrics and benchmark tooling (`VRMBenchmark`).
- DocC API reference and user-facing articles at https://arkavo-org.github.io/VRMMetalKit/.
- `GLTFMetalKit` library product for glTF 2.0 PBR rendering (not covered by the 1.0 API stability promise).

### Changed

- README installation example now pins to `from: "1.0.0"`.
- VRM 0.x models are rotated to face `+Z` at load time to match the VRM 1.0 convention and Unity-origin preview behavior. Documented as a deliberate spec deviation.

### Fixed

- Debug-skinned vertex shader now clamps joint indices to `uint4(255)`, preventing OOB reads of `jointMatrices` on malformed glTF inputs.
- Skinned cull volume now follows the skeleton so animated avatars no longer vanish.
- SpringBone warmup is pose-aware, preventing hair/penetration snaps on the first animated frame.

### Known Deviations

- **MToon `giEqualizationFactor`**: implemented as a lit/shade mix on indirect albedo rather than the spec's directional GI lerp. A spec-accurate implementation requires IBL/SH infrastructure; tracked by #328.
- **VRM 0.x forward direction**: rotated 180° around Y to face `+Z`; see #299.

## [0.21.0] - 2026-06-14

Pre-release validated by the primary consumer (Avatar Muse). Ships the performance and loading-pipeline improvements listed above plus SpringBone collider augmentation.

## [0.20.0] - 2026-05-23

Previous stable 0.x milestone.

[1.0.0-rc.1]: https://github.com/arkavo-org/VRMMetalKit/releases/tag/1.0.0-rc.1
[0.21.0]: https://github.com/arkavo-org/VRMMetalKit/releases/tag/0.21.0
[0.20.0]: https://github.com/arkavo-org/VRMMetalKit/releases/tag/0.20.0
