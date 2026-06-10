import XCTest
@testable import VRMAProcessKit

final class GLBContainerTests: XCTestCase {
    func makeMinimalGLB() throws -> Data {
        let json: [String: Any] = ["asset": ["version": "2.0"], "animations": []]
        let bin = Data([1, 2, 3, 4, 5, 6, 7, 8])
        var glb = GLBContainer(json: json, bin: bin)
        return try glb.serialize()
    }

    func testRoundTripPreservesJSONAndBin() throws {
        let data = try makeMinimalGLB()
        var container = try GLBContainer(data: data)
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
}
