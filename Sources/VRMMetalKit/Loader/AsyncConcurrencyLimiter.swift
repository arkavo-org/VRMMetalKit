//
// Copyright 2026 Arkavo
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

/// An async counting semaphore that bounds how many concurrent operations run at
/// once, without blocking a thread (unlike `DispatchSemaphore`, which would stall
/// the cooperative pool).
///
/// Used to give the parallel loader a **true global** bound on in-flight primitive
/// decodes: one limiter is shared by every primitive decode across every mesh, so
/// total concurrency is capped regardless of how the across-mesh and intra-mesh
/// task groups multiply.
///
/// Deadlock safety: acquire a permit **only at the leaf work** (the primitive
/// decode), never on the orchestration tasks that spawn and await children. A
/// parent that held a permit while awaiting children could starve the children of
/// permits and deadlock; because mesh-orchestration tasks hold none, the only
/// permit holders are the leaf decodes themselves, so progress is guaranteed.
public actor AsyncConcurrencyLimiter {
    private var available: Int
    private var waiters: [(id: Int, continuation: CheckedContinuation<Void, Error>)] = []
    private var nextWaiterID = 0

    /// - Parameter limit: Maximum number of permits held at once (clamped to >= 1).
    public init(limit: Int) {
        self.available = max(1, limit)
    }

    /// Suspends until a permit is available, then takes it. Pair with ``release()``.
    ///
    /// Cancellation-aware: if the calling task is cancelled while waiting, the
    /// wait is abandoned and `CancellationError` is thrown (no permit is taken, no
    /// continuation is leaked). A permit IS taken only on a non-throwing return.
    public func acquire() async throws {
        try Task.checkCancellation()
        if available > 0 {
            available -= 1
            return
        }
        let id = nextWaiterID
        nextWaiterID += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // Re-check under actor isolation: a cancel that lands between the
                // top-of-function check and here (or whose onCancel ran before this
                // closure) must resume immediately rather than enqueue a waiter that
                // nothing will ever wake.
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append((id, continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: Int) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let continuation = waiters.remove(at: index).continuation
        continuation.resume(throwing: CancellationError())
    }

    /// Returns a permit, waking the longest-waiting acquirer if any (FIFO).
    public func release() {
        if waiters.isEmpty {
            available += 1
        } else {
            waiters.removeFirst().continuation.resume(returning: ())
        }
    }
}
