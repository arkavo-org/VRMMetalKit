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

import XCTest
import Metal
import simd
@testable import VRMMetalKit

/// Guards synthetic collider sizing against the dimensions the rig's author
/// actually specified.
///
/// ## Why this exists
/// `SpringBoneBoneGeometry.limbCapsule` sizes a synthetic capsule as
/// `max(authoredHint, length * radiusFraction)` — the authored radius is a
/// FLOOR and never a CEILING, so a fraction constant that overshoots wins
/// silently on every rig. Three collider families avoid this by deriving their
/// size FROM an authored radius (`headSkullSphere` = 1.0 × `rHead`,
/// `headBrowCapsule` = 0.5 × `rHead`, `breastTwinSphere` = a copy of the
/// authored sphere), and those are exactly the ones that track the rig across
/// different bodies. The rest drift, and the drift is invisible to the existing
/// suites: a mesh-fitted shoulder sphere at ~1.9× authored funnelled hair into
/// the décolletage while every collider test stayed green.
///
/// ## What it asserts
/// For every synthetic collider whose anchor bone also carries an AUTHORED
/// collider, the synthetic radius must not exceed ``ratioCeiling`` × the largest
/// authored radius on that bone — unless that (bone, shape) pair appears in
/// ``knownOversized``, which pins the ratios measured when this guard was
/// written so existing debt cannot grow unnoticed.
///
/// Bones with no authored collider are skipped: there is no ground truth to
/// compare against, and inventing one is what this guard exists to prevent.
final class ColliderDimensionAudit: XCTestCase {

    /// Headroom over the authored radius that needs no justification. Synthetic
    /// colliders sit legitimately proud of the authored shape — they wrap
    /// clothing, not skin — but not by half again.
    private static let ratioCeiling: Float = 1.25

    /// Shape discriminator: one bone can anchor both a capsule and a sphere from
    /// different generators, and they drift independently.
    private enum ShapeKind: String { case sphere, capsule, plane }

    /// Documented sizing debt, keyed by anchor bone and shape.
    ///
    /// `limit` is the worst ratio measured across the fixtures plus a small
    /// margin. Exceeding it fails. Dropping cleanly below ``ratioCeiling`` ALSO
    /// fails, so a fixed entry gets deleted instead of lingering as cover.
    private struct KnownOversized {
        let bone: VRMHumanoidBone
        let kind: ShapeKind
        let limit: Float
        let note: String
    }

    private static let knownOversized: [KnownOversized] = [
        .init(bone: .leftHand, kind: .sphere, limit: 4.0,
              note: "handSphereRadiusFraction 0.4 yields ~86-91mm against an authored 24-29mm (3.0-3.8x). Shipped with #321's hand-poke-through fix."),
        .init(bone: .rightHand, kind: .sphere, limit: 4.0,
              note: "mirror of leftHand"),
        .init(bone: .leftUpperArm, kind: .sphere, limit: 2.0,
              note: "shoulder spheres: augmentor 1.20-1.53x, mesh-fitted SpringBoneBreastCollider 1.34-1.66x after the medial-vertex fit filter (was 1.76-1.88x, which funnelled front hair into the décolletage — #309 lookUp regression)."),
        .init(bone: .rightUpperArm, kind: .sphere, limit: 2.0,
              note: "mirror of leftUpperArm"),
        .init(bone: .leftLowerArm, kind: .capsule, limit: 1.6,
              note: "armRadiusFractionOfLength 0.2 beats the authored floor: 1.28-1.50x"),
        .init(bone: .rightLowerArm, kind: .capsule, limit: 1.6,
              note: "mirror of leftLowerArm"),
        .init(bone: .leftUpperArm, kind: .capsule, limit: 1.4,
              note: "upperArmRadiusFractionOfLength 0.22 beats the authored floor: 1.02-1.29x"),
        .init(bone: .rightUpperArm, kind: .capsule, limit: 1.4,
              note: "mirror of leftUpperArm")
    ]

    // MARK: - Guard

    /// Sweeps every available fixture in one test, because ``knownOversized`` is
    /// a global table: a collider can exceed the ceiling on one body type and sit
    /// under it on another (`upperArm` capsule is 1.29× on AvatarSample_A and
    /// 1.02× on AvatarSample_U), so staleness can only be judged across all rigs
    /// at once.
    @MainActor func testSyntheticCollidersTrackAuthoredDimensions() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }

        let fixtures: [(String, String)] = [
            (getTestVRM10ModelPath(), "AvatarSample_A"),
            (getTestModelPath("AvatarSample_U_1.0.vrm.glb"), "AvatarSample_U")
        ]

        var worstRatio: [String: Float] = [:]
        var rigsSwept = 0
        for (path, label) in fixtures {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            try await runGuard(path: path, label: label, worstRatio: &worstRatio)
            rigsSwept += 1
        }
        try XCTSkipIf(rigsSwept == 0, "No avatar fixtures available")

        // Staleness: an exemption that no rig actually needs is cover for a
        // collider the general assertion should be guarding. Only enforced once
        // every fixture was swept — a skipped rig could be the one that needs it.
        guard rigsSwept == fixtures.count else { return }
        for e in Self.knownOversized {
            let key = "\(e.bone)-\(e.kind.rawValue)"
            guard let worst = worstRatio[key] else {
                XCTFail("""
                    `knownOversized` entry \(key) was never exercised — no synthetic collider of that \
                    shape shares a bone with an authored collider on any fixture. Delete it. Context: \(e.note)
                    """)
                continue
            }
            XCTAssertGreaterThan(worst, Self.ratioCeiling,
                """
                `knownOversized` entry \(key) is stale: its worst ratio across all rigs is \(worst)x, \
                within the \(Self.ratioCeiling)x ceiling. Delete it so the general assertion guards this \
                collider from here on. Context: \(e.note)
                """)
        }
    }

    @MainActor private func runGuard(path: String, label: String,
                                     worstRatio: inout [String: Float]) async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        try requireFixture(path, hint: (path as NSString).lastPathComponent)

        let model = try await VRMModel.load(
            from: URL(fileURLWithPath: path), device: device,
            options: VRMLoadingOptions(augmentSpringBoneColliders: true))
        model.updateNodeTransforms()

        let humanoid = try XCTUnwrap(model.humanoid, "\(label): no humanoid")
        let spring = try XCTUnwrap(model.springBone, "\(label): no spring-bone data")
        XCTAssertFalse(spring.syntheticColliders.isEmpty,
                       "\(label): augmentation produced no synthetic colliders — the guard would be vacuous")

        var boneOfNode: [Int: VRMHumanoidBone] = [:]
        for bone in VRMHumanoidBone.allCases {
            if let n = humanoid.getBoneNode(bone) { boneOfNode[n] = bone }
        }

        // Ground truth: the largest authored radius on each node.
        var authoredMax: [Int: Float] = [:]
        for c in spring.colliders {
            guard let r = Self.radius(of: c.shape) else { continue }
            authoredMax[c.node] = max(authoredMax[c.node] ?? 0, r)
        }

        // Largest synthetic radius per (node, shape kind).
        var syntheticMax: [Int: [ShapeKind: Float]] = [:]
        for c in spring.syntheticColliders {
            guard let r = Self.radius(of: c.shape), let kind = Self.kind(of: c.shape) else { continue }
            syntheticMax[c.node, default: [:]][kind] = max(syntheticMax[c.node]?[kind] ?? 0, r)
        }

        var comparisons = 0
        for (node, byKind) in syntheticMax {
            guard let authored = authoredMax[node], authored > 1e-6 else { continue }
            let bone = boneOfNode[node]
            for (kind, synthetic) in byKind {
                comparisons += 1
                let ratio = synthetic / authored
                let site = "\(label) bone=\(bone.map { "\($0)" } ?? "node\(node)") \(kind.rawValue)"
                let exemption = bone.flatMap { b in
                    Self.knownOversized.first { $0.bone == b && $0.kind == kind }
                }

                if let e = exemption {
                    let key = "\(e.bone)-\(e.kind.rawValue)"
                    worstRatio[key] = max(worstRatio[key] ?? 0, ratio)
                    XCTAssertLessThanOrEqual(ratio, e.limit,
                        """
                        \(site): synthetic \(synthetic)m is \(ratio)x the authored \(authored)m, past the \
                        pinned limit \(e.limit)x. Known sizing debt must not grow. Context: \(e.note)
                        """)
                } else {
                    XCTAssertLessThanOrEqual(ratio, Self.ratioCeiling,
                        """
                        \(site): synthetic \(synthetic)m is \(ratio)x the authored \(authored)m. Synthetic \
                        colliders must track the dimensions the rig's author specified. `limbCapsule` uses \
                        the authored radius as a FLOOR only (`max(authoredHint, length * radiusFraction)`), \
                        so an overshooting fraction wins silently — see `headSkullSphere` / \
                        `breastTwinSphere` for the grounded pattern (derive the size FROM the authored \
                        radius). If this oversizing is deliberate, add it to `knownOversized` with a \
                        justification.
                        """)
                }
            }
        }

        XCTAssertGreaterThan(comparisons, 0,
                             "\(label): no synthetic collider shared a bone with an authored collider — nothing was compared")
    }

    // MARK: - Shape helpers

    private static func radius(of shape: VRMColliderShape) -> Float? {
        switch shape {
        case let .sphere(_, r), let .insideSphere(_, r): return r
        case let .capsule(_, r, _), let .insideCapsule(_, r, _): return r
        case .plane: return nil
        }
    }

    private static func kind(of shape: VRMColliderShape) -> ShapeKind? {
        switch shape {
        case .sphere, .insideSphere: return .sphere
        case .capsule, .insideCapsule: return .capsule
        case .plane: return .plane
        }
    }
}
