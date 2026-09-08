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

/// How Unity's left-handed coordinates map onto the model space VRMMetalKit renders.
///
/// VRMMetalKit loads every model facing +Z with the left hand toward +X
/// (VRM 0.x files are rotated 180° about Y at load time to match VRM 1.0).
/// Unity keeps +Z forward but its left hand is toward -X, so the two differ
/// by a reflection of X. ``flipZ`` is provided for raw VRM 0.x node data
/// that has not been through the loader's facing conversion.
public enum VMCCoordinateConvention: Sendable, Equatable {
    /// Negate X: Unity ↔ VRMMetalKit model space. The default.
    case flipX
    /// Negate Z: Unity ↔ raw VRM 0.x file space (model facing -Z).
    case flipZ

    public func convert(position p: SIMD3<Float>) -> SIMD3<Float> {
        switch self {
        case .flipX: return SIMD3<Float>(-p.x, p.y, p.z)
        case .flipZ: return SIMD3<Float>(p.x, p.y, -p.z)
        }
    }

    public func convert(rotation q: simd_quatf) -> simd_quatf {
        let v = q.imag
        switch self {
        case .flipX: return simd_quatf(ix: v.x, iy: -v.y, iz: -v.z, r: q.real)
        case .flipZ: return simd_quatf(ix: -v.x, iy: -v.y, iz: v.z, r: q.real)
        }
    }
}

/// Position and rotation of one bone or the root as received over VMC.
public struct VMCBoneTransform: Sendable, Equatable {
    public var position: SIMD3<Float>
    public var rotation: simd_quatf

    public init(position: SIMD3<Float> = .zero, rotation: simd_quatf = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)) {
        self.position = position
        self.rotation = rotation
    }
}

/// Sender status from `/VMC/Ext/OK`.
public struct VMCDeviceStatus: Sendable, Equatable {
    public var loaded: Bool
    public var calibrationState: Int?
    public var calibrationMode: Int?
    public var trackingStatus: Int?

    public init(loaded: Bool, calibrationState: Int? = nil, calibrationMode: Int? = nil, trackingStatus: Int? = nil) {
        self.loaded = loaded
        self.calibrationState = calibrationState
        self.calibrationMode = calibrationMode
        self.trackingStatus = trackingStatus
    }
}

/// The latest VMC state the driver has assembled, in Unity coordinates as received.
public struct VMCFrame: Sendable, Equatable {
    /// `/VMC/Ext/Root/Pos`, if the sender emits one.
    public var root: VMCBoneTransform?
    /// Humanoid bone transforms keyed by VRM bone, most recent value per bone.
    public var bones: [VRMHumanoidBone: VMCBoneTransform] = [:]
    /// Blend-shape weights committed by the last `/VMC/Ext/Blend/Apply`, keyed by sender name.
    public var blendShapes: [String: Float] = [:]
    /// Sender time from `/VMC/Ext/T`.
    public var time: Float?
    public var status: VMCDeviceStatus?
    /// Host time of the last message that changed this frame.
    public var receivedAt: TimeInterval = 0

    public init() {}
}

/// Consumes VMC Protocol messages and applies them to a VRM model, the network counterpart of the ARKit drivers.
///
/// ## Discussion
/// Feed decoded ``OSCPacket``s from ``VMCReceiver`` (or any transport) into
/// ``receive(_:)``. Bone transforms take effect immediately; blend-shape
/// values accumulate until `/VMC/Ext/Blend/Apply`, as the protocol requires.
/// Call ``apply(to:controller:)`` once per rendered frame from the
/// animation thread.
///
/// Rotations are applied relative to each bone's rest pose. VMC senders run
/// normalized Unity rigs whose rest rotation is identity, so the received
/// quaternion is a world-aligned delta; it is converted through
/// ``convention`` and then composed as `rest * inverse(restWorld) * delta * restWorld`,
/// which reduces to the delta itself on a normalized VRM 1.0 rig and stays
/// correct on rigs with non-identity rest rotations.
///
/// Reference: https://protocol.vmc.info/english
public final class VMCDriver: @unchecked Sendable {

    public var convention: VMCCoordinateConvention = .flipX
    /// Write the hips bone position (converted) into the hips node translation.
    public var appliesHipsPosition: Bool = true
    /// Ignore incoming data older than this when applying, in seconds. `nil` applies regardless of age.
    public var maxAge: TimeInterval? = 0.5

    /// Upper bound on distinct blend-shape names buffered between `Blend/Apply` messages.
    /// Real senders emit tens of names; the cap stops a hostile sender from growing memory.
    public static let maxPendingBlendShapes = 256

    /// The latest received state. Reads take the driver's lock.
    public var frame: VMCFrame { withLock { _frame } }
    public var messageCount: Int { withLock { _messageCount } }
    public var ignoredMessageCount: Int { withLock { _ignoredMessageCount } }
    public var appliedFrameCount: Int { withLock { _appliedFrameCount } }

    private let lock = NSLock()
    private var _frame = VMCFrame()
    private var _messageCount = 0
    private var _ignoredMessageCount = 0
    private var _appliedFrameCount = 0
    private var pendingBlendShapes: [String: Float] = [:]
    private var restWorldRotations: [VRMHumanoidBone: simd_quatf] = [:]
    private var restCacheModel: ObjectIdentifier?

    public init(convention: VMCCoordinateConvention = .flipX) {
        self.convention = convention
    }

    // MARK: - Receiving

    public func receive(_ packet: OSCPacket) {
        for message in packet.messages {
            receive(message)
        }
    }

    public func receive(_ message: OSCMessage) {
        lock.lock()
        defer { lock.unlock() }
        _messageCount += 1
        let now = Date().timeIntervalSinceReferenceDate
        let args = message.arguments

        switch message.address {
        case "/VMC/Ext/Bone/Pos":
            guard let name = args.first?.stringValue, let transform = Self.transform(args, from: 1),
                  let bone = Self.humanoidBone(unityName: name) else {
                _ignoredMessageCount += 1
                return
            }
            _frame.bones[bone] = transform
            _frame.receivedAt = now

        case "/VMC/Ext/Root/Pos":
            guard let transform = Self.transform(args, from: 1) else {
                _ignoredMessageCount += 1
                return
            }
            _frame.root = transform
            _frame.receivedAt = now

        case "/VMC/Ext/Blend/Val":
            guard let name = args.first?.stringValue, args.count > 1, let value = args[1].floatValue,
                  pendingBlendShapes.count < Self.maxPendingBlendShapes || pendingBlendShapes[name] != nil else {
                _ignoredMessageCount += 1
                return
            }
            pendingBlendShapes[name] = value

        case "/VMC/Ext/Blend/Apply":
            _frame.blendShapes = pendingBlendShapes
            pendingBlendShapes = [:]
            _frame.receivedAt = now

        case "/VMC/Ext/OK":
            guard let loaded = args.first?.intValue else {
                _ignoredMessageCount += 1
                return
            }
            _frame.status = VMCDeviceStatus(
                loaded: loaded != 0,
                calibrationState: args.count > 1 ? args[1].intValue : nil,
                calibrationMode: args.count > 2 ? args[2].intValue : nil,
                trackingStatus: args.count > 3 ? args[3].intValue : nil
            )

        case "/VMC/Ext/T":
            _frame.time = args.first?.floatValue

        default:
            _ignoredMessageCount += 1
        }
    }

    // MARK: - Applying

    /// Writes the current frame's bone rotations (and hips position) to `model`, and blend shapes to `controller`.
    ///
    /// Returns `false` when nothing was applied because no frame has arrived or it is older than ``maxAge``.
    @discardableResult
    public func apply(to model: VRMModel, controller: VRMExpressionController? = nil) -> Bool {
        let snapshot = frame

        guard snapshot.receivedAt > 0 else { return false }
        if let maxAge, Date().timeIntervalSinceReferenceDate - snapshot.receivedAt > maxAge {
            return false
        }
        guard let humanoid = model.humanoid else { return false }

        ensureRestCache(for: model, humanoid: humanoid)

        var touched = false
        for (bone, transform) in snapshot.bones {
            guard let index = humanoid.getBoneNode(bone), index < model.nodes.count,
                  let restWorld = restWorldRotations[bone] else { continue }
            let node = model.nodes[index]
            let delta = convention.convert(rotation: transform.rotation)
            node.rotation = simd_normalize(node.initialRotation * restWorld.inverse * delta * restWorld)
            if bone == .hips, appliesHipsPosition {
                node.translation = convention.convert(position: transform.position)
            }
            node.updateLocalMatrix()
            touched = true
        }

        if touched {
            for node in model.nodes where node.parent == nil {
                node.updateWorldTransform()
            }
        }

        if let controller {
            for (name, value) in snapshot.blendShapes {
                if let preset = Self.expressionPreset(blendShapeName: name) {
                    controller.setExpressionWeight(preset, weight: value)
                } else {
                    controller.setCustomExpressionWeight(name, weight: value)
                }
            }
        }

        withLock { _appliedFrameCount += 1 }
        return true
    }

    /// Drops the received frame and pending blend shapes.
    public func reset() {
        withLock {
            _frame = VMCFrame()
            pendingBlendShapes = [:]
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    // MARK: - Name mapping

    /// Maps a Unity `HumanBodyBones` name to the VRM 1.0 bone.
    ///
    /// Unity's thumb chain is Proximal/Intermediate/Distal; VRM 1.0 names the
    /// same three bones Metacarpal/Proximal/Distal, so the thumb shifts by one.
    public static func humanoidBone(unityName: String) -> VRMHumanoidBone? {
        if let shifted = thumbShift[unityName] { return shifted }
        guard let first = unityName.first else { return nil }
        return VRMHumanoidBone(rawValue: first.lowercased() + unityName.dropFirst())
    }

    /// Unity `HumanBodyBones` name for a VRM bone (inverse of ``humanoidBone(unityName:)``).
    public static func unityName(for bone: VRMHumanoidBone) -> String {
        if let unity = thumbShift.first(where: { $0.value == bone })?.key { return unity }
        let raw = bone.rawValue
        return raw.prefix(1).uppercased() + raw.dropFirst()
    }

    private static let thumbShift: [String: VRMHumanoidBone] = [
        "LeftThumbProximal": .leftThumbMetacarpal,
        "LeftThumbIntermediate": .leftThumbProximal,
        "LeftThumbDistal": .leftThumbDistal,
        "RightThumbProximal": .rightThumbMetacarpal,
        "RightThumbIntermediate": .rightThumbProximal,
        "RightThumbDistal": .rightThumbDistal
    ]

    /// Maps a VMC blend-shape name (VRM 1.0 preset or VRM 0.x alias) to a preset. ARKit and custom names return `nil`.
    public static func expressionPreset(blendShapeName name: String) -> VRMExpressionPreset? {
        if let preset = VRMExpressionPreset(rawValue: name) { return preset }
        return vrm0Aliases[name]
    }

    private static let vrm0Aliases: [String: VRMExpressionPreset] = [
        "Neutral": .neutral,
        "A": .aa, "I": .ih, "U": .ou, "E": .ee, "O": .oh,
        "Blink": .blink, "Blink_L": .blinkLeft, "Blink_R": .blinkRight,
        "Joy": .happy, "Angry": .angry, "Sorrow": .sad, "Fun": .relaxed, "Surprised": .surprised,
        "LookUp": .lookUp, "LookDown": .lookDown, "LookLeft": .lookLeft, "LookRight": .lookRight,
        "Happy": .happy, "Sad": .sad, "Relaxed": .relaxed,
        "Aa": .aa, "Ih": .ih, "Ou": .ou, "Ee": .ee, "Oh": .oh,
        "BlinkLeft": .blinkLeft, "BlinkRight": .blinkRight
    ]

    // MARK: - Internals

    private static func transform(_ args: [OSCArgument], from start: Int) -> VMCBoneTransform? {
        guard args.count >= start + 7 else { return nil }
        var values: [Float] = []
        values.reserveCapacity(7)
        for i in start..<(start + 7) {
            guard let v = args[i].floatValue else { return nil }
            values.append(v)
        }
        return VMCBoneTransform(
            position: SIMD3<Float>(values[0], values[1], values[2]),
            rotation: simd_quatf(ix: values[3], iy: values[4], iz: values[5], r: values[6])
        )
    }

    private func ensureRestCache(for model: VRMModel, humanoid: VRMHumanoid) {
        let id = ObjectIdentifier(model)
        if restCacheModel == id { return }
        restCacheModel = id
        restWorldRotations = [:]
        for (bone, ref) in humanoid.humanBones where ref.node < model.nodes.count {
            restWorldRotations[bone] = Self.restWorldRotation(of: model.nodes[ref.node])
        }
    }

    /// Rest world rotation from the initial rotations along the ancestor chain, independent of the current pose.
    static func restWorldRotation(of node: VRMNode) -> simd_quatf {
        var rotation = node.initialRotation
        var current = node.parent
        while let parent = current {
            rotation = parent.initialRotation * rotation
            current = parent.parent
        }
        return simd_normalize(rotation)
    }
}
