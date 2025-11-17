# CLAUDE.md

This file provides directives to Claude Code (claude.ai/code) when working with code in this repository.

> **For architecture, usage examples, and detailed documentation, see:**
> - [README.md](README.md) - Project overview, quick start, and API examples
> - [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) - Module structure, design patterns, and data flows
> - [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) - Build commands, workflows, and contribution guide

---

## Directives

### 1. Build & Test Commands

```bash
# Build the package
swift build

# Run tests
swift test

# Check for warnings (required before commits)
swift build --build-tests 2>&1 | tee build.log; grep -i "warning:" build.log || echo "No warnings found"

# Compile Metal shaders (after modifying .metal files)
make shaders
```

### 2. Git Workflow

After selecting a GitHub issue:
1. Create a branch: `git checkout -b feature/description-issue-N`
2. Make changes
3. Check format and build with no warnings
4. Commit with detailed message (include issue reference)
5. Push: `git push -u origin feature/description-issue-N`
6. Create PR that references the GitHub issue: `gh pr create --title "..." --body "..."`

### 3. Code Standards

**Metal Shaders:**
- All `.metal` files must be excluded from SPM compilation (see `Package.swift`)
- Run `make shaders` after any `.metal` file changes
- Uniforms structs in Metal must **exactly match** Swift structs (byte-for-byte)
- Validate struct sizes with `MetalSizeConstants` in StrictMode.swift

**Struct Layout Changes:**
- When changing `Uniforms` struct size:
  1. Update Swift struct in `VRMRenderer.swift`
  2. Update `MetalSizeConstants.uniformsSize` in `StrictMode.swift`
  3. Update **all** Metal shader `Uniforms` structs (MToonShader, SkinnedShader, Toon2DShader, Toon2DSkinnedShader)
  4. Run `make shaders`
  5. Add test to verify struct size matches

**Error Messages:**
- All errors must implement `LocalizedError` with LLM-friendly messages
- Include: what went wrong, where (file:line or index), why, how to fix, and VRM spec links
- Example format documented in docs/DEVELOPMENT.md

**Licensing:**
- All new `.swift` and `.metal` files must include Apache 2.0 header
- Verified automatically in PR checks

### 4. Testing Requirements

- Add unit tests for all new public APIs
- Test files live in `Tests/VRMMetalKitTests/`
- Test data lives in `Tests/VRMMetalKitTests/TestData/`
- All tests must pass before creating PR
- Use `swift test --filter TestClassName` for specific tests

### 5. Conditional Compilation

Debug flags (zero overhead when disabled):
- `VRM_METALKIT_ENABLE_LOGS` - General logging
- `VRM_METALKIT_ENABLE_DEBUG_ANIMATION` - Animation retargeting
- `VRM_METALKIT_ENABLE_DEBUG_PHYSICS` - SpringBone simulation
- `VRM_METALKIT_ENABLE_DEBUG_LOADER` - VRMA file parsing

**Never enable these flags for release builds.**

### 6. StrictMode Usage

- Use `.fail` mode during development to catch errors early
- When adding new rendering features, add validation to StrictMode
- ResourceIndices contract documented in `StrictMode.swift`
- See [docs/STRICT_MODE.md](docs/STRICT_MODE.md) for details

### 7. Quick Reference: Where Things Live

| Task | Location |
|------|----------|
| VRM specification types | `Core/VRMTypes.swift` |
| glTF/GLB parsing | `Loader/GLTFParser.swift` |
| VRM extensions parsing | `Loader/VRMExtensionParser.swift` |
| Main renderer | `Renderer/VRMRenderer.swift` |
| Pipeline creation | `Renderer/VRMRenderer+Pipeline.swift` |
| Metal shaders | `Shaders/*.metal` |
| Shader Swift interfaces | `Shaders/*.swift` |
| Animation playback | `Animation/AnimationPlayer.swift` |
| ARKit face tracking | `ARKit/ARKitFaceDriver.swift` |
| ARKit body tracking | `ARKit/ARKitBodyDriver.swift` |
| SpringBone physics | `SpringBone/SpringBoneComputeSystem.swift` |
| VRM builder API | `Builder/VRMBuilder.swift` |

### 8. Common Workflows

**Adding a VRM Extension:**
1. Define types in `Core/VRMTypes.swift`
2. Add parsing in `Loader/VRMExtensionParser.swift`
3. Store in `VRMModel`
4. Add error messages with spec links
5. Add tests

**Adding a Shader Feature:**
1. Implement in `Shaders/*.metal` or `Shaders/*.swift`
2. If `.metal`: Add to exclude list in `Package.swift`
3. Run `make shaders`
4. Update pipeline in `VRMRenderer+Pipeline.swift`
5. Add StrictMode validation if needed
6. Add tests

**Adding Animation Feature:**
1. Define data structures in `Animation/`
2. Add VRMA parsing to `VRMAnimationLoader.swift`
3. Integrate with `AnimationPlayer.swift`
4. Test with `-Xswiftc -DVRM_METALKIT_ENABLE_DEBUG_ANIMATION`

---

## Documentation References

- **Architecture & Design Patterns**: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
- **Development Workflows**: [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)
- **ARKit Integration Guide**: [docs/ARKitIntegration.md](docs/ARKitIntegration.md)
- **StrictMode Validation**: [docs/STRICT_MODE.md](docs/STRICT_MODE.md)
- **Shader Development**: [docs/SHADERS.md](docs/SHADERS.md)
- **Performance Tuning**: [docs/PERFORMANCE_REPORT.md](docs/PERFORMANCE_REPORT.md)
- **Concurrency Model**: [docs/CONCURRENCY.md](docs/CONCURRENCY.md)
