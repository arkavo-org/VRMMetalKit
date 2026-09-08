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

import XCTest
import Network
import simd
@testable import VRMMetalKit

final class VMCDriverTests: XCTestCase {

    private func bonePos(_ name: String, _ p: SIMD3<Float>, _ q: simd_quatf) -> OSCMessage {
        OSCMessage(address: "/VMC/Ext/Bone/Pos", arguments: [
            .string(name), .float32(p.x), .float32(p.y), .float32(p.z),
            .float32(q.imag.x), .float32(q.imag.y), .float32(q.imag.z), .float32(q.real)
        ])
    }

    private let identity = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)

    // MARK: - Name mapping

    func testUnityBoneNamesMapToVRMBones() {
        XCTAssertEqual(VMCDriver.humanoidBone(unityName: "Hips"), .hips)
        XCTAssertEqual(VMCDriver.humanoidBone(unityName: "LeftUpperArm"), .leftUpperArm)
        XCTAssertEqual(VMCDriver.humanoidBone(unityName: "RightIndexProximal"), .rightIndexProximal)
        XCTAssertEqual(VMCDriver.humanoidBone(unityName: "UpperChest"), .upperChest)
        XCTAssertEqual(VMCDriver.humanoidBone(unityName: "LeftEye"), .leftEye)
        XCTAssertNil(VMCDriver.humanoidBone(unityName: "LastBone"))
        XCTAssertNil(VMCDriver.humanoidBone(unityName: ""))
    }

    func testUnityThumbChainShiftsToVRMNames() {
        XCTAssertEqual(VMCDriver.humanoidBone(unityName: "LeftThumbProximal"), .leftThumbMetacarpal)
        XCTAssertEqual(VMCDriver.humanoidBone(unityName: "LeftThumbIntermediate"), .leftThumbProximal)
        XCTAssertEqual(VMCDriver.humanoidBone(unityName: "LeftThumbDistal"), .leftThumbDistal)
        XCTAssertEqual(VMCDriver.humanoidBone(unityName: "RightThumbIntermediate"), .rightThumbProximal)
    }

    func testUnityNameIsInverseOfBoneMapping() {
        for bone in VRMHumanoidBone.allCases {
            XCTAssertEqual(VMCDriver.humanoidBone(unityName: VMCDriver.unityName(for: bone)), bone, "\(bone)")
        }
        XCTAssertEqual(VMCDriver.unityName(for: .leftThumbMetacarpal), "LeftThumbProximal")
        XCTAssertEqual(VMCDriver.unityName(for: .hips), "Hips")
    }

    func testBlendShapeNamesMapPresetsAndVRM0Aliases() {
        XCTAssertEqual(VMCDriver.expressionPreset(blendShapeName: "happy"), .happy)
        XCTAssertEqual(VMCDriver.expressionPreset(blendShapeName: "Joy"), .happy)
        XCTAssertEqual(VMCDriver.expressionPreset(blendShapeName: "A"), .aa)
        XCTAssertEqual(VMCDriver.expressionPreset(blendShapeName: "Blink_L"), .blinkLeft)
        XCTAssertEqual(VMCDriver.expressionPreset(blendShapeName: "Sorrow"), .sad)
        XCTAssertEqual(VMCDriver.expressionPreset(blendShapeName: "Fun"), .relaxed)
        XCTAssertEqual(VMCDriver.expressionPreset(blendShapeName: "LookUp"), .lookUp)
        XCTAssertNil(VMCDriver.expressionPreset(blendShapeName: "jawOpen"), "ARKit names are custom expressions, not presets")
    }

    // MARK: - Coordinates

    func testFlipXConvertsPositionAndRotation() {
        let c = VMCCoordinateConvention.flipX
        XCTAssertEqual(c.convert(position: SIMD3<Float>(1, 2, 3)), SIMD3<Float>(-1, 2, 3))
        let q = c.convert(rotation: simd_quatf(ix: 0.1, iy: 0.2, iz: 0.3, r: 0.9))
        XCTAssertEqual(q.imag, SIMD3<Float>(0.1, -0.2, -0.3))
        XCTAssertEqual(q.real, 0.9)
    }

    func testFlipZConvertsPositionAndRotation() {
        let c = VMCCoordinateConvention.flipZ
        XCTAssertEqual(c.convert(position: SIMD3<Float>(1, 2, 3)), SIMD3<Float>(1, 2, -3))
        let q = c.convert(rotation: simd_quatf(ix: 0.1, iy: 0.2, iz: 0.3, r: 0.9))
        XCTAssertEqual(q.imag, SIMD3<Float>(-0.1, -0.2, 0.3))
    }

    func testUnityYaw90OnLeftUpperArmSwingsLeftHandForward() throws {
        // In Unity a +90° yaw about +Y rotates the left arm (which points -X there) to +Z: the hand ends in front.
        let model = try SyntheticHumanoidRig.makeTPose()
        let driver = VMCDriver()
        let s = sqrt(0.5) as Float
        driver.receive(bonePos("LeftUpperArm", .zero, simd_quatf(ix: 0, iy: s, iz: 0, r: s)))
        XCTAssertTrue(driver.apply(to: model))

        let shoulder = SyntheticHumanoidRig.worldPosition(.leftUpperArm, in: model)
        let hand = SyntheticHumanoidRig.worldPosition(.leftHand, in: model)
        XCTAssertLessThan(simd_distance(hand, shoulder + SIMD3<Float>(0, 0, 0.5)), 0.002,
                          "left hand should be 0.5 m in front of the shoulder, got \(hand - shoulder)")
    }

    func testHipsPositionIsConvertedAndApplied() throws {
        let model = try SyntheticHumanoidRig.makeTPose()
        let driver = VMCDriver()
        driver.receive(bonePos("Hips", SIMD3<Float>(0.1, 0.95, 0.2), identity))
        XCTAssertTrue(driver.apply(to: model))
        let hips = SyntheticHumanoidRig.worldPosition(.hips, in: model)
        XCTAssertEqual(hips, SIMD3<Float>(-0.1, 0.95, 0.2))

        driver.appliesHipsPosition = false
        driver.receive(bonePos("Hips", SIMD3<Float>(0.5, 0.5, 0.5), identity))
        driver.apply(to: model)
        XCTAssertEqual(SyntheticHumanoidRig.worldPosition(.hips, in: model), SIMD3<Float>(-0.1, 0.95, 0.2),
                       "hips must not move when position application is off")
    }

    func testRestRelativeApplicationOnRotatedRestBone() throws {
        // Give the left upper arm a non-identity rest rotation and confirm the
        // world-space effect of the received delta is unchanged.
        let model = try SyntheticHumanoidRig.makeTPose()
        let upper = model.nodes[model.humanoid!.getBoneNode(.leftUpperArm)!]
        let lower = model.nodes[model.humanoid!.getBoneNode(.leftLowerArm)!]
        let twist = simd_quatf(angle: 0.7, axis: SIMD3<Float>(1, 0, 0))
        upper.rotation = twist
        upper.initialRotation = twist
        lower.translation = twist.inverse.act(lower.translation)
        lower.initialTranslation = lower.translation
        model.nodes[0].updateWorldTransform()
        let restHand = SyntheticHumanoidRig.worldPosition(.leftHand, in: model)

        let driver = VMCDriver()
        let s = sqrt(0.5) as Float
        driver.receive(bonePos("LeftUpperArm", .zero, simd_quatf(ix: 0, iy: s, iz: 0, r: s)))
        driver.apply(to: model)

        let shoulder = SyntheticHumanoidRig.worldPosition(.leftUpperArm, in: model)
        let hand = SyntheticHumanoidRig.worldPosition(.leftHand, in: model)
        let expected = simd_quatf(angle: -.pi / 2, axis: SIMD3<Float>(0, 1, 0)).act(restHand - shoulder)
        XCTAssertLessThan(simd_distance(hand - shoulder, expected), 0.002)
    }

    // MARK: - Blend shapes

    func testBlendValuesCommitOnlyOnApply() throws {
        let model = try SyntheticHumanoidRig.makeTPose()
        let controller = VRMExpressionController()
        let driver = VMCDriver()
        driver.receive(bonePos("Hips", .zero, identity))
        driver.receive(OSCMessage("/VMC/Ext/Blend/Val", .string("Joy"), .float32(0.8)))
        driver.receive(OSCMessage("/VMC/Ext/Blend/Val", .string("A"), .float32(0.4)))
        driver.apply(to: model, controller: controller)
        XCTAssertEqual(controller.weight(for: .happy), 0, "values before Apply must not leak")

        driver.receive(OSCMessage(address: "/VMC/Ext/Blend/Apply"))
        driver.apply(to: model, controller: controller)
        XCTAssertEqual(controller.weight(for: .happy), 0.8, accuracy: 1e-6)
        XCTAssertEqual(controller.weight(for: .aa), 0.4, accuracy: 1e-6)
        XCTAssertEqual(driver.frame.blendShapes, ["Joy": 0.8, "A": 0.4])
    }

    // MARK: - Status and bookkeeping

    func testStatusAndTimeMessages() {
        let driver = VMCDriver()
        driver.receive(OSCMessage("/VMC/Ext/OK", .int32(1), .int32(3), .int32(0), .int32(1)))
        driver.receive(OSCMessage("/VMC/Ext/T", .float32(12.5)))
        XCTAssertEqual(driver.frame.status, VMCDeviceStatus(loaded: true, calibrationState: 3, calibrationMode: 0, trackingStatus: 1))
        XCTAssertEqual(driver.frame.time, 12.5)
    }

    func testUnknownAndMalformedMessagesAreCounted() {
        let driver = VMCDriver()
        driver.receive(OSCMessage(address: "/VMC/Ext/Something"))
        driver.receive(OSCMessage("/VMC/Ext/Bone/Pos", .string("Hips"), .float32(1)))
        driver.receive(bonePos("NotABone", .zero, identity))
        XCTAssertEqual(driver.messageCount, 3)
        XCTAssertEqual(driver.ignoredMessageCount, 3)
        XCTAssertTrue(driver.frame.bones.isEmpty)
    }

    func testApplyWithoutDataReturnsFalse() throws {
        let model = try SyntheticHumanoidRig.makeTPose()
        XCTAssertFalse(VMCDriver().apply(to: model))
    }

    func testStaleFrameIsNotApplied() throws {
        let model = try SyntheticHumanoidRig.makeTPose()
        let driver = VMCDriver()
        driver.maxAge = 0
        driver.receive(bonePos("Hips", SIMD3<Float>(0, 2, 0), identity))
        Thread.sleep(forTimeInterval: 0.01)
        XCTAssertFalse(driver.apply(to: model))
        driver.maxAge = nil
        XCTAssertTrue(driver.apply(to: model))
    }

    // MARK: - Encoder round trip

    func testEncoderFrameReproducesPoseThroughDriver() throws {
        let source = try SyntheticHumanoidRig.makeTPose()
        let compositor = AnimationLayerCompositor()
        compositor.setup(model: source)
        let ik = ArmIKLayer()
        compositor.addArmIKLayer(ik, for: source)
        ik.leftHand = ArmIKLayer.HandTarget(position: SIMD3<Float>(0.45, 1.05, 0.2))
        ik.rightFingers = .fist
        compositor.update(deltaTime: 1 / 60, context: AnimationContext(time: 0, deltaTime: 1 / 60))

        let controller = VRMExpressionController()
        controller.setExpressionWeight(.happy, weight: 0.6)
        let bundle = VMCEncoder.frame(for: source, controller: controller, time: 1.0)
        let packet = try OSCPacket.decode(bundle.encode())

        let target = try SyntheticHumanoidRig.makeTPose()
        let targetController = VRMExpressionController()
        let driver = VMCDriver()
        driver.receive(packet)
        XCTAssertTrue(driver.apply(to: target, controller: targetController))

        for bone in [VRMHumanoidBone.leftHand, .leftLowerArm, .rightIndexDistal, .rightThumbDistal, .head] {
            let a = SyntheticHumanoidRig.worldPosition(bone, in: source)
            let b = SyntheticHumanoidRig.worldPosition(bone, in: target)
            XCTAssertLessThan(simd_distance(a, b), 1e-3, "\(bone) mismatch: \(a) vs \(b)")
        }
        XCTAssertEqual(targetController.weight(for: .happy), 0.6, accuracy: 1e-6)
        XCTAssertEqual(driver.frame.time, 1.0)
        XCTAssertEqual(driver.frame.status?.loaded, true)
    }

    // MARK: - Receiver loopback

    func testReceiverDeliversDatagramOverLoopback() throws {
        let received = expectation(description: "packet received")
        let receiver = VMCReceiver(port: 0)
        let driver = VMCDriver()
        receiver.onPacket = { packet in
            driver.receive(packet)
            received.fulfill()
        }
        do {
            try receiver.start()
        } catch {
            throw XCTSkip("UDP listener unavailable in this environment: \(error)")
        }
        defer { receiver.stop() }
        guard receiver.waitUntilReady(timeout: 3), let port = receiver.boundPort else {
            throw XCTSkip("UDP listener did not become ready")
        }

        let payload = OSCBundle(elements: [
            .message(VMCEncoder.blendValue("Joy", 0.25)),
            .message(VMCEncoder.blendApply())
        ]).encode()
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .udp)
        connection.start(queue: DispatchQueue(label: "vmc-test-sender"))
        connection.send(content: payload, completion: .contentProcessed { _ in })

        wait(for: [received], timeout: 5)
        connection.cancel()
        XCTAssertEqual(driver.frame.blendShapes, ["Joy": 0.25])
        XCTAssertEqual(receiver.packetCount, 1)
    }
}

/// Verifies the Unity-to-model convention on a real VRM 0.x asset, which the
/// loader rotates 180° about Y so it faces +Z like VRM 1.0.
final class VMCDriverVRM0FixtureTests: XCTestCase {
    private func vrm0FixtureURL() -> URL? {
        var candidates: [URL] = []
        if let env = ProcessInfo.processInfo.environment["VRM0_FIXTURE_PATH"] {
            candidates.append(URL(fileURLWithPath: env))
        }
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        candidates.append(root.appendingPathComponent("AliciaSolid.vrm"))
        candidates.append(root.deletingLastPathComponent().appendingPathComponent("GameOfMods/VRM0-archive/AliciaSolid.vrm"))
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    func testFlipXHoldsOnLoadedVRM0Model() async throws {
        guard let url = vrm0FixtureURL() else {
            throw XCTSkip("No VRM 0.x fixture (set VRM0_FIXTURE_PATH or place AliciaSolid.vrm at the repo root)")
        }
        let model = try await VRMModel.load(from: url)
        XCTAssertEqual(model.specVersion, .v0_0, "fixture must be a VRM 0.x file")
        let humanoid = try XCTUnwrap(model.humanoid)
        let shoulder = model.nodes[try XCTUnwrap(humanoid.getBoneNode(.leftUpperArm))]
        let hand = model.nodes[try XCTUnwrap(humanoid.getBoneNode(.leftHand))]

        let restArm = hand.worldPosition - shoulder.worldPosition
        XCTAssertGreaterThan(restArm.x, 0.8 * simd_length(restArm), "loaded 0.x left arm must point +X like VRM 1.0")

        let driver = VMCDriver()
        let s = sqrt(0.5) as Float
        driver.receive(OSCMessage(address: "/VMC/Ext/Bone/Pos", arguments: [
            .string("LeftUpperArm"), .float32(0), .float32(0), .float32(0),
            .float32(0), .float32(s), .float32(0), .float32(s)
        ]))
        XCTAssertTrue(driver.apply(to: model))

        let arm = hand.worldPosition - shoulder.worldPosition
        XCTAssertGreaterThan(arm.z, 0.8 * simd_length(arm), "Unity yaw +90° must swing the left hand forward (+Z), got \(arm)")
        XCTAssertEqual(simd_length(arm), simd_length(restArm), accuracy: 1e-3)
    }
}

final class VMCReceiverLifecycleTests: XCTestCase {
    private func send(_ data: Data, to port: UInt16) -> NWConnection {
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .udp)
        connection.start(queue: DispatchQueue(label: "vmc-lifecycle-sender"))
        connection.send(content: data, completion: .contentProcessed { _ in })
        return connection
    }

    func testRestartAfterStopBindsFreshPortAndReceives() throws {
        let receiver = VMCReceiver(port: 0)
        do { try receiver.start() } catch { throw XCTSkip("UDP listener unavailable: \(error)") }
        guard receiver.waitUntilReady(timeout: 3) else { throw XCTSkip("listener not ready") }
        receiver.stop()
        XCTAssertNil(receiver.boundPort)

        let received = expectation(description: "packet after restart")
        receiver.onPacket = { _ in received.fulfill() }
        try receiver.start()
        XCTAssertTrue(receiver.waitUntilReady(timeout: 3), "second start must wait for its own listener")
        let port = try XCTUnwrap(receiver.boundPort)
        let sender = send(VMCEncoder.blendApply().encode(), to: port)
        wait(for: [received], timeout: 5)
        sender.cancel()
        receiver.stop()
    }

    func testSenderFlowsAreCappedAtMaxConnections() throws {
        let receiver = VMCReceiver(port: 0)
        receiver.maxConnections = 1
        let first = expectation(description: "packet from first flow")
        let second = expectation(description: "packet from second flow")
        let counter = VMCDriver()
        receiver.onPacket = { packet in
            counter.receive(packet)
            switch counter.messageCount {
            case 1: first.fulfill()
            case 2: second.fulfill()
            default: break
            }
        }
        do { try receiver.start() } catch { throw XCTSkip("UDP listener unavailable: \(error)") }
        guard receiver.waitUntilReady(timeout: 3), let port = receiver.boundPort else { throw XCTSkip("listener not ready") }

        // Sequential so the first flow's datagram lands before the second flow evicts it.
        let a = send(VMCEncoder.blendApply().encode(), to: port)
        wait(for: [first], timeout: 5)
        XCTAssertEqual(receiver.connectionCount, 1)
        let b = send(VMCEncoder.blendApply().encode(), to: port)
        wait(for: [second], timeout: 5)
        XCTAssertLessThanOrEqual(receiver.connectionCount, 1, "oldest flow must be evicted past the cap")
        a.cancel()
        b.cancel()
        receiver.stop()
    }
}
