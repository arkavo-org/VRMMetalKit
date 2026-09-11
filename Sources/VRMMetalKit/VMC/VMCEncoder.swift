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

/// Builds VMC Protocol messages from VRMMetalKit model state, the sending half of ``VMCDriver``.
///
/// Rotations are read relative to each bone's rest pose and expressed as
/// world-aligned deltas in Unity coordinates, which is what a normalized
/// Unity rig would report as its local rotation. Feeding the output of
/// ``frame(for:controller:convention:)`` back into a ``VMCDriver`` on the
/// same model reproduces the pose.
public enum VMCEncoder {

    public static func boneMessage(_ bone: VRMHumanoidBone, transform: VMCBoneTransform) -> OSCMessage {
        transformMessage(address: "/VMC/Ext/Bone/Pos", name: VMCDriver.unityName(for: bone), transform: transform)
    }

    public static func rootMessage(_ transform: VMCBoneTransform, name: String = "root") -> OSCMessage {
        transformMessage(address: "/VMC/Ext/Root/Pos", name: name, transform: transform)
    }

    public static func blendValue(_ name: String, _ value: Float) -> OSCMessage {
        OSCMessage("/VMC/Ext/Blend/Val", .string(name), .float32(value))
    }

    public static func blendApply() -> OSCMessage {
        OSCMessage(address: "/VMC/Ext/Blend/Apply")
    }

    public static func status(loaded: Bool, calibrationState: Int32 = 3, calibrationMode: Int32 = 0, trackingStatus: Int32 = 1) -> OSCMessage {
        OSCMessage("/VMC/Ext/OK", .int32(loaded ? 1 : 0), .int32(calibrationState), .int32(calibrationMode), .int32(trackingStatus))
    }

    public static func time(_ seconds: Float) -> OSCMessage {
        OSCMessage("/VMC/Ext/T", .float32(seconds))
    }

    /// One bundle describing the model's current humanoid pose and the controller's preset weights.
    public static func frame(
        for model: VRMModel,
        controller: VRMExpressionController? = nil,
        convention: VMCCoordinateConvention = .flipX,
        time seconds: Float? = nil
    ) -> OSCBundle {
        var elements: [OSCPacket] = [.message(status(loaded: true))]
        if let seconds { elements.append(.message(time(seconds))) }

        if let humanoid = model.humanoid {
            for bone in VRMHumanoidBone.allCases {
                guard let index = humanoid.getBoneNode(bone), index < model.nodes.count else { continue }
                let node = model.nodes[index]
                let restWorld = VMCDriver.restWorldRotation(of: node)
                let localDelta = node.initialRotation.inverse * node.rotation
                let worldDelta = simd_normalize(restWorld * localDelta * restWorld.inverse)
                let position = bone == .hips ? node.translation : .zero
                let transform = VMCBoneTransform(
                    position: convention.convert(position: position),
                    rotation: convention.convert(rotation: worldDelta)
                )
                elements.append(.message(boneMessage(bone, transform: transform)))
            }
        }

        if let controller {
            for preset in VRMExpressionPreset.allCases {
                let weight = controller.weight(for: preset)
                if weight > 0 {
                    elements.append(.message(blendValue(preset.rawValue, weight)))
                }
            }
            elements.append(.message(blendApply()))
        }

        return OSCBundle(elements: elements)
    }

    private static func transformMessage(address: String, name: String, transform: VMCBoneTransform) -> OSCMessage {
        let p = transform.position
        let q = transform.rotation
        return OSCMessage(address: address, arguments: [
            .string(name),
            .float32(p.x), .float32(p.y), .float32(p.z),
            .float32(q.imag.x), .float32(q.imag.y), .float32(q.imag.z), .float32(q.real)
        ])
    }
}
