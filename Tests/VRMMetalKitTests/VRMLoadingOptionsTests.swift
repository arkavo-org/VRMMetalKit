//
//  VRMLoadingOptionsTests.swift
//  VRMMetalKitTests
//
//  Tests for VRM loading progress callbacks and cancellation support.
//

import XCTest
@testable import VRMMetalKit

// MARK: - VRMLoadingOptionsTests

@MainActor
final class VRMLoadingOptionsTests: XCTestCase {
    
    // MARK: - Test Resources
    
    private var testVRMURL: URL {
        // Use AliciaSolid.vrm for integration tests
        let url = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("AliciaSolid.vrm")
        return url
    }
    
    // MARK: - VRMLoadingPhase Tests
    
    func testLoadingPhaseWeights() {
        // Given & When & Then
        XCTAssertEqual(VRMLoadingPhase.parsingGLTF.weight, 0.05)
        XCTAssertEqual(VRMLoadingPhase.parsingVRMExtension.weight, 0.05)
        XCTAssertEqual(VRMLoadingPhase.preloadingBuffers.weight, 0.03)
        XCTAssertEqual(VRMLoadingPhase.loadingTextures.weight, 0.34)
        XCTAssertEqual(VRMLoadingPhase.loadingMaterials.weight, 0.10)
        XCTAssertEqual(VRMLoadingPhase.loadingMeshes.weight, 0.20)
        XCTAssertEqual(VRMLoadingPhase.buildingHierarchy.weight, 0.05)
        XCTAssertEqual(VRMLoadingPhase.loadingSkins.weight, 0.10)
        XCTAssertEqual(VRMLoadingPhase.sanitizingJoints.weight, 0.05)
        XCTAssertEqual(VRMLoadingPhase.initializingPhysics.weight, 0.03)
        XCTAssertEqual(VRMLoadingPhase.complete.weight, 0.0)
    }
    
    func testLoadingPhaseWeightsSumToOne() {
        // Given
        let allPhases = VRMLoadingPhase.allCases
        
        // When
        let totalWeight = allPhases.reduce(0.0) { $0 + $1.weight }
        
        // Then
        XCTAssertEqual(totalWeight, 1.0, accuracy: 0.001)
    }
    
    func testLoadingPhaseRawValues() {
        // Given & When & Then
        XCTAssertEqual(VRMLoadingPhase.parsingGLTF.rawValue, "Parsing GLTF")
        XCTAssertEqual(VRMLoadingPhase.loadingTextures.rawValue, "Loading Textures")
        XCTAssertEqual(VRMLoadingPhase.complete.rawValue, "Complete")
    }
    
    // MARK: - VRMLoadingProgress Tests
    
    func testLoadingProgressPercentage() {
        // Given
        let progress = VRMLoadingProgress(
            currentPhase: .loadingTextures,
            phaseProgress: 0.5,
            overallProgress: 0.35
        )
        
        // When & Then
        XCTAssertEqual(progress.percentage, 35)
    }
    
    func testLoadingProgressPercentageRounding() {
        // Given
        let progress = VRMLoadingProgress(
            currentPhase: .loadingMeshes,
            phaseProgress: 0.75,
            overallProgress: 0.678
        )
        
        // When & Then
        XCTAssertEqual(progress.percentage, 68)
    }
    
    func testLoadingProgressZeroPercentage() {
        // Given
        let progress = VRMLoadingProgress(
            currentPhase: .parsingGLTF,
            phaseProgress: 0.0,
            overallProgress: 0.0
        )
        
        // When & Then
        XCTAssertEqual(progress.percentage, 0)
    }
    
    func testLoadingProgressHundredPercentage() {
        // Given
        let progress = VRMLoadingProgress(
            currentPhase: .complete,
            phaseProgress: 1.0,
            overallProgress: 1.0
        )
        
        // When & Then
        XCTAssertEqual(progress.percentage, 100)
    }
    
    func testLoadingProgressWithItems() {
        // Given
        let progress = VRMLoadingProgress(
            currentPhase: .loadingTextures,
            phaseProgress: 0.5,
            overallProgress: 0.25,
            itemsCompleted: 5,
            totalItems: 10,
            elapsedTime: 1.5,
            estimatedTimeRemaining: 2.0,
            operationDescription: "Loading Textures (50%)"
        )
        
        // Then
        XCTAssertEqual(progress.itemsCompleted, 5)
        XCTAssertEqual(progress.totalItems, 10)
        XCTAssertEqual(progress.elapsedTime, 1.5)
        XCTAssertEqual(progress.estimatedTimeRemaining, 2.0)
        XCTAssertEqual(progress.operationDescription, "Loading Textures (50%)")
    }
    
    // MARK: - VRMLoadingOptimization Tests
    
    func testLoadingOptimizationRawValues() {
        // Given & When & Then
        XCTAssertEqual(VRMLoadingOptimization.skipVerboseLogging.rawValue, 1 << 0)
        XCTAssertEqual(VRMLoadingOptimization.aggressiveTextureCompression.rawValue, 1 << 1)
        XCTAssertEqual(VRMLoadingOptimization.skipSecondaryUVs.rawValue, 1 << 2)
        XCTAssertEqual(VRMLoadingOptimization.parallelTextureDecoding.rawValue, 1 << 3)
    }
    
    func testLoadingOptimizationDefault() {
        // Given
        let defaultOpt = VRMLoadingOptimization.default
        
        // Then
        XCTAssertTrue(defaultOpt.contains(.skipVerboseLogging))
        XCTAssertTrue(defaultOpt.contains(.parallelTextureDecoding))
        XCTAssertFalse(defaultOpt.contains(.aggressiveTextureCompression))
        XCTAssertFalse(defaultOpt.contains(.skipSecondaryUVs))
    }
    
    func testLoadingOptimizationMaximumPerformance() {
        // Given
        let maxPerf = VRMLoadingOptimization.maximumPerformance
        
        // Then
        XCTAssertTrue(maxPerf.contains(.skipVerboseLogging))
        XCTAssertTrue(maxPerf.contains(.aggressiveTextureCompression))
        XCTAssertTrue(maxPerf.contains(.skipSecondaryUVs))
        XCTAssertTrue(maxPerf.contains(.parallelTextureDecoding))
    }
    
    func testLoadingOptimizationCombination() {
        // Given
        let combined: VRMLoadingOptimization = [.skipVerboseLogging, .skipSecondaryUVs]
        
        // Then
        XCTAssertTrue(combined.contains(.skipVerboseLogging))
        XCTAssertTrue(combined.contains(.skipSecondaryUVs))
        XCTAssertFalse(combined.contains(.aggressiveTextureCompression))
    }
    
    // MARK: - VRMLoadingOptions Tests
    
    func testLoadingOptionsDefault() {
        // Given
        let options = VRMLoadingOptions.default
        
        // Then
        XCTAssertNil(options.progressCallback)
        XCTAssertEqual(options.progressUpdateInterval, 0.1)
        XCTAssertTrue(options.enableCancellation)
        XCTAssertEqual(options.optimizations, .default)
    }
    
    func testLoadingOptionsCustom() {
        // When
        let options = VRMLoadingOptions(
            progressCallback: nil,
            progressUpdateInterval: 0.5,
            enableCancellation: false,
            optimizations: .maximumPerformance
        )
        
        // Then
        XCTAssertNil(options.progressCallback)
        XCTAssertEqual(options.progressUpdateInterval, 0.5)
        XCTAssertFalse(options.enableCancellation)
        XCTAssertEqual(options.optimizations, .maximumPerformance)
    }
    
    // MARK: - VRMError Loading Cancelled Tests
    
    func testLoadingCancelledError() {
        // Given
        let error = VRMError.loadingCancelled
        
        // When
        let description = error.errorDescription
        
        // Then
        XCTAssertNotNil(description)
        XCTAssertTrue(description?.contains("Loading Cancelled") ?? false)
        XCTAssertTrue(description?.contains("cancelled by the user") ?? false)
    }
    
    // MARK: - Progress Callback Integration Tests
    
    func testLoadWithProgressCallback() async throws {
        // Given
        guard FileManager.default.fileExists(atPath: testVRMURL.path) else {
            throw XCTSkip("AliciaSolid.vrm not found")
        }
        
        let expectation = XCTestExpectation(description: "Progress updates received")
        expectation.expectedFulfillmentCount = 3 // At least 3 updates
        
        // Use nonisolated closure with @Sendable to collect data safely
        let box = ProgressBox()
        
        let options = VRMLoadingOptions(
            progressCallback: { @Sendable progress in
                box.add(progress)
                Task { @MainActor in
                    expectation.fulfill()
                }
            },
            progressUpdateInterval: 0.05
        )
        
        // When
        let model = try await VRMModel.load(from: testVRMURL, options: options)
        
        // Then
        await fulfillment(of: [expectation], timeout: 30.0)
        XCTAssertNotNil(model)
        XCTAssertGreaterThan(box.count, 0)
        
        // Verify progress increases
        if box.count >= 2 {
            let firstProgress = box.updates[0].overallProgress
            let lastProgress = box.updates[box.count - 1].overallProgress
            XCTAssertGreaterThanOrEqual(lastProgress, firstProgress)
        }
        
        // Verify final progress is 100%
        if let finalProgress = box.updates.last {
            XCTAssertEqual(finalProgress.currentPhase, .complete)
            XCTAssertEqual(finalProgress.overallProgress, 1.0, accuracy: 0.001)
        }
    }
    
    func testLoadProgressPhases() async throws {
        // Given
        guard FileManager.default.fileExists(atPath: testVRMURL.path) else {
            throw XCTSkip("AliciaSolid.vrm not found")
        }
        
        let box = PhaseBox()
        
        let options = VRMLoadingOptions(
            progressCallback: { @Sendable progress in
                box.add(phase: progress.currentPhase)
            },
            progressUpdateInterval: 0.01
        )
        
        // When
        _ = try await VRMModel.load(from: testVRMURL, options: options)
        
        // Then
        XCTAssertTrue(box.phases.contains(.parsingGLTF))
        XCTAssertTrue(box.phases.contains(.parsingVRMExtension))
        XCTAssertTrue(box.phases.contains(.complete))
    }
    
    func testLoadProgressPercentageIncreases() async throws {
        // Given
        guard FileManager.default.fileExists(atPath: testVRMURL.path) else {
            throw XCTSkip("AliciaSolid.vrm not found")
        }
        
        let box = PercentageBox()
        
        let options = VRMLoadingOptions(
            progressCallback: { @Sendable progress in
                box.add(percentage: progress.percentage)
            },
            progressUpdateInterval: 0.01
        )
        
        // When
        _ = try await VRMModel.load(from: testVRMURL, options: options)
        
        // Then
        XCTAssertGreaterThan(box.percentages.count, 0)
        XCTAssertEqual(box.percentages.first, 0)
        XCTAssertEqual(box.percentages.last, 100)
        
        // Verify monotonic increase (allowing for some duplicates due to phase transitions)
        for i in 1..<box.percentages.count {
            XCTAssertGreaterThanOrEqual(box.percentages[i], box.percentages[i-1])
        }
    }
    
    // MARK: - Cancellation Tests
    
    func testLoadCancellationResponseTime() async throws {
        // Given
        guard FileManager.default.fileExists(atPath: testVRMURL.path) else {
            throw XCTSkip("AliciaSolid.vrm not found")
        }
        
        var errorThrown = false
        var errorTime: ContinuousClock.Instant?
        let cancellationTime = ContinuousClock().now
        
        // When
        let task = Task {
            do {
                let options = VRMLoadingOptions(enableCancellation: true)
                _ = try await VRMModel.load(from: self.testVRMURL, options: options)
                XCTFail("Should have thrown cancellation error")
            } catch {
                errorThrown = true
                errorTime = ContinuousClock().now
            }
        }
        
        // Cancel immediately
        task.cancel()
        _ = await task.result
        
        // Then
        XCTAssertTrue(errorThrown, "Error should have been thrown")
        if let errTime = errorTime {
            let responseTime = cancellationTime.duration(to: errTime)
            // Should respond within 100ms
            XCTAssertLessThan(responseTime, .milliseconds(100))
        }
    }
    
    func testLoadCancellationDisabled() async throws {
        // Given
        guard FileManager.default.fileExists(atPath: testVRMURL.path) else {
            throw XCTSkip("AliciaSolid.vrm not found")
        }
        
        let options = VRMLoadingOptions(
            enableCancellation: false
        )
        
        // When & Then - should complete without cancellation
        let model = try await VRMModel.load(from: testVRMURL, options: options)
        XCTAssertNotNil(model)
    }
    
    // MARK: - Performance Tests
    
    func testProgressCallbackPerformance() async throws {
        // Given
        guard FileManager.default.fileExists(atPath: testVRMURL.path) else {
            throw XCTSkip("AliciaSolid.vrm not found")
        }
        
        let counter = CounterBox()
        let options = VRMLoadingOptions(
            progressCallback: { @Sendable _ in
                counter.increment()
            },
            progressUpdateInterval: 0.001 // Very frequent updates
        )
        
        // When
        _ = try await VRMModel.load(from: testVRMURL, options: options)
        
        // Then - should not overwhelm with updates (throttled by interval)
        // Even with 0.001 interval, we should get reasonable number of updates
        XCTAssertGreaterThan(counter.count, 0)
        // Should be less than number of textures/meshes due to throttling
        XCTAssertLessThan(counter.count, 1000)
    }
    
    // MARK: - Edge Cases
    
    func testLoadWithZeroProgressInterval() async throws {
        // Given
        guard FileManager.default.fileExists(atPath: testVRMURL.path) else {
            throw XCTSkip("AliciaSolid.vrm not found")
        }
        
        let counter = CounterBox()
        let options = VRMLoadingOptions(
            progressCallback: { @Sendable _ in
                counter.increment()
            },
            progressUpdateInterval: 0 // Zero interval should still work
        )
        
        // When
        _ = try await VRMModel.load(from: testVRMURL, options: options)
        
        // Then
        XCTAssertGreaterThan(counter.count, 0)
    }
    
    func testLoadWithNoOptionsUsesDefault() async throws {
        // Given
        guard FileManager.default.fileExists(atPath: testVRMURL.path) else {
            throw XCTSkip("AliciaSolid.vrm not found")
        }
        
        // When - call with default options
        let model1 = try await VRMModel.load(from: testVRMURL)
        
        // When - call with explicit default
        let model2 = try await VRMModel.load(from: testVRMURL, options: .default)
        
        // Then - both should load successfully
        XCTAssertNotNil(model1)
        XCTAssertNotNil(model2)
    }
    
    func testProgressReportedOnMainActor() async throws {
        // Given
        guard FileManager.default.fileExists(atPath: testVRMURL.path) else {
            throw XCTSkip("AliciaSolid.vrm not found")
        }
        
        let box = MainThreadBox()
        
        let options = VRMLoadingOptions(
            progressCallback: { @Sendable _ in
                box.set(Thread.isMainThread)
            }
        )
        
        // When
        _ = try await VRMModel.load(from: testVRMURL, options: options)
        
        // Then
        XCTAssertTrue(box.isOnMainThread, "Progress callback should be called on MainActor")
    }
}

// MARK: - Thread-Safe Boxes for Test Data Collection

/// Thread-safe box for collecting progress updates
private final class ProgressBox: @unchecked Sendable {
    private var _updates: [VRMLoadingProgress] = []
    private let lock = NSLock()
    
    var updates: [VRMLoadingProgress] {
        lock.lock()
        defer { lock.unlock() }
        return _updates
    }
    
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return _updates.count
    }
    
    func add(_ progress: VRMLoadingProgress) {
        lock.lock()
        _updates.append(progress)
        lock.unlock()
    }
}

/// Thread-safe box for collecting phases
private final class PhaseBox: @unchecked Sendable {
    private var _phases: Set<VRMLoadingPhase> = []
    private let lock = NSLock()
    
    var phases: Set<VRMLoadingPhase> {
        lock.lock()
        defer { lock.unlock() }
        return _phases
    }
    
    func add(phase: VRMLoadingPhase) {
        lock.lock()
        _phases.insert(phase)
        lock.unlock()
    }
}

/// Thread-safe box for collecting percentages
private final class PercentageBox: @unchecked Sendable {
    private var _percentages: [Int] = []
    private let lock = NSLock()
    
    var percentages: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return _percentages
    }
    
    func add(percentage: Int) {
        lock.lock()
        _percentages.append(percentage)
        lock.unlock()
    }
}

/// Thread-safe counter
private final class CounterBox: @unchecked Sendable {
    private var _count = 0
    private let lock = NSLock()
    
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return _count
    }
    
    func increment() {
        lock.lock()
        _count += 1
        lock.unlock()
    }
}

/// Thread-safe box for main thread check
private final class MainThreadBox: @unchecked Sendable {
    private var _isOnMainThread = false
    private let lock = NSLock()
    
    var isOnMainThread: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isOnMainThread
    }
    
    func set(_ value: Bool) {
        lock.lock()
        _isOnMainThread = value
        lock.unlock()
    }
}

// MARK: - Performance Tests

@MainActor
final class VRMLoadingPerformanceTests: XCTestCase {
    
    private var testVRMURL: URL {
        URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("AliciaSolid.vrm")
    }
    
    func test20MBFileLoadsInUnder2Seconds() async throws {
        // Given
        guard FileManager.default.fileExists(atPath: testVRMURL.path) else {
            throw XCTSkip("AliciaSolid.vrm not found")
        }
        
        let fileSize = try FileManager.default.attributesOfItem(atPath: testVRMURL.path)[.size] as? Int64 ?? 0
        guard fileSize >= 20_000_000 else {
            throw XCTSkip("Test file is smaller than 20MB")
        }
        
        let options = VRMLoadingOptions(
            optimizations: .maximumPerformance
        )
        
        // When
        let startTime = ContinuousClock().now
        _ = try await VRMModel.load(from: testVRMURL, options: options)
        let elapsed = startTime.duration(to: ContinuousClock().now)
        
        // Then
        XCTAssertLessThan(elapsed, .seconds(2), "20MB file should load in under 2 seconds")
    }
    
    func testProgressUpdatesAreThrottled() async throws {
        // Given
        guard FileManager.default.fileExists(atPath: testVRMURL.path) else {
            throw XCTSkip("AliciaSolid.vrm not found")
        }
        
        let interval = 0.1
        let timeBox = TimeBox()
        
        let options = VRMLoadingOptions(
            progressCallback: { @Sendable _ in
                timeBox.add(time: ContinuousClock().now)
            },
            progressUpdateInterval: interval
        )
        
        // When
        _ = try await VRMModel.load(from: testVRMURL, options: options)
        
        // Then - verify throttling
        let times = timeBox.times
        guard times.count >= 2 else { return }
        
        for i in 1..<times.count {
            let timeBetween = times[i-1].duration(to: times[i])
            // Should be at least the interval (with small tolerance)
            XCTAssertGreaterThanOrEqual(
                timeBetween,
                .milliseconds(Int64(interval * 1000) - 10),
                "Updates should be throttled to the specified interval"
            )
        }
    }
}

/// Thread-safe box for time collection
private final class TimeBox: @unchecked Sendable {
    private var _times: [ContinuousClock.Instant] = []
    private let lock = NSLock()
    
    var times: [ContinuousClock.Instant] {
        lock.lock()
        defer { lock.unlock() }
        return _times
    }
    
    func add(time: ContinuousClock.Instant) {
        lock.lock()
        _times.append(time)
        lock.unlock()
    }
}
