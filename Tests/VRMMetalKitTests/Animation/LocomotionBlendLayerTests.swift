import XCTest
import simd
@testable import VRMMetalKit

final class LocomotionBlendLayerTests: XCTestCase {
    func makeClip(stride: Float, legAmplitude: Float = 0.4) -> AnimationClip {
        var clip = AnimationClip(duration: 1.0)
        clip.locomotion = LocomotionMetadata(
            version: 1, strideSpeed: stride, inPlace: true, sourceHipsHeight: 0.85)
        clip.addJointTrack(JointTrack(
            bone: .rightUpperLeg,
            rotationSampler: { t in simd_quatf(angle: legAmplitude * sin(t * 2 * .pi), axis: SIMD3(1, 0, 0)) }
        ))
        return clip
    }

    func testRefusesClipWithoutMetadata() {
        let layer = LocomotionBlendLayer()
        var bare = AnimationClip(duration: 1)
        XCTAssertThrowsError(try layer.setClips(idle: bare, walk: makeClip(stride: 1.5)))
        bare.locomotion = LocomotionMetadata(version: 1, strideSpeed: 0, inPlace: true, sourceHipsHeight: 0.85)
        XCTAssertNoThrow(try layer.setClips(idle: bare, walk: makeClip(stride: 1.5)))
    }

    func testRefusesWalkWithZeroStride() {
        let layer = LocomotionBlendLayer()
        XCTAssertThrowsError(try layer.setClips(idle: makeClip(stride: 0), walk: makeClip(stride: 0)))
    }

    func testDeterministicReplay() throws {
        func run() throws -> [simd_quatf] {
            let layer = LocomotionBlendLayer()
            try layer.setClips(idle: makeClip(stride: 0, legAmplitude: 0.05), walk: makeClip(stride: 1.5))
            layer.targetSpeed = 1.2
            layer.phaseOffset = 0.25
            var out: [simd_quatf] = []
            for _ in 0..<120 {
                layer.update(deltaTime: 1.0 / 60.0, context: AnimationContext())
                out.append(layer.evaluate().bones[.rightUpperLeg]!.rotation)
            }
            return out
        }
        let a = try run(), b = try run()
        for (qa, qb) in zip(a, b) {
            XCTAssertEqual(qa.vector, qb.vector, "bit-identical replay required")
        }
    }

    func testPhaseOffsetDecorrelates() throws {
        func leg(at phase: Float) throws -> simd_quatf {
            let layer = LocomotionBlendLayer()
            try layer.setClips(idle: makeClip(stride: 0, legAmplitude: 0.05), walk: makeClip(stride: 1.5))
            layer.targetSpeed = 1.5
            layer.phaseOffset = phase
            layer.update(deltaTime: 1.0 / 60.0, context: AnimationContext())
            return layer.evaluate().bones[.rightUpperLeg]!.rotation
        }
        // Quarter-cycle offset gives maximum angular separation on the
        // sine-driven fixture (a half-cycle offset is antipodal in TIME but
        // nearly symmetric in ANGLE this early in the cycle).
        let q0 = try leg(at: 0), qQuarter = try leg(at: 0.25)
        XCTAssertLessThan(abs(simd_dot(q0.vector, qQuarter.vector)), 0.999,
                          "quarter-cycle phase offset must change the pose")
    }

    func testZeroSpeedHoldsIdlePose() throws {
        let layer = LocomotionBlendLayer()
        try layer.setClips(idle: makeClip(stride: 0, legAmplitude: 0.0), walk: makeClip(stride: 1.5))
        layer.targetSpeed = 0
        layer.update(deltaTime: 0.5, context: AnimationContext())
        let q = layer.evaluate().bones[.rightUpperLeg]!.rotation
        XCTAssertEqual(abs(simd_dot(q.vector, simd_quatf(angle: 0, axis: SIMD3(1, 0, 0)).vector)), 1.0, accuracy: 1e-4)
    }

    func testPriorityIsBelowAllExistingLayers() {
        XCTAssertLessThan(LocomotionBlendLayer().priority, IdleBreathingLayer().priority)
    }

    func testTranslationOnlyTrackDoesNotEnterAffectedBones() throws {
        var idle = makeClip(stride: 0, legAmplitude: 0.05)
        // hips Y-bob: translation-only track, the post-ingest shape
        idle.addJointTrack(JointTrack(bone: .hips, translationSampler: { _ in SIMD3<Float>(0, 0.85, 0) }))
        let layer = LocomotionBlendLayer()
        try layer.setClips(idle: idle, walk: makeClip(stride: 1.5))
        XCTAssertFalse(layer.affectedBones.contains(.hips),
                       "translation-only bones must not be rotation-driven by the blend")
        layer.targetSpeed = 0.75
        layer.update(deltaTime: 1.0 / 60.0, context: AnimationContext())
        XCTAssertNil(layer.evaluate().bones[.hips])
    }

    func testBoneMissingFromOneClipBlendsTowardRestNotIdentity() throws {
        // walk animates rightLowerLeg; idle does not. With a non-identity
        // rest, the idle side of the blend must contribute REST (delta
        // identity), never world-identity.
        var walk = makeClip(stride: 1.5)
        let q = simd_quatf(angle: 0.5, axis: SIMD3<Float>(1, 0, 0))
        walk.addJointTrack(JointTrack(bone: .rightLowerLeg, rotationSampler: { _ in q }))
        let layer = LocomotionBlendLayer()
        // Simulate a captured non-identity rest without a model:
        layer.setRestRotationsForTesting([.rightLowerLeg: simd_quatf(angle: 0.2, axis: SIMD3<Float>(1, 0, 0))])
        try layer.setClips(idle: makeClip(stride: 0, legAmplitude: 0.05), walk: walk)
        layer.targetSpeed = 0  // pure idle: bone absent from idle pose
        layer.update(deltaTime: 1.0 / 60.0, context: AnimationContext())
        let delta = try XCTUnwrap(layer.evaluate().bones[.rightLowerLeg]).rotation
        let identity = simd_quatf(angle: 0, axis: SIMD3<Float>(1, 0, 0))
        XCTAssertEqual(abs(simd_dot(delta.vector, identity.vector)), 1.0, accuracy: 1e-4,
                       "missing-from-idle bone at speed 0 must emit an identity DELTA (stay at rest)")
    }
}
