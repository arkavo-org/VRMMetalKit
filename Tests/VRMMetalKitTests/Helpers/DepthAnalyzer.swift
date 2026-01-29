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

/// Analyzes depth buffer values to detect Z-fighting risk areas.
/// Z-fighting occurs when multiple surfaces have nearly identical depth values,
/// causing the GPU to non-deterministically choose which surface to render.
struct DepthAnalyzer {

    /// A cluster of pixels with similar depth values.
    struct DepthCluster {
        let depth: Float
        let count: Int
        let pixelIndices: [Int]
    }

    /// Result of depth buffer analysis.
    struct DepthAnalysisResult {
        /// Clusters of depth values found
        let clusters: [DepthCluster]
        /// True if Z-fighting risk was detected
        let hasZFightingRisk: Bool
        /// Minimum depth value found (excluding background)
        let minDepth: Float
        /// Maximum depth value found
        let maxDepth: Float
        /// Number of non-background pixels
        let foregroundPixelCount: Int
    }

    /// Find clusters of nearly-identical depth values.
    /// High clustering indicates multiple surfaces at the same depth, which causes Z-fighting.
    /// - Parameters:
    ///   - depthValues: Array of depth values from the depth buffer
    ///   - clusterThreshold: Values within this range are considered "clustered"
    ///   - backgroundThreshold: Depth values below this are considered background (for reverse-Z)
    /// - Returns: Array of depth clusters sorted by count (largest first)
    static func findDepthClusters(
        depthValues: [Float],
        clusterThreshold: Float = 0.00001,
        backgroundThreshold: Float = 0.001
    ) -> [DepthCluster] {
        var clusterMap: [Int: [Int]] = [:]
        let bucketSize = clusterThreshold

        for (index, depth) in depthValues.enumerated() {
            guard depth > backgroundThreshold else { continue }

            let bucket = Int(depth / bucketSize)
            clusterMap[bucket, default: []].append(index)
        }

        return clusterMap.map { bucket, indices in
            DepthCluster(
                depth: Float(bucket) * bucketSize,
                count: indices.count,
                pixelIndices: indices
            )
        }.sorted { $0.count > $1.count }
    }

    /// Detect Z-fighting risk areas where multiple surfaces share nearly-identical depth.
    /// - Parameters:
    ///   - depthValues: Array of depth values from the depth buffer
    ///   - minClusterSize: Minimum pixels to be considered significant
    ///   - clusterProximityThreshold: Distance threshold for considering clusters "too close"
    /// - Returns: True if Z-fighting risk detected
    static func detectZFightingRisk(
        depthValues: [Float],
        minClusterSize: Int = 100,
        clusterProximityThreshold: Float = 0.0001
    ) -> Bool {
        let clusters = findDepthClusters(depthValues: depthValues)
        let significantClusters = clusters.filter { $0.count >= minClusterSize }

        for i in 0..<significantClusters.count {
            for j in (i + 1)..<significantClusters.count {
                let depthDiff = abs(significantClusters[i].depth - significantClusters[j].depth)
                if depthDiff < clusterProximityThreshold {
                    return true
                }
            }
        }

        return false
    }

    /// Analyze depth buffer and return comprehensive results.
    /// - Parameters:
    ///   - depthValues: Array of depth values from the depth buffer
    ///   - backgroundThreshold: Depth values below this are considered background
    /// - Returns: DepthAnalysisResult with clusters and statistics
    static func analyzeDepthBuffer(
        depthValues: [Float],
        backgroundThreshold: Float = 0.001
    ) -> DepthAnalysisResult {
        let foregroundValues = depthValues.filter { $0 > backgroundThreshold }
        let clusters = findDepthClusters(depthValues: depthValues)
        let hasRisk = detectZFightingRisk(depthValues: depthValues)

        let minDepth = foregroundValues.min() ?? 0
        let maxDepth = foregroundValues.max() ?? 0

        return DepthAnalysisResult(
            clusters: clusters,
            hasZFightingRisk: hasRisk,
            minDepth: minDepth,
            maxDepth: maxDepth,
            foregroundPixelCount: foregroundValues.count
        )
    }

    /// Calculate the theoretical depth precision at a given distance.
    /// - Parameters:
    ///   - distance: Distance from camera
    ///   - nearZ: Near plane distance
    ///   - farZ: Far plane distance
    ///   - depthBits: Number of depth buffer bits (typically 24 or 32)
    /// - Returns: Minimum resolvable depth difference at this distance
    static func calculateDepthPrecision(
        distance: Float,
        nearZ: Float,
        farZ: Float,
        depthBits: Int = 24
    ) -> Float {
        let ndcPrecision = 1.0 / Float(1 << depthBits)
        let precision = ndcPrecision * (farZ - nearZ) * distance * distance / (nearZ * farZ)
        return precision
    }

    /// Find pixels where two different depth values are too close together.
    /// This identifies exact locations where Z-fighting may occur.
    /// - Parameters:
    ///   - depthValues: Array of depth values
    ///   - width: Image width
    ///   - height: Image height
    ///   - precisionThreshold: Minimum depth difference to consider safe
    /// - Returns: Set of pixel indices at Z-fighting risk
    static func findZFightingRiskPixels(
        depthValues: [Float],
        width: Int,
        height: Int,
        precisionThreshold: Float = 0.0001
    ) -> Set<Int> {
        var riskPixels: Set<Int> = []

        for y in 0..<height {
            for x in 0..<width {
                let index = y * width + x
                let depth = depthValues[index]

                guard depth > 0.001 else { continue }

                if x > 0 {
                    let leftIndex = y * width + (x - 1)
                    let leftDepth = depthValues[leftIndex]
                    if leftDepth > 0.001 && abs(depth - leftDepth) < precisionThreshold && abs(depth - leftDepth) > 0 {
                        riskPixels.insert(index)
                        riskPixels.insert(leftIndex)
                    }
                }

                if y > 0 {
                    let aboveIndex = (y - 1) * width + x
                    let aboveDepth = depthValues[aboveIndex]
                    if aboveDepth > 0.001 && abs(depth - aboveDepth) < precisionThreshold && abs(depth - aboveDepth) > 0 {
                        riskPixels.insert(index)
                        riskPixels.insert(aboveIndex)
                    }
                }
            }
        }

        return riskPixels
    }

    /// Generate a depth histogram for visualization.
    /// - Parameters:
    ///   - depthValues: Array of depth values
    ///   - bucketCount: Number of histogram buckets
    ///   - backgroundThreshold: Depth values below this are excluded
    /// - Returns: Array of bucket counts
    static func generateDepthHistogram(
        depthValues: [Float],
        bucketCount: Int = 100,
        backgroundThreshold: Float = 0.001
    ) -> [Int] {
        let foregroundValues = depthValues.filter { $0 > backgroundThreshold }
        guard let minVal = foregroundValues.min(),
              let maxVal = foregroundValues.max(),
              maxVal > minVal else {
            return Array(repeating: 0, count: bucketCount)
        }

        let range = maxVal - minVal
        let bucketSize = range / Float(bucketCount)

        var histogram = Array(repeating: 0, count: bucketCount)
        for value in foregroundValues {
            let bucket = min(Int((value - minVal) / bucketSize), bucketCount - 1)
            histogram[bucket] += 1
        }

        return histogram
    }
}
