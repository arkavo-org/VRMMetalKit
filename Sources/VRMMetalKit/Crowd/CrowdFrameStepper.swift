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
import simd

/// Per-frame orchestration for the crowd collision demo (design §3). Owns the
/// load-bearing ordering: Phase 0 poses EVERY avatar for this frame (animation +
/// scripted motion, via T/R/S so `updateWorldTransform` picks it up), then
/// Phase 1+2 runs the coordinator's `exchange()` (snapshot all → inject
/// union-minus-self) — so every snapshot reads a fresh, fully-committed pose and
/// all snapshots precede any spring integrate. Phase 3 (`drawComposite`) renders
/// the avatars into one shared frame. Keeps the video executable a thin shell.
///
/// Validated for offline-synchronous single-caller use; see design §2.2.
public final class CrowdFrameStepper {
    public struct Avatar {
        public let renderer: VRMRenderer
        public let model: VRMModel
        public let player: AnimationPlayer
        public let index: Int
        public init(renderer: VRMRenderer, model: VRMModel, player: AnimationPlayer, index: Int) {
            self.renderer = renderer; self.model = model; self.player = player; self.index = index
        }
    }

    private let avatars: [Avatar]
    private let driver: CrowdMotionDriver
    private let group: SpringBoneContactGroup?
    private let dt: Float
    private let baseTranslations: [Int: [ObjectIdentifier: SIMD3<Float>]]

    /// The avatars, exposed so a host can set a shared camera on each renderer.
    public var avatarsForCamera: [Avatar] { avatars }

    public init(avatars: [Avatar], driver: CrowdMotionDriver, group: SpringBoneContactGroup?, fps: Float) {
        self.avatars = avatars
        self.driver = driver
        self.group = group
        self.dt = fps > 0 ? 1.0 / fps : 1.0 / 60.0
        // Snapshot each root's authored (bind) translation so scripted motion is
        // applied additively and never loses the model's base pose.
        var bases: [Int: [ObjectIdentifier: SIMD3<Float>]] = [:]
        for avatar in avatars {
            var perRoot: [ObjectIdentifier: SIMD3<Float>] = [:]
            for root in avatar.model.nodes where root.parent == nil {
                perRoot[ObjectIdentifier(root)] = root.translation
            }
            bases[avatar.index] = perRoot
        }
        self.baseTranslations = bases
    }

    /// Phase 0 (pose all) + Phase 1+2 (exchange). `frameTime` is normalized [0,1].
    public func step(frameTime: Float) {
        let halfSep = driver.halfSeparation(at: frameTime)
        for avatar in avatars {
            // Phase 0a: animation (applies to bones + internal updateNodeTransforms).
            avatar.player.update(deltaTime: dt, model: avatar.model)
            // Phase 0b: scripted placement/motion on the scene root(s), via T/R/S.
            let offset = CrowdPlacement.rootTranslation(
                avatarIndex: avatar.index, avatarCount: avatars.count, halfSeparation: halfSep)
            let bases = baseTranslations[avatar.index] ?? [:]
            for root in avatar.model.nodes where root.parent == nil {
                let base = bases[ObjectIdentifier(root)] ?? .zero
                root.translation = base + offset
            }
            // Phase 0c: propagate root motion into world matrices for the snapshot.
            avatar.model.updateNodeTransforms()
        }
        // Phase 1+2: snapshot all (post-motion poses), inject union-minus-self.
        group?.exchange()
    }

    /// Phase 3: composite every avatar into `color`/`depth`. Each avatar is a
    /// separate render pass into the SAME MSAA `color`/`depth` textures, so the
    /// store-action contract matters as much as the load-action one: an
    /// intermediate pass's `.load` only sees a prior avatar's pixels if that
    /// prior pass actually stored the MSAA color+depth (not just resolved or
    /// discarded them). First avatar clears, the rest load; every avatar except
    /// the last stores MSAA color+depth so the next pass's `.load` is valid; only
    /// the last pass resolves color into the caller's resolve texture and
    /// discards MSAA depth, since nothing reads either after the frame (design
    /// §3).
    @MainActor
    public func drawComposite(color: MTLTexture, depth: MTLTexture,
                              commandBuffer: MTLCommandBuffer, renderPassDescriptor: MTLRenderPassDescriptor) {
        for (i, avatar) in avatars.enumerated() {
            let isFirst = i == 0
            let isLast = i == avatars.count - 1
            renderPassDescriptor.colorAttachments[0].loadAction = isFirst ? .clear : .load
            renderPassDescriptor.depthAttachment.loadAction = isFirst ? .clear : .load
            renderPassDescriptor.colorAttachments[0].storeAction = isLast ? .multisampleResolve : .store
            renderPassDescriptor.depthAttachment.storeAction = isLast ? .dontCare : .store
            avatar.renderer.drawOffscreenHeadless(
                to: color, depth: depth, commandBuffer: commandBuffer, renderPassDescriptor: renderPassDescriptor)
        }
    }
}
