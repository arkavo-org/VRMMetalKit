//
// Copyright 2025 Arkavo
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

import XCTest
@testable import VRMMetalKit

final class AudioVisemeTests: XCTestCase {
    private let sampleRate: Double = 48_000

    /// Two sine tones at the given formant frequencies, `amplitude` peak each.
    private func vowel(f1: Float, f2: Float, amplitude: Float = 0.3, count: Int = 2048) -> [Float] {
        (0..<count).map { i in
            let t = Float(i) / Float(sampleRate)
            return amplitude * (sin(2 * .pi * f1 * t) + 0.7 * sin(2 * .pi * f2 * t))
        }
    }

    // MARK: - Analyzer

    func testSilenceIsSilent() {
        let analyzer = AudioVisemeAnalyzer(sampleRate: sampleRate)
        let frame = analyzer.analyze([Float](repeating: 0, count: 1024))
        XCTAssertEqual(frame, .silent)
    }

    func testBelowNoiseGateIsSilent() {
        let analyzer = AudioVisemeAnalyzer(sampleRate: sampleRate)
        let frame = analyzer.analyze(vowel(f1: 730, f2: 1090, amplitude: 0.002))
        XCTAssertEqual(frame.volume, 0)
        XCTAssertNil(frame.dominant)
    }

    func testEachPrototypeVowelClassifiesToItsViseme() {
        let analyzer = AudioVisemeAnalyzer(sampleRate: sampleRate)
        for (viseme, proto) in AudioVisemeAnalyzer.formantPrototypes {
            let frame = analyzer.analyze(vowel(f1: proto.x, f2: proto.y))
            XCTAssertEqual(frame.dominant, viseme, "F1=\(proto.x) F2=\(proto.y) should read as \(viseme), got \(String(describing: frame.dominant)) f1=\(frame.f1 ?? -1) f2=\(frame.f2 ?? -1)")
            XCTAssertGreaterThan(frame.weights[viseme] ?? 0, 0.4, "\(viseme) should dominate its own prototype")
        }
    }

    func testFormantEstimateTracksInputTones() {
        let analyzer = AudioVisemeAnalyzer(sampleRate: sampleRate)
        let frame = analyzer.analyze(vowel(f1: 500, f2: 2000))
        XCTAssertEqual(frame.f1 ?? 0, 500, accuracy: 60)
        XCTAssertEqual(frame.f2 ?? 0, 2000, accuracy: 100)
    }

    func testWeightsSumToVolume() {
        let analyzer = AudioVisemeAnalyzer(sampleRate: sampleRate)
        let frame = analyzer.analyze(vowel(f1: 730, f2: 1090))
        let sum = frame.weights.values.reduce(0, +)
        XCTAssertEqual(sum, frame.volume, accuracy: 1e-4)
        XCTAssertGreaterThan(frame.volume, 0)
        XCTAssertLessThanOrEqual(frame.volume, 1)
    }

    func testLouderInputOpensMouthMore() {
        let analyzer = AudioVisemeAnalyzer(sampleRate: sampleRate)
        let quiet = analyzer.analyze(vowel(f1: 730, f2: 1090, amplitude: 0.03))
        let loud = analyzer.analyze(vowel(f1: 730, f2: 1090, amplitude: 0.3))
        XCTAssertGreaterThan(loud.volume, quiet.volume)
        XCTAssertEqual(loud.volume, 1, accuracy: 1e-4, "full-scale input should saturate at 1")
    }

    func testShortBuffersAreZeroPadded() {
        let analyzer = AudioVisemeAnalyzer(sampleRate: sampleRate)
        let frame = analyzer.analyze(vowel(f1: 270, f2: 2290, count: 256))
        XCTAssertNotNil(frame.dominant, "256 samples must still produce a classification")
    }

    // MARK: - Driver

    func testDriverWritesVisemeWeightsToController() {
        let driver = AudioVisemeDriver(sampleRate: sampleRate, smoothing: .none)
        let controller = VRMExpressionController()
        let frame = driver.update(samples: vowel(f1: 730, f2: 1090), controller: controller)

        XCTAssertEqual(frame.dominant, .aa)
        XCTAssertGreaterThan(controller.weight(for: .aa), 0.4)
        XCTAssertEqual(controller.weight(for: .aa), frame.weights[.aa] ?? -1, accuracy: 1e-5)
        XCTAssertLessThan(controller.weight(for: .ih), controller.weight(for: .aa))
    }

    func testDriverSilenceZeroesVisemesWithoutSmoothing() {
        let driver = AudioVisemeDriver(sampleRate: sampleRate, smoothing: .none)
        let controller = VRMExpressionController()
        driver.update(samples: vowel(f1: 730, f2: 1090), controller: controller)
        XCTAssertGreaterThan(controller.weight(for: .aa), 0)

        driver.update(samples: [Float](repeating: 0, count: 1024), controller: controller)
        for viseme in AudioVisemeAnalyzer.visemes {
            XCTAssertEqual(controller.weight(for: viseme), 0, "\(viseme) must close on silence")
        }
        XCTAssertEqual(driver.updateCount, 2)
        XCTAssertEqual(driver.silentUpdates, 1)
    }

    func testDriverSmoothingDecaysInsteadOfSnapping() {
        let driver = AudioVisemeDriver(sampleRate: sampleRate, smoothing: .smooth)
        let controller = VRMExpressionController()
        for _ in 0..<20 { driver.update(samples: vowel(f1: 730, f2: 1090), controller: controller) }
        let open = controller.weight(for: .aa)
        XCTAssertGreaterThan(open, 0.3)

        driver.update(samples: [Float](repeating: 0, count: 1024), controller: controller)
        let afterOne = controller.weight(for: .aa)
        XCTAssertGreaterThan(afterOne, 0, "smoothed viseme should decay, not snap to zero")
        XCTAssertLessThan(afterOne, open)
    }

    func testDriverAccumulatesSmallBuffersIntoWindow() {
        let driver = AudioVisemeDriver(sampleRate: sampleRate, smoothing: .none)
        let controller = VRMExpressionController()
        let tone = vowel(f1: 270, f2: 2290, count: 1024)
        for chunk in stride(from: 0, to: tone.count, by: 128) {
            driver.push(Array(tone[chunk..<min(chunk + 128, tone.count)]))
        }
        let frame = driver.apply(to: controller)
        XCTAssertEqual(frame.dominant, .ih)
    }

    func testDriverGainScalesWeights() {
        let driver = AudioVisemeDriver(sampleRate: sampleRate, smoothing: .none)
        let controller = VRMExpressionController()
        driver.gain = 0.5
        driver.update(samples: vowel(f1: 730, f2: 1090), controller: controller)
        let half = controller.weight(for: .aa)
        driver.gain = 1.0
        driver.update(samples: vowel(f1: 730, f2: 1090), controller: controller)
        XCTAssertEqual(half * 2, controller.weight(for: .aa), accuracy: 1e-4)
    }
}
