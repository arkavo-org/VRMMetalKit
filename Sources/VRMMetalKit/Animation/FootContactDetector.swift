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

/// Detects when a foot is planted (contact phase) vs moving (swing phase).
///
/// Uses velocity and height thresholds with hysteresis to prevent flickering
/// between planted and moving states.
public final class FootContactDetector {

    /// Configuration for contact detection
    public struct Config {
        /// Maximum velocity (m/s) for foot to be considered planted
        public var velocityThreshold: Float

        /// Maximum height (m) above ground for foot to be considered planted
        public var heightThreshold: Float

        /// Minimum frames a foot must stay in a state before transitioning (hysteresis)
        public var minFramesInState: Int

        /// Ground Y position in world space
        public var groundY: Float

        public init(
            velocityThreshold: Float = 0.05,
            heightThreshold: Float = 0.02,
            minFramesInState: Int = 3,
            groundY: Float = 0.0
        ) {
            self.velocityThreshold = velocityThreshold
            self.heightThreshold = heightThreshold
            self.minFramesInState = minFramesInState
            self.groundY = groundY
        }
    }

    /// Current contact state for a foot
    public struct FootState {
        /// Whether the foot is currently planted
        public private(set) var isPlanted: Bool

        /// World position where foot was planted (nil if not planted)
        public private(set) var plantedPosition: SIMD3<Float>?

        /// Number of consecutive frames in current state
        public private(set) var framesInState: Int

        /// Previous frame's position for velocity calculation
        fileprivate var previousPosition: SIMD3<Float>?

        public init() {
            self.isPlanted = false
            self.plantedPosition = nil
            self.framesInState = 0
            self.previousPosition = nil
        }

        mutating func setPlanted(_ planted: Bool, position: SIMD3<Float>?) {
            if planted != isPlanted {
                isPlanted = planted
                framesInState = 0
            } else {
                framesInState += 1
            }
            plantedPosition = planted ? position : nil
        }

        mutating func incrementFrameCount() {
            framesInState += 1
        }
    }

    public var config: Config
    public private(set) var leftFootState: FootState
    public private(set) var rightFootState: FootState

    public init(config: Config = Config()) {
        self.config = config
        self.leftFootState = FootState()
        self.rightFootState = FootState()
    }

    /// Update contact detection for both feet.
    ///
    /// - Parameters:
    ///   - leftFootPos: Current world position of left foot
    ///   - rightFootPos: Current world position of right foot
    ///   - deltaTime: Time since last update
    public func update(
        leftFootPos: SIMD3<Float>,
        rightFootPos: SIMD3<Float>,
        deltaTime: Float
    ) {
        updateFoot(
            currentPos: leftFootPos,
            state: &leftFootState,
            deltaTime: deltaTime
        )
        updateFoot(
            currentPos: rightFootPos,
            state: &rightFootState,
            deltaTime: deltaTime
        )
    }

    /// Reset detector state (call when animation changes)
    public func reset() {
        leftFootState = FootState()
        rightFootState = FootState()
    }

    private func updateFoot(
        currentPos: SIMD3<Float>,
        state: inout FootState,
        deltaTime: Float
    ) {
        var velocity: Float = 0
        if let prevPos = state.previousPosition, deltaTime > 0 {
            velocity = simd_length(currentPos - prevPos) / deltaTime
        }

        let heightAboveGround = currentPos.y - config.groundY
        let shouldBePlanted = velocity < config.velocityThreshold
            && heightAboveGround < config.heightThreshold

        if shouldBePlanted != state.isPlanted {
            if state.framesInState >= config.minFramesInState {
                state.setPlanted(shouldBePlanted, position: shouldBePlanted ? currentPos : nil)
            } else {
                state.incrementFrameCount()
            }
        } else {
            state.incrementFrameCount()
            if state.isPlanted && state.plantedPosition == nil {
                state.setPlanted(true, position: currentPos)
            }
        }

        state.previousPosition = currentPos
    }

    /// Check if left foot is planted
    public var isLeftFootPlanted: Bool {
        leftFootState.isPlanted
    }

    /// Check if right foot is planted
    public var isRightFootPlanted: Bool {
        rightFootState.isPlanted
    }

    /// Get locked position for left foot (nil if not planted)
    public var leftFootPlantedPosition: SIMD3<Float>? {
        leftFootState.plantedPosition
    }

    /// Get locked position for right foot (nil if not planted)
    public var rightFootPlantedPosition: SIMD3<Float>? {
        rightFootState.plantedPosition
    }
}
