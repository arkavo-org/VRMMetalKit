# Starter Craft Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the two native-anime starters from "lofted mannequin" to a VRoid-plausible read on the locked QA stills: continuous limbs with shaped hands and feet, corpus-fitted proportions, cloth with UV islands and trim, a skirt that clears the thighs, a closed collar, a lip band instead of a painted mouth, a covered crown and an aligned hair highlight.

**Architecture:** Every change is inside `Sources/VRMAuthorKit` (template geometry in `Template/NativeAnime`, wearables in `Wearables`, rasters in `Materials` and `Template/NativeAnime/NativeAnimeTextures.swift`) plus `scripts/style_lint.py` and the pinned profile. Acceptance is geometric and Metal-free per task; Metal still checks live in one skipping test file at the end. Three phases (body basis, garments and rasters, hair) each end in a committed, green suite; the final task re-pins packs and hashes.

**Tech Stack:** Swift 6.2 package `VRMAuthorKit` (Foundation + CryptoKit only), XCTest, python3 (`scripts/style_lint.py`, numpy), `scripts/repin_packs.py`, `vrm-author-render` (Metal) for the skipping still tests.

**Spec:** `docs/superpowers/specs/2026-09-12-starter-craft-design.md` (this plan) and `docs/superpowers/specs/2026-09-12-mcp-authoring-loop-design.md` §6 (the four original craft items).

## Global Constraints

- `Sources/VRMAuthorKit` imports only Foundation and CryptoKit. No image decoding in-process; PNG pixel reads happen only in tests via `RenderPackTests.rgbaPixels` (CoreGraphics is fine in the test target).
- New files carry the Apache 2.0 header (copy lines 1–15 of `Sources/VRMAuthorKit/Wearables/WearableValidation.swift`).
- No temporary or explanatory comments in code (CLAUDE.md). Doc comments describing what a type or constant is for are fine.
- No control key, control range, starter override, QA camera, threshold or scenario oracle changes. `NativeAnimeStarters.overrides` is untouched.
- Region names stay as they are: `upperArmL/R`, `forearmL/R`, `handL/R`, `thighL/R`, `shinL/R`, `footL/R`, `torsoCap`. Do not add body regions (they would have to be threaded through `NativeAnimeControls.bodyRegions`, `NativeAnimeRig.bodyRegionBones`, `NativeAnimeShapeOffsets`, `WearableRegion` and every preset).
- Spring chain count for `bob-v1` stays 40 (`HairBobV1.Layout.clumpCount`); added hair coverage is rigid.
- Tests run with `swift test --filter <Name> --disable-sandbox`; `--filter` only filters execution, every test file must compile. Full suite: `swift test --parallel --num-workers 14 -j 16 --disable-sandbox`.
- Commit after each task. Do not push.
- `TemplatePackTests.goldenDefaultBuildHash` is a cross-process pin: whenever a task changes compiled geometry or a Codable output type, run `swift test --filter TemplatePackTests --disable-sandbox`, copy the new hash from the failure message into the constant, and re-run once to confirm it is stable.
- Every edited test file is pinned by a pack under `docs/proposals/vrm-author-cli/acceptance/packs/`; Task 9 re-pins once. Do not re-pin per task.

---

## File map

| File | Responsibility |
|---|---|
| `Sources/VRMAuthorKit/Template/NativeAnime/NativeAnimeLayout.swift` (modify) | `shoulderHalfWidthFactor`, `eyeSpacingFactor`, fanned finger joints |
| `Sources/VRMAuthorKit/Template/NativeAnime/NativeAnimeBodyBuilder.swift` (modify) | Single-loft arms/legs, torso/neck radii, `buildFingers`, `buildFoot` |
| `Tests/VRMAuthorKitTests/Template/NativeAnimeGeometryTests.swift` (modify) | Continuity, knee/calf, finger fan, foot width tests |
| `Tests/VRMAuthorKitTests/Template/NativeAnimeProportionTests.swift` (new) | Bone metrics of default + starters inside the profile's corpus envelope |
| `Tests/VRMAuthorKitTests/Template/TemplatePackTests.swift` (modify) | `goldenDefaultBuildHash` |
| `scripts/style_lint.py` (modify) | `girth.*` metrics over skin-role primitives |
| `scripts/test_style_lint.py` (modify) | Girth unit test on a synthetic GLB |
| `docs/style/profiles/vroid-lineage-anime.json` (modify) | Version 0.2.0, four girth rules, regenerated provenance |
| `docs/style/corpus/vroid-lineage-anime.measurements.json` (regenerate) | Corpus re-measure |
| `docs/style/corpus/vroid-lineage-anime.witnesses.native-anime-v1.json` (regenerate) | Witness solve on the new linter |
| `docs/style/README.md` (modify) | Girth metric paragraph |
| `Sources/VRMAuthorKit/QA/QASuite.swift`, `Sources/VRMAuthorKit/Materials/StyleToolchain.swift` (modify) | Linter/profile hash pins |
| `Tests/VRMAuthorKitTests/Materials/StyleLintTests.swift` (modify) | `profile_version` 0.2.0 |
| `Sources/VRMAuthorKit/Wearables/GarmentUVLayout.swift` (new) | Island tables per `OutfitKind`, remap helpers |
| `Sources/VRMAuthorKit/Wearables/OutfitPresets.swift` (modify) | UV remap, trim UVs, skirt profile + hem band, collar lean, `collarGapM` |
| `Sources/VRMAuthorKit/Wearables/WearableOutput.swift` (modify) | `GarmentInfo.uvIslands`, `GarmentInfo.collarGapM`, `HairClumpInfo.isRigid`, `HairClumpInfo.highlightColumn` |
| `Sources/VRMAuthorKit/Template/NativeAnime/NativeAnimeTextures.swift` (modify) | `garmentRaster(kind:)`, eight-column `hairRaster` |
| `Sources/VRMAuthorKit/Template/NativeAnime/NativeAnimeV1Pack.swift` (modify) | Garment images through `garmentRaster(kind:)` |
| `Sources/VRMAuthorKit/Materials/MaterialRoleDefaults.swift` (modify) | Mouth lip band, cloth pixel |
| `Tests/VRMAuthorKitTests/Wearables/WearableOutfitTests.swift`, `WearableGarmentFitTests.swift` (new) | Islands, trim, skirt profile on the native host, collar gap |
| `Tests/VRMAuthorKitTests/Materials/MaterialsCompositingTests.swift` (modify) | Mouth and cloth raster pixel tests |
| `Sources/VRMAuthorKit/Wearables/HairBobV1.swift` (modify) | Rigid cap clumps, highlight column selection |
| `Tests/VRMAuthorKitTests/Wearables/WearableHairTests.swift` (modify) | Rigid clumps, coverage, highlight alignment |
| `Tests/VRMAuthorKitTests/Render/StarterStillTests.swift` (new) | Metal still checks (collar, hem, scalp), skip without a device |
| `docs/proposals/vrm-author-cli/README.md`, `verification.md`, six packs (modify) | Hash pins; Task 9 |

---

## Phase A: body basis

### Task 1: Continuous limbs and proportion fit

**Files:**
- Modify: `Sources/VRMAuthorKit/Template/NativeAnime/NativeAnimeLayout.swift:44` (`shoulderHalfWidthFactor`)
- Modify: `Sources/VRMAuthorKit/Template/NativeAnime/NativeAnimeBodyBuilder.swift` (whole file body)
- Test: `Tests/VRMAuthorKitTests/Template/NativeAnimeGeometryTests.swift`
- Test: `Tests/VRMAuthorKitTests/Template/NativeAnimeProportionTests.swift` (new)
- Modify: `Tests/VRMAuthorKitTests/Template/TemplatePackTests.swift:53`

**Interfaces:**
- Consumes: `NativeAnimeLayout.joint(_:)`, `BuildMesh.loft(_:segments:capStart:capEnd:extraRegions:)`, `Ring`, `NAMath`, `NativeAnimeFixture.compiled`, `TemplateAttachments.jointWorldPositions/heightM/indices(of:mesh:)`, `MaterialsTestSupport.repoRoot`, `StyleToolchain.profileRelativePath`, `NativeAnimeStarters.starterRecipe(base:registry:)`.
- Produces: `NativeAnimeBodyBuilder.buildFingers(_:side:)` and `buildFoot(_:side:)` as `private func`s Task 2 replaces; `NativeAnimeLayout.shoulderHalfWidthFactor = 0.064`.

- [ ] **Step 1: Write the failing geometry tests**

Append to `Tests/VRMAuthorKitTests/Template/NativeAnimeGeometryTests.swift` inside the class:

```swift
    /// One loft per limb: no cap pole sits on the limb axis between the
    /// shoulder and the palm or between the hip and the ankle, the knee is
    /// the leg's narrowest ring and the calf is wider than the knee.
    func testLimbsAreContinuousLofts() throws {
        let (avatar, attachments) = try NativeAnimeFixture.compiled()
        let body = NativeAnimeFixture.primitive(avatar, mesh: "mesh.body")
        let H = attachments.heightM
        let j = attachments.jointWorldPositions
        for (side, s) in [("L", Float(1)), ("R", Float(-1))] {
            let upper = j[side == "L" ? .leftUpperArm : .rightUpperArm]!
            let hand = j[side == "L" ? .leftHand : .rightHand]!
            let arm = attachments.indices(of: "upperArm\(side)", mesh: "mesh.body") + attachments.indices(of: "forearm\(side)", mesh: "mesh.body")
            for i in arm {
                let p = body.positions[i]
                guard (p.x - upper.x) * s > 0.02 * H, (p.x - hand.x) * s < 0.04 * H else { continue }
                XCTAssertGreaterThan(hypot(p.y - upper.y, p.z), 0.003 * H, "arm\(side) vertex \(i) sits on the limb axis")
            }
            let hip = j[side == "L" ? .leftUpperLeg : .rightUpperLeg]!
            let knee = j[side == "L" ? .leftLowerLeg : .rightLowerLeg]!
            let ankle = j[side == "L" ? .leftFoot : .rightFoot]!
            let leg = attachments.indices(of: "thigh\(side)", mesh: "mesh.body") + attachments.indices(of: "shin\(side)", mesh: "mesh.body")
            var kneeRadius = Float.greatestFiniteMagnitude, calfRadius: Float = 0
            let calfY = knee.y + (ankle.y - knee.y) * 0.35
            for i in leg {
                let p = body.positions[i]
                guard p.y < hip.y, p.y > ankle.y + 0.01 * H else { continue }
                let radial = hypot(p.x - hip.x, p.z)
                XCTAssertGreaterThan(radial, 0.003 * H, "leg\(side) vertex \(i) sits on the limb axis")
                if abs(p.y - knee.y) < 0.025 * H { kneeRadius = min(kneeRadius, radial) }
                if abs(p.y - calfY) < 0.02 * H { calfRadius = max(calfRadius, radial) }
            }
            XCTAssertGreaterThan(calfRadius, kneeRadius + 0.004 * H, "leg\(side): calf must be wider than the knee")
        }
    }

    func testShoulderNeckAndChestSitOnTheCorpusMedians() throws {
        let (avatar, attachments) = try NativeAnimeFixture.compiled()
        let body = NativeAnimeFixture.primitive(avatar, mesh: "mesh.body")
        let H = attachments.heightM
        let j = attachments.jointWorldPositions
        XCTAssertEqual((j[.leftUpperArm]!.x - j[.rightUpperArm]!.x) / H, 0.128, accuracy: 0.003)
        let collarbone = attachments.indices(of: "upperArmL", mesh: "mesh.body").filter { body.positions[$0].x < j[.leftUpperArm]!.x }.map { body.positions[$0].y }.max()!
        XCTAssertLessThanOrEqual(collarbone, j[.neck]!.y + 0.002 * H, "the arm's inner ring must not rise above the torso top")
        let neck = attachments.indices(of: "neck", mesh: "mesh.body").map { hypot(body.positions[$0].x, body.positions[$0].z) }.max()!
        XCTAssertEqual(neck / H, 0.0345, accuracy: 0.004)
        let chest = attachments.indices(of: "chest", mesh: "mesh.body").map { abs(body.positions[$0].x) }.max()!
        XCTAssertLessThan(chest / H, 0.076)
        let torsoBottom = attachments.indices(of: "hips", mesh: "mesh.body").map { body.positions[$0].y }.min()!
        XCTAssertGreaterThan(torsoBottom, j[.leftUpperLeg]!.y - 0.03 * H, "torso pole must not hang below the hips ring")
    }
```

Create `Tests/VRMAuthorKitTests/Template/NativeAnimeProportionTests.swift`:

```swift
import Foundation
import XCTest
@testable import VRMAuthorKit

/// Bone-derived proportion metrics of the pack default and both starters,
/// checked against the corpus envelope recorded in the pinned profile's rule
/// provenance rather than against the (deliberately loose) rule ranges.
final class NativeAnimeProportionTests: XCTestCase {
    struct Envelope { var min: Double; var max: Double }

    static func envelopes() throws -> [String: Envelope] {
        let url = MaterialsTestSupport.repoRoot.appendingPathComponent(StyleToolchain.profileRelativePath)
        let profile = try JSONValue.parse(try Data(contentsOf: url))
        var out: [String: Envelope] = [:]
        for rule in profile["rules"]?.array ?? [] {
            guard let metric = rule["metric"]?.string, let lo = rule["provenance"]?["min"]?.number, let hi = rule["provenance"]?["max"]?.number else { continue }
            out[metric] = Envelope(min: lo, max: hi)
        }
        return out
    }

    static func metrics(_ layout: NativeAnimeLayout) -> [String: Double] {
        let H = layout.height
        func d(_ a: VRMHumanBone, _ b: VRMHumanBone) -> Double { NAMath.length(layout.joint(a) - layout.joint(b)) }
        return [
            "proportions.shoulder_width_ratio": d(.leftUpperArm, .rightUpperArm) / H,
            "proportions.arm_span_height_ratio": d(.leftHand, .rightHand) / H,
            "proportions.hips_height_ratio": layout.joint(.hips).y / H,
            "proportions.upper_leg_height_ratio": layout.joint(.leftUpperLeg).y / H,
            "proportions.lower_upper_arm_ratio": d(.leftLowerArm, .leftHand) / d(.leftUpperArm, .leftLowerArm),
            "proportions.lower_upper_leg_ratio": d(.leftLowerLeg, .leftFoot) / d(.leftUpperLeg, .leftLowerLeg),
            "proportions.eye_height_ratio": layout.joint(.leftEye).y / H,
        ]
    }

    func testDefaultAndStartersSitInsideTheCorpusEnvelope() throws {
        let envelopes = try Self.envelopes()
        XCTAssertGreaterThanOrEqual(envelopes.count, 12)
        let registry = TemplateRegistry.standard()
        var recipes = [("default", NativeAnimeFixture.pack.defaults)]
        for base in NativeAnimeStarterBase.allCases { recipes.append((base.rawValue, try NativeAnimeStarters.starterRecipe(base: base, registry: registry))) }
        for (name, recipe) in recipes {
            let layout = NativeAnimeLayout(controls: try NativeAnimeControlSet(body: recipe.body, face: recipe.face))
            for (metric, value) in Self.metrics(layout) {
                let env = try XCTUnwrap(envelopes[metric], metric)
                XCTAssertGreaterThanOrEqual(value, env.min, "\(name) \(metric) = \(value) below corpus min \(env.min)")
                XCTAssertLessThanOrEqual(value, env.max, "\(name) \(metric) = \(value) above corpus max \(env.max)")
            }
        }
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter "NativeAnimeGeometryTests/testLimbsAreContinuousLofts|NativeAnimeGeometryTests/testShoulderNeckAndChestSitOnTheCorpusMedians|NativeAnimeProportionTests" --disable-sandbox`
Expected: FAIL. Continuity fails on "sits on the limb axis" (elbow/knee caps), medians fails on 0.175 vs 0.128, envelope fails on `shoulder_width_ratio` (0.176 > 0.1702) and `arm_span_height_ratio` (the female's 0.722 is just inside 0.7226; the male starter's 0.74 is not).

- [ ] **Step 3: Move the shoulder constant**

In `NativeAnimeLayout.swift`:

```swift
    static let shoulderHalfWidthFactor = 0.064
```

- [ ] **Step 4: Rewrite the body builder lofts**

Replace `buildTorso`'s ring table and cap, `buildNeck`'s radius, and `buildArm`/`buildLeg` in `NativeAnimeBodyBuilder.swift`:

```swift
    private func buildTorso(_ mesh: inout BuildMesh) {
        let y0 = layout.hipJointY - 0.02 * H
        let y1 = layout.neckBaseY
        func at(_ f: Double) -> Double { NAMath.lerp(y0, y1, f) }
        let hipW = layout.hipHalfWidth + 0.03 * H
        let shoulderW = layout.shoulderHalfWidth - 0.006 * H
        let rings = [
            yRing(at(0.00), rx: hipW * 0.86, rz: 0.058 * H, region: "hips", zc: -0.004 * H),
            yRing(at(0.12), rx: hipW * 0.94, rz: 0.068 * H, region: "hips", zc: -0.006 * H),
            yRing(at(0.26), rx: hipW * 0.84, rz: 0.058 * H, region: "waist", zc: -0.003 * H),
            yRing(at(0.42), rx: 0.064 * H, rz: 0.050 * H, region: "waist", zc: -0.002 * H),
            yRing(at(0.58), rx: 0.068 * H, rz: 0.058 * H, region: "chest", zc: 0.004 * H),
            yRing(at(0.72), rx: 0.072 * H, rz: 0.064 * H, region: "chest", zc: 0.010 * H),
            yRing(at(0.86), rx: shoulderW, rz: 0.054 * H, region: "chest", zc: 0.004 * H),
            yRing(at(0.95), rx: shoulderW * 0.80, rz: 0.048 * H, region: "torso", zc: 0.001 * H),
            yRing(at(1.00), rx: 0.046 * H, rz: 0.042 * H, region: "torso"),
        ]
        mesh.loft(rings, segments: Self.torsoSegments, capStart: NAVec3(0, y0 - 0.006 * H, -0.002 * H), capEnd: NAVec3(0, y1 + 0.01 * H, 0), extraRegions: ["torso"])
        let topPole = mesh.vertexCount - 1
        mesh.regions["torso"]?.removeAll { $0 == topPole }
        mesh.tag("torsoCap", [topPole])
    }

    private func buildNeck(_ mesh: inout BuildMesh) {
        let y0 = layout.neckBaseY - 0.02 * H
        let y1 = layout.headBottomY + 0.05 * layout.headHeight
        let r = 0.030 * H
        let rings = [
            yRing(y0, rx: r * 1.15, rz: r * 1.1, region: "neck"),
            yRing(NAMath.lerp(y0, y1, 0.5), rx: r, rz: r * 0.95, region: "neck"),
            yRing(y1, rx: r, rz: r * 0.95, region: "neck"),
        ]
        mesh.loft(rings, segments: Self.neckSegments, capStart: NAVec3(0, y0 - 0.01 * H, 0), capEnd: NAVec3(0, y1 + 0.01 * H, 0))
    }

    /// One loft from inside the torso to the knuckle line; regions switch at
    /// the elbow and wrist rings so garments and weights see the same names.
    private func buildArm(_ mesh: inout BuildMesh, side: String) {
        let s = side == "left" ? 1.0 : -1.0
        let sfx = NativeAnimeControls.suffix(side)
        let upper = layout.joint(side == "left" ? .leftUpperArm : .rightUpperArm)
        let lower = layout.joint(side == "left" ? .leftLowerArm : .rightLowerArm)
        let hand = layout.joint(side == "left" ? .leftHand : .rightHand)
        let y = upper.y
        let hl = layout.handLength
        func ring(_ x: Double, _ ry: Double, _ rz: Double, _ region: String) -> Ring {
            xRing(x, y: y, z: 0, ry: ry * H, rz: rz * H, sign: s, region: region + sfx)
        }
        let arm = [
            ring(upper.x - s * 0.030 * H, 0.026, 0.031, "upperArm"),
            ring(upper.x + s * 0.030 * H, 0.029, 0.030, "upperArm"),
            ring(NAMath.lerp(upper.x, lower.x, 0.55), 0.027, 0.027, "upperArm"),
            ring(lower.x - s * 0.012 * H, 0.024, 0.024, "upperArm"),
            ring(lower.x + s * 0.012 * H, 0.024, 0.024, "forearm"),
            ring(NAMath.lerp(lower.x, hand.x, 0.40), 0.023, 0.024, "forearm"),
            ring(NAMath.lerp(lower.x, hand.x, 0.80), 0.017, 0.019, "forearm"),
            ring(hand.x - s * 0.006 * H, 0.014, 0.017, "forearm"),
            ring(hand.x + s * 0.10 * hl, 0.010, 0.020, "hand"),
            ring(hand.x + s * 0.30 * hl, 0.009, 0.026, "hand"),
            ring(hand.x + s * 0.48 * hl, 0.008, 0.028, "hand"),
        ]
        mesh.loft(arm, segments: Self.limbSegments, capStart: NAVec3(upper.x - s * 0.045 * H, y, 0), capEnd: NAVec3(hand.x + s * 0.52 * hl, y, 0))
        buildFingers(&mesh, side: side)
    }

    private func buildFingers(_ mesh: inout BuildMesh, side: String) {
        let s = side == "left" ? 1.0 : -1.0
        let sfx = NativeAnimeControls.suffix(side)
        let hand = layout.joint(side == "left" ? .leftHand : .rightHand)
        let y = hand.y
        let hl = layout.handLength
        let fingerRadius: [Double] = [0.0068, 0.0073, 0.0068, 0.0056]
        for (fi, finger) in ["Index", "Middle", "Ring", "Little"].enumerated() {
            let joints = ["Proximal", "Intermediate", "Distal"].map { layout.joint(VRMHumanBone(rawValue: side + finger + $0)!) }
            let r0 = fingerRadius[fi] * H
            let dir = NAMath.normalize(joints[2] - joints[1])
            func fring(_ p: NAVec3, _ r: Double) -> Ring {
                Ring(center: p, u: NAMath.yAxis, v: NAMath.zAxis * s, ru: r, rv: r, region: "hand\(sfx)")
            }
            let rings = [
                fring(joints[0] - NAMath.xAxis * (s * 0.06 * hl), r0 * 1.1),
                fring(joints[0], r0),
                fring(joints[1], r0 * 0.88),
                fring(joints[2], r0 * 0.72),
            ]
            mesh.loft(rings, segments: Self.thumbSegments, capStart: joints[0] - NAMath.xAxis * (s * 0.11 * hl), capEnd: joints[2] + dir * (0.10 * hl))
        }
        let thumbBase = NAVec3(hand.x + s * 0.22 * hl, y - 0.002 * H, 0.018 * H)
        let thumbDir = NAMath.normalize(NAVec3(s * 0.45, 0, 1))
        let tu = NAMath.yAxis
        let tv = NAMath.normalize(NAMath.cross(thumbDir, tu))
        func thumbRing(_ t: Double, _ r: Double) -> Ring {
            Ring(center: thumbBase + thumbDir * t, u: tu, v: tv, ru: r, rv: r, region: "hand\(sfx)")
        }
        let thumb = [thumbRing(0, 0.010 * H), thumbRing(0.22 * hl, 0.0085 * H), thumbRing(0.40 * hl, 0.006 * H)]
        mesh.loft(thumb, segments: Self.thumbSegments, capStart: thumbBase - thumbDir * (0.01 * H), capEnd: thumbBase + thumbDir * (0.45 * hl))
    }

    /// One loft from inside the hips to the ankle with a knee narrowing and a
    /// calf; the end pole sits inside the foot loft.
    private func buildLeg(_ mesh: inout BuildMesh, side: String) {
        let sfx = NativeAnimeControls.suffix(side)
        let upper = layout.joint(side == "left" ? .leftUpperLeg : .rightUpperLeg)
        let lower = layout.joint(side == "left" ? .leftLowerLeg : .rightLowerLeg)
        let foot = layout.joint(side == "left" ? .leftFoot : .rightFoot)
        let x = upper.x
        func ring(_ y: Double, _ rx: Double, _ rz: Double, _ region: String) -> Ring {
            downRing(x, y, rx: rx * H, rz: rz * H, region: region + sfx)
        }
        let leg = [
            ring(upper.y + 0.035 * H, 0.045, 0.049, "thigh"),
            ring(upper.y - 0.030 * H, 0.046, 0.050, "thigh"),
            ring(NAMath.lerp(upper.y, lower.y, 0.55), 0.040, 0.043, "thigh"),
            ring(lower.y + 0.020 * H, 0.034, 0.036, "thigh"),
            ring(lower.y - 0.020 * H, 0.033, 0.035, "shin"),
            ring(NAMath.lerp(lower.y, foot.y, 0.35), 0.035, 0.040, "shin"),
            ring(NAMath.lerp(lower.y, foot.y, 0.75), 0.026, 0.028, "shin"),
            ring(foot.y + 0.005 * H, 0.019, 0.021, "shin"),
        ]
        mesh.loft(leg, segments: Self.limbSegments, capStart: NAVec3(x, upper.y + 0.050 * H, 0), capEnd: NAVec3(x, foot.y - 0.020 * H, 0))
        buildFoot(&mesh, side: side)
    }

    private func buildFoot(_ mesh: inout BuildMesh, side: String) {
        let sfx = NativeAnimeControls.suffix(side)
        let x = layout.joint(side == "left" ? .leftUpperLeg : .rightUpperLeg).x
        func footRing(_ z: Double, rx: Double, ry: Double) -> Ring {
            Ring(center: NAVec3(x, ry, z), u: NAMath.xAxis, v: NAMath.yAxis, ru: rx, rv: ry, region: "foot\(sfx)")
        }
        let footRings = [
            footRing(-0.032 * H, rx: 0.026 * H, ry: 0.026 * H),
            footRing(0.0, rx: 0.030 * H, ry: 0.031 * H),
            footRing(0.045 * H, rx: 0.032 * H, ry: 0.026 * H),
            footRing(0.085 * H, rx: 0.031 * H, ry: 0.019 * H),
            footRing(0.115 * H, rx: 0.025 * H, ry: 0.013 * H),
        ]
        mesh.loft(footRings, segments: Self.limbSegments, capStart: NAVec3(x, 0.024 * H, -0.042 * H), capEnd: NAVec3(x, 0.012 * H, 0.128 * H))
    }
```

Delete the old `buildArm`, `buildLeg` and their inline finger/foot code; the `xRing`, `downRing`, `yRing` helpers stay.

- [ ] **Step 5: Run the new tests and the template suites**

Run: `swift test --filter "NativeAnimeGeometryTests|NativeAnimeProportionTests|NativeAnimeRigTests|NativeAnimeMorphTests" --disable-sandbox`
Expected: the three new tests PASS. `testBodyWeightsFollowRegions` PASS (region names unchanged). `testDefaultMeshIsValidAndWithinTriangleBudget` PASS (one loft per limb has fewer triangles than three; confirm body+head stays ≥ 4000, if not raise `limbSegments` to 32).

- [ ] **Step 6: Run the wearable and pack suites, update the golden hash**

Run: `swift test --filter "WearableOutfitTests|WearableHairTests|WearablesPackTests|TemplatePackTests|NativeAnimeStartersTests|ExportPackTests" --disable-sandbox`
Expected: `TemplatePackTests.testCompileIsDeterministicAndSeedOnlyChangesTextures` (the golden hash test) FAILS with the new hash in its message; everything else PASS. Copy the new hash into `goldenDefaultBuildHash`, re-run `TemplatePackTests` twice, both PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/VRMAuthorKit/Template/NativeAnime/NativeAnimeLayout.swift Sources/VRMAuthorKit/Template/NativeAnime/NativeAnimeBodyBuilder.swift Tests/VRMAuthorKitTests/Template/NativeAnimeGeometryTests.swift Tests/VRMAuthorKitTests/Template/NativeAnimeProportionTests.swift Tests/VRMAuthorKitTests/Template/TemplatePackTests.swift
git commit -m "native-anime: single-loft limbs and corpus-fitted shoulders, neck, chest and eye spacing"
```

### Task 2: Fanned fingers, thumb and a shaped foot

**Files:**
- Modify: `Sources/VRMAuthorKit/Template/NativeAnime/NativeAnimeLayout.swift:130-142` (finger joints)
- Modify: `Sources/VRMAuthorKit/Template/NativeAnime/NativeAnimeBodyBuilder.swift` (`buildFingers`, `buildFoot` from Task 1)
- Test: `Tests/VRMAuthorKitTests/Template/NativeAnimeGeometryTests.swift`
- Modify: `Tests/VRMAuthorKitTests/Template/TemplatePackTests.swift:53`

**Interfaces:**
- Consumes: Task 1's `buildFingers(_:side:)` / `buildFoot(_:side:)`, `NativeAnimeLayout.handLength`, finger `VRMHumanBone` cases.
- Produces: `NativeAnimeLayout.fingerFanDegrees: [Double] = [8, 3, -3, -8]`, `NativeAnimeLayout.fingerLengthRatios: [Double] = [0.36, 0.40, 0.37, 0.30]` (static, used by the builder and the tests).

- [ ] **Step 1: Write the failing tests**

Append inside `NativeAnimeGeometryTests`:

```swift
    func testFingersFanAndFootIsNarrowWithAHeelAndToeBox() throws {
        let (avatar, attachments) = try NativeAnimeFixture.compiled()
        let body = NativeAnimeFixture.primitive(avatar, mesh: "mesh.body")
        let H = attachments.heightM
        let j = attachments.jointWorldPositions
        let tips: [VRMHumanBone] = [.leftIndexDistal, .leftMiddleDistal, .leftRingDistal, .leftLittleDistal]
        let zs = tips.map { j[$0]!.z }
        XCTAssertGreaterThan(zs.max()! - zs.min()!, 0.040 * H, "fingertips must fan in z")
        let mids: [VRMHumanBone] = [.leftIndexIntermediate, .leftMiddleIntermediate, .leftRingIntermediate, .leftLittleIntermediate]
        let radii: [Float] = [0.0055, 0.0058, 0.0054, 0.0047].map { Float($0) * H }
        for k in 0..<3 {
            XCTAssertGreaterThan(abs(j[mids[k]]!.z - j[mids[k + 1]]!.z), radii[k] + radii[k + 1], "fingers \(k) and \(k + 1) overlap at the middle joint")
        }
        XCTAssertGreaterThan(j[.leftMiddleDistal]!.x, j[.leftLittleDistal]!.x + 0.006 * H, "middle finger is the longest")
        XCTAssertGreaterThan(j[.leftIndexDistal]!.z, j[.leftMiddleDistal]!.z)
        let hand = attachments.indices(of: "handL", mesh: "mesh.body")
        let handThickness = hand.map { body.positions[$0].y }.max()! - hand.map { body.positions[$0].y }.min()!
        XCTAssertLessThan(handThickness, 0.028 * H, "palm reads as a flat blade, not a mitt")
        let foot = attachments.indices(of: "footL", mesh: "mesh.body")
        let footWidth = foot.map { body.positions[$0].x }.max()! - foot.map { body.positions[$0].x }.min()!
        XCTAssertLessThan(footWidth, 0.058 * H)
        let footLength = foot.map { body.positions[$0].z }.max()! - foot.map { body.positions[$0].z }.min()!
        XCTAssertGreaterThan(footLength, 0.15 * H)
        let heelTop = foot.filter { body.positions[$0].z < -0.02 * H }.map { body.positions[$0].y }.max()!
        let toeTop = foot.filter { body.positions[$0].z > 0.10 * H }.map { body.positions[$0].y }.max()!
        XCTAssertGreaterThan(heelTop, toeTop + 0.02 * H, "heel is taller than the toe box")
        XCTAssertEqual(foot.map { body.positions[$0].y }.min()!, 0, accuracy: 0.002, "sole touches the ground")
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter NativeAnimeGeometryTests/testFingersFanAndFootIsNarrowWithAHeelAndToeBox --disable-sandbox`
Expected: FAIL on "fingertips must fan in z" (current spread is 0.024 H), on the middle-joint overlap (0.008 H spacing against 0.0136 H of radii) and on foot width (0.064 H).

- [ ] **Step 3: Fan the finger joints in the layout**

In `NativeAnimeLayout.swift` add the two constants next to `headBoneFactor`:

```swift
    /// Finger fan in the palm plane (degrees toward +Z, index first) and
    /// finger lengths as fractions of hand length, index → little.
    static let fingerFanDegrees: [Double] = [8, 3, -3, -8]
    static let fingerLengthRatios: [Double] = [0.36, 0.40, 0.37, 0.30]
```

Replace `fingerZ` and the finger loop in `init(controls:)`:

```swift
            let fingerZ: [Double] = [0.018, 0.006, -0.006, -0.018].map { $0 * H }
            for (fi, chain) in fingers.enumerated() {
                let base = hand + NAVec3(sign * 0.50 * hl, 0, fingerZ[fi])
                let theta = NAMath.degrees(NativeAnimeLayout.fingerFanDegrees[fi])
                let dir = NAVec3(sign * cos(theta), 0, sin(theta))
                let length = NativeAnimeLayout.fingerLengthRatios[fi] * hl
                j[chain[0]] = base
                j[chain[1]] = base + dir * (0.55 * length)
                j[chain[2]] = base + dir * length
            }
            let thumbMeta = hand + NAVec3(sign * 0.20 * hl, -0.004 * H, 0.020 * H)
            let thumbDir = NAMath.normalize(NAVec3(sign * 0.5, -0.15, 1))
            j[s ? .leftThumbMetacarpal : .rightThumbMetacarpal] = thumbMeta
            j[s ? .leftThumbProximal : .rightThumbProximal] = thumbMeta + thumbDir * (0.22 * hl)
            j[s ? .leftThumbDistal : .rightThumbDistal] = thumbMeta + thumbDir * (0.40 * hl)
```

- [ ] **Step 4: Rebuild fingers and foot in the body builder**

Replace `buildFingers` and `buildFoot`:

```swift
    private func buildFingers(_ mesh: inout BuildMesh, side: String) {
        let s = side == "left" ? 1.0 : -1.0
        let sfx = NativeAnimeControls.suffix(side)
        let hl = layout.handLength
        let fingerRadius: [Double] = [0.0055, 0.0058, 0.0054, 0.0047]
        for (fi, finger) in ["Index", "Middle", "Ring", "Little"].enumerated() {
            let joints = ["Proximal", "Intermediate", "Distal"].map { layout.joint(VRMHumanBone(rawValue: side + finger + $0)!) }
            let r0 = fingerRadius[fi] * H
            let dir = NAMath.normalize(joints[2] - joints[0])
            let v = NAMath.normalize(NAMath.cross(dir, NAMath.yAxis))
            func fring(_ p: NAVec3, _ r: Double) -> Ring {
                Ring(center: p, u: NAMath.yAxis, v: v, ru: r * 0.85, rv: r, region: "hand\(sfx)")
            }
            let rings = [
                fring(joints[0] - dir * (0.08 * hl), r0 * 1.15),
                fring(joints[0] - dir * (0.04 * hl), r0 * 1.15),
                fring(joints[0] + dir * (0.03 * hl), r0),
                fring(joints[1], r0 * 0.92),
                fring(joints[2], r0 * 0.80),
            ]
            mesh.loft(rings, segments: Self.thumbSegments, capStart: joints[0] - dir * (0.13 * hl), capEnd: joints[2] + dir * (0.09 * hl))
        }
        let meta = layout.joint(side == "left" ? .leftThumbMetacarpal : .rightThumbMetacarpal)
        let proximal = layout.joint(side == "left" ? .leftThumbProximal : .rightThumbProximal)
        let distal = layout.joint(side == "left" ? .leftThumbDistal : .rightThumbDistal)
        let thumbDir = NAMath.normalize(distal - meta)
        let tu = NAMath.yAxis
        let tv = NAMath.normalize(NAMath.cross(thumbDir, tu))
        func thumbRing(_ p: NAVec3, _ r: Double) -> Ring {
            Ring(center: p, u: tu, v: tv, ru: r, rv: r, region: "hand\(sfx)")
        }
        let thumb = [thumbRing(meta, 0.010 * H), thumbRing(proximal, 0.0085 * H), thumbRing(distal, 0.0065 * H)]
        mesh.loft(thumb, segments: Self.thumbSegments, capStart: meta - thumbDir * (0.012 * H), capEnd: distal + thumbDir * (0.06 * hl))
    }

    private func buildFoot(_ mesh: inout BuildMesh, side: String) {
        let sfx = NativeAnimeControls.suffix(side)
        let x = layout.joint(side == "left" ? .leftUpperLeg : .rightUpperLeg).x
        func footRing(_ z: Double, rx: Double, ry: Double) -> Ring {
            Ring(center: NAVec3(x, ry * H, z * H), u: NAMath.xAxis, v: NAMath.yAxis, ru: rx * H, rv: ry * H, region: "foot\(sfx)")
        }
        let footRings = [
            footRing(-0.030, rx: 0.022, ry: 0.024),
            footRing(0.000, rx: 0.026, ry: 0.030),
            footRing(0.040, rx: 0.027, ry: 0.024),
            footRing(0.080, rx: 0.028, ry: 0.016),
            footRing(0.115, rx: 0.024, ry: 0.010),
        ]
        mesh.loft(footRings, segments: Self.limbSegments, capStart: NAVec3(x, 0.022 * H, -0.040 * H), capEnd: NAVec3(x, 0.008 * H, 0.130 * H))
    }
```

- [ ] **Step 5: Run the template suites**

Run: `swift test --filter "NativeAnimeGeometryTests|NativeAnimeRigTests|NativeAnimeMorphTests|NativeAnimeProportionTests|TemplatePackTests" --disable-sandbox`
Expected: the new test PASS; `testBodyWeightsFollowRegions` PASS ("mitt tip follows a finger bone" still holds because the most +x hand vertex is the middle fingertip cap); `testRestPoseIsTPoseInMetres` PASS (it checks arm/leg bones only; if it asserts finger joints share the hand's y, the fan keeps y unchanged); golden hash FAILS once, update `goldenDefaultBuildHash`, re-run, PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/VRMAuthorKit/Template/NativeAnime/NativeAnimeLayout.swift Sources/VRMAuthorKit/Template/NativeAnime/NativeAnimeBodyBuilder.swift Tests/VRMAuthorKitTests/Template/NativeAnimeGeometryTests.swift Tests/VRMAuthorKitTests/Template/TemplatePackTests.swift
git commit -m "native-anime: fanned fingers with knuckles, thumb along its bones, shaped foot"
```

### Task 3: Girth metrics in the style linter, profile 0.2.0, hash pins

**Files:**
- Modify: `scripts/style_lint.py:447-490` (geometry loop), `:531` (after `M["proportions"]`), metric docs in `describe()` are not needed (metric definitions live in the profile)
- Modify: `scripts/test_style_lint.py`
- Modify: `docs/style/profiles/vroid-lineage-anime.json` (`version`, `metric_definitions`, four rules)
- Regenerate: `docs/style/corpus/vroid-lineage-anime.measurements.json`, `docs/style/corpus/vroid-lineage-anime.witnesses.native-anime-v1.json`
- Modify: `docs/style/README.md` (after "## Material roles")
- Modify: `Sources/VRMAuthorKit/QA/QASuite.swift:25-26`, `Sources/VRMAuthorKit/Materials/StyleToolchain.swift:22-23`
- Modify: `Tests/VRMAuthorKitTests/Materials/StyleLintTests.swift:48`
- Modify: `docs/proposals/vrm-author-cli/README.md:58-59`, `docs/proposals/vrm-author-cli/verification.md:87,93`
- Modify: `oracleHashes` in `docs/proposals/vrm-author-cli/acceptance/packs/{export-vrm,style-lint,control-set,recipe-apply,style-attach,doctor}.json`

**Interfaces:**
- Consumes: `assign_role`, `accessor_array`, `world_mats` in `scripts/style_lint.py`; `envelopes(profile, corpus, write_path)`; `NativeAnimeProportionTests.envelopes()` (Task 1) which will now also see the girth rules.
- Produces: measurement keys `girth.upper_arm_ratio`, `girth.lower_arm_ratio`, `girth.thigh_ratio`, `girth.shin_ratio`, `girth.neck_ratio` (float or null); rules `girth.upper_arm`, `girth.thigh`, `girth.shin`, `girth.neck`.

- [ ] **Step 1: Write the failing python unit test**

Add a module-level fixture builder to `scripts/test_style_lint.py` after `minimal_vrm`:

```python
def skinned_arm_vrm(skin_width, cloth_width):
    """VRM 1.0 GLB with a T-pose left arm and two skinned 12-segment cylinders along
    leftUpperArm→leftLowerArm: one named as skin, one (wider) named as cloth."""
    names = ["hips", "spine", "head", "leftUpperArm", "leftLowerArm", "rightUpperArm", "leftUpperLeg", "rightUpperLeg"]
    world = {"hips": (0, 0.9, 0), "spine": (0, 1.1, 0), "head": (0, 1.55, 0), "leftUpperArm": (0.2, 1.3, 0), "leftLowerArm": (0.45, 1.3, 0),
             "rightUpperArm": (-0.2, 1.3, 0), "leftUpperLeg": (0.08, 0.85, 0), "rightUpperLeg": (-0.08, 0.85, 0)}
    nodes = [{"name": n, "translation": [float(c) for c in world[n]]} for n in names]
    ua = names.index("leftUpperArm")

    def cylinder(width):
        pts, idx = [], []
        for k in range(12):
            a = 2 * np.pi * k / 12
            for t in (0.2, 0.8):
                pts.append((0.2 + 0.25 * t, 1.3 + 0.5 * width * np.cos(a), 0.5 * width * np.sin(a)))
        for k in range(12):
            a, b = 2 * k, 2 * ((k + 1) % 12)
            idx += [a, a + 1, b, b, a + 1, b + 1]
        return np.array(pts, np.float32), np.array(idx, np.uint16)

    buf, views, accessors, prims = b"", [], [], []

    def push(arr, ctype, atype, extra=None):
        nonlocal buf
        views.append({"buffer": 0, "byteOffset": len(buf), "byteLength": arr.nbytes})
        accessors.append({"bufferView": len(views) - 1, "componentType": ctype, "count": len(arr), "type": atype, **(extra or {})})
        buf += arr.tobytes()
        buf += b"\0" * (-len(buf) % 4)
        return len(accessors) - 1

    for mi, width in enumerate((skin_width, cloth_width)):
        P, I = cylinder(width)
        J = np.zeros((len(P), 4), np.uint16)
        J[:, 0] = ua
        Wt = np.zeros((len(P), 4), np.float32)
        Wt[:, 0] = 1
        attrs = {"POSITION": push(P, 5126, "VEC3", {"min": P.min(0).tolist(), "max": P.max(0).tolist()}),
                 "JOINTS_0": push(J, 5123, "VEC4"), "WEIGHTS_0": push(Wt, 5126, "VEC4")}
        prims.append({"attributes": attrs, "indices": push(I, 5123, "SCALAR"), "material": mi})
    ibm = np.zeros((len(names), 16), np.float32)
    for i, n in enumerate(names):
        ibm[i, [0, 5, 10, 15]] = 1
        ibm[i, 12:15] = -np.array(world[n], np.float32)
    ibm_acc = push(ibm, 5126, "MAT4")
    nodes.append({"name": "mesh", "mesh": 0, "skin": 0})
    js = {"asset": {"version": "2.0"}, "nodes": nodes, "meshes": [{"primitives": prims}],
          "skins": [{"joints": list(range(len(names))), "inverseBindMatrices": ibm_acc}],
          "accessors": accessors, "bufferViews": views, "buffers": [{"byteLength": len(buf)}],
          "materials": [{"name": "Body_00_SKIN"}, {"name": "Tops_01_CLOTH"}],
          "extensions": {"VRMC_vrm": {"specVersion": "1.0", "humanoid": {"humanBones": {n: {"node": i} for i, n in enumerate(names)}},
                                      "meta": {"name": "arm", "authors": ["t"], "licenseUrl": "https://vrm.dev/licenses/1.0/"},
                                      "expressions": {"preset": {}}, "lookAt": {"type": "bone"}}}}
    return js, buf
```

and a test in `RobustnessTests`:

```python
    def test_girth_measures_skin_role_silhouette_only(self):
        M = self.measure(*skinned_arm_vrm(skin_width=0.10, cloth_width=0.30))
        H = M["asset"]["height_m"]
        self.assertAlmostEqual(M["girth"]["upper_arm_ratio"], 0.10 / H, places=3)
        for k in ("lower_arm_ratio", "thigh_ratio", "shin_ratio", "neck_ratio"):
            self.assertIsNone(M["girth"][k], k)
```

- [ ] **Step 2: Run it to verify it fails**

Run: `python3 -m unittest scripts/test_style_lint.py -k girth -v`
Expected: FAIL with `KeyError: 'girth'`.

- [ ] **Step 3: Add the metric to `measure()`**

In the geometry loop of `scripts/style_lint.py`, before `for ni, n in enumerate(nodes):`, add:

```python
    roles = [assign_role(name, role_overrides) for name, _ in mats]
    skin_pts, skin_dom = [], []
```

Inside the primitive loop, after the existing `head_pts.append(...)` block (inside the `if skinned and "JOINTS_0" in prim["attributes"]:` branch):

```python
                if mid is not None and mid < len(roles) and roles[mid] in ("body_skin", "face_skin"):
                    skin_pts.append(Pw)
                    skin_dom.append(dom)
```

After `M["proportions"] = P_` add:

```python
    # ---- girth: silhouette extent of skin-role vertices dominated by a bone, over the
    # middle 30 % of the bone segment, perpendicular to the segment, divided by height.
    sp = np.concatenate(skin_pts) if skin_pts else np.zeros((0, 3))
    sd = np.concatenate(skin_dom) if skin_dom else np.zeros((0,), dtype=np.int64)

    def girth(bone, child, axes):
        if bone not in bones or child not in pos:
            return None
        sel = sp[sd == bones[bone]]
        if len(sel) == 0:
            return None
        a, b = pos[bone], pos[child]
        seg = b - a
        t = ((sel - a) @ seg) / max(float(seg @ seg), 1e-9)
        sel = sel[(t > 0.35) & (t < 0.65)]
        if len(sel) < 8:
            return None
        return round(max(float(sel[:, i].max() - sel[:, i].min()) for i in axes) / H, 4)

    M["girth"] = {"upper_arm_ratio": girth("leftUpperArm", "leftLowerArm", (1, 2)),
                  "lower_arm_ratio": girth("leftLowerArm", "leftHand", (1, 2)),
                  "thigh_ratio": girth("leftUpperLeg", "leftLowerLeg", (0, 2)),
                  "shin_ratio": girth("leftLowerLeg", "leftFoot", (0, 2)),
                  "neck_ratio": girth("neck", "head", (0, 2))}
```

- [ ] **Step 4: Run the python tests**

Run: `python3 -m unittest scripts/test_style_lint.py`
Expected: all PASS including the girth test.

- [ ] **Step 5: Extend the profile**

In `docs/style/profiles/vroid-lineage-anime.json` set `"version": "0.2.0"`, add to `metric_definitions`:

```json
  "girth.upper_arm_ratio": "silhouette extent (max of the two axes perpendicular to the bone) of skin-role vertices dominated by leftUpperArm over the middle 30 % of the segment, divided by height; null when fewer than 8 vertices qualify.",
  "girth.lower_arm_ratio": "as girth.upper_arm_ratio for leftLowerArm→leftHand.",
  "girth.thigh_ratio": "as girth.upper_arm_ratio for leftUpperLeg→leftLowerLeg (x/z extent).",
  "girth.shin_ratio": "as girth.upper_arm_ratio for leftLowerLeg→leftFoot (x/z extent).",
  "girth.neck_ratio": "as girth.upper_arm_ratio for neck→head (x/z extent)."
```

and four rules after `prop.limb_symmetry`:

```json
    {"id": "girth.upper_arm", "class": "aesthetic", "severity": "should", "metric": "girth.upper_arm_ratio",
     "title": "Slim upper arms", "check": {"type": "range", "min": 0.03, "max": 0.11},
     "rationale": "Skin-role silhouette only; sleeves are excluded so a cardigan cannot mask a thick arm.",
     "provenance": {"source": "corpus"}},
    {"id": "girth.thigh", "class": "aesthetic", "severity": "should", "metric": "girth.thigh_ratio",
     "title": "Thigh silhouette", "check": {"type": "range", "min": 0.06, "max": 0.14}, "provenance": {"source": "corpus"}},
    {"id": "girth.shin", "class": "aesthetic", "severity": "should", "metric": "girth.shin_ratio",
     "title": "Shin silhouette", "check": {"type": "range", "min": 0.04, "max": 0.10}, "provenance": {"source": "corpus"}},
    {"id": "girth.neck", "class": "aesthetic", "severity": "should", "metric": "girth.neck_ratio",
     "title": "Neck silhouette", "check": {"type": "range", "min": 0.03, "max": 0.11}, "provenance": {"source": "corpus"}}
```

- [ ] **Step 6: Re-measure the corpus and regenerate provenance**

```bash
python3 scripts/style_lint.py corpus docs/style/corpus/vroid-lineage-anime.manifest.json --out docs/style/corpus/vroid-lineage-anime.measurements.json
python3 scripts/style_lint.py envelopes --profile docs/style/profiles/vroid-lineage-anime.json --measurements docs/style/corpus/vroid-lineage-anime.measurements.json --write
python3 scripts/style_lint.py lint --profile docs/style/profiles/vroid-lineage-anime.json AvatarSample_U_1.0.vrm.glb AvatarSample_A_1.0.vrm.glb
```
Expected: `corpus` reports 22 measured, 0 missing (all manifest assets are present on this machine as of 2026-09-12; if any is missing stop and restore it, never pass `--allow-missing`). `envelopes --write` fills `n/min/median/max/conforming` on the four new rules; check `conforming` is `22/22` or `21/22` for each and widen the `check` range if not. `lint` returns `conforming` for U and A as before.

- [ ] **Step 7: Move the hash pins**

```bash
shasum -a 256 scripts/style_lint.py docs/style/profiles/vroid-lineage-anime.json
```
Put the two hashes into `QAPins.styleLinterSha256` / `defaultProfileSha256` (`QASuite.swift`), `StyleToolchain.pinnedLinterSHA256` / `pinnedProfileSHA256`, `docs/proposals/vrm-author-cli/README.md` lines 58–59 (also change "(v0.1.0)" to "(v0.2.0)"), `verification.md` lines 87 and 93 ("Profile v0.2.0"), and the `oracleHashes` values for `scripts/style_lint.py` and `docs/style/profiles/vroid-lineage-anime.json` in the six packs listed above (`grep -l 01679f04 docs/proposals/vrm-author-cli/acceptance/packs/*.json` finds them). In `StyleLintTests.testFixtureConformsAndReportsOracleHashes` change the expected `profile_version` to `"0.2.0"`.

- [ ] **Step 8: Regenerate the witnesses file**

```bash
swift build --product vrm-author
python3 scripts/corpus_witness.py --measurements docs/style/corpus/vroid-lineage-anime.measurements.json --manifest docs/style/corpus/vroid-lineage-anime.manifest.json --profile docs/style/profiles/vroid-lineage-anime.json --template native-anime-v1 --out docs/style/corpus/vroid-lineage-anime.witnesses.native-anime-v1.json
```
Expected: the file's `styleLintSha256` equals the new linter hash and `templateSha256` equals `NativeAnimeV1Pack().sha256` (Tasks 1–2 changed geometry, so the solve reruns against the new template).

- [ ] **Step 9: Document the metric**

In `docs/style/README.md` after the "## Material roles" section add:

```markdown
## Girth metrics

`girth.*` metrics measure the body's silhouette, not its bones: for each of
leftUpperArm, leftLowerArm, leftUpperLeg, leftLowerLeg and neck, the vertices
of skin-role primitives (`face_skin`, `body_skin`) whose dominant joint is that
bone and that sit in the middle 30 % of the bone segment are projected onto the
two axes perpendicular to the bone; the larger extent divided by height is the
metric. Cloth is excluded on purpose, so a puffed sleeve cannot hide a thick
arm and a bare arm is measured the same way on every asset. Assets with fewer
than eight qualifying vertices report `null`, which fails the rule.
```

- [ ] **Step 10: Run the Swift suites that pin the linter**

Run: `swift test --filter "StyleLintTests|MaterialsPackTests|QAPackTests|NativeAnimeProportionTests" --disable-sandbox`
Expected: PASS. `MaterialsPackTests.testHandlersAreRegisteredAndPinsMatchVerificationTable` reads `verification.md`, so the table edit and the constants must agree. `NativeAnimeProportionTests` still passes (it only evaluates the bone metrics it computes).

- [ ] **Step 11: Commit**

```bash
git add scripts/style_lint.py scripts/test_style_lint.py docs/style docs/proposals/vrm-author-cli/README.md docs/proposals/vrm-author-cli/verification.md docs/proposals/vrm-author-cli/acceptance/packs Sources/VRMAuthorKit/QA/QASuite.swift Sources/VRMAuthorKit/Materials/StyleToolchain.swift Tests/VRMAuthorKitTests/Materials/StyleLintTests.swift
git commit -m "style: skin-role girth metrics, profile 0.2.0, corpus re-measure and pin move"
```

---

## Phase B: garments and rasters

### Task 4: Garment UV islands, trim strip and flat cloth rasters

**Files:**
- Create: `Sources/VRMAuthorKit/Wearables/GarmentUVLayout.swift`
- Modify: `Sources/VRMAuthorKit/Wearables/OutfitPresets.swift` (`build`, `addBand`, `buildSkirt`)
- Modify: `Sources/VRMAuthorKit/Wearables/WearableOutput.swift` (`GarmentInfo`)
- Modify: `Sources/VRMAuthorKit/Template/NativeAnime/NativeAnimeTextures.swift` (`garmentRaster`)
- Modify: `Sources/VRMAuthorKit/Template/NativeAnime/NativeAnimeMaterials.swift` (`garmentKinds`)
- Modify: `Sources/VRMAuthorKit/Template/NativeAnime/NativeAnimeV1Pack.swift:163-166`
- Modify: `Sources/VRMAuthorKit/Materials/MaterialRoleDefaults.swift` (`.cloth` pixel)
- Test: `Tests/VRMAuthorKitTests/Wearables/WearableOutfitTests.swift`, `Tests/VRMAuthorKitTests/Materials/MaterialsCompositingTests.swift`
- Modify: `Tests/VRMAuthorKitTests/Template/TemplatePackTests.swift:53`

**Interfaces:**
- Consumes: `OutfitKind`, `WearableRegion`, `MeshBuilder.uv0`, `RasterImage(width:height:)`, `RasterImage.uv(x:y:) -> SIMD2<Double>`, `RasterImage[x, y]`, `MaterialRoleDefaults.imageSize(for:)`.
- Produces:
  ```swift
  public struct GarmentUVIsland: Codable, Hashable, Sendable { public var name: String; public var rect: [Float]; public func contains(_ uv: SIMD2<Float>, tolerance: Float = 1e-4) -> Bool; func map(_ uv: SIMD2<Float>) -> SIMD2<Float> }
  public enum GarmentUVLayout { public static let trim: GarmentUVIsland; public static let skirt: GarmentUVIsland; public static func islands(for: OutfitKind) -> [GarmentUVIsland]; public static func island(for region: String, kind: OutfitKind) -> GarmentUVIsland? }
  // GarmentInfo gains `public var uvIslands: [String]` (init parameter with default [])
  // NativeAnimeTextures.garmentRaster(kind: OutfitKind, base: SIMD3<Float>, seed: UInt64) -> RasterImage
  // NativeAnimeMaterials.garmentKinds: [String: OutfitKind]  (image id → kind)
  ```

- [ ] **Step 1: Write the failing tests**

Append to `WearableOutfitTests`:

```swift
    func testShellUVsLandInRegionIslandsAndTrimInTheTrimStrip() throws {
        let out = try compile([Fixtures.top(length: 1), Fixtures.bottom(), Fixtures.footwear()])
        for (id, kind) in [("shirt", OutfitKind.top), ("pants", .bottom), ("shoes", .footwear)] {
            let prim = try garment(out, id)
            let info = try XCTUnwrap(out.garments.first { $0.id == id })
            let islands = GarmentUVLayout.islands(for: kind)
            for uv in prim.uv0 { XCTAssertTrue(islands.contains { $0.contains(uv) }, "\(id) uv \(uv) lies outside every island") }
            for a in islands { for b in islands where a.name < b.name {
                let overlap = min(a.rect[2], b.rect[2]) - max(a.rect[0], b.rect[0]) > 1e-6 && min(a.rect[3], b.rect[3]) - max(a.rect[1], b.rect[1]) > 1e-6
                XCTAssertFalse(overlap, "\(kind) islands \(a.name) and \(b.name) overlap")
            } }
            XCTAssertTrue(info.uvIslands.allSatisfy { name in islands.contains { $0.name == name } }, "\(id) \(info.uvIslands)")
        }
        let shirt = try garment(out, "shirt")
        XCTAssertGreaterThan(shirt.uv0.filter { GarmentUVLayout.trim.contains($0) }.count, 0, "collar, cuffs and hem take trim UVs")
        XCTAssertEqual(Set(out.garments.first { $0.id == "shirt" }!.uvIslands), ["torso", "upperArmL", "upperArmR", "forearmL", "forearmR", "trim"])
        let skirt = try garment(try compile([Fixtures.skirt()]), "skirt")
        XCTAssertTrue(skirt.uv0.allSatisfy { GarmentUVLayout.skirt.contains($0) || GarmentUVLayout.trim.contains($0) })
        XCTAssertGreaterThan(skirt.uv0.filter { GarmentUVLayout.trim.contains($0) }.count, 0, "the skirt carries a hem band")
    }
```

In `testShellReusesBodySkinWeightsAndUVs` replace the UV equality assertion with the island mapping: for a shell vertex whose source body index is `i` and region `r`, `XCTAssertEqual(prim.uv0[k], GarmentUVLayout.island(for: r, kind: .top)!.map(host.bodyUV0[i]))` (the test already pairs shell vertices with body vertices by position; keep that pairing and look the region up through `WearableCompiler.regionMap(host:)`).

Append to `MaterialsCompositingTests`:

```swift
    func testGarmentRasterHasADarkTrimStripAndNoWeave() {
        let base = SIMD3<Float>(0.6, 0.6, 0.6)
        let image = NativeAnimeTextures.garmentRaster(kind: .top, base: base, seed: 3)
        func lum(_ p: SIMD4<Float>) -> Float { 0.2126 * p.x + 0.7152 * p.y + 0.0722 * p.z }
        var body: Float = 0, trim: Float = 0, nb = 0, nt = 0
        for y in stride(from: 0, to: image.height, by: 4) {
            for x in stride(from: 0, to: image.width, by: 8) {
                let uv = image.uv(x: x, y: y)
                if uv.y > 0.905 { trim += lum(image[x, y]); nt += 1 }
                else if uv.y < 0.85, uv.x > 0.05, uv.x < 0.45 { body += lum(image[x, y]); nb += 1 }
            }
        }
        XCTAssertLessThan(trim / Float(nt), 0.85 * body / Float(nb), "trim strip reads darker than the torso island")
        let row = (0..<image.width).map { lum(image[$0, image.height / 4]) }
        XCTAssertLessThan(row.max()! - row.min()!, 0.06 * lum(SIMD4(base.x, base.y, base.z, 1)), "no high-frequency weave across a row")
        XCTAssertEqual(image, NativeAnimeTextures.garmentRaster(kind: .top, base: base, seed: 4), "cloth is seed-independent")
    }
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter "WearableOutfitTests/testShellUVsLandInRegionIslandsAndTrimInTheTrimStrip|MaterialsCompositingTests/testGarmentRasterHasADarkTrimStripAndNoWeave" --disable-sandbox`
Expected: compile error (`GarmentUVLayout`, `garmentRaster`, `uvIslands` undefined). Stub nothing; go to Step 3.

- [ ] **Step 3: Add the layout**

Create `Sources/VRMAuthorKit/Wearables/GarmentUVLayout.swift`:

```swift
import Foundation

/// One rectangle of a garment texture; `rect` is (u0, v0, u1, v1).
public struct GarmentUVIsland: Codable, Hashable, Sendable {
    public var name: String
    public var rect: [Float]

    public init(name: String, rect: [Float]) {
        self.name = name
        self.rect = rect
    }

    public func contains(_ uv: SIMD2<Float>, tolerance: Float = 1e-4) -> Bool {
        uv.x >= rect[0] - tolerance && uv.x <= rect[2] + tolerance && uv.y >= rect[1] - tolerance && uv.y <= rect[3] + tolerance
    }

    func map(_ uv: SIMD2<Float>) -> SIMD2<Float> {
        SIMD2(rect[0] + (rect[2] - rect[0]) * min(max(uv.x, 0), 1), rect[1] + (rect[3] - rect[1]) * min(max(uv.y, 0), 1))
    }
}

/// Named islands per outfit kind. Shells remap the body's per-loft UVs into
/// the island of each vertex's region; trim bands share the trim strip.
public enum GarmentUVLayout {
    public static let trim = GarmentUVIsland(name: "trim", rect: [0, 0.9, 1, 1])
    public static let skirt = GarmentUVIsland(name: "skirt", rect: [0, 0.45, 0.5, 0.9])

    public static func islands(for kind: OutfitKind) -> [GarmentUVIsland] {
        switch kind {
        case .top:
            return [GarmentUVIsland(name: "torso", rect: [0, 0, 0.5, 0.9]),
                    GarmentUVIsland(name: "upperArmL", rect: [0.5, 0, 0.75, 0.45]), GarmentUVIsland(name: "upperArmR", rect: [0.75, 0, 1, 0.45]),
                    GarmentUVIsland(name: "forearmL", rect: [0.5, 0.45, 0.75, 0.9]), GarmentUVIsland(name: "forearmR", rect: [0.75, 0.45, 1, 0.9]), trim]
        case .bottom:
            return [GarmentUVIsland(name: "waistHips", rect: [0, 0, 0.5, 0.45]), skirt,
                    GarmentUVIsland(name: "thighL", rect: [0.5, 0, 0.75, 0.45]), GarmentUVIsland(name: "thighR", rect: [0.75, 0, 1, 0.45]),
                    GarmentUVIsland(name: "shinL", rect: [0.5, 0.45, 0.75, 0.9]), GarmentUVIsland(name: "shinR", rect: [0.75, 0.45, 1, 0.9]), trim]
        case .footwear:
            return [GarmentUVIsland(name: "footL", rect: [0, 0, 0.5, 0.9]), GarmentUVIsland(name: "footR", rect: [0.5, 0, 1, 0.9]), trim]
        }
    }

    public static func island(for region: String, kind: OutfitKind) -> GarmentUVIsland? {
        let torso = [WearableRegion.chest, WearableRegion.torso, WearableRegion.waist, WearableRegion.hips]
        let name: String
        switch kind {
        case .top: name = torso.contains(region) ? "torso" : region
        case .bottom: name = (region == WearableRegion.waist || region == WearableRegion.hips || region == WearableRegion.torso) ? "waistHips" : region
        case .footwear: name = region
        }
        return islands(for: kind).first { $0.name == name }
    }
}
```

- [ ] **Step 4: Remap UVs in the shell, band and skirt builders**

`WearableCompiler.regionMap(host:)` assigns each vertex the first matching name in `WearableRegion.all` order, so on the native host every torso-loft vertex below the chest arrives as `torso` (the loft's `extraRegions` tag) rather than `waist` or `hips`; `island(for:kind:)` above folds `torso` into `waistHips` for bottoms for that reason.

In `OutfitPresets.build`, replace the vertex loop:

```swift
        var usedIslands = Set<String>()
        for i in ordered {
            guard i < host.bodyPositions.count, i < host.bodyNormals.count, i < host.bodyJoints.count, i < host.bodyWeights.count else { continue }
            let n = V3.normalize(host.bodyNormals[i])
            let raw = i < host.bodyUV0.count ? host.bodyUV0[i] : SIMD2<Float>(0, 0)
            let island = GarmentUVLayout.island(for: regionOfVertex[i] ?? "", kind: d.kind)
            if let island { usedIslands.insert(island.name) }
            remap[i] = builder.addVertex(host.bodyPositions[i] + n * offset, normal: n, uv: island?.map(raw) ?? raw, joints: host.bodyJoints[i], weights: host.bodyWeights[i])
            sources.append(i)
        }
```

After `addTrimBands(...)` add `usedIslands.insert(GarmentUVLayout.trim.name)` (inside the same `if`), and pass `uvIslands: usedIslands.sorted()` to `GarmentInfo`.

In `addBand`, enumerate the rim and give both rows trim UVs:

```swift
        for (k, i) in ordered.enumerated() {
            guard let vi = remap[i], Int(vi) < builder.positions.count else { return }
            let shellPos = builder.positions[Int(vi)]
            let n = V3.normalize(host.bodyNormals[i])
            let horizontal = V3.normalize(SIMD3<Float>(shellPos.x - centre.x, 0, shellPos.z - centre.z), fallback: n)
            let outward = aroundY ? horizontal : n
            let u = Float(k) / Float(ordered.count)
            innerRow.append(UInt32(builder.positions.count))
            builder.addVertex(shellPos, normal: n, uv: GarmentUVLayout.trim.map(SIMD2(u, 0.1)), joints: host.bodyJoints[i], weights: host.bodyWeights[i])
            outerRowIds.append(UInt32(builder.positions.count))
            builder.addVertex(outerRow(shellPos, n, outward), normal: n, uv: GarmentUVLayout.trim.map(SIMD2(u, 0.9)), joints: host.bodyJoints[i], weights: host.bodyWeights[i])
            sources.append(contentsOf: [i, i])
        }
```

In `buildSkirt`, map ring UVs through the skirt island (`uv: GarmentUVLayout.skirt.map(SIMD2(Float(k) / Float(segments), t))`), keep the last ring's radii in `var lastRx: Float = 0, lastRz: Float = 0` (assigned inside the ring loop after `rx`/`rz` are computed), and add a hem band row after the ring loop:

```swift
        var band: [UInt32] = []
        let last = rows[ringCount - 1]
        for k in 0..<segments {
            let a = 2 * Float.pi * Float(k) / Float(segments)
            let p = SIMD3<Float>((lastRx + 0.002) * cos(a), hemY - 0.015, (lastRz + 0.002) * sin(a))
            let n = V3.normalize(SIMD3(cos(a), flare, sin(a)))
            let src = sources[Int(last[k])]
            band.append(builder.addVertex(p, normal: n, uv: GarmentUVLayout.trim.map(SIMD2(Float(k) / Float(segments), 0.9)),
                                          joints: host.bodyJoints[src], weights: host.bodyWeights[src]))
            sources.append(src)
        }
        for k in 0..<segments {
            let k1 = (k + 1) % segments
            builder.addQuad(last[k], last[k1], band[k1], band[k])
        }
```

(`sources[Int(last[k])]` works because `sources` is appended in vertex order.) Pass `uvIslands: [GarmentUVLayout.skirt.name, GarmentUVLayout.trim.name]` to the skirt's `GarmentInfo`.

In `WearableOutput.swift` add `public var uvIslands: [String]` to `GarmentInfo` and `uvIslands: [String] = []` as the last `init` parameter.

- [ ] **Step 5: Paint the rasters**

In `NativeAnimeTextures` add:

```swift
    /// Flat cloth with a slow tone drift, a darker trim strip with one
    /// lighter stitch row, and a faint seam column at each island's u = 0.
    static func garmentRaster(kind: OutfitKind, base: SIMD3<Float>, seed: UInt64) -> RasterImage {
        let size = MaterialRoleDefaults.imageSize(for: .cloth)
        var image = RasterImage(width: size, height: size)
        let trim = GarmentUVLayout.trim
        let islands = GarmentUVLayout.islands(for: kind).filter { $0.name != trim.name }
        let texel = 1 / Float(size)
        for y in 0..<size {
            for x in 0..<size {
                let uv = image.uv(x: x, y: y)
                let u = Float(uv.x), v = Float(uv.y)
                var c = base * (0.98 + 0.02 * sin(2 * Float.pi * 3 * v + 1.3 * sin(2 * Float.pi * 2 * u)))
                if v >= trim.rect[1] {
                    c = base * (abs(v - 0.92) < texel ? 0.92 : 0.80)
                } else if let island = islands.first(where: { $0.contains(SIMD2(u, v), tolerance: 0) }), u - island.rect[0] < 2 * texel {
                    c *= 0.98
                }
                image[x, y] = SIMD4(min(c.x, 1), min(c.y, 1), min(c.z, 1), 1)
            }
        }
        return image
    }
```

In `NativeAnimeMaterials` add `public static let garmentKinds: [String: OutfitKind] = [clothTopImageId: .top, clothBottomImageId: .bottom, clothFootwearImageId: .footwear]`, and in `NativeAnimeV1Pack.compileWithAttachments` replace the garment image loop body with `sources[imageId] = NativeAnimeTextures.garmentRaster(kind: NativeAnimeMaterials.garmentKinds[imageId] ?? .top, base: palette, seed: seed)`.

In `MaterialRoleDefaults.pixel` replace the `.cloth` case (the role default no longer carries a weave either):

```swift
        case .cloth:
            return opaque(base * (0.98 + 0.02 * sin(v * 2 * Float.pi * 3 + 1.3 * sin(u * 2 * Float.pi * 2))))
```

- [ ] **Step 6: Run the wearable, material and pack suites**

Run: `swift test --filter "WearableOutfitTests|WearablesPackTests|MaterialsCompositingTests|MaterialsPackTests|TemplatePackTests|ExportPackTests|QAPackTests" --disable-sandbox`
Expected: PASS except the golden hash (update it, re-run). `testProceduralDefaultsAreDeterministicAndSeedSensitive` still passes (cloth stays seed-independent).

- [ ] **Step 7: Commit**

```bash
git add Sources/VRMAuthorKit/Wearables Sources/VRMAuthorKit/Template/NativeAnime Sources/VRMAuthorKit/Materials/MaterialRoleDefaults.swift Tests/VRMAuthorKitTests/Wearables/WearableOutfitTests.swift Tests/VRMAuthorKitTests/Materials/MaterialsCompositingTests.swift Tests/VRMAuthorKitTests/Template/TemplatePackTests.swift
git commit -m "wearables: garment UV islands with a trim strip, flat cloth rasters"
```

### Task 5: Skirt clearance profile and closed collar

**Files:**
- Modify: `Sources/VRMAuthorKit/Wearables/OutfitPresets.swift` (`buildSkirt`, `addTrimBands`)
- Modify: `Sources/VRMAuthorKit/Wearables/WearableOutput.swift` (`GarmentInfo.collarGapM`)
- Create: `Tests/VRMAuthorKitTests/Wearables/WearableGarmentFitTests.swift`
- Modify: `Tests/VRMAuthorKitTests/Template/TemplatePackTests.swift:53`

**Interfaces:**
- Consumes: `SurfaceProbe(positions:normals:indices:include:)`, `SurfaceProbe.signedDistance(to:)`, `NativeAnimeStarters.starterRecipe`, `NativeAnimeFixture.pack.compileWithAttachments`, `TemplateAttachments.indices(of:mesh:)`, `OutfitPresets.minClearanceM`.
- Produces: `GarmentInfo.collarGapM: Double?` (init parameter with default nil; the worst remaining front gap between the collar's outer row and the neck, nil for garments without a collar); `TemplateAttachments.garments: [GarmentInfo]` filled by `compileWithAttachments`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/VRMAuthorKitTests/Wearables/WearableGarmentFitTests.swift`:

```swift
import Foundation
import XCTest
@testable import VRMAuthorKit

/// Garment fit on the real native-anime host with the female starter, where
/// the thigh and torso lofts overlap and the clearance gate cannot see a
/// skirt cutting through the thigh tops.
final class WearableGarmentFitTests: XCTestCase {
    static func female() throws -> (avatar: CompiledAvatar, attachments: TemplateAttachments, recipe: Recipe) {
        let recipe = try NativeAnimeStarters.starterRecipe(base: .female, registry: TemplateRegistry.standard())
        let (avatar, attachments) = try NativeAnimeFixture.pack.compileWithAttachments(recipe, seed: NativeAnimeStarters.seed)
        return (avatar, attachments, recipe)
    }

    func testSkirtClearsTheLowerBodyAtEveryVertex() throws {
        let (avatar, attachments, recipe) = try Self.female()
        let item = try XCTUnwrap(recipe.outfits.first { $0.preset == "skirt-v1" })
        let skirt = try XCTUnwrap(avatar.meshes.first { $0.id == "mesh:garment:\(item.id)" }).primitives[0]
        let body = NativeAnimeFixture.primitive(avatar, mesh: "mesh.body")
        let lower = Set(["waist", "hips", "thighL", "thighR", "shinL", "shinR"].flatMap { attachments.indices(of: $0, mesh: "mesh.body") })
        let probe = SurfaceProbe(positions: body.positions, normals: body.normals, indices: body.indices) { a, b, c in
            lower.contains(a) && lower.contains(b) && lower.contains(c)
        }
        var worst = Float.infinity
        for p in skirt.positions { worst = min(worst, try XCTUnwrap(probe.signedDistance(to: p))) }
        XCTAssertGreaterThanOrEqual(worst, Float(OutfitPresets.minClearanceM), "skirt penetrates the lower body by \(worst)")
        let rings = Set(skirt.positions.map { ($0.y * 1000).rounded() })
        XCTAssertGreaterThanOrEqual(rings.count, 7, "six rings plus the hem band")
    }

    func testCollarClosesOnTheNeckWithoutCrossingIt() throws {
        let (avatar, attachments, recipe) = try Self.female()
        let top = try XCTUnwrap(recipe.outfits.first { $0.preset == "top-v1" })
        let info = try XCTUnwrap(attachments.garments.first { $0.id == top.id })
        let gap = try XCTUnwrap(info.collarGapM)
        XCTAssertLessThanOrEqual(gap, 0.002, "front collar gap \(gap)")
        let shirt = try XCTUnwrap(avatar.meshes.first { $0.id == info.meshId }).primitives[0]
        let outerV = GarmentUVLayout.trim.map(SIMD2(0, 0.9)).y
        let shellTop = shirt.positions.indices.filter { !GarmentUVLayout.trim.contains(shirt.uv0[$0]) }.map { shirt.positions[$0].y }.max()!
        let outerRowMin = shirt.positions.indices.filter { abs(shirt.uv0[$0].y - outerV) < 1e-4 && abs(shirt.positions[$0].x) < 0.10 }.map { shirt.positions[$0].y }.min()!
        XCTAssertGreaterThanOrEqual(outerRowMin, shellTop - 0.001, "collar band must sit on the shell's top edge, not below it")
        let body = NativeAnimeFixture.primitive(avatar, mesh: "mesh.body")
        let neck = attachments.indices(of: "neck", mesh: "mesh.body")
        for (k, p) in shirt.positions.enumerated() where GarmentUVLayout.trim.contains(shirt.uv0[k]) && p.y > attachments.jointWorldPositions[.neck]!.y - 0.01 {
            let neckR = neck.filter { abs(body.positions[$0].y - p.y) < 0.01 }.map { hypot(body.positions[$0].x, body.positions[$0].z) }.max() ?? 0
            XCTAssertGreaterThanOrEqual(hypot(p.x, p.z), neckR - 1e-4, "collar vertex \(k) is inside the neck shell")
        }
    }
}
```

`TemplateAttachments.garments` does not exist yet. In `TemplateAttachments.swift` add `public var garments: [GarmentInfo]` with `garments: [GarmentInfo] = []` as the last `init` parameter, and in `NativeAnimeV1Pack.compileWithAttachments` set `attachments.garments = wearables.garments` on a `var attachments` copy before returning it (the template-only `compileTemplate` leaves it empty).

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter WearableGarmentFitTests --disable-sandbox`
Expected: skirt test FAILS with a negative worst distance (thigh tops inside the cone); collar test fails on `collarGapM` (compile error until Step 4, then a gap ≈ 0.03).

- [ ] **Step 3: Profile the skirt from the body silhouette**

In `buildSkirt` extend `lower` with both shins, use six rings, and take each ring's radius from the body:

```swift
        let lower = waistIdx + hipsIdx + host.region(WearableRegion.thighL) + host.region(WearableRegion.thighR)
            + host.region(WearableRegion.shinL) + host.region(WearableRegion.shinR)
        func bodyRadius(at y: Float) -> (rx: Float, rz: Float) {
            var rx: Float = 0, rz: Float = 0
            for i in lower where abs(host.bodyPositions[i].y - y) < 0.02 {
                rx = max(rx, abs(host.bodyPositions[i].x))
                rz = max(rz, abs(host.bodyPositions[i].z))
            }
            return (rx, rz)
        }
        let ringCount = 6
        for r in 0..<ringCount {
            let t = Float(r) / Float(ringCount - 1)
            let y = topY + (hemY - topY) * t
            let body = bodyRadius(at: y)
            let rx = max(waistRx + offset + (hemRx - waistRx) * t, body.rx + offset + 0.010)
            let rz = max(waistRz + offset + (hemRz - waistRz) * t, body.rz + offset + 0.010)
```

(`hemRx`/`hemRz` keep their formula; the ring loop body below the radius lines is unchanged.)

- [ ] **Step 4: Lean the collar in and move the rim to the shell top**

The collar today is built on the top ring of the `chest` region (`at(0.86)`), but `top-v1` also covers `torso`, so the shell runs to the `at(1.00)` ring and the band sits about 6 cm below the shell's edge; that is the dark neckline. Replace the collar block in `addTrimBands` (the function gains an `inout collarGap: Float?` parameter; `build` passes a local and stores it as `collarGapM: collarGap.map(Double.init)`):

```swift
        let shell = covered.filter { remap[$0] != nil && (regionOfVertex[$0] == WearableRegion.chest || regionOfVertex[$0] == WearableRegion.torso) }
        if !shell.isEmpty {
            let topY = shell.map { host.bodyPositions[$0].y }.max()!
            let rim = shell.filter { topY - host.bodyPositions[$0].y < 0.012 }
            let rimY = rim.map { host.bodyPositions[$0].y }.reduce(0, +) / Float(max(rim.count, 1))
            let neckIdx = host.region("neck").filter { host.bodyPositions[$0].y >= rimY - 0.01 }
            let neckR: Float = neckIdx.map { hypot(host.bodyPositions[$0].x, host.bodyPositions[$0].z) }.max() ?? 0
            var worst: Float = 0
            addBand(builder: &builder, host: host, rim: rim, remap: remap, sources: &sources, axis: SIMD3(0, 1, 0), aroundY: true) { p, n, out in
                let frontness = 1 - OutfitPresets.shapeSmooth01((abs(out.x) - 0.5) / 0.25)
                let gap = neckR > 0 ? max(hypot(p.x, p.z) - neckR, 0) : 0
                let lean = max(gap - 0.002, 0) * frontness
                let q = p + SIMD3<Float>(0, 0.012 * frontness, 0) - out * lean + n * 0.001
                if frontness > 0.5, neckR > 0 { worst = max(worst, hypot(q.x, q.z) - neckR) }
                return q
            }
            collarGap = neckR > 0 ? worst : nil
        }
```

- [ ] **Step 5: Run the fit, outfit and pack suites**

Run: `swift test --filter "WearableGarmentFitTests|WearableOutfitTests|WearablesPackTests|TemplatePackTests|NativeAnimeStartersTests" --disable-sandbox`
Expected: PASS (golden hash updated once). `testSkirtHangsFromTheWaistAndClearsTheBody` on the synthetic host still passes: its top-ring assertion uses `waistMax + baseClearanceM`, and the profile only raises rings that would otherwise cut the body.

- [ ] **Step 6: Commit**

```bash
git add Sources/VRMAuthorKit/Wearables Sources/VRMAuthorKit/Template/NativeAnime Tests/VRMAuthorKitTests/Wearables/WearableGarmentFitTests.swift Tests/VRMAuthorKitTests/Template/TemplatePackTests.swift
git commit -m "wearables: skirt rings follow the body silhouette, collar leans onto the neck"
```

### Task 6: Face raster: lip band, softer blush, iris tracking test

**Files:**
- Modify: `Sources/VRMAuthorKit/Materials/MaterialRoleDefaults.swift` (`.mouth` base colour and pixel)
- Modify: `Sources/VRMAuthorKit/Template/NativeAnime/NativeAnimeTextures.swift:98` (blush call)
- Modify: `Sources/VRMAuthorKit/Template/NativeAnime/NativeAnimeHeadBuilder.swift:392-396` (inner lip and cavity-front UVs)
- Test: `Tests/VRMAuthorKitTests/Materials/MaterialsCompositingTests.swift`, `Tests/VRMAuthorKitTests/Template/NativeAnimeGeometryTests.swift`
- Modify: `Tests/VRMAuthorKitTests/Template/TemplatePackTests.swift:53`

- [ ] **Step 1: Write the failing tests**

Append to `MaterialsCompositingTests`:

```swift
    private func pixel(_ image: RasterImage, at target: SIMD2<Float>) -> SIMD4<Float> {
        let x = min(max(Int(target.x * Float(image.width)), 0), image.width - 1)
        let y = min(max(Int(target.y * Float(image.height)), 0), image.height - 1)
        var best = (x, y, Float.infinity)
        for dy in -1...1 { for dx in -1...1 {
            let px = min(max(x + dx, 0), image.width - 1), py = min(max(y + dy, 0), image.height - 1)
            let uv = image.uv(x: px, y: py)
            let d = hypot(Float(uv.x) - target.x, Float(uv.y) - target.y)
            if d < best.2 { best = (px, py, d) }
        } }
        return image[best.0, best.1]
    }

    func testMouthRasterPaintsTheInnerLipRingAsLipNotCavity() {
        let image = MaterialRoleDefaults.raster(for: .mouth, width: 512, height: 512, seed: 1)
        let base = MaterialRoleDefaults.baseColour(for: .mouth)
        func lum(_ p: SIMD4<Float>) -> Float { 0.2126 * p.x + 0.7152 * p.y + 0.0722 * p.z }
        let innerLip = pixel(image, at: SIMD2(0.5, 0.5 + 0.28))
        XCTAssertEqual(innerLip.x, base.x, accuracy: 0.12 * base.x)
        XCTAssertEqual(innerLip.y, base.y, accuracy: 0.12 * base.y)
        XCTAssertEqual(innerLip.z, base.z, accuracy: 0.12 * base.z)
        let cavity = pixel(image, at: SIMD2(0.5, 0.5 + 0.10))
        XCTAssertLessThan(lum(cavity), 0.3 * lum(SIMD4(base.x, base.y, base.z, 1)))
    }
```

Append to `NativeAnimeGeometryTests`:

```swift
    func testIrisAngleTracksTheSizeControl() throws {
        var angles: [Float] = []
        for size in [0.0, 0.5, 1.0] {
            let (_, attachments) = try NativeAnimeFixture.compiled { $0.face["face.iris.left.size"] = size }
            angles.append(attachments.eyes.first { $0.side == "left" }!.irisAngleRadians)
        }
        XCTAssertLessThan(angles[0], angles[1])
        XCTAssertLessThan(angles[1], angles[2])
        XCTAssertEqual(Double(angles[1]), 30 * Double.pi / 180, accuracy: 1e-4)
    }
```

- [ ] **Step 2: Run them to verify the mouth test fails**

Run: `swift test --filter "MaterialsCompositingTests/testMouthRasterPaintsTheInnerLipRingAsLipNotCavity|NativeAnimeGeometryTests/testIrisAngleTracksTheSizeControl" --disable-sandbox`
Expected: mouth test FAILS (the pixel at r = 0.28 is cavity-mixed); iris test PASSES already (it documents the contract).

- [ ] **Step 3: Repaint the mouth and soften the blush**

In `MaterialRoleDefaults.baseColour` set `.mouth` to `ColourTransfer.linear(srgb8: 232, 168, 158)`. In `pixel`, replace the first two lines of the `.mouth` case and the `lip` line:

```swift
        case .mouth:
            let cavity = 1 - Self.smooth01((r - 0.20) / 0.05)
            var c = mix(base, SIMD3<Float>(0.304, 0.039, 0.046), cavity)
            let lip = Self.smooth01((r - 0.22) / 0.04)
```

(the seam, corner and lipLight lines after it stay).

The inner lip ring's UVs sit at radius 0.10 at the lip centre (`0.5 - 0.1 * sa`), inside the cavity fill, so the lip quad would still sample cavity across half its width. In `NativeAnimeHeadBuilder.buildMouth` move the inner ring and cavity front outward:

```swift
            let i = mesh.addVertex(layout.onShell(x: 0.86 * W * ca, y: mouthY + innerGap * sa, offset: 0.0006), uv: NAVec2(0.5 + 0.43 * ca, 0.5 - 0.3 * sa),
                                   pivot: center, regions: regions)
            let f = mesh.addVertex(center + NAVec3(0.75 * W * ca, 0.010 * hh * sa, -0.02 * hh), uv: NAVec2(0.5 + 0.22 * ca, 0.5 - 0.22 * sa), pivot: center,
                                   regions: ["innerMouth"])
```

Add to `NativeAnimeGeometryTests`:

```swift
    func testInnerLipRingSamplesTheLipBand() throws {
        let (avatar, attachments) = try NativeAnimeFixture.compiled()
        let mouth = NativeAnimeFixture.primitive(avatar, mesh: "mesh.head", primitive: HeadPrimitive.mouth.rawValue)
        for i in attachments.indices(of: "lipsUpper", mesh: "mesh.head", primitive: HeadPrimitive.mouth.rawValue) + attachments.indices(of: "lipsLower", mesh: "mesh.head", primitive: HeadPrimitive.mouth.rawValue) {
            let uv = mouth.uv0[i]
            XCTAssertGreaterThanOrEqual(hypot(uv.x - 0.5, uv.y - 0.5), 0.28, "lip vertex \(i) samples the cavity")
        }
    }
```

In `NativeAnimeTextures.faceRaster` change the blush call to `blush(&image, centre: centre, radius: 0.050, strength: 0.09, colour: ColourTransfer.linear(srgb8: 244, 173, 164))`.

- [ ] **Step 4: Run the materials and pack suites**

Run: `swift test --filter "MaterialsCompositingTests|MaterialsPackTests|StyleLintTests|TemplatePackTests|NativeAnimeGeometryTests|NativeAnimeMorphTests" --disable-sandbox`
Expected: PASS (golden hash updated once; the viseme and emotion morph tests are unaffected because only UVs moved; `testRoleDefaultsSatisfyEveryMaterialRuleOfThePinnedProfile` still passes since only the texture and base colour changed, not the MToon factors).

- [ ] **Step 5: Commit**

```bash
git add Sources/VRMAuthorKit/Materials/MaterialRoleDefaults.swift Sources/VRMAuthorKit/Template/NativeAnime/NativeAnimeTextures.swift Sources/VRMAuthorKit/Template/NativeAnime/NativeAnimeHeadBuilder.swift Tests/VRMAuthorKitTests/Materials/MaterialsCompositingTests.swift Tests/VRMAuthorKitTests/Template/NativeAnimeGeometryTests.swift Tests/VRMAuthorKitTests/Template/TemplatePackTests.swift
git commit -m "materials: lip band instead of a painted cavity, softer blush, iris-size contract test"
```

---

## Phase C: hair

### Task 7: Rigid scalp-cap clumps

**Files:**
- Modify: `Sources/VRMAuthorKit/Wearables/HairBobV1.swift` (`LayoutParams`, `RootTarget`, `rootTargets`, `build`)
- Modify: `Sources/VRMAuthorKit/Wearables/WearableOutput.swift` (`HairClumpInfo.isRigid`)
- Test: `Tests/VRMAuthorKitTests/Wearables/WearableHairTests.swift`
- Modify: `Tests/VRMAuthorKitTests/Template/TemplatePackTests.swift:53`

**Interfaces:**
- Consumes: `HairBobV1.generateClump`, `traceStrip`, `SurfaceProbe`, `SyntheticHost.scalpSamples` (300 Fibonacci samples above 12°).
- Produces:
  ```swift
  extension HairBobV1.LayoutParams {
      public struct RigidCap: Sendable { public var ringClumps: Int; public var ringElevationDeg: Float; public var crownClumps: Int; public var crownElevationDeg: Float; public var lengthRatio: Float; public var widthFactor: Float }
      public var rigidCap: RigidCap?          // bob/long: RigidCap(10, 66, 4, 80, 0.45, 1.6); ponytail: nil
      public var rigidClumpCount: Int         // ringClumps + crownClumps, 0 when nil
  }
  // HairClumpInfo gains `public var isRigid: Bool` (init parameter default false); rigid clumps have nodeIds [] and springId "".
  // The hair skin's joint 0 is the host head node whenever rigidCap != nil.
  ```

- [ ] **Step 1: Write the failing test**

Append to `WearableHairTests`:

```swift
    func testRigidCapCoversTheCrownWithoutAddingSprings() throws {
        let out = try compileHair()
        let prim = try hairPrimitive(out)
        let P = HairBobV1.LayoutParams.bob
        let rigid = out.hairClumps.filter(\.isRigid)
        XCTAssertEqual(rigid.count, P.rigidClumpCount)
        XCTAssertEqual(out.hairClumps.count, HairBobV1.Layout.clumpCount + P.rigidClumpCount)
        XCTAssertEqual(out.springs.count, HairBobV1.Layout.clumpCount)
        let skin = try XCTUnwrap(out.skins.first { $0.id == "skin:hair:bob" })
        XCTAssertEqual(skin.jointNodeIds.first, host.headNodeId)
        for clump in rigid {
            XCTAssertTrue(clump.nodeIds.isEmpty)
            XCTAssertEqual(clump.springId, "")
            for v in clump.vertexStart..<(clump.vertexStart + clump.vertexCount) {
                XCTAssertEqual(prim.joints0![v], SIMD4(0, 0, 0, 0))
                XCTAssertEqual(prim.weights0![v], SIMD4(1, 0, 0, 0))
            }
            XCTAssertGreaterThan((clump.rootPosition.y - host.headCentre.y) / host.headRadius, sin(60 * Float.pi / 180), "cap roots sit on the crown")
        }
        let probe = SurfaceProbe(positions: prim.positions, normals: prim.normals, indices: prim.indices)
        let crown = host.scalpSamples.filter { ($0.position.y - host.headCentre.y) / host.headRadius > sin(35 * Float.pi / 180) }
        XCTAssertGreaterThan(crown.count, 50)
        var covered = 0
        for s in crown where abs(probe.signedDistance(to: s.position + s.normal * 0.006) ?? .infinity) < 0.012 { covered += 1 }
        XCTAssertGreaterThanOrEqual(Double(covered) / Double(crown.count), 0.95, "\(covered)/\(crown.count) crown samples lie under hair")
    }
```

Update the existing tests that assume every clump has a chain: in `testClumpLayoutIsPackConstant` compare `out.hairClumps.filter { !$0.isRigid }.count` with `clumpCount`, `Set(rootSampleIndex).count` with `clumpCount + rigidClumpCount`, and keep the node count assertion (rigid clumps add no nodes). In `testHairMeshIsSkinnedWithLongitudinalUVs` change the joint count to `clumpCount * nodesPerClump + 1`, skip the `clumpJoints`/`weights[vertexStart] == (1,0,0,0)` loop for rigid clumps, and keep the IBM check (joint 0's IBM inverts the head world matrix). In `testEveryClumpRootIsOnAScalpSample`, `testStripAndBoneSegmentsAreContinuous`, `testSpringsHaveTerminalTailsAndNoOverlap`, `testBangsKeepClearanceAcrossTipSweep` iterate `out.hairClumps.filter { !$0.isRigid }` where they touch `nodeIds`, `springId`, `sweepPivot` or `tipVertexStart`. `testNoHairVertexIsInsideTheHead` runs over every vertex unchanged.

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --filter WearableHairTests/testRigidCapCoversTheCrownWithoutAddingSprings --disable-sandbox`
Expected: compile error on `isRigid`/`rigidClumpCount`.

- [ ] **Step 3: Add the cap layout and the rigid build path**

In `LayoutParams` after `tail`:

```swift
        /// Rigid scalp cap: short, wide clumps skinned to the head bone with
        /// no chain, filling the crown between ring B and the part.
        public struct RigidCap: Sendable {
            public var ringClumps: Int
            public var ringElevationDeg: Float
            public var crownClumps: Int
            public var crownElevationDeg: Float
            public var lengthRatio: Float
            public var widthFactor: Float
        }
        public var rigidCap: RigidCap? = RigidCap(ringClumps: 10, ringElevationDeg: 66, crownClumps: 4, crownElevationDeg: 80, lengthRatio: 0.45, widthFactor: 1.6)
        public var rigidClumpCount: Int { rigidCap.map { $0.ringClumps + $0.crownClumps } ?? 0 }
```

In the `ponytail` initialiser add `rigidCap: nil` right after `tail: Tail(...)`. Add `var isRigid = false` to `RootTarget` and append the cap targets at the end of `rootTargets`:

```swift
        if let cap = P.rigidCap {
            for k in 0..<cap.ringClumps {
                targets.append(RootTarget(azimuthDeg: 360 * (Float(k) + 0.5) / Float(cap.ringClumps), elevationDeg: cap.ringElevationDeg, isBang: false, isRigid: true))
            }
            for k in 0..<cap.crownClumps {
                targets.append(RootTarget(azimuthDeg: 45 + 360 * Float(k) / Float(cap.crownClumps), elevationDeg: cap.crownElevationDeg, isBang: false, isRigid: true))
            }
        }
```

In `build`, before the clump loop, seed the skin with the head joint when a cap exists:

```swift
        if P.rigidCap != nil {
            jointIds.append(host.headNodeId)
            ibms.append(headInv.m)
        }
```

Inside the loop, for `target.isRigid`: build `controls` copy with `lengthM *= Double(cap.lengthRatio)` and `widthScale *= Double(cap.widthFactor)`, call `generateClump` with it, emit the strip vertices with `joints = SIMD4<UInt16>(0, 0, 0, 0)` and `weights = SIMD4<Float>(1, 0, 0, 0)`, skip node/spring creation, and append `HairClumpInfo(... nodeIds: [], springId: "", ... sweepPivot: strip.centres[pivotSection], sweepAxis: strip.widthDirs[pivotSection], sectionCentres: strip.centres, isRigid: true)`. Non-rigid clumps keep their code with `jointBase = UInt16(jointIds.count)` (now offset by the head joint). Add `isRigid` to `HairClumpInfo` (stored property, `isRigid: Bool = false` last in `init`).

- [ ] **Step 4: Run the hair suites**

Run: `swift test --filter "WearableHairTests|WearablesPackTests|TemplatePackTests|NativeAnimeStartersTests" --disable-sandbox`
Expected: PASS after the golden hash update. If coverage lands below 0.95, raise `ringClumps` to 12 and `crownClumps` to 6 before touching the threshold, and re-run `testNoHairVertexIsInsideTheHead` (cap strips must still clear the head by `headClearanceM`).

- [ ] **Step 5: Commit**

```bash
git add Sources/VRMAuthorKit/Wearables Tests/VRMAuthorKitTests/Wearables/WearableHairTests.swift Tests/VRMAuthorKitTests/Template/TemplatePackTests.swift
git commit -m "hair: rigid scalp-cap clumps cover the crown without new spring chains"
```

### Task 8: Highlight band aligned to one world height

**Files:**
- Modify: `Sources/VRMAuthorKit/Template/NativeAnime/NativeAnimeTextures.swift` (`hairRaster`, `highlightColumns`, `highlightV(column:)`)
- Modify: `Sources/VRMAuthorKit/Wearables/HairBobV1.swift` (`highlightColumn`, strip UVs)
- Modify: `Sources/VRMAuthorKit/Wearables/WearableOutput.swift` (`HairClumpInfo.highlightColumn`)
- Test: `Tests/VRMAuthorKitTests/Wearables/WearableHairTests.swift`, `Tests/VRMAuthorKitTests/Materials/MaterialsCompositingTests.swift`
- Modify: `Tests/VRMAuthorKitTests/Template/TemplatePackTests.swift:53`

**Interfaces:**
- Produces:
  ```swift
  extension NativeAnimeTextures {
      static let highlightColumns = 8
      static let highlightHeightFactor: Float = 0.50      // target = headCentre.y + factor × headRadius
      static func highlightV(column: Int) -> Float?       // nil for column 0, else 0.08 + 0.84 × (column − 1) / 6
  }
  extension HairBobV1 { static func highlightColumn(_ strip: Strip, host: WearableHost) -> Int }
  // HairClumpInfo gains `public var highlightColumn: Int` (init parameter default 0)
  ```

- [ ] **Step 1: Write the failing tests**

Append to `WearableHairTests`:

```swift
    func testHighlightColumnPutsTheBandAtOneWorldHeight() throws {
        let out = try compileHair()
        let prim = try hairPrimitive(out)
        let target = host.headCentre.y + NativeAnimeTextures.highlightHeightFactor * host.headRadius
        var lit = 0
        for clump in out.hairClumps {
            let column = clump.highlightColumn
            XCTAssertTrue((0..<NativeAnimeTextures.highlightColumns).contains(column))
            let mid = prim.uv0[clump.vertexStart + 1].x
            XCTAssertEqual(mid, (Float(column) + 0.5) / Float(NativeAnimeTextures.highlightColumns), accuracy: 1e-5, "\(clump.id) strip u lives in its column")
            guard let bandV = NativeAnimeTextures.highlightV(column: column) else {
                XCTAssertLessThan(clump.rootPosition.y, target + 0.002, "\(clump.id) is unlit only because it roots below the band height")
                continue
            }
            let range = clump.vertexStart..<(clump.vertexStart + clump.vertexCount)
            let nearest = range.min { abs(prim.uv0[$0].y - bandV) < abs(prim.uv0[$1].y - bandV) }!
            XCTAssertEqual(prim.positions[nearest].y, target, accuracy: 0.02, "\(clump.id) band vertex height")
            lit += 1
        }
        XCTAssertGreaterThan(lit, HairBobV1.LayoutParams.bob.ringBClumps, "ring B, bangs and the cap carry the band")
    }
```

Append to `MaterialsCompositingTests`:

```swift
    func testHairRasterColumnsCarryTheBandAtTheirOwnV() {
        let texture = HairTexture(baseColour: Colour(rgba: [0.3, 0.2, 0.1, 1]), rootColour: Colour(rgba: [0.3, 0.2, 0.1, 1]), tipColour: Colour(rgba: [0.3, 0.2, 0.1, 1]),
                                  highlightOpacity: 0.6, highlightWidth: 0.10)
        let image = NativeAnimeTextures.hairRaster(texture: texture, seed: 1)
        func lum(_ p: SIMD4<Float>) -> Float { 0.2126 * p.x + 0.7152 * p.y + 0.0722 * p.z }
        let w = image.width / NativeAnimeTextures.highlightColumns
        for column in 0..<NativeAnimeTextures.highlightColumns {
            let x = column * w + w / 2
            let profile = (0..<image.height).map { lum(image[x, $0]) }
            let peakRow = profile.indices.max { profile[$0] < profile[$1] }!
            if let bandV = NativeAnimeTextures.highlightV(column: column) {
                XCTAssertEqual(Float(image.uv(x: x, y: peakRow).y), bandV, accuracy: 0.03, "column \(column)")
                XCTAssertGreaterThan(profile[peakRow], 1.5 * profile.min()!, "column \(column) has a visible band")
            } else {
                XCTAssertLessThan(profile.max()! - profile.min()!, 0.08, "column 0 carries no band")
            }
        }
    }
```

Update `testHairMeshIsSkinnedWithLongitudinalUVs`: replace `uv0[vertexStart].x == 0` / `uv0[vertexStart + 2].x == 1` with `== Float(clump.highlightColumn) / 8` and `== Float(clump.highlightColumn + 1) / 8`.

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter "WearableHairTests/testHighlightColumnPutsTheBandAtOneWorldHeight|MaterialsCompositingTests/testHairRasterColumnsCarryTheBandAtTheirOwnV" --disable-sandbox`
Expected: compile error on `highlightColumns`/`highlightColumn`.

- [ ] **Step 3: Column the raster**

In `NativeAnimeTextures` add the constants and function, and change `hairRaster`'s inner loop:

```swift
    static let highlightColumns = 8
    static let highlightHeightFactor: Float = 0.50

    /// Band centre (strip V) painted in `column`; column 0 carries no band.
    static func highlightV(column: Int) -> Float? {
        guard column >= 1, column < highlightColumns else { return nil }
        return 0.08 + 0.84 * Float(column - 1) / Float(highlightColumns - 2)
    }
```

```swift
                let column = min(Int(u * Float(highlightColumns)), highlightColumns - 1)
                let uLocal = u * Float(highlightColumns) - Float(column)
                let flow = 2 * Float.pi * 96 * uLocal + seedPhase + 1.2 * sin(2 * Float.pi * 3 * v)
                let strand = 0.5 + 0.5 * sin(flow)
                let coarse = 0.5 + 0.5 * sin(2 * Float.pi * 12 * uLocal + 0.7 * sin(2 * Float.pi * 2 * v))
                c *= (0.93 + 0.11 * strand) * (0.95 + 0.09 * coarse)
                if let centre = highlightV(column: column) {
                    let h = 1 - smoothstep(0, highlightHalfWidth, abs(v - centre))
                    let lift = h * highlightOpacity
                    c = c * (1 - lift) + SIMD3<Float>(1, 1, 1) * lift
                }
```

(delete the old `highlightCentre` constant and the unconditional lift).

- [ ] **Step 4: Select the column per clump**

In `HairBobV1` add:

```swift
    /// Column whose band sits where the strip's centre line crosses the
    /// highlight height; 0 when the strip never reaches it.
    static func highlightColumn(_ strip: Strip, host: WearableHost) -> Int {
        let target = host.headCentre.y + NativeAnimeTextures.highlightHeightFactor * host.headRadius
        let steps = strip.centres.count - 1
        for i in 0..<steps where strip.centres[i].y >= target && strip.centres[i + 1].y < target {
            let f = (strip.centres[i].y - target) / max(strip.centres[i].y - strip.centres[i + 1].y, 1e-6)
            let v = (Float(i) + f) / Float(steps)
            let k = 1 + Int(((v - 0.08) / 0.84 * Float(NativeAnimeTextures.highlightColumns - 2)).rounded())
            return min(max(k, 1), NativeAnimeTextures.highlightColumns - 1)
        }
        return 0
    }
```

In `build`, compute `let column = highlightColumn(strip, host: host)` after `generateClump`, set the three strip UVs to `SIMD2((Float(column) + 0) / 8, u)`, `((Float(column) + 0.5) / 8, u)`, `((Float(column) + 1) / 8, u)` using `Float(NativeAnimeTextures.highlightColumns)` for the 8, and pass `highlightColumn: column` to `HairClumpInfo` (new stored property, `highlightColumn: Int = 0` last in `init` after `isRigid`).

- [ ] **Step 5: Run the hair and material suites**

Run: `swift test --filter "WearableHairTests|MaterialsCompositingTests|WearablesPackTests|TemplatePackTests" --disable-sandbox`
Expected: PASS after the golden hash update. If the alignment test misses by more than 0.02 m on the synthetic host, the strip's section spacing (`lengthM / 12` = 0.015 m) is the cause; tighten by rounding `k` toward the section whose centre is nearest `target` rather than by linear `v`.

- [ ] **Step 6: Commit**

```bash
git add Sources/VRMAuthorKit/Wearables Sources/VRMAuthorKit/Template/NativeAnime/NativeAnimeTextures.swift Tests/VRMAuthorKitTests/Wearables/WearableHairTests.swift Tests/VRMAuthorKitTests/Materials/MaterialsCompositingTests.swift Tests/VRMAuthorKitTests/Template/TemplatePackTests.swift
git commit -m "hair: eight-column raster puts the highlight band at one world height per clump"
```

---

## Phase D: stills, docs, re-pin

### Task 9: Metal still checks, comparison set, docs, full suite, re-pin

**Files:**
- Create: `Tests/VRMAuthorKitTests/Render/StarterStillTests.swift`
- Modify: `docs/superpowers/specs/2026-09-12-mcp-authoring-loop-design.md` (§6 pointer), `docs/proposals/vrm-author-cli/README.md` §6 (one paragraph)
- Regenerate: `/tmp/vrm-author-rate/stills/*__vrm-author-female.png`
- Re-pin: every pack under `docs/proposals/vrm-author-cli/acceptance/packs/`, `acceptance/evidence.json`

**Interfaces:**
- Consumes: `RenderPackTests.rendererBinary`, `RenderPackTests.rgbaPixels(_:)`, `VRMAuthorRenderAdapter`, `VRMAuthorRenderLocator.environmentKey`, `QAPins.renderScenarios()`, `GLBWriter.write(_:) -> GLBExport` (`.data`), `TestProject.make(pack:registry:env:)`, `TemplateAttachments.jointWorldPositions/headCenter/headRadii`, `NativeAnimeMaterials.garmentPalettes`, `MaterialRoleDefaults.baseColour(for:)`.

- [ ] **Step 1: Write the still tests (they skip without Metal)**

Create `Tests/VRMAuthorKitTests/Render/StarterStillTests.swift`:

```swift
import Foundation
import Metal
import XCTest
@testable import VRMAuthorKit

/// Pixel acceptance on the locked QA stills of the female starter. Skips
/// without `vrm-author-render` or a Metal device. With
/// `VRM_AUTHOR_STILLS_OUT` set, every rendered still is also copied to
/// `<dir>/<scenario>__vrm-author-female.png` for the comparison set.
final class StarterStillTests: XCTestCase {
    private var project: TestProject!
    private var avatar: CompiledAvatar!
    private var attachments: TemplateAttachments!
    private var adapter: VRMAuthorRenderAdapter!
    private var file: URL!
    private var data: Data!

    override func setUpWithError() throws {
        guard let binary = RenderPackTests.rendererBinary else { throw XCTSkip("vrm-author-render is not built next to the test bundle") }
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device is available on this host.") }
        let env = [VRMAuthorRenderLocator.environmentKey: binary.path]
        adapter = VRMAuthorRenderAdapter(executableURL: nil, environment: env)
        project = try TestProject.make(pack: NativeAnimeFixture.pack, registry: TestProject.registry(render: adapter), env: env)
        let recipe = try NativeAnimeStarters.starterRecipe(base: .female, registry: TemplateRegistry.standard())
        (avatar, attachments) = try NativeAnimeFixture.pack.compileWithAttachments(recipe, seed: NativeAnimeStarters.seed)
        data = try GLBWriter.write(avatar).data
        file = URL(fileURLWithPath: project.path("female.vrm"))
        try data.write(to: file)
    }

    override func tearDownWithError() throws { project?.cleanup() }

    private func still(_ id: String) throws -> (width: Int, height: Int, rgba: [UInt8]) {
        let scenario = try XCTUnwrap(QAPins.renderScenarios().first { $0.id == id })
        let out = URL(fileURLWithPath: project.path(id))
        let artifacts = try XCTUnwrap(try adapter.render(scenario: scenario, file: file, data: data, outputDirectory: out, context: project.context))
        let png = try Data(contentsOf: URL(fileURLWithPath: artifacts[0].path))
        if let dir = ProcessInfo.processInfo.environment["VRM_AUTHOR_STILLS_OUT"] {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(id)__vrm-author-female.png"))
        }
        return try RenderPackTests.rgbaPixels(png)
    }

    /// Projects a world point through a locked scenario camera (perspective,
    /// fov 30°, square image) to pixel coordinates.
    private func project(_ p: SIMD3<Float>, scenario id: String, size: Int) throws -> SIMD2<Float> {
        let scenario = try XCTUnwrap(QAPins.renderScenarios().first { $0.id == id })
        let cam = scenario.configuration["camera"]!
        let eye = SIMD3<Float>(cam["position"]!.array!.map { Float($0.number!) })
        let target = SIMD3<Float>(cam["target"]!.array!.map { Float($0.number!) })
        let f = V3.normalize(target - eye)
        let r = V3.normalize(V3.cross(f, SIMD3(0, 1, 0)))
        let u = V3.cross(r, f)
        let d = p - eye
        let x = V3.dot(d, r), y = V3.dot(d, u), z = V3.dot(d, f)
        let scale = 1 / tan(15 * Float.pi / 180)
        let ndcX = x / z * scale, ndcY = y / z * scale
        return SIMD2((ndcX * 0.5 + 0.5) * Float(size), (0.5 - ndcY * 0.5) * Float(size))
    }

    private func luminance(_ img: (width: Int, height: Int, rgba: [UInt8]), _ x: Int, _ y: Int) -> Float {
        let i = (y * img.width + x) * 4
        return (0.2126 * Float(img.rgba[i]) + 0.7152 * Float(img.rgba[i + 1]) + 0.0722 * Float(img.rgba[i + 2])) / 255
    }

    private func hue(_ img: (width: Int, height: Int, rgba: [UInt8]), _ x: Int, _ y: Int) -> (hue: Float, sat: Float, lum: Float) {
        let i = (y * img.width + x) * 4
        let r = Float(img.rgba[i]) / 255, g = Float(img.rgba[i + 1]) / 255, b = Float(img.rgba[i + 2]) / 255
        let hi = max(r, g, b), lo = min(r, g, b), c = hi - lo
        var h: Float = 0
        if c > 1e-4 {
            if hi == r { h = ((g - b) / c).truncatingRemainder(dividingBy: 6) } else if hi == g { h = (b - r) / c + 2 } else { h = (r - g) / c + 4 }
            h *= 60
            if h < 0 { h += 360 }
        }
        return (h, hi > 0 ? c / hi : 0, luminance(img, x, y))
    }

    private func hueOf(_ linear: SIMD3<Float>) -> Float {
        func byte(_ c: Float) -> UInt8 { UInt8(min(max(ColourTransfer.linearToSrgb(Double(c)) * 255, 0), 255).rounded()) }
        let img = (width: 1, height: 1, rgba: [byte(linear.x), byte(linear.y), byte(linear.z), 255])
        return hue(img, 0, 0).hue
    }

    func testFrontCollarShowsNoDarkNecklineBand() throws {
        let img = try still("visual.front")
        let neck = attachments.jointWorldPositions[.neck]!, head = attachments.jointWorldPositions[.head]!
        let top = try project(head, scenario: "visual.front", size: img.width)
        let bottom = try project(neck - SIMD3(0, 0.04, 0), scenario: "visual.front", size: img.width)
        let left = try project(neck - SIMD3(0.04, 0, 0), scenario: "visual.front", size: img.width)
        let right = try project(neck + SIMD3(0.04, 0, 0), scenario: "visual.front", size: img.width)
        var run = 0, worst = 0
        for y in Int(top.y)...Int(bottom.y) {
            var sum: Float = 0
            for x in Int(left.x)...Int(right.x) { sum += luminance(img, x, y) }
            let mean = sum / Float(Int(right.x) - Int(left.x) + 1)
            run = mean < 0.15 ? run + 1 : 0
            worst = max(worst, run)
        }
        XCTAssertLessThan(worst, 8, "a \(worst)-row dark band sits inside the neckline box")
    }

    func testThreeQuarterShowsASkirtHemBand() throws {
        let img = try still("visual.threeQuarter")
        let skirt = try XCTUnwrap(avatar.meshes.first { $0.id.hasPrefix("mesh:garment:") && attachments.garments.contains { g in g.meshId == $0.id && g.preset == "skirt-v1" } }).primitives[0]
        let hemY = skirt.positions.map(\.y).min()!
        let centre = try project(SIMD3(0, hemY, 0), scenario: "visual.threeQuarter", size: img.width)
        let halfWidth = 40
        func rowMean(_ y: Int) -> Float { (Int(centre.x) - halfWidth...Int(centre.x) + halfWidth).reduce(Float(0)) { $0 + luminance(img, $1, y) } / Float(2 * halfWidth + 1) }
        let above = (Int(centre.y) - 30..<Int(centre.y) - 10).map(rowMean).reduce(0, +) / 20
        var run = 0, best = 0
        for y in (Int(centre.y) - 12)...(Int(centre.y) + 12) {
            run = rowMean(y) < above * 0.90 ? run + 1 : 0
            best = max(best, run)
        }
        XCTAssertGreaterThanOrEqual(best, 5, "no ≥5-row band darker than the cloth above the hem (best run \(best))")
    }

    func testCrownShowsNoScalpThroughTheHair() throws {
        let hairHue = hueOf(NativeAnimeTextures.rgb(NativeAnimeFixture.pack.defaults.hair[0].texture.baseColour))
        let skinHue = hueOf(MaterialRoleDefaults.baseColour(for: .faceSkin))
        for id in ["visual.front", "visual.threeQuarter"] {
            let img = try still(id)
            let c = attachments.headCenter, R = attachments.headRadii.y
            let lo = try project(c + SIMD3(-0.8 * R, 0.30 * R, 0), scenario: id, size: img.width)
            let hi = try project(c + SIMD3(0.8 * R, 1.10 * R, 0), scenario: id, size: img.width)
            var hair = 0, skin = 0
            for y in Int(hi.y)...Int(lo.y) {
                for x in Int(min(lo.x, hi.x))...Int(max(lo.x, hi.x)) {
                    let p = hue(img, x, y)
                    guard p.sat > 0.12 else { continue }
                    if abs(p.hue - hairHue) < 14 && p.lum < 0.55 { hair += 1 } else if abs(p.hue - skinHue) < 10 && p.lum > 0.55 { skin += 1 }
                }
            }
            XCTAssertGreaterThan(hair, 500, "\(id): hair silhouette found")
            XCTAssertLessThan(Double(skin) / Double(hair + skin), 0.02, "\(id): \(skin) scalp pixels among \(hair) hair pixels")
        }
    }
}
```

- [ ] **Step 2: Build the renderer and run the still tests**

```bash
swift build --product vrm-author-render
VRM_AUTHOR_STILLS_OUT=/tmp/vrm-author-rate/stills swift test --filter StarterStillTests --disable-sandbox
```
Expected: three PASS on this machine (Metal present). If the collar run check fails, inspect `/tmp/vrm-author-rate/stills/visual.front__vrm-author-female.png` at the neckline: a remaining dark band means the band's `frontness` window (|out.x| < 0.5) is narrower than the visible slit; widen it to 0.6 in Task 5's closure and re-run Task 5's tests first.

- [ ] **Step 3: Refresh the comparison set**

Add a fourth test to `StarterStillTests` that renders every visual and expression scenario only when the output directory is requested:

```swift
    func testWritesEveryStillForTheComparisonSet() throws {
        guard ProcessInfo.processInfo.environment["VRM_AUTHOR_STILLS_OUT"] != nil else { throw XCTSkip("set VRM_AUTHOR_STILLS_OUT to refresh the comparison stills") }
        for scenario in QAPins.renderScenarios() where scenario.kind == "visual" || scenario.kind == "expression" {
            let img = try still(scenario.id)
            XCTAssertEqual(img.width, 1024, scenario.id)
        }
    }
```

Then:

```bash
VRM_AUTHOR_STILLS_OUT=/tmp/vrm-author-rate/stills swift test --filter StarterStillTests --disable-sandbox
ls -la /tmp/vrm-author-rate/stills/*__vrm-author-female.png
```
Expected: the six `<scenario>__vrm-author-female.png` files are rewritten with fresh timestamps; the `AvatarSample_A` halves of each pair are untouched. Open each pair once against its `AvatarSample_A` partner before moving on and record anything that still reads wrong in the commit message body.

- [ ] **Step 4: Point the docs at the spec**

In `docs/superpowers/specs/2026-09-12-mcp-authoring-loop-design.md` §6, add after the table: "Superseded in part by `2026-09-12-starter-craft-design.md`: the hair-coverage acceptance holds with rigid cap clumps (spring count unchanged), the face-raster item is the lip band and blush change, and body basis, proportion fit and skirt clearance are new there." In `docs/proposals/vrm-author-cli/README.md` §6, after the deliverable table, add one paragraph: "Starter craft (2026-09-12): the native-anime template lofts each limb once, fits shoulders, neck, chest and eye spacing to the profile's corpus provenance, and the style linter measures skin-role girth; see `docs/superpowers/specs/2026-09-12-starter-craft-design.md`."

- [ ] **Step 5: Full suite**

Run: `swift build && swift test --parallel --num-workers 14 -j 16 --disable-sandbox`
Expected: PASS. Known flaky under parallel: the arm-swing SpringBone guard; re-run that filter alone if it is the only red.

- [ ] **Step 6: Re-pin the packs and evidence**

`repin_packs.py` refuses a target commit whose `oracleHashes` do not match the files there; it never rewrites those hashes itself. Refresh them first, commit, then move the pins:

```bash
python3 - <<'EOF'
import glob, hashlib, json
for path in sorted(glob.glob("docs/proposals/vrm-author-cli/acceptance/packs/*.json")):
    pack = json.load(open(path))
    oracles = pack["runner"]["environment"]["oracleHashes"]
    changed = False
    for rel in list(oracles):
        digest = hashlib.sha256(open(rel, "rb").read()).hexdigest()
        if oracles[rel] != digest:
            oracles[rel] = digest
            changed = True
    if changed:
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(pack, fh, indent=2, ensure_ascii=False)
            fh.write("\n")
        print("refreshed", path)
EOF
git add docs/proposals/vrm-author-cli/acceptance/packs
git commit -m "acceptance: refresh oracle hashes after the craft pass"
python3 scripts/repin_packs.py --check
python3 scripts/repin_packs.py
python3 scripts/repin_packs.py --check
git add docs/proposals/vrm-author-cli/acceptance docs/superpowers docs/proposals/vrm-author-cli/README.md Tests/VRMAuthorKitTests/Render/StarterStillTests.swift Sources/VRMAuthorKit/Materials
git commit -m "acceptance: still checks for the starters, docs, re-pin after the craft pass"
```
Expected: the refresh script prints every pack whose pinned test files changed (Template, Wearables, Materials, Render and QA packs; the six linter-hash packs were refreshed by hand in Task 3); the first `--check` reports those pins broken, the re-pin moves the whole set onto the refresh commit, and the second `--check` reports every pin holding. Do not push.

---

## Self-review notes

- Spec §2.1 → Tasks 1–2; §2.2 → Tasks 1, 3; §3.1 → Task 4; §3.2–3.3 → Task 5; §4 → Task 6; §5 → Tasks 7–8; §7 pins → Task 3 (linter/profile) and Task 9 (packs); the Metal acceptances of §3.1, §3.3 and §5 → Task 9.
- Names used across tasks: `GarmentInfo.uvIslands` (Task 4) and `collarGapM` (Task 5), `TemplateAttachments.garments` (Task 5, read in Task 9), `HairClumpInfo.isRigid` (Task 7) and `highlightColumn` (Task 8), `NativeAnimeTextures.highlightColumns/highlightHeightFactor/highlightV(column:)` (Task 8), `NativeAnimeLayout.fingerFanDegrees/fingerLengthRatios` (Task 2), `LayoutParams.rigidCap/rigidClumpCount` (Task 7).
- Every task's acceptance runs without Metal except Task 9's still file, which skips.
