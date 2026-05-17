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
import CryptoKit
@testable import VRMMetalKit

/// vrm-conformance VMK#236: 24 collider sweep variants rendered
/// byte-identically to the no-collider baseline in the conformance harness.
/// The issue was filed as "warmupPhysics doesn't apply collisions during
/// settle"; this test pinned the actual root cause to a different layer
/// entirely — the collider offset parser was returning `(0, 0, 0)` for
/// every collider, so warmup *was* applying collisions but against
/// colliders sitting at their owning node's origin instead of the
/// authored offset. Same bug class as VMK#238/#239: `AnyCodable` stores
/// whole-number JSON literals as `Int`, so `[0.02, -0.10, 0.0] as? [Double]`
/// fails on the mixed array and `parseVector3` returns nil. Fixed in
/// `VRMExtensionParser.parseVector3(_:)` by adding a per-element
/// coercion fallback through `parseFloatValue(_:)`.
///
/// This test loads the no-collider baseline plus four sphere/capsule
/// variants, runs warmup-only (no swing animation), and asserts every
/// variant renders distinct from the baseline. Without the fix all five
/// fixtures hash identically.
final class SpringBoneSettleColliderTests: XCTestCase {

    private let warmupSteps: Int = 60   // matches conformance `physics.settle_steps`
    private let cameraPosition = SIMD3<Float>(0, 1.4, 1.5)
    private let cameraTarget   = SIMD3<Float>(0, 1.4, 0)
    private let cameraUp       = SIMD3<Float>(0, 1, 0)
    private let cameraFovYDeg: Float = 30
    private let keyLightDir   = SIMD3<Float>(-0.3, -0.6, -0.7)
    private let keyLightColor = SIMD3<Float>(1, 1, 1)
    private let keyLightIntensity: Float = 1.0
    private let ambientColor: SIMD3<Float> = SIMD3<Float>(0.5, 0.5, 0.5) * 0.3
    private let renderWidth = 256
    private let renderHeight = 256

    /// Each collider variant must produce a distinct render from the
    /// no-collider baseline — the chain deflects around the collider
    /// during warmup. Pre-fix, all five fixtures shared one SHA (collider
    /// offset zeroed, so it sat under the chain root and bone[1]
    /// happened to either not penetrate or got pushed into a position
    /// the renderer couldn't visually distinguish). Post-fix, the four
    /// colliders are placed at their authored offsets and the chain
    /// deflects visibly per variant.
    func testColliderSettleDeflectsChainPerVariant() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available (CI without GPU)")
        }
        guard let queue = device.makeCommandQueue() else {
            XCTFail("Could not create command queue"); return
        }

        // smoke_spring = no colliders. Other fixtures each have one sphere
        // or capsule collider positioned 0.02 m off the chain axis with
        // radius 0.05–0.10 m, fully intersecting the chain's natural rest
        // path. Any of them should deflect the chain visibly under correct
        // settle physics.
        let baselineFixture = "smoke_spring"
        let colliderFixtures = [
            "springbone_collider_sphere_x0p02_r0p05",
            "springbone_collider_sphere_x0p02_r0p1",
            "springbone_collider_capsule_x0p02_r0p05",
            "springbone_collider_capsule_x0p02_r0p1"
        ]

        let cameraPos = cameraPosition
        let cameraTgt = cameraTarget
        let cameraUpV = cameraUp
        let fovYDeg = cameraFovYDeg
        let lightDir = keyLightDir
        let lightCol = keyLightColor
        let lightInt = keyLightIntensity
        let ambient = ambientColor
        let warmup = warmupSteps
        let w = renderWidth
        let h = renderHeight

        func renderHash(_ fixture: String) async throws -> String {
            let url = try bundleURL(for: fixture)
            let model = try await VRMModel.load(from: url, device: device)
            return await MainActor.run {
                Self.renderSettledHash(
                    model: model, device: device, commandQueue: queue,
                    warmupSteps: warmup,
                    cameraPosition: cameraPos, cameraTarget: cameraTgt, cameraUp: cameraUpV,
                    cameraFovYDeg: fovYDeg,
                    keyLightDir: lightDir, keyLightColor: lightCol, keyLightIntensity: lightInt,
                    ambientColor: ambient,
                    renderWidth: w, renderHeight: h
                )
            }
        }

        let baselineHash = try await renderHash(baselineFixture)
        var colliderHashes: [String: String] = [:]
        for fixture in colliderFixtures {
            colliderHashes[fixture] = try await renderHash(fixture)
        }

        // Every collider variant must produce a render distinct from the
        // no-collider baseline. Any match means a regression in the
        // parseVector3 / collider-offset path (likely a fresh instance of
        // the AnyCodable Int-vs-Double bug).
        let matchingBaseline = colliderHashes.filter { $0.value == baselineHash }
        XCTAssertEqual(matchingBaseline.count, 0,
            "Collider variant(s) collapsed to the no-collider baseline. " +
            "Baseline: \(baselineHash.prefix(8)). " +
            "Variant hashes: \(colliderHashes.map { "\($0.key) → \($0.value.prefix(8))" }.joined(separator: ", ")). " +
            "Likely regression in VRMExtensionParser.parseVector3 — see VMK#236.")
        // Sphere-vs-capsule pairs of the same radius can render identically
        // (capsule with zero-length tail = sphere; at larger radii the
        // chain settles to the same equilibrium past either shape). The
        // strong assertion is the "differs from baseline" check above —
        // here we just want a sanity floor that at least *some* spread
        // exists across the four variants.
        let variantHashes = Set(colliderHashes.values)
        XCTAssertGreaterThanOrEqual(variantHashes.count, 2,
            "All four collider variants collapsed to a single hash. " +
            "Per-fixture: \(colliderHashes.map { "\($0.key) → \($0.value.prefix(8))" }.joined(separator: ", ")). " +
            "Either the parser fix regressed or the collision math now homogenises all variants.")
    }

    // MARK: - Render harness

    private func bundleURL(for fixture: String) throws -> URL {
        guard let url = Bundle.module.url(
            forResource: fixture,
            withExtension: "vrm",
            subdirectory: "TestData/Conformance"
        ) else {
            throw XCTSkip("\(fixture).vrm not bundled in Conformance/")
        }
        return url
    }

    @MainActor
    private static func renderSettledHash(
        model: VRMModel,
        device: MTLDevice,
        commandQueue: MTLCommandQueue,
        warmupSteps: Int,
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
    ) -> String {
        var config = RendererConfig()
        config.sampleCount = 1
        config.strict = .off
        let renderer = VRMRenderer(device: device, config: config)
        renderer.loadModel(model)
        renderer.enableSpringBone = true
        // Deterministic — irrelevant here since we skip the per-frame
        // sim loop, but keep it set so any post-warmup snapshot tick
        // behaves like the swing test.
        renderer.simulationDeltaTime = 1.0 / 60.0

        let aspect = Float(renderWidth) / Float(renderHeight)
        let fovY = cameraFovYDeg * .pi / 180
        renderer.projectionMatrix = perspectiveProjection(
            fovY: fovY, aspect: aspect, near: 0.05, far: 100
        )
        renderer.viewMatrix = lookAt(
            eye: cameraPosition, target: cameraTarget, up: cameraUp
        )
        renderer.setLight(0, direction: keyLightDir, color: keyLightColor,
                          intensity: keyLightIntensity)
        renderer.setAmbientColor(ambientColor)

        renderer.warmupPhysics(steps: warmupSteps)

        let colorTexture = makeTexture(
            device: device, width: renderWidth, height: renderHeight,
            format: .bgra8Unorm, usage: [.renderTarget, .shaderRead], storage: .shared
        )
        let depthTexture = makeTexture(
            device: device, width: renderWidth, height: renderHeight,
            format: .depth32Float, usage: [.renderTarget], storage: .private
        )
        guard let cb = commandQueue.makeCommandBuffer() else {
            XCTFail("makeCommandBuffer failed for settle render")
            return ""
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
        let digest = SHA256.hash(data: Data(pixels))
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    private static func perspectiveProjection(fovY: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let y = 1 / tan(fovY * 0.5)
        let x = y / aspect
        let z = far / (near - far)
        return simd_float4x4(
            SIMD4<Float>(x, 0, 0, 0),
            SIMD4<Float>(0, y, 0, 0),
            SIMD4<Float>(0, 0, z, -1),
            SIMD4<Float>(0, 0, z * near, 0)
        )
    }

    private static func lookAt(eye: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
        let z = normalize(eye - target)
        let x = normalize(cross(up, z))
        let y = cross(z, x)
        return simd_float4x4(
            SIMD4<Float>(x.x, y.x, z.x, 0),
            SIMD4<Float>(x.y, y.y, z.y, 0),
            SIMD4<Float>(x.z, y.z, z.z, 0),
            SIMD4<Float>(-dot(x, eye), -dot(y, eye), -dot(z, eye), 1)
        )
    }

    private static func makeTexture(
        device: MTLDevice, width: Int, height: Int,
        format: MTLPixelFormat, usage: MTLTextureUsage, storage: MTLStorageMode
    ) -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: width, height: height, mipmapped: false
        )
        desc.usage = usage
        desc.storageMode = storage
        return device.makeTexture(descriptor: desc)!
    }
}
