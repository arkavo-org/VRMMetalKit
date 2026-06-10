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
import simd
@testable import VRMMetalKit

/// Carries the two result buffers into `concurrentPerform`'s `@Sendable`
/// closure. `@unchecked Sendable` is sound here: each concurrent iteration
/// writes only its own disjoint index, so there is no overlapping access.
private struct DisjointResultBuffers: @unchecked Sendable {
    let mins: UnsafeMutableBufferPointer<SIMD3<Float>>
    let maxs: UnsafeMutableBufferPointer<SIMD3<Float>>
}

/// Tests for `VRMModel.modelLocalBounds` thread safety + eager-compute (#153).
///
/// `VRMModel` is `@unchecked Sendable`, so its public read-only properties must
/// be safe to access concurrently from any thread. Previously
/// `modelLocalBounds` was a lazy read-modify-write of `_cachedLocalBounds`
/// without synchronization — racy by construction.
final class ModelLocalBoundsThreadSafetyTests: XCTestCase {

    private func makeMinimalGLTF() -> GLTFDocument {
        let json: [String: Any] = [
            "asset": ["version": "2.0", "generator": "Test"]
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(GLTFDocument.self, from: data)
    }

    /// Build a minimal model with a single mesh + primitive at known extents.
    private func makeFixtureModel(min: SIMD3<Float>, max: SIMD3<Float>) -> VRMModel {
        let model = VRMModel(
            specVersion: .v1_0,
            meta: VRMMeta(licenseUrl: ""),
            humanoid: nil,
            gltf: makeMinimalGLTF()
        )
        let primitive = VRMPrimitive()
        primitive.vertexCount = 8
        primitive.localMin = min
        primitive.localMax = max
        let mesh = VRMMesh(name: "fixture")
        mesh.primitives = [primitive]
        model.meshes = [mesh]
        return model
    }

    /// 1,000 concurrent reads of `modelLocalBounds` must all observe the same
    /// value. Under the previous racy implementation, multiple threads could
    /// each enter the lazy-compute path and race on the optional write.
    func testConcurrentReadsAreConsistent() {
        let lo = SIMD3<Float>(-1, -2, -3)
        let hi = SIMD3<Float>( 4,  5,  6)
        let model = makeFixtureModel(min: lo, max: hi)

        let iterations = 1000
        let mins = UnsafeMutableBufferPointer<SIMD3<Float>>.allocate(capacity: iterations)
        let maxs = UnsafeMutableBufferPointer<SIMD3<Float>>.allocate(capacity: iterations)
        defer { mins.deallocate(); maxs.deallocate() }

        // `concurrentPerform`'s closure is `@Sendable`, but the result buffers
        // are `UnsafeMutableBufferPointer` (non-Sendable). Each iteration `i`
        // writes only its own disjoint slot `[i]`, so the sharing is data-race
        // free; the box makes that promise explicit to the compiler.
        let out = DisjointResultBuffers(mins: mins, maxs: maxs)
        DispatchQueue.concurrentPerform(iterations: iterations) { i in
            let b = model.modelLocalBounds
            out.mins[i] = b.min
            out.maxs[i] = b.max
        }

        for i in 0..<iterations {
            XCTAssertEqual(mins[i], lo, "concurrent read #\(i) saw inconsistent min")
            XCTAssertEqual(maxs[i], hi, "concurrent read #\(i) saw inconsistent max")
        }
    }

    /// After `finalizeModelLocalBounds()`, the bounds are precomputed and a
    /// subsequent read does not enter the compute path. Validates the
    /// "compute eagerly at end of load" design from the issue. Verified
    /// behaviorally by mutating `meshes` *after* finalize and confirming the
    /// returned bounds reflect the pre-finalize state.
    func testFinalizePrecomputesBounds() {
        let lo = SIMD3<Float>(-1, -1, -1)
        let hi = SIMD3<Float>( 1,  1,  1)
        let model = makeFixtureModel(min: lo, max: hi)

        model.finalizeModelLocalBounds()

        // After finalize, mutating meshes should NOT change the returned
        // bounds — they are frozen at finalize time.
        let mutatedPrimitive = VRMPrimitive()
        mutatedPrimitive.vertexCount = 8
        mutatedPrimitive.localMin = SIMD3<Float>(-100, -100, -100)
        mutatedPrimitive.localMax = SIMD3<Float>( 100,  100,  100)
        let mutatedMesh = VRMMesh(name: "mutated")
        mutatedMesh.primitives = [mutatedPrimitive]
        model.meshes.append(mutatedMesh)

        let b = model.modelLocalBounds
        XCTAssertEqual(b.min, lo, "finalize must freeze bounds; post-mutation read should ignore later meshes")
        XCTAssertEqual(b.max, hi, "finalize must freeze bounds; post-mutation read should ignore later meshes")
    }

    /// Repeated reads return the same tuple (no recompute, no jitter).
    func testRepeatedReadsReturnIdenticalBounds() {
        let lo = SIMD3<Float>(0, 0, 0)
        let hi = SIMD3<Float>(2, 3, 4)
        let model = makeFixtureModel(min: lo, max: hi)

        let first = model.modelLocalBounds
        for _ in 0..<10 {
            let next = model.modelLocalBounds
            XCTAssertEqual(next.min, first.min)
            XCTAssertEqual(next.max, first.max)
        }
    }
}
