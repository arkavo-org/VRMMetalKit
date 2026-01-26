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

import simd

/// Simple mesh representation for Z-fighting tests.
struct TestMesh {
    let positions: [SIMD3<Float>]
    let normals: [SIMD3<Float>]
    let indices: [UInt16]
    let color: SIMD4<Float>
}

/// Generates test geometry for Z-fighting detection.
/// Creates coplanar surfaces that should trigger Z-fighting when rendered
/// without proper depth bias or separation.
struct CoplanarTestGeometry {

    /// Create two overlapping quads at the same Z depth.
    /// These quads will Z-fight when rendered together.
    /// - Parameters:
    ///   - z: Z depth for both quads
    ///   - separation: Z separation between quads (0 = exactly coplanar)
    ///   - size: Size of each quad
    /// - Returns: Tuple of two TestMesh objects
    static func createCoplanarQuads(
        z: Float = 1.0,
        separation: Float = 0.0,
        size: Float = 0.5
    ) -> (quad1: TestMesh, quad2: TestMesh) {
        let normal = SIMD3<Float>(0, 0, 1)

        let quad1Positions: [SIMD3<Float>] = [
            SIMD3(-size, -size, z),
            SIMD3(size, -size, z),
            SIMD3(size, size, z),
            SIMD3(-size, size, z)
        ]

        let quad2Positions: [SIMD3<Float>] = [
            SIMD3(-size, -size, z + separation),
            SIMD3(size, -size, z + separation),
            SIMD3(size, size, z + separation),
            SIMD3(-size, size, z + separation)
        ]

        let normals = [normal, normal, normal, normal]
        let indices: [UInt16] = [0, 1, 2, 0, 2, 3]

        let quad1 = TestMesh(
            positions: quad1Positions,
            normals: normals,
            indices: indices,
            color: SIMD4<Float>(1, 0, 0, 1)
        )

        let quad2 = TestMesh(
            positions: quad2Positions,
            normals: normals,
            indices: indices,
            color: SIMD4<Float>(0, 0, 1, 1)
        )

        return (quad1, quad2)
    }

    /// Create overlapping quads at the same depth with interleaved triangles.
    /// This maximizes Z-fighting visibility by ensuring both surfaces
    /// are rendered at nearly identical depths.
    /// - Parameters:
    ///   - z: Z depth
    ///   - size: Quad size
    /// - Returns: TestMesh with interleaved triangles from both surfaces
    static func createInterleavedCoplanarQuads(
        z: Float = 1.0,
        size: Float = 0.5
    ) -> TestMesh {
        let normal = SIMD3<Float>(0, 0, 1)

        let positions: [SIMD3<Float>] = [
            SIMD3(-size, -size, z),
            SIMD3(size, -size, z),
            SIMD3(size, size, z),
            SIMD3(-size, size, z),
            SIMD3(-size, -size, z),
            SIMD3(size, -size, z),
            SIMD3(size, size, z),
            SIMD3(-size, size, z)
        ]

        let normals = Array(repeating: normal, count: 8)
        let indices: [UInt16] = [
            0, 1, 2,
            4, 5, 6,
            0, 2, 3,
            4, 6, 7
        ]

        return TestMesh(
            positions: positions,
            normals: normals,
            indices: indices,
            color: SIMD4<Float>(0.5, 0.5, 0.5, 1)
        )
    }
}

/// Generates face layer geometry that mimics VRM face material stacking.
/// VRM models have multiple coplanar face layers (skin, eyebrow, eyeline, eye, highlight)
/// that require proper depth bias to avoid Z-fighting.
struct FaceLayerTestGeometry {

    /// Face layer definition with associated depth bias.
    struct FaceLayer {
        let name: String
        let mesh: TestMesh
        let depthBias: Float
        let renderOrder: Int
    }

    /// Create a set of face layers mimicking VRM face material structure.
    /// - Parameter z: Base Z depth for all layers
    /// - Returns: Array of FaceLayer objects
    static func createFaceLayers(z: Float = 1.0) -> [FaceLayer] {
        let normal = SIMD3<Float>(0, 0, 1)
        let size: Float = 0.3

        func createQuad(color: SIMD4<Float>) -> TestMesh {
            let positions: [SIMD3<Float>] = [
                SIMD3(-size, -size, z),
                SIMD3(size, -size, z),
                SIMD3(size, size, z),
                SIMD3(-size, size, z)
            ]
            let normals = Array(repeating: normal, count: 4)
            let indices: [UInt16] = [0, 1, 2, 0, 2, 3]
            return TestMesh(positions: positions, normals: normals, indices: indices, color: color)
        }

        return [
            FaceLayer(
                name: "faceSkin",
                mesh: createQuad(color: SIMD4<Float>(1.0, 0.8, 0.7, 1)),
                depthBias: -0.0001,
                renderOrder: 1
            ),
            FaceLayer(
                name: "faceEyebrow",
                mesh: createQuad(color: SIMD4<Float>(0.3, 0.2, 0.1, 1)),
                depthBias: -0.0002,
                renderOrder: 2
            ),
            FaceLayer(
                name: "faceEyeline",
                mesh: createQuad(color: SIMD4<Float>(0.1, 0.1, 0.1, 1)),
                depthBias: -0.0002,
                renderOrder: 3
            ),
            FaceLayer(
                name: "faceEye",
                mesh: createQuad(color: SIMD4<Float>(0.2, 0.5, 0.8, 1)),
                depthBias: -0.0002,
                renderOrder: 4
            ),
            FaceLayer(
                name: "faceHighlight",
                mesh: createQuad(color: SIMD4<Float>(1, 1, 1, 0.5)),
                depthBias: -0.0003,
                renderOrder: 5
            )
        ]
    }

    /// Create layers with varying separation to test Z-fighting thresholds.
    /// - Parameters:
    ///   - z: Base Z depth
    ///   - separations: Array of Z separations between consecutive layers
    /// - Returns: Array of FaceLayer objects
    static func createLayersWithSeparations(
        z: Float = 1.0,
        separations: [Float]
    ) -> [FaceLayer] {
        let normal = SIMD3<Float>(0, 0, 1)
        let size: Float = 0.3

        var layers: [FaceLayer] = []
        var currentZ = z

        let colors: [SIMD4<Float>] = [
            SIMD4<Float>(1, 0, 0, 1),
            SIMD4<Float>(0, 1, 0, 1),
            SIMD4<Float>(0, 0, 1, 1),
            SIMD4<Float>(1, 1, 0, 1),
            SIMD4<Float>(1, 0, 1, 1)
        ]

        for (index, separation) in separations.enumerated() {
            let positions: [SIMD3<Float>] = [
                SIMD3(-size, -size, currentZ),
                SIMD3(size, -size, currentZ),
                SIMD3(size, size, currentZ),
                SIMD3(-size, size, currentZ)
            ]
            let normals = Array(repeating: normal, count: 4)
            let indices: [UInt16] = [0, 1, 2, 0, 2, 3]
            let color = colors[index % colors.count]

            let mesh = TestMesh(positions: positions, normals: normals, indices: indices, color: color)
            layers.append(FaceLayer(
                name: "layer_\(index)",
                mesh: mesh,
                depthBias: 0,
                renderOrder: index
            ))

            currentZ += separation
        }

        return layers
    }
}

/// Generates test geometry at various distances to test depth precision degradation.
struct DistanceTestGeometry {

    /// Create quads at various distances from the camera.
    /// - Parameter distances: Array of distances to create quads at
    /// - Returns: Array of TestMesh objects
    static func createQuadsAtDistances(_ distances: [Float]) -> [TestMesh] {
        let normal = SIMD3<Float>(0, 0, 1)
        let size: Float = 0.2

        return distances.enumerated().map { index, distance in
            let positions: [SIMD3<Float>] = [
                SIMD3(-size, -size, distance),
                SIMD3(size, -size, distance),
                SIMD3(size, size, distance),
                SIMD3(-size, size, distance)
            ]
            let normals = Array(repeating: normal, count: 4)
            let indices: [UInt16] = [0, 1, 2, 0, 2, 3]

            let hue = Float(index) / Float(distances.count)
            let color = hueToRGB(hue)

            return TestMesh(positions: positions, normals: normals, indices: indices, color: color)
        }
    }

    /// Create coplanar quads at a specific distance.
    /// - Parameters:
    ///   - distance: Distance from camera
    ///   - count: Number of coplanar quads
    /// - Returns: Array of TestMesh objects all at the same depth
    static func createCoplanarQuadsAtDistance(distance: Float, count: Int = 2) -> [TestMesh] {
        let normal = SIMD3<Float>(0, 0, 1)
        let size: Float = 0.3

        return (0..<count).map { index in
            let positions: [SIMD3<Float>] = [
                SIMD3(-size, -size, distance),
                SIMD3(size, -size, distance),
                SIMD3(size, size, distance),
                SIMD3(-size, size, distance)
            ]
            let normals = Array(repeating: normal, count: 4)
            let indices: [UInt16] = [0, 1, 2, 0, 2, 3]

            let hue = Float(index) / Float(count)
            let color = hueToRGB(hue)

            return TestMesh(positions: positions, normals: normals, indices: indices, color: color)
        }
    }

    private static func hueToRGB(_ hue: Float) -> SIMD4<Float> {
        let h = hue * 6
        let x = 1 - abs(h.truncatingRemainder(dividingBy: 2) - 1)

        var r: Float = 0
        var g: Float = 0
        var b: Float = 0

        switch Int(h) {
        case 0: (r, g, b) = (1, x, 0)
        case 1: (r, g, b) = (x, 1, 0)
        case 2: (r, g, b) = (0, 1, x)
        case 3: (r, g, b) = (0, x, 1)
        case 4: (r, g, b) = (x, 0, 1)
        default: (r, g, b) = (1, 0, x)
        }

        return SIMD4<Float>(r, g, b, 1)
    }
}
