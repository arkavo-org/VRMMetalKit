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


// VRMMetalKit - VRM 1.0 Model Loader and Renderer for Metal
//
// This package provides comprehensive support for loading and rendering
// VRM 1.0 avatars using Apple's Metal framework.

import Foundation
import Metal

public struct VRMMetalKit {
    public static let version = "1.0.1"
    public static let buildDate = "2026-01-18"
    public static let shaderVersion = "v21-fix-stiffness-index"

    /// Initialize VRMMetalKit with a Metal device
    public static func initialize(device: MTLDevice) {
        // Future: Global initialization if needed
    }

    /// Log version information to console
    public static func logVersion() {
        print("[VRMMetalKit] Version: \(version) (\(buildDate)) Shader: \(shaderVersion)")
    }

    /// Load a VRM model from a file URL
    public static func loadModel(from url: URL, device: MTLDevice? = nil) async throws -> VRMModel {
        return try await VRMModel.load(from: url, device: device)
    }

    /// Load a VRM model from data
    public static func loadModel(from data: Data, device: MTLDevice? = nil) async throws -> VRMModel {
        return try await VRMModel.load(from: data, device: device)
    }
}

// Re-export main types
public typealias VRM = VRMModel