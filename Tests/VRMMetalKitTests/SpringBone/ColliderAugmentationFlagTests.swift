//
// Copyright 2025 Arkavo
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//

import XCTest
@testable import VRMMetalKit

final class ColliderAugmentationFlagTests: XCTestCase {
    func testDefaultAugmentFlagIsOn() {
        XCTAssertTrue(VRMLoadingOptions().augmentSpringBoneColliders, "Augmentation defaults to on per #309")
    }
    func testCanDisableAugment() {
        XCTAssertFalse(VRMLoadingOptions(augmentSpringBoneColliders: false).augmentSpringBoneColliders)
    }
    func testSyntheticCollidersDefaultEmpty() {
        var sb = VRMSpringBone()
        XCTAssertTrue(sb.syntheticColliders.isEmpty)
        sb.syntheticColliders.append(VRMCollider(node: 0, shape: .sphere(offset: .zero, radius: 0.1)))
        XCTAssertEqual(sb.syntheticColliders.count, 1)
    }
}
