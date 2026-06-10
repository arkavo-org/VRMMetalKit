import XCTest
@testable import VRMAProcessKit

final class StrideAndExtrasTests: XCTestCase {
    func testMeasuresConstantStrideSpeed() throws {
        let glb = try SyntheticVRMA.make(duration: 2.0, vx: 1.5)
        let container = try GLBContainer(data: glb)
        let inspector = try VRMAClipInspector(container: container)
        let speed = try inspector.meanHipsXZSpeed()
        XCTAssertEqual(speed, 1.5, accuracy: 0.05)
        XCTAssertEqual(try inspector.hipsRestHeight(), 0.85, accuracy: 0.001)
    }

    func testExtrasRoundTrip() throws {
        let glb = try SyntheticVRMA.make()
        var container = try GLBContainer(data: glb)
        let meta = LocomotionExtras(strideSpeed: 1.42, inPlace: true, sourceHipsHeight: 0.85)
        try meta.write(into: &container)
        let reparsed = try GLBContainer(data: try container.serialize())
        let read = try XCTUnwrap(LocomotionExtras.read(from: reparsed))
        XCTAssertEqual(read.version, 1)
        XCTAssertEqual(read.strideSpeed, 1.42, accuracy: 1e-5)
        XCTAssertTrue(read.inPlace)
    }

    func testAbsentExtrasReadsNil() throws {
        let container = try GLBContainer(data: try SyntheticVRMA.make())
        XCTAssertNil(LocomotionExtras.read(from: container))
    }

    // C1 — oversized count must throw instead of reading out-of-bounds memory
    func testOversizedAccessorCountThrowsInsteadOfOverreading() throws {
        var container = try GLBContainer(data: try SyntheticVRMA.make())
        var accessors = container.json["accessors"] as! [[String: Any]]
        accessors[1]["count"] = 100_000
        container.json["accessors"] = accessors
        let inspector = try VRMAClipInspector(container: container)
        XCTAssertThrowsError(try inspector.meanHipsXZSpeed())
    }

    // C2 — a cycle in the node hierarchy must throw instead of hanging
    func testNodeCycleThrowsInsteadOfHanging() throws {
        var container = try GLBContainer(data: try SyntheticVRMA.make())
        var nodes = container.json["nodes"] as! [[String: Any]]
        nodes[1]["children"] = [2, 0]  // hips claims Root as child → cycle Root→hips→Root
        container.json["nodes"] = nodes
        let inspector = try VRMAClipInspector(container: container)
        XCTAssertThrowsError(try inspector.hipsRestHeight())
    }

    // I1 — non-float componentType must throw instead of silently returning garbage
    func testNonFloatComponentTypeThrows() throws {
        var container = try GLBContainer(data: try SyntheticVRMA.make())
        var accessors = container.json["accessors"] as! [[String: Any]]
        accessors[1]["componentType"] = 5123  // ushort
        container.json["accessors"] = accessors
        let inspector = try VRMAClipInspector(container: container)
        XCTAssertThrowsError(try inspector.meanHipsXZSpeed())
    }

    // Zero-velocity clip sanity check
    func testZeroVelocityClipMeasuresZeroStride() throws {
        let container = try GLBContainer(data: try SyntheticVRMA.make(vx: 0.0))
        let inspector = try VRMAClipInspector(container: container)
        XCTAssertEqual(try inspector.meanHipsXZSpeed(), 0, accuracy: 1e-4)
    }

    // I3 — unknown version must read as nil
    func testUnknownExtrasVersionReadsNil() throws {
        var container = try GLBContainer(data: try SyntheticVRMA.make())
        var meta = LocomotionExtras(strideSpeed: 1.0, inPlace: true, sourceHipsHeight: 0.85)
        meta.version = 2
        try meta.write(into: &container)
        XCTAssertNil(LocomotionExtras.read(from: container))
    }
}
