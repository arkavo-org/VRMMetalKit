// Copyright 2025 Arkavo Inc. and contributors
// Licensed under the Apache License, Version 2.0

import XCTest
import Metal
import simd
@testable import VRMMetalKit

/// Depth-mapping tests for `VRMRenderer.makeProjectionMatrix` (issue #408).
///
/// The existing projection tests pin matrix *coefficients* — `columns.2.z`,
/// `columns.0.x` — which is why they pass against a matrix that clips every
/// fragment. These tests instead push eye-space points through the matrix and
/// assert where they land in NDC, which is the property the renderer actually
/// depends on.
///
/// Both branches must agree on the sign of eye-space z. The perspective branch
/// sets `w_clip = -z_eye`, so the camera looks down **-Z** (right-handed) and
/// eye-space depths are negative. The orthographic branch has to read that same
/// convention and produce Metal's standard [0, 1] clip range, near -> 0 and
/// far -> 1. (Reverse-Z is a separate opt-in — `VRMRenderer.useReverseZ`, #403 —
/// which flips the depth-compare functions, not this matrix.)
final class ProjectionDepthMappingTests: XCTestCase {

    var device: (any MTLDevice)!
    var renderer: VRMRenderer!

    /// The near/far planes `makeProjectionMatrix` hardcodes.
    private let nearZ: Float = 0.1
    private let farZ: Float = 100.0

    override func setUp() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        self.device = device
        self.renderer = VRMRenderer(device: device)
    }

    /// Projects an eye-space point and returns its NDC z (perspective divide).
    private func ndcZ(_ matrix: matrix_float4x4, eyeZ: Float) -> Float {
        let clip = matrix * SIMD4<Float>(0, 0, eyeZ, 1)
        return clip.z / clip.w
    }

    // MARK: - Perspective (the reference convention)

    /// Control. Establishes what the orthographic branch has to match: negative
    /// eye-space z in, [0, 1] NDC out.
    func testPerspectiveMapsNearToZeroAndFarToOne() {
        renderer.useOrthographic = false
        let matrix = renderer.makeProjectionMatrix(aspectRatio: 1.0)

        XCTAssertEqual(ndcZ(matrix, eyeZ: -nearZ), 0.0, accuracy: 1e-4,
                       "perspective: the near plane must land at NDC z = 0")
        XCTAssertEqual(ndcZ(matrix, eyeZ: -farZ), 1.0, accuracy: 1e-4,
                       "perspective: the far plane must land at NDC z = 1")
    }

    // MARK: - Orthographic (#408)

    func testOrthographicMapsNearToZeroAndFarToOne() {
        renderer.useOrthographic = true
        let matrix = renderer.makeProjectionMatrix(aspectRatio: 1.0)

        XCTAssertEqual(ndcZ(matrix, eyeZ: -nearZ), 0.0, accuracy: 1e-4,
                       "orthographic: the near plane must land at NDC z = 0, matching the "
                       + "perspective branch's eye-space convention (camera looks down -Z)")
        XCTAssertEqual(ndcZ(matrix, eyeZ: -farZ), 1.0, accuracy: 1e-4,
                       "orthographic: the far plane must land at NDC z = 1")
    }

    /// The failure this issue is really about: with the near/far mapping wrong,
    /// depths between the planes fall outside [0, 1] and every fragment is
    /// clipped, so an orthographic render draws nothing.
    func testOrthographicKeepsDepthsBetweenThePlanesInsideClipRange() {
        renderer.useOrthographic = true
        let matrix = renderer.makeProjectionMatrix(aspectRatio: 1.0)

        for eyeDepth: Float in [0.1, 0.5, 1.0, 5.0, 25.0, 99.0, 100.0] {
            let z = ndcZ(matrix, eyeZ: -eyeDepth)
            XCTAssertGreaterThanOrEqual(z, 0.0, "eye depth \(eyeDepth) clipped below the near plane (NDC z \(z))")
            XCTAssertLessThanOrEqual(z, 1.0, "eye depth \(eyeDepth) clipped beyond the far plane (NDC z \(z))")
        }
    }

    /// Orthographic depth is linear in eye-space z — that is what distinguishes
    /// it from the perspective branch, and it pins the mapping's shape rather
    /// than just its endpoints.
    func testOrthographicDepthIsLinearInEyeSpaceZ() {
        renderer.useOrthographic = true
        let matrix = renderer.makeProjectionMatrix(aspectRatio: 1.0)

        let midpoint = (nearZ + farZ) / 2.0
        XCTAssertEqual(ndcZ(matrix, eyeZ: -midpoint), 0.5, accuracy: 1e-3,
                       "orthographic depth must be linear: the midpoint between the planes "
                       + "belongs at NDC z = 0.5")
    }

    /// Both branches must place a given eye-space depth on the same side of the
    /// clip range. Without this, geometry that is nearer in one mode reads as
    /// farther in the other, and depth-sorted draws invert on mode switch.
    func testBothBranchesAgreeOnDepthOrdering() {
        renderer.useOrthographic = false
        let perspective = renderer.makeProjectionMatrix(aspectRatio: 1.0)
        renderer.useOrthographic = true
        let orthographic = renderer.makeProjectionMatrix(aspectRatio: 1.0)

        let nearer = ndcZ(perspective, eyeZ: -1.0)
        let farther = ndcZ(perspective, eyeZ: -50.0)
        XCTAssertLessThan(nearer, farther, "perspective: nearer geometry must have smaller NDC z")

        let orthoNearer = ndcZ(orthographic, eyeZ: -1.0)
        let orthoFarther = ndcZ(orthographic, eyeZ: -50.0)
        XCTAssertLessThan(orthoNearer, orthoFarther,
                          "orthographic: nearer geometry must have smaller NDC z, same as perspective — "
                          + "otherwise the depth test rejects the wrong fragments on mode switch")
    }

    /// `orthoSize` and aspect ratio scale x/y only; the depth mapping is
    /// independent of both.
    func testOrthographicDepthMappingIsIndependentOfSizeAndAspect() {
        renderer.useOrthographic = true
        for size: Float in [0.5, 2.0, 10.0] {
            for aspect: Float in [0.5, 1.0, 2.35] {
                renderer.orthoSize = size
                let matrix = renderer.makeProjectionMatrix(aspectRatio: aspect)
                XCTAssertEqual(ndcZ(matrix, eyeZ: -nearZ), 0.0, accuracy: 1e-4,
                               "orthoSize \(size), aspect \(aspect): near plane must still map to 0")
                XCTAssertEqual(ndcZ(matrix, eyeZ: -farZ), 1.0, accuracy: 1e-4,
                               "orthoSize \(size), aspect \(aspect): far plane must still map to 1")
            }
        }
    }

    // MARK: - End-to-end: does an orthographic render actually draw? (#408)

    /// The matrix assertions above pin the mapping; this pins the consequence.
    /// With the broken offset every fragment fell outside [0, 1] and an
    /// orthographic render produced an empty frame, which no coefficient test
    /// can detect. Renders a real avatar through `makeProjectionMatrix`'s
    /// orthographic branch and requires the frame to be non-empty — and to be
    /// broadly the same silhouette the perspective branch produces from the
    /// same camera.
    @MainActor
    func testOrthographicRenderProducesAnImage() async throws {
        let path = getTestModelPath("AvatarSample_A_1.0.vrm.glb")
        try requireFixture(path, hint: "AvatarSample_A_1.0.vrm.glb")

        func render(orthographic: Bool) async throws -> [UInt8] {
            let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device)
            var config = RendererConfig()
            config.sampleCount = 1
            config.strict = .off
            let r = VRMRenderer(device: device, config: config)
            r.loadModel(model)
            r.useOrthographic = orthographic
            r.orthoSize = 2.0
            r.fovDegrees = 60.0
            // The camera the renderer's own matrix expects: looking down -Z,
            // avatar centred at chest height, well inside [near, far].
            r.projectionMatrix = r.makeProjectionMatrix(aspectRatio: 1.0)
            r.viewMatrix = matrix_float4x4(columns: (
                SIMD4<Float>(1, 0, 0, 0),
                SIMD4<Float>(0, 1, 0, 0),
                SIMD4<Float>(0, 0, 1, 0),
                SIMD4<Float>(0, -1.0, -2.0, 1)
            ))
            r.setLight(0, direction: SIMD3<Float>(0.3, 0.6, 0.7), color: SIMD3<Float>(1, 1, 1), intensity: 1.0)
            r.disableLight(1)
            r.disableLight(2)
            r.setAmbientColor(SIMD3<Float>(0.5, 0.5, 0.5) * 0.3)
            return try renderOffscreen(renderer: r, size: 128)
        }

        let ortho = try await render(orthographic: true)
        let persp = try await render(orthographic: false)

        let orthoDrawn = countNonClearPixels(ortho)
        let perspDrawn = countNonClearPixels(persp)
        let total = 128 * 128
        print("[#408] non-clear pixels — orthographic \(orthoDrawn)/\(total), perspective \(perspDrawn)/\(total)")

        XCTAssertGreaterThan(perspDrawn, 0,
            "perspective control drew nothing — the camera/scene scaffolding is wrong, "
            + "so the orthographic result below would be meaningless")
        XCTAssertGreaterThan(orthoDrawn, 0,
            "orthographic render produced an empty frame: every fragment was clipped, "
            + "which is the #408 failure this fix is meant to remove")
        // Same avatar, same camera, both branches in range: the covered area
        // should be the same order of magnitude, not a stray pixel or two.
        XCTAssertGreaterThan(orthoDrawn, perspDrawn / 10,
            "orthographic drew \(orthoDrawn) px against perspective's \(perspDrawn) px — "
            + "too sparse to be the avatar; the depth range is probably still wrong")
    }

    private func countNonClearPixels(_ bytes: [UInt8]) -> Int {
        var count = 0
        for i in stride(from: 0, to: bytes.count, by: 4) {
            // Clear colour is (0.05, 0.06, 0.11) in BGRA8; allow rounding slack.
            let b = Int(bytes[i]), g = Int(bytes[i + 1]), r = Int(bytes[i + 2])
            if abs(b - 28) > 2 || abs(g - 15) > 2 || abs(r - 13) > 2 { count += 1 }
        }
        return count
    }

    @MainActor
    private func renderOffscreen(renderer: VRMRenderer, size: Int) throws -> [UInt8] {
        let colorDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: size, height: size, mipmapped: false)
        colorDesc.usage = [.renderTarget, .shaderRead]
        colorDesc.storageMode = .shared
        let depthDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float, width: size, height: size, mipmapped: false)
        depthDesc.usage = .renderTarget
        depthDesc.storageMode = .private

        guard let colorTex = device.makeTexture(descriptor: colorDesc),
              let depthTex = device.makeTexture(descriptor: depthDesc),
              let queue = device.makeCommandQueue(),
              let cb = queue.makeCommandBuffer() else {
            throw XCTSkip("Could not allocate Metal render targets")
        }

        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = colorTex
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0.05, green: 0.06, blue: 0.11, alpha: 1)
        rpd.colorAttachments[0].storeAction = .store
        rpd.depthAttachment.texture = depthTex
        rpd.depthAttachment.loadAction = .clear
        rpd.depthAttachment.clearDepth = 1.0
        rpd.depthAttachment.storeAction = .dontCare

        renderer.drawOffscreenHeadless(to: colorTex, depth: depthTex,
                                       commandBuffer: cb, renderPassDescriptor: rpd)
        cb.commit()
        cb.waitUntilCompleted()

        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        bytes.withUnsafeMutableBytes { buf in
            colorTex.getBytes(buf.baseAddress!, bytesPerRow: size * 4,
                              from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
        }
        return bytes
    }
}
