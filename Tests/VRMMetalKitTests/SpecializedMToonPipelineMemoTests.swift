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
@testable import VRMMetalKit

/// Covers the per-renderer memo in ``VRMRenderer/specializedMToonPipelineState(isSkinned:features:)``.
///
/// The shared ``VRMPipelineCache`` can only be queried with a fully built
/// `MTLRenderPipelineDescriptor`, and building one calls
/// `MTLLibrary.makeFunction(name:constantValues:)` — where Metal hashes the
/// function-constant payload and validates its on-disk function cache. Because
/// the draw loop resolves a specialized PSO per draw per frame, that cost was
/// paid on every cache *hit* and the descriptor immediately discarded. Sampling
/// a release build put ~75% of `drawCore`'s CPU time in that one call.
///
/// The memo answers before a descriptor exists. Its key must therefore carry
/// every input that changes what Metal compiles — dropping one reintroduces the
/// wrong-pipeline-returned bug class that ``VRMPipelineCacheKeyTests`` covers
/// for the shared cache, just one layer higher up.
@MainActor
final class SpecializedMToonPipelineMemoTests: XCTestCase {

    private var device: MTLDevice!

    override func setUp() async throws {
        guard let dev = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        device = dev
    }

    private func features(alphaMode: UInt8 = 0, baseColor: Bool = true) -> MToonFunctionConstantKey {
        MToonFunctionConstantKey(
            hasBaseColorTexture: baseColor,
            alphaMode: alphaMode
        )
    }

    /// Repeated resolution of the same variant must hit the memo: one entry,
    /// and the identical `MTLRenderPipelineState` instance every time. A second
    /// entry (or a second instance) means the descriptor was rebuilt.
    func testRepeatedResolutionReusesOneMemoEntry() throws {
        let renderer = VRMRenderer(device: device, config: RendererConfig())
        let key = features()

        guard let first = renderer.specializedMToonPipelineState(isSkinned: false, features: key) else {
            throw XCTSkip("MToon specialization unavailable on this device")
        }
        XCTAssertEqual(renderer.specializedMToonPipelines.count, 1)

        for _ in 0..<16 {
            let again = renderer.specializedMToonPipelineState(isSkinned: false, features: key)
            XCTAssertTrue(
                again === first,
                "Same feature key must return the identical PSO instance from the memo."
            )
        }
        XCTAssertEqual(
            renderer.specializedMToonPipelines.count, 1,
            "Resolving the same variant 17 times must not grow the memo past one entry."
        )
    }

    /// Variants that compile to different shaders must not collapse onto one
    /// memo entry — that would bind the wrong specialization for the material.
    func testDistinctFeatureKeysGetDistinctEntries() throws {
        let renderer = VRMRenderer(device: device, config: RendererConfig())

        guard let opaque = renderer.specializedMToonPipelineState(
            isSkinned: false, features: features(alphaMode: 0)
        ) else {
            throw XCTSkip("MToon specialization unavailable on this device")
        }
        let blend = renderer.specializedMToonPipelineState(isSkinned: false, features: features(alphaMode: 2))
        let skinned = renderer.specializedMToonPipelineState(isSkinned: true, features: features(alphaMode: 0))
        let noBaseColor = renderer.specializedMToonPipelineState(
            isSkinned: false, features: features(alphaMode: 0, baseColor: false)
        )

        XCTAssertEqual(
            renderer.specializedMToonPipelines.count, 4,
            "alphaMode, isSkinned and each function constant must discriminate memo entries."
        )
        XCTAssertFalse(opaque === blend, "OPAQUE and BLEND compile different pipelines.")
        XCTAssertFalse(opaque === skinned, "Skinned and non-skinned use different vertex functions.")
        XCTAssertFalse(opaque === noBaseColor, "Function constants change the compiled fragment shader.")
    }

    /// The memo key must include the render-target configuration. Two renderers
    /// differing only in `colorPixelFormat` or `sampleCount` compile different
    /// pipelines, so neither may serve the other's PSO — this is the memo-layer
    /// analogue of the vrm-conformance #213 cache-key omission.
    func testRenderTargetConfigDiscriminatesMemoEntries() throws {
        var linear = RendererConfig()
        linear.colorPixelFormat = .bgra8Unorm
        linear.sampleCount = 1

        var srgb = RendererConfig()
        srgb.colorPixelFormat = .rgba8Unorm_srgb
        srgb.sampleCount = 1

        var msaa = RendererConfig()
        msaa.colorPixelFormat = .bgra8Unorm
        msaa.sampleCount = 4

        let key = features()
        let rendererA = VRMRenderer(device: device, config: linear)
        guard rendererA.specializedMToonPipelineState(isSkinned: false, features: key) != nil else {
            throw XCTSkip("MToon specialization unavailable on this device")
        }

        // Same renderer, mutated config: the memo must not answer with the
        // pipeline compiled for the previous render-target layout.
        rendererA.config = srgb
        _ = rendererA.specializedMToonPipelineState(isSkinned: false, features: key)
        XCTAssertEqual(
            rendererA.specializedMToonPipelines.count, 2,
            "Changing colorPixelFormat must miss the memo, not reuse the bgra8Unorm pipeline."
        )

        rendererA.config = msaa
        _ = rendererA.specializedMToonPipelineState(isSkinned: false, features: key)
        XCTAssertEqual(
            rendererA.specializedMToonPipelines.count, 3,
            "Changing sampleCount must miss the memo — rasterSampleCount affects compilation."
        )
    }

    /// A variant recorded as un-specializable must be answered from the memo,
    /// not retried. Without the negative entry the draw loop would rebuild the
    /// descriptor — the expensive `makeFunction(name:constantValues:)` call —
    /// once per draw per frame for every material that fails to specialize,
    /// which is strictly worse than the hit path this change optimizes.
    ///
    /// Metal accepts every constant payload this API can produce, so the
    /// failure is seeded directly rather than provoked; what needs asserting is
    /// that `nil` is a cached answer and not a cache miss.
    func testNegativeMemoEntryShortCircuitsRebuild() throws {
        let renderer = VRMRenderer(device: device, config: RendererConfig())
        let key = features()
        let memoKey = VRMRenderer.SpecializedMToonPipelineKey(
            features: key,
            isSkinned: false,
            colorPixelFormat: renderer.config.colorPixelFormat,
            sampleCount: renderer.config.sampleCount
        )
        renderer.specializedMToonPipelines[memoKey] = MTLRenderPipelineState?.none

        XCTAssertNil(
            renderer.specializedMToonPipelineState(isSkinned: false, features: key),
            "A negative memo entry must be returned as nil, not treated as a miss."
        )
        XCTAssertEqual(
            renderer.specializedMToonPipelines.count, 1,
            "Resolving a negatively-cached variant must not rebuild or add an entry."
        )
    }
}
