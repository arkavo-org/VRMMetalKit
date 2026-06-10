import XCTest
@testable import VRMAProcessKit

final class LoopTrimTests: XCTestCase {
    func testMixedTimelinesThrowInsteadOfCrashing() throws {
        var container = try GLBContainer(data: try SyntheticVRMA.make(duration: 3.0))
        // Give the leg-rotation sampler its own (shorter) timeline: clone input accessor with smaller count.
        var json = container.json
        var accessors = json["accessors"] as! [[String: Any]]
        var clone = accessors[0]
        clone["count"] = (accessors[0]["count"] as! Int) - 10
        accessors.append(clone)
        json["accessors"] = accessors
        var anims = json["animations"] as! [[String: Any]]
        var samplers = anims[0]["samplers"] as! [[String: Any]]
        samplers[1]["input"] = accessors.count - 1
        anims[0]["samplers"] = samplers
        json["animations"] = anims
        container.json = json
        var editor = VRMAClipEditor(container: container)
        try editor.stripNonHumanoidChannels()
        XCTAssertThrowsError(try editor.loopTrim())
    }

    func testOrphanedSamplersAreLeftUntouched() throws {
        var editor = VRMAClipEditor(container: try GLBContainer(data: try SyntheticVRMA.make(duration: 3.0)))
        try editor.stripNonHumanoidChannels()  // hair channel dropped, its sampler orphaned
        let samplersBefore = ((editor.container.json["animations"] as! [[String: Any]])[0]["samplers"] as! [[String: Any]])
        let orphanOutputBefore = samplersBefore[2]["output"] as! Int
        try editor.loopTrim()
        let samplersAfter = ((editor.container.json["animations"] as! [[String: Any]])[0]["samplers"] as! [[String: Any]])
        XCTAssertEqual(samplersAfter[2]["output"] as! Int, orphanOutputBefore, "orphaned sampler must not be rewritten")
    }

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
