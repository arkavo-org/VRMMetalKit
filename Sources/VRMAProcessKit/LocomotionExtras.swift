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

/// The locomotion metadata contract — glTF `extras.arkavo` on animations[0].
/// `strideSpeed: 0` is the explicit idle value; ABSENCE of the block means
/// "not a locomotion clip". `version` hedges the one cross-repo contract.
public struct LocomotionExtras: Equatable {
    /// Error thrown by ``write(into:)``.
    public enum WriteError: Error { case noAnimation }

    public var version: Int = 1
    public var strideSpeed: Float
    public var inPlace: Bool
    public var sourceHipsHeight: Float

    public init(strideSpeed: Float, inPlace: Bool, sourceHipsHeight: Float) {
        self.strideSpeed = strideSpeed
        self.inPlace = inPlace
        self.sourceHipsHeight = sourceHipsHeight
    }

    /// Reads locomotion metadata from `animations[0].extras.arkavo`.
    /// Unknown versions read as nil — same semantics as absence.
    public static func read(from container: GLBContainer) -> LocomotionExtras? {
        guard let anims = container.json["animations"] as? [[String: Any]],
              let extras = anims.first?["extras"] as? [String: Any],
              let arkavo = extras["arkavo"] as? [String: Any],
              let version = arkavo["version"] as? Int,
              let stride = (arkavo["strideSpeed"] as? NSNumber)?.floatValue,
              let inPlace = arkavo["inPlace"] as? Bool,
              let hipsH = (arkavo["sourceHipsHeight"] as? NSNumber)?.floatValue
        else { return nil }
        // Only version 1 is understood; any other version reads as absent.
        guard version == 1 else { return nil }
        var m = LocomotionExtras(strideSpeed: stride, inPlace: inPlace, sourceHipsHeight: hipsH)
        m.version = version
        return m
    }

    public func write(into container: inout GLBContainer) throws {
        guard var anims = container.json["animations"] as? [[String: Any]], !anims.isEmpty else {
            throw WriteError.noAnimation
        }
        var extras = anims[0]["extras"] as? [String: Any] ?? [:]
        extras["arkavo"] = [
            "version": version,
            "strideSpeed": strideSpeed,
            "inPlace": inPlace,
            "sourceHipsHeight": sourceHipsHeight,
        ] as [String: Any]
        anims[0]["extras"] = extras
        container.json["animations"] = anims
    }
}
