import XCTest
@testable import VRMMetalKit

final class LocomotionMetadataTests: XCTestCase {
    /// Builds the smallest VRMA glb with extras.arkavo inline.
    func makeVRMA(withExtras: Bool) throws -> URL {
        var animation: [String: Any] = [
            "channels": [["sampler": 0, "target": ["node": 0, "path": "translation"]]],
            "samplers": [["input": 0, "output": 1, "interpolation": "LINEAR"]],
        ]
        if withExtras {
            animation["extras"] = ["arkavo": [
                "version": 1, "strideSpeed": 1.42, "inPlace": true, "sourceHipsHeight": 0.9,
            ]]
        }
        var bin = Data()
        let times: [Float] = [0, 1], vals: [Float] = [0, 0.9, 0, 0, 0.9, 0]
        times.withUnsafeBytes { bin.append(contentsOf: $0) }
        vals.withUnsafeBytes { bin.append(contentsOf: $0) }
        let json: [String: Any] = [
            "asset": ["version": "2.0"],
            "buffers": [["byteLength": bin.count]],
            "bufferViews": [
                ["buffer": 0, "byteOffset": 0, "byteLength": 8],
                ["buffer": 0, "byteOffset": 8, "byteLength": 24],
            ],
            "accessors": [
                ["bufferView": 0, "componentType": 5126, "count": 2, "type": "SCALAR", "min": [0], "max": [1]],
                ["bufferView": 1, "componentType": 5126, "count": 2, "type": "VEC3"],
            ],
            "nodes": [["name": "hips"]],
            "animations": [animation],
            "extensions": ["VRMC_vrm_animation": ["specVersion": "1.0",
                "humanoid": ["humanBones": ["hips": ["node": 0]]]]],
        ]
        var jsonData = try JSONSerialization.data(withJSONObject: json)
        while jsonData.count % 4 != 0 { jsonData.append(0x20) }
        while bin.count % 4 != 0 { bin.append(0) }
        var out = Data("glTF".utf8)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
        u32(2); u32(UInt32(12 + 8 + jsonData.count + 8 + bin.count))
        u32(UInt32(jsonData.count)); u32(0x4E4F534A); out.append(jsonData)
        u32(UInt32(bin.count)); u32(0x004E4942); out.append(bin)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("locometa-\(withExtras).vrma")
        try out.write(to: url)
        return url
    }

    func testParsesLocomotionExtras() throws {
        let clip = try VRMAnimationLoader.loadVRMA(from: try makeVRMA(withExtras: true), model: nil)
        let meta = try XCTUnwrap(clip.locomotion)
        XCTAssertEqual(meta.version, 1)
        XCTAssertEqual(meta.strideSpeed, 1.42, accuracy: 1e-5)
        XCTAssertTrue(meta.inPlace)
        XCTAssertEqual(meta.sourceHipsHeight, 0.9, accuracy: 1e-5)
    }

    func testAbsentExtrasGivesNil() throws {
        let clip = try VRMAnimationLoader.loadVRMA(from: try makeVRMA(withExtras: false), model: nil)
        XCTAssertNil(clip.locomotion)
    }

    func testUnknownVersionGivesNil() throws {
        let url = try makeVRMA(withExtras: true)
        // rewrite version to 2 by editing the file's JSON chunk
        var data = try Data(contentsOf: url)
        if let range = data.range(of: Data("\"version\":1".utf8)) {
            data.replaceSubrange(range, with: Data("\"version\":2".utf8))
        } else if let range = data.range(of: Data("\"version\" : 1".utf8)) {
            data.replaceSubrange(range, with: Data("\"version\" : 2".utf8))
        } else {
            throw XCTSkip("serialized JSON layout unexpected; adapt the byte patch")
        }
        let patched = FileManager.default.temporaryDirectory.appendingPathComponent("locometa-v2.vrma")
        try data.write(to: patched)
        let clip = try VRMAnimationLoader.loadVRMA(from: patched, model: nil)
        XCTAssertNil(clip.locomotion)
    }
}
