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
import VRMAProcessKit

/// Accumulates glTF JSON arrays and the matching BIN chunk for a single-buffer
/// GLB. Every bufferView payload is preceded by zero padding to a 4-byte
/// boundary (`padTo4Bytes`); accessors are tightly packed (no byteStride).
final class GLBBuilder {
    private(set) var bin = Data()
    private(set) var bufferViews: [[String: Any]] = []
    private(set) var accessors: [[String: Any]] = []
    private(set) var meshes: [[String: Any]] = []
    private(set) var nodes: [[String: Any]] = []
    private(set) var materials: [[String: Any]] = []

    private(set) var totalVertices = 0
    private(set) var totalTriangles = 0

    func padTo4Bytes() {
        while bin.count % 4 != 0 { bin.append(0) }
    }

    @discardableResult
    private func appendBufferView(_ payload: Data) -> Int {
        padTo4Bytes()
        let offset = bin.count
        bin.append(payload)
        bufferViews.append(["buffer": 0, "byteOffset": offset, "byteLength": payload.count])
        return bufferViews.count - 1
    }

    private func littleEndianData(_ values: [Float]) -> Data {
        var data = Data(capacity: values.count * 4)
        for value in values {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        return data
    }

    private func littleEndianData(_ values: [UInt16]) -> Data {
        var data = Data(capacity: values.count * 2)
        for value in values {
            var le = value.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        return data
    }

    private func littleEndianData(_ values: [UInt32]) -> Data {
        var data = Data(capacity: values.count * 4)
        for value in values {
            var le = value.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        return data
    }

    private func addAccessor(bufferView: Int, componentType: Int, count: Int, type: String,
                             min: [Float]? = nil, max: [Float]? = nil) -> Int {
        var accessor: [String: Any] = [
            "bufferView": bufferView,
            "componentType": componentType,
            "count": count,
            "type": type,
        ]
        if let min { accessor["min"] = min }
        if let max { accessor["max"] = max }
        accessors.append(accessor)
        return accessors.count - 1
    }

    /// Packs one primitive's geometry (positions, normals, uvs, indices) and
    /// returns the glTF mesh index. Each entry in `parts` becomes one primitive
    /// with its own material.
    @discardableResult
    func addMesh(name: String, parts: [(mesh: MeshData, material: Int)]) -> Int {
        var primitives: [[String: Any]] = []
        for part in parts {
            let mesh = part.mesh
            var flatPositions: [Float] = []
            var flatNormals: [Float] = []
            var flatUVs: [Float] = []
            var minP = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
            var maxP = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
            for i in mesh.positions.indices {
                let p = mesh.positions[i]
                minP = simd_min(minP, p)
                maxP = simd_max(maxP, p)
                flatPositions.append(contentsOf: [p.x, p.y, p.z])
                let n = mesh.normals[i]
                flatNormals.append(contentsOf: [n.x, n.y, n.z])
                let t = mesh.uvs[i]
                flatUVs.append(contentsOf: [t.x, t.y])
            }
            let positionAccessor = addAccessor(
                bufferView: appendBufferView(littleEndianData(flatPositions)),
                componentType: 5126, count: mesh.positions.count, type: "VEC3",
                min: [minP.x, minP.y, minP.z], max: [maxP.x, maxP.y, maxP.z])
            let normalAccessor = addAccessor(
                bufferView: appendBufferView(littleEndianData(flatNormals)),
                componentType: 5126, count: mesh.normals.count, type: "VEC3")
            let uvAccessor = addAccessor(
                bufferView: appendBufferView(littleEndianData(flatUVs)),
                componentType: 5126, count: mesh.uvs.count, type: "VEC2")

            let indexAccessor: Int
            if mesh.positions.count < 65535 {
                indexAccessor = addAccessor(
                    bufferView: appendBufferView(littleEndianData(mesh.indices.map { UInt16($0) })),
                    componentType: 5123, count: mesh.indices.count, type: "SCALAR")
            } else {
                indexAccessor = addAccessor(
                    bufferView: appendBufferView(littleEndianData(mesh.indices)),
                    componentType: 5125, count: mesh.indices.count, type: "SCALAR")
            }

            primitives.append([
                "attributes": ["POSITION": positionAccessor, "NORMAL": normalAccessor, "TEXCOORD_0": uvAccessor],
                "indices": indexAccessor,
                "material": part.material,
                "mode": 4,
            ])
            totalVertices += mesh.positions.count
            totalTriangles += mesh.indices.count / 3
        }
        meshes.append(["name": name, "primitives": primitives])
        return meshes.count - 1
    }

    @discardableResult
    func addMaterial(_ material: [String: Any]) -> Int {
        materials.append(material)
        return materials.count - 1
    }

    @discardableResult
    func addNode(name: String, translation: [Float]? = nil, rotation: [Float]? = nil,
                 scale: [Float]? = nil, mesh: Int? = nil, children: [Int]? = nil) -> Int {
        var node: [String: Any] = ["name": name]
        if let translation { node["translation"] = translation }
        if let rotation { node["rotation"] = rotation }
        if let scale { node["scale"] = scale }
        if let mesh { node["mesh"] = mesh }
        if let children { node["children"] = children }
        nodes.append(node)
        return nodes.count - 1
    }

    /// Wraps the accumulated arrays in a GLB container with scene 0 rooted at
    /// `rootNode`.
    func makeContainer(rootNode: Int) -> GLBContainer {
        let json: [String: Any] = [
            "asset": ["version": "2.0", "generator": "AKIRAHoundGen (VRMMetalKit)"],
            "scene": 0,
            "scenes": [["name": "Scene", "nodes": [rootNode]]],
            "nodes": nodes,
            "meshes": meshes,
            "materials": materials,
            "bufferViews": bufferViews,
            "accessors": accessors,
            "buffers": [["byteLength": bin.count]],
            "extensionsUsed": ["KHR_materials_emissive_strength"],
        ]
        return GLBContainer(json: json, bin: bin)
    }
}

// MARK: - AKIRA-HOUND assembly

/// Quaternion (x, y, z, w) for a rotation of `radians` about the X axis.
func quatX(_ radians: Float) -> [Float] {
    [sin(radians * 0.5), 0, 0, cos(radians * 0.5)]
}

/// Builds the full AKIRA-HOUND asset.
///
/// Conventions:
/// - glTF standard: Y-up, -Z forward (nose at -Z, tail at +Z), metres.
/// - Left legs sit on the -X flank, right legs on +X.
/// - Wheels ride at the KNEE (thigh), not the paw. Each Wheel node is a child
///   of its Knee with a counter-rotation that cancels the cumulative
///   hip × knee fold, so the wheel frame is body-axis-aligned in rest (axle
///   +X) and spinning about local X rolls cleanly with no wobble.
/// - Wheels are large thin rings (radius 0.40, tire half-width 0.045): a dark
///   rubber tire, a proud emissive-cyan rim ring, a dark inner disc, and a
///   small hub with a cyan centre dot.
/// - Rest pose = drive stance: legs folded flat against the flanks with the
///   wheels touching the ground plane y=0 in two close pairs; the lower strut
///   wraps each wheel like a swingarm and the small red-accented foot hovers
///   ~5 cm above the ground (only the wheels touch).
func buildHoundAsset() -> (container: GLBContainer, builder: GLBBuilder) {
    let builder = GLBBuilder()

    // --- Materials ---------------------------------------------------------
    let crimson = builder.addMaterial([
        "name": "CrimsonPaint",
        "pbrMetallicRoughness": [
            "baseColorFactor": [0.55, 0.02, 0.05, 1.0],
            "metallicFactor": 0.9,
            "roughnessFactor": 0.25,
        ],
    ])
    let gunmetal = builder.addMaterial([
        "name": "Gunmetal",
        "pbrMetallicRoughness": [
            "baseColorFactor": [0.25, 0.26, 0.28, 1.0],
            "metallicFactor": 1.0,
            "roughnessFactor": 0.45,
        ],
    ])
    let rubber = builder.addMaterial([
        "name": "Rubber",
        "pbrMetallicRoughness": [
            "baseColorFactor": [0.03, 0.03, 0.035, 1.0],
            "metallicFactor": 0.0,
            "roughnessFactor": 0.9,
        ],
    ])
    let emissiveRed = builder.addMaterial([
        "name": "EmissiveRed",
        "pbrMetallicRoughness": [
            "baseColorFactor": [1.0, 0.05, 0.05, 1.0],
            "metallicFactor": 0.0,
            "roughnessFactor": 0.5,
        ],
        "emissiveFactor": [1.0, 0.05, 0.05],
        "extensions": ["KHR_materials_emissive_strength": ["emissiveStrength": 6.0]],
    ])
    let emissiveCyan = builder.addMaterial([
        "name": "EmissiveCyan",
        "pbrMetallicRoughness": [
            "baseColorFactor": [0.1, 0.9, 1.0, 1.0],
            "metallicFactor": 0.0,
            "roughnessFactor": 0.5,
        ],
        "emissiveFactor": [0.1, 0.9, 1.0],
        "extensions": ["KHR_materials_emissive_strength": ["emissiveStrength": 6.0]],
    ])

    // --- Body meshes -------------------------------------------------------

    // Chassis: long low wedge, nose tapering to a blade tip at z=-1.55, with
    // an open seat dip mid-body (top drops to 0.58 between the cowl rise and
    // the tail hump) and a kicked tail at z=+1.55. Bodywork rises well above
    // the wheel-top line (0.80) — the wheels must not swallow the silhouette.
    // Sections are (z, yBottom, yTop, halfWidth).
    let chassisSections: [LoftSection] = [
        LoftSection(z: -1.55, yBottom: 0.46, yTop: 0.54, halfWidth: 0.015),
        LoftSection(z: -1.20, yBottom: 0.40, yTop: 0.60, halfWidth: 0.10),
        LoftSection(z: -0.60, yBottom: 0.36, yTop: 0.74, halfWidth: 0.22),
        LoftSection(z: -0.10, yBottom: 0.34, yTop: 0.58, halfWidth: 0.27),
        LoftSection(z: 0.35, yBottom: 0.34, yTop: 0.58, halfWidth: 0.27),
        LoftSection(z: 0.80, yBottom: 0.36, yTop: 0.68, halfWidth: 0.26),
        LoftSection(z: 1.20, yBottom: 0.42, yTop: 0.76, halfWidth: 0.24),
        LoftSection(z: 1.55, yBottom: 0.58, yTop: 0.80, halfWidth: 0.16),
    ]
    let chassisMesh = builder.addMesh(name: "ChassisMesh", parts: [(makeLoft(sections: chassisSections), crimson)])

    // Nose cowl: pointed shield shroud wrapping the chassis nose, lower and
    // wider. The tall front shield face carries the cyclops eye high — the
    // bounds-fit front camera crops the low nose tip out of frame, so the eye
    // must sit near the top of the shield to read head-on.
    let cowlMesh = builder.addMesh(name: "NoseCowlMesh", parts: [(makeLoft(sections: [
        LoftSection(z: -1.66, yBottom: 0.32, yTop: 0.68, halfWidth: 0.10),
        LoftSection(z: -1.40, yBottom: 0.28, yTop: 0.62, halfWidth: 0.13),
        LoftSection(z: -1.05, yBottom: 0.30, yTop: 0.66, halfWidth: 0.17),
        LoftSection(z: -0.75, yBottom: 0.36, yTop: 0.72, halfWidth: 0.21),
    ]), crimson)])

    // Headlight: cyclops lens on the cowl's shield face, axis along Z. It
    // protrudes well proud of the face so the glowing side wall still reads
    // from grazing camera angles (the bounds-fit front camera gets very close
    // to the nose).
    let headlightMesh = builder.addMesh(name: "HeadlightMesh", parts: [
        (makeCylinder(axis: SIMD3(0, 0, 1), radius: 0.06, halfLength: 0.05, segments: 20), emissiveCyan),
    ])

    // Cowl slit lights: small red slits on the shield face, flanking the eye
    // like angry eyebrows (front view). They poke just proud of the face.
    let cowlSlitMesh = builder.addMesh(name: "CowlSlitMesh", parts: [
        (makeBox(size: SIMD3(0.045, 0.014, 0.02)), emissiveRed),
    ])

    // Spine fairing: no more sail — a low tail hump behind the seat dip,
    // rising gently and kicking up into a ducktail tip (peak y≈1.00).
    let spineMesh = builder.addMesh(name: "SpineFairingMesh", parts: [(makeLoft(sections: [
        LoftSection(z: 0.20, yBottom: 0.56, yTop: 0.64, halfWidth: 0.14),
        LoftSection(z: 0.50, yBottom: 0.56, yTop: 0.78, halfWidth: 0.17),
        LoftSection(z: 0.85, yBottom: 0.56, yTop: 0.88, halfWidth: 0.18),
        LoftSection(z: 1.15, yBottom: 0.58, yTop: 0.95, halfWidth: 0.16),
        LoftSection(z: 1.35, yBottom: 0.62, yTop: 1.00, halfWidth: 0.14),
        LoftSection(z: 1.56, yBottom: 0.70, yTop: 0.90, halfWidth: 0.09),
    ]), crimson)])

    // Seat pan: dark pad lying in the open dip between the cowl back and the
    // tail hump — the rider sits IN the body, not on top of it. Wide enough to
    // cover the chassis' dip top so the channel reads as a seat; gunmetal,
    // because the rubber material blows out cream on this big horizontal face
    // under the demo's sky IBL.
    let seatPanMesh = builder.addMesh(name: "SeatPanMesh", parts: [(makeLoft(sections: [
        LoftSection(z: -0.42, yBottom: 0.56, yTop: 0.60, halfWidth: 0.20),
        LoftSection(z: -0.10, yBottom: 0.555, yTop: 0.615, halfWidth: 0.24),
        LoftSection(z: 0.28, yBottom: 0.56, yTop: 0.62, halfWidth: 0.22),
    ]), gunmetal)])

    // Flank light strips: thin vertical blades along the LOWER flank edge,
    // derived from the mid-body chassis sections so they follow the taper.
    // Two meshes (mirroring via negative scale would flip face winding).
    func makeStrip(side: Float) -> MeshData {
        var sections: [LoftSection] = []
        for s in chassisSections[1...6] {
            sections.append(LoftSection(z: s.z, yBottom: 0.44, yTop: 0.47,
                                        halfWidth: 0.008, xCenter: side * (s.halfWidth + 0.002)))
        }
        return makeLoft(sections: sections)
    }
    let stripLMesh = builder.addMesh(name: "StripFlankLMesh", parts: [(makeStrip(side: -1), emissiveRed)])
    let stripRMesh = builder.addMesh(name: "StripFlankRMesh", parts: [(makeStrip(side: 1), emissiveRed)])

    // Tail bar: full-width light bar across the kicked-up tail — wider than
    // the tail sections so both ends stand proud of the bodywork.
    let tailBarMesh = builder.addMesh(name: "TailBarMesh", parts: [
        (makeBox(size: SIMD3(0.40, 0.05, 0.06)), emissiveRed),
    ])

    // --- Leg meshes (shared across all four legs) --------------------------

    // Struts run from their parent joint origin down local -Y; the joint's rest
    // rotation aims them. Upper strut length matches the hip→knee offset.
    // Upper = gunmetal (reads as the swingarm in drive mode); lower = crimson
    // armour (the red armoured segment below the wheel in walk mode).
    let upperMesh = builder.addMesh(name: "UpperStrutMesh", parts: [
        (makeBox(size: SIMD3(0.10, 0.55, 0.14)).translated(by: SIMD3(0, -0.275, 0)), gunmetal),
    ])
    let lowerMesh = builder.addMesh(name: "LowerStrutMesh", parts: [
        (makeBox(size: SIMD3(0.08, 0.55, 0.11)).translated(by: SIMD3(0, -0.275, 0)), crimson),
    ])
    // Knee strip: red glow blade hugging the lower strut's outer face.
    let kneeStripMesh = builder.addMesh(name: "KneeStripMesh", parts: [
        (makeBox(size: SIMD3(0.025, 0.45, 0.08)).translated(by: SIMD3(0, -0.30, 0)), emissiveRed),
    ])

    // Ankle joint ring: small glowing cyan collar with a dark centre cap,
    // attached to the Ankle node so it follows the joint in both modes.
    let ankleRingMesh = builder.addMesh(name: "AnkleRingMesh", parts: [
        (makeCylinder(axis: SIMD3(1, 0, 0), radius: 0.055, halfLength: 0.055, segments: 20), emissiveCyan),
        (makeCylinder(axis: SIMD3(1, 0, 0), radius: 0.034, halfLength: 0.058, segments: 16), gunmetal),
    ])

    // Paw strut: slim cannon link closing the ankle→paw link. Authored in the
    // PAW frame pointing UP local +Y: spans y 0…+0.30 from the paw origin to
    // the ankle origin (the ±0.02 x slant is inside the 0.06 width). Without
    // this the foot floats 0.30 m below the ankle ring, detached.
    let pawStrutMesh = builder.addMesh(name: "PawStrutMesh", parts: [
        (makeBox(size: SIMD3(0.06, 0.30, 0.09)).translated(by: SIMD3(0, 0.15, 0)), gunmetal),
    ])

    // Wheel: large thin ring, axle along +X. Layered cylinders prouder toward
    // the middle of the face stack, so the outer face reads (outside → in):
    // rubber tire edge (r 0.365–0.40), proud glowing cyan rim ring
    // (r 0.325–0.365), dark inner disc (r 0.10–0.325), gunmetal hub, cyan
    // centre dot. Three primitives would do; five make the rim read as a ring.
    let wheelMesh = builder.addMesh(name: "WheelMesh", parts: [
        (makeCylinder(axis: SIMD3(1, 0, 0), radius: 0.40, halfLength: 0.045, segments: 40), rubber),
        (makeCylinder(axis: SIMD3(1, 0, 0), radius: 0.365, halfLength: 0.0475, segments: 40), emissiveCyan),
        (makeCylinder(axis: SIMD3(1, 0, 0), radius: 0.325, halfLength: 0.050, segments: 32), rubber),
        (makeCylinder(axis: SIMD3(1, 0, 0), radius: 0.10, halfLength: 0.058, segments: 20), gunmetal),
        (makeCylinder(axis: SIMD3(1, 0, 0), radius: 0.04, halfLength: 0.060, segments: 16), emissiveCyan),
    ])

    // Foot: small digitigrade toe — dark pad with a glowing crimson toe cap.
    // Compact and kept tight against the paw origin: in the tucked rest pose
    // (paw at y≈0.05) its lowest corner sits ~0.03 m up, so only the wheels
    // touch the ground; in walk the paw plants and the toe reads as the hoof.
    let footPadMesh = builder.addMesh(name: "FootPadMesh", parts: [
        (makeBox(size: SIMD3(0.085, 0.04, 0.13)).translated(by: SIMD3(0, 0, -0.015)), rubber),
        (makeBox(size: SIMD3(0.06, 0.024, 0.04)).translated(by: SIMD3(0, 0.005, -0.075)), emissiveRed),
    ])

    // --- Nodes -------------------------------------------------------------

    let chassisNode = builder.addNode(name: "Chassis", mesh: chassisMesh)
    let cowlNode = builder.addNode(name: "Nose_Cowl", mesh: cowlMesh)
    let headlightNode = builder.addNode(name: "Headlight", translation: [0, 0.56, -1.63],
                                        mesh: headlightMesh)
    let slitLNode = builder.addNode(name: "Cowl_Slit_L", translation: [-0.075, 0.615, -1.652],
                                    mesh: cowlSlitMesh)
    let slitRNode = builder.addNode(name: "Cowl_Slit_R", translation: [0.075, 0.615, -1.652],
                                    mesh: cowlSlitMesh)
    let spineNode = builder.addNode(name: "Spine_Fairing", mesh: spineMesh)
    let seatPanNode = builder.addNode(name: "Seat_Pan", mesh: seatPanMesh)
    let stripLNode = builder.addNode(name: "Strip_Flank_L", mesh: stripLMesh)
    let stripRNode = builder.addNode(name: "Strip_Flank_R", mesh: stripRMesh)
    let tailBarNode = builder.addNode(name: "Tail_Bar", translation: [0, 0.79, 1.54],
                                      mesh: tailBarMesh)
    // Rider attach point: down in the open seat dip between cowl back and hump.
    let seatMountNode = builder.addNode(name: "Seat_Mount", translation: [0, 0.66, 0.02])

    // Leg rest pose. Segments (upper 0.55, lower 0.55, paw link 0.30) fold in
    // the YZ plane with hip/knee/ankle X-rotations α, -2α, α — cumulative paw
    // rotation is identity by construction. The wheel rides at the KNEE, so α
    // solves the tuck with the knee centre at wheel-centre height:
    //
    //   kneeY = hipY - 0.55·cos(α) = wheelRadius  →  0.40 = 0.45 - 0.55·cos(α)
    //
    // gives cos(α) = 0.05/0.55. The upper strut lies nearly horizontal
    // (swingarm-style), the lower strut folds back under the belly, and the
    // paw (ankle frame == body frame) ends at y≈0.05 with the small foot
    // skimming above the ground — only the wheels touch. Front legs fold with
    // the knee swung forward (α > 0), rear legs mirrored (α < 0); hips are
    // close together (z=∓0.18) so the r=0.40 wheel circles nearly touch.
    let alpha = acos(Float(0.05) / Float(0.55))  // ≈ 84.8°

    func addLeg(prefix: String, side: Float, front: Bool) -> Int {
        let a = front ? alpha : -alpha
        let hipZ: Float = front ? -0.18 : 0.18

        // Foot: digitigrade toe tipped up ~17°, tucked against the paw origin
        // so its lowest corner clears the ground by ~0.03 m in the tuck (only
        // the wheels touch in drive stance); the paw strut connects it to the
        // ankle so the leg reads as one mechanism in both modes.
        let footPadNode = builder.addNode(name: "Leg_\(prefix)_FootPad",
                                          translation: [0, 0.015, 0],
                                          rotation: quatX(0.30), mesh: footPadMesh)
        let pawNode = builder.addNode(name: "Leg_\(prefix)_Paw",
                                      translation: [-side * 0.02, -0.30, 0],
                                      mesh: pawStrutMesh,
                                      children: [footPadNode])
        let ankleNode = builder.addNode(name: "Leg_\(prefix)_Ankle",
                                        translation: [0, -0.55, 0],
                                        rotation: quatX(a),
                                        mesh: ankleRingMesh,
                                        children: [pawNode])
        let lowerNode = builder.addNode(name: "Leg_\(prefix)_Lower", mesh: lowerMesh)
        let kneeStripNode = builder.addNode(name: "Leg_\(prefix)_KneeStrip",
                                            translation: [side * 0.055, 0, 0],
                                            rotation: quatX(0.10), mesh: kneeStripMesh)
        // Wheel: child of the KNEE. Hip × knee accumulates a −2a = −a, so the
        // wheel carries +a to cancel it — its frame is body-axis-aligned in
        // rest (axle +X, clean local-X spin). Knee-frame X is body X (the fold
        // rotates about X), so the small lateral translation shifts the wheel
        // centre from hip x=±0.30 to the ±0.28 axle line.
        let wheelNode = builder.addNode(name: "Leg_\(prefix)_Wheel",
                                        translation: [-side * 0.02, 0, 0],
                                        rotation: quatX(a),
                                        mesh: wheelMesh)
        let kneeNode = builder.addNode(name: "Leg_\(prefix)_Knee",
                                       translation: [0, -0.55, 0],
                                       rotation: quatX(-2 * a),
                                       children: [kneeStripNode, lowerNode, ankleNode, wheelNode])
        let upperNode = builder.addNode(name: "Leg_\(prefix)_Upper", mesh: upperMesh)
        let hipNode = builder.addNode(name: "Leg_\(prefix)_Hip",
                                      translation: [side * 0.30, 0.45, hipZ],
                                      rotation: quatX(a),
                                      children: [upperNode, kneeNode])
        return hipNode
    }

    let hipFL = addLeg(prefix: "FL", side: -1, front: true)
    let hipFR = addLeg(prefix: "FR", side: 1, front: true)
    let hipRL = addLeg(prefix: "RL", side: -1, front: false)
    let hipRR = addLeg(prefix: "RR", side: 1, front: false)

    let bodyNode = builder.addNode(name: "Body", children: [
        chassisNode, cowlNode, headlightNode, slitLNode, slitRNode, spineNode,
        seatPanNode, stripLNode, stripRNode, tailBarNode, seatMountNode,
        hipFL, hipFR, hipRL, hipRR,
    ])
    let rootNode = builder.addNode(name: "HOUND_Root", children: [bodyNode])

    return (builder.makeContainer(rootNode: rootNode), builder)
}
