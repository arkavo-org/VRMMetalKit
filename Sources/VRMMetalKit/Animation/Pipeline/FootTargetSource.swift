//
// Copyright 2025 Arkavo
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
import simd

/// Where S3 gets its world-space foot targets.
///
/// The seam the interaction-volume RFC binds to. Day one this is the existing
/// `FootContactDetector` — the *when* of planting (a lock/unlock state machine
/// over foot velocity and height) is unchanged; only the *source of the target*
/// becomes swappable. A volume-backed implementation answers from the host's
/// spatial index instead, which is what makes real-floor planting and terrain
/// planting the same code.
public protocol FootTargetSource: AnyObject {
    /// Advances the source with this frame's measured foot positions.
    func update(leftFootPos: SIMD3<Float>, rightFootPos: SIMD3<Float>, deltaTime: Float)
    /// The world-space target for a planted foot, or `nil` when that foot is free.
    func plantedTarget(_ foot: BalanceModel.Foot) -> SIMD3<Float>?
}

/// The behaviour-preserving adapter: `FootContactDetector` behind the protocol.
public final class DetectorFootTargetSource: FootTargetSource {
    private let detector: FootContactDetector

    public init(detector: FootContactDetector = FootContactDetector()) {
        self.detector = detector
    }

    public func update(leftFootPos: SIMD3<Float>, rightFootPos: SIMD3<Float>, deltaTime: Float) {
        detector.update(leftFootPos: leftFootPos, rightFootPos: rightFootPos, deltaTime: deltaTime)
    }

    public func plantedTarget(_ foot: BalanceModel.Foot) -> SIMD3<Float>? {
        switch foot {
        case .left:  return detector.isLeftFootPlanted ? detector.leftFootPlantedPosition : nil
        case .right: return detector.isRightFootPlanted ? detector.rightFootPlantedPosition : nil
        }
    }
}
