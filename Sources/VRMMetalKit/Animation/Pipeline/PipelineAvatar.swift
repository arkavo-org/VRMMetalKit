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

/// One avatar's mutable per-frame pipeline state.
///
/// A struct passed `inout` rather than a class, because `StaggerShoveSolver` is
/// a value type whose `update` mutates in place; the layers and the capture-step
/// controller are reference types and are held as references. `VRMModel` is a
/// class, so pose writes land through it regardless.
public struct PipelineAvatar {
    public let index: Int
    public let model: VRMModel
    public let player: AnimationPlayer
    /// Each scene root's authored (bind) translation, so scripted motion stays additive.
    public let baseTranslations: [ObjectIdentifier: SIMD3<Float>]
    public let posturalLayer: PosturalContactLayer?
    public let armLayer: ArmCounterbalanceLayer?
    public let captureStepper: CaptureStepController?
    /// S3's limb-IK layer, terminal against S2's finalised root. `nil` on every
    /// existing construction site — `CrowdFrameStepper` never sets it, so the
    /// crowd path is unaffected until a caller opts in.
    public var ikLayer: IKLayer?
    /// The world-space foot-target source `ikLayer` re-sources from once the
    /// interaction-volume RFC lands. Wired but not yet consumed by `IKLayer`.
    public var footTargetSource: FootTargetSource?
    public var staggerSolver: StaggerShoveSolver?
    /// Set on this avatar's first frame with non-zero contact depth. Until then the
    /// stagger channel is dormant and the path is byte-identical to stagger-off.
    public var staggerActive: Bool
    /// This avatar's own S4 constraint solver — one per avatar, not shared, because
    /// `ConstraintSolver`'s `@unchecked Sendable` conformance is conditioned on the
    /// instance never being reachable from more than one concurrency domain
    /// (`ConstraintSolver.swift`). A process-wide static would put every stepper's
    /// avatars on the same instance, racing its unsynchronized topological-sort
    /// cache; a per-avatar instance also avoids cross-avatar cache invalidation
    /// when different avatars carry different constraint sets.
    public let constraintSolver: ConstraintSolver

    public init(index: Int, model: VRMModel, player: AnimationPlayer,
                baseTranslations: [ObjectIdentifier: SIMD3<Float>],
                posturalLayer: PosturalContactLayer? = nil,
                armLayer: ArmCounterbalanceLayer? = nil,
                captureStepper: CaptureStepController? = nil,
                ikLayer: IKLayer? = nil,
                footTargetSource: FootTargetSource? = nil,
                staggerSolver: StaggerShoveSolver? = nil,
                staggerActive: Bool = false,
                constraintSolver: ConstraintSolver = ConstraintSolver()) {
        self.index = index
        self.model = model
        self.player = player
        self.baseTranslations = baseTranslations
        self.posturalLayer = posturalLayer
        self.armLayer = armLayer
        self.captureStepper = captureStepper
        self.ikLayer = ikLayer
        self.footTargetSource = footTargetSource
        self.staggerSolver = staggerSolver
        self.staggerActive = staggerActive
        self.constraintSolver = constraintSolver
    }
}
