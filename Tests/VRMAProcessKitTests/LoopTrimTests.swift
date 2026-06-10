import XCTest
@testable import VRMAProcessKit

final class LoopTrimTests: XCTestCase {
    func testTrimProducesLoopContinuousClip() throws {
        var editor = VRMAClipEditor(container: try GLBContainer(data: try SyntheticVRMA.make(duration: 3.0)))
        try editor.stripNonHumanoidChannels()
        try editor.loopTrim()
        let inspector = try VRMAClipInspector(container: editor.container)
        // first/last leg-rotation keys nearly identical after trim
        let anim = (editor.container.json["animations"] as! [[String: Any]])[0]
        let samplers = anim["samplers"] as! [[String: Any]]
        let channels = anim["channels"] as! [[String: Any]]
        let legCh = channels.first { ($0["target"] as! [String: Any])["path"] as! String == "rotation" }!
        let s = samplers[legCh["sampler"] as! Int]
        let quats = try inspector.floats(accessor: s["output"] as! Int)
        let first = Array(quats.prefix(4)), last = Array(quats.suffix(4))
        let dot = abs(zip(first, last).map(*).reduce(0, +))
        XCTAssertGreaterThan(dot, 0.9999, "loop seam should be pose-continuous")
        // times rebased to 0
        let times = try inspector.floats(accessor: s["input"] as! Int)
        XCTAssertEqual(times.first!, 0, accuracy: 1e-6)
    }

    func testTrimKeepsAtLeast60PercentDuration() throws {
        var editor = VRMAClipEditor(container: try GLBContainer(data: try SyntheticVRMA.make(duration: 3.0)))
        try editor.stripNonHumanoidChannels()
        try editor.loopTrim()
        let inspector = try VRMAClipInspector(container: editor.container)
        let (inputAcc, _) = try inspector.hipsTranslationSampler()
        let times = try inspector.floats(accessor: inputAcc)
        XCTAssertGreaterThanOrEqual(times.last!, 3.0 * 0.6 - 0.2)
    }
}
