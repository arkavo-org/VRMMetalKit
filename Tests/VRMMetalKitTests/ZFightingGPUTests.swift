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
@testable import VRMMetalKit

/// GPU-based Z-fighting detection tests.
/// Unlike the theoretical ZFighting*Tests, these tests actually render frames
/// to GPU and analyze the output for Z-fighting artifacts.
@MainActor
final class ZFightingGPUTests: XCTestCase {

    var device: MTLDevice!
    var helper: ZFightingTestHelper!

    override func setUp() async throws {
        device = MTLCreateSystemDefaultDevice()
        guard device != nil else {
            throw XCTSkip("Metal device not available")
        }
        helper = try ZFightingTestHelper(device: device, width: 256, height: 256)
    }

    override func tearDown() async throws {
        helper = nil
        device = nil
    }

    // MARK: - Test Helpers

    private var projectRoot: String {
        let fileManager = FileManager.default
        let candidates: [String?] = [
            ProcessInfo.processInfo.environment["PROJECT_ROOT"],
            URL(fileURLWithPath: #file)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .path,
            fileManager.currentDirectoryPath
        ]

        for candidate in candidates.compactMap({ $0 }) {
            let packagePath = "\(candidate)/Package.swift"
            if fileManager.fileExists(atPath: packagePath) {
                return candidate
            }
        }
        return fileManager.currentDirectoryPath
    }

    // MARK: - Basic GPU Rendering Tests

    func testGPURenderingWorks() throws {
        let frameData = try helper.renderFrame()

        XCTAssertEqual(frameData.count, 256 * 256 * 4, "Frame data should be 256x256 BGRA")

        let nonZeroCount = frameData.filter { $0 != 0 }.count
        print("GPU Rendering test:")
        print("  - Total bytes: \(frameData.count)")
        print("  - Non-zero bytes: \(nonZeroCount)")

        if nonZeroCount > 0 {
            let samplePixel = Array(frameData[0..<4])
            print("  - First pixel (BGRA): \(samplePixel)")
        }

        XCTAssertGreaterThan(nonZeroCount, 0, "Frame should have non-zero data (clear color or rendered content)")
    }

    func testDepthBufferReadback() throws {
        let depthData = try helper.renderAndReadDepth()

        XCTAssertEqual(depthData.count, 256 * 256, "Depth data should be 256x256")

        let hasNonZeroDepth = depthData.contains { $0 > 0.001 }
        let hasValidRange = depthData.allSatisfy { $0 >= 0 && $0 <= 1.0 || $0.isNaN }
        XCTAssertTrue(hasValidRange, "All depth values should be in [0, 1] range")

        print("Depth buffer stats: min=\(depthData.filter { !$0.isNaN }.min() ?? 0), max=\(depthData.filter { !$0.isNaN }.max() ?? 0)")
        print("Non-zero depth pixels: \(depthData.filter { $0 > 0.001 }.count)")
        print("Has non-zero depth: \(hasNonZeroDepth)")
    }

    func testMultipleFrameRendering() throws {
        let frames = try helper.renderMultipleFrames(count: 5)

        XCTAssertEqual(frames.count, 5, "Should render 5 frames")
        for (index, frame) in frames.enumerated() {
            XCTAssertEqual(frame.count, 256 * 256 * 4, "Frame \(index) should be correct size")
        }
    }

    // MARK: - POSITIVE Z-Fighting Tests (Prove We Can Detect It)

    /// CRITICAL TEST: Proves the detector can catch real Z-fighting.
    /// Renders two quads at EXACT same depth - this MUST cause detectable flicker.
    func testCoplanarSurfacesCauseDetectableFlicker() throws {
        let renderer = try SimpleTestRenderer(device: device, width: 256, height: 256)

        let (quad1, quad2) = CoplanarTestGeometry.createCoplanarQuads(z: 1.0, separation: 0.0, size: 0.8)

        let commands = [
            SimpleTestRenderer.DrawCommand(mesh: quad1, depthBias: 0, depthState: "less"),
            SimpleTestRenderer.DrawCommand(mesh: quad2, depthBias: 0, depthState: "less")
        ]

        // Use larger perturbations to trigger more visible Z-fighting
        let frames = try renderer.renderMultipleFrames(commands: commands, count: 20, perturbationScale: 0.001)

        let result = FlickerDetector.detectFlicker(frames: frames, threshold: 5)

        print("=== POSITIVE TEST: Coplanar Surfaces ===")
        print("  - Flicker rate: \(result.flickerRate)%")
        print("  - Flickering pixels: \(result.flickeringPixels.count)")
        print("  - Total pixels: \(result.totalPixels)")

        // Z-fighting with coplanar surfaces should cause SOME detectable flicker
        // Even 0.1% means hundreds of pixels are flickering
        XCTAssertGreaterThan(
            result.flickeringPixels.count, 100,
            "Coplanar surfaces MUST cause detectable flicker (>100 pixels). Got \(result.flickeringPixels.count). If this fails, the detector or renderer is broken!"
        )
    }

    /// Tests that ONLY coplanar rendering produces flicker from Z-fighting.
    /// Single surface (no overlap) should have zero center flicker.
    func testOnlyOverlappingSurfacesFlicker() throws {
        let renderer = try SimpleTestRenderer(device: device, width: 256, height: 256)

        // Test 1: Single quad (no Z-fighting possible)
        let (singleQuad, _) = CoplanarTestGeometry.createCoplanarQuads(z: 1.0, separation: 0.0, size: 0.8)
        let commandsSingle = [
            SimpleTestRenderer.DrawCommand(mesh: singleQuad, depthBias: 0, depthState: "less")
        ]
        let framesSingle = try renderer.renderMultipleFrames(commands: commandsSingle, count: 20, perturbationScale: 0.001)

        let centerSize = 64
        let centerStart = (256 - centerSize) / 2
        let resultSingleCenter = FlickerDetector.analyzeRegion(
            frames: framesSingle,
            x: centerStart, y: centerStart,
            width: centerSize, height: centerSize,
            frameWidth: 256,
            threshold: 5
        )

        // Test 2: Two coplanar quads (Z-fighting)
        let (quad1, quad2) = CoplanarTestGeometry.createCoplanarQuads(z: 1.0, separation: 0.0, size: 0.8)
        let commandsDouble = [
            SimpleTestRenderer.DrawCommand(mesh: quad1, depthBias: 0, depthState: "less"),
            SimpleTestRenderer.DrawCommand(mesh: quad2, depthBias: 0, depthState: "less")
        ]
        let framesDouble = try renderer.renderMultipleFrames(commands: commandsDouble, count: 20, perturbationScale: 0.001)

        let resultDoubleCenter = FlickerDetector.analyzeRegion(
            frames: framesDouble,
            x: centerStart, y: centerStart,
            width: centerSize, height: centerSize,
            frameWidth: 256,
            threshold: 5
        )

        print("=== SINGLE VS DOUBLE SURFACE TEST (Center 64x64) ===")
        print("  Single surface: \(resultSingleCenter.flickeringPixels.count) flickering pixels")
        print("  Two coplanar: \(resultDoubleCenter.flickeringPixels.count) flickering pixels")

        // Single surface should have very little flicker (just edge/projection effects)
        // Two coplanar surfaces should have MORE flicker from Z-fighting
        XCTAssertGreaterThan(
            resultDoubleCenter.flickeringPixels.count, resultSingleCenter.flickeringPixels.count,
            "Two coplanar surfaces should have MORE flicker than single surface. Single=\(resultSingleCenter.flickeringPixels.count), Double=\(resultDoubleCenter.flickeringPixels.count)"
        )
    }

    /// Tests multiple face layers at same depth - simulates VRM face material stacking bug.
    func testFaceLayersWithoutSeparationCauseFlicker() throws {
        let renderer = try SimpleTestRenderer(device: device, width: 256, height: 256)

        // All layers at SAME depth - should cause Z-fighting
        let layersCoplanar = FaceLayerTestGeometry.createLayersWithSeparations(
            z: 1.0,
            separations: [0.0, 0.0, 0.0, 0.0] // 5 layers, all coplanar
        )

        let commandsCoplanar = layersCoplanar.map { layer in
            SimpleTestRenderer.DrawCommand(mesh: layer.mesh, depthBias: 0, depthState: "less")
        }

        let framesCoplanar = try renderer.renderMultipleFrames(commands: commandsCoplanar, count: 20, perturbationScale: 0.001)
        let resultCoplanar = FlickerDetector.detectFlicker(frames: framesCoplanar, threshold: 5)

        print("=== FACE LAYERS TEST ===")
        print("  Coplanar (no separation) - Flicker: \(resultCoplanar.flickerRate)% (\(resultCoplanar.flickeringPixels.count) pixels)")

        // Layers with proper separation - should NOT Z-fight
        let layersSeparated = FaceLayerTestGeometry.createLayersWithSeparations(
            z: 1.0,
            separations: [0.005, 0.005, 0.005, 0.005] // 5mm between each layer
        )

        let commandsSeparated = layersSeparated.map { layer in
            SimpleTestRenderer.DrawCommand(mesh: layer.mesh, depthBias: 0, depthState: "less")
        }

        let framesSeparated = try renderer.renderMultipleFrames(commands: commandsSeparated, count: 20, perturbationScale: 0.001)
        let resultSeparated = FlickerDetector.detectFlicker(frames: framesSeparated, threshold: 5)

        print("  Separated (5mm gaps) - Flicker: \(resultSeparated.flickerRate)% (\(resultSeparated.flickeringPixels.count) pixels)")

        XCTAssertGreaterThan(
            resultCoplanar.flickeringPixels.count, resultSeparated.flickeringPixels.count,
            "Coplanar face layers should have MORE flickering pixels than separated layers"
        )
    }

    /// Tests that lessEqual depth function reduces Z-fighting vs less.
    func testLessEqualReducesFlicker() throws {
        let renderer = try SimpleTestRenderer(device: device, width: 256, height: 256)

        let (quad1, quad2) = CoplanarTestGeometry.createCoplanarQuads(z: 1.0, separation: 0.0, size: 0.8)

        let commandsLess = [
            SimpleTestRenderer.DrawCommand(mesh: quad1, depthBias: 0, depthState: "less"),
            SimpleTestRenderer.DrawCommand(mesh: quad2, depthBias: 0, depthState: "less")
        ]

        let framesLess = try renderer.renderMultipleFrames(commands: commandsLess, count: 10, perturbationScale: 0.0001)
        let resultLess = FlickerDetector.detectFlicker(frames: framesLess, threshold: 10)

        let commandsLessEqual = [
            SimpleTestRenderer.DrawCommand(mesh: quad1, depthBias: 0, depthState: "lessEqual"),
            SimpleTestRenderer.DrawCommand(mesh: quad2, depthBias: 0, depthState: "lessEqual")
        ]

        let framesLessEqual = try renderer.renderMultipleFrames(commands: commandsLessEqual, count: 10, perturbationScale: 0.0001)
        let resultLessEqual = FlickerDetector.detectFlicker(frames: framesLessEqual, threshold: 10)

        print("=== DEPTH FUNCTION COMPARISON ===")
        print("  .less - Flicker rate: \(resultLess.flickerRate)%")
        print("  .lessEqual - Flicker rate: \(resultLessEqual.flickerRate)%")

        XCTAssertLessThanOrEqual(
            resultLessEqual.flickerRate, resultLess.flickerRate,
            ".lessEqual should have same or less flicker than .less for coplanar surfaces"
        )
    }

    /// Tests Z-fighting at various distances - farther = worse precision = more flicker.
    func testZFightingWorseAtDistance() throws {
        let renderer = try SimpleTestRenderer(device: device, width: 256, height: 256)

        var flickerByDistance: [(Float, Float)] = []

        for distance in [1.0, 3.0, 10.0] as [Float] {
            let (quad1, quad2) = CoplanarTestGeometry.createCoplanarQuads(z: distance, separation: 0.0, size: 0.3)

            renderer.viewMatrix = makeLookAt(
                eye: SIMD3<Float>(0, 0, distance + 2),
                target: SIMD3<Float>(0, 0, distance),
                up: SIMD3<Float>(0, 1, 0)
            )

            let commands = [
                SimpleTestRenderer.DrawCommand(mesh: quad1, depthBias: 0, depthState: "less"),
                SimpleTestRenderer.DrawCommand(mesh: quad2, depthBias: 0, depthState: "less")
            ]

            let frames = try renderer.renderMultipleFrames(commands: commands, count: 10, perturbationScale: 0.0001)
            let result = FlickerDetector.detectFlicker(frames: frames, threshold: 10)

            flickerByDistance.append((distance, result.flickerRate))
        }

        print("=== Z-FIGHTING VS DISTANCE ===")
        for (distance, flicker) in flickerByDistance {
            print("  Distance \(distance)m: \(flicker)% flicker")
        }

        if flickerByDistance.count >= 2 {
            let nearFlicker = flickerByDistance[0].1
            let farFlicker = flickerByDistance[flickerByDistance.count - 1].1
            print("  Near (\(flickerByDistance[0].0)m): \(nearFlicker)%")
            print("  Far (\(flickerByDistance[flickerByDistance.count - 1].0)m): \(farFlicker)%")
        }
    }

    /// Tests minimum depth bias needed to prevent Z-fighting at 1m.
    func testMinimumEffectiveDepthBias() throws {
        let renderer = try SimpleTestRenderer(device: device, width: 256, height: 256)

        let (quad1, quad2) = CoplanarTestGeometry.createCoplanarQuads(z: 1.0, separation: 0.0, size: 0.8)

        let biasValues: [Float] = [0, -0.00001, -0.0001, -0.001, -0.01]
        var results: [(Float, Float)] = []

        for bias in biasValues {
            let commands = [
                SimpleTestRenderer.DrawCommand(mesh: quad1, depthBias: 0, depthState: "less"),
                SimpleTestRenderer.DrawCommand(mesh: quad2, depthBias: bias, depthState: "less")
            ]

            let frames = try renderer.renderMultipleFrames(commands: commands, count: 10, perturbationScale: 0.0001)
            let result = FlickerDetector.detectFlicker(frames: frames, threshold: 10)
            results.append((bias, result.flickerRate))
        }

        print("=== DEPTH BIAS EFFECTIVENESS ===")
        for (bias, flicker) in results {
            let status = flicker < 1.0 ? "OK" : "FLICKER"
            print("  Bias \(bias): \(flicker)% [\(status)]")
        }

        let effectiveBias = results.first { $0.1 < 1.0 }
        if let (bias, _) = effectiveBias {
            print("  Minimum effective bias: \(bias)")
        }
    }

    // MARK: - Flicker Detection Tests

    func testFlickerDetectorBasicFunctionality() throws {
        let frames = try helper.renderMultipleFrames(count: 10)

        let result = FlickerDetector.detectFlicker(frames: frames, threshold: 5)

        print("Flicker detection result:")
        print("  - Total pixels: \(result.totalPixels)")
        print("  - Flickering pixels: \(result.flickeringPixels.count)")
        print("  - Flicker rate: \(result.flickerRate)%")

        XCTAssertEqual(result.totalPixels, 256 * 256)
    }

    func testNoFlickerWithEmptyScene() throws {
        let frames = try helper.renderMultipleFrames(count: 10)

        let result = FlickerDetector.detectFlicker(frames: frames, threshold: 5)

        XCTAssertLessThan(
            result.flickerRate, 1.0,
            "Empty scene should have minimal flicker (<1%), got \(result.flickerRate)%"
        )
    }

    // MARK: - Depth Analysis Tests

    func testDepthAnalyzerBasicFunctionality() throws {
        let depthData = try helper.renderAndReadDepth()

        let result = DepthAnalyzer.analyzeDepthBuffer(depthValues: depthData)

        print("Depth analysis result:")
        print("  - Clusters found: \(result.clusters.count)")
        print("  - Has Z-fighting risk: \(result.hasZFightingRisk)")
        print("  - Foreground pixels: \(result.foregroundPixelCount)")
        print("  - Depth range: \(result.minDepth) - \(result.maxDepth)")

        if !result.clusters.isEmpty {
            print("  - Largest cluster: \(result.clusters[0].count) pixels at depth \(result.clusters[0].depth)")
        }
    }

    func testDepthPrecisionCalculation() {
        let distances: [Float] = [0.1, 0.5, 1.0, 2.0, 5.0, 10.0]
        let nearZ: Float = 0.01
        let farZ: Float = 100.0

        print("Depth precision at various distances (near=\(nearZ), far=\(farZ)):")
        for distance in distances {
            let precision = DepthAnalyzer.calculateDepthPrecision(
                distance: distance,
                nearZ: nearZ,
                farZ: farZ,
                depthBits: 24
            )
            print("  - \(distance)m: precision = \(precision)m (\(precision * 1000)mm)")
        }

        let precision1m = DepthAnalyzer.calculateDepthPrecision(
            distance: 1.0, nearZ: nearZ, farZ: farZ, depthBits: 24
        )

        XCTAssertGreaterThan(precision1m, 0, "Precision should be positive")
        XCTAssertLessThan(precision1m, 0.01, "Precision at 1m should be sub-centimeter")
    }

    // MARK: - VRM Model Rendering Tests

    func testVRMModelRendering() async throws {
        let modelPath = "\(projectRoot)/AliciaSolid.vrm"
        try XCTSkipIf(!FileManager.default.fileExists(atPath: modelPath),
                      "VRM model not found at \(modelPath)")

        let modelURL = URL(fileURLWithPath: modelPath)
        let model = try await VRMModel.load(from: modelURL, device: device)

        helper.loadModel(model)

        helper.setViewMatrix(makeLookAt(
            eye: SIMD3<Float>(0, 1.5, 2.0),
            target: SIMD3<Float>(0, 1.5, 0),
            up: SIMD3<Float>(0, 1, 0)
        ))

        let frames = try helper.renderMultipleFrames(count: 10, perturbationScale: 0.0001)

        let result = FlickerDetector.detectFlicker(frames: frames, threshold: 10)

        print("VRM Model flicker analysis:")
        print("  - Flicker rate: \(result.flickerRate)%")
        print("  - Flickering pixels: \(result.flickeringPixels.count)")

        let depthData = try helper.renderAndReadDepth()
        let depthResult = DepthAnalyzer.analyzeDepthBuffer(depthValues: depthData)

        print("  - Foreground pixels: \(depthResult.foregroundPixelCount)")
        print("  - Has Z-fighting risk: \(depthResult.hasZFightingRisk)")
    }

    func testVRMModelFaceRegionFlicker() async throws {
        let modelPath = "\(projectRoot)/AliciaSolid.vrm"
        try XCTSkipIf(!FileManager.default.fileExists(atPath: modelPath),
                      "VRM model not found at \(modelPath)")

        let modelURL = URL(fileURLWithPath: modelPath)
        let model = try await VRMModel.load(from: modelURL, device: device)

        helper.loadModel(model)

        helper.setViewMatrix(makeLookAt(
            eye: SIMD3<Float>(0, 1.6, 0.5),
            target: SIMD3<Float>(0, 1.6, 0),
            up: SIMD3<Float>(0, 1, 0)
        ))

        let frames = try helper.renderMultipleFrames(count: 10, perturbationScale: 0.00001)

        let centerX = 256 / 4
        let centerY = 256 / 4
        let regionSize = 256 / 2

        let regionResult = FlickerDetector.analyzeRegion(
            frames: frames,
            x: centerX,
            y: centerY,
            width: regionSize,
            height: regionSize,
            frameWidth: 256,
            threshold: 10
        )

        print("VRM Face Region flicker analysis:")
        print("  - Region: (\(centerX), \(centerY)) size \(regionSize)x\(regionSize)")
        print("  - Region flicker rate: \(regionResult.flickerRate)%")
        print("  - Flickering pixels in region: \(regionResult.flickeringPixels.count)")

        XCTAssertLessThan(
            regionResult.flickerRate, 5.0,
            "Face region should have minimal Z-fighting (<5%), got \(regionResult.flickerRate)%"
        )
    }

    // MARK: - Depth Precision at Distance Tests

    func testDepthPrecisionAtMultipleDistances() throws {
        let distances: [Float] = [0.5, 1.0, 2.0, 5.0]

        print("Testing depth precision at multiple distances:")

        for distance in distances {
            helper.setViewMatrix(makeLookAt(
                eye: SIMD3<Float>(0, 0, distance + 1),
                target: SIMD3<Float>(0, 0, distance),
                up: SIMD3<Float>(0, 1, 0)
            ))

            let depthData = try helper.renderAndReadDepth()
            let analysis = DepthAnalyzer.analyzeDepthBuffer(depthValues: depthData)

            let theoreticalPrecision = DepthAnalyzer.calculateDepthPrecision(
                distance: distance,
                nearZ: 0.01,
                farZ: 100.0,
                depthBits: 24
            )

            print("  Distance \(distance)m:")
            print("    - Theoretical precision: \(theoreticalPrecision)m")
            print("    - Clusters: \(analysis.clusters.count)")
            print("    - Z-fighting risk: \(analysis.hasZFightingRisk)")
        }
    }

    // MARK: - Alternating Pattern Tests

    func testAlternatingPatternDetection() {
        var frame1: [UInt8] = Array(repeating: 0, count: 256 * 256 * 4)
        var frame2 = frame1
        var frame3 = frame1
        var frame4 = frame1
        var frame5 = frame1

        for pixel in 0..<100 {
            let offset = pixel * 4
            frame1[offset] = 255
            frame1[offset + 1] = 0
            frame1[offset + 2] = 0

            frame2[offset] = 0
            frame2[offset + 1] = 0
            frame2[offset + 2] = 255

            frame3[offset] = 255
            frame3[offset + 1] = 0
            frame3[offset + 2] = 0

            frame4[offset] = 0
            frame4[offset + 1] = 0
            frame4[offset + 2] = 255

            frame5[offset] = 255
            frame5[offset + 1] = 0
            frame5[offset + 2] = 0
        }

        let frames = [frame1, frame2, frame3, frame4, frame5]

        let alternatingPixels = FlickerDetector.findAlternatingPixels(frames: frames)

        XCTAssertGreaterThan(
            alternatingPixels.count, 50,
            "Should detect alternating pixels, found \(alternatingPixels.count)"
        )

        let hasAlternating = FlickerDetector.detectAlternatingPattern(
            frames: frames,
            pixelIndex: 0,
            tolerance: 10
        )

        XCTAssertTrue(hasAlternating, "Pixel 0 should show alternating pattern")
    }

    // MARK: - Depth Histogram Tests

    func testDepthHistogram() throws {
        let depthData = try helper.renderAndReadDepth()

        let histogram = DepthAnalyzer.generateDepthHistogram(
            depthValues: depthData,
            bucketCount: 20
        )

        print("Depth histogram (20 buckets):")
        for (index, count) in histogram.enumerated() where count > 0 {
            let percentage = Float(count) / Float(256 * 256) * 100
            print("  Bucket \(index): \(count) pixels (\(String(format: "%.2f", percentage))%)")
        }

        XCTAssertEqual(histogram.count, 20)
    }

    // MARK: - Z-Fighting Risk Detection Tests

    func testZFightingRiskPixelDetection() throws {
        let depthData = try helper.renderAndReadDepth()

        let riskPixels = DepthAnalyzer.findZFightingRiskPixels(
            depthValues: depthData,
            width: 256,
            height: 256,
            precisionThreshold: 0.0001
        )

        print("Z-fighting risk pixel detection:")
        print("  - Risk pixels: \(riskPixels.count)")
        print("  - Risk percentage: \(Float(riskPixels.count) / Float(256 * 256) * 100)%")
    }
}
