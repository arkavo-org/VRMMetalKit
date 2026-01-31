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

//
//  VRMLoadingPerformanceBenchmarkTests.swift
//  VRMMetalKitTests
//
//  Comprehensive performance benchmarks for VRM loading optimizations.
//

import XCTest
@testable import VRMMetalKit

// MARK: - Performance Benchmark Tests

@MainActor
final class VRMLoadingPerformanceBenchmarkTests: XCTestCase {
    
    // MARK: - Test Configuration
    
    /// Minimum number of iterations for statistical significance
    private let minIterations = 5
    
    /// Maximum time per test (seconds)
    private let maxTestTime: TimeInterval = 300
    
    /// Test file URL (AliciaSolid.vrm)
    private var testVRMURL: URL {
        URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("AliciaSolid.vrm")
    }
    
    // MARK: - Setup
    
    override func setUp() async throws {
        try await super.setUp()
        
        // Skip all performance tests if test file not available
        guard FileManager.default.fileExists(atPath: testVRMURL.path) else {
            throw XCTSkip("AliciaSolid.vrm not found - performance tests skipped")
        }
    }
    
    // MARK: - Baseline Benchmarks
    
    /// Benchmark baseline loading (no optimizations)
    func testBaselineLoadingPerformance() async throws {
        let options = VRMLoadingOptions(
            optimizations: [],  // No optimizations
            progressCallback: nil
        )
        
        var loadTimes: [TimeInterval] = []
        
        for _ in 0..<minIterations {
            let start = ContinuousClock().now
            _ = try await VRMModel.load(from: testVRMURL, options: options)
            let elapsed = start.duration(to: ContinuousClock().now)
            loadTimes.append(Double(elapsed))
        }
        
        let avgTime = loadTimes.reduce(0, +) / Double(loadTimes.count)
        let minTime = loadTimes.min()!
        let maxTime = loadTimes.max()!
        
        print("📊 Baseline Loading Performance:")
        print("  Average: \(String(format: "%.3f", avgTime))s")
        print("  Min: \(String(format: "%.3f", minTime))s")
        print("  Max: \(String(format: "%.3f", maxTime))s")
        
        // Performance assertion: Should complete in reasonable time
        XCTAssertLessThan(avgTime, 10.0, "Baseline loading should complete in under 10 seconds")
    }
    
    /// Benchmark default optimizations
    func testDefaultOptimizationsPerformance() async throws {
        let options = VRMLoadingOptions(optimizations: .default)
        
        var loadTimes: [TimeInterval] = []
        
        for _ in 0..<minIterations {
            let start = ContinuousClock().now
            _ = try await VRMModel.load(from: testVRMURL, options: options)
            let elapsed = start.duration(to: ContinuousClock().now)
            loadTimes.append(Double(elapsed))
        }
        
        let avgTime = loadTimes.reduce(0, +) / Double(loadTimes.count)
        
        print("📊 Default Optimizations Performance:")
        print("  Average: \(String(format: "%.3f", avgTime))s")
        
        XCTAssertLessThan(avgTime, 5.0, "Default optimizations should complete in under 5 seconds")
    }
    
    /// Benchmark maximum performance
    func testMaximumPerformanceLoading() async throws {
        let options = VRMLoadingOptions(optimizations: .maximumPerformance)
        
        var loadTimes: [TimeInterval] = []
        
        for _ in 0..<minIterations {
            let start = ContinuousClock().now
            _ = try await VRMModel.load(from: testVRMURL, options: options)
            let elapsed = start.duration(to: ContinuousClock().now)
            loadTimes.append(Double(elapsed))
        }
        
        let avgTime = loadTimes.reduce(0, +) / Double(loadTimes.count)
        let minTime = loadTimes.min()!
        
        print("📊 Maximum Performance Loading:")
        print("  Average: \(String(format: "%.3f", avgTime))s")
        print("  Best: \(String(format: "%.3f", minTime))s")
        
        // Target: < 2.0s for 20MB file
        XCTAssertLessThan(avgTime, 2.5, "Maximum performance should complete in under 2.5 seconds")
    }
    
    // MARK: - Individual Optimization Benchmarks
    
    func testParallelTextureLoadingPerformance() async throws {
        let sequentialOptions = VRMLoadingOptions(
            optimizations: [.skipVerboseLogging]
        )
        let parallelOptions = VRMLoadingOptions(
            optimizations: [.skipVerboseLogging, .parallelTextureLoading]
        )
        
        // Measure sequential
        var sequentialTimes: [TimeInterval] = []
        for _ in 0..<3 {
            let start = ContinuousClock().now
            _ = try await VRMModel.load(from: testVRMURL, options: sequentialOptions)
            sequentialTimes.append(Double(start.duration(to: ContinuousClock().now)))
        }
        
        // Measure parallel
        var parallelTimes: [TimeInterval] = []
        for _ in 0..<3 {
            let start = ContinuousClock().now
            _ = try await VRMModel.load(from: testVRMURL, options: parallelOptions)
            parallelTimes.append(Double(start.duration(to: ContinuousClock().now)))
        }
        
        let seqAvg = sequentialTimes.reduce(0, +) / Double(sequentialTimes.count)
        let parAvg = parallelTimes.reduce(0, +) / Double(parallelTimes.count)
        let speedup = seqAvg / parAvg
        
        print("📊 Parallel Texture Loading:")
        print("  Sequential: \(String(format: "%.3f", seqAvg))s")
        print("  Parallel: \(String(format: "%.3f", parAvg))s")
        print("  Speedup: \(String(format: "%.2f", speedup))x")
        
        XCTAssertGreaterThan(speedup, 1.0, "Parallel loading should be faster than sequential")
    }
    
    func testParallelMeshLoadingPerformance() async throws {
        let sequentialOptions = VRMLoadingOptions(
            optimizations: [.skipVerboseLogging]
        )
        let parallelOptions = VRMLoadingOptions(
            optimizations: [.skipVerboseLogging, .parallelMeshLoading]
        )
        
        var sequentialTimes: [TimeInterval] = []
        for _ in 0..<3 {
            let start = ContinuousClock().now
            _ = try await VRMModel.load(from: testVRMURL, options: sequentialOptions)
            sequentialTimes.append(Double(start.duration(to: ContinuousClock().now)))
        }
        
        var parallelTimes: [TimeInterval] = []
        for _ in 0..<3 {
            let start = ContinuousClock().now
            _ = try await VRMModel.load(from: testVRMURL, options: parallelOptions)
            parallelTimes.append(Double(start.duration(to: ContinuousClock().now)))
        }
        
        let seqAvg = sequentialTimes.reduce(0, +) / Double(sequentialTimes.count)
        let parAvg = parallelTimes.reduce(0, +) / Double(parallelTimes.count)
        let speedup = seqAvg / parAvg
        
        print("📊 Parallel Mesh Loading:")
        print("  Sequential: \(String(format: "%.3f", seqAvg))s")
        print("  Parallel: \(String(format: "%.3f", parAvg))s")
        print("  Speedup: \(String(format: "%.2f", speedup))x")
        
        XCTAssertGreaterThan(speedup, 1.0, "Parallel mesh loading should be faster")
    }
    
    func testBufferPreloadingPerformance() async throws {
        let noPreloadOptions = VRMLoadingOptions(
            optimizations: [.skipVerboseLogging]
        )
        let preloadOptions = VRMLoadingOptions(
            optimizations: [.skipVerboseLogging, .preloadBuffers]
        )
        
        var noPreloadTimes: [TimeInterval] = []
        for _ in 0..<3 {
            let start = ContinuousClock().now
            _ = try await VRMModel.load(from: testVRMURL, options: noPreloadOptions)
            noPreloadTimes.append(Double(start.duration(to: ContinuousClock().now)))
        }
        
        var preloadTimes: [TimeInterval] = []
        for _ in 0..<3 {
            let start = ContinuousClock().now
            _ = try await VRMModel.load(from: testVRMURL, options: preloadOptions)
            preloadTimes.append(Double(start.duration(to: ContinuousClock().now)))
        }
        
        let noAvg = noPreloadTimes.reduce(0, +) / Double(noPreloadTimes.count)
        let preAvg = preloadTimes.reduce(0, +) / Double(preloadTimes.count)
        
        print("📊 Buffer Preloading:")
        print("  Without preload: \(String(format: "%.3f", noAvg))s")
        print("  With preload: \(String(format: "%.3f", preAvg))s")
        
        // Preloading should not significantly hurt performance
        XCTAssertLessThan(preAvg, noAvg * 1.2, "Preloading should not be more than 20% slower")
    }
    
    // MARK: - Progress Callback Benchmarks
    
    func testProgressCallbackOverhead() async throws {
        let noCallbackOptions = VRMLoadingOptions(
            progressCallback: nil,
            optimizations: .maximumPerformance
        )
        
        var callbackCount = 0
        let withCallbackOptions = VRMLoadingOptions(
            progressCallback: { _ in
                callbackCount += 1
            },
            progressUpdateInterval: 0.01,  // Very frequent
            optimizations: .maximumPerformance
        )
        
        // Measure without callback
        let start1 = ContinuousClock().now
        _ = try await VRMModel.load(from: testVRMURL, options: noCallbackOptions)
        let time1 = Double(start1.duration(to: ContinuousClock().now))
        
        // Measure with frequent callbacks
        let start2 = ContinuousClock().now
        _ = try await VRMModel.load(from: testVRMURL, options: withCallbackOptions)
        let time2 = Double(start2.duration(to: ContinuousClock().now))
        
        let overhead = ((time2 - time1) / time1) * 100
        
        print("📊 Progress Callback Overhead:")
        print("  Without callbacks: \(String(format: "%.3f", time1))s")
        print("  With callbacks (\(callbackCount) calls): \(String(format: "%.3f", time2))s")
        print("  Overhead: \(String(format: "%.1f", overhead))%")
        
        XCTAssertLessThan(overhead, 20.0, "Callback overhead should be less than 20%")
    }
    
    // MARK: - Phase Breakdown Benchmarks
    
    func testLoadingPhaseBreakdown() async throws {
        var phaseTimes: [VRMLoadingPhase: [TimeInterval]] = [:]
        var lastPhase: VRMLoadingPhase?
        var lastTime = ContinuousClock().now
        
        let options = VRMLoadingOptions(
            progressCallback: { progress in
                let now = ContinuousClock().now
                let elapsed = Double(lastTime.duration(to: now))
                
                if let last = lastPhase {
                    phaseTimes[last, default: []].append(elapsed)
                }
                
                lastPhase = progress.currentPhase
                lastTime = now
            },
            progressUpdateInterval: 0.001,  // Capture all phase changes
            optimizations: .maximumPerformance
        )
        
        _ = try await VRMModel.load(from: testVRMURL, options: options)
        
        print("📊 Loading Phase Breakdown:")
        for phase in VRMLoadingPhase.allCases {
            if let times = phaseTimes[phase], !times.isEmpty {
                let total = times.reduce(0, +)
                print("  \(phase.rawValue): \(String(format: "%.3f", total))s")
            }
        }
        
        // Verify all phases were tracked
        XCTAssertTrue(phaseTimes[.loadingTextures] != nil, "Texture loading phase should be tracked")
        XCTAssertTrue(phaseTimes[.loadingMeshes] != nil, "Mesh loading phase should be tracked")
    }
    
    // MARK: - Memory Benchmarks
    
    func testLoadingMemoryUsage() async throws {
        let options = VRMLoadingOptions(optimizations: .maximumPerformance)
        
        // Measure memory before
        let memoryBefore = reportMemory()
        
        let model = try await VRMModel.load(from: testVRMURL, options: options)
        
        // Measure memory after
        let memoryAfter = reportMemory()
        let memoryDelta = memoryAfter - memoryBefore
        
        print("📊 Memory Usage:")
        print("  Before: \(memoryBefore) MB")
        print("  After: \(memoryAfter) MB")
        print("  Delta: \(memoryDelta) MB")
        
        // Rough estimate: 20MB file should use ~50-100MB memory
        XCTAssertLessThan(memoryDelta, 200, "Memory usage should be reasonable")
        
        // Keep model in scope to prevent optimization
        _ = model.textures.count
    }
    
    // MARK: - Cancellation Benchmarks
    
    func testCancellationResponseTime() async throws {
        var cancellationTimes: [TimeInterval] = []
        
        for _ in 0..<5 {
            let cancellationTime = ContinuousClock().now
            var errorTime: ContinuousClock.Instant?
            
            let task = Task {
                do {
                    let options = VRMLoadingOptions(
                        enableCancellation: true,
                        optimizations: .maximumPerformance
                    )
                    _ = try await VRMModel.load(from: self.testVRMURL, options: options)
                } catch {
                    errorTime = ContinuousClock().now
                }
            }
            
            // Cancel immediately
            task.cancel()
            _ = await task.result
            
            if let errTime = errorTime {
                let responseTime = Double(cancellationTime.duration(to: errTime))
                cancellationTimes.append(responseTime)
            }
        }
        
        let avgResponse = cancellationTimes.reduce(0, +) / Double(cancellationTimes.count)
        
        print("📊 Cancellation Response Time:")
        print("  Average: \(String(format: "%.3f", avgResponse))s")
        print("  Max: \(String(format: "%.3f", cancellationTimes.max()!))s")
        
        XCTAssertLessThan(avgResponse, 0.1, "Cancellation should respond within 100ms")
    }
    
    // MARK: - Target Verification
    
    /// Verify <2.0s target for 20MB files
    func test20MBFileTargetTime() async throws {
        // Check file size
        let fileSize = try FileManager.default.attributesOfItem(atPath: testVRMURL.path)[.size] as? Int64 ?? 0
        
        guard fileSize >= 20_000_000 else {
            throw XCTSkip("Test file is smaller than 20MB (actual: \(fileSize / 1_000_000)MB)")
        }
        
        let options = VRMLoadingOptions(optimizations: .maximumPerformance)
        
        var loadTimes: [TimeInterval] = []
        for _ in 0..<5 {
            let start = ContinuousClock().now
            _ = try await VRMModel.load(from: testVRMURL, options: options)
            loadTimes.append(Double(start.duration(to: ContinuousClock().now)))
        }
        
        let avgTime = loadTimes.reduce(0, +) / Double(loadTimes.count)
        let minTime = loadTimes.min()!
        
        print("📊 20MB File Target Verification:")
        print("  File size: \(fileSize / 1_000_000) MB")
        print("  Average load time: \(String(format: "%.3f", avgTime))s")
        print("  Best load time: \(String(format: "%.3f", minTime))s")
        print("  Target: < 2.0s")
        
        XCTAssertLessThan(avgTime, 2.0, "20MB file should load in under 2.0 seconds")
    }
    
    // MARK: - Helpers
    
    private func reportMemory() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size)/4
        
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_,
                         task_flavor_t(MACH_TASK_BASIC_INFO),
                         $0,
                         &count)
            }
        }
        
        guard kerr == KERN_SUCCESS else {
            return 0
        }
        
        return Double(info.resident_size) / (1024 * 1024)  // Convert to MB
    }
}

// MARK: - Stress Tests

@MainActor
final class VRMLoadingStressTests: XCTestCase {
    
    private var testVRMURL: URL {
        URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("AliciaSolid.vrm")
    }
    
    /// Test rapid successive loads
    func testRapidSuccessiveLoads() async throws {
        guard FileManager.default.fileExists(atPath: testVRMURL.path) else {
            throw XCTSkip("AliciaSolid.vrm not found")
        }
        
        let options = VRMLoadingOptions(optimizations: .maximumPerformance)
        
        let start = ContinuousClock().now
        
        // Load 10 times rapidly
        for i in 0..<10 {
            _ = try await VRMModel.load(from: testVRMURL, options: options)
            print("  Load \(i + 1)/10 complete")
        }
        
        let totalTime = Double(start.duration(to: ContinuousClock().now))
        let avgTime = totalTime / 10
        
        print("📊 Rapid Successive Loads:")
        print("  Total time: \(String(format: "%.3f", totalTime))s")
        print("  Average per load: \(String(format: "%.3f", avgTime))s")
    }
    
    /// Test concurrent loads
    func testConcurrentLoads() async throws {
        guard FileManager.default.fileExists(atPath: testVRMURL.path) else {
            throw XCTSkip("AliciaSolid.vrm not found")
        }
        
        let options = VRMLoadingOptions(optimizations: .maximumPerformance)
        
        let start = ContinuousClock().now
        
        // Load 3 models concurrently
        async let load1 = VRMModel.load(from: testVRMURL, options: options)
        async let load2 = VRMModel.load(from: testVRMURL, options: options)
        async let load3 = VRMModel.load(from: testVRMURL, options: options)
        
        _ = try await (load1, load2, load3)
        
        let totalTime = Double(start.duration(to: ContinuousClock().now))
        
        print("📊 Concurrent Loads (3x):")
        print("  Total time: \(String(format: "%.3f", totalTime))s")
        print("  Equivalent sequential: \(String(format: "%.3f", totalTime / 3))s per model")
    }
}
