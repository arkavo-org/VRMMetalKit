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
import Metal
import simd
@testable import VRMMetalKit

/// `CrowdFrameStepper` disables `AnimationPlayer.solvesConstraints` because S4
/// solves node constraints on the final pipeline pose instead. Since
/// `avatarsForCamera` hands those same player instances back, the stepper
/// borrows that flag rather than taking it: a host that later drives one of its
/// players directly must not silently lose twist/aim constraint solving.
final class PlayerOwnershipTests: XCTestCase {

    @MainActor private func avatar(_ device: MTLDevice, index: Int, player: AnimationPlayer) async throws
        -> CrowdFrameStepper.Avatar {
        let path = getTestVRM10ModelPath(); try requireFixture(path, hint: testVRM10Filename)
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device,
            options: VRMLoadingOptions(augmentSpringBoneColliders: false))
        var config = RendererConfig(); config.synchronousSpringBone = true
        let r = VRMRenderer(device: device, config: config)
        r.loadModel(model)
        model.updateNodeTransforms()
        return CrowdFrameStepper.Avatar(renderer: r, model: model, player: player, index: index)
    }

    /// The flag is off for the stepper's lifetime and back to its prior value once
    /// the stepper is gone.
    @MainActor func testStepperRestoresSolvesConstraintsOnDeinit() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }

        let player = AnimationPlayer()
        XCTAssertTrue(player.solvesConstraints, "precondition: a fresh player solves its own constraints")

        do {
            let a = try await avatar(device, index: 0, player: player)
            let driver = CrowdMotionDriver(startSep: 1.0, holdSep: 1.0,
                                           approachStart: 0.0, approachEnd: 0.01, holdEnd: 1.0, partEnd: 1.0)
            let stepper = CrowdFrameStepper(avatars: [a], driver: driver, group: nil, fps: 60)
            XCTAssertFalse(player.solvesConstraints,
                           "while the stepper owns the frame, S4 solves constraints instead of the player")
            stepper.step(frameTime: 0)
        }

        XCTAssertTrue(player.solvesConstraints,
                      "the stepper borrowed the flag; on teardown the caller's player must be as it was found")
    }

    /// A player that already had solving disabled stays disabled — restore returns
    /// the prior value, it does not force `true`.
    @MainActor func testRestorePreservesAnAlreadyDisabledFlag() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }

        let player = AnimationPlayer()
        player.solvesConstraints = false

        do {
            let a = try await avatar(device, index: 0, player: player)
            let driver = CrowdMotionDriver(startSep: 1.0, holdSep: 1.0,
                                           approachStart: 0.0, approachEnd: 0.01, holdEnd: 1.0, partEnd: 1.0)
            _ = CrowdFrameStepper(avatars: [a], driver: driver, group: nil, fps: 60)
        }

        XCTAssertFalse(player.solvesConstraints, "restore returns the prior value, it does not force true")
    }
}
