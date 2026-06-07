// Copyright 2025 Arkavo Inc. and contributors
// Licensed under the Apache License, Version 2.0

import XCTest
import Metal
import simd
@testable import VRMMetalKit

/// Tests for VRMC_springBone-1.0 spec compliance fixes.
///
/// Coverage:
///   C4 - gravityPower spec default (VRM 1.0 honours 0.0; VRM 0.0 applies quirk fix)
///   C2 - Duplicate joint node validation (within-spring and cross-spring)
///   C1 - center node index is tracked per-spring in SpringBoneComputeSystem
///   C3 - plane collider is marked non-spec; warning path exists in parser
final class SpringBoneSpecComplianceTests: XCTestCase {

    var parser: VRMExtensionParser!

    override func setUp() {
        super.setUp()
        parser = VRMExtensionParser()
    }

    override func tearDown() {
        parser = nil
        super.tearDown()
    }

    // MARK: - Shared helpers

    private func makeMinimalVRM1Dict(springBoneExt: [String: Any]) -> ([String: Any], GLTFDocument) {
        let vrmDict: [String: Any] = [
            "specVersion": "1.0",
            "meta": ["name": "Test", "licenseUrl": "https://example.com"],
            "humanoid": ["humanBones": [
                "hips": ["node": 0],
                "leftUpperLeg": ["node": 1],
                "rightUpperLeg": ["node": 2],
                "leftLowerLeg": ["node": 3],
                "rightLowerLeg": ["node": 4],
                "leftFoot": ["node": 5],
                "rightFoot": ["node": 6],
                "spine": ["node": 7],
                "chest": ["node": 8],
                "neck": ["node": 9],
                "head": ["node": 10],
                "leftShoulder": ["node": 11],
                "rightShoulder": ["node": 12],
                "leftUpperArm": ["node": 13],
                "rightUpperArm": ["node": 14],
                "leftLowerArm": ["node": 15],
                "rightLowerArm": ["node": 16],
                "leftHand": ["node": 17],
                "rightHand": ["node": 18]
            ]]
        ]
        let document = makeGLTFDocument(extensions: ["VRMC_springBone": springBoneExt])
        return (vrmDict, document)
    }

    private func makeMinimalVRM0Dict(secondaryAnimation: [String: Any]) -> ([String: Any], GLTFDocument) {
        let vrmDict: [String: Any] = [
            "version": "0.0",
            "meta": ["title": "Test", "author": "Test"],
            "humanoid": ["humanBones": [
                ["bone": "hips", "node": 0],
                ["bone": "leftUpperLeg", "node": 1],
                ["bone": "rightUpperLeg", "node": 2],
                ["bone": "leftLowerLeg", "node": 3],
                ["bone": "rightLowerLeg", "node": 4],
                ["bone": "leftFoot", "node": 5],
                ["bone": "rightFoot", "node": 6],
                ["bone": "spine", "node": 7],
                ["bone": "chest", "node": 8],
                ["bone": "neck", "node": 9],
                ["bone": "head", "node": 10],
                ["bone": "leftShoulder", "node": 11],
                ["bone": "rightShoulder", "node": 12],
                ["bone": "leftUpperArm", "node": 13],
                ["bone": "rightUpperArm", "node": 14],
                ["bone": "leftLowerArm", "node": 15],
                ["bone": "rightLowerArm", "node": 16],
                ["bone": "leftHand", "node": 17],
                ["bone": "rightHand", "node": 18]
            ]],
            "secondaryAnimation": secondaryAnimation
        ]
        let document = makeGLTFDocument()
        return (vrmDict, document)
    }

    private func makeGLTFDocument(nodes: Int = 25, extensions: [String: Any]? = nil) -> GLTFDocument {
        var json: [String: Any] = [
            "asset": ["version": "2.0", "generator": "Test"],
            "scene": 0,
            "scenes": [["nodes": Array(0..<nodes)]],
            "nodes": (0..<nodes).map { i in ["name": "node_\(i)"] }
        ]
        if let ext = extensions {
            json["extensions"] = ext
        }
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(GLTFDocument.self, from: data)
    }

    // MARK: - C4: gravityPower spec compliance

    /// VRM 1.0: explicit gravityPower=0.0 must be preserved as 0.0 (spec default is 0.0).
    func testVRM1ExplicitGravityPowerZeroIsRespected() throws {
        let springBoneExt: [String: Any] = [
            "specVersion": "1.0",
            "springs": [[
                "name": "Hair",
                "joints": [
                    ["node": 20, "gravityPower": Float(0.0), "stiffness": Float(1.0)],
                    ["node": 21, "gravityPower": Float(0.0), "stiffness": Float(1.0)]
                ]
            ]]
        ]
        let (vrmDict, document) = makeMinimalVRM1Dict(springBoneExt: springBoneExt)
        let model = try parser.parseVRMExtension(vrmDict, document: document)

        guard let spring = model.springBone?.springs.first else {
            XCTFail("No spring parsed")
            return
        }
        XCTAssertFalse(spring.joints.isEmpty, "Spring should have joints")
        for joint in spring.joints {
            XCTAssertEqual(joint.gravityPower, 0.0, accuracy: 0.0001,
                "VRM 1.0 explicit gravityPower=0.0 must not be overridden to 1.0. " +
                "VRMC_springBone-1.0 spec default is 0.0 and explicit zero must be respected.")
        }
    }

    /// VRM 1.0: omitted gravityPower must default to 0.0 (spec default).
    func testVRM1OmittedGravityPowerDefaultsToZero() throws {
        let springBoneExt: [String: Any] = [
            "specVersion": "1.0",
            "springs": [[
                "name": "Hair",
                "joints": [
                    ["node": 20, "stiffness": Float(1.0)],
                    ["node": 21, "stiffness": Float(1.0)]
                ]
            ]]
        ]
        let (vrmDict, document) = makeMinimalVRM1Dict(springBoneExt: springBoneExt)
        let model = try parser.parseVRMExtension(vrmDict, document: document)

        guard let spring = model.springBone?.springs.first else {
            XCTFail("No spring parsed")
            return
        }
        for joint in spring.joints {
            XCTAssertEqual(joint.gravityPower, 0.0, accuracy: 0.0001,
                "VRM 1.0 omitted gravityPower must default to 0.0 per spec.")
        }
    }

    /// VRM 1.0: explicit non-zero gravityPower is preserved.
    func testVRM1NonZeroGravityPowerIsPreserved() throws {
        let springBoneExt: [String: Any] = [
            "specVersion": "1.0",
            "springs": [[
                "name": "Hair",
                "joints": [
                    ["node": 20, "gravityPower": Float(0.5), "stiffness": Float(1.0)],
                    ["node": 21, "gravityPower": Float(0.5), "stiffness": Float(1.0)]
                ]
            ]]
        ]
        let (vrmDict, document) = makeMinimalVRM1Dict(springBoneExt: springBoneExt)
        let model = try parser.parseVRMExtension(vrmDict, document: document)

        guard let spring = model.springBone?.springs.first else {
            XCTFail("No spring parsed")
            return
        }
        for joint in spring.joints {
            XCTAssertEqual(joint.gravityPower, 0.5, accuracy: 0.0001,
                "VRM 1.0 non-zero gravityPower must be preserved.")
        }
    }

    /// VRM 0.x: explicit gravityPower=0.0 must be respected as inert (#326),
    /// matching UniVRM (the 0.x reference) and three-vrm. The old VMK quirk
    /// forced 0→1.0, which over-applied gravity to chains the artist authored
    /// inert (e.g. bangs meant to lie flat), parting them — a visible divergence
    /// from every other VRM renderer.
    func testVRM0ExplicitGravityPowerZeroIsRespected() throws {
        let (vrmDict, document) = makeMinimalVRM0Dict(secondaryAnimation: [
            "boneGroups": [[
                "comment": "Hair",
                "bones": [20, 21],
                "gravityPower": Double(0.0),
                "stiffness": Double(1.0),
                "dragForce": Double(0.4)
            ]]
        ])
        let model = try parser.parseVRMExtension(vrmDict, document: document)

        guard let spring = model.springBone?.springs.first else {
            XCTFail("No spring parsed")
            return
        }
        for joint in spring.joints {
            XCTAssertEqual(joint.gravityPower, 0.0, accuracy: 0.0001,
                "VRM 0.x gravityPower=0 must stay inert (no 0→1.0 substitution, #326) — " +
                "matches UniVRM/three-vrm.")
        }
    }

    /// VRM 0.x: non-zero gravityPower is preserved.
    func testVRM0NonZeroGravityPowerIsPreserved() throws {
        let (vrmDict, document) = makeMinimalVRM0Dict(secondaryAnimation: [
            "boneGroups": [[
                "comment": "Hair",
                "bones": [20, 21],
                "gravityPower": Double(0.7),
                "stiffness": Double(1.0),
                "dragForce": Double(0.4)
            ]]
        ])
        let model = try parser.parseVRMExtension(vrmDict, document: document)

        guard let spring = model.springBone?.springs.first else {
            XCTFail("No spring parsed")
            return
        }
        for joint in spring.joints {
            XCTAssertEqual(joint.gravityPower, 0.7, accuracy: 0.0001,
                "VRM 0.x non-zero gravityPower must be preserved.")
        }
    }

    // MARK: - C2: Duplicate joint validation

    /// A spring whose joints array contains the same node twice must have that
    /// duplicate removed, leaving only one entry for that node.
    func testWithinSpringDuplicateJointIsRemoved() throws {
        let springBoneExt: [String: Any] = [
            "specVersion": "1.0",
            "springs": [[
                "name": "Hair",
                "joints": [
                    ["node": 20, "stiffness": Float(1.0)],
                    ["node": 21, "stiffness": Float(1.0)],
                    ["node": 21, "stiffness": Float(1.0)]  // duplicate
                ]
            ]]
        ]
        let (vrmDict, document) = makeMinimalVRM1Dict(springBoneExt: springBoneExt)
        let model = try parser.parseVRMExtension(vrmDict, document: document)

        guard let spring = model.springBone?.springs.first else {
            XCTFail("No spring parsed")
            return
        }
        let nodeIndices = spring.joints.map { $0.node }
        XCTAssertEqual(Set(nodeIndices).count, nodeIndices.count,
            "Within-spring duplicate joints must be removed. Joints: \(nodeIndices)")
        XCTAssertFalse(nodeIndices.contains(where: { n in nodeIndices.filter { $0 == n }.count > 1 }),
            "Each node must appear at most once in a spring's joints array.")
    }

    /// A spring that ends up with fewer than 2 unique joints after deduplication is dropped.
    func testSpringWithFewerThanTwoUniqueJointsIsDropped() throws {
        let springBoneExt: [String: Any] = [
            "specVersion": "1.0",
            "springs": [
                [
                    "name": "Good",
                    "joints": [
                        ["node": 20, "stiffness": Float(1.0)],
                        ["node": 21, "stiffness": Float(1.0)]
                    ]
                ],
                [
                    "name": "Degenerate",
                    "joints": [
                        ["node": 22, "stiffness": Float(1.0)],
                        ["node": 22, "stiffness": Float(1.0)]  // both same node
                    ]
                ]
            ]
        ]
        let (vrmDict, document) = makeMinimalVRM1Dict(springBoneExt: springBoneExt)
        let model = try parser.parseVRMExtension(vrmDict, document: document)

        XCTAssertEqual(model.springBone?.springs.count, 1,
            "Spring 'Degenerate' has only one unique node after deduplication and must be dropped.")
        XCTAssertEqual(model.springBone?.springs.first?.name, "Good")
    }

    /// The same node appearing in two different springs must be retained only in the first spring.
    func testCrossSpringDuplicateNodeIsDroppedFromSecondSpring() throws {
        let springBoneExt: [String: Any] = [
            "specVersion": "1.0",
            "springs": [
                [
                    "name": "First",
                    "joints": [
                        ["node": 20, "stiffness": Float(1.0)],
                        ["node": 21, "stiffness": Float(1.0)]
                    ]
                ],
                [
                    "name": "Second",
                    "joints": [
                        ["node": 21, "stiffness": Float(1.0)],  // shared with First
                        ["node": 22, "stiffness": Float(1.0)]
                    ]
                ]
            ]
        ]
        let (vrmDict, document) = makeMinimalVRM1Dict(springBoneExt: springBoneExt)
        let model = try parser.parseVRMExtension(vrmDict, document: document)

        guard let springs = model.springBone?.springs else {
            XCTFail("No springs parsed")
            return
        }

        let firstNodes = springs.first(where: { $0.name == "First" })?.joints.map { $0.node } ?? []
        let secondNodes = springs.first(where: { $0.name == "Second" })?.joints.map { $0.node } ?? []

        XCTAssertTrue(firstNodes.contains(21),
            "Node 21 must remain in the first spring.")
        XCTAssertFalse(secondNodes.contains(21),
            "Node 21 must be dropped from the second spring (cross-spring duplicate). " +
            "Second spring nodes: \(secondNodes)")
    }

    // MARK: - C1: center node metadata in SpringBoneComputeSystem

    /// Parsing a VRM 1.0 spring with center=5 must result in the parsed VRMSpring
    /// carrying center==5, and SpringBoneComputeSystem must record a center record
    /// for that spring.
    func testVRM1SpringWithCenterIsStoredInParsedModel() throws {
        let springBoneExt: [String: Any] = [
            "specVersion": "1.0",
            "springs": [[
                "name": "Hair",
                "center": 5,
                "joints": [
                    ["node": 20, "stiffness": Float(1.0)],
                    ["node": 21, "stiffness": Float(1.0)]
                ]
            ]]
        ]
        let (vrmDict, document) = makeMinimalVRM1Dict(springBoneExt: springBoneExt)
        let model = try parser.parseVRMExtension(vrmDict, document: document)

        guard let spring = model.springBone?.springs.first else {
            XCTFail("No spring parsed")
            return
        }
        XCTAssertEqual(spring.center, 5,
            "Parsed VRMSpring must carry center node index 5 from the JSON.")
    }

    /// SpringBoneComputeSystem must populate its per-spring center metadata when a
    /// spring has a center node set. This is a CPU-side invariant that does not
    /// require GPU execution.
    func testSpringBoneComputeSystemRecordsCenterNodeIndex() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }

        let model = try VRMBuilder().setSkeleton(.defaultHumanoid).build()
        model.nodes.removeAll()

        let gltfJSON = """
        {"name":"n","translation":[0,0,0],"rotation":[0,0,0,1],"scale":[1,1,1]}
        """
        func makeNode(_ index: Int, _ t: SIMD3<Float>) -> VRMNode {
            let data = gltfJSON.replacingOccurrences(of: "[0,0,0]",
                with: "[\(t.x),\(t.y),\(t.z)]").data(using: .utf8)!
            let gltf = try! JSONDecoder().decode(GLTFNode.self, from: data)
            return VRMNode(index: index, gltfNode: gltf)
        }

        let centerNode = makeNode(5, SIMD3<Float>(0, 0, 0))
        let boneA = makeNode(20, SIMD3<Float>(0, 1, 0))
        let boneB = makeNode(21, SIMD3<Float>(0, 0.1, 0))
        boneB.parent = boneA
        boneA.children.append(boneB)

        model.nodes = Array(repeating: centerNode, count: 6)
        model.nodes[5] = centerNode
        for i in 0..<5 { model.nodes[i] = makeNode(i, .zero) }
        model.nodes.append(contentsOf: [boneA, boneB])
        for n in model.nodes { n.updateWorldTransform() }

        var springBone = VRMSpringBone()
        var spring = VRMSpring(name: "Hair")
        spring.center = 5
        var j1 = VRMSpringJoint(node: 20); j1.stiffness = 1.0
        var j2 = VRMSpringJoint(node: 21); j2.stiffness = 1.0
        spring.joints = [j1, j2]
        springBone.springs = [spring]
        model.springBone = springBone
        model.device = device

        let buffers = SpringBoneBuffers(device: device)
        buffers.allocateBuffers(numBones: 2, numSpheres: 0, numCapsules: 0)
        model.springBoneBuffers = buffers
        model.springBoneGlobalParams = SpringBoneGlobalParams(
            gravity: SIMD3<Float>(0, -9.8, 0),
            dtSub: Float(1.0 / 120.0),
            windAmplitude: 0, windFrequency: 0, windPhase: 0,
            windDirection: SIMD3<Float>(1, 0, 0),
            substeps: 1, numBones: 2, numSpheres: 0, numCapsules: 0,
            numPlanes: 0, settlingFrames: 0
        )

        let system = try SpringBoneComputeSystem(device: device)
        try system.populateSpringBoneData(model: model)

        XCTAssertTrue(system.hasCenterRecord(forNodeIndex: 5),
            "SpringBoneComputeSystem must record a center-spring entry for node index 5 " +
            "when a spring's center is set to 5.")
    }

    // MARK: - C3: plane collider warning

    /// The `plane` case in VRMColliderShape must be documented as non-spec.
    /// Verify the parser handles a JSON 'plane' collider without crashing and
    /// returns the non-spec shape (the warning is compile-flag-gated so we
    /// can only verify the parse outcome here).
    func testParsedPlaneColliderIsNonSpec() throws {
        let springBoneExt: [String: Any] = [
            "specVersion": "1.0",
            "colliders": [[
                "node": 0,
                "shape": [
                    "plane": [
                        "offset": [Float(0), Float(0), Float(0)],
                        "normal": [Float(0), Float(1), Float(0)]
                    ]
                ]
            ]]
        ]
        let (vrmDict, document) = makeMinimalVRM1Dict(springBoneExt: springBoneExt)
        let model = try parser.parseVRMExtension(vrmDict, document: document)

        XCTAssertEqual(model.springBone?.colliders.count, 1,
            "Plane collider in JSON must be parsed (non-spec extension path).")
        guard let shape = model.springBone?.colliders.first?.shape else {
            XCTFail("Collider shape missing")
            return
        }
        if case .plane = shape {
            // Correct
        } else {
            XCTFail("Expected .plane shape, got \(shape)")
        }
    }

    // MARK: - #182: expandVRM0SpringBoneChains must not run on VRM 1.0

    /// VRMC_springBone-1.0 already encodes the full chain in `springs[].joints`.
    /// Calling `expandVRM0SpringBoneChains()` on a VRM 1.0 model must be a no-op;
    /// otherwise each joint is treated as a chain root and the joint count inflates
    /// (e.g. 4 → 9 across 3 phantom sub-chains).
    func testVRM1SpringBoneChainExpansionIsNoOp() throws {
        let model = try VRMBuilder().setSkeleton(.defaultHumanoid).build()
        XCTAssertFalse(model.isVRM0, "VRMBuilder produces VRM 1.0 by default.")

        let gltfJSON = """
        {"name":"n","translation":[0,0,0],"rotation":[0,0,0,1],"scale":[1,1,1]}
        """
        func makeNode(_ index: Int) -> VRMNode {
            let data = gltfJSON.data(using: .utf8)!
            let gltf = try! JSONDecoder().decode(GLTFNode.self, from: data)
            return VRMNode(index: index, gltfNode: gltf)
        }

        // Linear chain 19→20→21→22 (matches the vrm-conformance emit-springbone repro).
        model.nodes.removeAll()
        var chainNodes: [VRMNode] = []
        for i in 0...22 {
            chainNodes.append(makeNode(i))
        }
        for i in 19..<22 {
            chainNodes[i + 1].parent = chainNodes[i]
            chainNodes[i].children.append(chainNodes[i + 1])
        }
        model.nodes = chainNodes
        for n in model.nodes { n.updateWorldTransform() }

        var springBone = VRMSpringBone()
        var spring = VRMSpring(name: "repro_chain")
        spring.joints = (19...22).map { idx in
            var j = VRMSpringJoint(node: idx)
            j.stiffness = 0.5
            return j
        }
        springBone.springs = [spring]
        model.springBone = springBone

        model.expandVRM0SpringBoneChains()

        XCTAssertEqual(model.springBone?.springs.count, 1,
            "VRM 1.0 chain must not be expanded into multiple springs.")
        XCTAssertEqual(model.springBone?.springs.first?.joints.count, 4,
            "VRM 1.0 chain joint count must remain 4 (asset's declared joints), not 9.")
        XCTAssertEqual(model.springBone?.springs.first?.joints.map { $0.node }, [19, 20, 21, 22],
            "Joint node indices must match the asset's declared order.")
    }

    /// VRM 0.x still relies on `expandVRM0SpringBoneChains()` to derive the full chain
    /// from a single root index per joint entry. Guard from #182 must not break this.
    func testVRM0SpringBoneChainExpansionStillRuns() throws {
        let (vrmDict, document) = makeMinimalVRM0Dict(secondaryAnimation: [
            "boneGroups": [[
                "comment": "Hair",
                "bones": [19],
                "stiffness": Double(1.0),
                "gravityPower": Double(0.5),
                "dragForce": Double(0.4)
            ]]
        ])
        let model = try parser.parseVRMExtension(vrmDict, document: document)
        XCTAssertTrue(model.isVRM0)

        let gltfJSON = """
        {"name":"n","translation":[0,0,0],"rotation":[0,0,0,1],"scale":[1,1,1]}
        """
        func makeNode(_ index: Int) -> VRMNode {
            let data = gltfJSON.data(using: .utf8)!
            let gltf = try! JSONDecoder().decode(GLTFNode.self, from: data)
            return VRMNode(index: index, gltfNode: gltf)
        }

        model.nodes.removeAll()
        var chainNodes: [VRMNode] = []
        for i in 0...22 { chainNodes.append(makeNode(i)) }
        // 19 is a root; expand should walk into 20→21→22 via children.
        for i in 19..<22 {
            chainNodes[i + 1].parent = chainNodes[i]
            chainNodes[i].children.append(chainNodes[i + 1])
        }
        model.nodes = chainNodes
        for n in model.nodes { n.updateWorldTransform() }

        let originalJointCount = model.springBone?.springs.reduce(0) { $0 + $1.joints.count } ?? 0
        XCTAssertEqual(originalJointCount, 1, "VRM 0.x parser stores roots only.")

        model.expandVRM0SpringBoneChains()

        let expandedJointCount = model.springBone?.springs.reduce(0) { $0 + $1.joints.count } ?? 0
        XCTAssertGreaterThan(expandedJointCount, originalJointCount,
            "VRM 0.x expansion must still traverse descendants and grow the joint list.")
    }
}

// MARK: - Test-only SpringBoneComputeSystem accessor

extension SpringBoneComputeSystem {
    /// Returns true if the system has a CenterSpringRecord whose centerNodeIndex matches.
    /// Exposed only for unit testing center-space metadata (C1).
    func hasCenterRecord(forNodeIndex index: Int) -> Bool {
        centerSpringRecords.contains { $0.centerNodeIndex == index }
    }
}
