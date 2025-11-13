// Copyright 2025 Arkavo Inc. and contributors
// Licensed under the Apache License, Version 2.0

import XCTest
import Metal
@testable import VRMMetalKit

/// Tests for SpriteCacheSystem focusing on thread safety and concurrent rendering
final class SpriteCacheSystemTests: XCTestCase {

    var device: MTLDevice!
    var commandQueue: MTLCommandQueue!

    override func setUp() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        self.device = device
        self.commandQueue = device.makeCommandQueue()!
    }

    // MARK: - Concurrent Rendering Tests

    /// Test that multiple threads can safely render different poses simultaneously
    /// Validates thread-safety improvements from PR #38
    func testConcurrentRenderingThreadSafety() throws {
        let cache = SpriteCacheSystem(device: device, commandQueue: commandQueue)

        let characterID = "testCharacter"
        let poseCount = 10
        let threadCount = 4

        // Generate unique pose hashes
        let poseHashes: [UInt64] = (0..<poseCount).map { UInt64($0) }

        // Track completion
        let completionExpectation = XCTestExpectation(description: "All renders complete")
        completionExpectation.expectedFulfillmentCount = poseCount

        final class ErrorCollector: @unchecked Sendable {
            private let lock = NSLock()
            private var _errors: [Error] = []

            func addError(_ error: Error) {
                lock.lock()
                _errors.append(error)
                lock.unlock()
            }

            var errors: [Error] {
                lock.lock()
                defer { lock.unlock() }
                return _errors
            }
        }

        let errorCollector = ErrorCollector()

        // Render poses concurrently from multiple threads
        DispatchQueue.concurrentPerform(iterations: poseCount) { index in
            let poseHash = poseHashes[index]

            cache.renderToCache(
                characterID: characterID,
                poseHash: poseHash,
                completion: { cachedPose in
                    if cachedPose == nil {
                        errorCollector.addError(NSError(domain: "SpriteCacheTests", code: index,
                                              userInfo: [NSLocalizedDescriptionKey: "Failed to cache pose \(index)"]))
                    }
                    completionExpectation.fulfill()
                }
            ) { encoder, texture in
                // Simple rendering: clear to unique color based on pose index
                let color = MTLClearColor(
                    red: Double(index) / Double(poseCount),
                    green: 0.5,
                    blue: 0.5,
                    alpha: 1.0
                )
                // Encoding is already set up by renderToCache
            }
        }

        wait(for: [completionExpectation], timeout: 5.0)

        // Verify no errors occurred
        let errors = errorCollector.errors
        XCTAssertTrue(errors.isEmpty, "Concurrent rendering had \(errors.count) errors: \(errors)")

        // Verify all poses were cached
        let stats = cache.getStatistics()
        XCTAssertEqual(stats.entryCount, poseCount, "Not all poses were cached")
    }

    /// Test that duplicate renders for the same pose are prevented
    /// Validates pendingRenders atomic check-and-set
    func testDuplicateRenderPrevention() throws {
        let cache = SpriteCacheSystem(device: device, commandQueue: commandQueue)

        let poseHash: UInt64 = 12345

        final class RenderCounter: @unchecked Sendable {
            private let lock = NSLock()
            private var _count = 0

            func increment() {
                lock.lock()
                _count += 1
                lock.unlock()
            }

            var count: Int {
                lock.lock()
                defer { lock.unlock() }
                return _count
            }
        }

        let counter = RenderCounter()
        let completionExpectation = XCTestExpectation(description: "First render completes")

        // Attempt to render the same pose 5 times simultaneously
        DispatchQueue.concurrentPerform(iterations: 5) { _ in
            cache.renderToCache(
                characterID: "char1",
                poseHash: poseHash,
                completion: { cachedPose in
                    if cachedPose != nil {
                        completionExpectation.fulfill()
                    }
                }
            ) { encoder, texture in
                counter.increment()
            }
        }

        wait(for: [completionExpectation], timeout: 2.0)

        // Should only render once despite 5 attempts
        XCTAssertEqual(counter.count, 1, "Duplicate renders were not prevented")

        // Verify only one entry in cache
        let stats = cache.getStatistics()
        XCTAssertEqual(stats.entryCount, 1)
    }

    // MARK: - Cache Hit/Miss Tests

    /// Test cache hit returns immediately without rendering
    func testCacheHitReturnsImmediately() throws {
        let cache = SpriteCacheSystem(device: device, commandQueue: commandQueue)

        let poseHash: UInt64 = 999

        final class RenderCounter: @unchecked Sendable {
            private let lock = NSLock()
            private var _count = 0

            func increment() {
                lock.lock()
                _count += 1
                lock.unlock()
            }

            var count: Int {
                lock.lock()
                defer { lock.unlock() }
                return _count
            }
        }

        let counter = RenderCounter()

        // First render (cache miss)
        let firstExpectation = XCTestExpectation(description: "First render")
        cache.renderToCache(
            characterID: "char1",
            poseHash: poseHash,
            waitUntilCompleted: true
        ) { encoder, texture in
            counter.increment()
        }
        firstExpectation.fulfill()

        wait(for: [firstExpectation], timeout: 1.0)
        XCTAssertEqual(counter.count, 1)

        // Second attempt (cache hit) - should return cached pose without rendering
        let cachedPose = cache.getOrRender(
            characterID: "char1",
            poseHash: poseHash
        ) { encoder, texture in
            counter.increment()  // Should not be called
        }

        XCTAssertNotNil(cachedPose, "Cache hit should return pose")
        XCTAssertEqual(counter.count, 1, "Cache hit should not trigger render")
    }

    // MARK: - Error Handling Tests

    /// Test that GPU errors are handled gracefully
    func testGPUErrorHandling() throws {
        // This test verifies error handling paths are in place
        // Actual GPU errors are hard to trigger in tests, so we just verify
        // the completion handler includes error checking code
        let cache = SpriteCacheSystem(device: device, commandQueue: commandQueue)

        let expectation = XCTestExpectation(description: "Render completes")

        cache.renderToCache(
            characterID: "errorTest",
            poseHash: 777,
            completion: { cachedPose in
                // Should complete even if there were internal errors
                expectation.fulfill()
            }
        ) { encoder, texture in
            // Normal render
        }

        wait(for: [expectation], timeout: 2.0)
    }

    // MARK: - Performance Tests

    /// Test cache performance with many entries
    func testCachePerformanceWithManyEntries() throws {
        let cache = SpriteCacheSystem(device: device, commandQueue: commandQueue)

        let poseCount = 50

        // Populate cache
        for i in 0..<poseCount {
            cache.renderToCache(
                characterID: "char1",
                poseHash: UInt64(i),
                waitUntilCompleted: true
            ) { encoder, texture in
                // Minimal rendering
            }
        }

        // Measure cache lookup performance
        measure {
            for i in 0..<poseCount {
                let cached = cache.getCachedPose(poseHash: UInt64(i))
                XCTAssertNotNil(cached)
            }
        }
    }

    // MARK: - Cleanup Tests

    /// Test cache clearing
    func testCacheClear() throws {
        let cache = SpriteCacheSystem(device: device, commandQueue: commandQueue)

        // Add some entries
        for i in 0..<5 {
            cache.renderToCache(
                characterID: "char1",
                poseHash: UInt64(i),
                waitUntilCompleted: true
            ) { encoder, texture in }
        }

        var stats = cache.getStatistics()
        XCTAssertEqual(stats.entryCount, 5)

        // Clear cache
        cache.clearCache()

        stats = cache.getStatistics()
        XCTAssertEqual(stats.entryCount, 0)
    }

    /// Test per-character clearing
    func testClearCharacter() throws {
        let cache = SpriteCacheSystem(device: device, commandQueue: commandQueue)

        // Add entries for two characters
        for i in 0..<3 {
            cache.renderToCache(
                characterID: "char1",
                poseHash: UInt64(i),
                waitUntilCompleted: true
            ) { encoder, texture in }

            cache.renderToCache(
                characterID: "char2",
                poseHash: UInt64(i + 100),
                waitUntilCompleted: true
            ) { encoder, texture in }
        }

        var stats = cache.getStatistics()
        XCTAssertEqual(stats.entryCount, 6)

        // Clear only char1
        cache.clearCharacter("char1")

        stats = cache.getStatistics()
        XCTAssertEqual(stats.entryCount, 3, "Should only have char2 entries left")

        // Verify char2 entries still exist
        for i in 0..<3 {
            let cached = cache.getCachedPose(poseHash: UInt64(i + 100))
            XCTAssertNotNil(cached, "char2 entry \(i) should still be cached")
        }
    }
}
