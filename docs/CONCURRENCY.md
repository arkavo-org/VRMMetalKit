# Concurrency and Thread Safety Guide

This document outlines thread safety guarantees and concurrency patterns for VRMMetalKit.

## Summary

**VRMMetalKit is NOT thread-safe by default.** All public classes are designed for single-threaded use, typically on the main thread. Some classes are marked `@unchecked Sendable` to work with async/await, but this does not imply thread-safety.

## Thread Safety by Component

### Core Classes

| Class | Thread Safety | Notes |
|-------|--------------|-------|
| `VRMModel` | ❌ NOT thread-safe | Mutable state, no synchronization |
| `VRMRenderer` | ❌ NOT thread-safe | Single-thread only, despite `@unchecked Sendable` |
| `AnimationPlayer` | ❌ NOT thread-safe | Mutates model state directly |
| `VRMExpressionController` | ⚠️ Partially safe | Reads safe, writes main-thread only |
| `VRMExpressionMixer` | ❌ NOT thread-safe | Timer-based, main thread required |
| `GLTFParser` | ✅ Thread-safe | Static methods, no shared state |

### Why `@unchecked Sendable`?

Several classes use `@unchecked Sendable` to satisfy Swift's concurrency checking while maintaining flexibility:

1. **VRMRenderer**: Allows Metal command queue operations across dispatch boundaries. The Metal command queue itself is thread-safe, but renderer state (pipelines, buffers) is not.

2. **VRMExpressionController**: Enables use in async contexts. Internal Timer callbacks use `@MainActor` to ensure thread-safe mutations.

3. **VRMExpressionMixer**: Similar to controller - works with async/await but requires main thread execution.

**Important**: `@unchecked Sendable` does NOT mean the class is thread-safe. It means "trust me, I'll handle concurrency correctly" - which in this case means "use me from one thread only."

## Safe Usage Patterns

### Pattern 1: Main Thread Rendering (Recommended)

```swift
// ✅ SAFE: Everything on main thread
class GameViewController: UIViewController {
    var renderer: VRMRenderer!
    var model: VRMModel!
    var animationPlayer: AnimationPlayer!

    func update(deltaTime: Float) {
        // All on main thread
        animationPlayer.update(deltaTime: deltaTime, model: model)
        renderer.render(model: model, in: metalView)
    }
}
```

### Pattern 2: Background Loading with Main Thread Handoff

```swift
// ✅ SAFE: Load on background, use on main
Task.detached {
    let model = try GLTFParser.loadVRM(from: url, device: device)

    // Transfer to main thread before use
    await MainActor.run {
        self.model = model
        self.renderer.model = model
    }
}
```

### Pattern 3: Dedicated Rendering Thread

```swift
// ✅ SAFE: All rendering on custom queue
let renderQueue = DispatchQueue(label: "com.app.render")

renderQueue.async {
    let renderer = VRMRenderer(device: device)
    let model = try! GLTFParser.loadVRM(from: url, device: device)

    // All subsequent operations on renderQueue only
    self.startRenderLoop(on: renderQueue, renderer: renderer, model: model)
}
```

## Unsafe Patterns to Avoid

### ❌ Concurrent Mutations

```swift
// WRONG: Renderer state modified from multiple threads
DispatchQueue.global().async {
    renderer.outlineWidth = 2.0  // Data race!
}

DispatchQueue.main.async {
    renderer.render(in: view)  // Reading while writing!
}
```

### ❌ Shared Animation Player

```swift
// WRONG: AnimationPlayer used from multiple threads
let player = AnimationPlayer()

DispatchQueue.global().async {
    player.update(deltaTime: 0.016, model: model)  // Race condition!
}

DispatchQueue.main.async {
    player.pause()  // Concurrent access!
}
```

### ❌ Background Timer Operations

```swift
// WRONG: Timer-based classes on background thread
DispatchQueue.global().async {
    let mixer = VRMExpressionMixer(controller: controller)
    mixer.setAutoBlinkEnabled(true)  // Timer won't work correctly!
}
```

## Metal-Specific Thread Safety

### Command Queue

Metal command queues are thread-safe. You can create command buffers from different threads:

```swift
// ✅ SAFE: Command buffer creation is thread-safe
DispatchQueue.global().async {
    let commandBuffer = renderer.commandQueue.makeCommandBuffer()
    // Encode work...
    commandBuffer?.commit()
}
```

### Command Encoders

Command encoders are NOT thread-safe. Each encoder must be used from a single thread:

```swift
// ❌ UNSAFE: Don't share encoders across threads
let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: desc)!

DispatchQueue.global().async {
    encoder.setVertexBuffer(buffer, offset: 0, index: 0)  // Data race!
}
```

### Metal Buffers

MTLBuffer contents can be accessed from multiple threads if you ensure proper synchronization:

```swift
// ✅ SAFE: Synchronized buffer access
let buffer = device.makeBuffer(length: 1024, options: .storageModeShared)!

DispatchQueue.global().async {
    buffer.contents().copyMemory(from: data, byteCount: data.count)
}
// Must wait for completion before accessing on another thread
```

## Recommended Architecture

For apps requiring concurrent rendering:

```swift
class RenderingSystem {
    // Separate contexts per thread
    private let renderThread = DispatchQueue(label: "com.app.render")
    private var renderer: VRMRenderer!
    private var model: VRMModel!

    // Animation on main thread
    private let animationPlayer = AnimationPlayer()

    func setup() {
        renderThread.async {
            self.renderer = VRMRenderer(device: MTLCreateSystemDefaultDevice()!)
            self.model = try! GLTFParser.loadVRM(from: url, device: self.renderer.device)
        }
    }

    func update(deltaTime: Float) {
        // Animation updates on main thread
        animationPlayer.update(deltaTime: deltaTime, model: model)

        // Render on dedicated thread
        renderThread.async {
            self.renderer.render(model: self.model, in: self.view)
        }
    }
}
```

## Future Improvements

We're considering these concurrency improvements for future versions:

1. **Actor-based API**: Migrate core classes to Swift actors for automatic isolation
2. **Immutable snapshots**: Provide copy-on-write snapshots for safe cross-thread access
3. **Explicit locks**: Add optional locking for shared use cases
4. **Thread-safe builders**: Allow model construction from background threads

## Testing Thread Safety

When in doubt, use Thread Sanitizer (TSan):

```bash
# Build with Thread Sanitizer enabled
swift build -Xswiftc -sanitize=thread

# Run tests with TSan
swift test -Xswiftc -sanitize=thread
```

TSan will detect data races at runtime and report them with stack traces.

## Resources

- [Swift Concurrency Documentation](https://docs.swift.org/swift-book/LanguageGuide/Concurrency.html)
- [Metal Threading Best Practices](https://developer.apple.com/documentation/metal/resource_objects/about_threading_metal)
- [Thread Sanitizer Guide](https://developer.apple.com/documentation/xcode/diagnosing-memory-thread-and-crash-issues-early)

## Questions?

If you're unsure about thread safety in a specific use case, please open an issue on GitHub with your code pattern and we'll provide guidance.
