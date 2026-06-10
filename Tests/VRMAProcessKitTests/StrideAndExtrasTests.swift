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
}
