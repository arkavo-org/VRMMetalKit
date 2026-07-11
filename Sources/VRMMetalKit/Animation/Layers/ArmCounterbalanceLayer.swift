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

/// Procedural arm counterbalance on impact: raise arms + soft elbows so the
/// avatar keeps upright with the arms (primary human strategy).
///
/// ## VRM 1.0 coordinate system (glTF right-handed, Y-up)
/// - Character **front** = local **+Z**
/// - Character **left**  = local **+X**
/// - Character **up**    = local **+Y**
/// - T-pose: left upper arm extends along **+X**, right along **−X**
///
/// Absolute local-Z deltas (the old `armsRaised` fixture) only match T-pose
/// bind. Post-multiplying them onto A-pose / walk clips drives the arms
/// **inward through the torso**. Brace therefore applies a **world-space**
/// raise about the character forward axis and converts to each bone's local
/// space (same parent-world conjugacy as ``PosturalContactLayer``):
/// - Left arm:  +angle about character **+Z** (from hang: −Y → +X, out/up)
/// - Right arm: −angle about character **+Z** (from hang: −Y → −X, out/up)
///
/// ## Apply path
/// ``applyDirect(to:)`` post-multiplies local shares onto the current animated
/// pose (clip-driven path, same as postural lean).
public final class ArmCounterbalanceLayer: AnimationLayer {

    public let identifier: String = "armCounterbalance"
    public let priority: Int = 6
    public var isEnabled: Bool = true
    public var affectedBones: Set<VRMHumanoidBone> {
        [.leftUpperArm, .rightUpperArm, .leftLowerArm, .rightLowerArm]
    }

    public var params: ArmCounterbalanceParams {
        get { solver.params }
        set { solver.params = newValue }
    }

    public var intensity: Float = 0
    public var fallDirXZ: SIMD2<Float> = .zero

    private var solver: ArmCounterbalanceSolver
    private weak var model: VRMModel?
    private var pending: [VRMHumanoidBone: simd_quatf] = [:]

    public var currentIntensity: Float { solver.pose.intensity }
    public var currentPose: ArmCounterbalancePose { solver.pose }

    public init(params: ArmCounterbalanceParams = ArmCounterbalanceParams()) {
        self.solver = ArmCounterbalanceSolver(params: params)
    }

    public func initialize(with model: VRMModel) {
        self.model = model
    }

    public func update(deltaTime: Float, context: AnimationContext) {
        pending.removeAll(keepingCapacity: true)
        guard isEnabled else {
            _ = solver.update(intensity: 0, localFallXZ: .zero, dt: deltaTime)
            return
        }
        guard let model = model else { return }

        let localFall = characterLocalFall(worldXZ: fallDirXZ, model: model)
        let pose = solver.update(intensity: intensity, localFallXZ: localFall, dt: deltaTime)
        guard pose.isActive else { return }

        // World-space raise about character forward (+Z). Signs lift arms
        // outward/up from hang — not into the torso.
        let forward = characterAxes(model: model).forward
        if pose.leftRaise > 1e-4,
           let q = localDelta(worldAngle: pose.leftRaise, worldAxis: forward,
                              bone: .leftUpperArm, model: model) {
            pending[.leftUpperArm] = q
        }
        if pose.rightRaise > 1e-4,
           let q = localDelta(worldAngle: -pose.rightRaise, worldAxis: forward,
                              bone: .rightUpperArm, model: model) {
            pending[.rightUpperArm] = q
        }

        // Soft elbows stay as small local-Y bends (IdleBreathing convention).
        // Kept modest so they don't pull hands into the ribs.
        let elbowScale: Float = 0.55
        if pose.leftElbow > 1e-4 {
            pending[.leftLowerArm] = simd_quatf(angle: -pose.leftElbow * elbowScale,
                                                axis: SIMD3<Float>(0, 1, 0))
        }
        if pose.rightElbow > 1e-4 {
            pending[.rightLowerArm] = simd_quatf(angle: pose.rightElbow * elbowScale,
                                                 axis: SIMD3<Float>(0, 1, 0))
        }
    }

    public func evaluate() -> LayerOutput {
        guard !pending.isEmpty else { return LayerOutput() }
        var bones: [VRMHumanoidBone: ProceduralBoneTransform] = [:]
        for (bone, q) in pending { bones[bone] = ProceduralBoneTransform(rotation: q) }
        return LayerOutput(bones: bones, morphWeights: [:], blendMode: .blend(1.0))
    }

    public func applyDirect(to model: VRMModel) {
        guard !pending.isEmpty, let humanoid = model.humanoid else { return }
        for (bone, share) in pending {
            guard let idx = humanoid.getBoneNode(bone), idx < model.nodes.count else { continue }
            guard share.angle > 1e-4 else { continue }
            model.nodes[idx].rotation = simd_normalize(model.nodes[idx].rotation * share)
        }
    }

    // MARK: Helpers

    /// Character ground axes from hips (VRM 1.0: +X left, +Z front).
    private func characterAxes(model: VRMModel) -> (left: SIMD3<Float>, forward: SIMD3<Float>, up: SIMD3<Float>) {
        let m: simd_float4x4
        if let humanoid = model.humanoid, let hips = humanoid.getBoneNode(.hips),
           hips < model.nodes.count {
            m = model.nodes[hips].worldMatrix
        } else if let root = model.nodes.first(where: { $0.parent == nil }) {
            m = root.worldMatrix
        } else {
            return (SIMD3(1, 0, 0), SIMD3(0, 0, 1), SIMD3(0, 1, 0))
        }
        var left = SIMD3<Float>(m.columns.0.x, 0, m.columns.0.z)
        var forward = SIMD3<Float>(m.columns.2.x, 0, m.columns.2.z)
        let ll = simd_length(left)
        let fl = simd_length(forward)
        if ll > 1e-6 { left /= ll } else { left = SIMD3(1, 0, 0) }
        if fl > 1e-6 { forward /= fl } else { forward = SIMD3(0, 0, 1) }
        return (left, forward, SIMD3(0, 1, 0))
    }

    /// World rotation about `worldAxis` by `worldAngle` → bone local delta.
    /// `qLocal = parentWorldRot⁻¹ · qWorld · parentWorldRot`
    private func localDelta(worldAngle: Float, worldAxis: SIMD3<Float>,
                            bone: VRMHumanoidBone, model: VRMModel) -> simd_quatf? {
        guard let humanoid = model.humanoid, let idx = humanoid.getBoneNode(bone),
              idx < model.nodes.count else { return nil }
        let axisLen = simd_length(worldAxis)
        guard axisLen > 1e-6, abs(worldAngle) > 1e-5 else { return nil }
        let qWorld = simd_quatf(angle: worldAngle, axis: worldAxis / axisLen)
        let parentWorldRot: simd_quatf
        if let parent = model.nodes[idx].parent {
            parentWorldRot = worldRotation(parent.worldMatrix)
        } else {
            parentWorldRot = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        }
        return simd_normalize(parentWorldRot.inverse * qWorld * parentWorldRot)
    }

    private func worldRotation(_ m: simd_float4x4) -> simd_quatf {
        let c0 = simd_normalize(SIMD3<Float>(m[0][0], m[0][1], m[0][2]))
        let c1 = simd_normalize(SIMD3<Float>(m[1][0], m[1][1], m[1][2]))
        let c2 = simd_normalize(SIMD3<Float>(m[2][0], m[2][1], m[2][2]))
        return simd_quatf(simd_float3x3(c0, c1, c2))
    }

    /// Project world XZ fall into character-local (right, forward).
    /// VRM +X = character left → right = −left.
    private func characterLocalFall(worldXZ: SIMD2<Float>, model: VRMModel?) -> SIMD2<Float> {
        guard simd_length_squared(worldXZ) > 1e-8, let model else {
            return SIMD2<Float>(0, 1)
        }
        let axes = characterAxes(model: model)
        let right = -axes.left
        let world = SIMD3<Float>(worldXZ.x, 0, worldXZ.y)
        return SIMD2<Float>(simd_dot(world, right), simd_dot(world, axes.forward))
    }
}
