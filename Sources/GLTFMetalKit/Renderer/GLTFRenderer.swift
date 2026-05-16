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

import Foundation
@preconcurrency import Metal

/// PBR renderer for static glTF 2.0 assets.
///
/// Phase 3a step 1 scaffold: holds the device + shader library and exposes
/// the entry surface. Pipeline creation, scene graph traversal, IBL setup,
/// and the per-frame draw loop land in later Phase 3a sub-steps.
///
/// Public-API note: this skeleton intentionally minimises commitments
/// because the real shape (uniform layout, IBL binding contract, KHR
/// extension dispatch) is still being worked out. Treat as unstable until
/// Phase 3a step 4 lands.
public final class GLTFRenderer: @unchecked Sendable {
    public let device: MTLDevice
    public let library: MTLLibrary

    /// Creates a renderer bound to a Metal device.
    ///
    /// - Parameter device: The Metal device to use for pipeline state and
    ///   GPU resource allocation. Typically `MTLCreateSystemDefaultDevice()`.
    /// - Throws: An error if the bundled `GLTFMetalKitShaders.metallib`
    ///   cannot be located or loaded.
    public init(device: MTLDevice) throws {
        self.device = device

        guard let metallibURL = GLTFMetalKit.bundle.url(
            forResource: "GLTFMetalKitShaders",
            withExtension: "metallib"
        ) else {
            throw GLTFRendererError.missingShaderLibrary
        }

        self.library = try device.makeLibrary(URL: metallibURL)
    }
}

/// Errors thrown by ``GLTFRenderer``.
public enum GLTFRendererError: Error, LocalizedError {
    /// The bundled `GLTFMetalKitShaders.metallib` resource could not be found.
    case missingShaderLibrary

    public var errorDescription: String? {
        switch self {
        case .missingShaderLibrary:
            return """
            ❌ Missing GLTFMetalKit Shader Library

            The bundled `GLTFMetalKitShaders.metallib` could not be located inside the GLTFMetalKit bundle.

            Suggestion: Run `make gltf-shaders` from the package root to compile the Metal shaders. The compiled metallib must live at `Sources/GLTFMetalKit/Resources/GLTFMetalKitShaders.metallib`.
            """
        }
    }
}
