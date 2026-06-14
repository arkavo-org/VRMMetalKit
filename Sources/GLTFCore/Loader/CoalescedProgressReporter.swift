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

/// Coalesces per-item progress into at most `maxReports` hops to the main actor.
///
/// The parallel loaders complete one item per loop iteration; reporting on every
/// completion floods `MainActor` with a hop per mesh/texture. This batches the
/// callback to fire roughly every `total / maxReports` completions plus a
/// guaranteed final report. For `total < maxReports` the batch size is 1, so small
/// loads still report every item.
struct CoalescedProgressReporter {
    private let total: Int
    private let batchSize: Int
    private let callback: (@Sendable (Int, Int) -> Void)?

    init(total: Int, maxReports: Int = 20, callback: (@Sendable (Int, Int) -> Void)?) {
        self.total = total
        self.batchSize = max(1, total / max(1, maxReports))
        self.callback = callback
    }

    /// Reports `(completed, total)` on the main actor iff this completion lands on a
    /// batch boundary or is the final one. No-op when no callback was supplied.
    func reportIfNeeded(completed: Int) async {
        guard let callback else { return }
        if completed % batchSize == 0 || completed == total {
            let snapshot = completed
            await MainActor.run { callback(snapshot, total) }
        }
    }
}
