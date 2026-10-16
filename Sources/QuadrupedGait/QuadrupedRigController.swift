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
import GLTFMetalKit

/// Node names of one leg's joint chain in a glTF asset.
public struct LegNodeNames: Sendable, Equatable {
    public var hip: String
    public var knee: String
    public var ankle: String
    public var paw: String
    public var wheel: String

    public init(hip: String, knee: String, ankle: String, paw: String, wheel: String) {
        self.hip = hip
        self.knee = knee
        self.ankle = ankle
        self.paw = paw
        self.wheel = wheel
    }
}

/// Maps a ``QuadrupedGaitEngine`` onto the named nodes of a glTF asset.
public struct QuadrupedRigMap: Sendable, Equatable {
    /// Node receiving body pitch/roll/bob.
    public var body: String
    /// Optional attach point for a rider model's root.
    public var seatMount: String?
    /// Joint node names per leg.
    public var legs: [LegID: LegNodeNames]

    public init(body: String, seatMount: String? = nil, legs: [LegID: LegNodeNames]) {
        self.body = body
        self.seatMount = seatMount
        self.legs = legs
    }
}

/// Errors thrown by ``QuadrupedRigController`` setup.
public enum QuadrupedRigError: Error, Equatable, LocalizedError {
    /// A node name from the rig map was not found in the asset.
    case missingNode(String)

    public var errorDescription: String? {
        switch self {
        case .missingNode(let name):
            return "Rig node '\(name)' was not found in the glTF document. Check QuadrupedRigMap names (Leg_*_Hip, Body, Seat_Mount, …) against GLTFAsset.nodeIndex(named:)."
        }
    }
}

/// How engine joint rotations map onto a node's authored rest rotation.
public enum JointSpace: Sendable, Equatable {
    /// Engine rotations are composed onto the rest rotation
    /// (`rest * engineRotation`). Suits rigs whose rest pose is the
    /// straight "zero" pose (engine rotations are deltas from rest).
    case relativeToRest
    /// Engine rotations **replace** the rest rotation. Suits rigs whose
    /// rest pose is a non-zero authored pose (e.g. a folded/tucked stance)
    /// and whose engine works in absolute joint angles — including blending
    /// back to that exact authored pose as one end of its own range.
    case absolute
}

/// Drives a glTF quadruped rig from a ``QuadrupedGaitEngine``.
///
/// Resolves the rig map's node names once at init, then each ``update``
/// steps the engine and ``nodePoses`` exposes the result as
/// `GLTFNodePose` overrides ready for `GLTFAsset.evaluate(poses:)`.
///
/// Wheel nodes spin about their local X axis; the body node receives pitch
/// (local X) · roll (local Z) and a +Y bob translation (always composed
/// onto rest — body dynamics are deltas by nature).
public final class QuadrupedRigController {
    /// The gait engine, stepped by ``update(deltaTime:speed:steering:acceleration:mode:)``.
    public private(set) var engine: QuadrupedGaitEngine
    /// The rig map this controller was built from.
    public let rigMap: QuadrupedRigMap
    /// How leg joint rotations are mapped onto node rest rotations.
    public let jointSpace: JointSpace

    private struct LegNodeIndices {
        var hip: Int
        var knee: Int
        var ankle: Int
        var paw: Int
        var wheel: Int
    }

    private let bodyIndex: Int
    private let seatMountIndex: Int?
    private let legIndices: [LegID: LegNodeIndices]
    /// Rest rotations of every driven node, read from the asset document.
    private let restRotations: [Int: simd_quatf]
    private let bodyRestTranslation: SIMD3<Float>

    /// Resolves every name in `rigMap` against `asset`.
    /// - Throws: ``QuadrupedRigError/missingNode(_:)`` on the first name
    ///   that does not resolve.
    public init(
        asset: GLTFAsset,
        rigMap: QuadrupedRigMap,
        engine: QuadrupedGaitEngine,
        jointSpace: JointSpace = .relativeToRest
    ) throws {
        func index(of name: String) throws -> Int {
            guard let i = asset.nodeIndex(named: name) else {
                throw QuadrupedRigError.missingNode(name)
            }
            return i
        }

        self.rigMap = rigMap
        self.engine = engine
        self.jointSpace = jointSpace
        self.bodyIndex = try index(of: rigMap.body)
        self.seatMountIndex = try rigMap.seatMount.map(index)

        var resolved: [LegID: LegNodeIndices] = [:]
        var rests: [Int: simd_quatf] = [:]
        for (leg, names) in rigMap.legs {
            let hip = try index(of: names.hip)
            let knee = try index(of: names.knee)
            let ankle = try index(of: names.ankle)
            let paw = try index(of: names.paw)
            let wheel = try index(of: names.wheel)
            resolved[leg] = LegNodeIndices(hip: hip, knee: knee, ankle: ankle, paw: paw, wheel: wheel)
            for i in [hip, knee, ankle, wheel] {
                rests[i] = asset.restPose(ofNode: i).rotation
                    ?? simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
            }
        }
        let bodyRest = asset.restPose(ofNode: self.bodyIndex)
        rests[self.bodyIndex] = bodyRest.rotation ?? simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        self.legIndices = resolved
        self.restRotations = rests
        self.bodyRestTranslation = bodyRest.translation ?? .zero
    }

    /// Steps the gait engine.
    public func update(
        deltaTime: Float,
        speed: Float,
        steering: Float,
        acceleration: Float,
        mode: LocomotionMode
    ) {
        engine.update(
            deltaTime: deltaTime,
            speed: speed,
            steering: steering,
            acceleration: acceleration,
            mode: mode
        )
    }

    /// Engine state mapped to node-indexed pose overrides, ready for
    /// `GLTFAsset.evaluate(poses:)`.
    ///
    /// Joint overrides follow ``jointSpace``: composed onto each joint's
    /// rest rotation (`.relativeToRest`) or written as absolute rotations
    /// (`.absolute`). The body node always gets pitch/roll composed onto its
    /// rest rotation plus the bob offset added to its rest translation. Paw
    /// nodes are not driven — the paw is rigid below the ankle, and the
    /// engine keeps it level via ankle compensation.
    public var nodePoses: [Int: GLTFNodePose] {
        var poses: [Int: GLTFNodePose] = [:]
        let joints = engine.jointPoses()
        let xAxis = SIMD3<Float>(1, 0, 0)
        let identity = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)

        // Base rotation each driven node composes onto. In `.absolute` space
        // the engine's quaternions already encode the full joint rotation.
        func base(for nodeIndex: Int) -> simd_quatf {
            switch jointSpace {
            case .relativeToRest: return restRotations[nodeIndex] ?? identity
            case .absolute: return identity
            }
        }

        for (leg, indices) in legIndices {
            guard let joint = joints[leg] else { continue }
            poses[indices.hip] = GLTFNodePose(rotation: base(for: indices.hip) * joint.hip)
            poses[indices.knee] = GLTFNodePose(rotation: base(for: indices.knee) * joint.knee)
            poses[indices.ankle] = GLTFNodePose(rotation: base(for: indices.ankle) * joint.ankle)
            let wheelSpin = simd_quatf(angle: joint.wheelSpinAngle, axis: xAxis)
            poses[indices.wheel] = GLTFNodePose(rotation: base(for: indices.wheel) * wheelSpin)
        }

        let body = engine.bodyPose()
        let pitch = simd_quatf(angle: body.pitch, axis: xAxis)
        let roll = simd_quatf(angle: body.roll, axis: SIMD3<Float>(0, 0, 1))
        let bodyRest = restRotations[bodyIndex] ?? identity
        poses[bodyIndex] = GLTFNodePose(
            translation: bodyRestTranslation + SIMD3<Float>(0, body.bobY, 0),
            rotation: bodyRest * pitch * roll
        )
        return poses
    }

    /// World transform for attaching a rider model's root to the seat mount.
    ///
    /// - Parameters:
    ///   - worldMatrices: World matrices from `GLTFAsset.evaluate(poses:)`,
    ///     indexed by node index.
    ///   - localOffset: Offset in the seat mount's local space.
    /// - Returns: `worldMatrices[seatMount] * translation(localOffset)`.
    ///   When no seat mount is configured (or the matrices don't cover it),
    ///   returns a translation-only transform of `localOffset`.
    public func riderRootTransform(
        worldMatrices: [simd_float4x4],
        localOffset: SIMD3<Float> = .zero
    ) -> simd_float4x4 {
        let offset = simd_float4x4(translation: localOffset)
        guard let seat = seatMountIndex, worldMatrices.indices.contains(seat) else {
            return offset
        }
        return worldMatrices[seat] * offset
    }
}
