import XCTest
@testable import VRMAProcessKit

final class LocomotionIngestTests: XCTestCase {
    func testWalkModeRefusesStationaryClip() throws {
        XCTAssertThrowsError(try LocomotionIngest.process(glb: try SyntheticVRMA.make(vx: 0.0), mode: .walk)) { error in
            guard case LocomotionIngest.IngestError.walkClipMeasuresStationary = error else {
                return XCTFail("expected walkClipMeasuresStationary, got \(error)")
            }
        }
    }

    func testWalkPipelineSinglePassOrder() throws {
        let out = try LocomotionIngest.process(glb: try SyntheticVRMA.make(vx: 1.5), mode: .auto)
        let container = try GLBContainer(data: out)
        let meta = try XCTUnwrap(LocomotionExtras.read(from: container))
        // measured BEFORE strip:
        XCTAssertEqual(meta.strideSpeed, 1.5, accuracy: 0.05)
        XCTAssertTrue(meta.inPlace)
        XCTAssertEqual(meta.sourceHipsHeight, 0.85, accuracy: 0.001)
        // stripped AFTER measure:
        XCTAssertEqual(try VRMAClipInspector(container: container).meanHipsXZSpeed(), 0, accuracy: 1e-3)
    }

    func testIdleAutoDetectionWritesExplicitZero() throws {
        let out = try LocomotionIngest.process(glb: try SyntheticVRMA.make(vx: 0.0), mode: .auto)
        let meta = try XCTUnwrap(LocomotionExtras.read(from: try GLBContainer(data: out)))
        XCTAssertEqual(meta.strideSpeed, 0)
    }

    func testStrideOverrideStampsAuthoredValueOnInPlaceWalk() throws {
        // The common case for licensed packs: an already-in-place walk
        // (hips travel ~0) with a known authored stride speed.
        let out = try LocomotionIngest.process(glb: try SyntheticVRMA.make(vx: 0.0), mode: .walk, strideOverride: 1.4)
        let meta = try XCTUnwrap(LocomotionExtras.read(from: try GLBContainer(data: out)))
        XCTAssertEqual(meta.strideSpeed, 1.4, accuracy: 1e-5)
        XCTAssertTrue(meta.inPlace)
    }

    func testNonFiniteStrideOverrideThrows() {
        XCTAssertThrowsError(try LocomotionIngest.process(glb: try! SyntheticVRMA.make(vx: 0.0), mode: .walk, strideOverride: .infinity))
        XCTAssertThrowsError(try LocomotionIngest.process(glb: try! SyntheticVRMA.make(vx: 0.0), mode: .walk, strideOverride: .nan))
    }

    func testStrideOverrideWithIdleModeThrows() {
        XCTAssertThrowsError(try LocomotionIngest.process(glb: try! SyntheticVRMA.make(vx: 0.0), mode: .idle, strideOverride: 1.4))
    }

    func testStrideOverrideMustBePositive() {
        XCTAssertThrowsError(try LocomotionIngest.process(glb: try! SyntheticVRMA.make(vx: 0.0), mode: .walk, strideOverride: 0))
    }

    func testForcedIdleModeOverridesMeasurement() throws {
        let out = try LocomotionIngest.process(glb: try SyntheticVRMA.make(vx: 1.5), mode: .idle)
        let meta = try XCTUnwrap(LocomotionExtras.read(from: try GLBContainer(data: out)))
        XCTAssertEqual(meta.strideSpeed, 0)
    }
}
