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

/// Detects Z-fighting by analyzing pixel color changes across multiple rendered frames.
/// Z-fighting causes pixels to flicker between two surfaces, creating a characteristic
/// alternating pattern that this detector identifies.
struct FlickerDetector {

    /// Result of flicker detection analysis.
    struct FlickerResult {
        /// Set of pixel indices that changed between frames
        let flickeringPixels: Set<Int>
        /// Total number of pixels analyzed
        let totalPixels: Int
        /// Flicker rate as a percentage (0-100)
        var flickerRate: Float {
            guard totalPixels > 0 else { return 0 }
            return Float(flickeringPixels.count) / Float(totalPixels) * 100.0
        }
        /// True if significant flickering was detected
        var hasSignificantFlicker: Bool {
            flickerRate > 1.0
        }
    }

    /// Detect flickering pixels by comparing consecutive frames.
    /// - Parameters:
    ///   - frames: Array of BGRA color data for each frame
    ///   - threshold: Minimum color difference to consider as flicker (0-255)
    /// - Returns: FlickerResult containing analysis
    static func detectFlicker(frames: [[UInt8]], threshold: UInt8 = 10) -> FlickerResult {
        guard frames.count >= 2 else {
            return FlickerResult(flickeringPixels: [], totalPixels: 0)
        }

        var flickeringPixels: Set<Int> = []
        let bytesPerPixel = 4
        let pixelCount = frames[0].count / bytesPerPixel

        for frameIndex in 1..<frames.count {
            let prevFrame = frames[frameIndex - 1]
            let currFrame = frames[frameIndex]

            guard prevFrame.count == currFrame.count else { continue }

            for pixel in 0..<pixelCount {
                let offset = pixel * bytesPerPixel

                let bDiff = abs(Int(currFrame[offset]) - Int(prevFrame[offset]))
                let gDiff = abs(Int(currFrame[offset + 1]) - Int(prevFrame[offset + 1]))
                let rDiff = abs(Int(currFrame[offset + 2]) - Int(prevFrame[offset + 2]))

                if rDiff > Int(threshold) || gDiff > Int(threshold) || bDiff > Int(threshold) {
                    flickeringPixels.insert(pixel)
                }
            }
        }

        return FlickerResult(flickeringPixels: flickeringPixels, totalPixels: pixelCount)
    }

    /// Detect alternating color patterns indicative of Z-fighting.
    /// Z-fighting typically causes pixels to alternate between two colors as the GPU
    /// non-deterministically chooses which surface to render.
    /// - Parameters:
    ///   - frames: Array of BGRA color data for each frame
    ///   - pixelIndex: Specific pixel to analyze
    ///   - tolerance: Color comparison tolerance
    /// - Returns: True if alternating pattern detected
    static func detectAlternatingPattern(
        frames: [[UInt8]],
        pixelIndex: Int,
        tolerance: UInt8 = 5
    ) -> Bool {
        guard frames.count >= 4 else { return false }

        let bytesPerPixel = 4
        let offset = pixelIndex * bytesPerPixel

        var pixelColors: [[UInt8]] = []
        for frame in frames {
            guard offset + 3 < frame.count else { return false }
            let color = Array(frame[offset..<(offset + bytesPerPixel)])
            pixelColors.append(color)
        }

        var alternations = 0
        for i in 2..<pixelColors.count {
            let prev2 = pixelColors[i - 2]
            let prev1 = pixelColors[i - 1]
            let curr = pixelColors[i]

            let matchesPrev2 = colorsSimilar(prev2, curr, tolerance: tolerance)
            let matchesPrev1 = colorsSimilar(prev1, curr, tolerance: tolerance)

            if matchesPrev2 && !matchesPrev1 {
                alternations += 1
            }
        }

        let ratio = Float(alternations) / Float(pixelColors.count - 2)
        return ratio > 0.5
    }

    /// Find pixels with alternating patterns across all pixels.
    /// - Parameters:
    ///   - frames: Array of BGRA color data for each frame
    ///   - tolerance: Color comparison tolerance
    /// - Returns: Set of pixel indices with alternating patterns
    static func findAlternatingPixels(
        frames: [[UInt8]],
        tolerance: UInt8 = 5
    ) -> Set<Int> {
        guard frames.count >= 4, let firstFrame = frames.first else {
            return []
        }

        let bytesPerPixel = 4
        let pixelCount = firstFrame.count / bytesPerPixel
        var alternatingPixels: Set<Int> = []

        for pixel in 0..<pixelCount {
            if detectAlternatingPattern(frames: frames, pixelIndex: pixel, tolerance: tolerance) {
                alternatingPixels.insert(pixel)
            }
        }

        return alternatingPixels
    }

    /// Analyze flicker in a specific region of the frame.
    /// - Parameters:
    ///   - frames: Array of BGRA color data for each frame
    ///   - x: Region start X
    ///   - y: Region start Y
    ///   - width: Region width
    ///   - height: Region height
    ///   - frameWidth: Full frame width
    ///   - threshold: Flicker threshold
    /// - Returns: FlickerResult for the specified region
    static func analyzeRegion(
        frames: [[UInt8]],
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        frameWidth: Int,
        threshold: UInt8 = 10
    ) -> FlickerResult {
        guard frames.count >= 2 else {
            return FlickerResult(flickeringPixels: [], totalPixels: 0)
        }

        var flickeringPixels: Set<Int> = []
        let bytesPerPixel = 4
        var regionPixelCount = 0

        for row in y..<(y + height) {
            for col in x..<(x + width) {
                let pixel = row * frameWidth + col
                regionPixelCount += 1

                for frameIndex in 1..<frames.count {
                    let prevFrame = frames[frameIndex - 1]
                    let currFrame = frames[frameIndex]

                    let offset = pixel * bytesPerPixel
                    guard offset + 3 < prevFrame.count, offset + 3 < currFrame.count else { continue }

                    let bDiff = abs(Int(currFrame[offset]) - Int(prevFrame[offset]))
                    let gDiff = abs(Int(currFrame[offset + 1]) - Int(prevFrame[offset + 1]))
                    let rDiff = abs(Int(currFrame[offset + 2]) - Int(prevFrame[offset + 2]))

                    if rDiff > Int(threshold) || gDiff > Int(threshold) || bDiff > Int(threshold) {
                        flickeringPixels.insert(pixel)
                        break
                    }
                }
            }
        }

        return FlickerResult(flickeringPixels: flickeringPixels, totalPixels: regionPixelCount)
    }

    // MARK: - Private Helpers

    private static func colorsSimilar(_ a: [UInt8], _ b: [UInt8], tolerance: UInt8) -> Bool {
        guard a.count >= 3 && b.count >= 3 else { return false }
        return abs(Int(a[0]) - Int(b[0])) <= Int(tolerance) &&
               abs(Int(a[1]) - Int(b[1])) <= Int(tolerance) &&
               abs(Int(a[2]) - Int(b[2])) <= Int(tolerance)
    }
}
