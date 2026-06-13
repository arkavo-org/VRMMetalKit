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
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// - Parameter limit: Maximum number of permits held at once (clamped to >= 1).
    public init(limit: Int) {
        self.available = max(1, limit)
    }

    /// Suspends until a permit is available, then takes it. Pair with ``release()``.
    public func acquire() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    /// Returns a permit, waking the longest-waiting acquirer if any.
    public func release() {
        if waiters.isEmpty {
            available += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}
