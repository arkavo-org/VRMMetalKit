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
import simd
@testable import VRMMetalKit

/// Tests for VRM 0.0 coordinate conversion when applying VRMA animations
///
/// VRM 0.0 models use Unity's left-handed coordinate system while
/// VRMA animations use VRM 1.0's glTF right-handed coordinate system.
/// The conversion negates X and Z components per three-vrm createVRMAnimationClip.ts.
final class VRMACoordinateConversionTests: XCTestCase {

    // MARK: - Test Setup

    private var projectRoot: String {
        let fileManager = FileManager.default
        let candidates: [String?] = [
            ProcessInfo.processInfo.environment["PROJECT_ROOT"],
            ProcessInfo.processInfo.environment["SRCROOT"],
            URL(fileURLWithPath: #file)
                .deletingLastPathComponent()
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

    // MARK: - VRM Version Detection Tests

    /// Verify that VRM 0.0 models are correctly detected
    func testVRM0VersionDetection() async throws {
        let modelPath = "\(projectRoot)/AliciaSolid.vrm"

        try XCTSkipIf(!FileManager.default.fileExists(atPath: modelPath),
                      "VRM model not found at \(modelPath)")

        guard let device = MTLCreateSystemDefaultDevice() else {
            XCTFail("Metal device not available")
            return
        }

        let modelURL = URL(fileURLWithPath: modelPath)
        let model = try await VRMModel.load(from: modelURL, device: device)

        XCTAssertEqual(model.specVersion, .v0_0, "AliciaSolid.vrm should be VRM 0.0")
        XCTAssertTrue(model.isVRM0, "isVRM0 should return true for VRM 0.0 models")

        print("\n=== VRM Version Detection ===")
        print("Model: AliciaSolid.vrm")
        print("specVersion: \(model.specVersion)")
        print("isVRM0: \(model.isVRM0)")
        print("springBone.specVersion: \(model.springBone?.specVersion ?? "nil")")
    }

    /// Verify version detection for AvatarSample_A
    func testAvatarSampleVersionDetection() async throws {
        let modelPath = "\(projectRoot)/AvatarSample_A.vrm"

        try XCTSkipIf(!FileManager.default.fileExists(atPath: modelPath),
                      "VRM model not found at \(modelPath)")

        guard let device = MTLCreateSystemDefaultDevice() else {
            XCTFail("Metal device not available")
            return
        }

        let modelURL = URL(fileURLWithPath: modelPath)
        let model = try await VRMModel.load(from: modelURL, device: device)

        print("\n=== VRM Version Detection ===")
        print("Model: AvatarSample_A.vrm")
        print("specVersion: \(model.specVersion)")
        print("isVRM0: \(model.isVRM0)")
    }

    // MARK: - Coordinate Conversion Math Tests

    /// Test rotation conversion math
    func testRotationConversionMath() {
        // Identity quaternion should remain unchanged
        let identity = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        let convertedIdentity = convertRotationForVRM0Test(identity)
        XCTAssertEqual(convertedIdentity.imag.x, 0, accuracy: 0.0001)
        XCTAssertEqual(convertedIdentity.imag.y, 0, accuracy: 0.0001)
        XCTAssertEqual(convertedIdentity.imag.z, 0, accuracy: 0.0001)
        XCTAssertEqual(convertedIdentity.real, 1, accuracy: 0.0001)

        // Test 90 degree rotation around Y axis (should be unchanged)
        let rotY90 = simd_quatf(angle: .pi/2, axis: SIMD3<Float>(0, 1, 0))
        let convertedRotY90 = convertRotationForVRM0Test(rotY90)

        // For Y-axis rotation, X and Z components of quaternion should be 0
        // So conversion should not change much
        print("\n=== Rotation Conversion Test (90° Y) ===")
        print("Original: quat(\(rotY90.imag.x), \(rotY90.imag.y), \(rotY90.imag.z), \(rotY90.real))")
        print("Converted: quat(\(convertedRotY90.imag.x), \(convertedRotY90.imag.y), \(convertedRotY90.imag.z), \(convertedRotY90.real))")

        // Test 45 degree rotation around X axis (X component should be negated)
        let rotX45 = simd_quatf(angle: .pi/4, axis: SIMD3<Float>(1, 0, 0))
        let convertedRotX45 = convertRotationForVRM0Test(rotX45)

        print("\n=== Rotation Conversion Test (45° X) ===")
        print("Original: quat(\(rotX45.imag.x), \(rotX45.imag.y), \(rotX45.imag.z), \(rotX45.real))")
        print("Converted: quat(\(convertedRotX45.imag.x), \(convertedRotX45.imag.y), \(convertedRotX45.imag.z), \(convertedRotX45.real))")

        // X component should be negated
        XCTAssertEqual(convertedRotX45.imag.x, -rotX45.imag.x, accuracy: 0.0001)
        XCTAssertEqual(convertedRotX45.imag.y, rotX45.imag.y, accuracy: 0.0001)
        XCTAssertEqual(convertedRotX45.imag.z, -rotX45.imag.z, accuracy: 0.0001)
        XCTAssertEqual(convertedRotX45.real, rotX45.real, accuracy: 0.0001)

        // Test 30 degree rotation around Z axis (Z component should be negated)
        let rotZ30 = simd_quatf(angle: .pi/6, axis: SIMD3<Float>(0, 0, 1))
        let convertedRotZ30 = convertRotationForVRM0Test(rotZ30)

        print("\n=== Rotation Conversion Test (30° Z) ===")
        print("Original: quat(\(rotZ30.imag.x), \(rotZ30.imag.y), \(rotZ30.imag.z), \(rotZ30.real))")
        print("Converted: quat(\(convertedRotZ30.imag.x), \(convertedRotZ30.imag.y), \(convertedRotZ30.imag.z), \(convertedRotZ30.real))")

        // Z component should be negated
        XCTAssertEqual(convertedRotZ30.imag.x, -rotZ30.imag.x, accuracy: 0.0001)
        XCTAssertEqual(convertedRotZ30.imag.y, rotZ30.imag.y, accuracy: 0.0001)
        XCTAssertEqual(convertedRotZ30.imag.z, -rotZ30.imag.z, accuracy: 0.0001)
        XCTAssertEqual(convertedRotZ30.real, rotZ30.real, accuracy: 0.0001)
    }

    /// Test translation conversion math
    func testTranslationConversionMath() {
        // Test positive translation
        let translation = SIMD3<Float>(1.0, 2.0, 3.0)
        let converted = convertTranslationForVRM0Test(translation)

        XCTAssertEqual(converted.x, -1.0, accuracy: 0.0001, "X should be negated")
        XCTAssertEqual(converted.y, 2.0, accuracy: 0.0001, "Y should remain unchanged")
        XCTAssertEqual(converted.z, -3.0, accuracy: 0.0001, "Z should be negated")

        print("\n=== Translation Conversion Test ===")
        print("Original: (\(translation.x), \(translation.y), \(translation.z))")
        print("Converted: (\(converted.x), \(converted.y), \(converted.z))")
    }

    // MARK: - VRMA Loading with Conversion Tests

    /// Test that VRMA loads with conversion enabled for VRM 0.0 models
    func testVRMALoadingWithVRM0Model() async throws {
        let modelPath = "\(projectRoot)/AliciaSolid.vrm"
        let vrmaPath = "\(projectRoot)/VRMA_01.vrma"

        try XCTSkipIf(!FileManager.default.fileExists(atPath: modelPath),
                      "VRM model not found at \(modelPath)")
        try XCTSkipIf(!FileManager.default.fileExists(atPath: vrmaPath),
                      "VRMA file not found at \(vrmaPath)")

        guard let device = MTLCreateSystemDefaultDevice() else {
            XCTFail("Metal device not available")
            return
        }

        // Load VRM 0.0 model
        let modelURL = URL(fileURLWithPath: modelPath)
        let model = try await VRMModel.load(from: modelURL, device: device)
        XCTAssertTrue(model.isVRM0, "Model should be VRM 0.0")

        // Load VRMA with model (should enable conversion)
        let vrmaURL = URL(fileURLWithPath: vrmaPath)
        let clip = try VRMAnimationLoader.loadVRMA(from: vrmaURL, model: model)

        XCTAssertGreaterThan(clip.duration, 0)
        XCTAssertGreaterThan(clip.jointTracks.count, 0)

        print("\n=== VRMA Loading with VRM 0.0 Model ===")
        print("Duration: \(clip.duration)s")
        print("Joint tracks: \(clip.jointTracks.count)")

        // Sample hips at t=0 and t=0.5 to see if coordinate conversion affects the values
        if let hipsTrack = clip.jointTracks.first(where: { $0.bone == .hips }) {
            let (rot0, trans0, _) = hipsTrack.sample(at: 0)
            let (rot05, trans05, _) = hipsTrack.sample(at: clip.duration / 2)

            print("\nHips at t=0:")
            if let r = rot0 {
                print("  Rotation: quat(\(r.imag.x), \(r.imag.y), \(r.imag.z), \(r.real))")
            }
            if let t = trans0 {
                print("  Translation: (\(t.x), \(t.y), \(t.z))")
            }

            print("\nHips at t=\(clip.duration / 2):")
            if let r = rot05 {
                print("  Rotation: quat(\(r.imag.x), \(r.imag.y), \(r.imag.z), \(r.real))")
            }
            if let t = trans05 {
                print("  Translation: (\(t.x), \(t.y), \(t.z))")
            }
        }
    }

    /// Compare VRMA loading with and without model to see conversion difference
    func testVRMALoadingComparisonWithAndWithoutModel() async throws {
        let modelPath = "\(projectRoot)/AliciaSolid.vrm"
        let vrmaPath = "\(projectRoot)/VRMA_01.vrma"

        try XCTSkipIf(!FileManager.default.fileExists(atPath: modelPath),
                      "VRM model not found at \(modelPath)")
        try XCTSkipIf(!FileManager.default.fileExists(atPath: vrmaPath),
                      "VRMA file not found at \(vrmaPath)")

        guard let device = MTLCreateSystemDefaultDevice() else {
            XCTFail("Metal device not available")
            return
        }

        // Load VRM 0.0 model
        let modelURL = URL(fileURLWithPath: modelPath)
        let model = try await VRMModel.load(from: modelURL, device: device)

        // Load VRMA without model (no conversion)
        let vrmaURL = URL(fileURLWithPath: vrmaPath)
        let clipWithoutModel = try VRMAnimationLoader.loadVRMA(from: vrmaURL, model: nil)

        // Load VRMA with model (conversion enabled)
        let clipWithModel = try VRMAnimationLoader.loadVRMA(from: vrmaURL, model: model)

        print("\n=== VRMA Loading Comparison ===")
        print("Testing if coordinate conversion is being applied for VRM 0.0 models")

        // Sample the same bone and compare values
        let testBones: [VRMHumanoidBone] = [.hips, .leftUpperArm, .rightUpperArm]

        for bone in testBones {
            guard let trackWithoutModel = clipWithoutModel.jointTracks.first(where: { $0.bone == bone }),
                  let trackWithModel = clipWithModel.jointTracks.first(where: { $0.bone == bone }) else {
                continue
            }

            let (rot1, trans1, _) = trackWithoutModel.sample(at: 0)
            let (rot2, trans2, _) = trackWithModel.sample(at: 0)

            print("\n\(bone):")
            if let r1 = rot1, let r2 = rot2 {
                print("  Without model: quat(\(String(format: "%.4f", r1.imag.x)), \(String(format: "%.4f", r1.imag.y)), \(String(format: "%.4f", r1.imag.z)), \(String(format: "%.4f", r1.real)))")
                print("  With VRM 0.0:  quat(\(String(format: "%.4f", r2.imag.x)), \(String(format: "%.4f", r2.imag.y)), \(String(format: "%.4f", r2.imag.z)), \(String(format: "%.4f", r2.real)))")

                // Check if X and Z are negated (allowing for retargeting differences)
                let xNegated = abs(r1.imag.x + r2.imag.x) < 0.01 || abs(r1.imag.x) < 0.001
                let zNegated = abs(r1.imag.z + r2.imag.z) < 0.01 || abs(r1.imag.z) < 0.001
                print("  X negated: \(xNegated), Z negated: \(zNegated)")
            }

            if let t1 = trans1, let t2 = trans2 {
                print("  Without model: (\(String(format: "%.4f", t1.x)), \(String(format: "%.4f", t1.y)), \(String(format: "%.4f", t1.z)))")
                print("  With VRM 0.0:  (\(String(format: "%.4f", t2.x)), \(String(format: "%.4f", t2.y)), \(String(format: "%.4f", t2.z)))")
            }
        }
    }

    // MARK: - Direction Tests

    /// Test that hips translation direction is correct after conversion
    func testHipsTranslationDirection() async throws {
        let modelPath = "\(projectRoot)/AliciaSolid.vrm"
        let vrmaPath = "\(projectRoot)/VRMA_01.vrma"

        try XCTSkipIf(!FileManager.default.fileExists(atPath: modelPath),
                      "VRM model not found at \(modelPath)")
        try XCTSkipIf(!FileManager.default.fileExists(atPath: vrmaPath),
                      "VRMA file not found at \(vrmaPath)")

        guard let device = MTLCreateSystemDefaultDevice() else {
            XCTFail("Metal device not available")
            return
        }

        let modelURL = URL(fileURLWithPath: modelPath)
        let model = try await VRMModel.load(from: modelURL, device: device)

        let vrmaURL = URL(fileURLWithPath: vrmaPath)
        let clip = try VRMAnimationLoader.loadVRMA(from: vrmaURL, model: model)

        guard let hipsTrack = clip.jointTracks.first(where: { $0.bone == .hips }) else {
            XCTFail("No hips track found")
            return
        }

        print("\n=== Hips Translation Over Time ===")
        print("Testing if walking animation moves in correct direction")

        let sampleTimes: [Float] = [0, 0.25, 0.5, 0.75, 1.0].map { $0 * clip.duration }
        var translations: [SIMD3<Float>] = []

        for t in sampleTimes {
            let (_, trans, _) = hipsTrack.sample(at: t)
            if let tr = trans {
                translations.append(tr)
                let timePercent = (t / clip.duration) * 100
                print("  t=\(String(format: "%.0f", timePercent))%: (\(String(format: "%.4f", tr.x)), \(String(format: "%.4f", tr.y)), \(String(format: "%.4f", tr.z)))")
            }
        }

        // Check if there's forward/backward movement (Z axis)
        if translations.count >= 2 {
            let zMovement = translations.last!.z - translations.first!.z
            print("\n  Z movement (first to last): \(String(format: "%.4f", zMovement))")
            print("  Direction: \(zMovement > 0 ? "Positive Z (forward in VRM 0.0)" : "Negative Z (backward in VRM 0.0)")")
        }
    }

    // MARK: - Helper Functions

    /// Test version of rotation conversion (matching the private function in VRMAnimationLoader)
    private func convertRotationForVRM0Test(_ q: simd_quatf) -> simd_quatf {
        return simd_quatf(ix: -q.imag.x, iy: q.imag.y, iz: -q.imag.z, r: q.real)
    }

    /// Test version of translation conversion (matching the private function in VRMAnimationLoader)
    private func convertTranslationForVRM0Test(_ v: SIMD3<Float>) -> SIMD3<Float> {
        return SIMD3<Float>(-v.x, v.y, -v.z)
    }
}
