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
@_exported import GLTFCore

/// A runtime override of a single node's local transform.
///
/// Any component left `nil` keeps the node's rest-pose value from the
/// document. Pass a dictionary of these to ``GLTFAsset/evaluate(poses:)``
/// to re-pose the scene graph without baked animation clips — e.g. for
/// procedural or game-code-driven node-level transform playback.
public struct GLTFNodePose: Sendable, Equatable {
    public var translation: SIMD3<Float>?
    public var rotation: simd_quatf?
    public var scale: SIMD3<Float>?

    public init(
        translation: SIMD3<Float>? = nil,
        rotation: simd_quatf? = nil,
        scale: SIMD3<Float>? = nil
    ) {
        self.translation = translation
        self.rotation = rotation
        self.scale = scale
    }
}

extension GLTFAsset {
    /// Returns the index of the first node with the given name, or `nil`.
    public func nodeIndex(named name: String) -> Int? {
        (_document.nodes ?? []).firstIndex { $0.name == name }
    }

    /// Returns the rest-pose local TRS of a node with every component
    /// filled in — missing document components default to identity (zero
    /// translation, identity rotation, unit scale). Out-of-range indices
    /// return the identity pose. Useful for composing runtime overrides
    /// onto a node's authored transform (e.g. procedural joint rotation
    /// multiplied onto the rest rotation).
    public func restPose(ofNode index: Int) -> GLTFNodePose {
        let nodes = _document.nodes ?? []
        guard index >= 0, index < nodes.count else {
            return GLTFNodePose(
                translation: SIMD3<Float>(0, 0, 0),
                rotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
                scale: SIMD3<Float>(1, 1, 1)
            )
        }
        let node = nodes[index]
        var translation = SIMD3<Float>(0, 0, 0)
        var rotation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        var scale = SIMD3<Float>(1, 1, 1)
        if let t = node.translation, t.count >= 3 {
            translation = SIMD3<Float>(t[0], t[1], t[2])
        }
        if let r = node.rotation, r.count >= 4 {
            rotation = simd_quatf(ix: r[0], iy: r[1], iz: r[2], r: r[3])
        }
        if let s = node.scale, s.count >= 3 {
            scale = SIMD3<Float>(s[0], s[1], s[2])
        }
        return GLTFNodePose(translation: translation, rotation: rotation, scale: scale)
    }

    /// Re-evaluates the scene with per-node TRS overrides applied on top of
    /// the rest pose and returns a fresh draw list plus the world matrix of
    /// every node. The asset itself is unchanged.
    ///
    /// World matrices are returned so callers can read attach points (seats,
    /// sockets, effectors) after posing — index them with node indices from
    /// ``nodeIndex(named:)``.
    ///
    /// - Parameter poses: Overrides keyed by node index. Unknown or
    ///   out-of-range indices are ignored.
    public func evaluate(
        poses: [Int: GLTFNodePose]
    ) -> (drawCalls: [GLTFDrawCall], worldMatrices: [simd_float4x4]) {
        let nodes = _document.nodes ?? []

        // 1. Start from rest-pose TRS for every node.
        var translations = [SIMD3<Float>](repeating: SIMD3<Float>(0, 0, 0), count: nodes.count)
        var rotations = [simd_quatf](repeating: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1), count: nodes.count)
        var scales = [SIMD3<Float>](repeating: SIMD3<Float>(1, 1, 1), count: nodes.count)
        for (i, node) in nodes.enumerated() {
            if let t = node.translation, t.count >= 3 {
                translations[i] = SIMD3<Float>(t[0], t[1], t[2])
            }
            if let r = node.rotation, r.count >= 4 {
                rotations[i] = simd_quatf(ix: r[0], iy: r[1], iz: r[2], r: r[3])
            }
            if let s = node.scale, s.count >= 3 {
                scales[i] = SIMD3<Float>(s[0], s[1], s[2])
            }
        }

        // 2. Apply overrides. A nil component keeps the rest-pose value.
        for (index, pose) in poses where index >= 0 && index < nodes.count {
            if let t = pose.translation { translations[index] = t }
            if let r = pose.rotation { rotations[index] = r }
            if let s = pose.scale { scales[index] = s }
        }

        // 3. Shared rebuild: world-matrix walk + draw-call rebuild.
        return rebuildDrawCalls(
            translations: translations,
            rotations: rotations,
            scales: scales,
            meshWeights: [:]
        )
    }
}
