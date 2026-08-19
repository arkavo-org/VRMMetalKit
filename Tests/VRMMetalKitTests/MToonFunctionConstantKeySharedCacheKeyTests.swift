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
@testable import VRMMetalKit

/// Pure-CPU coverage for ``MToonFunctionConstantKey/sharedCacheKey(isSkinned:colorPixelFormat:sampleCount:)``,
/// the string identity `VRMPipelineCache` uses to serve compiled MToon
/// pipelines. `VRMPipelineCache.getPipelineState` is documented first-wins:
/// the first pipeline compiled under a key is returned forever for every
/// later request with that key, regardless of the descriptor passed in
/// (`VRMPipelineCache.swift:144`). Two `MToonFunctionConstantKey` values that
/// compile *different* pipelines but produce the *same* string therefore
/// silently serve the wrong pipeline — permanently, process-wide — which is
/// exactly the bug class these tests guard against for `lightCount` and
/// `debugVisualization`.
///
/// No `MTLDevice` is required: `MTLPixelFormat` is a plain enum, and the key
/// computation touches nothing GPU-backed.
final class MToonFunctionConstantKeySharedCacheKeyTests: XCTestCase {

    private func baseKey(lightCount: UInt8 = 3, debugVisualization: Bool = false) -> MToonFunctionConstantKey {
        MToonFunctionConstantKey(
            hasBaseColorTexture: true,
            alphaMode: 0,
            lightCount: lightCount,
            debugVisualization: debugVisualization
        )
    }

    /// `lightCount` selects a different compiled fragment function constant
    /// (`makeFunctionConstantValues` index 13), so keys differing only in
    /// `lightCount` must produce different shared-cache strings.
    func testLightCountDiscriminatesSharedCacheKey() {
        let oneLight = baseKey(lightCount: 1).sharedCacheKey(
            isSkinned: false, colorPixelFormat: .bgra8Unorm, sampleCount: 1)
        let threeLights = baseKey(lightCount: 3).sharedCacheKey(
            isSkinned: false, colorPixelFormat: .bgra8Unorm, sampleCount: 1)

        XCTAssertNotEqual(
            oneLight, threeLights,
            "lightCount=1 and lightCount=3 compile different fragment specializations " +
            "(different `lightCount` function-constant value) and must not collide on one cache key."
        )
    }

    /// `debugVisualization` selects an entirely different compiled function
    /// (`mtoon_fragment_debug` vs. `mtoon_fragment_v2`), so keys differing
    /// only in this field must produce different shared-cache strings.
    func testDebugVisualizationDiscriminatesSharedCacheKey() {
        let production = baseKey(debugVisualization: false).sharedCacheKey(
            isSkinned: false, colorPixelFormat: .bgra8Unorm, sampleCount: 1)
        let debug = baseKey(debugVisualization: true).sharedCacheKey(
            isSkinned: false, colorPixelFormat: .bgra8Unorm, sampleCount: 1)

        XCTAssertNotEqual(
            production, debug,
            "debugVisualization selects mtoon_fragment_debug instead of mtoon_fragment_v2 " +
            "and must not collide on one cache key with the production variant."
        )
    }

    /// An out-of-contract `lightCount` (outside the documented 1...3 range)
    /// must key identically to its clamp target, matching what
    /// `makeFunctionConstantValues` actually compiles — not manufacture a
    /// spurious extra cache entry for a variant Metal never builds.
    func testOutOfRangeLightCountKeysAsItsClampedValue() {
        let clampedToThree = baseKey(lightCount: 3).sharedCacheKey(
            isSkinned: false, colorPixelFormat: .bgra8Unorm, sampleCount: 1)
        let aboveRange = baseKey(lightCount: 200).sharedCacheKey(
            isSkinned: false, colorPixelFormat: .bgra8Unorm, sampleCount: 1)

        XCTAssertEqual(
            clampedToThree, aboveRange,
            "lightCount=200 clamps to 3 in makeFunctionConstantValues, so it must key " +
            "identically to lightCount=3, not fork off a new cache entry."
        )
    }

    /// Every other stored field of `MToonFunctionConstantKey` (the audit for
    /// requirement 3) must still discriminate the key after folding in the
    /// two new fields — this is a regression guard on the field list itself.
    func testEveryStoredFieldDiscriminatesSharedCacheKey() {
        let base = MToonFunctionConstantKey()
        func key(_ k: MToonFunctionConstantKey) -> String {
            k.sharedCacheKey(isSkinned: false, colorPixelFormat: .bgra8Unorm, sampleCount: 1)
        }

        var variant = base
        variant.useMaterialFlags = true
        XCTAssertNotEqual(key(base), key(variant), "useMaterialFlags")

        variant = base
        variant.hasBaseColorTexture = true
        XCTAssertNotEqual(key(base), key(variant), "hasBaseColorTexture")

        variant = base
        variant.hasShadeMultiplyTexture = true
        XCTAssertNotEqual(key(base), key(variant), "hasShadeMultiplyTexture")

        variant = base
        variant.hasShadingShiftTexture = true
        XCTAssertNotEqual(key(base), key(variant), "hasShadingShiftTexture")

        variant = base
        variant.hasNormalTexture = true
        XCTAssertNotEqual(key(base), key(variant), "hasNormalTexture")

        variant = base
        variant.hasMatcapTexture = true
        XCTAssertNotEqual(key(base), key(variant), "hasMatcapTexture")

        variant = base
        variant.hasRimMultiplyTexture = true
        XCTAssertNotEqual(key(base), key(variant), "hasRimMultiplyTexture")

        variant = base
        variant.hasEmissiveTexture = true
        XCTAssertNotEqual(key(base), key(variant), "hasEmissiveTexture")

        variant = base
        variant.hasOcclusionTexture = true
        XCTAssertNotEqual(key(base), key(variant), "hasOcclusionTexture")

        variant = base
        variant.hasUvAnimationMaskTexture = true
        XCTAssertNotEqual(key(base), key(variant), "hasUvAnimationMaskTexture")

        variant = base
        variant.hasParametricRim = true
        XCTAssertNotEqual(key(base), key(variant), "hasParametricRim")

        variant = base
        variant.alphaMode = 2
        XCTAssertNotEqual(key(base), key(variant), "alphaMode")

        variant = base
        variant.lightCount = 1
        XCTAssertNotEqual(key(base), key(variant), "lightCount")

        variant = base
        variant.debugVisualization = true
        XCTAssertNotEqual(key(base), key(variant), "debugVisualization")

        let skinned = base.sharedCacheKey(isSkinned: true, colorPixelFormat: .bgra8Unorm, sampleCount: 1)
        XCTAssertNotEqual(key(base), skinned, "isSkinned")
    }
}
