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

/// Phase 3: Animation Layering & Blending Tests
///
/// 🔴 RED Tests for advanced animation features:
/// - Multiple animation layers
/// - Cross-fade between animations
/// - Animation blending weights
/// - Additive animations
final class AnimationLayeringTests: XCTestCase {
    
    // MARK: - Test Setup
    
    private var device: MTLDevice!
    private var model: VRMModel!
    
    override func setUp() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        self.device = device
        
        // Build test model
        let vrmDocument = try VRMBuilder()
            .setSkeleton(.defaultHumanoid)
            .addExpressions([.happy, .sad, .neutral])
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
    
    // MARK: - Multiple Animation Layers
    
    /// 🔴 RED: Multiple animation layers
    ///
    /// Base layer + additive layer should combine correctly.
    func testMultipleAnimationLayers() throws {
        // Arrange: Base animation (idle pose)
        var baseClip = AnimationClip(duration: 1.0)
        baseClip.addEulerTrack(bone: .hips, axis: .y) { _ in 0 }
        
        // Additive animation (wave)
        var additiveClip = AnimationClip(duration: 1.0)
        additiveClip.addEulerTrack(bone: .leftUpperArm, axis: .z) { time in
            sin(time * Float.pi * 2) * 0.5  // Wave motion
        }
        
        let player = AnimationPlayer()
        
        // Act: Load base layer
        player.load(baseClip)
        player.update(deltaTime: 0, model: model)
        
        guard let humanoid = model.humanoid,
              let leftArmIndex = humanoid.getBoneNode(.leftUpperArm) else {
            XCTFail("Model should have left upper arm")
            return
        }
        
        let baseRotation = model.nodes[leftArmIndex].rotation
        
        // Act: Add additive layer
        // TODO: This API doesn't exist yet - needs implementation
        // player.loadAdditive(additiveClip, layer: 1, weight: 1.0)
        // player.update(deltaTime: 0.25, model: model)
        
        // Assert: Left arm should have moved
        // let combinedRotation = model.nodes[leftArmIndex].rotation
        // XCTAssertNotEqual(combinedRotation, baseRotation, "Additive layer should affect rotation")
        
        // Placeholder assertion until layering is implemented
        throw XCTSkip("Layering not yet implemented")
    }
    
    /// 🔴 RED: Base layer + additive layer combination
    func testBasePlusAdditiveLayer() throws {
        // Create base pose (standing)
        let baseClip = createIdleAnimation()
        
        // Create additive pose (breathing)
        let breathingClip = createBreathingAnimation()
        
        // Apply both
        let player = AnimationPlayer()
        player.load(baseClip)
        
        // TODO: player.setAdditiveLayer(breathingClip, weight: 0.5)
        
        // Should combine both animations
        throw XCTSkip("Base + additive not yet implemented")
    }
    
    /// 🔴 RED: Layer priority/order
    func testLayerPriority() throws {
        // Higher priority layers should override lower priority
        // when affecting the same bones
        
        // TODO: Implement layer priority system
        throw XCTSkip("Layer priority not yet implemented")
    }
    
    // MARK: - Cross-Fade Tests
    
    /// 🔴 RED: Cross-fade between animations
    ///
    /// Smooth transition from clip A to clip B over time.
    func testCrossFadeBetweenAnimations() throws {
        // Arrange: Two different animations
        var clipA = AnimationClip(duration: 2.0)
        clipA.addEulerTrack(bone: .hips, axis: .y) { _ in Float.pi / 4 }  // 45°
        
        var clipB = AnimationClip(duration: 2.0)
        clipB.addEulerTrack(bone: .hips, axis: .y) { _ in -Float.pi / 4 } // -45°
        
        let player = AnimationPlayer()
        player.load(clipA)
        
        // Act: Start cross-fade to clip B
        // TODO: player.crossFade(to: clipB, duration: 0.5)
        
        // Sample at middle of cross-fade
        // player.update(deltaTime: 0.25, model: model)
        
        // Assert: Should be approximately 0° (halfway between 45° and -45°)
        guard let humanoid = model.humanoid,
              let hipsIndex = humanoid.getBoneNode(.hips) else {
            XCTFail("Model should have hips")
            return
        }
        
        // TODO: Implement and verify
        // let midRotation = model.nodes[hipsIndex].rotation
        // let angle = extractAngle(midRotation)
        // XCTAssertEqual(angle, 0, accuracy: 0.1, "Mid cross-fade should be ~0°")
        
        throw XCTSkip("Cross-fade not yet implemented")
    }
    
    /// 🔴 RED: Cross-fade timing
    func testCrossFadeTiming() throws {
        // Cross-fade should complete in specified duration
        // TODO: Implement cross-fade timing tests
        throw XCTSkip("Cross-fade timing not yet implemented")
    }
    
    /// 🔴 RED: Cross-fade interruption
    func testCrossFadeInterruption() throws {
        // Starting a new cross-fade during an ongoing one should handle gracefully
        // TODO: Implement interruption test
        throw XCTSkip("Cross-fade interruption not yet implemented")
    }
    
    // MARK: - Blending Weights
    
    /// 🔴 RED: Animation blending weights
    ///
    /// Layer weights affect final pose contribution.
    func testAnimationBlendingWeights() throws {
        // Arrange: Two animations affecting same bone
        var clipA = AnimationClip(duration: 1.0)
        clipA.addEulerTrack(bone: .head, axis: .y) { _ in Float.pi / 6 }  // 30° left
        
        var clipB = AnimationClip(duration: 1.0)
        clipB.addEulerTrack(bone: .head, axis: .y) { _ in -Float.pi / 6 } // 30° right
        
        // Act: Blend with different weights
        // TODO: player.blend(clipA: clipA, clipB: clipB, weight: 0.5)
        
        // Assert: At 50/50, should be 0°
        // At 75/25, should be 15°
        // At 25/75, should be -15°
        
        throw XCTSkip("Blending weights not yet implemented")
    }
    
    /// 🔴 RED: Weight of 0 means no contribution
    func testZeroWeightNoContribution() throws {
        // Layer with weight 0 should not affect output
        throw XCTSkip("Zero weight not yet implemented")
    }
    
    /// 🔴 RED: Weight of 1 means full contribution
    func testFullWeightContribution() throws {
        // Layer with weight 1 should fully apply
        throw XCTSkip("Full weight not yet implemented")
    }
    
    /// 🔴 RED: Weight changes over time
    func testWeightAnimation() throws {
        // Weights should be animatable for fade in/out effects
        throw XCTSkip("Weight animation not yet implemented")
    }
    
    // MARK: - Additive Animation Tests
    
    /// 🔴 RED: Additive animation on top of base
    func testAdditiveAnimation() throws {
        // Additive animations add delta to base pose
        // rather than replacing it
        throw XCTSkip("Additive animation not yet implemented")
    }
    
    /// 🔴 RED: Multiple additive layers
    func testMultipleAdditiveLayers() throws {
        // Should support multiple additive layers
        // (e.g., breathing + fidgeting + recoil)
        throw XCTSkip("Multiple additive not yet implemented")
    }
    
    // MARK: - Masking Tests
    
    /// 🔴 RED: Animation masking
    ///
    /// Masks allow partial application of animations.
    func testAnimationMasking() throws {
        // Apply animation only to upper body
        // Lower body continues with base animation
        throw XCTSkip("Animation masking not yet implemented")
    }
    
    /// 🔴 RED: Bone-specific masking
    func testBoneSpecificMasking() throws {
        // Mask specific bones from animation
        throw XCTSkip("Bone masking not yet implemented")
    }
    
    // MARK: - Helper Methods
    
    private func createIdleAnimation() -> AnimationClip {
        var clip = AnimationClip(duration: 2.0)
        // Subtle breathing motion
        clip.addEulerTrack(bone: .chest, axis: .x) { time in
            sin(time * Float.pi) * 0.05
        }
        return clip
    }
    
    private func createBreathingAnimation() -> AnimationClip {
        var clip = AnimationClip(duration: 3.0)
        clip.addEulerTrack(bone: .chest, axis: .x) { time in
            sin(time * Float.pi * 2 / 3) * 0.1
        }
        return clip
    }
    
    private func extractAngle(_ quat: simd_quatf) -> Float {
        return 2 * acos(min(1, abs(quat.real)))
    }
}

// MARK: - AnimationLayerSpec (Future Implementation)

/// Represents a planned animation layer for blending
/// 🔴 RED: This class needs to be implemented
public struct AnimationLayerSpec {
    let name: String
    let clip: AnimationClip
    let weight: Float
    let isAdditive: Bool
    let mask: AnimationMask?
}

/// Animation mask for selective application
/// 🔴 RED: This needs to be implemented
public struct AnimationMask {
    let includedBones: Set<VRMHumanoidBone>
    
    func contains(_ bone: VRMHumanoidBone) -> Bool {
        return includedBones.contains(bone)
    }
}
