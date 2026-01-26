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

    // MARK: - Thresholds (adjust as bugs are fixed)

    /// Maximum acceptable flicker rate for face regions
    static let faceFlickerThreshold: Float = 2.0  // Currently failing at 5%+, target <2%

    /// Maximum acceptable flicker rate for body regions
    static let bodyFlickerThreshold: Float = 3.0  // Currently failing at 9%+, target <3%

    /// Maximum acceptable flicker rate for clothing regions
    static let clothingFlickerThreshold: Float = 2.0

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
    /// BUG: Face materials (FaceMouth, EyeIris, EyeHighlight, Face_SKIN) Z-fight
    /// Current: 5.51% flicker | Target: <2%
    func testFaceFrontZFighting() async throws {
        let model = try await loadAvatarSampleA()
        helper.loadModel(model)

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

        print("Face Front: \(result.flickerRate)% flicker (\(result.flickeringPixels.count) pixels)")

        XCTAssertLessThan(
            result.flickerRate,
            Self.faceFlickerThreshold,
            "REGRESSION: Face front Z-fighting (\(result.flickerRate)%) exceeds threshold (\(Self.faceFlickerThreshold)%)"
        )
    }

    /// Regression test: Face side view Z-fighting
    /// Current: 5.11% flicker | Target: <2%
    func testFaceSideZFighting() async throws {
        let model = try await loadAvatarSampleA()
        helper.loadModel(model)

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

        print("Face Side: \(result.flickerRate)% flicker (\(result.flickeringPixels.count) pixels)")

        XCTAssertLessThan(
            result.flickerRate,
            Self.faceFlickerThreshold,
            "REGRESSION: Face side Z-fighting (\(result.flickerRate)%) exceeds threshold (\(Self.faceFlickerThreshold)%)"
        )
    }

    // MARK: - Neck/Collar Tests

    /// Regression test: Collar/Neck area Z-fighting
    /// BUG: Body_SKIN meets Face_SKIN at neck boundary
    /// Current: 9.27% flicker | Target: <3%
    func testCollarNeckZFighting() async throws {
        let model = try await loadAvatarSampleA()
        helper.loadModel(model)

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

        print("Collar/Neck: \(result.flickerRate)% flicker (\(result.flickeringPixels.count) pixels)")

        XCTAssertLessThan(
            result.flickerRate,
            Self.bodyFlickerThreshold,
            "REGRESSION: Collar/Neck Z-fighting (\(result.flickerRate)%) exceeds threshold (\(Self.bodyFlickerThreshold)%)"
        )
    }

    // MARK: - Body Region Tests

    /// Regression test: Chest/Bosom area Z-fighting
    /// BUG: Body_SKIN may Z-fight with clothing at chest boundary
    func testChestBosomZFighting() async throws {
        let model = try await loadAvatarSampleA()
        helper.loadModel(model)

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

        print("Chest/Bosom: \(result.flickerRate)% flicker (\(result.flickeringPixels.count) pixels)")

        XCTAssertLessThan(
            result.flickerRate,
            Self.bodyFlickerThreshold,
            "REGRESSION: Chest/Bosom Z-fighting (\(result.flickerRate)%) exceeds threshold (\(Self.bodyFlickerThreshold)%)"
        )
    }

    /// Regression test: Waist/Shorts area Z-fighting
    /// BUG: Body_SKIN meets Bottoms_CLOTH at waistline
    func testWaistShortsZFighting() async throws {
        let model = try await loadAvatarSampleA()
        helper.loadModel(model)

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

        print("Waist/Shorts: \(result.flickerRate)% flicker (\(result.flickeringPixels.count) pixels)")

        XCTAssertLessThan(
            result.flickerRate,
            Self.clothingFlickerThreshold,
            "REGRESSION: Waist/Shorts Z-fighting (\(result.flickerRate)%) exceeds threshold (\(Self.clothingFlickerThreshold)%)"
        )
    }

    /// Regression test: Hip/Skirt area Z-fighting
    /// BUG: Clothing primitives may overlap at hip area
    func testHipSkirtZFighting() async throws {
        let model = try await loadAvatarSampleA()
        helper.loadModel(model)

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

        print("Hip/Skirt: \(result.flickerRate)% flicker (\(result.flickeringPixels.count) pixels)")

        XCTAssertLessThan(
            result.flickerRate,
            Self.clothingFlickerThreshold,
            "REGRESSION: Hip/Skirt Z-fighting (\(result.flickerRate)%) exceeds threshold (\(Self.clothingFlickerThreshold)%)"
        )
    }

    // MARK: - Eye Detail Tests

    /// Regression test: Eye area Z-fighting
    /// BUG: EyeIris (BLEND) and EyeHighlight (BLEND) Z-fight with eye socket
    func testEyeDetailZFighting() async throws {
        let model = try await loadAvatarSampleA()
        helper.loadModel(model)

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

        print("Eye Detail: \(result.flickerRate)% flicker (\(result.flickeringPixels.count) pixels)")

        XCTAssertLessThan(
            result.flickerRate,
            Self.faceFlickerThreshold,
            "REGRESSION: Eye detail Z-fighting (\(result.flickerRate)%) exceeds threshold (\(Self.faceFlickerThreshold)%)"
        )
    }

    // MARK: - Comprehensive Summary Test

    /// Summary test that checks all regions and reports overall status
    func testZFightingSummary() async throws {
        let model = try await loadAvatarSampleA()
        helper.loadModel(model)

        print("\n" + String(repeating: "=", count: 50))
        print("Z-FIGHTING REGRESSION SUMMARY")
        print(String(repeating: "=", count: 50))

        struct RegionResult {
            let name: String
            let flickerRate: Float
            let threshold: Float
            let passed: Bool
        }

        var results: [RegionResult] = []

        let regions: [(name: String, eye: SIMD3<Float>, target: SIMD3<Float>, threshold: Float)] = [
            ("Face Front", SIMD3(0, 1.5, 1.0), SIMD3(0, 1.5, 0), Self.faceFlickerThreshold),
            ("Face Side", SIMD3(-0.5, 1.5, 0.5), SIMD3(0, 1.5, 0), Self.faceFlickerThreshold),
            ("Collar/Neck", SIMD3(0, 1.35, 0.4), SIMD3(0, 1.35, 0), Self.bodyFlickerThreshold),
            ("Chest/Bosom", SIMD3(0, 1.15, 0.5), SIMD3(0, 1.15, 0), Self.bodyFlickerThreshold),
            ("Waist/Shorts", SIMD3(0, 0.95, 0.6), SIMD3(0, 0.95, 0), Self.clothingFlickerThreshold),
            ("Hip/Skirt", SIMD3(0.3, 0.85, 0.5), SIMD3(0, 0.85, 0), Self.clothingFlickerThreshold),
            ("Eye Detail", SIMD3(0, 1.57, 0.2), SIMD3(0, 1.57, 0), Self.faceFlickerThreshold),
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
        print("-" * 50)
        for r in results {
            let status = r.passed ? "✅ PASS" : "❌ FAIL"
            let name = r.name.padding(toLength: 18, withPad: " ", startingAt: 0)
            print("\(name) \(String(format: "%6.2f%%", r.flickerRate))   \(String(format: "%5.1f%%", r.threshold))     \(status)")
        }

        let failedCount = results.filter { !$0.passed }.count
        print("-" * 50)
        print("Total: \(results.count - failedCount)/\(results.count) passed")

        if failedCount > 0 {
            print("\n❌ REGRESSION DETECTED in \(failedCount) region(s)")
        } else {
            print("\n✅ All regions within acceptable thresholds")
        }

        // This test documents current state but doesn't fail
        // Individual tests above will fail on regression
    }
}

// Helper for string multiplication
private func *(lhs: String, rhs: Int) -> String {
    return String(repeating: lhs, count: rhs)
}
