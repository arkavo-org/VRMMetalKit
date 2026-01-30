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
@testable import VRMMetalKit

// MARK: - Edge Case Value Sets

/// Float edge cases for fuzzing - values that commonly cause issues
enum FuzzEdgeCases {
    static let floats: [Float] = [
        0, -0, 1, -1,
        .infinity, -.infinity, .nan,
        .leastNormalMagnitude, .greatestFiniteMagnitude,
        .ulpOfOne, -.ulpOfOne,
        .leastNonzeroMagnitude,
        Float.pi, -Float.pi,
        1e-38, -1e-38,  // Near denormal
        1e38, -1e38     // Near max
    ]

    /// Joint indices that commonly cause issues
    static let jointIndices: [UInt32] = [
        0, 1,
        90, 91,          // Common skeleton sizes
        255, 256,        // UInt8 boundary
        65534, 65535,    // UInt16 max - sentinel values
        UInt32.max       // Maximum value
    ]

    /// Weights that commonly cause issues
    static let weights: [Float] = [
        0, 1, -1,
        0.0000001,       // Micro-weight (non-zero but tiny)
        0.5, 0.25,
        1.0001,          // Slightly over 1
        -0.0001,         // Slightly negative
        .nan, .infinity, -.infinity
    ]

    /// SIMD3 edge case vectors
    static let vectors: [SIMD3<Float>] = [
        .zero,
        SIMD3<Float>(1, 0, 0),
        SIMD3<Float>(0, 1, 0),
        SIMD3<Float>(0, 0, 1),
        SIMD3<Float>(-1, -1, -1),
        SIMD3<Float>(.infinity, 0, 0),
        SIMD3<Float>(.nan, .nan, .nan),
        SIMD3<Float>(.greatestFiniteMagnitude, .greatestFiniteMagnitude, .greatestFiniteMagnitude),
        SIMD3<Float>(.leastNormalMagnitude, .leastNormalMagnitude, .leastNormalMagnitude)
    ]
}

// MARK: - Random Generators

/// Generates random values for fuzzing, including edge cases
struct FuzzGenerator {
    private var rng: RandomNumberGenerator

    init(seed: UInt64 = 0) {
        self.rng = SeededRandomGenerator(seed: seed)
    }

    /// Generate a random float, occasionally returning edge cases
    mutating func randomFloat(in range: ClosedRange<Float> = -100...100, edgeCaseProbability: Float = 0.1) -> Float {
        if Float.random(in: 0...1, using: &rng) < edgeCaseProbability {
            return FuzzEdgeCases.floats.randomElement(using: &rng) ?? 0
        }
        return Float.random(in: range, using: &rng)
    }

    /// Generate a random joint index, occasionally returning edge cases
    mutating func randomJointIndex(maxValid: UInt32 = 90, edgeCaseProbability: Float = 0.1) -> UInt32 {
        if Float.random(in: 0...1, using: &rng) < edgeCaseProbability {
            return FuzzEdgeCases.jointIndices.randomElement(using: &rng) ?? 0
        }
        return UInt32.random(in: 0...maxValid, using: &rng)
    }

    /// Generate a random weight, occasionally returning edge cases
    mutating func randomWeight(edgeCaseProbability: Float = 0.1) -> Float {
        if Float.random(in: 0...1, using: &rng) < edgeCaseProbability {
            return FuzzEdgeCases.weights.randomElement(using: &rng) ?? 0
        }
        return Float.random(in: 0...1, using: &rng)
    }

    /// Generate a random SIMD3, occasionally returning edge cases
    mutating func randomVector(in range: ClosedRange<Float> = -100...100, edgeCaseProbability: Float = 0.1) -> SIMD3<Float> {
        if Float.random(in: 0...1, using: &rng) < edgeCaseProbability {
            return FuzzEdgeCases.vectors.randomElement(using: &rng) ?? .zero
        }
        return SIMD3<Float>(
            Float.random(in: range, using: &rng),
            Float.random(in: range, using: &rng),
            Float.random(in: range, using: &rng)
        )
    }

    /// Generate a random VRMVertex with fuzzed values
    mutating func randomVertex(maxJoints: UInt32 = 90) -> VRMVertex {
        var vertex = VRMVertex()
        vertex.position = randomVector(in: -10...10)
        vertex.normal = simd_normalize(randomVector(in: -1...1))
        vertex.texCoord = SIMD2<Float>(randomFloat(in: -2...2), randomFloat(in: -2...2))
        vertex.color = SIMD4<Float>(randomFloat(in: 0...2), randomFloat(in: 0...2), randomFloat(in: 0...2), randomFloat(in: 0...2))
        vertex.joints = SIMD4<UInt32>(
            randomJointIndex(maxValid: maxJoints),
            randomJointIndex(maxValid: maxJoints),
            randomJointIndex(maxValid: maxJoints),
            randomJointIndex(maxValid: maxJoints)
        )
        vertex.weights = SIMD4<Float>(
            randomWeight(),
            randomWeight(),
            randomWeight(),
            randomWeight()
        )
        return vertex
    }

    /// Generate random MToonMaterialUniforms with fuzzed values
    mutating func randomMToonUniforms() -> MToonMaterialUniforms {
        var uniforms = MToonMaterialUniforms()

        uniforms.baseColorFactor = SIMD4<Float>(
            randomFloat(in: -2...2), randomFloat(in: -2...2),
            randomFloat(in: -2...2), randomFloat(in: -2...2)
        )

        uniforms.shadeColorR = randomFloat(in: -2...2)
        uniforms.shadeColorG = randomFloat(in: -2...2)
        uniforms.shadeColorB = randomFloat(in: -2...2)
        uniforms.shadingToonyFactor = randomFloat(in: -2...2)

        uniforms.shadingShiftFactor = randomFloat(in: -2...2)
        uniforms.metallicFactor = randomFloat(in: -2...2)
        uniforms.roughnessFactor = randomFloat(in: -2...2)
        uniforms.giIntensityFactor = randomFloat(in: -2...2)

        uniforms.outlineWidthFactor = randomFloat(in: -10...10)
        uniforms.outlineMode = randomFloat(in: -5...5)
        uniforms.outlineLightingMixFactor = randomFloat(in: -2...2)

        uniforms.alphaMode = UInt32.random(in: 0...10, using: &rng)
        uniforms.alphaCutoff = randomFloat(in: -1...2)

        uniforms.parametricRimFresnelPowerFactor = randomFloat(in: -10...10)
        uniforms.parametricRimLiftFactor = randomFloat(in: -2...2)
        uniforms.rimLightingMixFactor = randomFloat(in: -2...2)

        return uniforms
    }

    /// Generate random BoneParams with fuzzed values
    mutating func randomBoneParams(maxParentIndex: UInt32 = 100) -> BoneParams {
        BoneParams(
            stiffness: randomFloat(in: -10...10),
            drag: randomFloat(in: -5...5),
            radius: randomFloat(in: -1...1),
            parentIndex: UInt32.random(in: 0...maxParentIndex, using: &rng),
            gravityPower: randomFloat(in: -100...100),
            colliderGroupMask: UInt32.random(in: 0...UInt32.max, using: &rng),
            gravityDir: randomVector(in: -10...10)
        )
    }

    /// Generate random SpringBoneGlobalParams with fuzzed values
    mutating func randomSpringBoneGlobalParams(numBones: UInt32 = 10) -> SpringBoneGlobalParams {
        SpringBoneGlobalParams(
            gravity: randomVector(in: -100...100),
            dtSub: randomFloat(in: -1...1),
            windAmplitude: randomFloat(in: -50...50),
            windFrequency: randomFloat(in: -10...10),
            windPhase: randomFloat(in: -100...100),
            windDirection: randomVector(in: -10...10),
            substeps: UInt32.random(in: 0...100, using: &rng),
            numBones: numBones,
            numSpheres: UInt32.random(in: 0...20, using: &rng),
            numCapsules: UInt32.random(in: 0...20, using: &rng),
            numPlanes: UInt32.random(in: 0...10, using: &rng),
            settlingFrames: UInt32.random(in: 0...1000, using: &rng),
            externalVelocity: randomVector(in: -100...100),
            dragMultiplier: randomFloat(in: -10...10)
        )
    }

    /// Generate random SphereCollider with fuzzed values
    mutating func randomSphereCollider() -> SphereCollider {
        SphereCollider(
            center: randomVector(in: -100...100),
            radius: randomFloat(in: -10...10),
            groupIndex: UInt32.random(in: 0...31, using: &rng)
        )
    }

    /// Generate random CapsuleCollider with fuzzed values
    mutating func randomCapsuleCollider() -> CapsuleCollider {
        CapsuleCollider(
            p0: randomVector(in: -100...100),
            p1: randomVector(in: -100...100),
            radius: randomFloat(in: -10...10),
            groupIndex: UInt32.random(in: 0...31, using: &rng)
        )
    }

    /// Generate random PlaneCollider with fuzzed values
    mutating func randomPlaneCollider() -> PlaneCollider {
        PlaneCollider(
            point: randomVector(in: -100...100),
            normal: randomVector(in: -10...10),
            groupIndex: UInt32.random(in: 0...31, using: &rng)
        )
    }
}

// MARK: - Seeded Random Generator

/// A seedable random number generator for reproducible fuzzing
struct SeededRandomGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed == 0 ? 0x853c49e6748fea9b : seed
    }

    mutating func next() -> UInt64 {
        // xorshift64* algorithm
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        return state &* 0x2545F4914F6CDD1D
    }
}

// MARK: - Validation Helpers

/// Checks if a float value is "safe" (not NaN, not infinite, within reasonable bounds)
func isSafeFloat(_ value: Float, maxMagnitude: Float = 1e10) -> Bool {
    !value.isNaN && !value.isInfinite && abs(value) <= maxMagnitude
}

/// Checks if a SIMD3 vector is "safe"
func isSafeVector(_ v: SIMD3<Float>, maxMagnitude: Float = 1e10) -> Bool {
    isSafeFloat(v.x, maxMagnitude: maxMagnitude) &&
    isSafeFloat(v.y, maxMagnitude: maxMagnitude) &&
    isSafeFloat(v.z, maxMagnitude: maxMagnitude)
}

/// Checks if a SIMD4 vector is "safe"
func isSafeVector4(_ v: SIMD4<Float>, maxMagnitude: Float = 1e10) -> Bool {
    isSafeFloat(v.x, maxMagnitude: maxMagnitude) &&
    isSafeFloat(v.y, maxMagnitude: maxMagnitude) &&
    isSafeFloat(v.z, maxMagnitude: maxMagnitude) &&
    isSafeFloat(v.w, maxMagnitude: maxMagnitude)
}

/// Checks if a 4x4 matrix is "safe"
func isSafeMatrix(_ m: simd_float4x4, maxMagnitude: Float = 1e10) -> Bool {
    isSafeVector4(m.columns.0, maxMagnitude: maxMagnitude) &&
    isSafeVector4(m.columns.1, maxMagnitude: maxMagnitude) &&
    isSafeVector4(m.columns.2, maxMagnitude: maxMagnitude) &&
    isSafeVector4(m.columns.3, maxMagnitude: maxMagnitude)
}

// MARK: - CPU Skinning Simulation

/// Simulates CPU skinning to validate GPU results
func cpuSkinVertex(_ vertex: VRMVertex, jointMatrices: [simd_float4x4]) -> SIMD3<Float> {
    var skinnedPosition = SIMD3<Float>.zero

    for i in 0..<4 {
        let jointIndex = Int(vertex.joints[i])
        let weight = vertex.weights[i]

        // Skip zero weights
        guard weight > 0 else { continue }

        // Bounds check
        guard jointIndex < jointMatrices.count else {
            // Out of bounds - this is a bug we want to catch
            return SIMD3<Float>(.nan, .nan, .nan)
        }

        let matrix = jointMatrices[jointIndex]
        let pos4 = SIMD4<Float>(vertex.position.x, vertex.position.y, vertex.position.z, 1.0)
        let transformed = matrix * pos4
        skinnedPosition += SIMD3<Float>(transformed.x, transformed.y, transformed.z) * weight
    }

    return skinnedPosition
}

// MARK: - Test Result Tracking

/// Tracks fuzzing test results for analysis
struct FuzzingResult {
    let iteration: Int
    let seed: UInt64
    let passed: Bool
    let failureReason: String?
    let inputDescription: String

    init(iteration: Int, seed: UInt64, passed: Bool, failureReason: String? = nil, inputDescription: String = "") {
        self.iteration = iteration
        self.seed = seed
        self.passed = passed
        self.failureReason = failureReason
        self.inputDescription = inputDescription
    }
}

/// Collects and summarizes fuzzing results
final class FuzzingResultCollector {
    private(set) var results: [FuzzingResult] = []
    private(set) var failures: [FuzzingResult] = []

    func record(_ result: FuzzingResult) {
        results.append(result)
        if !result.passed {
            failures.append(result)
        }
    }

    var summary: String {
        let total = results.count
        let failed = failures.count
        let passed = total - failed

        var summary = "Fuzzing Summary: \(passed)/\(total) passed"

        if !failures.isEmpty {
            summary += "\n\nFailures:"
            for failure in failures.prefix(10) {
                summary += "\n  - Iteration \(failure.iteration) (seed: \(failure.seed)): \(failure.failureReason ?? "unknown")"
                if !failure.inputDescription.isEmpty {
                    summary += "\n    Input: \(failure.inputDescription)"
                }
            }
            if failures.count > 10 {
                summary += "\n  ... and \(failures.count - 10) more failures"
            }
        }

        return summary
    }

    var hasFailures: Bool { !failures.isEmpty }
}
