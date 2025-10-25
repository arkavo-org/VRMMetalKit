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

// MARK: - LookAt Target Types

public enum VRMLookAtTarget {
    case camera                         // Look at the camera/viewer
    case user                          // Look at predefined user position
    case point(SIMD3<Float>)          // Look at specific world point
    case forward                       // Look straight ahead (rest position)
}

// MARK: - LookAt Controller

public class VRMLookAtController {
    // Configuration
    public var enabled: Bool = true
    public var mode: VRMLookAtType = .bone
    public var target: VRMLookAtTarget = .forward

    // Model references
    private weak var model: VRMModel?
    private var lookAtData: VRMLookAt?
    private weak var expressionController: VRMExpressionController?

    // Eye bone indices
    private var leftEyeBoneIndex: Int?
    private var rightEyeBoneIndex: Int?
    private var headBoneIndex: Int?

    // Current state
    private var currentYaw: Float = 0      // Horizontal rotation (radians)
    private var currentPitch: Float = 0    // Vertical rotation (radians)
    private var targetYaw: Float = 0
    private var targetPitch: Float = 0

    // Smoothing parameters
    public var smoothing: Float = 0.1      // 0 = instant, 1 = very smooth
    public var saccadeEnabled: Bool = true
    private var saccadeTimer: Float = 0
    private var nextSaccadeTime: Float = 2.0
    private var saccadeOffset = SIMD2<Float>(0, 0)

    // State machine support
    public enum State {
        case idle
        case listening
        case thinking
        case speaking
    }
    public var state: State = .idle

    // Camera reference for .camera target
    public var cameraPosition: SIMD3<Float> = [0, 1.6, 2.5]
    public var userPosition: SIMD3<Float> = [0, 1.6, 2.0]

    // MARK: - Initialization

    public init() {}

    public func setup(model: VRMModel, expressionController: VRMExpressionController? = nil) {
        self.model = model
        self.lookAtData = model.lookAt
        self.expressionController = expressionController

        // Find eye bone indices
        if let humanoid = model.humanoid {
            leftEyeBoneIndex = humanoid.humanBones[.leftEye]?.node
            rightEyeBoneIndex = humanoid.humanBones[.rightEye]?.node
            headBoneIndex = humanoid.humanBones[.head]?.node

            vrmLog("[VRMLookAtController] Initialized with bones:")
            vrmLog("  - Head: \(headBoneIndex != nil ? "node \(headBoneIndex!)" : "not found")")
            vrmLog("  - Left eye: \(leftEyeBoneIndex != nil ? "node \(leftEyeBoneIndex!)" : "not found")")
            vrmLog("  - Right eye: \(rightEyeBoneIndex != nil ? "node \(rightEyeBoneIndex!)" : "not found")")

            // DEBUG: Check if eye nodes are skinned or rigid
            if let leftIndex = leftEyeBoneIndex {
                let leftNode = model.nodes[leftIndex]
                vrmLog("  - Left eye node name: \(leftNode.name ?? "unnamed")")
                vrmLog("    Has mesh: \(leftNode.mesh != nil)")
                vrmLog("    Has skin: \(leftNode.skin != nil)")

                // Check if any skin includes this node as a joint
                var foundInSkin = false
                for (skinIdx, skin) in model.skins.enumerated() {
                    // Check if this node is in the joints array
                    for (jointIdx, jointNode) in skin.joints.enumerated() {
                        if jointNode === leftNode {  // Use identity check
                            vrmLog("    Found in skin \(skinIdx) as joint index \(jointIdx)")
                            foundInSkin = true

                            // Check which mesh uses this skin
                            for (nodeIdx, node) in model.nodes.enumerated() {
                                if node.skin == skinIdx {
                                    vrmLog("    Skin \(skinIdx) is used by node \(nodeIdx): \(node.name ?? "unnamed")")
                                    if let meshIdx = node.mesh {
                                        vrmLog("      Which has mesh \(meshIdx)")
                                    }
                                }
                            }
                            break
                        }
                    }
                }
                if !foundInSkin {
                    vrmLog("    WARNING: Left eye node NOT found in any skin joints!")
                    vrmLog("    This means the eye might be a rigid mesh or uses expressions")

                    // Check if there's an eye mesh directly attached
                    if let meshIdx = leftNode.mesh {
                        vrmLog("    Eye has its own mesh \(meshIdx) - likely a rigid eyeball")
                    }
                }
            }

            if let rightIndex = rightEyeBoneIndex {
                let rightNode = model.nodes[rightIndex]
                vrmLog("  - Right eye node name: \(rightNode.name ?? "unnamed")")
                vrmLog("    Has mesh: \(rightNode.mesh != nil)")
                vrmLog("    Has skin: \(rightNode.skin != nil)")

                // Check if any skin includes this node as a joint
                var foundInSkin = false
                for (skinIdx, skin) in model.skins.enumerated() {
                    // Check if this node is in the joints array
                    for (jointIdx, jointNode) in skin.joints.enumerated() {
                        if jointNode === rightNode {  // Use identity check
                            vrmLog("    Found in skin \(skinIdx) as joint index \(jointIdx)")
                            foundInSkin = true
                            break
                        }
                    }
                }
                if !foundInSkin {
                    vrmLog("    WARNING: Right eye node NOT found in any skin joints!")
                }
            }
        }

        // Auto-detect the best mode based on what's available
        var eyesAreRigid = false
        var eyesHaveExpressions = false

        // Check if eye nodes have their own meshes (rigid eyeballs)
        if let leftIdx = leftEyeBoneIndex, model.nodes[leftIdx].mesh != nil {
            eyesAreRigid = true
        }
        if let rightIdx = rightEyeBoneIndex, model.nodes[rightIdx].mesh != nil {
            eyesAreRigid = true
        }

        // Check if we have LookAt expressions - with detailed diagnostics
        if let expressions = model.expressions {
            vrmLog("[VRMLookAtController] Expression diagnostics:")
            vrmLog("  - Total custom expressions: \(expressions.custom.count)")
            for (name, expr) in expressions.custom {
                vrmLog("    Custom '\(name)': \(expr.morphTargetBinds.count) binds")
            }

            // Check if LookAt expressions have actual morph target binds
            var workingLookAtExpressions = 0
            if let left = expressions.custom["LookLeft"], !left.morphTargetBinds.isEmpty {
                workingLookAtExpressions += 1
                vrmLog("    LookLeft: \(left.morphTargetBinds.count) binds ✅")
            } else if expressions.custom["LookLeft"] != nil {
                vrmLog("    LookLeft: 0 binds ❌ (empty)")
            }

            if let right = expressions.custom["LookRight"], !right.morphTargetBinds.isEmpty {
                workingLookAtExpressions += 1
                vrmLog("    LookRight: \(right.morphTargetBinds.count) binds ✅")
            } else if expressions.custom["LookRight"] != nil {
                vrmLog("    LookRight: 0 binds ❌ (empty)")
            }

            if let up = expressions.custom["LookUp"], !up.morphTargetBinds.isEmpty {
                workingLookAtExpressions += 1
                vrmLog("    LookUp: \(up.morphTargetBinds.count) binds ✅")
            } else if expressions.custom["LookUp"] != nil {
                vrmLog("    LookUp: 0 binds ❌ (empty)")
            }

            if let down = expressions.custom["LookDown"], !down.morphTargetBinds.isEmpty {
                workingLookAtExpressions += 1
                vrmLog("    LookDown: \(down.morphTargetBinds.count) binds ✅")
            } else if expressions.custom["LookDown"] != nil {
                vrmLog("    LookDown: 0 binds ❌ (empty)")
            }

            if workingLookAtExpressions > 0 {
                eyesHaveExpressions = true
                vrmLog("[VRMLookAtController] ✅ Found \(workingLookAtExpressions) working LookAt expressions")
            } else {
                vrmLog("[VRMLookAtController] ❌ NO working LookAt expressions (all empty or missing)")
            }
        } else {
            vrmLog("[VRMLookAtController] ❌ NO expressions object found")
        }

        // Set mode based on available data
        // OVERRIDE: Force expression mode for Alicia since bones don't affect the eye mesh
        if eyesHaveExpressions {
            mode = .expression
            vrmLog("[VRMLookAtController] Using EXPRESSION mode (LookAt expressions available)")
        } else if eyesAreRigid {
            // Eyes are rigid meshes, can't use bone mode
            mode = .bone  // Try bone mode anyway, but it likely won't work
            vrmLog("[VRMLookAtController] Using BONE mode (but eyes are rigid - may not work!)")
        } else if lookAtData?.type == .expression || (leftEyeBoneIndex == nil && rightEyeBoneIndex == nil) {
            mode = .expression
            vrmLog("[VRMLookAtController] Using EXPRESSION mode (per VRM data or no eye bones)")
        } else {
            mode = .bone
            vrmLog("[VRMLookAtController] Using BONE mode (eyes should be skinned)")
        }
    }

    // MARK: - Update

    private var debugFrameCount = 0

    public func update(deltaTime: Float) {
        guard enabled, let _ = model else { return }

        // Calculate target angles based on target type
        updateTargetAngles()

        // Add saccades if enabled
        if saccadeEnabled {
            updateSaccades(deltaTime: deltaTime)
        }

        // Smooth towards target
        let smoothFactor = 1.0 - pow(smoothing, deltaTime * 60.0) // Frame-rate independent
        currentYaw = lerp(currentYaw, targetYaw + saccadeOffset.x, smoothFactor)
        currentPitch = lerp(currentPitch, targetPitch + saccadeOffset.y, smoothFactor)

        // DEBUG: Log current state (throttled to every 60 frames)
        debugFrameCount += 1
        if debugFrameCount % 60 == 0 {
            let yawDeg = currentYaw * 180.0 / .pi
            let pitchDeg = currentPitch * 180.0 / .pi
            vrmLog("[LookAt DEBUG] enabled=\(enabled) mode=\(mode) yaw=\(yawDeg)° pitch=\(pitchDeg)° L=\(leftEyeBoneIndex ?? -1) R=\(rightEyeBoneIndex ?? -1)")
        }

        // Apply constraints from VRM data
        applyConstraints()

        // Apply to model based on mode
        if mode == .bone {
            applyToBones()
        } else {
            applyToExpressions()
        }
    }

    // MARK: - Target Calculation

    private func updateTargetAngles() {
        guard let model = model else { return }

        // Get target position based on target type
        let targetPos: SIMD3<Float>
        switch target {
        case .camera:
            targetPos = cameraPosition
        case .user:
            targetPos = userPosition
        case .point(let pos):
            targetPos = pos
        case .forward:
            targetYaw = 0
            targetPitch = 0
            return
        }

        // Get eye position (approximate from head bone or model center)
        var eyePosition = SIMD3<Float>(0, 1.5, 0) // Default eye height

        if let headIndex = headBoneIndex, headIndex < model.nodes.count {
            let headNode = model.nodes[headIndex]
            eyePosition = SIMD3<Float>(
                headNode.worldMatrix[3][0],
                headNode.worldMatrix[3][1],
                headNode.worldMatrix[3][2]
            )

            // Apply offset from head bone if specified
            if let lookAt = lookAtData {
                eyePosition += lookAt.offsetFromHeadBone
            }
        }

        // Calculate direction vector
        let direction = normalize(targetPos - eyePosition)

        // Convert to yaw/pitch angles
        // Yaw: rotation around Y axis (horizontal)
        targetYaw = atan2(direction.x, direction.z)

        // Pitch: rotation around X axis (vertical)
        targetPitch = asin(clamp(direction.y, min: -1, max: 1))

        // Apply state-based modifications
        switch state {
        case .thinking:
            // Look up and away when thinking
            targetPitch += 0.2
            targetYaw *= 0.5
        case .speaking:
            // Focus more directly when speaking
            targetYaw *= 0.9
            targetPitch *= 0.9
        case .listening:
            // Softer tracking when listening
            targetYaw *= 0.7
            targetPitch *= 0.7
        case .idle:
            // Normal tracking
            break
        }
    }

    // MARK: - Constraints

    private func applyConstraints() {
        guard let lookAt = lookAtData else { return }

        // Apply horizontal constraints
        if currentYaw > 0 {
            // Looking right (outer)
            let maxAngle = lookAt.rangeMapHorizontalOuter.inputMaxValue * (.pi / 180)
            currentYaw = min(currentYaw, maxAngle)
        } else {
            // Looking left (inner)
            let maxAngle = lookAt.rangeMapHorizontalInner.inputMaxValue * (.pi / 180)
            currentYaw = max(currentYaw, -maxAngle)
        }

        // Apply vertical constraints
        if currentPitch > 0 {
            // Looking up
            let maxAngle = lookAt.rangeMapVerticalUp.inputMaxValue * (.pi / 180)
            currentPitch = min(currentPitch, maxAngle)
        } else {
            // Looking down
            let maxAngle = lookAt.rangeMapVerticalDown.inputMaxValue * (.pi / 180)
            currentPitch = max(currentPitch, -maxAngle)
        }
    }

    // MARK: - Bone Application

    private func applyToBones() {
        guard let model = model else { return }

        // FORCE TEST: Apply a big rotation to test if bones are connected

        // Apply to left eye
        if let leftIndex = leftEyeBoneIndex, leftIndex < model.nodes.count {
            let node = model.nodes[leftIndex]

            if false {
                // Force a big 30 degree rotation to test
                node.rotation = simd_quatf(angle: .pi / 6, axis: [0, 1, 0])
                vrmLog("[LookAt FORCE TEST] Left eye forced to 30° yaw")
            } else {
                // Create rotation quaternion for eye
                let yawQuat = simd_quatf(angle: currentYaw * 0.5, axis: [0, 1, 0])
                let pitchQuat = simd_quatf(angle: currentPitch * 0.5, axis: [1, 0, 0])
                let rotation = yawQuat * pitchQuat

                // Apply to node's local transform
                node.rotation = rotation

                // DEBUG: Log what we're applying (throttled)
                if debugFrameCount % 60 == 0 {
                    let eulerYaw = currentYaw * 0.5 * 180.0 / .pi
                    let eulerPitch = currentPitch * 0.5 * 180.0 / .pi
                    vrmLog("[LookAt BONE] Left eye node \(leftIndex) rotation: yaw=\(eulerYaw)° pitch=\(eulerPitch)°")
                }
            }

            // Ensure transforms are updated
            node.updateLocalMatrix()
            node.updateWorldTransform()
        }

        // Apply to right eye
        if let rightIndex = rightEyeBoneIndex, rightIndex < model.nodes.count {
            let node = model.nodes[rightIndex]

            if false {
                // Force a big 30 degree rotation to test
                node.rotation = simd_quatf(angle: .pi / 6, axis: [0, 1, 0])
                vrmLog("[LookAt FORCE TEST] Right eye forced to 30° yaw")
            } else {
                // Create rotation quaternion for eye
                let yawQuat = simd_quatf(angle: currentYaw * 0.5, axis: [0, 1, 0])
                let pitchQuat = simd_quatf(angle: currentPitch * 0.5, axis: [1, 0, 0])
                let rotation = yawQuat * pitchQuat

                // Apply to node's local transform
                node.rotation = rotation

                // DEBUG: Log what we're applying (throttled)
                if debugFrameCount % 60 == 0 {
                    let eulerYaw = currentYaw * 0.5 * 180.0 / .pi
                    let eulerPitch = currentPitch * 0.5 * 180.0 / .pi
                    vrmLog("[LookAt BONE] Right eye node \(rightIndex) rotation: yaw=\(eulerYaw)° pitch=\(eulerPitch)°")
                }
            }

            // Ensure transforms are updated
            node.updateLocalMatrix()
            node.updateWorldTransform()
        }

        // Mark skeleton as needing update
        model.updateNodeTransforms()
    }

    // MARK: - Expression Application

    private func applyToExpressions() {
        guard model != nil else { return }

        // Only reset LookAt expressions, don't interfere with other expressions
        // The expression controller should handle blending properly

        // Map angles to expression weights
        // Only apply LookAt expressions, let other expressions work normally

        // Reset LookAt expressions to 0 first
        expressionController?.setCustomExpressionWeight("LookLeft", weight: 0)
        expressionController?.setCustomExpressionWeight("LookRight", weight: 0)
        expressionController?.setCustomExpressionWeight("LookUp", weight: 0)
        expressionController?.setCustomExpressionWeight("LookDown", weight: 0)

        // Horizontal expressions - only if significant angle
        if abs(currentYaw) > 0.02 { // Increased threshold to reduce jitter
            if currentYaw > 0 {
                // Looking right
                let weight = min(abs(currentYaw) / (.pi / 4), 1.0) // Normalize to 45 degrees max
                expressionController?.setCustomExpressionWeight("LookRight", weight: weight)

                // DEBUG
                if debugFrameCount % 60 == 0 {
                    vrmLog("[LookAt EXPRESSION] LookRight weight: \(weight)")
                }
            } else {
                // Looking left
                let weight = min(abs(currentYaw) / (.pi / 4), 1.0)
                expressionController?.setCustomExpressionWeight("LookLeft", weight: weight)

                // DEBUG
                if debugFrameCount % 60 == 0 {
                    vrmLog("[LookAt EXPRESSION] LookLeft weight: \(weight)")
                }
            }
        }

        // Vertical expressions - only if significant angle
        if abs(currentPitch) > 0.02 { // Increased threshold to reduce jitter
            if currentPitch > 0 {
                // Looking up
                let weight = min(abs(currentPitch) / (.pi / 6), 1.0) // Normalize to 30 degrees max
                expressionController?.setCustomExpressionWeight("LookUp", weight: weight)

                // DEBUG
                if debugFrameCount % 60 == 0 {
                    vrmLog("[LookAt EXPRESSION] LookUp weight: \(weight)")
                }
            } else {
                // Looking down
                let weight = min(abs(currentPitch) / (.pi / 6), 1.0)
                expressionController?.setCustomExpressionWeight("LookDown", weight: weight)

                // DEBUG
                if debugFrameCount % 60 == 0 {
                    vrmLog("[LookAt EXPRESSION] LookDown weight: \(weight)")
                }
            }
        }
    }

    // MARK: - Saccades

    private func updateSaccades(deltaTime: Float) {
        saccadeTimer += deltaTime

        if saccadeTimer >= nextSaccadeTime {
            // Generate new saccade
            let intensity: Float = state == .speaking ? 0.002 : 0.005
            saccadeOffset = SIMD2<Float>(
                Float.random(in: -intensity...intensity),
                Float.random(in: -intensity...intensity)
            )

            // Schedule next saccade
            saccadeTimer = 0
            nextSaccadeTime = Float.random(in: 0.1...0.5)

            // Reduce frequency when speaking
            if state == .speaking {
                nextSaccadeTime *= 2
            }
        } else {
            // Decay saccade offset
            saccadeOffset *= 0.95
        }
    }

    // MARK: - Integration with Animation State

    public func applyToAnimationState(_ animationState: VRMAnimationState) {
        guard mode == .bone else { return }

        // Create eye rotation transforms
        let yawQuat = simd_quatf(angle: currentYaw * 0.5, axis: [0, 1, 0])
        let pitchQuat = simd_quatf(angle: currentPitch * 0.5, axis: [1, 0, 0])
        let eyeRotation = yawQuat * pitchQuat

        // Apply to animation state bones
        if leftEyeBoneIndex != nil {
            var transform = animationState.bones[.leftEye] ?? VRMAnimationState.BoneTransform()
            transform.rotation = eyeRotation
            animationState.bones[.leftEye] = transform
        }

        if rightEyeBoneIndex != nil {
            var transform = animationState.bones[.rightEye] ?? VRMAnimationState.BoneTransform()
            transform.rotation = eyeRotation
            animationState.bones[.rightEye] = transform
        }
    }

    // MARK: - Public API

    public func lookAt(_ target: VRMLookAtTarget, duration: Float? = nil) {
        self.target = target
        // Duration support could be added with a timer
    }

    public func reset() {
        target = .forward
        currentYaw = 0
        currentPitch = 0
        targetYaw = 0
        targetPitch = 0
        saccadeOffset = SIMD2<Float>(0, 0)
    }

    // MARK: - Utilities

    private func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float {
        return a + (b - a) * t
    }

    private func clamp(_ value: Float, min: Float, max: Float) -> Float {
        return Swift.min(Swift.max(value, min), max)
    }
}