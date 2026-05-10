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
import Metal
import simd

// MARK: - First-Person Visibility Helpers

/// Returns the `VRMFirstPersonFlag` for a given node index, defaulting to `.auto` per spec.
///
/// The VRM 1.0 spec mandates that any mesh without an explicit annotation behaves as `auto`.
///
/// - Parameters:
///   - nodeIndex: The node index to look up.
///   - model: The loaded VRM model.
/// - Returns: The annotation flag for that node, or `.auto` if none is found.
public func firstPersonAnnotation(for nodeIndex: Int, in model: VRMModel) -> VRMFirstPersonFlag {
    guard let fp = model.firstPerson else { return .auto }
    return fp.meshAnnotations.first(where: { $0.node == nodeIndex })?.type ?? .auto
}

/// Determines whether a primitive should be rendered given its annotation and the current camera mode.
///
/// | annotation       | thirdPerson | firstPerson |
/// |------------------|-------------|-------------|
/// | `auto`           | true        | true*       |
/// | `both`           | true        | true        |
/// | `firstPersonOnly`| false       | true        |
/// | `thirdPersonOnly`| true        | false       |
///
/// *For `auto` in first-person, per-vertex head-bone culling is handled separately in the shader.
///
/// - Parameters:
///   - annotation: The mesh annotation flag.
///   - cameraMode: The current rendering camera mode.
/// - Returns: `true` if the primitive should be submitted for rendering.
public func shouldRenderPrimitive(
    annotation: VRMFirstPersonFlag,
    cameraMode: VRMRenderer.VRMCameraMode
) -> Bool {
    switch (annotation, cameraMode) {
    case (.firstPersonOnly, .thirdPerson):
        return false
    case (.thirdPersonOnly, .firstPerson):
        return false
    default:
        return true
    }
}

// MARK: - Auto-Mode Flag Computation

/// Processes all skinned meshes in a model with `auto` (or missing) first-person annotation,
/// computing per-vertex head-bone hidden flags and uploading them as Metal buffers.
///
/// Call this once after loading the model (and after the Metal device is available) to prepare
/// the first-person hidden flags for all eligible primitives.
///
/// - Parameters:
///   - model: The VRM model whose skinned primitives should be processed.
///   - device: The Metal device to use for buffer allocation.
public func processFirstPersonAutoFlags(model: VRMModel, device: MTLDevice) {
    guard let headNodeIndex = model.humanoid?.getBoneNode(.head) else { return }

    for (nodeIndex, node) in model.nodes.enumerated() {
        guard let meshIndex = node.mesh, meshIndex < model.meshes.count else { continue }

        let annotation = firstPersonAnnotation(for: nodeIndex, in: model)
        guard annotation == .auto else { continue }

        guard let skinIndex = node.skin, skinIndex < model.skins.count else { continue }
        let skin = model.skins[skinIndex]

        guard let headJointIndex = skin.joints.firstIndex(where: { $0.index == headNodeIndex }) else {
            continue
        }

        let headJointUInt = UInt32(headJointIndex)
        let mesh = model.meshes[meshIndex]

        for primitive in mesh.primitives {
            guard primitive.hasJoints && primitive.hasWeights,
                  let vertexBuffer = primitive.vertexBuffer,
                  primitive.vertexCount > 0 else { continue }

            let vertices = vertexBuffer.contents().bindMemory(
                to: VRMVertex.self,
                capacity: primitive.vertexCount
            )
            var joints = [SIMD4<UInt32>](repeating: .zero, count: primitive.vertexCount)
            var weights = [SIMD4<Float>](repeating: .zero, count: primitive.vertexCount)
            for i in 0..<primitive.vertexCount {
                joints[i] = vertices[i].joints
                weights[i] = vertices[i].weights
            }

            primitive.firstPersonHiddenFlags = VRMPrimitive.computeFirstPersonHiddenFlags(
                joints: joints,
                weights: weights,
                headJointIndex: headJointUInt
            )
            primitive.uploadFirstPersonHiddenFlagsBuffer(device: device)
        }
    }
}
