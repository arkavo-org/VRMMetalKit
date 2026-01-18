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

/// AnimationPlayer controls playback of VRM animations and updates model state.
///
/// ## Thread Safety
/// **Thread-safe.** The `update` method is thread-safe as it acquires the `VRMModel`'s internal lock.
/// You can safely call `update` from a background thread while the model is being rendered on the main thread.
///
/// - Note: Playback control methods (`play`, `pause`, `seek`) modify internal state and are generally
///   safe to call from any thread, but consistent ordering depends on caller synchronization if
///   multiple threads control the *same* player instance.
public final class AnimationPlayer: @unchecked Sendable {
    // Internal lock for player state (speed, time, clip)
    private let playerLock = NSLock()

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

    public var isLooping = true
    public var applyRootMotion = false

    private var currentTime: Float = 0
    private var clip: AnimationClip?
    private var isPlaying = false
    private var currentMorphWeights: [String: Float] = [:]
    private var hasLoggedFirstFrame = false

    public init() {}

    public func load(_ clip: AnimationClip) {
        playerLock.withLock {
            self.clip = clip
            self.currentTime = 0
            self.isPlaying = true
        }
    }

    public func play() {
        playerLock.withLock { isPlaying = true }
    }

    public func pause() {
        playerLock.withLock { isPlaying = false }
    }

    public func stop() {
        playerLock.withLock {
            isPlaying = false
            currentTime = 0
        }
    }

    public func seek(to time: Float) {
        playerLock.withLock { currentTime = time }
    }

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

            // 4. Propagate World Transforms
            model.updateNodeTransforms()

            if debugFirstFrame {
                vrmLogAnimation("[AnimationPlayer] Updated \(updatedCount) node matrices")
                hasLoggedFirstFrame = true
            }
        }
    }

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

    public var progress: Float {
        guard let clip = playerLock.withLock({ clip }) else { return 0 }
        return playerLock.withLock { currentTime } / clip.duration
    }

    public var isFinished: Bool {
        return playerLock.withLock {
            guard let clip = clip, !isLooping else { return false }
            return currentTime >= clip.duration
        }
    }
}
