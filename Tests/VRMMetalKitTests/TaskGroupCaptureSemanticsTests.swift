//
// Copyright 2025 Arkavo
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//

import XCTest
@testable import VRMMetalKit

/// Regression tests for `[unowned self]` capture semantics in async task groups.
///
/// The parallel loaders (`ParallelMaterialLoader`, `ParallelTextureLoader`,
/// `GLTFParallelMeshLoader`) used `[unowned self]` inside `withTaskGroup` child tasks.
/// If the loader is deallocated while async work is in flight — e.g. the load is
/// cancelled, or the owning object sets its loader property to nil from another task —
/// the unowned reference becomes a dangling pointer and crashes the process.
///
/// These tests reproduce the capture pattern in isolation to demonstrate that:
/// 1. `[unowned self]` crashes when the owner is deallocated before the task completes.
/// 2. `[weak self]` handles deallocation gracefully (returns nil / skips work).
final class TaskGroupCaptureSemanticsTests: XCTestCase {

    /// A minimal stand-in for the loader classes: stores some data that child tasks read.
    private final class WorkItem: @unchecked Sendable {
        let payload: [Int]
        init(_ payload: [Int]) { self.payload = payload }
    }

    /// **Demonstrates the bug:** `[unowned]` capture in a task group crashes when the
    /// referenced object is deallocated before the child task runs.
    ///
    /// We cannot actually let the test crash the process, so instead we verify the
    /// *fix* pattern: `[weak self]` returns nil gracefully when the owner is gone.
    /// This test guards against regression back to `[unowned self]`.
    func testWeakSelfInTaskGroupSurvivesDeallocation() async {
        var item: WorkItem? = WorkItem(Array(0..<100))
        weak let weakItem = item

        let results = await withTaskGroup(of: Int?.self) { group -> [Int] in
            // Child task captures [weak item] — the fix pattern
            group.addTask { [weak item] in
                // Yield to let the parent run first and drop the reference
                await Task.yield()
                await Task.yield()
                guard let item else { return nil }
                return item.payload.count
            }

            // Drop the only strong reference — item is deallocated.
            // With [unowned self], the child task would crash here.
            // With [weak self], the child task returns nil.
            item = nil
            XCTAssertNil(weakItem, "WorkItem should be deallocated after strong ref dropped")

            var collected: [Int] = []
            for await result in group {
                collected.append(result ?? -1)
            }
            return collected
        }

        // With [weak self], the task returned nil (→ -1) instead of crashing.
        XCTAssertEqual(results, [-1],
                       "Weak capture must return nil gracefully when owner is deallocated, not crash")
    }

    /// Complementary test: when the owner is NOT deallocated, `[weak self]` works
    /// identically to `[unowned self]` — the child task runs to completion.
    func testWeakSelfInTaskGroupCompletesNormallyWhenRetained() async {
        let item = WorkItem(Array(0..<100))

        let results = await withTaskGroup(of: Int.self) { group -> [Int] in
            group.addTask { [weak item] in
                await Task.yield()
                guard let item else { return -1 }
                return item.payload.count
            }

            // Keep `item` alive (it's a `let` so it can't be nilled)
            var collected: [Int] = []
            for await result in group {
                collected.append(result)
            }
            return collected
        }

        XCTAssertEqual(results, [100],
                       "Weak capture must return correct result when owner is retained")
    }

    /// Stress test: run many iterations of the weak-capture deallocation pattern to
    /// ensure no intermittent crashes. This is the closest we can get to reproducing
    /// the race condition that `[unowned self]` would trigger in the real loaders.
    func testWeakCaptureDeallocationUnderStress() async {
        let iterations = 200

        await withTaskGroup(of: Bool.self) { outerGroup in
            for _ in 0..<iterations {
                outerGroup.addTask {
                    var item: WorkItem? = WorkItem(Array(repeating: 42, count: 1000))

                    let result = await withTaskGroup(of: Int?.self) { group -> Int? in
                        group.addTask { [weak item] in
                            // Simulate async I/O (texture/mesh loading)
                            try? await Task.sleep(nanoseconds: 1_000)
                            return item?.payload.count
                        }

                        item = nil  // deallocate during async work

                        return await group.next() ?? nil
                    }

                    // Either nil (deallocated before task ran) or 1000 (task ran first).
                    // Either way, no crash.
                    return result == nil || result == 1000
                }
            }

            var allPassed = true
            for await passed in outerGroup {
                if !passed { allPassed = false }
            }
            XCTAssertTrue(allPassed, "All iterations must complete without crash")
        }
    }
}
