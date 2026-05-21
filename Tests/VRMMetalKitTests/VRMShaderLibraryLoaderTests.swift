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
@testable import VRMMetalKit

final class VRMShaderLibraryLoaderTests: XCTestCase {

    func testBundledLibraryNameMatchesCurrentTarget() {
        #if os(iOS) && targetEnvironment(simulator)
        let expected = "VRMMetalKitShaders_iOSSimulator"
        #elseif os(iOS)
        let expected = "VRMMetalKitShaders_iOS"
        #else
        let expected = "VRMMetalKitShaders"
        #endif
        XCTAssertEqual(VRMShaderLibraryLoader.bundledLibraryName, expected)
    }

    func testLoadBundledLibrarySucceeds() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available (likely headless CI)")
        }
        let library = try VRMShaderLibraryLoader.loadBundledLibrary(device: device)
        XCTAssertFalse(library.functionNames.isEmpty, "Loaded library should expose at least one function")
    }

    func testErrorDescriptionIncludesSliceNameAndRebuildHint() {
        let error = VRMShaderLibraryLoaderError.shaderLibraryMissing(expected: "VRMMetalKitShaders_iOS")
        let description = error.errorDescription ?? ""
        XCTAssertTrue(description.contains("VRMMetalKitShaders_iOS"),
                      "Error description should include the slice name")
        XCTAssertTrue(description.contains("make shaders"),
                      "Error description should include the rebuild hint")
    }
}
