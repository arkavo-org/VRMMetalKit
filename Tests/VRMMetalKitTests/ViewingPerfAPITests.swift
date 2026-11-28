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

import Foundation
import Metal
import simd
import XCTest
@testable import VRMMetalKit

final class ViewingPerfAPITests: XCTestCase {

    func testVRMAlphaModeParsingAndUniformRawValues() {
        XCTAssertEqual(VRMAlphaMode(gltfValue: nil), .opaque)
        XCTAssertEqual(VRMAlphaMode(gltfValue: "OPAQUE"), .opaque)
        XCTAssertEqual(VRMAlphaMode(gltfValue: "opaque"), .opaque)
        XCTAssertEqual(VRMAlphaMode(gltfValue: "MASK"), .mask)
        XCTAssertEqual(VRMAlphaMode(gltfValue: "mask"), .mask)
        XCTAssertEqual(VRMAlphaMode(gltfValue: "BLEND"), .blend)
        XCTAssertEqual(VRMAlphaMode(gltfValue: "blend"), .blend)
        XCTAssertEqual(VRMAlphaMode(gltfValue: "unknown"), .opaque)

        XCTAssertEqual(VRMAlphaMode.opaque.uniformRawValue, 0)
        XCTAssertEqual(VRMAlphaMode.mask.uniformRawValue, 1)
        XCTAssertEqual(VRMAlphaMode.blend.uniformRawValue, 2)
    }

    func testVRMMToonMaterialIsReferenceTypeAndCloneIsolatesMutations() {
        let texA = VRMTexture(name: "A")
        let texB = VRMTexture(name: "B")

        let mtoon = VRMMToonMaterial()
        mtoon.shadeColorFactor = SIMD3<Float>(0.2, 0.3, 0.4)
        mtoon.shadeMultiplyTexture = texA

        let alias = mtoon
        alias.shadingToonyFactor = 0.42
        XCTAssertEqual(mtoon.shadingToonyFactor, 0.42, accuracy: 1e-6,
                       "VRMMToonMaterial should mutate in place as a final class")

        let cloned = mtoon.clone { $0 === texA ? texB : $0 }
        XCTAssertFalse(cloned === mtoon)
        XCTAssertTrue(cloned.shadeMultiplyTexture === texB)
        cloned.shadingToonyFactor = 0.88
        XCTAssertEqual(mtoon.shadingToonyFactor, 0.42, accuracy: 1e-6,
                       "Cloned VRMMToonMaterial must not mutate the original")
    }

    func testAnimationLayerEvaluateIntoReusesBufferAndPresetWeights() throws {
        let exprLayer = ExpressionLayer()
        exprLayer.blinkEnabled = false
        exprLayer.playfulIdleEnabled = false
        exprLayer.setExpression(.happy, intensity: 0.75)

        let ctx = AnimationContext(time: 0.1, deltaTime: 0.5)
        exprLayer.update(deltaTime: 0.5, context: ctx)

        var output = LayerOutput()
        exprLayer.evaluate(into: &output)
        XCTAssertEqual(output.blendMode.isAdditive, true)
        XCTAssertGreaterThan(output.presetWeights[.happy] ?? 0, 0.5)
        XCTAssertTrue(output.morphWeights.isEmpty,
                      "ExpressionLayer should emit typed presetWeights without string keys")

        // Verify compositor transfers presetWeights into VRMExpressionController
        let gltfJSON = """
        {
          "asset": { "version": "2.0" },
          "nodes": [{ "name": "Hips" }]
        }
        """
        let doc = try JSONDecoder().decode(GLTFDocument.self, from: Data(gltfJSON.utf8))
        let model = VRMModel(specVersion: .v1_0, meta: VRMMeta(licenseUrl: "https://example.com"), humanoid: VRMHumanoid(), gltf: doc)
        let hips = VRMNode(index: 0, name: "Hips")
        model.nodes = [hips]
        model.humanoid?.humanBones[.hips] = VRMHumanoid.VRMHumanBone(node: 0)

        let compositor = AnimationLayerCompositor()
        compositor.setup(model: model)
        compositor.addLayer(exprLayer)
        compositor.update(deltaTime: 0.016, context: ctx)

        let controller = VRMExpressionController()
        var happy = VRMExpression(preset: .happy)
        happy.morphTargetBinds = [VRMMorphTargetBind(node: 0, index: 0, weight: 1.0, meshIndex: 0)]
        controller.registerExpression(happy, for: .happy)

        compositor.applyMorphsToController(controller)
        XCTAssertGreaterThan(controller.weight(for: .happy), 0.5)
    }

    func testRetainCPUMorphDeltasFlagControlsCPUMemoryRetentionAndARKitSoAFallback() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable")
        }

        // Build minimal binary buffer: 3 float3 positions + 3 float3 morph deltas + 3 uint16 indices
        var bin = Data()
        func appendFloat3(_ v: SIMD3<Float>) {
            let arr = [v.x, v.y, v.z]
            arr.withUnsafeBytes { bin.append(contentsOf: $0) }
        }
        appendFloat3(SIMD3<Float>(0, 0, 0))
        appendFloat3(SIMD3<Float>(1, 0, 0))
        appendFloat3(SIMD3<Float>(0, 1, 0))
        // Morph target 0 (aa mouth displacement)
        appendFloat3(SIMD3<Float>(0, -0.05, 0))
        appendFloat3(SIMD3<Float>(0, -0.05, 0))
        appendFloat3(SIMD3<Float>(0, 0, 0))
        let indexOffset = bin.count
        let indices: [UInt16] = [0, 1, 2]
        indices.withUnsafeBytes { bin.append(contentsOf: $0) }
        while bin.count % 4 != 0 { bin.append(0) }

        let gltfJSON = """
        {
          "asset": { "version": "2.0" },
          "buffers": [{ "byteLength": \(bin.count) }],
          "bufferViews": [
            { "buffer": 0, "byteOffset": 0, "byteLength": 36 },
            { "buffer": 0, "byteOffset": 36, "byteLength": 36 },
            { "buffer": 0, "byteOffset": \(indexOffset), "byteLength": 6 }
          ],
          "accessors": [
            { "bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3", "min": [0,0,0], "max": [1,1,0] },
            { "bufferView": 1, "componentType": 5126, "count": 3, "type": "VEC3" },
            { "bufferView": 2, "componentType": 5123, "count": 3, "type": "SCALAR" }
          ],
          "meshes": [{
            "name": "Face",
            "primitives": [{
              "attributes": { "POSITION": 0 },
              "indices": 2,
              "targets": [{ "POSITION": 1 }]
            }]
          }],
          "nodes": [{ "name": "FaceNode", "mesh": 0 }],
          "extensions": {
            "VRMC_vrm": {
              "specVersion": "1.0",
              "meta": { "name": "MorphTest", "authors": ["Test"], "licenseUrl": "https://vrm.dev/licenses/1.0/" },
              "humanoid": {
                "humanBones": {
                  "hips": { "node": 0 }, "spine": { "node": 0 }, "head": { "node": 0 },
                  "leftUpperArm": { "node": 0 }, "leftLowerArm": { "node": 0 }, "leftHand": { "node": 0 },
                  "rightUpperArm": { "node": 0 }, "rightLowerArm": { "node": 0 }, "rightHand": { "node": 0 },
                  "leftUpperLeg": { "node": 0 }, "leftLowerLeg": { "node": 0 }, "leftFoot": { "node": 0 },
                  "rightUpperLeg": { "node": 0 }, "rightLowerLeg": { "node": 0 }, "rightFoot": { "node": 0 }
                }
              },
              "expressions": {
                "preset": {
                  "aa": { "morphTargetBinds": [{ "node": 0, "index": 0, "weight": 1.0 }] },
                  "happy": { "morphTargetBinds": [{ "node": 0, "index": 0, "weight": 0.5 }] }
                }
              }
            }
          }
        }
        """
        let doc = try JSONDecoder().decode(GLTFDocument.self, from: Data(gltfJSON.utf8))

        // Default: retainCPUMorphDeltas == false drops CPU delta arrays after GPU SoA upload
        let compactModel = try await VRMModel.load(document: doc, binaryData: bin, device: device)
        let compactPrim = try XCTUnwrap(compactModel.meshes.first?.primitives.first)
        XCTAssertEqual(compactPrim.morphTargetCount, 1)
        XCTAssertEqual(compactPrim.morphTargets.count, 1)
        XCTAssertNil(compactPrim.morphTargets[0].positionDeltas,
                     "Default load should drop CPU morph deltas once uploaded to GPU SoA buffer")
        XCTAssertNotNil(compactPrim.morphPositionsSoA)

        // Opt-in: retainCPUMorphDeltas == true preserves CPU delta arrays
        let retainedModel = try await VRMModel.load(
            document: doc,
            binaryData: bin,
            device: device,
            options: VRMLoadingOptions(retainCPUMorphDeltas: true)
        )
        let retainedPrim = try XCTUnwrap(retainedModel.meshes.first?.primitives.first)
        XCTAssertEqual(retainedPrim.morphTargets[0].positionDeltas?.count, 3)

        // ARKitMapper mouth overlap weights must agree between compact (GPU SoA) and retained (CPU) loads
        let compactOverlaps = ARKitToVRMMapper.mouthOverlapWeights(for: compactModel)
        let retainedOverlaps = ARKitToVRMMapper.mouthOverlapWeights(for: retainedModel)
        XCTAssertEqual(compactOverlaps["happy"] ?? -1, retainedOverlaps["happy"] ?? -2, accuracy: 1e-5)
        XCTAssertGreaterThan(compactOverlaps["happy"] ?? 0, 0.4)
    }

    func testUploadIndicesPopulatesIndexBufferAndMetadata() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable")
        }
        let prim = VRMPrimitive()
        prim.uploadIndices([UInt16(0), 1, 2], device: device)
        XCTAssertEqual(prim.indexCount, 3)
        XCTAssertEqual(prim.indexType, .uint16)
        XCTAssertNotNil(prim.indexBuffer)

        prim.uploadIndices([UInt32(0), 1, 2, 2, 1, 3], device: device)
        XCTAssertEqual(prim.indexCount, 6)
        XCTAssertEqual(prim.indexType, .uint32)
        XCTAssertNotNil(prim.indexBuffer)
    }

    func testMorphPositionDeltaBoundsSafetyAndCreateMorphTargetBuffersPreservesUploadedSoA() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable")
        }
        let prim = VRMPrimitive()
        prim.uploadVertices([
            VRMVertex(position: [0, 0, 0]),
            VRMVertex(position: [1, 0, 0]),
            VRMVertex(position: [0, 1, 0]),
        ], device: device)
        var target = VRMMorphTarget(name: "t0")
        target.positionDeltas = [[0, 0.2, 0], [0, 0.2, 0], [0, 0.2, 0]]
        prim.morphTargets = [target]
        prim.createMorphTargetBuffers(device: device)
        prim.morphTargets[0].positionDeltas = nil

        // Re-invoking createMorphTargetBuffers after CPU deltas were released must not zero SoA
        prim.createMorphTargetBuffers(device: device)
        XCTAssertEqual(prim.morphPositionDelta(targetIndex: 0, vertexIndex: 0), SIMD3<Float>(0, 0.2, 0))

        // Appending a metadata-only target must not read past SoA buffer length
        prim.morphTargets.append(VRMMorphTarget(name: "t1_extra"))
        XCTAssertEqual(prim.morphPositionDelta(targetIndex: 1, vertexIndex: 0), .zero)
    }

    func testMixedTypedAndStringPresetWeightsAccumulateAdditively() throws {
        final class StringHappyLayer: AnimationLayer {
            let identifier = "string_happy"
            let priority = 5
            var isEnabled = true
            let affectedBones: Set<VRMHumanoidBone> = []
            func update(deltaTime: Float, context: AnimationContext) {}
            func evaluate(into output: inout LayerOutput) {
                output.reset(blendMode: .additive)
                output.morphWeights["happy"] = 0.25
            }
        }
        final class TypedHappyLayer: AnimationLayer {
            let identifier = "typed_happy"
            let priority = 4
            var isEnabled = true
            let affectedBones: Set<VRMHumanoidBone> = []
            func update(deltaTime: Float, context: AnimationContext) {}
            func evaluate(into output: inout LayerOutput) {
                output.reset(blendMode: .additive)
                output.presetWeights[.happy] = 0.5
            }
        }

        let doc = try JSONDecoder().decode(GLTFDocument.self, from: Data(#"{"asset":{"version":"2.0"},"nodes":[{"name":"Hips"}]}"#.utf8))
        let model = VRMModel(specVersion: .v1_0, meta: VRMMeta(licenseUrl: "https://example.com"), humanoid: VRMHumanoid(), gltf: doc)
        model.nodes = [VRMNode(index: 0, name: "Hips")]
        let compositor = AnimationLayerCompositor()
        compositor.setup(model: model)
        compositor.addLayer(TypedHappyLayer())
        compositor.addLayer(StringHappyLayer())
        compositor.update(deltaTime: 0.016, context: AnimationContext(time: 0, deltaTime: 0.016))

        let controller = VRMExpressionController()
        var happy = VRMExpression(preset: .happy)
        happy.morphTargetBinds = [VRMMorphTargetBind(node: 0, index: 0, weight: 1.0, meshIndex: 0)]
        controller.registerExpression(happy, for: .happy)
        compositor.applyMorphsToController(controller)
        XCTAssertEqual(controller.weight(for: .happy), 0.75, accuracy: 1e-5)
    }

    func testVRM0UnlitTransparentZWritePreservesDepthWriteWhenZWriteOmitted() throws {
        let gltfMat = try JSONDecoder().decode(
            GLTFMaterial.self,
            from: Data(#"{"name":"UnlitZW","alphaMode":"BLEND"}"#.utf8)
        )
        var prop = VRM0MaterialProperty()
        prop.name = "UnlitZW"
        prop.shader = "VRM/UnlitTransparentZWrite"
        let mat = VRMMaterial(from: gltfMat, textures: [], vrm0MaterialProperty: prop, vrmVersion: .v0_0)
        XCTAssertEqual(mat.alphaMode, .blend)
        XCTAssertTrue(mat.transparentWithZWrite)

        // Stock VRM/UnlitTransparent without _BlendMode or _ZWrite must NOT enable depth writes
        var unlitTransparent = VRM0MaterialProperty()
        unlitTransparent.name = "UnlitT"
        unlitTransparent.shader = "VRM/UnlitTransparent"
        let matNoZWrite = VRMMaterial(from: gltfMat, textures: [], vrm0MaterialProperty: unlitTransparent, vrmVersion: .v0_0)
        XCTAssertEqual(matNoZWrite.alphaMode, .blend)
        XCTAssertFalse(matNoZWrite.transparentWithZWrite)

        // Explicit _ZWrite = 1.0 without _BlendMode still enables depth writes
        var explicitZWriteProp = VRM0MaterialProperty()
        explicitZWriteProp.name = "ExplicitZW"
        explicitZWriteProp.shader = "VRM_USE_GLTFSHADER"
        explicitZWriteProp.floatProperties["_ZWrite"] = 1.0
        let matExplicitZWrite = VRMMaterial(from: gltfMat, textures: [], vrm0MaterialProperty: explicitZWriteProp, vrmVersion: .v0_0)
        XCTAssertEqual(matExplicitZWrite.alphaMode, .blend)
        XCTAssertTrue(matExplicitZWrite.transparentWithZWrite)
    }
}

private extension AnimationBlendMode {
    var isAdditive: Bool {
        if case .additive = self { return true }
        return false
    }
}
