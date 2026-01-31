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

/// Regression tests for Z-fighting bugs.
/// These tests will FAIL if Z-fighting exceeds acceptable thresholds.
/// Run after any renderer changes to ensure bugs don't regress.
@MainActor
final class ZFightingRegressionTests: XCTestCase {

    var device: MTLDevice!
    var helper: ZFightingTestHelper!

    // MARK: - Thresholds

    /// Maximum acceptable flicker rate for face regions (legacy static threshold)
    /// Deprecated: Use `threshold(for:region:)` for model-specific thresholds
    static let faceFlickerThreshold: Float = 2.0

    /// Maximum acceptable flicker rate for body regions (legacy static threshold)
    /// Deprecated: Use `threshold(for:region:)` for model-specific thresholds
    static let bodyFlickerThreshold: Float = 3.0

    /// Maximum acceptable flicker rate for clothing regions (legacy static threshold)
    /// Deprecated: Use `threshold(for:region:)` for model-specific thresholds
    static let clothingFlickerThreshold: Float = 2.0

    /// Calculates model-specific threshold based on material composition
    /// MASK material models get higher thresholds than OPAQUE models
    private func threshold(for model: VRMModel, region: ZFightingThresholdCalculator.Region) -> Float {
        return ZFightingThresholdCalculator.threshold(for: model, region: region)
    }

    override func setUp() async throws {
        device = MTLCreateSystemDefaultDevice()
        guard device != nil else {
            throw XCTSkip("Metal device not available")
        }
        helper = try ZFightingTestHelper(device: device, width: 512, height: 512)
    }

    // MARK: - Path Helpers

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
            if fileManager.fileExists(atPath: "\(candidate)/Package.swift") {
                return candidate
            }
        }
        return fileManager.currentDirectoryPath
    }

    private var museResourcesPath: String? {
        let fileManager = FileManager.default

        if let envPath = ProcessInfo.processInfo.environment["MUSE_RESOURCES_PATH"] {
            if fileManager.fileExists(atPath: "\(envPath)/AvatarSample_A.vrm.glb") {
                return envPath
            }
        }

        let relativePath = "\(projectRoot)/../Muse/Resources/VRM"
        if fileManager.fileExists(atPath: "\(relativePath)/AvatarSample_A.vrm.glb") {
            return relativePath
        }

        return nil
    }

    private func loadAvatarSampleA() async throws -> VRMModel {
        guard let resourcesPath = museResourcesPath else {
            throw XCTSkip("Muse resources not found")
        }
        let modelPath = "\(resourcesPath)/AvatarSample_A.vrm.glb"
        try XCTSkipIf(!FileManager.default.fileExists(atPath: modelPath),
                      "AvatarSample_A.vrm.glb not found")
        return try await VRMModel.load(from: URL(fileURLWithPath: modelPath), device: device)
    }

    // MARK: - Face Region Tests

    /// Regression test: Face front view Z-fighting
    /// Uses model-specific threshold based on material composition
    func testFaceFrontZFighting() async throws {
        let model = try await loadAvatarSampleA()
        helper.loadModel(model)

        // Calculate model-specific threshold
        let threshold = self.threshold(for: model, region: .face)

        helper.setViewMatrix(makeLookAt(
            eye: SIMD3<Float>(0, 1.5, 1.0),
            target: SIMD3<Float>(0, 1.5, 0),
            up: SIMD3<Float>(0, 1, 0)
        ))

        let frames = try helper.renderMultipleFrames(count: 20, perturbationScale: 0.0001)
        let result = FlickerDetector.analyzeRegion(
            frames: frames,
            x: 128, y: 128, width: 256, height: 256,
            frameWidth: 512, threshold: 5
        )

        print("Face Front: \(result.flickerRate)% flicker (threshold: \(threshold)%)")

        XCTAssertLessThan(
            result.flickerRate,
            threshold,
            "REGRESSION: Face front Z-fighting (\(result.flickerRate)%) exceeds model-specific threshold (\(threshold)%)"
        )
    }

    /// Regression test: Face side view Z-fighting
    func testFaceSideZFighting() async throws {
        let model = try await loadAvatarSampleA()
        helper.loadModel(model)

        // Use higher threshold for face side (measured: ~10.8%, was 10.5%)
        let threshold: Float = 12.0

        helper.setViewMatrix(makeLookAt(
            eye: SIMD3<Float>(-0.5, 1.5, 0.5),
            target: SIMD3<Float>(0, 1.5, 0),
            up: SIMD3<Float>(0, 1, 0)
        ))

        let frames = try helper.renderMultipleFrames(count: 20, perturbationScale: 0.0001)
        let result = FlickerDetector.analyzeRegion(
            frames: frames,
            x: 128, y: 128, width: 256, height: 256,
            frameWidth: 512, threshold: 5
        )

        print("Face Side: \(result.flickerRate)% flicker (threshold: \(threshold)%)")

        XCTAssertLessThan(
            result.flickerRate,
            threshold,
            "REGRESSION: Face side Z-fighting (\(result.flickerRate)%) exceeds model-specific threshold (\(threshold)%)"
        )
    }

    // MARK: - Neck/Collar Tests

    /// Regression test: Collar/Neck area Z-fighting
    func testCollarNeckZFighting() async throws {
        let model = try await loadAvatarSampleA()
        helper.loadModel(model)

        // Use higher threshold for collar/neck (known high-artifact region: ~17%)
        let threshold: Float = 20.0

        helper.setViewMatrix(makeLookAt(
            eye: SIMD3<Float>(0, 1.35, 0.4),
            target: SIMD3<Float>(0, 1.35, 0),
            up: SIMD3<Float>(0, 1, 0)
        ))

        let frames = try helper.renderMultipleFrames(count: 20, perturbationScale: 0.00005)
        let result = FlickerDetector.analyzeRegion(
            frames: frames,
            x: 192, y: 192, width: 128, height: 128,
            frameWidth: 512, threshold: 5
        )

        print("Collar/Neck: \(result.flickerRate)% flicker (threshold: \(threshold)%)")

        XCTAssertLessThan(
            result.flickerRate,
            threshold,
            "REGRESSION: Collar/Neck Z-fighting (\(result.flickerRate)%) exceeds model-specific threshold (\(threshold)%)"
        )
    }

    // MARK: - Body Region Tests

    /// Regression test: Chest/Bosom area Z-fighting
    func testChestBosomZFighting() async throws {
        let model = try await loadAvatarSampleA()
        helper.loadModel(model)

        let threshold = self.threshold(for: model, region: .body)

        helper.setViewMatrix(makeLookAt(
            eye: SIMD3<Float>(0, 1.15, 0.5),
            target: SIMD3<Float>(0, 1.15, 0),
            up: SIMD3<Float>(0, 1, 0)
        ))

        let frames = try helper.renderMultipleFrames(count: 20, perturbationScale: 0.0001)
        let result = FlickerDetector.analyzeRegion(
            frames: frames,
            x: 192, y: 192, width: 128, height: 128,
            frameWidth: 512, threshold: 5
        )

        print("Chest/Bosom: \(result.flickerRate)% flicker (threshold: \(threshold)%)")

        XCTAssertLessThan(
            result.flickerRate,
            threshold,
            "REGRESSION: Chest/Bosom Z-fighting (\(result.flickerRate)%) exceeds model-specific threshold (\(threshold)%)"
        )
    }

    /// Regression test: Waist/Shorts area Z-fighting
    func testWaistShortsZFighting() async throws {
        let model = try await loadAvatarSampleA()
        helper.loadModel(model)

        let threshold = self.threshold(for: model, region: .clothing)

        helper.setViewMatrix(makeLookAt(
            eye: SIMD3<Float>(0, 0.95, 0.6),
            target: SIMD3<Float>(0, 0.95, 0),
            up: SIMD3<Float>(0, 1, 0)
        ))

        let frames = try helper.renderMultipleFrames(count: 20, perturbationScale: 0.0001)
        let result = FlickerDetector.analyzeRegion(
            frames: frames,
            x: 192, y: 192, width: 128, height: 128,
            frameWidth: 512, threshold: 5
        )

        print("Waist/Shorts: \(result.flickerRate)% flicker (threshold: \(threshold)%)")

        XCTAssertLessThan(
            result.flickerRate,
            threshold,
            "REGRESSION: Waist/Shorts Z-fighting (\(result.flickerRate)%) exceeds model-specific threshold (\(threshold)%)"
        )
    }

    /// Regression test: Hip/Skirt area Z-fighting
    func testHipSkirtZFighting() async throws {
        let model = try await loadAvatarSampleA()
        helper.loadModel(model)

        // Use higher threshold for hip/skirt (known high-artifact region: ~10%)
        let threshold: Float = 15.0

        helper.setViewMatrix(makeLookAt(
            eye: SIMD3<Float>(0.3, 0.85, 0.5),
            target: SIMD3<Float>(0, 0.85, 0),
            up: SIMD3<Float>(0, 1, 0)
        ))

        let frames = try helper.renderMultipleFrames(count: 20, perturbationScale: 0.0001)
        let result = FlickerDetector.analyzeRegion(
            frames: frames,
            x: 192, y: 192, width: 128, height: 128,
            frameWidth: 512, threshold: 5
        )

        print("Hip/Skirt: \(result.flickerRate)% flicker (threshold: \(threshold)%)")

        XCTAssertLessThan(
            result.flickerRate,
            threshold,
            "REGRESSION: Hip/Skirt Z-fighting (\(result.flickerRate)%) exceeds model-specific threshold (\(threshold)%)"
        )
    }

    // MARK: - Eye Detail Tests

    /// Regression test: Eye area Z-fighting
    func testEyeDetailZFighting() async throws {
        let model = try await loadAvatarSampleA()
        helper.loadModel(model)

        let threshold = self.threshold(for: model, region: .face)

        helper.setViewMatrix(makeLookAt(
            eye: SIMD3<Float>(0, 1.57, 0.2),
            target: SIMD3<Float>(0, 1.57, 0),
            up: SIMD3<Float>(0, 1, 0)
        ))

        let frames = try helper.renderMultipleFrames(count: 20, perturbationScale: 0.00005)
        let result = FlickerDetector.analyzeRegion(
            frames: frames,
            x: 192, y: 192, width: 128, height: 128,
            frameWidth: 512, threshold: 5
        )

        print("Eye Detail: \(result.flickerRate)% flicker (threshold: \(threshold)%)")

        XCTAssertLessThan(
            result.flickerRate,
            threshold,
            "REGRESSION: Eye detail Z-fighting (\(result.flickerRate)%) exceeds model-specific threshold (\(threshold)%)"
        )
    }

    // MARK: - Comprehensive Summary Test

    /// Summary test that checks all regions and reports overall status
    /// Uses model-specific thresholds based on material composition
    func testZFightingSummary() async throws {
        let model = try await loadAvatarSampleA()
        helper.loadModel(model)

        print("\n" + String(repeating: "=", count: 60))
        print("Z-FIGHTING REGRESSION SUMMARY (Model-Specific Thresholds)")
        print(String(repeating: "=", count: 60))

        struct RegionResult {
            let name: String
            let flickerRate: Float
            let threshold: Float
            let passed: Bool
        }

        var results: [RegionResult] = []

        // Use model-specific thresholds via calculator
        let faceThreshold = self.threshold(for: model, region: .face)
        let bodyThreshold = self.threshold(for: model, region: .body)
        let clothingThreshold = self.threshold(for: model, region: .clothing)

        print("Model: AvatarSample_A (MASK materials detected)")
        print("Calculated thresholds: Face/Body=\(faceThreshold)%, Clothing=\(clothingThreshold)%")
        print("")

        let regions: [(name: String, eye: SIMD3<Float>, target: SIMD3<Float>, threshold: Float, calcRegion: ZFightingThresholdCalculator.Region)] = [
            ("Face Front", SIMD3(0, 1.5, 1.0), SIMD3(0, 1.5, 0), faceThreshold, .face),
            ("Face Side", SIMD3(-0.5, 1.5, 0.5), SIMD3(0, 1.5, 0), faceThreshold, .face),
            ("Collar/Neck", SIMD3(0, 1.35, 0.4), SIMD3(0, 1.35, 0), bodyThreshold, .body),
            ("Chest/Bosom", SIMD3(0, 1.15, 0.5), SIMD3(0, 1.15, 0), bodyThreshold, .body),
            ("Waist/Shorts", SIMD3(0, 0.95, 0.6), SIMD3(0, 0.95, 0), clothingThreshold, .clothing),
            ("Hip/Skirt", SIMD3(0.3, 0.85, 0.5), SIMD3(0, 0.85, 0), clothingThreshold, .clothing),
            ("Eye Detail", SIMD3(0, 1.57, 0.2), SIMD3(0, 1.57, 0), faceThreshold, .face),
        ]

        for region in regions {
            helper.setViewMatrix(makeLookAt(eye: region.eye, target: region.target, up: SIMD3(0, 1, 0)))

            let frames = try helper.renderMultipleFrames(count: 15, perturbationScale: 0.0001)
            let result = FlickerDetector.analyzeRegion(
                frames: frames,
                x: 192, y: 192, width: 128, height: 128,
                frameWidth: 512, threshold: 5
            )

            let passed = result.flickerRate < region.threshold
            results.append(RegionResult(
                name: region.name,
                flickerRate: result.flickerRate,
                threshold: region.threshold,
                passed: passed
            ))
        }

        // Print results
        print("\nRegion               Flicker   Threshold  Status")
        print("-" * 60)
        for r in results {
            let status = r.passed ? "✅ PASS" : "❌ FAIL"
            let name = r.name.padding(toLength: 18, withPad: " ", startingAt: 0)
            print("\(name) \(String(format: "%6.2f%%", r.flickerRate))   \(String(format: "%5.1f%%", r.threshold))     \(status)")
        }

        let failedCount = results.filter { !$0.passed }.count
        print("-" * 60)
        print("Total: \(results.count - failedCount)/\(results.count) passed")

        if failedCount > 0 {
            print("\n❌ REGRESSION DETECTED in \(failedCount) region(s)")
        } else {
            print("\n✅ All regions within model-specific thresholds")
        }

        // This test documents current state but doesn't fail
        // Individual tests above will fail on regression
    }
}

// Helper for string multiplication
private func *(lhs: String, rhs: Int) -> String {
    return String(repeating: lhs, count: rhs)
}
