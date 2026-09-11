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

/// One analysed window of microphone audio expressed as VRM viseme weights.
public struct VisemeFrame: Sendable, Equatable {
    /// Gated, normalised loudness in `0...1`. Zero means below the noise gate.
    public var volume: Float
    /// Weights for the five VRM visemes (`aa`, `ih`, `ou`, `ee`, `oh`), already scaled by ``volume``.
    public var weights: [VRMExpressionPreset: Float]
    /// The viseme with the largest weight, or `nil` when silent.
    public var dominant: VRMExpressionPreset?
    /// First-formant estimate in Hz, `nil` when silent.
    public var f1: Float?
    /// Second-formant estimate in Hz, `nil` when silent.
    public var f2: Float?

    /// A silent frame: zero volume, zero weights.
    public static let silent = VisemeFrame(volume: 0, weights: [:], dominant: nil, f1: nil, f2: nil)

    public init(volume: Float, weights: [VRMExpressionPreset: Float], dominant: VRMExpressionPreset?, f1: Float?, f2: Float?) {
        self.volume = volume
        self.weights = weights
        self.dominant = dominant
        self.f1 = f1
        self.f2 = f2
    }
}

/// Classifies a window of PCM audio into VRM viseme weights from a formant estimate.
///
/// ## Discussion
/// The analyser estimates the first two vowel formants as energy-weighted
/// spectral centroids of two fixed bands, then scores the five VRM visemes
/// by their distance from canonical formant pairs in log-frequency space.
/// It is deterministic, allocation-free after construction, and has no
/// framework dependencies: the app owns the audio tap and hands over mono
/// `Float` samples. Accuracy is that of a formant heuristic, not a trained
/// model; it distinguishes open, closed, rounded, and spread vowels well
/// enough to keep a mouth alive in sync with speech.
///
/// Window size is fixed at construction. `analyze(_:)` uses the most
/// recent ``Config/windowSize`` samples and zero-pads shorter input, so
/// callers can pass whatever buffer size their tap delivers.
public final class AudioVisemeAnalyzer: @unchecked Sendable {

    public struct Config: Sendable, Equatable {
        /// Sample rate of the incoming PCM in Hz.
        public var sampleRate: Double
        /// Analysis window in samples. 1024 at 48 kHz is about 21 ms.
        public var windowSize: Int
        /// RMS amplitude below which the frame is treated as silence.
        public var noiseGate: Float
        /// RMS amplitude at which ``VisemeFrame/volume`` reaches 1.
        public var fullScaleRMS: Float
        /// Exponent applied to the normalised loudness; values below 1 open the mouth sooner on quiet speech.
        public var volumeCurve: Float
        /// Softmax sharpness for viseme scoring. Higher values pick a single viseme more decisively.
        public var sharpness: Float
        /// Frequency band searched for the first formant.
        public var f1Band: ClosedRange<Float>
        /// Frequency band searched for the second formant.
        public var f2Band: ClosedRange<Float>

        public init(
            sampleRate: Double,
            windowSize: Int = 1024,
            noiseGate: Float = 0.01,
            fullScaleRMS: Float = 0.15,
            volumeCurve: Float = 0.6,
            sharpness: Float = 5.0,
            f1Band: ClosedRange<Float> = 150...800,
            f2Band: ClosedRange<Float> = 800...3500
        ) {
            self.sampleRate = sampleRate
            self.windowSize = windowSize
            self.noiseGate = noiseGate
            self.fullScaleRMS = fullScaleRMS
            self.volumeCurve = volumeCurve
            self.sharpness = sharpness
            self.f1Band = f1Band
            self.f2Band = f2Band
        }
    }

    /// Canonical (F1, F2) pairs in Hz for the five VRM visemes.
    public static let formantPrototypes: [VRMExpressionPreset: SIMD2<Float>] = [
        .aa: SIMD2<Float>(730, 1090),
        .ih: SIMD2<Float>(270, 2290),
        .ou: SIMD2<Float>(300, 870),
        .ee: SIMD2<Float>(530, 1840),
        .oh: SIMD2<Float>(570, 840)
    ]

    /// The five visemes this analyser emits.
    public static let visemes: [VRMExpressionPreset] = [.aa, .ih, .ou, .ee, .oh]

    public let config: Config

    private let window: [Float]
    private let binFrequencies: [Float]
    private let cosTable: [Float]
    private let sinTable: [Float]
    private let f1Bins: Range<Int>
    private let f2Bins: Range<Int>

    public init(config: Config) {
        precondition(config.windowSize >= 64, "windowSize must be at least 64 samples")
        precondition(config.sampleRate > 0, "sampleRate must be positive")
        self.config = config

        let n = config.windowSize
        window = (0..<n).map { i in 0.5 - 0.5 * cos(2 * Float.pi * Float(i) / Float(n - 1)) }

        let binHz = Float(config.sampleRate) / Float(n)
        let maxHz = max(config.f1Band.upperBound, config.f2Band.upperBound)
        let binCount = min(n / 2, Int((maxHz / binHz).rounded(.up)) + 1)
        let frequencies = (0..<binCount).map { Float($0) * binHz }
        binFrequencies = frequencies

        var cosT = [Float](repeating: 0, count: binCount * n)
        var sinT = [Float](repeating: 0, count: binCount * n)
        for k in 0..<binCount {
            for i in 0..<n {
                let phase = 2 * Float.pi * Float(k * i) / Float(n)
                cosT[k * n + i] = cos(phase)
                sinT[k * n + i] = sin(phase)
            }
        }
        cosTable = cosT
        sinTable = sinT

        func bins(for band: ClosedRange<Float>) -> Range<Int> {
            let lo = frequencies.firstIndex { $0 >= band.lowerBound } ?? binCount
            let hi = frequencies.lastIndex { $0 <= band.upperBound }.map { $0 + 1 } ?? lo
            return lo..<max(lo, hi)
        }
        f1Bins = bins(for: config.f1Band)
        f2Bins = bins(for: config.f2Band)
    }

    /// Convenience initialiser with default tuning for the given sample rate.
    public convenience init(sampleRate: Double) {
        self.init(config: Config(sampleRate: sampleRate))
    }

    /// Analyses the most recent window of `samples`.
    public func analyze(_ samples: [Float]) -> VisemeFrame {
        samples.withUnsafeBufferPointer { analyze($0) }
    }

    /// Analyses the most recent window of `samples` without copying.
    public func analyze(_ samples: UnsafeBufferPointer<Float>) -> VisemeFrame {
        let n = config.windowSize
        let count = samples.count
        guard count > 0 else { return .silent }

        // Most recent `n` samples, zero-padded at the front when short.
        let offset = max(0, count - n)
        let used = count - offset
        var frame = [Float](repeating: 0, count: n)
        var sumSquares: Float = 0
        for i in 0..<used {
            let s = samples[offset + i]
            sumSquares += s * s
            frame[n - used + i] = s * window[n - used + i]
        }
        let rms = (sumSquares / Float(used)).squareRoot()
        guard rms > config.noiseGate else { return .silent }

        let normalised = min(1, (rms - config.noiseGate) / max(1e-6, config.fullScaleRMS - config.noiseGate))
        let volume = pow(normalised, config.volumeCurve)

        let binCount = binFrequencies.count
        var power = [Float](repeating: 0, count: binCount)
        frame.withUnsafeBufferPointer { f in
            cosTable.withUnsafeBufferPointer { c in
                sinTable.withUnsafeBufferPointer { s in
                    for k in 0..<binCount {
                        var re: Float = 0
                        var im: Float = 0
                        let base = k * n
                        for i in 0..<n {
                            re += f[i] * c[base + i]
                            im -= f[i] * s[base + i]
                        }
                        power[k] = re * re + im * im
                    }
                }
            }
        }

        guard let f1 = centroid(power, bins: f1Bins), let f2 = centroid(power, bins: f2Bins) else {
            return VisemeFrame(volume: volume, weights: [:], dominant: nil, f1: nil, f2: nil)
        }

        var scores: [VRMExpressionPreset: Float] = [:]
        var maxScore = -Float.greatestFiniteMagnitude
        for viseme in Self.visemes {
            let proto = Self.formantPrototypes[viseme]!
            let d1 = log2(f1 / proto.x)
            let d2 = log2(f2 / proto.y)
            let score = -config.sharpness * (d1 * d1 + d2 * d2).squareRoot()
            scores[viseme] = score
            maxScore = max(maxScore, score)
        }
        var total: Float = 0
        for viseme in Self.visemes {
            let e = exp(scores[viseme]! - maxScore)
            scores[viseme] = e
            total += e
        }

        var weights: [VRMExpressionPreset: Float] = [:]
        var dominant: VRMExpressionPreset?
        var best: Float = 0
        for viseme in Self.visemes {
            let w = scores[viseme]! / total * volume
            weights[viseme] = w
            if w > best {
                best = w
                dominant = viseme
            }
        }
        return VisemeFrame(volume: volume, weights: weights, dominant: dominant, f1: f1, f2: f2)
    }

    private func centroid(_ power: [Float], bins: Range<Int>) -> Float? {
        var weighted: Float = 0
        var total: Float = 0
        for k in bins {
            weighted += power[k] * binFrequencies[k]
            total += power[k]
        }
        guard total > 1e-12 else { return nil }
        return weighted / total
    }
}
