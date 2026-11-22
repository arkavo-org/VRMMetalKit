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

/// Regression coverage for the 2026-11-11 VRM loading audit follow-ups (#223):
/// 1. Bounded parallel texture concurrency + default parallel texture loading.
/// 2. Strict error propagation in parallel texture loading matching sequential loading.
/// 3. Negative image source indices and overflow-safe image buffer-view range checks.
/// 4. Early `baseURL` initialization for URL loads vs nil `baseURL` for in-memory loads.
final class LoaderHardeningTests: XCTestCase {

    // MARK: - 1. Default parallel texture loading + bounded concurrency

    func testDefaultOptimizationEnablesParallelTextureLoading() {
        XCTAssertTrue(VRMLoadingOptimization.default.contains(.parallelTextureLoading))
    }

    func testParallelTextureLoaderBoundedWindowLoadsAllTextures() async throws {
        let device = try metalDevice()
        let pngBase64 = try makePNGBase64()
        let count = 8
        let images = (0..<count).map { _ in ["uri": "data:image/png;base64,\(pngBase64)"] }
        let textures = (0..<count).map { ["source": $0] }
        let doc = try decodeDocument([
            "asset": ["version": "2.0"],
            "images": images,
            "textures": textures,
        ])
        let bufferLoader = BufferLoader(document: doc, binaryData: nil)

        for window in [1, 2, 4] {
            let loader = ParallelTextureLoader(
                device: device,
                bufferLoader: bufferLoader,
                document: doc,
                maxConcurrentLoads: window
            )
            let loaded = try await loader.loadTexturesParallelThrowing(
                indices: Array(0..<count),
                linearTextureIndices: [1, 3]
            )
            XCTAssertEqual(loaded.count, count, "Window \(window) must load every texture")
            XCTAssertEqual(loaded[0]?.pixelFormat, .rgba8Unorm_srgb)
            XCTAssertEqual(loaded[1]?.pixelFormat, .rgba8Unorm)
            XCTAssertEqual(loaded[3]?.pixelFormat, .rgba8Unorm)
        }
    }

    // MARK: - 2. Strict vs best-effort error preservation

    func testCorruptTextureThrowsInBothSequentialAndParallelVRMModelLoad() async throws {
        let device = try metalDevice()
        let validBase64 = try makePNGBase64()
        let corruptBase64 = Data("not-a-valid-png".utf8).base64EncodedString()

        let glb = try makeSyntheticVRM(
            images: [
                ["uri": "data:image/png;base64,\(validBase64)"],
                ["uri": "data:image/png;base64,\(corruptBase64)"],
            ],
            textures: [["source": 0], ["source": 1]]
        )

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("corrupt-tex-\(UUID().uuidString).vrm")
        try glb.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        for optimizations: VRMLoadingOptimization in [[], [.parallelTextureLoading], .default] {
            do {
                _ = try await VRMModel.load(
                    from: url,
                    device: device,
                    options: VRMLoadingOptions(optimizations: optimizations)
                )
                XCTFail("Expected invalidImageData for optimizations=\(optimizations)")
            } catch GLTFError.invalidImageData(let textureIndex, _, _) {
                XCTAssertEqual(textureIndex, 1)
            }
        }
    }

    func testBestEffortParallelTextureLoaderOmitsCorruptTexture() async throws {
        let device = try metalDevice()
        let validBase64 = try makePNGBase64()
        let corruptBase64 = Data("not-a-valid-png".utf8).base64EncodedString()
        let doc = try decodeDocument([
            "asset": ["version": "2.0"],
            "images": [
                ["uri": "data:image/png;base64,\(validBase64)"],
                ["uri": "data:image/png;base64,\(corruptBase64)"],
            ],
            "textures": [["source": 0], ["source": 1]],
        ])
        let loader = ParallelTextureLoader(
            device: device,
            bufferLoader: BufferLoader(document: doc, binaryData: nil),
            document: doc,
            maxConcurrentLoads: 2
        )
        let loaded = await loader.loadTexturesParallel(indices: [0, 1], linearTextureIndices: [])
        XCTAssertNotNil(loaded[0])
        XCTAssertNil(loaded[1])
    }

    // MARK: - 3. Negative sourceIndex & overflow-safe image bufferView validation

    func testNegativeImageSourceIndexDoesNotCrashEitherLoader() async throws {
        let device = try metalDevice()
        let validBase64 = try makePNGBase64()
        let doc = try decodeDocument([
            "asset": ["version": "2.0"],
            "images": [["uri": "data:image/png;base64,\(validBase64)"]],
            "textures": [["source": -1], ["source": 0]],
        ])
        let bufferLoader = BufferLoader(document: doc, binaryData: nil)

        let serial = TextureLoader(device: device, bufferLoader: bufferLoader, document: doc)
        let serialNeg = try await serial.loadTexture(at: 0, sRGB: true)
        XCTAssertNil(serialNeg)
        let serialValid = try await serial.loadTexture(at: 1, sRGB: true)
        XCTAssertNotNil(serialValid)

        let parallel = ParallelTextureLoader(device: device, bufferLoader: bufferLoader, document: doc)
        let parallelLoaded = try await parallel.loadTexturesParallelThrowing(indices: [0, 1], linearTextureIndices: [])
        XCTAssertNil(parallelLoaded[0])
        XCTAssertNotNil(parallelLoaded[1])
    }

    func testImageBufferViewMalformedRangesThrowWithoutOverflowOrTrap() async throws {
        let device = try metalDevice()
        let pngData = try makePNGData()
        let cases: [(offset: Int, length: Int)] = [
            (-1, 4),
            (0, -1),
            (Int.max, 1),
            (1, Int.max),
            (pngData.count, 1),
            (0, pngData.count + 1),
        ]

        for (offset, length) in cases {
            let doc = try decodeDocument([
                "asset": ["version": "2.0"],
                "buffers": [["byteLength": pngData.count]],
                "bufferViews": [["buffer": 0, "byteOffset": offset, "byteLength": length]],
                "images": [["bufferView": 0, "mimeType": "image/png"]],
                "textures": [["source": 0]],
            ])
            let bufferLoader = BufferLoader(document: doc, binaryData: pngData)

            let serial = TextureLoader(device: device, bufferLoader: bufferLoader, document: doc)
            do {
                _ = try await serial.loadTexture(at: 0, sRGB: true)
                XCTFail("Expected serial TextureLoader to throw for offset=\(offset), length=\(length)")
            } catch GLTFError.missingBuffer {
                // expected
            }

            let parallel = ParallelTextureLoader(device: device, bufferLoader: bufferLoader, document: doc)
            do {
                _ = try await parallel.loadTexturesParallelThrowing(indices: [0], linearTextureIndices: [])
                XCTFail("Expected ParallelTextureLoader to throw for offset=\(offset), length=\(length)")
            } catch GLTFError.missingBuffer {
                // expected
            }
        }
    }

    func testImageBufferViewWithinBinaryChunkBeyondDeclaredBufferLengthLoads() async throws {
        // Legacy VRM 0.x exporters (e.g. AliciaSolid.vrm) append thumbnail image bufferViews
        // inside the GLB BIN chunk past `buffers[0].byteLength`. Bounds must validate against
        // actual binaryData size without overflowing.
        let device = try metalDevice()
        let pngData = try makePNGData()
        var binData = Data(repeating: 0, count: 16)
        let imageOffset = binData.count
        binData.append(pngData)

        let doc = try decodeDocument([
            "asset": ["version": "2.0"],
            "buffers": [["byteLength": imageOffset]],
            "bufferViews": [["buffer": 0, "byteOffset": imageOffset, "byteLength": pngData.count]],
            "images": [["bufferView": 0, "mimeType": "image/png"]],
            "textures": [["source": 0]],
        ])
        let bufferLoader = BufferLoader(document: doc, binaryData: binData)

        let serial = TextureLoader(device: device, bufferLoader: bufferLoader, document: doc)
        let serialTex = try await serial.loadTexture(at: 0, sRGB: true)
        XCTAssertNotNil(serialTex)

        let parallel = ParallelTextureLoader(device: device, bufferLoader: bufferLoader, document: doc)
        let parallelLoaded = try await parallel.loadTexturesParallelThrowing(indices: [0], linearTextureIndices: [])
        XCTAssertNotNil(parallelLoaded[0])
    }

    // MARK: - 4. Early baseURL initialization (URL vs in-memory semantics)

    func testURLLoadResolvesExternalBufferAndTextureDuringLoad() async throws {
        let device = try metalDevice()
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("VRMExternalBaseURL-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let positions: [Float] = [0, 0, 0,  1, 0, 0,  0, 1, 0]
        let binData = positions.withUnsafeBufferPointer { Data(buffer: $0) }
        try binData.write(to: dir.appendingPathComponent("geo.bin"))

        let pngData = try makePNGData()
        try pngData.write(to: dir.appendingPathComponent("albedo.png"))

        let glb = try makeSyntheticVRM(
            images: [["uri": "albedo.png"], ["uri": "albedo.png"]],
            textures: [["source": 0], ["source": 1]],
            buffers: [["uri": "geo.bin", "byteLength": binData.count]],
            bufferViews: [["buffer": 0, "byteOffset": 0, "byteLength": binData.count]],
            accessors: [[
                "bufferView": 0, "byteOffset": 0,
                "componentType": 5126, "count": 3, "type": "VEC3",
                "min": [0.0, 0.0, 0.0], "max": [1.0, 1.0, 0.0],
            ]],
            meshes: [["name": "extTri", "primitives": [["attributes": ["POSITION": 0]]]]]
        )

        let vrmURL = dir.appendingPathComponent("avatar.vrm")
        try glb.write(to: vrmURL)

        // URL entry point must resolve external buffer and textures for both serial and parallel modes.
        for opts: VRMLoadingOptimization in [[], [.parallelTextureLoading]] {
            let model = try await VRMModel.load(
                from: vrmURL,
                device: device,
                options: VRMLoadingOptions(optimizations: opts)
            )
            XCTAssertEqual(model.baseURL?.standardizedFileURL, dir.standardizedFileURL)
            XCTAssertEqual(model.meshes.count, 1)
            XCTAssertEqual(model.meshes[0].primitives.first?.vertexCount, 3)
            XCTAssertEqual(model.textures.count, 2)
            XCTAssertNotNil(model.textures[0].mtlTexture)
            XCTAssertNotNil(model.textures[1].mtlTexture)
        }

        // In-memory entry point must NOT resolve relative filesystem URIs even when filePath is passed.
        do {
            _ = try await VRMModel.load(from: glb, filePath: vrmURL.path, device: device)
            XCTFail("In-memory VRMModel.load(from: Data) must not resolve external relative resources")
        } catch GLTFError.missingTexture {
            // expected (texture resolved first without baseURL)
        } catch GLTFError.invalidPath {
            // also acceptable if buffer load runs first
        }
    }

    // MARK: - Helpers

    private func decodeDocument(_ json: [String: Any]) throws -> GLTFDocument {
        try JSONDecoder().decode(GLTFDocument.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func makeSyntheticVRM(
        images: [[String: Any]],
        textures: [[String: Any]],
        buffers: [[String: Any]]? = nil,
        bufferViews: [[String: Any]]? = nil,
        accessors: [[String: Any]]? = nil,
        meshes: [[String: Any]]? = nil
    ) throws -> Data {
        let boneNames = [
            "hips", "spine", "head",
            "leftUpperArm", "leftLowerArm", "leftHand",
            "rightUpperArm", "rightLowerArm", "rightHand",
            "leftUpperLeg", "leftLowerLeg", "leftFoot",
            "rightUpperLeg", "rightLowerLeg", "rightFoot",
        ]
        var humanBones: [String: Any] = [:]
        var nodes: [[String: Any]] = []
        for (idx, bone) in boneNames.enumerated() {
            humanBones[bone] = ["node": idx]
            nodes.append(["name": bone])
        }
        if meshes != nil {
            nodes.append(["name": "meshNode", "mesh": 0])
        }

        var root: [String: Any] = [
            "asset": ["version": "2.0"],
            "extensions": [
                "VRMC_vrm": [
                    "specVersion": "1.0",
                    "meta": ["name": "HardeningFixture", "licenseUrl": "https://vrm.dev/licenses/1.0/"],
                    "humanoid": ["humanBones": humanBones],
                ],
            ],
            "nodes": nodes,
            "scenes": [["nodes": Array(0..<nodes.count)]],
            "scene": 0,
            "images": images,
            "textures": textures,
        ]
        if let buffers { root["buffers"] = buffers }
        if let bufferViews { root["bufferViews"] = bufferViews }
        if let accessors { root["accessors"] = accessors }
        if let meshes { root["meshes"] = meshes }

        var jsonData = try JSONSerialization.data(withJSONObject: root)
        jsonData.append(contentsOf: Array(repeating: UInt8(0x20), count: (4 - jsonData.count % 4) % 4))

        var glb = Data()
        glb.append(contentsOf: [0x67, 0x6C, 0x54, 0x46])
        glb.append(contentsOf: withUnsafeBytes(of: UInt32(2).littleEndian) { Array($0) })
        glb.append(contentsOf: withUnsafeBytes(of: UInt32(12 + 8 + jsonData.count).littleEndian) { Array($0) })
        glb.append(contentsOf: withUnsafeBytes(of: UInt32(jsonData.count).littleEndian) { Array($0) })
        glb.append(contentsOf: [0x4A, 0x53, 0x4F, 0x4E])
        glb.append(jsonData)
        return glb
    }

    private func makePNGData() throws -> Data {
        let size = 4
        var pixels = [UInt8](repeating: 255, count: size * size * 4)
        for p in 0..<(size * size) {
            pixels[p * 4] = UInt8((p * 17) % 256)
        }
        let context = try XCTUnwrap(CGContext(
            data: nil, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        pixels.withUnsafeBytes { buf in
            context.data?.copyMemory(from: buf.baseAddress!, byteCount: buf.count)
        }
        let cgImage = try XCTUnwrap(context.makeImage())
        let pngData = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(pngData, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw XCTSkip("PNG encode unavailable")
        }
        return pngData as Data
    }

    private func makePNGBase64() throws -> String {
        try makePNGData().base64EncodedString()
    }

    private func metalDevice() throws -> MTLDevice {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device not available")
        }
        return device
    }
}
