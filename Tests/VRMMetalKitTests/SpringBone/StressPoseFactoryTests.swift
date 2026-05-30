//
// Copyright 2025 Arkavo
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0

import XCTest
@testable import VRMMetalKit

final class StressPoseFactoryTests: XCTestCase {
    func testAllPosesHaveCorrectDuration() {
        for pose in StressPose.allCases {
            let clip = StressPoseFactory.clip(pose)
            XCTAssertEqual(clip.duration, 4.0, "Pose \(pose.rawValue) expected duration 4.0")
        }
    }

    func testLookUpHasOneJointTrack() {
        let clip = StressPoseFactory.clip(.lookUp)
        XCTAssertEqual(clip.jointTracks.count, 1, "lookUp should have 1 joint track")
    }

    func testArmsRaisedHasTwoJointTracks() {
        let clip = StressPoseFactory.clip(.armsRaised)
        XCTAssertEqual(clip.jointTracks.count, 2, "armsRaised should have 2 joint tracks")
    }

    func testArmsCrossedHasTwoJointTracks() {
        let clip = StressPoseFactory.clip(.armsCrossed)
        XCTAssertEqual(clip.jointTracks.count, 2, "armsCrossed should have 2 joint tracks")
    }

    func testSeatedDeepFlexionHasTwoJointTracks() {
        let clip = StressPoseFactory.clip(.seatedDeepFlexion)
        XCTAssertEqual(clip.jointTracks.count, 2, "seatedDeepFlexion should have 2 joint tracks")
    }

    func testCustomDurationIsRespected() {
        let clip = StressPoseFactory.clip(.lookUp, duration: 2.5)
        XCTAssertEqual(clip.duration, 2.5, accuracy: 0.001)
    }

    func testAllCasesAreCovered() {
        XCTAssertEqual(StressPose.allCases.count, 4)
    }
}
