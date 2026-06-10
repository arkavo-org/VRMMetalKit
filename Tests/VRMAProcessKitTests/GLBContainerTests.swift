import XCTest
@testable import VRMAProcessKit

final class GLBContainerTests: XCTestCase {
    func makeMinimalGLB() throws -> Data {
        let json: [String: Any] = ["asset": ["version": "2.0"], "animations": []]
        let bin = Data([1, 2, 3, 4, 5, 6, 7, 8])
        let glb = GLBContainer(json: json, bin: bin)
        return try glb.serialize()
    }

    func testRoundTripPreservesJSONAndBin() throws {
        let data = try makeMinimalGLB()
        let container = try GLBContainer(data: data)
        XCTAssertEqual((container.json["asset"] as? [String: Any])?["version"] as? String, "2.0")
        XCTAssertEqual(container.bin, Data([1, 2, 3, 4, 5, 6, 7, 8]))
        let re = try container.serialize()
        let reparsed = try GLBContainer(data: re)
        XCTAssertEqual(reparsed.bin, container.bin)
    }

    func testHeaderMagicAndLengthAreValid() throws {
        let data = try makeMinimalGLB()
        XCTAssertEqual(data.prefix(4), Data("glTF".utf8))
        let total = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self) }
        XCTAssertEqual(Int(total), data.count)
    }

    func testRejectsGarbage() {
        XCTAssertThrowsError(try GLBContainer(data: Data([0, 1, 2, 3])))
    }

    // FIX 2 — slice-safe init
    func testParsesDataSlice() throws {
        var prefixed = Data([0xFF, 0xFF, 0xFF, 0xFF])
        prefixed.append(try makeMinimalGLB())
        let slice = prefixed[4...]
        let container = try GLBContainer(data: slice)
        XCTAssertEqual(container.bin, Data([1, 2, 3, 4, 5, 6, 7, 8]))
    }

    // FIX 3 — honest byte-preservation contract tests
    func testSerializeParseSerializeIsIdempotent() throws {
        let first = try makeMinimalGLB()
        let second = try GLBContainer(data: first).serialize()
        XCTAssertEqual(first, second, "serialize→parse→serialize must be byte-stable")
    }

    func testUnalignedBinRoundTripPadsWithZeros() throws {
        let glb = GLBContainer(json: ["asset": ["version": "2.0"]], bin: Data([9, 9, 9, 9, 9, 9]))
        let reparsed = try GLBContainer(data: try glb.serialize())
        XCTAssertEqual(reparsed.bin, Data([9, 9, 9, 9, 9, 9, 0, 0]), "documented padding behavior")
    }

    func testNoBinChunkParsesToEmptyBin() throws {
        let glb = GLBContainer(json: ["asset": ["version": "2.0"]], bin: Data())
        let reparsed = try GLBContainer(data: try glb.serialize())
        XCTAssertTrue(reparsed.bin.isEmpty)
    }
}
