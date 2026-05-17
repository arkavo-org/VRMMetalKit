//
// Copyright 2025 Arkavo
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//

import XCTest
import Metal
import simd
@testable import GLTFMetalKit

/// Issue #247: per-frame `MTLBuffer` allocation in the morph rebuild path
/// was a heap-fragmentation hazard at face-blendshape scale. The pool
/// replaces that with a 3-deep ring keyed by primitive ID. Properties to
/// pin down:
///   1. First call for a new primitive allocates exactly 3 buffers.
///   2. Subsequent calls with the same weights return the cached slot
///      without rotating the ring or re-blending.
///   3. Calls with changed weights rotate to the next slot and write new
///      data; the slot rotation is bounded by `framesInFlight`.
///   4. Two primitives with independent weight histories don't share rings.
final class GLTFMorphBufferPoolTests: XCTestCase {

    func testFirstCallAllocatesRingAndReturnsBuffer() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available (CI without GPU)")
        }

        let pool = GLTFMorphBufferPool(device: device)
        let morph = makeMorphData(vertexCount: 4, targetCount: 2)
        XCTAssertEqual(pool.trackedPrimitiveCount, 0)

        let buffer = pool.buffer(
            primitiveID: 1,
            morph: morph,
            weights: [1.0, 0.0],
            joints: nil,
            skinWeights: nil,
            skinned: false
        )
        XCTAssertNotNil(buffer)
        XCTAssertEqual(pool.trackedPrimitiveCount, 1)
        XCTAssertEqual(pool.bufferCount(forPrimitiveID: 1), GLTFMorphBufferPool.framesInFlight)
    }

    func testUnchangedWeightsReturnSameBuffer() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available (CI without GPU)")
        }

        let pool = GLTFMorphBufferPool(device: device)
        let morph = makeMorphData(vertexCount: 4, targetCount: 2)
        let w: [Float] = [0.5, 0.5]

        guard let first = pool.buffer(primitiveID: 1, morph: morph, weights: w, joints: nil, skinWeights: nil, skinned: false) else {
            XCTFail("first call failed"); return
        }
        guard let second = pool.buffer(primitiveID: 1, morph: morph, weights: w, joints: nil, skinWeights: nil, skinned: false) else {
            XCTFail("second call failed"); return
        }
        XCTAssertTrue(first === second,
            "Unchanged weights must return the cached buffer; got fresh buffer (re-blend on every frame is the bug this PR fixes).")
    }

    func testChangedWeightsRotateThroughRing() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available (CI without GPU)")
        }

        let pool = GLTFMorphBufferPool(device: device)
        let morph = makeMorphData(vertexCount: 4, targetCount: 2)

        let weightSequence: [[Float]] = [
            [1.0, 0.0],
            [0.0, 1.0],
            [0.5, 0.5],
            [0.25, 0.75]
        ]
        var seen: [ObjectIdentifier] = []
        for w in weightSequence {
            guard let b = pool.buffer(primitiveID: 1, morph: morph, weights: w, joints: nil, skinWeights: nil, skinned: false) else {
                XCTFail("blend call failed for weights \(w)"); return
            }
            seen.append(ObjectIdentifier(b))
        }
        // After 4 distinct-weight calls in a 3-deep ring, the 4th call must
        // reuse a buffer that was seen earlier (slots cycle).
        let unique = Set(seen)
        XCTAssertLessThanOrEqual(unique.count, GLTFMorphBufferPool.framesInFlight,
            "Distinct-weight calls produced \(unique.count) buffers — must stay bounded by framesInFlight (\(GLTFMorphBufferPool.framesInFlight)).")
        XCTAssertGreaterThan(unique.count, 1,
            "Distinct-weight calls all returned the same buffer; ring is not rotating.")
    }

    func testTwoPrimitivesAllocateIndependentRings() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available (CI without GPU)")
        }

        let pool = GLTFMorphBufferPool(device: device)
        let morph = makeMorphData(vertexCount: 4, targetCount: 2)

        _ = pool.buffer(primitiveID: 1, morph: morph, weights: [1, 0], joints: nil, skinWeights: nil, skinned: false)
        _ = pool.buffer(primitiveID: 2, morph: morph, weights: [0, 1], joints: nil, skinWeights: nil, skinned: false)
        XCTAssertEqual(pool.trackedPrimitiveCount, 2)
        XCTAssertEqual(pool.bufferCount(forPrimitiveID: 1), GLTFMorphBufferPool.framesInFlight)
        XCTAssertEqual(pool.bufferCount(forPrimitiveID: 2), GLTFMorphBufferPool.framesInFlight)
    }

    func testPruneDropsInactivePrimitives() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available (CI without GPU)")
        }

        let pool = GLTFMorphBufferPool(device: device)
        let morph = makeMorphData(vertexCount: 4, targetCount: 2)
        for id in 1...4 {
            _ = pool.buffer(primitiveID: id, morph: morph, weights: [1, 0], joints: nil, skinWeights: nil, skinned: false)
        }
        XCTAssertEqual(pool.trackedPrimitiveCount, 4)

        // Keep only IDs 2 and 4; the other two should be dropped.
        pool.prune(activeIDs: [2, 4])
        XCTAssertEqual(pool.trackedPrimitiveCount, 2)
        XCTAssertEqual(pool.bufferCount(forPrimitiveID: 1), 0)
        XCTAssertEqual(pool.bufferCount(forPrimitiveID: 2), GLTFMorphBufferPool.framesInFlight)
        XCTAssertEqual(pool.bufferCount(forPrimitiveID: 3), 0)
        XCTAssertEqual(pool.bufferCount(forPrimitiveID: 4), GLTFMorphBufferPool.framesInFlight)
    }

    func testClearDropsAllPrimitives() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available (CI without GPU)")
        }

        let pool = GLTFMorphBufferPool(device: device)
        let morph = makeMorphData(vertexCount: 4, targetCount: 2)
        _ = pool.buffer(primitiveID: 1, morph: morph, weights: [1, 0], joints: nil, skinWeights: nil, skinned: false)
        _ = pool.buffer(primitiveID: 2, morph: morph, weights: [0, 1], joints: nil, skinWeights: nil, skinned: false)
        XCTAssertEqual(pool.trackedPrimitiveCount, 2)

        pool.clear()
        XCTAssertEqual(pool.trackedPrimitiveCount, 0)
        XCTAssertEqual(pool.bufferCount(forPrimitiveID: 1), 0)
        XCTAssertEqual(pool.bufferCount(forPrimitiveID: 2), 0)

        // Re-use after clear: pool still functional.
        _ = pool.buffer(primitiveID: 1, morph: morph, weights: [0.5, 0.5], joints: nil, skinWeights: nil, skinned: false)
        XCTAssertEqual(pool.trackedPrimitiveCount, 1)
    }

    // MARK: - Helpers

    /// Build a minimal `GLTFPrimitiveMorphData` with `vertexCount` vertices
    /// and `targetCount` morph targets. Position deltas are stamped so
    /// blended output can be visually verified if needed.
    private func makeMorphData(vertexCount: Int, targetCount: Int) -> GLTFPrimitiveMorphData {
        let basePositions = (0..<vertexCount).map { i in SIMD3<Float>(Float(i), 0, 0) }
        let baseNormals = Array(repeating: SIMD3<Float>(0, 0, 1), count: vertexCount)
        let baseTangents = Array(repeating: SIMD4<Float>(1, 0, 0, 1), count: vertexCount)
        let baseUVs = Array(repeating: SIMD2<Float>(0, 0), count: vertexCount)
        let positionDeltas = (0..<targetCount).map { t in
            (0..<vertexCount).map { _ in SIMD3<Float>(0, Float(t + 1), 0) }
        }
        // Per the morphData invariant, the outer array of normalDeltas and
        // tangentDeltas must be parallel to positionDeltas — inner arrays
        // can be empty when the target doesn't author normals/tangents.
        let emptyDeltas = Array(repeating: [SIMD3<Float>](), count: targetCount)
        return GLTFPrimitiveMorphData(
            basePositions: basePositions,
            baseNormals: baseNormals,
            baseTangents: baseTangents,
            baseUVs: baseUVs,
            positionDeltas: positionDeltas,
            normalDeltas: emptyDeltas,
            tangentDeltas: emptyDeltas
        )
    }
}
