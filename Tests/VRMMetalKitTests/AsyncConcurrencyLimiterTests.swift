// Copyright 2026 Arkavo Inc. and contributors
// Licensed under the Apache License, Version 2.0

import XCTest
@testable import VRMMetalKit

final class AsyncConcurrencyLimiterTests: XCTestCase {

    /// Tracks the maximum number of permit holders observed simultaneously.
    private actor PeakTracker {
        private(set) var current = 0
        private(set) var peak = 0
        func enter() { current += 1; peak = max(peak, current) }
        func leave() { current -= 1 }
    }

    /// Many tasks gated by a limit-N semaphore must never have more than N running
    /// at once, and all must complete (no permit leak / deadlock).
    func testLimiterBoundsPeakConcurrency() async {
        let limit = 4
        let taskCount = 64
        let limiter = AsyncConcurrencyLimiter(limit: limit)
        let tracker = PeakTracker()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<taskCount {
                group.addTask {
                    try? await limiter.acquire()  // never cancelled here
                    await tracker.enter()
                    // Yield a few times so overlap actually has a chance to occur.
                    for _ in 0..<5 { await Task.yield() }
                    await tracker.leave()
                    await limiter.release()
                }
            }
        }

        let peak = await tracker.peak
        XCTAssertLessThanOrEqual(peak, limit, "peak concurrency \(peak) exceeded limit \(limit)")
        XCTAssertGreaterThan(peak, 1, "limiter serialized everything — expected real overlap up to the limit")
        let leftover = await tracker.current
        XCTAssertEqual(leftover, 0, "not all permit holders left — possible leak/deadlock")
    }

    /// A limit of 1 must fully serialize: peak concurrency is exactly 1.
    func testLimiterOfOneSerializes() async {
        let limiter = AsyncConcurrencyLimiter(limit: 1)
        let tracker = PeakTracker()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<16 {
                group.addTask {
                    try? await limiter.acquire()  // never cancelled here
                    await tracker.enter()
                    await Task.yield()
                    await tracker.leave()
                    await limiter.release()
                }
            }
        }
        let peak = await tracker.peak
        XCTAssertEqual(peak, 1, "limit-1 limiter must serialize (peak \(peak))")
    }

    /// A non-positive limit is clamped to 1 rather than blocking forever: one
    /// acquire/release round-trip must complete.
    func testLimiterClampsToAtLeastOne() async throws {
        let limiter = AsyncConcurrencyLimiter(limit: 0)
        try await limiter.acquire()  // must not hang — at least one permit exists
        await limiter.release()
    }

    /// A task cancelled while waiting for a permit must unwind with
    /// `CancellationError` rather than hang forever (the bug a non-cancellable
    /// `withCheckedContinuation` would have). The permit holder never releases, so
    /// the only way the waiter finishes is via cancellation.
    func testAcquireUnwindsOnCancellation() async throws {
        let limiter = AsyncConcurrencyLimiter(limit: 1)
        try await limiter.acquire()  // take the only permit; never released

        let waiter = Task {
            try await limiter.acquire()  // no permit available → suspends
        }
        // Give the waiter time to register as a waiter before cancelling.
        try await Task.sleep(nanoseconds: 20_000_000)
        waiter.cancel()

        do {
            try await waiter.value
            XCTFail("expected the cancelled waiter to throw")
        } catch is CancellationError {
            // success — unwound cleanly, no hang
        }
    }

    /// After a waiter is cancelled, a subsequent release must still hand the permit
    /// to a live waiter (the cancelled one was removed from the queue, not skipped).
    func testReleaseAfterCancellationWakesLiveWaiter() async throws {
        let limiter = AsyncConcurrencyLimiter(limit: 1)
        try await limiter.acquire()  // hold the permit

        let cancelled = Task { try await limiter.acquire() }
        try await Task.sleep(nanoseconds: 10_000_000)
        let live = Task { try await limiter.acquire() }
        try await Task.sleep(nanoseconds: 10_000_000)

        cancelled.cancel()
        _ = try? await cancelled.value          // unwinds with CancellationError
        await limiter.release()                 // must wake `live`, not no-op
        try await live.value                    // must not hang
        await limiter.release()
    }
}
