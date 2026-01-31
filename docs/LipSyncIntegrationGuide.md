# LipSync Integration Guide

This guide explains how to integrate real-time lip sync (viseme-based mouth animation) into your VRMMetalKit application.

## Overview

The `LipSyncLayer` provides a way to drive mouth animations (visemes) from external audio analysis systems. This is essential for:

- **Real-time speech animation** - Animate the avatar's mouth during voice chat
- **Lip sync from audio** - Drive mouth shapes from microphone input or audio files
- **Voice assistant responses** - Animate avatars during AI-generated speech
- **VTuber applications** - Real-time avatar puppeteering

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  Your App                                                        │
│  ┌─────────────┐  ┌──────────────┐  ┌─────────────────────────┐ │
│  │Audio Engine │─▶│ Viseme Parser│─▶│     LipSyncLayer        │ │
│  │  (Muse/etc) │   │(audio→weights)│  │  setViseme(.aa, 0.8)    │ │
│  └─────────────┘  └──────────────┘  └─────────────────────────┘ │
│                                                 │                │
│  ┌──────────────────────────────────────────────┘                │
│  │                                                               │
│  ▼                                                               │
│  ┌─────────────────────────────────────────────────────────────┐│
│  │              AnimationLayerCompositor                        ││
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────────┐   ││
│  │  │ExpressionLayer│  │ LipSyncLayer │  │    IKLayer       │   ││
│  │  │  (priority 1)│  │ (priority 10)│  │  (priority 5)    │   ││
│  │  └──────────────┘  └──────────────┘  └──────────────────┘   ││
│  │                          │                                   ││
│  └──────────────────────────┼───────────────────────────────────┘│
│                             │                                    │
│  ┌──────────────────────────┼───────────────────────────────────┐│
│  │  VRMRenderer              ▼                                   ││
│  │  ┌─────────────────────────────────┐                         ││
│  │  │  expressionController           │                         ││
│  │  │  applyMorphsToController()     │◀── Call each frame      ││
│  │  └─────────────────────────────────┘                         ││
│  └───────────────────────────────────────────────────────────────┘│
└───────────────────────────────────────────────────────────────────┘
```

## Quick Start

### 1. Basic Setup

```swift
import VRMMetalKit
import Metal

class AvatarViewController: UIViewController {
    var renderer: VRMRenderer!
    var model: VRMModel!
    
    // Animation compositor and layers
    var compositor: AnimationLayerCompositor!
    var lipSyncLayer: LipSyncLayer!
    var expressionLayer: ExpressionLayer!
    
    func setupAvatar() async throws {
        // Load model and renderer (standard setup)
        let device = MTLCreateSystemDefaultDevice()!
        renderer = VRMRenderer(device: device)
        
        let modelURL = Bundle.main.url(forResource: "avatar", withExtension: "vrm")!
        model = try await VRMModel.load(from: modelURL, device: device)
        renderer.loadModel(model)
        
        // Setup animation compositor
        setupAnimationSystem()
    }
    
    func setupAnimationSystem() {
        // Create compositor
        compositor = AnimationLayerCompositor()
        compositor.setup(model: model)
        
        // Add expression layer (handles emotions, blinking)
        expressionLayer = ExpressionLayer()
        compositor.addLayer(expressionLayer)
        
        // Add lip sync layer (handles mouth visemes)
        lipSyncLayer = LipSyncLayer()
        compositor.addLayer(lipSyncLayer)
    }
}
```

### 2. Animation Loop Integration

```swift
extension AvatarViewController: MTKViewDelegate {
    
    func draw(in view: MTKView) {
        guard let commandBuffer = renderer.commandQueue.makeCommandBuffer(),
              let renderPassDescriptor = view.currentRenderPassDescriptor else {
            return
        }
        
        // 1. Update animation compositor
        let deltaTime = 1.0 / 60.0  // Or calculate actual delta time
        let context = AnimationContext(
            conversationState: isSpeaking ? .speaking : .idle
        )
        compositor.update(deltaTime: Float(deltaTime), context: context)
        
        // 2. Apply composited morphs to expression controller
        // This is the key step that bridges the compositor to the renderer
        compositor.applyMorphsToController(renderer.expressionController)
        
        // 3. Render
        renderer.draw(in: view, commandBuffer: commandBuffer,
                      renderPassDescriptor: renderPassDescriptor)
        
        commandBuffer.present(view.currentDrawable!)
        commandBuffer.commit()
    }
}
```

### 3. Driving Visemes from Audio

```swift
// Example: Receiving visemes from an audio analysis system (like Muse)
func onAudioAnalysisReceived(visemes: [String: Float]) {
    // Clear previous visemes
    lipSyncLayer.clearAllVisemes()
    
    // Set new viseme weights
    for (visemeName, weight) in visemes {
        lipSyncLayer.setViseme(named: visemeName, weight: weight)
    }
}

// Example: Direct viseme control
func speakPhoneme(_ phoneme: String) {
    // Map phonemes to VRM visemes
    let visemeMap: [String: VRMExpressionPreset] = [
        "a": .aa,   // "father"
        "i": .ih,   // "bit"
        "u": .ou,   // "boot"
        "e": .ee,   // "beet"
        "o": .oh,   // "boat"
    ]
    
    if let viseme = visemeMap[phoneme] {
        lipSyncLayer.setViseme(viseme, weight: 0.8)
    }
}

// Example: Speech ended - clear visemes
func speechEnded() {
    lipSyncLayer.clearAllVisemes()
}
```

## Advanced Usage

### Combining with Facial Expressions

```swift
// LipSyncLayer has priority 10, ExpressionLayer has priority 1
// So visemes will override expression mouth shapes, but eyes/brows from
// expressions will still show

// Set a happy expression (affects eyes, brows, mouth)
expressionLayer.setExpression(.happy, intensity: 0.7)

// Set visemes (will override the mouth part of happy expression)
lipSyncLayer.setViseme(.aa, weight: 0.8)

// Result: Happy eyes + speaking mouth
```

### Smooth Transitions

```swift
// Adjust transition speed (default: 20.0)
// Higher = faster transitions between visemes
lipSyncLayer.transitionSpeed = 30.0  // Snappy
lipSyncLayer.transitionSpeed = 10.0  // Smooth/relaxed

// The layer automatically smooths weight changes over time
// You don't need to manually interpolate
```

### Custom Viseme Names

```swift
// If your audio system uses different naming:
lipSyncLayer.setViseme(named: "mouth_a", weight: 0.8)   // Custom name
lipSyncLayer.setViseme(named: "jaw_open", weight: 0.5)  // Another custom name

// These will be passed through to the morph target system
// Make sure your VRM model has matching morph target names
```

## Integration with Muse App

If you're using the Muse app for audio-to-viseme conversion:

```swift
import Muse  // Your audio analysis framework

class MuseLipSyncBridge {
    weak var lipSyncLayer: LipSyncLayer?
    
    func setupMuseCallbacks() {
        Muse.shared.onVisemeUpdate = { [weak self] visemes in
            self?.updateLipSync(visemes: visemes)
        }
        
        Muse.shared.onSpeechStart = { [weak self] in
            // Optional: trigger speaking expression
        }
        
        Muse.shared.onSpeechEnd = { [weak self] in
            self?.lipSyncLayer?.clearAllVisemes()
        }
    }
    
    func updateLipSync(visemes: MuseVisemeData) {
        // Muse typically outputs weights for different mouth shapes
        lipSyncLayer?.clearAllVisemes()
        
        // Map Muse output to VRM visemes
        if visemes.mouthOpen > 0.1 {
            lipSyncLayer?.setViseme(.aa, weight: visemes.mouthOpen)
        }
        if visemes.mouthWide > 0.1 {
            lipSyncLayer?.setViseme(.ee, weight: visemes.mouthWide)
        }
        if visemes.mouthRound > 0.1 {
            lipSyncLayer?.setViseme(.ou, weight: visemes.mouthRound)
        }
    }
}
```

## Performance Considerations

1. **Update Rate**: Call `compositor.update()` at your render frame rate (60Hz typical)
2. **Viseme Frequency**: Update viseme weights at audio analysis rate (30-60Hz typical)
3. **Smoothing**: The layer handles smoothing internally - don't pre-smooth your inputs
4. **Clearing**: Always call `clearAllVisemes()` when speech ends to allow natural decay

## Troubleshooting

### Mouth not moving

1. Check that `applyMorphsToController()` is called each frame
2. Verify your VRM model has viseme morph targets (aa, ih, ou, ee, oh)
3. Check that weights are in range [0, 1]

### Visemes snap instead of smooth

- Adjust `transitionSpeed` property (default 20.0)
- Make sure you're not clearing and setting visemes too rapidly

### Expression eyes work but mouth doesn't

- `LipSyncLayer` overrides expression mouth shapes (by design)
- To disable: `lipSyncLayer.isEnabled = false` or remove the layer

### Custom viseme names not working

- Verify morph target names in your VRM model
- Use exact string matching (case-sensitive)

## Reference

### Viseme Presets

| Preset | Phoneme Example | Description |
|--------|-----------------|-------------|
| `.aa`  | "father"        | Mouth open wide |
| `.ih`  | "bit"           | Mouth slightly open, teeth visible |
| `.ou`  | "boot"          | Lips rounded |
| `.ee`  | "beet"          | Mouth spread wide |
| `.oh`  | "boat"          | Lips rounded, mouth open |

### LipSyncLayer API

```swift
// Set viseme by preset
func setViseme(_ viseme: VRMExpressionPreset, weight: Float)

// Set viseme by name
func setViseme(named name: String, weight: Float)

// Clear specific viseme
func clearViseme(named name: String)

// Clear all visemes
func clearAllVisemes()

// Get current weight
func weight(for name: String) -> Float

// Configuration
var transitionSpeed: Float  // Default: 20.0
var isEnabled: Bool         // Default: true
```

## See Also

- `LipSyncLayer.swift` - Source code and inline documentation
- `AnimationLayerCompositor.swift` - Layer compositing system
- `VRMExpressionPreset` - All available expression/viseme presets
