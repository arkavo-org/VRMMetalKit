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

/// Decides whether last frame's morph compute output can be reused.
enum MorphComputeGate {
    /// `true` when the expression-weight fingerprint matches the one that
    /// produced the already-resident morphed buffers. The first frame has
    /// no previous fingerprint and must encode.
    static func shouldReusePreviousOutput(
        currentFingerprint: UInt64,
        previousFingerprint: UInt64?
    ) -> Bool {
        previousFingerprint == currentFingerprint
    }
}
