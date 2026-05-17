// Copyright 2025 Arkavo Inc. and contributors
// Licensed under the Apache License, Version 2.0

import XCTest
import simd
@testable import VRMMetalKit

/// Tests for VMK#269: VRMA retargeting must produce a model-side pose
/// whose **arm world direction** matches the model's bind pose, regardless
/// of whether the VRMA was authored on a different rest pose.
///
/// The existing `VRMABoneRetargetingTests` suite missed this regression
/// because every test only asserts structural soundness of the retargeted
/// rotations (quaternion is normalized, no NaN, tracks exist) and never
/// the resulting POSE. `testRetargetingPreservesAnimationIntent` was
/// labelled the conceptual placeholder and is unconditionally `XCTSkip`-ed.
///
/// Test discipline going forward: assert observable pose invariants, not
/// "the math doesn't explode."
///
/// ## What this test asserts
///
/// VRM 1.0 spec (`VRMC_vrm-1.0/how_to_transform_human_pose.md`) defines
/// the normalisation that lets a VRMA whose rest pose is NOT the canonical
/// T-pose still drive a T-pose model correctly:
///
///   ```
///   Normalized = W_A · L_A⁻¹ · A.LocalRotation · W_A⁻¹
///   B.LocalRotation = L_B · W_B⁻¹ · Normalized · W_B
///   ```
///
/// Where `L_x` is the bone's local rest rotation and `W_x` is the bone's
/// WORLD rest rotation (cumulative product of ancestors' local rotations
/// down to and including the bone). Skipping the `W` terms — as the
/// current `makeRotationSampler` does — only works when `W_A == W_B`,
/// i.e. both rigs are already canonically T-pose. Idle.vrma in
/// `VRMA_Locomotion_Pack/` is authored arms-forward, which violates that
/// assumption and produces the visible zombie pose on every
/// AvatarSample model.
///
/// Reference: VRM 1.0 spec, `how_to_transform_human_pose.md`.
final class VRMARetargetingArmDirectionTests: XCTestCase {

    private let projectRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .path

    /// Loading AvatarSample_A_1.0 (T-pose, arms along +X) with Idle.vrma
    /// (arms-forward rest, along −Z) must yield a leftUpperArm world
    /// direction near +X at t=0, NOT near −Z. The current implementation
    /// produces ≈ −Z (the VRMA's authored rest direction); the spec-
    /// compliant `W`-normalised implementation produces ≈ +X.
    func testIdleVRMAOnAvatarSampleAKeepsLeftUpperArmAtModelTPoseDirection() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device not available")
        }
        let modelPath = "\(projectRoot)/AvatarSample_A_1.0.vrm.glb"
        let vrmaPath = "\(projectRoot)/VRMA_Locomotion_Pack/Idle.vrma"
        try XCTSkipIf(!FileManager.default.fileExists(atPath: modelPath),
                      "AvatarSample_A_1.0.vrm.glb not present at repo root")
        try XCTSkipIf(!FileManager.default.fileExists(atPath: vrmaPath),
                      "Idle.vrma not present at \(vrmaPath)")

        let model = try await VRMModel.load(
            from: URL(fileURLWithPath: modelPath), device: device)
        let clip = try VRMAnimationLoader.loadVRMA(
            from: URL(fileURLWithPath: vrmaPath), model: model)

        let upperArmDir = leftUpperArmWorldDirectionAtT0(model: model, clip: clip)
        XCTAssertNotNil(upperArmDir, "leftUpperArm track must produce a sampleable rotation at t=0.")
        guard let dir = upperArmDir else { return }

        // Spec-correct idle outcome: arm hangs **down** (along −Y) with a
        // small outward (+X) component — relaxed-shoulder pose. Definitely
        // NOT pointing forward along +Z, which is the zombie signature.
        //
        // Pre-fix: direction ≈ (+0.24, 0, +0.97) — dot(+Z) ≳ 0.95 (zombie).
        // Post-fix: direction ≈ (+0.24, −0.97, 0) — dot(−Y) ≳ 0.95 (idle).
        XCTAssertLessThan(dir.z, 0.5,
            "VMK#269: leftUpperArm must NOT point predominantly along +Z " +
            "(avatar's own forward) — that's the zombie pose. Got direction " +
            "= \(dir); dot(+Z) = \(dir.z), expected < 0.5. When this fails " +
            "with dot(+Z) ≳ 0.9, the arm is being driven by the VRMA's " +
            "arms-forward authored rest pose instead of being normalised " +
            "through W into the model's T-pose frame — the spec fix is " +
            "`result = L_B · W_B⁻¹ · W_A · L_A⁻¹ · A · W_A⁻¹ · W_B` " +
            "rather than `result = L_B · L_A⁻¹ · A`.")
        XCTAssertLessThan(dir.y, -0.5,
            "Idle pose expects the arm hanging downward (dot(−Y) > 0.5). " +
            "Got dot(−Y) = \(-dir.y). If close to zero, the arm hasn't " +
            "rotated from the T-pose, suggesting the rotation track isn't " +
            "being sampled. If positive, the arm is pointing up.")
    }

    /// Same fixture against AvatarSample_U_1.0 — different mesh and bone
    /// proportions, same humanoid hierarchy. Should reproduce identically.
    func testIdleVRMAOnAvatarSampleUKeepsLeftUpperArmAtModelTPoseDirection() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device not available")
        }
        let modelPath = "\(projectRoot)/AvatarSample_U_1.0.vrm.glb"
        let vrmaPath = "\(projectRoot)/VRMA_Locomotion_Pack/Idle.vrma"
        try XCTSkipIf(!FileManager.default.fileExists(atPath: modelPath),
                      "AvatarSample_U_1.0.vrm.glb not present at repo root")
        try XCTSkipIf(!FileManager.default.fileExists(atPath: vrmaPath),
                      "Idle.vrma not present at \(vrmaPath)")

        let model = try await VRMModel.load(
            from: URL(fileURLWithPath: modelPath), device: device)
        let clip = try VRMAnimationLoader.loadVRMA(
            from: URL(fileURLWithPath: vrmaPath), model: model)

        guard let dir = leftUpperArmWorldDirectionAtT0(model: model, clip: clip) else {
            XCTFail("U: no leftUpperArm track sample at t=0."); return
        }
        XCTAssertLessThan(dir.z, 0.5,
            "VMK#269 (U variant): leftUpperArm must NOT point along +Z. " +
            "Got direction = \(dir); dot(+Z) = \(dir.z). Same zombie signature " +
            "and same root cause as the A variant.")
        XCTAssertLessThan(dir.y, -0.5,
            "VMK#269 (U variant): idle pose expects arm hanging downward. " +
            "dot(−Y) = \(-dir.y), expected > 0.5.")
    }

    // MARK: - Helpers

    /// Compute the world-space direction in which the model's leftUpperArm
    /// "points" (toward its child, the leftLowerArm) after applying the
    /// retargeted t=0 rotation track from `clip`.
    ///
    /// Strategy: locate the bone's bind-pose world matrix, override its
    /// rotation with the retargeted t=0 sample, recompute the world
    /// matrix, and read out the local-translation direction of the
    /// leftLowerArm transformed through that matrix.
    private func leftUpperArmWorldDirectionAtT0(model: VRMModel,
                                                clip: AnimationClip) -> SIMD3<Float>? {
        // Find the leftUpperArm track and the matching node.
        guard let track = clip.jointTracks.first(where: { $0.bone == .leftUpperArm }),
              let humanoid = model.humanoid,
              let upperArmNodeIndex = humanoid.getBoneNode(.leftUpperArm) else {
            return nil
        }
        let (sampled, _, _) = track.sample(at: 0)
        guard let retargetedRotation = sampled else { return nil }

        // Snapshot the node hierarchy in bind pose, then apply ONLY the
        // upperArm rotation we want to evaluate.
        for node in model.nodes {
            // Reset to the original glTF rest pose by re-reading the
            // stored bindRotation / bindTranslation. Without a stored
            // bind snapshot we use the runtime values, which is fine
            // because no prior animation has run.
            node.updateLocalMatrix()
        }
        guard upperArmNodeIndex < model.nodes.count else { return nil }
        let upperArmNode = model.nodes[upperArmNodeIndex]
        let bindLocalRotation = upperArmNode.rotation
        upperArmNode.rotation = retargetedRotation
        upperArmNode.updateLocalMatrix()
        // Propagate to descendants by walking from the root.
        for root in model.nodes where root.parent == nil {
            root.updateWorldTransform()
        }

        // Use the lowerArm's WORLD position relative to the upperArm's
        // WORLD position as the arm's pointing direction.
        let lowerArmIndex = humanoid.getBoneNode(.leftLowerArm)
        guard let lowerArmIdx = lowerArmIndex, lowerArmIdx < model.nodes.count else {
            // Restore and bail.
            upperArmNode.rotation = bindLocalRotation
            upperArmNode.updateLocalMatrix()
            for root in model.nodes where root.parent == nil {
                root.updateWorldTransform()
            }
            return nil
        }
        let upperWorld = upperArmNode.worldPosition
        let lowerWorld = model.nodes[lowerArmIdx].worldPosition
        let dir = lowerWorld - upperWorld
        let len = simd_length(dir)

        // Restore so we don't pollute subsequent tests.
        upperArmNode.rotation = bindLocalRotation
        upperArmNode.updateLocalMatrix()
        for root in model.nodes where root.parent == nil {
            root.updateWorldTransform()
        }

        guard len > 1e-5 else { return nil }
        return dir / len
    }
}
