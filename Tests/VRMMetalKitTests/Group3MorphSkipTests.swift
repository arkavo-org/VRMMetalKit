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
@testable import VRMMetalKit

/// Group 3: skip morph GPU work when expression weights are unchanged,
/// and reuse the per-mesh weight scratch instead of allocating every read.
final class Group3MorphSkipTests: XCTestCase {

    func testGateReusesOutputWhenFingerprintMatches() {
        XCTAssertTrue(
            MorphComputeGate.shouldReusePreviousOutput(
                currentFingerprint: 42,
                previousFingerprint: 42
            )
        )
        XCTAssertFalse(
            MorphComputeGate.shouldReusePreviousOutput(
                currentFingerprint: 42,
                previousFingerprint: 7
            )
        )
        XCTAssertFalse(
            MorphComputeGate.shouldReusePreviousOutput(
                currentFingerprint: 42,
                previousFingerprint: nil
            ),
            "first frame has no previous output to reuse"
        )
    }

    /// A `nil` previous fingerprint is the invalidation sentinel a caller writes
    /// after a partial compute failure (VMK PR #420 review, task 2): the fix
    /// relies on `nil` never matching *any* current fingerprint, so a caller
    /// can force a re-dispatch on the next frame regardless of what value the
    /// weights happen to hash to (including zero and the maximum representable
    /// value, and even if a prior frame's recorded fingerprint happened to be 0).
    func testGateNeverReusesWhenPreviousFingerprintIsNil() {
        let candidateFingerprints: [UInt64] = [0, 1, 42, UInt64.max]
        for fingerprint in candidateFingerprints {
            XCTAssertFalse(
                MorphComputeGate.shouldReusePreviousOutput(
                    currentFingerprint: fingerprint,
                    previousFingerprint: nil
                ),
                "nil previousFingerprint (the invalidation sentinel) must never match currentFingerprint \(fingerprint)"
            )
        }
    }

    func testFingerprintStableWhenWeightsDoNotChange() {
        let controller = VRMExpressionController()
        var expression = VRMExpression(preset: .happy)
        expression.morphTargetBinds.append(
            VRMMorphTargetBind(node: 0, index: 0, weight: 1.0)
        )
        controller.registerExpression(expression, for: .happy)
        controller.setExpressionWeight(.happy, weight: 0.6)
        _ = controller.weightsForMesh(0, morphCount: 4)

        let first = controller.morphWeightsFingerprint()
        let second = controller.morphWeightsFingerprint()
        XCTAssertEqual(first, second)
    }

    func testFingerprintChangesWhenExpressionWeightChanges() {
        let controller = VRMExpressionController()
        var expression = VRMExpression(preset: .happy)
        expression.morphTargetBinds.append(
            VRMMorphTargetBind(node: 0, index: 0, weight: 1.0)
        )
        controller.registerExpression(expression, for: .happy)
        controller.setExpressionWeight(.happy, weight: 0.2)
        _ = controller.weightsForMesh(0, morphCount: 4)
        let before = controller.morphWeightsFingerprint()

        controller.setExpressionWeight(.happy, weight: 0.9)
        _ = controller.weightsForMesh(0, morphCount: 4)
        let after = controller.morphWeightsFingerprint()

        XCTAssertNotEqual(before, after)
    }

    func testWeightsForMeshReusesScratchCapacity() {
        let controller = VRMExpressionController()
        var expression = VRMExpression(preset: .aa)
        expression.morphTargetBinds.append(
            VRMMorphTargetBind(node: 3, index: 2, weight: 1.0)
        )
        controller.registerExpression(expression, for: .aa)
        controller.setExpressionWeight(.aa, weight: 1.0)

        let first = controller.weightsForMesh(3, morphCount: 32)
        XCTAssertEqual(first.count, 32)
        let capacity = controller.weightReadScratchCapacity(for: 3)
        XCTAssertGreaterThanOrEqual(capacity, 32)

        controller.setExpressionWeight(.aa, weight: 0.5)
        let second = controller.weightsForMesh(3, morphCount: 32)
        XCTAssertEqual(second.count, 32)
        XCTAssertEqual(
            controller.weightReadScratchCapacity(for: 3),
            capacity,
            "weightsForMesh must refill the same scratch, not allocate a new array"
        )
    }
}
