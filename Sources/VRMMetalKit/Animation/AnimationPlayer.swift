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
/// **NOT thread-safe.** AnimationPlayer must be used from a single thread (typically the main thread).
///
/// ### Rationale:
/// - Mutates internal playback state (currentTime, isPlaying) without synchronization
/// - Updates VRMModel node transforms directly during `update(deltaTime:model:)`
/// - Caches node lookups in dictionaries that are not thread-safe
///
/// ### Safe Usage Patterns:
/// ```swift
/// // ✅ SAFE: Update loop on main thread
/// func gameLoop(deltaTime: Float) {
///     animationPlayer.update(deltaTime: deltaTime, model: model)
/// }
///
/// // ✅ SAFE: Control playback from main thread
/// animationPlayer.play()
/// animationPlayer.speed = 2.0
///
/// // ❌ UNSAFE: Concurrent access from multiple threads
/// DispatchQueue.global().async {
///     animationPlayer.pause()  // Data race with update() on main thread!
/// }
/// ```
///
/// ### Integration with Rendering:
/// Ensure animation updates happen before rendering on the same thread:
/// ```swift
/// // 1. Update animation (modifies model.nodes)
/// animationPlayer.update(deltaTime: dt, model: model)
///
/// // 2. Render with updated transforms
/// renderer.render(model: model, in: view)
/// ```
///
/// - Note: Loading animation clips (`load(_:)`) is safe from any thread if the player is not active.
public final class AnimationPlayer {
    public var speed: Float = 1.0
    public var isLooping = true
    public var applyRootMotion = false

    private var currentTime: Float = 0
    private var clip: AnimationClip?
    private var isPlaying = false
    private var currentMorphWeights: [String: Float] = [:]
    private var hasLoggedFirstFrame = false

    // PERFORMANCE: Cache node lookups to avoid string operations every frame
    // Using Optional wrapper to distinguish "not cached yet" from "cached as nil"
    private var nodeTrackCache: [String: VRMNode?] = [:]
    private var nodeTrackCached: Set<String> = []  // Track which keys we've looked up

    public init() {}

    public func load(_ clip: AnimationClip) {
        self.clip = clip
        self.currentTime = 0
        self.isPlaying = true
        self.nodeTrackCache.removeAll()  // Clear cache when loading new clip
        self.nodeTrackCached.removeAll()
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

    public func update(deltaTime: Float, model: VRMModel) {
        guard isPlaying, let clip = clip else {
            if currentTime < 0.1 {
                vrmLog("[AnimationPlayer] NOT PLAYING! isPlaying=\(isPlaying), clip=\(clip != nil)")
            }
            return
        }

        currentTime += deltaTime * speed

        // Debug: Log update order
        if Int(currentTime * 10) % 10 == 0 {
            vrmLogAnimation("[UPDATE ORDER] 1. AnimationPlayer.update() at t=\(currentTime)")
        }

        if !hasLoggedFirstFrame {
            vrmLogAnimation("[AnimationPlayer] IS PLAYING! Processing \(clip.jointTracks.count) joint tracks")
        }

        let localTime: Float
        if isLooping {
            localTime = fmodf(currentTime, clip.duration)
        } else {
            localTime = min(currentTime, clip.duration)
            if currentTime >= clip.duration {
                isPlaying = false
            }
        }

        // Debug flag for first frame
        let debugFirstFrame = !hasLoggedFirstFrame
        if debugFirstFrame {
            vrmLogAnimation("[AnimationPlayer] Starting bone update loop, debugFirstFrame=true")
            vrmLogAnimation("[AnimationPlayer] clip.jointTracks.count = \(clip.jointTracks.count)")

            // CRITICAL: Verify we're using the correct humanoid mapping
            if let humanoid = model.humanoid {
                vrmLogAnimation("[HUMANOID VERIFICATION] Checking bone mappings:")
                for bone in [VRMHumanoidBone.hips, .spine, .chest, .head, .leftUpperArm, .rightUpperArm] {
                    if let nodeIndex = humanoid.getBoneNode(bone),
                       nodeIndex < model.nodes.count {
                        let node = model.nodes[nodeIndex]
                        vrmLogAnimation("  - \(bone): node[\(nodeIndex)] = \(node.name ?? "unnamed")")

                        // Check if this node is an ancestor of any skin joints
                        var isAncestorOfSkin = false
                        for skin in model.skins {
                            for joint in skin.joints {
                                var current: VRMNode? = joint
                                while let n = current {
                                    if n === node {
                                        isAncestorOfSkin = true
                                        break
                                    }
                                    current = n.parent
                                }
                                if isAncestorOfSkin { break }
                            }
                            if isAncestorOfSkin { break }
                        }
                        vrmLogAnimation("    Is ancestor of skinned joints: \(isAncestorOfSkin)")
                    }
                }
            }
        }

        for track in clip.jointTracks {
            guard let humanoid = model.humanoid,
                  let nodeIndex = humanoid.getBoneNode(track.bone),
                  nodeIndex < model.nodes.count else { continue }

            let node = model.nodes[nodeIndex]
            let (rotation, translation, scale) = track.sample(at: localTime)
            if debugFirstFrame {
                vrmLogAnimation("[SAMPLE] Bone \(track.bone): rot=\(rotation != nil), trans=\(translation != nil), scale=\(scale != nil)")
            }

            if let rotation = rotation {
                node.rotation = rotation
                // Debug all rotations for first update
                if debugFirstFrame {
                    vrmLogAnimation("[ROT DEBUG] Bone \(track.bone): rotation=\(rotation)")
                }
            } else if debugFirstFrame {
                vrmLogAnimation("[ROT DEBUG] Bone \(track.bone): NO ROTATION")
            }

            if let translation = translation, (applyRootMotion || track.bone != .hips) {
                node.translation = translation
            }

            if let scale = scale {
                node.scale = scale
            }
        }

        // Process non-humanoid node tracks (hair, bust, accessories)
        for track in clip.nodeTracks {
            // PERFORMANCE: Use model's pre-built lookup table (O(1) hash lookup, no string ops)
            let node: VRMNode?
            if nodeTrackCached.contains(track.nodeNameNormalized) {
                // Already looked up (might be nil if no match found)
                node = nodeTrackCache[track.nodeNameNormalized] ?? nil
            } else {
                // First time - use model's fast lookup table (no string operations!)
                node = model.findNodeByNormalizedName(track.nodeNameNormalized)
                nodeTrackCache[track.nodeNameNormalized] = node
                nodeTrackCached.insert(track.nodeNameNormalized)
                if debugFirstFrame {
                    if let foundNode = node {
                        vrmLogAnimation("[NON-HUMANOID] Found '\(track.nodeName)' → node '\(foundNode.name ?? "unnamed")'")
                    } else {
                        vrmLogAnimation("[NON-HUMANOID] No match for '\(track.nodeName)'")
                    }
                }
            }

            if let node = node {
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
            }
        }

        // Store morph weights to be applied by the expression controller
        currentMorphWeights.removeAll()
        for track in clip.morphTracks {
            let weight = track.sample(at: localTime)
            currentMorphWeights[track.key] = weight
        }

        // CRITICAL: Update transform matrices after modifying bone rotations
        // First update local matrices for modified nodes
        var updatedCount = 0
        for track in clip.jointTracks {
            if let humanoid = model.humanoid,
               let nodeIndex = humanoid.getBoneNode(track.bone),
               nodeIndex < model.nodes.count {
                model.nodes[nodeIndex].updateLocalMatrix()
                updatedCount += 1
            }
        }

        // Update non-humanoid node local matrices too
        for track in clip.nodeTracks {
            // Use cached lookup from above (already looked up in the animation loop)
            if let node = nodeTrackCache[track.nodeNameNormalized] ?? nil {
                node.updateLocalMatrix()
                updatedCount += 1
            }
        }

        // Debug log first frame
        if !hasLoggedFirstFrame {
            vrmLogAnimation("[AnimationPlayer] Updated \(updatedCount) bone local matrices")
            hasLoggedFirstFrame = true
            // Show which bones were updated AND their hierarchy
            for track in clip.jointTracks {
                if let humanoid = model.humanoid,
                   let nodeIndex = humanoid.getBoneNode(track.bone),
                   nodeIndex < model.nodes.count {
                    let node = model.nodes[nodeIndex]
                    vrmLogAnimation("[AnimationPlayer]   - Bone \(track.bone): node \(nodeIndex) (\(node.name ?? "unnamed"))")

                    // Show parent chain for critical bones
                    if track.bone == .hips {
                        var chain = [String]()
                        var current: VRMNode? = node
                        while let n = current {
                            chain.append(n.name ?? "node\(nodeIndex)")
                            current = n.parent
                        }
                        vrmLogAnimation("[ANIM HIERARCHY] Hips chain: \(chain.joined(separator: " → "))")
                    }
                }
            }
        }

        // Then propagate world transforms from root nodes
        for node in model.nodes where node.parent == nil {
            node.updateWorldTransform()
        }

        if currentTime < 0.1 {
            vrmLogAnimation("[AnimationPlayer] Propagated world transforms from root nodes")
        }

        if Int(currentTime * 10) % 10 == 0 {
            vrmLogAnimation("[UPDATE ORDER] 2. AnimationPlayer.updateWorldTransform() complete")
        }

        // DEBUG: Verify waist world transform has rotation after propagation
        if !hasLoggedFirstFrame {
            if let humanoid = model.humanoid,
               let waistIndex = humanoid.getBoneNode(.hips),
               waistIndex < model.nodes.count {
                let waistNode = model.nodes[waistIndex]
                // Check if world matrix has rotation (not identity)
                let m = waistNode.worldMatrix
                let hasRotation = abs(m[0][0] - 1.0) > 0.01 || abs(m[1][1] - 1.0) > 0.01 || abs(m[2][2] - 1.0) > 0.01
                vrmLogAnimation("[VERIFY] After propagation: waist worldMatrix diagonal=[\(m[0][0]), \(m[1][1]), \(m[2][2])], hasRotation=\(hasRotation)")
                vrmLogAnimation("[VERIFY] Full waist worldMatrix:")
                vrmLogAnimation("  [\(m[0][0]), \(m[0][1]), \(m[0][2]), \(m[0][3])]")
                vrmLogAnimation("  [\(m[1][0]), \(m[1][1]), \(m[1][2]), \(m[1][3])]")
                vrmLogAnimation("  [\(m[2][0]), \(m[2][1]), \(m[2][2]), \(m[2][3])]")
                vrmLogAnimation("  [\(m[3][0]), \(m[3][1]), \(m[3][2]), \(m[3][3])]")

                // Check a child too
                if let upperbodyIndex = humanoid.getBoneNode(.spine),
                   upperbodyIndex < model.nodes.count {
                    let upperbodyNode = model.nodes[upperbodyIndex]
                    let um = upperbodyNode.worldMatrix
                    vrmLogAnimation("[VERIFY] upperbody worldMatrix diagonal=[\(um[0][0]), \(um[1][1]), \(um[2][2])]")
                }

                // Check the local matrix too
                vrmLogAnimation("[VERIFY] waist localMatrix:")
                let lm = waistNode.localMatrix
                vrmLogAnimation("  [\(lm[0][0]), \(lm[0][1]), \(lm[0][2]), \(lm[0][3])]")
                vrmLogAnimation("  [\(lm[1][0]), \(lm[1][1]), \(lm[1][2]), \(lm[1][3])]")
                vrmLogAnimation("  [\(lm[2][0]), \(lm[2][1]), \(lm[2][2]), \(lm[2][3])]")
                vrmLogAnimation("  [\(lm[3][0]), \(lm[3][1]), \(lm[3][2]), \(lm[3][3])]")

                // Check rotation quaternion directly
                vrmLogAnimation("[VERIFY] waist rotation quaternion: \(waistNode.rotation)")
            }
        }
    }

    // Called by the renderer to apply morph weights through the expression controller
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

    // Find a node by normalized name (fuzzy matching for non-humanoid nodes)
    private func findNodeByName(_ normalizedName: String, in model: VRMModel) -> VRMNode? {
        // First try exact match
        for node in model.nodes {
            let nodeName = (node.name ?? "").lowercased()
                .replacingOccurrences(of: "_", with: "")
                .replacingOccurrences(of: ".", with: "")
            if nodeName == normalizedName {
                return node
            }
        }

        // Then try partial match (contains)
        for node in model.nodes {
            let nodeName = (node.name ?? "").lowercased()
                .replacingOccurrences(of: "_", with: "")
                .replacingOccurrences(of: ".", with: "")
            if nodeName.contains(normalizedName) || normalizedName.contains(nodeName) {
                return node
            }
        }

        return nil
    }
}