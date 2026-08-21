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
import Metal
import simd
@testable import VRMMetalKit

/// Regression tests for the `MorphComputeGate` reuse optimization in
/// `applyMorphTargetsCompute`. The gate records an expression-weight
/// fingerprint and reuses last frame's morphed buffers when the fingerprint
/// is unchanged. The fingerprint must always describe exactly what
/// `morphedBuffers` currently holds — otherwise a gate hit can resurrect a
/// stale dict.
///
/// A synthetic model with a single, <=8-morph-target primitive is used
/// (rather than a full avatar fixture) so that a zero-weight frame actually
/// takes the `guard needsComputePath else { return [:] }` early-out: real
/// avatars bundle enough blend shapes on the face mesh that `needsComputePath`
/// is forced `true` unconditionally (`primitive.morphTargets.count > 8`),
/// which never reaches the vulnerable code path.
final class MorphComputeGateStalenessTests: XCTestCase {

    var device: MTLDevice!

    override func setUp() async throws {
        device = MTLCreateSystemDefaultDevice()
        guard device != nil else {
            throw XCTSkip("Metal device not available")
        }
    }

    // MARK: - Test Fixture

    /// Builds a minimal VRM model (via `VRMBuilder`'s default humanoid) and
    /// appends a synthetic mesh with a single primitive carrying two morph
    /// targets, bound to the `.happy` preset at full weight. The mesh has
    /// real GPU base-position and SoA-delta buffers, so the compute path can
    /// actually dispatch and populate `morphedBuffers`.
    private func makeSyntheticMorphModel() async throws -> (model: VRMModel, meshIndex: Int) {
        let vrmDocument = try VRMBuilder()
            .setSkeleton(.defaultHumanoid)
            .build()

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("vrm")
        try vrmDocument.serialize(to: tempURL)
        let model = try await VRMModel.load(from: tempURL, device: device)
        try? FileManager.default.removeItem(at: tempURL)

        let vertexCount = 4
        let positions = (0..<vertexCount).map { i in
            VRMPositionVertex(position: SIMD3<Float>(Float(i), 0, 0))
        }
        let vertexBufferSize = vertexCount * MemoryLayout<VRMPositionVertex>.stride
        guard let vertexBuffer = device.makeBuffer(bytes: positions, length: vertexBufferSize, options: .storageModeShared) else {
            throw XCTSkip("Could not allocate synthetic vertex buffer")
        }

        let primitive = VRMPrimitive()
        primitive.vertexCount = vertexCount
        primitive.vertexBuffer = vertexBuffer

        var morphA = VRMMorphTarget(name: "morphA")
        morphA.positionDeltas = (0..<vertexCount).map { _ in SIMD3<Float>(0, 0.1, 0) }
        var morphB = VRMMorphTarget(name: "morphB")
        morphB.positionDeltas = (0..<vertexCount).map { _ in SIMD3<Float>(0.1, 0, 0) }
        primitive.morphTargets = [morphA, morphB]
        primitive.createMorphTargetBuffers(device: device)

        XCTAssertNotNil(primitive.basePositionsBuffer, "createMorphTargetBuffers should populate base positions")
        XCTAssertNotNil(primitive.morphPositionsSoA, "createMorphTargetBuffers should populate the SoA delta buffer")

        let mesh = VRMMesh(name: "SyntheticMorphMesh")
        mesh.primitives = [primitive]

        let meshIndex = model.meshes.count
        model.meshes.append(mesh)

        var expression = VRMExpression(preset: .happy)
        expression.morphTargetBinds.append(
            VRMMorphTargetBind(node: meshIndex, index: 0, weight: 1.0)
        )
        let expressions = model.expressions ?? VRMExpressions()
        expressions.preset[.happy] = expression
        model.expressions = expressions

        return (model, meshIndex)
    }

    private func makeCommandBuffer(_ renderer: VRMRenderer) throws -> MTLCommandBuffer {
        guard let commandBuffer = renderer.commandQueue.makeCommandBuffer() else {
            throw XCTSkip("Could not create command buffer")
        }
        return commandBuffer
    }

    // MARK: - Regression: stale reuse after weights return to zero

    /// RED: drives weights 1.0 -> 0.0 -> (unchanged) 0.0. The third frame's
    /// fingerprint matches the second frame's, so the gate fires. Before the
    /// fix, the second frame (zero weights) never cleared `morphedBuffers`
    /// before recording that fingerprint, so the gate hit on frame 3 returned
    /// the stale non-empty dict from frame 1.
    func testStaleMorphBuffersAreNotReusedAfterWeightsReturnToZero() async throws {
        let (model, _) = try await makeSyntheticMorphModel()

        let renderer = VRMRenderer(device: device)
        renderer.loadModel(model)
        guard let controller = renderer.expressionController else {
            XCTFail("Expression controller missing")
            return
        }

        // Frame 1: nonzero weight forces the compute path and populates morphedBuffers.
        controller.setExpressionWeight(.happy, weight: 1.0)
        let cb1 = try makeCommandBuffer(renderer)
        let frame1 = renderer.applyMorphTargetsCompute(commandBuffer: cb1)
        cb1.commit()
        await cb1.completed()
        XCTAssertFalse(frame1.isEmpty, "Nonzero weights should populate morphed buffers")

        // Frame 2: weights return to zero -> neutral frame, dict must go empty.
        controller.setExpressionWeight(.happy, weight: 0.0)
        let cb2 = try makeCommandBuffer(renderer)
        let frame2 = renderer.applyMorphTargetsCompute(commandBuffer: cb2)
        cb2.commit()
        await cb2.completed()
        XCTAssertTrue(frame2.isEmpty, "Zero weights should render neutral (no morphed buffers)")

        // Frame 3: weights unchanged at zero. Fingerprint matches frame 2's,
        // so the gate fires. It must serve the (empty) frame-2 state, not the
        // stale frame-1 dict.
        let cb3 = try makeCommandBuffer(renderer)
        let frame3 = renderer.applyMorphTargetsCompute(commandBuffer: cb3)
        cb3.commit()
        await cb3.completed()
        XCTAssertTrue(
            frame3.isEmpty,
            "Gate hit on a zero-weight fingerprint must not resurrect the stale non-zero-weight dict"
        )
    }

    // MARK: - Preserve the optimization: identical nonzero weights still reuse

    /// GREEN guard: two consecutive frames with identical nonzero weights
    /// must hit the gate and reuse the exact same buffer objects (no
    /// re-dispatch), which is the PR's intended optimization.
    func testGateReusesPreviousOutputForUnchangedNonZeroWeights() async throws {
        let (model, _) = try await makeSyntheticMorphModel()

        let renderer = VRMRenderer(device: device)
        renderer.loadModel(model)
        guard let controller = renderer.expressionController else {
            XCTFail("Expression controller missing")
            return
        }

        controller.setExpressionWeight(.happy, weight: 0.8)
        let cb1 = try makeCommandBuffer(renderer)
        let frame1 = renderer.applyMorphTargetsCompute(commandBuffer: cb1)
        cb1.commit()
        await cb1.completed()
        XCTAssertFalse(frame1.isEmpty, "Nonzero weights should populate morphed buffers")

        // Same weight again, no change -> fingerprint matches -> gate should
        // reuse without re-dispatching.
        let cb2 = try makeCommandBuffer(renderer)
        let frame2 = renderer.applyMorphTargetsCompute(commandBuffer: cb2)
        cb2.commit()
        await cb2.completed()

        XCTAssertEqual(frame1.count, frame2.count, "Reused frame should carry the same set of primitives")
        for (key, buffer) in frame1 {
            guard let reused = frame2[key] else {
                XCTFail("Reused frame is missing key \(key) present in the original dispatch")
                continue
            }
            XCTAssertTrue(
                reused === buffer,
                "Gate hit must return the identical buffer object from the previous dispatch, not a new one"
            )
        }
    }
}
