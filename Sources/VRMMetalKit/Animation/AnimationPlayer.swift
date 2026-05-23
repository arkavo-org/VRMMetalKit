//
// Copyright 2025 Arkavo
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//


import Foundation
import simd

/// Drives an ``AnimationClip`` against a ``VRMModel``, advancing time and writing bone, node, morph, and look-at state each frame.
///
/// ## Discussion
/// `AnimationPlayer` is the per-frame entry point for clip playback. A
/// typical integration constructs one player per avatar, loads a clip with
/// ``load(_:)``, and calls ``update(deltaTime:model:)`` once per frame from
/// the host's render loop:
///
/// ```swift
/// let player = AnimationPlayer()
/// player.load(try AnimationLibrary.loadClip(from: url, model: model))
/// // each frame
/// player.update(deltaTime: dt, model: model)
/// player.applyMorphWeights(to: expressionController)
/// ```
///
/// ### What `update` writes
/// `update(deltaTime:model:)` advances internal time by `deltaTime * speed`,
/// then for the active clip:
/// 1. Applies humanoid ``JointTrack`` samples to bones resolved via
///    `model.humanoid.getBoneNode(...)`. Translation on `.hips` is applied
///    only when ``applyRootMotion`` is `true`. VRMA-loaded clips only carry
///    translation samplers on `.hips` per the spec (``VRMAnimationLoader``
///    drops non-hips translation tracks). Hand-authored clips may include
///    translation on any humanoid bone, in which case those tracks are
///    applied unconditionally.
/// 2. Applies ``NodeTrack`` samples to non-humanoid nodes resolved by name.
/// 3. Caches morph weights for the next ``applyMorphWeights(to:)`` call.
/// 4. When ``lookAtController`` is attached and the clip carries a
///    `lookAtTargetSampler` (VRMC_vrm_animation §lookAt), look-at target
///    tracks are applied by setting
///    `controller.target = .headLocalPoint(sampler(time))`. The sampler value
///    is in head-bone-local coordinates per the VRMC_vrm_animation-1.0 spec;
///    ``VRMLookAtController`` resolves the value through the head bone's
///    world transform at update time.
/// 5. Propagates world transforms, then runs the ``ConstraintSolver`` on any
///    `VRMNodeConstraint`s the model carries and propagates again so
///    descendants see constraint output.
///
/// Morph weights are not pushed to the ``VRMExpressionController`` from
/// `update`; the caller must invoke ``applyMorphWeights(to:)`` (typically
/// immediately after `update`) so that other controllers (look-at,
/// expression mixers) can interleave their own writes.
///
/// ### Loop and finish semantics
/// When ``isLooping`` is `true` (the default), `currentTime` is sampled at
/// `fmodf(time, clip.duration)`. When it is `false`, `currentTime` is
/// clamped to `clip.duration` and playback halts (``isFinished`` flips to
/// `true`).
///
/// ### Thread safety
/// **Thread-safe.** Player-local state (speed, time, clip, morph cache) is
/// protected by an internal `NSLock`. ``update(deltaTime:model:)`` also
/// acquires the model's lock via `model.withLock`, so it cooperates with the
/// ``VRMRenderer`` even when called from a worker queue. Playback control
/// methods (``play()``, ``pause()``, ``stop()``, ``seek(to:)``,
/// ``load(_:)``) may be called from any thread; visible ordering between
/// concurrent callers is the caller's responsibility.
public final class AnimationPlayer: @unchecked Sendable {
    // Internal lock for player state (speed, time, clip)
    private let playerLock = NSLock()

    /// Playback speed multiplier. `1.0` is real-time; negative, NaN, and infinite values are normalised to `1.0`.
    public var speed: Float {
        get { playerLock.withLock { _speed } }
        set {
            playerLock.withLock {
                if newValue < 0 || newValue.isNaN || newValue.isInfinite {
                    _speed = 1.0
                } else {
                    _speed = newValue
                }
            }
        }
    }
    private var _speed: Float = 1.0

    /// Whether playback loops at the end of the clip. When `false`, ``isFinished`` flips to `true` and `update` becomes a no-op.
    public var isLooping = true
    /// When `true`, hips translation tracks are applied to the hips node; when `false` (default), hips translation is ignored so the avatar stays anchored.
    public var applyRootMotion = false

    /// Optional controller driven by the loaded clip's `lookAtTargetSampler`.
    /// When both are non-nil, each `update(deltaTime:model:)` call sets
    /// `controller.target = .headLocalPoint(sampler(currentTime))` so VRMA-authored
    /// look-at data drives the eyes end-to-end (sampler values are in head-bone
    /// local space per the VRMC_vrm_animation-1.0 spec). Held weakly to avoid a
    /// retain cycle if the controller's owner also holds the player.
    public weak var lookAtController: VRMLookAtController?

    private var currentTime: Float = 0
    private var clip: AnimationClip?
    private var isPlaying = false
    private var currentMorphWeights: [String: Float] = [:]
    private var hasLoggedFirstFrame = false
    private let constraintSolver = ConstraintSolver()

    /// Creates an idle player. No clip is loaded until ``load(_:)`` is called.
    public init() {}

    /// Loads `clip` and starts playback from time `0`.
    ///
    /// Replaces any previously loaded clip. After this call ``isFinished`` is
    /// `false` and the next ``update(deltaTime:model:)`` will begin sampling
    /// at `time = 0`.
    public func load(_ clip: AnimationClip) {
        playerLock.withLock {
            self.clip = clip
            self.currentTime = 0
            self.isPlaying = true
        }
    }

    /// Resumes playback. Has no effect if no clip is loaded.
    public func play() {
        playerLock.withLock { isPlaying = true }
    }

    /// Pauses playback without resetting time. ``play()`` resumes from the same `currentTime`.
    public func pause() {
        playerLock.withLock { isPlaying = false }
    }

    /// Pauses playback and rewinds to time `0`.
    public func stop() {
        playerLock.withLock {
            isPlaying = false
            currentTime = 0
        }
    }

    /// Seeks playback to `time` seconds. Does not toggle playing state.
    public func seek(to time: Float) {
        playerLock.withLock { currentTime = time }
    }

    /// Advances internal time and writes bone, node, morph, and look-at state to `model`.
    ///
    /// See the type-level Discussion for the full per-frame contract.
    /// Acquires both the player's internal lock and `model.withLock` so it
    /// cooperates safely with concurrent rendering on the model's lock.
    ///
    /// - Parameters:
    ///   - deltaTime: Frame delta in seconds. The clip's effective time
    ///     advance is `deltaTime * speed`.
    ///   - model: The avatar model whose nodes and constraints are updated.
    public func update(deltaTime: Float, model: VRMModel) {
        // 1. Capture player state (thread-safe)
        let (currentClip, currentSpeed, shouldUpdate) = playerLock.withLock {
            (clip, _speed, isPlaying && clip != nil)
        }

        guard shouldUpdate, let clip = currentClip else { return }

        // 2. Lock the MODEL for the duration of the update to prevent conflicts with Renderer
        model.withLock {
            playerLock.withLock {
                currentTime += deltaTime * currentSpeed
            }
            // Use local copy of time to avoid frequent locking
            let time = playerLock.withLock { currentTime }

            let localTime: Float
            if isLooping {
                localTime = fmodf(time, clip.duration)
            } else {
                localTime = min(time, clip.duration)
                if time >= clip.duration {
                    playerLock.withLock { isPlaying = false }
                }
            }

            let debugFirstFrame = !hasLoggedFirstFrame
            var updatedCount = 0

            // 1. Process Humanoid Tracks
            for track in clip.jointTracks {
                guard let humanoid = model.humanoid,
                      let nodeIndex = humanoid.getBoneNode(track.bone),
                      nodeIndex < model.nodes.count else { continue }

                let node = model.nodes[nodeIndex]
                let (rotation, translation, scale) = track.sample(at: localTime)

                if let rotation = rotation {
                    node.rotation = rotation
                }
                if let translation = translation, (applyRootMotion || track.bone != .hips) {
                    node.translation = translation
                }
                if let scale = scale {
                    node.scale = scale
                }
                node.updateLocalMatrix()
                updatedCount += 1
            }

            // 2. Process Non-Humanoid Node Tracks (hair, accessories, etc.)
            for track in clip.nodeTracks {
                if let node = model.findNodeByNormalizedName(track.nodeNameNormalized) {
                    let (rotation, translation, scale) = track.sample(at: localTime)

                    if let rotation = rotation {
                        node.rotation = rotation
                    }
                    if let translation = translation {
                        node.translation = translation
                    }
                    if let scale = scale {
                        node.scale = scale
                    }
                    node.updateLocalMatrix()
                    updatedCount += 1

                    if debugFirstFrame {
                        vrmLogAnimation("[NON-HUMANOID] Animated '\(track.nodeName)' -> node '\(node.name ?? "unnamed")'")
                    }
                }
            }

            // 3. Process Morph Tracks
            // We need to write to currentMorphWeights (AnimationPlayer state) but it's used later
            // by applyMorphWeights. Since this method updates state based on time, we can update it here.
            // Note: currentMorphWeights is local to AnimationPlayer, so we need playerLock to write it?
            // Actually, currentMorphWeights is read by applyMorphWeights which might be called from another thread.
            // So we should protect it.
            playerLock.withLock {
                currentMorphWeights.removeAll()
                for track in clip.morphTracks {
                    let weight = track.sample(at: localTime)
                    currentMorphWeights[track.key] = weight
                }
            }

            // 4. VRMA-driven lookAt: if a controller is attached and the clip
            //    has a lookAtTargetSampler (VRMC_vrm_animation §lookAt), set
            //    the controller's target. The sampler value is head-bone-local
            //    per the spec, so route through .headLocalPoint and let the
            //    controller compose with the head world transform at apply time.
            //    Skipped when sampler is nil so user-set targets (.camera /
            //    .user / .forward) are preserved.
            if let controller = lookAtController, let sampler = clip.lookAtTargetSampler {
                controller.target = .headLocalPoint(sampler(localTime))
            }

            // 5. Propagate world transforms once so aim/rotation constraints see this
            //    frame's animated source-node poses, not last frame's stale world matrices.
            model.updateNodeTransforms()

            // 5. Solve node constraints (twist bones, aim, rotation).
            if !model.nodeConstraints.isEmpty {
                constraintSolver.solve(constraints: model.nodeConstraints, nodes: model.nodes)
                // Re-propagate so descendants of constrained nodes see the constraint output.
                model.updateNodeTransforms()
            }

            if debugFirstFrame {
                vrmLogAnimation("[AnimationPlayer] Updated \(updatedCount) node matrices")
                hasLoggedFirstFrame = true
            }
        }
    }

    /// Pushes the morph weights cached by the most recent ``update(deltaTime:model:)`` to `expressionController`.
    ///
    /// Each cached `(key, weight)` is routed to ``VRMExpressionController/setExpressionWeight(_:weight:)``
    /// when `key` matches a ``VRMExpressionPreset`` raw value, otherwise to
    /// ``VRMExpressionController/setCustomExpressionWeight(_:weight:)``. A
    /// `nil` controller is a no-op.
    public func applyMorphWeights(to expressionController: VRMExpressionController?) {
        guard let controller = expressionController else { return }

        let weights = playerLock.withLock { currentMorphWeights }

        for (key, weight) in weights {
            if let preset = VRMExpressionPreset(rawValue: key) {
                controller.setExpressionWeight(preset, weight: weight)
            } else {
                controller.setCustomExpressionWeight(key, weight: weight)
            }
        }
    }

    /// One-call wrapper around `load → seek → update → applyMorphWeights`
    /// for offline harnesses and single-frame samplers.
    ///
    /// Loads `clip`, seeks to `time`, runs a zero-delta ``update(deltaTime:model:)``
    /// so all per-frame writes (joint tracks, hips translation, look-at,
    /// constraint solve, world propagation) land on `model`, and — if an
    /// `expressionController` is supplied — pushes the morph weights cached by
    /// `update` to it via ``applyMorphWeights(to:)``. When `lookAtController` is
    /// supplied it is attached to the player so the clip's
    /// `lookAtTargetSampler` (if any) drives gaze in the same call; passing
    /// `nil` leaves any previously attached controller in place.
    ///
    /// Useful for VRMA-driven test fixtures, render-sequence emitters, and
    /// any caller whose per-frame pattern is "I want this clip applied at
    /// this time, end of story." Live playback should continue to use
    /// ``update(deltaTime:model:)`` directly so frame-to-frame time
    /// accumulates naturally.
    ///
    /// - Parameters:
    ///   - clip: The animation clip to load and apply.
    ///   - time: The clip-local time to sample at, in seconds. Clamped or
    ///     wrapped by `update` per the player's ``isLooping`` setting.
    ///   - model: The avatar model whose nodes, constraints, and (via
    ///     `expressionController`) expression weights are updated.
    ///   - expressionController: Optional controller that morph weights
    ///     cached by this call are pushed to. `nil` skips the morph push.
    ///   - lookAtController: Optional look-at controller to attach for
    ///     this and subsequent updates. `nil` leaves the existing
    ///     ``lookAtController`` property untouched.
    public func applyClip(
        _ clip: AnimationClip,
        atTime time: Float,
        to model: VRMModel,
        expressionController: VRMExpressionController? = nil,
        lookAtController: VRMLookAtController? = nil
    ) {
        if let lookAt = lookAtController {
            self.lookAtController = lookAt
        }
        load(clip)
        seek(to: time)
        update(deltaTime: 0, model: model)
        if let controller = expressionController {
            applyMorphWeights(to: controller)
        }
        // VMK#294: `update` only sets `lookAtController.target`. The
        // smoothing-aware `update(deltaTime:)` tick that normally resolves
        // the target into eye-bone rotations (bone mode) or
        // `LookLeft`/`Right`/`Up`/`Down` preset weights (expression mode)
        // runs frame-by-frame in live playback — not in the offline
        // applyClip path. Without an explicit snap here, the offline
        // render frame reflects the pre-clip pose (typically rest, so
        // every gaze plan renders identical PNGs).
        self.lookAtController?.applyImmediately()
    }

    /// Current playback time in seconds. Reflects accumulated `deltaTime` from
    /// `update(deltaTime:model:)` and is reset by `seek(to:)` / `stop()` /
    /// `load(_:)`. Useful when consumers want to drive their own samplers
    /// alongside the player.
    public var time: Float {
        playerLock.withLock { currentTime }
    }

    /// Normalised playback position in [0, 1]. Wraps when ``isLooping`` is `true`; clamps to `1.0` otherwise. Returns `0` when no clip is loaded.
    public var progress: Float {
        guard let clip = playerLock.withLock({ clip }), clip.duration > 0 else { return 0 }
        let time = playerLock.withLock { currentTime }
        if isLooping {
            return fmodf(time, clip.duration) / clip.duration
        } else {
            return min(time / clip.duration, 1.0)
        }
    }

    /// `true` when a non-looping clip has reached its duration. Always `false` for looping playback and when no clip is loaded.
    public var isFinished: Bool {
        return playerLock.withLock {
            guard let clip = clip, !isLooping else { return false }
            return currentTime >= clip.duration
        }
    }
}
