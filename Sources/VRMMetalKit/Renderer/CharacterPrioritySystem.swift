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
import Metal
import simd

/// Allocates a GPU budget across many on-screen avatars: main speaker stays 3D, background characters fall back to cached sprites.
///
/// ## Discussion
/// Used together with ``SpriteCacheSystem`` for scenes with more avatars than
/// the GPU can render at full 3D every frame. Hosts register characters,
/// tag each one with a ``CharacterRole``, and call
/// ``computeRenderingDecisions(cameraPosition:deltaTime:)`` once per frame.
/// The result is a dictionary of `characterID -> RenderingDecision` the host
/// uses to pick between full 3D rendering and sprite cache lookup.
///
/// Role transitions are guarded by ``roleChangeHysteresisMs`` to prevent
/// flickering when a character oscillates between roles.
public class CharacterPrioritySystem {

    // MARK: - Character Role

    /// Role a character plays in the current scene; drives priority and rendering-mode allocation.
    public enum CharacterRole {
        /// Primary character that is speaking; always rendered as full 3D.
        case mainSpeaker
        /// Active listener reacting to dialogue; rendered as full 3D when the budget allows.
        case listener
        /// Inactive or background character; rendered as a cached sprite when possible.
        case background
        /// Not visible in the current frame; skipped entirely.
        case offscreen
    }

    // MARK: - Character State

    /// Per-character state used to compute a rendering decision (position, role, animation flag, hysteresis timer).
    public struct CharacterState {
        /// Stable identifier supplied by the host.
        public let characterID: String

        /// Human-readable name for debugging.
        public let displayName: String

        /// Current scene role.
        public var role: CharacterRole

        /// World-space position; updated each frame via ``CharacterPrioritySystem/updateCharacterPosition(characterID:position:)``.
        public var position: SIMD3<Float>

        /// Distance from the camera, refreshed inside ``CharacterPrioritySystem/computeRenderingDecisions(cameraPosition:deltaTime:)``.
        public var distanceFromCamera: Float

        /// Whether the character is currently playing animation. Static characters can stay on cached sprites longer.
        public var isAnimating: Bool

        /// Seconds since the role last changed; used to enforce ``CharacterPrioritySystem/roleChangeHysteresisMs``.
        public var timeSinceRoleChange: TimeInterval

        /// Most recent ``RenderingDecision`` emitted for this character.
        public var preferredMode: RenderingDecision

        /// Creates a character state with the given identifier. The role defaults to ``CharacterRole/background``.
        public init(
            characterID: String,
            displayName: String,
            role: CharacterRole = .background,
            position: SIMD3<Float> = SIMD3<Float>(0, 0, 0),
            distanceFromCamera: Float = 0,
            isAnimating: Bool = false
        ) {
            self.characterID = characterID
            self.displayName = displayName
            self.role = role
            self.position = position
            self.distanceFromCamera = distanceFromCamera
            self.isAnimating = isAnimating
            self.timeSinceRoleChange = 0
            self.preferredMode = .cached
        }
    }

    // MARK: - Rendering Decision

    /// What the host should do with a character this frame.
    public enum RenderingDecision {
        /// Render the full 3D avatar.
        case full3D
        /// Display a cached sprite from ``SpriteCacheSystem``.
        case cached
        /// Skip the character entirely (off-screen or below visibility threshold).
        case skip
    }

    // MARK: - Performance Budget

    /// Per-frame GPU budget used to allocate render slots between full-3D and cached-sprite characters.
    public struct PerformanceBudget {
        /// Target total frame time in milliseconds. `16.6` ms = 60 FPS, `33.3` ms = 30 FPS.
        public var targetFrameTimeMs: Float = 16.6

        /// Maximum number of characters allowed to render as full 3D before falling back to cached sprites.
        public var maxFull3DCharacters: Int = 3

        /// GPU budget reserved for the main speaker, in milliseconds.
        public var mainSpeakerBudgetMs: Float = 8.0

        /// GPU budget per listener, in milliseconds.
        public var listenerBudgetMs: Float = 4.0

        /// Combined GPU budget for all sprite-cache draws, in milliseconds.
        public var spriteBudgetMs: Float = 4.0

        /// Distance thresholds (near, medium, far) used by ``CharacterPrioritySystem/enableDistanceLOD``.
        public var lodDistances: [Float] = [5.0, 10.0, 20.0]

        /// Creates a budget with default values matching a 60 FPS dialogue scene.
        public init() {}
    }

    // MARK: - Properties

    /// All characters in the scene
    private var characters: [String: CharacterState] = [:]

    /// Active per-frame GPU budget.
    public var budget: PerformanceBudget

    /// Minimum time (in milliseconds) between role changes for the same character; prevents flickering decisions.
    public var roleChangeHysteresisMs: TimeInterval = 200

    /// When `true`, background characters closer than the first ``PerformanceBudget/lodDistances`` threshold may be promoted to full 3D.
    public var enableDistanceLOD: Bool = true

    // MARK: - Initialization

    /// Creates a priority system with the given budget. Defaults to a balanced multi-character configuration.
    public init(budget: PerformanceBudget = PerformanceBudget()) {
        self.budget = budget
    }

    // MARK: - Character Management

    /// Registers a character so subsequent calls to ``computeRenderingDecisions(cameraPosition:deltaTime:)`` consider it.
    public func registerCharacter(
        characterID: String,
        displayName: String,
        position: SIMD3<Float> = SIMD3<Float>(0, 0, 0)
    ) {
        characters[characterID] = CharacterState(
            characterID: characterID,
            displayName: displayName,
            position: position
        )
        vrmLog("[CharacterPriority] Registered character '\(displayName)' (ID: \(characterID))")
    }

    /// Removes a character from the priority system. Subsequent decisions ignore it.
    public func unregisterCharacter(characterID: String) {
        characters.removeValue(forKey: characterID)
        vrmLog("[CharacterPriority] Unregistered character (ID: \(characterID))")
    }

    /// Changes a character's ``CharacterRole``. Resets the hysteresis timer for the affected character.
    public func updateCharacterRole(characterID: String, role: CharacterRole) {
        guard var character = characters[characterID] else {
            vrmLog("[CharacterPriority] Warning: Character '\(characterID)' not registered")
            return
        }

        if character.role != role {
            character.role = role
            character.timeSinceRoleChange = 0
            characters[characterID] = character
            vrmLog("[CharacterPriority] Updated '\(character.displayName)' role to \(role)")
        }
    }

    /// Updates a character's world-space position. Called each frame so distance-based LOD is current.
    public func updateCharacterPosition(characterID: String, position: SIMD3<Float>) {
        guard var character = characters[characterID] else { return }
        character.position = position
        characters[characterID] = character
    }

    /// Marks whether a character is currently animating. Static characters can stay on cached sprites longer.
    public func updateCharacterAnimating(characterID: String, isAnimating: Bool) {
        guard var character = characters[characterID] else { return }
        character.isAnimating = isAnimating
        characters[characterID] = character
    }

    // MARK: - Priority Computation

    /// Compute rendering decisions for all characters
    /// - Parameters:
    ///   - cameraPosition: Current camera position
    ///   - deltaTime: Time since last frame (for hysteresis)
    /// - Returns: Dictionary of characterID -> RenderingDecision
    public func computeRenderingDecisions(
        cameraPosition: SIMD3<Float>,
        deltaTime: TimeInterval
    ) -> [String: RenderingDecision] {
        var decisions: [String: RenderingDecision] = [:]

        // Update distances from camera
        updateDistancesFromCamera(cameraPosition)

        // Update hysteresis timers
        updateHysteresis(deltaTime: deltaTime)

        // Sort characters by priority
        let sortedCharacters = sortByPriority()

        // Allocate rendering slots
        var full3DCount = 0

        for character in sortedCharacters {
            let decision = determineRenderingMode(
                character: character,
                full3DCount: full3DCount
            )

            decisions[character.characterID] = decision

            if decision == .full3D {
                full3DCount += 1
            }

            // Update preferred mode
            if var updatedChar = characters[character.characterID] {
                updatedChar.preferredMode = decision
                characters[character.characterID] = updatedChar
            }
        }

        return decisions
    }

    /// Update distances from camera for all characters
    private func updateDistancesFromCamera(_ cameraPosition: SIMD3<Float>) {
        for (id, var character) in characters {
            let distance = simd_distance(character.position, cameraPosition)
            character.distanceFromCamera = distance
            characters[id] = character
        }
    }

    /// Update hysteresis timers
    private func updateHysteresis(deltaTime: TimeInterval) {
        for (id, var character) in characters {
            character.timeSinceRoleChange += deltaTime
            characters[id] = character
        }
    }

    /// Sort characters by priority (highest first)
    private func sortByPriority() -> [CharacterState] {
        return characters.values.sorted { char1, char2 in
            // Priority order: mainSpeaker > listener > background > offscreen
            let priority1 = rolePriority(char1.role)
            let priority2 = rolePriority(char2.role)

            if priority1 != priority2 {
                return priority1 > priority2
            }

            // If same priority, prefer closer characters
            return char1.distanceFromCamera < char2.distanceFromCamera
        }
    }

    /// Get priority score for a role (higher = more important)
    private func rolePriority(_ role: CharacterRole) -> Int {
        switch role {
        case .mainSpeaker: return 100
        case .listener: return 50
        case .background: return 10
        case .offscreen: return 0
        }
    }

    /// Determine rendering mode for a character
    private func determineRenderingMode(
        character: CharacterState,
        full3DCount: Int
    ) -> RenderingDecision {
        // Offscreen characters are skipped
        if character.role == .offscreen {
            return .skip
        }

        // Main speaker always gets full 3D (highest priority)
        if character.role == .mainSpeaker {
            return .full3D
        }

        // Check if we're over budget for full 3D
        if full3DCount >= budget.maxFull3DCharacters {
            return .cached
        }

        // Listeners get full 3D if budget allows
        if character.role == .listener {
            // Apply hysteresis: don't change mode too quickly
            if character.timeSinceRoleChange < roleChangeHysteresisMs / 1000.0 {
                return character.preferredMode
            }
            return .full3D
        }

        // Distance-based LOD for background characters
        if enableDistanceLOD {
            if character.distanceFromCamera < budget.lodDistances[0] {
                // Very close background characters can be full 3D if budget allows
                return .full3D
            }
        }

        // Default: use cached sprite
        return .cached
    }

    // MARK: - Statistics

    /// Returns a snapshot of how many characters are currently full 3D, cached, or skipped.
    public func getStatistics() -> PriorityStatistics {
        let decisions = computeRenderingDecisions(
            cameraPosition: SIMD3<Float>(0, 0, 5),  // Dummy position
            deltaTime: 0
        )

        let full3DCount = decisions.values.filter { $0 == .full3D }.count
        let cachedCount = decisions.values.filter { $0 == .cached }.count
        let skippedCount = decisions.values.filter { $0 == .skip }.count

        return PriorityStatistics(
            totalCharacters: characters.count,
            full3DCharacters: full3DCount,
            cachedCharacters: cachedCount,
            skippedCharacters: skippedCount
        )
    }

    /// Snapshot of character-bucket counts returned by ``getStatistics()``.
    public struct PriorityStatistics {
        /// Total characters registered with the priority system.
        public let totalCharacters: Int
        /// Number of characters rendered as full 3D this frame.
        public let full3DCharacters: Int
        /// Number of characters rendered as cached sprites this frame.
        public let cachedCharacters: Int
        /// Number of characters skipped (off-screen).
        public let skippedCharacters: Int

        /// Multi-line human-readable summary suitable for log output.
        public var description: String {
            return """
            Character Priority Statistics:
              Total: \(totalCharacters)
              Full 3D: \(full3DCharacters)
              Cached: \(cachedCharacters)
              Skipped: \(skippedCharacters)
            """
        }
    }

    // MARK: - Scene Presets

    /// Configures a typical dialogue scene: one main speaker, a few listeners, the rest as background.
    ///
    /// - Parameters:
    ///   - mainSpeakerID: Character to flag as ``CharacterRole/mainSpeaker``.
    ///   - listenerIDs: Characters to flag as ``CharacterRole/listener``; everyone else becomes ``CharacterRole/background``.
    public func applyDialoguePreset(
        mainSpeakerID: String,
        listenerIDs: [String] = []
    ) {
        // Set all to background first
        for id in characters.keys {
            updateCharacterRole(characterID: id, role: .background)
        }

        // Set main speaker
        updateCharacterRole(characterID: mainSpeakerID, role: .mainSpeaker)

        // Set listeners
        for listenerID in listenerIDs {
            updateCharacterRole(characterID: listenerID, role: .listener)
        }

        vrmLog("[CharacterPriority] Applied dialogue preset: speaker=\(mainSpeakerID), listeners=\(listenerIDs)")
    }

    /// Configures a crowd scene: closest character as speaker, next two as listeners, the rest as background.
    /// - Parameter cameraPosition: World-space camera position used for distance sorting.
    public func applyCrowdPreset(cameraPosition: SIMD3<Float>) {
        updateDistancesFromCamera(cameraPosition)

        let sortedByDistance = characters.values.sorted {
            $0.distanceFromCamera < $1.distanceFromCamera
        }

        // Closest character is main speaker
        if let closest = sortedByDistance.first {
            updateCharacterRole(characterID: closest.characterID, role: .mainSpeaker)
        }

        // Next 2 are listeners
        for character in sortedByDistance.dropFirst().prefix(2) {
            updateCharacterRole(characterID: character.characterID, role: .listener)
        }

        // Rest are background
        for character in sortedByDistance.dropFirst(3) {
            updateCharacterRole(characterID: character.characterID, role: .background)
        }

        vrmLog("[CharacterPriority] Applied crowd preset")
    }
}
