# Architecture Decision Records (ADRs)

This directory contains Architecture Decision Records (ADRs) documenting significant architectural choices in VRMMetalKit.

## What are ADRs?

Architecture Decision Records capture important architectural decisions along with their context and consequences. They help:

- New contributors understand why the codebase is structured the way it is
- Prevent revisiting settled decisions without new information
- Document trade-offs and alternatives considered
- Provide historical context for future refactoring

## Format

Each ADR follows a consistent structure:

- **Status**: Proposed, Accepted, Deprecated, or Superseded
- **Context**: What problem are we trying to solve?
- **Decision Drivers**: What factors influenced the decision?
- **Considered Options**: What alternatives did we evaluate?
- **Decision Outcome**: What did we choose and why?
- **Consequences**: What are the positive and negative impacts?

See [000-template.md](000-template.md) for the full template.

## Index of ADRs

### Core Architecture

- [ADR-001: Metal API Selection](001-metal-api-selection.md)
  **Status:** Accepted
  **Summary:** Use Apple's Metal API as the foundation for GPU rendering instead of OpenGL, Vulkan, or SceneKit.
  **Key Decision:** Platform-specific optimization and performance take priority over cross-platform portability.

- [ADR-002: Triple-Buffered Uniform Buffers](002-triple-buffered-uniforms.md)
  **Status:** Accepted
  **Summary:** Use three rotating uniform buffers to eliminate CPU-GPU synchronization stalls.
  **Key Decision:** 3× memory overhead is acceptable for 2.2× performance improvement.

### Rendering & Performance

- [ADR-003: GPU Compute for Morph Targets](003-gpu-compute-morph-targets.md)
  **Status:** Accepted
  **Summary:** Use Metal compute shaders for blend shape morphing when 8+ morphs are active.
  **Key Decision:** Hybrid approach (CPU for ≤7 morphs, GPU for 8+) provides optimal performance across all scenarios.

- [ADR-004: XPBD for SpringBone Physics](004-xpbd-springbone-physics.md)
  **Status:** Accepted
  **Summary:** Use Extended Position-Based Dynamics (XPBD) for SpringBone physics simulation.
  **Key Decision:** Unconditional stability and GPU parallelism outweigh implementation complexity.

### Developer Experience

- [ADR-005: StrictMode Validation Framework](005-strictmode-validation.md)
  **Status:** Accepted
  **Summary:** Three-level validation system (.off, .warn, .fail) for catching rendering bugs during development.
  **Key Decision:** Custom validation framework provides better error messages and more flexibility than Metal validation alone.

- [ADR-006: Conditional Compilation for Debug Logging](006-conditional-compilation-logging.md)
  **Status:** Accepted
  **Summary:** Use conditional compilation flags to enable subsystem-specific logging with zero production overhead.
  **Key Decision:** Compile-time flags provide true zero-cost abstraction vs. runtime log levels.

## How to Use ADRs

### When Reading Code

If you encounter a design pattern or structure that seems unusual, check if there's an ADR documenting why:

```swift
// Why triple buffering? See ADR-002
let bufferIndex = frameCount % 3
```

### When Proposing Changes

Before proposing a significant architectural change:

1. Read relevant ADRs to understand existing decisions
2. Check if your proposal addresses new information or requirements
3. Document your proposal as a new ADR with status "Proposed"
4. Update existing ADRs if they're superseded

### When Writing Code

Reference ADRs in code comments for non-obvious decisions:

```swift
// Use XPBD for unconditional stability (see ADR-004)
springBoneSystem.update(deltaTime: dt)
```

## Creating a New ADR

1. Copy `000-template.md` to a new file with the next number
2. Fill in all sections (don't skip "Considered Options" or "Cons")
3. Submit for review alongside code changes
4. Update this README with the new ADR

## ADR Lifecycle

- **Proposed**: Under discussion, not yet approved
- **Accepted**: Decision made and implemented
- **Deprecated**: No longer recommended, but code may still exist
- **Superseded**: Replaced by a newer ADR (link to replacement)

## Questions?

If you have questions about an ADR or want to propose a new one, open a GitHub issue with the `architecture` label.

## Resources

- [ADR Tools](https://adr.github.io/)
- [Architecture Decision Records (Martin Fowler)](https://www.thoughtworks.com/radar/techniques/lightweight-architecture-decision-records)
- [Why ADRs?](https://github.com/joelparkerhenderson/architecture-decision-record)
