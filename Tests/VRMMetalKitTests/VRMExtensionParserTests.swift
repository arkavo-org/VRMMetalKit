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
@testable import VRMMetalKit

/// Unit tests for VRMExtensionParser
/// Tests VRM 0.0 and VRM 1.0 parsing, version detection, and format differences
final class VRMExtensionParserTests: XCTestCase {

    var parser: VRMExtensionParser!

    override func setUp() {
        super.setUp()
        parser = VRMExtensionParser()
    }

    override func tearDown() {
        parser = nil
        super.tearDown()
    }

    // MARK: - Version Detection Tests

    func testVRM1VersionDetection() throws {
        let vrmDict: [String: Any] = [
            "specVersion": "1.0",
            "meta": [
                "name": "TestModel",
                "licenseUrl": "https://example.com/license"
            ],
            "humanoid": [
                "humanBones": [
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
                ]
            ]
        ]

        let document = createMinimalGLTFDocument()
        let model = try parser.parseVRMExtension(vrmDict, document: document)

        XCTAssertEqual(model.specVersion, .v1_0)
        XCTAssertFalse(model.isVRM0)
        XCTAssertEqual(model.meta.name, "TestModel")
    }

    func testVRM0VersionDetection() throws {
        let vrmDict: [String: Any] = [
            "version": "0.0",
            "meta": [
                "title": "TestModel",
                "author": "TestAuthor"
            ],
            "humanoid": [
                "humanBones": [
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
                ]
            ]
        ]

        let document = createMinimalGLTFDocument()
        let model = try parser.parseVRMExtension(vrmDict, document: document)

        XCTAssertEqual(model.specVersion, .v0_0)
        XCTAssertTrue(model.isVRM0)
    }

    func testVersionFallbackToVRM0() throws {
        // No version field but has VRM 0.0 structure (array humanBones)
        let vrmDict: [String: Any] = [
            "meta": [
                "title": "TestModel"
            ],
            "humanoid": [
                "humanBones": [
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
                ]
            ]
        ]

        let document = createMinimalGLTFDocument()
        let model = try parser.parseVRMExtension(vrmDict, document: document)

        XCTAssertEqual(model.specVersion, .v0_0)
    }

    // MARK: - VRM 1.0 Dictionary Format Tests

    func testVRM1HumanoidDictionaryFormat() throws {
        let vrmDict: [String: Any] = [
            "specVersion": "1.0",
            "meta": ["name": "Test", "licenseUrl": "https://example.com"],
            "humanoid": [
                "humanBones": [
                    "hips": ["node": 0],
                    "leftUpperLeg": ["node": 1],
                    "rightUpperLeg": ["node": 2],
                    "leftLowerLeg": ["node": 3],
                    "rightLowerLeg": ["node": 4],
                    "leftFoot": ["node": 5],
                    "rightFoot": ["node": 6],
                    "spine": ["node": 7],
                    "chest": ["node": 8],
                    "upperChest": ["node": 9],
                    "neck": ["node": 10],
                    "head": ["node": 11],
                    "leftShoulder": ["node": 12],
                    "rightShoulder": ["node": 13],
                    "leftUpperArm": ["node": 14],
                    "rightUpperArm": ["node": 15],
                    "leftLowerArm": ["node": 16],
                    "rightLowerArm": ["node": 17],
                    "leftHand": ["node": 18],
                    "rightHand": ["node": 19]
                ]
            ]
        ]

        let document = createMinimalGLTFDocument()
        let model = try parser.parseVRMExtension(vrmDict, document: document)

        XCTAssertNotNil(model.humanoid)
        XCTAssertEqual(model.humanoid?.getBoneNode(.hips), 0)
        XCTAssertEqual(model.humanoid?.getBoneNode(.spine), 7)
        XCTAssertEqual(model.humanoid?.getBoneNode(.chest), 8)
        XCTAssertEqual(model.humanoid?.getBoneNode(.head), 11)
        XCTAssertEqual(model.humanoid?.getBoneNode(.leftUpperArm), 14)
        XCTAssertEqual(model.humanoid?.getBoneNode(.rightUpperArm), 15)
    }

    func testVRM1ExpressionsParsing() throws {
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
            ]],
            "expressions": [
                "preset": [
                    "happy": [
                        "morphTargetBinds": [
                            ["node": 0, "index": 0, "weight": 1.0]
                        ]
                    ],
                    "blink": [
                        "isBinary": true,
                        "morphTargetBinds": [
                            ["node": 1, "index": 0, "weight": 1.0]
                        ]
                    ]
                ],
                "custom": [
                    "customExpression": [
                        "morphTargetBinds": [
                            ["node": 2, "index": 0, "weight": 0.5]
                        ]
                    ]
                ]
            ]
        ]

        let document = createMinimalGLTFDocument()
        let model = try parser.parseVRMExtension(vrmDict, document: document)

        XCTAssertNotNil(model.expressions)
        XCTAssertNotNil(model.expressions?.preset[.happy])
        XCTAssertNotNil(model.expressions?.preset[.blink])
        XCTAssertTrue(model.expressions?.preset[.blink]?.isBinary ?? false)
        XCTAssertNotNil(model.expressions?.custom["customExpression"])
    }

    func testVRM1LookAtParsing() throws {
        // Note: parseLookAt expects Double values in dictionaries, not Float
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
            ]],
            "lookAt": [
                "type": "bone",
                "offsetFromHeadBone": [0.0, 0.05, 0.1],
                "rangeMapHorizontalInner": ["inputMaxValue": 0.5, "outputScale": 30.0],
                "rangeMapHorizontalOuter": ["inputMaxValue": 0.5, "outputScale": 30.0],
                "rangeMapVerticalDown": ["inputMaxValue": 0.3, "outputScale": 20.0],
                "rangeMapVerticalUp": ["inputMaxValue": 0.3, "outputScale": 20.0]
            ]
        ]

        let document = createMinimalGLTFDocument()
        let model = try parser.parseVRMExtension(vrmDict, document: document)

        XCTAssertNotNil(model.lookAt)
        XCTAssertEqual(model.lookAt?.type, .bone)
        // offsetFromHeadBone is parsed from Double array
        XCTAssertEqual(model.lookAt?.offsetFromHeadBone, SIMD3<Float>(0.0, 0.05, 0.1))
        // Range map values are parsed from Double values
        XCTAssertEqual(model.lookAt?.rangeMapHorizontalInner.inputMaxValue, 0.5)
        XCTAssertEqual(model.lookAt?.rangeMapHorizontalInner.outputScale, 30.0)
    }

    // MARK: - VRM 0.0 Array Format Tests

    func testVRM0HumanoidArrayFormat() throws {
        let vrmDict: [String: Any] = [
            "version": "0.0",
            "meta": [
                "title": "TestModel",
                "author": "TestAuthor"
            ],
            "humanoid": [
                "humanBones": [
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
                ]
            ]
        ]

        let document = createMinimalGLTFDocument()
        let model = try parser.parseVRMExtension(vrmDict, document: document)

        XCTAssertNotNil(model.humanoid)
        XCTAssertEqual(model.humanoid?.getBoneNode(.hips), 0)
        XCTAssertEqual(model.humanoid?.getBoneNode(.spine), 7)
        XCTAssertEqual(model.humanoid?.getBoneNode(.chest), 8)
        XCTAssertEqual(model.humanoid?.getBoneNode(.head), 10)
    }

    func testVRM0BlendShapeMasterParsing() throws {
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
            "blendShapeMaster": [
                "blendShapeGroups": [
                    [
                        "name": "happy",
                        "presetName": "happy",
                        "binds": [
                            ["mesh": 0, "index": 0, "weight": 100]
                        ]
                    ],
                    [
                        "name": "blink",
                        "presetName": "blink",
                        "isBinary": true,
                        "binds": [
                            ["mesh": 1, "index": 0, "weight": 100]
                        ]
                    ]
                ]
            ]
        ]

        let document = createMinimalGLTFDocument()
        let model = try parser.parseVRMExtension(vrmDict, document: document)

        XCTAssertNotNil(model.expressions)
        XCTAssertNotNil(model.expressions?.preset[.happy])
        XCTAssertNotNil(model.expressions?.preset[.blink])
        // Weight should be divided by 100 for VRM 0.0
        XCTAssertEqual(model.expressions?.preset[.happy]?.morphTargetBinds.first?.weight, 1.0)
    }

    func testVRM0LookAtInFirstPerson() throws {
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
            "firstPerson": [
                "lookAtTypeName": "Bone",
                "lookAtHorizontalInner": ["xRange": 90.0, "yRange": 10.0],
                "lookAtHorizontalOuter": ["xRange": 90.0, "yRange": 10.0]
            ]
        ]

        let document = createMinimalGLTFDocument()
        let model = try parser.parseVRMExtension(vrmDict, document: document)

        XCTAssertNotNil(model.lookAt)
        XCTAssertEqual(model.lookAt?.type, .bone)
        XCTAssertEqual(model.lookAt?.rangeMapHorizontalInner.inputMaxValue, 90.0)
        XCTAssertEqual(model.lookAt?.rangeMapHorizontalInner.outputScale, 10.0)
    }

    // MARK: - Meta Parsing Tests

    func testVRM1MetaParsing() throws {
        let vrmDict: [String: Any] = [
            "specVersion": "1.0",
            "meta": [
                "name": "Test Model",
                "version": "1.0.0",
                "authors": ["Author1", "Author2"],
                "copyrightInformation": "© 2025",
                "contactInformation": "test@example.com",
                "licenseUrl": "https://example.com/license",
                "avatarPermission": "everyone",
                "commercialUsage": "personalNonProfit",
                "creditNotation": "required",
                "allowRedistribution": true,
                "modify": "allowModification"
            ],
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

        let document = createMinimalGLTFDocument()
        let model = try parser.parseVRMExtension(vrmDict, document: document)

        XCTAssertEqual(model.meta.name, "Test Model")
        XCTAssertEqual(model.meta.version, "1.0.0")
        XCTAssertEqual(model.meta.authors, ["Author1", "Author2"])
        XCTAssertEqual(model.meta.copyrightInformation, "© 2025")
        XCTAssertEqual(model.meta.contactInformation, "test@example.com")
        XCTAssertEqual(model.meta.licenseUrl, "https://example.com/license")
        XCTAssertEqual(model.meta.avatarPermission, .everyone)
        XCTAssertEqual(model.meta.commercialUsage, .personalNonProfit)
        XCTAssertEqual(model.meta.creditNotation, .required)
        XCTAssertEqual(model.meta.allowRedistribution, true)
        XCTAssertEqual(model.meta.modify, .allowModification)
    }

    func testVRM0MetaParsing() throws {
        let vrmDict: [String: Any] = [
            "version": "0.0",
            "meta": [
                "title": "Test Model",
                "version": "1.0",
                "author": "Single Author"
            ],
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
            ]]
        ]

        let document = createMinimalGLTFDocument()
        let model = try parser.parseVRMExtension(vrmDict, document: document)

        XCTAssertEqual(model.meta.name, "Test Model")
        XCTAssertEqual(model.meta.version, "1.0")
        XCTAssertEqual(model.meta.authors, ["Single Author"])
    }

    // MARK: - SpringBone Parsing Tests

    func testVRM1SpringBoneParsing() throws {
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

        let document = createMinimalGLTFDocument(
            extensions: [
                "VRMC_springBone": [
                    "specVersion": "1.0",
                    "colliders": [
                        ["node": 0, "shape": ["sphere": ["offset": [0, 0, 0], "radius": 0.1]]]
                    ],
                    "springs": [
                        [
                            "name": "Hair",
                            "joints": [
                                ["node": 1, "stiffness": 0.8, "gravityPower": 0.5]
                            ]
                        ]
                    ]
                ]
            ]
        )

        let model = try parser.parseVRMExtension(vrmDict, document: document)

        XCTAssertNotNil(model.springBone)
        XCTAssertEqual(model.springBone?.specVersion, "1.0")
        XCTAssertEqual(model.springBone?.colliders.count, 1)
        XCTAssertEqual(model.springBone?.springs.count, 1)
        XCTAssertEqual(model.springBone?.springs.first?.name, "Hair")
    }

    func testVRM0SecondaryAnimationParsing() throws {
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
            "secondaryAnimation": [
                "boneGroups": [
                    [
                        "comment": "Hair",
                        "bones": [1, 2, 3],
                        "stiffness": 0.8,
                        "gravityPower": 0.5,
                        "dragForce": 0.3
                    ]
                ],
                "colliderGroups": [
                    [
                        "node": 0,
                        "colliders": [
                            ["offset": ["x": 0, "y": 0, "z": 0], "radius": 0.1]
                        ]
                    ]
                ]
            ]
        ]

        let document = createMinimalGLTFDocument()
        let model = try parser.parseVRMExtension(vrmDict, document: document)

        XCTAssertNotNil(model.springBone)
        XCTAssertEqual(model.springBone?.specVersion, "0.0")
        XCTAssertEqual(model.springBone?.springs.count, 1)
        XCTAssertEqual(model.springBone?.springs.first?.joints.count, 3)
    }

    // MARK: - Error Handling Tests

    func testMissingMetaThrowsError() {
        let vrmDict: [String: Any] = [
            "specVersion": "1.0",
            "humanoid": ["humanBones": [:]]
        ]

        let document = createMinimalGLTFDocument()

        XCTAssertThrowsError(try parser.parseVRMExtension(vrmDict, document: document)) { error in
            guard case VRMError.invalidJSON = error else {
                XCTFail("Expected invalidJSON error")
                return
            }
        }
    }

    func testMissingHumanoidThrowsError() {
        let vrmDict: [String: Any] = [
            "specVersion": "1.0",
            "meta": ["name": "Test", "licenseUrl": "https://example.com"]
        ]

        let document = createMinimalGLTFDocument()

        XCTAssertThrowsError(try parser.parseVRMExtension(vrmDict, document: document)) { error in
            guard case VRMError.invalidJSON = error else {
                XCTFail("Expected invalidJSON error")
                return
            }
        }
    }

    func testInvalidExtensionTypeThrowsError() {
        let document = createMinimalGLTFDocument()

        XCTAssertThrowsError(try parser.parseVRMExtension("not a dictionary", document: document)) { error in
            guard case VRMError.missingVRMExtension = error else {
                XCTFail("Expected missingVRMExtension error")
                return
            }
        }
    }

    // MARK: - Material Properties Tests

    func testVRM0MaterialPropertiesParsing() throws {
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
            "materialProperties": [
                [
                    "name": "Face",
                    "shader": "VRM/MToon",
                    "renderQueue": 2000,
                    "floatProperties": [
                        "_ShadeToony": 0.9,
                        "_ShadeShift": 0.0
                    ],
                    "vectorProperties": [
                        "_Color": [1, 1, 1, 1],
                        "_ShadeColor": [0.9, 0.9, 0.9, 1]
                    ],
                    "textureProperties": [
                        "_MainTex": 0
                    ],
                    "keywordMap": [
                        "_ALPHATEST_ON": true
                    ]
                ]
            ]
        ]

        let document = createMinimalGLTFDocument()
        let model = try parser.parseVRMExtension(vrmDict, document: document)

        XCTAssertEqual(model.vrm0MaterialProperties.count, 1)
        XCTAssertEqual(model.vrm0MaterialProperties.first?.name, "Face")
        XCTAssertEqual(model.vrm0MaterialProperties.first?.shader, "VRM/MToon")
        XCTAssertEqual(model.vrm0MaterialProperties.first?.floatProperties["_ShadeToony"], 0.9)
    }

    // MARK: - Helper Methods

    private func createMinimalGLTFDocument(nodes: Int = 1, extensions: [String: Any]? = nil) -> GLTFDocument {
        // Create a minimal GLTF document as JSON and decode it
        // Include all required humanoid bones for validation
        let requiredBones = [
            "hips", "leftUpperLeg", "rightUpperLeg", "leftLowerLeg", "rightLowerLeg",
            "leftFoot", "rightFoot", "spine", "chest", "upperChest",
            "neck", "head", "leftShoulder", "rightShoulder",
            "leftUpperArm", "rightUpperArm", "leftLowerArm", "rightLowerArm",
            "leftHand", "rightHand"
        ]
        
        let nodeCount = max(nodes, requiredBones.count)
        
        var json: [String: Any] = [
            "asset": ["version": "2.0", "generator": "Test"],
            "scene": 0,
            "scenes": [["nodes": Array(0..<nodeCount)]],
            "nodes": (0..<nodeCount).map { i in
                ["name": "node_\(i)"]
            }
        ]
        
        if let extensions = extensions {
            json["extensions"] = extensions
        }
        
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(GLTFDocument.self, from: data)
    }
}
