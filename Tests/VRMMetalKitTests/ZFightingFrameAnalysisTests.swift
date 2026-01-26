// Copyright 2025 Arkavo Inc. and contributors
// Licensed under the Apache License, Version 2.0

import XCTest
import Metal
import simd
@testable import VRMMetalKit

/// Tests for Z-fighting detection through frame-based analysis
/// Uses depth buffer histograms and multi-frame pixel comparison to detect flicker
final class ZFightingFrameAnalysisTests: XCTestCase {

    var device: MTLDevice!
    var commandQueue: MTLCommandQueue!
    var renderer: VRMRenderer!
    var model: VRMModel!

    // Test render target dimensions
    let renderWidth = 256
    let renderHeight = 256

    override func setUp() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        self.device = device

        guard let queue = device.makeCommandQueue() else {
            throw XCTSkip("Failed to create command queue")
        }
        self.commandQueue = queue

        self.renderer = VRMRenderer(device: device)

        // Create test model
        let vrmDocument = try VRMBuilder()
            .setSkeleton(.defaultHumanoid)
            .applyMorphs(["height": 1.0])
            .setHairColor([0.35, 0.25, 0.15])
            .setEyeColor([0.2, 0.4, 0.8])
            .setSkinTone(0.5)
            .addExpressions([.happy, .blink])
            .build()

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("vrm")

        try vrmDocument.serialize(to: tempURL)
        self.model = try await VRMModel.load(from: tempURL, device: device)
        try? FileManager.default.removeItem(at: tempURL)

        renderer.loadModel(model)
    }

    override func tearDown() async throws {
        // Wait for GPU to complete any in-flight commands before releasing resources
        if let commandQueue = commandQueue,
           let buffer = commandQueue.makeCommandBuffer() {
            buffer.commit()
            await buffer.completed()
        }

        if let renderer = renderer,
           let buffer = renderer.commandQueue.makeCommandBuffer() {
            buffer.commit()
            await buffer.completed()
        }

        // Small delay to allow Metal to finish any background cleanup
        try await Task.sleep(nanoseconds: 10_000_000)  // 10ms

        renderer = nil
        model = nil
        commandQueue = nil
        device = nil
    }

    // MARK: - Depth Buffer Creation Tests

    func testCreateDepthBuffer() {
        let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float,
            width: renderWidth,
            height: renderHeight,
            mipmapped: false
        )
        depthDescriptor.usage = [.renderTarget, .shaderRead]
        depthDescriptor.storageMode = .private

        let depthTexture = device.makeTexture(descriptor: depthDescriptor)

        XCTAssertNotNil(depthTexture, "Should be able to create depth texture")
        XCTAssertEqual(depthTexture?.width, renderWidth)
        XCTAssertEqual(depthTexture?.height, renderHeight)
        XCTAssertEqual(depthTexture?.pixelFormat, .depth32Float)
    }

    func testCreateReadableDepthBuffer() {
        // Create a depth buffer that can be read back for analysis
        let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float,
            width: renderWidth,
            height: renderHeight,
            mipmapped: false
        )
        depthDescriptor.usage = [.renderTarget, .shaderRead]

        #if os(macOS)
        depthDescriptor.storageMode = .managed
        #else
        depthDescriptor.storageMode = .shared
        #endif

        let depthTexture = device.makeTexture(descriptor: depthDescriptor)

        XCTAssertNotNil(depthTexture, "Should be able to create readable depth texture")
    }

    // MARK: - Depth Histogram Analysis

    /// Analyze depth values to detect clustering that might indicate Z-fighting
    func testDepthHistogramAnalysis() {
        // Simulate depth buffer values for analysis
        let depthValues: [Float] = generateTestDepthValues(count: 1000)

        // Build histogram
        let histogram = buildDepthHistogram(values: depthValues, bins: 100)

        // Check for suspicious clustering (many pixels at exactly the same depth)
        let maxBinCount = histogram.max() ?? 0
        let totalCount = histogram.reduce(0, +)
        let averageBinCount = totalCount / histogram.count

        // If any bin has more than 10x the average, it might indicate coplanar surfaces
        let clusteringThreshold = averageBinCount * 10

        let hasSuspiciousClustering = maxBinCount > clusteringThreshold

        print("Depth Histogram Analysis:")
        print("  Total samples: \(totalCount)")
        print("  Bins: \(histogram.count)")
        print("  Max bin count: \(maxBinCount)")
        print("  Average bin count: \(averageBinCount)")
        print("  Clustering threshold: \(clusteringThreshold)")
        print("  Suspicious clustering: \(hasSuspiciousClustering)")

        // This test documents the analysis approach
        XCTAssertGreaterThan(histogram.count, 0, "Should produce non-empty histogram")
    }

    func testDepthValueClustering() {
        // Create depth values that simulate Z-fighting (many values at same depth)
        var depthValues: [Float] = []

        // Normal distributed depths
        for i in 0..<500 {
            depthValues.append(Float(i) / 1000.0)
        }

        // Clustered depths (simulating Z-fighting)
        for _ in 0..<100 {
            depthValues.append(0.5)  // Many pixels at exactly depth 0.5
            depthValues.append(0.500001)  // Nearly identical depth
        }

        let clusteringScore = calculateClusteringScore(values: depthValues)

        print("Clustering score: \(clusteringScore)")

        // High clustering score indicates potential Z-fighting
        XCTAssertGreaterThan(clusteringScore, 0,
            "Clustered depths should produce non-zero clustering score")
    }

    // MARK: - Multi-Frame Flicker Detection

    func testMultiFrameFlickerDetection() {
        // Simulate multiple frames and check for pixel value changes
        // Z-fighting causes pixels to "flicker" between frames

        let frameCount = 10
        var frames: [[Float]] = []

        // Generate simulated frame data
        for frameIndex in 0..<frameCount {
            var frameData: [Float] = []
            for pixelIndex in 0..<(renderWidth * renderHeight) {
                // Simulate stable pixels (no Z-fighting)
                var value = Float(pixelIndex % 256) / 255.0

                // Simulate Z-fighting on some pixels (values alternate)
                if pixelIndex % 100 == 0 {
                    value = frameIndex % 2 == 0 ? 0.5 : 0.6  // Flickering pixel
                }

                frameData.append(value)
            }
            frames.append(frameData)
        }

        // Detect flicker by comparing consecutive frames
        var flickerPixels: Set<Int> = []

        for i in 1..<frameCount {
            let previousFrame = frames[i - 1]
            let currentFrame = frames[i]

            for pixelIndex in 0..<previousFrame.count {
                let diff = abs(currentFrame[pixelIndex] - previousFrame[pixelIndex])
                if diff > 0.01 {  // Threshold for significant change
                    flickerPixels.insert(pixelIndex)
                }
            }
        }

        let flickerRate = Float(flickerPixels.count) / Float(renderWidth * renderHeight)

        print("Flicker Detection:")
        print("  Frames analyzed: \(frameCount)")
        print("  Flickering pixels: \(flickerPixels.count)")
        print("  Flicker rate: \(flickerRate * 100)%")

        // Some flicker is expected in this test due to intentional simulation
        XCTAssertGreaterThan(flickerPixels.count, 0,
            "Test simulation should produce flickering pixels")
    }

    func testStableFramesNoFlicker() {
        // Generate frames with no Z-fighting (stable)
        let frameCount = 5
        var frames: [[Float]] = []

        for _ in 0..<frameCount {
            var frameData: [Float] = []
            for pixelIndex in 0..<(renderWidth * renderHeight) {
                // Stable pixel values (no flickering)
                let value = Float(pixelIndex % 256) / 255.0
                frameData.append(value)
            }
            frames.append(frameData)
        }

        // Detect flicker
        var flickerPixels: Set<Int> = []

        for i in 1..<frameCount {
            let previousFrame = frames[i - 1]
            let currentFrame = frames[i]

            for pixelIndex in 0..<previousFrame.count {
                let diff = abs(currentFrame[pixelIndex] - previousFrame[pixelIndex])
                if diff > 0.01 {
                    flickerPixels.insert(pixelIndex)
                }
            }
        }

        XCTAssertEqual(flickerPixels.count, 0,
            "Stable frames should have no flickering pixels")
    }

    // MARK: - Depth Buffer Read Tests

    func testDepthBufferReadback() {
        // Create a simple readable buffer to test readback capability
        let bufferSize = renderWidth * renderHeight * MemoryLayout<Float>.stride

        guard let readbackBuffer = device.makeBuffer(length: bufferSize, options: .storageModeShared) else {
            XCTFail("Failed to create readback buffer")
            return
        }

        // Initialize with test data
        let pointer = readbackBuffer.contents().bindMemory(to: Float.self, capacity: renderWidth * renderHeight)
        for i in 0..<(renderWidth * renderHeight) {
            pointer[i] = Float(i) / Float(renderWidth * renderHeight)
        }

        // Verify we can read back the data
        let readValue = pointer[1000]
        let expectedValue = Float(1000) / Float(renderWidth * renderHeight)

        XCTAssertEqual(readValue, expectedValue, accuracy: 0.0001,
            "Should be able to read back buffer contents")
    }

    // MARK: - Flicker Threshold Tests

    func testFlickerThresholdSensitivity() {
        // Test different thresholds for flicker detection
        let thresholds: [Float] = [0.001, 0.01, 0.05, 0.1]

        // Create frame pair with small differences
        var frame1: [Float] = []
        var frame2: [Float] = []

        for i in 0..<1000 {
            let base = Float(i) / 1000.0

            // Add small variations
            frame1.append(base)
            frame2.append(base + Float.random(in: -0.02...0.02))
        }

        print("\nFlicker Threshold Sensitivity:")
        print("Threshold | Detected Changes | Detection Rate")
        print("-" * 50)

        for threshold in thresholds {
            var changedPixels = 0

            for i in 0..<frame1.count {
                if abs(frame1[i] - frame2[i]) > threshold {
                    changedPixels += 1
                }
            }

            let detectionRate = Float(changedPixels) / Float(frame1.count)
            print(String(format: "%9.3f | %16d | %.2f%%", threshold, changedPixels, detectionRate * 100))
        }

        // Lower thresholds should detect more changes
        var detectionCounts: [Int] = []
        for threshold in thresholds {
            var count = 0
            for i in 0..<frame1.count {
                if abs(frame1[i] - frame2[i]) > threshold {
                    count += 1
                }
            }
            detectionCounts.append(count)
        }

        // Verify lower thresholds detect more
        for i in 1..<detectionCounts.count {
            XCTAssertLessThanOrEqual(detectionCounts[i], detectionCounts[i-1],
                "Lower threshold should detect more or equal changes")
        }
    }

    // MARK: - Z-Fighting Pattern Detection

    func testDetectAlternatingPattern() {
        // Z-fighting typically creates alternating patterns across frames
        let frameCount = 6
        var pixelValues: [Float] = []

        // Simulate Z-fighting: value alternates between 0.5 and 0.6
        for i in 0..<frameCount {
            pixelValues.append(i % 2 == 0 ? 0.5 : 0.6)
        }

        let isAlternating = detectAlternatingPattern(values: pixelValues)

        XCTAssertTrue(isAlternating,
            "Should detect alternating pattern indicative of Z-fighting")
    }

    func testNoAlternatingPatternInStablePixel() {
        let frameCount = 6
        var pixelValues: [Float] = []

        // Stable pixel: constant value with minor noise
        for _ in 0..<frameCount {
            pixelValues.append(0.5 + Float.random(in: -0.001...0.001))
        }

        let isAlternating = detectAlternatingPattern(values: pixelValues)

        XCTAssertFalse(isAlternating,
            "Stable pixel should not show alternating pattern")
    }

    // MARK: - Camera Movement Analysis

    /// Analysis helper for Z-fighting risk at different camera distances
    /// Not a test - run manually when needed for documentation
    private func analyzeZFightingDuringCameraMovement() {
        let cameraDistances: [Float] = [1.0, 2.0, 5.0, 10.0, 20.0]

        print("\nZ-Fighting Risk at Different Camera Distances:")
        print("Distance (m) | Depth Precision (mm) | Risk Level")
        print("-" * 55)

        let near: Float = 0.1
        let far: Float = 100.0
        let depthBits = 24

        for distance in cameraDistances {
            let depthRange = Float(1 << depthBits)
            let ndcPrecision = 1.0 / depthRange
            let precision = ndcPrecision * (far - near) * distance * distance / (near * far)

            let riskLevel: String
            if precision < 0.0001 {
                riskLevel = "Low"
            } else if precision < 0.001 {
                riskLevel = "Medium"
            } else {
                riskLevel = "High"
            }

            print(String(format: "%12.1f | %20.4f | %s", distance, precision * 1000, riskLevel))
        }
    }

    // MARK: - Helper Functions

    private func generateTestDepthValues(count: Int) -> [Float] {
        var values: [Float] = []

        // Generate depth values with realistic distribution
        for _ in 0..<count {
            // Most pixels are in the mid-range
            let depth = Float.random(in: 0.3...0.8)
            values.append(depth)
        }

        return values
    }

    private func buildDepthHistogram(values: [Float], bins: Int) -> [Int] {
        var histogram = [Int](repeating: 0, count: bins)

        for value in values {
            let binIndex = min(Int(value * Float(bins)), bins - 1)
            if binIndex >= 0 {
                histogram[binIndex] += 1
            }
        }

        return histogram
    }

    private func calculateClusteringScore(values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }

        // Sort values and look for clusters
        let sorted = values.sorted()

        var clusterCount = 0
        var currentClusterSize = 1
        let clusterThreshold: Float = 0.0001

        for i in 1..<sorted.count {
            if abs(sorted[i] - sorted[i-1]) < clusterThreshold {
                currentClusterSize += 1
            } else {
                if currentClusterSize > 5 {  // Significant cluster
                    clusterCount += currentClusterSize
                }
                currentClusterSize = 1
            }
        }

        // Don't forget to check the last cluster
        if currentClusterSize > 5 {
            clusterCount += currentClusterSize
        }

        return Float(clusterCount) / Float(values.count)
    }

    private func detectAlternatingPattern(values: [Float]) -> Bool {
        guard values.count >= 4 else { return false }

        var alternations = 0
        let threshold: Float = 0.01

        for i in 2..<values.count {
            let diff1 = values[i-1] - values[i-2]
            let diff2 = values[i] - values[i-1]

            // Check if differences alternate in sign and are significant
            if diff1 * diff2 < 0 && abs(diff1) > threshold && abs(diff2) > threshold {
                alternations += 1
            }
        }

        // If most transitions are alternations, it's likely Z-fighting
        return Float(alternations) / Float(values.count - 2) > 0.6
    }

}

// MARK: - String Multiplication Helper

private func *(lhs: String, rhs: Int) -> String {
    return String(repeating: lhs, count: rhs)
}
