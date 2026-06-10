import XCTest
@testable import VRMMetalKit

final class LocomotionBlendMathTests: XCTestCase {
    let math = LocomotionBlendMath(walkStrideSpeed: 1.5)

    func testWeightsSumToOneAndAreMonotonic() {
        var lastWalk: Float = -1
        for i in 0...100 {
            let speed = Float(i) / 100 * 3.0
            let b = math.blend(forSpeed: speed)
            XCTAssertEqual(b.idleWeight + b.walkWeight, 1.0, accuracy: 1e-5)
            XCTAssertGreaterThanOrEqual(b.walkWeight, lastWalk - 1e-6, "walk weight monotonic in speed")
            lastWalk = b.walkWeight
        }
    }

    func testRateClampBounds() {
        for i in 0...300 {
            let b = math.blend(forSpeed: Float(i) / 100 * 3.0)
            XCTAssertGreaterThanOrEqual(b.walkRate, LocomotionBlendMath.minRate - 1e-6)
            XCTAssertLessThanOrEqual(b.walkRate, LocomotionBlendMath.maxRate + 1e-6)
        }
    }

    func testLowSpeedUsesWeightNotRate() {
        let b = math.blend(forSpeed: 0.5)
        XCTAssertEqual(b.walkRate, 1.0, accuracy: 0.05)
        XCTAssertLessThan(b.walkWeight, 1.0)
    }

    func testAtStrideSpeedFullWalkAuthoredRate() {
        let b = math.blend(forSpeed: 1.5)
        XCTAssertEqual(b.walkWeight, 1.0, accuracy: 1e-4)
        XCTAssertEqual(b.walkRate, 1.0, accuracy: 1e-4)
    }

    func testAboveStrideSpeedRateScalesUpToClamp() {
        XCTAssertEqual(math.blend(forSpeed: 1.8).walkRate, 1.2, accuracy: 1e-3)
        XCTAssertEqual(math.blend(forSpeed: 3.0).walkRate, LocomotionBlendMath.maxRate, accuracy: 1e-4)
    }

    func testZeroSpeedIsPureIdle() {
        let b = math.blend(forSpeed: 0)
        XCTAssertEqual(b.idleWeight, 1.0)
        XCTAssertEqual(b.walkWeight, 0.0)
    }

    func testDeterminism() {
        for _ in 0..<3 {
            let a = math.blend(forSpeed: 1.2345)
            let b = math.blend(forSpeed: 1.2345)
            XCTAssertEqual(a.walkWeight, b.walkWeight)
            XCTAssertEqual(a.walkRate, b.walkRate)
        }
    }
}
