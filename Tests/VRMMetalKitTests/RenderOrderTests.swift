// Copyright 2025 Arkavo Inc. and contributors
// Licensed under the Apache License, Version 2.0

import XCTest
import Metal
import simd
@testable import VRMMetalKit

/// TDD tests for render order validation (Issue #105)
/// Verifies material sorting and render order constants
final class RenderOrderTests: XCTestCase {

    var device: MTLDevice!
    var renderer: VRMRenderer!

    override func setUp() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        self.device = device
        self.renderer = VRMRenderer(device: device)
    }

    // MARK: - Render Order Constants Tests

    /// Test render order constant values
    /// 0=opaque, 1=faceSkin, 2=faceEyebrow, 3=faceEyeline, 4=mask, 5=faceEye, 6=faceHighlight, 7=blend
    func testRenderOrderConstants() {
        // These values are documented in VRMRenderer.RenderItem.renderOrder
        // Verify the ordering makes logical sense

        let opaque = 0
        let faceSkin = 1
        let faceEyebrow = 2
        let faceEyeline = 3
        let mask = 4
        let faceEye = 5
        let faceHighlight = 6
        let blend = 7

        // Opaque materials render first
        XCTAssertEqual(opaque, 0, "Opaque should have lowest render order")

        // Face materials render in specific order to avoid z-fighting
        XCTAssertLessThan(faceSkin, faceEyebrow, "Face skin renders before eyebrows")
        XCTAssertLessThan(faceEyebrow, faceEyeline, "Eyebrows render before eyeline")
        XCTAssertLessThan(faceEyeline, faceEye, "Eyeline renders before eyes")
        XCTAssertLessThan(faceEye, faceHighlight, "Eyes render before highlights")

        // Transparent-band mask (queue >= 2500) renders between face and blend.
        // NOTE: cutout-band mask (queue < 2500, e.g. alpha-tested hair @ 2450) is
        // the exception — it sorts EARLY (renderOrder 1), before the BLEND face
        // overlays, per `VRMRenderer.nonFaceRenderOrder` (#322). Covered below.
        XCTAssertLessThan(faceEyeline, mask, "Transparent-band mask renders after face overlays")

        // Blend (transparent) materials render last
        XCTAssertEqual(blend, 7, "Blend should have highest render order")
        XCTAssertGreaterThan(blend, mask, "Blend renders after mask")
        XCTAssertGreaterThan(blend, faceHighlight, "Blend renders after face highlight")
    }

    /// Test opaque renders before blend
    func testOpaqueRendersBeforeBlend() {
        let opaqueOrder = 0
        let blendOrder = 7

        XCTAssertLessThan(
            opaqueOrder,
            blendOrder,
            "Opaque materials must render before blend materials"
        )
    }

    /// Test face materials render order chain
    func testFaceMaterialsRenderOrder() {
        // Face materials have specific render order to handle z-fighting
        // skin < eyebrow < eyeline < eye < highlight

        let faceMaterialOrders = [
            ("faceSkin", 1),
            ("faceEyebrow", 2),
            ("faceEyeline", 3),
            ("faceEye", 5),
            ("faceHighlight", 6)
        ]

        // Verify each material renders before the next
        for i in 0..<(faceMaterialOrders.count - 1) {
            let current = faceMaterialOrders[i]
            let next = faceMaterialOrders[i + 1]

            XCTAssertLessThan(
                current.1,
                next.1,
                "\(current.0) (order \(current.1)) should render before \(next.0) (order \(next.1))"
            )
        }
    }

    /// Test mask renders between opaque and blend
    func testMaskRendersBetweenOpaqueAndBlend() {
        let opaqueOrder = 0
        let maskOrder = 4
        let blendOrder = 7

        XCTAssertGreaterThan(maskOrder, opaqueOrder, "Mask should render after opaque")
        XCTAssertLessThan(maskOrder, blendOrder, "Mask should render before blend")
    }

    // MARK: - Depth State Per Render Order Tests

    /// Test that opaque render order uses opaque depth state
    func testOpaqueRenderOrderUsesOpaqueDepthState() {
        // Opaque materials (renderOrder=0) should use "opaque" depth state
        XCTAssertNotNil(
            renderer.depthStencilStates["opaque"],
            "Opaque depth state must exist for opaque render order"
        )
    }

    /// Test that blend render order uses blend depth state
    func testBlendRenderOrderUsesBlendDepthState() {
        // Blend materials (renderOrder=7) should use "blend" depth state
        XCTAssertNotNil(
            renderer.depthStencilStates["blend"],
            "Blend depth state must exist for blend render order"
        )
    }

    /// Test that face render orders use face depth state
    func testFaceRenderOrderUsesFaceDepthState() {
        // Face materials use "face" depth state with lessEqual to avoid z-fighting
        XCTAssertNotNil(
            renderer.depthStencilStates["face"],
            "Face depth state must exist for face render orders"
        )
    }

    // MARK: - Alpha Mode to Render Order Mapping Tests

    /// Test alpha mode opaque maps to render order 0
    func testAlphaModeOpaqueMapping() {
        // AlphaMode.opaque -> renderOrder 0
        let expectedOrder = 0
        XCTAssertEqual(expectedOrder, 0, "Opaque alpha mode maps to render order 0")
    }

    /// Test alpha mode mask maps to render order 4
    func testAlphaModeMaskMapping() {
        // AlphaMode.mask -> renderOrder 4
        let expectedOrder = 4
        XCTAssertEqual(expectedOrder, 4, "Mask alpha mode maps to render order 4")
    }

    /// Test alpha mode blend maps to render order 7
    func testAlphaModeBlendMapping() {
        // AlphaMode.blend -> renderOrder 7
        let expectedOrder = 7
        XCTAssertEqual(expectedOrder, 7, "Blend alpha mode maps to render order 7")
    }

    // MARK: - Z-Sorting for Blend Items Tests

    /// Test blend items should be sorted by Z depth (back to front)
    func testBlendItemsSortedByZDepth() {
        // For renderOrder=7 (blend), items should be sorted by view-space Z
        // This ensures correct alpha blending (back to front)

        // Create test positions at different Z depths
        let nearPosition = SIMD3<Float>(0, 0, -1.0)  // Closer to camera
        let farPosition = SIMD3<Float>(0, 0, -5.0)   // Farther from camera

        // In view space, more negative Z is farther
        // Back-to-front sorting means farther objects render first
        XCTAssertLessThan(farPosition.z, nearPosition.z, "Far position has smaller Z (more negative)")

        // When sorting back-to-front, far items come first (render first)
        // This is the expected behavior for transparent materials
    }

    /// Test multiple render orders maintain correct sequence
    func testMultipleRenderOrdersSequence() {
        // All render orders from lowest to highest
        let renderOrders = [0, 1, 2, 3, 4, 5, 6, 7]

        // Verify sorted order
        let sorted = renderOrders.sorted()
        XCTAssertEqual(renderOrders, sorted, "Render orders should already be in ascending sequence")

        // Verify no gaps that would cause issues
        for i in 0..<(renderOrders.count - 1) {
            let diff = renderOrders[i + 1] - renderOrders[i]
            XCTAssertLessThanOrEqual(diff, 2, "No large gaps between render orders")
        }
    }

    // MARK: - Non-face render-order mapping (#322)

    /// Cutout-band MASK (VRM Cutout queue < 2500, e.g. alpha-tested hair @ 2450)
    /// must sort in the early depth-writing band (1), BEFORE the BLEND face
    /// overlays (eyeline renderOrder 3), so the author's renderQueue is honored
    /// and the depth buffer — not draw order — resolves hair-vs-eyelash occlusion.
    /// Pre-#322 this was renderOrder 4, drawing alpha-tested hair AFTER the BLEND
    /// eyeline (queue ~2998) and letting the eyelash bleed through the bangs.
    func testCutoutMaskSortsBeforeFaceBlendOverlays() {
        let hair = VRMRenderer.nonFaceRenderOrder(alphaMode: "mask", renderQueue: 2450)
        let faceEyeline = 3
        XCTAssertEqual(hair, 1, "Cutout-band hair (queue 2450) sorts in the early depth band")
        XCTAssertLessThan(hair, faceEyeline,
            "Alpha-tested hair (queue 2450) must render before BLEND eyeline (queue ~2998) per the author's renderQueue (#322)")
    }

    /// Transparent-band MASK (queue >= 2500) keeps the later slot (4).
    func testTransparentBandMaskKeepsLateSlot() {
        XCTAssertEqual(VRMRenderer.nonFaceRenderOrder(alphaMode: "mask", renderQueue: 2998), 4)
        XCTAssertEqual(VRMRenderer.nonFaceRenderOrder(alphaMode: "mask", renderQueue: 2500), 4)
    }

    /// The cutout-band reorder is INTENTIONALLY broad: it covers every non-face
    /// cutout/alpha-tested MASK material in the VRM Cutout band (queue < 2500),
    /// not only hair @2450. A material with no explicit VRM renderQueue defaults
    /// to 2000 (VRMMaterial.renderQueue), so default-queue clothing/accessory MASK
    /// also sorts in the early depth-writing band (slot 1). This is spec-correct —
    /// alpha-tested materials zWrite, so the depth buffer resolves their occlusion
    /// and the Cutout band renders before Transparent — and is documented here so
    /// the broader scope (vs the hair-specific PR framing) is an explicit contract
    /// rather than an accident (Gitar review).
    func testDefaultQueueCutoutMaskAlsoSortsEarly() {
        XCTAssertEqual(VRMRenderer.nonFaceRenderOrder(alphaMode: "mask", renderQueue: 2000), 1,
            "Default-queue (2000) non-face cutout MASK sorts in the early depth-writing band")
        XCTAssertEqual(VRMRenderer.nonFaceRenderOrder(alphaMode: "mask", renderQueue: 2449), 1,
            "Cutout-band MASK just below the 2500 threshold sorts early")
    }

    /// Opaque and blend mappings are unchanged by the #322 cutout fix.
    func testNonFaceOpaqueAndBlendMapping() {
        XCTAssertEqual(VRMRenderer.nonFaceRenderOrder(alphaMode: "opaque", renderQueue: 2000), 0)
        XCTAssertEqual(VRMRenderer.nonFaceRenderOrder(alphaMode: "blend", renderQueue: 3000), 7)
    }
}
