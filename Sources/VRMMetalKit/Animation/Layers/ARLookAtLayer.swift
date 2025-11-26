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

import Foundation
import simd

/// AR look-at layer that tracks the camera position with head, neck, and eyes
public class ARLookAtLayer: AnimationLayer {
    public let identifier = "ar.lookat"
    public let priority = 2
    public var isEnabled = true

    public var affectedBones: Set<VRMHumanoidBone> {
        [.head, .neck, .leftEye, .rightEye]
    }

    // MARK: - Distribution Parameters

    /// Contribution of head rotation to total look direction (0-1)
    public var headContribution: Float = 0.7

    /// Contribution of neck rotation to total look direction (0-1)
    public var neckContribution: Float = 0.2

    /// Contribution of eye rotation to total look direction (0-1)
    public var eyeContribution: Float = 0.1

    // MARK: - Constraint Parameters (radians)

    /// Maximum horizontal rotation (yaw) in radians (default ±60°)
    public var maxYaw: Float = 60 * .pi / 180

    /// Maximum vertical rotation (pitch) in radians (default ±30°)
    public var maxPitch: Float = 30 * .pi / 180

    // MARK: - Smoothing Parameters

    /// Smoothing factor (0 = instant, lower = smoother)
    public var smoothingFactor: Float = 0.1

    // MARK: - Saccade Parameters

    /// Enable micro eye movements for realism
    public var saccadeEnabled = true

    /// Intensity of saccade movements (radians)
    public var saccadeIntensity: Float = 0.02

    // MARK: - Head Position Offset

    /// Offset from avatar position to head position (Y is up)
    public var headOffset: SIMD3<Float> = SIMD3<Float>(0, 1.5, 0)

    // MARK: - Private State

    private var currentYaw: Float = 0
    private var currentPitch: Float = 0
    private var saccadeOffset = SIMD2<Float>.zero
    private var saccadeTimer: Float = 0
    private var nextSaccadeTime: Float = 1.5

    // Pre-allocated output
    private var cachedOutput = LayerOutput(blendMode: .blend(1.0))

    // MARK: - Initialization

    public init() {
        // Pre-populate affected bones
        for bone in affectedBones {
            cachedOutput.bones[bone] = .identity
        }
    }

    // MARK: - AnimationLayer Protocol

    public func update(deltaTime: Float, context: AnimationContext) {
        // Calculate head world position
        let headPosition = context.avatarPosition + headOffset

        // Calculate direction to camera
        let lookDir = context.cameraPosition - headPosition
        let distance = simd_length(lookDir)

        // Skip if camera is too close (avoid singularity)
        guard distance > 0.1 else { return }

        let normalizedDir = lookDir / distance

        // Calculate target angles
        var targetYaw = atan2(normalizedDir.x, normalizedDir.z)
        var targetPitch = asin(clamp(normalizedDir.y, -1, 1))

        // Apply constraints
        targetYaw = clamp(targetYaw, -maxYaw, maxYaw)
        targetPitch = clamp(targetPitch, -maxPitch, maxPitch)

        // Smooth interpolation toward target
        currentYaw += (targetYaw - currentYaw) * smoothingFactor
        currentPitch += (targetPitch - currentPitch) * smoothingFactor

        // Update saccades
        if saccadeEnabled {
            updateSaccade(deltaTime: deltaTime)
        }
    }

    public func evaluate() -> LayerOutput {
        // Head rotation (primary contribution)
        let headYaw = currentYaw * headContribution
        let headPitch = currentPitch * headContribution
        let headRotY = simd_quatf(angle: headYaw, axis: SIMD3<Float>(0, 1, 0))
        let headRotX = simd_quatf(angle: headPitch, axis: SIMD3<Float>(1, 0, 0))

        var headTransform = ProceduralBoneTransform.identity
        headTransform.rotation = simd_mul(headRotY, headRotX)
        cachedOutput.bones[.head] = headTransform

        // Neck rotation (secondary contribution)
        let neckYaw = currentYaw * neckContribution
        let neckPitch = currentPitch * neckContribution
        let neckRotY = simd_quatf(angle: neckYaw, axis: SIMD3<Float>(0, 1, 0))
        let neckRotX = simd_quatf(angle: neckPitch, axis: SIMD3<Float>(1, 0, 0))

        var neckTransform = ProceduralBoneTransform.identity
        neckTransform.rotation = simd_mul(neckRotY, neckRotX)
        cachedOutput.bones[.neck] = neckTransform

        // Eye rotation (fine detail + saccades)
        let eyeYaw = currentYaw * eyeContribution + saccadeOffset.x
        let eyePitch = currentPitch * eyeContribution + saccadeOffset.y
        let eyeRotY = simd_quatf(angle: eyeYaw, axis: SIMD3<Float>(0, 1, 0))
        let eyeRotX = simd_quatf(angle: eyePitch, axis: SIMD3<Float>(1, 0, 0))
        let eyeRot = simd_mul(eyeRotY, eyeRotX)

        var leftEyeTransform = ProceduralBoneTransform.identity
        leftEyeTransform.rotation = eyeRot
        cachedOutput.bones[.leftEye] = leftEyeTransform

        var rightEyeTransform = ProceduralBoneTransform.identity
        rightEyeTransform.rotation = eyeRot
        cachedOutput.bones[.rightEye] = rightEyeTransform

        return cachedOutput
    }

    // MARK: - Private Methods

    private func updateSaccade(deltaTime: Float) {
        saccadeTimer += deltaTime

        if saccadeTimer >= nextSaccadeTime {
            // Generate new random saccade offset
            saccadeOffset = SIMD2<Float>(
                Float.random(in: -saccadeIntensity...saccadeIntensity),
                Float.random(in: -saccadeIntensity * 0.5...saccadeIntensity * 0.5)
            )
            saccadeTimer = 0
            nextSaccadeTime = Float.random(in: 1.0...3.0)
        }

        // Decay saccade offset smoothly
        saccadeOffset *= 0.95
    }

    private func clamp(_ value: Float, _ minVal: Float, _ maxVal: Float) -> Float {
        max(minVal, min(maxVal, value))
    }
}
