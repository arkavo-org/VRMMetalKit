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
public final class AnimationPlayer {
    public var speed: Float = 1.0 {
        didSet {
            if speed < 0 || speed.isNaN || speed.isInfinite {
                speed = 1.0
            }
        }
    }
    public var isLooping = true
    public var applyRootMotion = false

    private var currentTime: Float = 0
    private var clip: AnimationClip?
    private var isPlaying = false
    private var currentMorphWeights: [String: Float] = [:]
    private var hasLoggedFirstFrame = false

    public init() {}

    public func load(_ clip: AnimationClip) {
        self.clip = clip
        self.currentTime = 0
        self.isPlaying = true
    }

    public func play() {
        isPlaying = true
    }

    public func pause() {
        isPlaying = false
    }

    public func stop() {
        isPlaying = false
        currentTime = 0
    }

    public func seek(to time: Float) {
        currentTime = time
    }

    public func update(deltaTime: Float, model: VRMModel) {
        guard isPlaying, let clip = clip else {
            return
        }

        currentTime += deltaTime * speed
        let localTime: Float
        if isLooping {
            localTime = fmodf(currentTime, clip.duration)
        } else {
            localTime = min(currentTime, clip.duration)
            if currentTime >= clip.duration {
                isPlaying = false
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
        currentMorphWeights.removeAll()
        for track in clip.morphTracks {
            let weight = track.sample(at: localTime)
            currentMorphWeights[track.key] = weight
        }

        // 4. Propagate World Transforms
        model.updateNodeTransforms()

        if debugFirstFrame {
            vrmLogAnimation("[AnimationPlayer] Updated \(updatedCount) node matrices")
            hasLoggedFirstFrame = true
        }
    }

    public func applyMorphWeights(to expressionController: VRMExpressionController?) {
        guard let controller = expressionController else { return }

        for (key, weight) in currentMorphWeights {
            if let preset = VRMExpressionPreset(rawValue: key) {
                controller.setExpressionWeight(preset, weight: weight)
            } else {
                controller.setCustomExpressionWeight(key, weight: weight)
            }
        }
    }

    public var progress: Float {
        guard let clip = clip else { return 0 }
        return currentTime / clip.duration
    }

    public var isFinished: Bool {
        guard let clip = clip, !isLooping else { return false }
        return currentTime >= clip.duration
    }
}
