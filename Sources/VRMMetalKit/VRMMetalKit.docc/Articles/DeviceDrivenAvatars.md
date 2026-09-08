# Device-Driven Avatars

Animate a ``VRMModel`` with no tracker: hands that follow a keyboard or mouse, a mouth that follows the microphone, and poses received over VMC Protocol.

## Overview

Three building blocks cover the "move your avatar without special devices" workflow. ``ArmIKLayer`` is an ``AnimationLayer`` that solves shoulder and elbow rotations toward world-space hand targets and curls fingers. ``AudioVisemeDriver`` turns microphone PCM into the five VRM viseme weights. ``VMCDriver`` applies bone rotations and blend shapes sent by any VMC Protocol app, with ``VMCReceiver`` providing the UDP socket and ``VMCEncoder`` the sending side. Each is independent and none owns a device: the app supplies input events, audio buffers, or datagrams, and the library retargets them.

## Hands on the keyboard and mouse

Add an ``ArmIKLayer`` to the ``AnimationLayerCompositor`` and move its hand targets every frame. Targets are wrist positions in model space; the elbow bends toward ``ArmIKLayer/elbowHintDirection`` (down and back by default) unless a target carries its own hint. The layer sits above ``ArmCounterbalanceLayer`` so an explicit target wins over the procedural brace, and clearing a target returns the arm to the base pose on the next frame.

```swift
let arms = ArmIKLayer()
compositor.addArmIKLayer(arms, for: model)

// Per frame, from your keyboard/mouse mapping:
arms.leftHand = ArmIKLayer.HandTarget(position: keyPosition(for: lastKey))
arms.rightHand = ArmIKLayer.HandTarget(position: mousePosition)
arms.leftFingers = .relaxed
arms.rightFingers = ArmIKLayer.FingerCurl(thumb: 0.3, index: 0.1, middle: 0.5, ring: 0.6, little: 0.7)
```

Finger curl is a rotation about a model-space axis, converted into each phalanx's rest frame, so it does not depend on how a particular rig orients its finger bones. Override ``ArmIKLayer/fingerCurlAxis(for:)`` behaviour through ``ArmIKLayer/thumbCurlAxis`` and ``ArmIKLayer/maxFingerCurlAngle`` for rigs that need it.

## Lip-sync from the microphone

``AudioVisemeDriver`` accepts mono `Float` samples at the rate you construct it with and keeps a rolling window of ``AudioVisemeAnalyzer/Config/windowSize`` samples. Push from the audio tap and apply from the animation thread, or do both with ``AudioVisemeDriver/update(samples:controller:)``.

```swift
let lipSync = AudioVisemeDriver(sampleRate: 48_000, smoothing: .default)

// Audio tap callback:
lipSync.push(monoSamples)

// Animation frame:
lipSync.apply(to: expressionController)
```

The analyser estimates the first two formants as spectral centroids and scores each viseme against canonical F1/F2 pairs. It is a heuristic rather than a trained model: good enough to keep a mouth moving in sync with speech, and deterministic so it can be tested with synthetic tones. Tune ``AudioVisemeAnalyzer/Config/noiseGate`` and ``AudioVisemeAnalyzer/Config/fullScaleRMS`` to the input device. When a face tracker is also connected, let the tracked mouth win and use the audio driver only as the fallback.

## Receiving VMC Protocol

VMC senders (VSeeFace, Warudo, VMagicMirror, Waidayo, mocopi, iFacialMocap bridges) emit OSC over UDP, port 39539 by default. ``VMCReceiver`` decodes datagrams and hands them to ``VMCDriver``; call ``VMCDriver/apply(to:controller:)`` once per frame.

```swift
let vmc = VMCDriver()
let receiver = VMCReceiver(port: 39539, driver: vmc)
try receiver.start()

// Animation frame:
vmc.apply(to: model, controller: expressionController)
```

Rotations arrive in Unity's left-handed space. VRMMetalKit loads every model facing +Z with the left hand toward +X, which differs from Unity by a reflection of X, so ``VMCCoordinateConvention/flipX`` is the default. The driver composes each rotation relative to the bone's rest pose, so it stays correct on rigs whose rest rotations are not identity. Blend-shape names may be VRM 1.0 presets, VRM 0.x aliases (`Joy`, `A`, `Blink_L`), or ARKit names routed to custom expressions.

To send instead, ``VMCEncoder/frame(for:controller:convention:time:)`` builds one bundle describing the current pose; feeding it back through a ``VMCDriver`` reproduces the pose.

## Topics

### Arm IK

- ``ArmIKLayer``
- ``ArmIKLayer/HandTarget``
- ``ArmIKLayer/FingerCurl``
- ``AnimationLayerCompositor/addArmIKLayer(_:for:)``

### Audio lip-sync

- ``AudioVisemeDriver``
- ``AudioVisemeAnalyzer``
- ``VisemeFrame``

### VMC Protocol

- ``VMCDriver``
- ``VMCReceiver``
- ``VMCEncoder``
- ``VMCFrame``
- ``VMCCoordinateConvention``
- ``OSCPacket``
- ``OSCMessage``
- ``OSCBundle``
- ``OSCArgument``
