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
@testable import GLTFMetalKit

/// Phase 3a step 1 acceptance: the GLTFMetalKit target builds, ships its
/// shader metallib as a copied resource, and ``GLTFRenderer`` can load that
/// library on a Metal device. Real rendering checks land in step 4 once a
/// PBR pipeline + KHR dispatch are in place.
final class GLTFRendererSmokeTests: XCTestCase {

    func testShaderMetallibIsBundled() {
        let url = GLTFMetalKit.bundle.url(
            forResource: "GLTFMetalKitShaders",
            withExtension: "metallib"
        )
        XCTAssertNotNil(url, "GLTFMetalKitShaders.metallib must ship inside the GLTFMetalKit bundle")
    }

    func testRendererLoadsShaderLibrary() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available (CI without GPU)")
        }

        let renderer = try GLTFRenderer(device: device)
        // PBR shader exposes a vertex + fragment pair; verify both are linkable.
        XCTAssertNotNil(renderer.library.makeFunction(name: "gltf_pbr_vertex"))
        XCTAssertNotNil(renderer.library.makeFunction(name: "gltf_pbr_fragment"))
    }

    func testOpaquePBRPipelineStateBuilds() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available (CI without GPU)")
        }

        let renderer = try GLTFRenderer(device: device)
        // Catches vertex-descriptor / attribute-layout mismatches against the shader's
        // GLTFVertexIn declaration. The pipeline-state object isn't drawn with yet;
        // we just need MTLDevice.makeRenderPipelineState to validate the linkage.
        let pso = try renderer.makeOpaquePBRPipelineState(
            colorFormat: .bgra8Unorm_srgb,
            depthFormat: .depth32Float
        )
        XCTAssertNotNil(pso, "Opaque PBR pipeline state must construct from the bundled metallib")
    }

    func testBRDFLUTGenerates() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available (CI without GPU)")
        }

        let renderer = try GLTFRenderer(device: device)
        XCTAssertEqual(renderer.brdfLUT.width, GLTFBRDFLUT.size)
        XCTAssertEqual(renderer.brdfLUT.height, GLTFBRDFLUT.size)
        XCTAssertEqual(renderer.brdfLUT.pixelFormat, .rg16Float)
    }

    func testFallbackEnvironmentIsAttached() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available (CI without GPU)")
        }

        let renderer = try GLTFRenderer(device: device)
        // Fallback cubemaps are 1×1, single mip — keeps the split-sum path
        // valid until the consumer supplies a real environment.
        XCTAssertEqual(renderer.environment.diffuse.textureType, .typeCube)
        XCTAssertEqual(renderer.environment.specular.textureType, .typeCube)
        XCTAssertEqual(renderer.environment.specularMipCount, 1)
    }
}
