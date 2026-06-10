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

/// The single-pass ingest pipeline from the locomotion spec §3:
/// measure → write extras → strip hips XZ → strip non-humanoid → loop-trim.
public enum LocomotionIngest {
    public enum Mode { case auto, idle, walk }
    /// Below this measured speed (m/s) a clip auto-classifies as idle.
    public static let idleThreshold: Float = 0.1

    public enum IngestError: Error, CustomStringConvertible {
        case walkClipMeasuresStationary(measured: Float)
        public var description: String {
            switch self {
            case .walkClipMeasuresStationary(let m):
                return "walk clip measures \(m) m/s hips travel — below the idle threshold (\(LocomotionIngest.idleThreshold)). An already-in-place walk needs an authored stride speed; a --stride override is not implemented yet."
            }
        }
    }

    public static func process(glb: Data, mode: Mode) throws -> Data {
        var container = try GLBContainer(data: glb)
        let inspector = try VRMAClipInspector(container: container)

        // Measure FIRST — the strip below erases exactly what we measure.
        let measured = try inspector.meanHipsXZSpeed()
        if mode == .walk, measured < idleThreshold {
            throw IngestError.walkClipMeasuresStationary(measured: measured)
        }
        let isIdle = mode == .idle || (mode == .auto && measured < idleThreshold)
        let meta = LocomotionExtras(
            strideSpeed: isIdle ? 0 : measured,
            inPlace: true,
            sourceHipsHeight: try inspector.hipsRestHeight()
        )
        try meta.write(into: &container)

        var editor = VRMAClipEditor(container: container)
        try editor.stripHipsXZ()
        try editor.stripNonHumanoidChannels()
        try editor.loopTrim()  // pose-similarity works for idle and walk alike
        container = editor.container
        return try container.serialize()
    }
}
