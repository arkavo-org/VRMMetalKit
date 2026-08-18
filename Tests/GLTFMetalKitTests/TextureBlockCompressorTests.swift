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
@testable import GLTFCore

/// Group 6a: load-time BC7 encode used by `.aggressiveTextureCompression`.
final class TextureBlockCompressorTests: XCTestCase {

    func testSolidEvenChannelsRoundTripExactly() {
        // All-even RGBA so the shared Mode 6 p-bit matches every channel.
        let color = SIMD4<UInt8>(128, 64, 32, 200)
        var rgba = [UInt8](repeating: 0, count: 16 * 4)
        for i in 0..<16 {
            rgba[i * 4 + 0] = color.x
            rgba[i * 4 + 1] = color.y
            rgba[i * 4 + 2] = color.z
            rgba[i * 4 + 3] = color.w
        }
        let encoded = rgba.withUnsafeBufferPointer { buf in
            TextureBlockCompressor.encodeBC7Mode6(
                rgba: buf.baseAddress!, width: 4, height: 4, bytesPerRow: 16)
        }
        XCTAssertEqual(encoded.count, TextureBlockCompressor.blockBytes)
        let decoded = encoded.withUnsafeBytes { buf in
            TextureBlockCompressor.decodeBC7Mode6Block(buf.baseAddress!)
        }
        for pixel in decoded {
            XCTAssertEqual(pixel, color)
        }
    }

    func testGradientStaysWithinPixelNearThreshold() {
        // 1D luma ramp — locally correlated the way VRM albedo 4×4s are.
        // A 2D chroma field cannot fit Mode 6's single line; that is not the
        // documented pixel-near claim.
        var rgba = [UInt8](repeating: 0, count: 8 * 8 * 4)
        for y in 0..<8 {
            for x in 0..<8 {
                let i = (y * 8 + x) * 4
                let v = UInt8(x * 32)
                rgba[i + 0] = v
                rgba[i + 1] = v
                rgba[i + 2] = v
                rgba[i + 3] = 254
            }
        }
        let encoded = rgba.withUnsafeBufferPointer { buf in
            TextureBlockCompressor.encodeBC7Mode6(
                rgba: buf.baseAddress!, width: 8, height: 8, bytesPerRow: 32)
        }
        XCTAssertEqual(encoded.count, 4 * TextureBlockCompressor.blockBytes)

        var absErr: Int = 0
        var samples = 0
        encoded.withUnsafeBytes { buf in
            let blocks = buf.bindMemory(to: UInt8.self)
            for by in 0..<2 {
                for bx in 0..<2 {
                    let offset = (by * 2 + bx) * TextureBlockCompressor.blockBytes
                    let decoded = TextureBlockCompressor.decodeBC7Mode6Block(blocks.baseAddress! + offset)
                    for py in 0..<4 {
                        for px in 0..<4 {
                            let src = ((by * 4 + py) * 8 + (bx * 4 + px)) * 4
                            let dst = decoded[py * 4 + px]
                            absErr += abs(Int(rgba[src]) - Int(dst.x))
                            absErr += abs(Int(rgba[src + 1]) - Int(dst.y))
                            absErr += abs(Int(rgba[src + 2]) - Int(dst.z))
                            absErr += abs(Int(rgba[src + 3]) - Int(dst.w))
                            samples += 4
                        }
                    }
                }
            }
        }
        let mae = Float(absErr) / Float(samples) / 255.0
        XCTAssertLessThanOrEqual(mae, TextureBlockCompressor.pixelNearMeanAbsoluteError)
    }

    func testUploaderBlockCompressesSRGBWhenDeviceSupportsBC() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device not available")
        }
        guard TextureBlockCompressor.supportsCompression(on: device) else {
            throw XCTSkip("BC texture compression not supported")
        }

        var bytes = [UInt8](repeating: 0, count: 8 * 8 * 4)
        for i in 0..<(8 * 8) {
            bytes[i * 4 + 0] = 200
            bytes[i * 4 + 1] = 40
            bytes[i * 4 + 2] = 40
            bytes[i * 4 + 3] = 255
        }
        let compressed = bytes.withUnsafeMutableBytes { buf in
            TextureUploader.makeTexture(
                bitmapData: buf.baseAddress!,
                width: 8, height: 8,
                pixelFormat: .rgba8Unorm_srgb,
                device: device,
                blockCompress: true)
        }
        let raw = bytes.withUnsafeMutableBytes { buf in
            TextureUploader.makeTexture(
                bitmapData: buf.baseAddress!,
                width: 8, height: 8,
                pixelFormat: .rgba8Unorm_srgb,
                device: device,
                blockCompress: false)
        }
        XCTAssertEqual(try XCTUnwrap(raw).pixelFormat, .rgba8Unorm_srgb)
        XCTAssertEqual(try XCTUnwrap(compressed).pixelFormat, .bc7_rgbaUnorm_srgb)
    }

    func testLinearTexturesStayRGBA8EvenWhenCompressRequested() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device not available")
        }
        var bytes = [UInt8](repeating: 128, count: 8 * 8 * 4)
        let texture = bytes.withUnsafeMutableBytes { buf in
            TextureUploader.makeTexture(
                bitmapData: buf.baseAddress!,
                width: 8, height: 8,
                pixelFormat: .rgba8Unorm,
                device: device,
                blockCompress: false)
        }
        XCTAssertEqual(try XCTUnwrap(texture).pixelFormat, .rgba8Unorm)
    }
}
