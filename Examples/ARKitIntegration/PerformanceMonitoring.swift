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
import VRMMetalKit

/// Performance monitoring and statistics for ARKit integration
///
/// This example demonstrates how to monitor and optimize ARKit driver performance
/// for production use. Includes timing measurements, statistics tracking, and
/// performance profiling.
///
/// Use cases:
/// - Identifying performance bottlenecks
/// - Monitoring skip rates and staleness
/// - Profiling different smoothing configurations
/// - Validating 60 FPS target
class ARKitPerformanceMonitor {
    // MARK: - Properties

    let faceDriver: ARKitFaceDriver
    let bodyDriver: ARKitBodyDriver

    /// Timing measurements for face updates
    private var faceUpdateTimes: [TimeInterval] = []

    /// Timing measurements for body updates
    private var bodyUpdateTimes: [TimeInterval] = []

    /// Maximum number of timing samples to keep
    private let maxSamples = 1000

    // MARK: - Initialization

    init(faceDriver: ARKitFaceDriver, bodyDriver: ARKitBodyDriver) {
        self.faceDriver = faceDriver
        self.bodyDriver = bodyDriver
    }

    // MARK: - Timing Measurements

    /// Measure time taken for face update
    ///
    /// - Parameters:
    ///   - blendShapes: Face blend shapes to update
    ///   - controller: Expression controller to update
    /// - Returns: Time taken in milliseconds
    @discardableResult
    func measureFaceUpdate(
        blendShapes: ARKitFaceBlendShapes,
        controller: VRMExpressionController?
    ) -> TimeInterval {
        let start = DispatchTime.now()

        faceDriver.update(blendShapes: blendShapes, controller: controller)

        let end = DispatchTime.now()
        let nanos = end.uptimeNanoseconds - start.uptimeNanoseconds
        let ms = Double(nanos) / 1_000_000

        // Store measurement
        faceUpdateTimes.append(ms)
        if faceUpdateTimes.count > maxSamples {
            faceUpdateTimes.removeFirst()
        }

        return ms
    }

    /// Measure time taken for body update
    ///
    /// - Parameters:
    ///   - skeleton: Body skeleton to update
    ///   - nodes: VRM nodes to update
    ///   - humanoid: Humanoid mapping
    /// - Returns: Time taken in milliseconds
    @discardableResult
    func measureBodyUpdate(
        skeleton: ARKitBodySkeleton,
        nodes: [VRMNode],
        humanoid: VRMHumanoid?
    ) -> TimeInterval {
        let start = DispatchTime.now()

        bodyDriver.update(skeleton: skeleton, nodes: nodes, humanoid: humanoid)

        let end = DispatchTime.now()
        let nanos = end.uptimeNanoseconds - start.uptimeNanoseconds
        let ms = Double(nanos) / 1_000_000

        // Store measurement
        bodyUpdateTimes.append(ms)
        if bodyUpdateTimes.count > maxSamples {
            bodyUpdateTimes.removeFirst()
        }

        return ms
    }

    // MARK: - Statistics

    /// Get statistics for face driver
    func getFaceStatistics() -> DriverStatistics {
        let stats = faceDriver.getStatistics()

        return DriverStatistics(
            totalUpdates: stats.totalUpdates,
            skippedUpdates: stats.skippedUpdates,
            skipRate: stats.skipRate,
            averageUpdateTime: faceUpdateTimes.average(),
            p50UpdateTime: faceUpdateTimes.percentile(0.5),
            p95UpdateTime: faceUpdateTimes.percentile(0.95),
            p99UpdateTime: faceUpdateTimes.percentile(0.99)
        )
    }

    /// Get statistics for body driver
    func getBodyStatistics() -> DriverStatistics {
        let stats = bodyDriver.getStatistics()

        return DriverStatistics(
            totalUpdates: stats.updateCount,
            skippedUpdates: 0,  // Body stats don't track skips separately
            skipRate: 0,
            averageUpdateTime: bodyUpdateTimes.average(),
            p50UpdateTime: bodyUpdateTimes.percentile(0.5),
            p95UpdateTime: bodyUpdateTimes.percentile(0.95),
            p99UpdateTime: bodyUpdateTimes.percentile(0.99)
        )
    }

    /// Print comprehensive performance report
    func printReport() {
        let faceStats = getFaceStatistics()
        let bodyStats = getBodyStatistics()

        print("""
        ╔════════════════════════════════════════════════╗
        ║       ARKit Driver Performance Report          ║
        ╚════════════════════════════════════════════════╝

        Face Driver:
          Updates:    \(faceStats.totalUpdates) total, \(faceStats.skippedUpdates) skipped (\(String(format: "%.1f", faceStats.skipRate * 100))%)
          Timing:     avg=\(String(format: "%.3f", faceStats.averageUpdateTime))ms, p50=\(String(format: "%.3f", faceStats.p50UpdateTime))ms
                      p95=\(String(format: "%.3f", faceStats.p95UpdateTime))ms, p99=\(String(format: "%.3f", faceStats.p99UpdateTime))ms

        Body Driver:
          Updates:    \(bodyStats.totalUpdates) total
          Timing:     avg=\(String(format: "%.3f", bodyStats.averageUpdateTime))ms, p50=\(String(format: "%.3f", bodyStats.p50UpdateTime))ms
                      p95=\(String(format: "%.3f", bodyStats.p95UpdateTime))ms, p99=\(String(format: "%.3f", bodyStats.p99UpdateTime))ms

        Performance Grade: \(getPerformanceGrade(faceStats: faceStats, bodyStats: bodyStats))
        """)
    }

    /// Get performance grade based on timing measurements
    private func getPerformanceGrade(faceStats: DriverStatistics, bodyStats: DriverStatistics) -> String {
        let totalP95 = faceStats.p95UpdateTime + bodyStats.p95UpdateTime

        if totalP95 < 2.0 {
            return "A (Excellent - 120 FPS capable)"
        } else if totalP95 < 5.0 {
            return "B (Good - 60 FPS capable)"
        } else if totalP95 < 10.0 {
            return "C (Acceptable - 30 FPS capable)"
        } else {
            return "D (Poor - optimization needed)"
        }
    }

    /// Reset all measurements for clean profiling
    func reset() {
        faceUpdateTimes.removeAll()
        bodyUpdateTimes.removeAll()
        faceDriver.resetStatistics()
        bodyDriver.resetStatistics()
    }

    // MARK: - Profiling Helpers

    /// Run performance benchmark with test data
    ///
    /// - Parameters:
    ///   - iterations: Number of iterations to run
    ///   - blendShapes: Test blend shapes
    ///   - skeleton: Test skeleton
    ///   - controller: Expression controller
    ///   - nodes: VRM nodes
    ///   - humanoid: Humanoid mapping
    func runBenchmark(
        iterations: Int = 1000,
        blendShapes: ARKitFaceBlendShapes,
        skeleton: ARKitBodySkeleton,
        controller: VRMExpressionController?,
        nodes: [VRMNode],
        humanoid: VRMHumanoid?
    ) {
        print("Running benchmark with \(iterations) iterations...")

        reset()

        let start = Date()

        for _ in 0..<iterations {
            measureFaceUpdate(blendShapes: blendShapes, controller: controller)
            measureBodyUpdate(skeleton: skeleton, nodes: nodes, humanoid: humanoid)
        }

        let elapsed = Date().timeIntervalSince(start)
        let fps = Double(iterations) / elapsed

        print("Benchmark completed in \(String(format: "%.2f", elapsed))s (\(String(format: "%.1f", fps)) FPS)")
        printReport()
    }

    /// Compare two smoothing configurations
    ///
    /// - Parameters:
    ///   - config1: First smoothing config
    ///   - config2: Second smoothing config
    ///   - iterations: Number of iterations per config
    ///   - testData: Test blend shapes
    ///   - controller: Expression controller
    func compareSmoothingConfigs(
        config1: SmoothingConfig,
        config2: SmoothingConfig,
        config1Name: String = "Config 1",
        config2Name: String = "Config 2",
        iterations: Int = 1000,
        testData: ARKitFaceBlendShapes,
        controller: VRMExpressionController?
    ) {
        print("Comparing smoothing configurations...")

        // Test config 1
        let driver1 = ARKitFaceDriver(mapper: .default, smoothing: config1)
        var times1: [TimeInterval] = []

        for _ in 0..<iterations {
            let start = DispatchTime.now()
            driver1.update(blendShapes: testData, controller: controller)
            let end = DispatchTime.now()
            times1.append(Double(end.uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
        }

        // Test config 2
        let driver2 = ARKitFaceDriver(mapper: .default, smoothing: config2)
        var times2: [TimeInterval] = []

        for _ in 0..<iterations {
            let start = DispatchTime.now()
            driver2.update(blendShapes: testData, controller: controller)
            let end = DispatchTime.now()
            times2.append(Double(end.uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
        }

        // Print comparison
        print("""

        Smoothing Configuration Comparison (\(iterations) iterations):

        \(config1Name):
          Average: \(String(format: "%.3f", times1.average()))ms
          P95:     \(String(format: "%.3f", times1.percentile(0.95)))ms

        \(config2Name):
          Average: \(String(format: "%.3f", times2.average()))ms
          P95:     \(String(format: "%.3f", times2.percentile(0.95)))ms

        Winner: \(times1.average() < times2.average() ? config1Name : config2Name) (faster by \(String(format: "%.1f", abs(times1.average() - times2.average()) / min(times1.average(), times2.average()) * 100))%)
        """)
    }
}

// MARK: - Statistics Types

struct DriverStatistics {
    let totalUpdates: Int
    let skippedUpdates: Int
    let skipRate: Float
    let averageUpdateTime: TimeInterval
    let p50UpdateTime: TimeInterval
    let p95UpdateTime: TimeInterval
    let p99UpdateTime: TimeInterval
}

// MARK: - Array Extensions

extension Array where Element == TimeInterval {
    func average() -> TimeInterval {
        guard !isEmpty else { return 0 }
        return reduce(0, +) / Double(count)
    }

    func percentile(_ p: Double) -> TimeInterval {
        guard !isEmpty else { return 0 }
        let sorted = self.sorted()
        let index = Int(Double(sorted.count) * p)
        return sorted[min(index, sorted.count - 1)]
    }
}

// MARK: - Usage Examples

/*
 // Basic monitoring
 let monitor = ARKitPerformanceMonitor(
     faceDriver: faceDriver,
     bodyDriver: bodyDriver
 )

 // Measure individual updates
 let faceTime = monitor.measureFaceUpdate(
     blendShapes: faceData,
     controller: vrmModel.expressionController
 )
 print("Face update took \(faceTime)ms")

 // Print periodic reports
 Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
     monitor.printReport()
 }

 // Run benchmark
 monitor.runBenchmark(
     iterations: 1000,
     blendShapes: testFaceData,
     skeleton: testBodyData,
     controller: vrmModel.expressionController,
     nodes: vrmModel.nodes,
     humanoid: vrmModel.vrm?.humanoid
 )

 // Compare smoothing configs
 monitor.compareSmoothingConfigs(
     config1: .default,
     config2: .lowLatency,
     config1Name: "Default (EMA 0.3)",
     config2Name: "Low Latency (EMA 0.5)",
     iterations: 1000,
     testData: testFaceData,
     controller: vrmModel.expressionController
 )
 */
