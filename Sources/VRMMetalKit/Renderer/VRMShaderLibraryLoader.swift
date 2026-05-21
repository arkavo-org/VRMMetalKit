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
import Metal

/// Failures raised by ``VRMShaderLibraryLoader`` when locating or loading the bundled shader library.
enum VRMShaderLibraryLoaderError: Error, LocalizedError {
    /// The platform-specific `.metallib` slice is missing from the package resource bundle.
    /// Usually means `make shaders` was not run or the wrong slice was not built.
    case shaderLibraryMissing(expected: String)
    /// `MTLDevice.makeLibrary(URL:)` rejected the bundled metallib. The associated error carries
    /// the Metal-driver-level reason.
    case shaderLibraryLoadFailed(name: String, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .shaderLibraryMissing(let expected):
            return "\(expected).metallib not found in package resources. Run `make shaders` to rebuild all platform slices."
        case .shaderLibraryLoadFailed(let name, let underlying):
            return "Failed to load \(name).metallib: \(underlying.localizedDescription). " +
                   "Re-run `make shaders` and verify the correct SDK slice was built."
        }
    }
}

/// Resolves the correct bundled `.metallib` slice for the current build target and loads it.
///
/// Three slices are shipped as package resources:
/// - `VRMMetalKitShaders.metallib` — macOS
/// - `VRMMetalKitShaders_iOS.metallib` — iOS device
/// - `VRMMetalKitShaders_iOSSimulator.metallib` — iOS Simulator
///
/// ``loadBundledLibrary(device:)`` picks the correct slice at compile time via `#if` and
/// delegates the `Bundle.module` lookup and `MTLDevice.makeLibrary(URL:)` call.
enum VRMShaderLibraryLoader {
    /// The resource name (without extension) of the `.metallib` slice for the current build target.
    static var bundledLibraryName: String {
        #if os(iOS) && targetEnvironment(simulator)
        return "VRMMetalKitShaders_iOSSimulator"
        #elseif os(iOS)
        return "VRMMetalKitShaders_iOS"
        #else
        // macOS, visionOS, tvOS, macCatalyst — all use the macOS (FP32) slice.
        return "VRMMetalKitShaders"
        #endif
    }

    /// Loads the bundled shader library for the current platform from the package resource bundle.
    ///
    /// - Parameter device: The `MTLDevice` to create the library against.
    /// - Returns: The compiled shader library.
    /// - Throws: ``VRMShaderLibraryLoaderError/shaderLibraryMissing(expected:)`` if the metallib
    ///   is absent from the bundle, or ``VRMShaderLibraryLoaderError/shaderLibraryLoadFailed(name:underlying:)``
    ///   if Metal rejects the file.
    static func loadBundledLibrary(device: MTLDevice) throws -> MTLLibrary {
        let name = bundledLibraryName
        guard let url = Bundle.module.url(forResource: name, withExtension: "metallib") else {
            throw VRMShaderLibraryLoaderError.shaderLibraryMissing(expected: name)
        }
        do {
            return try device.makeLibrary(URL: url)
        } catch {
            throw VRMShaderLibraryLoaderError.shaderLibraryLoadFailed(
                name: name, underlying: error)
        }
    }
}
