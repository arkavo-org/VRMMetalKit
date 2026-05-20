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
import simd

/// Helper functions for traversing and computing matrix hierarchies on glTF scene graphs.
public enum GLTFSceneGraph {

    /// Recursively computes the world matrix of every node, starting from
    /// scene roots. Run once after parsing TRS / matrix and before scene
    /// traversal so skin-palette computation has every joint's transform.
    public static func computeWorldMatrices(
        document: GLTFDocument,
        into output: inout [simd_float4x4]
    ) {
        guard let nodes = document.nodes else { return }
        let sceneIndex = document.scene ?? 0
        let scenes = document.scenes ?? []
        guard sceneIndex < scenes.count else { return }

        func walk(_ nodeIndex: Int, parent: simd_float4x4) {
            guard nodeIndex < nodes.count else { return }
            let local = localMatrix(for: nodes[nodeIndex])
            let world = parent * local
            output[nodeIndex] = world
            for child in nodes[nodeIndex].children ?? [] {
                walk(child, parent: world)
            }
        }

        for root in scenes[sceneIndex].nodes ?? [] {
            walk(root, parent: matrix_identity_float4x4)
        }
    }

    /// Computes the 4x4 local matrix of a glTF node from its matrix or TRS fields.
    public static func localMatrix(for node: GLTFNode) -> simd_float4x4 {
        if let m = node.matrix, m.count == 16 {
            // glTF stores column-major, matching simd_float4x4.
            return simd_float4x4(
                SIMD4<Float>(m[0],  m[1],  m[2],  m[3]),
                SIMD4<Float>(m[4],  m[5],  m[6],  m[7]),
                SIMD4<Float>(m[8],  m[9],  m[10], m[11]),
                SIMD4<Float>(m[12], m[13], m[14], m[15])
            )
        }

        let translation: SIMD3<Float> = {
            if let t = node.translation, t.count >= 3 { return SIMD3<Float>(t[0], t[1], t[2]) }
            return SIMD3<Float>(0, 0, 0)
        }()
        let rotation: simd_quatf = {
            if let r = node.rotation, r.count >= 4 {
                return simd_quatf(ix: r[0], iy: r[1], iz: r[2], r: r[3])
            }
            return simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        }()
        let scale: SIMD3<Float> = {
            if let s = node.scale, s.count >= 3 { return SIMD3<Float>(s[0], s[1], s[2]) }
            return SIMD3<Float>(1, 1, 1)
        }()

        let t = simd_float4x4(translation: translation)
        let r = simd_float4x4(rotation)
        let s = simd_float4x4(scale: scale)
        return t * r * s
    }
}

// MARK: - simd_float4x4 helpers

public extension simd_float4x4 {
    init(translation t: SIMD3<Float>) {
        self.init(
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(t.x, t.y, t.z, 1)
        )
    }
    init(scale s: SIMD3<Float>) {
        self.init(
            SIMD4<Float>(s.x, 0, 0, 0),
            SIMD4<Float>(0, s.y, 0, 0),
            SIMD4<Float>(0, 0, s.z, 0),
            SIMD4<Float>(0, 0, 0, 1)
        )
    }
}
