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
@testable import GLTFMetalKit

/// Phase 3b morph-target acceptance: load Khronos `AnimatedMorphCube.glb`,
/// sample its weights animation at two different times, confirm the
/// rebuild emits a *different* vertex buffer (deformed cube, not the
/// rest-pose cube). Catches the full morph stack — primitive.targets
/// parsing, base/delta extraction, per-frame CPU blend, vertex-buffer
/// upload, draw-call emission.
final class GLTFMorphTests: XCTestCase {

    func testMorphedVerticesBlendsCorrectly() {
        // Hand-built morph data: one vertex, one morph target whose
        // position delta is (1, 0, 0). At weight 0.5 the morphed
        // position should be (0.5, 0, 0).
        let morph = GLTFPrimitiveMorphData(
            basePositions: [SIMD3<Float>(0, 0, 0)],
            baseNormals:   [SIMD3<Float>(0, 1, 0)],
            baseTangents:  [SIMD4<Float>(1, 0, 0, 1)],
            baseUVs:       [SIMD2<Float>(0, 0)],
            positionDeltas: [[SIMD3<Float>(1, 0, 0)]],
            normalDeltas:   [[]],   // no normal delta
            tangentDeltas:  [[]]
        )

        let zero = morph.morphedVertices(weights: [0])
        XCTAssertEqual(zero[0].position.x, 0, accuracy: 1e-5)

        let half = morph.morphedVertices(weights: [0.5])
        XCTAssertEqual(half[0].position.x, 0.5, accuracy: 1e-5)

        let full = morph.morphedVertices(weights: [1.0])
        XCTAssertEqual(full[0].position.x, 1.0, accuracy: 1e-5)
    }

    func testLoadsAnimatedMorphCubeWithTargets() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available (CI without GPU)")
        }
        guard let url = Bundle.module.url(forResource: "AnimatedMorphCube", withExtension: "glb", subdirectory: "TestData") else {
            throw XCTSkip("AnimatedMorphCube.glb not bundled")
        }

        let loader = GLTFAssetLoader()
        let asset = try await loader.load(from: url, device: device)

        XCTAssertGreaterThan(asset.animations.count, 0, "AnimatedMorphCube should have a weights animation.")
        let clip = asset.animations[0]
        XCTAssertTrue(clip.channels.contains { $0.property == .weights },
            "AnimatedMorphCube's clip should include a `weights` channel.")
    }

    /// The credibility check: morph weights animate the cube's vertices.
    /// drawCalls(at: 0) and drawCalls(at: duration/2) should reference
    /// different vertex buffers because the morph blend produces a
    /// different vertex layout. We compare the underlying MTLBuffer
    /// references — non-identical buffers prove the morph rebuild fired.
    func testMorphAnimationProducesDifferentVertexBuffers() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available (CI without GPU)")
        }
        guard let url = Bundle.module.url(forResource: "AnimatedMorphCube", withExtension: "glb", subdirectory: "TestData") else {
            throw XCTSkip("AnimatedMorphCube.glb not bundled")
        }

        let loader = GLTFAssetLoader()
        let asset = try await loader.load(from: url, device: device)
        guard !asset.animations.isEmpty else {
            XCTFail("AnimatedMorphCube.glb has no animations"); return
        }
        let duration = asset.animations[0].duration

        let drawsAtRest = asset.drawCalls(animationIndex: 0, time: 0)
        let drawsAtMid  = asset.drawCalls(animationIndex: 0, time: duration * 0.5)

        XCTAssertEqual(drawsAtRest.count, drawsAtMid.count,
            "Morph rebuild changed draw-call count — scene-traversal regression.")
        XCTAssertGreaterThan(drawsAtRest.count, 0)

        // The buffers must differ at *some* time during the animation. Any
        // primitive whose underlying vertex MTLBuffer is the *same* object
        // at t=0 and t=duration/2 has not gone through the morph rebuild.
        // (Tolerant comparison: a few primitives without morph targets are
        // legitimately the same buffer; we just need at least one to differ.)
        var atLeastOneRebuild = false
        for (rest, mid) in zip(drawsAtRest, drawsAtMid) {
            if rest.mesh.vertexBuffer !== mid.mesh.vertexBuffer {
                atLeastOneRebuild = true
                break
            }
        }
        XCTAssertTrue(atLeastOneRebuild,
            "No draw call's vertex buffer changed between t=0 and t=duration/2 — morph rebuild didn't fire.")
    }
}
