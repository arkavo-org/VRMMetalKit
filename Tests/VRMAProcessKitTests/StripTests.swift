import XCTest
@testable import VRMAProcessKit

final class StripTests: XCTestCase {
    func testHipsXZStripZeroesGroundMotionKeepsBob() throws {
        var container = try GLBContainer(data: try SyntheticVRMA.make(vx: 1.5))
        var editor = VRMAClipEditor(container: container)
        try editor.stripHipsXZ()
        container = editor.container
        let inspector = try VRMAClipInspector(container: container)
        XCTAssertEqual(try inspector.meanHipsXZSpeed(), 0, accuracy: 1e-4)
        // Y bob survives: output VEC3 ys must not all be equal
        let (_, out) = try inspector.hipsTranslationSampler()
        let xyz = try inspector.floats(accessor: out)
        let ys = stride(from: 1, to: xyz.count, by: 3).map { xyz[$0] }
        XCTAssertGreaterThan(ys.max()! - ys.min()!, 0.01)
        // XZ are rebased to first-frame values, not merely zeroed: x[0] == x[k]
        let xs = stride(from: 0, to: xyz.count, by: 3).map { xyz[$0] }
        XCTAssertEqual(xs.max()! - xs.min()!, 0, accuracy: 1e-5)
        // Pin the rebase: first-frame value is 0.1 (not zero), 0.05 for Z
        XCTAssertEqual(xs[0], 0.1, accuracy: 1e-5, "X rebased to first-frame value, not zeroed")
        let zs = stride(from: 2, to: xyz.count, by: 3).map { xyz[$0] }
        XCTAssertEqual(zs[0], 0.05, accuracy: 1e-5, "Z rebased to first-frame value, not zeroed")
    }

    func testNonHumanoidChannelStripDropsHairKeepsLeg() throws {
        var editor = VRMAClipEditor(container: try GLBContainer(data: try SyntheticVRMA.make()))
        let dropped = try editor.stripNonHumanoidChannels()
        XCTAssertEqual(dropped, 1)
        let anim = (editor.container.json["animations"] as! [[String: Any]])[0]
        let channels = anim["channels"] as! [[String: Any]]
        XCTAssertEqual(channels.count, 2)  // hips translation + leg rotation remain
    }

    func testZeroCountHipsAccessorThrows() throws {
        var container = try GLBContainer(data: try SyntheticVRMA.make())
        var accessors = container.json["accessors"] as! [[String: Any]]
        accessors[1]["count"] = 0
        container.json["accessors"] = accessors
        var editor = VRMAClipEditor(container: container)
        XCTAssertThrowsError(try editor.stripHipsXZ())
    }
}
