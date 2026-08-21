//
// Copyright 2026 Arkavo
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
import CoreGraphics
import ImageIO
@testable import VRMMetalKit
@testable import GLTFCore

/// Every loaded texture carries the sampler state its glTF sampler asked
/// for, and textures naming the same sampler share one state.
///
/// The bundled avatars all write `REPEAT`/`REPEAT`/`LINEAR` — the exact
/// behaviour of the renderer's old global sampler — so the association is
/// only observable on a synthetic VRM.
final class VRMTextureSamplerTests: XCTestCase {

    /// Four textures over three distinct samplers (one of them named
    /// twice) plus one texture with no `sampler` field. Sampler states are
    /// opaque, so the assertion is on sharing: same sampler ⇒ same state,
    /// different sampler ⇒ different state.
    func testEachTextureCarriesItsOwnSamplerState() async throws {
        let device = try metalDevice()
        let samplers: [[String: Any]] = [
            ["magFilter": 9729, "minFilter": 9729, "wrapS": 33071, "wrapT": 33071],
            ["magFilter": 9728, "minFilter": 9987, "wrapS": 33648, "wrapT": 10497],
            ["wrapS": 10497, "wrapT": 10497],
        ]
        let textures: [[String: Any]] = [
            ["sampler": 0, "source": 0],
            ["sampler": 1, "source": 0],
            ["sampler": 0, "source": 0],
            ["sampler": 2, "source": 0],
            ["source": 0],
        ]
        let model = try await loadSyntheticVRM(samplers: samplers, textures: textures, device: device)

        XCTAssertEqual(model.textures.count, 5)
        for (index, texture) in model.textures.enumerated() {
            XCTAssertNotNil(texture.sampler, "texture \(index) must carry a sampler state")
        }

        let clampA = try XCTUnwrap(model.textures[0].sampler)
        let mirrored = try XCTUnwrap(model.textures[1].sampler)
        let clampB = try XCTUnwrap(model.textures[2].sampler)
        let repeated = try XCTUnwrap(model.textures[3].sampler)
        let unsampled = try XCTUnwrap(model.textures[4].sampler)

        XCTAssertTrue(clampA === clampB, "textures naming sampler 0 must share one state")
        XCTAssertFalse(clampA === mirrored, "CLAMP_TO_EDGE and MIRRORED_REPEAT must not share a state")
        XCTAssertFalse(clampA === repeated, "CLAMP_TO_EDGE and REPEAT must not share a state")
        XCTAssertTrue(repeated === unsampled,
                      "a texture with no sampler resolves to the glTF defaults, which sampler 2 (wrap only) spells out")
    }

    /// The parallel loader is a separate branch in `VRMModel.loadResources`
    /// and carries the association independently.
    func testParallelTextureLoadingCarriesSamplerState() async throws {
        let device = try metalDevice()
        let samplers: [[String: Any]] = [
            ["magFilter": 9729, "minFilter": 9729, "wrapS": 33071, "wrapT": 10497],
            ["magFilter": 9729, "minFilter": 9729, "wrapS": 10497, "wrapT": 10497],
        ]
        let textures: [[String: Any]] = [
            ["sampler": 0, "source": 0],
            ["sampler": 1, "source": 0],
            ["sampler": 0, "source": 0],
        ]
        let model = try await loadSyntheticVRM(
            samplers: samplers, textures: textures, device: device,
            options: VRMLoadingOptions(optimizations: [.parallelTextureLoading]))

        let clampA = try XCTUnwrap(model.textures[0].sampler, "parallel loading must still associate samplers")
        let repeated = try XCTUnwrap(model.textures[1].sampler)
        let clampB = try XCTUnwrap(model.textures[2].sampler)
        XCTAssertTrue(clampA === clampB)
        XCTAssertFalse(clampA === repeated)
    }

    // MARK: - Fixture

    private func loadSyntheticVRM(samplers: [[String: Any]],
                                  textures: [[String: Any]],
                                  device: MTLDevice,
                                  options: VRMLoadingOptions? = nil) async throws -> VRMModel {
        let boneNames = ["hips", "spine", "head",
                         "leftUpperArm", "leftLowerArm", "leftHand",
                         "rightUpperArm", "rightLowerArm", "rightHand",
                         "leftUpperLeg", "leftLowerLeg", "leftFoot",
                         "rightUpperLeg", "rightLowerLeg", "rightFoot"]
        var humanBones: [String: Any] = [:]
        var nodes: [[String: Any]] = []
        for (index, bone) in boneNames.enumerated() {
            humanBones[bone] = ["node": index]
            nodes.append(["name": bone])
        }

        let root: [String: Any] = [
            "asset": ["version": "2.0"],
            "extensions": [
                "VRMC_vrm": [
                    "specVersion": "1.0",
                    "meta": ["name": "SamplerFixture", "licenseUrl": "https://vrm.dev/licenses/1.0/"],
                    "humanoid": ["humanBones": humanBones],
                ],
            ],
            "nodes": nodes,
            "scenes": [["nodes": Array(0..<nodes.count)]],
            "scene": 0,
            "images": [["uri": "data:image/png;base64,\(try makePNGBase64())"]],
            "samplers": samplers,
            "textures": textures,
        ]

        var jsonData = try JSONSerialization.data(withJSONObject: root, options: [])
        jsonData.append(contentsOf: Array(repeating: UInt8(0x20), count: (4 - jsonData.count % 4) % 4))

        var glb = Data()
        glb.append(contentsOf: [0x67, 0x6C, 0x54, 0x46])
        glb.append(contentsOf: withUnsafeBytes(of: UInt32(2).littleEndian) { Array($0) })
        glb.append(contentsOf: withUnsafeBytes(of: UInt32(12 + 8 + jsonData.count).littleEndian) { Array($0) })
        glb.append(contentsOf: withUnsafeBytes(of: UInt32(jsonData.count).littleEndian) { Array($0) })
        glb.append(contentsOf: [0x4A, 0x53, 0x4F, 0x4E])
        glb.append(jsonData)

        guard let options else {
            return try await VRMModel.load(from: glb, filePath: nil, device: device)
        }
        // The parallel-texture path is only reachable through the
        // URL-based entry point, which is what carries load options.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sampler-fixture-\(UUID().uuidString).vrm")
        try glb.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try await VRMModel.load(from: url, device: device, options: options)
    }

    private func makePNGBase64() throws -> String {
        let size = 8
        var pixels = [UInt8](repeating: 255, count: size * size * 4)
        for p in 0..<(size * size) {
            pixels[p * 4 + 0] = UInt8(p % 256)
        }
        let context = try XCTUnwrap(CGContext(
            data: nil, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        pixels.withUnsafeBytes { buf in
            context.data?.copyMemory(from: buf.baseAddress!, byteCount: buf.count)
        }
        let cgImage = try XCTUnwrap(context.makeImage(), "CGContext.makeImage failed")
        let pngData = NSMutableData()
        let dest = try XCTUnwrap(
            CGImageDestinationCreateWithData(pngData, "public.png" as CFString, 1, nil),
            "CGImageDestination creation failed")
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw XCTSkip("PNG encode unavailable")
        }
        return (pngData as Data).base64EncodedString()
    }

    private func metalDevice() throws -> MTLDevice {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device not available")
        }
        return device
    }
}
