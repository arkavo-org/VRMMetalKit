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

/// Mesh-aware breast collider sizing (#377). On VRoid rigs the visible breast
/// surface rides FORWARD on the spring-driven `Bust` bones (`J_Sec_*_Bust*`),
/// tens of millimetres beyond the authored chest colliders — which sit back on
/// `UpperChest` (the breast spheres are even offset *behind* the sternum). Hair
/// therefore rests legally on the authored/synthetic chest colliders yet still
/// pierces the forward breast MESH. No collision-response change (swept twins,
/// segment collision) can fix that — only a collider that actually reaches the
/// breast surface.
///
/// This fits a per-side bounding sphere to the *skinned* breast mesh so a
/// synthetic swept collider can hug the breast and follow its spring motion
/// (anchored on the side's `Bust1`). Unlike `SpringBoneColliderAugmentor` /
/// `SpringBoneBoneGeometry` (pure, bone-derived), this reads the skinned vertex
/// buffers, so it must run at load where the device-backed buffers exist.
enum SpringBoneBreastCollider {

    /// A fitted per-side breast sphere. `offset` is the sphere centre expressed
    /// in the anchor node's LOCAL frame, so re-applying the anchor's world
    /// matrix each frame rides the breast's spring motion.
    struct BreastSphere: Equatable {
        let node: Int
        let offset: SIMD3<Float>
        let radius: Float
    }

    /// One fitted breast per `Bust` spring chain: the anchor (side's Bust1), the
    /// world-space centroid of the skinned breast surface, and a radius at the
    /// given percentile of vertex-to-centroid distance.
    private struct BreastFit {
        let anchor: Int
        let centroidWorld: SIMD3<Float>
        let radius: Float
    }

    private static func fitBreasts(model: VRMModel, radiusPercentile: Float) -> [BreastFit] {
        SpringBoneMeshFit.computeBreastFits(model: model, radiusPercentile: radiusPercentile).map {
            BreastFit(anchor: $0.anchor, centroidWorld: $0.centroidWorld, radius: $0.radius)
        }
    }

    /// Per-side breast bounding spheres (the MEASURING stick / mesh proxy).
    static func computeBreastSpheres(model: VRMModel,
                                     radiusPercentile: Float = 0.92) -> [BreastSphere] {
        var out: [BreastSphere] = []
        for fit in fitBreasts(model: model, radiusPercentile: radiusPercentile) {
            let anchorWorld = model.nodes[fit.anchor].worldMatrix
            let local = simd_inverse(anchorWorld) * SIMD4<Float>(fit.centroidWorld, 1)
            guard local.x.isFinite, local.y.isFinite, local.z.isFinite else { continue }
            out.append(BreastSphere(node: fit.anchor,
                                    offset: SIMD3<Float>(local.x, local.y, local.z),
                                    radius: fit.radius))
        }
        return out
    }

    /// Per-side breast COLLIDERS for the swept synthetic group (#377). A sphere at
    /// the breast bulge leaves the superior entry open — hair enters at the
    /// collarbone and slides down BEHIND it into the breast. So each collider is a
    /// CAPSULE spanning from the upperChest (the collarbone-height entry) down to
    /// the breast centroid, radius fitted to enclose the breast surface. Anchored
    /// on the side's Bust1 so it rides the breast's spring motion. Empty when the
    /// rig has no `Bust` spring / body mesh / upperChest bone.
    static func computeBreastColliders(model: VRMModel,
                                       radiusPercentile: Float = 1.0,
                                       radiusScale: Float = 1.0) -> [VRMCollider] {
        SpringBoneMeshFit.computeBreastColliders(
            model: model,
            radiusPercentile: radiusPercentile,
            radiusScale: radiusScale
        )
    }

    /// Per-side deltoid/shoulder COLLIDERS for the swept synthetic group (#377
    /// upper body). The clothed shoulder (dress/skin) sits outside the
    /// bone-derived shoulder sphere, so hair sinks through it during dynamic
    /// motion. Fits a swept sphere to the PROXIMAL clothed shoulder mesh (verts
    /// weighted to the shoulder/upperArm bones within half an arm-length of the
    /// socket), anchored on the upperArm so it rides the arm. Empty when the
    /// bones / body mesh don't resolve.
    ///
    /// The proximity filter alone is a RADIUS filter with no directional
    /// component: verts on the collarbone/décolletage side of the arm socket
    /// fall inside the same half-arm-length ball as the deltoid cap and get
    /// averaged into the fit, dragging the centroid toward the midline and
    /// bulging the sphere across the front gap between the two shoulders (#309
    /// lookUp regression — measured 1.76-1.88x the authored shoulder radius,
    /// against 1.0-1.5x for every other grounded/mesh-fitted collider in this
    /// file). A second filter along the shoulder→upperArm axis drops anything
    /// medial of the socket before the centroid/radius are computed, so the fit
    /// only sees the deltoid cap the collider is meant to cover.
    static func computeShoulderColliders(model: VRMModel,
                                         radiusPercentile: Float = 0.95,
                                         radiusScale: Float = 1.0) -> [VRMCollider] {
        SpringBoneMeshFit.computeShoulderColliders(
            model: model,
            radiusPercentile: radiusPercentile,
            radiusScale: radiusScale
        )
    }

    /// Mesh-fitted upper-TORSO collider (#377 upper body): the clothed upper
    /// chest / décolletage (ABOVE the breast) and the sides/back of the upper
    /// torso (BEHIND the breast) sit outside the bone-derived midline torso
    /// capsule, so hair sinks through the dress there. Fits a swept capsule along
    /// the spine→upperChest axis with a radius fitted to the clothed torso
    /// surface (verts weighted to spine/chest/upperChest, EXCLUDING the bust which
    /// the breast capsule already covers). Anchored on the spine. Empty when the
    /// bones / skinned meshes don't resolve.
    static func computeTorsoCollider(model: VRMModel,
                                     radiusPercentile: Float = 0.90,
                                     radiusScale: Float = 1.0) -> [VRMCollider] {
        SpringBoneMeshFit.computeTorsoCollider(
            model: model,
            radiusPercentile: radiusPercentile,
            radiusScale: radiusScale
        )
    }
}
