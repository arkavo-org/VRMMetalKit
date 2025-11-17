//
// VRMLoadingTests.swift
// VRMMetalKit
//
// Copyright (c) 2025 Arkavo Inc.
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

/// Tests for loading real VRM model files
final class VRMLoadingTests: XCTestCase {

    var device: MTLDevice!

    override func setUp() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal is not available on this device")
        }
        self.device = device
    }

    /// Test loading AvatarSample_C.vrm.glb from the Muse project
    func testLoadAvatarSampleC() async throws {
        let filePath = "/Users/paul/Projects/arkavo/Muse/AvatarSample_C.vrm.glb"
        let url = URL(fileURLWithPath: filePath)

        // Verify file exists
        guard FileManager.default.fileExists(atPath: filePath) else {
            throw XCTSkip("Test file not found at \(filePath)")
        }

        // Attempt to load the model
        let model: VRMModel
        do {
            model = try await VRMModel.load(from: url, device: device)
        } catch let error as VRMError {
            XCTFail("Failed to load VRM model: \(error.errorDescription ?? String(describing: error))\n\(error.failureReason ?? "")\n\(error.recoverySuggestion ?? "")")
            return
        } catch {
            XCTFail("Failed to load VRM model with unexpected error: \(error)")
            return
        }

        // Verify basic model structure
        XCTAssertFalse(model.nodes.isEmpty, "Model should have nodes")
        XCTAssertFalse(model.meshes.isEmpty, "Model should have meshes")

        // Verify VRM-specific data exists

        // Check humanoid data
        XCTAssertNotNil(model.humanoid, "VRM should have humanoid bone mapping")
        if let humanoid = model.humanoid {
            XCTAssertFalse(humanoid.humanBones.isEmpty, "Humanoid should have bone mappings")
            print("✅ Loaded VRM with \(humanoid.humanBones.count) humanoid bones")
        }

        // Check metadata
        print("✅ VRM Metadata:")
        print("   Name: \(model.meta.name ?? "Unknown")")
        print("   Version: \(model.meta.version ?? "Unknown")")
        if !model.meta.authors.isEmpty {
            print("   Authors: \(model.meta.authors.joined(separator: ", "))")
        }

        // Check expressions if present
        if let expressions = model.expressions {
            print("✅ VRM has \(expressions.preset.count) preset expressions")
            print("✅ VRM has \(expressions.custom.count) custom expressions")
        }

        // Check spring bones if present
        if let springBone = model.springBone {
            print("✅ VRM has \(springBone.springs.count) spring bone chains")
        }

        // Verify materials
        XCTAssertFalse(model.materials.isEmpty, "Model should have materials")
        print("✅ Loaded \(model.materials.count) materials")

        // Print summary
        print("\n📊 Model Summary:")
        print("   Nodes: \(model.nodes.count)")
        print("   Meshes: \(model.meshes.count)")
        print("   Materials: \(model.materials.count)")
        print("   Textures: \(model.textures.count)")
    }

}
