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

public struct AnimationClip {
    public let duration: Float
    public var jointTracks: [JointTrack] = []
    public var morphTracks: [MorphTrack] = []
    public var nodeTracks: [NodeTrack] = []  // For non-humanoid nodes (hair, bust, accessories)
    public var expressionTracks: [ExpressionTrack] = []  // VRM expression animation tracks

    public init(duration: Float) {
        self.duration = duration
    }

    public mutating func addJointTrack(_ track: JointTrack) {
        jointTracks.append(track)
    }

    public mutating func addMorphTrack(_ track: MorphTrack) {
        morphTracks.append(track)
    }

    public mutating func addNodeTrack(_ track: NodeTrack) {
        nodeTracks.append(track)
    }

    public mutating func addEulerTrack(bone: VRMHumanoidBone, axis: EulerAxis, sample: @escaping (Float) -> Float) {
        let track = JointTrack(
            bone: bone,
            rotationSampler: { time in
                let angle = sample(time)
                switch axis {
                case .x:
                    return simd_quatf(angle: angle, axis: simd_float3(1, 0, 0))
                case .y:
                    return simd_quatf(angle: angle, axis: simd_float3(0, 1, 0))
                case .z:
                    return simd_quatf(angle: angle, axis: simd_float3(0, 0, 1))
                }
            }
        )
        jointTracks.append(track)
    }

    public mutating func addMorphTrack(key: String, sample: @escaping (Float) -> Float) {
        morphTracks.append(MorphTrack(key: key, sampler: sample))
    }

    public mutating func addExpressionTrack(_ track: ExpressionTrack) {
        expressionTracks.append(track)
    }
}

public struct JointTrack {
    public let bone: VRMHumanoidBone
    public let rotationSampler: ((Float) -> simd_quatf)?
    public let translationSampler: ((Float) -> simd_float3)?
    public let scaleSampler: ((Float) -> simd_float3)?

    public init(
        bone: VRMHumanoidBone,
        rotationSampler: ((Float) -> simd_quatf)? = nil,
        translationSampler: ((Float) -> simd_float3)? = nil,
        scaleSampler: ((Float) -> simd_float3)? = nil
    ) {
        self.bone = bone
        self.rotationSampler = rotationSampler
        self.translationSampler = translationSampler
        self.scaleSampler = scaleSampler
    }

    public func sample(at time: Float) -> (rotation: simd_quatf?, translation: simd_float3?, scale: simd_float3?) {
        return (
            rotation: rotationSampler?(time),
            translation: translationSampler?(time),
            scale: scaleSampler?(time)
        )
    }
}

public struct MorphTrack {
    public let key: String
    public let sampler: (Float) -> Float

    public init(key: String, sampler: @escaping (Float) -> Float) {
        self.key = key
        self.sampler = sampler
    }

    public func sample(at time: Float) -> Float {
        return sampler(time)
    }
}

/// Track for VRM expression animation (facial expressions, etc.)
/// Maps to VRMExpressionPreset for standardized expression names
public struct ExpressionTrack {
    public let expression: VRMExpressionPreset
    public let sampler: (Float) -> Float

    public init(expression: VRMExpressionPreset, sampler: @escaping (Float) -> Float) {
        self.expression = expression
        self.sampler = sampler
    }

    public func sample(at time: Float) -> Float {
        return sampler(time)
    }
}

/// Track for arbitrary nodes (non-humanoid bones like hair, bust, accessories)
/// Uses node name matching instead of humanoid bone enum
public struct NodeTrack {
    public let nodeName: String  // Original VRMA node name
    public let nodeNameNormalized: String  // Lowercased for fuzzy matching
    public let rotationSampler: ((Float) -> simd_quatf)?
    public let translationSampler: ((Float) -> simd_float3)?
    public let scaleSampler: ((Float) -> simd_float3)?

    public init(
        nodeName: String,
        rotationSampler: ((Float) -> simd_quatf)? = nil,
        translationSampler: ((Float) -> simd_float3)? = nil,
        scaleSampler: ((Float) -> simd_float3)? = nil
    ) {
        self.nodeName = nodeName
        self.nodeNameNormalized = nodeName.lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: ".", with: "")
        self.rotationSampler = rotationSampler
        self.translationSampler = translationSampler
        self.scaleSampler = scaleSampler
    }

    public func sample(at time: Float) -> (rotation: simd_quatf?, translation: simd_float3?, scale: simd_float3?) {
        return (
            rotation: rotationSampler?(time),
            translation: translationSampler?(time),
            scale: scaleSampler?(time)
        )
    }
}

public enum EulerAxis {
    case x, y, z
}