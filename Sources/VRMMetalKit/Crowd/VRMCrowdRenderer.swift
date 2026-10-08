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
import Metal

/// Schedules animation and physics before drawing a crowd into one shared pass.
/// Each avatar owns a distinct mutable model and renderer. Hosts retain control
/// of placement and camera matrices. Use one frame producer and one command queue.
public final class VRMCrowdRenderer {
    public struct Avatar {
        public let renderer: VRMRenderer
        public let player: AnimationPlayer?
        /// Keep animation and physics active even outside the camera (for contacts or gameplay).
        public var alwaysUpdate: Bool
        /// Full-quality physics setting; background tiers may temporarily reduce it.
        public var springBoneQuality: VRMConstants.SpringBoneQuality

        public init(renderer: VRMRenderer, player: AnimationPlayer? = nil, alwaysUpdate: Bool = false) {
            self.renderer = renderer
            self.player = player
            self.alwaysUpdate = alwaysUpdate
            self.springBoneQuality = renderer.springBoneQuality
        }
    }

    public struct Policy: Sendable {
        /// Nil keeps every visible avatar at full quality. Zero budgets every avatar as background.
        public var maxFullQualityAvatars: Int?
        public var backgroundAnimationFPS: Float
        public var backgroundSpringBoneQuality: VRMConstants.SpringBoneQuality
        public var updateBackgroundMorphs: Bool

        public init(maxFullQualityAvatars: Int? = nil, backgroundAnimationFPS: Float = 30,
                    backgroundSpringBoneQuality: VRMConstants.SpringBoneQuality = .low,
                    updateBackgroundMorphs: Bool = false) {
            self.maxFullQualityAvatars = maxFullQualityAvatars.map { max(0, $0) }
            self.backgroundAnimationFPS = max(1, backgroundAnimationFPS)
            self.backgroundSpringBoneQuality = backgroundSpringBoneQuality
            self.updateBackgroundMorphs = updateBackgroundMorphs
        }

        public static let full = Policy()
        public static let balanced = Policy(maxFullQualityAvatars: 8)
    }

    public enum Submission: Sendable { case sharedPass, individualPasses }

    public var policy: Policy
    public private(set) var avatars: [Avatar]
    public private(set) var visibleAvatarCount = 0
    public private(set) var fullQualityAvatarCount = 0
    public private(set) var animationUpdates = 0
    private var elapsed: [Float]
    private var sampled: [Bool]
    private var cadence: [Float]
    private var physicsElapsed: [Float]

    public init(avatars: [Avatar], policy: Policy = .full) {
        precondition(Set(avatars.map { ObjectIdentifier($0.renderer) }).count == avatars.count,
                     "Each crowd avatar requires its own renderer")
        let models = avatars.compactMap { $0.renderer.model }.map(ObjectIdentifier.init)
        precondition(Set(models).count == models.count, "Animated crowd avatars require distinct mutable models")
        self.avatars = avatars
        self.policy = policy
        elapsed = Array(repeating: 0, count: avatars.count)
        sampled = Array(repeating: false, count: avatars.count)
        cadence = Array(repeating: 0, count: avatars.count)
        physicsElapsed = Array(repeating: 0, count: avatars.count)
    }

    /// Changes an avatar's scheduling settings for the next draw without resetting its playback cadence.
    /// Call on the frame-producing thread before `draw`. Omitted settings retain their current values.
    /// The scene owns physics quality while drawing; change it here instead of on the renderer directly.
    public func updateAvatar(at index: Int, alwaysUpdate: Bool? = nil,
                             springBoneQuality: VRMConstants.SpringBoneQuality? = nil) {
        precondition(avatars.indices.contains(index), "Crowd avatar index is out of range")
        if let alwaysUpdate { avatars[index].alwaysUpdate = alwaysUpdate }
        if let springBoneQuality { avatars[index].springBoneQuality = springBoneQuality }
    }

    /// Advances the crowd by the host's timestep and encodes one frame.
    /// Background animation accumulates elapsed time, preserving playback speed.
    /// Root-motion players and `alwaysUpdate` avatars sample every frame.
    /// Offscreen avatars without root motion sample at 5 Hz so pose-driven bounds can re-enter view.
    /// Renderers' cameras and any external root placement must be set before this call.
    public func draw(deltaTime: Float, viewportSize: CGSize, commandBuffer: MTLCommandBuffer,
                     renderPassDescriptor: MTLRenderPassDescriptor, submission: Submission = .sharedPass) {
        let dt = max(0, deltaTime)
        let visibility = avatars.map { avatar -> (visible: Bool, distance: Float) in
            if !avatar.renderer.skipPreDrawTransformUpdate {
                avatar.renderer.model?.updateNodeTransforms()
            }
            return avatar.renderer.crowdVisibility()
        }
        let ranked = avatars.indices.filter { visibility[$0].visible || avatars[$0].alwaysUpdate }.sorted {
            if avatars[$0].alwaysUpdate != avatars[$1].alwaysUpdate { return avatars[$0].alwaysUpdate }
            if visibility[$0].distance != visibility[$1].distance { return visibility[$0].distance < visibility[$1].distance }
            return $0 < $1
        }
        let budget = max(0, policy.maxFullQualityAvatars ?? avatars.count)
        let full = Set(ranked.prefix(budget))
        var active: [VRMRenderer] = []
        visibleAvatarCount = 0
        fullQualityAvatarCount = 0
        animationUpdates = 0
        for i in avatars.indices {
            let avatar = avatars[i]
            let renderer = avatar.renderer
            let isFull = full.contains(i) || avatar.alwaysUpdate
            elapsed[i] += dt
            cadence[i] += dt
            let interval: Float = visibility[i].visible ? (isFull ? 0 : 1 / max(1, policy.backgroundAnimationFPS)) : 0.2
            let samplePose = !sampled[i] || avatar.alwaysUpdate || avatar.player?.applyRootMotion == true
                || cadence[i] + 0.000001 >= interval
            if samplePose {
                if let player = avatar.player, let model = renderer.model {
                    player.update(deltaTime: elapsed[i], model: model)
                    if let expressions = renderer.expressionController, isFull || policy.updateBackgroundMorphs {
                        player.applyMorphWeights(to: expressions)
                    }
                    animationUpdates += 1
                }
                elapsed[i] = 0
                if !sampled[i] {
                    // Distribute background work across frames without advancing playback ahead of time.
                    cadence[i] = Float(i) / Float(max(1, avatars.count)) * interval
                } else if interval > 0 {
                    cadence[i] = max(0, cadence[i] - floor((cadence[i] + 0.000001) / interval) * interval)
                } else {
                    cadence[i] = 0
                }
                sampled[i] = true
            }
            let visible = renderer.crowdVisibility().visible
            if visible { visibleAvatarCount += 1 }
            guard visible || avatar.alwaysUpdate else {
                physicsElapsed[i] = 0
                continue
            }
            if isFull { fullQualityAvatarCount += 1 }
            renderer.springBoneQuality = isFull ? avatar.springBoneQuality : policy.backgroundSpringBoneQuality
            physicsElapsed[i] += dt
            renderer.updatesCrowdPhysics = isFull || samplePose
            renderer.simulationDeltaTime = TimeInterval(physicsElapsed[i])
            if renderer.updatesCrowdPhysics { physicsElapsed[i] = 0 }
            renderer.updatesCrowdMorphs = isFull || policy.updateBackgroundMorphs
            active.append(renderer)
        }
        // The animation/placement phase has already propagated all node transforms.
        let transformFlags = active.map(\.skipPreDrawTransformUpdate)
        for renderer in active { renderer.skipPreDrawTransformUpdate = true }
        defer {
            for (i, renderer) in active.enumerated() {
                renderer.skipPreDrawTransformUpdate = transformFlags[i]
                renderer.updatesCrowdMorphs = true
                renderer.updatesCrowdPhysics = true
            }
        }
        switch submission {
        case .sharedPass:
            VRMRenderer.encodeCrowd(renderers: active, viewportSize: viewportSize,
                commandBuffer: commandBuffer, renderPassDescriptor: renderPassDescriptor)
        case .individualPasses:
            let count = active.count
            for (i, renderer) in active.enumerated() {
                let pass = renderPassDescriptor.copy() as! MTLRenderPassDescriptor
                if i > 0 {
                    pass.colorAttachments[0].loadAction = .load
                    pass.depthAttachment.loadAction = .load
                }
                if i + 1 < count {
                    pass.colorAttachments[0].storeAction = .store
                    pass.depthAttachment.storeAction = .store
                }
                guard let color = pass.colorAttachments[0].texture, let depth = pass.depthAttachment.texture else { continue }
                renderer.drawOffscreen(to: color, depth: depth, commandBuffer: commandBuffer, renderPassDescriptor: pass)
            }
            if active.isEmpty {
                commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor)?.endEncoding()
            }
        }
    }
}
