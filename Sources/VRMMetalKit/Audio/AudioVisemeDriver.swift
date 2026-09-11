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

import Foundation

/// Drives VRM viseme expressions from microphone PCM, the audio counterpart of ``ARKitFaceDriver``.
///
/// ## Discussion
/// Feed it whatever mono `Float` buffers the audio tap delivers; it keeps a
/// rolling window of the analyser's size, classifies the latest window with
/// ``AudioVisemeAnalyzer``, smooths each viseme through ``FilterManager``,
/// and writes the result to a ``VRMExpressionController``. Silence decays the
/// visemes to zero through the same filters, so a `.none` smoothing config
/// closes the mouth immediately and `.smooth` lets it relax.
///
/// The driver is safe to feed from an audio thread through `push(_:)` and
/// to apply from the animation thread through ``apply(to:)``; the combined
/// ``update(samples:controller:)`` does both and is intended for callers that
/// already marshal audio onto their animation thread.
public final class AudioVisemeDriver: @unchecked Sendable {

    public let analyzer: AudioVisemeAnalyzer
    public private(set) var smoothingConfig: SmoothingConfig

    /// Multiplier applied to every viseme weight before smoothing (1 = analyser output).
    public var gain: Float = 1.0

    public private(set) var lastFrame: VisemeFrame = .silent
    public private(set) var updateCount: Int = 0
    public private(set) var silentUpdates: Int = 0

    private let lock = NSLock()
    private var ring: [Float]
    private var ringHead = 0
    private var ringFilled = 0
    private var filterManager: FilterManager

    public init(analyzer: AudioVisemeAnalyzer, smoothing: SmoothingConfig = .default) {
        self.analyzer = analyzer
        self.smoothingConfig = smoothing
        self.filterManager = FilterManager(config: smoothing)
        self.ring = [Float](repeating: 0, count: analyzer.config.windowSize)
    }

    public convenience init(sampleRate: Double, smoothing: SmoothingConfig = .default) {
        self.init(analyzer: AudioVisemeAnalyzer(sampleRate: sampleRate), smoothing: smoothing)
    }

    // MARK: - Input

    /// Appends samples to the rolling window. Safe to call from the audio thread.
    public func push(_ samples: [Float]) {
        samples.withUnsafeBufferPointer { push($0) }
    }

    /// Appends samples to the rolling window without copying. Safe to call from the audio thread.
    public func push(_ samples: UnsafeBufferPointer<Float>) {
        lock.lock()
        defer { lock.unlock() }
        let n = ring.count
        let count = samples.count
        let start = max(0, count - n)
        for i in start..<count {
            ring[ringHead] = samples[i]
            ringHead = (ringHead + 1) % n
        }
        ringFilled = min(n, ringFilled + (count - start))
    }

    // MARK: - Output

    /// Analyses the current window, smooths, and writes viseme weights to `controller`.
    @discardableResult
    public func apply(to controller: VRMExpressionController) -> VisemeFrame {
        let frame = analyzeWindow()
        let smoothed = smooth(frame.weights)
        applyWeights(smoothed, to: controller)
        return frame
    }

    /// Pushes `samples` and applies the result to `controller` in one call.
    @discardableResult
    public func update(samples: [Float], controller: VRMExpressionController) -> VisemeFrame {
        push(samples)
        return apply(to: controller)
    }

    /// Analyses the current window and returns smoothed weights without touching a controller.
    public func smoothedWeights() -> [VRMExpressionPreset: Float] {
        smooth(analyzeWindow().weights)
    }

    /// Writes viseme weights to the controller. Visemes absent from `weights` are set to zero.
    public func applyWeights(_ weights: [VRMExpressionPreset: Float], to controller: VRMExpressionController) {
        for viseme in AudioVisemeAnalyzer.visemes {
            controller.setExpressionWeight(viseme, weight: weights[viseme] ?? 0)
        }
    }

    // MARK: - Filters

    public func resetFilters() {
        lock.lock()
        defer { lock.unlock() }
        filterManager.resetAll()
        lastFrame = .silent
    }

    public func updateSmoothingConfig(_ config: SmoothingConfig) {
        lock.lock()
        defer { lock.unlock() }
        smoothingConfig = config
        filterManager = FilterManager(config: config)
    }

    // MARK: - Internals

    private func analyzeWindow() -> VisemeFrame {
        lock.lock()
        defer { lock.unlock() }
        updateCount += 1
        guard ringFilled > 0 else {
            silentUpdates += 1
            lastFrame = .silent
            return .silent
        }
        let n = ring.count
        var ordered = [Float](repeating: 0, count: n)
        let start = (ringHead - ringFilled + n) % n
        for i in 0..<ringFilled {
            ordered[n - ringFilled + i] = ring[(start + i) % n]
        }
        let frame = analyzer.analyze(ordered)
        if frame.volume == 0 { silentUpdates += 1 }
        lastFrame = frame
        return frame
    }

    private func smooth(_ weights: [VRMExpressionPreset: Float]) -> [VRMExpressionPreset: Float] {
        lock.lock()
        defer { lock.unlock() }
        var out: [VRMExpressionPreset: Float] = [:]
        for viseme in AudioVisemeAnalyzer.visemes {
            let raw = min(1, (weights[viseme] ?? 0) * gain)
            out[viseme] = filterManager.update(key: viseme.rawValue, value: raw)
        }
        return out
    }
}
