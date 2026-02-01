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

/// Tests for VRMModel convenience methods
final class VRMModelConvenienceTests: XCTestCase {
    
    private var device: MTLDevice!
    private var model: VRMModel!
    
    override func setUp() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        self.device = device
        
        // Build a test model
        let vrmDocument = try VRMBuilder()
            .setSkeleton(.defaultHumanoid)
            .build()
        
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("vrm")
        
        try vrmDocument.serialize(to: tempURL)
        self.model = try await VRMModel.load(from: tempURL, device: device)
        try? FileManager.default.removeItem(at: tempURL)
    }
    
    override func tearDown() {
        model = nil
        device = nil
    }
    
    // MARK: - setLocalRotation Tests
    
    func testSetLocalRotation() throws {
        // Set rotation for head
        let rotation = simd_quatf(angle: Float.pi / 4, axis: SIMD3<Float>(0, 1, 0))
        model.setLocalRotation(rotation, for: .head)
        
        // Verify rotation was set
        guard let humanoid = model.humanoid,
              let headIndex = humanoid.getBoneNode(.head) else {
            XCTFail("Model should have head bone")
            return
        }
        
        let headNode = model.nodes[headIndex]
        assertQuaternionsEqual(headNode.rotation, rotation, tolerance: 0.001)
    }
    
    func testSetLocalRotationForMultipleBones() throws {
        // Set rotations for both arms
        let leftArmRotation = simd_quatf(angle: Float.pi / 6, axis: SIMD3<Float>(0, 0, 1))
        let rightArmRotation = simd_quatf(angle: -Float.pi / 6, axis: SIMD3<Float>(0, 0, 1))
        
        model.setLocalRotation(leftArmRotation, for: .leftUpperArm)
        model.setLocalRotation(rightArmRotation, for: .rightUpperArm)
        
        // Verify
        XCTAssertNotNil(model.getLocalRotation(for: .leftUpperArm))
        XCTAssertNotNil(model.getLocalRotation(for: .rightUpperArm))
        
        if let leftRot = model.getLocalRotation(for: .leftUpperArm) {
            assertQuaternionsEqual(leftRot, leftArmRotation, tolerance: 0.001)
        }
        if let rightRot = model.getLocalRotation(for: .rightUpperArm) {
            assertQuaternionsEqual(rightRot, rightArmRotation, tolerance: 0.001)
        }
    }
    
    func testSetLocalRotationForNonExistentBone() {
        // Should not crash for non-existent bone
        let rotation = simd_quatf(angle: Float.pi / 4, axis: SIMD3<Float>(0, 1, 0))
        
        // Create minimal model without all bones
        // This test just verifies it doesn't crash
        model.setLocalRotation(rotation, for: .leftThumbDistal)
        
        // Should return nil for non-existent bone
        XCTAssertNil(model.getLocalRotation(for: .leftThumbDistal))
    }
    
    // MARK: - getLocalRotation Tests
    
    func testGetLocalRotation() throws {
        // Initially should have some rotation (from bind pose)
        let initialRotation = model.getLocalRotation(for: .hips)
        XCTAssertNotNil(initialRotation)
        
        // Set a new rotation
        let newRotation = simd_quatf(angle: Float.pi / 2, axis: SIMD3<Float>(0, 1, 0))
        model.setLocalRotation(newRotation, for: .hips)
        
        // Get and verify
        let retrievedRotation = model.getLocalRotation(for: .hips)
        XCTAssertNotNil(retrievedRotation)
        if let retrieved = retrievedRotation {
            assertQuaternionsEqual(retrieved, newRotation, tolerance: 0.001)
        }
    }
    
    func testGetLocalRotationReturnsNilForInvalidBone() {
        // Should return nil for non-existent bone
        let rotation = model.getLocalRotation(for: .leftLittleDistal)
        XCTAssertNil(rotation)
    }
    
    // MARK: - setHipsTranslation Tests
    
    func testSetHipsTranslation() throws {
        let translation = SIMD3<Float>(1.0, 2.0, 3.0)
        model.setHipsTranslation(translation)
        
        // Verify
        let hipsTranslation = model.getHipsTranslation()
        XCTAssertNotNil(hipsTranslation)
        if let hips = hipsTranslation {
            XCTAssertEqual(hips.x, translation.x, accuracy: Float(0.001))
            XCTAssertEqual(hips.y, translation.y, accuracy: Float(0.001))
            XCTAssertEqual(hips.z, translation.z, accuracy: Float(0.001))
        }
    }
    
    func testSetHipsTranslationMultipleTimes() {
        // Set multiple positions
        let positions: [SIMD3<Float>] = [
            SIMD3<Float>(0, 0, 0),
            SIMD3<Float>(1, 0, 0),
            SIMD3<Float>(1, 1, 0),
            SIMD3<Float>(1, 1, 1),
        ]
        
        for position in positions {
            model.setHipsTranslation(position)
            if let current = model.getHipsTranslation() {
                XCTAssertEqual(current.x, position.x, accuracy: Float(0.001))
                XCTAssertEqual(current.y, position.y, accuracy: Float(0.001))
                XCTAssertEqual(current.z, position.z, accuracy: Float(0.001))
            }
        }
    }
    
    func testSetHipsTranslationForRootMotion() {
        // Simulate a walking motion
        let walkCycle: [SIMD3<Float>] = [
            SIMD3<Float>(0, 0, 0),
            SIMD3<Float>(0, 0, 0.25),
            SIMD3<Float>(0, 0, 0.5),
            SIMD3<Float>(0, 0, 0.75),
            SIMD3<Float>(0, 0, 1.0),
        ]
        
        for position in walkCycle {
            model.setHipsTranslation(position)
        }
        
        // Final position should be 1.0 forward
        if let final = model.getHipsTranslation() {
            XCTAssertEqual(final.z, 1.0, accuracy: Float(0.001))
        }
    }
    
    // MARK: - getHipsTranslation Tests
    
    func testGetHipsTranslation() throws {
        // Should return hips position
        let hipsPos = model.getHipsTranslation()
        XCTAssertNotNil(hipsPos)
        
        // Default hips position in a humanoid is typically at some height
        if let pos = hipsPos {
            // Y should be positive (above ground)
            XCTAssertGreaterThan(pos.y, 0)
        }
    }
    
    // MARK: - Combined Tests
    
    func testRotationAndTranslationCombined() {
        // Set hips translation (root motion)
        model.setHipsTranslation(SIMD3<Float>(0, 1, 0))
        
        // Set head rotation (looking up)
        let headRotation = simd_quatf(angle: -Float.pi / 6, axis: SIMD3<Float>(1, 0, 0))
        model.setLocalRotation(headRotation, for: .head)
        
        // Set arm rotation (waving)
        let armRotation = simd_quatf(angle: Float.pi / 3, axis: SIMD3<Float>(0, 0, 1))
        model.setLocalRotation(armRotation, for: .rightUpperArm)
        
        // Verify all
        if let hipsTranslation = model.getHipsTranslation() {
            XCTAssertEqual(hipsTranslation.y, 1.0, accuracy: Float(0.001))
        }
        XCTAssertNotNil(model.getLocalRotation(for: .head))
        XCTAssertNotNil(model.getLocalRotation(for: .rightUpperArm))
    }
    
    func testThreadSafety() {
        // Test that concurrent access doesn't crash
        let expectation = XCTestExpectation(description: "Concurrent access")
        expectation.expectedFulfillmentCount = 2
        
        DispatchQueue.global().async {
            for i in 0..<100 {
                let rotation = simd_quatf(angle: Float(i) * 0.01, axis: SIMD3<Float>(0, 1, 0))
                self.model.setLocalRotation(rotation, for: .head)
            }
            expectation.fulfill()
        }
        
        DispatchQueue.global().async {
            for i in 0..<100 {
                let translation = SIMD3<Float>(Float(i) * 0.01, 0, 0)
                self.model.setHipsTranslation(translation)
            }
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: 5.0)
        
        // Small delay to ensure async operations complete
        Thread.sleep(forTimeInterval: 0.1)
        
        // Verify model is in a valid state
        XCTAssertNotNil(model.getLocalRotation(for: .head))
        XCTAssertNotNil(model.getHipsTranslation())
    }
    
    // MARK: - Edge Cases
    
    func testSetZeroRotation() {
        let identity = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        model.setLocalRotation(identity, for: .head)
        
        if let rotation = model.getLocalRotation(for: .head) {
            assertQuaternionIsIdentity(rotation, tolerance: 0.001)
        }
    }
    
    func testSetZeroTranslation() {
        model.setHipsTranslation(SIMD3<Float>(0, 0, 0))
        
        if let translation = model.getHipsTranslation() {
            XCTAssertEqual(translation.x, 0, accuracy: Float(0.001))
            XCTAssertEqual(translation.y, 0, accuracy: Float(0.001))
            XCTAssertEqual(translation.z, 0, accuracy: Float(0.001))
        }
    }
    
    func testLargeTranslationValues() {
        let largeTranslation = SIMD3<Float>(1000, 2000, 3000)
        model.setHipsTranslation(largeTranslation)
        
        if let translation = model.getHipsTranslation() {
            XCTAssertEqual(translation.x, 1000, accuracy: Float(0.001))
            XCTAssertEqual(translation.y, 2000, accuracy: Float(0.001))
            XCTAssertEqual(translation.z, 3000, accuracy: Float(0.001))
        }
    }
}
