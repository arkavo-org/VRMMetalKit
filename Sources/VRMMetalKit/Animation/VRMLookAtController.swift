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

/// What the avatar's eyes should track each frame.
public enum VRMLookAtTarget {
    /// Look at the camera position stored in ``VRMLookAtController/cameraPosition``.
    case camera
    /// Look at the user position stored in ``VRMLookAtController/userPosition``.
    case user
    /// Look at a specific world-space point.
    case point(SIMD3<Float>)
    /// Look at a point expressed in the head bone's local space.
    ///
    /// This matches the coordinate space defined by the
    /// [VRMC_vrm_animation-1.0 spec](https://github.com/vrm-c/vrm-specification/blob/master/specification/VRMC_vrm_animation-1.0/README.md)
    /// for `lookAt` tracks. The controller resolves it through the head bone's
    /// world transform at each ``update(deltaTime:)`` call, so callers do not
    /// need to recompose the value when the head moves.
    case headLocalPoint(SIMD3<Float>)
    /// Look straight ahead along the rest pose forward direction (no gaze deviation).
    case forward
}

// MARK: - LookAt Controller

/// Drives VRM 1.0 gaze: chooses bone vs. expression mode automatically, applies the spec's range maps, and produces frame-rate-independent smoothing and optional saccades.
///
/// ## Discussion
/// `VRMLookAtController` is the runtime owner of the avatar's gaze. After
/// ``setup(model:expressionController:)`` it inspects the model to pick a
/// drive mode:
/// - **Expression mode** when the model exposes working `LookLeft`,
///   `LookRight`, `LookUp`, or `LookDown` custom expressions.
/// - **Bone mode** when the eyes are skinned to dedicated eye bones.
/// - **Bone mode (degraded)** when the eyes are rigid meshes — the
///   controller still writes to the eye bones but bone motion may not
///   affect the rendered eyeballs.
///
/// Each frame, ``update(deltaTime:)`` converts ``target`` into yaw/pitch
/// at the head bone, smooths toward the target with a frame-rate-independent
/// damping curve, applies the model's range-map constraints, and writes
/// out via the chosen mode. The smoothing factor ``smoothing`` is the
/// damping exponent: `0` is instant, `1` is fully damped (no motion).
public class VRMLookAtController {
    // Configuration
    /// Master enable. When `false`, ``update(deltaTime:)`` is a no-op and the eyes hold their last values.
    public var enabled: Bool = true
    /// Drive mode selected automatically by ``setup(model:expressionController:)`` based on what the model exposes.
    public var mode: VRMLookAtType = .bone
    /// What the eyes should track. Defaults to ``VRMLookAtTarget/forward``.
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
    /// Frame-rate-independent damping factor in [0, 1]. `0` snaps to target each frame; values approaching `1` produce very slow tracking.
    public var smoothing: Float = 0.1
    /// Whether sub-degree micro-saccade jitter is added on top of smoothed yaw/pitch for liveliness.
    public var saccadeEnabled: Bool = true
    private var saccadeTimer: Float = 0
    private var nextSaccadeTime: Float = 2.0
    private var saccadeOffset = SIMD2<Float>(0, 0)

    /// Conversational state hints that bias gaze behaviour (e.g. `thinking` adds an upward look-away bias).
    public enum State {
        /// Default tracking with no behavioural bias.
        case idle
        /// Softer tracking: yaw and pitch are scaled down to 70 %.
        case listening
        /// Look-up-and-away bias: pitch +0.2 rad, yaw scaled to 50 %.
        case thinking
        /// Focused tracking: yaw and pitch scaled down to 90 % to feel more locked-in.
        case speaking
    }
    /// Current conversational state hint. See ``State`` for per-case bias.
    public var state: State = .idle

    /// World-space camera position used when ``target`` is ``VRMLookAtTarget/camera``.
    public var cameraPosition: SIMD3<Float> = [0, 1.6, 2.5]
    /// World-space user position used when ``target`` is ``VRMLookAtTarget/user``.
    public var userPosition: SIMD3<Float> = [0, 1.6, 2.0]

    // MARK: - Initialization

    /// Creates an unconfigured controller. Call ``setup(model:expressionController:)`` before the first ``update(deltaTime:)``.
    public init() {}

    /// Binds the controller to `model`, locates the head and eye bones, and auto-selects ``mode``.
    ///
    /// Picks expression mode when working `LookLeft`/`LookRight`/`LookUp`/`LookDown`
    /// custom expressions exist on the model; falls back to bone mode otherwise.
    /// `expressionController` is required when expression mode is selected.
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

        // Check if we have LookAt expressions - with detailed diagnostics.
        //
        // VMK#297: check both namespaces — the VRM 1.0 spec preset
        // namespace (`expressions.preset[.lookLeft]`, lowercase) and the
        // legacy VRM 0.x custom namespace
        // (`expressions.custom["LookLeft"]`, PascalCase). Either one
        // having non-empty morph binds counts as "expression mode is
        // available." Pre-fix the check was custom-only, so
        // spec-compliant VRM 1.0 assets fell through to bone-mode
        // detection or the no-eye-bones fallback (#297).
        if let expressions = model.expressions {
            vrmLog("[VRMLookAtController] Expression diagnostics:")
            vrmLog("  - Total custom expressions: \(expressions.custom.count)")
            for (name, expr) in expressions.custom {
                vrmLog("    Custom '\(name)': \(expr.morphTargetBinds.count) binds")
            }

            var workingLookAtExpressions = 0
            let lookPresets: [VRMExpressionPreset] = [.lookLeft, .lookRight, .lookUp, .lookDown]
            for preset in lookPresets {
                if let expr = expressions.preset[preset], !expr.morphTargetBinds.isEmpty {
                    workingLookAtExpressions += 1
                    vrmLog("    preset.\(preset): \(expr.morphTargetBinds.count) binds ✅")
                } else if expressions.preset[preset] != nil {
                    vrmLog("    preset.\(preset): 0 binds ❌ (empty)")
                }
            }
            for name in ["LookLeft", "LookRight", "LookUp", "LookDown"] {
                if let expr = expressions.custom[name], !expr.morphTargetBinds.isEmpty {
                    workingLookAtExpressions += 1
                    vrmLog("    custom['\(name)']: \(expr.morphTargetBinds.count) binds ✅")
                } else if expressions.custom[name] != nil {
                    vrmLog("    custom['\(name)']: 0 binds ❌ (empty)")
                }
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

    /// Advances gaze by one frame: recomputes target yaw/pitch from ``target``, applies smoothing and saccades, clamps via range maps, and writes through the active ``mode``.
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

    /// Snap to the current ``target`` and write through the active ``mode``
    /// (bones or expression weights) in a single call, bypassing smoothing
    /// and the ``enabled`` tick gate.
    ///
    /// For offline harnesses that apply a clip at a single time and need
    /// the gaze to land in the next render without waiting for smoothing
    /// to converge. ``AnimationPlayer/applyClip(_:atTime:to:expressionController:lookAtController:)``
    /// calls this after the per-frame sampler updates ``target``; otherwise
    /// the offline render reflects whatever pre-applyClip pose was on the
    /// bones / weights (typically rest, so all gaze plans render identical
    /// PNGs — VMK#294).
    ///
    /// Live playback should continue to use ``update(deltaTime:)`` so the
    /// frame-rate-independent smoothing curve runs as designed.
    public func applyImmediately() {
        guard model != nil else { return }
        updateTargetAngles()
        currentYaw = targetYaw
        currentPitch = targetPitch
        applyConstraints()
        if mode == .bone {
            applyToBones()
        } else {
            applyToExpressions()
        }
    }

    // MARK: - Target Calculation

    private func updateTargetAngles() {
        guard let model = model else { return }

        // Resolve head-bone world transform once (used for both eye position and
        // for head-local targets). Falls back to a default eye height when the
        // model has no head bone wired up.
        var eyePosition = SIMD3<Float>(0, 1.5, 0) // Default eye height
        var headWorldMatrix: simd_float4x4?

        if let headIndex = headBoneIndex, headIndex < model.nodes.count {
            let headNode = model.nodes[headIndex]
            headWorldMatrix = headNode.worldMatrix
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

        // Get target position based on target type
        let targetPos: SIMD3<Float>
        switch target {
        case .camera:
            targetPos = cameraPosition
        case .user:
            targetPos = userPosition
        case .point(let pos):
            targetPos = pos
        case .headLocalPoint(let localPos):
            if let m = headWorldMatrix {
                let world = m * SIMD4<Float>(localPos, 1)
                targetPos = SIMD3<Float>(world.x, world.y, world.z)
            } else {
                // No head bone wired up — last-resort path: treat the payload
                // as world-space so gaze still has a defined direction (though
                // it will not track head motion).
                targetPos = localPos
            }
        case .forward:
            targetYaw = 0
            targetPitch = 0
            return
        }

        // Compute the gaze direction in HEAD-LOCAL space. The yaw/pitch produced
        // here are written to the eye bone as a *local* rotation, so they must be
        // expressed relative to the head's frame — not world space. Bringing the
        // world-space target through the head's inverse world matrix strips the
        // head's (and any root/body) rotation; computing the angles in world space
        // and stamping them onto a local bone points the eyes off by the head's
        // yaw whenever the head is turned (e.g. body rotated at the root).
        let direction: SIMD3<Float>
        if let headMatrix = headWorldMatrix {
            let localTarget4 = headMatrix.inverse * SIMD4<Float>(targetPos, 1)
            let localTarget = SIMD3<Float>(localTarget4.x, localTarget4.y, localTarget4.z)
            // The gaze origin in head-local space is the head bone's own origin
            // (zero) plus the authored offset; the head's world translation is
            // already removed by the inverse transform above.
            let gazeOrigin = lookAtData?.offsetFromHeadBone ?? .zero
            direction = normalize(localTarget - gazeOrigin)
        } else {
            // No head bone wired up — fall back to the world-space origin.
            direction = normalize(targetPos - eyePosition)
        }

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

    // MARK: - RangeMap Mapping

    /// Applies the VRM 1.0 rangeMap formula to a signed input angle (radians).
    ///
    /// Formula: `output = clamp(abs(input_deg) / inputMaxValue, 0, 1) * outputScale`
    ///
    /// - Parameters:
    ///   - inputRad: Signed input angle in radians.
    ///   - map: The rangeMap entry (inputMaxValue and outputScale in degrees).
    /// - Returns: The signed output value (degrees for bone mode, weight for expression mode).
    static func rangeMapOutput(_ inputRad: Float, map: VRMLookAtRangeMap) -> Float {
        let inputDeg = abs(inputRad) * (180.0 / .pi)
        let normalized = Swift.min(inputDeg / map.inputMaxValue, 1.0)
        let outputDeg = normalized * map.outputScale
        return inputRad >= 0 ? outputDeg : -outputDeg
    }

    // MARK: - Bone Application

    private func applyToBones() {
        guard let model = model else { return }
        guard let lookAt = lookAtData else { return }

        // Left eye: yaw > 0 (right) is inner (toward nose), yaw < 0 (left) is outer
        if let leftIndex = leftEyeBoneIndex, leftIndex < model.nodes.count {
            let node = model.nodes[leftIndex]

            let horizontalMap = currentYaw > 0 ? lookAt.rangeMapHorizontalInner : lookAt.rangeMapHorizontalOuter
            let mappedYawDeg = VRMLookAtController.rangeMapOutput(currentYaw, map: horizontalMap)
            let mappedYawRad = mappedYawDeg * (.pi / 180.0)

            let verticalMap = currentPitch > 0 ? lookAt.rangeMapVerticalUp : lookAt.rangeMapVerticalDown
            let mappedPitchDeg = VRMLookAtController.rangeMapOutput(currentPitch, map: verticalMap)
            let mappedPitchRad = mappedPitchDeg * (.pi / 180.0)

            let pitchQuat = simd_quatf(angle: mappedPitchRad, axis: [1, 0, 0])
            let yawQuat = simd_quatf(angle: mappedYawRad, axis: [0, 1, 0])
            // Compose the gaze deviation on top of the eye bone's authored rest
            // rotation (the bind-pose baseline the eyeball mesh is skinned to).
            // Overwriting with the bare gaze quaternion discards rest, which on
            // VRoid-style rigs (large mirrored outward eye rest) snaps the eyes
            // wall-eyed at center; pre-multiplying makes the rest cancel in the
            // skinning delta so both eyes track in parallel.
            node.rotation = pitchQuat * yawQuat * node.initialRotation

            if debugFrameCount % 60 == 0 {
                vrmLog("[LookAt BONE] Left eye node \(leftIndex) yaw=\(mappedYawDeg)° pitch=\(mappedPitchDeg)°")
            }

            node.updateLocalMatrix()
            node.updateWorldTransform()
        }

        // Right eye: yaw < 0 (left) is inner (toward nose), yaw > 0 (right) is outer
        if let rightIndex = rightEyeBoneIndex, rightIndex < model.nodes.count {
            let node = model.nodes[rightIndex]

            let horizontalMap = currentYaw < 0 ? lookAt.rangeMapHorizontalInner : lookAt.rangeMapHorizontalOuter
            let mappedYawDeg = VRMLookAtController.rangeMapOutput(currentYaw, map: horizontalMap)
            let mappedYawRad = mappedYawDeg * (.pi / 180.0)

            let verticalMap = currentPitch > 0 ? lookAt.rangeMapVerticalUp : lookAt.rangeMapVerticalDown
            let mappedPitchDeg = VRMLookAtController.rangeMapOutput(currentPitch, map: verticalMap)
            let mappedPitchRad = mappedPitchDeg * (.pi / 180.0)

            let pitchQuat = simd_quatf(angle: mappedPitchRad, axis: [1, 0, 0])
            let yawQuat = simd_quatf(angle: mappedYawRad, axis: [0, 1, 0])
            node.rotation = pitchQuat * yawQuat * node.initialRotation

            if debugFrameCount % 60 == 0 {
                vrmLog("[LookAt BONE] Right eye node \(rightIndex) yaw=\(mappedYawDeg)° pitch=\(mappedPitchDeg)°")
            }

            node.updateLocalMatrix()
            node.updateWorldTransform()
        }

        model.updateNodeTransforms()
    }

    // MARK: - Expression Application

    private func applyToExpressions() {
        guard model != nil else { return }
        guard let lookAt = lookAtData else { return }

        // VMK#297: write to BOTH the VRM 1.0 spec preset namespace
        // (lookLeft/lookRight/lookUp/lookDown lowercase) and the legacy
        // VRM 0.x custom namespace (PascalCase). Each setter is a no-op
        // when its target isn't registered, so spec-compliant assets land
        // in `expressions.preset[.lookLeft]` and legacy assets land in
        // `expressions.custom["LookLeft"]` — without the controller
        // needing to know which.
        expressionController?.setExpressionWeight(.lookLeft, weight: 0)
        expressionController?.setExpressionWeight(.lookRight, weight: 0)
        expressionController?.setExpressionWeight(.lookUp, weight: 0)
        expressionController?.setExpressionWeight(.lookDown, weight: 0)
        expressionController?.setCustomExpressionWeight("LookLeft", weight: 0)
        expressionController?.setCustomExpressionWeight("LookRight", weight: 0)
        expressionController?.setCustomExpressionWeight("LookUp", weight: 0)
        expressionController?.setCustomExpressionWeight("LookDown", weight: 0)

        if abs(currentYaw) > 0.02 {
            if currentYaw > 0 {
                let weight = abs(VRMLookAtController.rangeMapOutput(currentYaw, map: lookAt.rangeMapHorizontalOuter))
                expressionController?.setExpressionWeight(.lookRight, weight: weight)
                expressionController?.setCustomExpressionWeight("LookRight", weight: weight)
                if debugFrameCount % 60 == 0 {
                    vrmLog("[LookAt EXPRESSION] lookRight weight: \(weight)")
                }
            } else {
                let weight = abs(VRMLookAtController.rangeMapOutput(currentYaw, map: lookAt.rangeMapHorizontalOuter))
                expressionController?.setExpressionWeight(.lookLeft, weight: weight)
                expressionController?.setCustomExpressionWeight("LookLeft", weight: weight)
                if debugFrameCount % 60 == 0 {
                    vrmLog("[LookAt EXPRESSION] lookLeft weight: \(weight)")
                }
            }
        }

        if abs(currentPitch) > 0.02 {
            if currentPitch > 0 {
                let weight = abs(VRMLookAtController.rangeMapOutput(currentPitch, map: lookAt.rangeMapVerticalUp))
                expressionController?.setExpressionWeight(.lookUp, weight: weight)
                expressionController?.setCustomExpressionWeight("LookUp", weight: weight)
                if debugFrameCount % 60 == 0 {
                    vrmLog("[LookAt EXPRESSION] lookUp weight: \(weight)")
                }
            } else {
                let weight = abs(VRMLookAtController.rangeMapOutput(currentPitch, map: lookAt.rangeMapVerticalDown))
                expressionController?.setExpressionWeight(.lookDown, weight: weight)
                expressionController?.setCustomExpressionWeight("LookDown", weight: weight)
                if debugFrameCount % 60 == 0 {
                    vrmLog("[LookAt EXPRESSION] lookDown weight: \(weight)")
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

    /// Writes the current gaze yaw/pitch into `animationState.bones` for `leftEye` and `rightEye` when ``mode`` is bone.
    ///
    /// Allows look-at to flow through an intermediate ``VRMAnimationState``
    /// (e.g. when retargeting from a manually authored pose) instead of
    /// being applied to the model directly. No-op in expression mode or
    /// when the model's `lookAt` block is missing.
    /// Eye bone's bind-pose rotation, or identity if the index is missing or no
    /// longer fits the current model's node array. Bounds-checked to match
    /// ``applyToBones`` so a stale index skips rather than traps.
    private func eyeRestRotation(_ index: Int?) -> simd_quatf {
        guard let index, let model, index < model.nodes.count else {
            return simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        }
        return model.nodes[index].initialRotation
    }

    public func applyToAnimationState(_ animationState: VRMAnimationState) {
        guard mode == .bone, let lookAt = lookAtData else { return }

        // `VRMAnimationState.applyToModel` stamps these rotations onto the nodes
        // absolutely (no rest compose), so bake the eye bone's rest rotation in
        // here — same composition as `applyToBones`. Without it, VRoid-style
        // mirrored eye rests are discarded and the eyes go wall-eyed.
        // Bounds-guard the index like `applyToBones` does (line 500/524): a
        // stale eye-bone index from a swapped/rebuilt model must skip, not trap.
        let leftRest = eyeRestRotation(leftEyeBoneIndex)
        let rightRest = eyeRestRotation(rightEyeBoneIndex)

        // Left eye: yaw > 0 (right) is inner (toward nose), yaw < 0 (left) is outer
        if leftEyeBoneIndex != nil {
            let horizontalMap = currentYaw > 0 ? lookAt.rangeMapHorizontalInner : lookAt.rangeMapHorizontalOuter
            let mappedYawRad = VRMLookAtController.rangeMapOutput(currentYaw, map: horizontalMap) * (.pi / 180.0)
            let verticalMap = currentPitch > 0 ? lookAt.rangeMapVerticalUp : lookAt.rangeMapVerticalDown
            let mappedPitchRad = VRMLookAtController.rangeMapOutput(currentPitch, map: verticalMap) * (.pi / 180.0)
            let eyeRotation = simd_quatf(angle: mappedPitchRad, axis: [1, 0, 0]) * simd_quatf(angle: mappedYawRad, axis: [0, 1, 0])
            var transform = animationState.bones[.leftEye] ?? VRMAnimationState.BoneTransform()
            transform.rotation = eyeRotation * leftRest
            animationState.bones[.leftEye] = transform
        }

        // Right eye: yaw < 0 (left) is inner (toward nose), yaw > 0 (right) is outer
        if rightEyeBoneIndex != nil {
            let horizontalMap = currentYaw < 0 ? lookAt.rangeMapHorizontalInner : lookAt.rangeMapHorizontalOuter
            let mappedYawRad = VRMLookAtController.rangeMapOutput(currentYaw, map: horizontalMap) * (.pi / 180.0)
            let verticalMap = currentPitch > 0 ? lookAt.rangeMapVerticalUp : lookAt.rangeMapVerticalDown
            let mappedPitchRad = VRMLookAtController.rangeMapOutput(currentPitch, map: verticalMap) * (.pi / 180.0)
            let eyeRotation = simd_quatf(angle: mappedPitchRad, axis: [1, 0, 0]) * simd_quatf(angle: mappedYawRad, axis: [0, 1, 0])
            var transform = animationState.bones[.rightEye] ?? VRMAnimationState.BoneTransform()
            transform.rotation = eyeRotation * rightRest
            animationState.bones[.rightEye] = transform
        }
    }

    // MARK: - Public API

    /// Sets ``target`` to `target`. The optional `duration` parameter is currently unused; tween behaviour is reserved for a future revision.
    public func lookAt(_ target: VRMLookAtTarget, duration: Float? = nil) {
        self.target = target
        // Duration support could be added with a timer
    }

    /// Resets target to ``VRMLookAtTarget/forward`` and zeros current/target yaw, pitch, and saccade offsets.
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