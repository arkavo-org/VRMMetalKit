//
// Copyright 2026 Arkavo
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

final class APICleanupAndSendableTests: XCTestCase {

    // MARK: - #12: RendererConfig Full Init Parity & Runtime Knobs

    func testRendererConfigInitParityCoversAllProperties() {
        let archiveDir = URL(fileURLWithPath: "/tmp/vrm-archive-test")
        let config = RendererConfig(
            strict: .warn,
            colorPixelFormat: .rgba16Float,
            enableMetalValidation: false,
            checkCommandBufferErrors: false,
            minDrawCallsPerFrame: 3,
            maxFrameLuma: 0.8,
            renderFilter: .mesh("Body"),
            drawUntil: 10,
            drawOnlyIndex: 2,
            testIdentityPalette: 0,
            sampleCount: 4,
            depthBiasScale: 2.5,
            enableDepthPrepass: true,
            alphaToCoverageForMASK: true,
            synchronousSpringBone: true,
            dualQuaternionSkinning: true,
            enablePipelineArchive: true,
            pipelineArchiveDirectory: archiveDir,
            enableMToonFunctionConstants: false,
            enableMaterialization: true,
            enableMaterialFinish: true,
            hairHighlight: HairHighlightConfig(isEnabled: true, strength: 0.9, sharpness: 12),
            enableContactShadows: true,
            contactShadowOpacity: 0.6,
            contactShadowScale: 1.4,
            enableSSAO: true,
            ssaoStrength: 0.8,
            legacyMaterialHeuristics: true
        )

        XCTAssertEqual(config.strict, .warn)
        XCTAssertEqual(config.colorPixelFormat, .rgba16Float)
        XCTAssertFalse(config.enableMetalValidation)
        XCTAssertFalse(config.checkCommandBufferErrors)
        XCTAssertEqual(config.minDrawCallsPerFrame, 3)
        XCTAssertEqual(config.maxFrameLuma, 0.8)
        XCTAssertEqual(config.drawUntil, 10)
        XCTAssertEqual(config.drawOnlyIndex, 2)
        XCTAssertEqual(config.testIdentityPalette, 0)
        XCTAssertEqual(config.sampleCount, 4)
        XCTAssertEqual(config.depthBiasScale, 2.5)
        XCTAssertTrue(config.enableDepthPrepass)
        XCTAssertTrue(config.alphaToCoverageForMASK)
        XCTAssertTrue(config.synchronousSpringBone)
        XCTAssertTrue(config.dualQuaternionSkinning)
        XCTAssertTrue(config.enablePipelineArchive)
        XCTAssertEqual(config.pipelineArchiveDirectory, archiveDir)
        XCTAssertFalse(config.enableMToonFunctionConstants)
        XCTAssertTrue(config.enableMaterialization)
        XCTAssertTrue(config.enableMaterialFinish)
        XCTAssertTrue(config.hairHighlight.isEnabled)
        XCTAssertTrue(config.enableContactShadows)
        XCTAssertEqual(config.contactShadowOpacity, 0.6)
        XCTAssertEqual(config.contactShadowScale, 1.4)
        XCTAssertTrue(config.enableSSAO)
        XCTAssertEqual(config.ssaoStrength, 0.8)
        XCTAssertTrue(config.legacyMaterialHeuristics)
    }

    func testRendererRuntimeKnobsAreMutableWhileConfigStaysImmutable() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable")
        }

        let initialConfig = RendererConfig(
            strict: .off,
            depthBiasScale: 1.0,
            hairHighlight: HairHighlightConfig(isEnabled: true),
            contactShadowOpacity: 0.45,
            contactShadowScale: 1.15,
            ssaoStrength: 0.6
        )
        let renderer = VRMRenderer(device: device, config: initialConfig)

        XCTAssertEqual(renderer.config.strict, .off)
        XCTAssertEqual(renderer.strict, .off)
        XCTAssertEqual(renderer.depthBiasScale, 1.0)
        XCTAssertTrue(renderer.hairHighlight.isEnabled)
        XCTAssertEqual(renderer.contactShadowOpacity, 0.45)
        XCTAssertEqual(renderer.contactShadowScale, 1.15)
        XCTAssertEqual(renderer.ssaoStrength, 0.6)

        renderer.strict = .warn
        renderer.drawUntil = 5
        renderer.drawOnlyIndex = 1
        renderer.renderFilter = .material("Skin")
        renderer.testIdentityPalette = 0
        renderer.depthBiasScale = 3.0
        renderer.hairHighlight.isEnabled = false
        renderer.contactShadowOpacity = 0.8
        renderer.contactShadowScale = 1.75
        renderer.ssaoStrength = 1.2

        XCTAssertEqual(renderer.strict, .warn)
        XCTAssertEqual(renderer.strictValidator?.strict, .warn)
        XCTAssertEqual(renderer.drawUntil, 5)
        XCTAssertEqual(renderer.drawOnlyIndex, 1)
        XCTAssertEqual(renderer.testIdentityPalette, 0)
        XCTAssertEqual(renderer.depthBiasScale, 3.0)
        XCTAssertFalse(renderer.hairHighlight.isEnabled)
        XCTAssertEqual(renderer.contactShadowOpacity, 0.8)
        XCTAssertEqual(renderer.contactShadowScale, 1.75)
        XCTAssertEqual(renderer.ssaoStrength, 1.2)
        // Original immutable config snapshot remains untouched
        XCTAssertEqual(renderer.config.strict, .off)
        XCTAssertEqual(renderer.config.depthBiasScale, 1.0)
        XCTAssertTrue(renderer.config.hairHighlight.isEnabled)
        XCTAssertEqual(renderer.config.contactShadowOpacity, 0.45)
        XCTAssertEqual(renderer.config.contactShadowScale, 1.15)
        XCTAssertEqual(renderer.config.ssaoStrength, 0.6)
    }

    // MARK: - #13: Unified VRMModel.load & Swift 6 Sendable Conformance

    func testUnifiedVRMModelLoadOptionsWithLimits() async throws {
        let model = try VRMBuilder().setSkeleton(.defaultHumanoid).build()
        let glbData = try model.serialize()

        let loaded = try await VRMModel.load(
            from: glbData,
            device: nil,
            options: VRMLoadingOptions(limits: .default)
        )
        XCTAssertEqual(loaded.specVersion, .v1_0)
    }

    private func assertSendable<T: Sendable>(_ value: T) -> T {
        value
    }

    func testCoreValueTypesConformToSendable() {
        _ = assertSendable(RendererConfig())
        _ = assertSendable(ResourceIndices.self)
        _ = assertSendable(VRMSpecVersion.v1_0)
        _ = assertSendable(VRMExpression(name: "test", preset: .happy))
        _ = assertSendable(VRMMorphTargetBind(node: 0, index: 0, weight: 1.0))
        _ = assertSendable(VRMMaterialColorBind(material: 0, type: .color, targetValue: [1, 1, 1, 1]))
        _ = assertSendable(VRMMaterialColorType.color)
        _ = assertSendable(VRMTextureTransformBind(material: 0, scale: [1, 1], offset: [0, 0]))
        _ = assertSendable(VRMLookAtType.bone)
        _ = assertSendable(VRMLookAtRangeMap())
        _ = assertSendable(VRMMeta(licenseUrl: "https://vrm.dev/licenses/1.0/"))
        _ = assertSendable(VRMAvatarPermission.everyone)
        _ = assertSendable(VRMCommercialUsage.corporation)
        _ = assertSendable(VRMCreditNotation.unnecessary)
        _ = assertSendable(VRMModifyPermission.allowModification)
        _ = assertSendable(VRM0MaterialProperty())
        _ = assertSendable(VRMSpringBone())
        _ = assertSendable(VRMCollider(node: 0, shape: .sphere(offset: .zero, radius: 0.1)))
        _ = assertSendable(VRMColliderShape.sphere(offset: .zero, radius: 0.1))
        _ = assertSendable(VRMColliderGroup(name: "g", colliders: [0]))
        _ = assertSendable(VRMSpring(name: "s"))
        _ = assertSendable(VRMSpringJoint(node: 0))
        _ = assertSendable(VRMVertex())
        _ = assertSendable(VRMPositionVertex())
        _ = assertSendable(VRMAttributeVertex())
        _ = assertSendable(VRMMaterial.PipelineCategory.opaque)
        _ = assertSendable(VRMHumanoid.VRMHumanBone(node: 0))
        _ = assertSendable(VRMFirstPerson.VRMMeshAnnotation(node: 0, type: .auto))
        _ = assertSendable(VRMAnimationState.BoneTransform())
        _ = assertSendable(MToonMaterialUniforms())
        _ = assertSendable(PlaneCollider(floorY: 0))
        _ = assertSendable(BoneParams(
            stiffness: 1, drag: 0.4, radius: 0.05, parentIndex: 0xFFFFFFFF,
            gravityPower: 0, colliderGroupMask: 1, gravityDir: [0, -1, 0], angleLimit: 0
        ))
        _ = assertSendable(SpringBoneGlobalParams(
            gravity: .zero, dtSub: 1.0 / 120.0, windAmplitude: 0, windFrequency: 1,
            windPhase: 0, windDirection: [1, 0, 0], substeps: 2,
            numBones: 0, numSpheres: 0, numCapsules: 0, numPlanes: 0, settlingFrames: 0
        ))
    }
}
