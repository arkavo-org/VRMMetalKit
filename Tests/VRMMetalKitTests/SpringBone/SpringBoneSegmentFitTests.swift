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

/// #381: a fraction of bone length is not a size. Where the VRM defines an
/// outside collider, the fraction-derived synthetic uses that radius. Bones
/// the file leaves uncovered keep their fraction capsule.
final class SpringBoneSegmentFitTests: XCTestCase {

    @MainActor
    private func load(_ filename: String) async throws -> VRMModel {
        let path = getTestModelPath(filename)
        try requireFixture(path, hint: filename)
        return try await load(url: URL(fileURLWithPath: path))
    }

    @MainActor
    private func load(url: URL) async throws -> VRMModel {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        return try await VRMModel.load(from: url, device: device,
                                        options: VRMLoadingOptions(augmentSpringBoneColliders: true))
    }

    /// Directory that contains `Package.swift`, walked from this source file.
    /// `getProjectRoot()` is not that directory when `VRM_TEST_MODELS_PATH`
    /// is set: it returns the env path even if the file is not there, so the
    /// copies next to the package never get considered.
    private func sourcePackageRoot(filePath: String = #filePath) -> String? {
        var url = URL(fileURLWithPath: filePath)
        let fm = FileManager.default
        for _ in 0..<10 {
            url.deleteLastPathComponent()
            if fm.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
                return url.path
            }
        }
        return nil
    }

    /// Places a corpus file might live. The source tree comes first so an
    /// env models directory cannot hide the three glbs committed at the repo root.
    private func corpusCandidates(for name: String) -> [String] {
        var paths: [String] = []
        func add(_ directory: String) {
            let path = URL(fileURLWithPath: directory).appendingPathComponent(name).standardizedFileURL.path
            if !paths.contains(path) {
                paths.append(path)
            }
        }
        if let root = sourcePackageRoot() {
            add(root)
        }
        let env = ProcessInfo.processInfo.environment
        for key in ["CI_PRIMARY_REPOSITORY_PATH", "PROJECT_ROOT", "SRCROOT",
                    "VRM_TEST_MODELS_PATH", "VRM_MODELS_PATH", "MUSE_RESOURCES_PATH"] {
            if let value = env[key], !value.isEmpty {
                add(value)
            }
        }
        var cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for _ in 0..<4 {
            add(cwd.path)
            let parent = cwd.deletingLastPathComponent()
            if parent.path == cwd.path { break }
            cwd = parent
        }
        return paths
    }

    /// Xcode Cloud's test host does not see the checkout (cwd is `/private/tmp`
    /// and the CI variables are not in the test process). This corpus stays
    /// on machines that have the avatar files.
    private static var runningInCI: Bool {
        let env = ProcessInfo.processInfo.environment
        for key in ["CI", "CI_XCODE_CLOUD", "CI_PRIMARY_REPOSITORY_PATH", "GITHUB_ACTIONS", "TF_BUILD"] {
            let value = env[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !value.isEmpty, value != "0", value.lowercased() != "false" {
                return true
            }
        }
        return false
    }

    private func resolveCorpusFile(_ name: String) -> URL? {
        for path in corpusCandidates(for: name) where FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    /// Avatars that are not the VRoid sample template. Resolved from
    /// `MUSE_RESOURCES_PATH` or a sibling `Muse` checkout. Missing files are
    /// skipped so CI without that checkout still runs the shipped set.
    private func extraCorpusURLs() -> [URL] {
        var dirs: [String] = []
        if let muse = ProcessInfo.processInfo.environment["MUSE_RESOURCES_PATH"], !muse.isEmpty {
            dirs.append(muse)
        }
        let roots = [sourcePackageRoot(), getProjectRoot()].compactMap { $0 }
        for root in roots {
            let project = URL(fileURLWithPath: root)
            dirs.append(project.path)
            dirs.append(project.appendingPathComponent("../Muse/Resources/VRM").standardized.path)
            dirs.append(project.appendingPathComponent("../Muse").standardized.path)
        }
        let names = [
            "AliciaSolid.vrm",
            "AvatarSample_C.vrm.glb",
            "AvatarSample_A.vrm.glb",
        ]
        var urls: [URL] = []
        var seen = Set<String>()
        for dir in dirs {
            for name in names {
                let path = "\(dir)/\(name)"
                guard FileManager.default.fileExists(atPath: path), seen.insert(name).inserted else { continue }
                urls.append(URL(fileURLWithPath: path))
            }
        }
        return urls
    }

    private func radius(_ collider: VRMCollider) -> Float {
        switch collider.shape {
        case .sphere(_, let radius), .capsule(_, let radius, _),
             .insideSphere(_, let radius), .insideCapsule(_, let radius, _):
            return radius
        case .plane:
            return -1
        }
    }

    private func capsules(_ colliders: [VRMCollider]) -> [VRMCollider] {
        colliders.filter { if case .capsule = $0.shape { return true } else { return false } }
    }

    private func isSphere(_ collider: VRMCollider) -> Bool {
        if case .sphere = collider.shape { return true }
        return false
    }

    /// Fraction-derived synthetics stay within the authored radius, and every
    /// `knownOversized` pin is still actually oversized (a stale pin fails).
    private func assertAudit(_ model: VRMModel, _ label: String) {
        XCTAssertEqual(ColliderDimensionAudit.ceiling, 1, accuracy: 1e-6,
                       "the authored radius is the size; a slack factor is another guess")
        let found = ColliderDimensionAudit.offenders(model: model)
        let names = Set(found.map(\.nodeName))
        for pin in ColliderDimensionAudit.knownOversized {
            XCTAssertTrue(names.contains(pin),
                "\(label): stale knownOversized pin '\(pin)' is within the authored ceiling")
        }
        let unexpected = found.filter { !ColliderDimensionAudit.knownOversized.contains($0.nodeName) }
        let detail = unexpected.map {
            "\($0.nodeName) synthetic \($0.syntheticRadius) / authored \($0.authoredRadius)"
        }.joined(separator: "; ")
        XCTAssertTrue(unexpected.isEmpty,
            "\(label): synthetic colliders over \(ColliderDimensionAudit.ceiling)× authored: \(detail)")
        XCTAssertTrue(ColliderDimensionAudit.knownOversized.isEmpty,
            "\(label): knownOversized must be empty once every same-bone synthetic is within the ceiling")
    }

    @MainActor func testAudit_A_and_U_haveNoOversizedSynthetics() async throws {
        let a = try await load(testVRM10Filename)
        let u = try await load("AvatarSample_U_1.0.vrm.glb")
        assertAudit(a, "AvatarSample_A")
        assertAudit(u, "AvatarSample_U")
    }

    /// Capsule slots 0–9 stay in synthesize() order. Thighs, shins, and the brow
    /// keep their radii. Arm capsules, the torso capsule, and the palm sphere
    /// take the authored size. No chest sphere is invented.
    @MainActor func testA_refitsVariedLimbsWithoutMovingCapsuleSlots() async throws {
        let model = try await load(testVRM10Filename)
        let humanoid = try XCTUnwrap(model.humanoid)
        let synthetic = try XCTUnwrap(model.springBone).syntheticColliders
        let pure = SpringBoneColliderAugmentor.synthesize(model: model)
        let loadedCapsules = capsules(synthetic)
        let pureCapsules = capsules(pure)
        XCTAssertGreaterThanOrEqual(loadedCapsules.count, 10)
        XCTAssertEqual(loadedCapsules.prefix(10).map(\.node), pureCapsules.prefix(10).map(\.node),
                       "capsule slots 0–9 must stay in synthesize() order")

        // Slots: 0 L thigh, 1 L shin, 2 R thigh, 3 R shin, 4 head, 5 L forearm,
        // 6 R forearm, 7 torso, 8 L upper arm, 9 R upper arm.
        // Thighs and shins have no authored collider. The brow capsule is already
        // half the authored head sphere, so the clamp does not touch it.
        for index in [0, 1, 2, 3, 4] {
            XCTAssertEqual(radius(loadedCapsules[index]), radius(pureCapsules[index]), accuracy: 1e-5,
                           "slot \(index) radius is not replaced by an authored radius")
        }
        if let spine = humanoid.getBoneNode(.spine),
           let authoredSpine = ColliderDimensionAudit.maxAuthoredOutsideRadius(node: spine, model: model) {
            XCTAssertEqual(radius(loadedCapsules[7]), authoredSpine, accuracy: 1e-4,
                           "torso capsule must use the spine radius the VRM defines, not 0.5× the bone length")
            XCTAssertLessThanOrEqual(radius(loadedCapsules[7]), radius(pureCapsules[7]) + 1e-5)
        }
        for bone in [VRMHumanoidBone.leftUpperArm, .rightUpperArm, .leftLowerArm, .rightLowerArm] {
            let node = try XCTUnwrap(humanoid.getBoneNode(bone))
            let authored = try XCTUnwrap(
                ColliderDimensionAudit.maxAuthoredOutsideRadius(node: node, model: model))
            let capsule = try XCTUnwrap(loadedCapsules.first { $0.node == node })
            XCTAssertEqual(radius(capsule), authored, accuracy: 1e-4,
                           "\(bone) capsule must use the radius the VRM defines (\(authored))")
        }

        for hand in [VRMHumanoidBone.leftHand, .rightHand] {
            let node = try XCTUnwrap(humanoid.getBoneNode(hand))
            let authored = try XCTUnwrap(ColliderDimensionAudit.authoredSphere(node: node, model: model))
            let palm = try XCTUnwrap(synthetic.first { $0.node == node && isSphere($0) })
            guard case .sphere(let offset, let palmRadius) = palm.shape else {
                return XCTFail("palm collider must be a sphere")
            }
            print("[#381 \(hand)] authored r=\(authored.radius) offset=\(authored.offset) palm r=\(palmRadius) offset=\(offset)")
            XCTAssertEqual(palmRadius, authored.radius, accuracy: 1e-4)
            XCTAssertLessThan(simd_length(offset - authored.offset), 1e-4,
                              "palm sphere must sit on the authored sphere, not a fraction of forearm length")
        }

        if let neck = humanoid.getBoneNode(.neck) {
            let pureNeck = pure.filter { $0.node == neck }.count
            let loadedNeck = synthetic.filter { $0.node == neck }.count
            XCTAssertEqual(loadedNeck, pureNeck, "the neck must not gain a synthetic collider")
        }

        if let chest = humanoid.getBoneNode(.chest) {
            XCTAssertFalse(synthetic.contains { $0.node == chest && isSphere($0) },
                           "the VRM does not define a chest collider; a fitted sternum sphere is a guess")
        }
        let thighNodes = Set([VRMHumanoidBone.leftUpperLeg, .rightUpperLeg].compactMap { humanoid.getBoneNode($0) })
        XCTAssertFalse(synthetic.contains { thighNodes.contains($0.node) && isSphere($0) },
                       "no thigh sphere chain; the fraction capsule stays")

        let head = try XCTUnwrap(humanoid.getBoneNode(.head))
        let pureSkull = pure.first { $0.node == head && isSphere($0) }
        let loadedSkull = synthetic.first { $0.node == head && isSphere($0) }
        XCTAssertEqual(radius(try XCTUnwrap(loadedSkull)), radius(try XCTUnwrap(pureSkull)), accuracy: 1e-5,
                       "the head skull sphere is already 1× the authored radius")
    }

    /// AvatarSample_U authors 78 mm thigh spheres. The fraction capsule is
    /// larger, and the fast-march skirt gate is calibrated to it (1/180).
    /// Clamping the capsule down to the authored radius holds the skirt in
    /// the leg for 6/180 frames.
    @MainActor func testU_thighCapsuleKeepsTheFractionRadius() async throws {
        let model = try await load("AvatarSample_U_1.0.vrm.glb")
        let humanoid = try XCTUnwrap(model.humanoid)
        let loaded = try XCTUnwrap(model.springBone).syntheticColliders
        let pure = SpringBoneColliderAugmentor.synthesize(model: model)
        for bone in [VRMHumanoidBone.leftUpperLeg, .rightUpperLeg] {
            let node = try XCTUnwrap(humanoid.getBoneNode(bone))
            let authored = try XCTUnwrap(
                ColliderDimensionAudit.maxAuthoredOutsideRadius(node: node, model: model))
            let pureCapsule = try XCTUnwrap(pure.first { $0.node == node })
            let loadedCapsule = try XCTUnwrap(loaded.first { $0.node == node })
            XCTAssertGreaterThan(radius(pureCapsule), authored,
                                 "\(bone) fraction capsule should exceed the authored sphere, or this exemption is stale")
            XCTAssertEqual(radius(loadedCapsule), radius(pureCapsule), accuracy: 1e-5,
                           "\(bone) capsule keeps the fraction radius so the skirt march gate holds")
        }
    }

    /// `synthesize()` stays oracle-blind. The load path clamps same-bone radii
    /// and does not shrink a thigh.
    @MainActor func testSynthesizeDoesNotApplyTheMeshRefit() async throws {
        let model = try await load(testVRM10Filename)
        let humanoid = try XCTUnwrap(model.humanoid)
        let pure = SpringBoneColliderAugmentor.synthesize(model: model)
        let loaded = try XCTUnwrap(model.springBone).syntheticColliders
        guard let thigh = humanoid.getBoneNode(.leftUpperLeg) else {
            return XCTFail("A must rig a left thigh")
        }
        let pureThigh = try XCTUnwrap(pure.first { $0.node == thigh })
        let loadedThigh = try XCTUnwrap(loaded.first { $0.node == thigh })
        XCTAssertGreaterThanOrEqual(radius(pureThigh), radius(loadedThigh) - 1e-5)
    }

    /// The authored-radius clamp is a property of the file, not of AvatarSample_A.
    /// Runs locally, where the avatar files are on disk. Xcode Cloud cannot
    /// see that checkout, so the test skips there instead of failing the job.
    /// U stays required on a machine that has it: that thigh must keep the
    /// fraction radius.
    @MainActor func testCorpus_authoredRadiusWinsOnEveryAvatar() async throws {
        if Self.runningInCI {
            throw XCTSkip("corpus runs locally, where the avatar fixtures are on disk")
        }
        let required = [
            "AvatarSample_A_1.0.vrm.glb",
            "AvatarSample_A_0.0.vrm.glb",
            "AvatarSample_U_1.0.vrm.glb",
        ]
        let optional = [
            "AvatarSample_H_1.0.vrm",
            "AvatarSample_K_1.0.vrm",
            "AvatarSample_K_0.0.vrm",
            "AvatarSample_O_1.0.vrm",
            "vroid_default_F_1_0.vrm",
        ]
        var missing: [String] = []
        for file in required {
            guard let url = resolveCorpusFile(file) else {
                missing.append(file)
                continue
            }
            let model = try await load(url: url)
            assertCorpusModel(model, file)
        }
        if !missing.isEmpty {
            let looked = corpusCandidates(for: required[0]).joined(separator: ", ")
            throw XCTSkip("committed fixtures are not on this machine (\(missing.joined(separator: ", "))). looked in \(looked)")
        }

        for file in optional {
            guard let url = resolveCorpusFile(file) else {
                print("[corpus] missing \(file)")
                continue
            }
            let model = try await load(url: url)
            assertCorpusModel(model, file)
        }

        let extras = extraCorpusURLs()
        var extraChecked = 0
        for url in extras {
            let model = try await load(url: url)
            extraChecked += 1
            assertCorpusModel(model, url.lastPathComponent)
        }
        let root = sourcePackageRoot() ?? getProjectRoot()
        let muse = URL(fileURLWithPath: root)
            .appendingPathComponent("../Muse/Resources/VRM/AliciaSolid.vrm").standardized.path
        if FileManager.default.fileExists(atPath: muse) {
            XCTAssertGreaterThanOrEqual(extraChecked, 2,
                "AliciaSolid and AvatarSample_C are on disk; the corpus must load them, not only the VRoid template")
        }
    }

    private func assertCorpusModel(_ model: VRMModel, _ file: String) {
        let humanoid = model.humanoid
        let loaded = model.springBone?.syntheticColliders ?? []
        let pure = SpringBoneColliderAugmentor.synthesize(model: model)
        print("[corpus \(file)] authored=\(model.springBone?.colliders.count ?? 0) pure=\(pure.count) loaded=\(loaded.count)")

        let found = ColliderDimensionAudit.offenders(model: model)
        let detail = found.map {
            "\($0.nodeName) synthetic \($0.syntheticRadius) / authored \($0.authoredRadius)"
        }.joined(separator: "; ")
        XCTAssertTrue(found.isEmpty, "\(file): fraction collider over the authored radius: \(detail)")
        for pin in ColliderDimensionAudit.knownOversized {
            XCTAssertTrue(found.contains { $0.nodeName == pin },
                          "\(file): stale knownOversized pin '\(pin)'")
        }

        let pureCapsules = capsules(pure)
        let loadedCapsules = capsules(loaded)
        XCTAssertEqual(loadedCapsules.prefix(pureCapsules.count).map(\.node), pureCapsules.map(\.node),
                       "\(file): capsule order must match synthesize()")
        if !pureCapsules.isEmpty {
            XCTAssertFalse(loadedCapsules.isEmpty,
                           "\(file): augmentation produced no capsules, so the radius clamp was never applied")
        }

        var boneOfNode: [Int: String] = [:]
        if let humanoid {
            for bone in VRMHumanoidBone.allCases {
                if let node = humanoid.getBoneNode(bone) {
                    boneOfNode[node] = bone.rawValue
                    let inventory = authoredInventory(node, model)
                    if inventory != "-" {
                        print("  authored \(bone.rawValue): \(inventory)")
                    }
                }
            }
        }

        for collider in loaded {
            let r = radius(collider)
            XCTAssertTrue(r.isFinite && r > 0, "\(file): synthetic radius must be finite and positive")
        }

        let prefixCount = min(pure.count, loaded.count)
        for index in 0..<prefixCount {
            let before = pure[index]
            let after = loaded[index]
            XCTAssertEqual(after.node, before.node, "\(file): prefix node \(index) changed")
            let bone = boneOfNode[after.node] ?? (model.nodes.indices.contains(after.node)
                ? (model.nodes[after.node].name ?? "#\(after.node)") : "#\(after.node)")
            let authored = ColliderDimensionAudit.maxAuthoredOutsideRadius(node: after.node, model: model)
            let kept = SpringBoneSegmentFit.keepsFractionRadius(node: after.node, model: model)
            if kept {
                XCTAssertEqual(radius(after), radius(before), accuracy: 1e-5,
                               "\(file): \(bone) keeps the fraction radius")
            } else if let authored {
                XCTAssertLessThanOrEqual(radius(after), authored + 1e-4,
                                         "\(file): \(bone) loaded \(radius(after)) exceeds authored \(authored)")
            }
            let action: String
            if kept {
                action = "fraction"
            } else if abs(radius(after) - radius(before)) > 1e-4 {
                action = "clamped"
            } else {
                action = "kept"
            }
            let authoredText = authored.map { String(format: "%.4f", $0) } ?? "-"
            print(String(format: "  %-22@ %@ pure=%.4f loaded=%.4f authored=%@ %@",
                         bone as NSString, shapeLabel(after), radius(before), radius(after),
                         authoredText as NSString, action as NSString))
        }

        if let humanoid {
            for bone in [VRMHumanoidBone.leftHand, .rightHand] {
                guard let node = humanoid.getBoneNode(bone),
                      let authored = ColliderDimensionAudit.authoredSphere(node: node, model: model),
                      let palm = loaded.first(where: { $0.node == node && isSphere($0) }),
                      case .sphere(let offset, let palmRadius) = palm.shape else { continue }
                XCTAssertEqual(palmRadius, authored.radius, accuracy: 1e-4,
                               "\(file): \(bone) palm must copy the authored radius")
                XCTAssertLessThan(simd_length(offset - authored.offset), 1e-4,
                                  "\(file): \(bone) palm must sit on the authored sphere")
                if let maxRadius = ColliderDimensionAudit.maxAuthoredOutsideRadius(node: node, model: model) {
                    XCTAssertGreaterThanOrEqual(palmRadius + 1e-4, maxRadius,
                        "\(file): \(bone) palm copied a sphere smaller than another outside collider on that node")
                }
            }
            let mirror: [(VRMHumanoidBone, VRMHumanoidBone)] = [
                (.leftUpperArm, .rightUpperArm),
                (.leftLowerArm, .rightLowerArm),
                (.leftHand, .rightHand),
                (.leftUpperLeg, .rightUpperLeg),
                (.leftLowerLeg, .rightLowerLeg),
            ]
            for (left, right) in mirror {
                guard let ln = humanoid.getBoneNode(left), let rn = humanoid.getBoneNode(right),
                      let lc = loaded.first(where: { $0.node == ln }),
                      let rc = loaded.first(where: { $0.node == rn }) else { continue }
                let lr = radius(lc)
                let rr = radius(rc)
                let gap = abs(lr - rr)
                let authoredL = ColliderDimensionAudit.maxAuthoredOutsideRadius(node: ln, model: model)
                let authoredR = ColliderDimensionAudit.maxAuthoredOutsideRadius(node: rn, model: model)
                if let al = authoredL, let ar = authoredR {
                    let allowance = abs(al - ar) + max(0.005, 0.1 * max(al, ar))
                    XCTAssertLessThanOrEqual(gap, allowance,
                        "\(file): \(left)/\(right) diverged past the file (\(lr) vs \(rr), authored \(al) vs \(ar))")
                } else if authoredL == nil, authoredR == nil {
                    XCTAssertLessThanOrEqual(gap, max(0.005, 0.1 * max(lr, rr)),
                        "\(file): \(left)/\(right) fraction radii diverged (\(lr) vs \(rr))")
                }
            }
        }

        if let neck = humanoid?.getBoneNode(.neck) {
            XCTAssertEqual(loaded.filter { $0.node == neck }.count, pure.filter { $0.node == neck }.count,
                           "\(file): the neck must not gain a synthetic collider")
        }
    }

    private func authoredInventory(_ node: Int, _ model: VRMModel) -> String {
        guard let colliders = model.springBone?.colliders else { return "-" }
        let mine = colliders.filter { $0.node == node }
        if mine.isEmpty { return "-" }
        return mine.map { collider -> String in
            switch collider.shape {
            case .sphere(let offset, let radius):
                return String(format: "sphere r=%.4f off=(%.3f,%.3f,%.3f)", radius, offset.x, offset.y, offset.z)
            case .capsule(let offset, let radius, let tail):
                return String(format: "capsule r=%.4f off=(%.3f,%.3f,%.3f) tail=(%.3f,%.3f,%.3f)",
                              radius, offset.x, offset.y, offset.z, tail.x, tail.y, tail.z)
            case .insideSphere(_, let radius):
                return String(format: "insideSphere r=%.4f", radius)
            case .insideCapsule(_, let radius, _):
                return String(format: "insideCapsule r=%.4f", radius)
            case .plane:
                return "plane"
            }
        }.joined(separator: " | ")
    }

    private func shapeLabel(_ collider: VRMCollider) -> String {
        switch collider.shape {
        case .sphere: return "sphere "
        case .capsule: return "capsule"
        case .plane: return "plane  "
        case .insideSphere: return "isphere"
        case .insideCapsule: return "icaps  "
        }
    }
}
