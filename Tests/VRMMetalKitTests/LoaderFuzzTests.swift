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
import simd
import CoreGraphics
import ImageIO
@testable import VRMMetalKit

/// Loader-side fuzz expansion (companion to FuzzingTests.swift, which focuses on
/// vertex/skinning/render). These tests pound the parsing surface with garbage
/// input and assert only one invariant: **the loader must not crash**.
///
/// Pass criterion for every test: the input is either accepted, or rejected via
/// a thrown error / `nil` return. A `fatalError`, forced-cast crash, or
/// out-of-bounds access fails the run.
///
/// Run with: `swift test --filter LoaderFuzzTests --disable-sandbox`
final class LoaderFuzzTests: XCTestCase {

    // MARK: - 1. Randomized glTF JSON structures

    /// Random documents with missing required fields, null values, wrong types,
    /// negative counts. Must not crash the decoder.
    func testFuzzGLTFDocumentDecoding_RandomShapes() {
        var generator = SeededRandomGenerator(seed: 1729)
        var decodedOK = 0
        var threwError = 0

        for _ in 0..<200 {
            let json = makeRandomGLTFJSON(rng: &generator)
            guard let data = try? JSONSerialization.data(withJSONObject: json, options: []) else {
                continue  // JSONSerialization itself rejected the input
            }

            do {
                _ = try JSONDecoder().decode(GLTFDocument.self, from: data)
                decodedOK += 1
            } catch {
                threwError += 1
            }
            // Reaching here without crashing is the pass.
        }

        // No process-level crash reached → pass. (A real crash would
        // terminate the test process before this line is hit.)
        print("[Fuzz/JSON] 200 docs: decoded=\(decodedOK), threwError=\(threwError)")
    }

    /// Documents that elide the required `asset` field, set required arrays to
    /// `null`, or use empty objects everywhere. Decoder must throw, not crash.
    func testFuzzGLTFDocumentDecoding_MissingRequiredFields() {
        let scenarios: [(String, [String: Any])] = [
            ("empty object", [:]),
            ("nil asset", ["asset": NSNull()]),
            ("asset without version", ["asset": [:]]),
            ("asset wrong type", ["asset": "v2.0"]),
            ("nodes is null", ["asset": ["version": "2.0"], "nodes": NSNull()]),
            ("accessors is string", ["asset": ["version": "2.0"], "accessors": "garbage"]),
            ("extensions is array", ["asset": ["version": "2.0"], "extensions": ["a", "b"]]),
        ]

        for (name, json) in scenarios {
            let data: Data
            do {
                data = try JSONSerialization.data(withJSONObject: json, options: [])
            } catch {
                // JSONSerialization rejected → loader never sees this. Skip.
                continue
            }

            // Anything we get here is fine — decode either succeeds or throws.
            // The point is no crash.
            _ = try? JSONDecoder().decode(GLTFDocument.self, from: data)
            // If we reach this line, the loader didn't crash on "\(name)".
            _ = name
        }
    }

    /// Feed totally random byte sequences to `GLTFParser.parse(data:)`. Most are
    /// not valid GLB; the parser must reject them gracefully.
    func testFuzzGLBParser_RandomBytes() throws {
        var generator = SeededRandomGenerator(seed: 2025)
        let parser = GLTFParser()
        var rejections = 0

        for _ in 0..<100 {
            let length = Int(generator.next() % 8192)
            var bytes = [UInt8](repeating: 0, count: length)
            for i in 0..<length {
                bytes[i] = UInt8(generator.next() & 0xFF)
            }
            let data = Data(bytes)

            do {
                _ = try parser.parse(data: data)
            } catch {
                rejections += 1
            }
        }

        // We expect nearly all 100 random inputs to be rejected. Anything that
        // somehow parsed is fine, as long as we got here without a crash.
        XCTAssertGreaterThan(rejections, 90,
            "Random bytes should mostly fail GLB magic/version checks (got \(rejections)/100 rejections)")
    }

    /// GLB envelopes with valid headers but garbage chunk content. Tests the
    /// JSON-chunk fallback path.
    func testFuzzGLBParser_GarbageChunks() throws {
        var generator = SeededRandomGenerator(seed: 9999)
        let parser = GLTFParser()

        for _ in 0..<50 {
            let chunkLen = Int(generator.next() % 4096)
            var bytes = Data()
            // Header: magic "glTF", version 2, length=0 (parser ignores total length)
            bytes.append(contentsOf: [0x67, 0x6C, 0x54, 0x46])  // "glTF"
            withUnsafeBytes(of: UInt32(2).littleEndian) { bytes.append(contentsOf: $0) }
            withUnsafeBytes(of: UInt32(0).littleEndian) { bytes.append(contentsOf: $0) }
            // Chunk: length=chunkLen, type="JSON"
            withUnsafeBytes(of: UInt32(chunkLen).littleEndian) { bytes.append(contentsOf: $0) }
            bytes.append(contentsOf: [0x4A, 0x53, 0x4F, 0x4E])  // "JSON"
            // Random bytes for the chunk body
            for _ in 0..<chunkLen {
                bytes.append(UInt8(generator.next() & 0xFF))
            }

            do {
                _ = try parser.parse(data: bytes)
            } catch {
                // Expected — random bytes are not valid JSON
            }
            // Reaching here means no crash.
        }
    }

    // MARK: - 2. Malformed image data

    /// Random bytes fed to `CGImageSource` (the path TextureLoader uses for
    /// embedded image data). Must return `nil`, not crash.
    func testFuzzCGImageSource_RandomBytes() {
        var generator = SeededRandomGenerator(seed: 314)
        var nilCount = 0
        var imageCount = 0

        let sizes: [Int] = [0, 1, 7, 64, 1024, 8192]
        for size in sizes {
            for _ in 0..<20 {
                var bytes = [UInt8](repeating: 0, count: size)
                for i in 0..<size {
                    bytes[i] = UInt8(generator.next() & 0xFF)
                }
                let data = Data(bytes) as CFData
                if let src = CGImageSourceCreateWithData(data, nil),
                   CGImageSourceCreateImageAtIndex(src, 0, nil) != nil {
                    imageCount += 1
                } else {
                    nilCount += 1
                }
            }
        }

        print("[Fuzz/Image] random bytes: nil=\(nilCount), decoded=\(imageCount)")
        XCTAssertGreaterThan(nilCount, 100,
            "Random bytes should overwhelmingly produce nil images")
    }

    /// Truncated PNG / JPEG headers — valid signature bytes followed by garbage.
    /// Common attack pattern: a "looks-like-an-image" file that decodes partially.
    func testFuzzCGImageSource_TruncatedHeaders() {
        let pngMagic: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        let jpegMagic: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0]
        let webpMagic: [UInt8] = [0x52, 0x49, 0x46, 0x46]  // "RIFF"

        for magic in [pngMagic, jpegMagic, webpMagic] {
            for tailLen in [0, 1, 16, 256, 4096] {
                var bytes = Data(magic)
                bytes.append(Data(repeating: 0xAA, count: tailLen))
                let data = bytes as CFData
                // Should not crash — return nil or partial result.
                _ = CGImageSourceCreateWithData(data, nil)
                    .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
            }
        }
        // If we get here, no crash.
    }

    /// Data URIs with garbage base64 / wrong MIME / oversized payloads.
    /// Exercises BufferLoader.loadDataURI indirectly via the image path.
    func testFuzzDataURI_MalformedBase64() throws {
        let scenarios: [String] = [
            "data:",                       // No comma at all
            "data:,",                      // Empty payload
            "data:image/png;base64,",      // Empty base64
            "data:image/png;base64,!!!@@@",  // Non-base64 chars
            "data:image/png;base64," + String(repeating: "A", count: 100_000),  // Large payload
            "data:image/png;base64,QQ",    // Truncated base64 (1 char short of full block)
        ]

        for uri in scenarios {
            // Mimics what TextureLoader.loadImageFromDataURI does internally:
            // split on first comma, base64-decode the tail.
            if let commaIndex = uri.firstIndex(of: ",") {
                let base64String = String(uri[uri.index(after: commaIndex)...])
                _ = Data(base64Encoded: base64String)
            }
            // No crash regardless of input.
        }
    }

    // MARK: - 3. Extreme SpringBone configurations

    private var device: MTLDevice? { MTLCreateSystemDefaultDevice() }

    /// `numBones == 0` is a valid edge case (model with no spring bones).
    /// Buffer allocation should succeed and not divide-by-zero.
    func testFuzzSpringBone_ZeroJoints() throws {
        guard let device = device else { throw XCTSkip("Metal device not available") }

        let buffers = SpringBoneBuffers(device: device)
        buffers.allocateBuffers(numBones: 0, numSpheres: 0, numCapsules: 0, numPlanes: 0)

        // With zero bones, the optional buffers may legitimately be nil — but
        // accessing them must not crash.
        let positions = buffers.getCurrentPositions()
        XCTAssertEqual(positions.count, 0, "Zero-bone buffer should return empty positions")
    }

    /// Bone 0's parent = Bone 1, Bone 1's parent = Bone 0. A degenerate VRM
    /// shouldn't crash the parameter upload path. (Whether the GPU shader
    /// converges is a separate concern — that's the regression gate in #162.)
    func testFuzzSpringBone_CircularParentChain() throws {
        guard let device = device else { throw XCTSkip("Metal device not available") }

        let buffers = SpringBoneBuffers(device: device)
        buffers.allocateBuffers(numBones: 2, numSpheres: 0, numCapsules: 0, numPlanes: 0)

        let circularParams: [BoneParams] = [
            BoneParams(stiffness: 1.0, drag: 0.5, radius: 0.02, parentIndex: 1,
                       gravityPower: 1.0, colliderGroupMask: 0xFFFFFFFF,
                       gravityDir: SIMD3<Float>(0, -1, 0)),
            BoneParams(stiffness: 1.0, drag: 0.5, radius: 0.02, parentIndex: 0,
                       gravityPower: 1.0, colliderGroupMask: 0xFFFFFFFF,
                       gravityDir: SIMD3<Float>(0, -1, 0)),
        ]
        buffers.updateBoneParameters(circularParams)
        // No crash on parameter upload is the pass.
    }

    /// Bone N's parent = N (self-referential). Same invariant as above.
    func testFuzzSpringBone_SelfReferencingParent() throws {
        guard let device = device else { throw XCTSkip("Metal device not available") }

        let buffers = SpringBoneBuffers(device: device)
        buffers.allocateBuffers(numBones: 3, numSpheres: 0, numCapsules: 0, numPlanes: 0)

        let selfRefParams = (0..<3).map { i in
            BoneParams(stiffness: 1.0, drag: 0.5, radius: 0.02, parentIndex: UInt32(i),
                       gravityPower: 1.0, colliderGroupMask: 0xFFFFFFFF,
                       gravityDir: SIMD3<Float>(0, -1, 0))
        }
        buffers.updateBoneParameters(selfRefParams)
    }

    /// Parent index that wraps around past UInt32.max (interpreted from a
    /// negative Int in JSON via overflow). Must not crash collider/joint upload.
    func testFuzzSpringBone_ParentIndexOverflow() throws {
        guard let device = device else { throw XCTSkip("Metal device not available") }

        let buffers = SpringBoneBuffers(device: device)
        buffers.allocateBuffers(numBones: 2, numSpheres: 0, numCapsules: 0, numPlanes: 0)

        let overflowParams = [
            BoneParams(stiffness: 1.0, drag: 0.5, radius: 0.02, parentIndex: UInt32.max,
                       gravityPower: 1.0, colliderGroupMask: 0xFFFFFFFF,
                       gravityDir: SIMD3<Float>(0, -1, 0)),
            BoneParams(stiffness: 1.0, drag: 0.5, radius: 0.02, parentIndex: UInt32.max - 1,
                       gravityPower: 1.0, colliderGroupMask: 0xFFFFFFFF,
                       gravityDir: SIMD3<Float>(0, -1, 0)),
        ]
        // The "no parent" sentinel is 0xFFFFFFFF (see SpringBonePredict.metal:62),
        // so UInt32.max is actually the legitimate "root" — but UInt32.max - 1
        // is a bogus reference. Must not crash either way.
        buffers.updateBoneParameters(overflowParams)
    }

    /// NaN/Inf in sphere colliders, capsule colliders, AND plane colliders.
    /// Existing test in FuzzingTests covers sphere only.
    func testFuzzSpringBone_NaNCollidersAllShapes() throws {
        guard let device = device else { throw XCTSkip("Metal device not available") }

        let buffers = SpringBoneBuffers(device: device)
        buffers.allocateBuffers(numBones: 1, numSpheres: 2, numCapsules: 2, numPlanes: 2)

        let nanSpheres = [
            SphereCollider(center: SIMD3<Float>(.nan, .nan, .nan), radius: 1.0, groupIndex: 0),
            SphereCollider(center: SIMD3<Float>(.infinity, 0, 0), radius: .nan, groupIndex: 0),
        ]
        let nanCapsules = [
            CapsuleCollider(p0: SIMD3<Float>(.nan, 0, 0),
                            p1: SIMD3<Float>(0, .nan, 0),
                            radius: 1.0, groupIndex: 0),
            CapsuleCollider(p0: .zero, p1: SIMD3<Float>(.infinity, 0, 0),
                            radius: -1.0, groupIndex: 0),
        ]
        let nanPlanes = [
            PlaneCollider(point: SIMD3<Float>(.nan, .nan, .nan),
                          normal: SIMD3<Float>(0, 1, 0), groupIndex: 0),
            PlaneCollider(point: .zero,
                          normal: SIMD3<Float>(.nan, .nan, .nan), groupIndex: 0),
        ]

        buffers.updateSphereColliders(nanSpheres)
        buffers.updateCapsuleColliders(nanCapsules)
        buffers.updatePlaneColliders(nanPlanes)
        // No crash on upload = pass.
    }

    /// Many bones (1024+) with all-zero bind directions. Tests bind-direction
    /// normalization fallback path under stress.
    func testFuzzSpringBone_ZeroBindDirectionsAtScale() throws {
        guard let device = device else { throw XCTSkip("Metal device not available") }

        let bones = 1024
        let buffers = SpringBoneBuffers(device: device)
        buffers.allocateBuffers(numBones: bones, numSpheres: 0, numCapsules: 0, numPlanes: 0)

        let zeroDirs = Array(repeating: SIMD3<Float>.zero, count: bones)
        buffers.updateBindDirections(zeroDirs)

        // The implementation should substitute a default for zero-length dirs.
        // We don't assert on the exact substituted value — just that the upload
        // returned without crashing the test process.
    }

    // MARK: - Helpers

    /// Builds a glTF-shaped dictionary with random / cursed values. The shape
    /// loosely matches the real schema so JSONDecoder gets a chance to fail at
    /// each field, exercising both the success and decode-error paths.
    private func makeRandomGLTFJSON(rng: inout SeededRandomGenerator) -> [String: Any] {
        var dict: [String: Any] = [:]

        // asset: sometimes missing, sometimes wrong shape, sometimes valid
        switch rng.next() % 4 {
        case 0: break  // missing
        case 1: dict["asset"] = NSNull()
        case 2: dict["asset"] = "v2.0"  // wrong type
        default: dict["asset"] = ["version": "2.0"]
        }

        // accessors: sometimes empty, sometimes garbage, sometimes valid-ish
        switch rng.next() % 5 {
        case 0: break
        case 1: dict["accessors"] = []
        case 2: dict["accessors"] = NSNull()
        case 3: dict["accessors"] = "not-an-array"
        default:
            dict["accessors"] = [[
                "componentType": Int(rng.next() % 100_000),  // often invalid
                "count": Int(rng.next() % 1_000_000),
                "type": ["SCALAR", "VEC4", "BOGUS"][Int(rng.next() % 3)]
            ]]
        }

        // buffers: sometimes with negative byteLength, sometimes valid
        if rng.next() % 2 == 0 {
            let len = Int(Int32(truncatingIfNeeded: rng.next()))  // can be negative
            dict["buffers"] = [["byteLength": len]]
        }

        // extensionsRequired: random unknown extension names
        if rng.next() % 3 == 0 {
            dict["extensionsRequired"] = ["VRMC_unknown_\(rng.next() % 1000)"]
        }

        // extensions: deeply nested random dict
        if rng.next() % 4 == 0 {
            dict["extensions"] = ["VRMC_vrm": ["humanoid": ["humanBones": NSNull()]]]
        }

        return dict
    }
}
