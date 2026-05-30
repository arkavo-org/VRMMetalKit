//
// Copyright 2025 Arkavo
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//

import Foundation
import simd
import XCTest
@testable import VRMMetalKit

/// Test-only ground-truth oracle for SpringBone collider conformance (#309).
///
/// A hand-fit set of "skin-reference" colliders that trace AvatarSample_A's real
/// skin surface. Used ONLY in tests to assert that hair/cloth joints stay outside
/// the avatar's body. NEVER shipped as runtime colliders.
///
/// The JSON lives at `TestData/SpringBoneOracle/avatar_a_skin_reference.json` and
/// loads via `Bundle.module`, mirroring `SpringBoneRegressionTests.loadBaseline`.
struct SkinReferenceOracle: Decodable {
    /// Cheap fingerprint of the model the oracle was authored against, so a test
    /// can fail loudly if the fixture mesh drifts out from under the oracle.
    struct Integrity: Decodable {
        let vertexCount: Int
        let bboxMinY: Float
        let bboxMaxY: Float
    }

    /// One bone-local oracle shape (sphere or capsule).
    ///
    /// `VRMHumanoidBone` is not `Decodable` in the production target, so `bone`
    /// and `tailBone` are decoded from their `rawValue` strings here rather than
    /// adding a conformance to the shipped enum.
    struct Shape: Decodable {
        let bone: VRMHumanoidBone
        let kind: String
        let offset: SIMD3<Float>
        let tail: SIMD3<Float>?
        let tailBone: VRMHumanoidBone?
        let radius: Float

        private enum CodingKeys: String, CodingKey {
            case bone, kind, offset, tail, tailBone, radius
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let boneRaw = try c.decode(String.self, forKey: .bone)
            guard let bone = VRMHumanoidBone(rawValue: boneRaw) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .bone, in: c,
                    debugDescription: "Unknown VRMHumanoidBone rawValue '\(boneRaw)'")
            }
            self.bone = bone
            self.kind = try c.decode(String.self, forKey: .kind)
            self.offset = try Shape.decodeVec3(c, .offset)
            self.tail = try Shape.decodeVec3Optional(c, .tail)
            if let tbRaw = try c.decodeIfPresent(String.self, forKey: .tailBone) {
                guard let tb = VRMHumanoidBone(rawValue: tbRaw) else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .tailBone, in: c,
                        debugDescription: "Unknown VRMHumanoidBone rawValue '\(tbRaw)'")
                }
                self.tailBone = tb
            } else {
                self.tailBone = nil
            }
            self.radius = try c.decode(Float.self, forKey: .radius)
        }

        private static func decodeVec3(
            _ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys
        ) throws -> SIMD3<Float> {
            let a = try c.decode([Float].self, forKey: key)
            guard a.count == 3 else {
                throw DecodingError.dataCorruptedError(
                    forKey: key, in: c,
                    debugDescription: "Expected 3-element array for \(key.stringValue), got \(a.count)")
            }
            return SIMD3<Float>(a[0], a[1], a[2])
        }

        private static func decodeVec3Optional(
            _ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys
        ) throws -> SIMD3<Float>? {
            guard let a = try c.decodeIfPresent([Float].self, forKey: key) else { return nil }
            guard a.count == 3 else {
                throw DecodingError.dataCorruptedError(
                    forKey: key, in: c,
                    debugDescription: "Expected 3-element array for \(key.stringValue), got \(a.count)")
            }
            return SIMD3<Float>(a[0], a[1], a[2])
        }
    }

    let integrity: Integrity
    let colliders: [Shape]

    private enum CodingKeys: String, CodingKey {
        case integrity, colliders
    }

    static func load(named name: String) throws -> SkinReferenceOracle {
        let url = try XCTestResource.url(name, ext: "json", subdir: "TestData/SpringBoneOracle")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(SkinReferenceOracle.self, from: data)
    }
}

/// A resolved world-space oracle shape. NEGATIVE `signedDistance` means inside
/// (penetration depth = `-value`).
enum OracleWorldShape {
    case sphere(center: SIMD3<Float>, radius: Float)
    case capsule(p0: SIMD3<Float>, p1: SIMD3<Float>, radius: Float)

    func signedDistance(to point: SIMD3<Float>) -> Float {
        switch self {
        case let .sphere(center, radius):
            return simd_length(point - center) - radius
        case let .capsule(p0, p1, radius):
            let ab = p1 - p0
            let abLenSq = simd_dot(ab, ab)
            let t = abLenSq > 1e-12
                ? simd_clamp(simd_dot(point - p0, ab) / abLenSq, 0, 1)
                : 0
            let closest = p0 + t * ab
            return simd_length(point - closest) - radius
        }
    }
}

extension SkinReferenceOracle {
    /// Transforms each bone-local shape into a world-space `OracleWorldShape`
    /// using the live node world matrices, so the oracle tracks the avatar's
    /// current pose.
    func resolveWorldShapes(model: VRMModel) -> [OracleWorldShape] {
        guard let humanoid = model.humanoid else { return [] }
        func worldPos(_ bone: VRMHumanoidBone) -> SIMD3<Float>? {
            guard let n = humanoid.getBoneNode(bone), n >= 0, n < model.nodes.count else { return nil }
            return model.nodes[n].worldPosition
        }
        func worldMatrix(_ bone: VRMHumanoidBone) -> float4x4? {
            guard let n = humanoid.getBoneNode(bone), n >= 0, n < model.nodes.count else { return nil }
            return model.nodes[n].worldMatrix
        }
        var out: [OracleWorldShape] = []
        for shape in colliders {
            guard let m = worldMatrix(shape.bone) else { continue }
            let originW = (m * SIMD4<Float>(shape.offset, 1)).xyz
            switch shape.kind {
            case "sphere":
                out.append(.sphere(center: originW, radius: shape.radius))
            case "capsule":
                let tailW: SIMD3<Float>
                if let tb = shape.tailBone, let p = worldPos(tb) {
                    tailW = p
                } else if let tail = shape.tail {
                    tailW = (m * SIMD4<Float>(tail, 1)).xyz
                } else {
                    tailW = originW
                }
                out.append(.capsule(p0: originW, p1: tailW, radius: shape.radius))
            default:
                continue
            }
        }
        return out
    }

    /// Max penetration depth (>= 0) of `point` across all `shapes`; 0 if outside all.
    static func worstPenetration(of point: SIMD3<Float>, shapes: [OracleWorldShape]) -> Float {
        var worst: Float = 0
        for s in shapes {
            let pen = -s.signedDistance(to: point)
            if pen > worst { worst = pen }
        }
        return worst
    }
}

/// Locates a bundled test resource, throwing `XCTSkip` (not a failure) when the
/// file is absent so suites degrade gracefully on stripped checkouts.
enum XCTestResource {
    static func url(_ name: String, ext: String, subdir: String) throws -> URL {
        if let u = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: subdir) {
            return u
        }
        throw XCTSkip("Test resource missing: \(subdir)/\(name).\(ext)")
    }
}

// Note: `SIMD4<Float>.xyz` is already defined at test-target scope (MatCapTests.swift);
// the oracle reuses that extension rather than redeclaring it.
