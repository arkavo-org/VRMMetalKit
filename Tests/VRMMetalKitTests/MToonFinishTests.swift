// Copyright 2025 Arkavo Inc. and contributors
// Licensed under the Apache License, Version 2.0

import XCTest
import Metal
import simd
@testable import VRMMetalKit

/// Opt-in surface extensions on the MToon path: the glTF metallic/roughness
/// finish, the hair band and crease AO. The swatch fixtures carry matte
/// (0.0/0.9), leather (0.22/0.36) and metal (0.95/0.22) MToon materials.
@MainActor
final class MToonFinishTests: XCTestCase {
    private var device: MTLDevice!

    override func setUp() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        self.device = device
    }

    private func finishSetup(_ configure: (inout SwatchScene.Setup) -> Void = { _ in }) -> SwatchScene.Setup {
        var setup = SwatchScene.Setup()
        configure(&setup)
        return setup
    }

    private static let allMaterialsHair = HairHighlightConfig(
        isEnabled: true, strength: 1.2, sharpness: 16, materialNameContains: nil)

    /// Compiles the extensions in without enabling any of them on the swatch
    /// materials: the exact reference for "this material is untouched".
    private static let extensionsCompiledIn = HairHighlightConfig(
        isEnabled: true, materialNameContains: "no-such-material")

    /// Specialized pipelines compile an extension only into the materials
    /// that use it, so an untouched material must match a renderer with every
    /// extension off byte for byte.
    private func assertUntouched(_ frame: [UInt8], _ plain: [UInt8], columns: Range<Int>, _ label: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        let drift = SwatchScene.stats(frame, reference: plain, size: 512, columns: columns, threshold: 0)
        XCTAssertEqual(drift.changedPixels, 0,
                       "\(label) changed on \(drift.changedPixels) pixels (max delta \(drift.maxDelta)) with an extension enabled elsewhere",
                       file: file, line: line)
    }

    // MARK: - Thresholds and config (no GPU)

    func testSpecularModeClassificationMatchesShaderThresholds() {
        let epsilon = MToonSpecularMode.metallicEpsilon
        let metal = MToonSpecularMode.metalThreshold
        XCTAssertEqual(epsilon, 0.0001, "Must match mtoonFinishActive in MToonShader.metal")
        XCTAssertEqual(metal, 0.7, "Must match the midpoint of mtoonFinishMetalMask's smoothstep(0.6, 0.8)")

        XCTAssertEqual(MToonSpecularMode(metallicFactor: 0, roughnessFactor: 1), .off)
        XCTAssertEqual(MToonSpecularMode(metallicFactor: epsilon, roughnessFactor: 1), .off)
        XCTAssertEqual(MToonSpecularMode(metallicFactor: epsilon.nextUp, roughnessFactor: 1), .sheen)
        XCTAssertEqual(MToonSpecularMode(metallicFactor: 0.22, roughnessFactor: 0.36), .sheen)
        XCTAssertEqual(MToonSpecularMode(metallicFactor: metal.nextDown, roughnessFactor: 0.5), .sheen)
        XCTAssertEqual(MToonSpecularMode(metallicFactor: metal, roughnessFactor: 0.5), .metal)
        XCTAssertEqual(MToonSpecularMode(metallicFactor: 0.95, roughnessFactor: 0.22), .metal)
    }

    func testHairConfigMatchingAndClamping() {
        let hair = HairHighlightConfig(isEnabled: true, materialNameContains: "hair")
        XCTAssertTrue(hair.applies(toMaterialNamed: "Hair_01"))
        XCTAssertTrue(hair.applies(toMaterialNamed: "LongHairBack"))
        XCTAssertFalse(hair.applies(toMaterialNamed: "Skin"))
        XCTAssertFalse(HairHighlightConfig.disabled.applies(toMaterialNamed: "Hair"))
        XCTAssertTrue(HairHighlightConfig(isEnabled: true, materialNameContains: nil).applies(toMaterialNamed: "Skin"))

        var tuned = HairHighlightConfig(isEnabled: true)
        tuned.strength = 5
        tuned.sharpness = 0
        XCTAssertEqual(tuned.resolvedStrength, 2)
        XCTAssertEqual(tuned.resolvedSharpness, 1)
        tuned.strength = .nan
        tuned.sharpness = .infinity
        XCTAssertEqual(tuned.resolvedStrength, 0)
        XCTAssertEqual(tuned.resolvedSharpness, 8)
    }

    // MARK: - Opt-in

    /// Authored metallic must not change the default output: VRoid/UniVRM
    /// exports write metallicFactor = 1.0 on every MToon material.
    func testAuthoredMetallicIsIgnoredUnlessTheFinishIsEnabled() async throws {
        let authored = try await SwatchScene.load(.rigid, device: device)
        let zeroed = try await SwatchScene.load(.rigid, device: device)
        for material in zeroed.materials {
            material.metallicFactor = 0
            material.roughnessFactor = 1
        }
        XCTAssertEqual(try SwatchScene.render(authored, device: device),
                       try SwatchScene.render(zeroed, device: device),
                       "Default renderer must ignore authored metallic/roughness")

        // Compile the extensions in through another feature: metallic must
        // still be ignored while enableMaterialFinish is off.
        let otherExtension = finishSetup {
            $0.config.hairHighlight = HairHighlightConfig(isEnabled: true, materialNameContains: "no-such-material")
        }
        XCTAssertEqual(try SwatchScene.render(authored, device: device, setup: otherExtension),
                       try SwatchScene.render(zeroed, device: device, setup: otherExtension),
                       "Compiling the extensions in must not enable the finish")
    }

    /// Without function constants one fallback pipeline serves every
    /// material, so enabling an extension compiles it in for all of them; the
    /// changed instruction schedule may move untouched materials by at most
    /// one 8-bit step on one channel.
    func testFallbackPipelineDriftOnUntouchedMaterialsIsAtMostOneStep() async throws {
        let model = try await SwatchScene.load(.rigid, device: device)
        let plain = try SwatchScene.render(model, device: device, setup: finishSetup {
            $0.config.enableMToonFunctionConstants = false
        })
        let finished = try SwatchScene.render(model, device: device, setup: finishSetup {
            $0.config.enableMToonFunctionConstants = false
            $0.config.enableMaterialFinish = true
        })
        let matte = SwatchScene.stats(finished, reference: plain, size: 512, columns: SwatchScene.third(0, size: 512), threshold: 0)
        XCTAssertLessThanOrEqual(matte.maxDelta, 1, "Matte drifted by \(matte.maxDelta) on the fallback pipeline")
    }

    // MARK: - Three-swatch acceptance

    func testThreeFinishSwatches() async throws {
        let model = try await SwatchScene.load(.rigid, device: device)
        let plain = try SwatchScene.render(model, device: device)
        let reference = try SwatchScene.render(model, device: device, setup: finishSetup {
            $0.config.hairHighlight = Self.extensionsCompiledIn
        })
        let finished = try SwatchScene.render(model, device: device, setup: finishSetup { $0.config.enableMaterialFinish = true })
        let size = 512

        let matte = SwatchScene.stats(finished, reference: reference, size: size, columns: SwatchScene.third(0, size: size), threshold: 0)
        XCTAssertEqual(matte.changedPixels, 0, "Matte (metallic 0) must not change (max delta \(matte.maxDelta))")
        assertUntouched(finished, plain, columns: SwatchScene.third(0, size: size), "Matte")

        let leather = SwatchScene.stats(finished, reference: reference, size: size, columns: SwatchScene.third(1, size: size))
        XCTAssertGreaterThan(leather.changedPixels, 500, "Leather (0.22/0.36) should produce a broad visible sheen")
        XCTAssertGreaterThan(leather.maxDelta, 20)

        let metal = SwatchScene.stats(finished, reference: reference, size: size, columns: SwatchScene.third(2, size: size))
        XCTAssertGreaterThan(metal.changedPixels, 20, "Metal (0.95/0.22) should produce a visible highlight")
        XCTAssertLessThan(metal.changedPixels, leather.changedPixels / 3,
            "Metal highlight should be tight relative to the leather sheen")
        XCTAssertGreaterThan(metal.maxLuma, 0.85, "Metal highlight should reach a bright peak")
    }

    /// Lower roughness must narrow both lobes, across the whole range.
    func testLowerRoughnessNarrowsBothLobes() async throws {
        func highlightPixels(material index: Int, roughness: Float) async throws -> Int {
            let model = try await SwatchScene.load(.rigid, device: device)
            model.materials[index].roughnessFactor = roughness
            let off = try SwatchScene.render(model, device: device)
            let on = try SwatchScene.render(model, device: device, setup: finishSetup { $0.config.enableMaterialFinish = true })
            return SwatchScene.stats(on, reference: off, size: 512, columns: SwatchScene.third(index, size: 512)).changedPixels
        }
        let glossyLeather = try await highlightPixels(material: 1, roughness: 0.2)
        let roughLeather = try await highlightPixels(material: 1, roughness: 0.8)
        XCTAssertLessThan(glossyLeather, roughLeather, "Sheen: lower roughness must give a tighter lobe")

        let glossyMetal = try await highlightPixels(material: 2, roughness: 0.1)
        let midMetal = try await highlightPixels(material: 2, roughness: 0.4)
        let roughMetal = try await highlightPixels(material: 2, roughness: 1.0)
        XCTAssertLessThan(glossyMetal, midMetal, "Metal: lower roughness must give a tighter band")
        XCTAssertLessThan(midMetal, roughMetal, "Metal: roughness above 0.35 must still widen the band")
    }

    /// The shipped metallibs run MToon in half precision. A half-precision
    /// normal quantizes N·H near 1 more coarsely than a glossy metal band, so
    /// the band edge breaks into a jagged dither; the finish must shade from a
    /// float normal. Measured as the mean |Laplacian| of the added light along
    /// the band edge, relative to the band's height (float ≈ 0.3, half ≈ 1.4).
    func testGlossyMetalHighlightEdgeIsSmooth() async throws {
        let model = try await SwatchScene.load(.rigid, device: device)
        model.materials[2].roughnessFactor = 0
        let size = 1024
        let closeUp = finishSetup {
            $0.size = size
            $0.eye = SIMD3<Float>(1.3, 0, 1.4)
            $0.center = SIMD3<Float>(1.3, 0, 0)
        }
        var finished = closeUp
        finished.config.enableMaterialFinish = true
        let off = try SwatchScene.render(model, device: device, setup: closeUp)
        let on = try SwatchScene.render(model, device: device, setup: finished)

        var added = [Double](repeating: 0, count: size * size)
        for p in 0..<(size * size) {
            added[p] = SwatchScene.luma(on, p * 4) - SwatchScene.luma(off, p * 4)
        }
        let peak = added.max() ?? 0
        XCTAssertGreaterThan(peak, 0.1, "Test setup: the glossy metal band should be visible")

        var roughness = 0.0
        var edgePixels = 0
        for y in 1..<(size - 1) {
            for x in 1..<(size - 1) {
                let value = added[y * size + x]
                guard value > 0.1 * peak, value < 0.9 * peak else { continue }
                let laplacian = 4 * value - added[y * size + x - 1] - added[y * size + x + 1]
                    - added[(y - 1) * size + x] - added[(y + 1) * size + x]
                roughness += abs(laplacian)
                edgePixels += 1
            }
        }
        XCTAssertGreaterThan(edgePixels, 100, "Test setup: the band should have an edge")
        let relative = roughness / Double(max(edgePixels, 1)) / peak
        XCTAssertLessThan(relative, 0.7, "Glossy metal band edge is jagged (relative |Laplacian| \(relative))")
    }

    // MARK: - View vector on every vertex path

    /// The skinned and rigid fixtures describe identical geometry, so every
    /// extension must shade them identically from any camera. A skinned path
    /// that fed the dummy (0,0,1) view vector would pin highlights to +Z.
    func testSkinnedAndRigidPathsShadeExtensionsIdentically() async throws {
        let rigid = try await SwatchScene.load(.rigid, device: device)
        let skinned = try await SwatchScene.load(.skinned, device: device)
        let setup = finishSetup {
            $0.config.enableMaterialFinish = true
            $0.config.hairHighlight = Self.allMaterialsHair
            $0.config.enableSSAO = true
            $0.eye = SIMD3<Float>(1.6, 1.3, 4.4)
            $0.lightDirection = SIMD3<Float>(-0.5, -0.3, -0.8)
        }
        let rigidFrame = try SwatchScene.render(rigid, device: device, setup: setup)
        let skinnedFrame = try SwatchScene.render(skinned, device: device, setup: setup)
        let stats = SwatchScene.stats(skinnedFrame, reference: rigidFrame, size: 512, threshold: 0)
        XCTAssertEqual(stats.changedPixels, 0,
            "Skinned and rigid swatches differ on \(stats.changedPixels) pixels (max delta \(stats.maxDelta)) with the extensions on")
    }

    /// From a camera behind the spheres (looking down +Z) every visible normal
    /// has N.z < 0. A view vector stuck at +Z would make N·V <= 0 there and
    /// erase the band.
    func testHairBandIsVisibleFromBehindOnBothPaths() async throws {
        for fixture in [SwatchScene.Fixture.rigid, .skinned] {
            let model = try await SwatchScene.load(fixture, device: device)
            let behind = finishSetup {
                $0.eye = SIMD3<Float>(0, 0, -5)
                $0.lightDirection = SIMD3<Float>(0.3, -0.4, 0.9)
            }
            let off = try SwatchScene.render(model, device: device, setup: behind)
            var on = behind
            on.config.hairHighlight = Self.allMaterialsHair
            let band = SwatchScene.stats(try SwatchScene.render(model, device: device, setup: on), reference: off, size: 512)
            XCTAssertGreaterThan(band.changedPixels, 200, "\(fixture.rawValue): hair band missing when viewed from behind")
        }
    }

    // MARK: - Hair band

    func testHairBandIsOptInAndTracksTheKeyLight() async throws {
        let model = try await SwatchScene.load(.rigid, device: device)
        let hair = HairHighlightConfig(isEnabled: true, strength: 1.2, sharpness: 16, materialNameContains: "Matte")
        let off = try SwatchScene.render(model, device: device)
        let compiledIn = try SwatchScene.render(model, device: device, setup: finishSetup {
            $0.config.hairHighlight = Self.extensionsCompiledIn
        })
        let on = try SwatchScene.render(model, device: device, setup: finishSetup { $0.config.hairHighlight = hair })
        let matte = SwatchScene.third(0, size: 512)
        XCTAssertGreaterThan(SwatchScene.stats(on, reference: off, size: 512, columns: matte).changedPixels, 100,
            "The matte swatch should show the opt-in hair band")
        XCTAssertEqual(SwatchScene.stats(on, reference: compiledIn, size: 512, columns: SwatchScene.third(1, size: 512), threshold: 0).changedPixels, 0,
            "Materials that do not match the name filter must not change")
        assertUntouched(on, off, columns: SwatchScene.third(1, size: 512), "Leather (no hair band)")

        let movedOff = try SwatchScene.render(model, device: device, setup: finishSetup {
            $0.lightDirection = SIMD3<Float>(-0.9, -0.5, -0.2)
        })
        let movedOn = try SwatchScene.render(model, device: device, setup: finishSetup {
            $0.config.hairHighlight = hair
            $0.lightDirection = SIMD3<Float>(-0.9, -0.5, -0.2)
        })
        let a = try XCTUnwrap(SwatchScene.changeCentroid(on, reference: off, size: 512, columns: matte))
        let b = try XCTUnwrap(SwatchScene.changeCentroid(movedOn, reference: movedOff, size: 512, columns: matte))
        XCTAssertGreaterThan(simd_length(a - b), 2.0, "The hair band should move with the key light (\(a) -> \(b))")
    }

    // MARK: - Light scaling

    /// The finish and hair band must be linear in light intensity like the
    /// diffuse term, so one tuning carries across lighting rigs.
    func testExtensionsScaleLinearlyWithLightIntensity() async throws {
        let model = try await SwatchScene.load(.rigid, device: device)
        func addedLight(intensity: Float, columns: Range<Int>) throws -> Double {
            let base = finishSetup {
                $0.lightIntensity = intensity
                $0.normalization = .disabled
            }
            var extended = base
            extended.config.enableMaterialFinish = true
            extended.config.hairHighlight = HairHighlightConfig(isEnabled: true, strength: 1, sharpness: 8, materialNameContains: "Matte")
            let off = try SwatchScene.render(model, device: device, setup: base)
            let on = try SwatchScene.render(model, device: device, setup: extended)
            return SwatchScene.stats(on, reference: off, size: 512, columns: columns, threshold: 0).lumaDelta
        }
        for (name, columns) in [("hair band", SwatchScene.third(0, size: 512)), ("metal finish", SwatchScene.third(2, size: 512))] {
            let single = try addedLight(intensity: 0.25, columns: columns)
            let double = try addedLight(intensity: 0.5, columns: columns)
            XCTAssertGreaterThan(single, 0, "\(name) added no light")
            let ratio = double / single
            XCTAssertEqual(ratio, 2.0, accuracy: 0.4, "\(name): doubling the key light scaled the added light by \(ratio)")
        }
    }

    /// Like the rim, the extensions follow the light-normalization factor, so
    /// switching normalization modes keeps them in proportion to the surface.
    func testExtensionsFollowLightNormalization() async throws {
        let model = try await SwatchScene.load(.rigid, device: device)
        func addedLight(factor: Float) throws -> Double {
            let base = finishSetup {
                $0.lightIntensity = 0.25
                $0.normalization = .manual(factor)
            }
            var extended = base
            extended.config.enableMaterialFinish = true
            let off = try SwatchScene.render(model, device: device, setup: base)
            let on = try SwatchScene.render(model, device: device, setup: extended)
            return SwatchScene.stats(on, reference: off, size: 512, columns: SwatchScene.third(2, size: 512), threshold: 0).lumaDelta
        }
        let ratio = try addedLight(factor: 2) / addedLight(factor: 1)
        XCTAssertEqual(ratio, 2.0, accuracy: 0.4, "Finish scaled by \(ratio) when the normalization factor doubled")
    }

    // MARK: - Crease AO

    func testCreaseAOIsOptInAndClamped() async throws {
        let model = try await SwatchScene.load(.rigid, device: device)
        let off = try SwatchScene.render(model, device: device)
        let on = try SwatchScene.render(model, device: device, setup: finishSetup { $0.config.enableSSAO = true })
        XCTAssertGreaterThan(SwatchScene.differingBytes(off, on), 0,
            "enableSSAO should attenuate ambient light at the sphere silhouettes")

        let clampedHigh = try SwatchScene.render(model, device: device, setup: finishSetup {
            $0.config.enableSSAO = true
            $0.config.ssaoStrength = 50
        })
        let maximum = try SwatchScene.render(model, device: device, setup: finishSetup {
            $0.config.enableSSAO = true
            $0.config.ssaoStrength = 2
        })
        XCTAssertEqual(clampedHigh, maximum, "ssaoStrength above 2 must clamp to 2")
    }

    // MARK: - Silhouette

    func testSilhouetteModeSuppressesFinishAndHairBand() async throws {
        func silhouette(_ configure: (inout SwatchScene.Setup) -> Void) async throws -> [UInt8] {
            let model = try await SwatchScene.load(.rigid, device: device)
            let setup = finishSetup(configure)
            return try SwatchScene.render(model, device: device, setup: setup) { renderer in
                renderer.applySilhouetteMode(model: model)
            }
        }
        let plain = try await silhouette { _ in }
        let extended = try await silhouette {
            $0.config.enableMaterialFinish = true
            $0.config.hairHighlight = Self.allMaterialsHair
        }
        let stats = SwatchScene.stats(extended, reference: plain, size: 512, threshold: 0)
        XCTAssertEqual(stats.changedPixels, 0,
            "Silhouette output changed on \(stats.changedPixels) pixels with the finish and hair band enabled")
    }

    // MARK: - Material report

    func testMaterialReportReflectsTheRenderersFinish() async throws {
        let model = try await SwatchScene.load(.rigid, device: device)
        func report(finish: Bool) throws -> [String: MaterialReport.MaterialInfo] {
            var config = RendererConfig()
            config.colorPixelFormat = .rgba8Unorm
            config.enableMaterialFinish = finish
            let renderer = VRMRenderer(device: device, config: config)
            renderer.loadModel(model)
            let report = try XCTUnwrap(renderer.generateMaterialReport())
            XCTAssertEqual(report.materials.count, 3)
            let encoded = String(data: try JSONEncoder().encode(report), encoding: .utf8) ?? ""
            for key in ["specularMode", "outlineMode", "metallicFactor", "roughnessFactor", "outlineWidthFactor"] {
                XCTAssertTrue(encoded.contains("\"\(key)\""), "Report JSON is missing \(key)")
            }
            return Dictionary(uniqueKeysWithValues: report.materials.map { ($0.name, $0) })
        }

        let on = try report(finish: true)
        XCTAssertEqual(on["Matte"]?.specularMode, "off")
        XCTAssertEqual(on["Leather"]?.specularMode, "sheen")
        XCTAssertEqual(on["Metal"]?.specularMode, "metal")
        XCTAssertEqual(on["Matte"]?.roughnessFactor ?? -1, 0.9, accuracy: 0.0001)
        XCTAssertEqual(on["Metal"]?.outlineMode, "worldCoordinates")
        XCTAssertEqual(on["Metal"]?.outlineWidthFactor ?? -1, 0.0006, accuracy: 0.00001)

        let off = try report(finish: false)
        XCTAssertEqual(Set(off.values.map(\.specularMode)), ["off"], "The finish is off unless enabled")
        XCTAssertEqual(off["Metal"]?.metallicFactor ?? -1, 0.95, accuracy: 0.0001, "Authored values are still reported")
    }

    // MARK: - Per-fragment cost

    /// Env-gated microbenchmark (`VMK_RUN_FINISH_BENCH=1`). Renders a
    /// screen-filling sphere with matte and metal factors, extensions compiled
    /// in, and reports the GPU delta of the finish term. Not part of the
    /// default suite because timing is hardware-sensitive.
    func testFinishPerFragmentCost() throws {
        guard ProcessInfo.processInfo.environment["VMK_RUN_FINISH_BENCH"] == "1" else {
            throw XCTSkip("Set VMK_RUN_FINISH_BENCH=1 to run the finish microbenchmark")
        }
        let size = 4096
        let renderer = try LightingTestRenderer(device: device, width: size, height: size, surfaceExtensions: true)
        var uniforms = renderer.createUniforms(
            lightDir: SIMD3<Float>(-0.3, -0.4, -0.9),
            debugMode: 0)
        uniforms.viewMatrix = simd_float4x4(translation: SIMD3<Float>(0, 0, -1.2))
        uniforms.ambientColor = SIMD3<Float>(0.08, 0.08, 0.08)

        var matte = MToonMaterialUniforms()
        matte.baseColorFactor = SIMD4<Float>(0.8, 0.8, 0.8, 1)
        matte.shadeColorFactor = SIMD3<Float>(0.4, 0.4, 0.4)
        matte.shadingToonyFactor = 0.9
        matte.metallicFactor = 0
        matte.roughnessFactor = 1
        matte.vrmVersion = 1

        var metal = matte
        metal.metallicFactor = 1
        metal.roughnessFactor = 0.25

        func measure(_ material: inout MToonMaterialUniforms) throws -> [Double] {
            var samples: [Double] = []
            for frame in 0..<140 {
                var copy = material
                _ = try renderer.renderInternal(uniforms: &uniforms, material: &copy)
                if frame >= 10 { samples.append(renderer.lastGPUTimeMs) }
            }
            return samples.sorted()
        }

        let matteSamples = try measure(&matte)
        let metalSamples = try measure(&metal)
        let matteMedian = matteSamples[matteSamples.count / 2]
        let metalMedian = metalSamples[metalSamples.count / 2]
        print("[finish-bench] \(size)x\(size) matte median=\(matteMedian) ms metal median=\(metalMedian) ms delta=\(metalMedian - matteMedian) ms")
        XCTAssertGreaterThan(matteMedian, 0)
        XCTAssertGreaterThan(metalMedian, 0)
    }
}
