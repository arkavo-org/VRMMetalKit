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

import XCTest
import simd
@testable import VRMMetalKit

/// `removeAll()` without `keepingCapacity` drops dictionary storage every
/// frame on the animation / expression hot path. These tests pin the
/// production reset helpers so a later `removeAll()` regression is visible.
final class HotPathStorageCapacityTests: XCTestCase {

    func testExpressionControllerResetKeepsMeshWeightCapacity() {
        let controller = VRMExpressionController()
        var expression = VRMExpression(preset: .happy)
        for meshIndex in 0..<32 {
            expression.morphTargetBinds.append(
                VRMMorphTargetBind(node: meshIndex, index: 0, weight: 1.0)
            )
        }
        controller.registerExpression(expression, for: .happy)
        controller.setExpressionWeight(.happy, weight: 1.0)
        _ = controller.weightsForMesh(0, morphCount: 1)

        let capacityAfterFill = controller.meshMorphWeightStorageCapacity
        XCTAssertGreaterThanOrEqual(capacityAfterFill, 32)

        controller.resetMorphWeightScratch()

        XCTAssertEqual(controller.meshMorphWeightStorageCapacity, capacityAfterFill,
                       "reset must keep dictionary storage; removeAll() without keepingCapacity drops it")
        XCTAssertGreaterThanOrEqual(controller.cachedMeshMorphWeightStorageCapacity, 32)
        XCTAssertEqual(controller.meshMorphWeightCount, 0)
    }

    func testAnimationPlayerResetKeepsMorphCacheCapacity() throws {
        let model = try VRMBuilder()
            .setSkeleton(.defaultHumanoid)
            .build()

        var clip = AnimationClip(duration: 1.0)
        for i in 0..<16 {
            clip.addMorphTrack(key: "expr\(i)") { _ in 0.5 }
        }

        let player = AnimationPlayer()
        player.load(clip)
        player.update(deltaTime: 1.0 / 60.0, model: model)

        let capacityAfterFill = player.morphWeightCacheCapacity
        XCTAssertGreaterThanOrEqual(capacityAfterFill, 16)

        player.resetMorphWeightCache()

        XCTAssertEqual(player.morphWeightCacheCapacity, capacityAfterFill,
                       "reset must keep dictionary storage; removeAll() without keepingCapacity drops it")
        XCTAssertEqual(player.morphWeightCacheCount, 0)
    }
}
