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
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import VRMMetalKit

/// VMK#310 — glTF-core `occlusionTexture` was multiplied into the *final*
/// composed MToon color (direct toon term + indirect + rim + emissive),
/// so under a strong directional light the AO pattern crushed the
/// directly-lit toon lit-cap into a hard dark band. UniVRM, three-vrm and
/// godot all restrict occlusion to the **indirect / ambient (GI)** term:
/// on a directly-lit surface the AO map is nearly invisible.
///
/// These are behavioral tests (not hash-distinctness, which #293 already
/// covers). We render a flat MToon quad with a procedural quadrant AO map
/// under a strong front directional light + low ambient, and assert:
///
///  1. The directly-lit surface is NEARLY IDENTICAL with vs without the
///     occlusion texture — occlusion may only nibble at the small ambient
///     term, not the dominant direct toon term. (Pre-fix the whole color
///     is multiplied, so the TL quadrant (AO=0.1) loses ~90% brightness.)
///  2. Half-strength occlusion darkens the ambient term ~half as much as
///     full strength (glTF `1 + strength*(sample-1)` remap correctness).
final class MToonOcclusionDirectLightTests: XCTestCase {

    private let renderWidth = 256
    private let renderHeight = 256
    private let cameraPosition = SIMD3<Float>(0, 0, 1.4)
    private let cameraTarget   = SIMD3<Float>(0, 0, 0)
    private let cameraUp       = SIMD3<Float>(0, 1, 0)
    private let cameraFovYDeg: Float = 30

    // STRONG front directional key light, LOW ambient. Direct term should
    // dominate; occlusion (which is ambient-only per spec) must barely
    // move the directly-lit pixels.
    private let keyLightDir   = SIMD3<Float>(0, 0, -1)
    private let keyLightColor = SIMD3<Float>(1, 1, 1)
    private let keyLightIntensity: Float = 1.0
    // LOW ambient relative to the 1/π-normalized direct toon term so the
    // direct contribution clearly dominates the directly-lit region. With
    // baseColor 0.7 and key intensity 1.0 the direct term is ≈0.7/π≈0.22;
    // ambient*giAlbedo ≈ 0.03*0.7 ≈ 0.02 is a small fraction. Occlusion may
    // remove up to ~90% of that ambient sliver — well under the invariant
    // ceiling — but cannot touch the direct term.
    private let ambientColor: SIMD3<Float> = SIMD3<Float>(0.03, 0.03, 0.03)

    /// Sample point inside the TOP-LEFT quadrant — the heaviest AO
    /// (R = 0.1). The fixture quad spans the frame; TL in UV (0,0..0.5)
    /// maps to the upper-left screen region.
    private func sampleTopLeftLuma(_ pixels: [UInt8]) -> Double {
        averageLuma(pixels, xRange: 0.20..<0.30, yRange: 0.20..<0.30)
    }

    /// Directly-lit invariant: with vs without the occlusion texture, the
    /// directly-lit surface must stay nearly identical. Pre-fix the TL
    /// quadrant (AO=0.1) loses ~90% of its brightness — far beyond the
    /// small ambient contribution.
    func testDirectlyLitSurfaceNearlyIdenticalWithAndWithoutOcclusion() async throws {
        let baseline = try await renderLuma(strength: nil)      // no AO texture
        let occluded = try await renderLuma(strength: 1.0)      // heavy AO, full strength

        let lumaBase = sampleTopLeftLuma(baseline)
        let lumaOcc  = sampleTopLeftLuma(occluded)

        // The only legitimate change is attenuation of the ambient term.
        // ambient ≈ 0.08, direct toon ≈ ~0.7/π · light ≈ dominant. AO=0.1
        // at full strength removes ~90% of ambient (factor 0.1), i.e. it
        // can darken total luma by AT MOST ~0.9 * ambientContribution.
        // We require the directly-lit region to retain the vast majority
        // of its brightness — a generous 15% drop ceiling that the
        // ambient-only term comfortably satisfies but the pre-fix
        // whole-color multiply (≈90% drop) blows past.
        let relativeDrop = (lumaBase - lumaOcc) / max(lumaBase, 1e-6)
        XCTAssertLessThan(relativeDrop, 0.15,
            "VMK#310: occlusion must only attenuate the ambient/indirect " +
            "term, leaving the directly-lit toon surface ~unchanged. " +
            "Got a \(String(format: "%.1f", relativeDrop * 100))% luma drop " +
            "in the heavily-occluded directly-lit region " +
            "(baseline=\(String(format: "%.4f", lumaBase)), " +
            "occluded=\(String(format: "%.4f", lumaOcc))). A large drop " +
            "means occlusion is multiplying the final lit color (incl. the " +
            "direct toon term) instead of only the indirect/ambient GI term.")
    }

    /// Strength remap correctness: half-strength must darken the ambient
    /// term about half as much as full strength. With occlusion now
    /// restricted to the ambient term, this exercises
    /// `1 + strength*(sample-1)` on the indirect contribution.
    func testHalfStrengthDarkensAboutHalfOfFullStrength() async throws {
        let baseline = try await renderLuma(strength: nil)
        let full     = try await renderLuma(strength: 1.0)
        let half     = try await renderLuma(strength: 0.5)

        let lb = sampleTopLeftLuma(baseline)
        let lf = sampleTopLeftLuma(full)
        let lh = sampleTopLeftLuma(half)

        let dropFull = lb - lf   // luma removed at strength 1.0
        let dropHalf = lb - lh   // luma removed at strength 0.5

        XCTAssertGreaterThan(dropFull, 1e-4,
            "VMK#310: full-strength occlusion should remove SOME ambient " +
            "luma in the heavily-occluded region. Got dropFull=\(dropFull).")

        // glTF remap: factor = 1 + strength*(s-1). For sampled s=0.1:
        //   full (1.0): factor 0.1  → ambient * 0.1   (removes 0.9*ambient)
        //   half (0.5): factor 0.55 → ambient * 0.55  (removes 0.45*ambient)
        // So dropHalf should be ~half of dropFull. Allow a generous band.
        let ratio = dropHalf / max(dropFull, 1e-6)
        XCTAssertEqual(ratio, 0.5, accuracy: 0.18,
            "VMK#310: half-strength occlusion should darken the ambient " +
            "term ~half as much as full strength (glTF " +
            "`1 + strength*(sample-1)` remap). Got ratio=" +
            "\(String(format: "%.3f", ratio)) " +
            "(dropFull=\(String(format: "%.5f", dropFull)), " +
            "dropHalf=\(String(format: "%.5f", dropHalf))).")
    }

    // MARK: - Render harness (pixels)

    private func renderLuma(strength: Float?) async throws -> [UInt8] {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available (CI without GPU)")
        }
        guard let queue = device.makeCommandQueue() else {
            XCTFail("Could not create command queue"); return []
        }
        let glb = try MToonOcclusionFixture.buildVRMGLB(strength: strength)
        let model = try await VRMModel.load(from: glb, device: device)

        let cameraPos = cameraPosition
        let cameraTgt = cameraTarget
        let cameraUpV = cameraUp
        let fovYDeg = cameraFovYDeg
        let lightDir = keyLightDir
        let lightCol = keyLightColor
        let lightInt = keyLightIntensity
        let ambient = ambientColor
        let w = renderWidth
        let h = renderHeight

        return await MainActor.run {
            Self.renderModelToPixels(
                model: model, device: device, commandQueue: queue,
                cameraPosition: cameraPos, cameraTarget: cameraTgt, cameraUp: cameraUpV,
                cameraFovYDeg: fovYDeg,
                keyLightDir: lightDir, keyLightColor: lightCol, keyLightIntensity: lightInt,
                ambientColor: ambient,
                renderWidth: w, renderHeight: h
            )
        }
    }

    @MainActor
    private static func renderModelToPixels(
        model: VRMModel,
        device: MTLDevice,
        commandQueue: MTLCommandQueue,
        cameraPosition: SIMD3<Float>,
        cameraTarget: SIMD3<Float>,
        cameraUp: SIMD3<Float>,
        cameraFovYDeg: Float,
        keyLightDir: SIMD3<Float>,
        keyLightColor: SIMD3<Float>,
        keyLightIntensity: Float,
        ambientColor: SIMD3<Float>,
        renderWidth: Int,
        renderHeight: Int
    ) -> [UInt8] {
        var config = RendererConfig()
        config.sampleCount = 1
        config.strict = .off
        config.synchronousSpringBone = true
        let renderer = VRMRenderer(device: device, config: config)
        renderer.loadModel(model)

        let aspect = Float(renderWidth) / Float(renderHeight)
        let fovY = cameraFovYDeg * .pi / 180
        renderer.projectionMatrix = MToonOcclusionFixture.perspectiveProjection(
            fovY: fovY, aspect: aspect, near: 0.05, far: 100
        )
        renderer.viewMatrix = MToonOcclusionFixture.lookAt(
            eye: cameraPosition, target: cameraTarget, up: cameraUp
        )
        renderer.setLight(0, direction: keyLightDir, color: keyLightColor,
                          intensity: keyLightIntensity)
        renderer.setAmbientColor(ambientColor)

        let colorTexture = MToonOcclusionFixture.makeTexture(
            device: device, width: renderWidth, height: renderHeight,
            format: .bgra8Unorm, usage: [.renderTarget, .shaderRead], storage: .shared
        )
        let depthTexture = MToonOcclusionFixture.makeTexture(
            device: device, width: renderWidth, height: renderHeight,
            format: .depth32Float, usage: [.renderTarget], storage: .private
        )
        guard let cb = commandQueue.makeCommandBuffer() else {
            XCTFail("makeCommandBuffer failed"); return []
        }
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = colorTexture
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].storeAction = .store
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        rpd.depthAttachment.texture = depthTexture
        rpd.depthAttachment.loadAction = .clear
        rpd.depthAttachment.storeAction = .dontCare
        rpd.depthAttachment.clearDepth = 1.0
        renderer.drawOffscreenHeadless(to: colorTexture, depth: depthTexture,
                                        commandBuffer: cb, renderPassDescriptor: rpd)
        let sem = DispatchSemaphore(value: 0)
        cb.addCompletedHandler { _ in sem.signal() }
        cb.commit()
        sem.wait()

        let bytesPerRow = renderWidth * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * renderHeight)
        pixels.withUnsafeMutableBufferPointer { ptr in
            colorTexture.getBytes(ptr.baseAddress!, bytesPerRow: bytesPerRow,
                                  from: MTLRegionMake2D(0, 0, renderWidth, renderHeight),
                                  mipmapLevel: 0)
        }
        return pixels
    }

    /// Average luma over a fractional screen region. BGRA8 layout.
    private func averageLuma(_ pixels: [UInt8],
                             xRange: Range<Double>, yRange: Range<Double>) -> Double {
        let w = renderWidth, h = renderHeight
        let x0 = Int(xRange.lowerBound * Double(w)), x1 = Int(xRange.upperBound * Double(w))
        let y0 = Int(yRange.lowerBound * Double(h)), y1 = Int(yRange.upperBound * Double(h))
        var sum = 0.0
        var n = 0
        for y in y0..<y1 {
            for x in x0..<x1 {
                let i = (y * w + x) * 4
                let b = Double(pixels[i+0])
                let g = Double(pixels[i+1])
                let r = Double(pixels[i+2])
                sum += 0.2126 * r + 0.7152 * g + 0.0722 * b
                n += 1
            }
        }
        return n > 0 ? sum / Double(n) / 255.0 : 0
    }
}
