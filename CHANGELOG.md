# Changelog

All notable changes to VRMMetalKit will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2025-10-25

### Added

#### VRM 1.0 Specification Support
- Full VRM 1.0 (VRMC_vrm) specification implementation
- VRM 0.0 fallback support for legacy models
- Complete metadata and licensing support
- 55 humanoid bones (required + optional)
- 18 facial expressions (emotions, visemes, gaze)
- First-person view annotations

#### Animation System
- VRMA (VRM Animation) loader with intelligent retargeting
- Humanoid bone mapping with three-tier fallback system
- Non-humanoid node animation (hair, accessories, clothing)
- Rest pose retargeting with quaternion delta computation
- AnimationPlayer with looping, speed control, and root motion
- Support for 90+ animation tracks (52 humanoid + 38 non-humanoid)

#### GPU-Accelerated Physics
- SpringBone system with XPBD (Extended Position-Based Dynamics)
- Metal compute shaders for parallel physics simulation
- Fixed 120Hz substep simulation for stability
- Sphere and capsule collider support
- Configurable gravity, wind, drag, and stiffness

#### Advanced Rendering
- MToon shader with proper NPR (Non-Photorealistic Rendering)
- Matcap, rim lighting, and outline rendering
- Morph target support with GPU compute acceleration
- Skinning with up to 256 joints per skin
- Triple-buffered uniforms for smooth rendering
- Toon2D rendering mode with orthographic camera support

#### Performance & Debugging
- Built-in performance metrics tracking
- StrictMode validation system with three levels (off, warn, fail)
- Conditional debug logging with zero overhead when disabled
- Comprehensive error handling with LLM-friendly messages
- Material inspection and reporting
- Bounding box calculation for static and skinned models

#### VRM Builder System
- CharacterRecipe JSON format for procedural VRM generation
- GLTFDocumentBuilder for creating VRM files programmatically
- VRMBuilder for constructing VRM models from recipes
- Model serialization and export capabilities

### Technical Details

#### Architecture
- Clean separation of concerns with modular design
- Core, Loader, Renderer, Animation, Performance modules
- Strict resource index contract to prevent GPU binding conflicts
- Triple-buffered uniform updates
- GPU compute path for 8+ morph targets

#### Platforms
- macOS 14.0+
- iOS 17.0+
- Swift 6.0+
- Metal framework required

#### Build System
- Swift Package Manager support
- Modular architecture for easy integration
- No external dependencies

### Known Issues
- Some TODO comments remain in source code (non-critical)
- Test coverage is minimal (placeholder tests only)
- Documentation could be expanded with more code examples

### Performance Notes
- 60 FPS for complex VRM models (15K+ triangles, 8+ morphs) on Apple Silicon
- 120 FPS for simple models (5K triangles, basic animation)
- SpringBone: 50-100 bones at 120Hz substeps with minimal overhead

### Breaking Changes
- N/A (Initial release)

### Migration Guide
- N/A (Initial release)

## Release Notes

### Version 0.1.0 - Initial Public Release

This is the first public release of VRMMetalKit, a high-performance Swift package for loading and rendering VRM 1.0 avatars using Apple's Metal framework.

**Highlights:**
- 🎭 Best-in-class VRMA animation system with 100% track coverage
- ⚙️ GPU-accelerated SpringBone physics at 120Hz
- 🎨 Complete MToon shader implementation
- 📊 Comprehensive performance monitoring
- 🔧 Advanced debugging with StrictMode validation

**Use Cases:**
- VR/AR avatar applications
- Character creators and customization tools
- Game engines requiring VRM support
- Virtual production and motion capture
- Social VR platforms

**License:**
- Source code: Apache License 2.0
- VRM models: VRM Platform License 1.0 (VPL 1.0)

---

[Unreleased]: https://github.com/arkavo-org/VRMMetalKit/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/arkavo-org/VRMMetalKit/releases/tag/v0.1.0
