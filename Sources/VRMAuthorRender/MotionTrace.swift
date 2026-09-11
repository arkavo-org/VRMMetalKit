//
// Copyright 2026 Arkavo
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
import VRMAuthorKit
import VRMMetalKit

/// Samples spring joint world positions from the model after each simulation
/// step and accumulates the motion.idle metrics (tip penetration into the
/// spring's own collider groups, joint velocity).
struct MotionTrace {
    struct SpringInfo {
        var index: Int
        var name: String
        var jointNodes: [Int]
        var colliderIndices: [Int]
    }

    struct Frame {
        var step: Int
        var timeS: Double
        var tips: [SIMD3<Float>]
        var joints: [[SIMD3<Float>]]?
        var penetrationM: [Float]
        var maxPenetrationM: Float
        var maxTipPenetrationM: Float
        var maxJointVelocityMps: Float
    }

    let model: VRMModel
    let springs: [SpringInfo]
    let timestepS: Double
    private(set) var frames: [Frame] = []
    private var previous: [[SIMD3<Float>]]? = nil
    private(set) var maxPenetrationM: Float = 0
    private(set) var maxTipPenetrationM: Float = 0
    private(set) var maxJointVelocityMps: Float = 0

    init(model: VRMModel, timestepS: Double) {
        self.model = model
        self.timestepS = timestepS
        let groups = model.springBone?.colliderGroups ?? []
        springs = (model.springBone?.springs ?? []).enumerated().map { index, spring in
            let colliders = spring.colliderGroups.flatMap { groups.indices.contains($0) ? groups[$0].colliders : [] }
            return SpringInfo(index: index, name: spring.name ?? "spring\(index)", jointNodes: spring.joints.map(\.node), colliderIndices: Array(Set(colliders)).sorted())
        }
    }

    static func worldPosition(_ node: VRMNode) -> SIMD3<Float> {
        let column = node.worldMatrix.columns.3
        return SIMD3<Float>(column.x, column.y, column.z)
    }

    static func transformPoint(_ matrix: float4x4, _ point: SIMD3<Float>) -> SIMD3<Float> {
        let transformed = matrix * SIMD4<Float>(point, 1)
        return SIMD3<Float>(transformed.x, transformed.y, transformed.z)
    }

    /// Depth (metres) by which a joint sphere of `hitRadius` overlaps the
    /// collider; zero when clear. Plane and inside shapes are not scored.
    static func penetration(joint: SIMD3<Float>, hitRadius: Float, collider: VRMCollider, model: VRMModel) -> Float {
        guard let node = model.nodes[safe: collider.node] else { return 0 }
        let matrix = node.worldMatrix
        switch collider.shape {
        case .sphere(let offset, let radius):
            let centre = transformPoint(matrix, offset)
            return max(0, radius + hitRadius - simd_length(joint - centre))
        case .capsule(let offset, let radius, let tail):
            let a = transformPoint(matrix, offset)
            let b = transformPoint(matrix, tail)
            let ab = b - a
            let lengthSquared = simd_length_squared(ab)
            let t = lengthSquared > 1e-12 ? min(max(simd_dot(joint - a, ab) / lengthSquared, 0), 1) : 0
            let closest = a + ab * t
            return max(0, radius + hitRadius - simd_length(joint - closest))
        case .plane, .insideSphere, .insideCapsule:
            return 0
        }
    }

    mutating func sample(step: Int, timeS: Double, keepJoints: Bool) {
        let colliders = model.springBone?.colliders ?? []
        let springDefinitions = model.springBone?.springs ?? []
        var tips: [SIMD3<Float>] = []
        var jointsPerSpring: [[SIMD3<Float>]] = []
        var penetrations: [Float] = []
        var framePenetration: Float = 0
        var frameTipPenetration: Float = 0
        var frameVelocity: Float = 0
        for info in springs {
            let positions = info.jointNodes.map { index -> SIMD3<Float> in
                guard let node = model.nodes[safe: index] else { return .zero }
                return MotionTrace.worldPosition(node)
            }
            jointsPerSpring.append(positions)
            tips.append(positions.last ?? .zero)
            var springPenetration: Float = 0
            for (jointIndex, position) in positions.enumerated() {
                let hitRadius = springDefinitions[safe: info.index]?.joints[safe: jointIndex]?.hitRadius ?? 0
                for colliderIndex in info.colliderIndices {
                    guard let collider = colliders[safe: colliderIndex] else { continue }
                    let depth = MotionTrace.penetration(joint: position, hitRadius: hitRadius, collider: collider, model: model)
                    springPenetration = max(springPenetration, depth)
                    if jointIndex == positions.count - 1 { frameTipPenetration = max(frameTipPenetration, depth) }
                }
                if let previous, let before = previous[safe: info.index]?[safe: jointIndex] {
                    frameVelocity = max(frameVelocity, simd_length(position - before) / Float(timestepS))
                }
            }
            penetrations.append(springPenetration)
            framePenetration = max(framePenetration, springPenetration)
        }
        previous = jointsPerSpring
        maxPenetrationM = max(maxPenetrationM, framePenetration)
        maxTipPenetrationM = max(maxTipPenetrationM, frameTipPenetration)
        maxJointVelocityMps = max(maxJointVelocityMps, frameVelocity)
        frames.append(Frame(step: step, timeS: timeS, tips: tips, joints: keepJoints ? jointsPerSpring : nil, penetrationM: penetrations,
                            maxPenetrationM: framePenetration, maxTipPenetrationM: frameTipPenetration, maxJointVelocityMps: frameVelocity))
    }

    static func rounded(_ value: Float) -> JSONValue {
        guard value.isFinite else { return .null }
        return .number((Double(value) * 1e6).rounded() / 1e6)
    }

    static func vector(_ value: SIMD3<Float>) -> JSONValue { [rounded(value.x), rounded(value.y), rounded(value.z)] }

    func json(scenarioId: String, durationS: Double, stepCount: Int, captureTimesS: [Double]) -> JSONValue {
        let springJSON: [JSONValue] = springs.map { info in
            ["index": .number(Double(info.index)), "name": .string(info.name), "jointNodes": .array(info.jointNodes.map { .number(Double($0)) }),
             "colliders": .array(info.colliderIndices.map { .number(Double($0)) })]
        }
        let frameJSON: [JSONValue] = frames.map { frame in
            var entry: [String: JSONValue] = [
                "step": .number(Double(frame.step)), "timeS": .number((frame.timeS * 1e6).rounded() / 1e6),
                "tips": .array(frame.tips.map(MotionTrace.vector)), "penetrationM": .array(frame.penetrationM.map(MotionTrace.rounded)),
                "maxPenetrationM": MotionTrace.rounded(frame.maxPenetrationM), "maxTipPenetrationM": MotionTrace.rounded(frame.maxTipPenetrationM),
                "maxJointVelocityMps": MotionTrace.rounded(frame.maxJointVelocityMps),
            ]
            if let joints = frame.joints { entry["joints"] = .array(joints.map { .array($0.map(MotionTrace.vector)) }) }
            return .object(entry)
        }
        return [
            "traceVersion": 1, "scenarioId": .string(scenarioId), "timestepS": .number(timestepS), "durationS": .number(durationS),
            "steps": .number(Double(stepCount)), "captureTimesS": .array(captureTimesS.map { .number($0) }),
            "metrics": ["tipPenetration", "jointVelocity"], "springs": .array(springJSON), "frames": .array(frameJSON),
            "summary": ["maxPenetrationM": MotionTrace.rounded(maxPenetrationM), "maxTipPenetrationM": MotionTrace.rounded(maxTipPenetrationM),
                        "maxJointVelocityMps": MotionTrace.rounded(maxJointVelocityMps), "springs": .number(Double(springs.count))],
        ]
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
