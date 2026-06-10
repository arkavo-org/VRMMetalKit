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
        let q0 = try leg(at: 0), qHalf = try leg(at: 0.5)
        XCTAssertLessThan(abs(simd_dot(q0.vector, qHalf.vector)), 0.999,
                          "half-cycle phase offset must change the pose")
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
}
