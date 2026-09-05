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

import XCTest
import simd
@testable import VRMMetalKit

/// VRMC_node_constraint-1.0 evaluates every constraint relative to the rest
/// pose: the source contributes `inverse(srcRest) * srcCurrent`, and the
/// result is blended from `dstRest`, never from identity. These tests use
/// non-identity rest rotations so the rest handling is actually exercised.
final class ConstraintSolverRestPoseTests: XCTestCase {
    private func node(index: Int, rest: simd_quatf, translation: SIMD3<Float> = .zero) throws -> VRMNode {
        let json = """
        {
            "name": "n\(index)",
            "translation": [\(translation.x), \(translation.y), \(translation.z)],
            "rotation": [\(rest.imag.x), \(rest.imag.y), \(rest.imag.z), \(rest.real)],
            "scale": [1.0, 1.0, 1.0]
        }
        """
        let gltfNode = try JSONDecoder().decode(GLTFNode.self, from: json.data(using: .utf8)!)
        return VRMNode(index: index, gltfNode: gltfNode)
    }

    private func assertEqual(_ a: simd_quatf, _ b: simd_quatf, accuracy: Float = 1e-3,
                             _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        // q and -q are the same rotation.
        let d = min(simd_length(a.vector - b.vector), simd_length(a.vector + b.vector))
        XCTAssertLessThan(d, accuracy, "\(message): got \(a), expected \(b)", file: file, line: line)
    }

    private let xAxis = SIMD3<Float>(1, 0, 0)

    // MARK: Roll

    func testRollWithUnmovedSourceLeavesTargetAtRest() throws {
        let srcRest = simd_quatf(angle: .pi, axis: xAxis)
        let source = try node(index: 0, rest: srcRest)
        let target = try node(index: 1, rest: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1))
        let constraint = VRMNodeConstraint(targetNode: 1, constraint: .roll(sourceNode: 0, axis: xAxis, weight: 1))

        ConstraintSolver().solve(constraints: [constraint], nodes: [source, target])

        assertEqual(target.rotation, simd_quatf(ix: 0, iy: 0, iz: 0, r: 1), "no source delta must produce no twist")
    }

    func testRollTransfersDeltaFromSourceRest() throws {
        let srcRest = simd_quatf(angle: .pi, axis: xAxis)
        let delta = simd_quatf(angle: .pi / 6, axis: xAxis)
        let source = try node(index: 0, rest: srcRest)
        source.rotation = srcRest * delta
        let target = try node(index: 1, rest: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1))
        let constraint = VRMNodeConstraint(targetNode: 1, constraint: .roll(sourceNode: 0, axis: xAxis, weight: 1))

        ConstraintSolver().solve(constraints: [constraint], nodes: [source, target])

        assertEqual(target.rotation, delta, "twist must be the rest-relative delta, same sense as the source")
    }

    func testRollPreservesTargetRest() throws {
        let dstRest = simd_quatf(angle: 20 * .pi / 180, axis: xAxis)
        let source = try node(index: 0, rest: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1))
        let target = try node(index: 1, rest: dstRest)
        let constraint = VRMNodeConstraint(targetNode: 1, constraint: .roll(sourceNode: 0, axis: xAxis, weight: 1))

        ConstraintSolver().solve(constraints: [constraint], nodes: [source, target])

        assertEqual(target.rotation, dstRest, "target rest must survive an idle source")
    }

    // MARK: Rotation

    func testRotationAppliesDeltaOnTopOfTargetRest() throws {
        let srcRest = simd_quatf(angle: .pi, axis: xAxis)
        let delta = simd_quatf(angle: .pi / 6, axis: xAxis)
        let dstRest = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 1, 0))
        let source = try node(index: 0, rest: srcRest)
        source.rotation = srcRest * delta
        let target = try node(index: 1, rest: dstRest)
        let constraint = VRMNodeConstraint(targetNode: 1, constraint: .rotation(sourceNode: 0, weight: 1))

        ConstraintSolver().solve(constraints: [constraint], nodes: [source, target])

        assertEqual(target.rotation, dstRest * delta, "rotation constraint must be dstRest * (inv(srcRest) * src)")
    }

    func testRotationWeightBlendsFromTargetRest() throws {
        let dstRest = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 1, 0))
        let source = try node(index: 0, rest: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1))
        let target = try node(index: 1, rest: dstRest)
        let constraint = VRMNodeConstraint(targetNode: 1, constraint: .rotation(sourceNode: 0, weight: 0.5))

        ConstraintSolver().solve(constraints: [constraint], nodes: [source, target])

        assertEqual(target.rotation, dstRest, "weight blends between dstRest and dstRest*delta, so idle source keeps rest")
    }

    // MARK: Aim

    func testAimPreservesTargetRestTwistAboutAimAxis() throws {
        // Rest twists the target 90° about its own aim axis (+Z). The source
        // sits on +Z, so the aim is already satisfied and the rest must survive.
        let dstRest = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 0, 1))
        let source = try node(index: 0, rest: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1), translation: SIMD3<Float>(0, 0, 1))
        let target = try node(index: 1, rest: dstRest)
        source.updateWorldTransform()
        target.updateWorldTransform()
        let constraint = VRMNodeConstraint(targetNode: 1, constraint: .aim(sourceNode: 0, aimAxis: SIMD3<Float>(0, 0, 1), weight: 1))

        ConstraintSolver().solve(constraints: [constraint], nodes: [source, target])

        assertEqual(target.rotation, dstRest, "aim must rotate from the rested axis, keeping rest twist")
    }
}
